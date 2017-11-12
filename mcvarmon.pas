unit mcvarmon;
{                                                                           }
{ Mooncore Varmon variable management system                                }
{ Copyright 2016-2017 :: Kirinn Bunnylin / MoonCore                         }
{                                                                           }
{ Available under the zlib license:                                         }
{                                                                           }
{ This software is provided 'as-is', without any express or implied         }
{ warranty.  In no case will the authors be held liable for any damages     }
{ arising from the use of this software.                                    }
{                                                                           }
{ Permission is granted to anyone to use this software for any purpose,     }
{ including commercial applications, and to alter it and redistribute it    }
{ freely, subject to the following restrictions:                            }
{                                                                           }
{ 1. The origin of this software must not be misrepresented; you must not   }
{    claim that you wrote the original software. If you use this software   }
{    in a product, an acknowledgment in the product documentation would be  }
{    appreciated but is not required.                                       }
{ 2. Altered source versions must be plainly marked as such, and must not   }
{    be misrepresented as being the original software.                      }
{ 3. This notice may not be removed or altered from any source              }
{    distribution.                                                          }
{                                                                           }

// Variables are referenced by shortstring ascii names. Existing variable
// names are kept in hash buckets so they're quick to access. In each bucket,
// variable names are in a linked list, where any accessed name is moved to
// the top of the list, so scanning from the top of the list finds recently
// used variables fast.
//
// The actual variable values are kept in a separate direct array. All public
// access to the arrays is via getters and setters. Variable names are all
// case-insensitive.
//
// String variables are stored as a set, since when dealing with multiple
// simultaneous languages, it's necessary to keep a copy of every string in
// every language. For ease of access, a stringstash is used. Getters place
// their results in the stash, and setters take strings from the stash. If
// a string is not available in the requested language, the caller will get
// an empty string for those, and may prefer to substitute with the string
// from language 0.
//
// SaveVarState can be used to create a packed snapshot of the current set of
// variables system, which is easy to include in a save game file, perhaps
// with added compression. LoadVarState restores the saved state.
//
// Game-specific engine variables could be stored in these as well, so
// they'll be smoothly saved with the other variables. You can write-protect
// these by calling Set*Var with sudo = TRUE, so game scripts (which sudo
// should not be allowed for) can read but not write these variables.

// ------------------------------------------------------------------

{$mode objfpc}
{$codepage UTF8}

interface

uses mccommon, sysutils;

procedure LoadVarState(poku : pointer);
procedure SaveVarState(var poku : pointer);
function GetVarType(const varnamu : string) : byte;
procedure SetNumVar(const varnamu : string; num : longint; sudo : boolean);
function GetNumVar(const varnamu : string) : longint;
procedure SetStrVar(const varnamu : string; sudo : boolean);
procedure GetStrVar(const varnamu : string);
procedure SetNumBuckets(const newbuckets : dword);
function CountNumVars : dword;
function CountStrVars : dword;
function CountBuckets : dword;
procedure VarmonInit(numlang, numbuckets : dword);

const VARMON_MAXBUCKETS = 999999;
      VARMON_MAXLANGUAGES = 999;
      VARMON_VARTYPENULL = 0;
      VARMON_VARTYPEINT = 1;
      VARMON_VARTYPESTR = 2;

var stringstash : array of UTF8string;

// ------------------------------------------------------------------
implementation

var bucket : array of record
      bucketsize : dword;
      toplink : dword;
      content : array of record
        namu : string;
        varnum : dword;
        prevlink, nextlink : dword; // prev = topward, next = bottomward
        vartype : byte; // VARMON_VARTYPE*
        special : byte; // 0 = normal, 1 = readonly system var
      end;
    end;

    numvar : array of longint;
    strvar : array of record
      txt : array of UTF8string;
    end;

    bucketcount, numvarcount, strvarcount, numlanguages, danglies : dword;
    addbucketsautomatically : boolean;

