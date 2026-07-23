/* masktest.e -- 1.2.3 harness: the plane-mask invariant, simulated at
   the plane level.

   The claim (ccon-handler.e, the maskcalc block): within the window
   region, every plane outside mmask is all-zero, PROVIDED (a) the
   mask grows before the first draw with any new pen, and (b) masked
   operations (scroll, fill, JAM2 glyph writes) happen only while no
   full-depth overlay pixels are on screen - overlays draw AND erase
   at full mask, outside the masked bracket.

   The simulation: a cell grid stored as four bit-planes. Every
   operation honours the current mask exactly the way the blitter
   does - unmasked planes are simply not touched, whether drawing,
   scrolling or clearing. A reference grid runs the same operations
   at full depth. After every op the planes are recomposed into pen
   values and compared cell-for-cell against the reference: any
   difference is the invariant broken - plane droppings, ghost
   fragments, wrong colours.

   Three runs:
   1. RULES KEPT: random transcript ops (draws with a palette that
      widens over time, scrolls, clears) under grow-before-draw,
      plus overlay draw/erase pairs (a pen-8 ghost) at full mask
      between masked "packets". Must stay identical for the whole
      soak - this is the handler's design, proven.
   2. CONTROL A: the mask grows AFTER the draw (rule (a) broken on
      purpose). The harness MUST report corruption - otherwise the
      harness itself is blind and run 1 proved nothing.
   3. CONTROL B: an overlay is left on screen across a masked scroll
      (rule (b) broken). Must also corrupt - this is the ghost-
      droppings scenario the render-bracket design exists to prevent.
   4. CONTROL C (b2): a full-depth RESTORE (alt-screen return, resize
      pulling coloured history into view) WITHOUT the rescan that
      must follow it. Must corrupt.
   5. CONTROL D (b2): the narrow happens BEFORE the clear instead of
      after - the clear then runs at the new narrow mask and the old
      content's planes are never cleaned. Must corrupt.

   b2 adds rule (c): the mask may NARROW only immediately after the
   entire region was repainted or cleared at the OLD mask (form feed,
   resize reflow, alt-screen switch, iconify restore), and any
   full-depth restore of wider-penned content must rescan BEFORE the
   next masked operation.

   Mod is a DIVS: dividends stay under 15 bits (the defertest lesson).

   Build: ecompile masktest.e masktest
   Run:   vamos masktest */

MODULE 'dos/dos'

CONST COLS=8, ROWS=6, CELLS=48, PLANES=4, OPS=4000

DEF pl[192]:ARRAY OF CHAR,      -> PLANES*CELLS: the masked screen bits
    ref[48]:ARRAY OF CHAR,      -> full-depth reference, pen per cell
    mask, upens,
    seed=$C0DE,
    fails

PROC rnd(n)
  seed := Mul(seed, 1103515245) + 12345
  seed := seed AND $7FFFFFFF
ENDPROC Mod(Shr(seed, 7) AND $7FFF, n)

PROC tier(u)
  IF u <= 1 THEN RETURN 1
  IF u <= 3 THEN RETURN 3
ENDPROC $FF

-> write pen v into cell c honouring the CURRENT mask (a JAM2 cell
-> write: every writable plane gets its bit of v, others untouched)
PROC pwrite(c, v, m)
  DEF p
  FOR p := 0 TO PLANES - 1
    IF m AND Shl(1, p)
      pl[Mul(p, CELLS) + c] := IF v AND Shl(1, p) THEN 1 ELSE 0
    ENDIF
  ENDFOR
ENDPROC

-> scroll the grid up one row honouring the mask: masked planes move
-> and their bottom row clears; unmasked planes are NOT TOUCHED -
-> exactly what a masked ScrollRaster does
PROC pscroll(m)
  DEF p, c, base
  FOR p := 0 TO PLANES - 1
    IF m AND Shl(1, p)
      base := Mul(p, CELLS)
      FOR c := 0 TO CELLS - COLS - 1
        pl[base + c] := pl[base + c + COLS]
      ENDFOR
      FOR c := CELLS - COLS TO CELLS - 1
        pl[base + c] := 0
      ENDFOR
    ENDIF
  ENDFOR
