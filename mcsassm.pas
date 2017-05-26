unit mcsassm;
{                                                                           }
{ Mooncore Super Asset Manager                                              }
{ Copyright 2013-2017 :: Kirinn Bunnylin / MoonCore                         }
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

// This loads assets from DAT files.
// Also included is a background thread that should be used to load and make
// available any graphic assets or wave audio.
//
// To use, you need to define all resource types here in the unit. The cacher
// thread is launched automatically whenever GetGFX/CacheGFX is called, or
// you can launch it manually with asman_beginthread. The unit cleans up the
// thread and all loaded assets when your main program ends or crashes.
//
// You need to call LoadDAT to select the data files to use. Call the Get*
// functions to pull individual assets as you need them.

// For thread safety, your main program must observe these rules:
// - You do NOT have write access to gfxlist[], unless the cacher thread has
//   been stopped first. Try to use only the functions defined in the mcsassm
//   interface to modify gfxlist[].
// - You do NOT have read access to gfxlist[], unless you first mark the
//   slots you want to access by calling GetGFX. Afterward, you have to
//   eventually release the slots by calling ReleaseGFX.
// - Note that each GetGFX call may cause an implicit purge which may cause
//   a gfxlist[] resize. Item indexes remain valid, but if you have memory
//   pointers to gfxlist[] elements, they may become invalid, except the
//   gfxlist[].bitmap pointer which should remain valid.
//   Please refer to gfxlist[] by index rather than by pointer. If you must
//   use pointers at gfxlist[] elements, only store the pointers after your
//   last GetGFX call.
// - You can get most image metadata from PNGlist[], which you can read at
//   any time. The cacher thread does not modify PNGlist[]. The thread is
//   paused automatically during a LoadDAT call.
//
// - Your renderer should do this every frame:
//    + Decide which graphics you want to draw, call GetGFX for each
//    + Draw the graphics using the gfxlist[] bitmaps
// - Additionally, call ReleaseGFX periodically so the cacher has some idea
//   about which graphics haven't been used for a while. You should do this
//   whenever the visible set of graphics has changed significantly.

// If your program goes through a fullscreen or other window size switch, you
// probably need all graphics to be resized to the new window. To do this,
// call CancelCacheGFX, then ReleaseGFX. Then just get your renderer to start
// requesting the assets at their new sizes.

{$mode fpc}
{$inline on}
{$WARN 4079 off} // Spurious hints: Converting the operands to "Int64" before
{$WARN 4080 off} // doing the operation could prevent overflow errors.
{$WARN 4081 off}

interface

uses mcgloder,
     mccommon,
     {$ifdef unix}cthreads,{$endif}
     paszlib;

type // Resource types

     // SCRIPT/LABEL
     // init: only a null entry, length 1
     // grow + write: during LoadDAT or at main thread's responsibility
     // sorting: mandatory full sort by labelnamu after any change
     // shrink + remove: forbidden unless resetting game state, in which case
     //   the array is emptied and you must repopulate it using LoadDATs
     scripttype = record
       labelnamu : string[63]; // label string for this bytecode segment
       nextlabel : string[63];
       code : pointer;
       codesize : dword; // byte size of the bytecode
       stringlist : array of record // one for each language
         txt : array of UTF8string;
       end;
     end;

     // GRAPHICS
     // Dynamic list of all loaded graphics
     // init: only a null entry, length 1
     // write: main.CacheGFX sets up slots, cacher.LoadGFX writes into them;
     //   if cachestate is 1 or 2, cacher has write privilege, otherwise main
     // grow: by main.LoadDAT and main.CacheGFX, must stop cacher first
     // sorting: items may not be moved within the array, but they are sorted
     //   as a linked list from newest to oldest; only main may sort
     // remove: cached assets can be removed only by main.CacheGFX or
     //   main.UnloadDATs; assets pending caching can be removed by cacher
     // shrink: only by main.UnloadDATs

     gfxtype = record
       bitmap : pointer;
       namu : UTF8string;
       newerlink, olderlink : dword;
       ofsxp, ofsyp : longint;
       sizexp, sizeyp : word;
       frameheightp : word;

       cachestate : byte;
       // 0 - Empty slot, unloading unnecessary
       // 1 - Being cached (alpha), don't mess with it
       // 2 - Being cached (beta), don't mess with it
       // 3 - Caching complete, unloading allowed

       bitflag : byte; // 128 - if set, 32-bit RGBA, else 32-bit RGBx
       sacred : boolean;
     end;

     // Const list of all PNGs in DAT, original size, must be always sorted
     PNGtype = record
       // metadata from image header
       namu : UTF8string;
       origresx, origresy : word;
       origsizexp, origsizeyp : word;
       origsizex, origsizey : dword; // 32k size relative to original res
       origofsxp, origofsyp : longint; // pixel offset in original res
       origofsx, origofsy : longint; // 32k values relative to original res
       framecount : dword;
       seqlen : dword; // animation sequence length
       sequence : array of dword; // 16.16: action/frame . param/delay
       bitflag : byte; // 128 - if set, 32-bit RGBA, else 32-bit RGBx
       srcfilename : UTF8string; // DAT or PNG file to read the PNG from
       srcfileofs, srcfilesizu : dword;
       origframeheightp : word;
     end;

     DATtype = record
       filenamu : UTF8string;
       bannerofs : dword;
       projectname : UTF8string;
       parentname : UTF8string;
       projectdesc : UTF8string;
       gameversion : UTF8string;
     end;

type pscripttype = ^scripttype;
     pgfxtype = ^gfxtype;
     pPNGtype = ^PNGtype;

var // Game resources
    DATlist : array of DATtype;
    PNGlist : array of PNGtype;
    gfxlist : array of gfxtype;
    script : array of scripttype;
    languagelist : array of UTF8string; // list of language descriptors

    // Baseresxy is the preferred game window size as defined in the last
    // DAT that's been loaded. SuperSakura uses the largest 0.5x multiplier
    // of this size that can fit on the user's screen as its default window.
    // In fullscreen mode, this is ignored in favor of the user's native
    // desktop resolution.
    asman_baseresx, asman_baseresy : longint;

    // LoadGFX increases the memcount, asman_purgegfx decreases, UnloadDATs
    // resets to zero. Use interlockedexchangeadd!
    asman_gfxmemlimit : longint; // Soft limit for graphics cache, in bytes
    asman_gfxmemcount : longint; // current memory used

    // To easily switch between rescalers, use this. Default is fastest.
    // The rescalers are in the mcgloder unit.
    asman_rescaler : procedure(poku : pbitmaptype; tox, toy : word);

    asman_quitmsg : dword; // set to non-zero to request thread to quit
    asman_errormsg : string; // read errors from this
    asman_log : array of UTF8string;
    asman_logindex : byte;

function GetScr(const nam : UTF8string) : dword;
function GetPNG(const nam : UTF8string) : dword;
function CacheGFX(const nam : UTF8string; rqsizex, rqsizey : word; sacrflag : boolean) : dword;
procedure CancelCacheGFX;
function GetGFX(const nam : UTF8string; rqsizex, rqsizey : word) : dword;
procedure ReleaseGFX;
function ValidateIdentifier(const src : UTF8string; ofs, len : dword) : boolean;
procedure SortScripts(onlylast : boolean);
function ImportStringTable(const tablefile : UTF8string) : boolean;
function DumpStringTable(const tablefile : UTF8string) : boolean;
function CompressScripts(poku : ppointer) : dword;
function CompressStringTable(poku : ppointer; langindex : dword) : dword;
function DecompressScripts(poku : pointer; blocksize : dword) : boolean;
function DecompressStringTable(poku : pointer; blocksize : dword) : boolean;
function ReadDATHeader(var dest : DATtype; var filu : file) : byte;
function LoadDAT(const filunamu : UTF8string) : byte;
procedure UnloadDATs;

function asman_isthreadalive : boolean;
procedure asman_beginthread; // called automatically on unit load
procedure asman_endthread; // called automatically on unit exit

// ------------------------------------------------------------------
implementation

{$I-}

var asman_threadhandle : TThreadID; // used to close the thread at exit
    asman_threadID : TThreadID; // used for most thread-affecting actions
    asman_event : PRTLEvent; // used to tell the thread to start doing stuff
    asman_jobdone : PRTLEvent; // thread sets this when primeslot job done
    asman_threadendevent : PRTLEvent; // thread sets this when exiting
    asman_gfxwriteslot : dword; // rotating index to gfxlist[]

    // Whenever you set any item's cachestate to 1 or 2, increment this;
    // whenever it changes from 1 or 2 to anything not 1 or 2, decrement.
    // (use interlockedinc/dec to be safe)
    asman_queueitems : longint;
    // The cacher will always look at this slot first when deciding what to
    // load next. Set to 0 when override is not needed.
    asman_primeslot : dword;
    // The cachemark is either 1 or 2. Any graphic whose cache state is the
    // same as the cachemark needs to be loaded by the cacher. To cancel all
    // pending cache requests, CancelCacheGFX flips the cachemark to the
    // other possible value.
    asman_cachemark : byte;
    asman_threadalive : boolean;

function asman_thread(turhuus : pointer) : ptrint; forward;

procedure writelog(const logln : UTF8string);
// Use this to write out any debug info. It uses a circular buffer.
// Ideally there'd be a small msec timestamp and "asman." with every string
// printed into the log, but a good cross-platform timer is needed first.
begin
 asman_logindex := (asman_logindex + 1) mod length(asman_log);
 asman_log[asman_logindex] := logln;
 //writeln('>>',logln);
end;

procedure asman_pokethread; inline;
// Signals the asman_thread that there's work available. If the thread has
// finished all its work, it'll go into a waitstate and will not do anything
// until roused by a poke.
// GetGFX automatically calls CacheGFX, which automatically pokes as needed.
begin
 RTLEventSetEvent(asman_event);
end;

function asman_isthreadalive : boolean;
// Read-only public getter for thread liveness.
begin
 asman_isthreadalive := asman_threadalive;
end;

procedure asman_beginthread;
// Launch the asset manager thread, don't care about the input argument
// pointer, and try a stack size of 256k.
// The thread ID is stored in the asman_ThreadID variable, and can be used
// for most thread-affecting actions.
// The asman_threadhandle is used solely to close the thread at exit.
begin
 if asman_threadalive then begin
  writelog('[!] beginthread: already alive');
  exit;
 end;
 writelog('Launching asmanthread');
 asman_quitmsg := 0;
 asman_event := RTLEventCreate;
 asman_jobdone := RTLEventCreate;
 asman_threadendevent := RTLEventCreate;
 asman_threadhandle := BeginThread(@asman_thread, NIL, asman_ThreadID, 262144);
 asman_threadalive := TRUE;
end;

procedure asman_endthread;
begin
 if asman_threadalive = FALSE then exit;
 writelog('Ending asmanthread, id=' + strdec(asman_ThreadID));
 asman_quitmsg := 1; // order to shut down
 if asman_ThreadID <> 0 then begin
  asman_pokethread; // wake up! do stuff!
  // Normally this would be a good spot for WaitForThreadTerminate, but that
  // appears to sometimes (on win32 at least) return even while the thread is
  // still live. Waiting for an explicit event works as expected.
  RTLEventWaitFor(asman_threadendevent, 5000);
  KillThread(asman_ThreadID);
  CloseThread(asman_ThreadHandle); // trying to avoid handle leaking
 end;
 asman_ThreadID := 0;
 RTLEventDestroy(asman_event);
 RTLEventDestroy(asman_jobdone);
 RTLEventDestroy(asman_threadendevent);
 asman_threadalive := FALSE;
 writelog('Ended asmanthread');
end;

