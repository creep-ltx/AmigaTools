-> sbmaxtest.e - audit3 C1: prove that the ring accessors' single-
-> subtraction wrap escapes the model planes when sbmax is not kept
-> larger than the visible row count, and that openwin()'s new floor
-> (sbmax >= rows + 2) closes it.
->
-> Why a harness and not a boot test: the failure is an INDEX, and an
-> index can be computed exactly. On hardware this bug is a write past
-> a plane into E's heap - it corrupts something else and shows up
-> later as anything at all, or as nothing. The harness names it.
->
-> The arithmetic below is copied VERBATIM from ccon-handler.e's
-> visrow() (and sarow/ssrow/swrow/drawmodelrow/drawmodelcells, which
-> are the same two lines). If that changes, change it here.
->
->   PROC visrow(r)
->     DEF i
->     i := curcon.sbtop + r
->     IF i >= curcon.sbmax THEN i := i - curcon.sbmax
->   ENDPROC curcon.sb + Mul(i, curcon.cols)
->
-> Run: ecompile sbmaxtest.e sbmaxtest && vamos sbmaxtest

MODULE 'dos/dos'

DEF fails=0

-> the accessor's index, exactly as the handler computes it
PROC ringidx(sbtop, r, sbmax)
  DEF i
  i := sbtop + r
  IF i >= sbmax THEN i := i - sbmax
ENDPROC i

-> sweep every sbtop the ring can hold against every visible row, and
-> report the worst index the accessors can produce. A model plane is
-> sbmax * cols bytes, so any index >= sbmax is a write past the end.
PROC sweep(sbmax, rows, label)
  DEF sbtop, r, i, worst=-1, esc=0
  FOR sbtop := 0 TO sbmax - 1
    FOR r := 0 TO rows - 1
      i := ringidx(sbtop, r, sbmax)
      IF i > worst THEN worst := i
      IF (i < 0) OR (i >= sbmax) THEN esc := esc + 1
    ENDFOR
  ENDFOR
  WriteF('  \s\n', label)
  WriteF('    sbmax=\d rows=\d  -> worst index \d, legal range 0..\d\n',
         sbmax, rows, worst, sbmax - 1)
  IF esc > 0
    WriteF('    *** ESCAPES the plane on \d of \d (sbtop,row) pairs ***\n',
           esc, Mul(sbmax, rows))
  ELSE
    WriteF('    every index inside the plane (\d pairs checked)\n',
           Mul(sbmax, rows))
  ENDIF
ENDPROC esc

PROC expect(got, want, what)
  IF got = want
    WriteF('  PASS  \s\n', what)
  ELSE
    WriteF('  FAIL  \s (got \d, wanted \d)\n', what, got, want)
    fails := fails + 1
  ENDIF
ENDPROC

PROC main()
  DEF esc, rows, sbmax

  WriteF('audit3 C1 - sbmax vs rows\n\n')

  -> ---- the reported case -------------------------------------------
  -> LINES100 on a 1280x1024 screen at topaz 8: (1024 - 13) / 8 = 126
  -> rows against the 100-line ring the LINES option bought.
  WriteF('CASE 1: the reported configuration (LINES100, 126-row window)\n')
  esc := sweep(100, 126, 'BEFORE - sbmax straight from LINES=n')
  expect(IF esc > 0 THEN 1 ELSE 0, 1, 'the bug reproduces (indexes escape)')
  esc := sweep(128, 126, 'AFTER  - floored at rows + 2')
  expect(esc, 0, 'the floor closes it')

  -> ---- where exactly is the boundary? -------------------------------
  -> audit3 claims the escape begins at rows >= sbmax + 2. Check it
  -> rather than trust it - the handler's comment quotes this result.
  -> Note what it means: indexing alone would be satisfied by
  -> sbmax >= rows - 1. The handler floors at rows + 2 anyway, because
  -> sbmax - rows is ALSO the scrollback capacity (screenscroll's
  -> `IF sbcnt < (sbmax - rows)`), so the bare index minimum would buy a
  -> safe ring with no history in it.
  WriteF('\nCASE 2: the exact boundary (measured, not assumed)\n')
  esc := sweep(100, 100, 'rows = sbmax')
  expect(esc, 0, 'rows = sbmax is safe')
  esc := sweep(100, 101, 'rows = sbmax + 1')
  expect(esc, 0, 'rows = sbmax + 1 is safe (the last safe value)')
  esc := sweep(100, 102, 'rows = sbmax + 2')
  expect(IF esc > 0 THEN 1 ELSE 0, 1, 'rows = sbmax + 2 ESCAPES')

  -> ---- the floor applied across the whole plausible range ----------
  -> Every row count a real window can have (cols is capped at 255 and
  -> the smallest useful cell is a few pixels, so a few hundred rows is
  -> already generous), each with sbmax set the way openwin() now sets
  -> it. None may escape.
  WriteF('\nCASE 3: the new floor across every plausible window height\n')
  esc := 0
  FOR rows := 1 TO 400
    sbmax := 512                     -> the SBMAX default
    IF sbmax < 100 THEN sbmax := 100
    IF sbmax < (rows + 2) THEN sbmax := rows + 2   -> the C1 floor
    esc := esc + sweep2(sbmax, rows)
  ENDFOR
  expect(esc, 0, 'default SBMAX + floor: no escape at any height 1..400')

  esc := 0
  FOR rows := 1 TO 400
    sbmax := 100                     -> the worst case a user can ask
    IF sbmax < (rows + 2) THEN sbmax := rows + 2   -> the C1 floor
    esc := esc + sweep2(sbmax, rows)
  ENDFOR
  expect(esc, 0, 'LINES100 + floor: no escape at any height 1..400')

  -> ---- and prove the sweep would have caught it without the floor --
  WriteF('\nCASE 4: the same range WITHOUT the floor, to show the sweep works\n')
  esc := 0
  FOR rows := 1 TO 400
    esc := esc + sweep2(100, rows)   -> raw LINES100, no floor
  ENDFOR
  expect(IF esc > 0 THEN 1 ELSE 0, 1, 'unfloored LINES100 escapes at some height')
  WriteF('    (escaping (sbtop,row) pairs across the sweep: \d)\n', esc)

  WriteF('\n')
  IF fails = 0
    WriteF('ALL PASS - the floor is sbmax >= rows + 2, and it holds.\n')
  ELSE
    WriteF('\d FAILURE(S)\n', fails)
  ENDIF
ENDPROC

-> the quiet twin of sweep(), for the bulk ranges
PROC sweep2(sbmax, rows)
  DEF sbtop, r, i, esc=0
  FOR sbtop := 0 TO sbmax - 1
    FOR r := 0 TO rows - 1
      i := ringidx(sbtop, r, sbmax)
      IF (i < 0) OR (i >= sbmax) THEN esc := esc + 1
    ENDFOR
  ENDFOR
ENDPROC esc
