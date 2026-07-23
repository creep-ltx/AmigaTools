/* srbench.e -- S4 of the conbench analysis: measure the raw graphics
   primitives CCON's render path is built from, on the real screen,
   with no handler and no DOS packets in the way.

   usage: srbench [TO file] [REPS n] [W n] [H n]

   Opens its OWN window (default 640x246, tucked under the screen
   bar - the size all three conbench runs were resized to, 23.7.26)
   on the default public screen and times, over REPS iterations each:

     scroll-1     ScrollRaster of one text line   - screenscroll()'s
                  exact region shape: the per-newline cost every
                  scrolled line of output pays today
     scroll-10    ScrollRaster of ten lines in ONE call - what S2's
                  newline-run coalescing would pay instead of ten
                  scroll-1s
     scroll-page  ScrollRaster of the whole text height - the
                  everything-scrolled-off shape; ScrollRaster should
                  degenerate to a clear here, S2/S3's k >= rows case
     text-78      Move + Text of a 78-char varied line, JAM2, the
                  same call shape as render()'s printable-run path
     rectfill     one full inner-window RectFill - the form-feed /
                  clear-page primitive

   The point: conbench says CCON spends ~34ms per scrolled line and
   ~20ms per drawn line, but those numbers have the whole handler
   around them. This isolates the graphics calls. If scroll-1 alone
   accounts for the 34ms, the scroll path IS blitter-bound and S2/S3
   (fewer, bigger blits) attack the real cost; if it is much cheaper,
   the time is in the handler and the plan changes. scroll-10 vs
   scroll-1 gives the coalescing payoff directly (blit area is nearly
   the same, so ten-for-one should be close to a 10x win - this run
   proves or kills that arithmetic).

   Fairness rules, same spirit as conbench:
   - KEEP THE WINDOW UNCOVERED. A partially hidden window splits the
     layer into cliprects and every blit multiplies.
   - Same screen depth as the conbench runs: more planes, more
     blitting, for every test alike.
   - Results append to the TO file if given, after all timing.

   Timing resolution is one tick (1/50s); at the default 200 reps a
   1ms/op cost is 10 ticks of total time, comfortably measurable. */

MODULE 'intuition/intuition', 'intuition/screens',
       'graphics/rastport', 'graphics/text', 'graphics/gfx',
       'utility/tagitem',
       'dos/dos'

CONST NTESTS=11, RESSZ=2600

DEF win:PTR TO window, rp:PTR TO rastport,
    res:PTR TO CHAR, scratch[160]:STRING,
    il, it, ir, ib, iw, ih,     -> the inner region, screenscroll()'s shape
    cw, ch, rows, cols,
    ticks[NTESTS]:ARRAY OF LONG,
    reps=200,
    line78[80]:ARRAY OF CHAR,
    -> 0.2 (the sync-line campaign): the candidate primitives' shared
    -> geometry - the window's SCREEN-absolute region and its bitmap,
    -> resolved once. zrow feeds the CPU test's vacated-strip clear.
    sbm:PTR TO bitmap, sdepth,
    ax, ay,                     -> il/it in screen coordinates
    zrow[128]:ARRAY OF CHAR