function seekgfx(const nam : UTF8string; rqsizex, rqsizey : word) : dword;
// Scans through gfxlist and returns the gfxlist index of the first item
// matching the given name and size, that's not void or about to become void.
// If no match is found, returns 0.
// The search is case-sensitive, but graphic names shall be in uppercase.
// The pixel height is the frame height rather than the full bitmap height.
// (Otherwise frames would bleed in each other.)
//
// gfxlist[] is sorted from most to least recently used via a linked list,
// to make it easy to find the newest and oldest graphics.
begin
 seekgfx := gfxlist[0].olderlink; // newest
 while seekgfx <> 0 do with gfxlist[seekgfx] do begin
  if (cachestate = 3) or (cachestate = asman_cachemark) then
  if (namu = nam) and (sizexp = rqsizex) and (frameheightp = rqsizey) then exit;
  seekgfx := olderlink; // otherwise move to the next index
 end;
 // If the while-loop ends, no match was found and seekgfx = 0.
end;

procedure setmostrecent(listindex : dword);
// Sorts gfxlist[listindex] as the most recently accessed link.
begin
 with gfxlist[listindex] do begin
  // detach
  gfxlist[newerlink].olderlink := olderlink;
  gfxlist[olderlink].newerlink := newerlink;
  // reattach
  olderlink := gfxlist[0].olderlink;
  newerlink := 0;
  gfxlist[0].olderlink := listindex;
  gfxlist[olderlink].newerlink := listindex;
 end;
end;

procedure asman_purgegfx(listindex : dword);
// Releases a cached gfxlist[] slot. It is detached from the recency chain,
// set to state-0 (free), and the gfx memory total is updated.
begin
 if (listindex = 0) or (listindex >= dword(length(gfxlist))) then begin
  writelog('[!] purgegfx: invalid index ' + strdec(listindex) + '/' + strdec(dword(length(gfxlist))));
  exit;
 end;
 if gfxlist[listindex].cachestate <> 3 then begin
  writelog('[!] purgegfx: gfxlist[' + strdec(listindex) + '] not in state 3');
  exit;
 end;
 if gfxlist[listindex].sacred then begin
  writelog('[!] purgegfx: gfxlist[' + strdec(listindex) + '] is sacred');
  exit;
 end;

 with gfxlist[listindex] do begin
  if bitmap <> NIL then begin
   freemem(bitmap); bitmap := NIL;
  end;
  gfxlist[newerlink].olderlink := olderlink;
  gfxlist[olderlink].newerlink := newerlink;
  interlockedexchangeadd(asman_gfxmemcount, -(sizexp * sizeyp * 4));
  namu := '';
  cachestate := 0; sacred := FALSE;
 end;
end;

function GetScr(const nam : UTF8string) : dword;
// Looks through script[] and returns the script[] -index of an item with the
// given name. If the script is not in the list, returns 0.
// The search is case-sensitive, but all script names shall be in uppercase.
// The script[] array must be sorted before calling this.
var ivar, min, max : longint;
begin
 if (nam = '') or (high(script) = 0) then begin GetScr := 0; exit; end;
 // binary search
 min := 1; max := high(script);
 repeat
  GetScr := (min + max) shr 1;
  ivar := CompStr(@nam[1], @script[GetScr].labelnamu[1], length(nam), length(script[GetScr].labelnamu));
  if ivar = 0 then exit;
  if ivar > 0 then min := GetScr + 1 else max := GetScr - 1;
 until min > max;
 GetScr := 0;
end;

function GetPNG(const nam : UTF8string) : dword;
// Looks through PNGlist and returns the PNGlist[] -index of an item with
// the given name. If the graphic is not in the list, returns 0.
// The search is case-sensitive, but all PNGlist items shall be in uppercase.
// PNGlist[] is a mostly constant list that must be sorted before calling.
// For each image, the list contains some metadata and a reference to a DAT
// file that holds the compressed PNG stream.
var ivar, min, max : longint;
begin
 if (nam = '') or (high(PNGlist) = 0) then begin GetPNG := 0; exit; end;
 // binary search
 min := 1; max := high(PNGlist);
 repeat
  GetPNG := (min + max) shr 1;
  ivar := CompStr(@nam[1], @PNGlist[GetPNG].namu[1], length(nam), length(PNGlist[GetPNG].namu));
  if ivar = 0 then exit;
  if ivar > 0 then min := GetPNG + 1 else max := GetPNG - 1;
 until min > max;
 GetPNG := 0;
end;

function CacheGFX(const nam : UTF8string; rqsizex, rqsizey : word; sacrflag : boolean) : dword;
// Prepares a gfxlist[] slot for the requested graphic, and returns the slot
// index. If no such PNG exists, returns 0. Also sets up a slot for loading
// the original-size image, if necessary.
// The requested height here is the frame height, not the full bitmap height.
// When the cacher thread notices a prepared slot, it will load the PNG from
// disk or grab the existing original size copy, and saves the resized bitmap
// in the prepared gfxlist[] slot.
// If sacrflag is set, the slot is immediately marked as sacred so even after
// it is loaded, it absolutely cannot be freed until ReleaseGFX is called.
var ivar : dword;

  function ListThis(listsizex, listsizey : dword) : dword;
  begin
   // Find a state-0 (free) gfxlist[] slot.
   if asman_gfxwriteslot = 0 then inc(asman_gfxwriteslot);
   ListThis := asman_gfxwriteslot;
   repeat
    inc(ListThis);
    if ListThis >= dword(length(gfxlist)) then ListThis := 1;
    if ListThis = asman_gfxwriteslot then begin
     // we went all the way around the array, and no state-0's?
     // in that case, find the oldest state-3 and release it!
     // TODO: if not found by halfway, grow gfxlist?
     ListThis := 0;
     repeat
      ListThis := gfxlist[ListThis].newerlink; // oldest toward newest
      if ListThis = 0 then begin
       // we went all the way around again, and no state-3's either??
       // in that case, pause the cacher and enlarge gfxlist[]
       writelog('CacheGFX: gfxlist out of space, enlarging from ' + strdec(length(gfxlist)));
       asman_endthread;
       ListThis := length(gfxlist);
       setlength(gfxlist, ListThis + 32);
       fillbyte(gfxlist[ListThis], sizeof(gfxtype) * 32, 0);
       asman_beginthread;
       break;
      end;
      if (gfxlist[ListThis].cachestate = 3)
      and (gfxlist[ListThis].sacred = FALSE) then begin
       asman_purgegfx(ListThis);
       break;
      end;
     until FALSE;
    end;
   until gfxlist[ListThis].cachestate = 0;

   // Prepare the gfxlist[] slot with everything.
   with gfxlist[ListThis] do begin
    writelog('Cache ' + nam + ' @ size ' + strdec(listsizex) + 'x' + strdec(listsizey) + ' -> gfxlist[' + strdec(ListThis) + ']');
    namu := nam;
    // don't know if it's RGBA or RGB until it's loaded...
    bitflag := 0;
    // we need to convert the original offset and size to the new resolution,
    // using a direct size/size multiplier.
    // Since we need sub-pixel accuracy, the offset must be rounded down, and
    // the size must be rounded up; in other words, any pixel row or column
    // in which the resized graphic is in even fractionally must count as
    // a full row/column.
    // This same calculation is done again in LoadGFX.
    ofsxp := (PNGlist[ivar].origofsxp * longint(listsizex)) div PNGlist[ivar].origsizexp;
    if PNGlist[ivar].origofsxp < 0 then dec(ofsxp);
    ofsyp := (PNGlist[ivar].origofsyp * longint(listsizey)) div PNGlist[ivar].origframeheightp;
    if PNGlist[ivar].origofsyp < 0 then dec(ofsyp);

    sizexp := listsizex;
    frameheightp := listsizey;
    sizeyp := frameheightp * PNGlist[ivar].framecount;

    // bookkeeping
    newerlink := 0;
    olderlink := gfxlist[0].olderlink;
    gfxlist[0].olderlink := ListThis;
    gfxlist[olderlink].newerlink := ListThis;
    sacred := sacrflag;
    WriteBarrier; // not needed on x86/x64, but I'm paranoid
    cachestate := asman_cachemark;
    interlockedincrement(asman_queueitems);
   end;
  end;

begin
 // Does the requested graphic already exist at the right size?
 CacheGFX := seekgfx(nam, rqsizex, rqsizey);
 if CacheGFX <> 0 then begin
  // Found, and at the requested size! Sort to most recent, we're done!
  gfxlist[CacheGFX].sacred := sacrflag;
  if (gfxlist[CacheGFX].cachestate in [1..2])
  or (gfxlist[CacheGFX].cachestate = 3) and (gfxlist[CacheGFX].sacred = FALSE)
  then setmostrecent(CacheGFX);
  exit;
 end;

 // Not found at the requested size! Does the PNG exist at all?
 ivar := GetPNG(nam);
 if ivar = 0 then begin
  writelog('[!] CacheGFX: PNG not found: ' + nam);
  exit;
 end;

 // Are we asking for a resized version of the image?
 if (rqsizex <> PNGlist[ivar].origsizexp)
 or (rqsizey <> PNGlist[ivar].origframeheightp)
 then begin
  // Is the graphic already cached at its original size?
  CacheGFX := seekgfx(nam, PNGlist[ivar].origsizexp, PNGlist[ivar].origframeheightp);

  // NO: request the original size version.
  if CacheGFX = 0 then
   ListThis(PNGlist[ivar].origsizexp, PNGlist[ivar].origframeheightp)

  // YES: mark the original size version as recently accessed.
  else if (gfxlist[CacheGFX].cachestate in [1..2])
  or (gfxlist[CacheGFX].cachestate = 3) and (gfxlist[CacheGFX].sacred = FALSE)
  then setmostrecent(CacheGFX);
 end;

 // Now the original size is available or will soon be available, so it's
 // safe to request a resized version. Or, we're asking for the original.
 CacheGFX := ListThis(rqsizex, rqsizey);
 if asman_IsThreadAlive = FALSE then asman_beginthread;
 asman_pokethread; // *whipcrack*
end;

procedure CancelCacheGFX; inline;
// Flips the cache mark, causing all previous cache requests to become
// invalid. When the cacher sees them, it will just release them; while any
// new CacheGFX calls will use the new cache mark.
// If no new cacheables are added, the thread will soon go into a waitstate.
// You should preclude any burst of speculative precaching by cancelling the
// previous speculative cacheables that have turned out to be unnecessary.
begin
 asman_cachemark := (asman_cachemark and 1) + 1;
end;

function GetGFX(const nam : UTF8string; rqsizex, rqsizey : word) : dword;
// Call this to get the gfxlist index of the first item matching the given
// name and size. If the graphic has not been cached, this function blocks
// execution until caching finishes. If the graphic has not been set to be
// cached at all, a cache request is automatically sent first.
// The pixel height will be interpreted as the frame height rather than the
// full height of the bitmap. (Otherwise frames would bleed in each other.)
// If the graphic doesn't exist or couldn't be loaded, returns 0.
// Do not call this from the cacher thread!
begin
 RTLEventResetEvent(asman_jobdone);
 // First, find the gfxlist[] slot where this graphic is expected to be
 GetGFX := seekgfx(nam, rqsizex, rqsizey);
 // not found? in that case, must submit a caching request for it
 if GetGFX = 0 then GetGFX := CacheGFX(nam, rqsizex, rqsizey, TRUE);

 // Has the graphic been cached yet?
 if gfxlist[GetGFX].cachestate < 3 then begin
  // Nope! Tell the cacher this is a prime slot and go to sleep
  writelog('waiting for gfxload');
  gfxlist[GetGFX].sacred := TRUE;
  asman_primeslot := GetGFX;
  if asman_IsThreadAlive = FALSE then asman_beginthread;
  asman_pokethread; // *whipcrack*
  // Now we sleep until the cacher signals it's finished with the prime slot.
  // Or until 4 seconds have elapsed. If any asset load takes that long,
  // something's probably horribly wrong.
  RTLEventWaitFor(asman_jobdone, 4000);
  writelog('wait finished');
  asman_primeslot := 0;
 end;
 // The graphic is ready to be used!
end;

