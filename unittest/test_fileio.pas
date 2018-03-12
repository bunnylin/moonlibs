program test_varmon;

{$mode objfpc}
{$ifdef WINDOWS}{$apptype console}{$endif}
{$codepage UTF8}
{$ASSERTIONS ON}

uses mcfileio;

const testfile1 = 'deleteme.bin';
      testdir = 'deleteme.dir';
      testfile2 = testdir + DirectorySeparator + testfile1;
var   testfile3 : UTF8string;

var a, a2 : array[0..3] of dword;
    i, j : dword;
    f1, f2, f3 : file;
    loader : TFileLoader;

begin
 testfile3 := upcase(testfile1);
 // Delete the test files, if they exist.
 assign(f1, testfile1);
 assign(f2, testfile2);
 assign(f3, testfile3);

 {$I-}
 erase(f1); while IOresult <> 0 do ;
 erase(f2); while IOresult <> 0 do ;
 erase(f3); while IOresult <> 0 do ;
 rmdir(testdir); while IOresult <> 0 do ;
 {$I+}

 // Set up a small binary file for testing.
 try
  a[0] := $76543210;
  a[1] := $CDEF89AB;
  a[2] := $44332211;
  a[3] := $45006655;
  a2[0] := 0; // silence a compiler warning

  writeln(':: SaveFile ::');
  // It should be possible to save a file in the current directory.
  SaveFile(testfile1, @a[0], 16);

  // The created file should be openable.
  filemode := 0; reset(f1, 1);
  // The created file should contain the saved content.
  blockread(f1, a2[0], 16);
  close(f1);
  for i := 0 to 3 do assert(a2[i] = a[i]);

  // A file can be saved in a subdirectory, and the subdirectory is created
  // if it doesn't exist.
  SaveFile(testfile2, @a[0], 16);

  // Check the created file.
  filemode := 0; reset(f2, 1);
  blockread(f2, a2[0], 16);
  close(f2);
  for i := 0 to 3 do assert(a2[i] = a[i]);

  // Case shenanigans should be handled. We modify the content of a[], and
  // resave with a capitalised filename. On friendly file systems, this
  // overwrites the original. On hostile file systems, the original is left
  // in place, but SaveFile() removes it for us.
  a[2] := $FEEDBACC;
  SaveFile(testfile3, @a[0], 16);

  writeln(':: LoadFile ::');
  // Fileloader should be able to read a file.
  loader := TFileLoader.Open(testfile1);

  assert(loader.ofs = 0);
  assert(loader.size = 16);
  // This only works when caseshenanigans is defined.
  //assert(loader.filename = testfile3);
  // Verify data reading functions.
  assert(loader.ReadDword = a[0]);
  assert(loader.ofs = 4);
  assert(loader.ReadWord = word(a[1]));
  assert(loader.ReadByte = byte(a[1] shr 16));
  assert(loader.ofs = 7);

  assert(loader.ReadByteFrom(4) = byte(a[1]));
  assert(loader.ReadWordFrom(4) = word(a[1]));
  assert(loader.ReadDwordFrom(0) = a[0]);
  assert(loader.ofs = 7);

  // Verify bitreader.
  j := 0;
  loader.bitindex := 7;
  for i := 7 downto 0 do begin
   j := j shl 1;
   if loader.ReadBit then j := j or 1;
  end;
  assert(j = byte(a[1] shr 24));
  assert(loader.bitindex = 7);
  assert(loader.ofs = 8);
  // It should be possible to set ofs.
  loader.ofs := 4;
  assert(loader.ofs = 4);
  assert(loader.ReadDword = a[1]);
  // Setting ofs out of bounds should stop at first invalid offset.
  loader.ofs := 9999;
  assert(loader.ofs = 16);
  // Verify shenaniganned content.
  loader.ofs := 8;
  assert(loader.ReadDword = a[2]);

  // Verify zero-terminated stringreader.
  loader.ofs := $C;
  assert(loader.ReadString = chr(a[3] and $FF) + chr((a[3] shr 8) and $FF));
  assert(loader.ofs = $E);
  // Verify zero-terminated stringreader respects end of buffer.
  loader.ofs := $F;
  assert(loader.ReadString = chr(a[3] shr 24));
  assert(loader.ofs = $10);

  // Verify zero-terminated stringreader with custom offset.
  loader.ofs := 3;
  assert(loader.ReadStringFrom($C) = chr(a[3] and $FF) + chr((a[3] shr 8) and $FF));
  assert(loader.ofs = 3);
  // Verify zero-terminated stringreader with custom offset respects end of
  // buffer.
  assert(loader.ReadStringFrom($F) = chr(a[3] shr 24));
  // Verify buffy resize upward.
  loader.size := 17;
  loader.ofs := 0;
  word((loader.readp + 15)^) := $ABCD;
  assert(loader.ReadWordFrom(15) = $ABCD);
  // Verify buffy resize downward.
  loader.size := 6;
  assert(loader.ReadStringFrom(4) = chr(a[1] and $FF) + chr((a[1] shr 8) and $FF));
 finally
  {$I-}
  erase(f1); while IOresult <> 0 do ;
  erase(f2); while IOresult <> 0 do ;
  erase(f3); while IOresult <> 0 do ;
  rmdir(testdir); while IOresult <> 0 do ;
  if loader <> NIL then loader.free;
  loader := NIL;
 end;
 writeln('Tests passed.');
end.
