-> edanchortest.e - throwaway harness for audit finding B1
->
-> B1: eraseedit()'s early returns (win = NIL, and ancx >= cols) skip
-> the `edlast := 0 / edext := 0` reset at the bottom of the proc. The
-> b9 note says that reset exists so "the tail never re-cleans at a
-> moved anchor". So the claim under test is: leave edlast set, move
-> the anchor, and drawedit()'s oldl > l zeroing loop erases model
-> cells measured from the NEW anchor - client text, not editor text.
->
-> What this harness reproduces: the MODEL bookkeeping only. Every
-> pixel call is dropped, which is faithful because the two repaint
-> helpers drawedit/eraseedit call - drawmodelrow and drawmodelcells -
-> read the model and never write it. What it therefore CANNOT settle:
-> whether the glass agrees with the model afterwards. That still
-> needs the boot test.
->
-> Logic below is transcribed from ccon-handler.e 1.2b2:
-> visrow/sarow/ssrow, screenscroll, outnl, render's printable+CR
-> path, reanchor, edcap, edlastrow, edroom, eraseedit, drawedit.
-> ebuf is a plain array + elen standing in for the E-string + StrLen.
->
-> Build: ecompile edanchortest.e edanchortest
-> Run:   vamos edanchortest

MODULE 'dos/dos'

CONST COLS=20, ROWS=10, SBMAX=10, LINEMAX=400, CELLS=200

DEF sb[200]:ARRAY OF CHAR,
    sa[200]:ARRAY OF CHAR,
    ss[200]:ARRAY OF CHAR,
    sbtop, sbcnt,
    cx, cy, ancx, ancy,
    edlast, edext, cpos,
    ebuf[404]:ARRAY OF CHAR, elen,
    deffg,
    fixb1,                      -> TRUE = apply the proposed B1 fix
    bailcount,                  -> times eraseedit took an early return
    snap[200]:ARRAY OF CHAR     -> model snapshot for the damage metric

-> ---------- the model, verbatim shapes ----------

PROC visrow(r)
  DEF i
  i := sbtop + r
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC sb + Mul(i, COLS)

PROC sarow(r)
  DEF i
  i := sbtop + r
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC sa + Mul(i, COLS)

PROC ssrow(r)
  DEF i
  i := sbtop + r
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC ss + Mul(i, COLS)

PROC clearrow(r)
  DEF i, m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR
  m := visrow(r)
  a := sarow(r)
  stp := ssrow(r)
  FOR i := 0 TO COLS - 1
    m[i] := 0
    a[i] := 0
    stp[i] := 0
  ENDFOR
ENDPROC

PROC screenscroll()
  IF ancy > 0 THEN ancy := ancy - 1
  sbtop := sbtop + 1
  IF sbtop >= SBMAX THEN sbtop := 0
  IF sbcnt < (SBMAX - ROWS) THEN sbcnt := sbcnt + 1
  clearrow(ROWS - 1)
ENDPROC

PROC outnl()
  cx := 0
  cy := cy + 1
  IF cy >= ROWS
    screenscroll()
    cy := ROWS - 1
  ENDIF
ENDPROC

PROC reanchor()
  ancx := cx
  ancy := cy
ENDPROC

PROC edcap() IS Min(LINEMAX - 1, Mul(ROWS, COLS) - ancx - 1)

PROC edlastrow(n) IS ancy + ((ancx + n) / COLS)

PROC edroom(n)
  WHILE (edlastrow(n) > (ROWS - 1)) AND (ancy > 0)
    screenscroll()
    IF cy > 0 THEN cy := cy - 1
  ENDWHILE
ENDPROC

