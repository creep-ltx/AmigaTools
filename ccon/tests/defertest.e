/* defertest.e -- S2+S3 harness: the deferred-blit engine against the
   legacy immediate engine, cell for cell. v2 (E1, 1.2.4): the eight
   region escapes (K J @ P L M S T) join the streams as model ops
   with dirty marks in the deferred engine, against their legacy
   immediate forms - plus cursor positioning so they land anywhere.
   Op bytes in the test alphabet: 2=K 3=J 4=@ 5=P 6=L 7=M 14=S 15=T
   16=cursor-jump (both engines alike, no flush).

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
   the same run.

   v3 (J1, 1.2.8): JUMP=n jump scroll. Both engines' nl() grows the
   handler's exact bottom-margin fork: scroll jmp rows (one blit /
   jmp ring advances) and land the cursor jmp rows up. Three claims:

     A. engine equivalence survives jumping - the full v2 suite runs
        at jmp 1 (regression, the untouched claim), 3 and ROWS-1,
        legacy vs deferred cell-identical throughout;
     B. jumping changes WHEN rows scroll, never WHAT the console
        holds: for pure stream output (no FF, no region ops, no
        cursor jumps - the only traffic jumpok() lets jump) the
        logical stream [rows scrolled into history] ++ [visible rows
        0..cy] of a jmp=3 deferred run equals a jmp=1 legacy run's,
        wrap flags included, cursor column identical, and every
        visible row BELOW the jumped cursor is blank;
     C. the harness can SEE (controls): a jump that forgets to clear
        the vacated ring rows, and one that lands the cursor a row
        low, must both diverge - plus v2's forced-blank lie, kept.

   Claim B is the one that needed a new instrument: the transcript
   log - every row appended to history at scroll time, compared as
   an append-only stream with a watermark, plus the ring-offset
   (d0 = dtn-ltn) alignment of the two visible regions. */

CONST COLS=10, ROWS=6, SBMAX=16,
      MCELLS=160,               -> SBMAX * COLS: the model planes
      SCELLS=60,                -> ROWS * COLS: the screen grids
      PACKETS=4000, PKMAX=40,
      TRMAX=6000,               -> transcript rows per engine (claim B)
      TRPACKETS=300             -> claim B packet count (avg ~14
                                -> scrolls per packet stays under TRMAX)

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
    dgen=0, dblo=0, dbhi=-1,    -> E2a/b mirror: generation-counter
                                -> dirty flags + the dirty row range
    dvblank=TRUE,               -> E5: deferred engine's blank-screen
                                -> flag - skip the catch-up shift when
                                -> the screen is provably blank
    forcevb=FALSE,              -> control: force dvblank TRUE always
                                -> (a lie) - must make the grids diverge
    -> v3 (J1): per-engine jump counts (1 = classic scroll-by-one;
    -> phases A set both alike, claim B runs legacy@1 vs deferred@3)
    ljmp=1, djmp=1,
    -> claim B: the transcript logs - every row that leaves the
    -> visible region, in order, content + attr + wrap flag
    trlog=FALSE,                -> appending armed (B/C phases only -
                                -> the A phases would overflow TRMAX)
    ltrm:PTR TO CHAR, ltra:PTR TO CHAR, ltrw:PTR TO CHAR, ltn=0,
    dtrm:PTR TO CHAR, dtra:PTR TO CHAR, dtrw:PTR TO CHAR, dtn=0,
    trchk=0,                    -> transcript rows already proven equal
    trover=FALSE,               -> TRMAX exceeded (phase ends cleanly)
    -> claim C controls, deferred engine's jump only: a lie each
    forcejclear=FALSE,          -> jump skips the vacated-row clears
    forcejland=FALSE,           -> jump lands the cursor one row low
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
  DEF i, off
  IF trlog                          -> v3 claim B: row 0 enters history
    IF ltn < TRMAX
      off := Mul(lrow(0), COLS)
      FOR i := 0 TO COLS - 1
        ltrm[Mul(ltn, COLS) + i] := lm[off + i]
        ltra[Mul(ltn, COLS) + i] := la[off + i]
      ENDFOR
      ltrw[ltn] := lw[lrow(0)]
      ltn := ltn + 1
    ELSE
      trover := TRUE
    ENDIF
  ENDIF
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
  DEF k
  lcx := 0
  lcy := lcy + 1
  IF lcy >= ROWS
    IF ljmp > 1                     -> v3 (J1): the handler's outnl fork
      FOR k := 1 TO ljmp DO lscroll()
      lcy := ROWS - ljmp
    ELSE
      lscroll()
      lcy := ROWS - 1
    ENDIF
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

