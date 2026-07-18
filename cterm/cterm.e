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
-> Chrome (0.4): HEADER/FOOTER name band art files - the whole file
-> is the band (a header up to 6 lines, a footer up to 3),
-> plain art or ANSI (ESC[ detected,
-> SGR colours + gaps rendered, palette engaged). Naming one band
-> shows only that band; naming none shows the built-in mockup;
-> FULL shows none - the console takes the whole screen. ANSI opens
-> the screen with 16 pens and the classic 16-colour palette (bright
-> half included: bold-as-bright art, and pen 8 = grey), so colour
-> codes in prompts and command output have true colours to land
-> on; CCON-family consoles get a PEN7 option for light-grey text. Defaults for everything can live in PROGDIR:cterm.cfg
-> (KEY VALUE lines, ';' comments: CONSOLE, HEADER, FOOTER, FULL
-> ON, ANSI ON, FROM); the CLI overrides the file.
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

CONST HDRMAX=6, FTRMAX=2, MOCKMAX=40, MOCKBUFSZ=4096,
      HBANDMAX=6,       -> a user header band: 6 lines at most
      FBANDMAX=3,       -> a user footer band: 3 lines at most
      BANDBUFSZ=8192    -> per band; ANSI art carries escape bytes

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
    -> 0.4 settings: PROGDIR:cterm.cfg first, CLI args override
    dev[44]:STRING,             -> the console device (spec prefix)
    cmd[280]:STRING,            -> Execute's pre-prompt command (FROM)
    hdrfile[208]:STRING,        -> user band files; empty = built-in
    ftrfile[208]:STRING,
    fullmode=FALSE,             -> FULL: no bands at all
    ansimode=FALSE,             -> ANSI: the 8-colour ANSI palette
    -> the two bands, loaded independently (built-in mockup fills
    -> both from one file, user files bring their own)
    hbuf=NIL, hlptr[6]:ARRAY OF LONG, hllen[6]:ARRAY OF LONG,
    hln=0, hansi=FALSE, hbn=0,
    fbuf=NIL, flptr[3]:ARRAY OF LONG, fllen[3]:ARRAY OF LONG,
    fln=0, fansi=FALSE, fbn=0,
    softmask=0,
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

-> ---------- settings: PROGDIR:cterm.cfg, args override ----------

-> KEY VALUE lines, ';' comments, keys case-insensitive:
-> CONSOLE dev:, HEADER path, FOOTER path, FROM script,
-> FULL ON, ANSI ON
PROC readcfg()
  DEF fh, buf, n, i=0, j, k, s:PTR TO CHAR, key[24]:STRING,
      val[240]:STRING
  IF (fh := Open('PROGDIR:cterm.cfg', OLDFILE)) = NIL THEN RETURN
  buf := New(2048)
  IF buf = NIL
    Close(fh)
    RETURN
  ENDIF
  n := Read(fh, buf, 2047)
  Close(fh)
  IF n < 0 THEN n := 0
  s := buf
  WHILE i < n
    j := i
    WHILE (j < n) AND (s[j] <> 10)
      j := j + 1
    ENDWHILE
    -> [i..j) is one line; split at the first run of spaces
    IF (j > i) AND (s[i] <> ";")
      k := i
      StrCopy(key, '')
      WHILE (k < j) AND (s[k] <> " ") AND (StrLen(key) < 20)
        StrAdd(key, [s[k], 0]:CHAR)   -> upcased below
        k := k + 1
      ENDWHILE
      WHILE (k < j) AND (s[k] = " ")
        k := k + 1
      ENDWHILE
      StrCopy(val, '')
      WHILE (k < j) AND (s[k] <> 13) AND (StrLen(val) < 236)
        StrAdd(val, [s[k], 0]:CHAR)
        k := k + 1
      ENDWHILE
      WHILE (StrLen(val) > 0) AND (val[StrLen(val) - 1] = " ")
        SetStr(val, StrLen(val) - 1)
      ENDWHILE
      UpperStr(key)
      IF StrCmp(key, 'CONSOLE')
        IF StrLen(val) > 0 THEN StrCopy(dev, val)
      ELSEIF StrCmp(key, 'HEADER')
        StrCopy(hdrfile, val)
      ELSEIF StrCmp(key, 'FOOTER')
        StrCopy(ftrfile, val)
      ELSEIF StrCmp(key, 'FROM')
        IF StrLen(val) > 0 THEN StringF(cmd, 'EXECUTE "\s"', val)
      ELSEIF StrCmp(key, 'FULL')
        UpperStr(val)
        IF StrCmp(val, 'ON') OR StrCmp(val, 'YES') THEN fullmode := TRUE
      ELSEIF StrCmp(key, 'ANSI')
        UpperStr(val)
        IF StrCmp(val, 'ON') OR StrCmp(val, 'YES') THEN ansimode := TRUE
      ENDIF
    ENDIF
    i := j + 1
  ENDWHILE
ENDPROC

-> ---------- the bands ----------

-> split a loaded buffer into line ptr/len pairs, cap lines
PROC splitband(buf, n, lptr:PTR TO LONG, llen:PTR TO LONG, cap)
  DEF s:PTR TO CHAR, i=0, j, ln=0
  s := buf
  WHILE (i < n) AND (ln < cap)
    j := i
    WHILE (j < n) AND (s[j] <> 10)
      j := j + 1
    ENDWHILE
    lptr[ln] := s + i
    llen[ln] := j - i
    ln := ln + 1
    i := j + 1
  ENDWHILE
ENDPROC ln

-> does the band carry ANSI escapes? (ESC[ anywhere)
PROC bandisansi(buf, n)
  DEF s:PTR TO CHAR, i
  s := buf
  FOR i := 0 TO n - 2
    IF s[i] = 27
      IF s[i + 1] = "[" THEN RETURN TRUE
    ENDIF
  ENDFOR
ENDPROC FALSE

-> read a whole band file; returns the buffer (New'd) or NIL,
-> byte count in the LONG at nout
PROC loadfile(path, nout:PTR TO LONG)
  DEF fh, buf, n
  IF (fh := Open(path, OLDFILE)) = NIL THEN RETURN NIL
  buf := New(BANDBUFSZ)
  IF buf = NIL
    Close(fh)
    RETURN NIL
  ENDIF
  n := Read(fh, buf, BANDBUFSZ - 1)
  Close(fh)
  IF n < 0 THEN n := 0
  nout[] := n
ENDPROC buf

-> fill the two bands. FULL: none. User HEADER/FOOTER files: each
-> named band only (the whole file is the band: a header claims
-> up to HBANDMAX lines, a footer up to FBANDMAX). Neither named: the built-in mockup - its first HDRMAX
-> lines become the header, its last FTRMAX the footer, as always.
-> A band containing ESC[ renders as ANSI and engages the palette.
PROC loadbands()
  DEF fh=NIL, n, i
  IF fullmode THEN RETURN
  IF (StrLen(hdrfile) > 0) OR (StrLen(ftrfile) > 0)
    IF StrLen(hdrfile) > 0
      hbuf := loadfile(hdrfile, {hbn})
      IF hbuf THEN hln := splitband(hbuf, hbn, hlptr, hllen, HBANDMAX)
      IF hbuf THEN hansi := bandisansi(hbuf, hbn)
    ENDIF
    IF StrLen(ftrfile) > 0
      fbuf := loadfile(ftrfile, {fbn})
      IF fbuf THEN fln := splitband(fbuf, fbn, flptr, fllen, FBANDMAX)
      IF fbuf THEN fansi := bandisansi(fbuf, fbn)
    ENDIF
  ELSE
    -> the built-in: one mockup file, 6+2 split, font picks the art
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
    mocklines := splitband(mockbuf, n, mocklineptr, mocklinelen, MOCKMAX)
    IF mocklines >= (HDRMAX + FTRMAX)
      FOR i := 0 TO HDRMAX - 1
        hlptr[i] := mocklineptr[i]
        hllen[i] := mocklinelen[i]
      ENDFOR
      hln := HDRMAX
      FOR i := 0 TO FTRMAX - 1
        flptr[i] := mocklineptr[mocklines - FTRMAX + i]
        fllen[i] := mocklinelen[mocklines - FTRMAX + i]
      ENDFOR
      fln := FTRMAX
    ENDIF
  ENDIF
  IF hansi OR fansi THEN ansimode := TRUE
ENDPROC

-> the classic ANSI 8-colour palette: black red green yellow blue
-> magenta cyan white (CMenu's ANSI style). Deliberately TRUE to
-> ANSI even though consoles draw text in pen 1 (= red here): the
-> art's colours come first; the console-text pen is the SGR
-> milestone's business over in CCON.
-> is the chosen console device one of ours? (name contains CCON)
PROC devisccon()
  DEF i, l
  l := StrLen(dev)
  FOR i := 0 TO l - 4
    IF (tcfoldc(dev[i]) = "C") AND (tcfoldc(dev[i + 1]) = "C") AND
       (tcfoldc(dev[i + 2]) = "O") AND (tcfoldc(dev[i + 3]) = "N")
      RETURN TRUE
    ENDIF
  ENDFOR
ENDPROC FALSE

PROC tcfoldc(c)
  IF (c >= "a") AND (c <= "z") THEN RETURN c - 32
ENDPROC c

PROC applypalette()
  IF ansimode
    -> the dark terminal theme: classic 16, 0-7 normal (7 = light
    -> grey, the default text colour via PEN7), 8-15 bright (8 =
    -> dark grey for hidden files, 15 = true white)
    LoadRGB4(ViewPortAddress(artwin),
      [$0000,$0B22,$02B2,$0BB2,$044C,$0B2B,$02BB,$0AAA,
       $0555,$0F55,$05F5,$0FF5,$088F,$0F5F,$05FF,$0FFF]:INT, 16)
  ELSE
    -> the classic light theme (CMenu's LIGHT, grown to 16): grey
    -> bg, BLACK text where ANSI red would sit (the CMenu trade),
    -> the ANSI colours in 2-7, dark grey at 8, bright half above
    LoadRGB4(ViewPortAddress(artwin),
      [$0AAA,$0000,$02C2,$0BB2,$044C,$0B2B,$02BB,$0EEE,
       $0555,$0F55,$05F5,$0FF5,$088F,$0F5F,$05FF,$0FFF]:INT, 16)
  ENDIF
ENDPROC

-> a plain band, drawn as a block: lines have trimmed trailing
-> spaces so their lengths differ, but column positions must stay
-> aligned - center the band by its widest line, every line at the
-> same left edge.
PROC drawplain(rp:PTR TO rastport, lptr:PTR TO LONG, llen:PTR TO LONG,
               n, toprow)
  DEF i, w, c
  -> plain art follows the theme's text colour: light grey on the
  -> dark theme (pen 1 there is ANSI red), black on the light one
  SetAPen(rp, IF ansimode THEN 7 ELSE 1)
  SetBPen(rp, 0)
  c := 0
  FOR i := 0 TO n - 1
    IF llen[i] > c THEN c := llen[i]
  ENDFOR
  IF c > ncols THEN c := ncols
  c := (ncols - c) / 2
  IF c < 0 THEN c := 0
  FOR i := 0 TO n - 1
    w := llen[i]
    IF (c + w) > ncols THEN w := ncols - c
    Move(rp, x0 + (c * cw), top + ((toprow + i) * ch) + baseline)
    Text(rp, lptr[i], w)
  ENDFOR
ENDPROC

-> an ANSI band (CMenu's art renderer, grown a background colour):
-> SGR - 0 reset, 1 bold, 4 underline, 30-37 fg, 40-47 bg - and
-> cursor-forward (ESC[nC, how ANSI art places transparent gaps);
-> other sequences are consumed and ignored. ANSI art is authored
-> 80 columns wide: the block centers on that width.
PROC drawansi(rp:PTR TO rastport, buf, len, toprow, cap)
  DEF p:PTR TO CHAR, i, j, c, col, row, xa, fg, bg, sty, boldf,
      pv[8]:ARRAY OF LONG, np, v
  p := buf
  xa := ncols - 80
  IF xa < 0 THEN xa := 0
  xa := x0 + ((xa / 2) * cw)
  fg := 7
  bg := 0
  sty := 0
  boldf := FALSE
  SetSoftStyle(rp, 0, softmask)
  SetAPen(rp, 7)
  SetBPen(rp, 0)
  col := 0
  row := 0
  i := 0
  WHILE (i < len) AND (row < cap)
    c := p[i]
    IF c = 27    -> ESC
      i++
      IF (i < len) AND (p[i] = "[")
        i++
        np := 0
        v := 0
        c := IF i < len THEN p[i] ELSE 0
        WHILE ((c >= "0") AND (c <= "9")) OR (c = ";")
          IF c = ";"
            IF np < 8
              pv[np] := v
              np++
            ENDIF
            v := 0
          ELSE
            v := (v * 10) + (c - "0")
          ENDIF
          i++
          c := IF i < len THEN p[i] ELSE 0
        ENDWHILE
        IF np < 8
          pv[np] := v
          np++
        ENDIF
        IF c <> 0 THEN i++    -> consume the final letter
        IF c = "m"
          FOR j := 0 TO np - 1
            v := pv[j]
            IF v = 0
              fg := 7
              bg := 0
              sty := 0
              boldf := FALSE
            ELSEIF v = 1
              boldf := TRUE   -> bold = the bright pens (8-15), the
            ELSEIF v = 4      -> 16-colour ANSI art convention
              sty := sty OR FSF_UNDERLINED
            ELSEIF (v >= 30) AND (v <= 37)
              fg := v - 30
            ELSEIF (v >= 40) AND (v <= 47)
              bg := v - 40
            ENDIF
          ENDFOR
          SetSoftStyle(rp, sty, softmask)
          SetAPen(rp, IF boldf THEN fg + 8 ELSE fg)
          SetBPen(rp, bg)
        ELSEIF c = "C"
          col := col + (IF pv[0] = 0 THEN 1 ELSE pv[0])
        ENDIF
      ENDIF
    ELSEIF c = 10    -> LF
      col := 0
      row++
      i++
    ELSEIF c = 13    -> CR, ignore
      i++
    ELSEIF c >= 32
      -> whole printable runs in one Text() - per-character
      -> rendering is visibly slow on a 68000
      j := i
      WHILE (j < len) AND (p[j] >= 32)
        j++
      ENDWHILE
      Move(rp, xa + (col * cw), top + ((toprow + row) * ch) + baseline)
      Text(rp, p + i, j - i)
      col := col + (j - i)
      i := j
    ELSE
      i++
    ENDIF
  ENDWHILE
  SetSoftStyle(rp, 0, softmask)
  SetAPen(rp, 1)
  SetBPen(rp, 0)
ENDPROC

PROC drawchrome()
  DEF rp:PTR TO rastport
  hdrn := hln
  ftrn := fln
  IF (nrows - hdrn - ftrn) < 5    -> no room for a shell: no chrome
    hdrn := 0
    ftrn := 0
    RETURN
  ENDIF
  rp := artwin.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  softmask := AskSoftStyle(rp)
  IF hdrn > 0
    IF hansi
      drawansi(rp, hbuf, hbn, 0, hdrn)
    ELSE
      drawplain(rp, hlptr, hllen, hdrn, 0)
    ENDIF
  ENDIF
  IF ftrn > 0
    IF fansi
      drawansi(rp, fbuf, fbn, nrows - ftrn, ftrn)
    ELSE
      drawplain(rp, flptr, fllen, ftrn, nrows - ftrn)
    ENDIF
  ENDIF
ENDPROC

PROC openui()
  -> the screen carries the font: the console handler inherits it.
  -> Always 16 pens: both themes carry the ANSI colours (bright
  -> half included - bold-as-bright art, and pen 8 = the grey), so
  -> blue directories and grey hidden files work in the classic
  -> light theme too, with the same SGR codes
  scr := OpenScreenTagList(NIL,
    [SA_LIKEWORKBENCH, TRUE,
     SA_DEPTH,     4,
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
  DEF fh=NIL, spec[160]:STRING, rdargs=NIL, args[6]:ARRAY OF LONG,
      s:PTR TO CHAR, l, clichrome=FALSE
  -> settings: defaults, then PROGDIR:cterm.cfg, then the CLI -
  -> each layer overrides the one before. Copies are taken before
  -> FreeArgs; the e-strings clamp silently.
  StrCopy(dev, 'CON:')
  StrCopy(cmd, '')
  StrCopy(hdrfile, '')
  StrCopy(ftrfile, '')
  readcfg()
  FOR l := 0 TO 5
    args[l] := NIL
  ENDFOR
  IF (rdargs := ReadArgs('CONSOLE,HEADER/K,FOOTER/K,FULL/S,ANSI/S,FROM/K',
                         args, NIL)) = NIL
    Throw("ARG", NIL)
  ENDIF
  IF args[0]
    s := args[0]
    StrCopy(dev, s)
  ENDIF
  IF args[1]
    s := args[1]
    StrCopy(hdrfile, s)
    clichrome := TRUE
  ENDIF
  IF args[2]
    s := args[2]
    StrCopy(ftrfile, s)
    clichrome := TRUE
  ENDIF
  IF args[5]
    s := args[5]
    StringF(cmd, 'EXECUTE "\s"', s)
  ENDIF
  IF args[4] THEN ansimode := TRUE
  IF args[3]
    IF clichrome
      FreeArgs(rdargs)      -> FULL with HEADER/FOOTER is a
      Throw("ARG", NIL)     -> contradiction: refuse, explain
    ENDIF
    fullmode := TRUE
  ELSEIF clichrome
    fullmode := FALSE       -> a named band overrides config FULL
  ENDIF
  FreeArgs(rdargs)
  rdargs := NIL
  l := StrLen(dev)
  IF l > 0
    IF dev[l - 1] <> ":" THEN StrAdd(dev, ':')
  ENDIF
  ensureassigns()
  openfont()      -> before the bands: usemk picks the mockup, and
  loadbands()     -> band ANSI detection must precede the screen's
  openui()        -> depth choice in openui
  applypalette()
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
  -> on the ANSI palette pen 1 is red; CCON accepts a PEN option
  -> for its default text pen, so hand it the terminal's light
  -> grey. WBPENS makes CCON retarget plain SGR 30-33 as the
  -> Workbench pens programs like Ed hardcode (Ed's body text is
  -> ESC[31m = "WB black" = ANSI red otherwise). Only for
  -> CCON-family names - stock CON: rejects opens with options
  -> it does not know.
  IF ansimode AND devisccon() THEN StrAdd(spec, '/PEN7/WBPENS')
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
      WriteF('usage: CTerm [CONSOLE <device:>] [HEADER <file>]\n')
      WriteF('             [FOOTER <file>] [FULL] [ANSI] [FROM <script>]\n')
      WriteF('   CONSOLE: CON:, CCON:, KCON:, VNC:, any console handler\n')
      WriteF('   HEADER/FOOTER: band art files (plain or ANSI; the\n')
      WriteF('   named bands replace the built-in art). FULL: no bands\n')
      WriteF('   (contradicts HEADER/FOOTER). ANSI: the 8-colour ANSI\n')
      WriteF('   palette. FROM: script run before the first prompt.\n')
      WriteF('   Defaults read from PROGDIR:cterm.cfg (KEY VALUE\n')
      WriteF('   lines); the CLI overrides it. e.g.\n')
      WriteF('   CTerm CCON: FOOTER S:ltx-footer.ans FROM S:Shell-Startup\n')
      rc := 10
  ENDSELECT
  CleanUp(rc)
ENDPROC

version: CHAR '$VER: CTerm 0.4 (17.7.26) real shell in the LTX frame',0