PROC main() HANDLE
  DEF rdargs=NIL, argarray:PTR TO LONG, fname:PTR TO CHAR, p:PTR TO LONG,
      w=640, h=246, i, fh, scr:PTR TO screen, bm:PTR TO bitmap, c,
      pubscr:PTR TO screen, top

  argarray := [0,0,0,0]:LONG
  rdargs := ReadArgs('TO/K,REPS/K/N,W/K/N,H/K/N', argarray, NIL)
  IF rdargs = NIL
    Throw("ARG", 'usage: srbench [TO file] [REPS n] [W n] [H n]')
  ENDIF
  fname := argarray[0]
  IF argarray[1]
    p := argarray[1]
    reps := p[0]
  ENDIF
  IF argarray[2]
    p := argarray[2]
    w := p[0]
  ENDIF
  IF argarray[3]
    p := argarray[3]
    h := p[0]
  ENDIF
  IF reps < 1 THEN reps := 1

  res := String(RESSZ)
  IF res = NIL THEN Throw("MEM", 'out of memory')

  -> under the screen bar, clamped to fit: the conbench windows sat at
  -> the bar's bottom edge, and a hardcoded top would misplace (or
  -> unfit) the window on any screen whose bar is not that guess
  top := 18
  pubscr := LockPubScreen(NIL)
  IF pubscr
    top := pubscr.barheight + 1
    IF w > pubscr.width THEN w := pubscr.width
    IF h > (pubscr.height - top) THEN h := pubscr.height - top
  ENDIF
  win := OpenWindowTagList(NIL,
    [WA_TITLE, 'srbench - keep this window uncovered',
     WA_LEFT, 0, WA_TOP, top, WA_WIDTH, w, WA_HEIGHT, h,
     WA_DRAGBAR, TRUE, WA_DEPTHGADGET, TRUE, WA_ACTIVATE, TRUE,
     WA_PUBSCREEN, pubscr,
     WA_IDCMP, 0,
     TAG_DONE, NIL])
  IF pubscr THEN UnlockPubScreen(NIL, pubscr)
  IF win = NIL THEN Throw("WIN", 'window would not open (too big for the screen?)')

  rp := win.rport
  cw := rp.txwidth
  ch := rp.txheight
  il := win.borderleft
  it := win.bordertop
  ir := win.width - win.borderright - 1
  ib := win.height - win.borderbottom - 1
  iw := ir - il + 1
  ih := ib - it + 1
  cols := Div(iw, cw)
  rows := Div(ih, ch)
  IF rows < 2 THEN Throw("WIN", 'window too small to test in')

  -> 0.2: the candidates' shared geometry - screen bitmap, region in
  -> screen coordinates, depth capped at the planes array, and zrow
  -> zeroed EXPLICITLY (E globals start as garbage, the iconify lesson)
  scr := win.wscreen
  sbm := scr.rastport.bitmap
  sdepth := sbm.depth
  IF sdepth > 8 THEN sdepth := 8
  ax := win.leftedge + il
  ay := win.topedge + it
  FOR i := 0 TO 127
    zrow[i] := 0
  ENDFOR

  -> varied printable filler, conbench's rule: no repeated-glyph
  -> shortcuts, this is what a real listing looks like
  c := 33
  FOR i := 0 TO 77
    line78[i] := c
    c := c + 1
    IF c > 126 THEN c := 33
  ENDFOR
  line78[78] := 0

  runtests()

  scr := win.wscreen
  bm := scr.rastport.bitmap
  report(w, h, bm.depth)

  IF fname
    fh := Open(fname, MODE_READWRITE)
    IF fh
      Seek(fh, 0, OFFSET_END)
    ELSE
      fh := Open(fname, MODE_NEWFILE)
    ENDIF
    IF fh = NIL THEN Throw("DOS", IoErr())
    Write(fh, res, StrLen(res))
    Close(fh)
    WriteF('srbench: appended to \s\n', fname)
  ENDIF

EXCEPT DO
  IF win THEN CloseWindow(win)
  IF exception = "DOS"
    PrintFault(exceptioninfo, 'srbench')
  ELSEIF exception <> 0
    WriteF('srbench: \s\n', exceptioninfo)
  ENDIF
  IF rdargs THEN FreeArgs(rdargs)
ENDPROC

PROC stampticks(a:PTR TO datestamp, b:PTR TO datestamp)
  DEF dm
  dm := (Mul(b.days - a.days, 1440)) + (b.minute - a.minute)
ENDPROC Mul(dm, 3000) + (b.tick - a.tick)

