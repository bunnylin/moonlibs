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
interface

uses mccommon;

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
const VARMON_MAXLANGUAGES = 999;
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
        vartype : byte; // 1 = num, 2 = str
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
var bvar, cont : dword;
begin
 for bvar := 0 to bucketcount - 1 do begin
  if bucket[bvar].bucketsize <> 0 then
  for cont := 0 to bucket[bvar].bucketsize - 1 do
  with bucket[bvar].content[cont] do begin
   write('$',namu,chr(9),'bucket=',bvar,':',cont);
   if cont = bucket[bvar].toplink then write('*');
   write(chr(9),'prev=',prevlink,chr(9),'next=',nextlink,chr(9),'type=',vartype,chr(9),'spec=',special,chr(9));
   if vartype = 1 then write(numvar[varnum]) else
   if vartype = 2 then write(strvar[varnum].txt[0]);
   writeln;
  end;
 end;
end;
{$endif}

function HashString(const varnamu : string) : dword;
// Returns the bucket number that this variable name belongs to.
var ivar : dword;
    strlen : byte;
begin
 HashString := 0;
 strlen := length(varnamu);
 ivar := 1;
 while ivar + 3 <= strlen do begin
  HashString := RORdword(HashString, 13);
  HashString := HashString xor dword((@varnamu[ivar])^);
  inc(ivar, 4);
 end;
 while ivar <= strlen do begin
  HashString := RORdword(HashString, 3);
  HashString := HashString xor byte(varnamu[ivar]);
  inc(ivar);
 end;
 HashString := HashString mod bucketcount;
end;

function FindVar(const varnamu : string) : dword;
// Checks if the given variable name exists in the variable buckets. If it
// does, the variable is moved to the top of its bucket, and FindVar returns
// the bucket's number. If the variable doesn't exist, returns the bucket's
// number OR $8000 0000 so the caller can add it to the bucket if desired.
var ivar, jvar : dword;
begin
 FindVar := HashString(varnamu);
 ivar := bucket[FindVar].bucketsize;

 if ivar = 0 then begin
  // empty bucket! this variable name doesn't exist yet
  FindVar := FindVar or $80000000;
  exit;
 end;

 jvar := bucket[FindVar].toplink;
 while ivar <> 0 do with bucket[FindVar] do begin
  if content[jvar].namu = varnamu then begin
   // found a match!
   // move the matched variable name to the top, if not already at the top
   if toplink <> jvar then begin
    if ivar <> 1 then begin
     // detach from current link position, if not at very bottom
     content[content[jvar].prevlink].nextlink := content[jvar].nextlink;
     content[content[jvar].nextlink].prevlink := content[jvar].prevlink;
    end;
    // prepare own link
    content[jvar].nextlink := toplink;
    // attach at top link position
    content[toplink].prevlink := jvar;
    toplink := jvar;
   end;
   exit; // return the bucket number
  end;
  jvar := content[jvar].nextlink;
  dec(ivar);
 end;

 // no match found in bucket, this variable name doesn't exist yet
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
 AddVar := FindVar(varnamu);
 if AddVar < $80000000 then begin
  // this variable already exists...
  with bucket[AddVar].content[bucket[AddVar].toplink] do begin
   // check if it's write-protected and can't be changed
   if sudo = FALSE then begin
    if special and 1 <> 0 then exit;
    special := 0;
   end
   else special := 1;
   // if the variable type is changed, must set up a new variable slot
   // (the old slot is left dangling...)
   if vartype <> typenum then begin
    if typenum = 1 then varnum := NewNumVar else varnum := NewStrVar;
    vartype := typenum;
    inc(danglies);
    if danglies > 1000 then begin
     // too many dangling, reshuffle all variables, may take a moment...
     // this only happens if a script keeps switching same named variables
     // between number and string types, which you shouldn't be doing anyway
     poku := NIL;
     SaveVarState(poku);
     LoadVarState(poku); // loadstate sets danglies to 0
     freemem(poku); poku := NIL;
    end;
   end;
  end;
  exit;
 end;

 // this variable doesn't exist...
 AddVar := AddVar and $7FFFFFFF; // clear top bit

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
   if typenum = 1 then varnum := NewNumVar else varnum := NewStrVar;
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
var ivar, jvar, kvar, lvar, mvar, ofsu : dword;
    memused, numnumerics, numstrings, savedlanguages : dword;
