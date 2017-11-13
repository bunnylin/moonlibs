unit mcgloder;
{                                                                           }
{ Mooncore Graphics Loader and related functions                            }
{ Copyright 2005-2017 :: Kirinn Bunnylin / MoonCore                         }
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

{$mode fpc}
{$WARN 4079 off} // Spurious hints: Converting the operands to "Int64" before
{$WARN 4080 off} // doing the operation could prevent overflow errors.
{$WARN 4081 off}

interface

uses mccommon, paszlib;

type RGBquad = packed record b, g, r, a : byte; end;
     RGBA64 = packed record b, g, r, a : word; end;
     RGBAarray = array[0..$FFFFFF] of RGBquad;
     bitmaptype = packed record
       image : pointer;
       palette : array of rgbquad;
       sizex, sizey : word;
       memformat, bitdepth : byte;
       // possible memformat values...
       //   0 = RGB, 1 = RGBA
       //   2 = monochrome, 3 = monochrome with alpha
       //   4 = indexed RGB, 5 = indexed RGBA (no separate A channel)
       // The routine ExpandBitdepth can be used to expand bitdepth to 8, and
       // ExpandIndexed to unpack indexed images into RGB or RGBA.
       // If bitdepth is < 8, each image scanline must still be byte-aligned.
       // PNGs are such by definition; BMPs come with DWORD-aligned rows.
       // Bitdepth may not be > 8, due to effort involved.
     end;
     pbitmaptype = ^bitmaptype;

function xlatezerror(incode : longint) : string;
// Image loading, handling and unloading functions
procedure mcg_ForgetImage(which : pbitmaptype);
function mcg_GammaInput(color : rgbquad) : RGBA64; inline;
function mcg_GammaOutput(color : RGBA64) : rgbquad; inline;
procedure mcg_PremulRGBA32(imagep : pointer; numpixels : dword);
procedure mcg_ExpandBitdepth(whither : pbitmaptype);
procedure mcg_ExpandIndexed(whither : pbitmaptype);
function mcg_MatchColorInPal(color : rgbquad; which : pbitmaptype) : longint;
function mcg_PNGtoMemory(readp : pointer; psize : dword; membmp : pbitmaptype) : byte;
function mcg_BMPtoMemory(p : pointer; membmp : pbitmaptype) : byte;
function mcg_LoadGraphic(p : pointer; psize : dword; membmp : pbitmaptype) : byte;
function mcg_MemorytoPNG(membmp : pbitmaptype; p, psizu : pointer) : byte;
// Image scaling algorithms
{$ifdef bonk}
procedure BunnyScale2x32(poku : pbitmaptype);
procedure BunnyScale2x24(poku : pbitmaptype);
{$endif}
procedure mcg_EPScale32(poku : pbitmaptype; tox, toy : word);
procedure mcg_EPScale24(poku : pbitmaptype; tox, toy : word);
procedure mcg_ScaleBitmapCos(poku : pbitmaptype; tox, toy : word);
procedure mcg_ScaleBitmap(poku : pbitmaptype; tox, toy : word);

var mcg_errortxt : string; // in case of error, the caller can read this
    mcg_ReadHeaderOnly : byte; // if non-zero, doesn't load bitmaps
    mcg_AutoConvert : byte; // what to do to images upon loading?
    // 0 - Do nothing
    // 1 - Expand bitdepth to 8
    // 2 - Expand bitdepth and convert indexed to truecolor

// This is a precalculated half cosine curve at 16-bit resolution.
// In radians, the input goes from cos(0) to cos(pi).
// The output has been normalised from [1..-1] to [65535..0].
// Notes:
// Cosine's gradient is a phase-shifted cosine... maybe helpful.
//   cos(n)' = cos(n + 1/4 * 2pi)
//   cos[0..max/2]' = cos(max/2 + n)
//   cos[max/2..max]' = cos(max*3/2 - n)
// And, if only expanding 2x at a time, the interpolation simplifies to:
//   = (g1 - g2) / 8 + dy / 2 + y1
// (can't use shifts since the terms can be negative)
// So for cos[1]:
//   g1 = cos[0]', g2 = cos[2]', dy = cos[2] - cos[0], y1 = cos[0]
const mcg_costable : array[0..256] of word = (
  65535, 65533, 65525, 65513, 65496, 65473, 65446, 65414,
  65377, 65335, 65289, 65237, 65180, 65119, 65053, 64981,
  64905, 64825, 64739, 64648, 64553, 64453, 64348, 64238,
  64124, 64005, 63881, 63753, 63620, 63482, 63339, 63192,
  63041, 62885, 62724, 62559, 62389, 62215, 62036, 61853,
  61666, 61474, 61278, 61078, 60873, 60664, 60451, 60234,
  60013, 59787, 59558, 59324, 59087, 58845, 58600, 58350,
  58097, 57840, 57579, 57315, 57047, 56775, 56499, 56220,
  55938, 55652, 55362, 55069, 54773, 54473, 54170, 53864,
  53555, 53243, 52927, 52609, 52287, 51963, 51635, 51305,
  50972, 50636, 50298, 49957, 49613, 49267, 48919, 48567,
  48214, 47858, 47500, 47140, 46777, 46413, 46046, 45678,
  45307, 44935, 44560, 44184, 43807, 43427, 43046, 42663,
  42279, 41894, 41507, 41119, 40729, 40339, 39947, 39554,
  39160, 38765, 38369, 37973, 37575, 37177, 36779, 36379,
  35979, 35579, 35178, 34777, 34375, 33974, 33572, 33170,
  32767, 32365, 31963, 31561, 31160, 30758, 30357, 29956,
  29556, 29156, 28756, 28358, 27960, 27562, 27166, 26770,
  26375, 25981, 25588, 25196, 24806, 24416, 24028, 23641,
  23256, 22872, 22489, 22108, 21728, 21351, 20975, 20600,
  20228, 19857, 19489, 19122, 18758, 18395, 18035, 17677,
  17321, 16968, 16616, 16268, 15922, 15578, 15237, 14899,
  14563, 14230, 13900, 13572, 13248, 12926, 12608, 12292,
  11980, 11671, 11365, 11062, 10762, 10466, 10173,  9883,
   9597,  9315,  9036,  8760,  8488,  8220,  7956,  7695,
   7438,  7185,  6935,  6690,  6448,  6211,  5977,  5748,
   5522,  5301,  5084,  4871,  4662,  4457,  4257,  4061,
   3869,  3682,  3499,  3320,  3146,  2976,  2811,  2650,
   2494,  2343,  2196,  2053,  1915,  1782,  1654,  1530,
   1411,  1297,  1187,  1082,   982,   887,   796,   710,
    630,   554,   482,   416,   355,   298,   246,   200,
    158,   121,    89,    62,    39,    22,    10,     2,
      0);

// The below "gamma" lookup table is for color space transformations.
// We're assuming all 8-bit input values are in non-linear sRGB color space.
// sRGB has a perceptually somewhat uniform lightness gradient, whereas
// a linear color space has uniform light energy.
// Most image processing needs to be done in linear RGB for best results,
// so we need a lookup transform from 8-bit sRGB to 16-bit linear values.
//
// Inverse sRGB companding with normalised x in [0..1]
//   if x < 0.04045 then f(x) = x / 12.92
//                  else f(x) = ((x + 0.055) / 1.055) ^ 2.4
// Or, more usefully...
//   for x := 0 to 255 do begin
//     x2 := x / 255;
//     if x < 11 then x3 := x2 / 12.92
//               else x3 := ((x2 + 0.055) / 1.055) ^ 2.4;
//     mcg_GammaTab[x] := round(x3 * 65535);
//   end;
//
// A hardcoded reverse table would take 64k memory, so it's better to
// generate that at runtime. The average pixel intensity error this
// introduces is well below 1/256th per channel.
var mcg_RevGammaTab : array of byte;
const mcg_GammaTab : array[0..255] of word = (
     0,    20,    40,    60,    80,    99,   119,   139,
   159,   179,   199,   219,   241,   264,   288,   313,
   340,   367,   396,   427,   458,   491,   526,   562,
   599,   637,   677,   718,   761,   805,   851,   898,
   947,   997,  1048,  1101,  1156,  1212,  1270,  1330,
  1391,  1453,  1517,  1583,  1651,  1720,  1790,  1863,
  1937,  2013,  2090,  2170,  2250,  2333,  2418,  2504,
  2592,  2681,  2773,  2866,  2961,  3058,  3157,  3258,
  3360,  3464,  3570,  3678,  3788,  3900,  4014,  4129,
  4247,  4366,  4488,  4611,  4736,  4864,  4993,  5124,
  5257,  5392,  5530,  5669,  5810,  5953,  6099,  6246,
  6395,  6547,  6700,  6856,  7014,  7174,  7335,  7500,
  7666,  7834,  8004,  8177,  8352,  8528,  8708,  8889,
  9072,  9258,  9445,  9635,  9828, 10022, 10219, 10417,
 10619, 10822, 11028, 11235, 11446, 11658, 11873, 12090,
 12309, 12530, 12754, 12980, 13209, 13440, 13673, 13909,
 14146, 14387, 14629, 14874, 15122, 15371, 15623, 15878,
 16135, 16394, 16656, 16920, 17187, 17456, 17727, 18001,
 18277, 18556, 18837, 19121, 19407, 19696, 19987, 20281,
 20577, 20876, 21177, 21481, 21787, 22096, 22407, 22721,
 23038, 23357, 23678, 24002, 24329, 24658, 24990, 25325,
 25662, 26001, 26344, 26688, 27036, 27386, 27739, 28094,
 28452, 28813, 29176, 29542, 29911, 30282, 30656, 31033,
 31412, 31794, 32179, 32567, 32957, 33350, 33745, 34143,
 34544, 34948, 35355, 35764, 36176, 36591, 37008, 37429,
 37852, 38278, 38706, 39138, 39572, 40009, 40449, 40891,
 41337, 41785, 42236, 42690, 43147, 43606, 44069, 44534,
 45002, 45473, 45947, 46423, 46903, 47385, 47871, 48359,
 48850, 49344, 49841, 50341, 50844, 51349, 51858, 52369,
 52884, 53401, 53921, 54445, 54971, 55500, 56032, 56567,
 57105, 57646, 58190, 58737, 59287, 59840, 60396, 60955,
 61517, 62082, 62650, 63221, 63795, 64372, 64952, 65535);

// ------------------------------------------------------------------

implementation

type RGBtriplet = packed record
       b, g, r : byte;
     end;
     RGBarray = array[0..$FFFFFF] of RGBtriplet;

const allowdiff = 4; // if < 2 then change var calc to a word
var //sspat : array[0..$FF] of array[0..3] of byte;
    CRCtable : array[0..255] of dword;
    CRC : dword;
    CRCundone : boolean;
    pnghdr : packed record
      streamlength : dword;
      bitdepth, colortype, compression, filter, interlace : byte;
    end;

function xlatezerror(incode : longint) : string;
// Writes a ZLib error code into an informative string.
begin
 case incode of
   0: xlatezerror := 'ZLib errorcode Z_OK is not an error, you should never see this.';
   1: xlatezerror := 'ZLib errorcode Z_STREAM_END is not an error, you should never see this.';
   2: xlatezerror := 'ZLib errorcode Z_NEED_DICT is not an error, you should never see this.';
   -1: xlatezerror := 'ZLib error -1: Z_ERRNO';
   -2: xlatezerror := 'ZLib error -2: Z_STREAM_ERROR';
   -3: xlatezerror := 'ZLib error -3: Z_DATA_ERROR';
   -4: xlatezerror := 'ZLib error -4: Z_MEM_ERROR';
   -5: xlatezerror := 'ZLib error -5: Z_BUF_ERROR';
   -6: xlatezerror := 'ZLib error -6: Z_VERSION_ERROR';
   else xlatezerror := 'Unknown ZLib error' + strdec(incode) + '!';
 end;
end;

procedure updateCRC(const withwhat : byte); inline;
begin
 CRC := CRCtable[(CRC xor withwhat) and $FF] xor (CRC shr 8);
end;

// ------------------------------------------------------------------

// Releases the memory used by a bitmap resource.
procedure mcg_ForgetImage(which : pbitmaptype);
begin
 if which^.image <> NIL then begin
  freemem(which^.image); which^.image := NIL;
 end;
 setlength(which^.palette, 0);
end;

function mcg_GammaInput(color : rgbquad) : RGBA64; inline;
// Applies a ~2.4 gamma to convert display sRGB into a linear colorspace.
// The input is 8 bits per channel, the output is 16 bits.
// Use this on all input colors, before doing any processing on them. As an
// additional benefit, the higher bitdepth reduces image processing errors.
begin
 mcg_GammaInput.b := mcg_GammaTab[color.b];
 mcg_GammaInput.g := mcg_GammaTab[color.g];
 mcg_GammaInput.r := mcg_GammaTab[color.r];
 mcg_GammaInput.a := (color.a * 65535) div 255;
