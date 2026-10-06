-> a8test.e - Audit8 batch 1 checks a program can make on its own,
-> against any CCON-class device: a8test OPENSPEC
-> (e.g. a8test XC1:0/0/640/150/a8)
->
-> J4: WaitForChar(fh, 500000) with no key must wait ~25 ticks. Before
->     the fix the fraction became us mod 16960, so it came back at once.
-> J1: 300 X's, each wrapped in ESC[31m ... ESC[0m, written as one
->     continuous stream cut into 7-byte writes - so almost every flush
->     tick ends inside a sequence - must leave the cursor exactly where
->     300 plain X's do. Before the fix the C flush started the next
->     buffer at parser state 0 and painted the sequence's tail as text.
->     The cursor is read back with a device status report (raw mode).
->
-> Run the OLD build too (a second mount) - the checks must be able to
-> fail. Build: ecompile a8test.e a8test

MODULE 'dos/dos', 'dos/dosextens'

PROC ticks()
  DEF ds:datestamp
  DateStamp(ds)
ENDPROC Mul(ds.minute, 3000) + ds.tick

-> the cursor as row * 1000 + col (1-based), -1 = no answer
PROC dsr(fh)
  DEF buf[40]:ARRAY OF CHAR, n=0, i=0, row=0, col=0
  SetMode(fh, 1)
  Write(fh, '\e[6n', 4)
  WHILE (n < 38) AND WaitForChar(fh, 1000000)
    IF Read(fh, buf + n, 1) <> 1 THEN JUMP got
    n++
    IF buf[n - 1] = "R" THEN JUMP got
  ENDWHILE
got:
  SetMode(fh, 0)
  WHILE (i < n) AND ((buf[i] < "0") OR (buf[i] > "9")) DO i++
  IF i >= n THEN RETURN -1
  WHILE (i < n) AND (buf[i] >= "0") AND (buf[i] <= "9")
    row := Mul(row, 10) + buf[i] - "0"
    i++
  ENDWHILE
  IF (i < n) AND (buf[i] = ";") THEN i++
  WHILE (i < n) AND (buf[i] >= "0") AND (buf[i] <= "9")
    col := Mul(col, 10) + buf[i] - "0"
    i++
  ENDWHILE
ENDPROC Mul(row, 1000) + col

PROC main()
  DEF fh, name[120]:STRING, t0, t1, i, ff[2]:ARRAY OF CHAR, s:PTR TO CHAR,
      n, a, b, fails=0
  IF arg[0] = 0
    WriteF('usage: a8test OPENSPEC (e.g. XC1:0/0/640/150/a8)\n')
    RETURN 10
  ENDIF
  StrCopy(name, arg)
  fh := Open(name, MODE_NEWFILE)
  IF fh = NIL
    WriteF('cannot open \s\n', name)
    RETURN 10
  ENDIF
  ff[0] := 12

  -> J4
  FOR i := 1 TO 3
    t0 := ticks()
    WaitForChar(fh, 500000)
    t1 := ticks()
    WriteF('J4 WaitForChar(0.5s) took \d ticks\n', t1 - t0)
    IF (t1 - t0) < 15 THEN fails++
  ENDFOR

  -> J1, the control: 300 plain X's in one write
  s := New(3000)
  IF s = NIL THEN RETURN 20
  FOR i := 0 TO 299 DO s[i] := "X"
  Write(fh, ff, 1)
  Write(fh, s, 300)
  a := dsr(fh)
  -> J1, the test: the same X's in colour, cut into 7-byte writes
  FOR i := 0 TO 299 DO CopyMem('\e[31mX\e[0m', s + Mul(i, 10), 10)
  Write(fh, ff, 1)
  n := 0
  WHILE n < 3000
    Write(fh, s + n, Min(7, 3000 - n))
    n := n + 7
  ENDWHILE
  b := dsr(fh)
  WriteF('J1 cursor: plain X''s \d/\d, split colour stream \d/\d (row/col, must match)\n',
         a / 1000, Mod(a, 1000), b / 1000, Mod(b, 1000))
  IF (a < 0) OR (a <> b) THEN fails++
  Dispose(s)
  Close(fh)
  WriteF('a8test: \d failure(s)\n', fails)
ENDPROC IF fails THEN 5 ELSE 0