-> the legacy region ops: model change + IMMEDIATE screen mirror,
-> the 1.2.3 shapes (clamps included)
PROC lk()
  DEF j
  IF lcx >= COLS THEN RETURN
  FOR j := lcx TO COLS - 1
    lm[Mul(lrow(lcy), COLS) + j] := 0
    la[Mul(lrow(lcy), COLS) + j] := 0
    lsm[Mul(lcy, COLS) + j] := 0
    lsa[Mul(lcy, COLS) + j] := 0
  ENDFOR
  IF (lcy + 1) <= (ROWS - 1) THEN lw[lrow(lcy + 1)] := 0  -> B7 shape
ENDPROC

PROC lj()
  DEF r, j
  lk()
  FOR r := lcy + 1 TO ROWS - 1
    lclearrow(r)
    FOR j := 0 TO COLS - 1
      lsm[Mul(r, COLS) + j] := 0
      lsa[Mul(r, COLS) + j] := 0
    ENDFOR
  ENDFOR
ENDPROC

PROC lich(n)
  DEF j, mo, so
  IF lcx >= COLS THEN RETURN
  IF n > (COLS - lcx) THEN n := COLS - lcx
  mo := Mul(lrow(lcy), COLS)
  so := Mul(lcy, COLS)
  FOR j := COLS - 1 TO lcx + n STEP -1
    lm[mo + j] := lm[mo + j - n]
    la[mo + j] := la[mo + j - n]
    lsm[so + j] := lsm[so + j - n]
    lsa[so + j] := lsa[so + j - n]
  ENDFOR
  FOR j := lcx TO lcx + n - 1
    lm[mo + j] := 0
    la[mo + j] := 0
    lsm[so + j] := 0
    lsa[so + j] := 0
  ENDFOR
ENDPROC

PROC ldch(n)
  DEF j, mo, so
  IF lcx >= COLS THEN RETURN
  IF n > (COLS - lcx) THEN n := COLS - lcx
  mo := Mul(lrow(lcy), COLS)
  so := Mul(lcy, COLS)
  FOR j := lcx TO COLS - 1 - n
    lm[mo + j] := lm[mo + j + n]
    la[mo + j] := la[mo + j + n]
    lsm[so + j] := lsm[so + j + n]
    lsa[so + j] := lsa[so + j + n]
  ENDFOR
  FOR j := COLS - n TO COLS - 1
    lm[mo + j] := 0
    la[mo + j] := 0
    lsm[so + j] := 0
    lsa[so + j] := 0
  ENDFOR
ENDPROC