procedure ReleaseGFX;
// Call this to clear the sacred flags from gfxlist[], signalling that you're
// done drawing those bitmaps for now. As the graphics are released, they are
// also moved to the front of the recently-used queue, so when it's necessary
// to unload graphics, the least recently used ones are unloaded first.
var ivar : dword;
begin
 // If gfxmemlimit has been exceeded, purge some old state-3 slots!
 ivar := 0;
 while (asman_gfxmemcount > asman_gfxmemlimit)
 and (gfxlist[ivar].newerlink <> 0) do begin
  ivar := gfxlist[ivar].newerlink;
  if (gfxlist[ivar].cachestate = 3) and (gfxlist[ivar].sacred = FALSE)
  then asman_purgegfx(ivar);
 end;
 // Clear all sacred flags and sort them to most recent
 ivar := 0;
 while (gfxlist[ivar].olderlink <> 0) do begin
  ivar := gfxlist[ivar].olderlink;
  if (gfxlist[ivar].cachestate = 3) and (gfxlist[ivar].sacred) then begin
   gfxlist[ivar].sacred := FALSE;
   setmostrecent(ivar);
  end;
 end;
end;

function ValidateIdentifier(const src : UTF8string; ofs, len : dword) : boolean;
// To easily check if a resource name has stupid characters. Returns true if
// all ok, else false, and puts an error message in asman_errormsg.
// UTF8strings are 1-based, so ofs should be 1 or more. The offset and length
// are in bytes, not characters.
begin
 ValidateIdentifier := FALSE;
 // safety
 if ofs > dword(length(src)) then begin
  asman_errormsg := 'validation start ofs is beyond end of string';
  exit;
 end;
 if ofs = 0 then begin
  asman_errormsg := 'validation start ofs must be > 0';
  exit;
 end;

 while (len <> 0) and (ofs <= dword(length(src))) do begin
  if not byte((@src[ofs])^) in
  [48..57,65..90,97..122,ord('_'),ord('-'),ord('!'),ord('&'),ord('~'),ord('['),ord(']')]
  then begin
   asman_errormsg := 'illegal character in identifier, only alphanumerics and _-!&~ allowed';
   exit;
  end;
  inc(ofs);
  dec(len);
 end;

 ValidateIdentifier := TRUE;
end;

procedure LoadGFX(slotnum : dword);
// Loads and resizes a PNG bitmap as specified by gfxlist[slotnum].
// The list slot must have been pre-filled, preferably by CacheGFX.
// If anything goes wrong, generates a distinctive gradient image instead.
//
// If the graphics cacher thread is running, do not call this function from
// outside the thread. Instead, you should either use CacheGFX to
// request the cacher thread to precache an image, or call GetGFX to
// immediately get the image you need.
var ivar, jvar, kvar : dword;
    PNGindex, origsizeindex : dword;

    loopz, muah, argh, red, green, blue : dword;
    newofs : longint;
    framu : bitmaptype;
    cropleft, croptop, cropright, cropbottom : dword;
    //padleft, padtop, padright, padbottom : dword;
    //targetsizex, targetsizey : word;
    {$define !loadgfxspeedtest}
    {$ifdef loadgfxspeedtest}
    tix : dword;
    {$endif}

  function LoadGFX_LoadPNG(thisslot : dword) : boolean;
  // Loads the PNG file directly into gfxlist[thisslot].
  // Returns FALSE if anything went wrong.
  var newimu : pointer;
      infilu : file;
      bemari : bitmaptype;
      errcode, lvar : dword;
  begin
   LoadGFX_LoadPNG := FALSE;
   while IOresult <> 0 do ; // flush
   // Try to open the file and read the PNG into memory
   assign(infilu, PNGlist[PNGindex].srcfilename);
   lvar := 16;
   repeat
    filemode := 0; reset(infilu, 1); // read-only access
    errcode := IOresult;
    if errcode = 0 then break;
    dec(lvar);
    ThreadSwitch; // give up our timeslice
   until lvar = 0;

   if errcode <> 0 then begin
    writelog('[ERROR] LoadGFX: error ' + strdec(errcode) + ' while opening ' + PNGlist[PNGindex].srcfilename);
    exit;
   end;

   seek(infilu, PNGlist[PNGindex].srcfileofs);
   errcode := IOresult;
   if errcode <> 0 then begin
    close(infilu);
    writelog('[ERROR] LoadGFX: error ' + strdec(errcode) + ' while seeking in ' + PNGlist[PNGindex].srcfilename);
    exit;
   end;

   getmem(newimu, PNGlist[PNGindex].srcfilesizu);
   blockread(infilu, newimu^, PNGlist[PNGindex].srcfilesizu);
   errcode := IOresult;
   close(infilu);
   if errcode <> 0 then begin
    writelog('[ERROR] LoadGFX: error ' + strdec(errcode) + ' while reading ' + PNGlist[PNGindex].srcfilename);
    exit;
   end;

   // Unpack the image
   bemari.image := NIL;
   errcode := mcg_PNGtoMemory(newimu, PNGlist[PNGindex].srcfilesizu, @bemari);
   freemem(newimu); newimu := NIL;
   if errcode <> 0 then begin
    mcg_ForgetImage(@bemari);
    writelog('[ERROR] LoadGFX: ' + PNGlist[PNGindex].namu + ' << ' + mcg_errortxt);
    exit;
   end;

   // Bemari^ now has the RGB/RGBA bitmap!
   // The byte order is BGR, or BGRA.

   // Pre-multiply RGB by alpha if applicable.
   // Gamma-correction should also be done here, but it would kinda require
   // pushing the 32bpp image depth to 56bpp to avoid quality degradation...
   if bemari.memformat = 1 then mcg_PremulRGBA32(bemari.image, bemari.sizex * bemari.sizey)
   else begin
    // Expand 24bpp into 32bpp with a fully opaque alpha channel.
    getmem(newimu, bemari.sizex * bemari.sizey * 4);
    for lvar := bemari.sizex * bemari.sizey - 1 downto 0 do begin
     dword(newimu^) := dword(bemari.image^) or $FF000000;
     inc(newimu, 4); inc(bemari.image, 3);
    end;
    dec(newimu, bemari.sizex * bemari.sizey * 4);
    dec(bemari.image, bemari.sizex * bemari.sizey * 3);
    freemem(bemari.image); bemari.image := newimu; newimu := NIL;
   end;

   // We've got the image, now just stuff it into gfxlist[thisslot]!
   gfxlist[thisslot].bitflag := gfxlist[thisslot].bitflag or ((bemari.memformat and 1) shl 7);
   gfxlist[thisslot].bitmap := bemari.image;
   bemari.image := NIL;

   // track memory usage
   interlockedexchangeadd(asman_gfxmemcount, bemari.sizex * bemari.sizey shl 2);
   WriteBarrier; // not needed on x86/x64, but I'm paranoid...
   gfxlist[thisslot].cachestate := 3;
   interlockeddecrement(asman_queueitems);

   LoadGFX_LoadPNG := TRUE;
  end;

  procedure LoadGFX_FillGradient;
  // Generate a shaded rectangle and pretend that's what they asked for
  var gp : pointer;
      xx, yy : dword;
  begin
   with gfxlist[slotnum] do begin
    writelog('Spawning a gradient as ' + namu);
    argh := 0;
    newofs := length(namu);
    while newofs <> 0 do begin
     argh := (argh xor byte(namu[newofs]));
     argh := dword(argh shl 13) or dword(argh shr 19);
     dec(newofs);
    end;
    red := (argh shr 0) and $3F + $40;
    green := (argh shr 6) and $3F + $40;
    blue := (argh shr 12) and $3F + $40;

    if bitmap <> NIL then begin freemem(bitmap); bitmap := NIL; end;
    getmem(bitmap, sizexp * sizeyp * 4);
    gp := bitmap;
    if (sizexp > 1) and (sizeyp > 1) then
     for yy := sizeyp - 1 downto 0 do begin
      cropbottom := sizexp - 1;
      xx := sizeyp - 1;
      loopz := ($FF * yy + red * (xx - yy)) div xx;
      muah := ($FF * yy + green * (xx - yy)) div xx;
      argh := ($FF * yy + blue * (xx - yy)) div xx;
      cropleft := (red * yy) div xx;
      croptop := (green * yy) div xx;
      cropright := (blue * yy) div xx;
      for xx := sizexp - 1 downto 0 do begin
       byte(gp^) := (argh * xx + cropright * (cropbottom - xx)) div cropbottom;
       inc(gp);
       byte(gp^) := (muah * xx + croptop * (cropbottom - xx)) div cropbottom;
       inc(gp);
       byte(gp^) := (loopz * xx + cropleft * (cropbottom - xx)) div cropbottom;
       inc(gp);
       byte(gp^) := $FF;
       inc(gp);
      end;
     end;
    gp := NIL;
    dword(bitmap^) := $FFFFFFFF; // white top left
    dword((bitmap + (sizexp * sizeyp - 1) shl 2)^) := $FF000000; // black low right
    // track memory usage
    interlockedexchangeadd(asman_gfxmemcount, sizexp * sizeyp shl 2);
    WriteBarrier; // not needed on x86/x64, but I'm paranoid...
    cachestate := 3;
    interlockeddecrement(asman_queueitems);
   end;
  end;

  {$ifdef bonk}
  procedure LoadGFX_optimise(origofs1, origofs2 : longint; targetsize : dword; ppad1, ppad2 : pdword);
  var ideal1, ideal2 : longint; // ideal edges in 1.23.8
      ofs1padded, ofs2padded : longint;
      totaldevsqr, lowestdev, deviation1, deviation2 : dword;
      origsize, paddedsize, interpolationweight1, interpolationweight2, interpolationtotal : dword;
      pad1, pad2 : byte;
  begin
   origsize := origofs2 - origofs1;
   targetsize := targetsize shl 8; // transform to 1.23.8

   // Calculate the ideal resized edges...
   // target ofs = original ofs * targetsize / original size
   if origofs1 < 0
   then ideal1 := (origofs1 * targetsize - origsize shr 1) div origsize
   else ideal1 := (origofs1 * targetsize + origsize shr 1) div origsize;
   if origofs2 < 0
   then ideal2 := (origofs2 * targetsize - origsize shr 1) div origsize
   else ideal2 := (origofs2 * targetsize + origsize shr 1) div origsize;

   // test 16x16 combinations, find lowest squared edge deviation
   pad1 := 16;
   lowestdev := $FFFFFFFF; // lowest deviation amount
   while pad1 <> 0 do begin
    dec(pad1);
    pad2 := 16;
    while pad2 <> 0 do begin
     paddedsize := origsize + pad1 + pad2;
     paddedsize := (paddedsize * (targetsize shr 8) + origsize shr 1) div origsize;
     writeln('Tested pads ',pad1,'/',pad2,' - far edge 1: 0.000  far edge 2: ',paddedsize,'.000');

     interpolationtotal := origsize + pad1 + pad2;
     interpolationweight1 := interpolationtotal - pad1;
     interpolationweight2 := interpolationtotal - pad2;
     deviation1 := (0 * interpolationweight1 + (paddedsize shl 8) * word(interpolationtotal - interpolationweight1)) div interpolationtotal;
     deviation2 := ((paddedsize shl 8) * interpolationweight2 + 0 * word(interpolationtotal - interpolationweight2)) div interpolationtotal;
     ofs1padded := deviation1 mod 256;
     ofs2padded := deviation2 - (deviation1 - deviation1 mod 256);
     writeln('       new1: ',(deviation1/256):3:3,' -> ',(ofs1padded/256):3:3,'  new2: ',(deviation2/256):3:3,' -> ',(ofs2padded/256):3:3,'  newsize: ',((ofs2padded-ofs1padded)/256):3:3);
     deviation1 := abs(ideal1 - ofs1padded);
     deviation2 := abs(ideal2 - ofs2padded);
     totaldevsqr := deviation1 * deviation1 + deviation2 * deviation2;
     writeln('       devi1: ',(deviation1/256):3:3,'  devi2: ',(deviation2/256):3:3,'  total^2: ',totaldevsqr);

     if (totaldevsqr < lowestdev)
     or (totaldevsqr = lowestdev) and (pad1 + pad2 <= ppad1^ + ppad2^)
     then begin
      ppad1^ := pad1;
      ppad2^ := pad2;
      lowestdev := totaldevsqr;
     end;
    end;
   end;
  end;
  {$endif}

