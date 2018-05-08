unit mcfileio;
// File I/O, mainly a loader object, but also saving and name case handling.

{$mode objfpc}
{$I-}

// On case-sensitive filesystems, user experience can be improved by doing
// some extra case-insensitive checks.
{$ifndef WINDOWS}{$define caseshenanigans}{$endif}

interface

type TFileLoader = class
  private
    buffy, buffyendp : pointer;
    buffysize : ptruint;
    m_filename : UTF8string;
    function GetOfs : ptruint;
    procedure SetOfs(newofs : ptruint);
    procedure SetSize(newsize : ptruint);

  public
    property ofs : ptruint read GetOfs write SetOfs;
    property size : ptruint read buffysize write SetSize;
    property endp : pointer read buffyendp;
    property filename : UTF8string read m_filename;

  public
    readp : pointer;
    bitindex : byte; // 7 = top, 0 = bottom

    function ReadBit : boolean;
    function ReadByte : byte; inline;
    function ReadWord : word; inline;
    function ReadDword : dword; inline;
    function ReadString : UTF8string;
    function ReadByteFrom(readofs : ptruint) : byte; inline;
    function ReadWordFrom(readofs : ptruint) : word; inline;
    function ReadDwordFrom(readofs : ptruint) : dword; inline;
    function ReadStringFrom(readofs : ptruint) : UTF8string;
    function PtrAt(writeofs : ptruint) : pointer;

  constructor Open(const filepath : UTF8string);
  destructor Destroy(); override;
end;

{$ifdef caseshenanigans}
function FindFile_caseless(const filepath : UTF8string) : UTF8string;
{$endif}
procedure SaveFile(const filepath : UTF8string; buf : pointer; bufsize : ptruint);

// ------------------------------------------------------------------
implementation

uses sysutils, mccommon;

{$ifdef caseshenanigans}
function FindFile_caseless(const filepath : UTF8string) : UTF8string;
// Tries to find the given filename using a case-insensitive search.
// Wildcards not supported. The path still has to be case-correct. :(
// This can be used to find a single specific file on *nixes without knowing
// the exact case used in the filename.
// Returns the full case-correct path+name, or an empty string if not found.
// If multiple identically-named, differently-cased files exist, returns
// whichever FindFirst picks up first.
var filusr : TSearchRec;
    basedir, basename : UTF8string;
    findresult : longint;
begin
 FindFile_caseless := '';
 basename := lowercase(ExtractFileName(filepath));
 basedir := copy(filepath, 1, length(filepath) - length(basename));

 findresult := FindFirst(basedir + '*', faReadOnly, filusr);
 while findresult = 0 do begin
  if lowercase(filusr.Name) = basename then begin
   FindFile_caseless := basedir + filusr.Name;
   break;
  end;
  findresult := FindNext(filusr);
 end;
 FindClose(filusr);
end;
{$endif caseshenanigans}

// ------------------------------------------------------------------

constructor TFileLoader.Open(const filepath : UTF8string);
// Loads the given file's binary contents into the loader object.
// Does not care what the actual file content is.
// In case of errors, throws an exception.
var f : file;
    i : dword;
begin
 buffy := NIL;
 readp := NIL;
 buffyendp := NIL;
 m_filename := copy(filepath, 1);

 while IOresult <> 0 do; // flush
 assign(f, m_filename);
 filemode := 0; reset(f, 1); // read-only
 i := IOresult;
 {$ifdef caseshenanigans}
 // If the file wasn't found, we may have the wrong case in the file name...
 if i = 2 then begin
  m_filename := FindFile_caseless(m_filename);
  if m_filename <> '' then begin
   assign(f, m_filename);
   filemode := 0; reset(f, 1); // read-only
   i := IOresult;
  end;
 end;
 {$endif caseshenanigans}
 if i <> 0 then raise Exception.Create(errortxt(i) + ' opening ' + m_filename);

 // Load the entire file.
 buffysize := filesize(f);
 getmem(buffy, buffysize);
 blockread(f, buffy^, buffysize);
 i := IOresult;
 close(f);
 if i <> 0 then raise Exception.Create(errortxt(i) + ' reading ' + m_filename);

 readp := buffy;
 buffyendp := buffy + buffysize;
end;

destructor TFileLoader.Destroy;
begin
 if buffy <> NIL then begin freemem(buffy); buffy := NIL; end;
 inherited;
end;

function TFileLoader.GetOfs : ptruint;
// Returns the current read offset from the start of the file buffer.
begin
 result := readp - buffy;
end;

procedure TFileLoader.SetOfs(newofs : ptruint);
// Sets the current read offset.
begin
 readp := buffy + newofs;
 if readp > buffyendp then readp := buffyendp;
end;

procedure TFileLoader.SetSize(newsize : ptruint);
// Adjusts the buffer size. If shrinking, doesn't touch the buffer, only
// decreases endp. If growing, reallocates the whole thing (very slow). The
// newly allocated bytes are not initialised.
var i : ptruint;
begin
 if newsize > buffysize then begin
  i := ofs;
  reallocmem(buffy, newsize);
  readp := buffy + i;
 end;
 buffysize := newsize;
 buffyendp := buffy + buffysize;
 if readp > buffyendp then readp := buffyendp;
