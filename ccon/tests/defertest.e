/* defertest.e -- S2+S3 harness: the deferred-blit engine against the
   legacy immediate engine, cell for cell.

   The claim under test: for any byte stream cut into any packets, the
   1.2.2 deferred engine (model-first, dirty spans, one catch-up blit
   or a full rebuild at flush) leaves EXACTLY the state the 1.2.1
   immediate engine leaves - screen pixels, model ring, cursor, wrap
   flags, ring position. The pitfalls it exists to catch are the ones
   reasoned through in the handler comments:

     - dirt must scroll with the content (the span shift in dfscroll)
     - the k scroll-cleared rows must land exactly in the catch-up
       blit's vacated strip (no dirty mark, no repaint - the blit's
       own clear must be sufficient)
     - the dffull transition (pend >= rows, or FF) must not strand
       stale spans or half-cleared rows
     - a mid-packet flush (what CSI J/K/L/M/S/T/@/P do) must settle
       everything and let deferral resume cleanly in the same packet
     - packet boundaries must not matter (pend never crosses them)

   Both engines are REIMPLEMENTED here over byte grids: "screen" is a
   char+attr grid per engine, ScrollRaster becomes a shift+clear,
   Text/drawmodelcells become cell copies. The model/ring/wrap code
   mirrors the handler's structurally (visrow = sbtop+r mod sbmax,
   clearrow clears all planes + the wrap flag). What this harness
   cannot see is real blitter behaviour - that is srbench's and the
   boot checklist's job - but every line of df* BOOKKEEPING logic is
   the same shape as the handler's, so a bookkeeping bug here is a
   bookkeeping bug there.

   Run under vamos. Prints PASS or the first mismatch in full.

   Stream alphabet: printables, LF, CR, BS, TAB, FF, plus byte 1 as
   "mid-packet dfflush" (legacy no-op) to stand in for the pixel
   escapes. Directed scenarios first, then seeded-random packets -
   no Date/random dependency, the LCG is fixed-seed so every run is
   the same run. */

CONST COLS=10, ROWS=6, SBMAX=16,
      MCELLS=160,               -> SBMAX * COLS: the model planes
      SCELLS=60,                -> ROWS * COLS: the screen grids
      PACKETS=4000, PKMAX=40

DEF -> legacy engine: model+attr+wrap ring, screen grid, cursor
    lm[MCELLS]:ARRAY OF CHAR, la[MCELLS]:ARRAY OF CHAR,
    lw[SBMAX]:ARRAY OF CHAR,
    lsm[SCELLS]:ARRAY OF CHAR, lsa[SCELLS]:ARRAY OF CHAR,
    ltop=0, lcx=0, lcy=0,
    -> deferred engine: same shapes...
    dm[MCELLS]:ARRAY OF CHAR, da[MCELLS]:ARRAY OF CHAR,
    dw[SBMAX]:ARRAY OF CHAR,
    dsm[SCELLS]:ARRAY OF CHAR, dsa[SCELLS]:ARRAY OF CHAR,
    dtop=0, dcx=0, dcy=0,
    -> ...plus the deferral state proper (the code under test)
    dpend=0, dfull=FALSE,
    dfd[ROWS]:ARRAY OF CHAR, dfx0[ROWS]:ARRAY OF CHAR,
    dfx1[ROWS]:ARRAY OF CHAR,
    -> the current attr both engines stamp on writes; varied per packet
    -> so a span painted from the wrong row or column shows up in the
    -> attr plane even when the glyphs happen to match
    curat=1,
    seed=$1234,
    pkt[PKMAX]:ARRAY OF CHAR,
    fails=0

-> ---------------- shared helpers ----------------

PROC rnd(n)
  seed := Mul(seed, 1103515245) + 12345   -> the classic LCG; the first
  seed := seed AND $7FFFFFFF              -> attempt (x65+17) locked into
                                          -> a short high-residue cycle.
  -> Mod is a DIVS underneath: quotient past 16 bits OVERFLOWS and the
  -> "remainder" comes back garbage-large (this bit the first two runs
  -> of this harness - rnd(39) returned 156, the fill loop overran
  -> pkt[] and trampled the engine globals; the "failures" were the
  -> harness corrupting itself). 15 bits of dividend keeps DIVS honest.
ENDPROC Mod(Shr(seed, 7) AND $7FFF, n)

-> ---------------- legacy engine: paint-as-you-go ----------------

