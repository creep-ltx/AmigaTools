-> CFile - a two-pane text-style file manager for AmigaOS
->
-> Opens its own screen (SA_LIKEWORKBENCH) and composes a character
-> frame for whatever font the config names (PROGDIR:cfile.config:
-> LEFT/RIGHT start paths, SAVEDIRS, FONT name/size), with two
-> directory panes side by side. The panes start in SYS: and RAM:
-> unless the config or the command line says otherwise; going Left
-> past a device root shows the volume list (volumes, then assigns),
-> so either pane can reach any mounted volume.
->
-> Keys:
->   Tab         switch the active pane
->   Up/Down     move the selection (Shift = page, Ctrl = first/last)
->   Right       enter the selected directory or volume
->   Left        back to the parent directory (re-selects where you
->               came from); at a device root, the volume list
->   Enter       open by type: enter a directory, view text, run a
->               hunk executable (asks first), hex-view the rest
->   v           view the file: text pager, ANSI, or hex; with
->               marks, a tour - Right = next file (consumes the
->               mark), Left = back, Esc keeps the rest marked
->   e           edit a text file in place: arrows move the cursor
->               (Shift = page/line ends, Ctrl = first/last line),
->               Enter splits, Backspace/Del join; Esc asks to save
->               when something changed
->   i           info window: size/date/comment plus the protection
->               bits, which h/s/p/a/r/w/e/d toggle live
->   Space       mark/unmark the entry (marked sets make c/m/Del bulk)
->   c / C       copy the selection or marked set - directories
->               recursively - to the other pane's directory
->               (c asks on a name collision, C overwrites)
->   m / M       move likewise (same volume = Rename, across = copy
->               and delete)
->   r           rename the selected entry
->   n           new: a name ending in "/" makes a directory, any
->               other name opens the editor on a new file (created
->               only when saved)
->   Del / D     delete the selection or marked set, directories
->               contents and all (asks first)
->   u           unpack the selected archive (lha/lzx/zip) - or all
->               marked archives - into the other pane's directory
->   p           pack the selection or marked set into an archive in
->               the other pane; the typed name's extension picks
->               the archiver (.lha/.lzh, .lzx, .zip)
->   :           run a shell command in the active pane's directory
->               (output streams into the frame; Up/Down scroll back)
->   ? / Help    help screen (h works too)
->   Esc         quit (asks first)
->
-> Anything that takes a while (big files, directory trees, bulk
-> sets) draws a centered progress bar that fills left to right.
->
-> The current path of each pane is shown in the frame's border row
-> above the panes; prompts, questions and error messages use the
-> same row and give it back afterwards. The selection bar (inverted
-> colours, in the active pane only) marks both the selected entry
-> and which pane is active. Directories are listed first (in a
-> different colour on the own screen), then files, both sorted
-> case-insensitively.
->
-> Build: ecompile cfile.e   (E-VO)

OPT LARGE

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','dos/dos','dos/dosextens',
       'dos/datetime','dos/dostags','devices/inputevent','diskfont'

CONST CPATHLEN=300, MAXENT=500, CBUFSZ=16384,
      EDMAXL=8192, EDLW=200,    -> editor: line count / line length caps
      CMAXL=4000,    -> console scrollback, lines of 80
      RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F, RK_HELP=$5F,
      VIEWMAX=524288,    -> the viewers load whole files; cap at 512KB
      TY_OTHER=0, TY_EXEC=1, TY_TEXT=2, TY_LHA=3, TY_LZX=4, TY_ZIP=5,
      TY_ANSI=6

DEF enames[1000]:ARRAY OF LONG,   -> entry names, MAXENT slots per pane
    edirs[1000]:ARRAY OF CHAR,    -> nonzero = entry is a directory
    emark[1000]:ARRAY OF CHAR,    -> nonzero = entry is marked
    esize[1000]:ARRAY OF LONG,    -> file size (0 for dirs/volumes)
    ealloc[2]:ARRAY OF LONG,      -> allocated name slots per pane
    ecount[2]:ARRAY OF LONG,
    esel[2]:ARRAY OF LONG,
    etop[2]:ARRAY OF LONG,        -> first visible entry (scroll)
    efail[2]:ARRAY OF LONG,       -> directory could not be read
    ppath[2]:ARRAY OF LONG,
    active=0,
    scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    ownscr=FALSE, txtpen=1, dirpen=1, errpen=1, softmask=0,
    winw, winh, baseline, x0, top, bordy, panetop,
    cw=8, ch=8,          -> the font cell; every coordinate derives
    ncols=80, nrows=31,  -> the character grid the screen provides
    visrows=22,          -> pane rows: nrows minus logo and footer
    divcol=39, panewl=38, panewr=38,    -> pane split around the divider
    framebuf=NIL, viewbuf=NIL, promptbuf=NIL,    -> composed frames
    vescol=0,            -> where the view footer's Esc text sits
    fullfont[44]:STRING, diskfontbase=NIL,
    appliedfont[44]:STRING, wantreload=FALSE,    -> live config reload
    bulkpos=0, bulktot=0,    -> bulk view: position shown in the title
    prevname[108]:STRING,
    copybuf=NIL,      -> file-copy buffer, allocated once at startup
    rnames[500]:ARRAY OF LONG,    -> resolved target names (bulk runs)
    ridx[500]:ARRAY OF LONG,      -> entry index per resolved slot
    ralloc=0,                     -> allocated rnames slots
    msgup=FALSE,      -> a message covers the paths row; next key clears
    opmsg[120]:STRING,    -> last message, re-shown after a bulk refresh
    progon=FALSE, progtotal=1, progdone=0, progpx=0, progx=0, progy=0,
    statbytes=0, statfiles=0,    -> pre-scan totals for the progress bar
    gfails=0,    -> entries a delete run could not remove
    unprotall=FALSE,    -> 'a' at the unprotect prompt covers the run
    ccol=0, crow=0, cesc=0, cnum=0,    -> the in-frame console renderer
    cmodel=NIL, cmrow=0,    -> its text model: the scrollback
    cfgleft[300]:STRING, cfgright[300]:STRING,    -> start paths
    savedirs=TRUE,          -> rewrite the config with them on quit
    cfgfont[40]:STRING,     -> FONT key, applied by the grid build
    madeenv=FALSE, madet=FALSE,    -> assigns CFile itself created
    edl=NIL:PTR TO LONG, ednum=0,    -> the editor's line table
    edcur=0, edcol=0, edvtop=0, edxoff=0, edmod=FALSE, ednew=FALSE,
    rc=0