begin
 // safeties, read the header
 if poku = NIL then exit;
 memused := dword(poku^);
 if memused < 20 then exit;
 ivar := dword((poku + 4)^);
 numnumerics := dword((poku + 8)^);
 numstrings := dword((poku + 12)^);
 savedlanguages := dword((poku + 16)^);
 if (ivar = 0) or (savedlanguages = 0) then exit;
 bucketcount := ivar;
 ofsu := 20;

 // clear and re-init everything
 VarmonInit(numlanguages, bucketcount);
 setlength(numvar, numnumerics + 8);
 setlength(strvar, numstrings + 8);
 for ivar := length(strvar) - 1 downto 0 do
  setlength(strvar[ivar].txt, numlanguages);

 // read the variables into memory
 while ofsu + 4 < memused do begin
  lvar := byte((poku + ofsu)^); inc(ofsu); // variable type
  mvar := byte((poku + ofsu)^); inc(ofsu); // specialness
  kvar := AddVar(string((poku + ofsu)^), lvar, mvar <> 0);
  inc(ofsu, byte((poku + ofsu)^) + byte(1));
  jvar := bucket[kvar].content[bucket[kvar].toplink].varnum;
  if lvar = 0 then begin
   // numeric variable!
   numvar[jvar] := longint((poku + ofsu)^);
   inc(ofsu, 4);
  end else begin
   // string variable!
   ivar := 0;
   repeat
    // numlanguages and savedlanguages are hopefully equal, but if not,
    // there are four options for each language index...
    if ivar < numlanguages then begin
     if ivar < savedlanguages then begin
      // slot is within loaded languages and within languages in snapshot:
      // copy snapshot language string normally
      setlength(stringstash[ivar], dword((poku + ofsu)^)); inc(ofsu, 4);
      move((poku + ofsu)^, stringstash[ivar][1], length(stringstash[ivar]));
      inc(ofsu, dword(length(stringstash[ivar])));
     end else begin
      // slot is within loaded languages but beyond languages in snapshot:
      // copy language 0 string
      stringstash[ivar] := stringstash[0];
     end;
    end else begin
     if ivar < savedlanguages then begin
      // slot is beyond loaded languages but within languages in snapshot:
      // this language string must be dropped, there's nowhere to put it
      inc(ofsu, dword((poku + ofsu)^) + 4);
     end else begin
      // slot is beyond loaded languages and beyond languages in snapshot:
      // that means we're done with this string set!
      break;
     end;
    end;

    inc(ivar);
   until FALSE;
   setlength(strvar[jvar].txt, numlanguages);
   for ivar := 0 to numlanguages - 1 do
    strvar[jvar].txt[ivar] := stringstash[ivar];
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
//   array[numnumerics + numstrings] of :
//     byte : variable type
//     byte : specialness value
//     ministring : variable name
//     if numeric then longint : variable value
//     if string then array[numlanguages] of :
//       dword : UTF-8 string byte length
//       array[length] of bytes : UTF-8 string content
var ivar, jvar, kvar, lvar, mvar, numnumerics, numstrings, memused : dword;
begin
 // Calculate the memory needed
 numnumerics := 0; numstrings := 0;
 memused := 20; // header: 5 dwords
 ivar := bucketcount;
 while ivar <> 0 do begin
  dec(ivar);
  jvar := bucket[ivar].bucketsize;
  while jvar <> 0 do begin
   dec(jvar);
   kvar := bucket[ivar].content[jvar].varnum;
   if bucket[ivar].content[jvar].vartype = 1 then begin // numeric variable!
    inc(memused, 7 + dword(length(bucket[ivar].content[jvar].namu)));
    inc(numnumerics);
   end else begin // string variable!
    mvar := 0;
    for lvar := numlanguages - 1 downto 0 do
     inc(mvar, dword(length(strvar[kvar].txt[lvar])));
    inc(memused, 3 + dword(length(bucket[ivar].content[jvar].namu)) + 4 * numlanguages + mvar);
    inc(numstrings);
   end;
  end;
 end;

 // Reserve the memory... caller is responsible for freeing it
 getmem(poku, memused);

 // Write the header
 dword((poku + 0)^) := memused;
 dword((poku + 4)^) := bucketcount;
 dword((poku + 8)^) := numnumerics;
 dword((poku + 12)^) := numstrings;
 dword((poku + 16)^) := numlanguages;
 memused := 20;

 // Iterate through buckets, saving all variables
 ivar := bucketcount;
 while ivar <> 0 do begin
  dec(ivar);
  jvar := bucket[ivar].bucketsize;
  while jvar <> 0 do begin
   dec(jvar);

   // save common variable description
   byte((poku + memused)^) := bucket[ivar].content[jvar].vartype; inc(memused);
   byte((poku + memused)^) := bucket[ivar].content[jvar].special; inc(memused);
   move(bucket[ivar].content[jvar].namu[0], (poku + memused)^, length(bucket[ivar].content[jvar].namu) + 1);
   inc(memused, dword(length(bucket[ivar].content[jvar].namu)) + 1);

   kvar := bucket[ivar].content[jvar].varnum;
   if bucket[ivar].content[jvar].vartype = 1 then begin
    // numeric variable!
    longint((poku + memused)^) := numvar[kvar];
   end else begin
    // string variable!
    for lvar := 0 to numlanguages - 1 do begin
     dword((poku + memused)^) := length(strvar[kvar].txt[lvar]);
     inc(memused, 4);
     move(strvar[kvar].txt[lvar][1], (poku + memused)^, length(strvar[kvar].txt[lvar]));
     inc(memused, dword(length(strvar[kvar].txt[lvar])));
    end;
   end;

  end;
 end;
end;