ENDPROC

PROC pclear(m)
  DEF p, c, base
  FOR p := 0 TO PLANES - 1
    IF m AND Shl(1, p)
      base := Mul(p, CELLS)
      FOR c := 0 TO CELLS - 1
        pl[base + c] := 0
      ENDFOR
    ENDIF
  ENDFOR
ENDPROC

-> the reference runs the same ops at full depth
PROC rwrite(c, v)
  ref[c] := v
ENDPROC

PROC rscroll()
  DEF c
  FOR c := 0 TO CELLS - COLS - 1
    ref[c] := ref[c + COLS]
  ENDFOR
  FOR c := CELLS - COLS TO CELLS - 1
    ref[c] := 0
  ENDFOR
ENDPROC

PROC rclear()
  DEF c
  FOR c := 0 TO CELLS - 1
    ref[c] := 0
  ENDFOR
ENDPROC

PROC recompose(c)
  DEF p, v=0
  FOR p := 0 TO PLANES - 1
    IF pl[Mul(p, CELLS) + c] THEN v := v OR Shl(1, p)
  ENDFOR
ENDPROC v

PROC check(tag, op)
  DEF c
  FOR c := 0 TO CELLS - 1
    IF recompose(c) <> ref[c]
      fails := fails + 1
      IF fails < 4
        WriteF('  MISMATCH run \d op \d cell \d: screen \d, reference \d (mask \d upens \d)\n',
               tag, op, c, recompose(c), ref[c], mask, upens)
      ENDIF
      RETURN
    ENDIF
  ENDFOR
ENDPROC

-> erase the overlay at FULL mask, repainting the cell from the
-> model - drawedit/eraseedit's job. The handler erases at where it
-> BELIEVES the overlay is; if that has drifted off the grid (control
-> B scrolled it away), nothing is erased and the droppings stand.
PROC overase(ovc)
  IF (ovc >= 0) AND (ovc < CELLS) THEN pwrite(ovc, ref[ovc], $FF)
ENDPROC

-> rule (c)'s rescan: the mask re-derives from what the model
-> actually holds (maskscan() in the handler; ref IS the model here)
PROC rescanref()
  DEF c
  upens := 1
  FOR c := 0 TO CELLS - 1
    upens := upens OR ref[c]
  ENDFOR
  mask := tier(upens)
ENDPROC