{$define !debugdump}
{$ifdef debugdump}
procedure DumpVarTable;
var b, cont : dword;
begin
 for b := 0 to bucketcount - 1 do begin
  if bucket[b].bucketsize <> 0 then
  for cont := 0 to bucket[b].bucketsize - 1 do
  with bucket[b].content[cont] do begin
   write('$',namu,chr(9),'bucket=',b,':',cont);
   if cont = bucket[b].toplink then write('*');
   write(chr(9),'prev=',prevlink,chr(9),'next=',nextlink,chr(9),'type=',vartype,chr(9),'spec=',special,chr(9));
   if vartype = VARMON_VARTYPEINT then write(numvar[varnum]) else
   if vartype = VARMON_VARTYPESTR then write(strvar[varnum].txt[0]);
   writeln;
  end;
 end;
end;
{$endif}

function HashString(const varnamu : string) : dword;
// Returns the bucket number that this variable name belongs to.
var i : dword;
    strlen : byte;
begin
 HashString := 0;
 strlen := length(varnamu);
 i := 1;
 while i + 3 <= strlen do begin
  HashString := RORdword(HashString, 13);
  HashString := HashString xor dword((@varnamu[i])^);
  inc(i, 4);
 end;
 while i <= strlen do begin
  HashString := RORdword(HashString, 3);
  HashString := HashString xor byte(varnamu[i]);
  inc(i);
 end;
 HashString := HashString mod bucketcount;
end;

function FindVar(const varnamu : string) : dword;
// Checks if the given variable name exists in the variable buckets. If it
// does, the variable is moved to the top of its bucket, and FindVar returns
// the bucket's number. If the variable doesn't exist, returns the bucket's
// number OR $8000 0000 so the caller can add it to the bucket if desired.
var i, j : dword;
begin
 FindVar := HashString(varnamu);
 i := bucket[FindVar].bucketsize;

 if i = 0 then begin
  // Empty bucket! this variable name doesn't exist yet.
  FindVar := FindVar or $80000000;
  exit;
 end;

 j := bucket[FindVar].toplink;
 while i <> 0 do with bucket[FindVar] do begin
  if content[j].namu = varnamu then begin
   // Found a match!
   // Move the matched variable name to the top, if not already at the top.
   if toplink <> j then begin
    if i <> 1 then begin
     // Detach from current link position, if not at very bottom.
     content[content[j].prevlink].nextlink := content[j].nextlink;
     content[content[j].nextlink].prevlink := content[j].prevlink;
    end;
    // Prepare own link.
    content[j].nextlink := toplink;
    // Attach at top link position.
    content[toplink].prevlink := j;
    toplink := j;
   end;
   exit; // return the bucket number
  end;
  j := content[j].nextlink;
  dec(i);
 end;

 // No match found in bucket, this variable name doesn't exist yet.
 FindVar := FindVar or $80000000;
end;

function AddVar(const varnamu : string; typenum : byte; sudo : boolean) : dword;
// Checks if the given variable name exists yet. If not, creates it. If it
// exists, overwrites it, unless the variable is write-protected and sudo is
// not set.
// Returns the bucket number where the variable can be found topmost.
var poku : pointer;

  function NewNumVar : dword;
  // Adds a new slot to the number var array, returns the slot number.
  begin
   if dword(length(numvar)) <= numvarcount then setlength(numvar, length(numvar) + 16);
   NewNumVar := numvarcount;
   inc(numvarcount);
  end;

  function NewStrVar : dword;
  // Adds a new slot to the string var array, returns the slot number.
  begin
   if dword(length(strvar)) <= strvarcount then setlength(strvar, length(strvar) + 16);
   setlength(strvar[strvarcount].txt, numlanguages);
   NewStrVar := strvarcount;
   inc(strvarcount);
  end;