end;

function mcg_GammaOutput(color : RGBA64) : rgbquad; inline;
// Applies a reverse ~2.4 gamma to convert linear colorspace into displayable
// sRGB colors. The input is 16 bits per channel, the output is 8 bits.
// Use on all processed colors before showing them to the user.
begin
 mcg_GammaOutput.b := mcg_RevGammaTab[color.b];
 mcg_GammaOutput.g := mcg_RevGammaTab[color.g];
 mcg_GammaOutput.r := mcg_RevGammaTab[color.r];
 mcg_GammaOutput.a := (color.a * 255) div 65535;
end;

procedure mcg_PremulRGBA32(imagep : pointer; numpixels : dword);
// Imagep must point to an image buffer of RGBquads, numpixels pixels.
// This procedure then multiplies all pixels by their alpha value. This is
// called pre-multiplied alpha, and it makes the actual alpha-blending
// simpler. Only call this once per image.
var a : byte;
begin
 while numpixels <> 0 do begin
  a := byte((imagep + 3)^);
  byte(imagep^) := byte(imagep^) * a div 255; inc(imagep);
  byte(imagep^) := byte(imagep^) * a div 255; inc(imagep);
  byte(imagep^) := byte(imagep^) * a div 255; inc(imagep, 2);
  dec(numpixels);
 end;
end;

procedure mcg_ExpandBitdepth(whither : pbitmaptype);
// Transforms indexed bitmaps of less than 8 bits per pixel to 8 bpp.
var ivar, jvar, lvar, ofsu : dword;
    puhvi : pointer;
    bvar : byte;
begin
 if whither^.bitdepth = 8 then exit; // already at 8 bpp
 if whither^.bitdepth in [1,2,4] = FALSE then begin
  mcg_ErrorTxt := 'Unsupported bitdepth: ' + strdec(whither^.bitdepth); exit;
 end;

 getmem(puhvi, whither^.sizex * whither^.sizey);

 // Inflate bitdepth row by row, assuming source rows are BYTE-aligned
 jvar := whither^.sizey;
 lvar := 0; ofsu := 0;
 while jvar <> 0 do begin
  ivar := whither^.sizex;
  bvar := 8;
  while ivar <> 0 do begin
   dec(bvar, whither^.bitdepth);
   byte((puhvi + ofsu)^) := (byte((whither^.image + lvar)^) shr bvar) and ((1 shl whither^.bitdepth) - 1);
   if bvar = 0 then begin inc(lvar); bvar := 8; end;
   inc(ofsu); dec(ivar);
  end;
  if bvar <> 8 then inc(lvar); // force byte-align after end of row
  dec(jvar);
 end;

 freemem(whither^.image); whither^.image := puhvi; puhvi := NIL;
 whither^.bitdepth := 8;
end;

procedure mcg_ExpandIndexed(whither : pbitmaptype);
// Transforms an indexed bitmap into usable 24-bit RGB or 32-bit RGBA.
// (An inverse transition usually requires color compression, try BunComp)
var poku : pointer;
    ivar : dword;
    bvar : byte;
begin
 if whither^.memformat < 2 then exit; // already truecolor
 // Inflate bitdepth to 8 to start with
 if whither^.bitdepth <> 8 then mcg_ExpandBitdepth(whither);

 getmem(poku, whither^.sizex * whither^.sizey * dword(3 + whither^.memformat and 1));

 // Convert indexed
 if whither^.memformat = 4 then begin
  // Indexed to 24-bit RGB
  ivar := whither^.sizex * whither^.sizey;
  while ivar <> 0 do begin
   dec(ivar);
   bvar := byte((whither^.image + ivar)^);
   RGBarray(poku^)[ivar].r := whither^.palette[bvar].r;
   RGBarray(poku^)[ivar].g := whither^.palette[bvar].g;
   RGBarray(poku^)[ivar].b := whither^.palette[bvar].b;
  end;
  whither^.memformat := 0;
  freemem(whither^.image); whither^.image := poku; poku := NIL;
 end;

 if whither^.memformat = 5 then begin
  // Indexed to 32-bit RGBA
  for ivar := whither^.sizex * whither^.sizey - 1 downto 0 do
   dword((poku + ivar * 4)^) := dword(whither^.palette[byte((whither^.image + ivar)^)]);
  whither^.memformat := 1;
  freemem(whither^.image); whither^.image := poku; poku := NIL;
 end;

 // Convert monochrome
 if whither^.memformat = 2 then begin
  // Monochrome to 24-bit RGB
  ivar := whither^.sizex * whither^.sizey;
  while ivar <> 0 do begin
   dec(ivar);
   fillbyte((whither^.image + ivar * 3)^, 3, byte((whither^.image + ivar)^));
  end;
  whither^.memformat := 0;
 end;
 if whither^.memformat = 3 then begin
  // Monochrome to 32-bit RGB
  // this should not happen
  mcg_ErrorTxt := 'Monochrome/alpha!? Contact the author or code a conversion routine.';
 end;
end;

function mcg_MatchColorInPal(color : RGBquad; which : pbitmaptype) : longint;
// bitmaptype(which^) must have its .palette array filled in.
// The function finds the first palette color that matches the given color,
// and returns the 0-based index. In case of errors, it returns a negative
// number and places the explanation in mcg_errortxt.
begin
 if length(which^.palette) = 0 then begin
  mcg_MatchColorInPal := -1; mcg_errortxt := 'MatchColorInPal: given bitmap has no palette!'; exit;
 end;
 mcg_MatchColorInPal := length(which^.palette);
 while mcg_MatchColorInPal <> 0 do begin
  dec(mcg_MatchColorInPal);
  if dword(color) = dword(which^.palette[mcg_MatchColorInPal]) then exit;
 end;
 mcg_MatchColorInPal := -2;
 mcg_errortxt := 'MatchColorInPal: no match found!';
end;

function Openping(whence : pointer; whither : pbitmaptype) : byte;
// Openping accepts a PNG datastream together with a filled PNGHdr record.
// Whence^ needs to contain the PNG image datastream from its IDAT chunks.
// PNGHdr is a private variable record that has the most important image
// definitions. It must be filled in before calling this function.
// The decompressed image goes in bitmaptype(whither^).
// The output format is 24-bit RGB, or 32-bit RGBA if the image has alpha.
// Bitdepths 1, 2, 4 and 8 per sample are supported; interlacing is not.
// OpenPing returns 0 if all OK; otherwise mcg_errortxt is filled.
var ivar, jvar, kvar, x, y : dword;
    lvar : longint;
    bytesperrow, bytesperpixel : dword;
    tempbuf, sofs, dofs : pointer;
    z : tzstream;
    rowfilter : byte;
begin
 openping := 1;
 mcg_errortxt := '';

 bytesperpixel := 1;
 case pnghdr.colortype of
   2: begin // truecolor
       whither^.memformat := 0;
       bytesperpixel := 3;
      end;
   0: begin // monochrome
       whither^.memformat := 2;
      end;
   3: begin // indexed color
       whither^.memformat := 4;
      end;
   55: begin // indexed color that has alpha values in the palette
       whither^.memformat := 5;
      end;
   6: begin // truecolor with alpha channel
       whither^.memformat := 1;
       bytesperpixel := 4;
      end;
   4: mcg_errortxt := 'Greyscale PNGs with full alpha are not supported.';
   else mcg_errortxt := 'Messed up colortype: ' + strdec(pnghdr.colortype);
 end;

 whither^.bitdepth := pnghdr.bitdepth;
 if not pnghdr.bitdepth in [1,2,4,8] then mcg_errortxt := 'Unsupported bits per sample value in PNG! (' + strdec(pnghdr.bitdepth) + ')';
 if pnghdr.compression <> 0 then mcg_errortxt := 'Unknown compression ' + strdec(pnghdr.compression) + ' in PNG!';
 if pnghdr.filter <> 0 then mcg_errortxt := 'Unknown filtering method ' + strdec(pnghdr.filter) + ' in PNG!';
 if pnghdr.interlace <> 0 then mcg_errortxt := 'Interlaced PNGs not supported!';
 if (whither^.sizex = 0) or (whither^.sizey = 0) then mcg_errortxt := 'Image size is zero!';

 if mcg_errortxt <> '' then exit;

 // Decompress the image stream into tempbuf^.
 z.next_in := NIL;
 ivar := inflateInit(z);
 if ivar <> z_OK then begin
  mcg_errortxt := 'Openping: Error while calling inflateInit.'; exit;
 end;

 ivar := whither^.sizex * whither^.sizey * 4 + whither^.sizey;
 getmem(tempbuf, ivar);
 z.next_in := whence;
 z.avail_in := pnghdr.streamlength;
 z.total_in := 0;
 z.next_out := tempbuf;
 z.avail_out := ivar;
 z.total_out := 0;
 ivar := inflate(z, Z_FINISH);
 inflateEnd(z);
 if (ivar <> Z_STREAM_END) and (ivar <> Z_OK) then begin
  mcg_errortxt := 'Openping: Error ' + xlatezerror(ivar) + ' while inflating PNG image!';
  freemem(tempbuf); tempbuf := NIL; exit;
 end;

 case byte(tempbuf^) of
   4: begin
       mcg_errortxt := 'Openping: Paeth filter called on first scanline.';
       freemem(tempbuf); tempbuf := NIL; exit;
      end;
   3: begin
       mcg_errortxt := 'Openping: average filter called on first scanline.';
       freemem(tempbuf); tempbuf := NIL; exit;
      end;
   // Up filter on first row is equivalent to direct copy
   2: byte(tempbuf^) := 0;
 end;

 // Still need to filter the image...
 getmem(whither^.image, whither^.sizex * whither^.sizey * dword(3 + whither^.memformat and 1));

 // calculate how many bytes of pixel data per row
 bytesperrow := whither^.sizex * bytesperpixel;
 if whither^.bitdepth < 8 then bytesperrow := (bytesperrow * whither^.bitdepth + 7) div 8;

 sofs := tempbuf; // reading from tempbuf^
 dofs := whither^.image; // writing into whither^.image^

 for y := whither^.sizey - 1 downto 0 do begin

  // Each row starts with a filter byte
  rowfilter := byte(sofs^); inc(sofs);
  if rowfilter > 4 then begin
   mcg_errortxt := 'Openping: Illegal filter [' + strdec(rowfilter) + '] on image row ' + strdec(longint(whither^.sizey - 1 - y));
   freemem(whither^.image); whither^.image := NIL;
   freemem(tempbuf); tempbuf := NIL; exit;
  end;

  // Copy the row into the final image while applying a filter transform
  case rowfilter of
    // No change, direct copy
    0: begin
        move(sofs^, dofs^, bytesperrow);
        inc(sofs, bytesperrow);
        inc(dofs, bytesperrow);
       end;
    // Subtraction filter
    1: begin
        // first pixel or byte: direct copy
        move(sofs^, dofs^, bytesperpixel);
        inc(sofs, bytesperpixel);
        inc(dofs, bytesperpixel);

        // rest of the row: add the previous pixel or byte to current
        x := bytesperrow - bytesperpixel;
        while x > 0 do begin
         dec(x);
         byte(dofs^) := byte(byte(sofs^) + byte((dofs - bytesperpixel)^));
         inc(sofs); inc(dofs);
        end;
       end;
    // Up filter
    2: begin
        // add each byte from above row to current row
        for x := bytesperrow - 1 downto 0 do begin
         byte(dofs^) := byte(byte(sofs^) + byte((dofs - bytesperrow)^));
         inc(sofs); inc(dofs);
        end;
       end;
    // Average filter
    3: begin
        // first pixel or byte: add half of above pixel or byte to current
        for x := 1 to bytesperpixel do begin
         byte(dofs^) := byte(byte(sofs^) + byte((dofs - bytesperrow)^) shr 1);
         inc(sofs); inc(dofs);
        end;

        // rest of the row: add to the current location the average of the
        // previous and above pixel or byte
        x := bytesperrow - bytesperpixel;
        while x > 0 do begin
         dec(x);
         byte(dofs^) := byte(byte(sofs^) + (byte((dofs - bytesperpixel)^) + byte((dofs - bytesperrow)^)) shr 1);
         inc(sofs); inc(dofs);
        end;
       end;
    // Paeth filter
    4: begin
        // a = byte or pixel before current
        // b = byte or pixel above current
        // c = byte or pixel above a

        // first pixel or byte: add Paeth(0, b, 0) to current
        x := bytesperpixel;
        while x > 0 do begin
         dec(x);
         jvar := byte((dofs - bytesperrow)^); // b
         if jvar = 0
         then byte(dofs^) := byte(sofs^) // add 0
         else byte(dofs^) := byte(byte(sofs^) + jvar); // add b

         inc(sofs); inc(dofs);
        end;

        // rest of the row: add Paeth(a, b, c) to current
        x := bytesperrow - bytesperpixel;
        while x > 0 do begin
         dec(x);
         ivar := byte((dofs - bytesperpixel)^); // a
         jvar := byte((dofs - bytesperrow)^); // b
         kvar := byte((dofs - bytesperrow - bytesperpixel)^); // c
         // (the below longint cast avoids arithmetic overflow on linux64...)
         lvar := longint(ivar + jvar) - kvar; // p = a + b - c
         ivar := abs(lvar - ivar); // pa = abs(p - a)
         jvar := abs(lvar - jvar); // pb = abs(p - b)
         kvar := abs(lvar - kvar); // pc = abs(p - c)

         if (ivar <= jvar) and (ivar <= kvar)
         // add a
         then byte(dofs^) := byte(byte(sofs^) + byte((dofs - bytesperpixel)^))
         else if jvar <= kvar
         // add b
         then byte(dofs^) := byte(byte(sofs^) + byte((dofs - bytesperrow)^))
         else byte(dofs^) := byte(byte(sofs^) + byte((dofs - bytesperrow - bytesperpixel)^));

         inc(sofs); inc(dofs);
        end;
       end;
  end;
 end;

 freemem(tempbuf); tempbuf := NIL;

 // Flip RGB around!
 // PNG stores color values consistently in byte order RGBA.
 // Windows contrarily stores color values in byte order BGRA.
 // (Of course, due to the least-significant byte first order on x86/x64, the
 // first color byte is actually the rightmost when printed as text.
 // Alpha is always stored as the last byte, but printed as the leftmost.)
 if whither^.memformat <= 1 then begin
  sofs := whither^.image;
  dofs := sofs + bytesperrow * whither^.sizey;
  while sofs < dofs do begin
   ivar := byte(sofs^);
   byte(sofs^) := byte((sofs + 2)^);
   byte((sofs + 2)^) := ivar;
   inc(sofs, bytesperpixel);
  end;
 end;

 sofs := NIL; dofs := NIL;

 // Make sure the image will be in 24-bit RGB or 32-bit RGBA format.
 case mcg_AutoConvert of
   1: mcg_ExpandBitdepth(whither);
   2: mcg_ExpandIndexed(whither);
 end;

 openping := 0;