-> row-content moves between visible slots, top = row `top`, count n
PROC lrmove(top, n, down)
  DEF r, j
  IF n > (ROWS - top) THEN n := ROWS - top
  FOR r := top TO ROWS - 1
    lw[lrow(r)] := 0                 -> B7: dropwrapf across the region
  ENDFOR
  IF down
    FOR r := ROWS - 1 TO top + n STEP -1
      FOR j := 0 TO COLS - 1
        lm[Mul(lrow(r), COLS) + j] := lm[Mul(lrow(r - n), COLS) + j]
        la[Mul(lrow(r), COLS) + j] := la[Mul(lrow(r - n), COLS) + j]
        lsm[Mul(r, COLS) + j] := lsm[Mul(r - n, COLS) + j]
        lsa[Mul(r, COLS) + j] := lsa[Mul(r - n, COLS) + j]
      ENDFOR
    ENDFOR
    FOR r := top TO top + n - 1
      lclearrow(r)
      FOR j := 0 TO COLS - 1
        lsm[Mul(r, COLS) + j] := 0
        lsa[Mul(r, COLS) + j] := 0
      ENDFOR
    ENDFOR
  ELSE
    FOR r := top TO ROWS - 1 - n
      FOR j := 0 TO COLS - 1
        lm[Mul(lrow(r), COLS) + j] := lm[Mul(lrow(r + n), COLS) + j]
        la[Mul(lrow(r), COLS) + j] := la[Mul(lrow(r + n), COLS) + j]
        lsm[Mul(r, COLS) + j] := lsm[Mul(r + n, COLS) + j]
        lsa[Mul(r, COLS) + j] := lsa[Mul(r + n, COLS) + j]
      ENDFOR
    ENDFOR
    FOR r := ROWS - n TO ROWS - 1
      lclearrow(r)
      FOR j := 0 TO COLS - 1
        lsm[Mul(r, COLS) + j] := 0
        lsa[Mul(r, COLS) + j] := 0
      ENDFOR
    ENDFOR
  ENDIF
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
  ELSEIF c = 2
    lk()
  ELSEIF c = 3
    lj()
  ELSEIF c = 4
    lich(2)
  ELSEIF c = 5
    ldch(2)
  ELSEIF c = 6
    lrmove(lcy, 1, TRUE)              -> L: insert line at cursor
  ELSEIF c = 7
    lrmove(lcy, 1, FALSE)             -> M: delete line at cursor
  ELSEIF c = 14
    lrmove(0, 1, FALSE)               -> S: whole region up
  ELSEIF c = 15
    lrmove(0, 1, TRUE)                -> T: whole region down
  ELSEIF (c >= 20) AND (c <= 25)
    lcy := c - 20
    lcx := Mod(Mul(c - 20, 7) + c, COLS)
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
  DEF r, i, off
  IF trlog                          -> v3 claim B: row 0 enters history
    IF dtn < TRMAX
      off := Mul(drow(0), COLS)
      FOR i := 0 TO COLS - 1
        dtrm[Mul(dtn, COLS) + i] := dm[off + i]
        dtra[Mul(dtn, COLS) + i] := da[off + i]
      ENDFOR
      dtrw[dtn] := dw[drow(0)]
      dtn := dtn + 1
    ELSE
      trover := TRUE
    ENDIF
  ENDIF
  dtop := Mod(dtop + 1, SBMAX)
  dclearrow(ROWS - 1)
  IF dfull THEN RETURN
  dpend := dpend + 1
  IF dpend >= ROWS
    dfull := TRUE
    dpend := 0
    RETURN
  ENDIF
  IF dbhi >= 0                  -> E2b mirror: bounded shift
    FOR r := Max(dblo - 1, 0) TO dbhi - 1
      dfd[r] := dfd[r + 1]
      dfx0[r] := dfx0[r + 1]
      dfx1[r] := dfx1[r + 1]
    ENDFOR
    dfd[dbhi] := 0
    dblo := Max(dblo - 1, 0)
    dbhi := dbhi - 1
  ENDIF
ENDPROC

PROC dnl()
  DEF k
  dcx := 0
  dcy := dcy + 1
  IF dcy >= ROWS
    IF djmp > 1                     -> v3 (J1): the handler's dfnl fork
      FOR k := 1 TO djmp
        dscroll()
        IF forcejclear              -> control: "forgot the clear" -
          dm[Mul(drow(ROWS - 1), COLS)] := 99  -> stale junk survives
        ENDIF                       -> in a vacated row
      ENDFOR
      dcy := ROWS - djmp
      IF forcejland THEN dcy := (ROWS - djmp) + 1  -> control: a row low
    ELSE
      dscroll()
      dcy := ROWS - 1
    ENDIF
  ENDIF
  dw[drow(dcy)] := 0
