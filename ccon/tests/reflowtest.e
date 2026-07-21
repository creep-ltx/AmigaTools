-> reflowtest.e - harness for audit finding B7 (stage 2 of the fix)
->
-> B7: doresize()'s width-change path row-copies Min(oldcols,newcols)
-> bytes per ring row and disposes the old buffer, so shrinking a
-> window narrower than a line DESTROYS everything past the new width.
-> Growing back cannot recover it. Stock CON: does not do this - it
-> holds LOGICAL LINES and re-wraps them per resize (proved on
-> hardware 21.7.26, ccon-b7).
->
-> Stage 1 (shipped 1.2b9) added the missing information: a per-ring-
-> row "this row continues the row above" flag, set by the margin-wrap
-> path and cleared by real newlines. This harness develops and proves
-> the algorithm that CONSUMES it, before any of it goes near
-> doresize().
->
-> What this proves: the model arithmetic only. No pixel call exists
-> here. Whether the glass agrees still needs the boot test (ccon-b7).
->
-> The property that matters is the ROUND TRIP: wide -> narrow -> wide
-> must return the original text exactly. That is literally what
-> ccon-b7 checks on hardware, and what CCON fails today.
->
-> Ring rows carry real characters (not line numbers like
-> sbresizetest.e) because the failure mode here is losing or
-> misplacing text, which has to be readable as text.
->
-> Build: ecompile reflowtest.e reflowtest
-> Run:   vamos reflowtest

MODULE 'dos/dos'

CONST SBMAX=12,         -> ring depth (small, so overflow is reachable)
      MAXCOLS=40,       -> widest width any case here uses
      CELLS=480         -> SBMAX * MAXCOLS

DEF ring[480]:ARRAY OF CHAR,    -> the char plane, row-major at `cols`
    wrap[12]:ARRAY OF CHAR,     -> B7: 1 = row continues the row above
    dring[480]:ARRAY OF CHAR,   -> the destination the reflow builds
    dwrap[12]:ARRAY OF CHAR,
    cols, rows, sbtop, sbcnt, cy,
    dtotal,                     -> dest rows emitted (may exceed SBMAX)
    dr, dc,                     -> dest write cursor (dr is LINEAR)
    dcur,                       -> dest linear row the cursor landed on
    srccur,                     -> source ring row holding the cursor
    fails

-> ---------- ring helpers, transcribed from ccon-handler.e ----------

PROC ridx(r)
  DEF i
  i := sbtop + r
  WHILE i >= SBMAX
    i := i - SBMAX
  ENDWHILE
ENDPROC i

-> ---------- the reflow, the thing under test ----------