begin
 {$ifdef loadgfxspeedtest}
 tix := GetTickCount;
 {$endif}
 // First, safety checks...
 if (slotnum >= dword(length(gfxlist))) or (slotnum = 0) then begin
  writelog('[!] LoadGFX: slot out of bounds ' + strdec(slotnum) + '/' + strdec(dword(length(gfxlist))));
  exit;
 end;
 writelog('LoadGFX ' + gfxlist[slotnum].namu + ' @ ' + strdec(gfxlist[slotnum].sizexp) + 'x' + strdec(gfxlist[slotnum].frameheightp));
 if gfxlist[slotnum].cachestate = 3 then begin
  writelog('LoadGFX: slot ' + strdec(slotnum) + ' already cached');
  exit;
 end;

 // Any previous bitmap really should be freed by now, but just in case...
 if gfxlist[slotnum].bitmap <> NIL then begin
  writelog('[!] LoadGFX: gfxlist[' + strdec(slotnum) + '].bitmap not 0');
  freemem(gfxlist[slotnum].bitmap);
  gfxlist[slotnum].bitmap := NIL;
 end;

 // Let's look up the PNG...
 PNGindex := GetPNG(gfxlist[slotnum].namu);
 if PNGindex = 0 then begin // it doesn't even exist -_-
  writelog('[ERROR] ' + gfxlist[slotnum].namu + ' not present in known DAT files');
  LoadGFX_FillGradient;
  exit;
 end;

 // The PNG exists, and we know its original pixel size.
 // Are we trying to load the original size version?
 if (gfxlist[slotnum].sizexp = PNGlist[PNGindex].origsizexp)
 and (gfxlist[slotnum].frameheightp = PNGlist[PNGindex].origframeheightp)
 then begin
  // YES, let's load the PNG file! (or generate a pic in case of errors)
  if LoadGFX_LoadPNG(slotnum) = FALSE then LoadGFX_FillGradient;
  // Easy peasy, we can call it a day.
  writelog('loadgfx origsize easy');
  exit;
 end;

 // NO, we're trying to load a resized version...
 // Find the original size in gfxlist[].
 origsizeindex := length(gfxlist);
 while origsizeindex <> 0 do begin
  dec(origsizeindex);
  if (gfxlist[origsizeindex].namu = gfxlist[slotnum].namu)
  and (gfxlist[origsizeindex].sizexp = PNGlist[PNGindex].origsizexp)
  and (gfxlist[origsizeindex].frameheightp = PNGlist[PNGindex].origframeheightp)
  then
   if (gfxlist[origsizeindex].cachestate = 3)
   or (gfxlist[origsizeindex].cachestate = asman_cachemark)
   then break;
 end;

 // The original size version wasn't listed??
 if origsizeindex = 0 then begin
  writelog('[!] No prepped slot found for original size ' + gfxlist[slotnum].namu);
  LoadGFX_FillGradient;
  exit;
 end;

 // The original size version is listed, but not loaded yet?
 if gfxlist[origsizeindex].cachestate < 3 then begin
  // YES, let's load the PNG file! (or generate a pic in case of errors)
  if LoadGFX_LoadPNG(origsizeindex) = FALSE then begin
   LoadGFX_FillGradient;
   exit;
  end;
 end;

 // The original version is loaded and available!
 // It needs to be resized...
 // To minimise subtle alignment errors, the graphic needs to be resized with
 // sub-pixel precision. A normal straight resize will position a graphic's
 // edges exactly in the pixel grid, but if the graphic will be displayed
 // relative to a different-sized image (and using size multipliers that are
 // not integers), that means the pixel edges may be off by +/- 0.5 pixels,
 // which is definitely noticeable and distracting, for example in blinking
 // animations.
 //
 // To counter this, the graphic being resized can have temporary padding
 // added. Then the padding gets aligned at exactly the pixel grid, while the
 // graphic gets subtly shifted. By checking a number of small padding amount
 // combinations on opposing edges, we can choose the combination that places
 // the graphic's edges to the least wrong positions, and it's pretty fast.
 //
 // Note that since the run-time gob location is liable to change all over
 // the place at a moment's notice, it's not preferable to optimise the gob
 // location's sub-pixel position, since you'd potentially have to do it
 // every frame. However, in PNG metadata we track both the original
 // resolution and pixel location relative to the original resolution, as
 // a constant location offset. That one we can optimise for, here!

 // However! Since the asset manager now returns exactly the pixel size
 // requested, it's impossible to do sub-pixel optimisation here since it
 // results in the pixel size growing by 1 both ways.
 // So let's just resize normally and optimise the display elsewhere.

 gfxlist[slotnum].bitflag := gfxlist[slotnum].bitflag or (gfxlist[origsizeindex].bitflag and 128);
 ivar := PNGlist[PNGindex].framecount;
 jvar := PNGlist[PNGindex].origsizexp * PNGlist[PNGindex].origframeheightp * 4;
 if gfxlist[slotnum].bitmap <> NIL then begin freemem(gfxlist[slotnum].bitmap); gfxlist[slotnum].bitmap := NIL; end;
 setlength(framu.palette, 0);
 framu.memformat := 1;
 framu.bitdepth := 8;
 // Image with a single frame.
 if ivar = 1 then begin
  framu.sizex := PNGlist[PNGindex].origsizexp;
  framu.sizey := PNGlist[PNGindex].origsizeyp;
  getmem(framu.image, jvar);
  move(gfxlist[origsizeindex].bitmap^, framu.image^, jvar);
  mcg_ScaleBitmap(@framu, gfxlist[slotnum].sizexp, gfxlist[slotnum].sizeyp);
  gfxlist[slotnum].bitmap := framu.image; framu.image := NIL;
 end else begin
  // Image with multiple frames.
  kvar := gfxlist[slotnum].sizexp * gfxlist[slotnum].frameheightp * 4;
  getmem(gfxlist[slotnum].bitmap, kvar * ivar);
  muah := 0; // source ofs
  argh := 0; // dest ofs
  while ivar <> 0 do begin // for every frame...
   dec(ivar);
   framu.sizex := PNGlist[PNGindex].origsizexp;
   framu.sizey := PNGlist[PNGindex].origframeheightp;
   getmem(framu.image, jvar);
   move((gfxlist[origsizeindex].bitmap + muah)^, framu.image^, jvar);
   mcg_ScaleBitmap(@framu, gfxlist[slotnum].sizexp, gfxlist[slotnum].frameheightp);
   move(framu.image^, (gfxlist[slotnum].bitmap + argh)^, kvar);
   freemem(framu.image); framu.image := NIL;
   inc(muah, jvar);
   inc(argh, kvar);
  end;
 end;

 {$ifdef bonk}
 with PNGlist[PNGindex] do begin
  if ((origofsxp or origofsyp) = 0)
  and (origsizexp = origresx) and (origsizeyp = origresy)
  then begin
   // Actually it's a full-screen image, so it's going to get scaled to
   // a full viewport and its edges can generally be assumed to be fine
   // without optimisation
   padleft := 0; padright := 0;
   padtop := 0; padbottom := 0;
  end else begin
   // Find the ideal horizontal padding amounts!
   LoadGFX_optimise(origofsxp, origofsxp + origsizexp, gfxlist[slotnum].sizexp, @padleft, @padright);

   // Find the ideal vertical padding amounts!
   LoadGFX_optimise(origofsyp, origofsyp + origframeheightp, gfxlist[slotnum].frameheightp, @padtop, @padbottom);

  end;
 end;
 {$endif}

 // Track memory usage
 with gfxlist[slotnum] do begin
  interlockedexchangeadd(asman_gfxmemcount, sizexp * sizeyp shl 2);
  WriteBarrier;
  cachestate := 3;
  interlockeddecrement(asman_queueitems);
  writelog('Loaded slot ' + strdec(slotnum) + ' memcount=' + strdec(asman_gfxmemcount) + ' queue=' + strdec(asman_queueitems));
 end;
 // And we're done!
end;

procedure SortScripts(onlylast : boolean);
// Sorts the script label array in place using teleporting gnome sort.
var ivar, jvar : dword;
    tempscr : scripttype;
begin
 if length(script) = 0 then exit;
 ivar := 0; jvar := $FFFFFFFF;
 if onlylast then ivar := length(script) - 1;
 while ivar < dword(length(script)) do begin
  if (ivar = 0) or (script[ivar].labelnamu >= script[ivar - 1].labelnamu)
  then begin
   if jvar = $FFFFFFFF then
    inc(ivar)
   else begin
    ivar := jvar; jvar := $FFFFFFFF;
   end;
  end
  else begin
   tempscr := script[ivar];
   script[ivar] := script[ivar - 1];
   script[ivar - 1] := tempscr;
   jvar := ivar; dec(ivar);
  end;
 end;
end;

function GetLanguageIndex(const langdesc : UTF8string) : dword;
// This returns an existing language index for the input descriptor; if the
// language doesn't exist, it is added as a new language.
var ivar : dword;
begin
 // If no languages have been defined yet, make this the primary language.
 if languagelist[0] = 'undefined' then GetLanguageIndex := 0
 else begin
  // Does this language exist?
  GetLanguageIndex := $FFFFFFFF;
  for ivar := 0 to length(languagelist) - 1 do
   if lowercase(languagelist[ivar]) = lowercase(langdesc) then begin
    // it exists!
    GetLanguageIndex := ivar;
    break;
   end;
  if GetLanguageIndex = $FFFFFFFF then begin
   // it doesn't exist, so create a new language
   GetLanguageIndex := length(languagelist);
   setlength(languagelist, length(languagelist) + 1);
   // set up this language in the global empty label for duplicable strings
   setlength(script[0].stringlist, GetLanguageIndex + 1);
  end;
 end;
 languagelist[GetLanguageIndex] := langdesc;
end;

