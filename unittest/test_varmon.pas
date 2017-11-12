program test_varmon;

{$mode objfpc}
{$ifdef WINDOWS}{$apptype console}{$endif}
{$codepage UTF8}
{$ASSERTIONS ON}

uses mcvarmon, mccommon;

var strutsi : UTF8string;
    poku, poku2 : pointer;
    i : dword;

begin
 poku := NIL;
 poku2 := NIL;
 try
 writeln('max buckets=', VARMON_MAXBUCKETS);
 writeln('max languages=', VARMON_MAXLANGUAGES);

 // Should start with a clean state even without an init.
 writeln(':: basics ::');
 Assert(CountNumVars = 0);
 Assert(CountStrVars = 0);
 Assert(CountBuckets > 0);
 GetStrVar('non-existing string');
 Assert(stringstash[0] = '');
 Assert(GetNumVar('non-existing number') = 0);
 Assert(GetVarType('non-existing variable') = 0);

 // (After the linebreak, that's a pound sign and hiragana ne~.)
 strutsi := 'Test string' + chr(0) + chr($A) + chr($C2) + chr($A3) + chr($E3) + chr($81) + chr($AD) + '~';
 stringstash[0] := strutsi;
 SetStrVar('a', FALSE);
 SetNumVar('i', 32, FALSE);
 stringstash[0] := '';
 Assert(GetVarType('a') = VARMON_VARTYPESTR);
 Assert(GetVarType('i') = VARMON_VARTYPEINT);
 GetStrVar('a');
 Assert(stringstash[0] = strutsi);
 Assert(GetNumVar('i') = 32);
 writeln('_' + strutsi + '_');
 Assert(CountNumVars = 1);
 Assert(CountStrVars = 1);

 // Save current and wipe. Should be duly wiped.
 writeln(':: save1 ::');
 SaveVarState(poku);
 writeln(':: init1 ::');
 VarmonInit(0, 0);
 Assert(CountNumVars = 0);
 Assert(CountStrVars = 0);
 GetStrVar('a');
 Assert(stringstash[0] = '');
 Assert(GetNumVar('i') = 0);

 // Set another variable or two and save again.
 stringstash[0] := strutsi;
 SetStrVar('b', FALSE);
 SetStrVar('c', TRUE);
 SetNumVar('j', 99, FALSE);
 SetNumVar('k', 99, TRUE);
 Assert(CountNumVars = 2);
 Assert(CountStrVars = 2);
 writeln(':: save2 ::');
 SaveVarState(poku2);

 // Load state. The new variables should be gone, and the previous present.
 writeln(':: load1 ::');
 LoadVarState(poku);
 Assert(GetVarType('b') = VARMON_VARTYPENULL);
 Assert(GetVarType('c') = VARMON_VARTYPENULL);
 Assert(GetVarType('j') = VARMON_VARTYPENULL);
 Assert(GetVarType('k') = VARMON_VARTYPENULL);
 Assert(GetVarType('a') = VARMON_VARTYPESTR);
 Assert(GetVarType('i') = VARMON_VARTYPEINT);
 GetStrVar('A');
 writeln('_' + stringstash[0] + '_');
 Assert(stringstash[0] = strutsi);
 Assert(GetNumVar('I') = 32);
 Assert(CountNumVars = 1);
 Assert(CountStrVars = 1);

 // Load state again. New variables should be present.
 writeln(':: load2 ::');
 LoadVarState(poku2);
 Assert(GetVarType('b') = VARMON_VARTYPESTR);
 Assert(GetVarType('c') = VARMON_VARTYPESTR);
 Assert(GetVarType('j') = VARMON_VARTYPEINT);
 Assert(GetVarType('k') = VARMON_VARTYPEINT);
 Assert(GetVarType('a') = VARMON_VARTYPENULL);
 Assert(GetVarType('i') = VARMON_VARTYPENULL);
 Assert(CountNumVars = 2);
 Assert(CountStrVars = 2);

 // Protected variables shouldn't be overwritable without sudo.
 writeln(':: sudo ::');
 stringstash[0] := 'puuh';
 i := 0;
 try SetStrVar('c', FALSE);
 except inc(i);
 end;
 Assert(i = 1);
 try SetNumVar('k', 50, FALSE);
 except inc(i);
 end;
 Assert(i = 2);
 GetStrVar('c');
 Assert(stringstash[0] = strutsi);
 Assert(GetNumVar('k') = 99);

 // Protected should be overwritable with sudo.
 stringstash[0] := 'puuh';
 SetStrVar('c', TRUE);
 SetNumVar('k', 42, TRUE);
 stringstash[0] := strutsi;
 GetStrVar('c');
 Assert(stringstash[0] = 'puuh');
 Assert(GetNumVar('k') = 42);

 // Adding new variables should cause the bucket count to grow.
 writeln(':: autogrow ::');
 VarmonInit(1, 4);
 Assert(CountBuckets = 4);
 for i := 1 to 80 * 4 do SetNumVar(strdec(i), i, FALSE);
 Assert(CountBuckets > 4);
 Assert(CountNumVars = 80 * 4);

 // Bucket count shouldn't autogrow if numbuckets set manually.
 writeln(':: noautogrow ::');
 VarmonInit(1, 1);
 SetNumBuckets(4);
 Assert(CountBuckets = 4);
 for i := 1 to 80 * 4 do SetNumVar(strdec(i), i, FALSE);
 Assert(CountBuckets = 4);
 Assert(CountNumVars = 80 * 4);

 // Multiple languages also save correctly.
 writeln(':: multilang ::');
 VarmonInit(3, 1);
 for i := 0 to 2 do stringstash[i] := strdec(i);
 SetStrVar('a', FALSE);
 freemem(poku); poku := NIL;
 SaveVarState(poku);
 VarmonInit(3, 1);
 LoadVarState(poku);
 GetStrVar('a');
 for i := 0 to 2 do Assert(stringstash[i] = strdec(i));

 // Loading with a different current language count should work.
 VarmonInit(2, 1);
 LoadVarState(poku);
 GetStrVar('a');
 Assert(length(stringstash) = 2);
 for i := 0 to 1 do Assert(stringstash[i] = strdec(i));

 VarmonInit(4, 1);
 LoadVarState(poku);
 GetStrVar('a');
 Assert(length(stringstash) = 4);
 for i := 0 to 2 do Assert(stringstash[i] = strdec(i));
 Assert(stringstash[3] = stringstash[0]);


 finally
  if poku <> NIL then begin freemem(poku); poku := NIL; end;
  if poku2 <> NIL then begin freemem(poku2); poku2 := NIL; end;
 end;

 writeln('Tests passed.');
end.
