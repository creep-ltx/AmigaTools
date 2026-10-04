/* fpwtest.e - how fast can a CPU write glyphs into the planes of a
   stock A1200's Workbench? Text() against three asm shapes, one 77-cell
   row per op, timed in DateStamp ticks over REPS rows.

     fpa  column-major, byte read + byte write per glyph line
     fpb  column-major, two long reads per glyph, byte writes
     fpc  two cells per word write, two long reads per glyph

   Writes straight into the screen bitmap under its own window (kept
   in front, uncovered). ecompile fpwtest.e fpwtest ; fpwtest [REPS n] */

MODULE 'intuition/intuition', 'intuition/screens',
       'graphics/rastport', 'graphics/text', 'graphics/gfx', 'dos/dos'

DEF win:PTR TO window, rp:PTR TO rastport, bm:PTR TO bitmap,
    cache:PTR TO CHAR, row[80]:ARRAY OF CHAR, reps=300, bpr,
    ox, oy

PROC ticks(a:PTR TO datestamp, b:PTR TO datestamp) IS
  Mul(b.minute - a.minute, 3000) + b.tick - a.tick

PROC buildcache(f:PTR TO textfont)
  DEF c, y, loc:PTR TO LONG, off, d:PTR TO CHAR, b, lo, hi, w
  cache := New(256 * 8)
  lo := f.lochar
  hi := f.hichar
  loc := f.charloc
  d := f.chardata
  FOR c := lo TO hi
    off := Shr(loc[c - lo], 16)
    FOR y := 0 TO 7
      w := Shl(d[Mul(y, f.modulo) + Shr(off, 3)], 8) OR d[Mul(y, f.modulo) + Shr(off, 3) + 1]
      b := Shr(Shl(w, off AND 7), 8) AND $FF
      cache[Shl(c, 3) + y] := b
    ENDFOR
  ENDFOR
ENDPROC

PROC fpa(dst, chars, n, cache, bpr)
  MOVEM.L D2-D7/A2-A4,-(A7)
  MOVE.L dst,A0
  MOVE.L chars,A1
  MOVE.L cache,A2
  MOVE.L n,D7
  MOVE.L bpr,D1
  MOVE.L D1,D2
  ADD.L D2,D2
  MOVE.L D2,D3
  ADD.L D1,D3
  LEA 0(A0,D2.L),A3
  ADDA.L D2,A3
  SUBQ.L #1,D7
fpal:
  MOVEQ #0,D0
  MOVE.B (A1)+,D0
  LSL.W #3,D0
  LEA 0(A2,D0.L),A4
  MOVE.B (A4)+,(A0)
  MOVE.B (A4)+,0(A0,D1.L)
  MOVE.B (A4)+,0(A0,D2.L)
  MOVE.B (A4)+,0(A0,D3.L)
  MOVE.B (A4)+,(A3)
  MOVE.B (A4)+,0(A3,D1.L)
  MOVE.B (A4)+,0(A3,D2.L)
  MOVE.B (A4)+,0(A3,D3.L)
  ADDQ.L #1,A0
  ADDQ.L #1,A3
  DBRA D7,fpal
  MOVEM.L (A7)+,D2-D7/A2-A4
ENDPROC

PROC fpb(dst, chars, n, cache, bpr, xr)
  MOVEM.L D2-D7/A2-A4,-(A7)
  MOVE.L dst,A0
  MOVE.L chars,A1
  MOVE.L cache,A2
  MOVE.L n,D7
  MOVE.L bpr,D1
  MOVE.L xr,D5
  MOVE.L D1,D2
  ADD.L D2,D2
  MOVE.L D2,D3
  ADD.L D1,D3
  LEA 0(A0,D2.L),A3
  ADDA.L D2,A3
  SUBQ.L #1,D7
