/* cbone - ONE conbench workload, conbench's own loop, timed.
   usage: cbone <sync|plain|sgr|perchar|scroll|eeol|block> [N scale] */
MODULE 'dos/dos'
DEF out, blk[4100]:ARRAY OF CHAR

PROC main()
  DEF rd:PTR TO LONG, a[2]:ARRAY OF LONG, t, i, j, k, sc, s[80]:STRING,
      line2[400]:STRING, tmp[24]:STRING, c, t0:datestamp, t1:datestamp
  a[0] := 0; a[1] := 0
  rd := ReadArgs('TEST/A,N/N', a, NIL)
  IF rd = NIL THEN RETURN 10
  t := a[0]
  sc := IF a[1] THEN Long(a[1]) ELSE 10
  out := Output()
  c := 33
  FOR i := 0 TO 4095
    IF Mod(i, 79) = 78
      blk[i] := 10
    ELSE
      blk[i] := c
      c := c + 1
      IF c > 126 THEN c := 33
    ENDIF
  ENDFOR
  Write(out, [27,"[","0","m",12]:CHAR, 5)
  DateStamp(t0)
  IF StrCmp(t, 'sync')
    FOR i := 1 TO Mul(200, sc)
      Write(out, blk, 79)
      WaitForChar(out, 0)
    ENDFOR
  ELSEIF StrCmp(t, 'plain')
    FOR i := 1 TO Mul(816, sc) DO Write(out, blk, 79)
  ELSEIF StrCmp(t, 'block')
    FOR i := 1 TO Mul(16, sc) DO Write(out, blk, 4029)
  ELSEIF StrCmp(t, 'scroll')
    FOR i := 1 TO Mul(1200, sc) DO Write(out, '\n\n\n\n\n\n\n\n\n\n', 10)
  ELSEIF StrCmp(t, 'sgr')
    FOR i := 1 TO Mul(300, sc)
      FOR k := 0 TO 7
        StringF(s, '\c[3\dm12345678', 27, k)
        Write(out, s, StrLen(s))
      ENDFOR
      Write(out, '\n', 1)
    ENDFOR
  ELSEIF StrCmp(t, 'perchar')
    FOR i := 1 TO Mul(60, sc)
      StrCopy(line2, '')
      FOR k := 0 TO 39
        StringF(tmp, '\c[3\dm\c', 27, Mod(k, 8), 65 + Mod(k + i, 26))
        StrAdd(line2, tmp)
      ENDFOR
      StrAdd(line2, '\n')
      Write(out, line2, StrLen(line2))
    ENDFOR
  ELSEIF StrCmp(t, 'eeol')
    FOR i := 1 TO Mul(700, sc)
      StringF(s, '\cworking: \d%\c[K', 13, Mod(i, 100), 27)
      Write(out, s, StrLen(s))
    ENDFOR
  ELSEIF StrCmp(t, 'bytewise')
    FOR i := 1 TO Mul(2400, sc) DO Write(out, blk + Mod(i, 78), 1)
  ELSEIF StrCmp(t, 'cursor')
    FOR i := 1 TO Mul(700, sc)
      StringF(s, '\c[\d;\dH-cursor-', 27, Mod(i, 20) + 1, Mod(i, 60) + 1)
      Write(out, s, StrLen(s))
    ENDFOR
  ELSEIF StrCmp(t, 'vt')
    FOR i := 1 TO Mul(15, sc)
      FOR j := 1 TO 30
        StringF(s, '\c[\d;1H\c[K', 27, j, 27)
        k := StrLen(s)
        CopyMem(blk + Mod(Mul(j, 7) + i, 240), s + k, 60)
        SetStr(s, k + 60)
        Write(out, s, StrLen(s))
      ENDFOR
    ENDFOR
  ELSEIF StrCmp(t, 'insline')
    FOR i := 1 TO Mul(100, sc)
      StringF(line2, '\c[15;1H\c[L\c[M', 27, 27, 27)
      Write(out, line2, StrLen(line2))
    ENDFOR
  ELSEIF StrCmp(t, 'inschar')
    FOR i := 1 TO Mul(200, sc)
      StringF(line2, '\c[\d;5Habcdefgh\c[\d;5H\c[4@\c[4P', 27, Mod(i, 28) + 2, 27, Mod(i, 28) + 2, 27, 27)
      Write(out, line2, StrLen(line2))
    ENDFOR
  ELSEIF StrCmp(t, 'clear')
    FOR i := 1 TO Mul(40, sc)
      Write(out, [12]:CHAR, 1)
      FOR j := 1 TO 20 DO Write(out, blk, 79)
    ENDFOR
  ENDIF
  WaitForChar(out, 0)
  DateStamp(t1)
  j := Mul(Mul(t1.minute - t0.minute, 3000) + t1.tick - t0.tick, 20)
  Write(out, [27,"[","0","m",10]:CHAR, 5)
  StringF(line2, 'cbone \s: \d ms\n', t, j)
  c := Open('RAM:cbone.txt', MODE_READWRITE)
  IF c
    Seek(c, 0, OFFSET_END)
    Write(c, line2, StrLen(line2))
    Close(c)
  ENDIF
  FreeArgs(rd)
ENDPROC
