/* dplinetest.e - 1.2.8b8: the planar row writer's line loop (dpline,
   copied VERBATIM from ccon-handler.e - re-copy if it changes) against
   a pixel-at-a-time reference. Random cell widths 1..8, start bit
   0..7, 1..60 cells, random glyph rows, per-cell fg/bg plane bits, and
   random bytes around the span: every bit outside the span must be
   kept, every bit inside must be glyph ? fg : bg.
   ecompile dplinetest.e dplinetest ; vamos dplinetest */

DEF seed=12345

PROC rnd(n)
  seed := Mul(seed, 1103515245) + 12345
ENDPROC Mod(Shr(seed, 16) AND $7FFF, n)  -> E's Mod divides 32/16: keep it small



PROC dplinep(dst, b0, gop, glp, fgp, bgp, n, cw, pb)
  MOVEM.L D2-D7/A2-A6,-(A7)
  MOVE.L dst,A0
  MOVE.L gop,A1
  MOVE.L glp,A2
  MOVE.L fgp,A3
  MOVE.L bgp,A4
  MOVE.L n,D7
  MOVE.L cw,D6
  MOVE.L b0,D5
  MOVE.L pb,A6                  -> the plane number, kept in A6
  MOVEQ #0,D4
  TST.L D5
  BEQ.S dpqst
  MOVE.B (A0),D4
  MOVEQ #8,D0
  SUB.L D5,D0
  LSR.L D0,D4
dpqst:
  SUBQ.L #1,D7
dpqc:
  MOVE.L (A1)+,D0
  MOVEQ #0,D1
  MOVE.B 0(A2,D0.L),D1          -> glyph bits, left-aligned
  MOVE.L A6,D0
  MOVE.B (A3)+,D2
  BTST.L D0,D2
  SNE D2                        -> fg's bit p as $FF/$00
  MOVE.B (A4)+,D3
  BTST.L D0,D3
  SNE D3                        -> bg's
  AND.B D1,D2
  NOT.B D1
  AND.B D3,D1
  OR.B D2,D1
  MOVEQ #8,D0
  SUB.L D6,D0
  LSR.B D0,D1                   -> the cell's cw bits, low-aligned
  LSL.L D6,D4
  OR.L D1,D4
  ADD.L D6,D5
  CMP.L #8,D5
  BLT.S dpqnx
  SUBQ.L #8,D5
  MOVE.L D4,D0
  LSR.L D5,D0
  MOVE.B D0,(A0)+
dpqnx:
  DBRA D7,dpqc
  TST.L D5
  BEQ.S dpqx
  MOVEQ #8,D0
  SUB.L D5,D0
  LSL.L D0,D4
  MOVE.L #$FF,D1
  LSR.L D5,D1
  AND.B (A0),D1
  OR.B D4,D1
  MOVE.B D1,(A0)
dpqx:
  MOVEM.L (A7)+,D2-D7/A2-A6
ENDPROC

PROC dpcells(m, a, st, n, ch, deffg, gop, fgp, bgp)
  DEF r=0
  MOVEM.L D2-D7/A2-A6,-(A7)
  MOVE.L m,A0
  MOVE.L a,A1
  MOVE.L st,A2
  MOVE.L gop,A3
  MOVE.L fgp,A4
  MOVE.L bgp,A6
  MOVE.L n,D7
  MOVE.L ch,D6
  MOVE.L deffg,D5
  MOVEQ #0,D4                   -> styled
  SUBQ.L #1,D7
dpcel:
  MOVEQ #0,D0
  MOVE.B (A0)+,D0               -> char
  CMP.W #32,D0
  BCC.S dpcc
  MOVEQ #32,D0
dpcc:
  MULU D6,D0
  MOVE.L D0,(A3)+               -> glyph offset
  MOVEQ #0,D1
  MOVE.B (A1)+,D1               -> attr
  MOVEQ #0,D2
  MOVE.B (A2)+,D2               -> style
  MOVE.B D2,D0
  AND.B #3,D0
  BEQ.S dpcn
  MOVEQ #1,D4
dpcn:
  MOVE.B D1,D0
  OR.B D2,D0
  BNE.S dpcp
  CLR.B (A4)+                   -> blank: pen 0 on 0
  CLR.B (A6)+
  BRA.S dpcx
dpcp:
  MOVE.B D1,D3
  AND.B #15,D3                  -> fg
  LSR.B #4,D1
  AND.B #7,D1                   -> bg
  BTST.L #2,D2
  BEQ.S dpcw
  CMP.B D1,D3                   -> inverse: fg=bg takes deffg first
  BNE.S dpcs
  MOVE.B D5,D3
dpcs:
  EXG D1,D3
