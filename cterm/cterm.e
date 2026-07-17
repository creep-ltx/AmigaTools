-> CTerm - a real AmigaDOS shell inside the LTX frame
->
-> The whole trick, proven by contest.e and the Ed-in-the-frame
-> boot test: open a screen, draw the mockup's header/footer bands
-> on a backdrop window, open a BORDERLESS window covering the band
-> between them, and hand that window to the standard console
-> handler with CON:'s WINDOW option ("use window pointed to by
-> addr" - it never opens a window of its own, so there is no
-> chrome to fight). Execute('', console, NIL) then starts a real,
-> interactive UserShell in it: real stdin, raw mode, More, Ed,
-> menus, keymaps - the genuine article, zero protocol code.
->
-> The first CTerm (an application rendering its own PIPE:-fed
-> console - see git history) was the proving ground; its ceiling
-> was that spawned commands could never read input. This one has
-> no ceiling: the console is the OS's own.
->
-> EndShell (or EndCLI) ends the shell and CTerm closes behind it.
->
-> Arguments (0.3): CONSOLE picks the handler the frame window is
-> handed to - CON: (default), CCON:, KCON:, VNC:, any mounted
-> console device; it is only a prefix on the open spec, so there
-> is no list to maintain. FROM names a script the shell executes
-> before going interactive (aliases set there stick - same CLI
-> process, the NewShell FROM mechanism):
->
->   CTerm CCON: FROM S:Shell-Startup
->
-> Font: MicroKnight7/7 when FONTS: has it (with the 91-column
-> mockup), Topaz/8 otherwise (with the 80-column one). The screen
-> carries the font (SA_FONT), so the console inherits it.
->
-> Build: ecompile cterm.e   (E-VO)

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','dos/dos','dos/dosextens','dos/dostags',
       'diskfont'

CONST HDRMAX=6, FTRMAX=2, MOCKMAX=40, MOCKBUFSZ=4096

DEF scr=NIL:PTR TO screen,
    artwin=NIL:PTR TO window,
    conwin=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    diskfontbase=NIL, usemk=FALSE,
    cw=8, ch=8, baseline,
    ncols=80, nrows=25, x0=0, top=0,
    hdrn=0, ftrn=0,
    mockbuf=NIL,
    mocklineptr[40]:ARRAY OF LONG,
    mocklinelen[40]:ARRAY OF LONG,
    mocklines=0,
    madeenv=FALSE, madet=FALSE,
    rc=0

-> without a Startup-Sequence there is no ENV: or T:; make them the
-> standard way (RAM:Env, RAM:T) and remember what we made - the
-> shell and its commands need them even when CTerm does not.
-> Existence is asked of the DosList: a Lock on an unassigned name
-> would put up a "please insert volume" requester.
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

-> MicroKnight7/7 when FONTS: has it, Topaz/8 when it does not -
-> hardcoded for now (a config file is future work). Proportional
-> fonts are refused: the art needs fixed-width glyphs.
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
    ta.name := 'microknight7.font'
    ta.ysize := 7
  ELSE
    ta.name := 'topaz.font'
    ta.ysize := 8
    IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
  ENDIF
  cw := tf.xsize
  ch := tf.ysize
  baseline := tf.baseline
ENDPROC

-> the art matches the grid the font gives: the MicroKnight7 file
-> is 91 columns wide, the plain one 80 - the font decides which
-> file loads (and the wide one falls back to the plain one). The
-> first HDRMAX lines become the header band, the last FTRMAX the
-> footer; the blank middle of the mockup is the console's.
PROC loadmockup()
  DEF fh=NIL, n, i=0, j, s:PTR TO CHAR
  IF usemk
    fh := Open('PROGDIR:cterm-mockup-microknight7', OLDFILE)
  ENDIF
  IF fh = NIL THEN fh := Open('PROGDIR:cterm-mockup', OLDFILE)
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

-> the bands, drawn once on the backdrop art window. Each band is a
-> block: mockup lines have trimmed trailing spaces so their lengths
-> differ, but their column positions must stay aligned - center the
-> band by its widest line, every line at the same left edge.
PROC drawchrome()
  DEF rp:PTR TO rastport, i, w, c, y
  IF mocklines >= HDRMAX THEN hdrn := HDRMAX ELSE hdrn := 0
  IF mocklines >= (HDRMAX + FTRMAX) THEN ftrn := FTRMAX ELSE ftrn := 0
  IF (nrows - hdrn - ftrn) < 5    -> no room for a shell: no chrome
    hdrn := 0
    ftrn := 0
  ENDIF
  rp := artwin.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  SetAPen(rp, 1)
  SetBPen(rp, 0)
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
ENDPROC