function ImportStringTable(const tablefile : UTF8string) : boolean;
// Attempts to read the given file, which should contain a plain
// tab-separated table in UTF8, and imports it as a string table.
// The first row should be "String IDs", followed by language descriptors
// identifying their respective columns. The following rows must contain
// a unique string ID each, and string content in the other columns.
// Returns TRUE if successful, otherwise see asman_errormsg.
var outfile : file;
    tablebuf : pointer;
    tablesize : dword;
    ivar : dword;

  procedure importbuffy;
  var readp, endp, cellstart : pointer;
      langindex : array of dword;
      row : array of record
        col : array of UTF8string;
      end;
      labelstring : string[63];
      cellsize, rowcount, rowindex, colindex, labelindex : dword;
      stringindex, charindex : dword;
  begin
   readp := tablebuf;
   endp := tablebuf + tablesize;

   // First, convert the input stream into a table structure.
   rowcount := 0;
   colindex := 0;
   setlength(row, 512);
   cellstart := readp;

   while readp < endp do begin
    case byte(readp^) of
     // Tab, linebreak
     9, $A..$D:
     begin
      // new cell
      if colindex >= dword(length(row[rowcount].col))
      then setlength(row[rowcount].col, length(row[rowcount].col) + 3);
      cellsize := 0;
      if cellstart <> NIL then cellsize := readp - cellstart;
      setlength(row[rowcount].col[colindex], cellsize);
      if cellsize <> 0 then move(cellstart^, row[rowcount].col[colindex][1], cellsize);
      inc(colindex);
      cellstart := NIL;

      // new row
      if byte(readp^) in [$A..$D] then begin
       if rowcount = 0 then begin
        if colindex < 2 then begin
         asman_errormsg := 'No language columns in ' + tablefile;
         exit;
        end;
        if row[0].col[0] <> 'STRING IDS' then begin
         asman_errormsg := 'Expected "String IDs" at start of ' + tablefile + ', got ' + row[0].col[0];
         exit;
        end;
       end;
       if colindex > 1 then begin
        setlength(row[rowcount].col, colindex);
        inc(rowcount);
        if rowcount >= dword(length(row)) then setlength(row, length(row) + length(row) shr 1 + 256);
       end;
       colindex := 0;
      end;
     end;

     // Other control chars
     0..8, $E..$1F:
     begin
      asman_errormsg := 'Invalid character $' + strhex(byte(readp^)) + ' in ' + tablefile;
      exit;
     end;

     // Valid lowercase chars
     97..122:
     begin
      // uppercase it if it's the first column, which has labels
      if colindex = 0 then byte(readp^) := byte(readp^) and $5F;
      if cellstart = NIL then cellstart := readp;
     end;

     // Other valid chars
     else if cellstart = NIL then cellstart := readp;
    end;
    inc(readp);
   end;

   WriteLog('read the tsv! acquired rows: ' + strdec(rowcount));
   readp := NIL; endp := NIL; cellstart := NIL;
   // Shrink the imported table to minimum required
   setlength(row, rowcount);

   // Make sure our language list contains all languages from the table.
   // This also maps the table columns to language indexes.
   setlength(langindex, length(row[0].col));
   for colindex := 1 to length(row[0].col) - 1 do
    langindex[colindex] := GetLanguageIndex(row[0].col[colindex]);

   // Make sure the global label has a full language array.
   if length(script[0].stringlist) < length(languagelist) then
    setlength(script[0].stringlist, length(languagelist));

   // Loop through all rows of the imported table, from bottom to top.
   // If the table is sorted in ascending string ID order, as recommended,
   // this'll minimise string array resizing. Otherwise, it'll still work,
   // but more slowly.
   labelindex := 0;
   rowindex := rowcount - 1;
   while rowindex > 0 do begin
    // Get the number component of the string ID in the leftmost cell, by
    // reading numbers from the right side until a dot.
    charindex := length(row[rowindex].col[0]);
    if row[rowindex].col[0][charindex] in ['0'..'9'] = FALSE then begin
     asman_errormsg := tablefile + ' row ' + strdec(rowindex) + ' bad string ID';
     exit;
    end;
    repeat
     case row[rowindex].col[0][charindex] of
      '0'..'9': ; // tough to convert the number at this step, do it later
      '.':
      if charindex > 64 then charindex := 1
      else begin
       // Anything left of the dot is a script label name.
       byte(labelstring[0]) := charindex - 1;
       move(row[rowindex].col[0][1], labelstring[1], charindex - 1);
       // Anything right of the dot is a string index.
       stringindex := 0;
       while charindex < dword(length(row[rowindex].col[0])) do begin
        inc(charindex);
        stringindex := stringindex * 10 + byte(row[rowindex].col[0][charindex]) - 48;
       end;
       break;
      end;
      else charindex := 1;
     end;
     dec(charindex);
     if charindex = 0 then begin
      asman_errormsg := tablefile + ' row ' + strdec(rowindex) + ' bad string ID';
      exit;
     end;
    until FALSE;

    // Get the script label index for this row's label.
    if labelstring = '' then
     labelindex := 0
    else
    // If this script label is same as last time, re-use the label index.
    if (script[labelindex].labelnamu <> labelstring) then begin
     // It's a different label than last time... does the label exist yet?
     labelindex := GetScr(labelstring);
     if labelindex = 0 then begin
      // It doesn't exist, so add it to the script array.
      setlength(script, length(script) + 1);
      fillbyte(script[length(script) - 1], sizeof(scripttype), 0);
      script[length(script) - 1].labelnamu := labelstring;
      // The script array must always be sorted.
      SortScripts(TRUE);
      // Get the newly sorted label index.
      labelindex := GetScr(labelstring);
     end;
     // Make sure this label has a full language array.
     if length(script[labelindex].stringlist) < length(languagelist) then
      setlength(script[labelindex].stringlist, length(languagelist));
    end;

    // Loop through all language columns on this row.
    if length(row[rowindex].col) >= 2 then
    for colindex := 1 to length(row[rowindex].col) - 1 do
    with script[labelindex].stringlist[langindex[colindex]] do begin
     // Make sure the label's language's string array is big enough.
     if stringindex >= dword(length(txt)) then setlength(txt, stringindex + 1);
     // Save the string!
     txt[stringindex] := row[rowindex].col[colindex];
    end;

    // Clean up, release the table from memory as we go?
    setlength(row, rowindex);

    dec(rowindex);
   end;

   ImportStringTable := TRUE;
  end;

begin
 ImportStringTable := FALSE;
 assign(outfile, tablefile);
 filemode := 0; reset(outfile, 1); // read-only access
 ivar := IOresult;
 if ivar <> 0 then begin
  asman_errormsg := 'IO error ' + strdec(ivar) + ' trying to open ' + tablefile;
  exit;
 end;
 // Read the presumed string table file into memory.
 tablesize := filesize(outfile);
 if tablesize = 0 then begin
  asman_errormsg := tablefile + ' is empty';
  close(outfile);
  exit;
 end;
 getmem(tablebuf, tablesize + 1);
 blockread(outfile, tablebuf^, tablesize);
 ivar := IOresult;
 // add an extra linebreak at the end to be sure
 byte((tablebuf + tablesize)^) := $A;
 inc(tablesize);
 if ivar = 0 then begin
  importbuffy;
 end
 else asman_errormsg := 'IO error ' + strdec(ivar) + ' trying to read ' + tablefile;
 // Clean up
 freemem(tablebuf); tablebuf := NIL;
 close(outfile);
end;

function DumpStringTable(const tablefile : UTF8string) : boolean;
// Prints the current string tables in plain UTF8 text from memory into the
// given file. The strings are presented as a table, separated with tabs and
// linebreaks. This assumes the table labels are alphabetically sorted, as
// they should be at all times.
// Returns TRUE if successful, otherwise see asman_errormsg.
var outfile : text;
    ivar, jvar, kvar, lvar, mvar, stringindex : dword;
begin
 DumpStringTable := FALSE;
 if length(script) = 0 then begin
  asman_errormsg := 'Can''t dump string table, no strings exist';
  exit;
 end;

 assign(outfile, tablefile);
 ivar := IOresult;
 if ivar <> 0 then begin
  asman_errormsg := 'IO error ' + strdec(ivar) + ' trying to assign ' + tablefile;
  exit;
 end;
 filemode := 1; rewrite(outfile); // write-only access
 ivar := IOresult;
 if ivar <> 0 then begin
  asman_errormsg := 'IO error ' + strdec(ivar) + ' trying to rewrite ' + tablefile;
  exit;
 end;

 // Print the header, with language descriptors
 write(outfile, 'String IDs');
 for ivar := 0 to length(languagelist) - 1 do
  write(outfile, chr(9) + languagelist[ivar]);
 writeln(outfile);

 // Loop through all labels
 for jvar := 0 to length(script) - 1 do begin
  // Make sure each script has an array for all active languages.
  if length(script[jvar].stringlist) < length(languagelist) then
   setlength(script[jvar].stringlist, length(languagelist));
  // Find the maximum amount of strings in this script.
  kvar := 0;
  for lvar := length(languagelist) - 1 downto 0 do
   if dword(length(script[jvar].stringlist[lvar].txt)) > kvar then
    kvar := length(script[jvar].stringlist[lvar].txt);
  // Make sure all languages have the same amount of strings.
  for lvar := length(languagelist) - 1 downto 0 do
   if dword(length(script[jvar].stringlist[lvar].txt)) < kvar then
    setlength(script[jvar].stringlist[lvar].txt, kvar);
  // Loop through all strings indexes under this label.
  if kvar <> 0 then
   for stringindex := 0 to kvar - 1 do begin
    // Print the string ID.
    write(outfile, script[jvar].labelnamu + '.' + strdec(stringindex));
    // Loop through all languages.
    for lvar := 0 to length(languagelist) - 1 do
    with script[jvar].stringlist[lvar] do begin
     // Print the string!
     write(outfile, chr(9));
     if length(txt[stringindex]) <> 0 then
      for mvar := 1 to length(txt[stringindex]) do
       write(outfile, txt[stringindex][mvar]);
    end;
    writeln(outfile);
   end;
 end;

 DumpStringTable := TRUE;

 ivar := IOresult;
 if ivar <> 0 then asman_errormsg := 'IO error ' + strdec(ivar) + ' trying to write in ' + tablefile;
 close(outfile);
end;

function CompressScripts(poku : ppointer) : dword;
// Compresses all scripts currently in memory into a convenient block that
// can be directly written in a datafile, including signature and size.
// Returns the size of the created block in bytes, or 0 in case of errors.
// Read asman_errormsg for details.
// The caller must provide an empty pointer, where this function saves the
// block. The caller is responsible for freeing it.
var zzz : tzstream;
    ivar : dword;
    unpackedsize : dword;
    zlibcode : longint;

  procedure zzzerror;
  begin
   asman_errormsg := 'PasZLib.Deflate: ' + zError(zlibcode) + '; total_in=' + strdec(ptruint(zzz.total_in)) + ' total_out=' + strdec(ptruint(zzz.total_out)) + ' avail_in=' + strdec(zzz.avail_in) + ' avail_out=' + strdec(zzz.avail_out);
  end;

begin
 CompressScripts := 0;
 // Calculate how much uncompressed data we have
 unpackedsize := 12; // signature, block size, uncompressed block size
 ivar := length(script);
 while ivar <> 0 do begin
  dec(ivar);
  inc(unpackedsize,
    6 + // two length bytes, code size dword
    dword(length(script[ivar].labelnamu)) +
    dword(length(script[ivar].nextlabel)) +
    script[ivar].codesize);
 end;

 // Reserve a bunch of memory for the compressed stream
 getmem(poku^, unpackedsize + 65536);

 // Write the block header
 dword(poku^^) := $501E0BB0; // signature
 // dword((poku^ + 4)^) := compressed block size, skip for now...
 // dword((poku^ + 8)^) := unpackedsize; // uncompressed block size, skip...

 // Init the compressor!
 zzz.next_in := NIL;
 zlibcode := DeflateInit(zzz, Z_BEST_COMPRESSION);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;
 zzz.total_in := 0;
 zzz.total_out := 0;
 zzz.next_out := poku^ + 12;
 zzz.avail_out := unpackedsize + 65536 - 12;

 // Pack the scripts piece by piece
 // (skip script[0] which is hardcoded as invalid and empty)
 if length(script) >= 2 then
 for ivar := 1 to length(script) - 1 do begin
  // save the label name...
  zzz.next_in := @script[ivar].labelnamu[0];
  zzz.avail_in := length(script[ivar].labelnamu) + 1;
  zlibcode := deflate(zzz, Z_NO_FLUSH);
  if zlibcode <> Z_OK then begin zzzerror; exit; end;
  // save the next label name...
  zzz.next_in := @script[ivar].nextlabel[0];
  zzz.avail_in := length(script[ivar].nextlabel) + 1;
  zlibcode := deflate(zzz, Z_NO_FLUSH);
  if zlibcode <> Z_OK then begin zzzerror; exit; end;
  // save the code size...
  zzz.next_in := @script[ivar].codesize;
  zzz.avail_in := 4;
  zlibcode := deflate(zzz, Z_NO_FLUSH);
  if zlibcode <> Z_OK then begin zzzerror; exit; end;
  // save the bytecode...
  if script[ivar].codesize <> 0 then begin
   zzz.next_in := script[ivar].code;
   zzz.avail_in := script[ivar].codesize;
   zlibcode := deflate(zzz, Z_NO_FLUSH);
   if zlibcode <> Z_OK then begin zzzerror; exit; end;
  end;
 end;

 // Flush the output
 ivar := 0;
 zzz.next_in := @ivar;
 zzz.avail_in := 1;
 zlibcode := deflate(zzz, Z_FINISH);
 if zlibcode <> Z_STREAM_END then begin zzzerror; exit; end;

 // Shut down the compressor!
 zlibcode := DeflateEnd(zzz);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;

 // Save and return the size of the compressed block
 ivar := zzz.next_out - poku^;
 dword((poku^ + 4)^) := ivar - 8; // save, less sig and size dword itself
 dword((poku^ + 8)^) := zzz.total_in; // save true unpacked size
 CompressScripts := ivar;
end;