end;

function mcg_PNGtoMemory(readp : pointer; psize : dword; membmp : pbitmaptype) : byte;
// readp must point to a PNG datastream, consisting of the necessary PNG
// chunks to render the picture: IHDR, [PLTE, tRNS], IDAT and IEND. That is,
// a regular PNG file read into memory, with or without the 8-byte sig.
// psize is the size of the data at readp^.
// membmp must point to a record of bitmaptype, as defined in this unit.
// The PNG image from p^ is loaded into membmp^, auto-converted as specified
// by the mcg_AutoConvert variable.
// Membmp^ need not be initialised; if it already points to a graphic, the
// pointers are released first.
// The memory in p^ is not released by this function.
// If mcg_ReadHeaderOnly is non-zero, reads everything except the bitmap.
// PNGtoMemory returns 0 if all OK; otherwise mcg_errortxt is filled.
var chunklen, chunktype, konkeli : dword;
    pend, whence : pointer;
    headerfound : boolean;
begin
 mcg_PNGtoMemory := 1;
 headerfound := FALSE; whence := NIL;
 // Make sure we are not overwriting a graphic; release the memory if we are.
 mcg_ForgetImage(membmp);

 pend := readp + psize;
 repeat
  // Parse the PNG chunks (also recognise PNG signature if encountered).
  // Every chunk has a length dword, an ID dword, a variable length of data,
  // and a CRC dword. (We ignore the CRC.)

  // safety
  if readp + 8 >= pend then break;
  // chunk data length
  chunklen := swapendian(dword(readp^));
  inc(readp, 4);
  // chunk ID
  chunktype := dword(readp^);
  inc(readp, 4);

  // Skip the PNG signature, if encountered.
  if (chunktype = $0A1A0A0D) and (chunklen = $89504E47) then continue;

  // More safety...
  if readp + chunklen >= pend then break;

  case chunktype of
    // IHDR
    $52444849:
    begin
     headerfound := TRUE;
     membmp^.sizex := swapendian(dword(readp^));
     membmp^.sizey := swapendian(dword((readp + 4)^));
     pnghdr.bitdepth := byte((readp + 8)^);
     pnghdr.colortype := byte((readp + 9)^);
     pnghdr.compression := byte((readp + 10)^);
     pnghdr.filter := byte((readp + 11)^);
     pnghdr.interlace := byte((readp + 12)^);
     pnghdr.streamlength := 0;
    end;
    // PLTE
    $45544C50:
    begin
     konkeli := chunklen div 3;
     setlength(membmp^.palette, konkeli);
     while konkeli <> 0 do begin
      dec(konkeli);
      membmp^.palette[konkeli].r := byte((readp + konkeli * 3)^);
      membmp^.palette[konkeli].g := byte((readp + konkeli * 3 + 1)^);
      membmp^.palette[konkeli].b := byte((readp + konkeli * 3 + 2)^);
      membmp^.palette[konkeli].a := $FF;
     end;
    end;
    // IDAT
    $54414449:
    begin
     if mcg_ReadHeaderOnly = 0 then begin
      if pnghdr.streamlength = 0
      then getmem(whence, chunklen)
      else reallocmem(whence, pnghdr.streamlength + chunklen);
      move(readp^, (whence + pnghdr.streamlength)^, chunklen);
     end;
     inc(pnghdr.streamlength, chunklen);
    end;
    // tRNS
    $534E5274:
    if pnghdr.colortype = 3 then begin
     konkeli := chunklen;
     if konkeli > dword(length(membmp^.palette)) then konkeli := length(membmp^.palette);
     while konkeli <> 0 do begin
      dec(konkeli);
      membmp^.palette[konkeli].a := byte((readp + konkeli)^);
     end;
     pnghdr.colortype := 55; // internal: indexed with valid alpha
    end;
    // IEND
    $444E4549: break;
  end;

  // Move read pointer past this chunk's data, and skip the CRC dword.
  inc(readp, chunklen + 4);

 // Break if the input buffy ran out.
 until (readp >= pend);

 // Was a PNG IHDR encountered?
 if headerfound = FALSE then begin
  mcg_errortxt := 'No IHDR chunk found'; exit;
 end;

 // If the caller requested only the PNG header, we're done.
 if mcg_ReadHeaderOnly <> 0 then begin
  mcg_PNGtoMemory := 0; exit;
 end;

 // If the caller wants a usable image, we must have a data stream.
 if pnghdr.streamlength = 0 then begin
  mcg_errortxt := 'No PNG datastream'; exit;
 end;

 // Finally, decompress the image into a bitmap!
 mcg_PNGtoMemory := openping(whence, membmp);
 freemem(whence); whence := NIL;
end;

function mcg_BMPtoMemory(p : pointer; membmp : pbitmaptype) : byte;
// P must point to a BITMAPINFOHEADER structure followed by the bitmap bits,
// or to a BITMAPFILEHEADER followed by a BITMAPINFOHEADER and bitmap bits.
// These are regular Windows device-independent bitmaps.
// membmp must point to a record of my bitmaptype, defined in loder.
// The bitmap from p^ is loaded into membmp^, converted into a bitdepth of
// 24 or 32. Membmp^ need not be initialised; if it already points to
// a graphic, the pointers are released first.
// The memory in p^ is not released by this function.
// BMPtoMemory returns 0 if all OK; otherwise mcg_errortxt is filled.
type bitmapv4header = record
       bV4Size : dword;
       bV4Width, bV4Height : longint;
       bV4Planes : word;
       bV4BitCount : word;
       bV4V4Compression : dword;
       bV4SizeImage : dword;
       bV4XPelsPerMeter, bV4YPelsPerMeter : longint;
       bV4ClrUsed, bV4ClrImportant : dword;
       bV4RedMask, bV4GreenMask, bV4BlueMask, bV4AlphaMask : dword;
       bV4CSType : dword;
       bV4Endpoints : record
         ciexyzRed, ciexyzGreen, ciexyzBlue : record
           ciexyzX, ciexyzY, ciexyzZ : dword;
         end;
       end;
       bV4GammaRed, bV4GammaGreen, bV4GammaBlue : dword;
     end;
const BI_RGB = $0000;
      BI_BITFIELDS = $0003;
var sizu, destofs : dword;
    palsize, yloop : word;
    rmask, gmask, bmask : dword;
    redshift, greenshift, blueshift : byte; // for v4 bitmask shifting
    upsidedown : boolean;
    // although a negative height should imply a top-down DIB, it seems that
    // Windows cannot handle those at least on the clipboard
begin
 mcg_BMPtoMemory := 1;
 // Make sure we are not overwriting a graphic; release the memory if we are.
 mcg_ForgetImage(membmp);
 // Skip the BITMAPFILEHEADER if one exists
 if word(p^) = 19778 then // does it spell BM at the start?
  inc(p, 14);
 // Parse the BITMAPINFOHEADER (it could be a bitmapv4header too though)

 redshift := 0; greenshift := 0; blueshift := 0;
 if bitmapv4header(p^).bv4v4Compression = BI_BITFIELDS then begin
  // DIB v3 bitmaps have the bitmasks as three implicit palette colors;
  // to successfully skip them, we'll pretend they're part of the header.
  if bitmapv4header(p^).bv4size = 40 then inc(bitmapv4header(p^).bv4size, 12);
  // DIB v4 bitmaps have the bitmasks at the exact same byte locations as the
  // first three v3 palette items would be, and they're counted as part of
  // the header's size to begin with.
  rmask := bitmapv4header(p^).bv4redmask;
  gmask := bitmapv4header(p^).bv4greenmask;
  bmask := bitmapv4header(p^).bv4bluemask;
  sizu := rmask;
  if sizu <> 0 then while sizu and 1 = 0 do begin sizu := sizu shr 1; inc(redshift); end;
  sizu := gmask;
  if sizu <> 0 then while sizu and 1 = 0 do begin sizu := sizu shr 1; inc(greenshift); end;
  sizu := bmask;
  if sizu <> 0 then while sizu and 1 = 0 do begin sizu := sizu shr 1; inc(blueshift); end;
 end else
 if bitmapv4header(p^).bv4v4Compression <> BI_RGB then begin
  mcg_errortxt := 'Only uncompressed BI_RGB/BI_BITFIELDS bitmaps are presently supported! This is ' + strdec(bitmapv4header(p^).bv4v4Compression); exit;
 end;

 membmp^.sizex := bitmapv4header(p^).bv4Width;
 membmp^.sizey := abs(bitmapv4header(p^).bv4Height);
 // Most DIBs are stored vertically mirrored...
 if bitmapv4header(p^).bv4Height < 0 then upsidedown := FALSE else upsidedown := TRUE;
 membmp^.bitdepth := bitmapv4header(p^).bv4BitCount;
 // Set sizu to the byte width of one image scanline. For example: an image
 // of bitdepth 4 with a width of 7 pixels will occupy 4 bytes per scanline.
 sizu := (membmp^.sizex * membmp^.bitdepth + 7) shr 3;
 // Bitdepths of 8 or below are an indexed image, and have a palette.
 // Bitdepths of 16-32 mean an RGB image without a palette.
 case membmp^.bitdepth of
   1: begin membmp^.memformat := 4; palsize := 2; end;
   2: begin membmp^.memformat := 4; palsize := 4; end; // unsupported by specs
   4: begin membmp^.memformat := 4; palsize := 16; end;
   8: begin membmp^.memformat := 4; palsize := 256; end;
   // 16: meh; // if you ever come across one, I'll add support for it...
   24: begin membmp^.memformat := 0; palsize := 0; end;
   32: begin membmp^.memformat := 1; palsize := 0; end;
   else begin
    mcg_errortxt := 'Unsupported BMP bitdepth, ' + strdec(membmp^.bitdepth); exit;
   end;
 end;

 // If the colors used variable is nonzero, it defines the real palette size.
 if bitmapv4header(p^).bv4ClrUsed > 0 then palsize := bitmapv4header(p^).bv4ClrUsed;
 if (membmp^.memformat = 4) and (palsize > 0) then setlength(membmp^.palette, palsize);

 // Read the palette into memory
 // Per DIB specs, the alpha byte must be 0 both in the bitmap and palette
 // colors. Some programs put correct alpha data in anyway. With correct
 // alpha, 0 is fully transparent, so if the program reads all DIBs using the
 // alpha channel, fully compliant DIBs will be entirely transparent.
 // If all alpha samples are $FF, then the image is fully opaque.
 // Therefore, assume the image is alphaless, unless any alpha sample is not
 // $FF; and if all alpha is 0, discard the alpha channel.
 inc(p, bitmapv4header(p^).bv4Size);
 destofs := 0;
 if palsize > 0 then begin
  for yloop := 0 to palsize - 1 do begin
   dword(membmp^.palette[yloop]) := dword(p^);

   // Hack the alpha
   if RGBquad(p^).a <> $FF then membmp^.memformat := 5;
   if RGBquad(p^).a = 0 then inc(destofs);
   inc(p, 4);
  end;
  if destofs = palsize then begin
   membmp^.memformat := 4;
   for yloop := palsize - 1 downto 0 do membmp^.palette[yloop].a := $FF;
  end;
 end;

 // P now points to the beginning of the image data.
 // Since DIBs have DWORD-aligned scanlines, we must copy them one at a time
 // and reduce them to BYTE-alignment. Flip the image vertically while at it.
 getmem(membmp^.image, sizu * membmp^.sizey);
 if upsidedown then begin
  destofs := sizu * membmp^.sizey;
  for yloop := membmp^.sizey - 1 downto 0 do begin
   dec(destofs, sizu);
   move(p^, (membmp^.image + destofs)^, sizu);
   inc(p, ((sizu + 3) and $FFFFFFFC));
  end;
 end else begin
  destofs := 0;
  for yloop := membmp^.sizey - 1 downto 0 do begin
   move(p^, (membmp^.image + destofs)^, sizu);
   inc(p, ((sizu + 3) and $FFFFFFFC));
   inc(destofs, sizu);
  end;
 end;

 // Images copied from Opera are saved on the clipboard as 32-bit ARGB DIBs.
 // Irfanview and PSP import them as 24-bit RGB images, ignoring the alpha,
 // as expected by the DIB specs. However, including valid alpha data in an
 // old format DIB is a Microsoft-endorsed hack, since apparently even the
 // native XP printscreen screengrab may have valid alpha data.
 // Version 4 and 5 DIBs have color masks that allow legally defining an
 // alpha channel, but all programs I tried only generate old basic DIBs.
 if membmp^.memformat = 1 then begin
  sizu := 0;
  destofs := membmp^.sizex * membmp^.sizey;
  while destofs <> 0 do begin
   dec(destofs);
   if RGBAarray(membmp^.image^)[destofs].a <> 0 then sizu := sizu or 1;
   if RGBAarray(membmp^.image^)[destofs].a <> $FF then sizu := sizu or 2;
  end;
  // if all alpha data is 0 (fully transparent), or all FF, scrap the channel
  // (not properly tested...)
  if (sizu and 1 = 0) or (sizu and 2 = 0) then begin
   for destofs := 0 to membmp^.sizex * membmp^.sizey - 1 do begin
    RGBarray(membmp^.image^)[destofs].b := RGBAarray(membmp^.image^)[destofs].b;
    RGBarray(membmp^.image^)[destofs].g := RGBAarray(membmp^.image^)[destofs].g;
    RGBarray(membmp^.image^)[destofs].r := RGBAarray(membmp^.image^)[destofs].r;
   end;
   membmp^.memformat := 0;
  end;
 end;

 // Finally, AutoConvert the image format to 8 bpp and maybe even truecolor.
 case mcg_AutoConvert of
   1: mcg_ExpandBitdepth(membmp);
   2: mcg_ExpandIndexed(membmp);
 end;

 mcg_BMPtoMemory := 0;
