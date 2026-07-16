-> CShell - a full-screen, keyboard-driven CLI for AmigaOS
->
-> First test slice (see todo.md): opens its own screen, draws the
-> header/footer bands loaded straight from PROGDIR:cshell-mockup,
-> and runs a REPL loop between them. The prompt (the shell's own
-> current directory) lives on a fixed input row at the bottom of
-> the console band, above the footer; output scrolls in the region
-> above it and can never push the prompt around. A finished line is
-> echoed into the scroll region so the transcript reads like a
-> classic shell session. Enter runs the line through PIPE: with
-> output streamed live into the frame (cfile's console engine,
-> adapted), and the loop continues until `exit`/`quit`.
-> `cd` is a built-in (it has to be: an external process changing
-> its own current directory doesn't affect the parent); everything
-> else runs as an external command via SystemTagList.
->
-> Deliberately not in this slice (see todo.md for the rest):
-> command history, tab completion, mid-line cursor editing (typing
-> is append/backspace only - no Left/Right/Del yet), a config file,
-> and SGR colour in command output (cursor-forward and erase-line
-> are honoured, colour codes are dropped).
->
-> Build: ecompile cshell.e   (E-VO)

OPT LARGE

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','dos/dos','dos/dosextens','dos/dostags',
       'dos/datetime','devices/inputevent','diskfont'

CONST CPATHLEN=300, HDRMAX=6, FTRMAX=2, MOCKMAX=40, MOCKBUFSZ=4096,
      LINEMAX=200,
      CMAXL=4000,     -> console scrollback, lines (like cfile)
      HISTMAX=32,     -> prompt history ring, entries
      RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F,
      LSMAX=500,     -> built-in ls: entries listed at most
      LSSLOT=136     -> ls entry slot: flag, name, aligned meta

DEF scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    ownscr=FALSE, txtpen=1,
    diskfontbase=NIL, usemk=FALSE,    -> which font won: picks the art
    winw, winh, baseline, x0, top,
    cw=8, ch=8,
    ncols=80, nrows=25,
    ccol=0, crow=0, cesc=0, cnum=0, cpend=FALSE,
    cmodel=NIL, cmline=0, viewoff=0,    -> scrollback model + view
    cnl=0,    -> connl calls counted: the pager's page arithmetic
    hist[32]:ARRAY OF LONG, htotal=0,   -> prompt history ring
    consotop=0, consorows=25, hdrn=0, ftrn=0,
    mockbuf=NIL,
    mocklineptr[40]:ARRAY OF LONG,
    mocklinelen[40]:ARRAY OF LONG,
    mocklines=0,
    cwd[300]:STRING,
    done=FALSE,
    madeenv=FALSE, madet=FALSE,
    rc=0

-> without a Startup-Sequence there is no ENV: or T:; make them the
-> standard way (RAM:Env, RAM:T) and remember what we made, same as
-> cfile - external commands may need them even when CShell itself
-> does not.
PROC haveassign(name)
  DEF dl, found=FALSE
  dl := LockDosList(LDF_ASSIGNS OR LDF_DEVICES OR LDF_VOLUMES OR LDF_READ)
  IF FindDosEntry(dl, name, LDF_ASSIGNS OR LDF_DEVICES OR LDF_VOLUMES)
    found := TRUE
  ENDIF
  UnLockDosList(LDF_ASSIGNS OR LDF_DEVICES OR LDF_VOLUMES OR LDF_READ)
ENDPROC found

PROC dirlock(dir)
  DEF lock
  IF (lock := Lock(dir, SHARED_LOCK)) = NIL
    IF lock := CreateDir(dir)
      UnLock(lock)
      lock := Lock(dir, SHARED_LOCK)
    ENDIF
  ENDIF
ENDPROC lock

PROC ensureassigns()
  DEF lock
  IF haveassign('ENV') = FALSE
    IF lock := dirlock('RAM:Env')
      IF AssignLock('ENV', lock)
        madeenv := TRUE
      ELSE
        UnLock(lock)
      ENDIF
    ENDIF
  ENDIF
  IF haveassign('T') = FALSE
    IF lock := dirlock('RAM:T')
      IF AssignLock('T', lock)
        madet := TRUE
      ELSE
        UnLock(lock)
      ENDIF
    ENDIF
  ENDIF
ENDPROC

PROC dropassigns()
  IF madeenv THEN AssignLock('ENV', NIL)
  IF madet THEN AssignLock('T', NIL)
ENDPROC

-> the frame art lives next to the binary: PROGDIR:cshell-mockup.
-> Split into lines once; the first HDRMAX become the header band,
-> the last FTRMAX the footer band, everything else is ignored (the
-> blank middle of the mockup is just a placeholder for the console
-> area, which is drawn fresh, not loaded).
-> the art matches the grid the font gives: the MicroKnight7 file
-> is 91 columns wide, the plain one 80 - so the font decides which
-> file loads (and the wide one falls back to the plain one)
PROC loadmockup()
  DEF fh=NIL, n, i=0, j, s:PTR TO CHAR
  IF usemk
    fh := Open('PROGDIR:cshell-mockup-microknight7', OLDFILE)
  ENDIF
  IF fh = NIL THEN fh := Open('PROGDIR:cshell-mockup', OLDFILE)
  IF fh = NIL THEN RETURN
  mockbuf := New(MOCKBUFSZ)
  IF mockbuf = NIL
    Close(fh)
    RETURN
  ENDIF
  n := Read(fh, mockbuf, MOCKBUFSZ - 1)
  Close(fh)
  IF n < 0 THEN n := 0
  s := mockbuf
  WHILE (i < n) AND (mocklines < MOCKMAX)
    j := i
    WHILE (j < n) AND (s[j] <> 10)
      j := j + 1
    ENDWHILE
    mocklineptr[mocklines] := s + i
    mocklinelen[mocklines] := j - i
    mocklines := mocklines + 1
    i := j + 1
  ENDWHILE
ENDPROC

-> MicroKnight7/7 when FONTS: has it, Topaz/8 when it does not -
-> hardcoded for now, the config file arrives with the handler
-> rebuild (todo.md M5). Proportional fonts are refused: the grid
-> needs fixed-width glyphs.
PROC openfont()
  NEW ta
  ta.style := 0
  ta.flags := 0
  IF diskfontbase := OpenLibrary('diskfont.library', 0)
    ta.name := 'microknight7.font'
    ta.ysize := 7
    tf := OpenDiskFont(ta)
    CloseLibrary(diskfontbase)
    diskfontbase := NIL
    IF tf
      IF tf.flags AND FPF_PROPORTIONAL
        CloseFont(tf)
        tf := NIL
      ENDIF
    ENDIF
  ENDIF
  IF tf
    usemk := TRUE
  ELSE
    ta.name := 'topaz.font'
    ta.ysize := 8
    IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
  ENDIF
  cw := tf.xsize
  ch := tf.ysize
  baseline := tf.baseline
ENDPROC

PROC openui()
  openfont()
  scr := OpenScreenTagList(NIL,
    [SA_LIKEWORKBENCH, TRUE,
     SA_DEPTH,     3,
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     SA_TITLE,     'CShell',
     SA_PUBNAME,   'CSHELL',
     TAG_DONE,     NIL])
  IF scr
    ownscr := TRUE
    win := OpenWindowTagList(NIL,
      [WA_LEFT,     0,
       WA_TOP,      0,
       WA_WIDTH,    scr.width,
       WA_HEIGHT,   scr.height,
       WA_CUSTOMSCREEN, scr,
       WA_BACKDROP,   TRUE,
       WA_BORDERLESS, TRUE,
       WA_ACTIVATE,   TRUE,
       WA_RMBTRAP,    TRUE,
       WA_IDCMP,    IDCMP_RAWKEY OR IDCMP_VANILLAKEY,
       TAG_DONE,    NIL])
  ELSE
    ownscr := FALSE
    OpenWorkBench()
    IF (scr := LockPubScreen(NIL)) = NIL THEN Throw("UI", 'no screen')
    win := OpenWindowTagList(NIL,
      [WA_LEFT,     0,
       WA_TOP,      0,
       WA_WIDTH,    scr.width,
       WA_HEIGHT,   scr.height,
       WA_PUBSCREEN, scr,
       WA_BORDERLESS, TRUE,
       WA_ACTIVATE,   TRUE,
       WA_RMBTRAP,    TRUE,
       WA_IDCMP,    IDCMP_RAWKEY OR IDCMP_VANILLAKEY,
       TAG_DONE,    NIL])
    UnlockPubScreen(NIL, scr)
    scr := NIL
  ENDIF
  IF win = NIL THEN Throw("UI", 'window')
  IF ownscr THEN PubScreenStatus(scr, 0)
  rp := win.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  txtpen := 1
  winw := win.width
  winh := win.height
  ncols := winw / cw
  IF ncols > 200 THEN ncols := 200
  nrows := winh / ch
  IF nrows > 120 THEN nrows := 120
  x0 := (winw - Mul(ncols, cw)) / 2
  IF x0 < 0 THEN x0 := 0
  top := (winh - Mul(nrows, ch)) / 2
  IF top < 0 THEN top := 0
ENDPROC

PROC closeui()
  IF win
    CloseWindow(win)
    win := NIL
  ENDIF
  IF scr
    IF ownscr
      CloseScreen(scr)
    ELSE
      UnlockPubScreen(NIL, scr)
    ENDIF
    scr := NIL
  ENDIF
  IF tf
    CloseFont(tf)
    tf := NIL
  ENDIF
ENDPROC

-> pixel Y of console row `row` (0-based, within the console band)
PROC consoy(row)
ENDPROC top + Mul(consotop + row, ch)

-> draw the header/footer bands once and clear the console area;
-> falls back to no chrome (console fills the whole screen) if the
-> screen is too short for both bands plus a usable console
PROC drawchrome()
  DEF i, w, c, y
  IF mocklines >= HDRMAX THEN hdrn := HDRMAX ELSE hdrn := 0
  IF mocklines >= (HDRMAX + FTRMAX) THEN ftrn := FTRMAX ELSE ftrn := 0
  consotop := hdrn
  -> the last row of the band belongs to the input line: the scroll
  -> region is everything above it, so output can never touch it
  consorows := nrows - hdrn - ftrn - 1
  IF consorows < 3
    hdrn := 0
    ftrn := 0
    consotop := 0
    consorows := nrows - 1
  ENDIF
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  -> each band is a block: mockup lines have trimmed trailing spaces
  -> so their lengths differ, but their column positions must stay
  -> aligned - center the band by its widest line, every line at the
  -> same left edge, never per line
  c := 0
  FOR i := 0 TO hdrn - 1
    IF mocklinelen[i] > c THEN c := mocklinelen[i]
  ENDFOR
  IF c > ncols THEN c := ncols
  c := (ncols - c) / 2
  IF c < 0 THEN c := 0
  FOR i := 0 TO hdrn - 1
    w := mocklinelen[i]
    IF (c + w) > ncols THEN w := ncols - c
    Move(rp, x0 + (c * cw), top + (i * ch) + baseline)
    Text(rp, mocklineptr[i], w)
  ENDFOR
  c := 0
  FOR i := 0 TO ftrn - 1
    IF mocklinelen[mocklines - ftrn + i] > c THEN c := mocklinelen[mocklines - ftrn + i]
  ENDFOR
  IF c > ncols THEN c := ncols
  c := (ncols - c) / 2
  IF c < 0 THEN c := 0
  FOR i := 0 TO ftrn - 1
    w := mocklinelen[mocklines - ftrn + i]
    IF (c + w) > ncols THEN w := ncols - c
    y := nrows - ftrn + i
    Move(rp, x0 + (c * cw), top + (y * ch) + baseline)
    Text(rp, mocklineptr[mocklines - ftrn + i], w)
  ENDFOR
  SetAPen(rp, 0)
  RectFill(rp, x0, consoy(0), x0 + Mul(ncols, cw) - 1, consoy(consorows) - 1)
  ccol := 0
  crow := consorows - 1    -> fill from the bottom, next to the
  cpend := FALSE           -> prompt, pushing older content up
ENDPROC

-> the scrollback model: CMAXL rendered rows in a ring, written by
-> confeed alongside the live drawing. E globals are uninitialised,
-> so the history ring's strings are made here; a failed model
-> allocation just disables scrollback, it does not kill the shell.
PROC initcon()
  DEF i
  FOR i := 0 TO HISTMAX - 1
    IF (hist[i] := String(LINEMAX)) = NIL THEN Raise("MEM")
  ENDFOR
  htotal := 0
  cmline := 0
  viewoff := 0
  cmodel := New(Mul(CMAXL, ncols))
ENDPROC

-> pointer to the model row of absolute line ln (the ring wraps)
PROC cmslot(ln)
ENDPROC cmodel + Mul(Mod(ln, CMAXL), ncols)

PROC conscroll()
  ScrollRaster(rp, 0, ch, x0, consoy(0), x0 + Mul(ncols, cw) - 1,
               consoy(consorows) - 1)
ENDPROC

-> a pending bottom-row scroll happens only when something actually
-> draws: a trailing LF in command output must not leave a blank row
-> between the output and the fixed prompt row below it
PROC conflush()
  IF cpend
    conscroll()
    cpend := FALSE
  ENDIF
ENDPROC

-> advance to the next console row; at the bottom of the scroll
-> region the scroll is deferred (see conflush), so back-to-back
-> LFs still produce their blank lines but a final LF costs nothing
PROC connl()
  DEF m:PTR TO CHAR, i
  ccol := 0
  cnl := cnl + 1
  IF cmodel    -> the model gets its new line at once, only the
    cmline := cmline + 1    -> screen scroll is deferred
    m := cmslot(cmline)
    FOR i := 0 TO ncols - 1
      m[i] := 0
    ENDFOR
  ENDIF
  IF crow < (consorows - 1)
    crow := crow + 1
  ELSEIF cpend
    conscroll()    -> the earlier LF's blank line materialises now
  ELSE
    cpend := TRUE
  ENDIF
ENDPROC

-> feed raw bytes into the console area: printable runs in one
-> Text() each, LF = new line, CR = column 0, tabs to 8-stops,
-> ncols wrap. Escape sequences - ESC[... and the Amiga's one-byte
-> $9B CSI - are consumed whole (intro, parameters, final byte):
-> swallowing only the intro byte would print the parameters as
-> garbage ("33m"). Cursor-forward (C) and erase-line (K) are
-> honoured, same as cfile's console; SGR colour (m) is dropped, a
-> later todo item. The cesc/cnum state is global because a
-> sequence can straddle two pipe reads.
PROC confeed(buf, n)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit, m:PTR TO CHAR
  s := buf
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  WHILE i < n
    c := s[i]
    IF cesc = 1    -> after ESC: '[' opens a CSI, else two-byte seq
      IF c = "["
        cesc := 2
        cnum := 0
      ELSE
        cesc := 0
      ENDIF
      i := i + 1
    ELSEIF cesc = 2    -> CSI parameters end at the final byte >= $40
      IF (c >= "0") AND (c <= "9")
        cnum := Mul(cnum, 10) + (c - 48)
        IF cnum > 999 THEN cnum := 999
      ELSEIF c = ";"
        cnum := 0    -> multi-parameter: only the last one matters here
      ELSEIF c >= $40
        -> two sequences are honoured, same as cfile's console: C
        -> (cursor forward - ANSI art's transparent gaps; swallowing
        -> it shifts everything after the gap left and merges the
        -> shapes) and K (erase to end of line). SGR colour (m) and
        -> the rest stay dropped for now.
        IF c = "C"
          IF cnum < 1 THEN cnum := 1
          ccol := ccol + cnum
          IF ccol > ncols THEN ccol := ncols
        ELSEIF c = "K"
          conflush()
          SetAPen(rp, 0)
          RectFill(rp, x0 + (ccol * cw), consoy(crow),
                   x0 + Mul(ncols, cw) - 1, consoy(crow) + ch - 1)
          SetAPen(rp, txtpen)
          IF cmodel
            m := cmslot(cmline)
            FOR j := ccol TO ncols - 1
              m[j] := 0
            ENDFOR
          ENDIF
        ENDIF
        cesc := 0
        cnum := 0
      ENDIF
      i := i + 1
    ELSEIF c = 27
      cesc := 1
      i := i + 1
    ELSEIF c = $9B
      cesc := 2
      cnum := 0
      i := i + 1
    ELSEIF c = 10
      connl()
      i := i + 1
    ELSEIF c = 13
      ccol := 0
      i := i + 1
    ELSEIF c = 9
      REPEAT
        conflush()
        Move(rp, x0 + (ccol * cw), consoy(crow) + baseline)
        Text(rp, ' ', 1)
        IF cmodel
          m := cmslot(cmline)
          m[ccol] := 32
        ENDIF
        ccol := ccol + 1
      UNTIL (Mod(ccol, 8) = 0) OR (ccol >= ncols)
      IF ccol >= ncols THEN connl()
      i := i + 1
    ELSEIF ((c >= 32) AND (c <= 126)) OR (c >= 160)
      -> printable: ASCII and Latin-1 high half; $7F-$9F are controls
      j := i
      WHILE (j < n) AND (((s[j] >= 32) AND (s[j] <= 126)) OR (s[j] >= 160))
        j := j + 1
      ENDWHILE
      run := j - i
      WHILE run > 0
        IF ccol >= ncols THEN connl()
        conflush()
        fit := ncols - ccol
        IF fit > run THEN fit := run
        Move(rp, x0 + (ccol * cw), consoy(crow) + baseline)
        Text(rp, s + i, fit)
        IF cmodel
          m := cmslot(cmline)
          CopyMem(s + i, m + ccol, fit)
        ENDIF
        ccol := ccol + fit
        i := i + fit
        run := run - fit
      ENDWHILE
    ELSE
      i := i + 1    -> other control bytes
    ENDIF
  ENDWHILE
ENDPROC

-> redraw the whole console region from the model. viewoff = lines
-> scrolled back, 0 = live. A pending bottom scroll means the model
-> already has a line the screen has not scrolled in yet, so the
-> view anchors one line earlier - what the screen shows and what
-> the model shows must be the same picture.
PROC drawconsole()
  DEF r, ln, anchor, oldest, y, i, c,
      m:PTR TO CHAR, rowbuf[204]:ARRAY OF CHAR
  IF cmodel = NIL THEN RETURN
  anchor := cmline
  IF cpend THEN anchor := anchor - 1
  oldest := cmline - CMAXL + 1
  IF oldest < 0 THEN oldest := 0
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR r := 0 TO consorows - 1
    ln := anchor - viewoff - (consorows - 1) + r
    y := consoy(r)
    IF (ln >= oldest) AND (ln <= cmline)
      m := cmslot(ln)
      FOR i := 0 TO ncols - 1
        c := m[i]
        rowbuf[i] := IF c < 32 THEN 32 ELSE c
      ENDFOR
    ELSE
      FOR i := 0 TO ncols - 1
        rowbuf[i] := 32
      ENDFOR
    ENDIF
    Move(rp, x0, y + baseline)
    Text(rp, rowbuf, ncols)
  ENDFOR
ENDPROC

-> scroll the console view by delta lines (positive = back in time)
-> and redraw; clamped to the history actually stored
PROC scrollcon(delta)
  DEF anchor, oldest, maxoff
  IF cmodel = NIL THEN RETURN
  anchor := cmline
  IF cpend THEN anchor := anchor - 1
  oldest := cmline - CMAXL + 1
  IF oldest < 0 THEN oldest := 0
  maxoff := anchor - (consorows - 1) - oldest
  IF maxoff < 0 THEN maxoff := 0
  viewoff := viewoff + delta
  IF viewoff > maxoff THEN viewoff := maxoff
  IF viewoff < 0 THEN viewoff := 0
  drawconsole()
ENDPROC

-> run one command with its output streamed live into the console
-> area, through PIPE: - cfile's console engine, minus the per-pane
-> CurrentDir() juggling: CShell's own current directory already IS
-> the shell's cwd (see docd), so a spawned command inherits it
-> without any extra Lock/CurrentDir dance.
PROC runexternal(cmd)
  DEF wout=NIL, nin=NIL, rdr=NIL, res,
      buf[260]:ARRAY OF CHAR, n, s:PTR TO CHAR
  IF (wout := Open('PIPE:cshell-con', NEWFILE)) = NIL
    s := 'cshell: PIPE: is not available\n'
    confeed(s, StrLen(s))
    RETURN
  ENDIF
  nin := Open('NIL:', OLDFILE)
  res := SystemTagList(cmd,
    [SYS_INPUT,  nin,
     SYS_OUTPUT, wout,
     SYS_ASYNCH, TRUE,
     TAG_DONE,   NIL])
  IF res = -1
    Close(wout)
    IF nin THEN Close(nin)
    s := 'cshell: cannot run the command\n'
    confeed(s, StrLen(s))
    RETURN
  ENDIF
  IF rdr := Open('PIPE:cshell-con', OLDFILE)
    n := Read(rdr, buf, 256)
    WHILE n > 0
      confeed(buf, n)
      n := Read(rdr, buf, 256)
    ENDWHILE
    Close(rdr)
  ENDIF
ENDPROC

-> refresh the `cwd` display string from the process's actual
-> current directory (a duplicate Lock('') is the standard AmigaDOS
-> way to read it without disturbing it)
PROC updatecwd()
  DEF l
  l := Lock('', SHARED_LOCK)
  IF l
    NameFromLock(l, cwd, CPATHLEN)
    UnLock(l)
  ENDIF
ENDPROC

-> cd: the one built-in that MUST be in-process - an external `cd`
-> changing its own current directory would not affect CShell's.
-> Linux reflexes are translated: "." means here, ".." climbs -
-> AmigaDOS spells a parent step as a bare "/", so ".." becomes
-> "/", "../.." becomes "//", "../x" becomes "/x".
PROC docd(path)
  DEF l, old, s:PTR TO CHAR, t[220]:STRING, i=0
  s := path
  StrCopy(t, '')
  IF (s[0] = ".") AND (s[1] = "/")
    i := 2    -> "./x" is just x
  ELSEIF (s[0] = ".") AND (s[1] = 0)
    i := 1    -> "." is here
  ENDIF
  WHILE (s[i] = ".") AND (s[i + 1] = ".") AND
        ((s[i + 2] = "/") OR (s[i + 2] = 0))
    StrAdd(t, '/')
    i := i + 2
    IF s[i] = "/" THEN i := i + 1
  ENDWHILE
  StrAdd(t, s + i)
  IF StrLen(t) = 0
    -> bare `cd` prints the current directory, the AmigaDOS way
    confeed(cwd, StrLen(cwd))
    s := '\n'
    confeed(s, 1)
    RETURN
  ENDIF
  IF (l := Lock(t, SHARED_LOCK)) = NIL
    s := 'cshell: cd: cannot find "'
    confeed(s, StrLen(s))
    confeed(path, StrLen(path))
    s := '"\n'
    confeed(s, StrLen(s))
    RETURN
  ENDIF
  old := CurrentDir(l)
  IF old THEN UnLock(old)
  updatecwd()
ENDPROC

-> cls/clear: push the visible region into the scrollback and show
-> a clean one - what the old content deserves is Ctrl+Up, not
-> destruction
PROC doclear()
  DEF r, i, m:PTR TO CHAR
  IF cmodel
    FOR r := 1 TO consorows
      cmline := cmline + 1
      m := cmslot(cmline)
      FOR i := 0 TO ncols - 1
        m[i] := 0
      ENDFOR
    ENDFOR
    ccol := 0
    cpend := FALSE
    viewoff := 0
    drawconsole()
  ELSE
    -> no model: just wipe the region
    SetAPen(rp, 0)
    RectFill(rp, x0, consoy(0), x0 + Mul(ncols, cw) - 1,
             consoy(consorows) - 1)
    ccol := 0
  ENDIF
ENDPROC

-> ls entry slots, LSSLOT bytes each: byte 0 = directory flag, the
-> name from byte 1 (NUL-terminated), then longword-aligned meta:
-> size at 112, protection at 116, datestamp days/mins/ticks at
-> 120/124/128
PROC lsname(a, b)    -> case-insensitive name compare: a before b?
  DEF pa:PTR TO CHAR, pb:PTR TO CHAR, i=0, ca, cb
  pa := a + 1
  pb := b + 1
  WHILE pa[i] AND pb[i]
    ca := pa[i]
    cb := pb[i]
    IF (ca >= "A") AND (ca <= "Z") THEN ca := ca + 32
    IF (cb >= "A") AND (cb <= "Z") THEN cb := cb + 32
    IF ca < cb THEN RETURN TRUE
    IF ca > cb THEN RETURN FALSE
    i := i + 1
  ENDWHILE
ENDPROC (pa[i] = 0) AND (pb[i] <> 0)

PROC lsbefore(a, b, mode)    -> mode 0 = name, 1 = time, 2 = size
  DEF pa:PTR TO LONG, pb:PTR TO LONG
  IF mode = 1    -> newest first, like ls -t
    pa := a + 120
    pb := b + 120
    IF pa[0] <> pb[0] THEN RETURN pa[0] > pb[0]
    IF pa[1] <> pb[1] THEN RETURN pa[1] > pb[1]
    IF pa[2] <> pb[2] THEN RETURN pa[2] > pb[2]
    RETURN lsname(a, b)
  ELSEIF mode = 2    -> biggest first, like ls -S
    pa := a + 112
    pb := b + 112
    IF pa[0] <> pb[0] THEN RETURN pa[0] > pb[0]
    RETURN lsname(a, b)
  ENDIF
ENDPROC lsname(a, b)

-> "hsparwed" the way List shows it: hspa lit when the bit is set,
-> rwed lit when the bit is CLEAR (set means protected against)
PROC lsflags(prot, out:PTR TO CHAR)
  out[0] := IF prot AND 128 THEN "h" ELSE "-"
  out[1] := IF prot AND 64  THEN "s" ELSE "-"
  out[2] := IF prot AND 32  THEN "p" ELSE "-"
  out[3] := IF prot AND 16  THEN "a" ELSE "-"
  out[4] := IF prot AND 8   THEN "-" ELSE "r"
  out[5] := IF prot AND 4   THEN "-" ELSE "w"
  out[6] := IF prot AND 2   THEN "-" ELSE "e"
  out[7] := IF prot AND 1   THEN "-" ELSE "d"
  out[8] := 0
ENDPROC

-> ls: a Linux-style listing as a built-in - the current directory
-> (or a given path), names sorted case-insensitively, multi-column
-> filled down-then-across the way ls does it, directories marked
-> with a trailing "/". AmigaDOS has `dir`, but fingers have muscle
-> memory. Options, combinable (ls -lt): -l long format (hsparwed
-> flags, size, date, name), -1 one per line, -t newest first,
-> -S/-s biggest first, -r reversed.
PROC dols(arg)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, pool=NIL,
      idx=NIL:PTR TO LONG, cnt=0, nm:PTR TO CHAR, fn:PTR TO CHAR,
      i, j, t, l, w, maxw=0, colw, cols, rows, r, c, ok, bef,
      line[240]:STRING, s:PTR TO CHAR, a:PTR TO CHAR,
      optl=FALSE, opt1=FALSE, optr=FALSE, mode=0,
      p:PTR TO LONG, q:PTR TO LONG, dt=NIL:PTR TO datetime,
      fl[10]:ARRAY OF CHAR, num[16]:STRING,
      bufd[20]:ARRAY OF CHAR, buft[20]:ARRAY OF CHAR,
      path[210]:STRING
  -> peel leading option tokens off the argument; the rest is a path
  StrCopy(path, arg)
  a := path
  WHILE (a[0] = "-") AND a[1]
    i := 1
    WHILE a[i] AND (a[i] <> 32)
      IF a[i] = "l"
        optl := TRUE
      ELSEIF a[i] = "1"
        opt1 := TRUE
      ELSEIF a[i] = "t"
        mode := 1
      ELSEIF (a[i] = "S") OR (a[i] = "s")
        mode := 2
      ELSEIF a[i] = "r"
        optr := TRUE
      ELSE
        s := 'cshell: ls: unknown option (knows l 1 t S r)\n'
        confeed(s, StrLen(s))
        RETURN
      ENDIF
      i := i + 1
    ENDWHILE
    WHILE a[i] = 32
      i := i + 1
    ENDWHILE
    MidStr(path, path, i, ALL)
    a := path
  ENDWHILE
  lock := Lock(IF StrLen(path) = 0 THEN '' ELSE path, SHARED_LOCK)
  IF lock = NIL
    s := 'cshell: ls: cannot find "'
    confeed(s, StrLen(s))
    confeed(path, StrLen(path))
    s := '"\n'
    confeed(s, StrLen(s))
    RETURN
  ENDIF
  NEW fib
  pool := New(Mul(LSMAX, LSSLOT))
  idx := New(Mul(LSMAX, 4))
  IF (pool = NIL) OR (idx = NIL)
    UnLock(lock)
    IF pool THEN Dispose(pool)
    IF idx THEN Dispose(idx)
    END fib
    s := 'cshell: ls: out of memory\n'
    confeed(s, StrLen(s))
    RETURN
  ENDIF
  IF Examine(lock, fib)
    IF fib.direntrytype > 0
      WHILE ExNext(lock, fib) AND (cnt < LSMAX)
        nm := pool + Mul(cnt, LSSLOT)
        nm[0] := IF fib.direntrytype > 0 THEN 1 ELSE 0
        fn := fib.filename
        j := 0
        WHILE fn[j] AND (j < 107)
          nm[j + 1] := fn[j]
          j := j + 1
        ENDWHILE
        nm[j + 1] := 0
        p := nm + 112
        p[0] := IF fib.direntrytype > 0 THEN 0 ELSE fib.size
        p[1] := fib.protection
        q := fib.datestamp
        p[2] := q[0]    -> days
        p[3] := q[1]    -> mins
        p[4] := q[2]    -> ticks
        idx[cnt] := nm
        cnt := cnt + 1
      ENDWHILE
    ELSE
      -> ls on a file prints the name, the ls way
      fn := fib.filename
      confeed(fn, StrLen(fn))
      s := '\n'
      confeed(s, 1)
    ENDIF
  ENDIF
  UnLock(lock)
  END fib
  IF cnt > 0
    -> insertion sort (the flag keeps the loop condition free of
    -> derefs: E AND does not short-circuit)
    FOR i := 1 TO cnt - 1
      t := idx[i]
      j := i - 1
      ok := TRUE
      WHILE (j >= 0) AND ok
        bef := lsbefore(t, idx[j], mode)
        IF optr THEN bef := (bef = FALSE)
        IF bef
          idx[j + 1] := idx[j]
          j := j - 1
        ELSE
          ok := FALSE
        ENDIF
      ENDWHILE
      idx[j + 1] := t
    ENDFOR
    IF optl
      -> long format: hsparwed  size  DD-MMM-YY HH:MM  name
      NEW dt
      FOR i := 0 TO cnt - 1
        nm := idx[i]
        p := nm + 112
        lsflags(p[1], fl)
        StrCopy(line, fl)
        StrAdd(line, '  ')
        IF nm[0]
          StrCopy(num, '(dir)')
        ELSE
          StringF(num, '\d', p[0])
        ENDIF
        FOR j := StrLen(num) TO 8    -> right-align in 9
          StrAdd(line, ' ')
        ENDFOR
        StrAdd(line, num)
        StrAdd(line, '  ')
        q := dt.stamp
        q[0] := p[2]
        q[1] := p[3]
        q[2] := p[4]
        dt.format := FORMAT_DOS
        dt.flags := 0
        dt.strday := NIL
        dt.strdate := bufd
        dt.strtime := buft
        IF DateToStr(dt)
          confeed(line, StrLen(line))
          confeed(bufd, StrLen(bufd))
          s := ' '
          confeed(s, 1)
          confeed(buft, 5)    -> HH:MM, the seconds stay private
          StrCopy(line, '  ')
        ELSE
          StrAdd(line, '  ')
          confeed(line, StrLen(line))
          StrCopy(line, '')
        ENDIF
        StrAdd(line, nm + 1)
        IF nm[0] THEN StrAdd(line, '/')
        confeed(line, StrLen(line))
        connl()
      ENDFOR
      END dt
    ELSE
      -> short format: multi-column, filled down then across; -1
      -> forces one per line
      FOR i := 0 TO cnt - 1
        nm := idx[i]
        w := StrLen(nm + 1) + nm[0]
        IF w > maxw THEN maxw := w
      ENDFOR
      colw := maxw + 2
      cols := IF opt1 THEN 1 ELSE (ncols / colw)
      IF cols < 1 THEN cols := 1
      rows := (cnt + cols - 1) / cols
      FOR r := 0 TO rows - 1
        StrCopy(line, '')
        FOR c := 0 TO cols - 1
          i := Mul(c, rows) + r
          IF i < cnt
            nm := idx[i]
            StrAdd(line, nm + 1)
            w := StrLen(nm + 1)
            IF nm[0]
              StrAdd(line, '/')
              w := w + 1
            ENDIF
            IF (Mul(c + 1, rows) + r) < cnt    -> pad unless last column
              WHILE w < colw
                StrAdd(line, ' ')
                w := w + 1
              ENDWHILE
            ENDIF
          ENDIF
        ENDFOR
        confeed(line, StrLen(line))
        connl()
      ENDFOR
    ENDIF
  ENDIF
  Dispose(pool)
  Dispose(idx)
ENDPROC

-> one line of built-in output
PROC hline(s)
  confeed(s, StrLen(s))
  connl()
ENDPROC

-> history: the prompt history ring, numbered, oldest first
PROC dohistory()
  DEF i, avail, n, w, line[220]:STRING, num[12]:STRING
  avail := htotal
  IF avail > HISTMAX THEN avail := HISTMAX
  FOR i := avail - 1 TO 0 STEP -1
    StringF(num, '\d', htotal - i)
    StrCopy(line, '')
    FOR w := StrLen(num) TO 3    -> right-align in 4
      StrAdd(line, ' ')
    ENDFOR
    StrAdd(line, num)
    StrAdd(line, '  ')
    StrAdd(line, hist[Mod(htotal - 1 - i, HISTMAX)])
    hline(line)
  ENDFOR
ENDPROC

PROC dohelp()
  hline('CShell built-ins:')
  hline('  cd [path]      change directory (.. climbs; bare cd prints it)')
  hline('  ls [-l1tSr]    list: -l long, -1 one/line, -t newest, -S size, -r rev')
  hline('  cls / clear    fresh page (the old one stays in the scrollback)')
  hline('  history        the prompt history, numbered')
  hline('  df             volumes: size, used, free')
  hline('  less <file>    page through a text file')
  hline('  cat <file>     pour out a text file, no pausing')
  hline('  exit / quit    leave')
  hline('Keys:')
  hline('  Up/Down        prompt history')
  hline('  Ctrl+Up/Down   scroll the output by line - Shift: by page')
  hline('  Left/Right     cursor (Ctrl: word jump, Shift: line ends)')
  hline('  Backspace/Del  delete before/under the cursor')
  hline('  Esc            clear the line')
  hline('Anything else runs as an AmigaDOS command.')
ENDPROC

-> df: every mounted volume with size/used/free (and how full);
-> names are collected first - Lock() must not run while the
-> DosList is held
PROC dodf()
  DEF head, dl:PTR TO doslist, s:PTR TO CHAR, cnt=0, i, j, len, w,
      pool[1200]:ARRAY OF CHAR, nm:PTR TO CHAR, lock,
      id=NIL:PTR TO infodata, line[120]:STRING, num[20]:STRING,
      kb, mb10, v
  head := LockDosList(LDF_VOLUMES OR LDF_READ)
  dl := NextDosEntry(head, LDF_VOLUMES)
  WHILE dl AND (cnt < 30)
    s := Shl(dl.name, 2)
    len := s[0]
    IF len > 30 THEN len := 30
    nm := pool + Mul(cnt, 36)
    FOR i := 0 TO len - 1
      nm[i] := s[i + 1]
    ENDFOR
    nm[len] := ":"
    nm[len + 1] := 0
    cnt := cnt + 1
    dl := NextDosEntry(dl, LDF_VOLUMES)
  ENDWHILE
  UnLockDosList(LDF_VOLUMES OR LDF_READ)
  NEW id
  hline('Volume                Size      Used      Free  Full')
  FOR j := 0 TO cnt - 1
    nm := pool + Mul(j, 36)
    StrCopy(line, '')
    StrAdd(line, nm)
    w := StrLen(nm)
    WHILE w < 16
      StrAdd(line, ' ')
      w := w + 1
    ENDWHILE
    IF lock := Lock(nm, SHARED_LOCK)
      IF Info(lock, id)
        FOR i := 0 TO 2
          IF i = 0
            v := id.numblocks
          ELSEIF i = 1
            v := id.numblocksused
          ELSE
            v := id.numblocks - id.numblocksused
          ENDIF
          -> KB = blocks * (bpb/256) / 4: stays 32-bit safe
          kb := Mul(v, Shr(id.bytesperblock, 8)) / 4
          mb10 := Mul(kb, 10) / 1024
          StringF(num, '\d.\dM', mb10 / 10, Mod(mb10, 10))
          FOR w := StrLen(num) TO 8    -> right-align in 9
            StrAdd(line, ' ')
          ENDFOR
          StrAdd(line, num)
          StrAdd(line, ' ')
        ENDFOR
        IF id.numblocks > 0
          StringF(num, '\d%', Mul(id.numblocksused, 100) / id.numblocks)
          FOR w := StrLen(num) TO 3
            StrAdd(line, ' ')
          ENDFOR
          StrAdd(line, num)
        ENDIF
      ELSE
        StrAdd(line, '  (no info)')
      ENDIF
      UnLock(lock)
    ELSE
      StrAdd(line, '  (offline)')
    ENDIF
    hline(line)
  ENDFOR
  END id
ENDPROC

-> the pager's pause: a question on the input row. Returns how many
-> lines may pass before the next pause: a page, one (Enter), or
-> none - quit (Esc/q)
PROC morepause()
  DEF class, code, r=-1
  redrawinput(0, '-- More: Space = page, Enter = line, Esc = quit --', -1)
  WHILE r = -1
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      IF code = 32
        r := consorows - 1
      ELSEIF code = 13
        r := 1
      ELSEIF (code = 27) OR (code = "q") OR (code = "Q")
        r := 0
      ENDIF
    ENDIF
  ENDWHILE
  redrawinput(0, '', -1)
ENDPROC r

-> cat and less: show a text file. The bytes go through confeed, so
-> tabs, wrapping and escape codes behave exactly like command
-> output. less pauses per page - connl's counter (wraps included)
-> does the page math - cat just pours. The name `more` is left
-> alone: that is a standard Amiga command in the path.
PROC dopage(arg, pause)
  DEF fh=NIL, buf=NIL, n, i, st, s:PTR TO CHAR, act, stop=FALSE
  IF StrLen(arg) = 0
    IF pause
      hline('cshell: less: which file?')
    ELSE
      hline('cshell: cat: which file?')
    ENDIF
    RETURN
  ENDIF
  IF (fh := Open(arg, OLDFILE)) = NIL
    IF pause
      s := 'cshell: less: cannot find "'
    ELSE
      s := 'cshell: cat: cannot find "'
    ENDIF
    confeed(s, StrLen(s))
    confeed(arg, StrLen(arg))
    s := '"'
    confeed(s, 1)
    connl()
    RETURN
  ENDIF
  IF (buf := New(8192)) = NIL
    Close(fh)
    hline('cshell: out of memory')
    RETURN
  ENDIF
  cnl := 0
  n := Read(fh, buf, 8192)
  WHILE (n > 0) AND (stop = FALSE)
    s := buf
    st := 0
    i := 0
    WHILE (i < n) AND (stop = FALSE)
      IF s[i] = 10
        confeed(s + st, i - st + 1)    -> the line, LF included
        st := i + 1
        IF pause AND (cnl >= (consorows - 1))
          act := morepause()
          IF act = 0
            stop := TRUE
          ELSE
            cnl := (consorows - 1) - act
          ENDIF
        ENDIF
      ENDIF
      i := i + 1
    ENDWHILE
    IF (st < n) AND (stop = FALSE) THEN confeed(s + st, n - st)
    n := IF stop THEN 0 ELSE Read(fh, buf, 8192)
  ENDWHILE
  IF ccol > 0 THEN connl()    -> no trailing LF: leave a clean line
  Close(fh)
  Dispose(buf)
ENDPROC

-> the mockup's prompt shape: DH0:path >, long paths truncated to
-> their last two components with a leading "..." rather than
-> wrapping (DH0:.../cfile/testfolder >)
PROC trimpath(dst, src, maxw)
  DEF l, i, n=0, s:PTR TO CHAR, found=-1
  s := src
  l := StrLen(src)
  IF l <= maxw
    StrCopy(dst, src)
    RETURN
  ENDIF
  i := l - 1
  WHILE (i >= 0) AND (found = -1)
    IF s[i] = "/"
      n := n + 1
      IF n = 2 THEN found := i
    ENDIF
    i := i - 1
  ENDWHILE
  IF found = -1
    -> fewer than two slashes but still too long (a long volume or
    -> single deep drawer): keep the tail, chars rather than
    -> components, so the prompt can never wrap the input row
    StrCopy(dst, '...')
    StrAdd(dst, s + l - (maxw - 3))
  ELSE
    StrCopy(dst, '...')
    StrAdd(dst, s + found)
  ENDIF
ENDPROC

-> pixel Y of the fixed input row: the last row of the console band,
-> directly under the scroll region, directly above the footer
PROC inputy()
ENDPROC top + Mul(consotop + consorows, ch)

-> redraw the line being typed at pcol on the fixed input row; the
-> cell at cpos is drawn inverted - the blip - so the cursor is
-> visible for mid-line editing. cpos = -1 draws no cursor (the
-> row while a command runs).
PROC redrawinput(pcol, buf, cpos)
  DEF y, s:PTR TO CHAR, l, cch[2]:ARRAY OF CHAR
  y := inputy()
  SetAPen(rp, 0)
  RectFill(rp, x0 + (pcol * cw), y, x0 + Mul(ncols, cw) - 1, y + ch - 1)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0 + (pcol * cw), y + baseline)
  Text(rp, buf, StrLen(buf))
  IF cpos >= 0
    s := buf
    l := StrLen(buf)
    cch[0] := IF cpos < l THEN s[cpos] ELSE 32
    SetAPen(rp, 0)
    SetBPen(rp, txtpen)
    Move(rp, x0 + ((pcol + cpos) * cw), y + baseline)
    Text(rp, cch, 1)
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
  ENDIF
ENDPROC

-> read one line on the fixed input row: the prompt and the typing
-> live there, so command output can never push the prompt around,
-> wrap it, or land mid-line after it. On Enter the prompt and the
-> line are echoed into the scroll region, so the transcript still
-> reads like a classic shell session (and like the mockup).
-> Append/backspace only in this slice - no Left/Right/Del mid-line
-> editing and no history yet (see todo.md).
-> put history entry idx (0 = newest) into buf, cut to fit the row
PROC histload(buf, idx, pcol)
  StrCopy(buf, hist[Mod(htotal - 1 - idx, HISTMAX)])
  WHILE (pcol + StrLen(buf)) >= (ncols - 1)
    SetStr(buf, StrLen(buf) - 1)
  ENDWHILE
ENDPROC

PROC replinput(promptstr, buf, max)
  DEF class, code, qual, l, j, pcol, y, s:PTR TO CHAR, res=-2,
      hpos=-1, avail, cpos=0, stash[204]:STRING
  s := buf
  StrCopy(buf, '')
  y := inputy()
  SetAPen(rp, 0)
  RectFill(rp, x0, y, x0 + Mul(ncols, cw) - 1, y + ch - 1)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0, y + baseline)
  Text(rp, promptstr, StrLen(promptstr))
  pcol := StrLen(promptstr)
  redrawinput(pcol, buf, cpos)    -> the blip stands from the start
  WHILE res = -2
    class := WaitIMessage(win)
    code := MsgCode()
    qual := MsgQualifier()
    IF class = IDCMP_RAWKEY
      -> plain Up/Down walk the prompt history and NEVER move a
      -> scrolled console view; Ctrl = line and Shift = page scroll
      -> the output history, independent of what the input line does
      IF code = RK_UP
        IF qual AND IEQUALIFIER_CONTROL
          scrollcon(1)
        ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
          scrollcon(consorows - 1)
        ELSE
          avail := htotal
          IF avail > HISTMAX THEN avail := HISTMAX
          IF hpos < (avail - 1)
            IF hpos = -1 THEN StrCopy(stash, buf)  -> the half-typed line
            hpos := hpos + 1
            histload(buf, hpos, pcol)
            cpos := StrLen(buf)
            redrawinput(pcol, buf, cpos)
          ENDIF
        ENDIF
      ELSEIF code = RK_DOWN
        IF qual AND IEQUALIFIER_CONTROL
          scrollcon(-1)
        ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
          scrollcon(-(consorows - 1))
        ELSEIF hpos >= 0
          hpos := hpos - 1
          IF hpos = -1
            StrCopy(buf, stash)    -> back to the half-typed line
          ELSE
            histload(buf, hpos, pcol)
          ENDIF
          cpos := StrLen(buf)
          redrawinput(pcol, buf, cpos)
        ENDIF
      ELSEIF code = RK_LEFT
        -> Shift = all the way (the house rule), Ctrl = word jump
        IF qual AND IEQUALIFIER_CONTROL
          WHILE (cpos > 0) AND (s[cpos - 1] = 32)
            cpos := cpos - 1
          ENDWHILE
          WHILE (cpos > 0) AND (s[cpos - 1] <> 32)
            cpos := cpos - 1
          ENDWHILE
        ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
          cpos := 0
        ELSEIF cpos > 0
          cpos := cpos - 1
        ENDIF
        redrawinput(pcol, buf, cpos)
      ELSEIF code = RK_RIGHT
        IF qual AND IEQUALIFIER_CONTROL
          l := StrLen(buf)
          WHILE (cpos < l) AND (s[cpos] <> 32)
            cpos := cpos + 1
          ENDWHILE
          WHILE (cpos < l) AND (s[cpos] = 32)
            cpos := cpos + 1
          ENDWHILE
        ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
          cpos := StrLen(buf)
        ELSEIF cpos < StrLen(buf)
          cpos := cpos + 1
        ENDIF
        redrawinput(pcol, buf, cpos)
      ENDIF
    ELSEIF class = IDCMP_VANILLAKEY
      IF code = 13
        res := 1
      ELSEIF code = 27
        StrCopy(buf, '')
        cpos := 0
        redrawinput(pcol, buf, cpos)    -> erase the abandoned line
        res := 0
      ELSEIF code = 8
        -> Backspace: delete before the cursor, close the gap
        l := StrLen(buf)
        IF cpos > 0
          FOR j := cpos TO l - 1
            s[j - 1] := s[j]
          ENDFOR
          SetStr(buf, l - 1)
          cpos := cpos - 1
          redrawinput(pcol, buf, cpos)
        ENDIF
      ELSEIF code = 127
        -> Del: delete under the cursor
        l := StrLen(buf)
        IF cpos < l
          FOR j := cpos + 1 TO l - 1
            s[j - 1] := s[j]
          ENDFOR
          SetStr(buf, l - 1)
          redrawinput(pcol, buf, cpos)
        ENDIF
      ELSEIF ((code >= 32) AND (code <= 126)) OR (code >= 160)
        -> Latin-1 high half too: Swedish keymaps type beyond ASCII;
        -> typed characters insert at the cursor, not just append
        l := StrLen(buf)
        IF (l < max) AND ((pcol + l) < (ncols - 1))
          FOR j := l - 1 TO cpos STEP -1
            s[j + 1] := s[j]
          ENDFOR
          s[cpos] := code
          SetStr(buf, l + 1)
          cpos := cpos + 1
          redrawinput(pcol, buf, cpos)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  IF res = 1
    -> a running command means the live output position: leave any
    -> scrolled-back view before anything new draws
    IF viewoff > 0
      viewoff := 0
      drawconsole()
    ENDIF
    -> commit: the finished line joins the transcript in the scroll
    -> region - on a fresh line even after output with no final LF
    IF ccol > 0 THEN connl()
    confeed(promptstr, StrLen(promptstr))
    confeed(buf, StrLen(buf))
    connl()
    -> remember the line: newest first, consecutive repeats once
    IF StrLen(buf) > 0
      IF (htotal = 0) OR
         (StrCmp(hist[Mod(htotal - 1, HISTMAX)], buf) = FALSE)
        StrCopy(hist[Mod(htotal, HISTMAX)], buf)
        htotal := htotal + 1
      ENDIF
    ENDIF
  ENDIF
  -> the prompt stays visible while the command runs - only the
  -> typed line is wiped, buf itself still belongs to the caller
  -> (keys pressed meanwhile queue up and reach the next input
  -> line, so the standing prompt is honest); no blip either -
  -> the cursor means "typing lands here", and right now it won't
  redrawinput(pcol, '', -1)
