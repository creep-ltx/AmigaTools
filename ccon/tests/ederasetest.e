/* ederasetest.e -- S1 harness: eraseedit's blip-only fast path against
   the 1.2.2b1 full-row repaint, pixel for pixel.

   The claim under test: whenever the fast path's conditions hold
   (edlast = 0, edext <= 1, srch off, model present), repainting the
   ONE normalized anchor cell leaves the screen in exactly the state
   the old full-row drawmodelrow loop left it in - and whenever any
   condition fails (typed text mirrored, a ghost, the Ctrl+R banner),
   the fast path DECLINES and the full body runs, so those cases
   cannot regress by construction. The b32 lesson says a claim like
   this gets a harness, not a hand-trace.

   The simulation: model planes (char+attr ring) and a screen grid per
   engine. drawedit-sim paints what the real drawedit paints for the
   states exercised: the mirrored text cells, the blip (the model cell
   marked inverse - char OR $80 on the sim screen), an optional ghost
   tail (pixels-only, char OR $40), and the srch banner (pixels-only
   overprint of prompt cells 0..ancx-1). eraseedit-sim comes in two
   flavours - OLD (mirror-zero loop + full drawmodelrow rows, always)
   and NEW (the fast path guarded exactly as the handler guards it,
   falling through to the same full body otherwise). Client output
   between edit-cycles goes through the same putc/nl/scroll sim
   defertest uses, INCLUDING \r overprints that park the anchor over
   client text (the b8 shape: the blip sits on a client cell and must
   give it back uninverted).

   Each cycle: [client writes] -> eraseedit -> [more client writes] ->
   reanchor -> drawedit, run in lockstep on both engines; screens,
   models, cursors and anchors compared after every step. Directed
   scenarios (pending-wrap anchor, banner, ghost, bottom-row wrap,
   blip-over-client-text) first, then seeded-random cycles. Note the
   Mod-is-a-DIVS rule: dividends stay under 15 bits (defertest paid
   for that lesson).

   Build: ecompile ederasetest.e ederasetest
   Run:   vamos ederasetest */

MODULE 'dos/dos'

CONST COLS=10, ROWS=6, SBMAX=16,
      MCELLS=160, SCELLS=60,
      CYCLES=3000

-> engine state, two of everything: index 0 = OLD, 1 = NEW
DEF ml[2]:ARRAY OF LONG,        -> -> model char plane (MCELLS)
    al[2]:ARRAY OF LONG,        -> -> model attr plane
    sl[2]:ARRAY OF LONG,        -> -> screen grid (SCELLS)
    tops[2]:ARRAY OF LONG, cxs[2]:ARRAY OF LONG, cys[2]:ARRAY OF LONG,
    anx[2]:ARRAY OF LONG, any[2]:ARRAY OF LONG,
    edl[2]:ARRAY OF LONG, edx[2]:ARRAY OF LONG,
    -> shared editor inputs, identical for both engines per cycle
    elen=0, srch=FALSE, ghost=0,  -> ghost = extra pixels past the blip
    curat=1,
    seed=$BEEF,
    fails=0,
    prevel=0, prevgh=0, prevsr=FALSE  -> last cycle's editor inputs, for
                                      -> the failure dump only

PROC rnd(n)
  seed := Mul(seed, 1103515245) + 12345
  seed := seed AND $7FFFFFFF
ENDPROC Mod(Shr(seed, 7) AND $7FFF, n)

PROC alloc()
  DEF e
  FOR e := 0 TO 1
    ml[e] := New(MCELLS)
    al[e] := New(MCELLS)
    sl[e] := New(SCELLS)
    IF (ml[e] = NIL) OR (al[e] = NIL) OR (sl[e] = NIL)
      WriteF('out of memory\n')
      CleanUp(20)
    ENDIF
  ENDFOR
ENDPROC

-> ---------- shared per-engine primitives ----------

PROC vrow(e, r)
  DEF i
  i := tops[e] + r
  WHILE i >= SBMAX DO i := i - SBMAX
ENDPROC Mul(i, COLS)

PROC clearrow(e, r)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, i, off
  m := ml[e]
  a := al[e]
  off := vrow(e, r)
  FOR i := 0 TO COLS - 1
    m[off + i] := 0
    a[off + i] := 0
  ENDFOR
ENDPROC