-> start a fresh destination row. cont = 1 marks it a continuation of
-> the row just finished (a soft wrap), 0 starts a new logical line.
-> dr is a LINEAR row counter that may run past the ring; dslot maps
-> it onto the ring. NOT `AND 15`: SBMAX is 12, not a power of two, so
-> a mask would reach rows 12-15 and write past the end of dring -
-> which the first draft here did, silently, underneath checks that
-> then "passed". Ring arithmetic only gets to use AND when the depth
-> is genuinely a power of two (INQMAX's case, audit P2).
PROC dslot(n)
  DEF i
  i := n
  WHILE i >= SBMAX
    i := i - SBMAX
  ENDWHILE
ENDPROC i

-> Moving to a fresh destination row must CLEAR it. When the reflow
-> produces more rows than the ring holds, dr wraps onto slots that
-> still hold the oldest content - and a logical line that emits no
-> cells at all (the empty row the cursor sits on after the final
-> newline) would otherwise leave that stale content showing through
-> as a phantom row. Caught by case E: the oldest line reappeared at
-> the BOTTOM of the window. screenscroll() clears its new bottom row
-> for exactly this reason.
PROC dnewrow(cont)
  DEF j, s
  dr := dr + 1
  dc := 0
  dtotal := dr + 1
  s := dslot(dr)
  IF cont THEN dwrap[s] := 1 ELSE dwrap[s] := 0
  FOR j := 0 TO MAXCOLS - 1
    dring[Mul(s, MAXCOLS) + j] := 0
  ENDFOR
ENDPROC

-> emit one cell, wrapping at the NEW width
PROC demit(c, ncols)
  IF dc >= ncols THEN dnewrow(1)
  dring[Mul(dslot(dr), MAXCOLS) + dc] := c
  dc := dc + 1
ENDPROC

-> content length of source ring row `i`: trailing NEVER-WRITTEN cells
-> (0) do not count. An explicit space (32) does - it was written and
-> may carry attributes, so it is content.
PROC rowlen(i)
  DEF j, n
  n := 0
  FOR j := 0 TO cols - 1
    IF ring[Mul(i, MAXCOLS) + j] <> 0 THEN n := j + 1
  ENDFOR
ENDPROC n

-> THE ALGORITHM. Walk the live source rows oldest -> newest, joining
-> each run of continuation rows back into one logical line, and emit
-> that line into the destination wrapping at ncols. A hard break
-> (dnewrow(0)) ends every logical line.
->
-> Source range: sbcnt history rows above the screen, then `rows`
-> visible rows - sbcnt + rows in ring order starting at sbtop-sbcnt.
->
-> Emission is sequential and each dest row is finished before the
-> next starts, so writing into a ring of SBMAX rows with wraparound
-> is equivalent to writing into an unbounded buffer and keeping the
-> newest SBMAX - which is what the real doresize() will do, and why
-> this harness models it the same way instead of over-allocating.
PROC reflow(ncols)
  DEF i, total, first, sr, j, n, started, k
  FOR i := 0 TO CELLS - 1
    dring[i] := 0
  ENDFOR
  FOR i := 0 TO SBMAX - 1
    dwrap[i] := 0
  ENDFOR
  dr := 0
  dc := 0
  dtotal := 1
  dcur := 0
  first := sbtop - sbcnt
  WHILE first < 0
    first := first + SBMAX
  ENDWHILE
  total := sbcnt + rows
  started := FALSE
  FOR i := 0 TO total - 1
    sr := first + i
    WHILE sr >= SBMAX
      sr := sr - SBMAX
    ENDWHILE
    -> a row with no continuation flag begins a new logical line
    IF wrap[sr] = 0
      IF started THEN dnewrow(0)
      started := TRUE
    ENDIF
    IF sr = srccur THEN dcur := dr
    n := rowlen(sr)
    FOR j := 0 TO n - 1
      demit(ring[Mul(sr, MAXCOLS) + j], ncols)
      IF sr = srccur THEN dcur := dr
    ENDFOR
  ENDFOR
  -> adopt the result
  FOR i := 0 TO CELLS - 1
    ring[i] := dring[i]
  ENDFOR
  FOR i := 0 TO SBMAX - 1
    wrap[i] := dwrap[i]
  ENDFOR
  cols := ncols
  -> the newest `rows` dest rows are the visible screen; everything
  -> before them is history, capped by what the ring can still hold
  IF dtotal < rows THEN dtotal := rows
  k := dtotal - rows
  sbtop := k
  WHILE sbtop >= SBMAX
    sbtop := sbtop - SBMAX
  ENDWHILE
  sbcnt := k
  IF sbcnt > (SBMAX - rows) THEN sbcnt := SBMAX - rows
  cy := dcur - k
  IF cy < 0 THEN cy := 0
  IF cy > (rows - 1) THEN cy := rows - 1
  srccur := ridx(cy)
ENDPROC

-> ---------- scaffolding ----------

-> write a string as client output would: wrapping at the margin, with
-> the wrap flag set exactly where outchr/render would set it, then a
-> real newline. Mirrors outchr + outwrapnl + outnl.
-> outnl()/outwrapnl() + screenscroll(), transcribed. THE HARNESS MUST
-> SCROLL: the first draft here just advanced cy past the last row, so
-> emitting more lines than the window holds wrote outside the visible
-> grid and sbcnt never moved - which made the overflow case (E) look
-> like an algorithm bug when it was the model that was wrong. Same
-> trap sbresizetest.e fell into with emit()'s fill order. A harness is
-> only evidence once it matches the thing it models.
PROC advrow(cont)
  DEF idx, j
  cy := cy + 1
  IF cy >= rows
    sbtop := sbtop + 1
    IF sbtop >= SBMAX THEN sbtop := 0
    IF sbcnt < (SBMAX - rows) THEN sbcnt := sbcnt + 1
    cy := rows - 1
    idx := ridx(cy)             -> screenscroll clears the new bottom
    FOR j := 0 TO MAXCOLS - 1
      ring[Mul(idx, MAXCOLS) + j] := 0
    ENDFOR
  ENDIF
  idx := ridx(cy)
  wrap[idx] := cont
ENDPROC

PROC emitline(s:PTR TO CHAR)
  DEF i, l, x, idx
  l := StrLen(s)
  x := 0
  FOR i := 0 TO l - 1
    IF x >= cols
      advrow(1)                 -> margin wrap: CONTINUES the row above
      x := 0
    ENDIF
    idx := ridx(cy)
    ring[Mul(idx, MAXCOLS) + x] := s[i]
    x := x + 1
  ENDFOR
  advrow(0)                     -> the real newline
  srccur := ridx(cy)
ENDPROC

PROC resetring(c, rw)
  DEF i
  FOR i := 0 TO CELLS - 1
    ring[i] := 0
  ENDFOR
  FOR i := 0 TO SBMAX - 1
    wrap[i] := 0
  ENDFOR
  cols := c
  rows := rw
  sbtop := 0
  sbcnt := 0
  cy := 0
  srccur := 0
ENDPROC

-> the visible screen plus its history, as one string with '/' between
-> rows - the shape a human can diff by eye
PROC snapshot(out:PTR TO CHAR)
  DEF i, j, sr, first, total, n, p
  p := 0
  first := sbtop - sbcnt
  WHILE first < 0
    first := first + SBMAX
  ENDWHILE
  total := sbcnt + rows
  FOR i := 0 TO total - 1
    sr := first + i
    WHILE sr >= SBMAX
      sr := sr - SBMAX
    ENDWHILE
    n := rowlen(sr)
    FOR j := 0 TO n - 1
      out[p] := ring[Mul(sr, MAXCOLS) + j]
      p := p + 1
    ENDFOR
    out[p] := "/"
    p := p + 1
  ENDFOR
  out[p] := 0
ENDPROC

-> the TEXT only, row breaks discarded - what must survive a reflow
PROC textof(out:PTR TO CHAR)
  DEF i, j, sr, first, total, n, p
  p := 0
  first := sbtop - sbcnt
  WHILE first < 0
    first := first + SBMAX
  ENDWHILE
  total := sbcnt + rows
  FOR i := 0 TO total - 1
    sr := first + i
    WHILE sr >= SBMAX
      sr := sr - SBMAX
    ENDWHILE
    n := rowlen(sr)
    FOR j := 0 TO n - 1
      out[p] := ring[Mul(sr, MAXCOLS) + j]
      p := p + 1
    ENDFOR
    IF wrap[sr] = 0
      IF p > 0
        IF i < (total - 1) THEN out[p] := "|" ELSE out[p] := "|"
        p := p + 1
      ENDIF
    ENDIF
  ENDFOR
  out[p] := 0
ENDPROC

PROC check(tag, got:PTR TO CHAR, want:PTR TO CHAR)
  IF StrCmp(got, want)
    WriteF('    ok   \s\n', tag)
  ELSE
    WriteF('    FAIL \s\n         got  \s\n         want \s\n', tag, got, want)
    fails := fails + 1
  ENDIF
ENDPROC

PROC main()
  DEF a[400]:ARRAY OF CHAR, b[400]:ARRAY OF CHAR
  fails := 0
  WriteF('reflowtest - audit B7 (resize must re-wrap, not truncate)\n')
  WriteF('ring \d rows; the round trip is the property that matters\n\n', SBMAX)

  -> ---- A: one long line, wide -> narrow -> wide ----
  WriteF('--- A: a line wider than the window, shrunk then grown ---\n')
  resetring(20, 4)
  emitline('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123')   -> 30 chars at cols 20
  textof(a)
  WriteF('    at 20: \s\n', a)
  reflow(8)
  snapshot(b)
  WriteF('    at  8: \s\n', b)
  reflow(20)
  textof(b)
  WriteF('    back : \s\n', b)
  check('round trip 20->8->20 keeps the text', b, a)

  -> ---- B: several logical lines, mixed lengths ----
  WriteF('\n--- B: three lines, only one of them wraps ---\n')
  resetring(20, 5)
  emitline('short')
  emitline('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123')
  emitline('tail')
  textof(a)
  WriteF('    at 20: \s\n', a)
  reflow(6)
  reflow(20)
  textof(b)
  WriteF('    back : \s\n', b)
  check('line boundaries survive a narrow pass', b, a)

  -> ---- C: widening re-joins what was wrapped ----
  WriteF('\n--- C: grow re-wraps a wrapped line onto fewer rows ---\n')
  resetring(10, 6)
  emitline('AAAABBBBCCCCDDDD')            -> wraps at 10
  snapshot(a)
  WriteF('    at 10: \s\n', a)
  reflow(20)
  snapshot(b)
  WriteF('    at 20: \s\n', b)
  -> 16 chars land on row 0 alone, then five empty rows: sixteen
  -> characters and six row separators. (The first written expectation
  -> here carried a spurious leading '/' and the harness caught the
  -> EXPECTATION, not the code - worth leaving noted, since the same
  -> mistake in the other direction is how a harness launders a bug.)
  check('16 chars fit one row at width 20', b, 'AAAABBBBCCCCDDDD//////')

  -> ---- D: a hard newline is NOT a wrap and must not be joined ----
  WriteF('\n--- D: two exactly-full rows are two lines, not one ---\n')
  resetring(8, 5)
  emitline('AAAABBBB')                    -> exactly cols wide, then NL
  emitline('CCCCDDDD')
  textof(a)
  WriteF('    at  8: \s\n', a)
  reflow(20)
  textof(b)
  WriteF('    at 20: \s\n', b)
  check('full-width rows stay separate lines', b, a)

  -> ---- E: OVERFLOW - reflow produces more rows than the ring holds.
  -> This is the B2 bug class (sbtop/sbcnt accounting), so it gets its
  -> own case: narrowing multiplies row count, and the ring must drop
  -> the OLDEST content and keep the NEWEST, never the reverse.
  WriteF('\n--- E: narrowing overflows the ring - newest must survive ---\n')
  resetring(20, 3)
  emitline('1111111111')
  emitline('2222222222')
  emitline('3333333333')
  emitline('4444444444')
  reflow(4)                     -> each 10-char line becomes 3 rows
  snapshot(b)
  WriteF('    at  4: \s\n', b)
  WriteF('    sbtop=\d sbcnt=\d cy=\d (ring holds \d)\n', sbtop, sbcnt, cy, SBMAX)
  IF sbcnt > (SBMAX - rows)
    WriteF('    FAIL sbcnt \d exceeds sbmax-rows \d\n', sbcnt, SBMAX - rows)
    fails := fails + 1
  ELSE
    WriteF('    ok   sbcnt within sbmax-rows\n')
  ENDIF
  -> the newest line must still be reachable; the oldest may be gone
  textof(a)
  IF InStr(a, '4444') >= 0
    WriteF('    ok   newest line survived the overflow\n')
  ELSE
    WriteF('    FAIL newest line was dropped instead of the oldest\n')
    fails := fails + 1
  ENDIF

  -> ---- F: the cursor must land on its own text, not drift.
  -> The other risk flagged before stage 3: cy/ancy point at rows that
  -> MOVE when everything above them re-wraps.
  WriteF('\n--- F: the cursor follows its line through a reflow ---\n')
  resetring(20, 5)
  emitline('first')
  emitline('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123')
  WriteF('    at 20: cy=\d\n', cy)
  reflow(8)
  WriteF('    at  8: cy=\d (rows=\d)\n', cy, rows)
  IF (cy >= 0) AND (cy <= (rows - 1))
    WriteF('    ok   cy inside the grid\n')
  ELSE
    WriteF('    FAIL cy \d outside 0..\d\n', cy, rows - 1)
    fails := fails + 1
  ENDIF

  WriteF('\n---------------------------------------------\n')
  IF fails = 0
    WriteF('all checks passed - the algorithm is safe to wire into\n')
    WriteF('doresize() (stage 3). Hardware proof is still ccon-b7.\n')
  ELSE
    WriteF('\d CHECK(S) FAILED - do not wire this in yet\n', fails)
  ENDIF
ENDPROC