-> one soak. growlate = control A (mask grows after the draw);
-> stickyoverlay = control B (an overlay survives into masked scrolls,
-> and the handler's idea of its position moves with the text while
-> its unmasked plane bits stay put - the ghost-droppings shape)
PROC soak(tag, growlate, stickyoverlay, badc, badd)
  DEF i, k, c, v, ovc=-999      -> -999 = no overlay (drift can pass -1)
  FOR i := 0 TO 191 DO pl[i] := 0
  FOR i := 0 TO CELLS - 1 DO ref[i] := 0
  upens := 1                    -> deffg seeded, like gridcalc does
  mask := tier(upens)
  fails := 0
  FOR i := 0 TO OPS - 1
    k := rnd(100)
    -> rule (b): before any MASKED op, overlays are erased (that is
    -> what running only render() masked, after eraseedit/curserase,
    -> means). Control B skips this and lets scrolls run under one.
    IF (k < 85) AND (ovc > -999) AND (stickyoverlay = FALSE)
      overase(ovc)
      ovc := -999
    ENDIF
    IF k < 55
      -> a transcript draw; the palette widens as a session would:
      -> mostly pen 1, sometimes 2-3, rarely bright pens
      c := rnd(CELLS)
      v := 1
      IF rnd(10) = 0 THEN v := 2 + rnd(2)
      IF rnd(40) = 0 THEN v := 8 + rnd(8)
      IF growlate = FALSE
        upens := upens OR v            -> rule (a): grow BEFORE
        mask := tier(upens)
      ENDIF
      pwrite(c, v, mask)
      rwrite(c, v)
      IF growlate
        upens := upens OR v            -> control A: grow AFTER - the
        mask := tier(upens)            -> draw above ran under-masked
      ENDIF
    ELSEIF k < 80
      pscroll(mask)
      rscroll()
      IF ovc > -999
        ovc := ovc - COLS              -> control B: the handler thinks
      ENDIF                            -> the ghost moved with the text;
                                       -> its plane bits did not
    ELSEIF k < 82
      -> the form feed: clear at the OLD mask (which covers all
      -> content planes by the invariant), THEN narrow - rule (c).
      -> Control D inverts the order and must corrupt.
      IF badd
        rclear()
        rescanref()                    -> narrow first (WRONG)...
        pclear(mask)                   -> ...then clear too narrow
      ELSE
        pclear(mask)
        rclear()
        rescanref()                    -> narrow after: sound
      ENDIF
      IF ovc > -999 THEN ovc := -999   -> a clear abandons any ghost
    ELSEIF k < 88
      -> the restore: full-depth repaint of wider-penned content (alt
      -> screen return, reflow pulling coloured history into view) -
      -> then rule (c)'s rescan widens the mask BEFORE the next
      -> masked op. Control C forgets the rescan.
      c := rnd(CELLS)
      v := 8 + rnd(8)
      pwrite(c, v, $FF)
      rwrite(c, v)
      IF badc = FALSE THEN rescanref()
    ELSE
      -> a ghost appears: pen 8, drawn at FULL mask, never grows upens
      IF ovc > -999
        overase(ovc)                   -> one overlay at a time
      ENDIF
      ovc := rnd(CELLS)
      pwrite(ovc, 8, $FF)
    ENDIF
    -> the reference never sees overlays (pixels-only); compare only
    -> when none is meant to be on screen
    IF ovc = -999 THEN check(tag, i)
    IF fails >= 4 THEN RETURN fails
  ENDFOR
ENDPROC fails

PROC main()
  DEF f1, f2, f3, f4, f5, ok=TRUE
  f1 := soak(1, FALSE, FALSE, FALSE, FALSE)
  IF f1 = 0
    WriteF('run 1 (rules kept, narrow+restore included): clean over \d ops\n', OPS)
  ELSE
    WriteF('run 1 (rules kept): \d FAILURES - THE DESIGN IS BROKEN\n', f1)
    ok := FALSE
  ENDIF
  f2 := soak(2, TRUE, FALSE, FALSE, FALSE)
  IF f2 > 0
    WriteF('run 2 (control A, grow-after-draw): corrupts as it must (\d)\n', f2)
  ELSE
    WriteF('run 2 (control A): NO corruption - the harness is blind\n')
    ok := FALSE
  ENDIF
  f3 := soak(3, FALSE, TRUE, FALSE, FALSE)
  IF f3 > 0
    WriteF('run 3 (control B, overlay across masked scroll): corrupts as it must (\d)\n', f3)
  ELSE
    WriteF('run 3 (control B): NO corruption - the harness is blind\n')
    ok := FALSE
  ENDIF
  f4 := soak(4, FALSE, FALSE, TRUE, FALSE)
  IF f4 > 0
    WriteF('run 4 (control C, restore without rescan): corrupts as it must (\d)\n', f4)
  ELSE
    WriteF('run 4 (control C): NO corruption - the harness is blind\n')
    ok := FALSE
  ENDIF
  f5 := soak(5, FALSE, FALSE, FALSE, TRUE)
  IF f5 > 0
    WriteF('run 5 (control D, narrow before the clear): corrupts as it must (\d)\n', f5)
  ELSE
    WriteF('run 5 (control D): NO corruption - the harness is blind\n')
    ok := FALSE
  ENDIF
  IF ok THEN WriteF('PASS\n') ELSE WriteF('FAIL\n')
ENDPROC
