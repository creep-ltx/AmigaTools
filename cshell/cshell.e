-> CShell - a full-screen, keyboard-driven CLI for AmigaOS
->
-> First test slice (see todo.md): opens its own screen, draws the
-> header/footer bands loaded straight from PROGDIR:cshell-mockup,
-> and runs a REPL loop in the area between them - the prompt shows
-> the shell's own current directory, Enter runs the line through
-> PIPE: with output streamed live into the frame (cfile's console
-> engine, adapted), and the loop continues until `exit`/`quit`.
-> `cd` is a built-in (it has to be: an external process changing
-> its own current directory doesn't affect the parent); everything
-> else runs as an external command via SystemTagList.
->
-> Deliberately not in this slice (see todo.md for the rest):
-> command history, tab completion, mid-line cursor editing (typing
-> is append/backspace only - no Left/Right/Del yet), a config file,
-> and full ANSI SGR handling in command output (escape sequences
-> are swallowed, not interpreted).
->
-> Build: ecompile cshell.e   (E-VO)

OPT LARGE

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','dos/dos','dos/dosextens','dos/dostags'

CONST CPATHLEN=300, HDRMAX=6, FTRMAX=2, MOCKMAX=40, MOCKBUFSZ=4096,
      LINEMAX=200

DEF scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    ownscr=FALSE, txtpen=1,
    winw, winh, baseline, x0, top,
    cw=8, ch=8,
    ncols=80, nrows=25,
    ccol=0, crow=0,
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
PROC loadmockup()
  DEF fh, n, i=0, j, s:PTR TO CHAR
  IF (fh := Open('PROGDIR:cshell-mockup', OLDFILE)) = NIL THEN RETURN
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

PROC openfont()
  NEW ta
  ta.name := 'topaz.font'
  ta.ysize := 8
  ta.style := 0
  ta.flags := 0
  IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
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
  consorows := nrows - hdrn - ftrn
  IF consorows < 3
    hdrn := 0
    ftrn := 0
    consotop := 0
    consorows := nrows
  ENDIF
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR i := 0 TO hdrn - 1
    w := mocklinelen[i]
    IF w > ncols THEN w := ncols
    c := (ncols - w) / 2
    IF c < 0 THEN c := 0
    Move(rp, x0 + (c * cw), top + (i * ch) + baseline)
    Text(rp, mocklineptr[i], w)
  ENDFOR
  FOR i := 0 TO ftrn - 1
    w := mocklinelen[mocklines - ftrn + i]
    IF w > ncols THEN w := ncols
    c := (ncols - w) / 2
    IF c < 0 THEN c := 0
    y := nrows - ftrn + i
    Move(rp, x0 + (c * cw), top + (y * ch) + baseline)
    Text(rp, mocklineptr[mocklines - ftrn + i], w)
  ENDFOR
  SetAPen(rp, 0)
  RectFill(rp, x0, consoy(0), x0 + Mul(ncols, cw) - 1, consoy(consorows) - 1)
  ccol := 0
  crow := 0
ENDPROC

-> advance to the next console row, scrolling the console area (not
-> the whole screen) when it is full
PROC connl()
  ccol := 0
  IF crow < (consorows - 1)
    crow := crow + 1
  ELSE
    ScrollRaster(rp, 0, ch, x0, consoy(0), x0 + Mul(ncols, cw) - 1,
                 consoy(consorows) - 1)
  ENDIF
ENDPROC

-> feed raw bytes into the console area: printable runs in one
-> Text() each, LF = new line, CR = column 0, tabs to 8-stops,
-> ncols wrap. Escape sequences (ESC[.../the Amiga's $9B CSI) are
-> swallowed byte-by-byte rather than interpreted - full ANSI SGR
-> handling is a later todo item, not this slice.
PROC confeed(buf, n)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit
  s := buf
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  WHILE i < n
    c := s[i]
    IF c = 10
      connl()
      i := i + 1
    ELSEIF c = 13
      ccol := 0
      i := i + 1
    ELSEIF c = 9
      REPEAT
        Move(rp, x0 + (ccol * cw), consoy(crow) + baseline)
        Text(rp, ' ', 1)
        ccol := ccol + 1
      UNTIL (Mod(ccol, 8) = 0) OR (ccol >= ncols)
      IF ccol >= ncols THEN connl()
      i := i + 1
    ELSEIF (c >= 32) AND (c <> 127)
      j := i
      WHILE (j < n) AND (s[j] >= 32) AND (s[j] <> 127)
        j := j + 1
      ENDWHILE
      run := j - i
      WHILE run > 0
        IF ccol >= ncols THEN connl()
        fit := ncols - ccol
        IF fit > run THEN fit := run
        Move(rp, x0 + (ccol * cw), consoy(crow) + baseline)
        Text(rp, s + i, fit)
        ccol := ccol + fit
        i := i + fit
        run := run - fit
      ENDWHILE
    ELSE
      i := i + 1    -> ESC, the Amiga CSI byte, and other controls
    ENDIF
  ENDWHILE
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
-> changing its own current directory would not affect CShell's
PROC docd(path)
  DEF l, old, s:PTR TO CHAR
  IF StrLen(path) = 0 THEN RETURN
  IF (l := Lock(path, SHARED_LOCK)) = NIL
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
    StrCopy(dst, src)
  ELSE
    StrCopy(dst, '...')
    StrAdd(dst, s + found)
  ENDIF
ENDPROC

-> redraw the line being typed at (row, pcol) in the console area
PROC redrawinput(row, pcol, buf)
  DEF y
  y := consoy(row)
  SetAPen(rp, 0)
  RectFill(rp, x0 + (pcol * cw), y, x0 + Mul(ncols, cw) - 1, y + ch - 1)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0 + (pcol * cw), y + baseline)
  Text(rp, buf, StrLen(buf))
ENDPROC

-> read one line at the current console position: the prompt is
-> printed inline (not a separate fixed row), typed characters echo
-> after it. Append/backspace only in this slice - no Left/Right/Del
-> mid-line editing and no history yet (see todo.md).
PROC replinput(promptstr, buf, max)
  DEF class, code, l, prow, pcol, s:PTR TO CHAR, res=-2
  s := buf
  StrCopy(buf, '')
  prow := crow
  confeed(promptstr, StrLen(promptstr))
  pcol := ccol
  WHILE res = -2
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      IF code = 13
        res := 1
      ELSEIF code = 27
        StrCopy(buf, '')
        res := 0
      ELSEIF code = 8
        l := StrLen(buf)
        IF l > 0
          SetStr(buf, l - 1)
          redrawinput(prow, pcol, buf)
        ENDIF
      ELSEIF (code >= 32) AND (code <= 126)
        l := StrLen(buf)
        IF (l < max) AND ((pcol + l) < (ncols - 1))
          s[l] := code
          SetStr(buf, l + 1)
          redrawinput(prow, pcol, buf)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  crow := prow
  ccol := 0
  connl()
ENDPROC

-> cd is a built-in, exit/quit end the loop, everything else is an
-> external command run through PIPE:
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
  ELSE
    StrCopy(word, line, sp)
  ENDIF
  LowerStr(word)
  IF StrCmp(word, 'cd')
    IF sp = -1
      StrCopy(arg, '')
    ELSE
      MidStr(arg, line, sp + 1, ALL)
      WHILE (StrLen(arg) > 0) AND (arg[0] = 32)
        MidStr(arg, arg, 1, ALL)
      ENDWHILE
    ENDIF
    docd(arg)
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
  loadmockup()
  openui()
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