function CompressStringTable(poku : ppointer; langindex : dword) : dword;
// Compresses the strings of this language from all scripts into
// a convenient block that can be directly written in a datafile. Only one
// language can be compressed in one block.
// Returns the size of the created block in bytes, or 0 in case of errors.
// Read asman_errormsg for details.
// The caller must provide an empty pointer, where this function saves the
// block. The caller is responsible for freeing it.
var zzz : tzstream;
    ivar, jvar, lvar : dword;
    unpackedsize : dword;
    zlibcode : longint;

  procedure zzzerror;
  begin
   asman_errormsg := 'PasZLib.Deflate: ' + zError(zlibcode) + '; total_in=' + strdec(ptruint(zzz.total_in)) + ' total_out=' + strdec(ptruint(zzz.total_out)) + ' avail_in=' + strdec(zzz.avail_in) + ' avail_out=' + strdec(zzz.avail_out);
  end;

begin
 CompressStringTable := 0;

 // safety
 if langindex >= dword(length(languagelist)) then begin
  asman_errormsg := 'CompressStringTable: Language index ' + strdec(langindex) + ' out of bounds';
  exit;
 end;

 // Calculate how much uncompressed data we have, to estimate how large the
 // output buffer needs to be.
 unpackedsize := 12; // signature, block size, uncompressed stream size
 // language description, terminator byte
 inc(unpackedsize, dword(length(languagelist[langindex])) + 2);

 if length(script) <> 0 then
  for ivar := length(script) - 1 downto 0 do begin
   if langindex < dword(length(script[ivar].stringlist)) then
    with script[ivar] do begin
     // stringcount dword, terminator word
     inc(unpackedsize, 6);
     // labelnamu ministring
     inc(unpackedsize, dword(length(labelnamu)) + 1);
     if length(stringlist[langindex].txt) <> 0 then
      for jvar := length(stringlist[langindex].txt) - 1 downto 0 do
       inc(unpackedsize, 2 + dword(length(stringlist[langindex].txt[jvar])));
    end;
  end;

 // Reserve a bunch of memory for the compressed stream.
 // Compared to the uncompressed size, zdeflate.pas says the compressed
 // buffer must be at least 0.1% larger + 12 bytes.
 ivar := unpackedsize + unpackedsize shr 9 + 16;
 getmem(poku^, ivar);

 // Write the block header
 dword(poku^^) := $511E0BB0; // signature
 //dword((poku^ + 4)^) := compressed block size, skip for now...
 //dword((poku^ + 8)^) := unpackedsize; // uncompressed stream size, skip...

 // Init the compressor!
 zzz.next_in := NIL;
 zlibcode := DeflateInit(zzz, Z_BEST_COMPRESSION);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;
 zzz.total_in := 0;
 zzz.total_out := 0;
 zzz.next_out := poku^ + 12; // skip sig, blocksize, streamsize
 zzz.avail_out := ivar - 12;

 // Save the UTF-8 language descriptor ministring
 ivar := length(languagelist[langindex]);
 if ivar > 255 then ivar := 255;
 zzz.next_in := @ivar;
 zzz.avail_in := 1;
 zlibcode := deflate(zzz, Z_NO_FLUSH);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;
 zzz.next_in := @languagelist[langindex][1];
 zzz.avail_in := ivar;
 zlibcode := deflate(zzz, Z_NO_FLUSH);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;

 // Pack the strings label by label
 if length(script) <> 0 then
 for ivar := 0 to length(script) - 1 do begin
  if langindex < dword(length(script[ivar].stringlist)) then begin
   // save the label name as a ministring
   zzz.next_in := @script[ivar].labelnamu[0];
   zzz.avail_in := length(script[ivar].labelnamu) + 1;
   zlibcode := deflate(zzz, Z_NO_FLUSH);
   if zlibcode <> Z_OK then begin zzzerror; exit; end;

   with script[ivar].stringlist[langindex] do begin
    // save the string count
    lvar := length(txt);
    zzz.next_in := @lvar;
    zzz.avail_in := 4;
    zlibcode := deflate(zzz, Z_NO_FLUSH);
    if zlibcode <> Z_OK then begin zzzerror; exit; end;

    // loop through the strings in this label...
    if length(txt) <> 0 then
    for jvar := 0 to length(txt) - 1 do begin
     // save the string length
     lvar := length(txt[jvar]);
     zzz.next_in := @lvar;
     zzz.avail_in := 2;
     zlibcode := deflate(zzz, Z_NO_FLUSH);
     if zlibcode <> Z_OK then begin zzzerror; exit; end;
     // save the string
     if lvar <> 0 then begin
      zzz.next_in := @txt[jvar][1];
      zzz.avail_in := lvar;
      zlibcode := deflate(zzz, Z_NO_FLUSH);
      if zlibcode <> Z_OK then begin zzzerror; exit; end;
     end;
    end;
    // save the terminator
    lvar := $FFFFFFFF;
    zzz.next_in := @lvar;
    zzz.avail_in := 2;
    zlibcode := deflate(zzz, Z_NO_FLUSH);
    if zlibcode <> Z_OK then begin zzzerror; exit; end;
   end;
  end;
 end;

 // Save the final terminator and flush the output
 ivar := 0;
 zzz.next_in := @ivar;
 zzz.avail_in := 1;
 zlibcode := deflate(zzz, Z_FINISH);
 if zlibcode <> Z_STREAM_END then begin zzzerror; exit; end;

 // Calculate the final size of the block we generated
 ivar := zzz.next_out - poku^;
 // Save the string set chunk size, less the chunk signature/size itself
 dword((poku^ + 4)^) := ivar - 8;
 // Save the uncompressed stream size
 dword((poku^ + 8)^) := zzz.total_in;
 writelog('String table saved: ' + strdec(ptruint(zzz.total_out)) + ' packed, ' + strdec(ptruint(zzz.total_in)) + ' unpacked');
 // Return the size of the compressed block
 CompressStringTable := ivar;

 // Shut down the compressor!
 zlibcode := DeflateEnd(zzz);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;
end;

function DecompressScripts(poku : pointer; blocksize : dword) : boolean;
// Poku^ must point to a SuperSakura script block, at the first byte after
// the signature and block size. This will unpack the scripts into memory,
// and resorts the scripts array.
// The caller is responsible for freeing poku.
// Returns true if successful, otherwise check asman_errormsg for details.
var tempbuffy, streamp, streamend : pointer;
    newlabellist : array of scripttype;
    newlabelcount : dword;
    templabel : scripttype;
    zzz : tzstream;
    ivar, jvar, unpackedsize : dword;
    zlibcode : longint;

  procedure zzzerror;
  begin
   asman_errormsg := ('PasZLib.Deflate: ' + zError(zlibcode) + '; total_in=' + strdec(ptruint(zzz.total_in)) + ' total_out=' + strdec(ptruint(zzz.total_out)) + ' avail_in=' + strdec(zzz.avail_in) + ' avail_out=' + strdec(zzz.avail_out));
   if tempbuffy <> NIL then begin freemem(tempbuffy); tempbuffy := NIL; end;
  end;

begin
 DecompressScripts := FALSE;
 templabel.code := NIL;
 if blocksize < 4 then begin
  asman_errormsg := 'Corrupted sakurascript block header in DAT';
  exit;
 end;

 // Set up a buffer to decompress the scripts in
 unpackedsize := dword(poku^);
 getmem(tempbuffy, unpackedsize);
 writelog('reading scripts block, packed ' + strdec(blocksize) + ', unpacked ' + strdec(unpackedsize));

 // Init the decompressor!
 zzz.next_in := NIL;
 zlibcode := InflateInit(zzz);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;

 zzz.next_in := poku + 4;
 zzz.next_out := tempbuffy;
 zzz.avail_in := blocksize - 4;
 zzz.avail_out := unpackedsize;
 zzz.total_in := 0;
 zzz.total_out := 0;

 // Decompress!
 zlibcode := Inflate(zzz, Z_FINISH);
 if zlibcode <> Z_STREAM_END then begin zzzerror; exit; end;

 // Shut down the decompressor!
 zlibcode := InflateEnd(zzz);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;

 // Tempbuffy now contains a series of concatenated script label records.
 // Let's iterate through them. If a label name already exists in memory, it
 // will be overwritten; otherwise it's saved as a new script label.
 setlength(newlabellist, 256);
 newlabelcount := 0;
 streamp := tempbuffy;
 streamend := tempbuffy + unpackedsize;

 while streamp < streamend do begin
  // Bounds check...
  ivar := byte(streamp^);
  if (ivar = 0) or (streamp + ivar + 1 >= streamend) then break;
  // Get and uppercase the label name
  templabel.labelnamu := upcase(string(streamp^));
  inc(streamp, ivar + 1);
  // Bounds check...
  ivar := byte(streamp^);
  if streamp + ivar + 1 + 4 >= streamend then break;
  // Get and uppercase the next label name
  templabel.nextlabel := upcase(string(streamp^));
  inc(streamp, ivar + 1);
  // Get the code size
  templabel.codesize := dword(streamp^);
  inc(streamp, 4);
  // Bounds check...
  if streamp + ivar > streamend then break;
  // Get the bytecode
  getmem(templabel.code, templabel.codesize);
  move(streamp^, templabel.code^, templabel.codesize);
  inc(streamp, templabel.codesize);
  // Set up a string array in templabel
  setlength(templabel.stringlist, 0);
  setlength(templabel.stringlist, length(languagelist));

  // Does this label exist yet?
  ivar := GetScr(templabel.labelnamu);

  if ivar <> 0 then begin
   // Label has been previously loaded! Overwrite the old one
   if script[ivar].code <> NIL then begin
    freemem(script[ivar].code); script[ivar].code := NIL;
   end;
   script[ivar] := templabel;
  end else begin
   // Label has not been previously loaded! Append to the new labels list.
   // (The label may already be in the new label list if the dat file has
   // been hacked or incorrectly generated, but in that case the engine will
   // just randomly use one or the other script.)
   if newlabelcount >= dword(length(newlabellist)) then
    setlength(newlabellist, length(newlabellist) + 256);
   newlabellist[newlabelcount] := templabel;
   inc(newlabelcount);
  end;

  // Clean up
  templabel.code := NIL;
 end;

 // Append newlabellist[] to script[], and re-sort
 if newlabelcount <> 0 then begin
  ivar := length(script);
  setlength(script, ivar + newlabelcount);
  // Since there are dynamic arrays involved, can't just "move" the memory
  for jvar := 0 to newlabelcount - 1 do
   script[ivar + jvar] := newlabellist[jvar];
  setlength(newlabellist, 0);
  SortScripts(FALSE);
 end;
 writelog('acquired ' + strdec(newlabelcount) + ' new labels from script block');

 // clean up
 if tempbuffy <> NIL then begin freemem(tempbuffy); tempbuffy := NIL; end;
 if templabel.code <> NIL then begin freemem(templabel.code); templabel.code := NIL; end;
 DecompressScripts := TRUE;
end;

function DecompressStringTable(poku : pointer; blocksize : dword) : boolean;
// Poku^ must point to a SuperSakura string table block, at the first byte
// after the signature and block size.
// This will unpack the strings into memory, and re-sorts the script array,
// if necessary.
// The caller is responsible for freeing poku.
// Returns true if successful, otherwise check asman_errormsg for details.
var tempbuffy, streamp, streamend : pointer;
    langindex : dword;
    numlabels, numstrings : dword;
    newlabellist : array of scripttype;
    newlabelcount : dword;
    zzz : tzstream;
    langdesc : UTF8string;
    targetlabel : pscripttype;
    labelnamu : string[63];
    ivar, jvar, unpackedsize : dword;
    zlibcode : longint;

  procedure zzzerror;
  begin
   asman_errormsg := ('PasZLib.Deflate: ' + zError(zlibcode) + '; total_in=' + strdec(ptruint(zzz.total_in)) + ' total_out=' + strdec(ptruint(zzz.total_out)) + ' avail_in=' + strdec(zzz.avail_in) + ' avail_out=' + strdec(zzz.avail_out));
   if tempbuffy <> NIL then begin freemem(tempbuffy); tempbuffy := NIL; end;
  end;