-> the global arrays are NOT zero-initialised (E globals live in the
-> uncleared stack allocation), so every pane field is set explicitly
-> here and name slots are tracked with ealloc
PROC initpanes()
  DEF p
  FOR p := 0 TO 1
    IF (ppath[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    ealloc[p] := 0
    ecount[p] := 0
    esel[p] := 0
    etop[p] := 0
    efail[p] := FALSE
  ENDFOR
  StrCopy(ppath[0], cfgleft)
  StrCopy(ppath[1], cfgright)
  IF (copybuf := String(CBUFSZ)) = NIL THEN Raise("MEM")
ENDPROC

-> without a Startup-Sequence there is no ENV: or T:; CFile makes
-> them the standard way (RAM:Env, RAM:T) and remembers what it made.
-> Existence is asked of the DosList - a Lock on an unassigned name
-> would put up a "please insert volume" requester.
PROC haveassign(name)
  DEF dl, found=FALSE
  dl := LockDosList(LDF_ASSIGNS OR LDF_DEVICES OR LDF_VOLUMES OR LDF_READ)
  IF FindDosEntry(dl, name, LDF_ASSIGNS OR LDF_DEVICES OR LDF_VOLUMES)
    found := TRUE
  ENDIF
  UnLockDosList(LDF_ASSIGNS OR LDF_DEVICES OR LDF_VOLUMES OR LDF_READ)
ENDPROC found

-> a shared lock on dir (created if missing) for AssignLock to keep
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
      IF AssignLock('ENV', lock)    -> the assign owns the lock now
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

-> clean exits only: remove exactly what ensureassigns created
PROC dropassigns()
  IF madeenv THEN AssignLock('ENV', NIL)
  IF madet THEN AssignLock('T', NIL)
ENDPROC

-> the config lives next to the binary: PROGDIR:cfile.config.
-> KEY value lines, ';' comments. LEFT/RIGHT start paths ("(volumes)"
-> = the volume list), SAVEDIRS ON|OFF, FONT name/size (stored and
-> preserved; takes effect with the font-grid build).
PROC loadconfig()
  DEF fh, buf=NIL, n, i=0, j, c, s:PTR TO CHAR,
      line[300]:STRING, key[20]:STRING, val[280]:STRING, l, sp
  StrCopy(cfgleft, 'SYS:')
  StrCopy(cfgright, 'RAM:')
  StrCopy(cfgfont, '')
  IF (fh := Open('PROGDIR:cfile.config', OLDFILE)) = NIL THEN RETURN
  buf := New(4096)
  IF buf = NIL
    Close(fh)
    RETURN
  ENDIF
  n := Read(fh, buf, 4095)
  Close(fh)
  IF n < 0 THEN n := 0
  s := buf
  WHILE i < n
    -> one line
    StrCopy(line, '')
    j := i
    WHILE (j < n) AND (s[j] <> 10)
      j := j + 1
    ENDWHILE
    l := j - i
    IF l > 298 THEN l := 298
    IF l > 0 THEN StrCopy(line, s + i, l)
    i := j + 1
    -> split into KEY and value on the first space
    IF EstrLen(line) > 0
      c := line[0]
      IF c <> ";"
        sp := -1
        FOR j := 0 TO EstrLen(line) - 1
          IF (line[j] = 32) AND (sp = -1) THEN sp := j
        ENDFOR
        IF sp > 0
          StrCopy(key, line, sp)
          UpperStr(key)
          MidStr(val, line, sp + 1, ALL)
          -> trim leading spaces from the value
          WHILE (EstrLen(val) > 0) AND (val[0] = 32)
            MidStr(val, val, 1, ALL)
          ENDWHILE
          IF StrCmp(key, 'LEFT')
            IF StrCmp(val, '(volumes)')
              StrCopy(cfgleft, '')
            ELSE
              StrCopy(cfgleft, val)
            ENDIF
          ELSEIF StrCmp(key, 'RIGHT')
            IF StrCmp(val, '(volumes)')
              StrCopy(cfgright, '')
            ELSE
              StrCopy(cfgright, val)
            ENDIF
          ELSEIF StrCmp(key, 'SAVEDIRS')
            UpperStr(val)
            savedirs := StrCmp(val, 'ON')
          ELSEIF StrCmp(key, 'FONT')
            StrCopy(cfgfont, val)
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  Dispose(buf)
ENDPROC

-> command-line arguments override the config: cfile [left] [right],
-> quotes allowed for paths with spaces
PROC parseargs()
  DEF s:PTR TO CHAR, i=0, t, q, tok[300]:STRING, ntok=0
  s := arg
  WHILE s[i]
    WHILE s[i] = 32
      i := i + 1
    ENDWHILE
    IF s[i]
      q := s[i] = 34
      IF q THEN i := i + 1
      t := i
      IF q
        WHILE s[i] AND (s[i] <> 34)
          i := i + 1
        ENDWHILE
      ELSE
        WHILE s[i] AND (s[i] <> 32)
          i := i + 1
        ENDWHILE
      ENDIF
      StrCopy(tok, s + t, i - t)
      IF q AND s[i] THEN i := i + 1
      IF ntok = 0
        StrCopy(cfgleft, tok)
      ELSEIF ntok = 1
        StrCopy(cfgright, tok)
      ENDIF
      ntok := ntok + 1
    ENDIF
  ENDWHILE
ENDPROC

PROC wline(fh, s)
ENDPROC Write(fh, s, EstrLen(s))

-> SAVEDIRS ON: remember where the panes stand for the next start.
-> Only the LEFT/RIGHT lines are rewritten - everything else in the
-> file (comments, FONT, SAVEDIRS, hand edits) passes through
-> verbatim, so editing the config from inside CFile survives quit.
PROC savepane(fh, keyname, p)
  DEF line[340]:STRING
  StringF(line, '\s \s\n', keyname,
          IF EstrLen(ppath[p]) = 0 THEN '(volumes)' ELSE ppath[p])
  wline(fh, line)
ENDPROC

PROC saveconfig()
  DEF fh, buf=NIL, n=0, i, j, l, sp, c, s:PTR TO CHAR,
      line[300]:STRING, key[20]:STRING, wl=FALSE, wr=FALSE
  IF savedirs = FALSE THEN RETURN
  IF fh := Open('PROGDIR:cfile.config', OLDFILE)
    buf := New(4096)
    IF buf
      n := Read(fh, buf, 4095)
      IF n < 0 THEN n := 0
    ENDIF
    Close(fh)
  ENDIF
  IF (fh := Open('PROGDIR:cfile.config', NEWFILE)) = NIL
    IF buf THEN Dispose(buf)
    RETURN
  ENDIF
  IF n = 0
    StringF(line, '; CFile configuration - LEFT/RIGHT start paths,\n')
    wline(fh, line)
    StringF(line, '; SAVEDIRS ON|OFF, FONT name/size\n')
    wline(fh, line)
    StringF(line, 'SAVEDIRS ON\n')
    wline(fh, line)
    IF EstrLen(cfgfont) > 0
      StringF(line, 'FONT \s\n', cfgfont)
      wline(fh, line)
    ENDIF
  ELSE
    s := buf
    i := 0
    WHILE i < n
      j := i
      WHILE (j < n) AND (s[j] <> 10)
        j := j + 1
      ENDWHILE
      l := j - i
      IF l > 298 THEN l := 298
      StrCopy(line, '')
      IF l > 0 THEN StrCopy(line, s + i, l)
      i := j + 1
      StrCopy(key, '')
      IF EstrLen(line) > 0
        c := line[0]
        IF c <> ";"
          sp := -1
          FOR j := 0 TO EstrLen(line) - 1
            IF (line[j] = 32) AND (sp = -1) THEN sp := j
          ENDFOR
          IF sp > 0
            StrCopy(key, line, sp)
            UpperStr(key)
          ENDIF
        ENDIF
      ENDIF
      IF StrCmp(key, 'LEFT')
        savepane(fh, 'LEFT', 0)
        wl := TRUE
      ELSEIF StrCmp(key, 'RIGHT')
        savepane(fh, 'RIGHT', 1)
        wr := TRUE
      ELSE
        StrAdd(line, '\n')
        wline(fh, line)
      ENDIF
    ENDWHILE
  ENDIF
  IF wl = FALSE THEN savepane(fh, 'LEFT', 0)
  IF wr = FALSE THEN savepane(fh, 'RIGHT', 1)
  Close(fh)
  IF buf THEN Dispose(buf)
ENDPROC

-> an empty pane path means the pane shows the volume list
PROC involume(p)
ENDPROC EstrLen(ppath[p]) = 0

PROC addentry(p, name, isdir, size)
  DEF i
  i := ecount[p]
  IF i >= MAXENT THEN RETURN
  IF i >= ealloc[p]
    IF (enames[(p * MAXENT) + i] := String(108)) = NIL THEN Raise("MEM")
    ealloc[p] := i + 1
  ENDIF
  StrCopy(enames[(p * MAXENT) + i], name)
  edirs[(p * MAXENT) + i] := isdir
  esize[(p * MAXENT) + i] := size
  ecount[p] := i + 1
ENDPROC

-> a fresh listing never keeps marks (they are positional)
PROC clearmarks(p)
  DEF i
  FOR i := 0 TO MAXENT - 1
    emark[(p * MAXENT) + i] := 0
  ENDFOR
ENDPROC

PROC markcount(p)
  DEF i, n=0
  IF ecount[p] > 0
    FOR i := 0 TO ecount[p] - 1
      IF emark[(p * MAXENT) + i] THEN n := n + 1
    ENDFOR
  ENDIF
ENDPROC n

-> case-insensitive name compare (AmigaDOS filenames are
-> case-preserving but case-insensitive)
PROC nccmp(a, b)
  DEF sa:PTR TO CHAR, sb:PTR TO CHAR, i=0, ca, cb, d
  sa := a
  sb := b
  REPEAT
    ca := sa[i]
    cb := sb[i]
    IF (ca >= "a") AND (ca <= "z") THEN ca := ca - 32
    IF (cb >= "a") AND (cb <= "z") THEN cb := cb - 32
    d := ca - cb
    i++
  UNTIL (d <> 0) OR (ca = 0)
ENDPROC d

-> sort order: directories first, then files, alphabetical within each
PROC entbefore(p, i, j)
  DEF b, di, dj
  b := p * MAXENT
  di := edirs[b + i]
  dj := edirs[b + j]
  -> higher tier sorts first: directories/volumes (255) over
  -> assigns (1) over files (0), alphabetical within each
  IF di > dj THEN RETURN TRUE
  IF di < dj THEN RETURN FALSE
ENDPROC nccmp(enames[b + i], enames[b + j]) < 0

-> selection sort: n*n/2 compares but only n swaps; fine for one
-> directory's worth of names
PROC sortpane(p)
  DEF i, j, m, b, t
  IF ecount[p] < 2 THEN RETURN
  b := p * MAXENT
  FOR i := 0 TO ecount[p] - 2
    m := i
    FOR j := i + 1 TO ecount[p] - 1
      IF entbefore(p, j, m) THEN m := j
    ENDFOR
    IF m <> i
      t := enames[b + i]
      enames[b + i] := enames[b + m]
      enames[b + m] := t
      t := edirs[b + i]
      edirs[b + i] := edirs[b + m]
      edirs[b + m] := t
    ENDIF
  ENDFOR
ENDPROC

PROC readdir(p)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, more
  ecount[p] := 0
  efail[p] := FALSE
  clearmarks(p)
  IF (lock := Lock(ppath[p], SHARED_LOCK)) = NIL
    efail[p] := TRUE
    RETURN
  ENDIF
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL
    UnLock(lock)
    efail[p] := TRUE
    RETURN
  ENDIF
  IF Examine(lock, fib)
    IF fib.direntrytype > 0
      -> ExNext lives in the loop body: E's AND does not short-circuit,
      -> so it must never sit in a compound condition
      more := ExNext(lock, fib)
      WHILE more
        addentry(p, fib.filename, fib.direntrytype > 0, fib.size)
        more := ExNext(lock, fib)
      ENDWHILE
    ELSE
      efail[p] := TRUE    -> the path is a file, not a directory
    ENDIF
  ELSE
    efail[p] := TRUE
  ENDIF
  FreeDosObject(DOS_FIB, fib)
  UnLock(lock)
  sortpane(p)
  IF esel[p] >= ecount[p] THEN esel[p] := ecount[p] - 1
  IF esel[p] < 0 THEN esel[p] := 0
  IF etop[p] > esel[p] THEN etop[p] := esel[p]
ENDPROC

-> list the mounted volumes (what Workbench shows) into the pane.
-> Names are copied out while the DosList is locked; dol_Name is a
-> BPTR to a length-prefixed BCPL string.
PROC readvolumes(p)
  DEF dl:PTR TO doslist, head, s:PTR TO CHAR, nm[34]:STRING, len, i
  ecount[p] := 0
  efail[p] := FALSE
  clearmarks(p)
  head := LockDosList(LDF_VOLUMES OR LDF_ASSIGNS OR LDF_READ)
  dl := NextDosEntry(head, LDF_VOLUMES)
  WHILE dl
    s := Shl(dl.name, 2)
    len := s[0]
    IF len > 30 THEN len := 30
    FOR i := 0 TO len - 1
      nm[i] := s[i + 1]
    ENDFOR
    SetStr(nm, len)
    StrAdd(nm, ':')
    addentry(p, nm, 255, 0)
    dl := NextDosEntry(dl, LDF_VOLUMES)
  ENDWHILE
  -> assigns below the volumes (tier 1 sorts after tier 255)
  dl := NextDosEntry(head, LDF_ASSIGNS)
  WHILE dl
    s := Shl(dl.name, 2)
    len := s[0]
    IF len > 30 THEN len := 30
    FOR i := 0 TO len - 1
      nm[i] := s[i + 1]
    ENDFOR
    SetStr(nm, len)
    StrAdd(nm, ':')
    addentry(p, nm, 1, 0)
    dl := NextDosEntry(dl, LDF_ASSIGNS)
  ENDWHILE
  UnLockDosList(LDF_VOLUMES OR LDF_ASSIGNS OR LDF_READ)
  sortpane(p)
  IF esel[p] >= ecount[p] THEN esel[p] := ecount[p] - 1
  IF esel[p] < 0 THEN esel[p] := 0
  IF etop[p] > esel[p] THEN etop[p] := esel[p]
ENDPROC

PROC readpane(p)
  IF involume(p)
    readvolumes(p)
  ELSE
    readdir(p)
  ENDIF
ENDPROC

-> the configured FONT via diskfont.library (CMenu's pattern);
-> anything missing or proportional falls back to ROM Topaz/8
PROC openfont()
  DEF l, i, sl=-1, sz, t[12]:STRING, s:PTR TO CHAR
  NEW ta
  ta.style := 0
  ta.flags := 0
  IF EstrLen(cfgfont) > 0
    s := cfgfont
    l := EstrLen(cfgfont)
    FOR i := 0 TO l - 1
      IF s[i] = "/" THEN sl := i
    ENDFOR
    IF sl > 0
      StrCopy(fullfont, cfgfont, sl)
      sz := Val(s + sl + 1)
      IF sz < 4 THEN sz := 8
      l := EstrLen(fullfont)
      IF l >= 5
        MidStr(t, fullfont, l - 5, 5)
        LowerStr(t)
      ENDIF
      IF StrCmp(t, '.font') = FALSE THEN StrAdd(fullfont, '.font')
      -> "topaz" always means the ROM font: the topaz.font file on
      -> disk is a different font with different metrics
      StrCopy(t, '')
      IF EstrLen(fullfont) >= 10 THEN StrCopy(t, fullfont, 10)
      LowerStr(t)
      IF StrCmp(t, 'topaz.font')
        ta.name := 'topaz.font'
        ta.ysize := sz
        tf := OpenFont(ta)
      ELSEIF diskfontbase := OpenLibrary('diskfont.library', 0)
        ta.name := fullfont
        ta.ysize := sz
        tf := OpenDiskFont(ta)
        CloseLibrary(diskfontbase)
        diskfontbase := NIL
      ENDIF
      IF tf
        IF tf.flags AND FPF_PROPORTIONAL
          -> the grid needs fixed-width glyphs
          CloseFont(tf)
          tf := NIL
        ENDIF
      ENDIF
    ENDIF
  ENDIF
  IF tf = NIL
    ta.name := 'topaz.font'
    ta.ysize := 8
    IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
  ENDIF
  cw := tf.xsize
  ch := tf.ysize
  baseline := tf.baseline
ENDPROC

-> compose the frame for this grid from the measured pieces: left
-> pieces keep their distance from the left edge, right pieces from
-> the right, centered pieces stay centered; the pane rows repeat
PROC composeframes()
  DEF i, r, c, t:PTR TO LONG, row, anch, par, w, o,
      m:PTR TO CHAR, dst:PTR TO CHAR, n
  IF (framebuf := New(Mul(nrows, ncols))) = NIL THEN Raise("MEM")
  IF (viewbuf := New(Mul(4, ncols))) = NIL THEN Raise("MEM")
  IF (promptbuf := New(ncols)) = NIL THEN Raise("MEM")
  n := Mul(nrows, ncols)
  m := framebuf
  FOR i := 0 TO n - 1
    m[i] := 32
  ENDFOR
  m := viewbuf
  FOR i := 0 TO Mul(4, ncols) - 1
    m[i] := 32
  ENDFOR
  m := promptbuf
  FOR i := 0 TO ncols - 1
    m[i] := 32
  ENDFOR
  -> row 5, resting: the paths border with the divider notch
  m := framebuf + Mul(5, ncols)
  FOR c := 1 TO ncols - 2
    m[c] := 45
  ENDFOR
  m[0] := 166
  m[ncols - 1] := 166
  m[divcol] := 46
  m[divcol + 1] := 46
  -> the pane rows: ':'/'·' accents on the first, '|' after
  FOR r := 6 TO nrows - 4
    m := framebuf + Mul(r, ncols)
    IF r = 6
      m[0] := 58
      m[ncols - 1] := 183
    ELSE
      m[0] := 124
      m[ncols - 1] := 124
    ENDIF
    m[divcol] := 124
    m[divcol + 1] := 124
  ENDFOR
  -> banner rows fill with dashes before the pieces land
  m := framebuf + Mul(nrows - 1, ncols)
  FOR c := 0 TO ncols - 1
    m[c] := 45
  ENDFOR
  m := viewbuf + Mul(3, ncols)
  FOR c := 0 TO ncols - 1
    m[c] := 45
  ENDFOR
  -> the view frame's closed top border
  m := viewbuf
  FOR c := 1 TO ncols - 2
    m[c] := 45
  ENDFOR
  m[0] := 96
  m[ncols - 1] := 180
  -> the occupied border: text between the guillemets
  m := promptbuf
  m[0] := 166
  m[1] := 45
  m[2] := 187
  m[ncols - 3] := 171
  m[ncols - 2] := 45
  m[ncols - 1] := 166
  -> place the measured pieces
  t := {ctab}
  i := 0
  WHILE t[i] <> -99
    row  := t[i]
    anch := t[i + 1]
    par  := t[i + 2]
    w    := t[i + 3]
    o    := t[i + 4]
    IF row < 20
      dst := framebuf + Mul(row, ncols)
    ELSEIF row < 30
      dst := framebuf + Mul(nrows - 24 + row, ncols)
    ELSE
      dst := viewbuf + Mul(row - 30, ncols)
    ENDIF
    IF anch = 0
      c := par
    ELSEIF anch = 1
      c := (ncols - w) / 2
    ELSE
      c := ncols - par
    ENDIF
    CopyMem({cpieces} + o, dst + c, w)
    i := i + 5
  ENDWHILE
  vescol := (ncols - 25) / 2
ENDPROC

PROC openui()
  openfont()
  scr := OpenScreenTagList(NIL,
    [SA_LIKEWORKBENCH, TRUE,
     SA_DEPTH,     3,
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     SA_TITLE,     'CFile',
     SA_PUBNAME,   'CFILE',
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
    -> fallback: window on the public screen, no palette of our own
    ownscr := FALSE
    OpenWorkBench()    -> ensure the Workbench screen exists (early boot)
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
  IF ownscr THEN PubScreenStatus(scr, 0)    -> console windows visit us
  rp := win.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  softmask := AskSoftStyle(rp)
  IF ownscr
    setlightpal()
    txtpen := 1
    dirpen := 4
    errpen := 5
  ELSE
    txtpen := 1
    dirpen := 1
    errpen := 1
  ENDIF
  winw := win.width
  winh := win.height
  -> the character grid this font gets from this screen
  ncols := winw / cw
  IF ncols > 200 THEN ncols := 200
  nrows := winh / ch
  IF nrows > 120 THEN nrows := 120
  IF (ncols < 80) OR (nrows < 18)
    -> the frame cannot fit at this size: retreat to Topaz/8
    IF StrCmp(fullfont, 'topaz.font') = FALSE
      CloseFont(tf)
      tf := NIL
      StrCopy(cfgfont, '')
      openfont()
      SetFont(rp, tf)
      ncols := winw / cw
      IF ncols > 200 THEN ncols := 200
      nrows := winh / ch
      IF nrows > 120 THEN nrows := 120
    ENDIF
  ENDIF
  x0 := (winw - Mul(ncols, cw)) / 2
  IF x0 < 0 THEN x0 := 0
  top := (winh - Mul(nrows, ch)) / 2
  IF top < 0 THEN top := 0
  visrows := nrows - 9
  divcol := (ncols - 2) / 2
  panewl := divcol - 1
  panewr := ncols - divcol - 3
  bordy   := top + (5 * ch)    -> grid row 5: the border above the panes
  panetop := top + (6 * ch)    -> grid row 6: the first listing row
  composeframes()
  StrCopy(appliedfont, cfgfont)
ENDPROC

-> saving the config from inside CFile applies it on the spot: the
-> font (and grid, and frames) rebuild live. A font that fails to
-> open or cannot fit the frame is refused and the current one
-> stays - the last good setup always survives.
PROC applyfont()
  DEF oldtf, oldcw, oldch, oldbl, nc, nr
  oldtf := tf
  oldcw := cw
  oldch := ch
  oldbl := baseline
  tf := NIL
  openfont()
  nc := winw / cw
  IF nc > 200 THEN nc := 200
  nr := winh / ch
  IF nr > 120 THEN nr := 120
  IF (nc < 80) OR (nr < 18)
    -> no good: keep what we have
    IF tf <> oldtf THEN CloseFont(tf)
    tf := oldtf
    cw := oldcw
    ch := oldch
    baseline := oldbl
    showmsg('that font does not fit this screen - keeping the old one')
    RETURN FALSE
  ENDIF
  IF tf <> oldtf THEN CloseFont(oldtf)
  SetFont(rp, tf)
  ncols := nc
  nrows := nr
  x0 := (winw - Mul(ncols, cw)) / 2
  IF x0 < 0 THEN x0 := 0
  top := (winh - Mul(nrows, ch)) / 2
  IF top < 0 THEN top := 0
  visrows := nrows - 9
  divcol := (ncols - 2) / 2
  panewl := divcol - 1
  panewr := ncols - divcol - 3
  bordy   := top + (5 * ch)
  panetop := top + (6 * ch)
  IF framebuf THEN Dispose(framebuf)
  IF viewbuf THEN Dispose(viewbuf)
  IF promptbuf THEN Dispose(promptbuf)
  composeframes()
  IF cmodel    -> the scrollback's row width changed with the grid
    Dispose(cmodel)
    cmodel := NIL
  ENDIF
  StrCopy(appliedfont, cfgfont)
ENDPROC TRUE

PROC applyconfig()
  DEF keepl[300]:STRING, keepr[300]:STRING
  -> re-read the file; the panes keep their session paths (LEFT and
  -> RIGHT are start paths, honoured at the next start)
  StrCopy(keepl, cfgleft)
  StrCopy(keepr, cfgright)
  loadconfig()
  StrCopy(cfgleft, keepl)
  StrCopy(cfgright, keepr)
  IF StrCmp(cfgfont, appliedfont) = FALSE
    applyfont()
    -> reclamp the pane windows to the new row count
    IF esel[0] >= (etop[0] + visrows) THEN etop[0] := esel[0] - visrows + 1
    IF esel[1] >= (etop[1] + visrows) THEN etop[1] := esel[1] - visrows + 1
    drawall()
    IF msgup THEN remsg()
  ENDIF
ENDPROC

-> Workbench-style palette: grey background, black text, blue
-> directories; pens 2-7 keep the ANSI colours (red gives way to
-> the black text pen)
PROC setlightpal()
  IF ownscr
    LoadRGB4(ViewPortAddress(win),
      [$0AAA,$0000,$02C2,$0EE2,$055E,$0D2D,$02DD,$0EEE]:INT, 8)
  ENDIF
ENDPROC

-> the classic ANSI 8 colours (CMenu's ANSI style) for viewing art
PROC setansipal()
  IF ownscr
    LoadRGB4(ViewPortAddress(win),
      [$0000,$0E22,$02C2,$0EE2,$055E,$0D2D,$02DD,$0EEE]:INT, 8)
  ENDIF
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

PROC panex(p)
  DEF x
  x := IF p = 0 THEN 1 ELSE divcol + 2
ENDPROC x0 + (x * cw)

-> pane interior width in characters
PROC panew(p)
ENDPROC IF p = 0 THEN panewl ELSE panewr

-> one row of the composed frame, 0-based
PROC frow(r)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0, top + (r * ch) + baseline)
  Text(rp, framebuf + Mul(r, ncols), ncols)
ENDPROC

PROC drawframe()
  DEF r
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  FOR r := 0 TO nrows - 1
    frow(r)
  ENDFOR
ENDPROC

-> the pane paths live in the border row above the panes, drawn plain;
-> the selection bar alone shows which pane is active. Deep paths show
-> their tail end, truncated to 32 characters.
PROC drawpaths()
  DEF p, s[200]:STRING, l, x, j
  frow(5)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR p := 0 TO 1
    j := (IF p = 0 THEN panewl ELSE panewr) - 6    -> label room
    l := EstrLen(ppath[p])
    IF l = 0
      StrCopy(s, '(volumes)')
    ELSEIF l > j
      MidStr(s, ppath[p], l - j, j)
    ELSE
      StrCopy(s, ppath[p])
    ENDIF
    x := IF p = 0 THEN 3 ELSE divcol + 4
    Move(rp, x0 + (x * cw), bordy + baseline)
    Text(rp, ' ', 1)
    Text(rp, s, EstrLen(s))
    Text(rp, ' ', 1)
  ENDFOR
  SetBPen(rp, 0)
ENDPROC

PROC drawrow(p, r)
  DEF idx, x, y, s, l, pw
  x := panex(p)
  y := panetop + (r * ch)
  pw := Mul(panew(p), cw)
  idx := etop[p] + r
  SetAPen(rp, 0)
  RectFill(rp, x, y, x + pw - 1, y + ch - 1)
  IF efail[p]
    IF r = 0
      s := 'cannot read this directory'
      SetAPen(rp, errpen)
      SetBPen(rp, 0)
      Move(rp, x, y + baseline)
      Text(rp, s, StrLen(s))
    ENDIF
    RETURN
  ENDIF
  IF idx >= ecount[p] THEN RETURN
  s := enames[(p * MAXENT) + idx]
  l := EstrLen(s)
  IF l > (panew(p) - (IF emark[(p * MAXENT) + idx] THEN 1 ELSE 0))
    l := panew(p) - (IF emark[(p * MAXENT) + idx] THEN 1 ELSE 0)
  ENDIF
  IF (p = active) AND (idx = esel[p])
    -> the bar keeps the entry's type colour: blue text for a
    -> directory, grey for a file (unless the fallback screen left
    -> dirpen = txtpen, which would vanish into the bar)
    SetAPen(rp, txtpen)
    RectFill(rp, x, y, x + pw - 1, y + ch - 1)
    IF edirs[(p * MAXENT) + idx] AND (dirpen <> txtpen)
      SetAPen(rp, dirpen)
    ELSE
      SetAPen(rp, 0)
    ENDIF
    SetBPen(rp, txtpen)
  ELSE
    SetAPen(rp, IF edirs[(p * MAXENT) + idx] THEN dirpen ELSE txtpen)
    SetBPen(rp, 0)
  ENDIF
  Move(rp, x, y + baseline)
  IF emark[(p * MAXENT) + idx] THEN Text(rp, '*', 1)
  Text(rp, s, l)
  SetBPen(rp, 0)
ENDPROC

PROC drawpane(p)
  DEF r
  FOR r := 0 TO visrows - 1
    drawrow(p, r)
  ENDFOR
ENDPROC

PROC drawall()
  drawframe()
  drawpaths()
  drawpane(0)
  drawpane(1)
ENDPROC

-> re-read and redraw everything (the full frame redraw also erases
-> whatever a prompt or the progress bar left behind)
PROC refreshall()
  readpane(0)
  readpane(1)
  drawall()
ENDPROC

-> select the entry named in prevname (if present), centre it, redraw
PROC selectbyname(p)
  DEF i, b
  IF ecount[p] > 0
    b := p * MAXENT
    FOR i := 0 TO ecount[p] - 1
      IF nccmp(enames[b + i], prevname) = 0 THEN esel[p] := i
    ENDFOR
    etop[p] := esel[p] - (visrows / 2)
    IF etop[p] > (ecount[p] - visrows) THEN etop[p] := ecount[p] - visrows
    IF etop[p] < 0 THEN etop[p] := 0
  ENDIF
  drawpane(p)
ENDPROC

-> prompts and messages live on the border row above the panes,
-> dressed per his layout: text between the guillemets instead of
-> over the dashes. The paths return afterwards (drawpaths).
PROC promptrow(s)
  DEF l
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0, bordy + baseline)
  Text(rp, promptbuf, ncols)
  l := StrLen(s)
  IF l > (ncols - 7) THEN l := ncols - 7
  Move(rp, x0 + (4 * cw), bordy + baseline)
  Text(rp, s, l)
ENDPROC

-> switch the frame into console/view dress: row 6 closes the top,
-> the footer offers the way back (his console-and-view-layout)
PROC drawviewframe(showesc)
  DEF r
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0, bordy + baseline)    -> grid row 5, closed border
  Text(rp, viewbuf, ncols)
  FOR r := 0 TO 2    -> the footer rows
    Move(rp, x0, top + ((nrows - 3 + r) * ch) + baseline)
    Text(rp, viewbuf + Mul(r + 1, ncols), ncols)
  ENDFOR
  IF showesc = FALSE
    -> the console is left by any key, so the footer offer is blanked
    Move(rp, x0 + (vescol * cw), top + ((nrows - 2) * ch) + baseline)
    Text(rp, {spaces}, 25)
  ENDIF
ENDPROC

PROC showmsg(s)
  StrCopy(opmsg, s)    -> kept so a bulk run can re-show it after refresh
  promptrow(s)
  msgup := TRUE
ENDPROC

-> bring the stored message back on top after refreshall wiped it
PROC remsg()
  promptrow(opmsg)
  msgup := TRUE
ENDPROC

PROC clearmsg()
  IF msgup
    drawpaths()
    msgup := FALSE
  ENDIF
ENDPROC

PROC showfault(prefix, err)
  DEF fb[84]:STRING, mb[120]:STRING
  Fault(err, NIL, fb, 80)
  SetStr(fb, StrLen(fb))
  StringF(mb, '\s: \s', prefix, fb)
  showmsg(mb)
ENDPROC

PROC faultmsg(prefix)
  showfault(prefix, IoErr())
ENDPROC

-> wait for the next vanilla key (prompts ignore everything else)
PROC waitvanilla()
  DEF class, code
  REPEAT
    class := WaitIMessage(win)
    code := MsgCode()
  UNTIL class = IDCMP_VANILLAKEY
ENDPROC code

-> the edit field is a fixed max+1 cells wide and fully redrawn in
-> place each keystroke (JAM2 over the old content) - the border art
-> is drawn once when the editor opens and never again, so nothing
-> shows through between keystrokes
PROC drawinput(prompt, buf, cpos, max)
  DEF pl, l, s:PTR TO CHAR, pad
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  pl := StrLen(prompt)
  s := buf
  l := EstrLen(buf)
  Move(rp, x0 + (4 * cw), bordy + baseline)
  Text(rp, prompt, pl)
  IF cpos > 0 THEN Text(rp, s, cpos)
  SetAPen(rp, 0)    -> the cursor cell, inverted
  SetBPen(rp, txtpen)
  IF cpos < l
    Text(rp, s + cpos, 1)
  ELSE
    Text(rp, ' ', 1)
  ENDIF
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  IF cpos < l THEN Text(rp, s + cpos + 1, l - cpos - 1)
  pad := max + 1 - IF cpos < l THEN l ELSE l + 1
  IF pad > 80 THEN pad := 80
  IF pad > 0 THEN Text(rp, {spaces}, pad)
ENDPROC

-> in-place line editor on the border row: returns 1 on Return, 0 on
-> Esc. Left/Right move the cursor, Backspace deletes before it, Del
-> under it, typing inserts. names=TRUE refuses "/" and ":" (object
-> names, never paths); FALSE takes anything (shell commands).
PROC lineinput(prompt, buf, max, names)
  DEF class, code, l, i, res=-2, s:PTR TO CHAR, cpos
  s := buf
  -> a prefill longer than the field (a long-name filesystem entry)
  -> is truncated - the new name is capped at max anyway
  IF EstrLen(buf) > max THEN SetStr(buf, max)
  cpos := EstrLen(buf)
  promptrow('')    -> dress the row once; the field is fixed-width
  drawinput(prompt, buf, cpos, max)
  WHILE res = -2
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      IF code = 13
        res := 1
      ELSEIF code = 27
        res := 0
      ELSEIF code = 8    -> backspace: delete before the cursor
        IF cpos > 0
          l := EstrLen(buf)
          FOR i := cpos TO l - 1
            s[i - 1] := s[i]
          ENDFOR
          SetStr(buf, l - 1)
          cpos := cpos - 1
          drawinput(prompt, buf, cpos, max)
        ENDIF
      ELSEIF code = 127    -> Del: delete under the cursor
        l := EstrLen(buf)
        IF cpos < l
          FOR i := cpos + 1 TO l - 1
            s[i - 1] := s[i]
          ENDFOR
          SetStr(buf, l - 1)
          drawinput(prompt, buf, cpos, max)
        ENDIF
      ELSEIF (code >= 32) AND (code <= 255) AND
             ((names = FALSE) OR ((code <> "/") AND (code <> ":")))
        l := EstrLen(buf)
        IF l < max
          FOR i := l TO cpos + 1 STEP -1    -> insert at the cursor
            s[i] := s[i - 1]
          ENDFOR
          s[cpos] := code
          SetStr(buf, l + 1)
          cpos := cpos + 1
          drawinput(prompt, buf, cpos, max)
        ENDIF
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80
        IF code = RK_LEFT
          IF MsgQualifier() AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            cpos := 0    -> Shift: start of the line
          ELSEIF cpos > 0
            cpos := cpos - 1
          ENDIF
          drawinput(prompt, buf, cpos, max)
        ELSEIF code = RK_RIGHT
          IF MsgQualifier() AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            cpos := EstrLen(buf)    -> Shift: end of the line
          ELSEIF cpos < EstrLen(buf)
            cpos := cpos + 1
          ENDIF
          drawinput(prompt, buf, cpos, max)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC res

PROC moveup()
  DEF p
  p := active
  IF efail[p] THEN RETURN
  IF esel[p] <= 0 THEN RETURN
  esel[p] := esel[p] - 1
  IF esel[p] < etop[p]
    etop[p] := esel[p]
    drawpane(p)
  ELSE
    drawrow(p, esel[p] + 1 - etop[p])
    drawrow(p, esel[p] - etop[p])
  ENDIF
ENDPROC

PROC movedown()
  DEF p
  p := active
  IF efail[p] THEN RETURN
  IF esel[p] >= (ecount[p] - 1) THEN RETURN
  esel[p] := esel[p] + 1
  IF esel[p] >= (etop[p] + visrows)
    etop[p] := esel[p] - visrows + 1
    drawpane(p)
  ELSE
    drawrow(p, esel[p] - 1 - etop[p])
    drawrow(p, esel[p] - etop[p])
  ENDIF
ENDPROC

-> jump the selection by delta (page moves and first/last), keeping
-> it visible; the window jumps with it
PROC pagemove(delta)
  DEF p, ns
  p := active
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  ns := esel[p] + delta
  IF ns > (ecount[p] - 1) THEN ns := ecount[p] - 1
  IF ns < 0 THEN ns := 0
  IF ns = esel[p] THEN RETURN
  esel[p] := ns
  IF esel[p] < etop[p] THEN etop[p] := esel[p]
  IF esel[p] >= (etop[p] + visrows) THEN etop[p] := esel[p] - visrows + 1
  drawpane(p)
ENDPROC

PROC switchpane()
  DEF old
  old := active
  active := IF active = 0 THEN 1 ELSE 0
  drawpaths()
  drawrow(old, esel[old] - etop[old])
  drawrow(active, esel[active] - etop[active])
ENDPROC

PROC enterdir()
  DEF p, i
  p := active
  IF efail[p] THEN RETURN
  IF ecount[p] = 0 THEN RETURN
  i := (p * MAXENT) + esel[p]
  IF edirs[i] = 0 THEN RETURN    -> files do nothing yet (viewer later)
  IF involume(p)
    StrCopy(ppath[p], enames[i])    -> a volume entry IS the new root
  ELSE
    AddPart(ppath[p], enames[i], CPATHLEN - 4)
    SetStr(ppath[p], StrLen(ppath[p]))
  ENDIF
  esel[p] := 0
  etop[p] := 0
  readpane(p)
  drawpaths()
  drawpane(p)
ENDPROC

PROC parentdir()
  DEF p, s:PTR TO CHAR, l, i, cut=-1, colon=-1, start
  p := active
  s := ppath[p]
  l := EstrLen(ppath[p])
  IF l = 0 THEN RETURN    -> already at the volume list
  FOR i := 0 TO l - 1
    IF s[i] = "/" THEN cut := i
    IF s[i] = ":" THEN colon := i
  ENDFOR
  start := IF cut >= 0 THEN cut + 1 ELSE colon + 1
  IF start >= l
    -> at a device root: up to the volume list. The root name is kept
    -> for re-selection - it matches when the pane came from the list
    StrCopy(prevname, ppath[p])
    SetStr(ppath[p], 0)
  ELSE
    MidStr(prevname, ppath[p], start, l - start)
    SetStr(ppath[p], IF cut >= 0 THEN cut ELSE colon + 1)
  ENDIF
  esel[p] := 0
  etop[p] := 0
  readpane(p)
  drawpaths()
  selectbyname(p)    -> re-select the directory we just came out of
ENDPROC

PROC buildfull(dst, dir, name)
  StrCopy(dst, dir)
  AddPart(dst, name, CPATHLEN - 4)
  SetStr(dst, StrLen(dst))
ENDPROC

-> 0 = does not exist, 1 = file, 2 = directory
PROC pathtype(path)
  DEF lock, fib:PTR TO fileinfoblock, t=0
  IF lock := Lock(path, SHARED_LOCK)
    t := 1
    IF fib := AllocDosObject(DOS_FIB, NIL)
      IF Examine(lock, fib)
        IF fib.direntrytype > 0 THEN t := 2
      ENDIF
      FreeDosObject(DOS_FIB, fib)
    ENDIF
    UnLock(lock)
  ENDIF
ENDPROC t

-> TRUE if both paths lock and are the same object. Guards against
-> copying a file onto itself through an aliased path (DH0: vs its
-> volume name). NOTE: only real AmigaOS answers this faithfully -
-> vamos' SameLock is known-broken.
PROC samefile(a, b)
  DEF la, lb, same=FALSE
  IF la := Lock(a, SHARED_LOCK)
    IF lb := Lock(b, SHARED_LOCK)
      IF SameLock(la, lb) = LOCK_SAME THEN same := TRUE
      UnLock(lb)
    ENDIF
    UnLock(la)
  ENDIF
ENDPROC same

-> carry protection bits, datestamp and comment over to the copy
PROC copyattribs(src, dst)
  DEF lock, fib:PTR TO fileinfoblock
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL THEN RETURN
  IF lock := Lock(src, SHARED_LOCK)
    IF Examine(lock, fib)
      UnLock(lock)
      SetProtection(dst, fib.protection)
      SetFileDate(dst, fib.datestamp)
      IF fib.comment[0] <> 0 THEN SetComment(dst, fib.comment)
    ELSE
      UnLock(lock)
    ENDIF
  ENDIF
  FreeDosObject(DOS_FIB, fib)
ENDPROC

PROC copyfile(src, dst)
  DEF fhs=NIL, fhd=NIL, n, w, ok=TRUE, err=0
  IF (fhs := Open(src, OLDFILE)) = NIL
    faultmsg('cannot read the source')
    RETURN FALSE
  ENDIF
  IF (fhd := Open(dst, NEWFILE)) = NIL
    Close(fhs)
    faultmsg('cannot write the target')
    RETURN FALSE
  ENDIF
  REPEAT
    n := Read(fhs, copybuf, CBUFSZ)
    IF n < 0
      ok := FALSE
      err := IoErr()
    ENDIF
    IF ok
      IF n > 0
        w := Write(fhd, copybuf, n)
        IF w <> n
          ok := FALSE
          err := IoErr()
        ELSE
          progadd(n)
        ENDIF
      ENDIF
    ENDIF
  UNTIL (n <= 0) OR (ok = FALSE)
  Close(fhd)
  Close(fhs)
  IF ok = FALSE
    DeleteFile(dst)    -> no partial targets
    showfault('copy failed', err)
    RETURN FALSE
  ENDIF
  copyattribs(src, dst)
ENDPROC TRUE

-> ---- the progress bar (his mockup: a bordered box, centered, the
-> ---- fill is a black rectangle growing left to right) --------------

PROC progshow(total)
  DEF r
  progtotal := IF total < 1 THEN 1 ELSE total
  progdone := 0
  progpx := 0
  progon := TRUE
  progx := x0 + (((ncols - 33) / 2) * cw)    -> 33 cells, centered
  progy := top + (((nrows / 2) - 2) * ch)
  -> the box is an overlay of exactly its own footprint: the three
  -> JAM2 rows paint every cell of it (borders and interior), and
  -> whatever is around it stays put right up to the edge
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR r := 0 TO 2
    Move(rp, progx, progy + (r * ch) + baseline)
    Text(rp, {progart} + (r * 33), 33)
  ENDFOR
ENDPROC

-> add finished units and grow the fill. The maths stay inside the
-> 68000's 16-bit mul/div limits: both sides are shifted down until
-> the total fits, and Mul/Div are the 32-bit-safe library routines.
PROC progadd(n)
  DEF t, d, px
  IF progon = FALSE THEN RETURN
  progdone := progdone + n
  t := progtotal
  d := progdone
  WHILE t > 30000
    t := Shr(t, 1)
    d := Shr(d, 1)
  ENDWHILE
  IF t < 1 THEN t := 1
  IF d < 0 THEN d := 0
  IF d > t THEN d := t
  px := Div(Mul(d, Mul(31, cw)), t)    -> the 31-cell interior
  IF px > progpx
    SetAPen(rp, txtpen)
    RectFill(rp, progx + cw + progpx, progy + ch,
             progx + cw + px - 1, progy + ch + ch - 1)
    progpx := px
  ENDIF
ENDPROC

PROC progoff()
  progon := FALSE
ENDPROC

-> ---- recursive helpers ---------------------------------------------

-> pre-scan a directory tree: counts every entry into statfiles and
-> sums file bytes into statbytes (progress denominators only, so
-> errors are simply ignored)
PROC treestat(path, depth)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, more, child
  IF depth > 20 THEN RETURN
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL THEN RETURN
  IF (child := String(CPATHLEN)) = NIL
    FreeDosObject(DOS_FIB, fib)
    RETURN
  ENDIF
  IF lock := Lock(path, SHARED_LOCK)
    IF Examine(lock, fib)
      more := ExNext(lock, fib)
      WHILE more
        statfiles := statfiles + 1
        IF fib.direntrytype > 0
          StrCopy(child, path)
          AddPart(child, fib.filename, CPATHLEN - 4)
          SetStr(child, StrLen(child))
          treestat(child, depth + 1)
        ELSE
          statbytes := statbytes + fib.size
        ENDIF
        more := ExNext(lock, fib)
      ENDWHILE
    ENDIF
    UnLock(lock)
  ENDIF
  DisposeLink(child)
  FreeDosObject(DOS_FIB, fib)
ENDPROC

-> TRUE if directory b is (or lies inside) directory a: walk b's
-> parent chain comparing locks. Alias-proof on real AmigaOS; vamos'
-> SameLock is known-broken.
PROC insidedir(a, b)
  DEF la, l, pl, inside=FALSE
  IF (la := Lock(a, SHARED_LOCK)) = NIL THEN RETURN FALSE
  l := Lock(b, SHARED_LOCK)
  WHILE l
    IF SameLock(la, l) = LOCK_SAME
      inside := TRUE
      UnLock(l)
      l := NIL
    ELSE
      pl := ParentDir(l)
      UnLock(l)
      l := pl
    ENDIF
  ENDWHILE
  UnLock(la)
ENDPROC inside

-> copy a directory tree. The target may already exist (a merge:
-> files of the same name are overwritten). Path buffers per level
-> come from the heap - E cannot size its stack for deep recursion.
PROC copytree(src, dst, depth)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, more, ok=TRUE, lk,
      csrc=NIL, cdst=NIL
  IF depth > 20
    showmsg('directory tree too deep')
    RETURN FALSE
  ENDIF
  lk := CreateDir(dst)
  IF lk
    UnLock(lk)
  ELSE
    IF pathtype(dst) <> 2
      faultmsg('cannot create the target directory')
      RETURN FALSE
    ENDIF
  ENDIF
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL THEN RETURN FALSE
  csrc := String(CPATHLEN)
  cdst := String(CPATHLEN)
  IF (csrc = NIL) OR (cdst = NIL)
    IF csrc THEN DisposeLink(csrc)
    IF cdst THEN DisposeLink(cdst)
    FreeDosObject(DOS_FIB, fib)
    RETURN FALSE
  ENDIF
  IF (lock := Lock(src, SHARED_LOCK)) = NIL
    faultmsg('cannot read the source')
    ok := FALSE
  ELSE
    IF Examine(lock, fib) = FALSE THEN ok := FALSE
    IF ok
      more := ExNext(lock, fib)
      WHILE more AND ok    -> plain flags: safe despite E's eager AND
        StrCopy(csrc, src)
        AddPart(csrc, fib.filename, CPATHLEN - 4)
        SetStr(csrc, StrLen(csrc))
        StrCopy(cdst, dst)
        AddPart(cdst, fib.filename, CPATHLEN - 4)
        SetStr(cdst, StrLen(cdst))
        IF fib.direntrytype > 0
          ok := copytree(csrc, cdst, depth + 1)
        ELSE
          ok := copyfile(csrc, cdst)
        ENDIF
        IF ok THEN more := ExNext(lock, fib)
      ENDWHILE
    ENDIF
    UnLock(lock)
  ENDIF
  DisposeLink(csrc)
  DisposeLink(cdst)
  FreeDosObject(DOS_FIB, fib)
  IF ok THEN copyattribs(src, dst)
ENDPROC ok

-> delete a directory tree, then the directory itself. Children are
-> taken one at a time with a fresh scan each round - deleting during
-> an ExNext walk would invalidate it. tick = count entries on the
-> progress bar (deletes use entry units, copies use byte units).
-> An entry that will not go (protection, or a name the handler
-> cannot resolve back - seen with FS-UAE directory drives and
-> non-ASCII names) is put on a skip list and the rest of the tree
-> still gets deleted; every undeletable entry counts into gfails
-> and the caller reports the total.
PROC deltree(path, depth, tick)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, ok, got, isdir=FALSE,
      nm[108]:STRING, child, pm[130]:STRING,
      skip[16]:ARRAY OF LONG, nskip=0, j, more, over, sawany=FALSE
  IF depth > 20
    showmsg('directory tree too deep')
    gfails := gfails + 1
    RETURN FALSE
  ENDIF
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL THEN RETURN FALSE
  IF (child := String(CPATHLEN)) = NIL
    FreeDosObject(DOS_FIB, fib)
    RETURN FALSE
  ENDIF
  REPEAT
    got := FALSE
    IF (lock := Lock(path, SHARED_LOCK)) = NIL
      StringF(pm, 'cannot read "\s"', FilePart(path))
      faultmsg(pm)
      nskip := 999    -> cannot even scan: give up on this level
    ELSE
      IF Examine(lock, fib)
        -> first child that is not on the skip list
        more := ExNext(lock, fib)
        WHILE more AND (got = FALSE)
          over := FALSE
          IF nskip > 0
            FOR j := 0 TO nskip - 1
              IF nccmp(fib.filename, skip[j]) = 0 THEN over := TRUE
            ENDFOR
          ENDIF
          IF over
            more := ExNext(lock, fib)
          ELSE
            got := TRUE
            sawany := TRUE
            StrCopy(nm, fib.filename)
            isdir := fib.direntrytype > 0
          ENDIF
        ENDWHILE
      ENDIF
      UnLock(lock)
    ENDIF
    IF got
      StrCopy(child, path)
      AddPart(child, nm, CPATHLEN - 4)
      SetStr(child, StrLen(child))
      IF isdir
        ok := deltree(child, depth + 1, tick)
      ELSE
        IF (ok := zap(child, TRUE))
          IF tick THEN progadd(1)
        ELSE
          StringF(pm, 'cannot delete "\s"', nm)
          faultmsg(pm)
          gfails := gfails + 1
        ENDIF
      ENDIF
      IF ok = FALSE
        -> leave it behind and carry on with its siblings
        IF nskip < 16
          IF (skip[nskip] := String(108)) = NIL
            nskip := 999
          ELSE
            StrCopy(skip[nskip], nm)
            nskip := nskip + 1
          ENDIF
        ELSE
          nskip := 999    -> too many failures here: stop this level
        ENDIF
      ENDIF
    ENDIF
  UNTIL (got = FALSE) OR (nskip > 16)
  IF nskip > 0
    IF nskip <= 16
      FOR j := 0 TO nskip - 1
        DisposeLink(skip[j])
      ENDFOR
    ENDIF
    ok := FALSE
    gfails := gfails + 1    -> the directory itself stays behind
  ELSE
    IF (ok := zap(path, TRUE))
      IF tick THEN progadd(1)
    ELSE
      IF (IoErr() = ERROR_DIRECTORY_NOT_EMPTY) AND (sawany = FALSE)
        -> nothing was listed, yet DOS says not empty: an entry the
        -> filesystem cannot show us (FS-UAE hides host names it
        -> cannot decode) - no Amiga-side program can remove it
        StringF(pm, '"\s": invisible entries remain', FilePart(path))
        showmsg(pm)
      ELSE
        StringF(pm, 'cannot delete "\s"', FilePart(path))
        faultmsg(pm)
      ENDIF
      gfails := gfails + 1
    ENDIF
  ENDIF
  DisposeLink(child)
  FreeDosObject(DOS_FIB, fib)
ENDPROC ok

-> DeleteFile with DOpus's policies: an object that is already gone
-> counts as deleted, and a protected object is unprotected and
-> retried. ask=TRUE puts the question first - "(y)es (n)o (a)ll",
-> where a covers the rest of the run; ask=FALSE unprotects silently
-> (transfers: the user already chose overwrite/move, DOpus's
-> unprotect=1 cases).
PROC zap(path, ask)
  DEF err, k, pm[130]:STRING
  IF DeleteFile(path) THEN RETURN TRUE
  err := IoErr()
  IF err = ERROR_OBJECT_NOT_FOUND THEN RETURN TRUE
  IF err = ERROR_DIRECTORY_NOT_EMPTY THEN RETURN FALSE  -> no bit fixes that
  IF ask
    IF unprotall = FALSE
      StringF(pm, '"\s" is protected - unprotect? (y)es (n)o (a)ll',
              FilePart(path))
      promptrow(pm)
      k := waitvanilla()
      IF (k = "a") OR (k = "A")
        unprotall := TRUE
      ELSEIF (k = "y") OR (k = "Y")
        -> just this one
      ELSE
        RETURN FALSE
      ENDIF
    ENDIF
  ENDIF
  SetProtection(path, 0)    -> whatever bit is in the way, clear the lot
  IF DeleteFile(path) THEN RETURN TRUE
ENDPROC FALSE

-> guards shared by every operation on the current selection; returns
-> the entry index or -1 (with the reason on the message row)
PROC opentry()
  DEF p
  p := active
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN -1
  ENDIF
  IF efail[p] THEN RETURN -1
  IF ecount[p] = 0 THEN RETURN -1
ENDPROC (p * MAXENT) + esel[p]

-> resolve ONE entry's target name - collision prompts, no file I/O.
-> Fills tname. Returns 1 go, 0 skip this one, -1 refused (message
-> stored), -2 Esc: give up on the whole run. Since resolution runs
-> BEFORE any transfer, -1/-2 cancel the run with nothing changed.
PROC resolveone(p, q, name, isdir, force, tname)
  DEF k, t, go=FALSE,
      src[310]:STRING, dst[310]:STRING, mb[120]:STRING
  buildfull(src, ppath[p], name)
  StrCopy(tname, name)
  REPEAT
    buildfull(dst, ppath[q], tname)
    t := pathtype(dst)
    IF t = 0
      go := TRUE
    ELSE
      IF samefile(src, dst)
        showmsg('source and target are the same file')
        RETURN -1
      ENDIF
      IF force
        k := "o"
      ELSE
        StringF(mb, '"\s" exists: (s)kip (o)verwrite (r)ename?', tname)
        promptrow(mb)
        k := waitvanilla()
      ENDIF
      IF (k = "o") OR (k = "O")
        IF isdir
          IF t = 1
            showmsg('a file with the target name is in the way')
            RETURN -1
          ENDIF
          -> t = 2: merge into the existing directory
        ELSE
          IF t = 2
            showmsg('the target exists as a directory')
            RETURN -1
          ENDIF
        ENDIF
        go := TRUE
      ELSEIF (k = "r") OR (k = "R")
        IF lineinput('new name: ', tname, 30, TRUE) = 0
          drawpaths()
          RETURN 0
        ENDIF
        IF EstrLen(tname) = 0
          drawpaths()
          RETURN 0
        ENDIF
      ELSEIF k = 27    -> Esc gives up on the whole run
        drawpaths()
        RETURN -2
      ELSE    -> s, or anything else: skip this one
        drawpaths()
        RETURN 0
      ENDIF
    ENDIF
  UNTIL go
  IF isdir
    IF insidedir(src, ppath[q])
      showmsg('the target is inside the source')
      RETURN -1
    ENDIF
  ENDIF
ENDPROC 1

-> transfer ONE resolved entry - file I/O only, never a prompt.
-> Returns 1 done, -1 failed (message stored).
PROC transferone(p, q, name, tname, isdir, ismove, samevol)
  DEF src[310]:STRING, dst[310]:STRING, t
  buildfull(src, ppath[p], name)
  buildfull(dst, ppath[q], tname)
  IF ismove
    IF samevol
      t := pathtype(dst)
      IF t > 0
        -> Rename cannot land on an existing name; o/force said
        -> replace (a merge of directories cannot Rename: a full
        -> target reports "not empty" here)
        IF zap(dst, FALSE) = FALSE
          faultmsg('cannot replace the target')
          RETURN -1
        ENDIF
      ENDIF
      IF Rename(src, dst) = FALSE
        faultmsg('cannot move')
        RETURN -1
      ENDIF
    ELSE
      IF isdir
        IF copytree(src, dst, 0) = FALSE THEN RETURN -1
        IF deltree(src, 0, FALSE) = FALSE THEN RETURN -1
      ELSE
        IF copyfile(src, dst) = FALSE THEN RETURN -1
        IF zap(src, FALSE) = FALSE
          faultmsg('copied, but cannot delete the source')
          RETURN -1
        ENDIF
      ENDIF
    ENDIF
  ELSE
    IF isdir
      IF copytree(src, dst, 0) = FALSE THEN RETURN -1
    ELSE
      IF copyfile(src, dst) = FALSE THEN RETURN -1
    ENDIF
  ENDIF
ENDPROC 1

-> copy or move to the other pane: the marked set if the active pane
-> has marks, the selection otherwise. force = overwrite collisions.
-> Three phases: (1) resolve every collision up front - any refusal
-> or Esc cancels with nothing changed; (2) pre-scan the resolved set
-> for the progress denominator; (3) transfer it all in one go, the
-> bar running uninterrupted.
PROC doxfer(ismove, force)
  DEF p, q, i, b, s, nmark, nsel=0, r, la, lb, samevol=TRUE,
      anydir=FALSE, showbar=FALSE, haderr=FALSE,
      tname[110]:STRING, tpath[310]:STRING
  p := active
  q := IF p = 0 THEN 1 ELSE 0
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  IF involume(q)
    showmsg('the other pane shows volumes - enter one first')
    RETURN
  ENDIF
  IF efail[q]
    showmsg('the other pane has no readable directory')
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  -> one volume or two? (decides Rename vs copy+delete for the run)
  la := Lock(ppath[p], SHARED_LOCK)
  lb := Lock(ppath[q], SHARED_LOCK)
  IF la
    IF lb
      IF SameLock(la, lb) < 0 THEN samevol := FALSE
    ENDIF
  ENDIF
  IF la THEN UnLock(la)
  IF lb THEN UnLock(lb)
  -> phase 1: resolve the whole set before touching anything
  IF nmark > 0
    FOR i := 0 TO ecount[p] - 1
      IF emark[b + i]
        r := resolveone(p, q, enames[b + i], edirs[b + i] <> 0,
                        force, tname)
        IF r < 0 THEN RETURN    -> refused/Esc: nothing has happened
        IF r = 1
          IF nsel >= ralloc
            IF (rnames[nsel] := String(110)) = NIL THEN Raise("MEM")
            ralloc := nsel + 1
          ENDIF
          StrCopy(rnames[nsel], tname)
          ridx[nsel] := i
          nsel := nsel + 1
        ENDIF
      ENDIF
    ENDFOR
  ELSE
    i := esel[p]
    r := resolveone(p, q, enames[b + i], edirs[b + i] <> 0,
                    force, tname)
    IF r < 0 THEN RETURN
    IF r = 1
      IF ralloc = 0
        IF (rnames[0] := String(110)) = NIL THEN Raise("MEM")
        ralloc := 1
      ENDIF
      StrCopy(rnames[0], tname)
      ridx[0] := i
      nsel := 1
    ENDIF
  ENDIF
  IF nsel = 0 THEN RETURN    -> everything was skipped
  -> phase 2: a same-volume move is all Renames - instant, no bar;
  -> everything else gets a byte pre-scan for the denominator
  IF (ismove AND samevol) = FALSE
    statbytes := 0
    statfiles := 0
    FOR s := 0 TO nsel - 1
      i := ridx[s]
      IF edirs[b + i]
        anydir := TRUE
        buildfull(tpath, ppath[p], enames[b + i])
        treestat(tpath, 0)
      ELSE
        statbytes := statbytes + esize[b + i]
      ENDIF
    ENDFOR
    IF anydir OR (nsel > 1) OR (statbytes > 131072) THEN showbar := TRUE
    IF showbar THEN progshow(statbytes)
  ENDIF
  -> phase 3: transfer, no questions left to ask
  FOR s := 0 TO nsel - 1
    IF haderr = FALSE
      i := ridx[s]
      r := transferone(p, q, enames[b + i], rnames[s],
                       edirs[b + i] <> 0, ismove, samevol)
      IF r < 0 THEN haderr := TRUE
    ENDIF
  ENDFOR
  progoff()
  refreshall()
  IF haderr THEN remsg()
ENDPROC

PROC delone(p, i)
  DEF dpath[310]:STRING, ok, pm[130]:STRING
  buildfull(dpath, ppath[p], enames[i])
  IF edirs[i]
    ok := deltree(dpath, 0, TRUE)
  ELSE
    IF zap(dpath, TRUE)
      progadd(1)
      ok := TRUE
    ELSE
      StringF(pm, 'cannot delete "\s"', enames[i])
      faultmsg(pm)
      gfails := gfails + 1
      ok := FALSE
    ENDIF
  ENDIF
ENDPROC ok

-> delete the marked set (one confirmation for the lot) or the
-> selection. Directories go recursively, contents and all.
PROC dodelete()
  DEF p, i, b, k, nmark, showbar=FALSE,
      dpath[310]:STRING, mb[120]:STRING
  p := active
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  b := p * MAXENT
  nmark := markcount(p)
  IF nmark > 0
    StringF(mb, 'delete \d marked entries? (y)es (n)o', nmark)
  ELSEIF edirs[b + esel[p]]
    StringF(mb, 'delete "\s" and all contents? (y)es (n)o',
            enames[b + esel[p]])
  ELSE
    StringF(mb, 'delete "\s"? (y)es (n)o', enames[b + esel[p]])
  ENDIF
  promptrow(mb)
  k := waitvanilla()
  IF (k <> "y") AND (k <> "Y")
    drawpaths()
    RETURN
  ENDIF
  -> deletes tick per entry, so pre-count the entries
  statbytes := 0
  statfiles := 0
  IF nmark > 0
    FOR i := 0 TO ecount[p] - 1
      IF emark[b + i]
        statfiles := statfiles + 1
        IF edirs[b + i]
          buildfull(dpath, ppath[p], enames[b + i])
          treestat(dpath, 0)
        ENDIF
      ENDIF
    ENDFOR
  ELSE
    statfiles := 1
    IF edirs[b + esel[p]]
      buildfull(dpath, ppath[p], enames[b + esel[p]])
      treestat(dpath, 0)
    ENDIF
  ENDIF
  IF statfiles > 10 THEN showbar := TRUE
  IF showbar THEN progshow(statfiles)
  -> one stubborn entry must not stop the rest of the run
  gfails := 0
  unprotall := FALSE
  IF nmark > 0
    FOR i := 0 TO ecount[p] - 1
      IF emark[b + i] THEN delone(p, b + i)
    ENDFOR
  ELSE
    delone(p, b + esel[p])
  ENDIF
  progoff()
  refreshall()
  IF gfails = 1
    -> the stored fault text says which entry and why
    remsg()
  ELSEIF gfails > 1
    StringF(mb, '\d entries not deleted - last: \s', gfails, opmsg)
    showmsg(mb)
  ENDIF
ENDPROC

-> ---- the info/protect window ---------------------------------------

-> one line inside the info box, padded to the full 31-cell interior
PROC infline(xx, yy, row, s)
  DEF l
  l := StrLen(s)
  IF l > 31 THEN l := 31
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, xx + cw, yy + (row * ch) + baseline)
  Text(rp, s, l)
  IF l < 31 THEN Text(rp, {spaces}, 31 - l)
ENDPROC

-> the classic hsparwed string: h/s/p/a show when SET, r/w/e/d show
-> when CLEAR (the AmigaDOS inversion: a set bit denies the access)
PROC flagstr(dst, mask)
  DEF s:PTR TO CHAR
  s := dst
  s[0] := IF mask AND FIBF_HOLD    THEN "h" ELSE "-"
  s[1] := IF mask AND FIBF_SCRIPT  THEN "s" ELSE "-"
  s[2] := IF mask AND FIBF_PURE    THEN "p" ELSE "-"
  s[3] := IF mask AND FIBF_ARCHIVE THEN "a" ELSE "-"
  s[4] := IF mask AND FIBF_READ    THEN "-" ELSE "r"
  s[5] := IF mask AND FIBF_WRITE   THEN "-" ELSE "w"
  s[6] := IF mask AND FIBF_EXECUTE THEN "-" ELSE "e"
  s[7] := IF mask AND FIBF_DELETE  THEN "-" ELSE "d"
  SetStr(dst, 8)
ENDPROC

-> i: a floating window (exact footprint, like the progress box) with
-> the entry's details; h/s/p/a/r/w/e/d toggle the protection bits
-> live via SetProtection, Esc closes
PROC infowindow()
  DEF p, i, xx, yy, r, k, mask, isdir, done=FALSE, changed,
      fpath[310]:STRING, lock=NIL, fib=NIL:PTR TO fileinfoblock,
      dtb[26]:ARRAY OF CHAR, dt:PTR TO datetime,
      db[20]:ARRAY OF CHAR, tb[20]:ARRAY OF CHAR,
      fl[10]:STRING, cmt[80]:STRING, ln[40]:STRING
  p := active
  IF involume(p)
    showmsg('no file information in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  i := (p * MAXENT) + esel[p]
  buildfull(fpath, ppath[p], enames[i])
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL THEN RETURN
  IF (lock := Lock(fpath, SHARED_LOCK)) = NIL
    FreeDosObject(DOS_FIB, fib)
    faultmsg('cannot examine')
    RETURN
  ENDIF
  IF Examine(lock, fib) = FALSE
    UnLock(lock)
    FreeDosObject(DOS_FIB, fib)
    faultmsg('cannot examine')
    RETURN
  ENDIF
  UnLock(lock)
  -> copy everything out of the fib, then let go of it
  mask := fib.protection
  isdir := fib.direntrytype > 0
  dt := dtb
  CopyMem(fib.datestamp, dt, 12)
  dt.format := FORMAT_DOS
  dt.flags := 0
  dt.strday := NIL
  dt.strdate := db
  dt.strtime := tb
  IF DateToStr(dt) = FALSE
    db[0] := 0
    tb[0] := 0
  ENDIF
  StrCopy(cmt, fib.comment)
  FreeDosObject(DOS_FIB, fib)
  -> the box: 8 rows, borders from the progress art (same width)
  xx := x0 + (((ncols - 33) / 2) * cw)
  yy := top + (((nrows / 2) - 4) * ch)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, xx, yy + baseline)
  Text(rp, {progart}, 33)
  FOR r := 1 TO 6
    Move(rp, xx, yy + (r * ch) + baseline)
    Text(rp, {progart} + 33, 33)
  ENDFOR
  Move(rp, xx, yy + (7 * ch) + baseline)
  Text(rp, {progart} + 66, 33)
  infline(xx, yy, 1, enames[i])
  IF isdir
    infline(xx, yy, 2, 'size: (directory)')
  ELSE
    StringF(ln, 'size: \d bytes', esize[i])
    infline(xx, yy, 2, ln)
  ENDIF
  StringF(ln, 'date: \s \s', db, tb)
  infline(xx, yy, 3, ln)
  IF EstrLen(cmt) > 0
    StringF(ln, 'comment: \s', cmt)
  ELSE
    StrCopy(ln, 'comment: -')
  ENDIF
  infline(xx, yy, 5, ln)
  infline(xx, yy, 6, 'hsparwed = toggle - Esc = close')
  REPEAT
    flagstr(fl, mask)
    StringF(ln, 'flags: \s', fl)
    infline(xx, yy, 4, ln)
    k := waitvanilla()
    changed := FALSE
    IF k = 27
      done := TRUE
    ELSEIF (k = "h") OR (k = "H")
      mask := Eor(mask, FIBF_HOLD)
      changed := TRUE
    ELSEIF (k = "s") OR (k = "S")
      mask := Eor(mask, FIBF_SCRIPT)
      changed := TRUE
    ELSEIF (k = "p") OR (k = "P")
      mask := Eor(mask, FIBF_PURE)
      changed := TRUE
    ELSEIF (k = "a") OR (k = "A")
      mask := Eor(mask, FIBF_ARCHIVE)
      changed := TRUE
    ELSEIF (k = "r") OR (k = "R")
      mask := Eor(mask, FIBF_READ)
      changed := TRUE
    ELSEIF (k = "w") OR (k = "W")
      mask := Eor(mask, FIBF_WRITE)
      changed := TRUE
    ELSEIF (k = "e") OR (k = "E")
      mask := Eor(mask, FIBF_EXECUTE)
      changed := TRUE
    ELSEIF (k = "d") OR (k = "D")
      mask := Eor(mask, FIBF_DELETE)
      changed := TRUE
    ENDIF
    IF changed
      IF SetProtection(fpath, mask) = FALSE
        faultmsg('cannot set protection')
        done := TRUE
      ENDIF
    ENDIF
  UNTIL done
  drawall()
  IF msgup THEN remsg()
ENDPROC

-> ---- open and view (type dispatch by header sniffing) --------------

-> what is this file? Amiga magic is strong: hunk executables, lha,
-> LZX and zip have exact headers; text is "no NULs, nearly all
-> printable" over the first 512 bytes
PROC sniff(path)
  DEF fh, buf[520]:ARRAY OF CHAR, n, i, c, m, pr=0, esc=FALSE
  IF (fh := Open(path, OLDFILE)) = NIL THEN RETURN TY_OTHER
  n := Read(fh, buf, 512)
  Close(fh)
  IF n < 1 THEN RETURN TY_OTHER
  IF n >= 4
    IF (buf[0] = 0) AND (buf[1] = 0) AND (buf[2] = 3) AND (buf[3] = $F3)
      RETURN TY_EXEC
    ENDIF
    IF (buf[0] = "P") AND (buf[1] = "K") AND (buf[2] = 3) AND (buf[3] = 4)
      RETURN TY_ZIP
    ENDIF
    IF (buf[0] = "L") AND (buf[1] = "Z") AND (buf[2] = "X")
      RETURN TY_LZX
    ENDIF
  ENDIF
  IF n >= 7
    IF (buf[2] = "-") AND (buf[3] = "l") AND (buf[6] = "-")
      RETURN TY_LHA
    ENDIF
  ENDIF
  m := n
  FOR i := 0 TO m - 1
    c := buf[i]
    IF c = 0 THEN RETURN TY_OTHER
    IF ((c >= 32) AND (c <= 126)) OR (c = 9) OR (c = 10) OR
       (c = 13) OR (c >= 160) THEN pr := pr + 1
    IF c = 27    -> ESC: text with escape codes is ANSI art
      pr := pr + 1
      esc := TRUE
    ENDIF
  ENDFOR
  IF Mul(pr, 100) >= Mul(m, 95)
    RETURN IF esc THEN TY_ANSI ELSE TY_TEXT
  ENDIF
ENDPROC TY_OTHER

-> render one text line (tabs to 8-column stops, controls as dots)
-> into a 78-column row buffer; returns the offset after the line
PROC textrow(buf, len, off, rb)
  DEF col=0, c, r:PTR TO CHAR, s:PTR TO CHAR
  r := rb
  s := buf
  WHILE off < len
    c := s[off]
    off := off + 1
    IF c = 10 THEN RETURN off    -> line done
    IF c = 9
      REPEAT
        IF col < ncols THEN r[col] := 32
        col := col + 1
      UNTIL Mod(col, 8) = 0
    ELSEIF (c >= 32) AND ((c <= 126) OR (c >= 160))
      IF col < ncols THEN r[col] := c
      col := col + 1
    ELSEIF c <> 13
      IF col < ncols THEN r[col] := "."
      col := col + 1
    ENDIF
  ENDWHILE
ENDPROC off

-> offset of the line start before 'off' (scan back over the buffer)
PROC prevline(buf, off)
  DEF s:PTR TO CHAR, o
  s := buf
  o := off - 2    -> step over the LF that ends the previous line
  WHILE (o >= 0) AND (s[o] <> 10)
    o := o - 1
  ENDWHILE
ENDPROC o + 1

PROC hexrow(buf, len, off, rb)
  DEF r:PTR TO CHAR, s:PTR TO CHAR, i, c, n, hx:PTR TO CHAR
  r := rb
  s := buf
  hx := '0123456789abcdef'
  FOR i := 0 TO 5    -> six hex digits of offset
    r[i] := hx[Shr(off, (5 - i) * 4) AND $F]
  ENDFOR
  r[6] := ":"
  n := len - off
  IF n > 16 THEN n := 16
  FOR i := 0 TO 15
    IF i < n
      c := s[off + i]
      r[8 + (i * 3)] := hx[Shr(c, 4)]
      r[9 + (i * 3)] := hx[c AND $F]
    ENDIF
    IF i < 16 THEN r[10 + (i * 3)] := 32
  ENDFOR
  FOR i := 0 TO n - 1
    c := s[off + i]
    r[58 + i] := IF ((c >= 32) AND (c <= 126)) OR (c >= 160) THEN c ELSE "."
  ENDFOR
ENDPROC

-> one page of ANSI art: CMenu's renderer (SGR 0/1/4/30-37, ESC[nC
-> column skips, other sequences consumed; whole printable runs per
-> Text call) parsed from the top of the file so the colour state is
-> always right, emitting only the rows vtop..vtop+21. Colours only
-> on the own screen; elsewhere they are stripped but the skips keep
-> the art's shape.
PROC drawansipage(buf, len, vtop)
  DEF p:PTR TO CHAR, i, j, c, col, row, fg, sty,
      pv[8]:ARRAY OF LONG, np, v, xa
  p := buf
  -> 80-column art centers on wider grids
  xa := x0 + (IF ncols > 80 THEN ((ncols - 80) / 2) * cw ELSE 0)
  SetAPen(rp, 0)
  RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
           panetop + Mul(visrows, ch) - 1)
  fg := 7
  sty := 0
  SetSoftStyle(rp, 0, softmask)
  SetAPen(rp, IF ownscr THEN 7 ELSE txtpen)
  SetBPen(rp, 0)
  col := 0
  row := 0
  i := 0
  WHILE (i < len) AND (row < (vtop + visrows))
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
          IF ownscr
            FOR j := 0 TO np - 1
              v := pv[j]
              IF v = 0
                fg := 7
                sty := 0
              ELSEIF v = 1
                sty := sty OR FSF_BOLD
              ELSEIF v = 4
                sty := sty OR FSF_UNDERLINED
              ELSEIF (v >= 30) AND (v <= 37)
                fg := v - 30
              ENDIF
            ENDFOR
            SetSoftStyle(rp, sty, softmask)
            SetAPen(rp, fg)
          ENDIF
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
      -> whole printable runs per Text call, like CMenu
      j := i
      WHILE (j < len) AND (p[j] >= 32)
        j++
      ENDWHILE
      IF row >= vtop
        Move(rp, xa + (col * cw), panetop + ((row - vtop) * ch) + baseline)
        Text(rp, p + i, j - i)
      ENDIF
      col := col + (j - i)
      i := j
    ELSE
      i++
    ENDIF
  ENDWHILE
  SetSoftStyle(rp, 0, softmask)
  SetAPen(rp, txtpen)