PROC scroll(e)
  DEF s:PTR TO CHAR, i
  s := sl[e]
  FOR i := 0 TO SCELLS - COLS - 1
    s[i] := s[i + COLS]
  ENDFOR
  FOR i := SCELLS - COLS TO SCELLS - 1
    s[i] := 0
  ENDFOR
  tops[e] := tops[e] + 1
  IF tops[e] >= SBMAX THEN tops[e] := 0
  clearrow(e, ROWS - 1)
  IF any[e] > 0 THEN any[e] := any[e] - 1
ENDPROC

PROC putc(e, c)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, s:PTR TO CHAR
  IF cxs[e] >= COLS
    cxs[e] := 0
    cys[e] := cys[e] + 1
    IF cys[e] >= ROWS
      scroll(e)
      cys[e] := ROWS - 1
    ENDIF
  ENDIF
  m := ml[e]
  a := al[e]
  s := sl[e]
  m[vrow(e, cys[e]) + cxs[e]] := c
  a[vrow(e, cys[e]) + cxs[e]] := curat
  s[Mul(cys[e], COLS) + cxs[e]] := c
  cxs[e] := cxs[e] + 1
ENDPROC

PROC clnl(e)
  cxs[e] := 0
  cys[e] := cys[e] + 1
  IF cys[e] >= ROWS
    scroll(e)
    cys[e] := ROWS - 1
  ENDIF
ENDPROC

-> repaint cells x0..x1 of view row r from the model - drawmodelcells
PROC dmc(e, r, x0, x1)
  DEF m:PTR TO CHAR, s:PTR TO CHAR, x, off
  IF (x0 < 0) THEN x0 := 0
  IF (x1 > (COLS - 1)) THEN x1 := COLS - 1
  IF x0 > x1 THEN RETURN
  m := ml[e]
  s := sl[e]
  off := vrow(e, r)
  FOR x := x0 TO x1
    s[Mul(r, COLS) + x] := m[off + x]
  ENDFOR
ENDPROC

PROC edlastrow(e, n) IS any[e] + Div((anx[e] + n), COLS)

-> ---------- drawedit-sim: identical for both engines ----------
-> paints elen mirror cells, the blip (model char OR $80), an optional
-> ghost tail (OR $40, pixels only), the srch banner (cells 0..ancx-1
-> overprinted with $7F, pixels only); sets edlast/edext like the real
-> proc: edext counts text + blip + ghost (blip at line end always
-> here - cpos = elen throughout, the shape every WRITE sees)
PROC dedraw(e)
  DEF m:PTR TO CHAR, s:PTR TO CHAR, i, cc, rr, bc, r, g
  -> edroom: scroll until the line + blip fits
  WHILE (edlastrow(e, elen + 1) > (ROWS - 1)) AND (any[e] > 0)
    scroll(e)
    IF cys[e] > 0 THEN cys[e] := cys[e] - 1
  ENDWHILE
  m := ml[e]
  s := sl[e]
  cc := anx[e]
  rr := any[e]
  FOR i := 0 TO elen - 1
    IF cc >= COLS
      cc := 0
      rr := rr + 1
    ENDIF
    IF rr <= (ROWS - 1)
      m[vrow(e, rr) + cc] := 97 + i          -> mirrored text cell
      s[Mul(rr, COLS) + cc] := 97 + i
    ENDIF
    cc := cc + 1
  ENDFOR
  -> the blip: inverse of the model cell at the normalized position
  bc := anx[e] + elen
  r := Div(bc, COLS)
  cc := bc - Mul(r, COLS)
  rr := any[e] + r
  IF rr <= (ROWS - 1)
    s[Mul(rr, COLS) + cc] := m[vrow(e, rr) + cc] OR $80
    -> the ghost tail: pixels only, same row, right of the blip
    g := ghost
    WHILE (g > 0) AND ((cc + g) <= (COLS - 1))
      s[Mul(rr, COLS) + cc + g] := $40 OR g
      g := g - 1
    ENDWHILE
  ENDIF
  IF srch
    FOR i := 0 TO anx[e] - 1                 -> the banner overprint
      IF any[e] <= (ROWS - 1)
        s[Mul(any[e], COLS) + i] := $7F
      ENDIF
    ENDFOR
  ENDIF
  edl[e] := elen
  edx[e] := elen + 1 + (IF ghost > 0 THEN ghost ELSE 0)
ENDPROC