fpbl:
  MOVEQ #0,D0
  MOVE.B (A1)+,D0
  LSL.W #3,D0
  MOVE.L 0(A2,D0.L),D4
  MOVE.L 4(A2,D0.L),D6
  EOR.L D5,D4
  EOR.L D5,D6
  ROL.L #8,D4
  MOVE.B D4,(A0)
  ROL.L #8,D4
  MOVE.B D4,0(A0,D1.L)
  ROL.L #8,D4
  MOVE.B D4,0(A0,D2.L)
  ROL.L #8,D4
  MOVE.B D4,0(A0,D3.L)
  ROL.L #8,D6
  MOVE.B D6,(A3)
  ROL.L #8,D6
  MOVE.B D6,0(A3,D1.L)
  ROL.L #8,D6
  MOVE.B D6,0(A3,D2.L)
  ROL.L #8,D6
  MOVE.B D6,0(A3,D3.L)
  ADDQ.L #1,A0
  ADDQ.L #1,A3
  DBRA D7,fpbl
  MOVEM.L (A7)+,D2-D7/A2-A4
ENDPROC

-> n even, dst even
PROC fpc(dst, chars, n, cache, bpr)
  MOVEM.L D2-D7/A2-A6,-(A7)
  MOVE.L dst,A0
  MOVE.L chars,A1
  MOVE.L cache,A2
  MOVE.L n,D0
  LEA 0(A1,D0.L),A6
  MOVE.L bpr,D1
  MOVE.L D1,D2
  ADD.L D2,D2
  MOVE.L D2,D3
  ADD.L D1,D3
  LEA 0(A0,D2.L),A3
  ADDA.L D2,A3
fpcl:
  MOVEQ #0,D0
  MOVE.B (A1)+,D0
  LSL.W #3,D0
  MOVE.L 0(A2,D0.L),D4
  MOVE.L 4(A2,D0.L),D5
  MOVEQ #0,D0
  MOVE.B (A1)+,D0
  LSL.W #3,D0
  MOVE.L 0(A2,D0.L),D6
  MOVE.L 4(A2,D0.L),D7
  ROL.L #8,D4
  MOVE.B D4,D0
  LSL.W #8,D0
  ROL.L #8,D6
  MOVE.B D6,D0
  MOVE.W D0,(A0)
  ROL.L #8,D4
  MOVE.B D4,D0
  LSL.W #8,D0
  ROL.L #8,D6
  MOVE.B D6,D0
  MOVE.W D0,0(A0,D1.L)
  ROL.L #8,D4
  MOVE.B D4,D0
  LSL.W #8,D0
  ROL.L #8,D6
  MOVE.B D6,D0
  MOVE.W D0,0(A0,D2.L)
  ROL.L #8,D4
  MOVE.B D4,D0
  LSL.W #8,D0
  ROL.L #8,D6
  MOVE.B D6,D0
  MOVE.W D0,0(A0,D3.L)
  ROL.L #8,D5
  MOVE.B D5,D0
  LSL.W #8,D0
  ROL.L #8,D7
  MOVE.B D7,D0
  MOVE.W D0,(A3)
  ROL.L #8,D5
  MOVE.B D5,D0
  LSL.W #8,D0
  ROL.L #8,D7
  MOVE.B D7,D0
  MOVE.W D0,0(A3,D1.L)
  ROL.L #8,D5
  MOVE.B D5,D0
  LSL.W #8,D0
  ROL.L #8,D7
  MOVE.B D7,D0
  MOVE.W D0,0(A3,D2.L)
  ROL.L #8,D5
  MOVE.B D5,D0
  LSL.W #8,D0
  ROL.L #8,D7
  MOVE.B D7,D0
  MOVE.W D0,0(A3,D3.L)
  ADDQ.L #2,A0
  ADDQ.L #2,A3
  CMPA.L A6,A1
  BLT fpcl
  MOVEM.L (A7)+,D2-D7/A2-A6
ENDPROC