PROC openui()
  openfont()
  -> the screen carries the font: the console handler inherits it
  scr := OpenScreenTagList(NIL,
    [SA_LIKEWORKBENCH, TRUE,
     SA_DEPTH,     3,
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     SA_TITLE,     'CTerm',
     SA_PUBNAME,   'CTERM',
     SA_FONT,      ta,
     TAG_DONE,     NIL])
  IF scr = NIL THEN Throw("UI", 'screen')
  artwin := OpenWindowTagList(NIL,
    [WA_LEFT,     0,
     WA_TOP,      0,
     WA_WIDTH,    scr.width,
     WA_HEIGHT,   scr.height,
     WA_CUSTOMSCREEN, scr,
     WA_BACKDROP,   TRUE,
     WA_BORDERLESS, TRUE,
     WA_RMBTRAP,    TRUE,
     TAG_DONE,    NIL])
  IF artwin = NIL THEN Throw("UI", 'art window')
  PubScreenStatus(scr, 0)
  ncols := scr.width / cw
  IF ncols > 200 THEN ncols := 200
  nrows := scr.height / ch
  IF nrows > 120 THEN nrows := 120
  x0 := (scr.width - Mul(ncols, cw)) / 2
  IF x0 < 0 THEN x0 := 0
  top := (scr.height - Mul(nrows, ch)) / 2
  IF top < 0 THEN top := 0
ENDPROC

PROC closeui()
  IF conwin
    CloseWindow(conwin)
    conwin := NIL
  ENDIF
  IF artwin
    CloseWindow(artwin)
    artwin := NIL
  ENDIF
  IF scr
    CloseScreen(scr)
    scr := NIL
  ENDIF
  IF tf
    CloseFont(tf)
    tf := NIL
  ENDIF
ENDPROC

PROC main() HANDLE
  DEF fh=NIL, spec[160]:STRING, rdargs=NIL, args[2]:ARRAY OF LONG,
      dev[44]:STRING, cmd[280]:STRING, s:PTR TO CHAR, l
  -> CONSOLE = the handler device the frame is handed to; FROM = a
  -> startup script the shell runs before the first prompt. Copies
  -> are taken before FreeArgs; the e-strings clamp silently.
  args[0] := NIL
  args[1] := NIL
  IF (rdargs := ReadArgs('CONSOLE,FROM/K', args, NIL)) = NIL
    Throw("ARG", NIL)
  ENDIF
  StrCopy(dev, 'CON:')
  IF args[0]
    s := args[0]
    StrCopy(dev, s)
    l := StrLen(dev)
    IF l > 0
      IF dev[l - 1] <> ":" THEN StrAdd(dev, ':')
    ENDIF
  ENDIF
  StrCopy(cmd, '')
  IF args[1]
    s := args[1]
    StringF(cmd, 'EXECUTE "\s"', s)
  ENDIF
  FreeArgs(rdargs)
  rdargs := NIL
  ensureassigns()
  openui()
  loadmockup()
  drawchrome()
  -> the console's window: borderless, covering exactly the grid
  -> rows between the bands
  conwin := OpenWindowTagList(NIL,
    [WA_LEFT,     x0,
     WA_TOP,      top + Mul(hdrn, ch),
     WA_WIDTH,    Mul(ncols, cw),
     WA_HEIGHT,   Mul(nrows - hdrn - ftrn, ch),
     WA_CUSTOMSCREEN, scr,
     WA_BORDERLESS, TRUE,
     WA_ACTIVATE,   TRUE,
     TAG_DONE,    NIL])
  IF conwin = NIL THEN Throw("UI", 'console window')
  SetFont(conwin.rport, tf)
  -> the whole architecture is this one line:
  StringF(spec, '\s0/0/0/0/CTerm/WINDOW0x\h', dev, conwin)
  IF fh := Open(spec, NEWFILE)
    -> a real, interactive UserShell; returns at EndShell/EndCLI.
    -> Execute with output NIL is the boot-proven form of this
    -> call (a SystemTagList/SYS_USERSHELL variant crashed bootless
    -> starts). The command string runs the FROM script (if any)
    -> before the first prompt. One quirk: the new shell's banner
    -> goes to CTerm's own Output(), which from a boot script is
    -> the boot shell's lazy console - launch as `cterm >NIL:
    -> <NIL:` there, and the banner has nowhere chrome-producing
    -> to land.
    Execute(cmd, fh, NIL)
    Close(fh)
  ELSE
    rc := 10
  ENDIF
  closeui()
  dropassigns()
  IF rc = 10 THEN WriteF('CTerm: \s refused the window\n', dev)
EXCEPT DO
  closeui()
  SELECT exception
    CASE "UI"
      WriteF('CTerm: cannot open UI (\s)\n', exceptioninfo)
      rc := 20
    CASE "MEM"
      WriteF('CTerm: out of memory\n')
      rc := 20
    CASE "ARG"
      WriteF('usage: CTerm [CONSOLE <device:>] [FROM <script>]\n')
      WriteF('   the console device is CON:, CCON:, KCON:, VNC:,\n')
      WriteF('   any mounted console handler; e.g.\n')
      WriteF('   CTerm CCON: FROM S:Shell-Startup\n')
      rc := 10
  ENDSELECT
  CleanUp(rc)
ENDPROC

version: CHAR '$VER: CTerm 0.3 (17.7.26) real shell in the LTX frame',0