-> ---------- eraseedit-sim, both flavours ----------
-> full body: the 1.2.2b1 shape - mirror-zero loop, then drawmodelrow
-> (= dmc full width) for rows ay0..r1
PROC deerase(e, fast)
  DEF n, ax0, ay0, r1, cc, r, j, m:PTR TO CHAR
  n := edl[e]
  edl[e] := 0
  ax0 := anx[e]
  ay0 := any[e]
  r1 := edlastrow(e, edx[e])
  IF r1 > (ROWS - 1) THEN r1 := ROWS - 1
  IF ax0 >= COLS
    ax0 := 0
    ay0 := ay0 + 1
  ENDIF
  -> the S1 fast path, guarded exactly as the handler guards it
  IF fast
    IF (n = 0) AND (edx[e] <= 1) AND (srch = FALSE)
      IF (edx[e] = 1) AND (ay0 <= (ROWS - 1))
        dmc(e, ay0, ax0, ax0)
      ENDIF
      edx[e] := 0
      RETURN
    ENDIF
  ENDIF
  m := ml[e]
  cc := ax0
  r := ay0
  FOR j := 0 TO n - 1
    IF r <= (ROWS - 1)
      m[vrow(e, r) + cc] := 0
      al[e] := al[e]                    -> (attr zero elided: attrs are
    ENDIF                               -> not compared through mirrors)
    cc := cc + 1
    IF cc >= COLS
      cc := 0
      r := r + 1
    ENDIF
  ENDFOR
  -> mirror-zero must hit the attr plane too, as the real proc does
  cc := ax0
  r := ay0
  FOR j := 0 TO n - 1
    IF r <= (ROWS - 1)
      m := al[e]
      m[vrow(e, r) + cc] := 0
      m := ml[e]
    ENDIF
    cc := cc + 1
    IF cc >= COLS
      cc := 0
      r := r + 1
    ENDIF
  ENDFOR
  FOR r := ay0 TO r1
    IF r <= (ROWS - 1) THEN dmc(e, r, 0, COLS - 1)
  ENDFOR
  edx[e] := 0
ENDPROC

-> ---------- lockstep driver ----------

PROC compare(tag)
  DEF i, bad=-1, s0:PTR TO CHAR, s1:PTR TO CHAR, m0:PTR TO CHAR,
      m1:PTR TO CHAR, r, c
  s0 := sl[0]
  s1 := sl[1]
  m0 := ml[0]
  m1 := ml[1]
  IF (cxs[0] <> cxs[1]) OR (cys[0] <> cys[1]) THEN bad := 1000
  IF (anx[0] <> anx[1]) OR (any[0] <> any[1]) THEN bad := 1001
  IF (tops[0] <> tops[1]) THEN bad := 1002
  IF (edl[0] <> edl[1]) OR (edx[0] <> edx[1]) THEN bad := 1003
  FOR i := 0 TO SCELLS - 1
    IF s0[i] <> s1[i] THEN bad := i
  ENDFOR
  FOR i := 0 TO MCELLS - 1
    IF m0[i] <> m1[i] THEN bad := 2000 + i
  ENDFOR
  IF bad = -1 THEN RETURN
  fails := fails + 1
  WriteF('FAIL cycle \d (bad \d; 1000=cursor 1001=anchor 1002=ring 1003=edstate 2000+=model)\n',
         tag, bad)
  WriteF('  old cx=\d cy=\d anc=\d,\d edl=\d edx=\d | new cx=\d cy=\d anc=\d,\d edl=\d edx=\d\n',
         cxs[0], cys[0], anx[0], any[0], edl[0], edx[0],
         cxs[1], cys[1], anx[1], any[1], edl[1], edx[1])
  WriteF('  cycle inputs: elen=\d ghost=\d srch=\d | prev: elen=\d ghost=\d srch=\d\n',
         elen, ghost, srch, prevel, prevgh, prevsr)
  WriteF('  screens (old / new), then MODEL view rows (old / new), . = 0:\n')
  FOR r := 0 TO ROWS - 1
    WriteF('   ')
    FOR i := 0 TO COLS - 1
      c := s0[Mul(r, COLS) + i]
      WriteF('\c', IF c = 0 THEN "." ELSE (IF (c AND $7F) < 32 THEN "?" ELSE c AND $7F))
    ENDFOR
    WriteF('  ')
    FOR i := 0 TO COLS - 1
      c := s1[Mul(r, COLS) + i]
      WriteF('\c', IF c = 0 THEN "." ELSE (IF (c AND $7F) < 32 THEN "?" ELSE c AND $7F))
    ENDFOR
    WriteF('   ')
    FOR i := 0 TO COLS - 1
      c := m0[vrow(0, r) + i]
      WriteF('\c', IF c = 0 THEN "." ELSE (IF (c AND $7F) < 32 THEN "?" ELSE c AND $7F))
    ENDFOR
    WriteF('  ')
    FOR i := 0 TO COLS - 1
      c := m1[vrow(1, r) + i]
      WriteF('\c', IF c = 0 THEN "." ELSE (IF (c AND $7F) < 32 THEN "?" ELSE c AND $7F))
    ENDFOR
    WriteF('\n')
  ENDFOR