ENDPROC

-> full-screen viewer over the pane area: text pager, hex dump, or
-> ANSI art (mode 0/1/2). Up/Down = line, Shift = page, Ctrl = ends,
-> Space = page down, Esc/q = back.
PROC viewfile(path, name, mode, bulk)
  DEF buf=NIL, bp:PTR TO CHAR, len, size, fh, top2=0, r, off, o2,
      class, code, qual, done=FALSE, dirty=TRUE, res2=0,
      rb[204]:ARRAY OF CHAR, i, mb[120]:STRING, mn:PTR TO CHAR,
      pgd, lock, fib:PTR TO fileinfoblock, nrows2=0, maxtop=0, vmax=0
  -> size via the pane data is stale-proof enough, but re-examine to
  -> be safe for files just written
  size := -1
  IF fib := AllocDosObject(DOS_FIB, NIL)
    IF lock := Lock(path, SHARED_LOCK)
      IF Examine(lock, fib) THEN size := fib.size
      UnLock(lock)
    ENDIF
    FreeDosObject(DOS_FIB, fib)
  ENDIF
  IF size < 0
    faultmsg('cannot view')
    RETURN
  ENDIF
  IF size > VIEWMAX
    showmsg('file too large to view (512KB cap for now)')
    RETURN
  ENDIF
  IF size > 0
    IF (buf := New(size)) = NIL
      showmsg('not enough memory to view this file')
      RETURN
    ENDIF
    IF (fh := Open(path, OLDFILE)) = NIL
      Dispose(buf)
      faultmsg('cannot view')
      RETURN
    ENDIF
    len := Read(fh, buf, size)
    Close(fh)
    IF len < 0 THEN len := 0
  ELSE
    len := 0
  ENDIF
  bp := buf
  IF mode = 0
    -> the last line belongs on the BOTTOM row: the highest top2 is
    -> the start of the final 22-line window
    vmax := len
    FOR r := 1 TO visrows
      IF vmax > 0 THEN vmax := prevline(buf, vmax)
    ENDFOR
    IF vmax < 0 THEN vmax := 0
  ELSEIF mode = 1
    vmax := Shr(len + 15, 4) - visrows
    IF vmax < 0 THEN vmax := 0
    vmax := Mul(vmax, 16)
  ENDIF
  IF mode = 2
    -> ANSI scrolls by art rows; count them, and light the classic
    -> ANSI palette while the art is up
    nrows2 := 1
    FOR i := 0 TO len - 1
      IF bp[i] = 10 THEN nrows2 := nrows2 + 1
    ENDFOR
    maxtop := nrows2 - visrows
    IF maxtop < 0 THEN maxtop := 0
    setansipal()
  ENDIF
  mn := 'view'
  IF mode = 1 THEN mn := 'hex'
  IF mode = 2 THEN mn := 'ansi'
  drawviewframe(TRUE)
  IF bulktot > 0
    StringF(mb, '\s "\s" (\d/\d) - \d bytes', mn, name, bulkpos, bulktot, len)
  ELSE
    StringF(mb, '\s "\s" - \d bytes', mn, name, len)
  ENDIF
  promptrow(mb)
  WHILE done = FALSE
    IF dirty
      IF mode = 2
        drawansipage(bp, len, top2)
      ELSE
        -> draw the page: 22 rows over the pane area
        off := top2
        FOR r := 0 TO visrows - 1
          FOR i := 0 TO ncols - 1
            rb[i] := 32
          ENDFOR
          IF mode = 1
            IF off < len
              hexrow(buf, len, off, rb)
              off := off + 16
            ENDIF
          ELSE
            IF off < len THEN off := textrow(buf, len, off, rb)
          ENDIF
          SetAPen(rp, txtpen)
          SetBPen(rp, 0)
          Move(rp, x0, panetop + (r * ch) + baseline)
          Text(rp, rb, ncols)
        ENDFOR
      ENDIF
      dirty := FALSE
    ENDIF
    class := WaitIMessage(win)
    code := MsgCode()
    qual := MsgQualifier()
    pgd := 0
    IF class = IDCMP_VANILLAKEY
      IF (code = 27) OR (code = "q") OR (code = "Q")
        done := TRUE
      ELSEIF ((code = "e") OR (code = "E")) AND (mode = 0)
        res2 := 1    -> straight from reading to editing
        done := TRUE
      ELSEIF code = 32
        pgd := visrows - 1
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80
        IF code = RK_UP
          IF qual AND IEQUALIFIER_CONTROL
            pgd := -30000
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            pgd := -(visrows - 1)
          ELSE
            pgd := -1
          ENDIF
        ELSEIF code = RK_DOWN
          IF qual AND IEQUALIFIER_CONTROL
            pgd := 30000
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            pgd := visrows - 1
          ELSE
            pgd := 1
          ENDIF
        ELSEIF (code = RK_RIGHT) AND bulk    -> next marked file
          res2 := 2
          done := TRUE
        ELSEIF (code = RK_LEFT) AND bulk    -> back one file
          res2 := 3
          done := TRUE
        ENDIF
      ENDIF
    ENDIF
    IF mode = 2
      -> row-number scrolling, clamped wholesale
      o2 := top2 + pgd
      IF o2 > maxtop THEN o2 := maxtop
      IF o2 < 0 THEN o2 := 0
      IF o2 <> top2
        top2 := o2
        dirty := TRUE
      ENDIF
      pgd := 0
    ENDIF
    WHILE pgd > 0
      -> forward one line/row from top2, stopping at the last line
      IF mode = 1
        o2 := top2 + 16
      ELSE
        o2 := top2
        WHILE (o2 < len) AND (bp[o2] <> 10)    -> plain reads, safe
          o2 := o2 + 1
        ENDWHILE
        o2 := o2 + 1
      ENDIF
      IF o2 <= vmax
        top2 := o2
        dirty := TRUE
      ENDIF
      pgd := pgd - 1
      IF o2 > vmax THEN pgd := 0
    ENDWHILE
    WHILE pgd < 0
      IF top2 > 0
        IF mode = 1
          top2 := top2 - 16
          IF top2 < 0 THEN top2 := 0
        ELSE
          top2 := prevline(buf, top2)
        ENDIF
        dirty := TRUE
      ELSE
        pgd := 0
      ENDIF
      pgd := pgd + 1
      IF pgd > 0 THEN pgd := 0
    ENDWHILE
  ENDWHILE
  IF buf THEN Dispose(buf)
  IF mode = 2 THEN setlightpal()
  IF bulk = FALSE THEN drawall()    -> a bulk tour redraws at its end