ENDPROC

-> cd and ls are built-ins (cd HAS to be - an external process
-> changing its own current directory does not affect the parent),
-> exit/quit end the loop, everything else is an external command
-> run through PIPE:
PROC dispatch(line)
  DEF s:PTR TO CHAR, l, i, sp=-1, word[200]:STRING, arg[210]:STRING
  s := line
  l := StrLen(line)
  IF l = 0 THEN RETURN
  FOR i := 0 TO l - 1
    IF (s[i] = 32) AND (sp = -1) THEN sp := i
  ENDFOR
  IF sp = -1
    StrCopy(word, line)
    StrCopy(arg, '')
  ELSE
    StrCopy(word, line, sp)
    MidStr(arg, line, sp + 1, ALL)
    WHILE (StrLen(arg) > 0) AND (arg[0] = 32)
      MidStr(arg, arg, 1, ALL)
    ENDWHILE
  ENDIF
  LowerStr(word)
  IF StrCmp(word, 'cd')
    docd(arg)
  ELSEIF StrCmp(word, 'ls')
    dols(arg)
  ELSEIF StrCmp(word, 'cls') OR StrCmp(word, 'clear')
    doclear()
  ELSEIF StrCmp(word, 'history')
    dohistory()
  ELSEIF StrCmp(word, 'help')
    dohelp()
  ELSEIF StrCmp(word, 'df')
    dodf()
  ELSEIF StrCmp(word, 'less')
    dopage(arg, TRUE)
  ELSEIF StrCmp(word, 'cat')
    dopage(arg, FALSE)
  ELSEIF StrCmp(word, 'exit') OR StrCmp(word, 'quit')
    done := TRUE
  ELSE
    runexternal(line)
  ENDIF
ENDPROC

PROC mainloop()
  DEF line[200]:STRING, prompt[220]:STRING, pfx[300]:STRING
  WHILE done = FALSE
    trimpath(pfx, cwd, 40)
    StringF(prompt, '\s > ', pfx)
    replinput(prompt, line, LINEMAX)
    dispatch(line)
  ENDWHILE
ENDPROC

PROC main() HANDLE
  ensureassigns()
  openui()
  loadmockup()    -> after openui: the font decides which art loads
  initcon()       -> after openui: the model rows are ncols wide
  updatecwd()
  drawchrome()
  mainloop()
  closeui()
  dropassigns()
EXCEPT DO
  closeui()
  SELECT exception
    CASE "UI"
      WriteF('CShell: cannot open UI (\s)\n', exceptioninfo)
      rc := 20
    CASE "MEM"
      WriteF('CShell: out of memory\n')
      rc := 20
  ENDSELECT
  CleanUp(rc)
ENDPROC

version: CHAR '$VER: CShell 0.1 (16.7.26) E build',0