ENDPROC

-> one client-output burst, same bytes to both engines
PROC burst(nn)
  DEF e, i, k, c
  FOR i := 0 TO nn - 1
    k := rnd(10)
    c := 33 + rnd(60)   -> drawn ONCE - the first run of this harness
                        -> called rnd() inside the per-engine loop and
                        -> fed the two engines different bytes; the
                        -> cycle-0 "failures" were the harness, again
    FOR e := 0 TO 1
      IF k < 6
        putc(e, c)
      ELSEIF k < 8
        clnl(e)
      ELSE
        cxs[e] := 0                     -> \r: the b8 overprint shape
      ENDIF
    ENDFOR
  ENDFOR
ENDPROC

PROC reanchor()
  DEF e
  FOR e := 0 TO 1
    anx[e] := cxs[e]
    any[e] := cys[e]
  ENDFOR
ENDPROC

-> one full edit cycle: erase (old vs new) around output, then repaint
PROC cycle(tag, outn, el, gh, sr)
  DEF e
  prevel := elen
  prevgh := ghost
  prevsr := srch
  -> NOTE the sequencing: the erase runs with the PREVIOUS cycle's
  -> srch/ghost/elen still in force, exactly as the handler does it -
  -> eraseedit always runs before the state that will feed the NEXT
  -> drawedit changes (every srch flip in dovanilla is bracketed by
  -> its own erase/draw pair). The new inputs land after the erase.
  deerase(0, FALSE)                     -> OLD: always the full body
  deerase(1, TRUE)                      -> NEW: fast path when it may
  elen := el
  ghost := gh
  srch := sr
  burst(outn)
  reanchor()
  dedraw(0)
  dedraw(1)
  compare(tag)
ENDPROC

PROC main()
  DEF t, i
  alloc()
  -> settle both engines into a known identical start
  burst(8)
  reanchor()
  dedraw(0)
  dedraw(1)
  compare(0)
  -> directed: the load-bearing shapes, one condition at a time
  cycle(1, 5, 0, 0, FALSE)              -> plain write, empty editor: THE path
  cycle(2, 0, 0, 0, FALSE)              -> no output at all between edits
  cycle(3, 3, 0, 0, TRUE)               -> banner up: fast path must decline
  cycle(4, 3, 0, 2, FALSE)              -> ghost up: edext > 1, decline
  cycle(5, 3, 4, 0, FALSE)              -> typed text mirrored: n > 0, decline
  cycle(6, 2, 0, 0, FALSE)
  -> park the anchor at the pending-wrap column: fill the row exactly
  FOR i := 1 TO COLS
    putc(0, 65)
    putc(1, 65)
  ENDFOR
  reanchor()
  dedraw(0)
  dedraw(1)
  compare(7)
  cycle(8, 4, 0, 0, FALSE)              -> erase from the wrapped anchor
  -> random soak: output lengths, editor states, flags all seeded
  FOR t := 0 TO CYCLES - 1
    cycle(100 + t,
          rnd(24),                      -> output burst length
          IF rnd(4) = 0 THEN rnd(6) ELSE 0,   -> sometimes typed text
          IF rnd(6) = 0 THEN rnd(3) ELSE 0,   -> sometimes a ghost
          IF rnd(8) = 0 THEN TRUE ELSE FALSE) -> sometimes the banner
    IF fails > 4
      WriteF('stopping after \d failures\n', fails)
      CleanUp(10)
    ENDIF
  ENDFOR
  IF fails = 0
    WriteF('PASS: 9 directed + \d random cycles, old and new eraseedit pixel-identical\n', CYCLES)
  ELSE
    WriteF('\d FAILURES\n', fails)
  ENDIF
ENDPROC