begin
 if NOT typenum in [VARMON_VARTYPEINT, VARMON_VARTYPESTR] then
  raise Exception.create('AddVar: bad type ' + strdec(typenum) + ' for ' + varnamu);
 AddVar := FindVar(varnamu);
 if AddVar < $80000000 then begin
  // This variable already exists...
  with bucket[AddVar].content[bucket[AddVar].toplink] do begin
   // Check if it's write-protected and can't be changed.
   if sudo = FALSE then begin
    if special and 1 <> 0 then
     raise Exception.create('Variable ' + varnamu + ' is write-protected');
    special := 0;
   end
   else special := 1;
   // If the variable type is changed, must set up a new variable slot.
   // (the old slot is left dangling...)
   if vartype <> typenum then begin
    if typenum = VARMON_VARTYPEINT then varnum := NewNumVar else varnum := NewStrVar;
    vartype := typenum;
    inc(danglies);
    if danglies > 1000 then begin
     // Too many dangling. Reshuffle all variables, may take a moment...
     // This only happens if a script keeps switching same named variables
     // between number and string types, which you shouldn't be doing anyway.
     poku := NIL;
     SaveVarState(poku);
     LoadVarState(poku); // loadstate sets danglies to 0
     freemem(poku); poku := NIL;
    end;
   end;
  end;
  exit;
 end;

 // This variable doesn't exist... clear the inexistence bit.
 AddVar := AddVar and $7FFFFFFF;

 // If the content array is getting quite big, and automatic bucket
 // management is enabled, add more buckets. This causes a slight delay as
 // all existing variables are redistributed.
 if (addbucketsautomatically) and (length(bucket[AddVar].content) >= 80)
 then begin
  poku := NIL;
  SaveVarState(poku);
  inc(dword((poku + 4)^), 4); // poke a bigger bucket count directly in
  LoadVarState(poku);
  freemem(poku); poku := NIL;
  // Find the new bucket this variable will go in.
  AddVar := FindVar(varnamu) and $7FFFFFFF;
 end;

 with bucket[AddVar] do begin
  // Make sure the bucket's content array is big enough for a new slot.
  if bucketsize >= dword(length(content)) then setlength(content, length(content) + 16);
  // Set up the new slot.
  with content[bucketsize] do begin
   namu := varnamu;
   if typenum = VARMON_VARTYPEINT then varnum := NewNumVar else varnum := NewStrVar;
   vartype := typenum;
   special := 0;
   if sudo then special := 1;
  end;
  // Make the new item the topmost in the bucket's chain.
  content[bucketsize].nextlink := toplink;
  content[toplink].prevlink := bucketsize;
  toplink := bucketsize;

  inc(bucketsize);
 end;
end;

procedure LoadVarState(poku : pointer);
// The input variable must be a pointer to a packed snapshot created by the
// above SaveState procedure. The snapshot is extracted over existing
// variable data, including overwriting the bucket count.
// If the current number of languages is fewer than the languages in the
// snapshot, the extra language string variables are dropped. If the current
// languages is greater, then language 0 is copied to the extra languages.
// The caller is responsible for freeing the buffer.
// The savestate buffer is not robustly checked for correctness, beware.
var i, j, k, l, m, ofsu : dword;
    memused, savedbuckets, numnumerics, numstrings, savedlanguages : dword;
