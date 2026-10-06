#!/usr/bin/env python3
"""mkdiff.py - build engine/fxdiff.e: the WHOLE handler source with its
main renamed and dfflush swapped for a bookkeeping-only stub, plus a
driver that feeds random output through render() twice - E only, then
with the C engine - and compares every model byte, every console field,
the engine globals and a digest of what each flush would have painted.
Every second chunk is rendered as two calls cut at a random byte
(Audit8), so split sequences are compared as well.
Run: engine/mkdiff.py && ecompile engine/fxdiff.e engine/fxdiff LARGE ADDBUF=1
     && vamos -C 68020 engine/fxdiff [seeds]"""
import sys
src = open('ccon-handler.e', encoding='latin1').read()
def rep(a, b):
    global src
    assert src.count(a) == 1, a
    src = src.replace(a, b)
rep('\nPROC main()\n', '\nDEF frec=0, hseed=1, hbuf[600]:ARRAY OF CHAR,\n    sdb[1536]:ARRAY OF CHAR, satr[512]:ARRAY OF CHAR, sglob[20]:ARRAY OF LONG,\n    adb[1536]:ARRAY OF CHAR, aglob[20]:ARRAY OF LONG, bglob[20]:ARRAY OF LONG\n\nPROC hmain()\n')
rep('\nPROC dfflush()\n', '\nPROC dfflush_real()\n')
driver = r'''
PROC hrnd(n)
  hseed := Mul(hseed, 1103515245) + 12345
ENDPROC Mod(Shr(hseed, 16) AND $7FFF, n)

PROC fmix(v)
  frec := Eor(Mul(frec, 33), v)
ENDPROC

-> dfflush, bookkeeping only: digest what the real one would paint,
-> then settle the engine state exactly as it does
PROC dfflush()
  DEF r
  IF dfon = FALSE THEN RETURN
  fmix(dfpend + Shl(dffull AND 1, 8) + Shl(dflost, 9))
  IF dffull = FALSE
    IF dfhi >= dflo
      FOR r := dflo TO dfhi
        IF dfd[r] = dfgen THEN fmix(r + Shl(dfx0[r], 8) + Shl(dfx1[r], 16))
      ENDFOR
    ENDIF
  ELSE
    IF dfnarrow
      maskscan()
      dfnarrow := FALSE
    ENDIF
  ENDIF
  fmix(Mul(dflo, 1000) + dfhi)
  dffull := FALSE
  dfpend := 0
  dfgen := dfgen + 1
  IF dfgen > 255
    FOR r := 0 TO 511 DO dfdb[r] := 0
    dfgen := 1
  ENDIF
  dflo := curcon.rows
  dfhi := -1
  dflost := 0
  dfvb := curcon.vblank
ENDPROC

PROC gsave(g:PTR TO LONG, db:PTR TO CHAR)
  g[0] := dfo; g[1] := dfgen; g[2] := alteat; g[3] := dfnarrow; g[4] := dfon
  g[5] := dfpend; g[6] := dffull; g[7] := dflo; g[8] := dfhi; g[9] := dflost
  g[10] := dfvb; g[11] := atrunv; g[12] := styrunv; g[13] := maskon
  CopyMem(dfdb, db, 512); CopyMem(dfx0b, db + 512, 512); CopyMem(dfx1b, db + 1024, 512)
ENDPROC

PROC grest(g:PTR TO LONG, db:PTR TO CHAR)
  dfo := g[0]; dfgen := g[1]; alteat := g[2]; dfnarrow := g[3]; dfon := g[4]
  dfpend := g[5]; dffull := g[6]; dflo := g[7]; dfhi := g[8]; dflost := g[9]
  dfvb := g[10]; atrunv := g[11]; styrunv := g[12]; maskon := g[13]
  CopyMem(db, dfdb, 512); CopyMem(db + 512, dfx0b, 512); CopyMem(db + 1024, dfx1b, 512)
  dfd := dfdb + dfo; dfx0 := dfx0b + dfo; dfx1 := dfx1b + dfo
ENDPROC

PROC mkcon(rows, cols, hist, jeff, jauto, wbp)
  DEF k:PTR TO console, n, i
  k := New(SIZEOF console)
  k.rows := rows; k.cols := cols
  k.sbmax := rows + hist
  n := Mul(k.sbmax, cols)
  k.sb := New(n); k.sa := New(n); k.ss := New(n); k.sw := New(slsize(k.sbmax))
  k.win := New(200); k.rp := New(100)
  k.deffg := 1; k.curfg := 1; k.mfloor := 1; k.mpens := 1; k.mmask := 1
  k.jeff := Max(1, Min(jeff, rows - 1)); k.jauto := jauto; k.wbpens := wbp; k.can16 := TRUE
  FOR i := 0 TO 7 DO k.anstab[i] := IF i AND 1 THEN i + 8 ELSE -1
  k.vblank := TRUE
  k.jsync := IF Mod(rows + hist, 3) = 2 THEN 5 ELSE 0   -> 1.2.8b9: barrier cadence
ENDPROC k

PROC conclone(a:PTR TO console, b:PTR TO console)
  DEF n, sb, sa, ss, sw, win, rp
  n := Mul(a.sbmax, a.cols)
  sb := b.sb; sa := b.sa; ss := b.ss; sw := b.sw; win := b.win; rp := b.rp
  CopyMem(a, b, SIZEOF console)
  b.sb := sb; b.sa := sa; b.ss := ss; b.sw := sw; b.win := win; b.rp := rp
  CopyMem(a.sb, sb, n); CopyMem(a.sa, sa, n); CopyMem(a.ss, ss, n); CopyMem(a.sw, sw, slsize(a.sbmax))
ENDPROC

-> 0 = same; else a description code
PROC concmp(a:PTR TO console, b:PTR TO console)
  DEF n, sb, sa, ss, sw, win, rp, i, p:PTR TO CHAR, q:PTR TO CHAR, r=0
  n := Mul(a.sbmax, a.cols)
  sb := b.sb; sa := b.sa; ss := b.ss; sw := b.sw; win := b.win; rp := b.rp
  b.sb := a.sb; b.sa := a.sa; b.ss := a.ss; b.sw := a.sw; b.win := a.win; b.rp := a.rp
  p := a; q := b
  FOR i := 0 TO SIZEOF console - 1
    IF r = 0 THEN IF p[i] <> q[i] THEN r := 10000 + i
  ENDFOR
  b.sb := sb; b.sa := sa; b.ss := ss; b.sw := sw; b.win := win; b.rp := rp
  IF r THEN RETURN r
  p := a.sb; q := sb
  FOR i := 0 TO n - 1 DO IF p[i] <> q[i] THEN RETURN 20000 + i
  p := a.sa; q := sa
  FOR i := 0 TO n - 1 DO IF p[i] <> q[i] THEN RETURN 30000 + i
  p := a.ss; q := ss
  FOR i := 0 TO n - 1 DO IF p[i] <> q[i] THEN RETURN 40000 + i
  p := a.sw; q := sw
  FOR i := 0 TO a.sbmax - 1 DO IF p[i] <> q[i] THEN RETURN 50000 + i
ENDPROC 0

-> 1.2.8b11: the written-length rule - every cell from a ring row's
-> length to the margin is zero in all three planes. 0 = holds.
PROC slcheck(k:PTR TO console)
  DEF i, x, n, o
  FOR i := 0 TO k.sbmax - 1
    n := Int(slbase(k) + i + i)
    IF (n < 0) OR (n > k.cols) THEN RETURN 90000 + i
    o := Mul(i, k.cols)
    FOR x := n TO k.cols - 1
      IF Char(k.sb + o + x) OR Char(k.sa + o + x) OR Char(k.ss + o + x) THEN RETURN 91000 + i
    ENDFOR
  ENDFOR
ENDPROC 0

PROC putnum(p, v)
  DEF s[8]:STRING, i
  StringF(s, '\d', v)
  FOR i := 0 TO StrLen(s) - 1 DO hbuf[p + i] := s[i]
ENDPROC p + StrLen(s)

-> a chunk of plausible output, weighted toward what the engine takes,
-> with everything else E must still get in between
PROC genchunk(maxn)
  DEF n=0, t, len, j, f
  len := hrnd(maxn) + 1
  WHILE n < len
    t := hrnd(100)
    IF t < 40
      FOR j := 0 TO hrnd(90) DO IF n < 590 THEN hbuf[n++] := 32 + hrnd(95)
    ELSEIF t < 48
      hbuf[n++] := 10
    ELSEIF t < 51
      hbuf[n++] := 13
    ELSEIF t < 53
      hbuf[n++] := 8
    ELSEIF t < 55
      hbuf[n++] := 9
    ELSEIF t < 56
      hbuf[n++] := 12
    ELSEIF t < 58
      hbuf[n++] := 160 + hrnd(96)
    ELSEIF t < 60
      hbuf[n++] := 128 + hrnd(32)
      IF hbuf[n - 1] = $9D THEN hbuf[n - 1] := $9E  -> OSC retitles: needs a real window
    ELSEIF t < 61
      hbuf[n++] := hrnd(32)
    ELSEIF t < 63
      hbuf[n++] := 27
      hbuf[n++] := ListItem(["D", "E", "M", "c", "7"], hrnd(5))
    ELSE
      hbuf[n++] := 27
      IF hrnd(40) = 0 THEN hbuf[n - 1] := $9B ELSE hbuf[n++] := "["
      IF hrnd(30) = 0 THEN hbuf[n++] := ">"
      f := hrnd(20)
      IF f < 9
        n := putnum(n, ListItem([0, 1, 22, 3, 23, 4, 24, 7, 27, 30, 31, 32, 33, 34, 35, 36, 37, 39, 40, 41, 47, 49, 5, 1000], hrnd(24)))
        IF hrnd(3) = 0
          hbuf[n++] := ";"
          n := putnum(n, 30 + hrnd(18))
        ENDIF
        IF hrnd(8) = 0
          hbuf[n++] := ";"; hbuf[n++] := ";"; hbuf[n++] := ";"
          n := putnum(n, hrnd(50))
        ENDIF
        hbuf[n++] := "m"
      ELSEIF f < 12
        n := putnum(n, hrnd(40))
        IF hrnd(4) THEN hbuf[n++] := ";"
        IF hrnd(4) THEN n := putnum(n, hrnd(100))
        hbuf[n++] := IF hrnd(2) THEN "H" ELSE "f"
      ELSE
        IF hrnd(2) THEN n := putnum(n, hrnd(12))
        IF hrnd(25) = 0 THEN hbuf[n++] := " "
        hbuf[n++] := ListItem(["K", "J", "A", "B", "C", "D", "L", "M", "@", "P", "S", "T", "x"], hrnd(13))
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC n

-> Audit8: every second chunk goes in as TWO render calls cut at a
-> random byte, so sequences split across writes (E finishing what C
-> handed back, at cesc <> 0) are compared too - the J1 class
PROC rsplit(len, cut)
  IF cut <= 0
    render(hbuf, len)
  ELSE
    render(hbuf, cut)
    render(hbuf + cut, len - cut)
  ENDIF
ENDPROC

PROC main()
  DEF k1:PTR TO console, k2:PTR TO console, cfg, it, len, f1, f2, r,
      rows, cols, s0, nchunks=0, bad=0, i, cut
  FOR i := 0 TO 255
    prtbl[i] := IF ((i >= 32) AND (i <= 126)) OR (i >= 160) THEN 1 ELSE 0
    zerorun[i] := 0
  ENDFOR
  dfd := dfdb; dfx0 := dfx0b; dfx1 := dfx1b
  FOR i := 0 TO 511 DO dfdb[i] := 0
  fxsetup()
  WriteF('layout check: \s (SIZEOF console \d)\n', IF fastok THEN 'ok' ELSE 'FAILED', SIZEOF console)
  IF fastok = FALSE THEN RETURN 20
  s0 := 1
  IF arg[0] THEN s0 := Val(arg + (IF arg[0] = "v" THEN 1 ELSE 0))
  FOR cfg := 0 TO 23
    hseed := s0 + Mul(cfg, 7919)
    IF arg[0] = "v" THEN WriteF('cfg \d\n', cfg)
    rows := ListItem([3, 6, 24, 30, 2, 50], Mod(cfg, 6))
    cols := ListItem([10, 77, 1, 40, 255, 8], Mod(Div(cfg, 2), 6))
    k1 := mkcon(rows, cols, ListItem([0, 5, 200], Mod(cfg, 3)), ListItem([1, 4, 2, 9], Mod(cfg, 4)),
                IF Mod(cfg, 5) < 2 THEN TRUE ELSE FALSE, IF Mod(cfg, 7) = 3 THEN TRUE ELSE FALSE)
    k2 := mkcon(rows, cols, ListItem([0, 5, 200], Mod(cfg, 3)), 1, FALSE, FALSE)
    conclone(k1, k2)
    FOR it := 1 TO 300
      len := genchunk(IF Mod(it, 3) = 0 THEN 20 ELSE 300)
      cut := IF (Mod(it, 2) = 0) AND (len > 1) THEN 1 + hrnd(len - 1) ELSE 0
      gsave(sglob, sdb)
      CopyMem(atrun, satr, 256); CopyMem(styrun, satr + 256, 256)
      IF (arg[0] = "v") AND (cfg = 19) AND (it = 214)
        WriteF('cx \d cy \d sbtop \d sbcnt \d ancy \d jburst \d jslk \d cesc \d viewoff \d\n', k1.cx, k1.cy, k1.sbtop, k1.sbcnt, k1.ancy, k1.jburst, k1.jslk, k1.cesc, k1.viewoff)
        FOR i := 0 TO len - 1 DO WriteF(' \d', hbuf[i])
        WriteF('\n')
      ENDIF
      curcon := k1; fastok := FALSE; frec := 0
      rsplit(len, cut)
      f1 := frec
      gsave(aglob, adb)
      grest(sglob, sdb)
      CopyMem(satr, atrun, 256); CopyMem(satr + 256, styrun, 256)
      IF (arg[0] = "v") AND (cfg = 19) THEN WriteF('it \d C\n', it)
      curcon := k2; fastok := TRUE; frec := 0
      rsplit(len, cut)
      f2 := frec
      gsave(bglob, sdb)
      nchunks++
      r := concmp(k1, k2)
      IF (r = 0) AND (f1 <> f2) THEN r := 60000
      IF r = 0 THEN r := slcheck(k1)
      IF r = 0 THEN IF slcheck(k2) THEN r := 100000 + slcheck(k2)
      IF r = 0
        FOR i := 0 TO 10 DO IF aglob[i] <> bglob[i] THEN IF r = 0 THEN r := 70000 + i
      ENDIF
      IF r = 0
        FOR i := 0 TO 1535 DO IF adb[i] <> sdb[i] THEN IF r = 0 THEN r := 80000 + i
      ENDIF
      IF r
        WriteF('MISMATCH cfg \d (\dx\d) chunk \d code \d cut \d\n  bytes:', cfg, cols, rows, it, r, cut)
        WriteF('  E: jburst \d cx \d cy \d jslk \d sbtop \d  C: jburst \d cx \d cy \d jslk \d sbtop \d\n', k1.jburst, k1.cx, k1.cy, k1.jslk, k1.sbtop, k2.jburst, k2.cx, k2.cy, k2.jslk, k2.sbtop)
        FOR i := 0 TO len - 1 DO WriteF(' \d', hbuf[i])
        WriteF('\n  E sb:')
        FOR i := 0 TO Min(40, Mul(k1.sbmax, k1.cols)) - 1 DO WriteF(' \d', Char(k1.sb + i))
        WriteF('\n  C sb:')
        FOR i := 0 TO Min(40, Mul(k1.sbmax, k1.cols)) - 1 DO WriteF(' \d', Char(k2.sb + i))
        WriteF('\n')
        bad++
        conclone(k1, k2)
        grest(aglob, adb)
        IF bad > 5 THEN RETURN 10
      ENDIF
    ENDFOR
  ENDFOR
  WriteF('\d chunks, \d mismatches\n', nchunks, bad)
ENDPROC
'''
open('engine/fxdiff.e', 'w', encoding='latin1').write(src.replace("INCBIN 'engine/engine.bin'", "INCBIN 'engine.bin'") + driver)
print('engine/fxdiff.e written')