PROC lrow(r) IS Mod(ltop + r, SBMAX)

PROC lclearrow(r)
  DEF i, off
  off := Mul(lrow(r), COLS)
  FOR i := 0 TO COLS - 1
    lm[off + i] := 0
    la[off + i] := 0
  ENDFOR
  lw[lrow(r)] := 0
ENDPROC

PROC lscroll()
  DEF i
  FOR i := 0 TO SCELLS - COLS - 1   -> ScrollRaster: shift up one row,
    lsm[i] := lsm[i + COLS]         -> vacated bottom row cleared
    lsa[i] := lsa[i + COLS]
  ENDFOR
  FOR i := SCELLS - COLS TO SCELLS - 1
    lsm[i] := 0
    lsa[i] := 0
  ENDFOR
  ltop := Mod(ltop + 1, SBMAX)
  lclearrow(ROWS - 1)
ENDPROC

PROC lnl()
  lcx := 0
  lcy := lcy + 1
  IF lcy >= ROWS
    lscroll()
    lcy := ROWS - 1
  ENDIF
  lw[lrow(lcy)] := 0
ENDPROC

PROC lwrapnl()
  lnl()
  lw[lrow(lcy)] := 1
ENDPROC

PROC lputc(c)
  DEF off
  IF lcx >= COLS THEN lwrapnl()
  off := Mul(lrow(lcy), COLS) + lcx
  lm[off] := c
  la[off] := curat
  lsm[Mul(lcy, COLS) + lcx] := c    -> the immediate Text()
  lsa[Mul(lcy, COLS) + lcx] := curat
  lcx := lcx + 1
ENDPROC

PROC lff()
  DEF r, i
  FOR i := 0 TO SCELLS - 1          -> the RectFill
    lsm[i] := 0
    lsa[i] := 0
  ENDFOR
  FOR r := 0 TO ROWS - 1
    lclearrow(r)
  ENDFOR
  lcx := 0
  lcy := 0
ENDPROC

PROC lbyte(c)
  IF c = 10
    lnl()
  ELSEIF c = 13
    lcx := 0
  ELSEIF c = 8
    IF lcx > 0 THEN lcx := lcx - 1
  ELSEIF c = 9
    REPEAT
      lputc(32)
    UNTIL (Mod(lcx, 8) = 0) OR (lcx >= COLS)
  ELSEIF c = 12
    lff()
  ELSEIF c >= 32
    lputc(c)
  ENDIF                             -> byte 1: legacy no-op
ENDPROC

-> ---------------- deferred engine: the code under test ----------------

PROC drow(r) IS Mod(dtop + r, SBMAX)

PROC dclearrow(r)
  DEF i, off
  off := Mul(drow(r), COLS)
  FOR i := 0 TO COLS - 1
    dm[off + i] := 0
    da[off + i] := 0
  ENDFOR
  dw[drow(r)] := 0
ENDPROC

-> dfscroll(), the handler shape: ring bookkeeping + pend/full/shift
PROC dscroll()
  DEF r
  dtop := Mod(dtop + 1, SBMAX)
  dclearrow(ROWS - 1)
  IF dfull THEN RETURN
  dpend := dpend + 1
  IF dpend >= ROWS
    dfull := TRUE
    dpend := 0
    RETURN
  ENDIF
  FOR r := 0 TO ROWS - 2
    dfd[r] := dfd[r + 1]
    dfx0[r] := dfx0[r + 1]
    dfx1[r] := dfx1[r + 1]
  ENDFOR
  dfd[ROWS - 1] := 0
ENDPROC

PROC dnl()
  dcx := 0
  dcy := dcy + 1
  IF dcy >= ROWS
    dscroll()
    dcy := ROWS - 1
  ENDIF
  dw[drow(dcy)] := 0
ENDPROC

PROC dwrapnl()
  dnl()
  dw[drow(dcy)] := 1
ENDPROC

PROC dmark(r, x0, x1)
  IF dfull THEN RETURN
  IF (r < 0) OR (r > (ROWS - 1)) THEN RETURN
  IF dfd[r]
    IF x0 < dfx0[r] THEN dfx0[r] := x0
    IF x1 > dfx1[r] THEN dfx1[r] := x1
  ELSE
    dfd[r] := 1
    dfx0[r] := x0
    dfx1[r] := x1
  ENDIF
ENDPROC

