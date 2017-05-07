unit minicrt;
{                                                                           }
{ MiniCrt, a small console-interaction unit that works like the Crt unit.   }
{ Compiles with FPC 3.0.2 on Windows/Linux.                                 }
{ CC0, 2017 :: Kirinn Bunnylin / MoonCore :: Use freely for anything ever!  }
{                                                                           }
{ Main differences:                                                         }
{ - Smaller code, more comments; more maintainable, less robust             }
{ - Console size querying and size change callback                          }
{ - No mouse or sound functions, no subwindows, no line editing functions   }
{ - Expects UTF-8 input and output everywhere                               }
{ - ReadKey returns a UTF-8 string                                          }
{                                                                           }
{ For a more robust solution, consider FPC's rtl-console/keyboard unit.     }
{                                                                           }

{$mode fpc}
{$codepage UTF8}
{$inline on}

// You can use normal Write/WriteLn to output UTF-8 text. You may want to
// include "$codepage UTF8" in your program's defines.
// NOTE: the Write function in FPC 3.0.2 prints direct string literals and
// UTF-8 text from codepageless shortstrings correctly under Windows, but
// fails to print UTF8strings correctly. Use this unit's UTF8Write for such
// cases.
// NOTE: the plain linux tty does not yet display CJK without tweaking.
//
// ReadKey returns a UTF8string that contains a UTF8 code of 1-4 bytes.
// If any modifier keys apply to the keypress, the UTF8 code will be prefixed
// with a null byte and a modifier byte, a combination of:
//   4 = CTRL
//   2 = ALT
//   1 = SHIFT
// NOTE: The Ctrl+Alt+key combination is the same as AltGr+key, which is used
// in some keyboard layouts to produce common special characters. For
// simplicity, ReadKey does not see the Ctrl+Alt combination.
//
// Extended keys are saved as UTF-8 codes in the Unicode private use area:
//   EE 90 8C (E40C) = numpad center
//   EE 90 A1 (E421) = page up
//   EE 90 A2 (E422) = page down
//   EE 90 A3 (E423) = end
//   EE 90 A4 (E424) = home
//   EE 90 A5 (E425) = cursor left
//   EE 90 A6 (E426) = cursor up
//   EE 90 A7 (E427) = cursor right
//   EE 90 A8 (E428) = cursor down
//   EE 90 AD (E42D) = insert
//   EE 90 AE (E42E) = delete
//   EE 91 B0 .. EE 91 BB (E470..E47B) = F1..F12

// Not all key combinations are equally available cross-platform. Don't even
// try to use the following:
//   Ctrl/Alt/Shift + Esc/Tab/Fn/Insert/Delete
//   PrintScr-SysRq key
//   Pause-Break key
//   Num lock, caps lock, scroll lock
//   Windows/Super/Menu key
//   Ctrl + 0..9 are partially unsupported on all terminals
//   Shift-F9..Shift-F12 are ignored in the plain linux tty
//   Shift-F1..Shift-F12 produce wrong, conflicting codes in urxvt
//   Ctrl+Alt+Fn and Alt+Fn tend to be bound to various OS functions
//   Ctrl-F1..Ctrl-F12 are ignored in linux tty
//   Ctrl + ,.- are not ok by lxterminal, qterminal, urxvt, linux tty
//   Numpad 5 is ignored by qterminal, urxvt; doesn't mix well with Ctrl/Alt
//   Page Down has a conflicting code on FreeBSD with numpad 5 in linux tty?
//   Shift-insert is used for pasting, so it won't produce a keypress
//   Ctrl/Shift + delete is incorrect in linux tty
//   Ctrl-insert is incorrect in linux tty and ignored by lxterminal
//   Ctrl/Alt/Shift + cursor keys are incorrect or OS functions in linux tty
//   Shift + PageUp/PageDown are used to scroll terminal buffers
//   Shift + Home/End are incorrect in linux tty, and scroll lx/qterminal
//   Ctrl/Alt + PageUp/PageDown are incorrect in qterminal
//   Ctrl/Alt + Home/End are incorrect in lxterminal
//   Ctrl/Alt + Ins/Del/Home/End/PgUp/PgDn are incorrect in linux tty
//   Ctrl+Alt + A..Z only work on Linux (except C, S, V in urxvt)
//   Ctrl+Shift + A..Z only work on Windows

// What does appear to work universally?
//   Cursor keys and numpad directions
//   Ins/Del/Home/End/PgUp/PgDn
//   All normally typeable UTF-8 characters
//   space, enter, tab, shift-tab, backspace
//   ESC, F1..F12
//   Ctrl + A..Z except H..J, M
//   Alt + A..Z (unless a terminal window's own menus intercept it)
//     (on xterm, altSendsEscape must be true)
//   Alt + 0..9

// ------------------------------------------------------------------
interface

{$ifdef WINDOWS}

uses windows;

const crtpalette : array[0..15] of packed record r, g, b : byte; end = (
(r: 0; g: 0; b: 0),
(r: 0; g: 0; b: 128),
(r: 0; g: 128; b: 0),
(r: 0; g: 128; b: 128),
(r: 128; g: 0; b: 0),
(r: 128; g: 0; b: 128),
(r: 128; g: 128; b: 0),
(r: 192; g: 192; b: 192),
(r: 128; g: 128; b: 128),
(r: 0; g: 0; b: 255),
(r: 0; g: 255; b: 0),
(r: 0; g: 255; b: 255),
(r: 255; g: 0; b: 0),
(r: 255; g: 0; b: 255),
(r: 255; g: 255; b: 0),
(r: 255; g: 255; b: 255));

// Windows-specific wrapper for WriteConsoleOutputW, the only way to do fast
// console output.
procedure CrtWriteConOut(const srcp : pointer; const sx, sy, x1, y1, x2, y2 : dword); inline;

{$else}

uses unix, baseunix, termio;

// Unix terminal colors have the red and blue components switched compared to
// legacy CGA. A translation table seems the fastest solution.
const termtextcolor : array[0..15] of string[3] =
('30','34','32','36','31','35','33','37','90','94','92','96','91','95','93','97');
const termbkgcolor : array[0..15] of string[3] =
('40','44','42','46','41','45','43','47','100','104','102','106','101','105','103','107');

// The XTerm palette is a good linux default. Call GetConsolePalette to ask
// the terminal for the precise values, but some terminals don't support that
// command (qterminal), or respond with incorrect RGB values (lxterminal).
const crtpalette : array[0..15] of packed record r, g, b : byte; end = (
(r: 0; g: 0; b: 0),
(r: 0; g: 0; b: $CD),
(r: 0; g: $CD; b: 0),
(r: 0; g: $CD; b: $CD),
(r: $EE; g: 0; b: 0),
(r: $CD; g: 0; b: $CD),
(r: $CD; g: $CD; b: 0),
(r: $E5; g: $E5; b: $E5),
(r: $7F; g: $7F; b: $7F),
(r: 0; g: 0; b: $FF),
(r: 0; g: $FF; b: 0),
(r: 0; g: $FF; b: $FF),
(r: $FF; g: $5C; b: $5C),
(r: $FF; g: 0; b: $FF),
(r: $FF; g: $FF; b: 0),
(r: $FF; g: $FF; b: $FF));

{$endif}

// Assign a callback procedure to this variable during your program startup
// to get console size change notifications.
var NewConSizeCallback : procedure(sizex, sizey : dword);

procedure Delay(msec : dword); inline;
function GetMsecTime : ptruint; inline;
procedure GotoXY(x, y : dword); inline;
procedure ClrScr;
procedure SetColor(color : word); inline;
function KeyPressed : boolean;
function ReadKey : UTF8string;
procedure UTF8Write(const outstr : UTF8string); inline;
procedure CrtSetTitle(const newtitle : UTF8string); inline;
procedure CrtShowCursor(visible : boolean); inline;
procedure GetConsoleSize(var sizex, sizey : dword);
procedure GetConsolePalette;
procedure RunTest;

// ------------------------------------------------------------------
implementation

// Keypresses through stdin are fed into this ring buffer. They can be
// fetched one at a time by calling ReadKey.
var inputbuf : array[0..31] of UTF8string;
    inputbufreadindex, inputbufwriteindex : dword;

{$ifdef WINDOWS}
var StdInH, StdOutH : HANDLE;
    oldcodepageout : dword;
    concursorinfo : CONSOLE_CURSOR_INFO;
{$else}

var StdInDescriptor : tfdSet;
    TermSettings : termios;
    OldSigAction : SigActionRec;
    filecontrolflags : ptrint;
    termsizex, termsizey : dword; // internal only, use GetConsoleSize
    crtpalresponse : dword;

// Keyboard input from unix terminals is fubar. The below table and
// procedures are used to extract whatever data we can.
type keyseqtype = record
       i : string[9];
       o : string[5];
     end;

// This table must be sorted by i-sequence, so a binary search is possible.
// A possibly more comprehensive list of sequences is available as part of
// FPC's rtl-console/keyboard.pp.
const keyseqlist : array[0..278] of keyseqtype = (
(i:#27'OP'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B0)), // Alt-F1 (xterm)
(i:#27'OQ'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B1)), // Alt-F2 (xterm)
(i:#27'OR'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B2)), // Alt-F3 (xterm)
(i:#27'OS'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (xterm)
(i:#27'Oa'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A6)), // Alt-up (?)
(i:#27'Ob'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A8)), // Alt-down (?)
(i:#27'Oc'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A7)), // Alt-right (?)
(i:#27'Od'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A5)), // Alt-left (?)
(i:#27'Ol'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B7)), // Alt-F8 (xterm)
(i:#27'Ot'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B4)), // Alt-F5 (xterm)
(i:#27'Ou'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B5)), // Alt-F6 (xterm)
(i:#27'Ov'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B6)), // Alt-F7 (xterm)
(i:#27'Ow'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B8)), // Alt-F9 (xterm)
(i:#27'Ox'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B9)), // Alt-F10 (xterm)
(i:#27'Oy'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($BA)), // Alt-F11 (xterm)
(i:#27'Oz'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($BB)), // Alt-F12 (xterm)
(i:#27'[11~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B0)), // Alt-F1 (rxvt)
(i:#27'[12~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B1)), // Alt-F2 (rxvt)
(i:#27'[13~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B2)), // Alt-F3 (rxvt)
(i:#27'[14~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (rxvt)
(i:#27'[15~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B4)), // Alt-F5 (rxvt)
(i:#27'[17~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B5)), // Alt-F6 (rxvt)
(i:#27'[18~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B6)), // Alt-F7 (rxvt)
(i:#27'[19~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B7)), // Alt-F8 (rxvt)
(i:#27'[20~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B8)), // Alt-F9 (rxvt)
(i:#27'[21~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B9)), // Alt-F10 (rxvt)
(i:#27'[23~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($BA)), // Alt-F11 (rxvt)
(i:#27'[24~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($BB)), // Alt-F12 (rxvt)
(i:#27'[2~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($AD)), // Alt-insert (rxvt)
(i:#27'[3~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($AE)), // Alt-delete (rxvt)
(i:#27'[5~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A1)), // Alt-pageup (rxvt)
(i:#27'[6~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A2)), // Alt-pagedown (rxvt)
(i:#27'[7~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A4)), // Alt-home (rxvt)
(i:#27'[8~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A3)), // Alt-end (rxvt)
(i:#27'[A'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A6)), // Alt-up (rxvt)
(i:#27'[B'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A8)), // Alt-down (rxvt)
(i:#27'[C'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A7)), // Alt-right (rxvt)
(i:#27'[D'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A5)), // Alt-left (rxvt)
(i:#27'[[A'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B0)), // Alt-F1 (?)
(i:#27'[[B'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B1)), // Alt-F2 (?)
(i:#27'[[C'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B2)), // Alt-F3 (?)
(i:#27'[[D'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (?)
(i:#27'[[E'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (?)
(i:'O1;2P'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B0)), // Shift-F1 (lxterminal)
(i:'O1;2Q'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B1)), // Shift-F2 (lxterminal)
(i:'O1;2R'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B2)), // Shift-F3 (lxterminal)
(i:'O1;2S'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B3)), // Shift-F4 (lxterminal)
(i:'O1;3P'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B0)), // Alt-F1 (lxterminal)
(i:'O1;3Q'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B1)), // Alt-F2 (lxterminal)
(i:'O1;3R'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B2)), // Alt-F3 (lxterminal)
(i:'O1;3S'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (lxterminal)
(i:'O1;5P'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B0)), // Ctrl-F1 (lxterminal)
(i:'O1;5Q'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B1)), // Ctrl-F2 (lxterminal)
(i:'O1;5R'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B2)), // Ctrl-F3 (lxterminal)
(i:'O1;5S'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B3)), // Ctrl-F4 (lxterminal)
(i:'O2M'; o:chr(0)+chr(1)+chr($D)), // Shift-numpad-enter (xterm)
(i:'O2P'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B0)), // Shift-F1 (konsole/xterm)
(i:'O2Q'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B1)), // Shift-F2 (konsole/xterm)
(i:'O2R'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B2)), // Shift-F3 (konsole/xterm)
(i:'O2S'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B3)), // Shift-F4 (konsole/xterm)
(i:'O2j'; o:chr(0)+chr(1)+chr($2A)), // Shift-numpad-mul (xterm)
(i:'O2l'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($AE)), // Shift-numpad-delete (xterm)
(i:'O2o'; o:chr(0)+chr(1)+chr($2F)), // Shift-numpad-div (xterm)
(i:'O2p'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($AD)), // Shift-numpad-insert (xterm)
(i:'O2q'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A3)), // Shift-numpad1 (xterm)
(i:'O2r'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A8)), // Shift-numpad2 (xterm)
(i:'O2s'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A2)), // Shift-numpad3 (xterm)
(i:'O2t'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A5)), // Shift-numpad4 (xterm)
(i:'O2u'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($8C)), // Shift-numpad5 (xterm)
(i:'O2v'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A7)), // Shift-numpad6 (xterm)
(i:'O2w'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A4)), // Shift-numpad7 (xterm)
(i:'O2x'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A6)), // Shift-numpad8 (xterm)
(i:'O2y'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A1)), // Shift-numpad9 (xterm)
(i:'O3M'; o:chr(0)+chr(2)+chr($D)), // Alt-numpad-enter (xterm)
(i:'O3P'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B0)), // Alt-F1 (xterm)
(i:'O3Q'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B1)), // Alt-F2 (xterm)
(i:'O3R'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B2)), // Alt-F3 (xterm)
(i:'O3S'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (xterm)
(i:'O3j'; o:chr(0)+chr(2)+chr($2A)), // Alt-numpad-mul (xterm)
(i:'O3k'; o:chr(0)+chr(2)+chr($2B)), // Alt-numpad-plus (xterm)
(i:'O3m'; o:chr(0)+chr(2)+chr($2D)), // Alt-numpad-minus (xterm)
(i:'O3o'; o:chr(0)+chr(2)+chr($2F)), // Alt-numpad-div (xterm)
(i:'O5M'; o:chr(0)+chr(4)+chr($A)), // Ctrl-numpad-enter (xterm)
(i:'O5P'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B0)), // Ctrl-F1 (konsole/xterm)
(i:'O5Q'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B1)), // Ctrl-F2 (konsole/xterm)
(i:'O5R'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B2)), // Ctrl-F3 (konsole/xterm)
(i:'O5S'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B3)), // Ctrl-F4 (konsole/xterm)
(i:'O5j'; o:chr(0)+chr(4)+chr($2A)), // Ctrl-numpad-mul (xterm)
(i:'O5k'; o:chr(0)+chr(4)+chr($2B)), // Ctrl-numpad-plus (xterm)
(i:'O5m'; o:chr(0)+chr(4)+chr($2D)), // Ctrl-numpad-minus (xterm)
(i:'O5o'; o:chr(0)+chr(4)+chr($2F)), // Ctrl-numpad-div (xterm)
(i:'OA'; o:chr($EE)+chr($90)+chr($A6)), // up (xterm)
(i:'OB'; o:chr($EE)+chr($90)+chr($A8)), // down (xterm)
(i:'OC'; o:chr($EE)+chr($90)+chr($A7)), // right (xterm)
(i:'OD'; o:chr($EE)+chr($90)+chr($A5)), // left (xterm)
(i:'OE'; o:chr($EE)+chr($90)+chr($8C)), // numpad5 (xterm)
(i:'OF'; o:chr($EE)+chr($90)+chr($A3)), // end (xterm)
(i:'OH'; o:chr($EE)+chr($90)+chr($A4)), // home (xterm)
(i:'OM'; o:chr($D)), // numpad-enter (xterm)
(i:'OP'; o:chr($EE)+chr($91)+chr($B0)), // F1 (vt100/gnome/konsole)
(i:'OQ'; o:chr($EE)+chr($91)+chr($B1)), // F2 (vt100/gnome/konsole)
(i:'OR'; o:chr($EE)+chr($91)+chr($B2)), // F3 (vt100/gnome/konsole)
(i:'OS'; o:chr($EE)+chr($91)+chr($B3)), // F4 (vt100/gnome/konsole)
(i:'Oa'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A6)), // Ctrl-up (rxvt)
(i:'Ob'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A8)), // Ctrl-down (rxvt)
(i:'Oc'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A7)), // Ctrl-right (rxvt)
(i:'Od'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A5)), // Ctrl-left (rxvt)
(i:'Oj'; o:chr($2A)), // numpad-mul (xterm)
(i:'Ok'; o:chr($2B)), // numpad-plus (xterm)
(i:'Ol'; o:chr($EE)+chr($91)+chr($B7)), // F8 (vt100)
(i:'Om'; o:chr($2D)), // numpad-minus (xterm)
(i:'Oo'; o:chr($2F)), // numpad-div (xterm)
(i:'Op'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($AD)), // shift-numpad-insert (rxvt)
(i:'Ot'; o:chr($EE)+chr($91)+chr($B4)), // F5 (vt100)
(i:'Ou'; o:chr($EE)+chr($91)+chr($B5)), // F6 (vt100)
(i:'Ov'; o:chr($EE)+chr($91)+chr($B6)), // F7 (vt100)
(i:'Ow'; o:chr($EE)+chr($91)+chr($B8)), // F9 (vt100)
(i:'Ox'; o:chr($EE)+chr($91)+chr($B9)), // F10 (vt100)
(i:'Oy'; o:chr($EE)+chr($91)+chr($BA)), // F11 (vt100)
(i:'Oz'; o:chr($EE)+chr($91)+chr($BB)), // F12 (vt100)
(i:'[11;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B0)), // Shift-F1 (konsole as vt420pc)
(i:'[11;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B0)), // Ctrl-F1
(i:'[11^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B0)), // Ctrl-F1 (rxvt)
(i:'[11~'; o:chr($EE)+chr($91)+chr($B0)), // F1 (Eterm/rxvt)
(i:'[12;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B1)), // Shift-F2 (konsole as vt420pc)
(i:'[12;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B1)), // Ctrl-F2
(i:'[12^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B1)), // Ctrl-F2 (rxvt)
(i:'[12~'; o:chr($EE)+chr($91)+chr($B1)), // F2 (Eterm/rxvt)
(i:'[13;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B2)), // Shift-F3 (konsole as vt420pc)
(i:'[13;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B2)), // Ctrl-F3
(i:'[13^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B2)), // Ctrl-F3 (rxvt)
(i:'[13~'; o:chr($EE)+chr($91)+chr($B2)), // F3 (Eterm/rxvt)
(i:'[14;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B3)), // Shift-F4 (konsole as vt420pc)
(i:'[14;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B3)), // Ctrl-F4
(i:'[14^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B3)), // Ctrl-F4 (rxvt)
(i:'[14~'; o:chr($EE)+chr($91)+chr($B3)), // F4 (Eterm/rxvt)
(i:'[15;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B4)), // Shift-F5 (xterm)
(i:'[15;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B4)), // Alt-F5 (xterm)
(i:'[15;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B4)), // Ctrl-F5 (xterm)
(i:'[15^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B4)), // Ctrl-F5 (rxvt)
(i:'[15~'; o:chr($EE)+chr($91)+chr($B4)), // F5 (xterm/Eterm/gnome/rxvt)
(i:'[17;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B5)), // Shift-F6 (xterm)
(i:'[17;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B5)), // Alt-F6 (xterm)
(i:'[17;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B5)), // Ctrl-F6 (xterm)
(i:'[17^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B5)), // Ctrl-F6 (rxvt)
(i:'[17~'; o:chr($EE)+chr($91)+chr($B5)), // F6 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[18;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B6)), // Shift-F7 (xterm)
(i:'[18;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B6)), // Alt-F7 (xterm)
(i:'[18;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B6)), // Ctrl-F7 (xterm)
(i:'[18^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B6)), // Ctrl-F7 (rxvt)
(i:'[18~'; o:chr($EE)+chr($91)+chr($B6)), // F7 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[19;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B7)), // Shift-F8 (xterm)
(i:'[19;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B7)), // Alt-F8 (xterm)
(i:'[19;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B7)), // Ctrl-F8 (xterm)
(i:'[19^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B7)), // Ctrl-F8 (rxvt)
(i:'[19~'; o:chr($EE)+chr($91)+chr($B7)), // F8 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[1;2A'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A6)), // Shift-up (xterm)
(i:'[1;2B'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A8)), // Shift-down (xterm)
(i:'[1;2C'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A7)), // Shift-right (xterm)
(i:'[1;2D'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A5)), // Shift-left (xterm)
(i:'[1;2F'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A3)), // Shift-end (xterm)
(i:'[1;2H'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A4)), // Shift-home (xterm)
(i:'[1;2P'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B0)), // Shift-F1 (xterm/gnome3)
(i:'[1;2Q'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B1)), // Shift-F2 (xterm/gnome3)
(i:'[1;2R'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B2)), // Shift-F3 (xterm/gnome3)
(i:'[1;2S'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B3)), // Shift-F4 (xterm/gnome3)
(i:'[1;3A'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A6)), // Alt-up (xterm)
(i:'[1;3B'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A8)), // Alt-down (xterm)
(i:'[1;3C'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A7)), // Alt-right (xterm)
(i:'[1;3D'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A5)), // Alt-left (xterm)
(i:'[1;3E'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($8C)), // Alt-numpad5 (xterm)
(i:'[1;3F'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A3)), // Alt-end (xterm)
(i:'[1;3H'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A4)), // Alt-home (xterm)
(i:'[1;3P'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B0)), // Alt-F1 (xterm/gnome3)
(i:'[1;3Q'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B1)), // Alt-F2 (xterm/gnome3)
(i:'[1;3R'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B2)), // Alt-F3 (xterm/gnome3)
(i:'[1;3S'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B3)), // Alt-F4 (xterm/gnome3)
(i:'[1;5A'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A6)), // Ctrl-up (xterm)
(i:'[1;5B'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A8)), // Ctrl-down (xterm)
(i:'[1;5C'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A7)), // Ctrl-right (xterm)
(i:'[1;5D'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A5)), // Ctrl-left (xterm)
(i:'[1;5E'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($8C)), // Ctrl-numpad5 (xterm)
(i:'[1;5F'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A3)), // Ctrl-end (xterm)
(i:'[1;5H'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A4)), // Ctrl-home (xterm)
(i:'[1;5P'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B0)), // Ctrl-F1 (xterm/gnome3)
(i:'[1;5Q'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B1)), // Ctrl-F2 (xterm/gnome3)
(i:'[1;5R'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B2)), // Ctrl-F3 (xterm/gnome3)
(i:'[1;5S'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B3)), // Ctrl-F4 (xterm/gnome3)
(i:'[1~'; o:chr($EE)+chr($90)+chr($A4)), // home (linux)
(i:'[20;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B8)), // Shift-F9 (xterm)
(i:'[20;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B8)), // Alt-F9 (xterm)
(i:'[20;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B8)), // Ctrl-F9 (xterm)
(i:'[20^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B8)), // Ctrl-F9 (rxvt)
(i:'[20~'; o:chr($EE)+chr($91)+chr($B8)), // F9 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[21;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B9)), // Shift-F10 (xterm)
(i:'[21;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($B9)), // Alt-F10 (xterm)
(i:'[21;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B9)), // Ctrl-F10 (xterm)
(i:'[21^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($B9)), // Ctrl-F10 (rxvt)
(i:'[21~'; o:chr($EE)+chr($91)+chr($B9)), // F10 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[23$'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($BA)), // Shift-F11 (rxvt)
(i:'[23;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($BA)), // Shift-F11 (xterm)
(i:'[23;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($BA)), // Alt-F11 (xterm)
(i:'[23;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($BA)), // Ctrl-F11 (xterm)
(i:'[23^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($BA)), // Ctrl-F11 (rxvt)
(i:'[23~'; o:chr($EE)+chr($91)+chr($BA)), // F11 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[24$'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($BB)), // Shift-F12 (rxvt)
(i:'[24;2~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($BB)), // Shift-F12 (xterm)
(i:'[24;3~'; o:chr(0)+chr(2)+chr($EE)+chr($91)+chr($BB)), // Alt-F12 (xterm)
(i:'[24;5~'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($BB)), // Ctrl-F12 (xterm)
(i:'[24^'; o:chr(0)+chr(4)+chr($EE)+chr($91)+chr($BB)), // Ctrl-F12 (rxvt)
(i:'[24~'; o:chr($EE)+chr($91)+chr($BB)), // F12 (linux/xterm/Eterm/konsole/gnome/rxvt)
(i:'[25~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B0)), // Shift-F1 (linux)
(i:'[26~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B1)), // Shift-F2 (linux)
(i:'[28~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B2)), // Shift-F3 (linux)
(i:'[29~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B3)), // Shift-F4 (linux)
(i:'[2;3~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($AD)), // Alt-insert (xterm)
(i:'[2;5~'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($AD)), // Ctrl-insert (xterm)
(i:'[2^'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($AD)), // Ctrl-insert (rxvt)
(i:'[2~'; o:chr($EE)+chr($90)+chr($AD)), // insert (linux/xterm/Eterm/rxvt)
(i:'[3$'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($AE)), // Shift-delete (rxvt)
(i:'[31~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B4)), // Shift-F5 (linux)
(i:'[32~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B5)), // Shift-F6 (linux)
(i:'[33~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B6)), // Shift-F7 (linux)
(i:'[34~'; o:chr(0)+chr(1)+chr($EE)+chr($91)+chr($B7)), // Shift-F8 (linux)
(i:'[3;2~'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($AE)), // Shift-delete (xterm/konsole)
(i:'[3;3~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($AE)), // Alt-delete (xterm)
(i:'[3;5~'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($AE)), // Ctrl-delete (xterm)
(i:'[3^'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($AE)), // Ctrl-delete (rxvt)
(i:'[3~'; o:chr($EE)+chr($90)+chr($AE)), // delete (linux/xterm/Eterm/rxvt)
(i:'[4~'; o:chr($EE)+chr($90)+chr($A3)), // end (linux/Eterm)
(i:'[5;3~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A1)), // Alt-pageup (xterm)
(i:'[5;5~'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A1)), // Ctrl-pageup (xterm)
(i:'[5^'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A1)), // Ctrl-pageup (rxvt)
(i:'[5~'; o:chr($EE)+chr($90)+chr($A1)), // page up (linux/xterm/Eterm/rxvt)
(i:'[6;3~'; o:chr(0)+chr(2)+chr($EE)+chr($90)+chr($A2)), // Alt-pagedown (xterm)
(i:'[6;5~'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A2)), // Ctrl-pagedown (xterm)
(i:'[6^'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A2)), // Ctrl-pagedown (rxvt)
(i:'[6~'; o:chr($EE)+chr($90)+chr($A2)), // page down (linux/xterm/Eterm/rxvt)
(i:'[7$'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A4)), // Shift-home (rxvt)
(i:'[7^'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A4)), // Ctrl-home (rxvt)
(i:'[7~'; o:chr($EE)+chr($90)+chr($A4)), // home (Eterm/rxvt)
(i:'[8$'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A3)), // Shift-end (rxvt)
(i:'[8^'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A3)), // Ctrl-end (rxvt)
(i:'[8~'; o:chr($EE)+chr($90)+chr($A3)), // end (rxvt)
(i:'[A'; o:chr($EE)+chr($90)+chr($A6)), // up (linux/xterm/FreeBSD/rxvt)
(i:'[B'; o:chr($EE)+chr($90)+chr($A8)), // down (linux/xterm/FreeBSD/rxvt)
(i:'[C'; o:chr($EE)+chr($90)+chr($A7)), // right (linux/xterm/FreeBSD/rxvt)
(i:'[D'; o:chr($EE)+chr($90)+chr($A5)), // left (linux/xterm/FreeBSD/rxvt)
(i:'[E'; o:chr($EE)+chr($90)+chr($8C)), // numpad 5 (xterm/lxterminal)
(i:'[F'; o:chr($EE)+chr($90)+chr($A3)), // end (xterm/FreeBSD)
(i:'[G'; o:chr($EE)+chr($90)+chr($8C)), // numpad 5 (linux)
(i:'[H'; o:chr($EE)+chr($90)+chr($A4)), // home (xterm/FreeBSD)
(i:'[I'; o:chr($EE)+chr($90)+chr($A1)), // page up (FreeBSD)
(i:'[M'; o:chr($EE)+chr($91)+chr($B0)), // F1 (FreeBSD)
(i:'[N'; o:chr($EE)+chr($91)+chr($B1)), // F2 (FreeBSD)
(i:'[O'; o:chr($EE)+chr($91)+chr($B2)), // F3 (FreeBSD)
(i:'[Oa'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A6)), // Ctrl-up (rxvt)
(i:'[Ob'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A8)), // Ctrl-down (rxvt)
(i:'[Oc'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A7)), // Ctrl-right (rxvt)
(i:'[Od'; o:chr(0)+chr(4)+chr($EE)+chr($90)+chr($A5)), // Ctrl-left (rxvt)
(i:'[P'; o:chr($EE)+chr($91)+chr($B3)), // F4 (FreeBSD)
(i:'[Q'; o:chr($EE)+chr($91)+chr($B4)), // F5 (FreeBSD)
(i:'[R'; o:chr($EE)+chr($91)+chr($B5)), // F6 (FreeBSD)
(i:'[S'; o:chr($EE)+chr($91)+chr($B6)), // F7 (FreeBSD)
(i:'[T'; o:chr($EE)+chr($91)+chr($B7)), // F8 (FreeBSD)
(i:'[U'; o:chr($EE)+chr($91)+chr($B8)), // F9 (FreeBSD)
(i:'[V'; o:chr($EE)+chr($91)+chr($B9)), // F10 (FreeBSD)
(i:'[W'; o:chr($EE)+chr($91)+chr($BA)), // F11 (FreeBSD)
(i:'[X'; o:chr($EE)+chr($91)+chr($BB)), // F12 (FreeBSD)
(i:'[Z'; o:chr(0)+chr(1)+chr(9)), // Shift-tab
(i:'[[A'; o:chr($EE)+chr($91)+chr($B0)), // F1 (linux/konsole/xterm)
(i:'[[B'; o:chr($EE)+chr($91)+chr($B1)), // F2 (linux/konsole/xterm)
(i:'[[C'; o:chr($EE)+chr($91)+chr($B2)), // F3 (linux/konsole/xterm)
(i:'[[D'; o:chr($EE)+chr($91)+chr($B3)), // F4 (linux/konsole/xterm)
(i:'[[E'; o:chr($EE)+chr($91)+chr($B4)), // F5 (linux/konsole)
(i:'[a'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A6)), // Shift-up (rxvt)
(i:'[b'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A8)), // Shift-down (rxvt)
(i:'[c'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A7)), // Shift-right (rxvt)
(i:'[d'; o:chr(0)+chr(1)+chr($EE)+chr($90)+chr($A5)) // Shift-left (rxvt)
);

const lastmatch : longint = high(keyseqlist) shr 1;

function FindSeq(seqp : pointer; seqlen : byte) : longint;
// Attempts to match the pointed-to byte sequence in keyseqlist[].
// Returns the matched index if found, otherwise -1.
var min, max : ptrint;
    res : longint;
    minlen, complen : byte;
begin
 // binary search, starting from last successful match
 min := 0; max := high(keyseqlist);
 FindSeq := lastmatch;
 repeat
  {for minlen := 1 to length(inputbuf[inputbufwriteindex]) do
  if byte(inputbuf[inputbufwriteindex][minlen]) in [32..127]
  then write(inputbuf[inputbufwriteindex][minlen])
  else write('.');
  write(' = ');
  for minlen := 1 to length(keyseqlist[findseq].i) do
  if byte(keyseqlist[findseq].i[minlen]) in [32..127]
  then write(keyseqlist[findseq].i[minlen])
  else write('.');
  write(' ? ');}

  complen := length(keyseqlist[FindSeq].i);
  minlen := seqlen;
  if complen < seqlen then minlen := complen;
  res := CompareByte(seqp^, keyseqlist[FindSeq].i[1], minlen);
  //writeln(res);
  if res = 0 then begin
   if complen = seqlen then begin
    lastmatch := FindSeq;
    exit;
   end;
   inc(res);
   if complen > seqlen then res := -1;
  end;
  if res > 0 then min := FindSeq + 1 else max := FindSeq - 1;
  FindSeq := (min + max) shr 1;
 until min > max;
 FindSeq := -1;
end;

procedure TranslateEsc;
// This replaces the current inputbuf string with a non-escaped version.
// The inputbuf string must come with the initial esc stripped.
var mymod, myseq : longint;
begin
 // Basic alt combinations.
 if length(inputbuf[inputbufwriteindex]) = 1 then begin
  case inputbuf[inputbufwriteindex] of
   // alt-tab in linux tty should be treated as shift-tab
   chr(9): inputbuf[inputbufwriteindex] := chr($00) + chr($01) + chr($09);
   // backspace masquerading as delete
   chr($7F): inputbuf[inputbufwriteindex] := chr($00) + chr($02) + chr($08);
   // any other alphanumeric or basic symbol key
   else inputbuf[inputbufwriteindex] := chr($00) + chr($02) + inputbuf[inputbufwriteindex];
  end;
  exit;
 end;
 // Structured xterm modified keypresses.
 if (length(inputbuf[inputbufwriteindex]) >= 8)
 and (copy(inputbuf[inputbufwriteindex], 1, 4) = '[27;')
 and (inputbuf[inputbufwriteindex][6] = ';')
 then begin
  // 3=alt, 4=alt+shift, 5=ctrl, 6=ctrl+shift
  mymod := byte(inputbuf[inputbufwriteindex][5]) - 49;
  // convert the character code to a number
  myseq := 0;
  if inputbuf[inputbufwriteindex][7] in ['0'..'9'] then begin
   myseq := byte(inputbuf[inputbufwriteindex][7]) - 48;
   if inputbuf[inputbufwriteindex][8] in ['0'..'9'] then begin
    myseq := myseq * 10 + byte(inputbuf[inputbufwriteindex][8]) - 48;
    if (length(inputbuf[inputbufwriteindex]) >= 9)
    and (inputbuf[inputbufwriteindex][9] in ['0'..'9'])
    then myseq := myseq * 10 + byte(inputbuf[inputbufwriteindex][9]) - 48;
   end;
  end;
  // save the translated keypress
  inputbuf[inputbufwriteindex] := chr(0) + chr(mymod) + chr(myseq);
  exit;
 end;
 // Complex alt combinations.
 myseq := FindSeq(@inputbuf[inputbufwriteindex][1], length(inputbuf[inputbufwriteindex]));
 if myseq >= 0 then inputbuf[inputbufwriteindex] := keyseqlist[myseq].o;
 //if myseq = -1 then write('ESC+');
end;
{$endif}

{$ifdef WINDOWS}

procedure CrtWriteConOut(const srcp : pointer; const sx, sy, x1, y1, x2, y2 : dword); inline;
var bufsize, bufcoord : COORD;
    writereg : SMALL_RECT;
begin
 bufsize.x := sx; bufsize.y := sy;
 bufcoord.x := 0; bufcoord.y := 0;
 writereg.left := x1; writereg.top := y1; writereg.right := x2; writereg.bottom := y2;
 WriteConsoleOutputW(StdOutH, srcp, bufsize, bufcoord, writereg);
end;

procedure Delay(msec : dword); inline;
begin
 Sleep(msec);
end;

function GetMsecTime : ptruint; inline;
begin
 GetMsectime := GetTickCount;
end;

procedure GotoXY(x, y : dword); inline;
// Attempts to place the cursor to the given character cell in the console.
// If the coordinates are outside the console buffer, the move is cancelled.
// The coordinates are 0-based.
var gotopos : COORD;
begin
 gotopos.X := x; gotopos.Y := y;
 SetConsoleCursorPosition(StdOutH, gotopos);
end;

procedure ClrScr;
// Fills the console buffer with whitespace, and places the cursor in the top
// left.
var numcharswritten : dword;
const writecoord : COORD = (x : 0; y : 0);
begin
 numcharswritten := 0; // silence a compiler warning
 FillConsoleOutputCharacter(StdOutH, ' ', 32767 * 32767, writecoord, numcharswritten);
 FillConsoleOutputAttribute(StdOutH, 7, 32767 * 32767, writecoord, numcharswritten);
 GotoXY(0, 0);
end;

procedure SetColor(color : word); inline;
// Sets the attribute to be used when printing any text in the console after
// this call. The low nibble is the text color, and the next nibble is the
// background color, using the standard 16-color palette. The high byte may
// contain some other odd flags; see "Console Screen Buffers" on MSDN.
begin
 SetConsoleTextAttribute(StdOutH, color);
end;

function KeyPressed : boolean;
// Returns TRUE if the user has pressed a key, that hasn't yet been fetched
// through the ReadKey function. Otherwise returns FALSE without waiting.
// Any new keypresses are placed in inputbuf[].
var numevents, mychar, mymod : dword;
    eventrecord : INPUT_RECORD;
begin
 numevents := 0;
 repeat
  // Check if new input events exist.
  {$note test why esc not detected on win7??}
  if GetNumberOfConsoleInputEvents(StdInH, numevents) = FALSE then break;
  if numevents = 0 then break;
  // Fetch the next console input event.
  if ReadConsoleInputW(StdInH, @eventrecord, 1, @numevents) = FALSE then break;

  // If the event is a keypress, we may be interested...
  if eventrecord.EventType = KEY_EVENT then
  with KEY_EVENT_RECORD(eventrecord.Event) do begin
   // The key was pressed, rather than released?
   if bKeyDown = TRUE then begin
    // Ignore unaccompanied special keys (shift, alt, numlock, etc).
    if wVirtualKeyCode in [16,17,18,20,91,92,144,145] then continue;
    mymod := 0;

    // Note the key value...
    if UnicodeChar = #0 then begin
     // "Enhanced" key.
     case wVirtualKeyCode of
      // Ctrl-number
      $30..$39: begin
       mychar := wVirtualKeyCode;
       mymod := 4;
      end;
      // Ctrl-numpadstar/numpadplus/numpadminus/numpadslash
      $6A, $6B, $6D, $6F: begin
       mychar := wVirtualKeyCode - $40;
       mymod := 4;
      end;
      // Ctrl-plus/comma/dash/period/slash
      $BB, $BC, $BD, $BE, $BF: begin
       mychar := wVirtualKeyCode - $90;
       mymod := 4;
      end;
      // Recognised enhanced keys
      $C,$21..$28,$2D,$2E,$70..$7B: mychar := $E400 + wVirtualKeyCode;
      // Ignore unrecognised enhanced keys
      else continue;
     end;
     if dwControlKeyState and SHIFT_PRESSED <> 0 then mymod := 1;
    end else begin
     // Normal keypress. (If the user input a value outside the basic
     // multilingual plane, this only returns half of the code point.)
     mychar := dword(UnicodeChar);
     // Note shift if the key was a control key or space etc.
     if (dword(UnicodeChar) <= 32)
     and (dwControlKeyState and SHIFT_PRESSED <> 0)
     then mymod := 1;
    end;

    // Note control and alt modifiers.
    if dwControlKeyState and (LEFT_ALT_PRESSED + RIGHT_ALT_PRESSED) <> 0
    then mymod := mymod or 2;
    if dwControlKeyState and (LEFT_CTRL_PRESSED + RIGHT_CTRL_PRESSED) <> 0
    then mymod := mymod or 4;
    // AltGr or Ctrl+Alt can be confusing, since it is present in various
    // normal keypresses on certain keyboard layouts. For simplicity, let's
    // just ignore that modifier.
    if mymod = 6 then mymod := 0;

    // Convert the UCS-2 to UTF-8, and stash it with the control modifier.
    // (see unicode.org's Corrigendum #1, "UTF-8 Bit Distribution")
    // UCS 0..7F    : 0000-0000-0xxx-xxxx --> 0xxxxxxx
    // UCS 80..7FF  : 0000-0yyy-yyxx-xxxx --> 110yyyyy 10xxxxxx
    // UCS 800..FFFF: zzzz-yyyy-yyxx-xxxx --> 1110zzzz 10yyyyyy 10xxxxxx
    if mychar <= $7F then begin
     if mymod = 0 then
      inputbuf[inputbufwriteindex] := char(mychar)
     else
      inputbuf[inputbufwriteindex] := chr(0) + chr(mymod) + chr(mychar);
    end else
    if mychar <= $7FF then begin
     if mymod = 0 then
      inputbuf[inputbufwriteindex] := chr($C0 or (mychar shr 6)) + chr($80 or (mychar and $3F))
     else
      inputbuf[inputbufwriteindex] := chr(0) + chr(mymod) + chr($C0 or (mychar shr 6)) + chr($80 or (mychar and $3F));
    end else
    begin
     if mymod = 0 then
      inputbuf[inputbufwriteindex] := chr($E0 or (mychar shr 12)) + chr($80 or ((mychar shr 6) and $3F)) + chr($80 or (mychar and $3F))
     else
      inputbuf[inputbufwriteindex] := chr(0) + chr(mymod) + chr($E0 or (mychar shr 12)) + chr($80 or ((mychar shr 6) and $3F)) + chr($80 or (mychar and $3F));
    end;

    // Advance the input buffer write index.
    inputbufwriteindex := (inputbufwriteindex + 1) mod length(inputbuf);
   end;
   continue;
  end;

  // If the event is a window size change, ping the callback procedure.
  // (Only signals buffer size changes, not window size change...)
  if (eventrecord.EventType = WINDOW_BUFFER_SIZE_EVENT)
  and (NewConSizeCallback <> NIL) then
   with WINDOW_BUFFER_SIZE_RECORD((@eventrecord.Event)^).dwSize do
    NewConSizeCallback(x, y);

  // Continue checking input events, until no more are available.
 until FALSE;

 // Return TRUE, if a keypress was buffered earlier but hasn't yet been
 // read with ReadKey. Otherwise return FALSE.
 KeyPressed := inputbufreadindex <> inputbufwriteindex;
end;

function ReadKey : UTF8string;
// Blocks execution until the user presses a key. This function returns the
// pressed key value as a UTF-8 string. Extended keys are returned as values
// in the Unicode private use area; see the top of the file.
// If any modifiers are present, the returned string will begin with a null
// byte, followed by a modifier bitfield, and then the UTF-8 code value.
begin
 // Repeat this until a wild keypress appears.
 while KeyPressed = FALSE do begin
  // No keypress yet, enter an efficient wait state.
  if WaitForSingleObject(StdInH, INFINITE) <> WAIT_OBJECT_0 then begin
   // The Wait call may return WAIT_FAILED or WAIT_ABANDONED, in which case
   // something has gone horribly wrong.
   ReadKey := '';
   exit;
  end;
 end;
 // Key pressed! Return its value and advance the input buffer read index.
 ReadKey := inputbuf[inputbufreadindex];
 inputbuf[inputbufreadindex] := '';
 inputbufreadindex := (inputbufreadindex + 1) mod length(inputbuf);
end;

procedure UTF8Write(const outstr : UTF8string); inline;
// Workaround for FPC's Write failing to print UTF8strings in a Windows
// console.
begin
 if length(outstr) <> 0 then
  WriteConsoleA(stdouth, @outstr[1], length(outstr), NIL, NIL);
end;

procedure CrtSetTitle(const newtitle : UTF8string); inline;
// Attempts to set the console or term window's title to the given string.
var widetitle : unicodestring;
begin
 widetitle := unicodestring(newtitle) + WideChar(0);
 SetConsoleTitleW(@widetitle[1]);
end;

procedure CrtShowCursor(visible : boolean); inline;
// Shows or hides the blinking console cursor.
begin
 concursorinfo.bVisible := visible;
 SetConsoleCursorInfo(StdOutH, concursorinfo);
end;

procedure GetConsoleSize(var sizex, sizey : dword);
// Returns the currently visible console size (cols and rows) in sizex and
// sizey.
var bufinfo : CONSOLE_SCREEN_BUFFER_INFO;
begin
 if GetConsoleScreenBufferInfo(StdOutH, @bufinfo) = FALSE then begin
  sizex := 0;
  sizey := 0;
 end else begin
  sizex := bufinfo.srWindow.right - bufinfo.srWindow.left + 1;
  sizey := bufinfo.srWindow.bottom - bufinfo.srWindow.top + 1;
 end;
end;

procedure GetConsolePalette;
// Updates crtpalette with the console's actual palette, if possible. May
// fail silently, in which case the fallback palette remains in place.
// This uses a function only available on WinVista and later.
type CONSOLE_SCREEN_BUFFER_INFOEX = record
       cbSize : ULONG;
       dwSize, dwCursorPosition : COORD;
       wAttributes : word;
       srWindow : SMALL_RECT;
       dwMaximumWindowSize : COORD;
       wPopupAttributes : word;
       bFullscreenSupported: BOOL;
       ColorTable : array[0..15] of COLORREF;
     end;
     PCONSOLE_SCREEN_BUFFER_INFOEX = ^CONSOLE_SCREEN_BUFFER_INFOEX;
var GetConsoleScreenBufferInfoEx : function(hConsoleOutput : HANDLE; lpConsoleScreenBufferInfoEx : PCONSOLE_SCREEN_BUFFER_INFOEX) : BOOL; stdcall;
    conbufinfo : CONSOLE_SCREEN_BUFFER_INFOEX;
    libhandle : HANDLE;
    txt : widestring;
    procname : string;
    ivar : UINT;
begin
 libhandle := 0;
 setlength(txt, MAX_PATH);
 // To load a system dll, we first need the system directory.
 ivar := GetSystemDirectoryW(@txt[1], MAX_PATH);
 if ivar <> 0 then begin
  setlength(txt, ivar);
  txt := txt + '\kernel32.dll' + chr(0);
  // Try to load the library.
  libhandle := LoadLibraryW(@txt[1]);
  if libhandle <> 0 then begin
   // Success! Now fetch the function from the library.
   procname := 'GetConsoleScreenBufferInfoEx' + chr(0);
   pointer(GetConsoleScreenBufferInfoEx) := GetProcAddress(libhandle, @procname[1]);
   if pointer(GetConsoleScreenBufferInfoEx) <> NIL then begin
    // So far so good. The info structure's size element must be filled in.
    conbufinfo.cbSize := sizeof(CONSOLE_SCREEN_BUFFER_INFOEX);
    // Try to fetch the extended console information using the new function.
    if GetConsoleScreenBufferInfoEx(StdOutH, @conbufinfo) then begin
     // Got it! Distribute the palette colors into crtpalette[].
     for ivar := 0 to $F do begin
      crtpalette[ivar].r := conbufinfo.ColorTable[ivar] and $FF;
      crtpalette[ivar].g := (conbufinfo.ColorTable[ivar] shr 8) and $FF;
      crtpalette[ivar].b := (conbufinfo.ColorTable[ivar] shr 16) and $FF;
     end;
    end;
   end;
  end;
 end;
 // Clean up.
 setlength(txt, 0);
 pointer(GetConsoleScreenBufferInfoEx) := NIL;
 if libhandle <> 0 then FreeLibrary(libhandle);
end;

{$else}

procedure Delay(msec : dword); inline;
begin
 // Although fpNanoSleep exists specifically for delays, it may unexpectedly
 // return before the requested timeout if some other interesting signal
 // appeared. Also, it uses nanosecs rather than millisecs.
 // fpSelect will reliably wait the requested time. Normally it's used to
 // wait for a file event, but by inputting all null files, the function only
 // returns upon timeout.
 fpSelect(0, NIL, NIL, NIL, msec);
end;

function GetMsecTime : ptruint; inline;
var tp : TTimeVal;
begin
 FpGetTimeOfDay(@tp, NIL);
 GetMsecTime := tp.tv_sec * 1000 + tp.tv_usec shr 10;
end;

procedure GotoXY(x, y : dword); inline;
// Attempts to place the cursor to the given character cell in the console.
// If the coordinates are outside the console buffer, the move is cancelled.
// The coordinates are 0-based.
var xx, yy : string[15];
begin
 str(x + 1, xx);
 str(y + 1, yy);
 write(chr(27) + '[' + yy + ';' + xx + 'H');
end;

procedure ClrScr;
// Fills the console buffer with whitespace, and places the cursor in the top
// left.
begin
 write(chr(27) + '[2J' + chr(27) + '[H');
end;

procedure SetColor(color : word); inline;
// Sets the attribute to be used when printing any text in the console after
// this call. The low nibble is the text color, and the next nibble is the
// background color, using the standard 16-color palette. The high byte
// doesn't do anything.
begin
 write(chr(27) + '[' + termtextcolor[color and $F] + ';' + termbkgcolor[color shr 4] + 'm');
end;

function KeyPressed : boolean;
// Returns TRUE if the user has pressed a key, that hasn't yet been fetched
// through the ReadKey function. Otherwise returns FALSE without waiting.
// Any new keypresses are placed in inputbuf[].
var seq : array[0..31] of byte;
    numbytes : ptrint;
begin
 seq[0] := 0;
 inputbuf[inputbufwriteindex] := '';
 repeat
  // Check if a new input sequence exists.
  numbytes := fpRead(1, seq[0], 31);
  if (numbytes <= 0) and (fpGetErrno = ESysEAGAIN) then break;
  // Translate and save the input sequence in our input buffy.
  case seq[0] of
    // special case: ctrl-space
    0: inputbuf[inputbufwriteindex] := chr($00) + chr($04) + chr($20);
    // non-conflicting ctrl-letters: a..g, k, l, n..z
    1..7, $B, $C, $E..$1A:
     inputbuf[inputbufwriteindex] := chr($00) + chr($04) + chr(seq[0]);
    // non-conflicting ctrl-numbers: 4..6
    $1C..$1E:
     inputbuf[inputbufwriteindex] := chr($00) + chr($04) + chr(seq[0] + $18);
    // ctrl-minus (conflicts with ctrl-7)
    $1F: inputbuf[inputbufwriteindex] := chr($00) + chr($04) + chr($1F);
    // esc
    $1B: begin
     if numbytes = 1 then
      // just an esc
      inputbuf[inputbufwriteindex] := chr(27)
     else begin
      // terminal window size notification ESC[8;<rows>;<cols>t
      if (numbytes >= 8)
      and (chr(seq[2]) = '8') and (chr(seq[3]) = ';') and (chr(seq[1]) = '[')
      and (chr(seq[numbytes - 1]) = 't')
      then begin
       termsizey := 0; seq[0] := 4;
       while (seq[0] < numbytes) and (chr(seq[seq[0]]) in ['0'..'9']) do begin
        termsizey := termsizey * 10 + seq[seq[0]] - 48;
        inc(seq[0]);
       end;
       termsizex := 0; inc(seq[0]);
       while (seq[0] < numbytes) and (chr(seq[seq[0]]) in ['0'..'9']) do begin
        termsizex := termsizex * 10 + seq[seq[0]] - 48;
        inc(seq[0]);
       end;
       continue;
      end;
      // palette response
      if (numbytes >= 22)
      and (chr(seq[2]) = '4') and (chr(seq[3]) = ';') and (chr(seq[1]) = ']')
      then begin
       seq[1] := seq[numbytes - 13];
       seq[2] := seq[numbytes - 14];
       seq[3] := seq[numbytes - 8];
       seq[4] := seq[numbytes - 9];
       seq[5] := seq[numbytes - 3];
       seq[6] := seq[numbytes - 4];
       crtpalresponse := 0; seq[0] := 1;
       while seq[0] <= 6 do begin
        crtpalresponse := crtpalresponse shl 4;
        case chr(seq[seq[0]]) of
          '1'..'9': inc(crtpalresponse, seq[seq[0]] - 48);
          'a'..'f': inc(crtpalresponse, seq[seq[0]] - 87);
        end;
        inc(seq[0]);
       end;
       continue;
      end;
      // scary escape sequence
      dec(numbytes);
      setlength(inputbuf[inputbufwriteindex], numbytes);
      move(seq[1], inputbuf[inputbufwriteindex][1], numbytes);
      TranslateEsc;
     end;
    end;
    // backspace masquerading as delete
    $7F: inputbuf[inputbufwriteindex] := chr(8);
    // normal UTF-8 value
    else begin
     setlength(inputbuf[inputbufwriteindex], numbytes);
     move(seq[0], inputbuf[inputbufwriteindex][1], numbytes);
    end;
  end;
  // Advance the input buffer write index.
  inputbufwriteindex := (inputbufwriteindex + 1) mod length(inputbuf);

  // Continue checking input events, until no more are available.
 until FALSE;

 // Return TRUE, if a keypress was buffered earlier but hasn't yet been
 // read with ReadKey. Otherwise return FALSE.
 KeyPressed := inputbufreadindex <> inputbufwriteindex;
end;

function ReadKey : UTF8string;
// Blocks execution until the user presses a key. This function returns the
// pressed key value as a UTF-8 string. Extended keys are returned as values
// in the Unicode private use area; see the top of the file.
// If any modifiers are present, the returned string will begin with a null
// byte, followed by a modifier bitfield, and then the UTF-8 code value.
begin
 // Repeat this until a wild keypress appears.
 while KeyPressed = FALSE do begin
  // No keypress yet, enter an efficient wait state...
  // Use a file descriptor pointing at stdin (channel 0).
  fpFD_ZERO(StdInDescriptor);
  fpFD_SET(0, StdInDescriptor);
  fpSelect(1, @StdInDescriptor, NIL, NIL, -1);
 end;
 // Key pressed! Return its value and advance the input buffer read index.
 ReadKey := inputbuf[inputbufreadindex];
 inputbuf[inputbufreadindex] := '';
 inputbufreadindex := (inputbufreadindex + 1) mod length(inputbuf);
end;

procedure UTF8Write(const outstr : UTF8string); inline;
begin
 write(outstr);
end;

procedure CrtSetTitle(const newtitle : UTF8string); inline;
// Attempts to set the console or term window's title to the given string.
begin
 write(chr(27) + ']2;', newtitle, chr(7));
end;

procedure CrtShowCursor(visible : boolean); inline;
// Attempts to show or hide the cursor in the terminal window.
begin
 if visible
 then write(chr(27) + '[?25h') // show
 else write(chr(27) + '[?25l'); // hide
end;

procedure GetConsoleSize(var sizex, sizey : dword);
// Returns the currently visible terminal size (cols and rows) in sizex and
// sizey.
begin
 // Flush stdin.
 KeyPressed;
 // Request the window size.
 write(chr(27) + '[18t');
 // Enter a wait state until something appears in stdin, or 768ms elapsed.
 fpFD_ZERO(StdInDescriptor);
 fpFD_SET(0, StdInDescriptor);
 fpSelect(1, @StdInDescriptor, NIL, NIL, 768);
 // Check stdin; the window size should be processed into termsizexy.
 KeyPressed;
 sizex := termsizex; sizey := termsizey;
end;

procedure GetConsolePalette;
// Updates crtpalette with the terminal's actual palette, if possible. May
// fail silently, in which case the fallback palette remains in place.

  function ansigetcolor(colnum : byte) : boolean;
  begin
   crtpalresponse := $FFFFFFFF; ansigetcolor := FALSE;
   write(chr(27) + ']4;', colnum, ';?' + chr(7));
   // Enter a wait state until something appears in stdin, or 768ms elapsed.
   fpFD_ZERO(StdInDescriptor);
   fpFD_SET(0, StdInDescriptor);
   fpSelect(1, @StdInDescriptor, NIL, NIL, 768);
   // Check stdin; the color should be processed by KeyPressed.
   KeyPressed;
   if crtpalresponse <> $FFFFFFFF then begin
    crtpalette[colnum].r := crtpalresponse and $FF;
    crtpalette[colnum].g := (crtpalresponse shr 8) and $FF;
    crtpalette[colnum].b := (crtpalresponse shr 16) and $FF;
    ansigetcolor := TRUE;
   end;
  end;

var ivar : dword;
begin
 // Flush stdin.
 KeyPressed;
 // Request palette 0.
 if ansigetcolor(0) then
 // If that worked, request the other colors.
 for ivar := 1 to 15 do ansigetcolor(ivar);
end;

{$HINTS OFF} // fpc complains about the parameters being unused...
procedure sigwinchHandler(sig : longint; psi : PSigInfo; psc : PSigContext); cdecl;
// Callback for SIGWINCHes. This doesn't seem safe to use however, if there
// is any significant drawing to the screen happening, since the callback may
// occur during write operations, and that tends to end in a crash. :(
var oldx, oldy, x, y : dword;
begin
 if NewConSizeCallback <> NIL then begin
  oldx := termsizex; oldy := termsizey;
  GetConsoleSize(x, y);
  if (oldx <> x) or (oldy <> y) then NewConSizeCallback(x, y);
 end;
end;
{$HINTS ON}

procedure DoNewSets;
// This is called during initialisation, to tweak the terminal settings.
// Current settings must have been fetched into TermSettings before calling.
var newsets : termios;
    sigact : SigActionRec;
begin
 newsets := TermSettings;
 // See man pages on cfmakeraw and termios for details.
 // This tweaks the settings to a standard raw IO mode.
 cfmakeraw(newsets);
 // Enable UTF-8 handling. Should already be on by default everywhere?
 //newsets.c_iflag := newsets.c_iflag or IUTF8;
 // Output processing must be kept on, or writeln stops working as expected,
 // since linebreaks no longer get automatically expanded from a newline to
 // a newline-carriage return pair.
 newsets.c_oflag := OPOST or ONLCR or ONOCR;
 // Send in the new settings.
 tcsetattr(1, TCSANOW, newsets);
 // Set up a signal handler for window size changes.
 sigact.sa_Handler := NIL;
 fillbyte(sigact, sizeof(sigact), 0);
 sigact.sa_Handler := @sigwinchHandler;
 FPSigaction(SIGWINCH, @sigact, @OldSigAction);
end;

{$endif}

// ------------------------------------------------------------------

procedure MyCallback(sizex, sizey : dword);
begin
 writeln('new con size: ',sizex,'x',sizey);
end;

procedure RunTest;
// Call this from your program to enter a debug testing mode. This calls all
// functions in the unit, then enters a loop waiting for keypresses and
// console resizes. Press ESC to finish the test.
const hextable : array[0..$F] of char = (
'0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F');
var sux, suy : dword;
    kii : UTF8string;
begin
 sux := 0; suy := 0;
 NewConSizeCallback := @MyCallback;
 CrtSetTitle('yeehehee');
 ClrScr;
 GetConsoleSize(sux, suy);
 writeln('detected console size: ', sux, 'x', suy);
 if sux = 0 then sux := 80;
 if suy = 0 then suy := 25;
 Delay(1600);
 writeln('delay done');

 // Japanese UTF-8 text output.
 write(chr($E3) + chr($81) + chr($BE) + chr($E3) + chr($81) + chr($A0));
 kii := chr($E8) + chr($A9) + chr($B1) + chr($E3) + chr($81) + chr($99);
 UTF8write(kii);
 writeln;

 // Fill the bottom row with purple, scribble in the lower right corner.
 // The window should not scroll.
 GotoXY(0, suy - 1);
 SetColor($50);
 write(space(sux - 5));
 write('...+*');

 // Draw a palette at the top.
 GetConsolePalette;
 GotoXY(0, 3);
 for sux := 0 to $F do begin
  if sux = 0 then SetColor(7) else SetColor(sux);
  suy := sux * 4;
  if suy > 0 then dec(suy);
  if sux and 1 = 0 then GotoXY(suy, 3) else GotoXY(suy, 6);
  write(hextable[crtpalette[sux].r shr 4]);
  write(hextable[crtpalette[sux].r and $F]);
  write(hextable[crtpalette[sux].g shr 4]);
  write(hextable[crtpalette[sux].g and $F]);
  write(hextable[crtpalette[sux].b shr 4]);
  write(hextable[crtpalette[sux].b and $F]);
 end;
 GotoXY(0, 4);
 for sux := 0 to $F do begin SetColor($11 * sux); write('@@@@'); end;
 GotoXY(0, 5);
 for sux := 0 to $F do begin SetColor($11 * sux); write('@@@@'); end;

 // Start the key-catcher.
 GotoXY(0,7);
 suy := $003B;
 repeat
  kii := ReadKey;
  SetColor(suy);
  suy := suy xor 4;
  write('kii: ');
  for sux := 1 to length(kii) do
   write(hextable[(byte(kii[sux]) shr 4)], hextable[(byte(kii[sux]) and $F)]);
  write(': ');
  for sux := 1 to length(kii) do
   if byte(kii[sux]) in [32..127] then write(kii[sux]);
  writeln;
 until (kii = chr(27)) or (kii = chr(32));
end;

// ------------------------------------------------------------------
initialization

 {$ifdef WINDOWS}

 // Get the OS handles for the console's input and output.
 StdInH := GetStdHandle(STD_INPUT_HANDLE);
 StdOutH := GetStdHandle(STD_OUTPUT_HANDLE);
 // Disable most special handling, but enable window resize notifications.
 SetConsoleMode(StdInH, ENABLE_WINDOW_INPUT);
 SetConsoleMode(StdOutH, ENABLE_PROCESSED_OUTPUT{ or ENABLE_WRAP_AT_EOL_OUTPUT});
 // Fetch the cursor size and visibility.
 concursorinfo.dwSize := 0;
 GetConsoleCursorInfo(StdOutH, concursorinfo);
 // The console must be switched to UTF-8 mode, or multibyte characters are
 // displayed as single-byte garbage characters. The console or OS must also
 // have a suitable font with the needed glyphs, such as Lucida Sans Unicode.
 // At least on WinXP the console is buggy, and will display kanji as generic
 // blocks, until you move the window around to force a redraw, which makes
 // the correct characters turn up at a wider spacing.
 oldcodepageout := GetConsoleOutputCP;
 SetConsoleOutputCP(CP_UTF8);

 {$else}

 // Get the current terminal settings.
 TermSettings.c_iflag := 0;
 tcgetattr(1, TermSettings);
 // Punch in new settings.
 DoNewSets;
 // Stop fpRead from blocking execution, for benefit of KeyPressed.
 filecontrolflags := fpFcntl(0, F_GetFl);
 fpFcntl(0, F_SetFl, filecontrolflags or O_NONBLOCK);
 // Reset text color attributes?
 write(chr(27) + '[0m');
 // Select the UTF-8 character set. Not always necessary, but at least on my
 // LXterminal this is required or UTF-8 output isn't recognised.
 write(chr(27) + '%G');

 {$endif}

 // Initialise the internal keypress ring buffer.
 inputbufwriteindex := 0;
 inputbufreadindex := 0;

// ------------------------------------------------------------------
finalization

 {$ifdef WINDOWS}

 // Restore the original console code page.
 SetConsoleOutputCP(oldcodepageout);
 // Restore the standard console mode and color.
 SetConsoleMode(StdInH, ENABLE_LINE_INPUT + ENABLE_ECHO_INPUT + ENABLE_PROCESSED_INPUT + ENABLE_MOUSE_INPUT);
 SetConsoleMode(StdOutH, ENABLE_PROCESSED_OUTPUT + ENABLE_WRAP_AT_EOL_OUTPUT);
 SetColor($0007);

 {$else}

 // Restore the standard text color.
 write(chr(27) + '[0m');
 // Restore the original terminal settings.
 tcsetattr(1, TCSANOW, TermSettings);
 // Restore the old signal handling.
 FPSigaction(SIGWINCH, @OldSigAction, NIL);
 // Restore normal fpRead operation.
 fpFcntl(0, F_SetFl, filecontrolflags);

 {$endif}

 // Restore the cursor.
 CrtShowCursor(true);
end.