end;

function mcg_LoadGraphic(p : pointer; psize : dword; membmp : pbitmaptype) : byte;
// This is a general BMP/DIB/PNG loader function.
//
// P must point to a memory area containing a BMP or PNG image. If it is
// a BMP, the data must begin with a BITMAPFILEHEADER (BMP files begin with
// this) or with a BITMAPINFOHEADER (Windows DIBs begin with this, such as
// graphics copied to the clipboard).
// If it is a PNG, the data must begin with the 8-byte PNG signature or
// a recognisable PNG chunk, most likely IHDR.
// psize is the size of the data at p^.
//
// membmp must point to a record of my bitmaptype, as defined by this unit.
// The image format in p^ is identified and the appropriate loader function
// is called; the image goes into membmp^, converted into a bitdepth of
// 24 or 32. Membmp^ need not be initialised; if it already points to
// a graphic, the pointers are released first.
// The memory in p^ is not released by this function.
// If mcg_ReadHeaderOnly is non-zero, reads everything except the bitmap.
//
// LoadGraphic returns 0 if all OK; otherwise mcg_errortxt is filled.
begin
 if (dword(p^) = $474E5089) and (dword((p + 4)^) = $0A1A0A0D)
 or (dword(p^) = $0D000000) and (dword((p + 4)^) = $52444849)
 then
  mcg_LoadGraphic := mcg_PNGtoMemory(p, psize, membmp)
 else
 //if (word(p^) = 19778)
  mcg_LoadGraphic := mcg_BMPtoMemory(p, membmp);
end;

function mcg_MemorytoPNG(membmp : pbitmaptype; p, psizu : pointer) : byte;
// This generates a PNG datastream from the image in bitmaptype(membmp^).
// P must point to a valid pointer variable, set to a NIL value! The function
// reserves memory for the datastream and puts the pointer in pointer(P^).
// The caller is responsible for freeing the memory afterward.
// PSizu must point to a usable DWORD-sized memory area! The function places
// the size in bytes of the resulting datastream into DWORD(PSizu^).
// The function return 0 if all goes well, otherwise mcg_errortxt is filled.
var ivar, jvar, rowsize : dword;
    iofs, dofs : dword;
    poku, tempbuf : pointer;
    z : tzstream;
begin
 // Safety first
 mcg_MemorytoPNG := 1;
 mcg_errortxt := '';
 if membmp^.memformat < 2 then
  if membmp^.bitdepth in [24,32] then membmp^.bitdepth := 8
  else if membmp^.bitdepth < 8 then mcg_errortxt := 'MemorytoPNG: True color images may not have a bitdepth of ' + strdec(membmp^.bitdepth) + '!';
 if membmp^.image = NIL then mcg_errortxt := 'MemorytoPNG: Image bitmap pointer is nil!';
 if membmp^.bitdepth in [1,2,4,8] = FALSE then mcg_errortxt := 'MemorytoPNG: Bitdepth ' + strdec(membmp^.bitdepth) + ' is not supported!';
 if membmp^.memformat in [0..2,4,5] = FALSE then mcg_errortxt := 'MemorytoPNG: Unsupported image format ' + strdec(membmp^.memformat) + '!';
 if (membmp^.sizex = 0) or (membmp^.sizey = 0) then mcg_errortxt := 'MemorytoPNG: image size 0!';
 if mcg_errortxt <> '' then exit;

 // Split the image into scanlines and theoretically filter it -> tempbuf^
 rowsize := 0;
 case membmp^.memformat of
   0: rowsize := membmp^.sizex * 3;
   1: rowsize := membmp^.sizex * 4;
   2,4,5: rowsize := (membmp^.sizex * membmp^.bitdepth + 7) div 8;
 end;
 dword(psizu^) := (rowsize + 1) * membmp^.sizey;
 getmem(tempbuf, dword(psizu^));
 getmem(poku, dword(psizu^) + 65536);

 iofs := 0; dofs := 0;
 if membmp^.memformat = 0 then begin
  // 24-bit RGB
  for ivar := membmp^.sizey - 1 downto 0 do begin
   byte((tempbuf + dofs)^) := 0; inc(dofs); // filter byte = lazy constant 0
   for jvar := membmp^.sizex - 1 downto 0 do begin
    byte((tempbuf + dofs + 2)^) := byte((membmp^.image + iofs    )^); // blue
    byte((tempbuf + dofs + 1)^) := byte((membmp^.image + iofs + 1)^); // green
    byte((tempbuf + dofs    )^) := byte((membmp^.image + iofs + 2)^); // red
    inc(dofs, 3); inc(iofs, 3);
   end;
  end;
 end else
 if membmp^.memformat = 1 then begin
  // 32-bit (in: BGRA; out: RGBA)
  for ivar := membmp^.sizey - 1 downto 0 do begin
   byte((tempbuf + dofs)^) := 0; inc(dofs); // filter byte = lazy constant 0
   for jvar := membmp^.sizex - 1 downto 0 do begin
    byte((tempbuf + dofs + 2)^) := byte((membmp^.image + iofs    )^); // blue
    byte((tempbuf + dofs + 1)^) := byte((membmp^.image + iofs + 1)^); // green
    byte((tempbuf + dofs    )^) := byte((membmp^.image + iofs + 2)^); // red
    byte((tempbuf + dofs + 3)^) := byte((membmp^.image + iofs + 3)^); // alpha
    inc(dofs, 4); inc(iofs, 4);
   end;
  end;
 end else
  // Any-bit indexed
  for ivar := membmp^.sizey - 1 downto 0 do begin
   byte((tempbuf + dofs)^) := 0; inc(dofs); // filter byte = lazy constant 0
   move((membmp^.image + iofs)^, (tempbuf + dofs)^, rowsize);
   inc(iofs, rowsize); inc(dofs, rowsize);
  end;

 // Sic ZLib on the tempbuf^ image
 z.next_in := NIL;
 longint(ivar) := DeflateInit(z, Z_DEFAULT_COMPRESSION);
 if longint(ivar) <> Z_OK then begin
  mcg_errortxt := xlatezerror(longint(ivar));
  freemem(tempbuf); tempbuf := NIL; freemem(poku); poku := NIL; exit;
 end;
 z.next_in := tempbuf;
 z.avail_in := dword(psizu^);
 z.total_in := 0;
 z.next_out := poku;
 z.avail_out := dword(psizu^) + 65536;
 z.total_out := 0;
 longint(ivar) := Deflate(z, z_finish);
 dword(psizu^) := z.total_out;
 freemem(tempbuf); tempbuf := poku; poku := NIL;
 DeflateEnd(z);
 if longint(ivar) <> Z_STREAM_END then begin
  mcg_errortxt := xlatezerror(longint(ivar));
  freemem(tempbuf); tempbuf := NIL; exit;
 end;

 // Calculate the CRC table for PNG creation, if not yet calculated.
 if CRCundone then begin
  for ivar := 0 to 255 do begin
   CRC := ivar;
   for jvar := 0 to 7 do
    if CRC and 1 <> 0 then CRC := $EDB88320 xor (CRC shr 1)
    else CRC := CRC shr 1;
   CRCtable[ivar] := CRC;
  end;
  CRCundone := FALSE;
 end;

 // Reserve memory
 ivar := dword(psizu^) + dword(length(membmp^.palette)) * 4 + 65536;
 pointer(p^) := NIL; getmem(pointer(p^), ivar);
 poku := pointer(p^);

 // PNG signature
 dword(poku^) := $474E5089; inc(poku, 4);
 dword(poku^) := $0A1A0A0D; inc(poku, 4);

 // IHDR
 dword(poku^) := $0D000000; inc(poku, 4); // header.length
 iofs := poku - pointer(p^); // store the offset of CRC start
 dword(poku^) := $52444849; inc(poku, 4); // header.signature
 dword(poku^) := swapendian(dword(membmp^.sizex)); inc(poku, 4); // width
 dword(poku^) := swapendian(dword(membmp^.sizey)); inc(poku, 4); // height
 byte(poku^) := membmp^.bitdepth; inc(poku); // header.bitdepth
 case membmp^.memformat of
   0: byte(poku^) := 2; // truecolor
   1: byte(poku^) := 6; // truecolor with alpha
   2: byte(poku^) := 0; // greyscale
   4,5: byte(poku^) := 3; // indexed-color
 end; inc(poku); // header.colortype
 byte(poku^) := 0; inc(poku); // header.compressionmethod
 byte(poku^) := 0; inc(poku); // header.filtermethod
 byte(poku^) := 0; inc(poku); // header.interlacemethod
 dofs := poku - pointer(p^); CRC := $FFFFFFFF;
 while iofs < dofs do begin
  UpdateCRC(byte((pointer(p^) + iofs)^));
  inc(iofs);
 end;
 dword(poku^) := swapendian(dword(CRC xor $FFFFFFFF)); inc(poku, 4); // CRC

 // PLTE
 if membmp^.memformat and 4 <> 0 then begin
  ivar := length(membmp^.palette); if ivar > 256 then ivar := 256;
  dword(poku^) := swapendian(dword(ivar * 3)); inc(poku, 4); // pal.length
  iofs := poku - pointer(p^); // store the offset of CRC start
  dword(poku^) := $45544C50; inc(poku, 4); // pal.signature
  dofs := 0;
  while dofs < ivar do begin
   byte(poku^) := membmp^.palette[dofs].r; inc(poku);
   byte(poku^) := membmp^.palette[dofs].g; inc(poku);
   byte(poku^) := membmp^.palette[dofs].b; inc(poku);
   inc(dofs);
  end;
  dofs := poku - pointer(p^); CRC := $FFFFFFFF;
  while iofs < dofs do begin
   UpdateCRC(byte((pointer(p^) + iofs)^));
   inc(iofs);
  end;
  dword(poku^) := swapendian(dword(CRC xor $FFFFFFFF)); inc(poku, 4); // CRC
 end;

 // tRNS
 if membmp^.memformat = 5 then begin
  ivar := length(membmp^.palette); if ivar > 256 then ivar := 256;
  dword(poku^) := swapendian(ivar); inc(poku, 4); // transparency.length
  iofs := poku - pointer(p^); // store the offset of CRC start
  dword(poku^) := $534E5274; inc(poku, 4); // transparency.signature
  dofs := 0;
  while dofs < ivar do begin
   byte(poku^) := membmp^.palette[dofs].a;
   inc(poku); inc(dofs);
  end;
  dofs := poku - pointer(p^); CRC := $FFFFFFFF;
  while iofs < dofs do begin
   UpdateCRC(byte((pointer(p^) + iofs)^));
   inc(iofs);
  end;
  dword(poku^) := swapendian(dword(CRC xor $FFFFFFFF)); inc(poku, 4); // CRC
 end;

 // IDAT
 dword(poku^) := swapendian(dword(psizu^)); inc(poku, 4); // imagedata.length
 iofs := poku - pointer(p^); // store the offset of CRC start
 dword(poku^) := $54414449; inc(poku, 4); // imagedata.signature
 move(tempbuf^, poku^, dword(psizu^));
 inc(poku, dword(psizu^)); // the compressed image data itself
 freemem(tempbuf); tempbuf := NIL;
 dofs := poku - pointer(p^); CRC := $FFFFFFFF;
 while iofs < dofs do begin
  UpdateCRC(byte((pointer(p^) + iofs)^));
  inc(iofs);
 end;
 dword(poku^) := swapendian(dword(CRC xor $FFFFFFFF)); inc(poku, 4); // CRC

 // IEND
 dword(poku^) := 0; inc(poku, 4); // end length
 dword(poku^) := $444E4549; inc(poku, 4); // end signature
 dword(poku^) := $826042AE; inc(poku, 4); // end CRC

 // Calculate the final size, and we're done
 dword(psizu^) := poku - pointer(p^);
 poku := NIL;

 mcg_MemorytoPNG := 0;
