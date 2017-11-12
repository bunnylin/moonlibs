// This is a performance test for the mcg_ScaleBitmap function.
uses windows, mcgloder;

var baseimage, testimage : bitmaptype;
    maxiterations : dword;

const basesizex = 640; basesizey = 400;

procedure MakeImage(sx, sy : dword);
var destp : pointer;
    bytesize, counter : dword;
begin
 mcg_ForgetImage(@baseimage);
 with baseimage do begin
  // Define image metadata.
  sizex := sx;
  sizey := sy;
  memformat := 1; // 0 = RGB, 1 = RGBA
  bitdepth := 8;
  bytesize := sx * sy * 4;
  getmem(image, bytesize);
  // Fill in the image with a messy deterministic pattern.
  destp := image;
  for counter := bytesize - 1 downto 0 do begin
   byte(destp^) := byte(counter xor (counter shr 8));
   inc(destp);
  end;
 end;
end;

procedure CopyImage;
begin
 mcg_ForgetImage(@testimage);
 testimage := baseimage;
 with testimage do begin
  image := NIL;
  getmem(image, sizex * sizey * 4);
  move(baseimage.image^, testimage.image^, sizex * sizey * 4);
 end;
end;

procedure RunTest(const testname : string; testx, testy, form : dword);
var totalresult, iteration, tickcount : dword;
begin
 totalresult := 0;
 for iteration := maxiterations - 1 downto 0 do begin
  // Make a fresh copy of the standard base image.
  CopyImage;
  // Override the image copy's format.
  testimage.memformat := form;
  // Start counting.
  tickcount := GetTickCount;
  // Resize the image!
  mcg_ScaleBitmap(@testimage, testx, testy);
  // Add up the time spent.
  inc(totalresult, GetTickCount - tickcount);
  // Chill to hopefully get a full time slice for the next run.
  sleep(256);
 end;
 // Report the result, except if this was a warmup run.
 if testname <> '' then
  writeln(testname, ': ', totalresult div maxiterations, ' ms');
end;

begin
 // Build the base image.
 MakeImage(basesizex, basesizey);
 // Cache warmup.
 maxiterations := 1;
 RunTest('', 32, 32, 0);
 RunTest('', 32, 32, 1);
 maxiterations := 16;
 // Test downscaling.
 RunTest('Downscale24', basesizex * 7 div 8, basesizey * 7 div 8, 0);
 RunTest('Downscale32', basesizex * 7 div 8, basesizey * 7 div 8, 1);
 // Test integer upscaling.
 RunTest('Intupscale24', basesizex * 2, basesizey * 2, 0);
 RunTest('Intupscale32', basesizex * 2, basesizey * 2, 1);
 // Test fractional upscaling.
 RunTest('Fracupscale24', basesizex * 17 div 7, basesizey * 17 div 7, 0);
 RunTest('Fracupscale32', basesizex * 17 div 7, basesizey * 17 div 7, 1);
 // Clean up.
 mcg_ForgetImage(@baseimage);
 mcg_ForgetImage(@testimage);
end.