begin
 // Safeties, read the header.
 if poku = NIL then raise Exception.create('LoadVarState: tried to load null');
 memused := dword(poku^);
 if memused < 20 then raise Exception.create('LoadVarState: state too small, corrupted?');
 savedbuckets := dword((poku + 4)^);
 addbucketsautomatically := (savedbuckets and $80000000) <> 0;
 savedbuckets := savedbuckets and $7FFFFFFF;
 if savedbuckets = 0 then raise Exception.create('LoadVarState: state numbuckets = 0');
 if savedbuckets > VARMON_MAXBUCKETS then raise Exception.create('LoadVarState: state numbuckets > max');
 numnumerics := dword((poku + 8)^);
 numstrings := dword((poku + 12)^);
 savedlanguages := dword((poku + 16)^);
 if savedlanguages = 0 then raise Exception.create('LoadVarState: state savedlanguages = 0');
 if savedlanguages > VARMON_MAXLANGUAGES then raise Exception.create('LoadVarState: state savedlanguages > max');
 ofsu := 20;

 // Clear and re-init everything.
 // Note, that this will not change numlanguages, even if the savestate has
 // a different language count! Numlanguages can only be equal to however
 // many languages the caller currently has available. So while loading
 // a state, any extra saved languages are dropped; if the state is missing
 // languages, then language 0 is substituted for the missing strings.
 VarmonInit(numlanguages, savedbuckets);
 setlength(numvar, numnumerics + 8);
 setlength(strvar, numstrings + 8);
 for i := length(strvar) - 1 downto 0 do
  setlength(strvar[i].txt, numlanguages);

 // Read the variables into memory.
 while ofsu + 4 < memused do begin
  l := byte((poku + ofsu)^); inc(ofsu); // variable type
  m := byte((poku + ofsu)^); inc(ofsu); // specialness
  k := AddVar(string((poku + ofsu)^), l, m <> 0);
  inc(ofsu, byte((poku + ofsu)^) + byte(1));
  j := bucket[k].content[bucket[k].toplink].varnum;
  if l = VARMON_VARTYPEINT then begin
   // numeric variable!
   numvar[j] := longint((poku + ofsu)^);
   inc(ofsu, 4);
  end else begin
   // string variable!
   i := 0;
   repeat
    // Numlanguages and savedlanguages are hopefully equal, but if not,
    // there are four options for each language index...
    if i < numlanguages then begin
     if i < savedlanguages then begin
      // slot is within loaded languages and within languages in snapshot:
      // copy snapshot language string normally
      setlength(stringstash[i], dword((poku + ofsu)^)); inc(ofsu, 4);
      move((poku + ofsu)^, stringstash[i][1], length(stringstash[i]));
      inc(ofsu, dword(length(stringstash[i])));
     end else begin
      // slot is within loaded languages but beyond languages in snapshot:
      // copy language 0 string
      stringstash[i] := stringstash[0];
     end;
    end else begin
     if i < savedlanguages then begin
      // slot is beyond loaded languages but within languages in snapshot:
      // this language string must be dropped, there's nowhere to put it
      inc(ofsu, dword((poku + ofsu)^) + 4);
     end else begin
      // slot is beyond loaded languages and beyond languages in snapshot:
      // that means we're done with this string set!
      break;
     end;
    end;

    inc(i);
   until FALSE;
   setlength(strvar[j].txt, numlanguages);
   for i := 0 to numlanguages - 1 do
    strvar[j].txt[i] := stringstash[i];
  end;
 end;
end;