PROC dputc(c)
  DEF off
  IF dcx >= COLS THEN dwrapnl()
  off := Mul(drow(dcy), COLS) + dcx
  dm[off] := c
  da[off] := curat
  dmark(dcy, dcx, dcx)              -> model + mark, NO screen write
  dcx := dcx + 1
ENDPROC

PROC dff()
  DEF r
  FOR r := 0 TO ROWS - 1
    dclearrow(r)
  ENDFOR
  dcx := 0
  dcy := 0
  dfull := TRUE
  dpend := 0
ENDPROC

PROC dflush()
  DEF r, i, x, soff, moff
  IF dfull
    FOR r := 0 TO ROWS - 1          -> redraw(): every row, full width,
      soff := Mul(r, COLS)          -> straight from the model
      moff := Mul(drow(r), COLS)
      FOR x := 0 TO COLS - 1
        dsm[soff + x] := dm[moff + x]
        dsa[soff + x] := da[moff + x]
      ENDFOR
    ENDFOR
    dfull := FALSE
    FOR r := 0 TO ROWS - 1
      dfd[r] := 0
    ENDFOR
  ELSE
    IF dpend > 0                    -> the ONE catch-up ScrollRaster
      FOR i := 0 TO SCELLS - Mul(dpend, COLS) - 1
        dsm[i] := dsm[i + Mul(dpend, COLS)]
        dsa[i] := dsa[i + Mul(dpend, COLS)]
      ENDFOR
      FOR i := SCELLS - Mul(dpend, COLS) TO SCELLS - 1
        dsm[i] := 0                 -> the vacated strip, blit-cleared
        dsa[i] := 0
      ENDFOR
      dpend := 0
    ENDIF
    FOR r := 0 TO ROWS - 1          -> drawmodelcells per dirty span
      IF dfd[r]
        soff := Mul(r, COLS)
        moff := Mul(drow(r), COLS)
        FOR x := dfx0[r] TO dfx1[r]
          dsm[soff + x] := dm[moff + x]
          dsa[soff + x] := da[moff + x]
        ENDFOR
        dfd[r] := 0
      ENDIF
    ENDFOR
  ENDIF
ENDPROC

PROC dbyte(c)
  IF c = 10
    dnl()
  ELSEIF c = 13
    dcx := 0
  ELSEIF c = 8
    IF dcx > 0 THEN dcx := dcx - 1
  ELSEIF c = 9
    REPEAT
      dputc(32)
    UNTIL (Mod(dcx, 8) = 0) OR (dcx >= COLS)
  ELSEIF c = 12
    dff()
  ELSEIF c = 1
    dflush()                        -> the CSI-J/K/... stand-in
  ELSEIF c >= 32
    dputc(c)
  ENDIF
ENDPROC

-> ---------------- the drive-and-compare loop ----------------

PROC feed(buf:PTR TO CHAR, n, tag)
  DEF i, r
  -> the deferred engine's packet: dfstart .. bytes .. dfflush,
  -> exactly render()'s bracket
  dpend := 0
  dfull := FALSE
  FOR r := 0 TO ROWS - 1
    dfd[r] := 0
  ENDFOR
  FOR i := 0 TO n - 1
    dbyte(buf[i])
  ENDFOR
  dflush()
  -> the legacy engine has no bracket: bytes act as they land
  FOR i := 0 TO n - 1
    lbyte(buf[i])
  ENDFOR
  compare(tag, buf, n)
ENDPROC

PROC compare(tag, buf:PTR TO CHAR, n)
  DEF i, bad=-1, r
  IF (lcx <> dcx) OR (lcy <> dcy) THEN bad := 1000
  IF Mod(ltop, SBMAX) <> Mod(dtop, SBMAX) THEN bad := 1001
  FOR i := 0 TO SCELLS - 1
    IF (lsm[i] <> dsm[i]) OR (lsa[i] <> dsa[i]) THEN bad := i
  ENDFOR
  FOR i := 0 TO MCELLS - 1
    IF (lm[i] <> dm[i]) OR (la[i] <> da[i]) THEN bad := 2000 + i
  ENDFOR
  FOR i := 0 TO SBMAX - 1
    IF lw[i] <> dw[i] THEN bad := 3000 + i
  ENDFOR
  IF bad = -1 THEN RETURN
  fails := fails + 1
  WriteF('FAIL packet \d len \d (last bad index \d, 1000=cursor 1001=ring 2000+=model 3000+=wrap)\n', tag, n, bad)
  WriteF('  legacy cx=\d cy=\d top=\d | defer cx=\d cy=\d top=\d\n',
         lcx, lcy, ltop, dcx, dcy, dtop)
  WriteF('  packet bytes:')
  FOR i := 0 TO Min(n, 60) - 1
    WriteF(' \d', buf[i])
  ENDFOR
  WriteF('\n  screens (legacy / defer):\n')
  FOR r := 0 TO ROWS - 1
    WriteF('   ')
    FOR i := 0 TO COLS - 1
      WriteF('\c', IF lsm[Mul(r, COLS) + i] < 32 THEN "." ELSE lsm[Mul(r, COLS) + i])
    ENDFOR
    WriteF('  ')
    FOR i := 0 TO COLS - 1
      WriteF('\c', IF dsm[Mul(r, COLS) + i] < 32 THEN "." ELSE dsm[Mul(r, COLS) + i])
    ENDFOR
    WriteF('\n')
  ENDFOR