begin
 DecompressStringTable := FALSE;
 if blocksize < 4 then begin
  asman_errormsg := 'Too small block size in string table header';
  exit;
 end;

 // Set up a buffer to decompress the strings in
 unpackedsize := dword(poku^);
 getmem(tempbuffy, unpackedsize);
 writelog('reading string table block, packed ' + strdec(blocksize) + ', unpacked ' + strdec(unpackedsize));

 // Init the decompressor!
 zzz.next_in := NIL;
 zlibcode := InflateInit(zzz);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;

 zzz.next_in := poku + 4;
 zzz.next_out := tempbuffy;
 zzz.avail_in := blocksize - 4;
 zzz.avail_out := unpackedsize;
 zzz.total_in := 0;
 zzz.total_out := 0;

 // Decompress!
 zlibcode := Inflate(zzz, Z_FINISH);
 if zlibcode <> Z_STREAM_END then begin zzzerror; exit; end;

 // Tempbuffy now contains strings for multiple script labels.
 // Let's loop through them. If strings already exists in memory, they will
 // be overwritten; otherwise added to the current string table.
 streamp := tempbuffy;
 streamend := tempbuffy + zzz.total_out;

 // Shut down the decompressor first.
 zlibcode := InflateEnd(zzz);
 if zlibcode <> Z_OK then begin zzzerror; exit; end;

 // Bounds check...
 if streamp >= streamend then begin
  asman_errormsg := 'String table block too small in DAT file';
  if tempbuffy <> NIL then begin freemem(tempbuffy); tempbuffy := NIL; end;
  exit;
 end;
 // First get the language descriptor length.
 setlength(langdesc, byte(streamp^));
 inc(streamp);
 // Bounds check...
 if streamp + length(langdesc) > streamend then begin
  asman_errormsg := 'String table block language descriptor out of bounds';
  if tempbuffy <> NIL then begin freemem(tempbuffy); tempbuffy := NIL; end;
  exit;
 end;
 move(streamp^, langdesc[1], length(langdesc));
 inc(streamp, length(langdesc));
 langindex := GetLanguageIndex(langdesc);

 // We'll use these to track statistics of how many things were loaded.
 numlabels := 0; numstrings := 0;
 // Stringsets are unpacked into these first.
 setlength(newlabellist, 256);
 newlabelcount := 0;

 while streamp < streamend do begin
  // Read label name length byte
  ivar := byte(streamp^);
  // Bounds check...
  if streamp + ivar + 5 > streamend then break;
  // Acquire the label name
  labelnamu := string(streamp^);
  inc(streamp, ivar + 1);

  // Figure out where these strings can be placed
  if labelnamu = '' then
   // global label!
   targetlabel := @script[0]
  else begin
   ivar := GetScr(labelnamu);
   if ivar <> 0 then
    // pre-existing script label!
    targetlabel := @script[ivar]
   else begin
    // new script label!
    if newlabelcount >= dword(length(newlabellist)) then setlength(newlabellist, length(newlabellist) + 256);
    targetlabel := @newlabellist[newlabelcount];
    inc(newlabelcount);
    fillbyte(targetlabel^, sizeof(scripttype), 0);
    targetlabel^.labelnamu := labelnamu;
   end;
  end;

  // Make sure the string list is big enough
  if length(targetlabel^.stringlist) < length(languagelist) then
   setlength(targetlabel^.stringlist, length(languagelist));

  // Get the string count for this label
  ivar := dword(streamp^);
  inc(streamp, 4);
  setlength(targetlabel^.stringlist[langindex].txt, 0);
  setlength(targetlabel^.stringlist[langindex].txt, ivar);

  // Loop through the string block
  ivar := 0;
  repeat
   // Bounds check...
   if streamp + 2 > streamend then break;
   // Get the string length
   jvar := word(streamp^);
   inc(streamp, 2);
   // Check for the terminator
   if jvar >= $FFFF then break;
   // Bounds check...
   if streamp + jvar > streamend then break;
   // Get the string
   setlength(targetlabel^.stringlist[langindex].txt[ivar], jvar);
   move(streamp^, targetlabel^.stringlist[langindex].txt[ivar][1], jvar);
   inc(streamp, jvar);
   inc(numstrings);
   inc(ivar);
  until FALSE;

  inc(numlabels);
 end;

 // clean up
 if tempbuffy <> NIL then begin freemem(tempbuffy); tempbuffy := NIL; end;
 targetlabel := NIL;
 streamp := NIL; streamend := NIL;

 writelog('language ' + strdec(langindex) + ': ' + languagelist[langindex]);
 writelog(strdec(numstrings) + ' strings were loaded in ' + strdec(numlabels) + ' labels.');

 // Append newlabellist[] to script[], and re-sort
 if newlabelcount <> 0 then begin
  ivar := length(script);
  setlength(script, ivar + newlabelcount);
  // Since there are dynamic arrays involved, can't just "move" the memory
  for jvar := 0 to newlabelcount - 1 do
   script[ivar + jvar] := newlabellist[jvar];
  setlength(newlabellist, 0);
  SortScripts(FALSE);
 end;

 DecompressStringTable := TRUE;
end;