-> render(), printable-run + CR only - the shape that matters here is
-> that a run ending flush at the right margin leaves cx = COLS
-> (pending wrap), which is what parks ancx = COLS on the reanchor.
PROC render(s:PTR TO CHAR, len)
  DEF i=0, c, run, fit, j, m:PTR TO CHAR
  WHILE i < len
    c := s[i]
    IF c = 13
      cx := 0
      i := i + 1
    ELSEIF c = 10
      outnl()
      i := i + 1
    ELSE
      j := i
      WHILE (j < len) AND (s[j] >= 32)
        j := j + 1
      ENDWHILE
      run := j - i
      WHILE run > 0
        IF cx >= COLS THEN outnl()
        fit := COLS - cx
        IF fit > run THEN fit := run
        CopyMem(s + i, visrow(cy) + cx, fit)
        m := sarow(cy) + cx
        FOR j := 0 TO fit - 1
          m[j] := deffg
        ENDFOR
        m := ssrow(cy) + cx
        FOR j := 0 TO fit - 1
          m[j] := 0
        ENDFOR
        cx := cx + fit
        i := i + fit
        run := run - fit
      ENDWHILE
    ENDIF
  ENDWHILE
ENDPROC

-> ---------- the two procs under test ----------

PROC eraseedit()
  DEF r, cc, m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, j, n
  -> The proposed fix: TAKE the extent into a local and clear the
  -> fields immediately, before either guard can return. Note it can
  -> NOT simply be "zero the fields at the top" - the erase loop below
  -> reads the count, so zeroing it first would skip the erase on the
  -> normal path. Scenario C exists to catch exactly that mistake.
  n := edlast
  IF fixb1
    edlast := 0
    edext := 0
  ENDIF
  IF ancx >= COLS                 -> the B1 guard
    bailcount := bailcount + 1
    RETURN
  ENDIF
  cc := ancx
  r := ancy
  FOR j := 0 TO n - 1
    IF r <= (ROWS - 1)
      m := visrow(r)
      a := sarow(r)
      stp := ssrow(r)
      m[cc] := 0
      a[cc] := 0
      stp[cc] := 0
    ENDIF
    cc := cc + 1
    IF cc >= COLS
      cc := 0
      r := r + 1
    ENDIF
  ENDFOR
  -> the drawmodelrow repaint loop is pixels only - dropped
  edlast := 0
  edext := 0
ENDPROC

PROC drawedit()
  DEF l, i, n, r, xc, j, a:PTR TO CHAR, stp:PTR TO CHAR, m:PTR TO CHAR,
      oldl, newext, cc, rr
  oldl := edlast
  l := elen
  edroom(l)
  -> mirror the typed text into the model
  i := 0
  r := ancy
  xc := ancx
  WHILE i < l
    n := Min(COLS - xc, l - i)
    IF n > 0
      CopyMem(ebuf + i, visrow(r) + xc, n)
      a := sarow(r) + xc
      stp := ssrow(r) + xc
      FOR j := 0 TO n - 1
        a[j] := deffg
        stp[j] := 0
      ENDFOR
    ENDIF
    i := i + n
    xc := 0
    r := r + 1
  ENDWHILE
  -> zero the mirror where the OLD text out-reaches the new. This is
  -> the loop B1 is about: with a stale oldl and a moved anchor it
  -> measures from the wrong place.
  IF oldl > l
    j := l
    cc := ancx + l
    rr := ancy
    WHILE cc >= COLS
      cc := cc - COLS
      rr := rr + 1
    ENDWHILE
    WHILE j < oldl
      IF rr <= (ROWS - 1)
        m := visrow(rr)
        a := sarow(rr)
        stp := ssrow(rr)
        m[cc] := 0
        a[cc] := 0
        stp[cc] := 0
      ENDIF
      j := j + 1
      cc := cc + 1
      IF cc >= COLS
        cc := 0
        rr := rr + 1
      ENDIF
    ENDWHILE
  ENDIF
  -> ghost/blip/search banner are pixels only - dropped.
  -> the b9 tail calls drawmodelcells, which READS the model - dropped
  newext := l
  IF cpos = l THEN newext := l + 1
  edlast := l
  edext := newext
ENDPROC

-> ---------- client-side simulation ----------

-> ACTION_WRITE: dowrite()'s cooked ordering
PROC dowrite(s:PTR TO CHAR, len)
  eraseedit()
  render(s, len)
  reanchor()
  drawedit()
ENDPROC