procedure SaveVarState(var poku : pointer);
// The input variable must be a null pointer. A packed snapshot of the
// current variable state is placed there.
// The caller is responsible for freeing the buffer, and may want to compress
// the buffer if saving in a file.
//
// Snapshot content:
//   dword : byte size of used memory including this dword
//   dwords : bucketcount, numnumerics, numstrings, numlanguages
//     (except bucketcount's top bit is addbucketsautomatically)
//   array[numnumerics + numstrings] of :
//     byte : variable type
//     byte : specialness value
//     ministring : variable name
//     if numeric then longint : variable value
//     if string then array[numlanguages] of :
//       dword : UTF-8 string byte length
//       array[length] of bytes : UTF-8 string content
var i, j, k, l, m, numnumerics, numstrings, memused : dword;
begin
 // Calculate the memory needed.
 numnumerics := 0; numstrings := 0;
 memused := 20; // header: 5 dwords
 i := bucketcount;
 while i <> 0 do begin
  dec(i);
  j := bucket[i].bucketsize;
  while j <> 0 do begin
   dec(j);
   k := bucket[i].content[j].varnum;
   if bucket[i].content[j].vartype = VARMON_VARTYPEINT then begin
    // numeric variable!
    inc(memused, 7 + dword(length(bucket[i].content[j].namu)));
    inc(numnumerics);
   end else begin
    // string variable!
    m := 0;
    for l := numlanguages - 1 downto 0 do
     inc(m, dword(length(strvar[k].txt[l])));
    inc(memused, 3 + dword(length(bucket[i].content[j].namu)) + 4 * numlanguages + m);
    inc(numstrings);
   end;
  end;
 end;

 // Reserve the memory... caller is responsible for freeing it.
 getmem(poku, memused);

 // Write the header.
 dword((poku + 0)^) := memused;
 i := bucketcount;
 if addbucketsautomatically then i := i or $80000000;
 dword((poku + 4)^) := i;
 dword((poku + 8)^) := numnumerics;
 dword((poku + 12)^) := numstrings;
 dword((poku + 16)^) := numlanguages;
 memused := 20;

 // Iterate through buckets, saving all variables.
 i := bucketcount;
 while i <> 0 do begin
  dec(i);
  j := bucket[i].bucketsize;
  while j <> 0 do begin
   dec(j);

   // Save a description of the variable.
   byte((poku + memused)^) := bucket[i].content[j].vartype; inc(memused);
   byte((poku + memused)^) := bucket[i].content[j].special; inc(memused);
   move(bucket[i].content[j].namu[0], (poku + memused)^, length(bucket[i].content[j].namu) + 1);
   inc(memused, dword(length(bucket[i].content[j].namu)) + 1);

   k := bucket[i].content[j].varnum;
   if bucket[i].content[j].vartype = VARMON_VARTYPEINT then begin
    // numeric variable!
    longint((poku + memused)^) := numvar[k];
    inc(memused, 4);
   end else begin
    // string variable!
    for l := 0 to numlanguages - 1 do begin
     dword((poku + memused)^) := length(strvar[k].txt[l]);
     inc(memused, 4);
     move(strvar[k].txt[l][1], (poku + memused)^, length(strvar[k].txt[l]));
     inc(memused, dword(length(strvar[k].txt[l])));
    end;
   end;

  end;
 end;
end;

function GetVarType(const varnamu : string) : byte;
// Returns the variable type, VARMON_VARTYPE*.
var i : dword;
begin
 GetVarType := VARMON_VARTYPENULL;
 i := FindVar(upcase(varnamu));
 if i >= $80000000 then exit; // variable doesn't exist
 GetVarType := bucket[i].content[bucket[i].toplink].vartype;
end;

procedure SetNumVar(const varnamu : string; num : longint; sudo : boolean);
// Assigns the given number to the variable by the given name.
// If the variable is write-protected, throws an exception. Unless sudo is
// true, then writes regardless of protection.
var i, j : dword;
begin
 i := AddVar(upcase(varnamu), 1, sudo);
 j := bucket[i].toplink;
 if (bucket[i].content[j].special <> 0) // write-protected
 and (sudo = FALSE) then
  raise Exception.create('Variable ' + varnamu + ' is write-protected');

 numvar[bucket[i].content[j].varnum] := num;
end;

function GetNumVar(const varnamu : string) : longint;
// Returns the value of the given variable, or 0 if that doesn't exist.
// If the requested variable is a string, also returns 0. If a string
// contains a valid number, it must be converted explicitly by script code.
var i, j : dword;
begin
 GetNumVar := 0;
 i := FindVar(upcase(varnamu));
 if i >= $80000000 then exit; // variable doesn't exist
 j := bucket[i].toplink;
 if bucket[i].content[j].vartype <> VARMON_VARTYPEINT then exit;
 GetNumVar := numvar[bucket[i].content[j].varnum];
end;

procedure SetStrVar(const varnamu : string; sudo : boolean);
// Assigns the contents of the string stash to the given string variable.
// If the variable is write-protected, throws an exception. Unless sudo is
// true, then writes regardless of protection.
var i, j, l : dword;
begin
 i := AddVar(upcase(varnamu), 2, sudo);
 j := bucket[i].toplink;
 if (bucket[i].content[j].special <> 0) // write-protected
 and (sudo = FALSE) then
  raise Exception.create('Variable ' + varnamu + ' is write-protected');

 setlength(strvar[bucket[i].content[j].varnum].txt, numlanguages);
 for l := 0 to numlanguages - 1 do
  strvar[bucket[i].content[j].varnum].txt[l] := stringstash[l];
