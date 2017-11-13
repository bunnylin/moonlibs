unit mccommon;

{                                                                           }
{ Mooncore common functions unit                                            }
{ CC0, 2016-2017 : Kirinn Bunnylin / MoonCore                               }
{ Use freely for anything ever!                                             }
{                                                                           }

{$mode fpc}
{$WARN 4079 off} // Spurious hints: Converting the operands to "Int64" before
{$WARN 4080 off} // doing the operation could prevent overflow errors.
{$WARN 4081 off}

interface

const hextable : array[0..$F] of char = (
'0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F');

function strhex(luku : ptruint) : string;
function strdec(luku : ptruint) : string;
function strdec(luku : ptrint) : string;
function valx(const luku : string) : ptrint;
function valhex(const luku : string) : ptruint;
function CompStr(str1p, str2p : pointer; str1len, str2len : dword) : longint;
function CutNumberFromString(const src : UTF8string; var ofs : dword) : longint;
function MatchString(const str1, str2 : UTF8string; var ofs : dword) : boolean;
procedure DumpBuffer(buffy : pointer; buflen : dword);
function errortxt(const ernum : byte) : string;

// ------------------------------------------------------------------

implementation

function strhex(luku : ptruint) : string;
// Takes a value and returns it in hex in an ascii string.
begin
 strhex := '';
 repeat
  strhex := hextable[luku and $F] + strhex;
  luku := luku shr 4;
 until luku = 0;
 if length(strhex) = 1 then strhex := '0' + strhex;
end;

function strdec(luku : ptruint) : string;
// Takes a value and returns it in plain numbers in an ascii string.
begin
 strdec := '';
 repeat
  strdec := chr(luku mod 10 + 48) + strdec;
  luku := luku div 10;
 until luku = 0;
end;

function strdec(luku : ptrint) : string;
var signage : boolean;
begin
 strdec := ''; signage := FALSE;
 if luku < 0 then begin signage := TRUE; luku := -luku; end;
 repeat
  strdec := chr(luku mod 10 + 48) + strdec;
  luku := luku div 10;
 until luku = 0;
 if signage then strdec := '-' + strdec;
end;

function valx(const luku : string) : ptrint;
// Takes a string and returns any possible value it encounters at the start.
var tempvar : byte;
    nega : boolean;
begin
 valx := 0; tempvar := 1; nega := FALSE;
 if luku = '' then exit;
 while (tempvar <= length(luku))
 and (ord(luku[tempvar]) in [45, 48..57] = FALSE)
  do inc(tempvar);
 if tempvar > length(luku) then exit;

 if luku[tempvar] = '-' then begin
  inc(tempvar); nega := TRUE;
 end;
 while luku[tempvar] in ['0'..'9'] do begin
  valx := valx * 10 + ord(luku[tempvar]) and $F;
  inc(tempvar);
  if tempvar > length(luku) then break;
 end;
 if nega then valx := -valx;
end;

function valhex(const luku : string) : ptruint;
// Takes a string and returns the first hexadecimal value it finds.
var tempvar : byte;
begin
 valhex := 0; tempvar := 1;
 if luku = '' then exit;
 while (tempvar <= length(luku)) and (luku[tempvar] in ['0'..'9','A'..'F','a'..'f'] = FALSE) do inc(tempvar);
 if tempvar > length(luku) then exit;

 repeat
  case ord(luku[tempvar]) of
    48..57: valhex := (valhex shl 4) or byte(ord(luku[tempvar]) and $F);
    65..70: valhex := (valhex shl 4) or byte(ord(luku[tempvar]) - 55);
    97..102: valhex := (valhex shl 4) or byte(ord(luku[tempvar]) - 87);
    else exit;
  end;
  inc(tempvar);
  if tempvar > length(luku) then begin exit; end;
 until FALSE;
end;

// ------------------------------------------------------------------

function CompStr(str1p, str2p : pointer; str1len, str2len : dword) : longint;
// For sorting: returns 0 if str1 = str2, a positive value if str1 > str2,
// and a negative value if str1 < str2. The value is equal to the difference
// between the first differing character.
var ivar : dword;
begin
 ivar := str1len;
 if str1len > str2len then ivar := str2len;
 CompStr := CompareByte(str1p^, str2p^, ivar);
 if CompStr = 0 then begin
  if str1len = str2len then exit;
  inc(CompStr);
  if str1len < str2len then CompStr := -1;
 end;
end;

function CutNumberFromString(const src : UTF8string; var ofs : dword) : longint;
// Finds the first number character or minus-sign in src at or after the byte
// offset ofs, reads all number characters from that on and returns the built
// value. Also moves the ofs index to point to the first character after the
// last harvested numeral, or end of string of no numerals found.
// Ofs is 1-based.
// If the string isn't valid, or ofs is out of bounds, or there just aren't
// any numerals, returns 0.
// This will only recognise integer decimals, not hex or anything.
// The output number is cropped to range [-$7FFF FFF7 .. $7FFF FFF7].
var reading, negatron : boolean;
begin
 CutNumberFromString := 0;
 negatron := FALSE;
 reading := FALSE;
 while ofs <= dword(length(src)) do begin
  if char(src[ofs]) = '-' then begin
   if reading then break;
   negatron := TRUE;
  end
  else if char(src[ofs]) in ['0'..'9'] then begin
   reading := TRUE;
   if CutNumberFromString > 214748363 then CutNumberFromString := $7FFFFFF7
   else CutNumberFromString := CutNumberFromString * 10 + ord(src[ofs]) and $F;
  end
  else begin
   if reading then break;
   negatron := FALSE;
  end;
  inc(ofs);
 end;
 if negatron then CutNumberFromString := -CutNumberFromString;