PROC runtests()
  DEF t0:datestamp, t1:datestamp, i, id, dy

  FOR id := 0 TO NTESTS - 1
    -> start each test from a cleared window so leftover pixels from
    -> the previous one cannot matter (they should not - blit cost is
    -> content-independent - but this keeps the runs identical)
    SetAPen(rp, 0)
    RectFill(rp, il, it, ir, ib)
    SetAPen(rp, 1)
    SetBPen(rp, 0)

    DateStamp(t0)
    SELECT id
    CASE 0                        -> scroll-1: screenscroll() verbatim
      FOR i := 1 TO reps
        ScrollRaster(rp, 0, ch, il, it, ir, ib)
      ENDFOR
    CASE 1                        -> scroll-10: S2's one-blit-for-ten
      dy := Mul(10, ch)
      IF dy > (ih - ch) THEN dy := ih - ch
      FOR i := 1 TO reps
        ScrollRaster(rp, 0, dy, il, it, ir, ib)
      ENDFOR
    CASE 2                        -> scroll-page: everything scrolls off
      dy := Mul(rows, ch)
      FOR i := 1 TO reps
        ScrollRaster(rp, 0, dy, il, it, ir, ib)
      ENDFOR
    CASE 3                        -> text-78: render()'s Move+Text shape
      FOR i := 1 TO reps
        Move(rp, il, it + Mul(2, ch) + rp.txbaseline)
        Text(rp, line78, Min(cols, 78))
      ENDFOR
    CASE 4                        -> rectfill: the form-feed clear
      FOR i := 1 TO reps
        SetAPen(rp, IF i AND 1 THEN 0 ELSE 1)  -> alternate pens so no
        RectFill(rp, il, it, ir, ib)           -> fill is ever a no-op
      ENDFOR
      SetAPen(rp, 1)
    -> ---- 0.2: the candidate primitives. The question on the table:
    -> stock console.device renders a scrolled line in ~17ms where
    -> ScrollRaster costs ~34 for the same region - what is it NOT
    -> paying? Every candidate below performs the same LOGICAL op as
    -> scroll-1 (move the region up one text line, vacate the bottom
    -> strip) so the numbers are directly comparable. ----
    CASE 5                        -> scrollbf-1: the backfill variant
      FOR i := 1 TO reps
        ScrollRasterBF(rp, 0, ch, il, it, ir, ib)
      ENDFOR
    CASE 6                        -> blit-1: direct BltBitMap, no layer
      -> walk - the region in SCREEN coordinates on the screen's own
      -> bitmap, LockLayerRom held exactly as a real handler swap
      -> would hold it (single uncovered cliprect assumed - which is
      -> the fast path a real swap would gate on). The vacated strip
      -> is RectFilled after, matching ScrollRaster's own erase step.
      FOR i := 1 TO reps
        LockLayerRom(win.wlayer)
        BltBitMap(sbm, ax, ay + ch, sbm, ax, ay, iw, ih - ch, $C0, $FF, NIL)
        UnlockLayerRom(win.wlayer)
        SetAPen(rp, 0)
        RectFill(rp, il, ib - ch + 1, ir, ib)
        SetAPen(rp, 1)
      ENDFOR
    CASE 7                        -> blit-10: ten lines, one direct blit
      dy := Mul(10, ch)
      IF dy > (ih - ch) THEN dy := ih - ch
      FOR i := 1 TO reps
        LockLayerRom(win.wlayer)
        BltBitMap(sbm, ax, ay + dy, sbm, ax, ay, iw, ih - dy, $C0, $FF, NIL)
        UnlockLayerRom(win.wlayer)
        SetAPen(rp, 0)
        RectFill(rp, il, ib - dy + 1, ir, ib)
        SetAPen(rp, 1)
      ENDFOR
    CASE 8                        -> cpu-1: planar row copies, the
      cpuscroll()                 -> reference the blitter must beat
                                  -> (and on real chip-bus iron, will)
    CASE 9                        -> mask3-scroll-1: THE console.device
      -> trick, decoded from the 3.2 ROM (46.1, site $2592): it pokes
      -> a used-planes byte into rp_Mask before ScrollRaster, so the
      -> blitter skips planes the text never touched. Pens 0-3 =
      -> mask %0011 = TWO of this screen's four planes.
      rp.mask := $03
      FOR i := 1 TO reps
        ScrollRaster(rp, 0, ch, il, it, ir, ib)
      ENDFOR
      rp.mask := $FF
    CASE 10                       -> mask1-scroll-1: pen-1-only text
      rp.mask := $01              -> (the bare shell transcript) = ONE
      FOR i := 1 TO reps          -> plane in four
        ScrollRaster(rp, 0, ch, il, it, ir, ib)
      ENDFOR
      rp.mask := $FF
    ENDSELECT
    WaitBlit()                    -> the last blit may still be running;
    DateStamp(t1)                 -> without this the final op is free
    ticks[id] := stampticks(t0, t1)
  ENDFOR