ENDPROC res2

-> v with marks: tour the marked files - Right = next (consumes the
-> mark), Left = back, Esc keeps the current and unviewed marks
PROC bulkview(p)
  DEF b, i, n=0, pos=0, r, ty, mode, seq[500]:ARRAY OF LONG,
      fpath[310]:STRING
  b := p * MAXENT
  FOR i := 0 TO ecount[p] - 1
    IF emark[b + i]
      IF edirs[b + i] = 0
        seq[n] := i
        n := n + 1
      ENDIF
    ENDIF
  ENDFOR
  IF n = 0
    showmsg('only directories are marked - nothing to view')
    RETURN
  ENDIF
  bulktot := n
  WHILE pos >= 0
    i := seq[pos]
    bulkpos := pos + 1
    buildfull(fpath, ppath[p], enames[b + i])
    ty := sniff(fpath)
    mode := 1
    IF ty = TY_TEXT THEN mode := 0
    IF ty = TY_ANSI THEN mode := 2
    r := viewfile(fpath, enames[b + i], mode, TRUE)
    IF r = 2    -> onward; this one is seen and its mark consumed
      emark[b + i] := 0
      pos := pos + 1
      IF pos >= n THEN pos := -1    -> tour complete
    ELSEIF r = 3
      IF pos > 0 THEN pos := pos - 1
    ELSEIF r = 1    -> e: edit this one, the tour ends here
      bulktot := 0
      bulkpos := 0
      IF editfile(fpath, enames[b + i]) = 1
        refreshall()
      ELSE
        drawall()
      ENDIF
      RETURN
    ELSE    -> Esc/q: abort - current and unviewed stay marked
      pos := -1
    ENDIF
  ENDWHILE
  bulktot := 0
  bulkpos := 0
  drawall()