ENDPROC

PROC dwrapnl()
  dnl()
  dw[drow(dcy)] := 1
ENDPROC

PROC dmark(r, x0, x1) IS dmark2(r, x0, x1)  -> v1's mark, forwarded:
  -> the E2a patch converted dmark2 and this one kept writing boolean
  -> dirt the gen-aware flush no longer accepts - the harness caught
  -> its own split-brain within four packets

PROC dputc(c)
  DEF off
  IF dcx >= COLS THEN dwrapnl()
  dvblank := FALSE                  -> E5: a glyph on screen
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
  dvblank := TRUE                   -> E5: the page is blank now
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
  ELSE
    IF dpend > 0                    -> the ONE catch-up ScrollRaster
      IF (forcevb = FALSE) AND (dvblank = FALSE)  -> E5: skip when blank.
        FOR i := 0 TO SCELLS - Mul(dpend, COLS) - 1  -> forcevb forces the
          dsm[i] := dsm[i + Mul(dpend, COLS)]        -> flag TRUE (a lie) =
          dsa[i] := dsa[i + Mul(dpend, COLS)]        -> always-skip, which
        ENDFOR                                        -> MUST diverge from
        FOR i := SCELLS - Mul(dpend, COLS) TO SCELLS - 1  -> the always-
          dsm[i] := 0                                     -> shifting legacy
          dsa[i] := 0                                     -> on real content
        ENDFOR
      ENDIF
      dpend := 0
    ENDIF
    IF dbhi >= dblo                 -> E2b mirror: scan the range only
      FOR r := dblo TO dbhi
        IF dfd[r] = dgen
          soff := Mul(r, COLS)
          moff := Mul(drow(r), COLS)
          FOR x := dfx0[r] TO dfx1[r]
            dsm[soff + x] := dm[moff + x]
            dsa[soff + x] := da[moff + x]
          ENDFOR
        ENDIF
      ENDFOR
    ENDIF
  ENDIF
  dgen := dgen + 1                  -> E2a mirror: O(1) invalidation
  IF dgen > 255
    FOR r := 0 TO ROWS - 1
      dfd[r] := 0
    ENDFOR
    dgen := 1
  ENDIF
  dblo := ROWS
  dbhi := -1
ENDPROC

-> E1: the deferred region ops - the SAME model changes as the l*
-> twins, dirty marks instead of screen writes. dmarkrows = the
-> handler's dfmarkrows.
PROC dmark2(r, x0, x1)
  IF dfull THEN RETURN
  IF (r < 0) OR (r > (ROWS - 1)) THEN RETURN
  IF dfd[r] = dgen              -> E2a mirror
    IF x0 < dfx0[r] THEN dfx0[r] := x0
    IF x1 > dfx1[r] THEN dfx1[r] := x1
  ELSE
    dfd[r] := dgen
    dfx0[r] := x0
    dfx1[r] := x1
  ENDIF
  IF r < dblo THEN dblo := r    -> E2b mirror
  IF r > dbhi THEN dbhi := r
ENDPROC

PROC dmarkrows(r0, r1)
  DEF r
  FOR r := r0 TO r1
    dmark2(r, 0, COLS - 1)
  ENDFOR
ENDPROC

PROC dk()
  DEF j
  IF dcx >= COLS THEN RETURN
  FOR j := dcx TO COLS - 1
    dm[Mul(drow(dcy), COLS) + j] := 0
    da[Mul(drow(dcy), COLS) + j] := 0
  ENDFOR
  IF (dcy + 1) <= (ROWS - 1) THEN dw[drow(dcy + 1)] := 0
  dmark2(dcy, dcx, COLS - 1)
ENDPROC

PROC dj()
  DEF r
  dk()
  FOR r := dcy + 1 TO ROWS - 1
    dclearrow(r)
  ENDFOR
  IF (dcy + 1) <= (ROWS - 1) THEN dmarkrows(dcy + 1, ROWS - 1)