function ReadDATHeader(var dest : DATtype; var filu : file) : byte;
// Attempts to read the header of a .DAT resource pack. The file name must be
// preset in the given DATtype record, and the file handle should be just
// an unopened file.
// If failed, returns an error number, and an error message is placed in
// asman_errormsg, and the file handle won't be valid.
// If successful, returns 0. The header content is placed in the given
// DATtype record. The caller can continue reading the file contents using
// the same file handle. The caller is responsible for closing the file.
var ivar : dword;
begin
 ReadDATHeader := 0;
 while IOresult <> 0 do ; // flush

 // Open the DAT file, prepare to start reading resources
 assign(filu, dest.filenamu);
 filemode := 0; reset(filu, 1); // read-only
 ivar := IOresult;
 if ivar <> 0 then begin
  ReadDATHeader := byte(ivar);
  asman_errormsg := errortxt(ivar);
  exit;
 end;
 blockread(filu, ivar, 4);
 if ivar <> $CACABAAB then begin // SuperSakura signature
  close(filu);
  ReadDATHeader := 97;
  asman_errormsg := dest.filenamu + ' is missing SuperSakura DAT signature';
  exit;
 end;

 // ----- Reading Resources -----
 // HEADER (sig DWORD, header length DWORD, header data)
 ivar := 0;
 blockread(filu, ivar, 1);
 if ivar <> 3 then begin
  close(filu);
  ReadDATHeader := 97;
  asman_errormsg := 'Incorrect DAT format version: ' + strdec(ivar);
  exit;
 end;

 // Read the banner image offset.
 blockread(filu, dest.bannerofs, 4);

 // Read the project/parent name.
 blockread(filu, ivar, 1);
 setlength(dest.parentname, ivar);
 if ivar <> 0 then blockread(filu, dest.parentname[1], ivar);
 dest.parentname := lowercase(dest.parentname);
 // Extract the project name from the file name.
 dest.projectname := dest.filenamu;
 if lowercase(copy(dest.projectname, length(dest.projectname) - 3, 4)) = '.dat'
 then setlength(dest.projectname, length(dest.projectname) - 4);
 ivar := length(dest.projectname);
 while (ivar <> 0) and (dest.projectname[ivar] in ['/','\'] = FALSE) do dec(ivar);
 if ivar <> 0 then dest.projectname := copy(dest.projectname, ivar + 1, length(dest.projectname));
 dest.projectname := lowercase(dest.projectname);
 // If the project and parent are the same, no parent dependency.
 if dest.parentname = dest.projectname then dest.parentname := '';

 // Read the project description.
 blockread(filu, ivar, 1);
 setlength(dest.projectdesc, ivar);
 if ivar <> 0 then blockread(filu, dest.projectdesc[1], ivar);

 // Read the game version.
 blockread(filu, ivar, 1);
 setlength(dest.gameversion, ivar);
 if ivar <> 0 then blockread(filu, dest.gameversion[1], ivar);

 ivar := IOresult;
 if ivar <> 0 then begin
  ReadDATHeader := byte(ivar);
  asman_errormsg := errortxt(ivar);
 end;
end;

function LoadDAT(const filunamu : UTF8string) : byte;
// Attempts to load a .DAT resource pack. Returns 0 if successful, otherwise
// returns an error number and an error message is placed in asman_errormsg.
var filu : file;
    blockp : pointer;
    datindex, blockID, blocksize, ivar, jvar : dword;
    pnglistitems : dword;
    newPNGlist : array of PNGtype;
    PNGswap : PNGtype;
    PNGpoku : pPNGtype;
    swaps : string;
    opresult, revivethread : boolean;
begin
 LoadDAT := 0;
 opresult := TRUE;
 // just to eliminate compiler warnings
 swaps := ''; assign(filu, '');
 blocksize := 0; blockID := 0;

 asman_errormsg := '';
 if filunamu = '' then begin
  LoadDat := 98;
  asman_errormsg := 'LoadDAT: No filename given';
  exit;
 end;

 writelog('Loading dat ' + filunamu);

 // We have to shut down the cacher thread for a bit... this will require
 // moving stuff around in memory and we don't want access conflicts.
 revivethread := asman_threadalive;
 asman_endthread;

 // We keep track of which dat files are loaded in this list: add new entry
 // (if this dat file was already loaded earlier, we erase it later on)
 datindex := length(datlist);
 setlength(datlist, datindex + 1);
 datlist[datindex].filenamu := filunamu;

 // Read the header.
 LoadDAT := ReadDATHeader(datlist[datindex], filu);
 if LoadDAT <> 0 then begin
  // Failed, drop the dat from datlist and bail out.
  setlength(datlist, datindex);
  if revivethread then asman_beginthread;
  exit;
 end;

 setlength(newPNGlist, 400);
 PNGlistitems := 0;

 // Read the remaining data blocks.
 while filepos(filu) < filesize(filu) do begin

  blockread(filu, blockID, 4);
  blockread(filu, blocksize, 4);
  if filepos(filu) + blocksize > filesize(filu) then break;

  case blockID of
    // SCRIPTS
    $501E0BB0:
    begin
     getmem(blockp, blocksize);
     blockread(filu, blockp^, blocksize);
     opresult := DecompressScripts(blockp, blocksize);
     freemem(blockp); blockp := NIL;
     if opresult = FALSE then begin break; end;
    end;

    // STRING TABLE
    $511E0BB0:
    begin
     getmem(blockp, blocksize);
     blockread(filu, blockp^, blocksize);
     opresult := DecompressStringTable(blockp, blocksize);
     freemem(blockp); blockp := NIL;
     if opresult = FALSE then begin break; end;
    end;

    // MIDI MUSIC
    $521E0BB0:
    begin
     seek(filu, filepos(filu) + blocksize);
    end;

    // PNG IMAGE
    $531E0BB0:
    begin
     jvar := filepos(filu) + blocksize; // end of this block
     // Check if PNG by this name is already listed.
     blockread(filu, swaps[0], 1); // namu : string[31]
     blockread(filu, swaps[1], byte(swaps[0]));
     swaps := upcase(swaps);
     ivar := GetPNG(swaps);
     // PNG is already listed, overwrite it.
     if ivar <> 0 then
      PNGpoku := @PNGlist[ivar]
     else begin
      // Unlisted PNG, add to newPNGlist.
      if PNGlistitems >= dword(length(newPNGlist)) then setlength(newPNGlist, length(newPNGlist) + 100);
      PNGpoku := @newPNGlist[PNGlistitems];
      inc(PNGlistitems);
     end;
     // Read the metadata.
     PNGpoku^.namu := swaps;
     blockread(filu, PNGpoku^.origresx, sizeof(PNGtype.origresx));
     blockread(filu, PNGpoku^.origresy, sizeof(PNGtype.origresy));
     blockread(filu, PNGpoku^.origsizexp, sizeof(PNGtype.origsizexp));
     blockread(filu, PNGpoku^.origsizeyp, sizeof(PNGtype.origsizeyp));
     blockread(filu, PNGpoku^.origofsxp, sizeof(PNGtype.origofsxp));
     blockread(filu, PNGpoku^.origofsyp, sizeof(PNGtype.origofsyp));
     blockread(filu, PNGpoku^.framecount, sizeof(PNGtype.framecount));
     if PNGpoku^.framecount = 0 then PNGpoku^.framecount := 1;
     PNGpoku^.origframeheightp := PNGpoku^.origsizeyp div PNGpoku^.framecount;

     PNGpoku^.origsizex := (PNGpoku^.origsizexp shl 15 + PNGpoku^.origresx shr 1) div PNGpoku^.origresx;
     PNGpoku^.origsizey := (PNGpoku^.origframeheightp shl 15 + PNGpoku^.origresy shr 1) div PNGpoku^.origresy;
     if PNGpoku^.origofsxp >= 0
     then PNGpoku^.origofsx := (dword(PNGpoku^.origofsxp) shl 15 + PNGpoku^.origresx shr 1) div PNGpoku^.origresx
     else PNGpoku^.origofsx := -((dword(-PNGpoku^.origofsxp) shl 15 + PNGpoku^.origresx shr 1) div PNGpoku^.origresx);
     if PNGpoku^.origofsyp >= 0
     then PNGpoku^.origofsy := (dword(PNGpoku^.origofsyp) shl 15 + PNGpoku^.origresy shr 1) div PNGpoku^.origresy
     else PNGpoku^.origofsy := -((dword(-PNGpoku^.origofsyp) shl 15 + PNGpoku^.origresy shr 1) div PNGpoku^.origresy);

     blockread(filu, PNGpoku^.seqlen, sizeof(PNGtype.seqlen));
     setlength(PNGpoku^.sequence, PNGpoku^.seqlen);
     if PNGpoku^.seqlen <> 0 then
      blockread(filu, PNGpoku^.sequence[0], PNGpoku^.seqlen * 4);
     blockread(filu, PNGpoku^.bitflag, sizeof(PNGtype.bitflag));
     // Remember where to find the image data
     PNGpoku^.srcfilename := filunamu;
     PNGpoku^.srcfileofs := filepos(filu);
     PNGpoku^.srcfilesizu := jvar - filepos(filu);
     // Skip the rest
     seek(filu, jvar);
    end;

    // OGG SOUND
    $541E0BB0:
    begin
     seek(filu, filepos(filu) + blocksize);
    end;

    // Base resolution
    $5F1E0BB0:
    begin
     blockread(filu, asman_baseresx, 4);
     blockread(filu, asman_baseresy, 4);
    end;

    else begin
     asman_errormsg := 'Unknown block: $' + strhex(blockID);
     writelog(asman_errormsg);
     seek(filu, filepos(filu) + blocksize);
    end;
  end;
  ivar := IOresult; if ivar <> 0 then break;
 end;

 close(filu);
 // Ignore and flush IO errors, we'll just go with whatever we got.
 while IOresult <> 0 do ;

 // Add new PNG images into PNGlist[]
 // (Note that we don't check if the new PNGs exist in multiple copies in
 // this same DAT file; although technically possible, Recomp doesn't allow
 // it, but the DAT file may be hacked; if multiple copies exist, then they
 // all get loaded side by side into PNGlist, and exactly which PNG is
 // returned by GetPNG will depend on the length and content of PNGlist.)
 if PNGlistitems <> 0 then begin
  ivar := dword(length(PNGlist)) + PNGlistitems;
  setlength(PNGlist, ivar);

  while PNGlistitems <> 0 do begin
   dec(PNGlistitems);
   dec(ivar);
   PNGlist[ivar] := newPNGlist[PNGlistitems];
   setlength(PNGlist[ivar].sequence, PNGlist[ivar].seqlen);
   PNGlist[ivar].sequence := newPNGlist[PNGlistitems].sequence;
   //move(newPNGlist[0], PNGlist[ivar], PNGlistitems * sizeof(PNGtype));
  end;

  setlength(newPNGlist, 0);

  // Sort PNGlist[] - teleporting gnome
  ivar := 0; jvar := $FFFFFFFF;
  while ivar < dword(length(PNGlist)) do begin
   if (ivar = 0) or (PNGlist[ivar].namu >= PNGlist[ivar - 1].namu)
   then begin
    if jvar = $FFFFFFFF then inc(ivar) else begin ivar := jvar; jvar := $FFFFFFFF; end;
   end
   else begin
    PNGswap := PNGlist[ivar];
    PNGlist[ivar] := PNGlist[ivar - 1];
    PNGlist[ivar - 1] := PNGswap;
    jvar := ivar; dec(ivar);
   end;
  end;
 end;

 // Set up the gfxlist[] to accommodate the loaded PNGs, at minimum 1 slot
 ivar := length(gfxlist);
 jvar := length(PNGlist) * 2 + 1;
 if jvar > ivar then begin
  setlength(gfxlist, jvar);
  fillbyte(gfxlist[ivar], (jvar - ivar) * sizeof(gfxtype), 0);
 end;

 // Now it's safe for the cacher thread to get up again
 if revivethread then asman_beginthread;
 if opresult = FALSE then LoadDAT := 99;
end;

procedure UnloadDATs;
// Call this to dump all loaded assets if any, reset the asset arrays
// including list of DATs loaded to empty, and set up invalid null items in
// each array.
// This is called automatically once on asman startup, and at asman shutdown.
// You should call this explicitly only when loading a game state, if the new
// state has different DATs (eg. due to a mod change); afterward, load your
// new list of DATs.
// The caller MUST stop the cacher thread before calling this.
var ivar, jvar : dword;
begin
 writelog('Initing asset arrays to null');
 if length(script) <> 0 then
  for ivar := dword(high(script)) downto 0 do begin
   if script[ivar].code <> NIL then begin
    freemem(script[ivar].code); script[ivar].code := NIL;
   end;
   if length(script[ivar].stringlist) <> 0 then
   for jvar := dword(high(script[ivar].stringlist)) downto 0 do
    setlength(script[ivar].stringlist[jvar].txt, 0);
   setlength(script[ivar].stringlist, 0);
  end;

 if length(gfxlist) <> 0 then
  for ivar := dword(high(gfxlist)) downto 0 do begin
   if gfxlist[ivar].bitmap <> NIL then begin
    freemem(gfxlist[ivar].bitmap);
    gfxlist[ivar].bitmap := NIL;
   end;
  end;
 asman_gfxmemcount := 0;
 asman_queueitems := 0;

 if length(PNGlist) <> 0 then
  for ivar := dword(high(PNGlist)) downto 0 do
   setlength(PNGlist[ivar].sequence, 0);

 // Release the arrays entirely to discourage implicit resizing
 setlength(script, 0);
 setlength(gfxlist, 0);
 setlength(PNGlist, 0);
 setlength(DATlist, 0);
 setlength(languagelist, 0);

 // Now set up a null item in each array. (This ensures the array is never
 // empty, which saves a safety check during Get* seeks, and allows returning
 // index 0 if there was an error.)
 setlength(script, 1);
 setlength(gfxlist, 1);
 setlength(PNGlist, 1);
 setlength(DATlist, 1);

 fillbyte(script[0], sizeof(scripttype), 0);
 fillbyte(gfxlist[0], sizeof(gfxtype), 0);
 fillbyte(PNGlist[0], sizeof(PNGtype), 0);
 fillbyte(DATlist[0], sizeof(DATtype), 0);
 asman_gfxwriteslot := 0;

 gfxlist[0].namu := chr(0);

 // Init the global empty label for duplicable strings
 setlength(script[0].stringlist, 1);

 // Set up the base language
 setlength(languagelist, 1);
 languagelist[0] := 'undefined';
end;

// ------------------------------------------------------------------

function asman_thread(turhuus : pointer) : ptrint;
// This is the background worker thread. The input pointer and output ptrint
// are not used, but FPC requires they be defined. Ignore them.
//
// The main program should not modify the gfxlist[] array on its own. All
// write access goes through this thread; read access is free, though.
//
// Whenever the thread runs out of things to do, it goes into a waitstate.
// Use asman_pokethread to wake the thread.
// While awake, the thread will continuously check the asman_* variables,
// where a non-zero value means some action is required. To set the
// variables, use the interlocked* commands.
// Assets to be loaded need to be placed in the asman_queue. While awake,
// the thread will pick asset requests from the queue and load them.
//
// Queue slots are considered free until the assettype is non-zero. When
// adding an item in the queue, first fill out its other characteristics and
// only set the assettype as the last thing. When a queue slot has been
// processed, this thread will set the assettype to zero.

// cacher thread:
// - while asman_queueitems <> 0:
//    + iterate over gfxlist[] endlessly, check asman_primeslot between each
//    + if slot state = asman_cachemark, load the graphic, set to state-3
//    + else if slot state in [1,2], set state = 0
//    + else if slot = asman_primeslot, sleep(0)

var workslot : dword;

  procedure DoSlot(slotnum : dword);
  begin
   // Load the graphic for this slot!
   with gfxlist[slotnum] do writelog('doslot ' + strdec(slotnum) + ' namu=' + namu + ' cachestate=' + strdec(cachestate) + ' sacred=' + strdec(byte(sacred)) + ' prime=' + strdec(asman_primeslot));
   LoadGFX(slotnum);
   // Another queueable item is belong to us!
  end;

begin
 asman_thread := turhuus - turhuus; // to eliminate compiler warnings

 // remain unobtrusive, humility is key to user satisfaction
 threadsetpriority(asman_ThreadID, -2); // lowest
 workslot := 1;

 repeat
  // If there's nothing queued and we're not shutting down, enter a waitstate
  while (asman_primeslot = 0) and (asman_queueitems = 0)
  and (asman_quitmsg = 0) do begin
   RTLEventWaitFor(asman_event);
   RTLEventResetEvent(asman_event);
  end;
  if asman_quitmsg <> 0 then break;

  // As long as there is work to be done and we're not quitting, we keep
  // iterating over gfxlist[] looking for stuff to cache.
  //writelog('===asman_thread: queueitems=' + strdec(asman_queueitems) + ' quitmsg=' + strdec(asman_quitmsg));
  while (asman_primeslot <> 0) or (asman_queueitems <> 0) do begin
   if asman_quitmsg <> 0 then break;
   // Check the prime slot for emergency work regularly
   if asman_primeslot <> 0 then begin
    if asman_primeslot >= dword(length(gfxlist)) then begin
     writelog('[!] asman_thread: primeslot out of bounds ' + strdec(asman_primeslot) + '/' + strdec(dword(length(gfxlist))));
    end else
    if gfxlist[asman_primeslot].cachestate = asman_cachemark then DoSlot(asman_primeslot);
    asman_primeslot := 0;
    RTLEventSetEvent(asman_jobdone); // let the main thread know we're done
    if asman_quitmsg <> 0 then break;
   end;

   // Next slot...
   inc(workslot);
   if workslot >= dword(length(gfxlist)) then workslot := 1;
   // If we found something that needs to be cached, get it done
   if gfxlist[workslot].cachestate = asman_cachemark then DoSlot(workslot)
   // The other non-mark state, however, means the cache request in this slot
   // has become out of date and can be scrapped.
   else if gfxlist[workslot].cachestate in [1,2] then begin
    gfxlist[workslot].cachestate := 0;
    interlockeddecrement(asman_queueitems);
   end;

   if asman_quitmsg = 0 then ThreadSwitch; // kindly give up our timeslice
  end;
 until asman_quitmsg <> 0;
 RTLEventSetEvent(asman_threadendevent);
 EndThread(0); // return 0 for a successful exit
end;

// ------------------------------------------------------------------

initialization

 // Start logging
 setlength(asman_log, 100);
 asman_logindex := 0;
 writelog('---===--- supersakura_asman ---===---');

 // Init variables
 asman_ThreadID := 0; asman_threadalive := FALSE;
 asman_rescaler := @mcg_ScaleBitmap; // default scaler is the fastest
 asman_gfxmemlimit := 16777216; asman_gfxmemcount := 0;
 asman_primeslot := 0; asman_cachemark := 1;
 asman_baseresx := 640; asman_baseresy := 480;
 UnloadDATs; // inits asset arrays, sets up null items

// ------------------------------------------------------------------

finalization

 writelog('mcsassm is exiting');
 if (erroraddr <> NIL) or (exitcode <> 0) then begin
  writelog('mcsassm exitcode ' + strdec(exitcode));
 end;
 asman_endthread;
 UnloadDATs;
end.