ENDPROC

PROC doview()
  DEF p, i, ty, fpath[310]:STRING, cmd[680]:STRING
  p := active
  IF involume(p)
    showmsg('nothing to view in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  IF markcount(p) > 0
    bulkview(p)
    RETURN
  ENDIF
  i := (p * MAXENT) + esel[p]
  IF edirs[i]
    showmsg('cannot view a directory')
    RETURN
  ENDIF
  buildfull(fpath, ppath[p], enames[i])
  ty := sniff(fpath)
  IF ty = TY_TEXT
    IF viewfile(fpath, enames[i], 0, FALSE) = 1
      IF editfile(fpath, enames[i]) = 1 THEN refreshall() ELSE drawall()
    ENDIF
  ELSEIF ty = TY_ANSI
    viewfile(fpath, enames[i], 2, FALSE)
  ELSEIF ty = TY_LHA
    StringF(cmd, 'lha l "\s"', fpath)
    capturecmd(p, cmd, enames[i], FALSE)
  ELSEIF ty = TY_LZX
    StringF(cmd, 'lzx l "\s"', fpath)
    capturecmd(p, cmd, enames[i], FALSE)
  ELSEIF ty = TY_ZIP
    StringF(cmd, 'unzip -l "\s"', fpath)
    capturecmd(p, cmd, enames[i], FALSE)
  ELSE
    viewfile(fpath, enames[i], 1, FALSE)
  ENDIF
ENDPROC

-> ---- the text editor ----------------------------------------------

PROC edtitle(name)
  DEF mb[130]:STRING
  StringF(mb, 'edit "\s"\s', name,
          IF edmod THEN ' *modified*' ELSE (IF ednew THEN ' (new)' ELSE ''))
  promptrow(mb)
ENDPROC

PROC edtouch(name)
  IF edmod = FALSE
    edmod := TRUE
    edtitle(name)
  ENDIF
ENDPROC

-> one window row: line edvtop+r from column edxoff, with the cursor
-> cell inverted when it lives here
PROC edrow(r)
  DEF idx, s:PTR TO CHAR, l, i, vis, erb[204]:ARRAY OF CHAR,
      cc[4]:ARRAY OF CHAR
  idx := edvtop + r
  FOR i := 0 TO ncols - 1
    erb[i] := 32
  ENDFOR
  IF idx < ednum
    s := edl[idx]
    l := EstrLen(edl[idx])
    vis := l - edxoff
    IF vis > ncols THEN vis := ncols
    IF vis > 0 THEN CopyMem(s + edxoff, erb, vis)
  ENDIF
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0, panetop + (r * ch) + baseline)
  Text(rp, erb, ncols)
  IF idx = edcur
    cc[0] := erb[edcol - edxoff]
    SetAPen(rp, 0)
    SetBPen(rp, txtpen)
    Move(rp, x0 + ((edcol - edxoff) * cw), panetop + (r * ch) + baseline)
    Text(rp, cc, 1)
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
  ENDIF