ENDPROC

PROC dich(n)
  DEF j, mo
  IF dcx >= COLS THEN RETURN
  IF n > (COLS - dcx) THEN n := COLS - dcx
  mo := Mul(drow(dcy), COLS)
  FOR j := COLS - 1 TO dcx + n STEP -1
    dm[mo + j] := dm[mo + j - n]
    da[mo + j] := da[mo + j - n]
  ENDFOR
  FOR j := dcx TO dcx + n - 1
    dm[mo + j] := 0
    da[mo + j] := 0
  ENDFOR
  dmark2(dcy, dcx, COLS - 1)
ENDPROC

PROC ddch(n)
  DEF j, mo
  IF dcx >= COLS THEN RETURN
  IF n > (COLS - dcx) THEN n := COLS - dcx
  mo := Mul(drow(dcy), COLS)
  FOR j := dcx TO COLS - 1 - n
    dm[mo + j] := dm[mo + j + n]
    da[mo + j] := da[mo + j + n]
  ENDFOR
  FOR j := COLS - n TO COLS - 1
    dm[mo + j] := 0
    da[mo + j] := 0
  ENDFOR
  dmark2(dcy, dcx, COLS - 1)
ENDPROC

PROC drmove(top, n, down)
  DEF r, j
  IF n > (ROWS - top) THEN n := ROWS - top
  FOR r := top TO ROWS - 1
    dw[drow(r)] := 0
  ENDFOR
  IF down
    FOR r := ROWS - 1 TO top + n STEP -1
      FOR j := 0 TO COLS - 1
        dm[Mul(drow(r), COLS) + j] := dm[Mul(drow(r - n), COLS) + j]
        da[Mul(drow(r), COLS) + j] := da[Mul(drow(r - n), COLS) + j]
      ENDFOR
    ENDFOR
    FOR r := top TO top + n - 1
      dclearrow(r)
    ENDFOR
  ELSE
    FOR r := top TO ROWS - 1 - n
      FOR j := 0 TO COLS - 1
        dm[Mul(drow(r), COLS) + j] := dm[Mul(drow(r + n), COLS) + j]
        da[Mul(drow(r), COLS) + j] := da[Mul(drow(r + n), COLS) + j]
      ENDFOR
    ENDFOR
    FOR r := ROWS - n TO ROWS - 1
      dclearrow(r)
    ENDFOR
  ENDIF
  dmarkrows(top, ROWS - 1)
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
    dflush()                        -> a forcing packet (read/mode/key)
  ELSEIF c = 2
    dk()
  ELSEIF c = 3
    dj()
  ELSEIF c = 4
    dich(2)
  ELSEIF c = 5
    ddch(2)
  ELSEIF c = 6
    drmove(dcy, 1, TRUE)
  ELSEIF c = 7
    drmove(dcy, 1, FALSE)
  ELSEIF c = 14
    drmove(0, 1, FALSE)
  ELSEIF c = 15
    drmove(0, 1, TRUE)
  ELSEIF (c >= 20) AND (c <= 25)
    dcy := c - 20                   -> cursor jump, coords a pure
    dcx := Mod(Mul(c - 20, 7) + c, COLS)  -> function of the byte -
                                    -> identical in both replay loops
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
  dgen := dgen + 1                  -> dfstart's E2a/b arming, mirrored
  IF dgen > 255
    FOR r := 0 TO ROWS - 1
      dfd[r] := 0
    ENDFOR
    dgen := 1
  ENDIF
  dblo := ROWS
  dbhi := -1
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

-> ---------------- v3: state reset, generators, claim B ----------------