end;

// ------------------------------------------------------------------
// There Be Scaling Algorithms Here
// ------------------------------------------------------------------

// Thoughts for new BunnyScale:
//
// Double-pass? First pass should calculate all needed pixel diffs and save
// them in a big bitmap... and quickly generate extra few pixels for the
// borders, so it's possible to do a second pass with direct references to
// the diffmap, rather than having to add IF-statements to protect against
// areas too close to the image borders.
// The diffs are I think all calculatable without conditionals, so it doesn't
// have to be super-slow. Only the second pass needs conditionals to check
// for pixel patterns, to identify where to best interpolate.

{$ifdef bonk}
procedure BunnyScale2x32(poku : pbitmaptype);
// Resizes the bitmaptype(poku^) resource to double resolution both axles.
// Uses a sharp scaling algorithm to reduce pixelization without blurring.
var processor : pointer;
    loopx, loopy : word;
    c : dword;
    grid, nextline, source, target, optimus : dword;
    gridbyte, kalk : byte;
    calc : byte; // change to word if allowdiff < 2
begin
 if (poku^.image = NIL) or (poku^.memformat <> 1)
 then exit;

 getmem(processor, poku^.sizex * poku^.sizey * 4 * 4);
 // The edges would not be changed using this algorithm, so pixel-copy them.
 source := 0; target := 0;
 nextline := poku^.sizex * (poku^.sizey - 1);
 grid := nextline * 4;
 optimus := poku^.sizex * 2;
 for loopx := 0 to poku^.sizex - 1 do begin
  c := dword((poku^.image + source * 4)^);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  inc(target);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  dec(target);
  c := dword((poku^.image + (source + nextline) * 4)^);
  inc(target, grid);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  inc(target);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  dec(target, grid - 1);
  inc(source);
 end;

 source := poku^.sizex;
 target := source * 4;
 for loopy := 1 to poku^.sizey - 2 do begin
  c := dword((poku^.image + source * 4)^);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  inc(target);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  inc(target, optimus - 3);

  inc(source, poku^.sizex - 1);
  c := dword((poku^.image + source * 4)^);
  inc(source);

  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  inc(target);
  dword((processor + target * 4)^) := c;
  dword((processor + (target + optimus) * 4)^) := c;
  inc(target, optimus + 1);
 end;

 // Build a 3x3 neighbor grid for all remaining pixels.
 // The grid is packed into 8 bits, where a bit is set if the neighbor pixel
 // has the exact same color as the center pixel. The gridbyte is then used
 // to access a precalculated array which defines how the center pixel will
 // be divided into four new pixels.
 // Gridbyte bits:
 //   7 6 5
 //   4 . 3
 //   2 1 0
 // If a gridbyte bit is set, that color is not the center color.
 source := 0;
 target := poku^.sizex * 4 + 2;
 for loopy := 1 to poku^.sizey - 2 do begin
  for loopx := 1 to poku^.sizex - 2 do begin
   c := dword((poku^.image + (source + poku^.sizex + 1) * 4)^);
   if c shr 24 = 0 then begin
    dword((processor + target * 4)^) := c;
    dword((processor + (target + optimus) * 4)^) := c;
    inc(target);
    dword((processor + target * 4)^) := c;
    dword((processor + (target + optimus) * 4)^) := c;
    inc(target);
    inc(source);
    continue;
   end;
   gridbyte := 0;
   // top left
   calc := (abs(byte(c) - byte(dword((poku^.image + source * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + source * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + source * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := calc;
   // top
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + 1) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + 1) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + 1) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // top right
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + 2) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + 2) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + 2) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // left
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + poku^.sizex) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + poku^.sizex) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + poku^.sizex) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // right
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + poku^.sizex + 2) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + poku^.sizex + 2) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + poku^.sizex + 2) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // bottom left
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + optimus) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + optimus) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + optimus) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // bottom
   inc(optimus);
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + optimus) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + optimus) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + optimus) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // bottom right
   inc(optimus);
   calc := (abs(byte(c) - byte(dword((poku^.image + (source + optimus) * 4)^)))
         + abs(byte(c shr 8) - byte(dword((poku^.image + (source + optimus) * 4)^) shr 8))
         + abs(byte(c shr 16) - byte(dword((poku^.image + (source + optimus) * 4)^) shr 16))) shr allowdiff;
   calc := (calc and $F) or (calc shr 4);
   calc := (calc and $3) or (calc shr 2);
   calc := (calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;

   // Apply the gridbyte!
   // Reduce effect of center pixel?
   // Top left subpixel
   optimus := dword((poku^.image + (source + poku^.sizex) * 4)^);
   kalk := (byte(dword((poku^.image + (source + 1) * 4)^)) * 2 + byte(optimus) * 2 +
            byte(dword((poku^.image + source * 4)^)) + byte(c)) div 6;
   grid := (kalk and sspat[gridbyte][0]) or (byte(c) and (sspat[gridbyte][0] xor $FF));
   kalk := (byte(dword((poku^.image + (source + 1) * 4)^) shr 8) * 2 + byte(optimus shr 8) * 2 +
            byte(dword((poku^.image + source * 4)^) shr 8) + byte(c shr 8)) div 6;
   grid := grid or ((kalk and sspat[gridbyte][0]) or (byte(c shr 8) and (sspat[gridbyte][0] xor $FF))) shl 8;
   kalk := (byte(dword((poku^.image + (source + 1) * 4)^) shr 16) * 2 + byte(optimus shr 16) * 2 +
            byte(dword((poku^.image + source * 4)^) shr 16) + byte(c shr 16)) div 6;
   dword((processor + target * 4)^) := grid or ((kalk and sspat[gridbyte][0]) or (byte(c shr 16) and (sspat[gridbyte][0] xor $FF))) shl 16
        or (c and $FF000000);
   // Top right subpixel
   inc(target);
   optimus := dword((poku^.image + (source + poku^.sizex + 2) * 4)^);
   kalk := (byte(dword((poku^.image + (source + 1) * 4)^)) * 2 + byte(optimus) * 2 +
            byte(dword((poku^.image + (source + 2) * 4)^)) + byte(c)) div 6;
   grid := (kalk and sspat[gridbyte][1]) or (byte(c) and (sspat[gridbyte][1] xor $FF));
   kalk := (byte(dword((poku^.image + (source + 1) * 4)^) shr 8) * 2 + byte(optimus shr 8) * 2 +
            byte(dword((poku^.image + (source + 2) * 4)^) shr 8) + byte(c shr 8)) div 6;
   grid := grid or ((kalk and sspat[gridbyte][1]) or (byte(c shr 8) and (sspat[gridbyte][1] xor $FF))) shl 8;
   kalk := (byte(dword((poku^.image + (source + 1) * 4)^) shr 16) * 2 + byte(optimus shr 16) * 2 +
            byte(dword((poku^.image + (source + 2) * 4)^) shr 16) + byte(c shr 16)) div 6;
   dword((processor + target * 4)^) := grid or ((kalk and sspat[gridbyte][1]) or (byte(c shr 16) and (sspat[gridbyte][1] xor $FF))) shl 16
        or (c and $FF000000);
   // Bottom right subpixel
   inc(target, dword(poku^.sizex * 2));
   optimus := dword((poku^.image + (source + poku^.sizex * 2 + 1) * 4)^);
   kalk := (byte(optimus) * 2 + byte(dword((poku^.image + (source + poku^.sizex + 2) * 4)^)) * 2 +
            byte(dword((poku^.image + (source + poku^.sizex * 2 + 2) * 4)^)) + byte(c)) div 6;
   grid := (kalk and sspat[gridbyte][2]) or (byte(c) and (sspat[gridbyte][2] xor $FF));
   kalk := (byte(optimus shr 8) * 2 + byte(dword((poku^.image + (source + poku^.sizex + 2) * 4)^) shr 8) * 2 +
            byte(dword((poku^.image + (source + poku^.sizex * 2 + 2) * 4)^) shr 8) + byte(c shr 8)) div 6;
   grid := grid or ((kalk and sspat[gridbyte][2]) or (byte(c shr 8) and (sspat[gridbyte][2] xor $FF))) shl 8;
   kalk := (byte(optimus shr 16) * 2 + byte(dword((poku^.image + (source + poku^.sizex + 2) * 4)^) shr 16) * 2 +
            byte(dword((poku^.image + (source + poku^.sizex * 2 + 2) * 4)^) shr 16) + byte(c shr 16)) div 6;
   dword((processor + target * 4)^) := grid or ((kalk and sspat[gridbyte][2]) or (byte(c shr 16) and (sspat[gridbyte][2] xor $FF))) shl 16
        or (c and $FF000000);
   // Bottom left subpixel
   dec(target);
   kalk := (byte(optimus) * 2 + byte(dword((poku^.image + (source + poku^.sizex) * 4)^)) * 2 +
            byte(dword((poku^.image + (source + poku^.sizex * 2) * 4)^)) + byte(c)) div 6;
   grid := (kalk and sspat[gridbyte][3]) or (byte(c) and (sspat[gridbyte][3] xor $FF));
   kalk := (byte(optimus shr 8) * 2 + byte(dword((poku^.image + (source + poku^.sizex) * 4)^) shr 8) * 2 +
            byte(dword((poku^.image + (source + poku^.sizex * 2) * 4)^) shr 8) + byte(c shr 8)) div 6;
   grid := grid or ((kalk and sspat[gridbyte][3]) or (byte(c shr 8) and (sspat[gridbyte][3] xor $FF))) shl 8;
   kalk := (byte(optimus shr 16) * 2 + byte(dword((poku^.image + (source + poku^.sizex) * 4)^) shr 16) * 2 +
            byte(dword((poku^.image + (source + poku^.sizex * 2) * 4)^) shr 16) + byte(c shr 16)) div 6;
   dword((processor + target * 4)^) := grid or ((kalk and sspat[gridbyte][3]) or (byte(c shr 16) and (sspat[gridbyte][3] xor $FF))) shl 16
        or (c and $FF000000);

   optimus := poku^.sizex * 2;
   inc(source);
   dec(target, optimus - 2);
  end;
  inc(source, 2);
  inc(target, optimus + 4);
 end;

 poku^.sizex := poku^.sizex * 2;
 poku^.sizey := poku^.sizey * 2;
 freemem(poku^.image);
 poku^.image := processor; processor := NIL;
end;

procedure BunnyScale2x24(poku : pbitmaptype);
// Resizes the bitmaptype(poku^) resource to double resolution both axles.
// Uses a sharp scaling algorithm to reduce pixelization without blurring.
var processor : pointer;
    loopx, loopy : word;
    c : RGBtriplet;
    grid, nextline, source, target, optimus : dword;
    gridbyte, kalk : byte;
    calc : byte; // change to word if allowdiff < 2
begin
 if (poku^.image = NIL) or (poku^.memformat <> 0)
 then exit;

 getmem(processor, poku^.sizex * poku^.sizey * 4 * 3);
 // The edges would not be changed using this algorithm, so pixel-copy them.
 source := 0; target := 0;
 nextline := poku^.sizex * (poku^.sizey - 1);
 grid := nextline * 4;
 optimus := poku^.sizex * 2;
 for loopx := 0 to poku^.sizex - 1 do begin
  c := RGBarray(poku^.image^)[source];
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  inc(target);
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  dec(target);
  c := RGBarray(poku^.image^)[source + nextline];
  inc(target, grid);
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  inc(target);
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  dec(target, grid - 1);
  inc(source);
 end;

 source := poku^.sizex;
 target := source * 4;
 for loopy := 1 to poku^.sizey - 2 do begin
  c := RGBarray(poku^.image^)[source];
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  inc(target);
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  inc(target, optimus - 3);

  inc(source, dword(poku^.sizex - 1));
  c := RGBarray(poku^.image^)[source];
  inc(source);

  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  inc(target);
  RGBarray(processor^)[target] := c;
  RGBarray(processor^)[target + optimus] := c;
  inc(target, optimus + 1);
 end;

 // Build a 3x3 neighbor grid for all remaining pixels.
 // The grid is packed into 8 bits, where a bit is set if the neighbor pixel
 // has the exact same color as the center pixel. The gridbyte is then used
 // to access a precalculated array which defines how the center pixel will
 // be divided into four new pixels.
 // Gridbyte bits:
 //   7 6 5
 //   4 . 3
 //   2 1 0
 // If a gridbyte bit is set, that color is not the center color.
 source := 0;
 target := poku^.sizex * 4 + 2;
 for loopy := 1 to poku^.sizey - 2 do begin
  for loopx := 1 to poku^.sizex - 2 do begin
   c := RGBarray(poku^.image^)[source + poku^.sizex + 1];
   gridbyte := 0;
   // top left
   calc := (abs(c.r - RGBarray(poku^.image^)[source].r)
         + abs(c.g - RGBarray(poku^.image^)[source].g)
         + abs(c.b - RGBarray(poku^.image^)[source].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := calc;
   // top
   calc := (abs(c.r - RGBarray(poku^.image^)[source + 1].r)
         + abs(c.g - RGBarray(poku^.image^)[source + 1].g)
         + abs(c.b - RGBarray(poku^.image^)[source + 1].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // top right
   calc := (abs(c.r - RGBarray(poku^.image^)[source + 2].r)
         + abs(c.g - RGBarray(poku^.image^)[source + 2].g)
         + abs(c.b - RGBarray(poku^.image^)[source + 2].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // left
   calc := (abs(c.r - RGBarray(poku^.image^)[source + poku^.sizex].r)
         + abs(c.g - RGBarray(poku^.image^)[source + poku^.sizex].g)
         + abs(c.b - RGBarray(poku^.image^)[source + poku^.sizex].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // right
   calc := (abs(c.r - RGBarray(poku^.image^)[source + poku^.sizex + 2].r)
         + abs(c.g - RGBarray(poku^.image^)[source + poku^.sizex + 2].g)
         + abs(c.b - RGBarray(poku^.image^)[source + poku^.sizex + 2].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // bottom left
   calc := (abs(c.r - RGBarray(poku^.image^)[source + optimus].r)
         + abs(c.g - RGBarray(poku^.image^)[source + optimus].g)
         + abs(c.b - RGBarray(poku^.image^)[source + optimus].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // bottom
   inc(optimus);
   calc := (abs(c.r - RGBarray(poku^.image^)[source + optimus].r)
         + abs(c.g - RGBarray(poku^.image^)[source + optimus].g)
         + abs(c.b - RGBarray(poku^.image^)[source + optimus].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;
   // bottom right
   inc(optimus);
   calc := (abs(c.r - RGBarray(poku^.image^)[source + optimus].r)
         + abs(c.g - RGBarray(poku^.image^)[source + optimus].g)
         + abs(c.b - RGBarray(poku^.image^)[source + optimus].b)) shr allowdiff;
   calc := dword(calc and $F) or (calc shr 4);
   calc := dword(calc and $3) or (calc shr 2);
   calc := dword(calc and $1) or (calc shr 1);
   gridbyte := (gridbyte shl 1) or calc;

   // Apply the gridbyte!
   // Top left subpixel
   optimus := source + poku^.sizex;
   kalk := (RGBarray(poku^.image^)[source + 1].r * 2 + RGBarray(poku^.image^)[optimus].r * 2 +
            RGBarray(poku^.image^)[source].r + c.r) div 6;
   RGBarray(processor^)[target].r := (kalk and sspat[gridbyte][0]) or (c.r and (sspat[gridbyte][0] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + 1].g * 2 + RGBarray(poku^.image^)[optimus].g * 2 +
            RGBarray(poku^.image^)[source].g + c.g) div 6;
   RGBarray(processor^)[target].g := (kalk and sspat[gridbyte][0]) or (c.g and (sspat[gridbyte][0] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + 1].b * 2 + RGBarray(poku^.image^)[optimus].b * 2 +
            RGBarray(poku^.image^)[source].b + c.b) div 6;
   RGBarray(processor^)[target].b := (kalk and sspat[gridbyte][0]) or (c.b and (sspat[gridbyte][0] xor $FF));
   // Top right subpixel
   inc(target);
   inc(optimus, 2); // := source + poku^.sizex + 2;
   kalk := (RGBarray(poku^.image^)[source + 1].r * 2 + RGBarray(poku^.image^)[optimus].r * 2 +
            RGBarray(poku^.image^)[source + 2].r + c.r) div 6;
   RGBarray(processor^)[target].r := (kalk and sspat[gridbyte][1]) or (c.r and (sspat[gridbyte][1] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + 1].g * 2 + RGBarray(poku^.image^)[optimus].g * 2 +
            RGBarray(poku^.image^)[source + 2].g + c.g) div 6;
   RGBarray(processor^)[target].g := (kalk and sspat[gridbyte][1]) or (c.g and (sspat[gridbyte][1] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + 1].b * 2 + RGBarray(poku^.image^)[optimus].b * 2 +
            RGBarray(poku^.image^)[source + 2].b + c.b) div 6;
   RGBarray(processor^)[target].b := (kalk and sspat[gridbyte][1]) or (c.b and (sspat[gridbyte][1] xor $FF));
   // Bottom right subpixel
   optimus := poku^.sizex * 2;
   inc(target, optimus);
   inc(optimus);
   kalk := (RGBarray(poku^.image^)[source + optimus].r * 2 + RGBarray(poku^.image^)[source + poku^.sizex + 2].r * 2 +
            RGBarray(poku^.image^)[source + optimus + 1].r + c.r) div 6;
   RGBarray(processor^)[target].r := (kalk and sspat[gridbyte][2]) or (c.r and (sspat[gridbyte][2] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + optimus].g * 2 + RGBarray(poku^.image^)[source + poku^.sizex + 2].g * 2 +
            RGBarray(poku^.image^)[source + optimus + 1].g + c.g) div 6;
   RGBarray(processor^)[target].g := (kalk and sspat[gridbyte][2]) or (c.g and (sspat[gridbyte][2] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + optimus].b * 2 + RGBarray(poku^.image^)[source + poku^.sizex + 2].b * 2 +
            RGBarray(poku^.image^)[source + optimus + 1].b + c.b) div 6;
   RGBarray(processor^)[target].b := (kalk and sspat[gridbyte][2]) or (c.b and (sspat[gridbyte][2] xor $FF));
   // Bottom left subpixel
   dec(optimus);
   dec(target);
   kalk := (RGBarray(poku^.image^)[source + optimus + 1].r * 2 + RGBarray(poku^.image^)[source + poku^.sizex].r * 2 +
            RGBarray(poku^.image^)[source + optimus].r + c.r) div 6;
   RGBarray(processor^)[target].r := (kalk and sspat[gridbyte][3]) or (c.r and (sspat[gridbyte][3] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + optimus + 1].g * 2 + RGBarray(poku^.image^)[source + poku^.sizex].g * 2 +
            RGBarray(poku^.image^)[source + optimus].g + c.g) div 6;
   RGBarray(processor^)[target].g := (kalk and sspat[gridbyte][3]) or (c.g and (sspat[gridbyte][3] xor $FF));
   kalk := (RGBarray(poku^.image^)[source + optimus + 1].b * 2 + RGBarray(poku^.image^)[source + poku^.sizex].b * 2 +
            RGBarray(poku^.image^)[source + optimus].b + c.b) div 6;
   RGBarray(processor^)[target].b := (kalk and sspat[gridbyte][3]) or (c.b and (sspat[gridbyte][3] xor $FF));

   inc(source);
   dec(target, optimus - 2);
  end;
  inc(source, 2);
  inc(target, optimus + 4);
 end;

 poku^.sizex := poku^.sizex * 2;
 poku^.sizey := poku^.sizey * 2;
 freemem(poku^.image);
 poku^.image := processor; processor := NIL;
end;
{$endif}

procedure mcg_EPScale32(poku : pbitmaptype; tox, toy : word);
// Resizes the bitmaptype(poku^) resource to tox:toy resolution.
// Uses a weighed average of 2x2 pixel matrices, reducing the importance of
// any pixels in the matrix whose color differs too much from the top left
// pixel. The end result makes the edges a little sharper than cosine
// interpolation, while very slightly anti-aliasing jagged lines.
// Downscaling images with this will not give optimal results, since this
// does not stack values over pixel spans.
var processor, target : pointer;
    loopx, loopy : word;
    source, ysource : dword;
    x1, y1, r1, g1, b1, a1, stacksize, diff : dword;
    cr, cg, cb, ca, r2, g2, b2, a2 : byte;
    t1, t2, t3 : byte;
begin
 if (poku^.image = NIL) or (poku^.memformat <> 1) or (tox or toy = 0)
 then exit;

 getmem(processor, tox * toy * 4);

 target := processor;
 for loopy := 0 to toy - 1 do begin
  y1 := (loopy shl 8) * word(poku^.sizey - 1) div word(toy - 1);
  ysource := (y1 shr 8) * poku^.sizex;
  for loopx := 0 to tox - 1 do begin
   x1 := (loopx shl 8) * word(poku^.sizex - 1) div word(tox - 1);
   // X1,Y1 is now the subpixel in the original with the value to stick in
   // the scaled image at loopx,loopy; subpixel accuracy = fixed point 16.8
   source := (ysource + (x1 shr 8)) * 4;
   t2 := x1 and $FF;
   t1 := t2 xor $FF;
   t3 := (y1 and $FF) xor $FF;

   cr := byte((poku^.image + source)^);
   cg := byte((poku^.image + source + 1)^);
   cb := byte((poku^.image + source + 2)^);
   ca := byte((poku^.image + source + 3)^);
   r1 := (cr * t1 * t3); g1 := (cg * t1 * t3); b1 := (cb * t1 * t3); a1 := (ca * t1 * t3);
   stacksize := t1 * t3;

   r2 := byte((poku^.image + source + 4)^);
   g2 := byte((poku^.image + source + 5)^);
   b2 := byte((poku^.image + source + 6)^);
   a2 := byte((poku^.image + source + 7)^);
   diff := abs(cr - r2) + abs(cg - g2) + abs(cb - b2);
   if diff shr allowdiff <> 0 then diff := (t2 * t3) shr 1 else diff := t2 * t3;

   inc(r1, r2 * diff); inc(g1, g2 * diff); inc(b1, b2 * diff); inc(a1, a2 * diff);
   inc(stacksize, diff);

   inc(source, dword(poku^.sizex * 4));
   t3 := t3 xor $FF;

   r2 := byte((poku^.image + source)^);
   g2 := byte((poku^.image + source + 1)^);
   b2 := byte((poku^.image + source + 2)^);
   a2 := byte((poku^.image + source + 3)^);
   diff := abs(cr - r2) + abs(cg - g2) + abs(cb - b2);
   if diff shr allowdiff <> 0 then diff := (t1 * t3) shr 1 else diff := t1 * t3;

   inc(r1, r2 * diff); inc(g1, g2 * diff); inc(b1, b2 * diff); inc(a1, a2 * diff);
   inc(stacksize, diff);

   r2 := byte((poku^.image + source + 4)^);
   g2 := byte((poku^.image + source + 5)^);
   b2 := byte((poku^.image + source + 6)^);
   a2 := byte((poku^.image + source + 7)^);
   diff := abs(cr - r2) + abs(cg - g2) + abs(cb - b2);
   if diff shr allowdiff <> 0 then diff := (t2 * t3) shr 2 else diff := t2 * t3;

   inc(r1, r2 * diff); inc(g1, g2 * diff); inc(b1, b2 * diff); inc(a1, a2 * diff);
   inc(stacksize, diff);

   byte(target^) := r1 div stacksize;
   inc(target);
   byte(target^) := g1 div stacksize;
   inc(target);
   byte(target^) := b1 div stacksize;
   inc(target);
   byte(target^) := a1 div stacksize;
   inc(target);
  end;
 end;

 poku^.sizex := tox; poku^.sizey := toy;
 freemem(poku^.image);
 poku^.image := processor; processor := NIL;
end;

procedure mcg_EPScale24(poku : pbitmaptype; tox, toy : word);
// Resizes the bitmaptype(poku^) resource to tox:toy resolution.
// Uses a weighed average of 2x2 pixel matrices, reducing the importance of
// any pixels in the matrix whose color differs too much from the top left
// pixel. The end result makes the edges a little sharper than cosine
// interpolation, while very slightly anti-aliasing jagged lines.
// Downscaling images with this will not give optimal results, since this
// does not stack values over pixel spans.
var processor, target : pointer;
    loopx, loopy : word;
    source, ysource : dword;
    x1, y1, r1, g1, b1, stacksize, diff : dword;
    cr, cg, cb, r2, g2, b2 : byte;
    t1, t2, t3 : byte;
begin
 if (poku^.image = NIL) or (poku^.memformat <> 0) or (tox or toy = 0)
 then exit;

 getmem(processor, tox * toy * 3);

 target := processor;
 for loopy := 0 to toy - 1 do begin
  y1 := (loopy shl 8) * word(poku^.sizey - 1) div word(toy - 1);
  ysource := ((y1 shr 8) * poku^.sizex) * 3;
  for loopx := 0 to tox - 1 do begin
   x1 := (loopx shl 8) * word(poku^.sizex - 1) div word(tox - 1);
   // X1,Y1 is now the subpixel in the original with the value to stick in
   // the scaled image at loopx,loopy; subpixel accuracy = fixed point 16.8
   source := ysource + (x1 shr 8) * 3;
   t2 := x1 and $FF;
   t1 := t2 xor $FF;
   t3 := (y1 and $FF) xor $FF;

   cr := byte((poku^.image + source)^);
   cg := byte((poku^.image + source + 1)^);
   cb := byte((poku^.image + source + 2)^);
   r1 := (cr * t1 * t3); g1 := (cg * t1 * t3); b1 := (cb * t1 * t3);
   stacksize := t1 * t3;

   r2 := byte((poku^.image + source + 3)^);
   g2 := byte((poku^.image + source + 4)^);
   b2 := byte((poku^.image + source + 5)^);
   diff := abs(cr - r2) + abs(cg - g2) + abs(cb - b2);
   if diff shr allowdiff <> 0 then diff := (t2 * t3) shr 1 else diff := t2 * t3;

   inc(r1, r2 * diff); inc(g1, g2 * diff); inc(b1, b2 * diff);
   inc(stacksize, diff);

   inc(source, dword(poku^.sizex * 3));
   t3 := t3 xor $FF;

   r2 := byte((poku^.image + source)^);
   g2 := byte((poku^.image + source + 1)^);
   b2 := byte((poku^.image + source + 2)^);
   diff := abs(cr - r2) + abs(cg - g2) + abs(cb - b2);
   if diff shr allowdiff <> 0 then diff := (t1 * t3) shr 1 else diff := t1 * t3;

   inc(r1, r2 * diff); inc(g1, g2 * diff); inc(b1, b2 * diff);
   inc(stacksize, diff);

   r2 := byte((poku^.image + source + 3)^);
   g2 := byte((poku^.image + source + 4)^);
   b2 := byte((poku^.image + source + 5)^);
   diff := abs(cr - r2) + abs(cg - g2) + abs(cb - b2);
   if diff shr allowdiff <> 0 then diff := (t2 * t3) shr 2 else diff := t2 * t3;

   inc(r1, r2 * diff); inc(g1, g2 * diff); inc(b1, b2 * diff);
   inc(stacksize, diff);

   byte(target^) := r1 div stacksize;
   inc(target);
   byte(target^) := g1 div stacksize;
   inc(target);
   byte(target^) := b1 div stacksize;
   inc(target);
  end;
 end;

 poku^.sizex := tox; poku^.sizey := toy;
 freemem(poku^.image);
 poku^.image := processor; processor := NIL;
end;

procedure mcg_ScaleBitmapCos32(poku : pbitmaptype; tox, toy : word);
// Resizes the bitmaptype(poku^) resource to tox:toy resolution.
// Uses immediate cosine interpolation.
// Downscaling images with this will not give optimal results, since this
// does not stack values over pixel spans.
var processor, target : pointer;
    loopx, loopy : word;
    ysource, source : dword;
    x1, y1, r1, r2, g1, g2, b1, b2, a1, a2, p1, p2 : dword;
    cos1, cos2 : byte;
begin
 if (poku^.image = NIL) or (poku^.memformat <> 1) or (tox or toy = 0)
 then exit;

 getmem(processor, tox * toy * 4);

 target := processor;
 for loopy := 0 to toy - 1 do begin
  y1 := (loopy shl 8) * word(poku^.sizey - 1) div word(toy - 1);
  ysource := (y1 shr 8) * poku^.sizex;
  for loopx := 0 to tox - 1 do begin
   x1 := (loopx shl 8) * word(poku^.sizex - 1) div word(tox - 1);
   // X1,Y1 is now the subpixel in the original with the value to stick in
   // the scaled image at loopx,loopy; subpixel accuracy = fixed point 16.8
   source := ysource + (x1 shr 8);
   cos1 := mcg_costable[x1 and $FF] shr 8;
   cos2 := cos1 xor $FF;
   p1 := dword((poku^.image + source * 4)^);
   p2 := dword((poku^.image + (source + 1) * 4)^);
   r1 := byte(p1) * cos1 + byte(p2) * cos2;
   p1 := p1 shr 8; p2 := p2 shr 8;
   g1 := byte(p1) * cos1 + byte(p2) * cos2;
   p1 := p1 shr 8; p2 := p2 shr 8;
   b1 := byte(p1) * cos1 + byte(p2) * cos2;
   p1 := p1 shr 8; p2 := p2 shr 8;
   a1 := byte(p1) * cos1 + byte(p2) * cos2;
   inc(source, poku^.sizex);
   p1 := dword((poku^.image + source * 4)^);
   p2 := dword((poku^.image + (source + 1) * 4)^);
   r2 := byte(p1) * cos1 + byte(p2) * cos2;
   p1 := p1 shr 8; p2 := p2 shr 8;
   g2 := byte(p1) * cos1 + byte(p2) * cos2;
   p1 := p1 shr 8; p2 := p2 shr 8;
   b2 := byte(p1) * cos1 + byte(p2) * cos2;
   p1 := p1 shr 8; p2 := p2 shr 8;
   a2 := byte(p1) * cos1 + byte(p2) * cos2;
   cos1 := mcg_costable[y1 and $FF] shr 8;
   cos2 := cos1 xor $FF;
   byte(target^) := (r1 * cos1 + r2 * cos2) shr 16;
   inc(target);
   byte(target^) := (g1 * cos1 + g2 * cos2) shr 16;
   inc(target);
   byte(target^) := (b1 * cos1 + b2 * cos2) shr 16;
   inc(target);
   byte(target^) := (a1 * cos1 + a2 * cos2) shr 16;
   inc(target);
  end;
 end;

 poku^.sizex := tox; poku^.sizey := toy;
 freemem(poku^.image);
 poku^.image := processor; processor := NIL;
end;

procedure mcg_ScaleBitmapCos24(poku : pbitmaptype; tox, toy : word);
// Resizes the bitmaptype(poku^) resource to tox:toy resolution.
// Uses immediate cosine interpolation.
// Downscaling images with this will not give optimal results, since this
// does not stack values over pixel spans.
var processor, target : pointer;
    loopx, loopy : word;
    source, ysource : dword;
    x1, y1, r1, r2, g1, g2, b1, b2 : dword;
    cos1, cos2 : byte;
begin
 if (poku^.image = NIL) or (poku^.memformat <> 0) or (tox or toy = 0)
 then exit;

 getmem(processor, tox * toy * 3);

 target := processor;
 for loopy := 0 to toy - 1 do begin
  y1 := (loopy shl 8) * word(poku^.sizey - 1) div word(toy - 1);
  ysource := ((y1 shr 8) * poku^.sizex) * 3;
  for loopx := 0 to tox - 1 do begin
   x1 := (loopx shl 8) * word(poku^.sizex - 1) div word(tox - 1);
   // X1,Y1 is now the subpixel in the original with the value to stick in
   // the scaled image at loopx,loopy; subpixel accuracy = fixed point 16.8
   source := ysource + (x1 shr 8) * 3;
   cos1 := mcg_costable[x1 and $FF] shr 8;
   cos2 := cos1 xor $FF;
   r1 := byte((poku^.image + source)^) * cos1
       + byte((poku^.image + source + 3)^) * cos2;
   g1 := byte((poku^.image + source + 1)^) * cos1
       + byte((poku^.image + source + 4)^) * cos2;
   b1 := byte((poku^.image + source + 2)^) * cos1
       + byte((poku^.image + source + 5)^) * cos2;
   inc(source, dword(poku^.sizex * 3));
   r2 := byte((poku^.image + source)^) * cos1
       + byte((poku^.image + source + 3)^) * cos2;
   g2 := byte((poku^.image + source + 1)^) * cos1
       + byte((poku^.image + source + 4)^) * cos2;
   b2 := byte((poku^.image + source + 2)^) * cos1
       + byte((poku^.image + source + 5)^) * cos2;
   cos1 := mcg_costable[y1 and $FF] shr 8;
   cos2 := cos1 xor $FF;
   byte(target^) := (r1 * cos1 + r2 * cos2) shr 16; inc(target);
   byte(target^) := (g1 * cos1 + g2 * cos2) shr 16; inc(target);
   byte(target^) := (b1 * cos1 + b2 * cos2) shr 16; inc(target);
  end;
 end;

 poku^.sizex := tox; poku^.sizey := toy;
 freemem(poku^.image);
 poku^.image := processor; processor := NIL;
end;

procedure mcg_ScaleBitmapCos(poku : pbitmaptype; tox, toy : word);
begin
 if poku^.image = NIL then begin
  mcg_errortxt := 'Image pointer is NIL'; exit;
 end;
 if (tox = 0) or (toy = 0) then begin
  mcg_errortxt := 'Target size cannot be 0'; exit;
 end;

 case poku^.memformat of
   0: mcg_ScaleBitmapCos24(poku, tox, toy);
   1: mcg_ScaleBitmapCos32(poku, tox, toy);
   else begin
    mcg_errortxt := 'Image memformat must be 0 or 1'; exit;
   end;
 end;
end;

procedure mcg_ScaleBitmap24(poku : pbitmaptype; tox, toy : dword);
// Resize procedure called by mcg_ScaleBitmap.
var workbuf, srcp, destp : pointer;
    loopx, loopy : dword;
    start, finish, span : dword;
    a, b, c, d, e, f, g : dword;
begin
 if (poku^.image = NIL) or (poku^.memformat <> 0) or (tox or toy = 0)
 then exit;

 // Adjust image horizontally from poku^ into workbuf.
 if tox > poku^.sizex then begin
  start := 0;
  a := tox * 3;
  b := poku^.sizex * 3;
  g := poku^.sizey * a;
  // Horizontal stretch
  getmem(workbuf, g);
  destp := workbuf;
  span := (poku^.sizex shl 15) div tox;
  for loopx := tox - 1 downto 0 do begin
   finish := start + span - 1;
   srcp := poku^.image + (start shr 15) * 3;
   if start and $FFFF8000 = finish and $FFFF8000 then begin
    // start and finish are in the same source pixel column
    for loopy := poku^.sizey - 1 downto 0 do begin
     word(destp^) := word(srcp^);
     byte((destp + 2)^) := byte((srcp + 2)^);
     inc(srcp, b);
     inc(destp, a);
    end;
   end else begin
    // start and finish are in two adjacent source pixel columns
    c := (start and $7FFF) xor $7FFF; // weight of left column
    d := (finish and $7FFF); // weight of right column
    e := c + d; // total weight for dividing
    c := (c shl 15) div e; // 32k weight of left column
    d := (d shl 15) div e; // 32k weight of right column
    for loopy := poku^.sizey - 1 downto 0 do begin
     byte((destp    )^) := (byte((srcp    )^) * c + byte((srcp + 3)^) * d) shr 15;
     byte((destp + 1)^) := (byte((srcp + 1)^) * c + byte((srcp + 4)^) * d) shr 15;
     byte((destp + 2)^) := (byte((srcp + 2)^) * c + byte((srcp + 5)^) * d) shr 15;
     inc(srcp, b);
     inc(destp, a);
    end;
   end;
   dec(destp, g);
   inc(start, span);
   inc(destp, 3);
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end else

 if tox < poku^.sizex then begin
  // Horizontal shrink
  getmem(workbuf, tox * poku^.sizey * 3);
  destp := workbuf;
  span := (poku^.sizex shl 15) div tox;
  for loopy := poku^.sizey - 1 downto 0 do begin
   start := 0;
   b := (poku^.sizey - 1 - loopy) * poku^.sizex;
   for loopx := tox - 1 downto 0 do begin
    finish := start + span - 1;
    srcp := poku^.image + (start shr 15 + b) * 3;
    // left edge
    c := (start and $7FFF) xor $7FFF; // weight of left column
    // (c is also accumulated weight for this pixel)
    d := byte(srcp^) * c;
    e := byte(srcp^) * c;
    f := byte(srcp^) * c;
    // full middle columns
    a := start shr 15 + 1;
    while a < finish shr 15 do begin
     inc(c, $8000); // accumulate weight
     inc(d, byte(srcp^) shl 15); inc(srcp);
     inc(e, byte(srcp^) shl 15); inc(srcp);
     inc(f, byte(srcp^) shl 15); inc(srcp);
     inc(a);
    end;
    // right edge
    a := (finish and $7FFF); // weight of right column
    inc(c, a); // accumulate weight
    inc(d, byte(srcp^) * a); inc(srcp);
    inc(e, byte(srcp^) * a); inc(srcp);
    inc(f, byte(srcp^) * a);
    // save result
    byte(destp^) := d div c; inc(destp);
    byte(destp^) := e div c; inc(destp);
    byte(destp^) := f div c; inc(destp);
    inc(start, span);
   end;
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end;

 // else... Horizontal change is unnecessary.
 poku^.sizex := tox;

 // Adjust image vertically from poku^ into workbuf.
 start := 0;
 b := poku^.sizex * 3;
 if toy > poku^.sizey then begin
  // Vertical stretch
  getmem(workbuf, b * toy);
  destp := workbuf;
  span := (poku^.sizey shl 15) div toy;
  for loopy := toy - 1 downto 0 do begin
   finish := start + span - 1;
   srcp := poku^.image + (start shr 15) * b;
   if start and $FFFF8000 = finish and $FFFF8000 then begin
    // start and finish are on the same source pixel row
    move(srcp^, destp^, b);
    inc(destp, b);
   end else begin
    // start and finish are on two adjacent source pixel rows
    c := (start and $7FFF) xor $7FFF; // weight of upper row
    d := (finish and $7FFF); // weight of lower row
    e := c + d; // total weight for dividing
    c := (c shl 15) div e; // 32k weight of left column
    d := (d shl 15) div e; // 32k weight of right column
    for loopx := b - 1 downto 0 do begin
     byte(destp^) := (byte(srcp^) * c + byte((srcp + b)^) * d) shr 15;
     inc(srcp);
     inc(destp);
    end;
   end;
   inc(start, span);
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end else

 if toy < poku^.sizey then begin
  // Vertical shrink
  getmem(workbuf, b * toy);
  destp := workbuf;
  span := (poku^.sizey shl 15) div toy;
  for loopy := toy - 1 downto 0 do begin
   finish := start + span - 1;
   srcp := poku^.image + (start shr 15) * b;
   a := (start and $7FFF) xor $7FFF; // weight of highest row
   c := (finish and $7FFF); // weight of lowest row
   g := (finish shr 15) - (start shr 15);
   if g <> 0 then dec(g); // number of full rows between high and low
   d := a + c + g shl 15; // total weight
   g := g * b;
   for loopx := b - 1 downto 0 do begin
    // accumulate weighed pixels in e, first add highest and lowest
    e := byte(srcp^) * a + byte((srcp + g + b)^) * c;
    // then add middle lines
    if g <> 0 then begin
     f := g;
     repeat
      inc(srcp, b);
      inc(e, byte(srcp^) shl 15);
      dec(f, b);
     until f = 0;
     dec(srcp, g);
    end;
    // divide by total weight
    byte(destp^) := e div d;
    inc(srcp);
    inc(destp);
   end;
   inc(start, span);
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end;

 // else ... Vertical change is unnecessary.
 poku^.sizey := toy;
end;

procedure mcg_ScaleBitmap32(poku : pbitmaptype; tox, toy : dword);
// Resize procedure called by mcg_ScaleBitmap.
var workbuf, srcp, destp : pointer;
    loopx, loopy : dword;
    start, finish, span : dword;
    a, b, c, d, e, f, g : dword;
begin
 if (poku^.image = NIL) or (poku^.memformat <> 1) or (tox or toy = 0)
 then exit;

 // Adjust image horizontally from poku^ into workbuf.
 if tox > poku^.sizex then begin
  start := 0;
  a := tox * 4;
  b := poku^.sizex * 4;
  g := poku^.sizey * a;
  // Horizontal stretch
  getmem(workbuf, g);
  destp := workbuf;
  span := (poku^.sizex shl 15) div tox;
  for loopx := tox - 1 downto 0 do begin
   finish := start + span - 1;
   srcp := poku^.image + (start shr 15) * 4;
   if start and $FFFF8000 = finish and $FFFF8000 then begin
    // start and finish are in the same source pixel column
    for loopy := poku^.sizey - 1 downto 0 do begin
     dword(destp^) := dword(srcp^);
     inc(srcp, b);
     inc(destp, a);
    end;
   end else begin
    // start and finish are in two adjacent source pixel columns
    c := (start and $7FFF) xor $7FFF; // weight of left column
    d := (finish and $7FFF); // weight of right column
    e := c + d; // total weight for dividing
    c := (c shl 15) div e; // 32k weight of left column
    d := (d shl 15) div e; // 32k weight of right column
    for loopy := poku^.sizey - 1 downto 0 do begin
     byte((destp    )^) := (byte((srcp    )^) * c + byte((srcp + 4)^) * d) shr 15;
     byte((destp + 1)^) := (byte((srcp + 1)^) * c + byte((srcp + 5)^) * d) shr 15;
     byte((destp + 2)^) := (byte((srcp + 2)^) * c + byte((srcp + 6)^) * d) shr 15;
     byte((destp + 3)^) := (byte((srcp + 3)^) * c + byte((srcp + 7)^) * d) shr 15;
     inc(srcp, b);
     inc(destp, a);
    end;
   end;
   dec(destp, g);
   inc(start, span);
   inc(destp, 4);
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end else

 if tox < poku^.sizex then begin
  // Horizontal shrink
  getmem(workbuf, tox * poku^.sizey * 4);
  destp := workbuf;
  span := (poku^.sizex shl 15) div tox;
  for loopy := poku^.sizey - 1 downto 0 do begin
   start := 0;
   b := (poku^.sizey - 1 - loopy) * poku^.sizex;
   for loopx := tox - 1 downto 0 do begin
    finish := start + span - 1;
    srcp := poku^.image + (start shr 15 + b) * 4;
    // left edge
    c := (start and $7FFF) xor $7FFF; // weight of left column
    // (c is also accumulated weight for this pixel)
    d := byte(srcp^) * c; inc(srcp);
    e := byte(srcp^) * c; inc(srcp);
    f := byte(srcp^) * c; inc(srcp);
    g := byte(srcp^) * c; inc(srcp);
    // full middle columns
    a := start shr 15 + 1;
    while a < finish shr 15 do begin
     inc(c, $8000); // accumulate weight
     inc(d, byte(srcp^) shl 15); inc(srcp);
     inc(e, byte(srcp^) shl 15); inc(srcp);
     inc(f, byte(srcp^) shl 15); inc(srcp);
     inc(g, byte(srcp^) shl 15); inc(srcp);
     inc(a);
    end;
    // right edge
    a := (finish and $7FFF); // weight of right column
    inc(c, a); // accumulate weight
    inc(d, byte(srcp^) * a); inc(srcp);
    inc(e, byte(srcp^) * a); inc(srcp);
    inc(f, byte(srcp^) * a); inc(srcp);
    inc(g, byte(srcp^) * a);
    // save result
    byte(destp^) := d div c; inc(destp);
    byte(destp^) := e div c; inc(destp);
    byte(destp^) := f div c; inc(destp);
    byte(destp^) := g div c; inc(destp);
    inc(start, span);
   end;
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end;

 // else... Horizontal change is unnecessary.
 poku^.sizex := tox;

 // Adjust image vertically from poku^ into workbuf.
 start := 0;
 b := poku^.sizex * 4;
 if toy > poku^.sizey then begin
  // Vertical stretch
  getmem(workbuf, b * toy);
  destp := workbuf;
  span := (poku^.sizey shl 15) div toy;
  for loopy := toy - 1 downto 0 do begin
   finish := start + span - 1;
   srcp := poku^.image + (start shr 15) * b;
   if start and $FFFF8000 = finish and $FFFF8000 then begin
    // start and finish are on the same source pixel row
    move(srcp^, destp^, b);
    inc(destp, b);
   end else begin
    // start and finish are on two adjacent source pixel rows
    c := (start and $7FFF) xor $7FFF; // weight of upper row
    d := (finish and $7FFF); // weight of lower row
    e := c + d; // total weight for dividing
    c := (c shl 15) div e; // 32k weight of left column
    d := (d shl 15) div e; // 32k weight of right column
    for loopx := b - 1 downto 0 do begin
     byte(destp^) := (byte(srcp^) * c + byte((srcp + b)^) * d) shr 15;
     inc(srcp);
     inc(destp);
    end;
   end;
   inc(start, span);
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end else

 if toy < poku^.sizey then begin
  // Vertical shrink
  getmem(workbuf, b * toy);
  destp := workbuf;
  span := (poku^.sizey shl 15) div toy;
  for loopy := toy - 1 downto 0 do begin
   finish := start + span - 1;
   srcp := poku^.image + (start shr 15) * b;
   a := (start and $7FFF) xor $7FFF; // weight of highest row
   c := (finish and $7FFF); // weight of lowest row
   g := (finish shr 15) - (start shr 15);
   if g <> 0 then dec(g); // number of full rows between high and low
   d := a + c + g shl 15; // total weight
   g := g * b;
   for loopx := b - 1 downto 0 do begin
    // accumulate weighed pixels in e, first add highest and lowest
    e := byte(srcp^) * a + byte((srcp + g + b)^) * c;
    // then add middle lines
    if g <> 0 then begin
     f := g;
     repeat
      inc(srcp, b);
      inc(e, byte(srcp^) shl 15);
      dec(f, b);
     until f = 0;
     dec(srcp, g);
    end;
    // divide by total weight, save result
    byte(destp^) := e div d;
    inc(srcp);
    inc(destp);
   end;
   inc(start, span);
  end;
  freemem(poku^.image); poku^.image := workbuf; workbuf := NIL;
 end;

 // else ... Vertical change is unnecessary.
 poku^.sizey := toy;
end;

procedure mcg_ScaleBitmap(poku : pbitmaptype; tox, toy : word);
// Resizes the bitmaptype(poku^) resource to tox:toy resolution.
// Uses a sort of general purpose linear method to do it.
// Scaling downwards looks good, as color values stack properly.
// Scaling upwards by integer multiples looks like a point scaler.
// Scaling upwards by fractions is like a softened point scaler.
begin
 if poku^.image = NIL then begin
  mcg_errortxt := 'Image pointer is NIL'; exit;
 end;
 if (tox = 0) or (toy = 0) then begin
  mcg_errortxt := 'Target size cannot be 0'; exit;
 end;
 case poku^.memformat of
   0: mcg_ScaleBitmap24(poku, tox, toy);
   1: mcg_ScaleBitmap32(poku, tox, toy);
   else begin
    mcg_errortxt := 'Image memformat must be 0 or 1'; exit;
   end;
 end;
end;

// ------------------------------------------------------------------

procedure doinits;
var ivar, jvar : dword;
begin
 fillbyte(pnghdr, sizeof(pnghdr), 0);
 CRCundone := TRUE;
 // Set default AutoConversion value to turn everything into truecolor.
 mcg_AutoConvert := 2;
 // By default, read PNGs and BMPs fully into memory.
 mcg_ReadHeaderOnly := 0;

 // Pre-calculate the reverse gamma-correction table.
 setlength(mcg_RevGammaTab, 65536);
 jvar := 254;
 for ivar := 65535 downto 0 do begin
  if ivar < mcg_GammaTab[jvar] then dec(jvar);
  if mcg_GammaTab[jvar + 1] - ivar < ivar - mcg_GammaTab[jvar]
  then mcg_RevGammaTab[ivar] := jvar + 1
  else mcg_RevGammaTab[ivar] := jvar;
 end;
end;

// ------------------------------------------------------------------

initialization
 doinits;

finalization
end.
