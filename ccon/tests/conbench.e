/* conbench.e -- console speed benchmark for CCON:, CON: and ViNCEd
   usage: conbench NAME <label> [TO file] [REPS n] [SCALE n] [SYNC] [FORCE]

   Run it INSIDE the console you want to measure - it writes its test
   output to stdout, so the console under test is whichever one the
   shell is running in:

     NewShell CCON:                       (then, in that window)
     conbench CCON TO RAM:conbench.txt
     NewShell CON:                        (then, in that window)
     conbench CON: TO RAM:conbench.txt
     NewShell ViNCEd-or-your-CON-takeover
     conbench ViNCEd TO RAM:conbench.txt

   Results APPEND to the file, so all three runs land in one place and
   can be read side by side. NAME is just the label written into the
   file - call it whatever you like.

   ---------------------------------------------------------------
   WHAT THIS ACTUALLY MEASURES - read this before believing a number
   ---------------------------------------------------------------

   A console is a DOS handler: Write() sends an ACTION_WRITE packet
   and blocks until the handler replies. So what is timed here is
   "how long the handler takes to accept and acknowledge the output".

   For a console that draws before it replies, that IS drawing time.
   CCON: works this way - it renders directly and replies afterwards
   (the double-buffering experiment was removed in 1.2, so there is
   no deferred flush left in it).

   A console that replies FIRST and draws later would look faster
   here than it feels to a user. That is not a hypothetical: it is
   the obvious way to make a console appear quick, and this benchmark
   cannot see past it from the client side. There is no reliable
   cross-console "render barrier" a client can ask for.

   The SYNC switch is the honest partial answer. With SYNC, each test
   ends with a WaitForChar(fh, 0) - a separate packet, which the
   handler must dequeue after the writes it is already holding. It is
   NOT a guaranteed render barrier (a handler may reply to it without
   flushing pixels), but it is a cheap probe: if a console's numbers
   change noticeably between a plain run and a SYNC run, that console
   is deferring something, and its plain numbers are optimistic.
   Run both ways before drawing conclusions.

   ---------------------------------------------------------------
   MAKING THE COMPARISON FAIR
   ---------------------------------------------------------------

   - SAME WINDOW SIZE. Wrapping and scrolling dominate several of
     these tests, so a 80x25 window and a 80x50 window are not
     comparable. conbench asks the console for its size and records
     it in the file; check the three lines match before comparing.
   - SAME SCREEN DEPTH. More bitplanes means more blitting for every
     console. A 4-colour and a 256-colour screen are different tests.
   - SAME FONT. topaz 8 everywhere, unless you are deliberately
     measuring font cost.
   - NOTHING ELSE RUNNING. Close other windows; a busy Workbench
     steals time from whichever console is measured second.
   - REPS n (default 3) runs the whole suite n times and keeps the
     BEST time for each test, which is the usual defence against
     another task stealing a slice mid-measurement.

   Resolution is one system tick, 1/50 s. Any test finishing in under
   25 ticks (half a second) is flagged with a '?' - raise SCALE and
   re-run rather than trusting it.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/datetime'

CONST BLKSZ=4096,           -> the big-write buffer
      BLKLINES=51,          -> whole 79-byte lines inside one 4K block
      BLKBYTES=4029,        -> BLKLINES * 79, the block test's write size
      BLKREPS=8,            -> so block-4k moves BLKREPS*BLKBYTES bytes
      NLINES=408,           -> = BLKREPS * BLKLINES: plain-lines moves the
                            -> SAME bytes and the same line count, which is
                            -> the only reason comparing the two means
                            -> anything
      LONGLINE=300,         -> the auto-wrap test's line length
      RESSZ=8192,           -> the results text accumulated in memory
      NTESTS=9,
      SLOWTICKS=25          -> below this a result is not trustworthy

DEF out,                    -> the console under test (stdout)
    blk:PTR TO CHAR,        -> BLKSZ of printable filler
    longl:PTR TO CHAR,      -> LONGLINE printable chars, no newline
    res:PTR TO CHAR,        -> results text, written at the very end
    scratch[256]:STRING,
    best[NTESTS]:ARRAY OF LONG,
    bytes[NTESTS]:ARRAY OF LONG,
    dosync=FALSE,
    cols=0, rows=0

PROC main() HANDLE
  DEF rdargs, argarray:PTR TO LONG, label:PTR TO CHAR, fname:PTR TO CHAR,
      reps, scale, p:PTR TO LONG, i, r, t, fh, ds:datestamp

  argarray := [0,0,0,0,0,0]:LONG
  rdargs := ReadArgs('NAME/A,TO/K,REPS/K/N,SCALE/K/N,SYNC/S,FORCE/S', argarray, NIL)
  IF rdargs = NIL
    Throw("ARG", 'usage: conbench NAME <label> [TO file] [REPS n] [SCALE n] [SYNC] [FORCE]')
  ENDIF
  label := argarray[0]
  fname := argarray[1]
  IF fname = NIL THEN fname := 'RAM:conbench.txt'
  reps := 3
  IF argarray[2]
    p := argarray[2]
    reps := p[0]
  ENDIF
  scale := 1
  IF argarray[3]
    p := argarray[3]
    scale := p[0]
  ENDIF
  IF reps < 1 THEN reps := 1
  IF scale < 1 THEN scale := 1
  dosync := argarray[4]

  out := Output()
  -> Refuse a redirected run: `conbench X >file` would time the
  -> FILESYSTEM, not the console, and produce a confident nonsense
  -> number. FORCE exists so the thing can be smoke-tested off a real
  -> console (under vamos, say) without pretending the result means
  -> anything.
  IF (IsInteractive(out) = 0) AND (argarray[5] = 0)
    Throw("ARG", 'stdout is not a console - run conbench IN the console you want to measure (FORCE to override)')
  ENDIF

  blk := New(BLKSZ + 4)
  longl := New(LONGLINE + 4)
  res := String(RESSZ)
  IF (blk = NIL) OR (longl = NIL) OR (res = NIL) THEN Throw("MEM", 'out of memory')
  fillbuffers()

  -> the window size, asked of the console itself. Done ONCE, before
  -> any timing, so whatever it costs (CCON: takes an alternate-screen
  -> snapshot on the cooked->raw switch, for instance) is paid outside
  -> every measured region and by all three consoles alike.
  winsize()

  FOR i := 0 TO NTESTS - 1
    best[i] := -1
    bytes[i] := 0
  ENDFOR

  -> the suite, REPS times, keeping the best time per test
  FOR r := 1 TO reps
    FOR i := 0 TO NTESTS - 1
      t := timetest(i, scale)
      IF (best[i] < 0) OR (t < best[i]) THEN best[i] := t
    ENDFOR
  ENDFOR

  -> back to a clean screen before the summary, so the numbers are
  -> readable and the next run starts from the same state
  Write(out, [27,"[","0","m",12]:CHAR, 5)

  DateStamp(ds)
  report(label, reps, scale, ds)

  -> the file is opened and written only NOW: no disk I/O of ours
  -> happened between or during the timed regions
  fh := Open(fname, MODE_READWRITE)
  IF fh
    Seek(fh, 0, OFFSET_END)
  ELSE
    fh := Open(fname, MODE_NEWFILE)
  ENDIF
  IF fh = NIL THEN Throw("DOS", IoErr())
  Write(fh, res, StrLen(res))
  Close(fh)

  WriteF('\nconbench: appended to \s\n', fname)

EXCEPT DO
  IF exception = "DOS"
    PrintFault(exceptioninfo, 'conbench')
  ELSEIF exception <> 0
    WriteF('conbench: \s\n', exceptioninfo)
  ENDIF
  IF rdargs THEN FreeArgs(rdargs)
ENDPROC

-> printable filler. Deliberately VARIED, not one repeated character:
-> a console that batches identical glyphs, or a Text() call on a run
-> of spaces, is not doing the work a real listing asks for.
PROC fillbuffers()
  DEF i, c
  c := 33
  FOR i := 0 TO BLKSZ - 1
    -> lay it out as 78-char lines so the block test scrolls the same
    -> number of times the line test does, for the same byte count
    IF Mod(i, 79) = 78
      blk[i] := 10
    ELSE
      blk[i] := c
      c := c + 1
      IF c > 126 THEN c := 33
    ENDIF
  ENDFOR
  blk[BLKSZ] := 0
  c := 33
  FOR i := 0 TO LONGLINE - 1
    longl[i] := c
    c := c + 1
    IF c > 126 THEN c := 33
  ENDFOR
  longl[LONGLINE] := 0
ENDPROC

-> ---------------------------------------------------------------
-> timing. DateStamp gives days/minutes/ticks at 50 ticks a second;
-> the delta is computed in ticks and stays well inside a LONG for
-> anything short of a two-week benchmark.
-> ---------------------------------------------------------------
PROC stampticks(a:PTR TO datestamp, b:PTR TO datestamp)
  DEF dm
  dm := (Mul(b.days - a.days, 1440)) + (b.minute - a.minute)
ENDPROC Mul(dm, 3000) + (b.tick - a.tick)

PROC timetest(id, scale)
  DEF t0:datestamp, t1:datestamp, n
  -> start every test from a cleared screen and default colours, so
  -> one test cannot leave the console in a state that changes the
  -> next one's cost (a left-over colour, a scrolled-up prompt)
  Write(out, [27,"[","0","m",12]:CHAR, 5)
  DateStamp(t0)
  n := dotest(id, scale)
  IF dosync THEN WaitForChar(out, 0)
  DateStamp(t1)
  bytes[id] := n
ENDPROC stampticks(t0, t1)

-> ---------------------------------------------------------------
-> the workloads. Each returns the number of bytes it wrote.
-> Sizes are chosen so a stock CON: takes roughly half a second to a
-> few seconds each on an 030; SCALE multiplies them if your machine
-> is quick enough to finish one under SLOWTICKS.
-> ---------------------------------------------------------------
PROC dotest(id, scale)
  DEF i, j, n=0, s[80]:STRING, k

  SELECT id
  CASE 0
    -> PLAIN: 78-char lines, ONE Write() per line. The ordinary shape
    -> of command output, and the number most people mean by "is my
    -> console fast". Per-packet cost is included, once per line.
    FOR i := 1 TO Mul(NLINES, scale)
      Write(out, blk, 79)
      n := n + 79
    ENDFOR
  CASE 1
    -> BLOCK: the SAME bytes and the same number of line breaks, but
    -> handed over in 4K writes. Comparing this against PLAIN
    -> separates per-packet overhead from per-character rendering:
    -> if BLOCK is much faster, the console's fixed cost per write
    -> dominates; if they are close, it is all drawing.
    FOR i := 1 TO Mul(BLKREPS, scale)
      Write(out, blk, BLKBYTES)
      n := n + BLKBYTES
    ENDFOR
  CASE 2
    -> BYTEWISE: one Write() per character. Brutal, and not artificial
    -> - it is exactly what a program using unbuffered single-character
    -> output does, and More reads and echoes this way. Almost pure
    -> packet round-trip cost.
    FOR i := 1 TO Mul(1200, scale)
      Write(out, blk + Mod(i, 78), 1)
      n := n + 1
    ENDFOR
  CASE 3
    -> SCROLL: bare newlines in one big write. Isolates the scroll
    -> path (ScrollRaster plus whatever bookkeeping the console does
    -> per line) from glyph drawing entirely.
    FOR i := 1 TO Mul(6, scale)
      FOR j := 1 TO 100
        Write(out, '\n\n\n\n\n\n\n\n\n\n', 10)
        n := n + 10
      ENDFOR
    ENDFOR
  CASE 4
    -> WRAP: 300-character lines with no newline, so the console must
    -> wrap them itself. CCON: also updates its soft-wrap plane here,
    -> which is what lets it re-flow on resize - a cost stock CON:
    -> pays differently and ViNCEd not at all in the same way.
    FOR i := 1 TO Mul(70, scale)
      Write(out, longl, LONGLINE)
      n := n + LONGLINE
    ENDFOR
  CASE 5
    -> SGR: colour changes several times per line. Every console has
    -> to split the line into runs and change pens between them; this
    -> is the `ls` colour case, and CCON: additionally stores an
    -> attribute per cell for its scrollback.
    FOR i := 1 TO Mul(150, scale)
      FOR k := 0 TO 7
        StringF(s, '\c[3\dm12345678', 27, k)
        Write(out, s, StrLen(s))
        n := n + StrLen(s)
      ENDFOR
      Write(out, '\n', 1)
      n := n + 1
    ENDFOR
  CASE 6
    -> CURSOR: absolute positioning then a short string, the shape a
    -> full-screen editor draws in. Tests the CSI parser and random
    -> access to the grid rather than sequential appending.
    FOR i := 1 TO Mul(350, scale)
      StringF(s, '\c[\d;\dH-cursor-', 27, Mod(i, 20) + 1, Mod(i, 60) + 1)
      Write(out, s, StrLen(s))
      n := n + StrLen(s)
    ENDFOR
  CASE 7
    -> CLEAR: form feed then a screenful. This is the More page-flip
    -> path - the one CCON: 1.2 fixed - and it is worth its own number
    -> because a console that clears slowly feels slow at exactly the
    -> moment a user is waiting to read something.
    FOR i := 1 TO Mul(20, scale)
      Write(out, [12]:CHAR, 1)
      n := n + 1
      FOR j := 1 TO 20
        Write(out, blk, 79)
        n := n + 79
      ENDFOR
    ENDFOR
  CASE 8
    -> ERASE-EOL: carriage return, text, erase to end of line - the
    -> progress-bar / percentage-counter idiom that rewrites one row
    -> over and over without scrolling.
    FOR i := 1 TO Mul(350, scale)
      StringF(s, '\cworking: \d%\c[K', 13, Mod(i, 100), 27)
      Write(out, s, StrLen(s))
      n := n + StrLen(s)
    ENDFOR
    Write(out, '\n', 1)
    n := n + 1
  ENDSELECT
ENDPROC n

PROC testname(id)
  DEF s
  SELECT id
  CASE 0; s := 'plain-lines'
  CASE 1; s := 'block-4k'
  CASE 2; s := 'bytewise'
  CASE 3; s := 'scroll-nl'
  CASE 4; s := 'wrap-long'
  CASE 5; s := 'sgr-colour'
  CASE 6; s := 'cursor-pos'
  CASE 7; s := 'clear-page'
  CASE 8; s := 'erase-eol'
  DEFAULT; s := '?'
  ENDSELECT
ENDPROC s

-> ---------------------------------------------------------------
-> ask the console how big it is: CSI 0 SPACE q, answered on the
-> INPUT stream as CSI 1;1;rows;cols SPACE r. Every console in the
-> family supports it - it is how stock `dir` learns it can do
-> columns - but a console that does NOT answer must not hang us,
-> so every read is gated behind WaitForChar with a timeout and the
-> whole thing gives up after a second.
-> ---------------------------------------------------------------
PROC winsize()
  DEF b[80]:ARRAY OF CHAR, n=0, c, got=FALSE, i, v, fld, done=FALSE

  SetMode(out, 1)                 -> raw: bytes arrive as they come
  Write(out, [27,"[","0",32,"q"]:CHAR, 5)
  WHILE (done = FALSE) AND (n < 78)
    IF WaitForChar(out, 500000) = 0    -> half a second per byte, plenty
      done := TRUE
    ELSE
      IF Read(out, b + n, 1) <> 1
        done := TRUE
      ELSE
        c := b[n]
        n := n + 1
        -> the report ends with 'r'; accept the 8-bit and 7-bit forms
        -> of everything before it without caring which arrived
        IF c = "r"
          done := TRUE
          got := TRUE
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  SetMode(out, 0)
  IF got = FALSE THEN RETURN
  -> pull the last two numbers out of the ;-separated run: the report
  -> is 1;1;rows;cols, so field 2 is rows and field 3 is cols
  fld := 0
  v := 0
  FOR i := 0 TO n - 1
    c := b[i]
    IF (c >= "0") AND (c <= "9")
      v := Mul(v, 10) + (c - 48)
    ELSEIF c = ";"
      IF fld = 2 THEN rows := v
      fld := fld + 1
      v := 0
    ELSE
      IF fld = 3 THEN cols := v
      v := 0
    ENDIF
  ENDFOR
ENDPROC

-> ---------------------------------------------------------------
-> the report. Built in memory, written to the file in one go.
-> ---------------------------------------------------------------
PROC addres(s:PTR TO CHAR)
  IF (StrLen(res) + StrLen(s)) < (RESSZ - 2) THEN StrAdd(res, s)
ENDPROC

-> centiseconds as "s.cc". Hand-built rather than StringF's \z, which
-> turned out to apply zero-padding to EVERY field in the format string,
-> not just the one it precedes.
PROC fmtsecs(dst:PTR TO CHAR, cs)
  DEF f
  f := Mod(cs, 100)
  IF f < 10
    StringF(dst, '\d.0\d', Div(cs, 100), f)
  ELSE
    StringF(dst, '\d.\d', Div(cs, 100), f)
  ENDIF
ENDPROC

PROC report(label:PTR TO CHAR, reps, scale, ds:PTR TO datestamp)
  DEF i, t, cs, rate, tot=0, totb=0, d[LEN_DATSTRING]:ARRAY OF CHAR,
      tm[LEN_DATSTRING]:ARRAY OF CHAR, sz[40]:STRING,
      flag:PTR TO CHAR, dt:datetime, secs[16]:STRING,
      nb[20]:STRING, nr[20]:STRING

  StrCopy(res, '')
  -> dat_Stamp is the FIRST field of a datetime, so the whole stamp
  -> copies straight in; setting the three fields individually would
  -> work too but this cannot get the order wrong.
  CopyMem(ds, dt, SIZEOF datestamp)
  dt.format := FORMAT_DOS
  dt.flags := 0
  dt.strday := NIL
  dt.strdate := d
  dt.strtime := tm
  d[0] := 0
  tm[0] := 0
  IF DateToStr(dt) = 0
    d[0] := "?"                     -> plain arrays: DateToStr writes a C
    d[1] := 0                       -> string into them, so they have no
    tm[0] := "?"                    -> E-string header for StrCopy to find
    tm[1] := 0
  ENDIF
  IF cols > 0
    StringF(sz, '\dx\d', cols, rows)
  ELSE
    StrCopy(sz, '?x? (console did not answer)')
  ENDIF

  addres('==========================================================\n')
  StringF(scratch, 'console : \s\n', label)
  addres(scratch)
  StringF(scratch, 'when    : \s \s\n', d, tm)
  addres(scratch)
  StringF(scratch, 'window  : \s\n', sz)
  addres(scratch)
  StringF(scratch, 'run     : reps \d, scale \d, sync \s\n',
          reps, scale, IF dosync THEN 'ON' ELSE 'off')
  addres(scratch)
  addres('  (best of the reps for each test; ? = under half a\n')
  addres('   second, too short to trust - raise SCALE)\n')
  addres('\n')
  addres('  test              bytes    secs      bytes/s\n')
  addres('  --------------------------------------------------\n')

  FOR i := 0 TO NTESTS - 1
    t := best[i]
    IF t < 0 THEN t := 0
    cs := Mul(t, 2)                 -> ticks are 20ms, so 2 centiseconds
    IF t > 0 THEN rate := Div(Mul(bytes[i], 50), t) ELSE rate := 0
    flag := IF t < SLOWTICKS THEN '?' ELSE ' '
    fmtsecs(secs, cs)
    -> numbers go through \s, not \d: a [n] field width on \d pads with
    -> ZEROES in E-VO ("000032232"), which reads like a serial number.
    -> \s pads with spaces, so the columns line up and still look like
    -> quantities.
    StringF(nb, '\d', bytes[i])
    StringF(nr, '\d', rate)
    StringF(scratch, '  \l\s[13]\r\s[9] \r\s[7]\s \r\s[10]\n',
            testname(i), nb, secs, flag, nr)
    addres(scratch)
    tot := tot + t
    totb := totb + bytes[i]
  ENDFOR

  addres('  --------------------------------------------------\n')
  cs := Mul(tot, 2)
  IF tot > 0 THEN rate := Div(Mul(totb, 50), tot) ELSE rate := 0
  fmtsecs(secs, cs)
  StringF(nb, '\d', totb)
  StringF(nr, '\d', rate)
  StringF(scratch, '  \l\s[13]\r\s[9] \r\s[7]  \r\s[10]\n',
          'TOTAL', nb, secs, nr)
  addres(scratch)
  addres('\n')

  -> the same table to the screen, so the run is readable without
  -> going to fetch the file
  WriteF('\s', res)
ENDPROC