PROC rowdst(p, r) IS bm.planes[p] + Mul(oy + Mul(r, 8), bpr) + Shr(ox, 3)

PROC main()
  DEF t0:datestamp, t1:datestamp, i, r, p, n=0, scr:PTR TO screen,
      out[200]:STRING, rdargs, args:PTR TO LONG, q:PTR TO LONG
  args := [0]:LONG
  rdargs := ReadArgs('REPS/K/N', args, NIL)
  IF rdargs
    IF args[0]
      q := args[0]
      reps := q[0]
    ENDIF
  ENDIF
  scr := LockPubScreen(NIL)
  win := OpenWindowTagList(NIL, [WA_LEFT, 0, WA_TOP, 0, WA_WIDTH, scr.width,
           WA_HEIGHT, scr.height, WA_PUBSCREEN, scr, WA_TITLE, 'fpwtest',
           WA_DRAGBAR, TRUE, WA_DEPTHGADGET, TRUE, WA_ACTIVATE, TRUE, 0])
  UnlockPubScreen(NIL, scr)
  IF win = NIL THEN RETURN
  rp := win.rport
  bm := rp.bitmap
  bpr := bm.bytesperrow
  buildcache(rp.font)
  FOR i := 0 TO 76 DO row[i] := 33 + Mod(i * 7, 90)
  ox := 8
  oy := win.bordertop + 8
  WriteF('depth \d bpr \d font \d/\d rows \d\n', bm.depth, bpr, rp.font.xsize, rp.font.ysize, reps)
  SetDrMd(rp, RP_JAM2)

  -> Text 1 plane
  SetAPen(rp, 1); SetBPen(rp, 0); rp.mask := 1
  DateStamp(t0)
  FOR i := 1 TO reps
    Move(rp, ox, oy + Mul(Mod(i, 28), 8) + rp.font.baseline)
    Text(rp, row, 77)
  ENDFOR
  WaitBlit()
  DateStamp(t1)
  WriteF('text-1pl   \d ticks\n', ticks(t0, t1))
  -> Text 3 planes
  SetAPen(rp, 5); SetBPen(rp, 0); rp.mask := 7
  DateStamp(t0)
  FOR i := 1 TO reps
    Move(rp, ox, oy + Mul(Mod(i, 28), 8) + rp.font.baseline)
    Text(rp, row, 77)
  ENDFOR
  WaitBlit()
  DateStamp(t1)
  WriteF('text-3pl   \d ticks\n', ticks(t0, t1))
  rp.mask := $FF
  Delay(25)
  DateStamp(t0)
  FOR i := 1 TO reps DO fpa(rowdst(0, Mod(i, 28)), row, 77, cache, bpr)
  DateStamp(t1)
  WriteF('fpa-1pl    \d ticks\n', ticks(t0, t1))
  Delay(25)
  DateStamp(t0)
  FOR i := 1 TO reps DO fpb(rowdst(0, Mod(i, 28)), row, 77, cache, bpr, 0)
  DateStamp(t1)
  WriteF('fpb-1pl    \d ticks\n', ticks(t0, t1))
  Delay(25)
  DateStamp(t0)
  FOR i := 1 TO reps DO fpc(rowdst(0, Mod(i, 28)), row, 76, cache, bpr)
  DateStamp(t1)
  WriteF('fpc-1pl    \d ticks (76 cells)\n', ticks(t0, t1))
  Delay(25)
  DateStamp(t0)
  FOR i := 1 TO reps
    r := Mod(i, 28)
    fpb(rowdst(0, r), row, 77, cache, bpr, 0)
    fpb(rowdst(1, r), row, 77, cache, bpr, -1)
    fpb(rowdst(2, r), row, 77, cache, bpr, 0)
  ENDFOR
  DateStamp(t1)
  WriteF('fpb-3pl    \d ticks\n', ticks(t0, t1))
  Delay(100)
  CloseWindow(win)
ENDPROC