ENDPROC

PROC edpage()
  DEF r
  FOR r := 0 TO visrows - 1
    edrow(r)
  ENDFOR
ENDPROC

-> keep the cursor inside the window; TRUE = whole page must redraw
PROC edfix()
  DEF fix=FALSE
  IF edcur < edvtop
    edvtop := edcur
    fix := TRUE
  ENDIF
  IF edcur >= (edvtop + visrows)
    edvtop := edcur - visrows + 1
    fix := TRUE
  ENDIF
  IF edcol < edxoff
    edxoff := edcol
    fix := TRUE
  ENDIF
  IF (edcol - edxoff) >= ncols
    edxoff := edcol - ncols + 1
    fix := TRUE
  ENDIF
ENDPROC fix

PROC edfree()
  DEF i
  IF ednum > 0
    FOR i := 0 TO ednum - 1
      DisposeLink(edl[i])
    ENDFOR
  ENDIF
  ednum := 0
ENDPROC

-> insert one character at the cursor (no redraw; caller batches)
PROC edinsch(c)
  DEF s:PTR TO CHAR, l, i
  s := edl[edcur]
  l := EstrLen(edl[edcur])
  IF l >= EDLW THEN RETURN FALSE
  FOR i := l TO edcol + 1 STEP -1
    s[i] := s[i - 1]
  ENDFOR
  s[edcol] := c
  SetStr(edl[edcur], l + 1)
  edcol := edcol + 1
ENDPROC TRUE

-> load for editing: LF splits, CR dropped, tabs to spaces (8-stops),
-> lines capped at 200 characters. -1 = failed (message shown).
PROC edload(path)
  DEF fh, buf=NIL, n, size=-1, i, c, col, s, ok=TRUE,
      lock, fib:PTR TO fileinfoblock, bp:PTR TO CHAR, ln:PTR TO CHAR
  IF edl = NIL
    IF (edl := New(Mul(EDMAXL, 4))) = NIL THEN RETURN FALSE
  ENDIF
  edfree()
  ednew := FALSE
  IF fib := AllocDosObject(DOS_FIB, NIL)
    IF lock := Lock(path, SHARED_LOCK)
      IF Examine(lock, fib) THEN size := fib.size
      UnLock(lock)
    ELSEIF IoErr() = ERROR_OBJECT_NOT_FOUND
      -> a new file: an empty buffer that only exists once saved
      size := 0
      ednew := TRUE
    ENDIF
    FreeDosObject(DOS_FIB, fib)
  ENDIF
  IF size < 0
    faultmsg('cannot edit')
    RETURN FALSE
  ENDIF
  IF size > VIEWMAX
    showmsg('file too large to edit (512KB cap)')
    RETURN FALSE
  ENDIF
  IF size > 0
    IF (buf := New(size)) = NIL
      showmsg('not enough memory')
      RETURN FALSE
    ENDIF
    IF (fh := Open(path, OLDFILE)) = NIL
      Dispose(buf)
      faultmsg('cannot edit')
      RETURN FALSE
    ENDIF
    n := Read(fh, buf, size)
    Close(fh)
    IF n < 0 THEN n := 0
  ELSE
    n := 0
  ENDIF
  bp := buf
  IF (s := String(EDLW)) = NIL THEN ok := FALSE
  IF ok
    edl[0] := s
    ednum := 1
    ln := s
    col := 0
    i := 0
    WHILE (i < n) AND ok
      c := bp[i]
      IF c = 10
        SetStr(edl[ednum - 1], col)
        IF ednum >= EDMAXL
          showmsg('too many lines to edit (8192 cap)')
          ok := FALSE
        ELSEIF (s := String(EDLW)) = NIL
          showmsg('not enough memory')
          ok := FALSE
        ELSE
          edl[ednum] := s
          ednum := ednum + 1
          ln := s
          col := 0
        ENDIF
      ELSEIF c = 13
        -> dropped: Amiga text is LF
      ELSEIF c = 9
        REPEAT
          IF col < EDLW
            ln[col] := 32
            col := col + 1
          ENDIF
        UNTIL (Mod(col, 8) = 0) OR (col >= EDLW)
      ELSE
        IF col < EDLW
          ln[col] := c
          col := col + 1
        ENDIF
      ENDIF
      i := i + 1
    ENDWHILE
    IF ok THEN SetStr(edl[ednum - 1], col)
  ENDIF
  IF buf THEN Dispose(buf)
  IF ok = FALSE THEN edfree()
ENDPROC ok

PROC edsave(path)
  DEF fh, i, ok=TRUE
  IF samefile(path, 'PROGDIR:cfile.config') THEN wantreload := TRUE
  IF (fh := Open(path, NEWFILE)) = NIL
    faultmsg('cannot save')
    RETURN FALSE
  ENDIF
  FOR i := 0 TO ednum - 1
    IF ok
      IF Write(fh, edl[i], EstrLen(edl[i])) < 0 THEN ok := FALSE
      IF Write(fh, '\n', 1) < 0 THEN ok := FALSE
    ENDIF
  ENDFOR
  Close(fh)
  IF ok = FALSE THEN faultmsg('write failed')
ENDPROC ok

-> the editor itself. Returns -1 = could not load (message shown),
-> 0 = left without saving, 1 = saved.
PROC editfile(path, name)
  DEF class, code, qual, done2=FALSE, saved=0, k, i, l, r, nl,
      s:PTR TO CHAR
  IF edload(path) = FALSE THEN RETURN -1
  edcur := 0
  edcol := 0
  edvtop := 0
  edxoff := 0
  edmod := FALSE
  drawviewframe(TRUE)
  SetAPen(rp, 0)
  RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
           panetop + Mul(visrows, ch) - 1)
  edtitle(name)
  edpage()
  WHILE done2 = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    qual := MsgQualifier()
    IF class = IDCMP_VANILLAKEY
      IF code = 27
        IF edmod
          promptrow('save changes? (y)es (n)o (Esc = keep editing)')
          k := waitvanilla()
          IF (k = "y") OR (k = "Y")
            IF edsave(path)
              saved := 1
              ednew := FALSE
              done2 := TRUE
            ENDIF
          ELSEIF (k = "n") OR (k = "N")
            done2 := TRUE
          ENDIF
          IF done2 = FALSE THEN edtitle(name)
        ELSE
          done2 := TRUE
        ENDIF
      ELSEIF code = 13    -> split the line at the cursor
        IF ednum < EDMAXL
          IF (nl := String(EDLW)) <> NIL
            s := edl[edcur]
            StrCopy(nl, s + edcol)
            SetStr(edl[edcur], edcol)
            FOR i := ednum TO edcur + 2 STEP -1
              edl[i] := edl[i - 1]
            ENDFOR
            edl[edcur + 1] := nl
            ednum := ednum + 1
            edcur := edcur + 1
            edcol := 0
            edtouch(name)
            edfix()
            edpage()
          ENDIF
        ENDIF
      ELSEIF code = 8    -> backspace
        IF edcol > 0
          s := edl[edcur]
          l := EstrLen(edl[edcur])
          FOR i := edcol TO l - 1
            s[i - 1] := s[i]
          ENDFOR
          SetStr(edl[edcur], l - 1)
          edcol := edcol - 1
          edtouch(name)
          IF edfix() THEN edpage() ELSE edrow(edcur - edvtop)
        ELSEIF edcur > 0
          -> join with the line above when the result fits
          l := EstrLen(edl[edcur - 1])
          IF (l + EstrLen(edl[edcur])) <= EDLW
            edcol := l
            StrAdd(edl[edcur - 1], edl[edcur])
            DisposeLink(edl[edcur])
            FOR i := edcur TO ednum - 2
              edl[i] := edl[i + 1]
            ENDFOR
            ednum := ednum - 1
            edcur := edcur - 1
            edtouch(name)
            edfix()
            edpage()
          ENDIF
        ENDIF
      ELSEIF code = 127    -> del: under the cursor / join the next
        s := edl[edcur]
        l := EstrLen(edl[edcur])
        IF edcol < l
          FOR i := edcol + 1 TO l - 1
            s[i - 1] := s[i]
          ENDFOR
          SetStr(edl[edcur], l - 1)
          edtouch(name)
          IF edfix() THEN edpage() ELSE edrow(edcur - edvtop)
        ELSEIF edcur < (ednum - 1)
          IF (l + EstrLen(edl[edcur + 1])) <= EDLW
            StrAdd(edl[edcur], edl[edcur + 1])
            DisposeLink(edl[edcur + 1])
            FOR i := edcur + 1 TO ednum - 2
              edl[i] := edl[i + 1]
            ENDFOR
            ednum := ednum - 1
            edtouch(name)
            edfix()
            edpage()
          ENDIF
        ENDIF
      ELSEIF code = 9    -> tab: spaces to the next 8-stop
        REPEAT
          IF edinsch(32) = FALSE THEN edcol := edcol    -> line full
        UNTIL (Mod(edcol, 8) = 0) OR (EstrLen(edl[edcur]) >= EDLW)
        edtouch(name)
        IF edfix() THEN edpage() ELSE edrow(edcur - edvtop)
      ELSEIF (code >= 32) AND (code <= 255)
        IF edinsch(code)
          edtouch(name)
          IF edfix() THEN edpage() ELSE edrow(edcur - edvtop)
        ENDIF
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80
        r := edcur
        IF code = RK_UP
          IF qual AND IEQUALIFIER_CONTROL
            edcur := 0
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            edcur := edcur - (visrows - 1)
          ELSE
            edcur := edcur - 1
          ENDIF
        ELSEIF code = RK_DOWN
          IF qual AND IEQUALIFIER_CONTROL
            edcur := ednum - 1
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            edcur := edcur + (visrows - 1)
          ELSE
            edcur := edcur + 1
          ENDIF
        ELSEIF code = RK_LEFT
          IF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            edcol := 0
          ELSEIF edcol > 0
            edcol := edcol - 1
          ELSEIF edcur > 0
            edcur := edcur - 1
            edcol := EstrLen(edl[edcur])
          ENDIF
        ELSEIF code = RK_RIGHT
          IF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            edcol := EstrLen(edl[edcur])
          ELSEIF edcol < EstrLen(edl[edcur])
            edcol := edcol + 1
          ELSEIF edcur < (ednum - 1)
            edcur := edcur + 1
            edcol := 0
          ENDIF
        ENDIF
        IF edcur < 0 THEN edcur := 0
        IF edcur > (ednum - 1) THEN edcur := ednum - 1
        IF edcol > EstrLen(edl[edcur]) THEN edcol := EstrLen(edl[edcur])
        IF edfix()
          edpage()
        ELSEIF edcur <> r
          edrow(r - edvtop)
          edrow(edcur - edvtop)
        ELSE
          edrow(edcur - edvtop)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  edfree()
ENDPROC saved