PROC reset()
  DEF i
  seed := $1234
  dtop := 0; dcx := 0; dcy := 0; ltop := 0; lcx := 0; lcy := 0
  FOR i := 0 TO MCELLS - 1
    lm[i] := 0; la[i] := 0; dm[i] := 0; da[i] := 0
  ENDFOR
  FOR i := 0 TO SCELLS - 1
    lsm[i] := 0; lsa[i] := 0; dsm[i] := 0; dsa[i] := 0
  ENDFOR
  FOR i := 0 TO SBMAX - 1
    lw[i] := 0; dw[i] := 0
  ENDFOR
  dpend := 0
  dfull := FALSE
  dvblank := TRUE
  ltn := 0; dtn := 0; trchk := 0
  trover := FALSE
ENDPROC

-> the v2 full-alphabet packet (region ops, cursor jumps, FF included)
PROC randfull()
  DEF i, n, c
  n := 1 + rnd(PKMAX - 1)
  FOR i := 0 TO n - 1
    c := rnd(100)
    IF c < 40
      pkt[i] := 33 + rnd(90)      -> printable
    ELSEIF c < 56
      pkt[i] := 10                -> LF - scroll pressure is the point
    ELSEIF c < 60
      pkt[i] := 13
    ELSEIF c < 63
      pkt[i] := 9
    ELSEIF c < 65
      pkt[i] := 8
    ELSEIF c < 68
      pkt[i] := 12
    ELSEIF c < 71
      pkt[i] := 1                 -> mid-packet flush (forcing packet)
    ELSEIF c < 74
      pkt[i] := 2                 -> E1: K
    ELSEIF c < 76
      pkt[i] := 3                 -> J
    ELSEIF c < 79
      pkt[i] := 4                 -> @
    ELSEIF c < 82
      pkt[i] := 5                 -> P
    ELSEIF c < 85
      pkt[i] := 6                 -> L
    ELSEIF c < 88
      pkt[i] := 7                 -> M
    ELSEIF c < 90
      pkt[i] := 14                -> S
    ELSEIF c < 92
      pkt[i] := 15                -> T
    ELSE
      pkt[i] := 20 + rnd(6)       -> cursor jump
    ENDIF
  ENDFOR
ENDPROC n

-> claim B's alphabet: pure stream output - exactly the traffic
-> jumpok() lets jump in the handler (no FF, no region ops, no cursor
-> jumps), LF-heavy for scroll pressure
PROC randstream()
  DEF i, n, c
  n := 1 + rnd(PKMAX - 1)
  FOR i := 0 TO n - 1
    c := rnd(100)
    IF c < 45
      pkt[i] := 33 + rnd(90)
    ELSEIF c < 70
      pkt[i] := 10
    ELSEIF c < 78
      pkt[i] := 13
    ELSEIF c < 84
      pkt[i] := 9
    ELSEIF c < 88
      pkt[i] := 8
    ELSE
      pkt[i] := 1
    ENDIF
  ENDFOR
ENDPROC n

-> phase A: the v2 lockstep suite at one shared jump count
PROC phasea(j, base)
  DEF p, n
  ljmp := j; djmp := j
  reset()
  directed()
  FOR p := 0 TO PACKETS - 1
    curat := 1 + Mod(p, 7)          -> a fresh attr stamp per packet
    n := randfull()
    feed(pkt, n, base + p)
    IF fails > 4
      WriteF('stopping after \d failures (jmp \d)\n', fails, j)
      RETURN FALSE
    ENDIF
  ENDFOR
  IF fails > 0
    WriteF('\d FAILURES at jmp \d\n', fails, j)
    RETURN FALSE
  ENDIF
  WriteF('phase A jmp=\d PASS: 10 directed + \d random packets identical\n', j, PACKETS)
ENDPROC TRUE

-> claim B: feed both engines WITHOUT the grid compare (they run at
-> different jump counts on purpose), then check the logical stream
PROC feedb(buf:PTR TO CHAR, n, tag)
  DEF i, r
  dpend := 0
  dfull := FALSE
  dgen := dgen + 1
  IF dgen > 255
    FOR r := 0 TO ROWS - 1
      dfd[r] := 0
    ENDFOR
    dgen := 1
  ENDIF
  dblo := ROWS
  dbhi := -1
  FOR i := 0 TO n - 1
    dbyte(buf[i])
  ENDFOR
  dflush()
  FOR i := 0 TO n - 1
    lbyte(buf[i])
  ENDFOR
  trcompare(tag)