end;

function MatchString(const str1, str2 : UTF8string; var ofs : dword) : boolean;
// Checks if str2 exists exactly at str1[ofs], returns TRUE if so.
// If an exact match was found, also moves ofs to point to the offset in
// str1 after the last matched character. Otherwise doesn't modify ofs.
// Ofs is 1-based.
var ivar, str2len : dword;
    str1ofs, str2ofs : pointer;
begin
 MatchString := FALSE;
 str2len := length(str2);
 // Are there even enough characters to compare?
 if (str2len = 0) or (dword(length(str1)) + 1 < ofs + str2len) then exit;

 // First do dword compares.
 str1ofs := @str1[ofs];
 str2ofs := @str2[1];
 ivar := str2len shr 2;
 while ivar <> 0 do begin
  if dword(str1ofs^) <> dword(str2ofs^) then exit;
  inc(str1ofs, 4);
  inc(str2ofs, 4);
  dec(ivar);
 end;

 // Finally do byte compares.
 ivar := str2len and 3;
 while ivar <> 0 do begin
  if byte(str1ofs^) <> byte(str2ofs^) then exit;
  inc(str1ofs);
  inc(str2ofs);
  dec(ivar);
 end;

 // Made it all the way, found a match!
 inc(ofs, str2len);
 MatchString := TRUE;
end;

procedure DumpBuffer(buffy : pointer; buflen : dword);
{$ifdef dumpbufferaltstyle}
// Prints out the given memory region as standard output in a human-readable
// format: offsets in the left column, bytes in plain hex in the middle, and
// an ascii representation in the right column.
// Widths: 6 offset, 3 spacer, 16 x 3 bytes with 4x2 spacers, 16 ascii
var ascii, strutsi : string;
    bufofs : dword;
begin
 bufofs := 0;
 while buflen <> 0 do begin
  dec(buflen);

  // Start of row: print offset.
  if bufofs and $F = 0 then begin
   strutsi := strhex(bufofs);
   write(space(6 - length(strutsi)) + strutsi + ':  ');
   ascii := '';
  end;

  // Middle: print bytes, with vertical divider after every fourth.
  inc(bufofs);
  if bufofs and 3 = 0 then write(strhex(byte(buffy^)) + '  ')
  else write(strhex(byte(buffy^)) + ' ');
  inc(byte(ascii[0]));
  // Construct the ascii representation while at it.
  if byte(buffy^) in [0..31, 255]
  then ascii[byte(ascii[0])] := '.'
  else ascii[byte(ascii[0])] := char(buffy^);

  // End of row: print ascii representation.
  if bufofs and $F = 0 then writeln(ascii);

  inc(buffy);
 end;
 // End of data: print ascii representation.
 if bufofs and $F <> 0 then
  writeln(space(
  (16 - (bufofs and $F)) * 3 // skip rest of middle bytes on this row
  + 4 - ((bufofs and $F) shr 2) // skip remaining spacers on this row
  ) + ascii);
end;
{$else}
var bufofs : dword;
begin
 bufofs := 0;
 while buflen <> 0 do begin
  dec(buflen);
  case byte(buffy^) of
    0..31, 127..255: write('[' + strhex(byte(buffy^)) + ']');
    else write(char(buffy^));
  end;
  inc(bufofs);
  if bufofs and $F = 0 then writeln;
  inc(buffy);
 end;
 if bufofs and $F <> 0 then writeln;
end;
{$endif}

// ------------------------------------------------------------------

function errortxt(const ernum : byte) : string;
begin
 case ernum of
   2: errortxt := 'File not found';
   3: errortxt := 'Path not found';
   5: errortxt := 'Access denied';
   6: errortxt := 'File handle trashed, memory corrupted!';
   100: errortxt := 'Disk read error';
   101: errortxt := 'Disk write error or printed incomplete UTF8';
   103: errortxt := 'File not open';
   200: errortxt := 'Div by zero!!';
   201: errortxt := 'Range check error';
   202: errortxt := 'Stack overflow';
   203: errortxt := 'Heap overflow, out of mem';
   204: errortxt := 'Invalid pointer operation';
   205: errortxt := 'FP overflow';
   206: errortxt := 'FP underflow';
   207: errortxt := 'Invalid FP op';
   215: errortxt := 'Arithmetic overflow';
   216: errortxt := 'General protection fault';
   217: errortxt := 'Unhandled exception';
   else errortxt := 'Unlisted error';
 end;
 errortxt := strdec(ernum) + ': ' + errortxt;
end;

// ------------------------------------------------------------------

initialization
finalization
end.