end;

procedure GetStrVar(const varnamu : string);
// Fetches the given string variables and places a copy of them in the
// string stash. If the given variable doesn't exist, places empty strings.
// If the requested variable is a number, returns a string representation.
var i, j, l : dword;
begin
 i := FindVar(upcase(varnamu));
 if i >= $80000000 then begin
  // variable doesn't exist
  for j := numlanguages - 1 downto 0 do stringstash[j] := '';
  exit;
 end;
 j := bucket[i].toplink;
 if bucket[i].content[j].vartype = VARMON_VARTYPEINT then begin
  // numeric variable, convert to string
  i := bucket[i].content[j].varnum;
  stringstash[0] := strdec(numvar[i]);
  j := numlanguages - 1;
  while j > 0 do begin
   stringstash[j] := stringstash[0];
   dec(j);
  end;
  exit;
 end;

 for l := 0 to numlanguages - 1 do
  stringstash[l] := strvar[bucket[i].content[j].varnum].txt[l];
end;

procedure SetNumBuckets(const newbuckets : dword);
// Saves the current variables, re-inits with the new bucket count, then
// loads the variables into the new buckets. Scripts can set the number of
// buckets to accommodate their expected variable use. If a script uses a lot
// of variables, a larger number of buckets will be faster. If a script uses
// few variables, a small number of buckets keeps the memory overhead low.
var poku : pointer;
begin
 if newbuckets = bucketcount then exit;
 if (newbuckets = 0) or (newbuckets > VARMON_MAXBUCKETS) then
  raise Exception.create('Bad new bucketcount, must be 1..' + strdec(VARMON_MAXBUCKETS));
 poku := NIL;
 SaveVarState(poku);
 dword((poku + 4)^) := newbuckets; // poke bucketcount in saved structure
 LoadVarState(poku);
 freemem(poku); poku := NIL;
 // Manually setting the number of buckets disables automatic bucket adding.
 addbucketsautomatically := FALSE;
end;

function CountNumVars : dword;
begin
 CountNumVars := numvarcount;
end;

function CountStrVars : dword;
begin
 CountStrVars := strvarcount;
end;

function CountBuckets : dword;
begin
 CountBuckets := bucketcount;
end;

procedure VarmonInit(numlang, numbuckets : dword);
// Initialises everything, needs the number of languages being used and the
// preferred number of variable buckets. The number of languages is known at
// game mod load and should not change. The number of buckets may be changed
// at runtime using SetNumBuckets.
var i : dword;
begin
 // safeties
 if numlang = 0 then numlang := 1;
 if numlang > VARMON_MAXLANGUAGES then raise Exception.create('Tried to init with ' + strdec(numlang) + ' languages, max ' + strdec(VARMON_MAXLANGUAGES));
 if numbuckets = 0 then numbuckets := 1;
 if numbuckets > VARMON_MAXBUCKETS then numbuckets := VARMON_MAXBUCKETS;
 // inits
 bucketcount := numbuckets;
 numlanguages := numlang;
 setlength(bucket, 0);
 setlength(bucket, numbuckets);
 for i := numbuckets - 1 downto 0 do with bucket[i] do begin
  bucketsize := 0;
  setlength(content, 0);
 end;
 setlength(stringstash, numlang);

 numvarcount := 0; strvarcount := 0; danglies := 0;
 setlength(numvar, 0);
 setlength(strvar, 0);
 addbucketsautomatically := TRUE;
end;

// ------------------------------------------------------------------
initialization
 VarmonInit(1, 1);

// ------------------------------------------------------------------
finalization
 {$ifdef debugdump}DumpVarTable;{$endif}
end.