dpcw:
  MOVE.B D3,(A4)+
  MOVE.B D1,(A6)+
dpcx:
  DBRA D7,dpcel
  MOVE.L D4,D0
  MOVEM.L (A7)+,D2-D7/A2-A6
  MOVE.L D0,r
ENDPROC r

PROC main()
  lineptest()
  cellstest()
ENDPROC

-> dplinep: pens instead of masks, plane bit chosen inside
PROC lineptest()
  DEF buf:PTR TO CHAR, ref:PTR TO CHAR, go:PTR TO LONG, gl:PTR TO CHAR,
      fg:PTR TO CHAR, bg:PTR TO CHAR, trial, cw, b0, n, i, x, g, bit,
      px, by, fails=0, k, v, pb
  buf := New(64)
  ref := New(64)
  go := New(256)
  gl := New(256)
  fg := New(64)
  bg := New(64)
  FOR trial := 1 TO 20000
    cw := rnd(8) + 1
    b0 := rnd(8)
    n := rnd(60) + 1
    pb := rnd(8)
    FOR i := 0 TO 63
      v := rnd(256)
      buf[i] := v
      ref[i] := v
    ENDFOR
    FOR i := 0 TO n - 1
      gl[i] := rnd(256)
      go[i] := i
      fg[i] := rnd(256)
      bg[i] := rnd(256)
    ENDFOR
    FOR i := 0 TO n - 1
      FOR x := 0 TO cw - 1
        g := gl[i] AND Shl(1, 7 - x)
        bit := IF g THEN (fg[i] AND Shl(1, pb)) ELSE (bg[i] AND Shl(1, pb))
        px := b0 + Mul(i, cw) + x
        by := Shr(px, 3)
        k := Shl(1, 7 - (px AND 7))
        IF bit THEN ref[by] := ref[by] OR k ELSE ref[by] := ref[by] AND (255 - k)
      ENDFOR
    ENDFOR
    dplinep(buf, b0, go, gl, fg, bg, n, cw, pb)
    FOR i := 0 TO 63
      IF buf[i] <> ref[i]
        IF fails < 5 THEN WriteF('dplinep MISMATCH trial \d cw \d b0 \d n \d plane \d byte \d\n', trial, cw, b0, n, pb, i)
        fails := fails + 1
        i := 64
      ENDIF
    ENDFOR
  ENDFOR
  IF fails = 0 THEN WriteF('PASS: dplinep, 20000 random lines\n') ELSE WriteF('FAIL: dplinep \d\n', fails)
ENDPROC

-> dpcells against drawmrow's rules written out in E
PROC cellstest()
  DEF m:PTR TO CHAR, a:PTR TO CHAR, st:PTR TO CHAR, go:PTR TO LONG,
      fg:PTR TO CHAR, bg:PTR TO CHAR, trial, n, i, ch, dfg, sty, rs,
      c, at, sy, f, b, t, fails=0
  m := New(256)
  a := New(256)
  st := New(256)
  go := New(1024)
  fg := New(256)
  bg := New(256)
  FOR trial := 1 TO 5000
    n := rnd(200) + 1
    ch := rnd(32) + 1
    dfg := rnd(16)
    FOR i := 0 TO n - 1
      m[i] := rnd(256)
      a[i] := IF rnd(3) THEN rnd(256) ELSE 0
      st[i] := IF rnd(3) THEN rnd(8) ELSE 0
    ENDFOR
    rs := dpcells(m, a, st, n, ch, dfg, go, fg, bg)
    sty := FALSE
    FOR i := 0 TO n - 1
      c := m[i]
      IF c < 32 THEN c := 32
      at := a[i]
      sy := st[i]
      IF sy AND 3 THEN sty := TRUE
      IF (at = 0) AND (sy = 0)
        f := 0
        b := 0
      ELSE
        f := at AND 15
        b := Shr(at, 4) AND 7
        IF sy AND 4
          IF f = b THEN f := dfg
          t := f
          f := b
          b := t
        ENDIF
      ENDIF
      IF (go[i] <> Mul(c, ch)) OR (fg[i] <> f) OR (bg[i] <> b)
        IF fails < 5 THEN WriteF('dpcells MISMATCH trial \d cell \d\n', trial, i)
        fails := fails + 1
      ENDIF
    ENDFOR
    IF (rs <> 0) <> sty
      IF fails < 5 THEN WriteF('dpcells styled flag wrong trial \d\n', trial)
      fails := fails + 1
    ENDIF
  ENDFOR
  IF fails = 0 THEN WriteF('PASS: dpcells, 5000 random rows\n') ELSE WriteF('FAIL: dpcells \d\n', fails)
ENDPROC