ENDPROC

-> 0.2: the CPU planar reference - per plane, per raster row, CopyMem
-> the region bytes one text line up, then clear the vacated strip
-> from a zero row. Byte-aligned x (rounded OUT to cover the region),
-> which a real swap would also do - cell columns are byte-multiples
-> whenever cw is 8, and the round-out only ever widens the move.
PROC cpuscroll()
  DEF i, p, r, pl, bpr, xb, wb, ytop
  bpr := sbm.bytesperrow
  xb := Shr(ax, 3)
  wb := Shr(ax + iw + 7, 3) - xb
  IF wb > 128 THEN wb := 128    -> zrow's reach; 640px = 80 bytes, ample
  ytop := ay
  FOR i := 1 TO reps
    LockLayerRom(win.wlayer)
    FOR p := 0 TO sdepth - 1
      pl := sbm.planes[p]
      FOR r := 0 TO ih - ch - 1
        CopyMem(pl + Mul(ytop + ch + r, bpr) + xb,
                pl + Mul(ytop + r, bpr) + xb, wb)
      ENDFOR
      FOR r := ih - ch TO ih - 1
        CopyMem(zrow, pl + Mul(ytop + r, bpr) + xb, wb)
      ENDFOR
    ENDFOR
    UnlockLayerRom(win.wlayer)
  ENDFOR
ENDPROC

PROC testname(id)
  DEF s
  SELECT id
  CASE 0; s := 'scroll-1'
  CASE 1; s := 'scroll-10'
  CASE 2; s := 'scroll-page'
  CASE 3; s := 'text-78'
  CASE 4; s := 'rectfill'
  CASE 5; s := 'scrollbf-1'
  CASE 6; s := 'blit-1'
  CASE 7; s := 'blit-10'
  CASE 8; s := 'cpu-1'
  CASE 9; s := 'mask3-scroll'
  CASE 10; s := 'mask1-scroll'
  DEFAULT; s := '?'
  ENDSELECT
ENDPROC s

PROC addres(s:PTR TO CHAR)
  IF (StrLen(res) + StrLen(s)) < (RESSZ - 2) THEN StrAdd(res, s)
ENDPROC

-> centiseconds as "s.cc" (conbench's fmtsecs, same \z caveat)
PROC fmtsecs(dst:PTR TO CHAR, cs)
  DEF f
  f := Mod(cs, 100)
  IF f < 10
    StringF(dst, '\d.0\d', Div(cs, 100), f)
  ELSE
    StringF(dst, '\d.\d', Div(cs, 100), f)
  ENDIF
ENDPROC

-> per-op milliseconds as "m.t": ticks are 20ms, so ms*10 per op is
-> ticks*200/reps - one decimal is what one-tick resolution honestly
-> supports at these rep counts
PROC fmtms(dst:PTR TO CHAR, t)
  DEF v
  v := Div(Mul(t, 200), reps)
  StringF(dst, '\d.\d', Div(v, 10), Mod(v, 10))
ENDPROC

PROC report(w, h, depth)
  DEF i, t, secs[16]:STRING, msop[16]:STRING

  StrCopy(res, '')
  addres('==========================================================\n')
  StringF(scratch, 'srbench 0.2: window \dx\d, inner \dx\d, \dx\d cells of \dx\d, depth \d\n',
          w, h, iw, ih, cols, rows, cw, ch, depth)
  addres(scratch)
  StringF(scratch, 'run     : reps \d per test\n', reps)
  addres(scratch)
  addres('\n')
  addres('  test              secs        ms/op\n')
  addres('  -------------------------------------\n')
  FOR i := 0 TO NTESTS - 1
    t := ticks[i]
    fmtsecs(secs, Mul(t, 2))
    fmtms(msop, t)
    StringF(scratch, '  \l\s[13]\r\s[9] \r\s[10]\n',
            testname(i), secs, msop)
    addres(scratch)
  ENDFOR
  addres('\n')
  WriteF('\s', res)
ENDPROC