function GetVarType(const varnamu : string) : byte;
// Returns the variable type: 0 = doesn't exist, 1 = number, 2 = string
var ivar : dword;
begin
 GetVarType := 0;
 ivar := FindVar(upcase(varnamu));
 if ivar >= $80000000 then exit; // variable doesn't exist
 GetVarType := bucket[ivar].content[bucket[ivar].toplink].vartype;
end;

procedure SetNumVar(const varnamu : string; num : longint; sudo : boolean);
// Assigns the given number to the variable by the given name.
// If the variable is write-protected, fails silently. :p Unless sudo is
// true, then writes regardless of protection.
var ivar, jvar : dword;
begin
 ivar := AddVar(upcase(varnamu), 1, sudo);
 jvar := bucket[ivar].toplink;
 if (bucket[ivar].content[jvar].special <> 0) // write-protected
 and (sudo = FALSE)
 then exit;
 numvar[bucket[ivar].content[jvar].varnum] := num;
end;

function GetNumVar(const varnamu : string) : longint;
// Returns the value of the given variable, or 0 if that doesn't exist.
// If the requested variable is a string, also returns 0. If a string
// contains a valid number, it must be converted explicitly by script code.
var ivar, jvar : dword;
begin
 GetNumVar := 0;
 ivar := FindVar(upcase(varnamu));
 if ivar >= $80000000 then exit; // variable doesn't exist
 jvar := bucket[ivar].toplink;
 if bucket[ivar].content[jvar].vartype <> 1 then exit; // string variable
 GetNumVar := numvar[bucket[ivar].content[jvar].varnum];
end;

procedure SetStrVar(const varnamu : string; sudo : boolean);
// Assigns the contents of the string stash to the given string variable.
// If the variable is write-protected, fails silently. :p Unless sudo is
// true, then writes regardless of protection.
var ivar, jvar, lvar : dword;
begin
 ivar := AddVar(upcase(varnamu), 2, sudo);
 jvar := bucket[ivar].toplink;
 if (bucket[ivar].content[jvar].special <> 0) // write-protected
 and (sudo = FALSE)
 then exit;
 setlength(strvar[bucket[ivar].content[jvar].varnum].txt, numlanguages);
 for lvar := 0 to numlanguages - 1 do
  strvar[bucket[ivar].content[jvar].varnum].txt[lvar] := stringstash[lvar];
end;

procedure GetStrVar(const varnamu : string);
// Fetches the given string variables and places a copy of them in the
// string stash. If the given variable doesn't exist, places empty strings.
// If the requested variable is a number, returns a string representation.
var ivar, jvar, lvar : dword;
begin
 ivar := FindVar(upcase(varnamu));
 if ivar >= $80000000 then begin
  // variable doesn't exist
  for jvar := numlanguages - 1 downto 0 do stringstash[jvar] := '';
  exit;
 end;
 jvar := bucket[ivar].toplink;
 if bucket[ivar].content[jvar].vartype = 1 then begin
  // numeric variable, convert to string
  ivar := bucket[ivar].content[jvar].varnum;
  stringstash[0] := strdec(numvar[ivar]);
  jvar := numlanguages - 1;
  while jvar > 0 do begin
   stringstash[jvar] := stringstash[0];
   dec(jvar);
  end;
  exit;
 end;

 for lvar := 0 to numlanguages - 1 do
  stringstash[lvar] := strvar[bucket[ivar].content[jvar].varnum].txt[lvar];
end;

procedure SetNumBuckets(const newbuckets : dword);
// Saves the current variables, re-inits with the new bucket count, then
// loads the variables into the new buckets. Scripts can set the number of
// buckets to accommodate their expected variable use. If a script uses a lot
// of variables, a larger number of buckets will be faster. If a script uses
// few variables, a small number of buckets keeps the memory overhead low.
var poku : pointer;
begin
 if (newbuckets = 0) or (newbuckets = bucketcount)
 or (newbuckets > VARMON_MAXBUCKETS) then exit;
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
var ivar : dword;
begin
 // safeties
 if numlang = 0 then numlang := 1;
 if numlang > VARMON_MAXLANGUAGES then numlang := VARMON_MAXLANGUAGES;
 if numbuckets = 0 then numbuckets := 1;
 if numbuckets > VARMON_MAXBUCKETS then numbuckets := VARMON_MAXBUCKETS;
 // inits
 bucketcount := numbuckets;
 numlanguages := numlang;
 setlength(bucket, 0);
 setlength(bucket, numbuckets);
 for ivar := numbuckets - 1 downto 0 do with bucket[ivar] do begin
  bucketsize := 0;
  setlength(content, 0);
 end;
 setlength(stringstash, numlang);
end;

// ------------------------------------------------------------------
initialization
 numvarcount := 0; strvarcount := 0; danglies := 0;
 setlength(numvar, 0);
 setlength(strvar, 0);
 addbucketsautomatically := TRUE;

// ------------------------------------------------------------------
finalization
 {$ifdef debugdump}DumpVarTable;{$endif}
end.