PROC typechar(c)
  DEF j
  IF elen < edcap()
    FOR j := elen - 1 TO cpos STEP -1
      ebuf[j + 1] := ebuf[j]
    ENDFOR
    ebuf[cpos] := c
    elen := elen + 1
    cpos := cpos + 1
    ebuf[elen] := 0
    drawedit()
  ENDIF
ENDPROC

PROC typestr(s:PTR TO CHAR)
  DEF i
  FOR i := 0 TO StrLen(s) - 1
    typechar(s[i])
  ENDFOR
ENDPROC

-> dovanilla()'s code = 13 commit path
PROC commit()
  eraseedit()
  render(ebuf, elen)
  outnl()
  elen := 0
  ebuf[0] := 0
  cpos := 0
  reanchor()
  drawedit()
ENDPROC

-> ---------- reporting ----------

PROC dumpmodel(tag)
  DEF r, i, m:PTR TO CHAR, line[64]:ARRAY OF CHAR, c
  WriteF('  \s\n', tag)
  FOR r := 0 TO ROWS - 1
    m := visrow(r)
    FOR i := 0 TO COLS - 1
      c := m[i]
      line[i] := IF c = 0 THEN "." ELSE c
    ENDFOR
    line[COLS] := 0
    WriteF('   row \d[2] |\s|\n', r, line)
  ENDFOR
ENDPROC

-> how many of the first n cells of row r still hold char c
PROC intact(r, c, n)
  DEF i, m:PTR TO CHAR, k=0
  m := visrow(r)
  FOR i := 0 TO n - 1
    IF m[i] = c THEN k := k + 1
  ENDFOR
ENDPROC k

PROC reset()
  DEF i
  FOR i := 0 TO CELLS - 1
    sb[i] := 0
    sa[i] := 0
    ss[i] := 0
  ENDFOR
  sbtop := 0
  sbcnt := 0
  cx := 0
  cy := 0
  ancx := 0
  ancy := 0
  edlast := 0
  edext := 0
  cpos := 0
  elen := 0
  ebuf[0] := 0
  deffg := 1
  bailcount := 0
ENDPROC

-> fill rows 0..n-1 with a repeated identifying letter, straight into
-> the model - this is prior client output already on screen
PROC fillrows(n)
  DEF r, i, m:PTR TO CHAR, a:PTR TO CHAR
  FOR r := 0 TO n - 1
    m := visrow(r)
    a := sarow(r)
    FOR i := 0 TO COLS - 1
      m[i] := "A" + r
      a[i] := deffg
    ENDFOR
  ENDFOR
ENDPROC

-> ---------- the scenario ----------
->
-> The damaging sequence, reasoned out before writing this:
->   1. rows 0..5 already carry client output (AAAA / BBBB / CCCC ...)
->   2. a write lands EXACTLY on the right margin -> cx = COLS, and
->      dowrite's reanchor parks ancx = COLS (the legal pending-wrap
->      state doresize documents)
->   3. the user types at that prompt -> edlast > 0
->   4. Enter: eraseedit() BAILS on the ancx >= COLS guard, leaving
->      edlast set; render echoes the line and outnl() moves the
->      output cursor DOWN ONTO A ROW THAT ALREADY HAS CONTENT;
->      reanchor moves the anchor there; drawedit sees oldl > l (the
->      line just went empty) and zeroes oldl cells from the new
->      anchor - on top of the client's row.
->
-> The row below the commit has to be non-empty for this to bite,
-> which is why the screen is pre-filled rather than started blank.

-> damage metric, scenario-independent: cells that held content before
-> the commit and read empty after. The echo OVERWRITES cells (never
-> zeroes them), so anything counted here was destroyed by a zeroing
-> loop, which is the only thing under test.
PROC snapshot()
  DEF i
  FOR i := 0 TO CELLS - 1
    snap[i] := sb[i]
  ENDFOR
ENDPROC

PROC lostcells()
  DEF i, k=0
  FOR i := 0 TO CELLS - 1
    IF (snap[i] <> 0) AND (sb[i] = 0) THEN k := k + 1
  ENDFOR