end;

function TFileLoader.ReadBit : boolean;
// Returns the next bit from buffy, advances read counters.
// Range checking is the caller's responsibility.
begin
 if bitindex = 0 then begin
  ReadBit := (byte(readp^) and 1) <> 0;
  inc(readp);
  bitindex := 7;
  exit;
 end;

 ReadBit := ((byte(readp^) shr bitindex) and 1) <> 0;
 dec(bitindex);
end;

function TFileLoader.ReadByte : byte; inline;
// Returns the next byte from buffy, advances read counter.
// Range checking is the caller's responsibility.
begin
 ReadByte := byte(readp^);
 inc(readp);
end;

function TFileLoader.ReadWord : word; inline;
// Returns the next word from buffy, advances read counter.
// Range checking is the caller's responsibility.
begin
 ReadWord := word(readp^);
 inc(readp, 2);
end;

function TFileLoader.ReadDword : dword; inline;
// Returns the next dword from buffy, advances read counter.
// Range checking is the caller's responsibility.
begin
 ReadDword := dword(readp^);
 inc(readp, 4);
end;

function TFileLoader.ReadString : UTF8string;
// Returns the next null-terminated string from buffy, advances read counter.
// Does range checking. If the requested string goes beyond the buffer, cuts
// the string at the buffer boundary.
var lenp : pointer;
    length : ptruint;
begin
 lenp := readp;
 while (lenp < buffyendp) and (byte(lenp^) <> 0) do inc(lenp);
 length := lenp - readp;

 setlength(result, length);
 if length <> 0 then move(readp^, result[1], length);
 inc(readp, length);
end;

function TFileLoader.ReadByteFrom(readofs : ptruint) : byte; inline;
// Returns a byte from the given offset in buffy. Does not advance read
// counters, but throws an exception the read is out of bounds.
begin
 if readofs >= size then raise Exception.Create('ReadByteFrom out of bounds');
 result := byte((buffy + readofs)^);
end;

function TFileLoader.ReadWordFrom(readofs : ptruint) : word; inline;
// Returns the next word from buffy, advances read counter.
// Range checking is the caller's responsibility.
begin
 if readofs + 1 >= size then raise Exception.Create('ReadWordFrom out of bounds');
 result := word((buffy + readofs)^);
end;

function TFileLoader.ReadDwordFrom(readofs : ptruint) : dword; inline;
// Returns the next dword from buffy, advances read counter.
// Range checking is the caller's responsibility.
begin
 if readofs + 3 >= size then raise Exception.Create('ReadDwordFrom out of bounds');
 result := dword((buffy + readofs)^);
end;

function TFileLoader.ReadStringFrom(readofs : ptruint) : UTF8string;
// Returns a null-terminated string from the given offset in buffy.
// Does not advance read counters, but does range checking. If the requested
// string goes beyond the buffer, cuts the string at the buffer boundary.
var startp, lenp : pointer;
    length : ptruint;
begin
 startp := buffy + readofs;
 lenp := startp;
 while (lenp < buffyendp) and (byte(lenp^) <> 0) do inc(lenp);
 length := lenp - startp;

 setlength(result, length);
 if length <> 0 then move(startp^, result[1], length);
end;

function TFileLoader.PtrAt(writeofs : ptruint) : pointer;
// Returns a pointer at the given offset in buffy. Does range checking.
// If the requested offset is out of bounds, throws an exception.
begin
 if writeofs >= buffysize then raise Exception.Create('PtrAt out of bounds');
 result := buffy + writeofs;
end;

procedure SaveFile(const filepath : UTF8string; buf : pointer; bufsize : ptruint);
// Saves bufsize bytes from buf^ into the given file. If the file exists, it
// is overwritten without warning.
// In case of errors, throws an exception.
var f : file;
    target : UTF8string;
    i, j : dword;
begin
 if filepath = '' then raise Exception.Create('no file name specified');

 while IOresult <> 0 do; // flush
 {$ifdef caseshenanigans}
 // On case-sensitive filesystems, to avoid ending up with multiple
 // identically-named differently-cased files, we must explicitly delete any
 // previous file that has a matching name.
 target := FindFile_caseless(filepath);
 if target <> '' then begin
  assign(f, target);
  erase(f);
 end;
 {$endif}

 // Make sure the target directory exists.
 for i := 2 to length(filepath) do
  if filepath[i] = DirectorySeparator then begin
   target := copy(filepath, 1, i);
   if DirectoryExists(target) = FALSE then begin
    mkdir(target);
    j := IOresult;
    if j <> 0 then raise Exception.Create(errortxt(j) + ' creating directory ' + target);
   end;
  end;

 // Try to write the file.
 assign(f, filepath);
 filemode := 1; rewrite(f, 1); // write-only
 i := IOresult;
 if i <> 0 then raise Exception.Create(errortxt(i) + ' creating ' + filepath);

 blockwrite(f, buf^, bufsize);
 i := IOresult;
 close(f);
 if i <> 0 then raise Exception.Create(errortxt(i) + ' writing ' + filepath);

 while IOresult <> 0 do; // flush
end;

initialization
finalization
end.