-> e: edit the selected text file
PROC doedit()
  DEF p, i, ty, r, fpath[310]:STRING
  p := active
  IF involume(p)
    showmsg('nothing to edit in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  i := (p * MAXENT) + esel[p]
  IF edirs[i]
    showmsg('cannot edit a directory')
    RETURN
  ENDIF
  buildfull(fpath, ppath[p], enames[i])
  ty := sniff(fpath)
  IF (ty = TY_TEXT) OR (esize[i] = 0)
    r := editfile(fpath, enames[i])
    IF r = 1
      refreshall()
    ELSEIF r = 0
      drawall()
    ENDIF
  ELSE
    showmsg('only text files can be edited')
  ENDIF
ENDPROC

-> run a shell command line, current dir set to pane p's directory
-> (so launched programs find their data files). The command's
-> console lives on OUR screen: AUTO means the window only appears
-> if the command actually reads or writes, WAIT keeps it up until
-> its close gadget is clicked, and SYS_OUTPUT=NIL reuses the input
-> console (the RKM System() pattern).
PROC runcmd(p, cmd)
  DEF dlock=NIL, old=NIL, res, coni=NIL, mb[120]:STRING
  dlock := Lock(ppath[p], SHARED_LOCK)
  IF dlock THEN old := CurrentDir(dlock)
  coni := Open(IF ownscr THEN
      'CON:0/0/640/200/CFile/AUTO/CLOSE/WAIT/SCREEN CFILE' ELSE
      'CON:0/0/640/200/CFile/AUTO/CLOSE/WAIT', OLDFILE)
  res := SystemTagList(cmd,
    [SYS_INPUT,  coni,
     SYS_OUTPUT, NIL,
     SYS_ASYNCH, FALSE,
     TAG_DONE,   NIL])
  IF coni THEN Close(coni)    -> WAIT: holds here until the window goes
  ActivateWindow(win)
  IF dlock
    CurrentDir(old)
    UnLock(dlock)
  ENDIF
  refreshall()    -> it may have written anywhere
  IF res = -1
    faultmsg('cannot run')
  ELSEIF res <> 0
    StringF(mb, 'returned code \d', res)
    showmsg(mb)
  ENDIF
ENDPROC

-> run a command with its output captured to T: and shown in the
-> text viewer afterwards (archiver listings and unpack logs read
-> nicer there than in a console). refresh = re-read the panes first
-> so the viewer's exit redraw shows the new state.
PROC capturecmd(p, cmd, title, refresh)
  DEF dlock=NIL, old=NIL, res, fout=NIL, fin=NIL, mb[120]:STRING
  dlock := Lock(ppath[p], SHARED_LOCK)
  IF dlock THEN old := CurrentDir(dlock)
  fin := Open('NIL:', OLDFILE)
  IF (fout := Open('T:CFile-out', NEWFILE)) = NIL
    -> no T:? unlikely, but the console runner still works
    IF fin THEN Close(fin)
    IF dlock
      CurrentDir(old)
      UnLock(dlock)
    ENDIF
    runcmd(p, cmd)
    RETURN
  ENDIF
  res := SystemTagList(cmd,
    [SYS_INPUT,  fin,
     SYS_OUTPUT, fout,
     SYS_ASYNCH, FALSE,
     TAG_DONE,   NIL])
  Close(fout)
  IF fin THEN Close(fin)
  IF dlock
    CurrentDir(old)
    UnLock(dlock)
  ENDIF
  IF refresh
    readpane(0)
    readpane(1)
  ENDIF
  IF res = -1
    IF refresh THEN drawall()
    faultmsg('cannot run')
  ELSE
    viewfile('T:CFile-out', title, 0, FALSE)    -> ends with a full redraw
    IF res <> 0
      StringF(mb, 'returned code \d', res)
      showmsg(mb)
    ENDIF
  ENDIF
  DeleteFile('T:CFile-out')
ENDPROC

-> ---- CFile's own console: command output rendered live into the
-> ---- text area - no window, no chrome, our pens and font ---------

PROC connl()
  DEF m:PTR TO CHAR, j
  ccol := 0
  IF crow < (visrows - 1)
    crow := crow + 1
  ELSE
    ScrollRaster(rp, 0, ch, x0, panetop,
                 x0 + Mul(ncols, cw) - 1, panetop + Mul(visrows, ch) - 1)
  ENDIF
  IF cmodel
    IF cmrow < (CMAXL - 1)    -> past the cap the last line churns
      cmrow := cmrow + 1
      m := cmodel + Mul(cmrow, ncols)
      FOR j := 0 TO ncols - 1
        m[j] := 32
      ENDFOR
    ENDIF
  ENDIF
ENDPROC

-> feed raw command output to the area: printable runs in one Text
-> each, LF = new line, CR = column 0 (in-place progress counters
-> work), tabs to 8-stops, 80-col wrap. Control sequences come as
-> ESC[ or the Amiga's single-byte CSI ($9B); params run until the
-> first byte >= $40, the final letter. Cursor-forward (C) and
-> erase-to-end-of-line (K) are honoured - lha uses both - the rest
-> is swallowed.
PROC confeed(buf, n)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit, m:PTR TO CHAR
  s := buf
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  WHILE i < n
    c := s[i]
    IF cesc = 2    -> inside a CSI sequence
      IF (c >= 48) AND (c <= 57)
        cnum := (cnum * 10) + (c - 48)
      ELSEIF c = ";"
        cnum := 0
      ENDIF
      IF c >= 64    -> the final byte
        IF c = "C"
          ccol := ccol + (IF cnum = 0 THEN 1 ELSE cnum)
          IF ccol > ncols THEN ccol := ncols
        ELSEIF c = "K"
          SetAPen(rp, 0)
          RectFill(rp, x0 + (ccol * cw), panetop + (crow * ch),
                   x0 + Mul(ncols, cw) - 1, panetop + (crow * ch) + ch - 1)
          SetAPen(rp, txtpen)
          IF cmodel
            m := cmodel + Mul(cmrow, ncols)
            FOR j := ccol TO ncols - 1
              m[j] := 32
            ENDFOR
          ENDIF
        ENDIF
        cesc := 0
      ENDIF
      i := i + 1
    ELSEIF cesc = 1    -> just saw ESC
      IF c = "["
        cesc := 2
        cnum := 0
      ELSE
        cesc := 0    -> a lone ESC+letter sequence: swallow it
      ENDIF
      i := i + 1
    ELSEIF c = $9B    -> the Amiga single-byte CSI
      cesc := 2
      cnum := 0
      i := i + 1
    ELSEIF c = 27
      cesc := 1
      i := i + 1
    ELSEIF c = 10
      connl()
      i := i + 1
    ELSEIF c = 13
      ccol := 0
      i := i + 1
    ELSEIF c = 9
      REPEAT
        Move(rp, x0 + (ccol * cw), panetop + (crow * ch) + baseline)
        Text(rp, ' ', 1)
        IF cmodel
          m := cmodel + Mul(cmrow, ncols)
          m[ccol] := 32
        ENDIF
        ccol := ccol + 1
      UNTIL (Mod(ccol, 8) = 0) OR (ccol >= ncols)
      IF ccol >= 80 THEN connl()
      i := i + 1
    ELSEIF c >= 32
      j := i
      WHILE (j < n) AND (s[j] >= 32) AND (s[j] <> 127) AND (s[j] <> $9B)
        j := j + 1
      ENDWHILE
      run := j - i
      WHILE run > 0
        IF ccol >= ncols THEN connl()
        fit := ncols - ccol
        IF fit > run THEN fit := run
        Move(rp, x0 + (ccol * cw), panetop + (crow * ch) + baseline)
        Text(rp, s + i, fit)
        IF cmodel THEN CopyMem(s + i, cmodel + Mul(cmrow, ncols) + ccol, fit)
        ccol := ccol + fit
        i := i + fit
        run := run - fit
      ENDWHILE
    ELSE
      i := i + 1
    ENDIF
  ENDWHILE
ENDPROC

-> dress the frame for console output and reset the renderer
PROC livestart()
  DEF m:PTR TO CHAR, j
  drawviewframe(FALSE)
  SetAPen(rp, 0)
  RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
           panetop + Mul(visrows, ch) - 1)
  ccol := 0
  crow := 0
  cesc := 0
  cnum := 0
  -> the scrollback model, allocated once; without it the console
  -> still works, just without scrolling back
  IF cmodel = NIL THEN cmodel := New(Mul(CMAXL, ncols))
  cmrow := 0
  IF cmodel
    m := cmodel
    FOR j := 0 TO ncols - 1
      m[j] := 32
    ENDFOR
  ENDIF
ENDPROC

-> one command through the PIPE: into the console area. Returns
-> FALSE only when the pipe itself cannot be opened; a command that
-> fails to launch reports into the area and still returns TRUE.
PROC livepipe(p, cmd)
  DEF dlock=NIL, old=NIL, res, wout=NIL, nin=NIL, rdr=NIL,
      buf[260]:ARRAY OF CHAR, n, s:PTR TO CHAR
  IF (wout := Open('PIPE:cfile-con', NEWFILE)) = NIL THEN RETURN FALSE
  dlock := Lock(ppath[p], SHARED_LOCK)
  IF dlock THEN old := CurrentDir(dlock)
  nin := Open('NIL:', OLDFILE)
  res := SystemTagList(cmd,
    [SYS_INPUT,  nin,
     SYS_OUTPUT, wout,
     SYS_ASYNCH, TRUE,    -> it runs while we render
     TAG_DONE,   NIL])
  IF dlock
    CurrentDir(old)
    UnLock(dlock)
  ENDIF
  IF res = -1
    -> could not launch: an asynch failure leaves the handles ours
    Close(wout)
    IF nin THEN Close(nin)
    s := 'cannot run the command\n'
    confeed(s, StrLen(s))
    RETURN TRUE
  ENDIF
  -> the command owns the handles now (asynch closes them on exit)
  IF rdr := Open('PIPE:cfile-con', OLDFILE)
    n := Read(rdr, buf, 256)
    WHILE n > 0
      confeed(buf, n)
      n := Read(rdr, buf, 256)
    ENDWHILE
    Close(rdr)
  ENDIF
ENDPROC TRUE

-> close the console session: arrows (with Shift/Ctrl) scroll the
-> backlog - the feature every Amiga file manager forgot - and any
-> other key returns to the panes
PROC liveend()
  DEF s:PTR TO CHAR, msg, vtop, maxv, nv, r, line,
      class, code, qual, over=FALSE
  s := '\n-- arrows scroll back, any other key returns --'
  confeed(s, StrLen(s))
  -> drop the key presses that piled up while the commands ran
  msg := GetMsg(win.userport)
  WHILE msg
    ReplyMsg(msg)
    msg := GetMsg(win.userport)
  ENDWHILE
  IF cmodel = NIL
    waitkey()    -> no scrollback memory: the old behaviour
    refreshall()
    RETURN
  ENDIF
  maxv := cmrow - (visrows - 1)
  IF maxv < 0 THEN maxv := 0
  vtop := maxv
  WHILE over = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    qual := MsgQualifier()
    nv := vtop
    IF class = IDCMP_RAWKEY
      IF code < $80
        IF code = RK_UP
          IF qual AND IEQUALIFIER_CONTROL
            nv := 0
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            nv := vtop - (visrows - 1)
          ELSE
            nv := vtop - 1
          ENDIF
        ELSEIF code = RK_DOWN
          IF qual AND IEQUALIFIER_CONTROL
            nv := maxv
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            nv := vtop + (visrows - 1)
          ELSE
            nv := vtop + 1
          ENDIF
        ELSEIF (code >= $60) AND (code <= $67)
          -> the qualifier keys themselves (Shift/Ctrl/Alt/Amiga):
          -> pressing one is preparation, not an answer
        ELSE
          over := TRUE
        ENDIF
      ENDIF
    ELSE
      over := TRUE    -> vanilla keys included
    ENDIF
    IF nv > maxv THEN nv := maxv
    IF nv < 0 THEN nv := 0
    IF (nv <> vtop) AND (over = FALSE)
      vtop := nv
      SetAPen(rp, txtpen)
      SetBPen(rp, 0)
      FOR r := 0 TO visrows - 1
        line := vtop + r
        Move(rp, x0, panetop + (r * ch) + baseline)
        IF line <= cmrow
          Text(rp, cmodel + Mul(line, ncols), ncols)
        ELSE
          Text(rp, {spaces2}, ncols)
        ENDIF
      ENDFOR
    ENDIF
  ENDWHILE
  refreshall()
ENDPROC

-> run one command with LIVE output rendered into the frame
PROC livecmd(p, cmd)
  livestart()
  IF livepipe(p, cmd) = FALSE
    runcmd(p, cmd)    -> PIPE: not mounted? the bordered console works
    RETURN
  ENDIF
  liveend()
ENDPROC

-> : - a shell command line, run in the active pane's directory
PROC docommand()
  DEF cmd[140]:STRING
  IF involume(active)
    showmsg('enter a volume first')
    RETURN
  ENDIF
  StrCopy(cmd, '')
  IF lineinput(': ', cmd, 68, FALSE) = 0
    drawpaths()
    RETURN
  ENDIF
  IF EstrLen(cmd) = 0
    drawpaths()
    RETURN
  ENDIF
  drawpaths()
  livecmd(active, cmd)
ENDPROC

-> case-insensitive extension check for the pack prompt
PROC hasext(name, ext)
  DEF s:PTR TO CHAR, t:PTR TO CHAR, l, e, i, ca, cb
  s := name
  t := ext
  l := StrLen(name)
  e := StrLen(ext)
  IF l < e THEN RETURN FALSE
  FOR i := 0 TO e - 1
    ca := s[l - e + i]
    cb := t[i]
    IF (ca >= "A") AND (ca <= "Z") THEN ca := ca + 32
    IF (cb >= "A") AND (cb <= "Z") THEN cb := cb + 32
    IF ca <> cb THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

-> p: pack the selection or the marked set into an archive in the
-> other pane's directory. The typed name's extension picks the
-> archiver (.lha/.lzh, .lzx, .zip). The archiver runs CD'd into
-> the active pane, so the archive holds clean relative paths.
PROC dopack()
  DEF p, q, i, b, nmark, pick, k, ty=0, baselen, pipeok=TRUE,
      tname[40]:STRING, dst[314]:STRING, cmd[700]:STRING,
      mb[130]:STRING, base[400]:STRING
  p := active
  q := IF p = 0 THEN 1 ELSE 0
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  IF involume(q)
    showmsg('the other pane shows volumes - enter one first')
    RETURN
  ENDIF
  IF efail[q]
    showmsg('the other pane has no readable directory')
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  -> a sensible prefill: the selection's name, or the directory's
  IF nmark > 0
    StrCopy(tname, FilePart(ppath[p]))
    IF EstrLen(tname) = 0 THEN StrCopy(tname, 'archive')
  ELSE
    StrCopy(tname, enames[b + esel[p]])
  ENDIF
  IF EstrLen(tname) > 25 THEN SetStr(tname, 25)
  StrAdd(tname, '.lha')
  IF lineinput('pack as: ', tname, 30, TRUE) = 0
    drawpaths()
    RETURN
  ENDIF
  IF EstrLen(tname) = 0
    drawpaths()
    RETURN
  ENDIF
  IF hasext(tname, '.lha') OR hasext(tname, '.lzh')
    ty := 1
  ELSEIF hasext(tname, '.lzx')
    ty := 2
  ELSEIF hasext(tname, '.zip')
    ty := 3
  ELSE
    showmsg('unknown archive type - use .lha, .lzh, .lzx or .zip')
    RETURN
  ENDIF
  buildfull(dst, ppath[q], tname)
  IF pathtype(dst) > 0
    StringF(mb, '"\s" exists: (a)ppend (o)verwrite?', tname)
    promptrow(mb)
    k := waitvanilla()
    IF (k = "o") OR (k = "O")
      IF zap(dst, FALSE) = FALSE
        faultmsg('cannot replace the target')
        RETURN
      ENDIF
    ELSEIF (k = "a") OR (k = "A")
      -> append into the existing archive
    ELSE
      drawpaths()
      RETURN
    ENDIF
  ENDIF
  drawpaths()
  livestart()
  -> sources go on the command line in batches; the archivers all
  -> append, so several batches build one archive
  IF ty = 1
    StringF(cmd, 'lha -r a "\s"', dst)
  ELSEIF ty = 2
    StringF(cmd, 'lzx -r a "\s"', dst)
  ELSE
    StringF(cmd, 'zip -r "\s"', dst)
  ENDIF
  StrCopy(base, cmd)    -> keep the bare command as the batch base
  baselen := EstrLen(cmd)
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND pipeok
      IF (EstrLen(cmd) + StrLen(enames[b + i])) > 600
        pipeok := livepipe(p, cmd)
        StrCopy(cmd, base)
      ENDIF
      StrAdd(cmd, ' "')
      StrAdd(cmd, enames[b + i])
      StrAdd(cmd, '"')
    ENDIF
  ENDFOR
  IF pipeok
    IF EstrLen(cmd) > baselen THEN pipeok := livepipe(p, cmd)
  ENDIF
  liveend()
ENDPROC

-> u: unpack the selected archive - or every marked archive - into
-> the other pane's directory, all in one console session with a
-> >> header line per archive
PROC dounpack()
  DEF p, q, i, b, ty, nmark, narc=0, pick, pipeok=TRUE,
      fpath[310]:STRING, dst[314]:STRING, cmd[680]:STRING,
      hdr[130]:STRING, s:PTR TO CHAR, l
  p := active
  q := IF p = 0 THEN 1 ELSE 0
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  IF involume(q)
    showmsg('the other pane shows volumes - enter one first')
    RETURN
  ENDIF
  IF efail[q]
    showmsg('the other pane has no readable directory')
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  -> pre-scan: is there anything unpackable in the set?
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      IF edirs[b + i] = 0
        buildfull(fpath, ppath[p], enames[b + i])
        ty := sniff(fpath)
        IF (ty = TY_LHA) OR (ty = TY_LZX) OR (ty = TY_ZIP)
          narc := narc + 1
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  IF narc = 0
    IF nmark > 0
      showmsg('no archives among the marked entries')
    ELSE
      showmsg('not a recognised archive (lha, lzx or zip)')
    ENDIF
    RETURN
  ENDIF
  -> archivers take a trailing '/' or ':' as "into this directory"
  StrCopy(dst, ppath[q])
  s := dst
  l := EstrLen(dst)
  IF l > 0
    IF (s[l - 1] <> ":") AND (s[l - 1] <> "/") THEN StrAdd(dst, '/')
  ENDIF
  livestart()
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND pipeok
      IF edirs[b + i] = 0
        buildfull(fpath, ppath[p], enames[b + i])
        ty := sniff(fpath)
        StrCopy(cmd, '')
        IF ty = TY_LHA
          StringF(cmd, 'lha x "\s" "\s"', fpath, dst)
        ELSEIF ty = TY_LZX
          StringF(cmd, 'lzx x "\s" "\s"', fpath, dst)
        ELSEIF ty = TY_ZIP
          StringF(cmd, 'unzip "\s" -d "\s"', fpath, dst)
        ENDIF
        IF EstrLen(cmd) > 0
          StringF(hdr, '\n>> \s\n', enames[b + i])
          confeed(hdr, StrLen(hdr))
          pipeok := livepipe(q, cmd)
          IF pipeok = FALSE
            s := 'PIPE: is not available - run stopped\n'
            confeed(s, StrLen(s))
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  liveend()
ENDPROC

-> Enter: do the obvious thing for the type
PROC doopen()
  DEF p, i, ty, k, fpath[310]:STRING, mb[120]:STRING, rcmd[330]:STRING
  p := active
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  i := (p * MAXENT) + esel[p]
  IF edirs[i]
    enterdir()
    RETURN
  ENDIF
  buildfull(fpath, ppath[p], enames[i])
  ty := sniff(fpath)
  IF ty = TY_EXEC
    StringF(mb, 'run "\s"? (y)es (n)o', enames[i])
    promptrow(mb)
    k := waitvanilla()
    IF (k = "y") OR (k = "Y")
      drawpaths()
      StringF(rcmd, '"\s"', fpath)
      livecmd(p, rcmd)
    ELSE
      drawpaths()
    ENDIF
  ELSEIF ty = TY_TEXT
    IF viewfile(fpath, enames[i], 0, FALSE) = 1
      IF editfile(fpath, enames[i]) = 1 THEN refreshall() ELSE drawall()
    ENDIF
  ELSEIF ty = TY_ANSI
    viewfile(fpath, enames[i], 2, FALSE)
  ELSEIF (ty = TY_LHA) OR (ty = TY_LZX) OR (ty = TY_ZIP)
    showmsg('an archive - u unpacks it to the other pane, v lists it')
  ELSE
    viewfile(fpath, enames[i], 1, FALSE)
  ENDIF
ENDPROC

-> Space: toggle the mark and step down (runs mark quickly that way)
PROC togglemark()
  DEF p, i
  p := active
  IF involume(p) THEN RETURN
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  i := (p * MAXENT) + esel[p]
  emark[i] := IF emark[i] THEN 0 ELSE 1
  IF esel[p] < (ecount[p] - 1)
    movedown()    -> redraws the old row, mark included
  ELSE
    drawrow(p, esel[p] - etop[p])
  ENDIF
ENDPROC

PROC dorename()
  DEF p, i, b, nmark, r, pick, stopped=FALSE, any=FALSE,
      src2[310]:STRING, dst[310]:STRING, tname[110]:STRING
  p := active
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  b := p * MAXENT
  nmark := markcount(p)
  -> the marked set renames one at a time (his thought); Esc stops
  -> the rest, an unchanged name skips that one
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stopped = FALSE)
      StrCopy(tname, enames[b + i])
      r := lineinput('rename to: ', tname, 30, TRUE)
      IF r = 0
        stopped := TRUE
      ELSEIF EstrLen(tname) > 0
        buildfull(src2, ppath[p], enames[b + i])
        buildfull(dst, ppath[p], tname)
        IF StrCmp(src2, dst) = FALSE    -> case changes are real
          IF Rename(src2, dst)
            any := TRUE
            StrCopy(prevname, tname)
          ELSE
            faultmsg('cannot rename')
            stopped := TRUE
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  IF any
    refreshall()
    IF nmark = 0 THEN selectbyname(p)
    IF msgup THEN remsg()
  ELSE
    drawpaths()
    IF msgup THEN remsg()
  ENDIF