ENDPROC

PROC trbad(tag, why, a, b)
  fails := fails + 1
  WriteF('CLAIM-B FAIL packet \d: \s (\d vs \d)\n', tag, why, a, b)
  WriteF('  ltn=\d dtn=\d lcx=\d lcy=\d dcx=\d dcy=\d trchk=\d\n',
         ltn, dtn, lcx, lcy, dcx, dcy, trchk)
ENDPROC

PROC trcompare(tag)
  DEF d0, i, j, r, x, lo, do2
  IF trover THEN RETURN           -> a truncated log cannot testify
  d0 := dtn - ltn
  -> the deferred run only ever scrolls EARLIER, never less
  IF d0 < 0 THEN RETURN trbad(tag, 'transcript ran BEHIND', dtn, ltn)
  IF dcx <> lcx THEN RETURN trbad(tag, 'cursor column', dcx, lcx)
  IF dcy <> (lcy - d0) THEN RETURN trbad(tag, 'cursor row (ring-adjusted)', dcy, lcy - d0)
  -> 1: the settled transcript prefix, watermark onward (append-only,
  -> so each row is checked exactly once across the whole phase)
  FOR i := trchk TO ltn - 1
    FOR x := 0 TO COLS - 1
      IF ltrm[Mul(i, COLS) + x] <> dtrm[Mul(i, COLS) + x] THEN RETURN trbad(tag, 'transcript glyph row', i, x)
      IF ltra[Mul(i, COLS) + x] <> dtra[Mul(i, COLS) + x] THEN RETURN trbad(tag, 'transcript attr row', i, x)
    ENDFOR
    IF ltrw[i] <> dtrw[i] THEN RETURN trbad(tag, 'transcript wrap row', i, 0)
  ENDFOR
  trchk := ltn
  -> 2: rows the jumped run already filed as history but the jmp=1 run
  -> still shows - D transcript row j = L visible row j-ltn
  FOR j := ltn TO dtn - 1
    r := j - ltn
    FOR x := 0 TO COLS - 1
      IF dtrm[Mul(j, COLS) + x] <> lsm[Mul(r, COLS) + x] THEN RETURN trbad(tag, 'early-history glyph', j, x)
      IF dtra[Mul(j, COLS) + x] <> lsa[Mul(r, COLS) + x] THEN RETURN trbad(tag, 'early-history attr', j, x)
    ENDFOR
    IF dtrw[j] <> lw[lrow(r)] THEN RETURN trbad(tag, 'early-history wrap', j, 0)
  ENDFOR
  -> 3: the visible overlap, ring-offset aligned: L row r = D row r-d0
  FOR r := d0 TO lcy
    lo := Mul(r, COLS)
    do2 := Mul(r - d0, COLS)
    FOR x := 0 TO COLS - 1
      IF lsm[lo + x] <> dsm[do2 + x] THEN RETURN trbad(tag, 'visible glyph', r, x)
      IF lsa[lo + x] <> dsa[do2 + x] THEN RETURN trbad(tag, 'visible attr', r, x)
    ENDFOR
    IF lw[lrow(r)] <> dw[drow(r - d0)] THEN RETURN trbad(tag, 'visible wrap', r, 0)
  ENDFOR
  -> 4: everything below the jumped cursor is blank - screen AND model
  FOR r := dcy + 1 TO ROWS - 1
    do2 := Mul(r, COLS)
    FOR x := 0 TO COLS - 1
      IF dsm[do2 + x] THEN RETURN trbad(tag, 'below-cursor screen not blank', r, x)
      IF dm[Mul(drow(r), COLS) + x] THEN RETURN trbad(tag, 'below-cursor model not blank', r, x)
    ENDFOR
  ENDFOR
ENDPROC