ENDPROC k

-> startrow = where the prompt sits. The whole question is whether the
-> row the commit's anchor lands on has content or not.
PROC scenario(fix, startrow, tag)
  DEF lost
  reset()
  fixb1 := fix
  fillrows(6)                   -> rows 0..5 = AAAA.. BBBB.. CCCC..
  cx := 0
  cy := startrow
  dowrite('12345678901234567890', 20)   -> lands flush on the margin
  typestr('HELLO')
  snapshot()
  commit()
  lost := lostcells()
  WriteF('  \s: anchor after commit = row \d, cells destroyed = \d (bails=\d)\n',
         tag, ancy, lost, bailcount)
ENDPROC lost

-> C: the REGRESSION guard on the fix itself. Normal anchor
-> (ancx < COLS), so eraseedit does NOT bail and its erase loop must
-> still clear the edit-line mirror out of the model. If the fix were
-> written as "zero the fields at the top", this returns non-zero
-> leftovers and the fix would be silently breaking the common path.
PROC scenarioC(fix)
  DEF leftovers, i, m:PTR TO CHAR
  reset()
  fixb1 := fix
  cx := 0
  cy := 0
  dowrite('1234567890', 10)     -> ends mid-row: ancx = 10, no bail
  typestr('HELLO')              -> mirror lands at row 0, cols 10..14
  eraseedit()                   -> must clear those five cells
  leftovers := 0
  m := visrow(0)
  FOR i := 10 TO 14
    IF m[i] <> 0 THEN leftovers := leftovers + 1
  ENDFOR
  WriteF('  \s: ancx=\d bails=\d, mirror cells left behind = \d (want 0), edlast=\d\n',
         IF fix THEN 'fixed  ' ELSE 'current', ancx, bailcount, leftovers, edlast)
ENDPROC leftovers

PROC main()
  DEF a1, a2, b1v, b2v, c1, c2
  WriteF('edanchortest - audit B1 (stale edlast across a moved anchor)\n')
  WriteF('grid \dx\d, rows 0-5 pre-filled with client output\n\n', COLS, ROWS)

  WriteF('--- A: prompt at row 0, so the commit anchor lands on a row\n')
  WriteF('       that still holds client output (row 2) ---\n')
  a1 := scenario(FALSE, 0, 'current')
  a2 := scenario(TRUE,  0, 'fixed  ')

  WriteF('\n--- B: prompt at row 5, so the commit anchor lands on a\n')
  WriteF('       BLANK row below the content (row 7) ---\n')
  b1v := scenario(FALSE, 5, 'current')
  b2v := scenario(TRUE,  5, 'fixed  ')

  WriteF('\n--- C: normal anchor - the fix must not break the erase ---\n')
  c1 := scenarioC(FALSE)
  c2 := scenarioC(TRUE)

  WriteF('\n--- model after A/current, for the record ---\n')
  scenario(FALSE, 0, 'replay ')
  dumpmodel('')

  WriteF('\n---------------------------------------------\n')
  IF (a1 > a2) AND (b1v = b2v) AND (c1 = 0) AND (c2 = 0)
    WriteF('B1 REPRODUCED, precondition pinned, fix does not regress:\n')
    WriteF('  A  destroys \d cells when the post-commit anchor lands on a\n', a1 - a2)
    WriteF('     row holding content; B harmless when that row is blank.\n')
    WriteF('     So a cols-wide write is NECESSARY but NOT SUFFICIENT -\n')
    WriteF('     the audit text overstated the trigger and needs correcting.\n')
    WriteF('  C  normal anchor still erases its mirror under the fix.\n')
  ELSEIF c2 > 0
    WriteF('FIX IS WRONG: it breaks the normal erase path (C left \d cells)\n', c2)
  ELSEIF a1 > a2
    WriteF('B1 reproduced in A; B or C unexpected - re-read the scenarios\n')
  ELSE
    WriteF('B1 NOT reproduced - downgrade the finding\n')
  ENDIF
ENDPROC