ENDPROC

PROC directed()
  DEF b[64]:ARRAY OF CHAR, i, t=0
  -> 1: a full screen of newlines and change (the dffull transition)
  FOR i := 0 TO (ROWS * 2) + 1
    b[i] := 10
  ENDFOR
  feed(b, (ROWS * 2) + 2, t++)
  -> 2: FF alone
  b[0] := 12
  feed(b, 1, t++)
  -> 3: FF then a page (More's flip)
  b[0] := 12
  FOR i := 1 TO 30
    b[i] := 64 + Mod(i, 20)
  ENDFOR
  feed(b, 31, t++)
  -> 4: text, FF mid-packet, text again
  FOR i := 0 TO 9
    b[i] := 65 + i
  ENDFOR
  b[10] := 12
  FOR i := 11 TO 20
    b[i] := 97 + (i - 11)
  ENDFOR
  feed(b, 21, t++)
  -> 5: an exactly-COLS line + LF (the pending-wrap anchor shape)
  FOR i := 0 TO COLS - 1
    b[i] := 88
  ENDFOR
  b[COLS] := 10
  feed(b, COLS + 1, t++)
  -> 6: a COLS+1 line: wrap then one char (the conbench 78-in-77 shape)
  FOR i := 0 TO COLS
    b[i] := 89
  ENDFOR
  feed(b, COLS + 1, t++)
  -> 7: scroll debt then a mid-packet flush then more scroll debt
  b[0] := 10
  b[1] := 10
  b[2] := 65
  b[3] := 1
  b[4] := 10
  b[5] := 66
  feed(b, 6, t++)
  -> 8: TAB dance across the width
  FOR i := 0 TO 11
    b[i] := IF Mod(i, 3) = 0 THEN 9 ELSE 46
  ENDFOR
  feed(b, 12, t++)
  -> 9: CR overprint of a scrolled row
  FOR i := 0 TO 5
    b[i] := 72
  ENDFOR
  b[6] := 13
  b[7] := 74
  b[8] := 74
  feed(b, 9, t++)
  -> 10: BS at column 0 and mid-row
  b[0] := 8
  b[1] := 75
  b[2] := 75
  b[3] := 8
  b[4] := 76
  b[5] := 10
  feed(b, 6, t++)
ENDPROC

PROC main()
  DEF p, n, i, c
  directed()
  FOR p := 0 TO PACKETS - 1
    curat := 1 + Mod(p, 7)          -> a fresh attr stamp per packet
    n := 1 + rnd(PKMAX - 1)
    FOR i := 0 TO n - 1
      c := rnd(100)
      IF c < 52
        pkt[i] := 33 + rnd(90)      -> printable
      ELSEIF c < 74
        pkt[i] := 10                -> LF - scroll pressure is the point
      ELSEIF c < 80
        pkt[i] := 13
      ELSEIF c < 86
        pkt[i] := 9
      ELSEIF c < 90
        pkt[i] := 8
      ELSEIF c < 94
        pkt[i] := 12
      ELSE
        pkt[i] := 1                 -> mid-packet flush
      ENDIF
    ENDFOR
    feed(pkt, n, 100 + p)
    IF fails > 4
      WriteF('stopping after \d failures\n', fails)
      RETURN
    ENDIF
  ENDFOR
  IF fails = 0
    WriteF('PASS: \d directed + \d random packets, engines identical\n',
           10, PACKETS)
  ELSE
    WriteF('\d FAILURES\n', fails)
  ENDIF
ENDPROC