PROC phaseb(base, quiet)
  DEF p, n
  ljmp := 1; djmp := 3
  reset()
  trlog := TRUE
  FOR p := 0 TO TRPACKETS - 1
    curat := 1 + Mod(p, 7)
    n := randstream()
    feedb(pkt, n, base + p)
    IF trover
      IF quiet = FALSE THEN WriteF('claim B: transcript cap at packet \d (fine, phase ends)\n', base + p)
      trlog := FALSE
      RETURN fails = 0
    ENDIF
    IF fails > 0
      trlog := FALSE
      RETURN FALSE
    ENDIF
  ENDFOR
  trlog := FALSE
ENDPROC fails = 0

PROC main()
  DEF p, n, i
  ltrm := New(Mul(TRMAX, COLS))
  ltra := New(Mul(TRMAX, COLS))
  ltrw := New(TRMAX)
  dtrm := New(Mul(TRMAX, COLS))
  dtra := New(Mul(TRMAX, COLS))
  dtrw := New(TRMAX)
  IF (ltrm = NIL) OR (ltra = NIL) OR (ltrw = NIL) OR
     (dtrm = NIL) OR (dtra = NIL) OR (dtrw = NIL)
    WriteF('out of memory for the transcript logs\n')
    RETURN
  ENDIF
  -> phase A: engine lockstep at jmp 1 (the v2 regression), 3, ROWS-1
  fails := 0
  IF phasea(1, 100) = FALSE THEN RETURN
  fails := 0
  IF phasea(3, 5100) = FALSE THEN RETURN
  fails := 0
  IF phasea(ROWS - 1, 10100) = FALSE THEN RETURN
  -> claim B: jumping must preserve the logical stream exactly
  fails := 0
  IF phaseb(15000, FALSE) = FALSE
    WriteF('claim B FAILED\n')
    RETURN
  ENDIF
  WriteF('claim B PASS: \d stream packets, jmp=3 vs jmp=1 logical streams identical\n', TRPACKETS)
  -> claim C controls: each lie must make claim B diverge
  forcejclear := TRUE
  fails := 0
  IF phaseb(20000, TRUE)
    WriteF('control (uncleaned jump rows) did NOT diverge - harness BLIND\nFAIL\n')
    RETURN
  ENDIF
  WriteF('control (uncleaned jump rows) correctly DIVERGES - harness can see\n')
  forcejclear := FALSE
  forcejland := TRUE
  fails := 0
  IF phaseb(25000, TRUE)
    WriteF('control (cursor lands a row low) did NOT diverge - harness BLIND\nFAIL\n')
    RETURN
  ENDIF
  WriteF('control (cursor lands a row low) correctly DIVERGES - harness can see\n')
  forcejland := FALSE
  -> E5 control: force the blank-skip flag TRUE always (claim every
  -> screen is blank, even mid-content). A correct harness MUST now
  -> diverge - if it does not, the blank-skip test proves nothing.
  ljmp := 1; djmp := 1
  forcevb := TRUE
  fails := 0
  reset()
  FOR p := 0 TO PACKETS - 1
    curat := 1 + Mod(p, 7)
    n := 1 + rnd(PKMAX - 1)
    -> alternate: a glyph packet lays down content, the NEXT packet is
    -> pure newlines that scroll it WITHOUT rewriting - exactly the
    -> case the model-repaint cannot mask, so a wrong skip must show
    IF Mod(p, 2) = 0
      FOR i := 0 TO n - 1
        pkt[i] := 33 + rnd(90)
      ENDFOR
    ELSE
      FOR i := 0 TO n - 1
        pkt[i] := 10
      ENDFOR
    ENDIF
    feed(pkt, n, 30000 + p)
    IF fails > 0
      WriteF('control (forced-blank lie) correctly DIVERGES at packet \d - harness can see\n', 30000 + p)
      WriteF('PASS\n')
      RETURN
    ENDIF
  ENDFOR
  WriteF('control did NOT diverge - the harness is BLIND, blank-skip unproven\n')
  WriteF('FAIL\n')
ENDPROC
