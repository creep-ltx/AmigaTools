-> hordertest.e - E-VO codegen probe for the v1.2.7 horder access
->
-> The 1.2.7b1 boot found the Up/Down walk ordered but the ghost and
-> Ctrl+R not - and the ONLY code-shape difference is how the INT
-> member array is read: the walk hoists it into a local first
-> (slot := IF .. THEN con.horder[idx] ELSE 0, then ghist[slot]),
-> the searches nest it inside another subscript
-> (h := ghist[con.horder[idx]]). Inline member arrays are proven
-> for CHAR (AmigaReferences/amiga-e-language.md); INT, and INT
-> nested in an outer subscript, are not. This probes exactly those
-> shapes on data.
->
-> Build: ecompile hordertest.e hordertest
-> Run:   vamos hordertest

MODULE 'dos/dos'

OBJECT probecon
  pada, padb, padc              -> LONG padding so horder sits at a
                                -> realistic non-zero offset, like
                                -> the handler's console object
  hpos
  hover
  horder[8]:ARRAY OF INT
  after                         -> written BEFORE the fill; a stride
                                -> bug (LONG writes) would smash it
ENDOBJECT

DEF ghist[8]:ARRAY OF LONG, fails

PROC check(tag, got:PTR TO CHAR, want:PTR TO CHAR)
  IF StrCmp(got, want)
    WriteF('    ok   \s\n', tag)
  ELSE
    WriteF('    FAIL \s\n         got  "\s"\n         want "\s"\n', tag, got, want)
    fails := fails + 1
  ENDIF
ENDPROC

PROC main()
  DEF con:PTR TO probecon, i, slot, idx, h:PTR TO CHAR,
      b:PTR TO CHAR, raw:PTR TO CHAR, n, avail, want:PTR TO CHAR
  fails := 0
  b := String(64)
  WriteF('hordertest - INT member array, hoisted vs nested read\n\n')

  FOR i := 0 TO 7
    ghist[i] := String(16)
  ENDFOR
  StrCopy(ghist[0], 's0'); StrCopy(ghist[1], 's1')
  StrCopy(ghist[2], 's2'); StrCopy(ghist[3], 's3')
  StrCopy(ghist[4], 's4'); StrCopy(ghist[5], 's5')
  StrCopy(ghist[6], 's6'); StrCopy(ghist[7], 's7')

  con := New(SIZEOF probecon)
  con.after := $CAFE

  -> fill with a permutation through the MEMBER write, the same
  -> shape historder uses (con.horder[n] := slot)
  con.horder[0] := 3; con.horder[1] := 1
  con.horder[2] := 4; con.horder[3] := 0
  con.horder[4] := 2; con.horder[5] := 7
  con.horder[6] := 5; con.horder[7] := 6
  avail := 8

  -> probe 1: the write stride. Raw bytes must be 2-byte INTs:
  -> 00 03 00 01 00 04 ... - a LONG-stride bug would leave zeros in
  -> the odd words and smash `after`
  raw := con + OFFSETOF probecon.horder
  want := [0,3,0,1,0,4,0,0,0,2,0,7,0,5,0,6]:CHAR
  n := 0
  FOR i := 0 TO 15
    IF raw[i] <> want[i] THEN n := n + 1
  ENDFOR
  IF n = 0
    WriteF('    ok   write stride is INT (raw bytes match)\n')
  ELSE
    WriteF('    FAIL write stride: \d raw bytes differ\n', n)
    fails := fails + 1
  ENDIF
  IF con.after = $CAFE
    WriteF('    ok   field after the array untouched\n')
  ELSE
    WriteF('    FAIL field after the array smashed: $\h\n', con.after)
    fails := fails + 1
  ENDIF

  -> probe 2: the WALK's shape - hoist through a local with the
  -> guarded IF-expression, then subscript ghist
  StrCopy(b, '')
  FOR idx := 0 TO avail - 1
    slot := IF idx < avail THEN con.horder[idx] ELSE 0
    StrAdd(b, ghist[slot])
  ENDFOR
  check('hoisted read (walk shape)', b, 's3s1s4s0s2s7s5s6')

  -> probe 3: the SEARCHES' shape - the member read nested directly
  -> inside the outer subscript, sgfind/srfind verbatim
  StrCopy(b, '')
  FOR idx := 0 TO avail - 1
    h := ghist[con.horder[idx]]
    StrAdd(b, h)
  ENDFOR
  check('nested read (search shape)', b, 's3s1s4s0s2s7s5s6')

  -> probe 4: nested read as a proc argument, histmatches-style
  StrCopy(b, '')
  FOR idx := 0 TO avail - 1
    StrAdd(b, ghist[con.horder[idx]])
  ENDFOR
  check('nested read as argument', b, 's3s1s4s0s2s7s5s6')

  WriteF('\n---------------------------------------------\n')
  IF fails = 0
    WriteF('all shapes agree - the miscompile theory is DEAD\n')
  ELSE
    WriteF('\d CHECK(S) FAILED - the failing shape is the bug\n', fails)
  ENDIF
ENDPROC