ENDPROC

-> n: a name ending in "/" makes a directory; anything else opens
-> the editor on a NEW file - which only exists once it is saved
PROC donew()
  DEF p, lock, tname[40]:STRING, dpath[310]:STRING,
      s:PTR TO CHAR, i, l, wantdir=FALSE, r
  p := active
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] THEN RETURN
  StrCopy(tname, '')
  IF lineinput('new (name/ = dir): ', tname, 31, FALSE) = 0
    drawpaths()
    RETURN
  ENDIF
  l := EstrLen(tname)
  IF l = 0
    drawpaths()
    RETURN
  ENDIF
  s := tname
  IF s[l - 1] = "/"
    wantdir := TRUE
    SetStr(tname, l - 1)
    l := l - 1
  ENDIF
  IF l = 0
    drawpaths()
    RETURN
  ENDIF
  FOR i := 0 TO l - 1
    IF (s[i] = "/") OR (s[i] = ":")
      showmsg('plain names only (a trailing / makes a directory)')
      RETURN
    ENDIF
  ENDFOR
  buildfull(dpath, ppath[p], tname)
  IF wantdir
    IF lock := CreateDir(dpath)
      UnLock(lock)    -> CreateDir hands back an exclusive lock
      StrCopy(prevname, tname)
      refreshall()
      selectbyname(p)
    ELSE
      faultmsg('cannot create')
    ENDIF
  ELSE
    IF pathtype(dpath) > 0
      showmsg('that name already exists - e edits it')
      RETURN
    ENDIF
    drawpaths()
    r := editfile(dpath, tname)
    IF r = 1
      StrCopy(prevname, tname)
      refreshall()
      selectbyname(p)
    ELSEIF r = 0
      drawall()    -> nothing was saved, nothing exists
    ENDIF
  ENDIF
ENDPROC

PROC waitkey()
  DEF class, code, done=FALSE
  WHILE done = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      done := TRUE
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80 THEN done := TRUE    -> key down only
    ENDIF
  ENDWHILE
ENDPROC

-> a help line on pane row r (skipped when the grid is too short)
PROC helptext(s, r)
  IF r >= visrows THEN RETURN
  Move(rp, x0 + (19 * cw), panetop + (r * ch) + baseline)
  Text(rp, s, StrLen(s))
ENDPROC

PROC helpscreen()
  DEF y
  drawviewframe(TRUE)    -> closed border + the viewer's footer
  SetAPen(rp, 0)
  RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
           panetop + Mul(visrows, ch) - 1)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  y := 0
  helptext('CFile 0.2', y)
  helptext('Tab ........ switch pane', y + 2)
  helptext('Up/Down .... move (Shift = page, Ctrl = first/last)', y + 3)
  helptext('Right/Left . enter / parent, then the volume list', y + 4)
  helptext('Enter ...... open: enter dir, view text, run binary', y + 5)
  helptext('v .......... view; marks tour with Right/Left', y + 6)
  helptext('e .......... edit text file (e in the viewer works too)', y + 7)
  helptext('i .......... file info, edit protection bits', y + 8)
  helptext('u .......... unpack archive(s), marks work', y + 9)
  helptext('p .......... pack into an archive (.lha/.lzx/.zip)', y + 10)
  helptext('Space ...... mark/unmark (ops take the marks if any)', y + 11)
  helptext('c / C ...... copy to the other pane (C overwrites)', y + 12)
  helptext('m / M ...... move to the other pane (M overwrites)', y + 13)
  helptext('r .......... rename (marks: one at a time)', y + 14)
  helptext('n .......... new file in the editor (name/ = dir)', y + 15)
  helptext('Del / D .... delete, directories and all (asks first)', y + 16)
  helptext(': .......... run a shell command here', y + 17)
  helptext('? / Help ... this help', y + 18)
  helptext('Esc ........ quit (asks first)', y + 19)
  helptext('press any key', y + 21)
  waitkey()
  drawall()
ENDPROC

PROC eventloop()
  DEF class, code, qual, k, done=FALSE
  WHILE done = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    qual := MsgQualifier()
    IF class = IDCMP_VANILLAKEY
      clearmsg()    -> any key first gives the paths row back
      IF code = 27
        -> one stray Esc (say, out of the viewer) must not kill the
        -> session: only y quits
        promptrow('quit CFile? (y)es (n)o')
        k := waitvanilla()
        IF (k = "y") OR (k = "Y")
          done := TRUE
        ELSE
          drawpaths()
        ENDIF
      ELSEIF code = 9
        switchpane()
      ELSEIF (code = "h") OR (code = "H") OR (code = "?")
        helpscreen()
      ELSEIF code = 13     -> Enter: open by type
        doopen()
      ELSEIF (code = "v") OR (code = "V")
        doview()
      ELSEIF (code = "e") OR (code = "E")
        doedit()
      ELSEIF (code = "i") OR (code = "I")
        infowindow()
      ELSEIF code = "c"
        doxfer(FALSE, FALSE)
      ELSEIF code = "C"
        doxfer(FALSE, TRUE)
      ELSEIF code = "m"
        doxfer(TRUE, FALSE)
      ELSEIF code = "M"
        doxfer(TRUE, TRUE)
      ELSEIF (code = "r") OR (code = "R")
        dorename()
      ELSEIF (code = "n") OR (code = "N")
        donew()
      ELSEIF (code = 127) OR (code = "D")    -> the Del key, or D
        dodelete()
      ELSEIF code = 32     -> Space: mark for a bulk copy/move/delete
        togglemark()
      ELSEIF code = ":"    -> a shell command in the active directory
        docommand()
      ELSEIF (code = "u") OR (code = "U")
        dounpack()
      ELSEIF (code = "p") OR (code = "P")
        dopack()
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80    -> key down only, ignore releases
        clearmsg()
        IF code = RK_UP
          IF qual AND IEQUALIFIER_CONTROL
            pagemove(-MAXENT)
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            pagemove(-(visrows - 1))
          ELSE
            moveup()
          ENDIF
        ELSEIF code = RK_DOWN
          IF qual AND IEQUALIFIER_CONTROL
            pagemove(MAXENT)
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            pagemove(visrows - 1)
          ELSE
            movedown()
          ENDIF
        ELSEIF code = RK_RIGHT
          enterdir()
        ELSEIF code = RK_LEFT
          parentdir()
        ELSEIF code = RK_HELP    -> the Amiga Help key
          helpscreen()
        ENDIF
      ENDIF
    ENDIF
    IF wantreload    -> the config was saved from the editor
      wantreload := FALSE
      applyconfig()
    ENDIF
  ENDWHILE
ENDPROC

PROC main() HANDLE
  ensureassigns()
  loadconfig()
  parseargs()
  initpanes()
  readpane(0)
  readpane(1)
  openui()
  drawall()
  eventloop()
  closeui()
  saveconfig()
  dropassigns()
EXCEPT DO
  closeui()
  SELECT exception
    CASE "UI"
      WriteF('CFile: cannot open UI (\s)\n', exceptioninfo)
      rc := 20
    CASE "MEM"
      WriteF('CFile: out of memory\n')
      rc := 20
  ENDSELECT
  CleanUp(rc)
ENDPROC

-> 80 pad spaces for the fixed-width edit fields (the command line
-> pads up to 69 cells; running past this static would draw the next
-> one - progart's dashes - as a phantom border)
spaces: CHAR '                                                                                '

-> frame pieces measured from his two mockups, composed at
-> runtime for any grid: rowcodes 0-4 = logo rows, 21-23 =
-> main footer (nrows-3..-1), 31-33 = view footer (viewbuf
-> rows 1-3). Anchor 0 = col from left, 1 = centered, 2 =
-> distance from the right edge. Table: row,anchor,param,
-> width,blob offset; -99 ends it.
cpieces: CHAR 46,95,32,32,32,95,46,32,32,32,32,32,95,95,32,32
  CHAR 32,95,95,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,46,95,32,32,32,95,46,32,41,40,92,32,47,41
  CHAR 40,32,32,32,32,47,32,47,32,32,47,32,47,95,32,32
  CHAR 32,32,32,95,95,32,95,95,32,32,32,32,41,40,92,32
  CHAR 47,41,40,32,96,46,32,94,32,46,39,32,32,95,47,32
  CHAR 32,124,95,47,32,95,95,47,95,95,32,95,47,32,32,124
  CHAR 32,32,92,95,32,32,96,32,32,94,32,32,39,32,32,33
  CHAR 32,161,32,33,32,32,124,32,32,32,32,124,32,32,32,96
  CHAR 41,32,32,32,124,62,32,32,32,95,32,32,32,60,46,32
  CHAR 32,33,32,161,32,33,32,32,32,32,32,33,32,32,32,32
  CHAR 96,45,45,45,45,94,45,45,46,95,95,95,95,95,124,45
  CHAR 45,45,45,124,95,95,95,95,124,32,32,32,32,33,32,32
  CHAR 32,32,183,183,124,124,124,32,32,32,32,32,32,92,32,33
  CHAR 58,32,47,32,32,32,32,32,32,124,124,32,32,32,32,32
  CHAR 32,92,92,63,32,61,32,104,101,108,112,183,69,115,99,32
  CHAR 61,32,81,117,105,116,47,47,32,32,32,32,32,32,124,96
  CHAR 45,45,45,45,45,45,32,92,45,32,45,45,45,45,45,32
  CHAR 47,45,32,45,45,45,45,45,45,32,45,247,45,32,65,32
  CHAR 76,65,84,69,88,32,80,82,79,68,85,67,84,105,79,78
  CHAR 33,32,45,247,45,32,45,45,45,45,45,45,32,45,92,45
  CHAR 45,45,45,45,32,45,47,32,45,45,45,45,45,45,39,183
  CHAR 32,32,32,32,32,32,92,32,47,32,32,32,32,32,32,46
  CHAR 33,32,32,32,32,32,32,92,92,69,115,99,32,61,32,82
  CHAR 101,116,117,114,110,32,116,111,32,102,105,108,101,32,118,105
  CHAR 101,119,47,47,32,32,32,32,32,32,58,96,45,45,45,45
  CHAR 45,45,32,92,45,32,45,45,45,45,45,32,47,45,32,45
  CHAR 45,45,45,45,45,32,45,247,45,32,65,32,76,65,84,69
  CHAR 88,32,80,82,79,68,85,67,84,105,79,78,33,32,45,247
  CHAR 45,32,45,45,45,45,45,45,32,45,92,45,45,45,45,45
  CHAR 32,45,47,32,45,45,45,45,45,45,39

ctab: LONG 0,0,14,8,0,0,1,0,25,8,0,2,24,9,33
  LONG 1,0,14,8,42,1,1,0,25,50,1,2,24,9,75
  LONG 2,0,14,8,84,2,1,0,25,92,2,2,24,9,117
  LONG 3,0,14,8,126,3,1,0,25,134,3,2,24,9,159
  LONG 4,0,14,8,168,4,1,0,25,176,4,2,24,9,201
  LONG 3,0,0,1,210,3,2,1,1,211,4,0,0,1,212
  LONG 4,2,1,1,213,21,0,0,9,214,21,1,0,2,223
  LONG 21,2,9,9,225,22,0,0,9,234,22,0,19,8,243
  LONG 22,1,0,1,251,22,2,28,10,252,22,2,9,9,262
  LONG 23,0,0,27,271,23,1,0,27,298,23,2,26,26,325
  LONG 31,0,0,8,351,31,2,9,9,359,32,0,0,9,368
  LONG 32,1,0,25,377,32,2,9,9,402,33,0,0,27,411
  LONG 33,1,0,27,438,33,2,26,26,465
  LONG -99

-> 200 pad spaces (grids can be wider than 80 cols)
spaces2: CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32

-> the progress bar box, 3 rows of 33 characters flat (his mockup):
-> .-------------------------------. / | 31 spaces | / `31 dashes´
-> Numeric bytes only: E-VO appends a NUL to every quoted string in
-> CHAR data, which would shift the row offsets.
progart: CHAR 46,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 46,124,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,124,96,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 45,45,180

version: CHAR '$VER: CFile 0.2 (16.7.26) E build',0