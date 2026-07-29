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
->   Right       enter the selected directory, volume, or lha archive
->               (an archive opens like a directory - browse it, view,
->               and c/m/r/n/Del/e all work inside it; Left exits)
->   Left        back to the parent directory (re-selects where you
->               came from); at a device root, the volume list; inside
->               an archive, up a level, then out to the real directory
->   Enter       open by type: enter a directory or lha archive, view
->               text, run a hunk executable (asks first), hex the rest
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
       'dos/datetime','dos/dostags','devices/inputevent','diskfont',
       'dos/exall','graphics/gfx'

CONST CPATHLEN=300, MAXENT=500, CBUFSZ=16384, PIPESZ=4096,
      EABUFSZ=16384,  -> I3: ExAll batch buffer, dozens of entries/trip
      DTCHUNK=100,    -> I7b: names snapshotted per deltree scan round
      FINDMAX=500,    -> find: results collected before the search stops
      FLDW=10,    -> fixed border-row status slot (widest: "500* 1023K")
      CSZW=5,     -> pane size column (widest: "1023K", "<DIR>")
      EDMAXL=8192, EDLINIT=120,    -> editor: line count cap, initial
                                   -> per-line buffer (lines grow on demand,
                                   -> so there is no line-length limit)
      CMAXL=4000,    -> console scrollback, lines of 80
      MAXMEM=1500,   -> members cached when going inside one lha archive
      RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F, RK_HELP=$5F,
      RK_F5=$54,    -> re-read both panes
      VIEWMAX=524288,    -> the viewers load whole files; cap at 512KB
      TY_OTHER=0, TY_EXEC=1, TY_TEXT=2, TY_LHA=3, TY_LZX=4, TY_ZIP=5,
      TY_ANSI=6, TY_ISO=7, TY_ADF=8,
      ISOSEC=2048,    -> ISO9660 logical sector (the only size supported)
      ADFDD=901120, ADFHD=1802240,    -> the only sizes trackfile mounts
      DAMAX=8,        -> disk images mounted by this CFile at once
      -> per-member cache status for deferred archive writes (0.3b3):
      -> CLEAN, flagged for DELETE at commit, a new member ADDed since
      -> entry, or a committed member whose staged copy REPLACEs it (edit
      -> in place, or copy-in over an existing member). ADD and REPLACE
      -> both have a file waiting in the staging tree; REPLACE also needs
      -> the old member deleted first (the commit's delete pass does it).
      -> Set by the write verbs under ARCWRITE ONEXIT, flushed on exit.
      MST_CLEAN=0, MST_DEL=1, MST_ADD=2, MST_REPLACE=3

DEF enames[1000]:ARRAY OF LONG,   -> entry names, MAXENT slots per pane
    edirs[1000]:ARRAY OF CHAR,    -> nonzero = entry is a directory
    emark[1000]:ARRAY OF CHAR,    -> nonzero = entry is marked
    esize[1000]:ARRAY OF LONG,    -> file size (0 for dirs/volumes)
    edate[1000]:ARRAY OF LONG,    -> sortable date key (days*1440+minute,
                                  -> 0 for archive members and volumes)
    eext[1000]:ARRAY OF LONG,     -> ISO panes: the entry's extent LBA
                                  -> (0 elsewhere). A SIXTH parallel
                                  -> field: rides swapentry/snapentry/
                                  -> unsnapentry like the other five
    edds[8000]:ARRAY OF CHAR,     -> C4: per-slot "DDMon" memo, 8B each
    eddk[1000]:ARRAY OF LONG,     -> C4: the datekey each memo is FOR.
                                  -> VALUE-keyed (datestr is a pure
                                  -> function of the key), so the entry
                                  -> movers need NOT carry these: any
                                  -> reorder just mismatches the tag
                                  -> and the slot re-fills on next draw
                                  -> - no new esize-lesson exposure
    ealloc[2]:ARRAY OF LONG,      -> allocated name slots per pane
    ecount[2]:ARRAY OF LONG,
    esel[2]:ARRAY OF LONG,
    etop[2]:ARRAY OF LONG,        -> first visible entry (scroll)
    efail[2]:ARRAY OF LONG,       -> directory could not be read
    pfree[2]:ARRAY OF LONG,       -> cached free bytes, -1 = none to show
    pfreeok[2]:ARRAY OF LONG,     -> 0 = cache stale, ask Info() again
    ppath[2]:ARRAY OF LONG,
    active=0,
    scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    ownscr=FALSE, txtpen=1, dirpen=1, errpen=1, softmask=0,
    panemask=255, flatmask=255,   -> R6: scroll-blit plane masks (255
                                  -> = unmasked; set at openui only on
                                  -> a planar-standard own screen)
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
    cbufsz=CBUFSZ,    -> its actual size: 256K/64K when RAM allows (I1)
    pipebuf=NIL:PTR TO CHAR,    -> shared PIPE: read buffer (I7a); safe
                                -> because the two pipe readers are modal
                                -> loops that can never nest
    rnames[500]:ARRAY OF LONG,    -> resolved target names (bulk runs)
    ridx[500]:ARRAY OF LONG,      -> entry index per resolved slot
    ralloc=0,                     -> allocated rnames slots
    msgup=FALSE,      -> a message covers the paths row; next key clears
    opmsg[120]:STRING,    -> last message, re-shown after a bulk refresh
    progon=FALSE, progtotal=1, progdone=0, progpx=0, progx=0, progy=0,
    progbyfile=FALSE,    -> bar counts lha's per-file lines, not copy bytes
    progbybytes=FALSE,   -> bar advances by each lha member's byte total
                         -> (parsed from its "(done/total)"), for the
                         -> archive copy/move bar - big members weigh more
    proglzx=0,           -> lzx byte bar: 1 = add ("Adding (<size>)"),
                         -> 2 = extract ("( <run> / <total> )"); overrides the
                         -> lha marker parse in arcrunprog
    statbytes=0, statfiles=0,    -> pre-scan totals for the progress bar
    gfails=0,    -> entries a delete run could not remove
    unprotall=FALSE,    -> 'a' at the unprotect prompt covers the run
    cancelok=FALSE,     -> a cancellable op is running (copy/move/delete or an
                        -> archive transfer); only then does Esc set `abort`
    abort=FALSE,        -> Esc pressed mid-op: the copy/tree loops bail out,
                        -> and a running archiver child is handed the break
    runname[24]:STRING, -> the detached archiver's process name (NP_NAME),
                        -> unique per CFile instance: Esc's break signal can
                        -> only ever find OUR child (arcname/arcbreak)
    ccol=0, crow=0, cesc=0, cnum=0,    -> the in-frame console renderer
    cmodel=NIL, cmrow=0, cmfull=FALSE,  -> its text model: the scrollback
                                  -> (cmfull: R2 - model cap reached,
                                  -> the direct path serves the rest)
    cfgleft[300]:STRING, cfgright[300]:STRING,    -> start paths
    savedirs=TRUE,          -> rewrite the config with them on quit
    arcwrite=TRUE,          -> ARCWRITE key: TRUE = ONEXIT (batch archive
                            -> edits, commit on leave/quit - the default
                            -> since 0.3b3), FALSE = DIRECT (repack per
                            -> edit, the old behaviour).
    icons=TRUE,             -> ICONS key: TRUE = copy/move/delete/rename
                            -> take a "<name>.info" sidecar along (default),
                            -> FALSE = leave icons where they are.
    sortmode=0,             -> 0 = name (A-Z), 1 = size (large first),
                            -> 2 = date (newest first); directories always
                            -> sort ahead of files
    sortrev=FALSE,          -> reverse the within-tier order
    cfgfont[40]:STRING,     -> FONT key, applied by the grid build
    bmark[10]:ARRAY OF LONG,     -> 10 bookmark slots: String ptr per slot,
                                 -> "" = the volume list. Set by Alt+digit,
                                 -> jumped to by the bare digit. Slot i is
                                 -> the digit i (0-9).
    bmarkset[10]:ARRAY OF CHAR,  -> nonzero = that slot holds a bookmark
    savebmarks=FALSE,       -> SAVEBOOKMARKS key: persist slots across runs
    madeenv=FALSE, madet=FALSE,    -> assigns CFile itself created
    edl=NIL:PTR TO LONG, ednum=0,    -> the editor's line table
    edcur=0, edcol=0, edvtop=0, edxoff=0, edmod=FALSE, ednew=FALSE,
    -> "inside an archive": a third pane mode beside real-dir and the
    -> volume list. arcpath[p] holds the real .lha (empty = not inside);
    -> arcsub[p] is where we are within it (empty = archive root). The
    -> whole member list is parsed once on entry into amem/amsz and the
    -> pane listings are filtered out of that cache - no lha per keypress.
    arcpath[2]:ARRAY OF LONG, arcsub[2]:ARRAY OF LONG,
    isopath[2]:ARRAY OF LONG,  -> pane browses inside this .iso ('' = no)
    isosub[2]:ARRAY OF LONG,   -> current directory within the image
    isoroot[2]:ARRAY OF LONG,  -> root dir extent LBA (from the PVD)
    isorootsz[2]:ARRAY OF LONG, -> root dir byte size
    damdev[8]:ARRAY OF LONG,   -> ADF mounts WE made: device ('' = free
    damfile[8]:ARRAY OF LONG,  -> slot), the image file behind it, the
    damback[8]:ARRAY OF LONG,  -> directory to return to on unmount and
    damname[8]:ARRAY OF LONG,  -> the .adf name to reselect there
    amem[2]:ARRAY OF LONG,     -> New()'d LONG[] of member-path String ptrs
    amsz[2]:ARRAY OF LONG,     -> New()'d LONG[] of member sizes
    amst[2]:ARRAY OF LONG,     -> New()'d LONG[] of MST_* status per member
    amcnt[2]:ARRAY OF LONG,    -> members cached for the pane
    arcfmt[2]:ARRAY OF LONG,   -> archive kind of the pane: TY_LHA or TY_LZX
    rc=0,
    -> BENCH mode: temporary perf-campaign instrument (perf-roadmap.md
    -> phase 0). `cfile BENCH <dir> [file] [needle]` - see dobench()
    benchmode=FALSE, bdir[300]:STRING, bfile[300]:STRING,
    bneedle[80]:STRING

-> the global arrays are NOT zero-initialised (E globals live in the
-> uncleared stack allocation), so every pane field is set explicitly
-> here and name slots are tracked with ealloc
PROC initpanes()
  DEF p
  FOR p := 0 TO 1
    IF (ppath[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    IF (arcpath[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    IF (arcsub[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    IF (isopath[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    IF (isosub[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    isoroot[p] := 0
    isorootsz[p] := 0
  ENDFOR
  FOR p := 0 TO DAMAX - 1
    IF (damdev[p] := String(16)) = NIL THEN Raise("MEM")
    IF (damfile[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    IF (damback[p] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    IF (damname[p] := String(110)) = NIL THEN Raise("MEM")
  ENDFOR
  FOR p := 0 TO 1
    amem[p] := NIL
    amsz[p] := NIL
    amst[p] := NIL
    amcnt[p] := 0
    arcfmt[p] := TY_LHA
    ealloc[p] := 0
    ecount[p] := 0
    esel[p] := 0
    etop[p] := 0
    efail[p] := FALSE
  ENDFOR
  StrCopy(ppath[0], cfgleft)
  StrCopy(ppath[1], cfgright)
  -> I1: bigger copy chunks = fewer packet round trips (the audit's
  -> 13ms/16KB floor). 256KB only when the machine clearly has room,
  -> 64KB as the normal case, the old 16KB so a 2MB machine keeps its
  -> RAM for the editor. MUST be New(), not String(): E-VO String()
  -> returns NIL for >= 32767 bytes (vamos-proven, strsz.e) - the
  -> first ladder build silently fell through to 16KB on every config.
  -> copybuf is a raw byte buffer (Read/Write/CopyMem only), so New()
  -> is the right kind anyway.
  cbufsz := IF AvailMem(0) > $400000 THEN 262144 ELSE 65536
  IF (copybuf := New(cbufsz)) = NIL
    cbufsz := 65536
    IF (copybuf := New(cbufsz)) = NIL
      cbufsz := CBUFSZ
      IF (copybuf := New(cbufsz)) = NIL THEN Raise("MEM")
    ENDIF
  ENDIF
  IF (pipebuf := New(PIPESZ)) = NIL THEN Raise("MEM")
ENDPROC

-> the bookmark slots, allocated before loadconfig so it can fill them from
-> saved BOOKMARK<d> lines (initpanes runs after the config is read)
PROC initbookmarks()
  DEF i
  FOR i := 0 TO 9
    IF (bmark[i] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    bmarkset[i] := 0
  ENDFOR
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

-> read an already-open file whole into a New()'d buffer sized to it (via a
-> seek to the end), so a large hand-edited config is never clipped the way
-> the old fixed 4KB read would. Returns the buffer - the caller Dispose()s
-> it - and writes the byte count to cnt. An empty file gives a valid 1-byte
-> buffer with cnt 0; a real allocation failure gives NIL with cnt -1, so a
-> caller can tell "empty" from "could not read" and never truncate a file
-> it failed to slurp.
PROC slurpfh(fh, cnt:PTR TO LONG)
  DEF sz, buf=NIL, n=0
  cnt[0] := 0
  Seek(fh, 0, OFFSET_END)
  sz := Seek(fh, 0, OFFSET_BEGINNING)    -> previous pos = size; fh rewound
  IF sz < 0 THEN sz := 0
  IF (buf := New(sz + 1)) = NIL
    cnt[0] := -1
    RETURN NIL
  ENDIF
  IF sz > 0
    n := Read(fh, buf, sz)
    IF n < 0 THEN n := 0
  ENDIF
  cnt[0] := n
ENDPROC buf

-> the config lives next to the binary: PROGDIR:cfile.config.
-> KEY value lines, ';' comments. LEFT/RIGHT start paths ("(volumes)"
-> = the volume list), SAVEDIRS ON|OFF, FONT name/size (stored and
-> preserved; takes effect with the font-grid build).
PROC loadconfig()
  DEF fh, buf=NIL, n, i=0, j, c, d, s:PTR TO CHAR,
      line[300]:STRING, key[20]:STRING, val[280]:STRING, l, sp
  StrCopy(cfgleft, 'SYS:')
  StrCopy(cfgright, 'RAM:')
  StrCopy(cfgfont, '')
  IF (fh := Open('PROGDIR:cfile.config', OLDFILE)) = NIL THEN RETURN
  buf := slurpfh(fh, {n})
  Close(fh)
  IF buf = NIL THEN RETURN
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
          ELSEIF StrCmp(key, 'ARCWRITE')
            UpperStr(val)
            arcwrite := StrCmp(val, 'ONEXIT')    -> else DIRECT
          ELSEIF StrCmp(key, 'ICONS')
            UpperStr(val)
            icons := StrCmp(val, 'ON')    -> else OFF
          ELSEIF StrCmp(key, 'SORT')
            -> SORT name|size|date, plus an optional "rev" word
            UpperStr(val)
            IF InStr(val, 'SIZE') >= 0
              sortmode := 1
            ELSEIF InStr(val, 'DATE') >= 0
              sortmode := 2
            ELSE
              sortmode := 0
            ENDIF
            sortrev := InStr(val, 'REV') >= 0
          ELSEIF StrCmp(key, 'FONT')
            StrCopy(cfgfont, val)
          ELSEIF StrCmp(key, 'SAVEBOOKMARKS')
            UpperStr(val)
            savebmarks := StrCmp(val, 'ON')
          ELSEIF (EstrLen(key) = 9) AND StrCmp(key, 'BOOKMARK', 8) AND
                 (key[8] >= "0") AND (key[8] <= "9")
            -> BOOKMARK<d> <path>; "(volumes)" = the volume list. bmark[] is
            -> allocated by initbookmarks() before loadconfig runs.
            d := key[8] - "0"
            IF StrCmp(val, '(volumes)')
              StrCopy(bmark[d], '')
            ELSE
              StrCopy(bmark[d], val)
            ENDIF
            bmarkset[d] := 1
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
        IF nccmp(tok, 'BENCH') = 0
          benchmode := TRUE
        ELSE
          StrCopy(cfgleft, tok)
        ENDIF
      ELSEIF benchmode
        IF ntok = 1
          StrCopy(bdir, tok)
        ELSEIF ntok = 2
          StrCopy(bfile, tok)
        ELSEIF ntok = 3
          StrCopy(bneedle, tok)
        ENDIF
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

-> write a config line through verbatim, restoring the newline slurpfh stripped
PROC passline(fh, line)
  DEF b[302]:STRING
  StrCopy(b, line)
  StrAdd(b, '\n')
  wline(fh, b)
ENDPROC

-> SAVEBOOKMARKS ON: write a BOOKMARK<d> line for each set slot. Old
-> BOOKMARK lines are dropped in the pass-through, so these are the fresh set.
PROC savebookmarks(fh)
  DEF d, line[340]:STRING
  FOR d := 0 TO 9
    IF bmarkset[d]
      StringF(line, 'BOOKMARK\d \s\n', d,
              IF EstrLen(bmark[d]) = 0 THEN '(volumes)' ELSE bmark[d])
      wline(fh, line)
    ENDIF
  ENDFOR
ENDPROC

PROC saveconfig()
  DEF fh, buf=NIL, n=0, i, j, l, sp, c, s:PTR TO CHAR,
      line[300]:STRING, key[20]:STRING, wl=FALSE, wr=FALSE
  IF (savedirs = FALSE) AND (savebmarks = FALSE) THEN RETURN
  IF fh := Open('PROGDIR:cfile.config', OLDFILE)
    buf := slurpfh(fh, {n})
    Close(fh)
  ENDIF
  -> the file exists but could not be read (cnt -1: too big to allocate):
  -> do NOT open it NEWFILE, which would truncate it to just the defaults.
  -> Leave the original untouched.
  IF n < 0 THEN RETURN
  IF (fh := Open('PROGDIR:cfile.config', NEWFILE)) = NIL
    IF buf THEN Dispose(buf)
    RETURN
  ENDIF
  IF n = 0
    StringF(line, '; CFile configuration - LEFT/RIGHT start paths,\n')
    wline(fh, line)
    StringF(line, '; SAVEDIRS ON|OFF, ARCWRITE DIRECT|ONEXIT,\n')
    wline(fh, line)
    StringF(line, '; ICONS ON|OFF, SORT name|size|date [rev], FONT name/size\n')
    wline(fh, line)
    StringF(line, 'SAVEDIRS ON\n')
    wline(fh, line)
    StringF(line, 'ARCWRITE ONEXIT\n')
    wline(fh, line)
    StringF(line, 'ICONS ON\n')
    wline(fh, line)
    StringF(line, 'SORT name\n')
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
      -> LEFT/RIGHT are rewritten only when SAVEDIRS is on; otherwise they
      -> pass through untouched. Old BOOKMARK lines are dropped (the current
      -> set is written fresh at the end when SAVEBOOKMARKS is on).
      IF StrCmp(key, 'LEFT')
        IF savedirs THEN savepane(fh, 'LEFT', 0) ELSE passline(fh, line)
        wl := TRUE
      ELSEIF StrCmp(key, 'RIGHT')
        IF savedirs THEN savepane(fh, 'RIGHT', 1) ELSE passline(fh, line)
        wr := TRUE
      ELSEIF (EstrLen(key) = 9) AND StrCmp(key, 'BOOKMARK', 8) AND
             (key[8] >= "0") AND (key[8] <= "9")
        -> drop it
      ELSE
        passline(fh, line)
      ENDIF
    ENDWHILE
  ENDIF
  IF savedirs
    IF wl = FALSE THEN savepane(fh, 'LEFT', 0)
    IF wr = FALSE THEN savepane(fh, 'RIGHT', 1)
  ENDIF
  IF savebmarks THEN savebookmarks(fh)
  Close(fh)
  IF buf THEN Dispose(buf)
ENDPROC

-> write one setting block: a ";" explanation, the KEY value, a blank line
PROC cfgput(fh, comment, key, val)
  DEF line[300]:STRING
  StringF(line, '; \s\n', comment)
  wline(fh, line)
  StringF(line, '\s \s\n\n', key, val)
  wline(fh, line)
ENDPROC

-> the value a key should carry in the file, read from the live settings
-> (which hold the loaded value, or the default when the key was absent)
PROC cfgval(key, dst)
  IF StrCmp(key, 'LEFT')
    IF EstrLen(cfgleft) = 0 THEN StrCopy(dst, '(volumes)') ELSE StrCopy(dst, cfgleft)
  ELSEIF StrCmp(key, 'RIGHT')
    IF EstrLen(cfgright) = 0 THEN StrCopy(dst, '(volumes)') ELSE StrCopy(dst, cfgright)
  ELSEIF StrCmp(key, 'SAVEDIRS')
    StrCopy(dst, IF savedirs THEN 'ON' ELSE 'OFF')
  ELSEIF StrCmp(key, 'ARCWRITE')
    StrCopy(dst, IF arcwrite THEN 'ONEXIT' ELSE 'DIRECT')
  ELSEIF StrCmp(key, 'ICONS')
    StrCopy(dst, IF icons THEN 'ON' ELSE 'OFF')
  ELSEIF StrCmp(key, 'SORT')
    IF sortmode = 1
      StrCopy(dst, 'size')
    ELSEIF sortmode = 2
      StrCopy(dst, 'date')
    ELSE
      StrCopy(dst, 'name')
    ENDIF
    IF sortrev THEN StrAdd(dst, ' rev')
  ELSEIF StrCmp(key, 'FONT')
    IF EstrLen(cfgfont) = 0 THEN StrCopy(dst, 'topaz.font') ELSE StrCopy(dst, cfgfont)
  ELSEIF StrCmp(key, 'SAVEBOOKMARKS')
    StrCopy(dst, IF savebmarks THEN 'ON' ELSE 'OFF')
  ELSE
    StrCopy(dst, '')
  ENDIF
ENDPROC

-> TRUE if `key` appears as the first token of a non-comment line in buf
PROC keypresent(buf:PTR TO CHAR, n, key)
  DEF i=0, j, l, line[300]:STRING, tok[24]:STRING, sp, found=FALSE
  WHILE (i < n) AND (found = FALSE)
    j := i
    WHILE (j < n) AND (buf[j] <> 10)
      j++
    ENDWHILE
    l := j - i
    IF l > 298 THEN l := 298
    StrCopy(line, '')
    IF l > 0 THEN StrCopy(line, buf + i, l)
    i := j + 1
    IF (EstrLen(line) > 0) AND (line[0] <> ";")
      sp := 0
      WHILE (sp < EstrLen(line)) AND (line[sp] <> 32)
        sp++
      ENDWHILE
      IF sp > 0
        StrCopy(tok, line, IF sp > 22 THEN 22 ELSE sp)
        UpperStr(tok)
        IF StrCmp(tok, key) THEN found := TRUE
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC found

-> at start-up: create cfile.config with commented defaults if it is
-> missing, or append any known setting the file does not yet have (so a
-> setting added in a later CFile just appears, no hand-editing). The
-> table is the one place a new setting is declared - key + its comment.
PROC configensure()
  DEF tab:PTR TO LONG, nk=8, ki, fh, buf=NIL, n=0, exists=FALSE,
      key:PTR TO CHAR, comment:PTR TO CHAR, val[300]:STRING,
      anymissing=FALSE, line[80]:STRING
  tab := ['LEFT', 'Left pane start path.  (volumes) starts in the volume list.',
          'RIGHT', 'Right pane start path.',
          'SAVEDIRS', 'Write the pane paths back on quit: ON or OFF.',
          'ARCWRITE', 'Archive edits to disk: ONEXIT (batch, commit on leave) or DIRECT.',
          'ICONS', 'Carry a file .info icon along on copy/move/delete/rename: ON or OFF.',
          'SORT', 'Start-up sort order: name, size or date; add rev to reverse.',
          'FONT', 'Display font name/size.  topaz.font = ROM Topaz 8.',
          'SAVEBOOKMARKS', 'Remember the b+digit bookmark slots across runs: ON or OFF.']:LONG
  IF fh := Open('PROGDIR:cfile.config', MODE_OLDFILE)
    exists := TRUE
    buf := slurpfh(fh, {n})
    Close(fh)
  ENDIF
  IF exists AND (buf = NIL) THEN RETURN    -> could not read; leave it be
  IF exists = FALSE
    -> no file: write a fresh one with every block
    IF fh := Open('PROGDIR:cfile.config', MODE_NEWFILE)
      StringF(line, '; CFile configuration\n\n')
      wline(fh, line)
      FOR ki := 0 TO nk - 1
        key := tab[ki * 2]
        comment := tab[(ki * 2) + 1]
        cfgval(key, val)
        cfgput(fh, comment, key, val)
      ENDFOR
      Close(fh)
    ENDIF
    RETURN
  ENDIF
  -> the file exists: append any key it is missing
  FOR ki := 0 TO nk - 1
    IF keypresent(buf, n, tab[ki * 2]) = FALSE THEN anymissing := TRUE
  ENDFOR
  IF anymissing
    IF fh := Open('PROGDIR:cfile.config', MODE_OLDFILE)
      Seek(fh, 0, OFFSET_END)
      StringF(line, '\n')
      wline(fh, line)
      FOR ki := 0 TO nk - 1
        key := tab[ki * 2]
        comment := tab[(ki * 2) + 1]
        IF keypresent(buf, n, key) = FALSE
          cfgval(key, val)
          cfgput(fh, comment, key, val)
        ENDIF
      ENDFOR
      Close(fh)
    ENDIF
  ENDIF
  Dispose(buf)
ENDPROC

-> an empty pane path means the pane shows the volume list
PROC involume(p)
ENDPROC EstrLen(ppath[p]) = 0

-> the pane is browsing inside an lha archive (read-only, for now)
PROC inarchive(p)
ENDPROC EstrLen(arcpath[p]) > 0

-> TRUE if the pane's archive carries uncommitted edits: any cached
-> member flagged for deletion, or a member added since entry. Drives
-> the "modified" tag on the border row and, later, the commit on exit.
PROC arcdirty(p)
  DEF st:PTR TO LONG, k
  IF inarchive(p) = FALSE THEN RETURN FALSE
  IF amst[p] = NIL THEN RETURN FALSE
  st := amst[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      IF st[k] <> MST_CLEAN THEN RETURN TRUE
    ENDFOR
  ENDIF
ENDPROC FALSE

-> drop the member cache a pane built on entering an archive
PROC freearccache(p)
  DEF a:PTR TO LONG, i
  IF amem[p]
    a := amem[p]
    FOR i := 0 TO amcnt[p] - 1
      IF a[i] THEN DisposeLink(a[i])
    ENDFOR
    Dispose(amem[p])
    amem[p] := NIL
  ENDIF
  IF amsz[p]
    Dispose(amsz[p])
    amsz[p] := NIL
  ENDIF
  IF amst[p]
    Dispose(amst[p])
    amst[p] := NIL
  ENDIF
  amcnt[p] := 0
ENDPROC

-> leave the archive: clear the mode, forget the cache. The caller
-> restores ppath and reselects the .lha in its real parent.
PROC leavearchive(p)
  arccommit(p)    -> flush deferred edits while the cache still exists
  freearccache(p)
  SetStr(arcpath[p], 0)
  SetStr(arcsub[p], 0)
ENDPROC

-> ---- ISO9660: browse a CD image like a directory, READ-ONLY ---------
-> The parser was proven in a vamos harness (isoh.e, 30.7.26) against
-> Python-mastered images verified by 7z: 143 entries listed and 132
-> files extracted byte-perfect before any of this touched cfile. No
-> member cache: an ISO can dwarf MAXMEM, and its directories are a
-> real tree - each listing reads just the one directory's records.
-> All numbers come from the BIG-endian halves of the format's
-> both-endian fields (the 68k half - no byte swapping anywhere).

PROC iniso(p)
ENDPROC EstrLen(isopath[p]) > 0

-> big-endian u32 at b. CD extents/sizes stay far below 2^31.
PROC isob32(b:PTR TO CHAR)
ENDPROC Shl(b[0], 24) OR Shl(b[1], 16) OR Shl(b[2], 8) OR b[3]

-> read the Primary Volume Descriptor: root dir extent + byte size.
-> Descriptors start at sector 16; type 1 + "CD001" is the PVD, 255
-> ends the set. Only 2048-byte logical blocks are accepted (anything
-> else is vanishingly rare and everything here assumes Shl(x,11)).
PROC isopvd(fh, rootp:PTR TO LONG, rszp:PTR TO LONG)
  DEF buf:PTR TO CHAR, sec, ok=FALSE, t, r:PTR TO CHAR
  IF (buf := New(ISOSEC)) = NIL THEN RETURN FALSE
  FOR sec := 16 TO 31    -> descriptor set: a bounded scan is plenty
    IF ok = FALSE
      IF Seek(fh, Shl(sec, 11), OFFSET_BEGINNING) >= 0
        IF Read(fh, buf, ISOSEC) = ISOSEC
          t := buf[0]
          IF (buf[1] = "C") AND (buf[2] = "D") AND (buf[3] = "0") AND
             (buf[4] = "0") AND (buf[5] = "1")
            IF t = 1
              IF (Shl(buf[130], 8) OR buf[131]) = ISOSEC
                r := buf + 156          -> the root directory record
                rootp[] := isob32(r + 6)
                rszp[]  := isob32(r + 14)
                ok := TRUE
              ENDIF
            ELSEIF t = 255
              sec := 31               -> terminator: stop scanning
            ENDIF
          ELSE
            sec := 31                 -> not a descriptor: stop
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  Dispose(buf)
ENDPROC ok

-> caller-frame directory-record iterator (the eascan shape). One heap
-> sector buffer; records never straddle sectors (a length byte of 0
-> means the rest of this sector is padding - hop to the next one).
OBJECT isoscan
  fh                          -> image file handle (caller owns)
  ext                         -> dir extent LBA
  secs                        -> sectors in the extent
  cur                         -> sectors consumed so far
  pos                         -> parse offset in buf
  avail                       -> valid bytes in buf
  buf:PTR TO CHAR             -> New(ISOSEC); NIL = begin failed
  err
  rsize                       -> current record: file byte size
  rext                        ->   extent LBA
  rdir                        ->   nonzero = directory
  rname[110]:ARRAY OF CHAR    -> display name, NUL-terminated
                              -> (";version" and one trailing "." off)
ENDOBJECT

PROC isodbegin(s:PTR TO isoscan, fh, ext, size)
  s.fh := fh
  s.ext := ext
  s.secs := Shr(size + (ISOSEC - 1), 11)
  s.cur := 0
  s.pos := 0
  s.avail := 0
  s.err := FALSE
  s.buf := New(ISOSEC)
  IF s.buf = NIL THEN s.err := TRUE
ENDPROC

PROC isodsec(s:PTR TO isoscan)    -> pull the next sector into buf
  IF s.cur >= s.secs THEN RETURN FALSE
  IF Seek(s.fh, Shl(s.ext + s.cur, 11), OFFSET_BEGINNING) < 0
    s.err := TRUE
    RETURN FALSE
  ENDIF
  IF Read(s.fh, s.buf, ISOSEC) <> ISOSEC
    s.err := TRUE
    RETURN FALSE
  ENDIF
  s.cur := s.cur + 1
  s.pos := 0
  s.avail := ISOSEC
ENDPROC TRUE

PROC isodnext(s:PTR TO isoscan)
  DEF b:PTR TO CHAR, len, il, i, c, n, going=TRUE
  IF s.err THEN RETURN FALSE
  WHILE going
    IF (s.avail = 0) OR (s.pos >= s.avail)
      IF isodsec(s) = FALSE THEN RETURN FALSE
    ENDIF
    b := s.buf + s.pos
    len := b[0]
    IF len = 0
      s.pos := s.avail    -> padding: the rest of this sector is dead
    ELSEIF (s.pos + len) > s.avail
      s.err := TRUE       -> a record cannot straddle: broken image
      RETURN FALSE
    ELSE
      s.pos := s.pos + len
      il := b[32]
      IF (il = 1) AND (b[33] <= 1)
        -> the "." / ".." records: skip
      ELSE
        s.rext := isob32(b + 6)
        s.rsize := isob32(b + 14)
        s.rdir := b[25] AND 2
        n := 0
        IF il > 106 THEN il := 106    -> enames slots are String(108)
        FOR i := 0 TO il - 1
          c := b[33 + i]
          IF (c = ";") AND (s.rdir = 0)
            i := il             -> ";version": the name ends here
          ELSE
            s.rname[n] := c
            n++
          ENDIF
        ENDFOR
        IF n > 1
          IF s.rname[n - 1] = "." THEN n--    -> "TRAIL." stores a dot
        ENDIF
        s.rname[n] := 0
        IF n > 0 THEN going := FALSE          -> a real entry: yield
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC TRUE

PROC isodend(s:PTR TO isoscan)
  IF s.buf THEN Dispose(s.buf)
  s.buf := NIL
ENDPROC

-> resolve a "/"-separated path inside the image to (extent, size,
-> isdir), walking from the root. Empty path = the root itself.
PROC isofind(fh, root, rootsz, path:PTR TO CHAR,
             extp:PTR TO LONG, szp:PTR TO LONG, dirp:PTR TO LONG)
  DEF comp[110]:STRING, i=0, j, ext, sz, isdir=2, found, done=FALSE,
      s[1]:ARRAY OF isoscan, sc:PTR TO isoscan
  ext := root
  sz := rootsz
  sc := s
  WHILE done = FALSE
    j := 0
    WHILE (path[i] <> 0) AND (path[i] <> "/")
      IF j < 106
        comp[j] := path[i]
        j++
      ENDIF
      i++
    ENDWHILE
    IF path[i] = "/" THEN i++
    comp[j] := 0
    SetStr(comp, j)
    IF j = 0
      IF path[i] = 0 THEN done := TRUE    -> ran out of components
    ELSE
      IF isdir = 0 THEN RETURN FALSE      -> a component under a FILE
      found := FALSE
      isodbegin(sc, fh, ext, sz)
      WHILE (found = FALSE) AND isodnext(sc)
        IF nccmp(sc.rname, comp) = 0
          ext := sc.rext
          sz := sc.rsize
          isdir := sc.rdir
          found := TRUE
        ENDIF
      ENDWHILE
      isodend(sc)
      IF found = FALSE THEN RETURN FALSE
      IF path[i] = 0 THEN done := TRUE
    ENDIF
  ENDWHILE
  extp[] := ext
  szp[] := sz
  dirp[] := isdir
ENDPROC TRUE

-> does the path smell like an ISO image? Cheap gate: ".iso" suffix,
-> then the CD001 magic where the descriptor set lives.
PROC isoext(name:PTR TO CHAR)
  DEF l
  l := StrLen(name)
  IF l < 5 THEN RETURN FALSE
  IF (name[l - 4] <> ".") THEN RETURN FALSE
  IF (name[l - 3] <> "i") AND (name[l - 3] <> "I") THEN RETURN FALSE
  IF (name[l - 2] <> "s") AND (name[l - 2] <> "S") THEN RETURN FALSE
  IF (name[l - 1] <> "o") AND (name[l - 1] <> "O") THEN RETURN FALSE
ENDPROC TRUE

PROC isomagic(path)
  DEF fh, b[8]:ARRAY OF CHAR, ok=FALSE
  IF (fh := Open(path, OLDFILE)) = NIL THEN RETURN FALSE
  IF Seek(fh, Shl(16, 11) + 1, OFFSET_BEGINNING) >= 0
    IF Read(fh, b, 5) = 5
      IF (b[0] = "C") AND (b[1] = "D") AND (b[2] = "0") AND
         (b[3] = "0") AND (b[4] = "1") THEN ok := TRUE
    ENDIF
  ENDIF
  Close(fh)
ENDPROC ok

-> enter/leave the image mode. ppath keeps the real directory under
-> the image the whole time, exactly like the archive mode does.
PROC enteriso(p, fpath)
  DEF fh, rt, rsz
  IF (fh := Open(fpath, OLDFILE)) = NIL
    showmsg('cannot open the image file')
    RETURN
  ENDIF
  IF isopvd(fh, {rt}, {rsz}) = FALSE
    Close(fh)
    showmsg('not an ISO 9660 image (or an unsupported one)')
    RETURN
  ENDIF
  Close(fh)
  StrCopy(isopath[p], fpath)
  SetStr(isosub[p], 0)
  isoroot[p] := rt
  isorootsz[p] := rsz
  esel[p] := 0
  etop[p] := 0
  readpane(p)
  drawpaths()
  drawpane(p)
ENDPROC

PROC leaveiso(p)
  SetStr(isopath[p], 0)
  SetStr(isosub[p], 0)
  isoroot[p] := 0
  isorootsz[p] := 0
ENDPROC

-> list the pane's current directory inside the image. Same MAXENT cap
-> as a real directory listing (addentry stops quietly at 500).
PROC readisodir(p)
  DEF fh, ext, sz, isdir, b, s[1]:ARRAY OF isoscan, sc:PTR TO isoscan
  clearmarks(p)
  ecount[p] := 0
  efail[p] := FALSE
  IF (fh := Open(isopath[p], OLDFILE)) = NIL
    efail[p] := TRUE
    RETURN
  ENDIF
  IF isofind(fh, isoroot[p], isorootsz[p], isosub[p],
             {ext}, {sz}, {isdir}) = FALSE
    Close(fh)
    efail[p] := TRUE
    RETURN
  ENDIF
  b := p * MAXENT
  sc := s
  isodbegin(sc, fh, ext, sz)
  WHILE isodnext(sc)
    isdir := ecount[p]    -> reuse: slot this entry should land in
    -> dirs list with size 0 so the size column shows <DIR>; their
    -> extent size is re-resolved with isofind when actually needed
    addentry(p, sc.rname, IF sc.rdir THEN 1 ELSE 0,
             IF sc.rdir THEN 0 ELSE sc.rsize, 0)
    IF ecount[p] > isdir
      eext[b + isdir] := sc.rext    -> only when addentry took it (cap)
    ENDIF
  ENDWHILE
  IF sc.err THEN efail[p] := TRUE
  isodend(sc)
  Close(fh)
  sortpane(p)
  IF esel[p] >= ecount[p] THEN esel[p] := ecount[p] - 1
  IF esel[p] < 0 THEN esel[p] := 0
  IF etop[p] > esel[p] THEN etop[p] := esel[p]
ENDPROC

-> pull `size` bytes at `ext` out of the open image into dst. tick =
-> feed the progress bar and honour Esc (the copyfile discipline: a
-> cancelled or failed target is deleted, never left partial).
PROC isoextract(fh, ext, size, dst, tick)
  DEF fo, left, n, ok=TRUE
  IF (fo := Open(dst, NEWFILE)) = NIL THEN RETURN FALSE
  IF Seek(fh, Shl(ext, 11), OFFSET_BEGINNING) < 0 THEN ok := FALSE
  left := size
  WHILE (left > 0) AND ok
    IF tick
      IF checkabort() THEN ok := FALSE
    ENDIF
    IF ok
      n := IF left > cbufsz THEN cbufsz ELSE left
      IF Read(fh, copybuf, n) <> n
        ok := FALSE
      ELSEIF Write(fo, copybuf, n) <> n
        ok := FALSE
      ELSE
        left := left - n
        IF tick THEN progadd(n)
      ENDIF
    ENDIF
  ENDWHILE
  Close(fo)
  IF ok = FALSE THEN DeleteFile(dst)
ENDPROC ok

-> subdirectories collected per directory while walking (heap lists,
-> recursion keeps a small frame like copytree does)
CONST ISOSD=192

-> total bytes of every file below a directory extent (pre-scan
-> denominator for the smooth bar, and the = key inside an image).
-> A directory with more than ISOSD subdirectories only understates
-> the bar's denominator - the copy itself never drops anything.
PROC isosum(fh, ext, sz, depth)
  DEF s[1]:ARRAY OF isoscan, sc:PTR TO isoscan, n=0,
      dext:PTR TO LONG, dsz:PTR TO LONG, nd=0, k
  IF depth > 20 THEN RETURN 0
  dext := New(ISOSD * 4)
  dsz := New(ISOSD * 4)
  IF (dext = NIL) OR (dsz = NIL)
    IF dext THEN Dispose(dext)
    IF dsz THEN Dispose(dsz)
    RETURN 0
  ENDIF
  sc := s
  isodbegin(sc, fh, ext, sz)
  WHILE isodnext(sc)
    IF sc.rdir
      IF nd < ISOSD
        dext[nd] := sc.rext
        dsz[nd] := sc.rsize
        nd++
      ENDIF
    ELSE
      n := n + sc.rsize
    ENDIF
  ENDWHILE
  isodend(sc)
  FOR k := 0 TO nd - 1
    n := n + isosum(fh, dext[k], dsz[k], depth + 1)
  ENDFOR
  Dispose(dext)
  Dispose(dsz)
ENDPROC n

-> ---- ADF disk images: REAL mounts via 3.2's DAControl -------------
-> (daprobe round 1, 30.7.26). Never a parser: the real filesystem
-> does the thinking, every verb works on the mounted volume, and
-> writes land in the .adf file (host-verified). The probe's lessons
-> live here: DAControl will YANK a disk from under live locks, so
-> the in-use discipline is OURS; eject right after create/write can
-> fail transiently (validator) - retry once; an unformatted image
-> mounts but requester-storms - refuse NDOS before mounting; and
-> DAControl output is never parsed beyond pass/fail (DA_LASTDEVICE
-> via SETENV carries the device name instead).

PROC adfext(name:PTR TO CHAR)
  DEF l
  l := StrLen(name)
  IF l < 5 THEN RETURN FALSE
  IF (name[l - 4] <> ".") THEN RETURN FALSE
  IF (name[l - 3] <> "a") AND (name[l - 3] <> "A") THEN RETURN FALSE
  IF (name[l - 2] <> "d") AND (name[l - 2] <> "D") THEN RETURN FALSE
  IF (name[l - 1] <> "f") AND (name[l - 1] <> "F") THEN RETURN FALSE
ENDPROC TRUE

-> 0 = no DAControl, 1 = ready
PROC dacheck()
  IF pathtype('C:DAControl') <> 1
    showmsg('ADF mounting needs AmigaOS 3.2 (C:DAControl + trackfile.device)')
    RETURN FALSE
  ENDIF
ENDPROC TRUE

-> the mount table: slot by device name / by image file / first free
PROC damfind(dev)
  DEF k
  FOR k := 0 TO DAMAX - 1
    IF EstrLen(damdev[k]) > 0
      IF nccmp(damdev[k], dev) = 0 THEN RETURN k
    ENDIF
  ENDFOR
ENDPROC -1

PROC damfindfile(path)
  DEF k
  FOR k := 0 TO DAMAX - 1
    IF EstrLen(damdev[k]) > 0
      IF nccmp(damfile[k], path) = 0 THEN RETURN k
    ENDIF
  ENDFOR
ENDPROC -1

PROC damfree()
  DEF k
  FOR k := 0 TO DAMAX - 1
    IF EstrLen(damdev[k]) = 0 THEN RETURN k
  ENDFOR
ENDPROC -1

-> the pane's real path sits inside a disk image WE mounted (any
-> depth): slot index, or -1
PROC damunder(p)
  DEF k
  FOR k := 0 TO DAMAX - 1
    IF EstrLen(damdev[k]) > 0
      IF ncprefix(ppath[p], damdev[k], EstrLen(damdev[k])) THEN RETURN k
    ENDIF
  ENDFOR
ENDPROC -1

-> eject + stop one device, the probe-proven way: SAFEEJECT asks the
-> filesystem to flush and let go; a transient "in use" right after
-> writes gets one retry after a beat. TRUE = the unit is gone.
PROC daeject(dev)
  DEF cmd[200]:STRING, res
  StringF(cmd, 'C:DAControl EJECT SAFEEJECT=YES TIMEOUT=5 STOP UNIT=\s QUIET',
          dev)
  res := runcapture(NIL, cmd, 'T:CFile-out')
  IF res <> 0
    Delay(100)    -> the validator may still be settling
    res := runcapture(NIL, cmd, 'T:CFile-out')
  ENDIF
  DeleteFile('T:CFile-out')
ENDPROC res = 0

-> quit: best-effort unmount of everything WE mounted. First, any
-> pane still sitting inside one of those volumes is pointed back at
-> the directory holding its .adf - otherwise SAVEDIRS would remember
-> a DAn: path and the next start would beg "insert DA3: in any
-> drive" for a volume that no longer exists (his find, 30.7.26).
PROC daunmountall()
  DEF k, p
  FOR p := 0 TO 1
    k := damunder(p)
    IF k >= 0 THEN StrCopy(ppath[p], damback[k])
  ENDFOR
  FOR k := 0 TO DAMAX - 1
    IF EstrLen(damdev[k]) > 0
      daeject(damdev[k])
      SetStr(damdev[k], 0)
    ENDIF
  ENDFOR
ENDPROC

-> Enter on a .adf: mount it writable and jump the pane inside. The
-> image already mounted by us = just jump (mounting the same file
-> twice is the crash DAControl's checksum option exists to prevent).
PROC enteradf(p, fpath)
  DEF k, fh, b[8]:ARRAY OF CHAR, n, cmd[CPATHLEN+80]:STRING,
      res, dev[20]:STRING
  k := damfindfile(fpath)
  IF k >= 0
    StrCopy(ppath[p], damdev[k])
    esel[p] := 0
    etop[p] := 0
    readpane(p)
    drawpaths()
    drawpane(p)
    RETURN
  ENDIF
  IF dacheck() = FALSE THEN RETURN
  -> NDOS gate: an image whose bootblock does not open with "DOS"
  -> would mount and then requester-storm on every access
  n := 0
  IF (fh := Open(fpath, OLDFILE))
    n := Read(fh, b, 4)
    Close(fh)
  ENDIF
  IF (n < 4) OR (b[0] <> "D") OR (b[1] <> "O") OR (b[2] <> "S")
    showmsg('not a DOS disk image (a game/NDOS disk cannot be browsed)')
    RETURN
  ENDIF
  IF (k := damfree()) = -1
    showmsg('too many mounted images - unmount one first (Left at its root)')
    RETURN
  ENDIF
  -> pin the device OURSELVES (b24). b23 read DA_LASTDEVICE back and
  -> a stale value recorded the WRONG unit - the image then could
  -> never be unmounted again (his find). Now: try each DAn: not in
  -> our table until one takes; DAControl reuses stopped units, so
  -> the first attempt normally answers. The table entry is CERTAIN.
  res := -1
  n := 0
  WHILE (n < DAMAX) AND (res <> 0)
    StringF(dev, 'DA\d:', n)
    IF damfind(dev) = -1    -> not one of ours already
      StringF(cmd, 'C:DAControl LOAD "\s" DEVICE=\s WRITEPROTECTED=NO QUIET',
              fpath, dev)
      res := runcapture(NIL, cmd, 'T:CFile-out')
    ENDIF
    IF res <> 0 THEN n++
  ENDWHILE
  DeleteFile('T:CFile-out')
  IF res <> 0
    showmsg('could not mount the image (already mounted, or units busy)')
    RETURN
  ENDIF
  StrCopy(damdev[k], dev)
  StrCopy(damfile[k], fpath)
  StrCopy(damback[k], ppath[p])
  StrCopy(damname[k], FilePart(fpath))
  StrCopy(ppath[p], dev)
  esel[p] := 0
  etop[p] := 0
  readpane(p)
  drawpaths()
  drawpane(p)
ENDPROC

-> n with a name ending .adf: create a formatted blank image (FFS,
-> 880K, labeled after the file's stem) - DAControl CREATE formats
-> AND mounts it writable in one stroke, so it is immediately usable
PROC docreateadf(p, dpath, tname)
  DEF lbl[110]:STRING, cmd[CPATHLEN+140]:STRING, res=-1, k, n=0,
      dev[20]:STRING
  IF dacheck() = FALSE THEN RETURN
  IF pathtype(dpath) > 0
    showmsg('that name already exists')
    RETURN
  ENDIF
  -> CREATE mounts what it makes, so it needs a table slot up front -
  -> an untracked mount is a file that can never be deleted (b24)
  IF (k := damfree()) = -1
    showmsg('too many mounted images - unmount one first (Left at its root)')
    RETURN
  ENDIF
  StrCopy(lbl, tname)
  SetStr(lbl, EstrLen(lbl) - 4)    -> the stem names the volume
  -> pinned-device ladder, same reasoning as enteradf. A failed try
  -> may leave the created file behind (CREATE makes the file, THEN
  -> inserts it) - clear it so the next try is not "already exists".
  WHILE (n < DAMAX) AND (res <> 0)
    StringF(dev, 'DA\d:', n)
    IF damfind(dev) = -1
      StringF(cmd, 'C:DAControl CREATE LABEL="\s" FILESYSTEMTYPE=FFS DISKTYPE=DD DEVICE=\s QUIET "\s"', lbl, dev, dpath)
      res := runcapture(NIL, cmd, 'T:CFile-out')
      IF res <> 0
        IF pathtype(dpath) = 1 THEN DeleteFile(dpath)
      ENDIF
    ENDIF
    IF res <> 0 THEN n++
  ENDWHILE
  DeleteFile('T:CFile-out')
  IF res <> 0
    faultmsg('could not create the image')
    RETURN
  ENDIF
  StrCopy(damdev[k], dev)
  StrCopy(damfile[k], dpath)
  StrCopy(damback[k], ppath[p])
  StrCopy(damname[k], tname)
  StrCopy(prevname, tname)
  refreshpane(p, TRUE)
  showmsg('image created and mounted - Enter goes inside')
ENDPROC

-> throw away a pane's uncommitted archive edits: drop the staging tree
-> and reset every flag to CLEAN, so the arccommit that leavearchive runs
-> next finds nothing to write and the archive on disk is left untouched.
PROC arcdiscard(p)
  DEF st:PTR TO LONG, k, stageroot[CPATHLEN]:STRING
  arcstage(p, stageroot)
  arcwipe(stageroot)
  IF amst[p] AND (amcnt[p] > 0)
    st := amst[p]
    FOR k := 0 TO amcnt[p] - 1
      st[k] := MST_CLEAN
    ENDFOR
  ENDIF
ENDPROC

PROC addentry(p, name, isdir, size, date)
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
  edate[(p * MAXENT) + i] := date
  eext[(p * MAXENT) + i] := 0    -> ISO listings overwrite this after
  ecount[p] := i + 1
ENDPROC

-> Every entry is really six parallel fields - name pointer, is-dir, size,
-> date, mark and extent - that must move together. These three helpers are
-> the ONE place that enumerates them, so a listing that reorders or snapshots
-> entries can never again keep five in step and forget the sixth (the /
-> filter's date column once was). Add a field here and every mover follows.

-> swap two entries in place within the global arrays (b = p * MAXENT)
PROC swapentry(b, i, j)
  DEF t
  t := enames[b + i]
  enames[b + i] := enames[b + j]
  enames[b + j] := t
  t := edirs[b + i]
  edirs[b + i] := edirs[b + j]
  edirs[b + j] := t
  t := esize[b + i]
  esize[b + i] := esize[b + j]
  esize[b + j] := t
  t := edate[b + i]
  edate[b + i] := edate[b + j]
  edate[b + j] := t
  t := emark[b + i]
  emark[b + i] := emark[b + j]
  emark[b + j] := t
  t := eext[b + i]
  eext[b + i] := eext[b + j]
  eext[b + j] := t
ENDPROC

-> copy the global entry at b+gi out to the snapshot arrays at index si
PROC snapentry(si, sn:PTR TO LONG, sd:PTR TO CHAR, ss:PTR TO LONG,
               sdt:PTR TO LONG, sm:PTR TO CHAR, sx:PTR TO LONG, b, gi)
  sn[si]  := enames[b + gi]
  sd[si]  := edirs[b + gi]
  ss[si]  := esize[b + gi]
  sdt[si] := edate[b + gi]
  sm[si]  := emark[b + gi]
  sx[si]  := eext[b + gi]
ENDPROC

-> copy the snapshot entry at si back into the global slot b+gi
PROC unsnapentry(si, sn:PTR TO LONG, sd:PTR TO CHAR, ss:PTR TO LONG,
                 sdt:PTR TO LONG, sm:PTR TO CHAR, sx:PTR TO LONG, b, gi)
  enames[b + gi] := sn[si]
  edirs[b + gi]  := sd[si]
  esize[b + gi]  := ss[si]
  edate[b + gi]  := sdt[si]
  emark[b + gi]  := sm[si]
  eext[b + gi]   := sx[si]
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

-> byte total of the marked set (directories count as 0 - their real
-> size needs a treestat walk, which the border row must not do)
PROC markbytes(p)
  DEF i, b, n=0
  b := p * MAXENT
  IF ecount[p] > 0
    FOR i := 0 TO ecount[p] - 1
      IF emark[b + i] THEN n := n + esize[b + i]
    ENDFOR
  ENDIF
ENDPROC n

-> bytes as a short human string, at most 5 characters so it fits a
-> narrow column: plain under 1K, then K/M/G with one decimal while
-> the whole part is a single digit ("937", "9.1K", "123K", "1.4M").
-> Integer math throughout - the remainder is scaled down before the
-> multiply so an M or G value cannot overflow a LONG.
PROC fmtbytes(dst, n)
  DEF unit, whole, rem, frac, suf
  IF n < 1024
    StringF(dst, '\d', n)
    RETURN
  ENDIF
  IF n < 1048576
    unit := 1024
    suf := 'K'
  ELSEIF n < 1073741824
    unit := 1048576
    suf := 'M'
  ELSE
    unit := 1073741824
    suf := 'G'
  ENDIF
  -> Div/Mul throughout: these are byte counts, and E's / and * are
  -> the 16-bit operators
  whole := Div(n, unit)
  rem := n - Mul(whole, unit)
  IF whole < 10
    IF unit = 1024
      frac := Div(Mul(rem, 10), unit)
    ELSE
      -> rem can be just under 1G, so rem * 10 would wrap: scale it
      -> and the unit down by 1K first, which still leaves 3 digits
      -> of headroom under the one decimal we print
      frac := Div(Mul(Div(rem, 1024), 10), Div(unit, 1024))
    ENDIF
    IF frac > 9 THEN frac := 9
    StringF(dst, '\d.\d\s', whole, frac, suf)
  ELSE
    StringF(dst, '\d\s', whole, suf)
  ENDIF
ENDPROC

-> compact day+month for the size column when sorting by date: DateToStr
-> gives "DD-Mon-YY"; we drop the dashes, spaces and year to "DDMon" (max
-> 5 chars, same slot as a size). datekey = days*1440 + minute.
PROC datestr(datekey, dst)
  DEF dt:datetime, dbuf[20]:ARRAY OF CHAR, days, i=0, j=0, dash=0
  StrCopy(dst, '')
  days := Div(datekey, 1440)
  dt.stamp.days := days
  dt.stamp.minute := datekey - Mul(days, 1440)
  dt.stamp.tick := 0
  dt.format := FORMAT_DOS
  dt.flags := 0
  dt.strday := NIL
  dt.strdate := dbuf
  dt.strtime := NIL
  IF DateToStr(dt)
    WHILE (dbuf[i] <> 0) AND (dash < 2) AND (j < 8)
      IF dbuf[i] = "-"
        dash++
      ELSEIF dbuf[i] <> 32
        dst[j] := dbuf[i]
        j++
      ENDIF
      i++
    ENDWHILE
    SetStr(dst, j)
  ENDIF
ENDPROC

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

-> TRUE if `needle` occurs anywhere in `hay`, case-insensitively (the
-> empty needle matches everything). Drives the / live filter.
PROC nchas(hay:PTR TO CHAR, needle:PTR TO CHAR)
  DEF hl, nl, i, j, c1, c2, ok
  nl := StrLen(needle)
  IF nl = 0 THEN RETURN TRUE
  hl := StrLen(hay)
  IF nl > hl THEN RETURN FALSE
  FOR i := 0 TO hl - nl
    j := 0
    ok := TRUE
    WHILE ok AND (j < nl)
      c1 := hay[i + j]
      c2 := needle[j]
      IF (c1 >= "a") AND (c1 <= "z") THEN c1 := c1 - 32
      IF (c2 >= "a") AND (c2 <= "z") THEN c2 := c2 - 32
      IF c1 <> c2 THEN ok := FALSE ELSE j++
    ENDWHILE
    IF ok THEN RETURN TRUE
  ENDFOR
ENDPROC FALSE

-> TRUE if `name` ends in ".info" (case-insensitive) - a Workbench icon
PROC isinfo(name:PTR TO CHAR)
  DEF l
  l := StrLen(name)
  IF l < 5 THEN RETURN FALSE
ENDPROC nccmp(name + (l - 5), '.info') = 0

-> the base name behind an icon: "<name>.info" -> "<name>"
PROC infobase(name:PTR TO CHAR, dst)
  StrCopy(dst, name, StrLen(name) - 5)
ENDPROC

-> build the icon sidecar path for `name` in `dir` into dst; TRUE if that
-> ".info" file actually exists (so an op only bothers when there's one)
PROC sidecarof(dir, name, dst)
  DEF nm[120]:STRING
  StrCopy(nm, name)
  StrAdd(nm, '.info')
  buildfull(dst, dir, nm)
ENDPROC pathtype(dst) = 1

-> TRUE if pane p has a MARKED entry named nm
PROC nameismarked(p, nm)
  DEF bb, i
  bb := p * MAXENT
  IF ecount[p] > 0
    FOR i := 0 TO ecount[p] - 1
      -> C3: nested, not AND - E's eager AND ran nccmp for every
      -> unmarked entry, which made icon-heavy bulk ops quadratic
      IF emark[bb + i]
        IF nccmp(enames[bb + i], nm) = 0 THEN RETURN TRUE
      ENDIF
    ENDFOR
  ENDIF
ENDPROC FALSE

-> TRUE if the entry at full index `idx` is an icon whose base file is
-> ALSO marked: it travels as that file's sidecar, so a bulk op skips it
-> here to avoid touching it twice. (Only meaningful with marks.)
PROC infodup(p, idx)
  DEF base[120]:STRING
  IF icons = FALSE THEN RETURN FALSE
  IF isinfo(enames[idx]) = FALSE THEN RETURN FALSE
  infobase(enames[idx], base)
ENDPROC nameismarked(p, base)

-> C3: "marked, and not a sidecar-duplicate" with the guards NESTED -
-> at the bulk-loop call sites the eager AND ran infodup (and its
-> pane scan) for every UNMARKED entry too. Unmarked now costs one
-> array read.
PROC markednodup(p, idx)
  IF emark[idx] = 0 THEN RETURN FALSE
  IF infodup(p, idx) THEN RETURN FALSE
ENDPROC TRUE

-> sort order: directories first, then files. Within a tier the key is
-> the chosen mode - name (A-Z), size (largest first) or date (newest
-> first) - reversed by sortrev. The dir-before-file tier never reverses,
-> so folders stay on top either way. Returns TRUE if i sorts before j.
PROC entbefore(p, i, j)
  DEF b, di, dj, c=0
  b := p * MAXENT
  di := edirs[b + i]
  dj := edirs[b + j]
  -> higher tier sorts first: directories/volumes (255) over
  -> assigns (1) over files (0)
  IF di > dj THEN RETURN TRUE
  IF di < dj THEN RETURN FALSE
  -> same tier: order by mode (c < 0 means i comes first)
  IF sortmode = 1          -> size, largest first
    IF esize[b + i] > esize[b + j] THEN c := -1
    IF esize[b + i] < esize[b + j] THEN c := 1
  ELSEIF sortmode = 2      -> date, newest first
    IF edate[b + i] > edate[b + j] THEN c := -1
    IF edate[b + i] < edate[b + j] THEN c := 1
  ENDIF
  IF c = 0 THEN c := nccmp(enames[b + i], enames[b + j])   -> name / tiebreak
  IF sortrev THEN c := -c
ENDPROC c < 0

-> C1 (0.4.1 stage b4): Shell sort, Knuth gaps. The selection sort
-> paid n*n/2 entbefore CALLS - 125k for a full pane, ~1M char-fold
-> iterations, seconds at stock CPU on every entry into a big
-> drawer. Shell's compare count is ~n^1.3 with the SAME entbefore
-> and the same all-five-fields swapentry (which carries size, date
-> and any live mark with the name). FFS delivers near-sorted names,
-> which the gap ladder exploits and selection cannot. Harness-
-> proven against the old sort (b4test.e): identical order on
-> unique keys, tier + sortedness invariants on ties.
PROC sortpane(p)
  DEF i, j, b, n, gap, done
  n := ecount[p]
  IF n < 2 THEN RETURN
  b := p * MAXENT
  gap := 1
  WHILE (Mul(gap, 3) + 1) < n
    gap := Mul(gap, 3) + 1
  ENDWHILE
  WHILE gap >= 1
    FOR i := gap TO n - 1
      j := i
      done := FALSE
      WHILE (j >= gap) AND (done = FALSE)
        IF entbefore(p, j, j - gap)
          swapentry(b, j, j - gap)
          j := j - gap
        ELSE
          done := TRUE
        ENDIF
      ENDWHILE
    ENDFOR
    gap := Div(gap - 1, 3)
  ENDWHILE
ENDPROC

-> run a command with its output captured to a file, quietly - no
-> console render, no window. dir (or NIL) is the CWD to run it in.
-> Returns the DOS return code, or -1 if the command could not start.
PROC runcapture(dir, cmd, outfile)
  DEF dlock=NIL, old=NIL, res=-1, fout=NIL, fin=NIL
  IF dir
    dlock := Lock(dir, SHARED_LOCK)
    IF dlock THEN old := CurrentDir(dlock)
  ENDIF
  fin := Open('NIL:', OLDFILE)
  fout := Open(outfile, NEWFILE)
  IF fout
    res := SystemTagList(cmd,
      [SYS_INPUT,  fin,
       SYS_OUTPUT, fout,
       SYS_ASYNCH, FALSE,
       TAG_DONE,   NIL])
    Close(fout)
  ENDIF
  IF fin THEN Close(fin)
  IF dlock
    CurrentDir(old)
    UnLock(dlock)
  ENDIF
ENDPROC res

-> one member into the pane's archive cache
-> add one member to the cache; returns its slot index, or -1 if the cache
-> is full or the name could not be allocated. Callers that then set a
-> status flag must use the returned slot, not amcnt-1 (which on a failed
-> add still points at the previous member).
PROC arcadd(p, name, size)
  DEF a:PTR TO LONG, z:PTR TO LONG, k, s
  k := amcnt[p]
  IF k >= MAXMEM THEN RETURN -1
  a := amem[p]
  z := amsz[p]
  IF (s := String(EstrLen(name) + 1)) = NIL THEN RETURN -1
  StrCopy(s, name)
  a[k] := s
  z[k] := size
  amcnt[p] := k + 1
ENDPROC k

-> a listing separator row: only dashes/equals and spaces, and enough
-> of them to be the real rule, not a stray line of text
PROC issepline(s:PTR TO CHAR)
  DEF i=0, c, ndash=0
  WHILE c := s[i]
    IF (c = "-") OR (c = "=")
      ndash++
    ELSEIF c <> 32
      RETURN FALSE
    ENDIF
    i++
  ENDWHILE
ENDPROC ndash >= 6

-> how many space-delimited fields sit before the Name column on the
-> header row, or -1 if this is not the header. LhA's short list is
->   Original Packed Ratio Date Time Name
-> so five fields precede Name. We count by word rather than by column
-> because LhA's Ratio field is variable width ("40.5%" is five chars,
-> "100.0%" six - %2ld overflows for stored files), which shifts the
-> Name column by one between rows. None of the five fields hold a
-> space, and the name (which can) is everything past them.
PROC hdrnamefields(s:PTR TO CHAR)
  DEF i=0, c, inword=FALSE, nwords=0, namei=-1
  WHILE c := s[i]
    IF c = 32
      inword := FALSE
    ELSE
      IF inword = FALSE
        inword := TRUE
        IF ((c = "N") OR (c = "n")) AND
           ((s[i+1] = "A") OR (s[i+1] = "a")) AND
           ((s[i+2] = "M") OR (s[i+2] = "m")) AND
           ((s[i+3] = "E") OR (s[i+3] = "e")) AND
           ((s[i+4] = 0) OR (s[i+4] = 32))
          namei := nwords    -> word index of Name = fields before it
        ENDIF
        nwords++
      ENDIF
    ENDIF
    i++
  ENDWHILE
ENDPROC namei

-> the member name from a data row: skip `nfields` space-delimited
-> tokens (none contain a space), then take the rest, right-trimmed.
-> Internal spaces in the name survive; the leading ratio-width drift
-> no longer matters.
PROC namefield(dst, line:PTR TO CHAR, nfields)
  DEF i=0, f, e
  FOR f := 1 TO nfields
    WHILE line[i] = 32
      i++
    ENDWHILE
    WHILE (line[i] <> 0) AND (line[i] <> 32)
      i++
    ENDWHILE
  ENDFOR
  WHILE line[i] = 32
    i++
  ENDWHILE
  MidStr(dst, line, i, ALL)
  e := EstrLen(dst)
  WHILE (e > 0) AND ((dst[e-1] = 32) OR (dst[e-1] = 9))
    e--
  ENDWHILE
  SetStr(dst, e)
ENDPROC

-> ---- lzx listing parser (LZX 1.21 `lzx l`). Its columns are fixed-width
-> but the Ratio renders "100 %" (a space) or "00.0%", so a token count
-> like the lha parser breaks. Instead: a member row is any row with an
-> HH:MM:SS time field (colons can't be in an Amiga filename), the name is
-> everything after it, and the size is the first integer (Original). This
-> also skips the merged-group summary row (no time) and the footer total
-> (past the closing rule). Verified on real `lzx l` captures. --------------

PROC isdig(c)
ENDPROC (c >= "0") AND (c <= "9")

-> index just past an HH:MM:SS time field in s, or -1 if none. Reads a few
-> bytes past a short line, which is safe - the caller's line buffer is a
-> fixed String, NUL-terminated and padded.
PROC lzxnamestart(s:PTR TO CHAR)
  DEF i=0
  WHILE s[i]
    IF isdig(s[i]) AND isdig(s[i+1]) AND (s[i+2] = ":") AND
       isdig(s[i+3]) AND isdig(s[i+4]) AND (s[i+5] = ":") AND
       isdig(s[i+6]) AND isdig(s[i+7])
      RETURN i + 8
    ENDIF
    i++
  ENDWHILE
ENDPROC -1

-> the member name of an `lzx l` data row into dst (spaces trimmed both
-> ends); FALSE if the row carries no time field (header/summary/blank)
PROC lzxname(dst, line:PTR TO CHAR)
  DEF ns, i, e
  ns := lzxnamestart(line)
  IF ns < 0 THEN RETURN FALSE
  i := ns
  WHILE line[i] = 32
    i++
  ENDWHILE
  MidStr(dst, line, i, ALL)
  e := EstrLen(dst)
  WHILE (e > 0) AND ((dst[e-1] = 32) OR (dst[e-1] = 9))
    e--
  ENDWHILE
  SetStr(dst, e)
ENDPROC EstrLen(dst) > 0

-> TRUE if pane p is inside an lzx archive (vs lha) - the archive write verbs
-> branch on it (lzx commands, immediate; lha keeps its deferred/direct paths)
PROC islzx(p)
ENDPROC inarchive(p) AND (arcfmt[p] = TY_LZX)

-> parse `lha v` output into pane p's cache: find the header, take its field
-> count before Name, then read data rows (name = everything past those
-> space-delimited fields) until the closing rule.
PROC parselha(p, buf:PTR TO CHAR, n)
  DEF i=0, j, l, st=0, line[340]:STRING, nfld=-1, dcol, sz, nm[300]:STRING
  WHILE i < n
    j := i
    WHILE (j < n) AND (buf[j] <> 10)
      j++
    ENDWHILE
    l := j - i
    IF l > 338 THEN l := 338
    StrCopy(line, IF l > 0 THEN buf + i ELSE '', l)
    i := j + 1
    IF st = 0
      dcol := hdrnamefields(line)
      IF dcol >= 0
        nfld := dcol
        st := 1
      ENDIF
    ELSEIF st = 1
      -> the rule under the header comes before any member (skipped); the
      -> next rule (after members exist) closes the listing.
      IF issepline(line)
        IF amcnt[p] > 0 THEN st := 2
      ELSEIF EstrLen(line) > 0
        namefield(nm, line, nfld)
        IF EstrLen(nm) > 0
          sz := Val(line)    -> first number on the row = original size
          arcadd(p, nm, sz)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

-> parse `lzx l` output into pane p's cache: the first rule opens the member
-> block, the next rule closes it; a member row is one with a time field
-> (lzxname), size = the first integer. Skips the merged-group summary (no
-> time) and the footer total (past the closing rule).
PROC parselzx(p, buf:PTR TO CHAR, n)
  DEF i=0, j, l, st=0, line[340]:STRING, sz, nm[300]:STRING
  WHILE i < n
    j := i
    WHILE (j < n) AND (buf[j] <> 10)
      j++
    ENDWHILE
    l := j - i
    IF l > 338 THEN l := 338
    StrCopy(line, IF l > 0 THEN buf + i ELSE '', l)
    i := j + 1
    IF issepline(line)
      IF st = 0
        st := 1
      ELSEIF st = 1
        st := 2
      ENDIF
    ELSEIF st = 1
      IF lzxname(nm, line)
        sz := Val(line)
        arcadd(p, nm, sz)
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

PROC loadarchive(p, arcfile)
  DEF cmd[340]:STRING, res, buf=NIL:PTR TO CHAR, n, fh
  -> a rebuild from disk would wipe the deferred flags, so any pending
  -> edits are committed first. Only fires on a rebuild WHILE inside the
  -> archive (an immediate write verb in ONEXIT mode); on entry the pane
  -> is not yet inarchive, and nothing is pending.
  IF inarchive(p) AND arcwrite THEN arccommit(p)
  freearccache(p)
  amem[p] := New(MAXMEM * 4)
  amsz[p] := New(MAXMEM * 4)
  amst[p] := New(MAXMEM * 4)    -> New() clears, so every member is CLEAN
  IF (amem[p] = NIL) OR (amsz[p] = NIL) OR (amst[p] = NIL)
    freearccache(p)
    RETURN FALSE
  ENDIF
  amcnt[p] := 0
  -> lzx: terse `l` (Original/Packed/Ratio/Date/Time/Name, name right after
  -> the time). lha: `v` (verbose) - LhA's terse `l` is a flag layout that
  -> hides the path.
  IF arcfmt[p] = TY_LZX
    StringF(cmd, 'lzx l "\s"', arcfile)
  ELSE
    StringF(cmd, 'lha v "\s"', arcfile)
  ENDIF
  res := runcapture(NIL, cmd, 'T:CFile-arc')
  IF res = -1
    freearccache(p)
    RETURN FALSE
  ENDIF
  -> X4: size the capture to the file (slurpfh) - the old fixed 128KB
  -> read silently truncated a long `lha v` of ~1500 long-pathed members
  IF (fh := Open('T:CFile-arc', OLDFILE))
    buf := slurpfh(fh, {n})
    Close(fh)
  ENDIF
  IF buf = NIL
    DeleteFile('T:CFile-arc')
    freearccache(p)
    RETURN FALSE
  ENDIF
  IF n < 0 THEN n := 0
  IF arcfmt[p] = TY_LZX THEN parselzx(p, buf, n) ELSE parselha(p, buf, n)
  Dispose(buf)
  DeleteFile('T:CFile-arc')
ENDPROC amcnt[p] > 0

-> 0.4.1 I3 (campaign stage b3): batched directory reads. ExAll
-> delivers dozens of entries per packet round trip where ExNext
-> costs one trip per entry - the classic 3-10x real-media win. One
-> iterator serves every walker; its state lives in the CALLER's
-> frame (DEF s[1]:ARRAY OF eascan) so recursive walkers can nest
-> scans. Fallback: a handler that rejects the FIRST ExAll call
-> (odd handlers, netfs - and vamos) is served by Examine/ExNext
-> through the SAME iterator, each entry shaped into one reusable
-> exalldata so callers see a single form. ED_COMMENT level: the
-> deepest field any of the family's views reads. E note: no
-> short-circuit ANDs in any loop body - readdir's own old rule.
OBJECT eascan
  lock:LONG                     -> the caller's lock, never freed here
  buf:PTR TO CHAR               -> New'd ExAll buffer (EABUFSZ)
  ctl:PTR TO exallcontrol       -> AllocDosObject(DOS_EXALLCONTROL)
  cur:PTR TO exalldata          -> next unserved entry of the batch
  more:LONG                     -> ExAll promised another batch
  first:LONG                    -> no batch fetched yet
  fb:LONG                       -> fallback (Examine/ExNext) mode
  err:LONG                      -> scan died mid-way; caller reports
  fib:PTR TO fileinfoblock      -> fallback only
  fbed:PTR TO exalldata         -> fallback only: the reusable entry
ENDOBJECT

PROC easbegin(s:PTR TO eascan, lock)
  s.lock := lock
  s.buf := New(EABUFSZ)
  s.ctl := NIL
  s.cur := NIL
  s.more := 0
  s.first := TRUE
  s.fb := FALSE
  s.err := FALSE
  s.fib := NIL
  s.fbed := NIL
  IF s.buf THEN s.ctl := AllocDosObject(DOS_EXALLCONTROL, NIL)
  IF s.ctl = NIL THEN easfallback(s)
ENDPROC

-> switch to Examine/ExNext - legal only while NO ExAll entry has
-> been served yet (easbegin, or the first ExAll call failing)
PROC easfallback(s:PTR TO eascan)
  s.fb := TRUE
  IF s.fib = NIL THEN s.fib := AllocDosObject(DOS_FIB, NIL)
  IF s.fbed = NIL THEN s.fbed := New(SIZEOF exalldata)
  IF (s.fib = NIL) OR (s.fbed = NIL)
    s.err := TRUE
    RETURN
  ENDIF
  IF Examine(s.lock, s.fib) = FALSE THEN s.err := TRUE
ENDPROC

PROC easnextfb(s:PTR TO eascan)
  DEF ed:PTR TO exalldata, ds:PTR TO LONG
  IF ExNext(s.lock, s.fib) = FALSE
    IF IoErr() <> ERROR_NO_MORE_ENTRIES THEN s.err := TRUE
    RETURN NIL
  ENDIF
  ed := s.fbed
  ed.name := s.fib.filename
  ed.type := s.fib.direntrytype
  ed.size := s.fib.size
  ds := s.fib.datestamp
  ed.days := ds[0]
  ed.mins := ds[1]
  ed.ticks := ds[2]
  ed.comment := s.fib.comment
ENDPROC ed

-> the next directory entry, or NIL at the end (s.err tells a died
-> scan from a finished one). The entry is valid until the NEXT
-> easnext/easend call - consume before iterating.
PROC easnext(s:PTR TO eascan)
  DEF ed:PTR TO exalldata, r
  IF s.err THEN RETURN NIL
  IF s.fb THEN RETURN easnextfb(s)
  IF s.cur = NIL
    IF s.first = FALSE
      IF s.more = 0 THEN RETURN NIL   -> batches exhausted, clean end
    ENDIF
    r := ExAll(s.lock, s.buf, EABUFSZ, ED_COMMENT, s.ctl)
    s.more := r
    IF s.ctl.entries = 0
      IF r = 0
        IF IoErr() = ERROR_NO_MORE_ENTRIES THEN RETURN NIL
        IF s.first                    -> handler without ExAll: the
          easfallback(s)              -> whole scan restarts on the
          IF s.err THEN RETURN NIL    -> ExNext road (nothing was
          RETURN easnextfb(s)         -> served yet, no duplicates)
        ENDIF
        s.err := TRUE                 -> died mid-scan
        RETURN NIL
      ENDIF
      s.err := TRUE                   -> more promised, zero entries:
      RETURN NIL                      -> one entry outgrew 16KB -
    ENDIF                             -> impossible; refuse to spin
    s.first := FALSE
    s.cur := s.buf
  ENDIF
  ed := s.cur
  s.cur := ed.next
ENDPROC ed

PROC easend(s:PTR TO eascan)
  IF s.fb = FALSE
    IF s.more                         -> aborted mid-scan: drain the
      WHILE ExAll(s.lock, s.buf, EABUFSZ, ED_COMMENT, s.ctl)
      ENDWHILE                        -> handler's state (no V39
    ENDIF                             -> ExAllEnd dependency)
  ENDIF
  IF s.ctl THEN FreeDosObject(DOS_EXALLCONTROL, s.ctl)
  IF s.buf THEN Dispose(s.buf)
  IF s.fib THEN FreeDosObject(DOS_FIB, s.fib)
  IF s.fbed THEN Dispose(s.fbed)
  s.ctl := NIL
  s.buf := NIL
  s.fib := NIL
  s.fbed := NIL
ENDPROC

PROC readdir(p)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
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
      -> I3: the entry loop is BATCHED now (exallscan above); the
      -> dircheck Examine stays - ExAll answers nothing for a file.
      -> Date key as before: minutes since the epoch, ticks dropped.
      sc := s
      easbegin(sc, lock)
      ed := easnext(sc)
      WHILE ed
        addentry(p, ed.name, ed.type > 0, ed.size,
                 Mul(ed.days, 1440) + ed.mins)
        ed := easnext(sc)
      ENDWHILE
      IF sc.err THEN efail[p] := TRUE
      easend(sc)
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

-> case-insensitive: does m begin with the first n chars of pfx?
PROC ncprefix(m:PTR TO CHAR, pfx:PTR TO CHAR, n)
  DEF i, ca, cb
  FOR i := 0 TO n - 1
    ca := m[i]
    cb := pfx[i]
    IF ca = 0 THEN RETURN FALSE
    IF (ca >= "a") AND (ca <= "z") THEN ca := ca - 32
    IF (cb >= "a") AND (cb <= "z") THEN cb := cb - 32
    IF ca <> cb THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

-> has this subdirectory name already been added at this level?
PROC arcdirseen(p, name)
  DEF b, i
  b := p * MAXENT
  -> C5 (stage b4): BACKWARD - the member list names same-dir
  -> entries in runs, so the dir just added answers on the first
  -> probe instead of after a full forward scan per member
  FOR i := ecount[p] - 1 TO 0 STEP -1
    IF edirs[b + i]
      IF nccmp(enames[b + i], name) = 0 THEN RETURN TRUE
    ENDIF
  ENDFOR
ENDPROC FALSE

-> the pane's listing when it is inside an archive: the cached member
-> paths, filtered to arcsub and cut at the next "/" so each level
-> shows just its own files and the subdirectories one step down.
PROC readarcdir(p)
  DEF a:PTR TO LONG, z:PTR TO LONG, st:PTR TO LONG, k, m:PTR TO CHAR,
      pfx[CPATHLEN]:STRING,
      pl, rest:PTR TO CHAR, sl, comp[200]:STRING, e, keep
  ecount[p] := 0
  efail[p] := FALSE
  clearmarks(p)
  StrCopy(pfx, arcsub[p])
  pl := EstrLen(pfx)
  IF pl > 0
    IF pfx[pl-1] <> "/"    -> the prefix always ends in a slash
      StrAdd(pfx, '/')
      pl++
    ENDIF
  ENDIF
  a := amem[p]
  z := amsz[p]
  st := amst[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      -> a member queued for deletion is gone from the view already;
      -> the pane shows what the archive will be once committed.
      -> C5 (stage b4): NESTED - the eager AND/OR called ncprefix
      -> for every deleted member and for EVERY member at root level
      keep := FALSE
      IF st[k] <> MST_DEL
        IF pl = 0
          keep := TRUE
        ELSEIF ncprefix(m, pfx, pl)
          keep := TRUE
        ENDIF
      ENDIF
      IF keep
        rest := m + pl
        IF rest[0]    -> not the level's own directory entry
          sl := -1
          e := 0
          WHILE (rest[e] <> 0) AND (sl < 0)
            IF rest[e] = "/" THEN sl := e
            e++
          ENDWHILE
          IF sl < 0
            StrCopy(comp, rest)
            addentry(p, comp, FALSE, z[k], 0)    -> a file at this level
          ELSE
            StrCopy(comp, rest, sl)           -> a subdirectory name
            IF arcdirseen(p, comp) = FALSE THEN addentry(p, comp, 255, 0, 0)
          ENDIF
        ENDIF
      ENDIF
    ENDFOR
  ENDIF
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
    addentry(p, nm, 255, 0, 0)
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
    addentry(p, nm, 1, 0, 0)
    dl := NextDosEntry(dl, LDF_ASSIGNS)
  ENDWHILE
  UnLockDosList(LDF_VOLUMES OR LDF_ASSIGNS OR LDF_READ)
  sortpane(p)
  IF esel[p] >= ecount[p] THEN esel[p] := ecount[p] - 1
  IF esel[p] < 0 THEN esel[p] := 0
  IF etop[p] > esel[p] THEN etop[p] := esel[p]
ENDPROC

PROC readpane(p)
  pfreeok[p] := FALSE    -> free space may have changed; re-ask Info()
  IF inarchive(p)
    readarcdir(p)
  ELSEIF iniso(p)
    readisodir(p)
  ELSEIF involume(p)
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
    panemask := 255    -> R6: never mask a pubscreen
    flatmask := 255
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
    -> R6 (stage b8): the ROM's plane-mask trick. The own screen is
    -> depth 3; the pane surfaces use pens {0,1,4,5} (planes %101 -
    -> plane 1 provably untouched) and the console/viewer/editor/
    -> results surfaces pens {0,1} (%001). Their SCROLL blits may
    -> skip the other planes - but only when the bitmap is really
    -> planar-standard (RTG lies about depth); the pubscreen
    -> fallback and the ANSI viewer (full-colour, never blits) stay
    -> at 255. Text/fills stay full-depth: every surface ENTRY
    -> repaints unmasked, which is what scrubs another surface's
    -> planes (the ccon narrowing rule).
    IF GetBitMapAttr(rp.bitmap, BMA_FLAGS) AND BMF_STANDARD
      panemask := %101
      flatmask := %001
    ENDIF
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
    cmfull := FALSE
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
-> R5 (0.4.1 stage b5): a PANE row's framebuf interior is spaces by
-> construction (the composer writes only cols 0/divcol/divcol+1/
-> ncols-1 there, and no ctab art piece lands on rows 6..nrows-4) -
-> drawframe's RectFill already blanked it and drawpane owns it, so
-> pane rows draw just the four border cells instead of ncols of
-> Text that drawrow then painted a third time.
PROC frow(r)
  DEF y, m
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  y := top + (r * ch) + baseline
  IF (r >= 6) AND (r <= (nrows - 4))
    m := framebuf + Mul(r, ncols)
    Move(rp, x0, y)
    Text(rp, m, 1)
    Move(rp, x0 + Mul(divcol, cw), y)
    Text(rp, m + divcol, 2)
    Move(rp, x0 + Mul(ncols - 1, cw), y)
    Text(rp, m + (ncols - 1), 1)
  ELSE
    Move(rp, x0, y)
    Text(rp, framebuf + Mul(r, ncols), ncols)
  ENDIF
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
-> the pane's location as one string: a real path, "(volumes)", or the
-> archive path with the subpath inside it appended for the border row
PROC paneloc(p, dst)
  IF inarchive(p)
    StrCopy(dst, arcpath[p])
    IF EstrLen(arcsub[p]) > 0
      StrAdd(dst, '/')
      StrAdd(dst, arcsub[p])
    ENDIF
  ELSEIF iniso(p)
    StrCopy(dst, isopath[p])
    IF EstrLen(isosub[p]) > 0
      StrAdd(dst, '/')
      StrAdd(dst, isosub[p])
    ENDIF
  ELSEIF EstrLen(ppath[p]) = 0
    StrCopy(dst, '(volumes)')
  ELSE
    StrCopy(dst, ppath[p])
  ENDIF
ENDPROC

-> free bytes on the volume a pane sits on, or -1 when there is no
-> one volume to ask about (the volume list) or the question means
-> nothing (inside an archive). Info() wants a longword-aligned
-> InfoData and AllocDosObject has no type for one, so it comes from
-> New(), which is longword-aligned.
PROC freebytes(p)
  DEF id:PTR TO infodata, lock=NIL, n=-1, nfree, bpb, t, lim
  -> Info() means a Lock, so on a floppy it can touch the disk; cache
  -> the answer and only re-ask when readpane marks the pane stale
  IF pfreeok[p] THEN RETURN pfree[p]
  pfree[p] := -1
  pfreeok[p] := TRUE
  IF inarchive(p) THEN RETURN -1
  IF iniso(p) THEN RETURN -1
  IF EstrLen(ppath[p]) = 0 THEN RETURN -1
  IF (id := New(SIZEOF infodata)) = NIL THEN RETURN -1
  IF lock := Lock(ppath[p], SHARED_LOCK)
    IF Info(lock, id)
      bpb := id.bytesperblock
      nfree := id.numblocks - id.numblocksused
      IF nfree < 0 THEN nfree := 0
      IF bpb < 1
        n := -1
      ELSE
        -> X1: Div's DIVS quotient overflows 16 bits for any real
        -> bytes-per-block, so this guard was dead and Mul could wrap
        -> negative on a >2GB volume. Shift-derive the limit instead:
        -> halve MAXLONG once per doubling up to bpb (rounding bpb UP
        -> to a power of two, so odd sizes stay conservative).
        lim := 2147483647
        t := 1
        WHILE t < bpb
          t := Shl(t, 1)
          lim := Shr(lim, 1)
        ENDWHILE
        IF nfree > lim
          n := 2147483647    -> past a LONG of bytes; fmtbytes says 1.9G
        ELSE
          n := Mul(nfree, bpb)
        ENDIF
      ENDIF
    ENDIF
    UnLock(lock)
  ENDIF
  Dispose(id)
  pfree[p] := n
ENDPROC n

-> the border-row status field for one pane: the marked set's count
-> and bytes while anything is marked, otherwise the volume's free
-> space. At most 10 characters ("500* 1023K", "1023K free"). The
-> '*' is the same glyph the pane puts in front of a marked name.
PROC panefield(p, dst)
  DEF nm, sz[12]:STRING, fb
  StrCopy(dst, '')
  IF (nm := markcount(p)) > 0
    fmtbytes(sz, markbytes(p))
    StringF(dst, '\d* \s', nm, sz)
    RETURN
  ENDIF
  -> an archive with uncommitted edits flags itself here (there is no
  -> free space to show inside one); the edits commit on leaving it
  IF arcdirty(p)
    StrCopy(dst, 'modified')
    RETURN
  ENDIF
  IF (fb := freebytes(p)) >= 0
    fmtbytes(sz, fb)
    StringF(dst, '\s free', sz)
  ENDIF
ENDPROC

PROC drawpaths()
  DEF p, full[620]:STRING, s[200]:STRING, fld[20]:STRING,
      l, x, j, fw, fx, hend, slot
  frow(5)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR p := 0 TO 1
    x := IF p = 0 THEN 3 ELSE divcol + 4
    hend := IF p = 0 THEN divcol - 1 ELSE ncols - 2
    -> The status field lives in a FIXED slot at the right of the pane
    -> half, so its width never steals path columns: whatever the count
    -> or byte total, the path keeps the same room and does not reflow
    -> as marks come and go. The slot is reserved whenever a field can
    -> appear at all - i.e. not in the volume list, where there is no
    -> free space to show and nothing can be marked. The path then owns
    -> everything up to one clear column before the slot.
    panefield(p, fld)
    fw := EstrLen(fld)
    IF involume(p)
      slot := 0
    ELSE
      slot := FLDW
    ENDIF
    -> the slot's right edge is fixed at hend-1; its content is right-
    -> aligned within it so the last digit always lands in the same cell
    fx := hend - fw
    j := hend - slot - 1 - x - 1
    IF j < 1 THEN j := 1
    paneloc(p, full)
    l := EstrLen(full)
    IF l > j
      MidStr(s, full, l - j, j)
    ELSE
      StrCopy(s, full)
    ENDIF
    Move(rp, x0 + (x * cw), bordy + baseline)
    Text(rp, ' ', 1)
    Text(rp, s, EstrLen(s))
    Text(rp, ' ', 1)
    IF fw > 0
      -> one space left of the field carves it out of the dash rail,
      -> the way the path's own leading/trailing spaces do
      Move(rp, x0 + ((fx - 1) * cw), bordy + baseline)
      Text(rp, ' ', 1)
      Text(rp, fld, fw)
    ENDIF
  ENDFOR
  SetBPen(rp, 0)
ENDPROC

-> R8 (stage b5): repaint ONLY one pane's border-row status slot (the
-> FLDW field drawpaths reserves) - the slot span is restored from the
-> composed frame row (dashes) and the field re-laid right-aligned,
-> exactly as drawpaths lays it. For the mark-run path, where the full
-> row redraw (and its two markcount walks per pane) was the cost.
PROC drawfield(p)
  DEF fld[20]:STRING, fw, hend, w, cpos
  IF involume(p) THEN RETURN    -> no slot reserved there
  hend := IF p = 0 THEN divcol - 1 ELSE ncols - 2
  panefield(p, fld)
  fw := EstrLen(fld)
  w := FLDW + 1                 -> the slot + its carving space
  cpos := hend - w
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0 + Mul(cpos, cw), bordy + baseline)
  Text(rp, framebuf + Mul(5, ncols) + cpos, w)
  IF fw > 0
    Move(rp, x0 + Mul(hend - fw - 1, cw), bordy + baseline)
    Text(rp, ' ', 1)
    Text(rp, fld, fw)
  ENDIF
ENDPROC

PROC drawrow(p, r)
  DEF idx, x, y, s, l, pw, i, mk, sz[12]:STRING, fw, nw
  x := panex(p)
  y := panetop + (r * ch)
  pw := Mul(panew(p), cw)
  idx := etop[p] + r
  IF efail[p]
    SetAPen(rp, 0)
    RectFill(rp, x, y, x + pw - 1, y + ch - 1)
    IF r = 0
      s := 'cannot read this directory'
      SetAPen(rp, errpen)
      SetBPen(rp, 0)
      Move(rp, x, y + baseline)
      Text(rp, s, StrLen(s))
    ENDIF
    RETURN
  ENDIF
  IF idx >= ecount[p]
    SetAPen(rp, 0)
    RectFill(rp, x, y, x + pw - 1, y + ch - 1)
    RETURN
  ENDIF
  i := (p * MAXENT) + idx
  mk := emark[i]
  s := enames[i]
  l := EstrLen(s)
  -> the name gives up the size column's cells (and the '*' cell if
  -> marked); the volume list has no size column, so names run full
  IF involume(p)
    nw := panew(p) - (IF mk THEN 1 ELSE 0)
  ELSE
    nw := panew(p) - CSZW - 1 - (IF mk THEN 1 ELSE 0)
  ENDIF
  IF nw < 1 THEN nw := 1
  IF l > nw THEN l := nw
  -> R8 (stage b5): ONE fill per row - the bar row used to be
  -> RectFilled black and then AGAIN in the bar pen (x22 per pane
  -> draw); the fill pen now branches first
  IF (p = active) AND (idx = esel[p])
    -> the bar keeps the entry's type colour: blue text for a
    -> directory, grey for a file (unless the fallback screen left
    -> dirpen = txtpen, which would vanish into the bar)
    SetAPen(rp, txtpen)
    RectFill(rp, x, y, x + pw - 1, y + ch - 1)
    IF edirs[i] AND (dirpen <> txtpen)
      SetAPen(rp, dirpen)
    ELSE
      SetAPen(rp, 0)
    ENDIF
    SetBPen(rp, txtpen)
  ELSE
    SetAPen(rp, 0)
    RectFill(rp, x, y, x + pw - 1, y + ch - 1)
    SetAPen(rp, IF edirs[i] THEN dirpen ELSE txtpen)
    SetBPen(rp, 0)
  ENDIF
  Move(rp, x, y + baseline)
  IF mk THEN Text(rp, '*', 1)
  Text(rp, s, l)
  -> the right-aligned column: normally a size (a file's bytes, "<DIR>"
  -> for an unmeasured directory, its walked size once '=' measured it),
  -> but a compact date when the panes are sorted by date. Same pens as
  -> the name, so the selection bar inverts it too.
  IF involume(p) = FALSE
    IF sortmode = 2
      IF edate[i] > 0
        -> C4: a DateToStr per visible cell per repaint became a
        -> memo hit - scrolls and repaints stop re-deriving dates
        IF eddk[i] <> edate[i]
          datestr(edate[i], sz)
          AstrCopy(edds + Mul(i, 8), sz, 8)
          eddk[i] := edate[i]
        ELSE
          StrCopy(sz, edds + Mul(i, 8))
        ENDIF
      ELSE
        StrCopy(sz, '')
      ENDIF
    ELSEIF edirs[i] AND (esize[i] = 0)
      StrCopy(sz, '<DIR>')
    ELSE
      fmtbytes(sz, esize[i])
    ENDIF
    fw := EstrLen(sz)
    IF fw > 0
      Move(rp, x + pw - Mul(fw, cw), y + baseline)
      Text(rp, sz, fw)
    ENDIF
  ENDIF
  SetBPen(rp, 0)
ENDPROC

PROC drawpane(p)
  DEF r
  FOR r := 0 TO visrows - 1
    drawrow(p, r)
  ENDFOR
ENDPROC

-> R1 (0.4.1 stage b6): the scroll engine's ONE primitive - shift a
-> pixel rectangle by one cell row; the caller draws only what came
-> in. dy = +1 scrolls content UP (revealing at the bottom), -1 DOWN
-> (revealing at the top). The CCON lesson in one line: move pixels
-> that exist, draw only what is new - the border is never touched.
PROC scrollone(x, y, w, h, dy, mask)
  rp.mask := mask               -> R6 (stage b8): the blit skips the
  ScrollRaster(rp, 0, Mul(dy, ch), x, y, x + w - 1, y + h - 1)
  rp.mask := 255                -> planes this surface's pens never
ENDPROC                         -> touch; everything else full-depth

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

-> R5 (stage b5): refresh + re-place the cursor on prevname with each
-> pane drawn ONCE - the old shape was refreshall() (both panes drawn)
-> then selectbyname() (the pane drawn AGAIN)
PROC refreshsel(p)
  readpane(0)
  readpane(1)
  placebyname(p)
  drawall()
ENDPROC

-> I6 (stage b5): one-sided refresh - re-read and redraw ONLY pane p;
-> the OTHER pane re-reads only when it shows the same directory
-> (else its pixels are not touched at all). Border row redrawn for
-> the field slots. Only for verbs whose screen debris is confined
-> to the border row (prompts) - anything that painted a progress
-> box must keep refreshall's full-frame erase.
PROC refreshpane(p, place)
  DEF q
  q := 1 - p
  readpane(p)
  IF place THEN placebyname(p)
  IF (inarchive(q) = FALSE) AND (iniso(q) = FALSE)
    IF nccmp(ppath[p], ppath[q]) = 0
      readpane(q)
      drawpane(q)
    ENDIF
  ENDIF
  drawpane(p)
  drawpaths()
ENDPROC

-> F5: re-read both panes from disk (a shell or Workbench may have
-> changed a directory behind CFile's back), keeping each cursor on the
-> entry it was on if that entry is still there.
PROC rescan()
  DEF n0[110]:STRING, n1[110]:STRING
  StrCopy(n0, '')
  StrCopy(n1, '')
  IF ecount[0] > 0 THEN StrCopy(n0, enames[esel[0]])
  IF ecount[1] > 0 THEN StrCopy(n1, enames[MAXENT + esel[1]])
  readpane(0)
  readpane(1)
  -> R5 (stage b5): place BOTH cursors first, draw once - each pane
  -> was drawn by drawall and then AGAIN by selectbyname
  IF EstrLen(n0) > 0
    StrCopy(prevname, n0)
    placebyname(0)
  ENDIF
  IF EstrLen(n1) > 0
    StrCopy(prevname, n1)
    placebyname(1)
  ENDIF
  drawall()
ENDPROC

-> locate the entry named in prevname (if present) and centre it -
-> NO draw (R5: callers pair it with the one draw they already own)
PROC placebyname(p)
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
ENDPROC

-> select the entry named in prevname (if present), centre it, redraw
PROC selectbyname(p)
  placebyname(p)
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
  IF pad > 0
    -> R8 (stage b5): the trailing pad was a Text of up to 80 spaces
    -> per prompt repaint - one fill covers the same cells
    SetAPen(rp, 0)
    RectFill(rp, x0 + Mul(4 + pl + (IF cpos < l THEN l ELSE l + 1), cw), bordy,
             x0 + Mul(4 + pl + (IF cpos < l THEN l ELSE l + 1) + pad, cw) - 1,
             bordy + ch - 1)
    SetAPen(rp, txtpen)
  ENDIF
ENDPROC

-> in-place line editor on the border row: returns 1 on Return, 0 on
-> Esc. Left/Right move the cursor, Backspace deletes before it, Del
-> under it, typing inserts. names=TRUE refuses "/" and ":" (object
-> names, never paths); FALSE takes anything (shell commands).
PROC lineinput(prompt, buf, max, names)
  DEF class, code, l, i, j, qual, res=-2, s:PTR TO CHAR, cpos
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
      ELSEIF code = 8    -> backspace: one char; Shift = to line start,
                         -> Ctrl = back to the nearest "/" or ":" (path bit)
        IF cpos > 0
          qual := MsgQualifier()
          IF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            j := 0
          ELSEIF qual AND IEQUALIFIER_CONTROL
            -> skip any separators right before the cursor, then the
            -> component, stopping just after the previous "/" or ":"
            j := cpos
            WHILE (j > 0) AND ((s[j-1] = "/") OR (s[j-1] = ":"))
              j--
            ENDWHILE
            WHILE (j > 0) AND (s[j-1] <> "/") AND (s[j-1] <> ":")
              j--
            ENDWHILE
          ELSE
            j := cpos - 1
          ENDIF
          -> delete [j, cpos): shift the tail down by (cpos - j)
          l := EstrLen(buf)
          FOR i := cpos TO l - 1
            s[i - (cpos - j)] := s[i]
          ENDFOR
          SetStr(buf, l - (cpos - j))
          cpos := j
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
    -> R1 (stage b6): edge cross = one blit + two rows, not a
    -> 22-row repaint (the hottest interactive path in the program)
    etop[p] := esel[p]
    scrollone(panex(p), panetop, Mul(panew(p), cw), Mul(visrows, ch), -1, panemask)
    drawrow(p, 0)
    IF visrows > 1 THEN drawrow(p, 1)
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
    -> R1 (stage b6): edge cross = one blit + two rows (see moveup)
    etop[p] := esel[p] - visrows + 1
    scrollone(panex(p), panetop, Mul(panew(p), cw), Mul(visrows, ch), 1, panemask)
    IF visrows > 1 THEN drawrow(p, visrows - 2)
    drawrow(p, visrows - 1)
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
  -> R8 (stage b5): no drawpaths - nothing on that row changes on a
  -> pane switch (the bar alone shows which pane is active)
  drawrow(old, esel[old] - etop[old])
  drawrow(active, esel[active] - etop[active])
ENDPROC

-> go inside an lha archive selected in a real directory. On success
-> the pane switches to archive mode rooted at the archive; ppath[p]
-> stays put (the archive's own directory), ready for the exit.
PROC enterarchive(p, fpath, fmt)
  DEF stageroot[CPATHLEN]:STRING
  arcfmt[p] := fmt    -> loadarchive and the write verbs branch on this
  IF loadarchive(p, fpath)
    StrCopy(arcpath[p], fpath)
    arcstage(p, stageroot)    -> clear any staging a crash left behind
    arcwipe(stageroot)
    SetStr(arcsub[p], 0)
    esel[p] := 0
    etop[p] := 0
    readpane(p)
    drawpaths()
    drawpane(p)
  ELSE
    freearccache(p)
    showmsg(IF fmt = TY_LZX THEN 'could not read the archive - is C:lzx present?' ELSE 'could not read the archive - is C:lha present?')
  ENDIF
ENDPROC

PROC enterdir()
  DEF p, i, ty, fpath[CPATHLEN+12]:STRING
  p := active
  IF efail[p] THEN RETURN
  IF ecount[p] = 0 THEN RETURN
  i := (p * MAXENT) + esel[p]
  IF inarchive(p)
    IF edirs[i] = 0 THEN RETURN    -> a member file: Right does nothing
    IF EstrLen(arcsub[p]) > 0 THEN StrAdd(arcsub[p], '/')
    StrAdd(arcsub[p], enames[i])   -> descend a virtual subdirectory
    esel[p] := 0
    etop[p] := 0
    readpane(p)
    drawpaths()
    drawpane(p)
    RETURN
  ENDIF
  IF iniso(p)
    IF edirs[i] = 0 THEN RETURN    -> a file: Right does nothing
    IF EstrLen(isosub[p]) > 0 THEN StrAdd(isosub[p], '/')
    StrAdd(isosub[p], enames[i])   -> descend inside the image
    esel[p] := 0
    etop[p] := 0
    readpane(p)
    drawpaths()
    drawpane(p)
    RETURN
  ENDIF
  IF edirs[i] = 0
    -> a file in a real directory: Right enters it only if it is an
    -> lha/lzx archive or an ISO image (other types stay files)
    IF involume(p) = FALSE
      buildfull(fpath, ppath[p], enames[i])
      ty := sniff(fpath)
      IF (ty = TY_LHA) OR (ty = TY_LZX)
        enterarchive(p, fpath, ty)
      ELSEIF ty = TY_ISO
        enteriso(p, fpath)
      ELSEIF ty = TY_ADF
        enteradf(p, fpath)
      ENDIF
    ENDIF
    RETURN
  ENDIF
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
  DEF p, s:PTR TO CHAR, l, i, cut=-1, colon=-1, start, k, didleave=FALSE
  p := active
  IF inarchive(p)
    IF EstrLen(arcsub[p]) > 0
      -> up one level inside the archive: drop the last path component
      s := arcsub[p]
      l := EstrLen(arcsub[p])
      cut := -1
      FOR i := 0 TO l - 1
        IF s[i] = "/" THEN cut := i
      ENDFOR
      IF cut >= 0
        MidStr(prevname, arcsub[p], cut + 1, ALL)   -> reselect the child
        SetStr(arcsub[p], cut)
      ELSE
        StrCopy(prevname, arcsub[p])
        SetStr(arcsub[p], 0)
      ENDIF
    ELSE
      -> at the archive root: leave the archive, back to its real
      -> directory, and reselect the archive file there. A modified
      -> archive asks first - save the pending edits, discard them, or
      -> cancel and stay inside. (Quitting CFile always saves.)
      IF arcdirty(p)
        promptrow('archive modified - (s)ave (d)iscard (c)ancel')
        k := waitvanilla()
        IF (k = "d") OR (k = "D")
          arcdiscard(p)    -> leavearchive's commit then finds nothing
        ELSEIF (k = "s") OR (k = "S")
          -> keep the pending edits; leavearchive commits them
        ELSE
          drawpaths()      -> cancel: stay in the archive
          RETURN
        ENDIF
      ENDIF
      StrCopy(prevname, FilePart(arcpath[p]))
      leavearchive(p)
      didleave := TRUE
    ENDIF
    esel[p] := 0
    etop[p] := 0
    IF didleave
      -> leaving may have committed edits that changed the archive file's
      -> size, so refresh BOTH panes - the other one may show that file too
      refreshsel(p)    -> R5: one draw, cursor pre-placed
    ELSE
      readpane(p)
      drawpaths()
      selectbyname(p)
    ENDIF
    RETURN
  ENDIF
  IF iniso(p)
    IF EstrLen(isosub[p]) > 0
      -> up one level inside the image: drop the last path component
      s := isosub[p]
      l := EstrLen(isosub[p])
      cut := -1
      FOR i := 0 TO l - 1
        IF s[i] = "/" THEN cut := i
      ENDFOR
      IF cut >= 0
        MidStr(prevname, isosub[p], cut + 1, ALL)   -> reselect the child
        SetStr(isosub[p], cut)
      ELSE
        StrCopy(prevname, isosub[p])
        SetStr(isosub[p], 0)
      ENDIF
    ELSE
      -> at the image root: leave, back to the real directory, and
      -> reselect the .iso file there (nothing to commit - read-only)
      StrCopy(prevname, FilePart(isopath[p]))
      leaveiso(p)
    ENDIF
    esel[p] := 0
    etop[p] := 0
    readpane(p)
    drawpaths()
    selectbyname(p)
    RETURN
  ENDIF
  -> Left at the root of a disk image WE mounted: offer the way out
  -> his ask specified. (y) unmounts and returns to the .adf's
  -> directory; (n) keeps it mounted - quit will still clean it up;
  -> Esc stays. The other pane is OUR in-use discipline: DAControl
  -> would happily yank the disk from under it (daprobe lesson).
  k := damfind(ppath[p])
  IF k >= 0
    promptrow('unmount the disk image? (y)es (n)o = keep mounted')
    i := waitvanilla()
    IF (i = "y") OR (i = "Y")
      -> prefix, not equality: the other pane may be DEEPER inside
      IF ncprefix(ppath[1 - p], ppath[p], EstrLen(ppath[p]))
        showmsg('the other pane is inside the mounted disk')
        RETURN
      ENDIF
      IF daeject(damdev[k])
        SetStr(damdev[k], 0)    -> slot free again
      ELSE
        showmsg('the volume is busy - kept mounted (quit retries)')
      ENDIF
    ELSEIF (i <> "n") AND (i <> "N")
      drawpaths()    -> Esc or anything else: stay put
      RETURN
    ENDIF
    StrCopy(prevname, damname[k])
    StrCopy(ppath[p], damback[k])
    esel[p] := 0
    etop[p] := 0
    readpane(p)
    drawpaths()
    selectbyname(p)
    RETURN
  ENDIF
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

-> non-blocking: drain the window's pending input, and if Esc was pressed
-> while a cancellable op is running, raise `abort` (other keys are dropped so
-> nothing queued fires when the op ends). A no-op outside a cancellable op
-> (cancelok = FALSE), so helper copies inside non-cancellable verbs are
-> never interrupted. The archive transfers set cancelok too (b21): their
-> pump/poll loops call this each tick and hand the archiver the break.
PROC checkabort()
  DEF msg:PTR TO intuimessage
  IF cancelok = FALSE THEN RETURN FALSE
  WHILE (msg := GetMsg(win.userport))
    IF (msg.class = IDCMP_VANILLAKEY) AND (msg.code = 27) THEN abort := TRUE
    ReplyMsg(msg)
  ENDWHILE
ENDPROC abort

-> the Esc-cancel family for archiver children (b21). The async runs
-> (arcpollrun, arcrunprog) launch the child under NP_NAME = arcname():
-> a name unique to THIS CFile instance, so the break can never land in
-> another instance's run. SystemTagList passes NP_ tags through to
-> CreateNewProc, and the command runs inside that named process itself.
PROC arcname()
  IF runname[0] = 0 THEN StringF(runname, 'CFile-arc.\h', FindTask(NIL))
ENDPROC runname

-> hand the running child the shell break. Inside Forbid the process
-> cannot exit between find and Signal; if it is already gone, FindTask
-> misses and this is a no-op. lha and lzx honour CTRL-C: they stop,
-> drop their temp file, and the archive itself stays as it was (both
-> rebuild to a temp and rename only at the very end).
PROC arcbreak()
  DEF t
  Forbid()
  t := FindTask(runname)
  IF t THEN Signal(t, SIGBREAKF_CTRL_C)
  Permit()
ENDPROC

PROC copyfile(src, dst)
  DEF fhs=NIL, fhd=NIL, n=0, w, ok=TRUE, err=0, chunk
  IF (fhs := Open(src, OLDFILE)) = NIL
    faultmsg('cannot read the source')
    RETURN FALSE
  ENDIF
  IF (fhd := Open(dst, NEWFILE)) = NIL
    Close(fhs)
    faultmsg('cannot write the target')
    RETURN FALSE
  ENDIF
  -> the smooth bar (his ask, 29.7.26: byte-honest, not chunks, not
  -> per file - the thing no Amiga file manager has). The bar already
  -> fills at PIXEL resolution over its 248-px interior; the only
  -> chunkiness was the update rate - one progadd per 256KB read. So
  -> the chunk adapts to the RUN's bytes-per-pixel (progtotal spans
  -> the whole marked set, so the bar is pixel-continuous across
  -> files too): every completed chunk advances the fill ~one pixel,
  -> and every pixel is genuinely completed bytes. Floored at 16KB
  -> (the packet-cost floor - big runs have big pixels, so big runs
  -> keep big chunks), capped at the I1 buffer. Bonus: Esc latency
  -> rides the chunk rate and improves with it.
  chunk := cbufsz
  IF progon
    IF progbyfile = FALSE
      chunk := Shr(progtotal, 8)    -> ~bytes per bar pixel
      IF chunk < 16384 THEN chunk := 16384
      IF chunk > cbufsz THEN chunk := cbufsz
    ENDIF
  ENDIF
  REPEAT
    IF checkabort()    -> Esc mid-copy: stop like an error, dst is cleaned up
      ok := FALSE
    ELSE
      n := Read(fhs, copybuf, chunk)
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
            IF progbyfile = FALSE THEN progadd(n)    -> archive bar is by file
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  UNTIL (n <= 0) OR (ok = FALSE)
  Close(fhd)
  Close(fhs)
  IF ok = FALSE
    DeleteFile(dst)    -> no partial targets
    IF abort = FALSE THEN showfault('copy failed', err)   -> cancel: no error
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
  DEF lock=NIL, child,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF depth > 20 THEN RETURN
  IF (child := String(CPATHLEN)) = NIL THEN RETURN
  IF lock := Lock(path, SHARED_LOCK)
    sc := s                     -> I3 (stage b3+): batched walk
    easbegin(sc, lock)
    ed := easnext(sc)
    WHILE (ed <> NIL) AND (checkabort() = FALSE)   -> Esc stops the pre-scan too
      statfiles := statfiles + 1
      IF ed.type > 0
        StrCopy(child, path)
        AddPart(child, ed.name, CPATHLEN - 4)
        SetStr(child, StrLen(child))
        treestat(child, depth + 1)
      ELSE
        statbytes := statbytes + ed.size
      ENDIF
      ed := easnext(sc)
    ENDWHILE
    easend(sc)
    UnLock(lock)
  ENDIF
  DisposeLink(child)
ENDPROC

-> TRUE if `s` carries an AmigaDOS pattern metacharacter - then find globs
-> the whole name instead of matching a substring
PROC hasmeta(s:PTR TO CHAR)
  DEF i=0, c
  WHILE c := s[i]
    IF (c = "#") OR (c = "?") OR (c = "*") OR (c = "(") OR (c = ")") OR
       (c = "|") OR (c = "~") OR (c = "[") OR (c = "]") OR (c = "%")
      RETURN TRUE
    ENDIF
    i++
  ENDWHILE
ENDPROC FALSE

-> recursively collect every real file/dir under `dir` whose name matches
-> into res[], each a String'd full path, up to FINDMAX. isglob TRUE = whole-
-> name MatchPatternNoCase against `parsed`; otherwise a case-insensitive
-> substring of `pat`. cnt^ is shared across the recursion. Cancellable via
-> Esc (checkabort - the caller sets cancelok). Heap path buffers, like
-> copytree: a deep tree cannot sit on E's stack.
PROC findwalk(dir, depth, pat, parsed, isglob, res:PTR TO LONG, cnt:PTR TO LONG)
  DEF lock=NIL, child=NIL, full=NIL, s, match,
      es[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF depth > 20 THEN RETURN
  IF cnt[0] >= FINDMAX THEN RETURN
  IF checkabort() THEN RETURN
  child := String(CPATHLEN)
  full := String(CPATHLEN)
  IF (child = NIL) OR (full = NIL)
    IF child THEN DisposeLink(child)
    IF full THEN DisposeLink(full)
    RETURN
  ENDIF
  IF lock := Lock(dir, SHARED_LOCK)
    sc := es                    -> I3 (stage b3+): batched walk
    easbegin(sc, lock)
    ed := easnext(sc)
    WHILE (ed <> NIL) AND (cnt[0] < FINDMAX) AND (checkabort() = FALSE)
      StrCopy(full, dir)
      AddPart(full, ed.name, CPATHLEN - 4)
      SetStr(full, StrLen(full))
      IF isglob
        match := MatchPatternNoCase(parsed, ed.name)
      ELSE
        match := nchas(ed.name, pat)
      ENDIF
      IF match
        IF (s := String(EstrLen(full) + 1))
          StrCopy(s, full)
          res[cnt[0]] := s
          cnt[0] := cnt[0] + 1
        ENDIF
      ENDIF
      IF (ed.type > 0) AND (cnt[0] < FINDMAX)
        StrCopy(child, full)
        findwalk(child, depth + 1, pat, parsed, isglob, res, cnt)
      ENDIF
      ed := easnext(sc)
    ENDWHILE
    easend(sc)
    UnLock(lock)
  ENDIF
  DisposeLink(child)
  DisposeLink(full)
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
  DEF lock=NIL, ok=TRUE, lk, csrc=NIL, cdst=NIL,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
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
  csrc := String(CPATHLEN)
  cdst := String(CPATHLEN)
  IF (csrc = NIL) OR (cdst = NIL)
    IF csrc THEN DisposeLink(csrc)
    IF cdst THEN DisposeLink(cdst)
    RETURN FALSE
  ENDIF
  IF (lock := Lock(src, SHARED_LOCK)) = NIL
    faultmsg('cannot read the source')
    ok := FALSE
  ELSE
    sc := s                     -> I3 (stage b3+): batched walk
    easbegin(sc, lock)
    ed := easnext(sc)
    WHILE (ed <> NIL) AND ok    -> plain flags: safe despite E's eager AND
      StrCopy(csrc, src)
      AddPart(csrc, ed.name, CPATHLEN - 4)
      SetStr(csrc, StrLen(csrc))
      StrCopy(cdst, dst)
      AddPart(cdst, ed.name, CPATHLEN - 4)
      SetStr(cdst, StrLen(cdst))
      IF ed.type > 0
        ok := copytree(csrc, cdst, depth + 1)
      ELSE
        ok := copyfile(csrc, cdst)
      ENDIF
      IF ok THEN ed := easnext(sc)
    ENDWHILE
    IF sc.err THEN ok := FALSE  -> a died scan fails the copy, as the
    easend(sc)                  -> old failed Examine did
    UnLock(lock)
  ENDIF
  DisposeLink(csrc)
  DisposeLink(cdst)
  IF ok THEN copyattribs(src, dst)
ENDPROC ok

-> delete a directory tree, then the directory itself. tick = count
-> entries on the progress bar (deletes use entry units, copies use
-> byte units). An entry that will not go (protection, or a name the
-> handler cannot resolve back - seen with FS-UAE directory drives
-> and non-ASCII names) is put on a skip list and the rest of the
-> tree still gets deleted; every undeletable entry counts into
-> gfails and the caller reports the total.
-> 0.4.1 I7b (stage b3): the old shape re-Locked and re-walked the
-> directory PER DELETED CHILD (~4-5 packets each - deleting during
-> an ExNext walk would invalidate it, so each round rescanned to
-> the first unskipped name). Now one exallscan SNAPSHOTS up to
-> DTCHUNK unskipped names, the deletes run from the snapshot, and
-> the level rescans only when the snapshot was truncated. The
-> snapshot lives on the heap (New), not the frame - the proc
-> recurses 20 deep and the stack budget stays where it was.
PROC deltree(path, depth, tick)
  DEF lock=NIL, ok, child, pm[130]:STRING,
      skip[16]:ARRAY OF LONG, nskip=0, j, i, over, sawany=FALSE,
      giveup=FALSE,   -> stop this level, but nskip stays the true slot count
      names=NIL:PTR TO LONG, dirsb=NIL:PTR TO CHAR, ncol, trunc,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF depth > 20
    showmsg('directory tree too deep')
    gfails := gfails + 1
    RETURN FALSE
  ENDIF
  IF (child := String(CPATHLEN)) = NIL THEN RETURN FALSE
  names := New(DTCHUNK * 4)
  dirsb := New(DTCHUNK)
  IF (names = NIL) OR (dirsb = NIL)
    IF names THEN Dispose(names)
    IF dirsb THEN Dispose(dirsb)
    DisposeLink(child)
    RETURN FALSE
  ENDIF
  REPEAT
    ncol := 0
    trunc := FALSE
    IF checkabort()
      abort := TRUE    -> Esc mid-delete: end the loop, leave the rest in place
    ELSEIF (lock := Lock(path, SHARED_LOCK)) = NIL
      StringF(pm, 'cannot read "\s"', FilePart(path))
      faultmsg(pm)
      giveup := TRUE    -> cannot even scan: give up on this level
    ELSE
      -> snapshot pass: every unskipped name, up to the chunk cap
      sc := s
      easbegin(sc, lock)
      ed := easnext(sc)
      WHILE ed
        over := FALSE
        IF nskip > 0
          FOR j := 0 TO nskip - 1
            IF nccmp(ed.name, skip[j]) = 0 THEN over := TRUE
          ENDFOR
        ENDIF
        IF over = FALSE
          IF ncol < DTCHUNK
            IF (names[ncol] := String(StrLen(ed.name)))
              StrCopy(names[ncol], ed.name)
              dirsb[ncol] := IF ed.type > 0 THEN 1 ELSE 0
              ncol := ncol + 1
              sawany := TRUE
            ELSE
              giveup := TRUE
            ENDIF
          ELSE
            trunc := TRUE       -> the remainder waits for a rescan
          ENDIF
        ENDIF
        ed := easnext(sc)
      ENDWHILE
      easend(sc)
      UnLock(lock)
      lock := NIL
    ENDIF
    -> delete pass: from the snapshot, no rescan per child
    i := 0
    WHILE (i < ncol) AND (abort = FALSE) AND (giveup = FALSE)
      IF checkabort()
        abort := TRUE
      ELSE
        StrCopy(child, path)
        AddPart(child, names[i], CPATHLEN - 4)
        SetStr(child, StrLen(child))
        IF dirsb[i]
          ok := deltree(child, depth + 1, tick)
        ELSE
          IF (ok := zap(child, TRUE))
            IF tick THEN progadd(1)
          ELSE
            StringF(pm, 'cannot delete "\s"', names[i])
            faultmsg(pm)
            gfails := gfails + 1
          ENDIF
        ENDIF
        IF (ok = FALSE) AND (abort = FALSE)
          -> leave it behind and carry on with its siblings
          IF nskip < 16
            IF (skip[nskip] := String(StrLen(names[i])))
              StrCopy(skip[nskip], names[i])
              nskip := nskip + 1
            ELSE
              giveup := TRUE
            ENDIF
          ELSE
            giveup := TRUE    -> too many failures here: stop this level
          ENDIF
        ENDIF
        i := i + 1
      ENDIF
    ENDWHILE
    FOR j := 0 TO ncol - 1      -> this chunk's name copies
      DisposeLink(names[j])
    ENDFOR
    -> trunc=FALSE means the snapshot covered the WHOLE level: after
    -> its delete pass nothing new remains (failures sit in the skip
    -> list) - no confirming rescan owed
  UNTIL (trunc = FALSE) OR giveup OR abort
  -> free every skip slot we actually allocated (nskip is the true count now,
  -> so a give-up no longer leaks them)
  FOR j := 0 TO nskip - 1
    DisposeLink(skip[j])
  ENDFOR
  IF abort
    ok := FALSE    -> cancelled: leave this dir and its remaining contents
  ELSEIF (nskip > 0) OR giveup
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
  Dispose(names)
  Dispose(dirsb)
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

-> ---- copy / move with archives (files only, for now) --------------

-> build the stored member path: "sub/name", or just "name" at the root
PROC arcmember(dst, sub, name)
  StrCopy(dst, sub)
  IF EstrLen(dst) > 0 THEN StrAdd(dst, '/')
  StrAdd(dst, name)
ENDPROC

-> the first path component of `path` (up to the first slash)
PROC firstcomp(dst, path:PTR TO CHAR)
  DEF i=0
  WHILE (path[i] <> 0) AND (path[i] <> "/")
    i++
  ENDWHILE
  StrCopy(dst, path, i)
ENDPROC

-> the deferred-write staging root: a scratch directory in the archive's
-> OWN directory. T: is normally RAM:T, so accumulating a session's
-> edits there would eat memory a machine with little fast RAM does not
-> have; the archive's volume is where the commit writes anyway. The
-> name carries the pane number, so the same archive open in both panes
-> stages to two separate trees. Writes dst = "<archive's dir>/CFile-stgN".
-> build "<the archive's directory>/name" - a scratch path on the
-> archive's own volume (see arcstage for why not T:)
PROC arcsibling(p, dst, name)
  DEF a:PTR TO CHAR, dl
  a := arcpath[p]
  dl := PathPart(a) - a    -> length of the directory part
  StrCopy(dst, a, dl)
  AddPart(dst, name, CPATHLEN - 4)
  SetStr(dst, StrLen(dst))
ENDPROC

-> the deferred-write staging root, one scratch dir per pane so the same
-> archive open in both panes stages separately
PROC arcstage(p, dst)
  arcsibling(p, dst, IF p = 0 THEN 'CFile-stg0' ELSE 'CFile-stg1')
ENDPROC

-> index of the exact stored member in pane p's cache, or -1
PROC arccacheslot(p, member:PTR TO CHAR)
  DEF a:PTR TO LONG, k
  a := amem[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      IF nccmp(a[k], member) = 0 THEN RETURN k
    ENDFOR
  ENDIF
ENDPROC -1

-> add a staged member to the cache as a pending add, unless it is
-> already there (a merge into an existing folder just keeps the old
-> entry). A directory member is stored with a trailing slash.
PROC arccacheput(p, member, size, isdir)
  DEF full[CPATHLEN]:STRING, st:PTR TO LONG, slot
  StrCopy(full, member)
  IF isdir THEN StrAdd(full, '/')
  IF arccacheslot(p, full) >= 0 THEN RETURN
  slot := arcadd(p, full, size)
  IF slot >= 0
    st := amst[p]
    st[slot] := MST_ADD
  ENDIF
ENDPROC

-> walk a just-staged source tree on disk and add a cache member for
-> every file and subdirectory, so a copied-in folder browses correctly
-> before the commit. `disk` is the staged directory, `mprefix` its
-> stored member path (no trailing slash).
PROC arccachetree(p, disk, mprefix, depth)
  DEF lock=NIL, child=NIL, mem=NIL,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF depth > 20 THEN RETURN
  IF (lock := Lock(disk, SHARED_LOCK)) = NIL THEN RETURN
  -> path buffers from the heap, not the stack: this recurses to depth 20
  -> and E cannot size its stack for that (as copytree/deltree/treestat do)
  child := String(CPATHLEN)
  mem := String(CPATHLEN)
  IF (child = NIL) OR (mem = NIL)
    IF child THEN DisposeLink(child)
    IF mem THEN DisposeLink(mem)
    UnLock(lock)
    RETURN
  ENDIF
  sc := s                       -> I3 (stage b3+): batched walk
  easbegin(sc, lock)
  ed := easnext(sc)
  WHILE ed
    StrCopy(mem, mprefix)
    StrAdd(mem, '/')
    StrAdd(mem, ed.name)
    IF ed.type > 0
      arccacheput(p, mem, 0, TRUE)
      StrCopy(child, disk)
      AddPart(child, ed.name, CPATHLEN - 4)
      SetStr(child, StrLen(child))
      arccachetree(p, child, mem, depth + 1)
    ELSE
      arccacheput(p, mem, ed.size, FALSE)
    ENDIF
    ed := easnext(sc)
  ENDWHILE
  easend(sc)
  DisposeLink(child)
  DisposeLink(mem)
  UnLock(lock)
ENDPROC

-> wipe a scratch tree without disturbing the delete-run failure count
PROC arcwipe(dir)
  DEF savg
  savg := gfails
  IF pathtype(dir) > 0 THEN deltree(dir, 0, FALSE)
  gfails := savg
ENDPROC

-> is `full` already a member of pane q's cached archive?
PROC archasmember(q, full)
  DEF a:PTR TO LONG, k
  a := amem[q]
  IF amcnt[q] > 0
    FOR k := 0 TO amcnt[q] - 1
      IF nccmp(a[k], full) = 0 THEN RETURN TRUE
    ENDFOR
  ENDIF
ENDPROC FALSE

-> delete one member from an archive by its exact stored path. -Qw
-> turns off wildcards so a pattern character in the name cannot make
-> the delete match anything but that one member.
PROC arcdelmember(arcfile, member)
  DEF cmd[700]:STRING, res
  StringF(cmd, 'lha -M -Qw d "\s" "\s"', arcfile, member)
  res := arcrunprog(NIL, cmd)
  DeleteFile('T:CFile-out')
ENDPROC res

-> copy `src` into dst, escaping AmigaDOS pattern metachars with ' so
-> `lzx d` matches the name literally. LZX 1.21's d globs and has no -Qw, so
-> a stored name with #?%*()|[]~ (or a literal ') would otherwise over-match
-> (probe-confirmed). The ' is escaped first as '', so its own escape is not
-> re-processed. dst must hold up to twice the source length.
PROC lzxesc(dst, src:PTR TO CHAR)
  DEF i=0, j=0, c, d:PTR TO CHAR
  d := dst
  WHILE c := src[i]
    IF (c = "'") OR (c = "#") OR (c = "?") OR (c = "%") OR (c = "*") OR
       (c = "(") OR (c = ")") OR (c = "|") OR (c = "[") OR (c = "]") OR (c = "~")
      d[j] := "'"
      j++
    ENDIF
    d[j] := c
    j++
    i++
  ENDWHILE
  SetStr(dst, j)
ENDPROC

-> delete one member from an lzx archive by its exact stored name (escaped).
-> runcapture, not arcrunprog: lzx's delete output ("Deleted: x") is not the
-> lha "...ing:" the progress bar keys on, so the bar just rests.
PROC lzxdelmember(arcfile, member)
  DEF cmd[700]:STRING, esc[620]:STRING, res
  lzxesc(esc, member)
  StringF(cmd, 'lzx d "\s" "\s"', arcfile, esc)
  res := runcapture(NIL, cmd, 'T:CFile-out')
  DeleteFile('T:CFile-out')
ENDPROC res

-> delete every member under `prefix` (the bare "prefix/" dir entry included)
-> from pane p's lzx archive, batched, each name escaped. lzx d removes stored
-> directory members directly (with the trailing slash), so - unlike lha - no
-> rebuild is needed. Iterates the current cache; the caller reloads it.
PROC lzxdeltree(p, prefix)
  DEF a:PTR TO LONG, k, pfx[CPATHLEN]:STRING, pl, m:PTR TO CHAR,
      cmd[700]:STRING, base[360]:STRING, esc[620]:STRING, res, ok=TRUE, baselen
  StrCopy(pfx, prefix)
  StrAdd(pfx, '/')
  pl := StrLen(pfx)
  StringF(base, 'lzx d "\s"', arcpath[p])
  StrCopy(cmd, base)
  baselen := EstrLen(cmd)
  a := amem[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      IF ncprefix(m, pfx, pl)
        lzxesc(esc, m)
        IF (EstrLen(cmd) + EstrLen(esc)) > 600
          res := runcapture(NIL, cmd, 'T:CFile-out')
          IF res = -1 THEN ok := FALSE
          StrCopy(cmd, base)
        ENDIF
        StrAdd(cmd, ' "')
        StrAdd(cmd, esc)
        StrAdd(cmd, '"')
      ENDIF
    ENDFOR
  ENDIF
  IF EstrLen(cmd) > baselen
    res := runcapture(NIL, cmd, 'T:CFile-out')
    IF res = -1 THEN ok := FALSE
  ENDIF
  DeleteFile('T:CFile-out')
ENDPROC ok

-> run an lha command asynchronously through a PIPE and drive the
-> progress bar from its output: LhA prints one line per file, each
-> ending "...ing:" (Extract/Add/Delet-ing), so every "ing:" that goes
-> by is one file done - progadd(1). No console render, just the bar.
-> A byte-by-byte match survives the marker splitting across reads.
-> Returns the launch result (-1 could not start); the effect is
-> verified by the caller, not by an exit code the asynch run hides.
PROC arcrunprog(dir, cmd)
  DEF wout=NIL, nin=NIL, rdr=NIL, dlock=NIL, old=NIL, res,
      buf:PTR TO CHAR, n, i, c, st=0, prevtotal=0, curtot=0, memdone=0,
      killed=FALSE, w
  buf := pipebuf    -> I7a: 4KB shared pipe buffer, not 256B on the stack
  IF (wout := Open('PIPE:cfile-arc', NEWFILE)) = NIL
    RETURN runcapture(dir, cmd, 'T:CFile-out')    -> no PIPE: no bar
  ENDIF
  IF dir
    dlock := Lock(dir, SHARED_LOCK)
    IF dlock THEN old := CurrentDir(dlock)
  ENDIF
  nin := Open('NIL:', OLDFILE)
  res := SystemTagList(cmd,
    [SYS_INPUT,  nin,
     SYS_OUTPUT, wout,
     SYS_ASYNCH, TRUE,
     NP_NAME,    arcname(),
     TAG_DONE,   NIL])
  IF dlock
    CurrentDir(old)
    UnLock(dlock)
  ENDIF
  IF res = -1
    Close(wout)
    IF nin THEN Close(nin)
    RETURN -1
  ENDIF
  -> the launched command owns nin/wout now (asynch closes them)
  IF rdr := Open('PIPE:cfile-arc', OLDFILE)
    n := Read(rdr, buf, PIPESZ)
    WHILE n > 0
      FOR i := 0 TO n - 1
        c := buf[i]
        IF proglzx = 1
          -> lzx ADD: each file prints "Adding (<size>)" - progadd its size
          -> when the ")" closes. States 4..10 spell out "Adding (".
          IF st = 10                   -> collecting the size digits
            IF (c >= "0") AND (c <= "9")
              curtot := Mul(curtot, 10) + (c - "0")
            ELSEIF c = ")"
              progadd(curtot)
              st := 0
            ENDIF
          ELSEIF st = 9                -> after "Adding", seek the "("
            IF c = "("
              curtot := 0
              st := 10
            ENDIF
          ELSEIF (st = 8) AND (c = "g")
            st := 9
          ELSEIF (st = 7) AND (c = "n")
            st := 8
          ELSEIF (st = 6) AND (c = "i")
            st := 7
          ELSEIF (st = 5) AND (c = "d")
            st := 6
          ELSEIF (st = 4) AND (c = "d")
            st := 5
          ELSEIF c = "A"
            st := 4
          ELSE
            st := 0
          ENDIF
        ELSEIF proglzx = 2
          -> lzx EXTRACT: the "( <run> / <total> )" line REDRAWS into
          -> the pipe as lzx works - live intra-member byte progress.
          -> The smooth bar (b18): progadd the run's DELTAS as they
          -> stream (memdone = bytes already credited this member);
          -> the no-slash "( total ) Extracted OK:" line closes the
          -> member - reconcile to its full total and reset. Deltas
          -> only ever grow (clamped), so redraw retransmissions and
          -> split pipe reads cannot double-count.
          IF st = 12                   -> after "/", collect the total
            IF (c >= "0") AND (c <= "9")
              curtot := Mul(curtot, 10) + (c - "0")
            ELSEIF c = ")"
              IF prevtotal > memdone   -> live delta from the redraw
                progadd(prevtotal - memdone)
                memdone := prevtotal
              ENDIF
              st := 0
            ENDIF
          ELSEIF st = 11               -> before "/", collect the running count
            IF (c >= "0") AND (c <= "9")
              prevtotal := Mul(prevtotal, 10) + (c - "0")
            ELSEIF c = "/"
              curtot := 0
              st := 12
            ELSEIF c = ")"
              -> no slash: "( total ) Extracted OK" - the member ends
              IF prevtotal > memdone THEN progadd(prevtotal - memdone)
              memdone := 0
              st := 0
            ENDIF
          ELSEIF c = "("
            prevtotal := 0
            st := 11
          ELSE
            st := 0
          ENDIF
        ELSEIF progbybytes
          -> match "ing:" for a new file, then read its "(...  /  total)":
          -> on each new file the PREVIOUS one is done, so its total is
          -> added; the last file's total is added when the pipe closes.
          IF st = 6                    -> reading the total's digits
            IF (c >= "0") AND (c <= "9")
              curtot := Mul(curtot, 10) + (c - "0")
            ELSEIF c <> 32
              prevtotal := curtot
              st := 0
            ENDIF
          ELSEIF st = 5                -> inside (), seek the '/'
            IF c = "/"
              curtot := 0
              st := 6
            ENDIF
          ELSEIF st = 4                -> after "ing:", seek the '('
            IF c = "("
              st := 5
            ENDIF
          ELSEIF (st = 3) AND (c = ":")
            progadd(prevtotal)         -> the previous member finished
            prevtotal := 0
            st := 4
          ELSEIF (st = 2) AND (c = "g")
            st := 3
          ELSEIF (st = 1) AND (c = "n")
            st := 2
          ELSEIF c = "i"
            st := 1
          ELSE
            st := 0
          ENDIF
        ELSE
          IF (st = 3) AND (c = ":")
            progadd(1)
            st := 0
          ELSEIF (st = 2) AND (c = "g")
            st := 3
          ELSEIF (st = 1) AND (c = "n")
            st := 2
          ELSEIF c = "i"
            st := 1
          ELSE
            st := 0
          ENDIF
        ENDIF
      ENDFOR
      -> Esc (b21): checked between pipe chunks - and, where PIPE:
      -> supports WaitForChar, every 1/5s while the pipe is silent (a
      -> big member packs for a long time without printing). The wait
      -> is BOUNDED (~5s) so a handler that cannot wait, or one blind
      -> at EOF, just falls through to the blocking Read as before -
      -> correctness never rests on WaitForChar. After the break the
      -> loop keeps draining to EOF, so the child's exit is still seen
      -> the normal way and the run winds down cleanly.
      w := IF (killed = FALSE) AND cancelok THEN 25 ELSE 0
      WHILE w > 0
        IF checkabort()
          arcbreak()
          killed := TRUE
          w := 0
        ELSEIF WaitForChar(rdr, 200000)
          w := 0
        ELSE
          w := w - 1
        ENDIF
      ENDWHILE
      n := Read(rdr, buf, PIPESZ)
    ENDWHILE
    Close(rdr)
    -> a broken-off run never finished its last member: no credit
    IF progbybytes AND (killed = FALSE) THEN progadd(prevtotal)
  ENDIF
ENDPROC res

-> how many file members of pane p's archive live under `prefix`
PROC arccountunder(p, prefix)
  DEF a:PTR TO LONG, k, pfx[CPATHLEN]:STRING, pl, m:PTR TO CHAR, n=0
  StrCopy(pfx, prefix)
  StrAdd(pfx, '/')
  pl := StrLen(pfx)
  a := amem[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      IF ncprefix(m, pfx, pl)
        IF m[pl] THEN n := n + 1
      ENDIF
    ENDFOR
  ENDIF
ENDPROC n

-> total byte size of the file members under `prefix` (the progress
-> denominator for a byte-weighted extract)
PROC arcsizeunder(p, prefix)
  DEF a:PTR TO LONG, z:PTR TO LONG, k, pfx[CPATHLEN]:STRING, pl,
      m:PTR TO CHAR, n=0
  StrCopy(pfx, prefix)
  StrAdd(pfx, '/')
  pl := StrLen(pfx)
  a := amem[p]
  z := amsz[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      IF ncprefix(m, pfx, pl)
        IF m[pl] THEN n := n + z[k]
      ENDIF
    ENDFOR
  ENDIF
ENDPROC n

-> extract every member of pane p's archive that lives under `prefix`
-> (a directory member path, no trailing slash) into T:CFile-x, its
-> stored subtree intact. Members go on the command line in batches -
-> lha takes several filespecs at once - and makepath pre-builds each
-> target dir so lha never has to (the NIL:-input directory bug). The
-> prefix dir itself is created even when it holds no files.
PROC arcextracttree(p, prefix, root)
  DEF a:PTR TO LONG, k, pfx[CPATHLEN]:STRING, pl, m:PTR TO CHAR,
      cmd[700]:STRING, base[360]:STRING, sfile[CPATHLEN]:STRING,
      res, ok=TRUE, baselen,
      z:PTR TO LONG, pfiles=NIL:PTR TO LONG, psizes=NIL:PTR TO LONG,
      nf=0, pidx, pcred, j
  StrCopy(pfx, prefix)
  StrAdd(pfx, '/')
  pl := StrLen(pfx)
  -> the byte bar: collect the expected outputs (path + exact size,
  -> cache order = archive order = extraction order) BEFORE any run;
  -> arcpollrun walks them across the batched commands with one
  -> shared cursor. Dir members and zero-size files sit in the list
  -> harmlessly - they advance instantly. Allocation failure just
  -> means no polling (nf stays 0, runs fall back to the pipe road).
  z := amsz[p]
  a := amem[p]
  IF amcnt[p] > 0
    pfiles := New(Mul(amcnt[p], 4))
    psizes := New(Mul(amcnt[p], 4))
    IF (pfiles = NIL) OR (psizes = NIL)
      IF pfiles THEN Dispose(pfiles)
      IF psizes THEN Dispose(psizes)
      pfiles := NIL
      psizes := NIL
    ELSE
      FOR k := 0 TO amcnt[p] - 1
        m := a[k]
        IF ncprefix(m, pfx, pl)
          IF m[pl]
            IF (pfiles[nf] := String(StrLen(root) + 1 + StrLen(m)))
              StrCopy(pfiles[nf], root)
              StrAdd(pfiles[nf], '/')
              StrAdd(pfiles[nf], m)
              psizes[nf] := z[k]
              nf := nf + 1
            ENDIF
          ENDIF
        ENDIF
      ENDFOR
    ENDIF
  ENDIF
  pidx := 0
  pcred := 0
  StrCopy(sfile, root)            -> make sure the prefix dir exists
  StrAdd(sfile, '/')
  StrAdd(sfile, pfx)
  StrAdd(sfile, '.')
  makepath(sfile)
  -> lzx x vs lha -M x (see arcviewsel). Member names go on the command line
  -> unescaped: extract patterns can only over-match into the T: scratch,
  -> which is harmless (the literal member always lands, then copytree takes
  -> exactly the intended subtree).
  IF arcfmt[p] = TY_LZX
    StringF(base, 'lzx x "\s"', arcpath[p])
  ELSE
    StringF(base, 'lha -M x "\s"', arcpath[p])
  ENDIF
  StrCopy(cmd, base)
  baselen := EstrLen(cmd)
  a := amem[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      IF ncprefix(m, pfx, pl) AND (abort = FALSE)    -> Esc: stop batching
        IF m[pl]    -> a real file below the dir, not the bare dir entry
          StrCopy(sfile, root)
          StrAdd(sfile, '/')
          StrAdd(sfile, m)
          makepath(sfile)
          DeleteFile(sfile)
          IF (EstrLen(cmd) + StrLen(m)) > 600
            StrAdd(cmd, ' "')
            StrAdd(cmd, root)
            StrAdd(cmd, '/"')
            IF nf > 0
              res := arcpollrun(cmd, pfiles, psizes, nf, {pidx}, {pcred})
              IF res = -1 THEN res := arcrunprog(NIL, cmd)
            ELSE
              res := arcrunprog(NIL, cmd)
            ENDIF
            IF (res = -1) OR abort THEN ok := FALSE
            StrCopy(cmd, base)
          ENDIF
          StrAdd(cmd, ' "')
          StrAdd(cmd, m)
          StrAdd(cmd, '"')
        ENDIF
      ENDIF
    ENDFOR
  ENDIF
  IF (EstrLen(cmd) > baselen) AND (abort = FALSE)
    StrAdd(cmd, ' "')
    StrAdd(cmd, root)
    StrAdd(cmd, '/"')
    IF nf > 0
      res := arcpollrun(cmd, pfiles, psizes, nf, {pidx}, {pcred})
      IF res = -1 THEN res := arcrunprog(NIL, cmd)
    ELSE
      res := arcrunprog(NIL, cmd)
    ENDIF
    IF (res = -1) OR abort THEN ok := FALSE
  ENDIF
  FOR j := 0 TO nf - 1
    DisposeLink(pfiles[j])
  ENDFOR
  IF pfiles THEN Dispose(pfiles)
  IF psizes THEN Dispose(psizes)
  DeleteFile('T:CFile-out')
ENDPROC ok

-> delete every member under `prefix` (the dir entry included) from
-> pane p's archive, in batches. Iterates the CURRENT cache; the caller
-> reloads it afterwards.
PROC arcdeltree(p, prefix)
  DEF a:PTR TO LONG, k, pfx[CPATHLEN]:STRING, pl, m:PTR TO CHAR,
      cmd[700]:STRING, base[360]:STRING, res, ok=TRUE, baselen
  StrCopy(pfx, prefix)
  StrAdd(pfx, '/')
  pl := StrLen(pfx)
  -> -Qw: no wildcards, so each stored name is matched literally and a
  -> member with pattern characters cannot delete more than itself
  StringF(base, 'lha -M -Qw d "\s"', arcpath[p])
  StrCopy(cmd, base)
  baselen := EstrLen(cmd)
  a := amem[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      IF ncprefix(m, pfx, pl)
        IF (EstrLen(cmd) + StrLen(m)) > 600
          res := arcrunprog(NIL, cmd)
          IF res = -1 THEN ok := FALSE
          StrCopy(cmd, base)
        ENDIF
        StrAdd(cmd, ' "')
        StrAdd(cmd, m)
        StrAdd(cmd, '"')
      ENDIF
    ENDFOR
  ENDIF
  IF EstrLen(cmd) > baselen
    res := arcrunprog(NIL, cmd)
    IF res = -1 THEN ok := FALSE
  ENDIF
  DeleteFile('T:CFile-out')
ENDPROC ok

-> drop a member's staged content when a not-yet-committed add is
-> deleted, so the commit's add pass does not put it back. Files go
-> with DeleteFile, an empty staged directory with arcwipe.
PROC arcunstage(p, member:PTR TO CHAR)
  DEF stageroot[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING, l
  arcstage(p, stageroot)
  StrCopy(sfile, stageroot)
  AddPart(sfile, member, CPATHLEN - 4)
  SetStr(sfile, StrLen(sfile))
  l := EstrLen(sfile)
  IF (l > 0) AND (sfile[l - 1] = "/") THEN SetStr(sfile, l - 1)
  IF pathtype(sfile) = 2 THEN arcwipe(sfile) ELSE DeleteFile(sfile)
ENDPROC

-> ARCWRITE ONEXIT: flag the cache members a delete would remove, so
-> the archive is left untouched until commit. A file matches by exact
-> stored name; a directory matches everything under it (the same
-> prefix test arcdeltree uses, so an empty "dir/" entry is caught too).
-> A member still only STAGED (added this session, not yet committed) is
-> un-staged instead - its file leaves the tree and the flag hides it.
-> Returns how many members were newly flagged.
PROC arcflagdel(p, member, isdir)
  DEF a:PTR TO LONG, st:PTR TO LONG, k, pfx[CPATHLEN]:STRING, pl,
      m:PTR TO CHAR, n=0
  a := amem[p]
  st := amst[p]
  IF amcnt[p] = 0 THEN RETURN 0
  IF isdir
    StrCopy(pfx, member)
    StrAdd(pfx, '/')
    pl := StrLen(pfx)
    FOR k := 0 TO amcnt[p] - 1
      IF ncprefix(a[k], pfx, pl)
        IF (st[k] = MST_ADD) OR (st[k] = MST_REPLACE) THEN arcunstage(p, a[k])
        IF st[k] <> MST_DEL THEN n++
        st[k] := MST_DEL
      ENDIF
    ENDFOR
  ELSE
    FOR k := 0 TO amcnt[p] - 1
      m := a[k]
      IF nccmp(m, member) = 0
        IF (st[k] = MST_ADD) OR (st[k] = MST_REPLACE) THEN arcunstage(p, m)
        IF st[k] <> MST_DEL THEN n++
        st[k] := MST_DEL
      ENDIF
    ENDFOR
  ENDIF
ENDPROC n

-> commit a pane's deferred archive edits: the one batched LhA delete
-> the whole session's flagged members collapse into. Runs only in
-> ARCWRITE ONEXIT and only when something is pending; the caller (leave
-> or quit) invokes it while the cache still exists. Batches like
-> arcdeltree - lha takes several filespecs per call. So far only
-> deletes are deferred; adds/edits join here as the model grows.
-> the add pass of a commit: every top-level entry of the staging tree
-> goes into one lha -r -e add, CWD = the staging root so the stored
-> paths are tree-relative (the only add form that keeps a subdirectory
-> prefix). -e stores an explicitly-made empty directory. Batched like
-> the delete pass; the shared lock is held across the run, which is
-> safe - lha only reads the tree, it writes the archive elsewhere.
PROC arcaddstaged(p, stageroot)
  DEF lock=NIL, cmd[700]:STRING, base[360]:STRING, baselen,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF (lock := Lock(stageroot, SHARED_LOCK)) = NIL THEN RETURN
  -> add the staging tree's top-level entries; -r -e keeps the subtree and
  -> stores empty dirs. Source names go unescaped (they name real staged
  -> files, so a pattern can only re-match them).
  IF islzx(p)
    StringF(base, 'lzx -r -e a "\s"', arcpath[p])
  ELSE
    StringF(base, 'lha -M -r -e a "\s"', arcpath[p])
  ENDIF
  StrCopy(cmd, base)
  baselen := EstrLen(cmd)
  sc := s                       -> I3 (stage b3+): batched walk
  easbegin(sc, lock)
  ed := easnext(sc)
  WHILE ed
    IF (EstrLen(cmd) + StrLen(ed.name)) > 600
      arcrunprog(stageroot, cmd)
      StrCopy(cmd, base)
    ENDIF
    StrAdd(cmd, ' "')
    StrAdd(cmd, ed.name)
    StrAdd(cmd, '"')
    ed := easnext(sc)
  ENDWHILE
  easend(sc)
  UnLock(lock)
  IF EstrLen(cmd) > baselen THEN arcrunprog(stageroot, cmd)
  DeleteFile('T:CFile-out')
ENDPROC

-> repack a whole work tree into a fresh archive: every top-level entry
-> in one lha -r -e add, CWD = the tree for tree-relative paths. Returns
-> TRUE if at least one entry was archived (an all-deleted archive would
-> leave newarc absent - the caller keeps the original then).
PROC arcrepack(work, newarc)
  DEF lock=NIL, cmd[700]:STRING, base[360]:STRING, baselen, any=FALSE,
      s[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF (lock := Lock(work, SHARED_LOCK)) = NIL THEN RETURN FALSE
  StringF(base, 'lha -M -r -e a "\s"', newarc)
  StrCopy(cmd, base)
  baselen := EstrLen(cmd)
  sc := s                       -> I3 (stage b3+): batched walk
  easbegin(sc, lock)
  ed := easnext(sc)
  WHILE ed
    IF (EstrLen(cmd) + StrLen(ed.name)) > 600
      runcapture(work, cmd, 'T:CFile-out')
      StrCopy(cmd, base)
    ENDIF
    StrAdd(cmd, ' "')
    StrAdd(cmd, ed.name)
    StrAdd(cmd, '"')
    any := TRUE
    ed := easnext(sc)
  ENDWHILE
  easend(sc)
  UnLock(lock)
  IF EstrLen(cmd) > baselen THEN runcapture(work, cmd, 'T:CFile-out')
  DeleteFile('T:CFile-out')
ENDPROC any

-> commit when a DIRECTORY member must go: LhA's 'd' cannot remove a
-> -lhd- entry, so the whole archive is rebuilt. Extract it all to a work
-> tree, prune the deleted paths, overlay the staged adds/replaces, repack
-> with -r -e, and swap the fresh archive in. Also collapses any duplicate
-> members. Heavy (a full recompress) - only the dir-delete commit pays it.
PROC arcrebuild(p, stageroot)
  DEF a:PTR TO LONG, st:PTR TO LONG, k, m:PTR TO CHAR, lk, l, res, ok=FALSE,
      work[CPATHLEN]:STRING, xdir[CPATHLEN]:STRING, path[CPATHLEN]:STRING,
      newarc[CPATHLEN]:STRING, cmd[700]:STRING, canary=NIL:PTR TO CHAR
  a := amem[p]
  st := amst[p]
  arcsibling(p, work, IF p = 0 THEN 'CFile-wrk0' ELSE 'CFile-wrk1')
  -> the .lha suffix is REQUIRED: LhA auto-appends it to a suffixless
  -> archive name, so writing "CFile-nw0" really makes "CFile-nw0.lha" -
  -> the name we hand lha must match the file it creates and we rename
  arcsibling(p, newarc, IF p = 0 THEN 'CFile-nw0.lha' ELSE 'CFile-nw1.lha')
  arcwipe(work)
  DeleteFile(newarc)
  IF lk := CreateDir(work) THEN UnLock(lk)
  IF pathtype(work) <> 2
    faultmsg('cannot make the rebuild work directory')
    RETURN FALSE
  ENDIF
  -> pre-build every kept member's directory: lha fed NIL: for input
  -> cannot create a missing output dir, and this also materialises the
  -> empty-dir members we are keeping. MST_ADD members are not in the
  -> archive (they live in the staging tree), so they are skipped.
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      IF st[k] <> MST_ADD
        StrCopy(path, work)
        AddPart(path, a[k], CPATHLEN - 4)
        SetStr(path, StrLen(path))
        makepath(path)
        -> remember one kept file to prove the extract worked afterwards
        IF (canary = NIL) AND (st[k] <> MST_DEL) AND (memberisdir(a[k]) = FALSE)
          canary := a[k]
        ENDIF
      ENDIF
    ENDFOR
  ENDIF
  StrCopy(xdir, work)
  StrAdd(xdir, '/')    -> a destdir must end in a slash
  StringF(cmd, 'lha -M x "\s" "\s"', arcpath[p], xdir)
  res := runcapture(NIL, cmd, 'T:CFile-out')
  DeleteFile('T:CFile-out')
  IF res = -1
    faultmsg('the rebuild extract failed - archive left as it was')
    arcwipe(work)
    RETURN FALSE
  ENDIF
  -> verify by effect: if a known kept file did NOT extract, the tree is
  -> incomplete - repacking the pre-built empty dirs over the original
  -> would lose data, so abort and leave the archive untouched
  IF canary
    StrCopy(path, work)
    AddPart(path, canary, CPATHLEN - 4)
    SetStr(path, StrLen(path))
    IF pathtype(path) <> 1
      faultmsg('the rebuild extract was incomplete - archive left as it was')
      arcwipe(work)
      RETURN FALSE
    ENDIF
  ENDIF
  -> prune the deleted paths from the work tree
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      IF st[k] = MST_DEL
        m := a[k]
        StrCopy(path, work)
        AddPart(path, m, CPATHLEN - 4)
        SetStr(path, StrLen(path))
        l := EstrLen(path)
        IF (l > 0) AND (path[l - 1] = "/") THEN SetStr(path, l - 1)
        IF pathtype(path) = 2
          deltree(path, 0, FALSE)
        ELSEIF pathtype(path) = 1
          DeleteFile(path)
        ENDIF
      ENDIF
    ENDFOR
  ENDIF
  -> overlay the staged adds/edits (a merge - replaced files overwrite)
  IF pathtype(stageroot) = 2 THEN copytree(stageroot, work, 0)
  -> repack and swap in only on success, so a failure never loses data
  IF arcrepack(work, newarc) AND (pathtype(newarc) = 1)
    IF DeleteFile(arcpath[p])
      ok := Rename(newarc, arcpath[p]) <> 0
    ENDIF
  ENDIF
  IF ok = FALSE THEN DeleteFile(newarc)
  arcwipe(work)
ENDPROC ok

-> TRUE if the stored member path is a directory entry (trailing slash)
PROC memberisdir(m:PTR TO CHAR)
  DEF l
  l := StrLen(m)
ENDPROC (l > 0) AND (m[l - 1] = "/")

PROC arccommit(p)
  DEF a:PTR TO LONG, st:PTR TO LONG, k, cmd[700]:STRING, base[360]:STRING,
      m:PTR TO CHAR, esc[620]:STRING, baselen, hasdel=FALSE, hasadd,
      needrebuild=FALSE, lzx, stageroot[CPATHLEN]:STRING
  IF inarchive(p) = FALSE THEN RETURN
  IF arcwrite = FALSE THEN RETURN
  IF amst[p] = NIL THEN RETURN
  lzx := islzx(p)
  a := amem[p]
  st := amst[p]
  IF amcnt[p] > 0
    FOR k := 0 TO amcnt[p] - 1
      -> REPLACE also needs the old member deleted before the add pass
      IF (st[k] = MST_DEL) OR (st[k] = MST_REPLACE) THEN hasdel := TRUE
      -> lha d cannot remove a directory member - that forces the rebuild
      -> path (extract/prune/repack). lzx d removes stored dir members
      -> directly (trailing slash), so lzx never needs the rebuild.
      IF (lzx = FALSE) AND (st[k] = MST_DEL) AND memberisdir(a[k])
        needrebuild := TRUE
      ENDIF
    ENDFOR
  ENDIF
  arcstage(p, stageroot)
  hasadd := pathtype(stageroot) = 2    -> a staging tree was built
  IF (hasdel = FALSE) AND (hasadd = FALSE) THEN RETURN
  -> a border-row note, not the centred bar: the commit can fire on the
  -> way out of the archive (partial redraw) or at quit (screen closing),
  -> neither of which erases a centred overlay cleanly.
  promptrow('writing changes to the archive')
  IF needrebuild
    -> a dir member is going (lha only): rebuild handles deletes, adds and
    -> edits all at once (and cleans up duplicates), so the passes are skipped
    arcrebuild(p, stageroot)
    IF pathtype(stageroot) = 2 THEN arcwipe(stageroot)
    DeleteFile('T:CFile-out')
    RETURN
  ENDIF
  -> delete pass FIRST, so a replaced or edited member is gone before its new
  -> version is added. lzx: escaped `lzx d` (globs, no -Qw), files and dir
  -> members alike. lha: `lha -M -Qw d`. Each rewrites the archive once.
  IF hasdel
    IF lzx
      StringF(base, 'lzx d "\s"', arcpath[p])
    ELSE
      StringF(base, 'lha -M -Qw d "\s"', arcpath[p])
    ENDIF
    StrCopy(cmd, base)
    baselen := EstrLen(cmd)
    FOR k := 0 TO amcnt[p] - 1
      IF (st[k] = MST_DEL) OR (st[k] = MST_REPLACE)
        m := a[k]
        IF lzx THEN lzxesc(esc, m) ELSE StrCopy(esc, m)
        IF (EstrLen(cmd) + EstrLen(esc)) > 600
          IF lzx THEN runcapture(NIL, cmd, 'T:CFile-out') ELSE arcrunprog(NIL, cmd)
          StrCopy(cmd, base)
        ENDIF
        StrAdd(cmd, ' "')
        StrAdd(cmd, esc)
        StrAdd(cmd, '"')
      ENDIF
    ENDFOR
    IF EstrLen(cmd) > baselen
      IF lzx THEN runcapture(NIL, cmd, 'T:CFile-out') ELSE arcrunprog(NIL, cmd)
    ENDIF
  ENDIF
  IF hasadd
    arcaddstaged(p, stageroot)
    arcwipe(stageroot)
  ENDIF
  DeleteFile('T:CFile-out')
ENDPROC

-> c/m when the ACTIVE pane is inside an archive: extract the selected
-> file(s) to the other pane. move = also delete the member afterwards.
-> the bar he asked for from the beginning (30.7.26, arc edition):
-> BYTE BY BYTE, no chunks, no per-member jumps. The archiver tells
-> us nothing useful through the pipe - so we stop listening and
-> WATCH THE DESTINATION FILES GROW instead. The expected outputs
-> (paths + exact sizes, in archive order - lha extracts in archive
-> order and the cache was built from the archive listing) are
-> handed in; the run goes DETACHED (SYS_ASYNCH, output captured to
-> T:CFile-out with no pump), and a Delay(1) poll walks the list:
-> each tick Examines the file the archiver is currently writing
-> and progadds the honest growth delta, advancing when a file
-> reaches its full size (zero-size entries and dir members advance
-> instantly). Run completion is unambiguous: the child owns the
-> capture file handle, so an EXCLUSIVE Lock on it succeeds only
-> after the archiver exits. idxp/credp persist the cursor across
-> BATCHED runs (arcextracttree splits big trees over several
-> commands). Esc (b21): the child runs under a per-instance NP_NAME,
-> so the poll can FindTask it and hand it the shell break - lha/lzx
-> stop cleanly, the lock check sees the exit, and the caller's abort
-> flag keeps the partial output from landing (the stage wipe eats it).
PROC arcsizeof(path)
  DEF lock, fib:PTR TO fileinfoblock, n=-1
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL THEN RETURN -1
  IF lock := Lock(path, SHARED_LOCK)
    IF Examine(lock, fib) THEN n := fib.size
    UnLock(lock)
  ENDIF
  FreeDosObject(DOS_FIB, fib)
ENDPROC n

PROC arcpollrun(cmd, files:PTR TO LONG, sizes:PTR TO LONG, nf,
                idxp:PTR TO LONG, credp:PTR TO LONG)
  DEF wout=NIL, nin=NIL, res, lk, sz, done=FALSE, adv, d, killed=FALSE
  DeleteFile('T:CFile-out')
  IF (wout := Open('T:CFile-out', NEWFILE)) = NIL THEN RETURN -1
  nin := Open('NIL:', OLDFILE)
  res := SystemTagList(cmd,
    [SYS_INPUT,  nin,
     SYS_OUTPUT, wout,
     SYS_ASYNCH, TRUE,
     NP_NAME,    arcname(),
     TAG_DONE,   NIL])
  IF res = -1
    Close(wout)
    IF nin THEN Close(nin)
    RETURN -1
  ENDIF
  -> the launched command owns nin/wout now (asynch closes them)
  REPEAT
    Delay(1)                    -> 1/50s: the poll IS the bar's tick
    IF checkabort()             -> Esc (b21): break the child once; the
      IF killed = FALSE         -> poll then just rides to its exit, and
        arcbreak()              -> the drain keeps eating queued keys
        killed := TRUE
      ENDIF
    ENDIF
    adv := TRUE
    WHILE adv AND (idxp[0] < nf)
      adv := FALSE
      sz := arcsizeof(files[idxp[0]])
      IF sz < 0 THEN sz := 0
      IF sz > sizes[idxp[0]] THEN sz := sizes[idxp[0]]
      d := sz - credp[0]
      IF d > 0
        progadd(d)              -> honest bytes, straight off the disk
        credp[0] := credp[0] + d
      ENDIF
      IF credp[0] >= sizes[idxp[0]]
        idxp[0] := idxp[0] + 1  -> this output is whole: next
        credp[0] := 0
        adv := TRUE
      ENDIF
    ENDWHILE
    lk := Lock('T:CFile-out', EXCLUSIVE_LOCK)
    IF lk                       -> the child released its output:
      UnLock(lk)                -> the run is over
      done := TRUE
    ENDIF
  UNTIL done
ENDPROC res

-> recreate one image directory as a real tree under dst: dirs made,
-> files pulled straight out of the image (byte-smooth bar, Esc lands
-> mid-file). More than ISOSD subdirectories in ONE directory is
-> refused honestly rather than silently dropped.
PROC isoextracttree(fh, ext, sz, dst, depth)
  DEF s[1]:ARRAY OF isoscan, sc:PTR TO isoscan, ok=TRUE, lk,
      child=NIL, dext=NIL:PTR TO LONG, dsz=NIL:PTR TO LONG,
      dnames=NIL:PTR TO LONG, nd=0, k
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
  child := String(CPATHLEN)
  dext := New(ISOSD * 4)
  dsz := New(ISOSD * 4)
  dnames := New(ISOSD * 4)
  IF (child = NIL) OR (dext = NIL) OR (dsz = NIL) OR (dnames = NIL)
    IF child THEN DisposeLink(child)
    IF dext THEN Dispose(dext)
    IF dsz THEN Dispose(dsz)
    IF dnames THEN Dispose(dnames)
    RETURN FALSE
  ENDIF
  sc := s
  isodbegin(sc, fh, ext, sz)
  WHILE isodnext(sc) AND ok    -> plain flags: safe despite eager AND
    StrCopy(child, dst)
    AddPart(child, sc.rname, CPATHLEN - 4)
    SetStr(child, StrLen(child))
    IF sc.rdir
      IF nd >= ISOSD
        showmsg('too many subdirectories in one folder')
        ok := FALSE
      ELSE
        dext[nd] := sc.rext
        dsz[nd] := sc.rsize
        IF (dnames[nd] := String(EstrLen(child) + 2))
          StrCopy(dnames[nd], child)
          nd++
        ELSE
          ok := FALSE
        ENDIF
      ENDIF
    ELSE
      IF isoextract(fh, sc.rext, sc.rsize, child, TRUE) = FALSE
        ok := FALSE
      ENDIF
    ENDIF
  ENDWHILE
  IF sc.err THEN ok := FALSE
  isodend(sc)
  FOR k := 0 TO nd - 1
    IF ok
      IF isoextracttree(fh, dext[k], dsz[k], dnames[k], depth + 1) = FALSE
        ok := FALSE
      ENDIF
    ENDIF
    DisposeLink(dnames[k])
  ENDFOR
  DisposeLink(child)
  Dispose(dext)
  Dispose(dsz)
  Dispose(dnames)
  IF abort THEN ok := FALSE
ENDPROC ok

-> c when the ACTIVE pane is inside an ISO image: copy the selected
-> file(s)/folder(s) to the other pane, reading straight out of the
-> image - no archiver, no staging, so the bar is byte-smooth by
-> construction and Esc lands mid-file. m refuses: the image is
-> read-only, a move could never drop its source.
PROC isoxfer_out(p, q, ismove, force)
  DEF b, nmark, i, pick, nm:PTR TO CHAR, member[CPATHLEN]:STRING,
      dfile[CPATHLEN]:STRING, tname[110]:STRING, mb[130]:STRING,
      fh=NIL, t, k, stop=FALSE, ndone=0, doit, total=0, ext, sz, isd
  IF involume(q) OR efail[q]
    showmsg('the other pane needs a directory to receive the files')
    RETURN
  ENDIF
  IF inarchive(q) OR iniso(q)
    showmsg('image-to-archive is not supported')
    RETURN
  ENDIF
  IF ismove
    showmsg('the CD image is read-only - c copies without moving')
    RETURN
  ENDIF
  IF (fh := Open(isopath[p], OLDFILE)) = NIL
    showmsg('cannot open the image file')
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  cancelok := TRUE    -> Esc cancels: the pre-scan and every copy
  abort := FALSE
  -> pre-scan: file bytes from the listing, folder bytes by walking
  -> the subtree - the smooth bar's denominator
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      IF edirs[b + i]
        arcmember(member, isosub[p], enames[b + i])
        IF isofind(fh, isoroot[p], isorootsz[p], member, {ext}, {sz}, {isd})
          total := total + isosum(fh, ext, sz, 0)
        ENDIF
      ELSE
        total := total + esize[b + i]
      ENDIF
    ENDIF
  ENDFOR
  IF total > 1 THEN progshow(total)
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stop = FALSE)
      nm := enames[b + i]
      IF edirs[b + i]
        arcmember(member, isosub[p], nm)
        buildfull(dfile, ppath[q], nm)
        IF pathtype(dfile) = 1
          showmsg('a file with that name is in the way')
        ELSEIF isofind(fh, isoroot[p], isorootsz[p], member,
                       {ext}, {sz}, {isd}) = FALSE
          faultmsg('cannot find that folder in the image')
          stop := TRUE
        ELSEIF isoextracttree(fh, ext, sz, dfile, 0) = FALSE
          IF abort = FALSE THEN faultmsg('could not copy the folder out')
          stop := TRUE
        ELSE
          ndone := ndone + 1
        ENDIF
      ELSE
        StrCopy(tname, nm)
        buildfull(dfile, ppath[q], tname)
        doit := TRUE
        t := pathtype(dfile)
        IF t > 0
          IF force
            k := "o"
          ELSE
            StringF(mb, '"\s" exists: (s)kip (o)verwrite (r)ename?', tname)
            promptrow(mb)
            k := waitvanilla()
          ENDIF
          IF (k = "o") OR (k = "O")
            IF t = 2
              showmsg('the target exists as a directory')
              doit := FALSE
            ENDIF
          ELSEIF (k = "r") OR (k = "R")
            IF lineinput('new name: ', tname, 30, TRUE) = 0
              drawpaths()
              doit := FALSE
            ELSEIF EstrLen(tname) = 0
              doit := FALSE
            ELSE
              buildfull(dfile, ppath[q], tname)
              IF pathtype(dfile) = 2
                showmsg('that name is a directory')
                doit := FALSE
              ENDIF
            ENDIF
          ELSEIF k = 27
            drawpaths()
            stop := TRUE
            doit := FALSE
          ELSE
            doit := FALSE    -> skip
          ENDIF
        ENDIF
        IF doit
          IF isoextract(fh, eext[b + i], esize[b + i], dfile, TRUE)
            ndone := ndone + 1
          ELSE
            IF abort = FALSE THEN faultmsg('could not copy that file out')
            stop := TRUE
          ENDIF
        ENDIF
      ENDIF
      IF abort THEN stop := TRUE
    ENDIF
  ENDFOR
  Close(fh)
  cancelok := FALSE
  progoff()
  refreshall()
  IF abort
    StringF(mb, 'cancelled - \d of \d done', ndone,
            IF nmark > 0 THEN nmark ELSE 1)
    showmsg(mb)
  ELSEIF ndone > 0
    StringF(mb, '\d file\s copied out', ndone, IF ndone = 1 THEN '' ELSE 's')
    showmsg(mb)
  ENDIF
  abort := FALSE
ENDPROC

PROC arcxfer_out(p, q, ismove, force)
  DEF b, nmark, i, pick, nm:PTR TO CHAR, member[CPATHLEN]:STRING,
      sfile[CPATHLEN]:STRING, dfile[CPATHLEN]:STRING, tname[110]:STRING,
      cmd[700]:STRING, mb[130]:STRING, res, t, k, stop=FALSE,
      ndone=0, deld=FALSE, deferred=FALSE, doit, total=0,
      stage[CPATHLEN]:STRING, moved,
      pfiles[1]:ARRAY OF LONG, psizes[1]:ARRAY OF LONG, pidx, pcred
  IF involume(q) OR efail[q]
    showmsg('the other pane needs a directory to receive the files')
    RETURN
  ENDIF
  IF inarchive(q) OR iniso(q)
    showmsg('archive-to-archive is not supported')
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  cancelok := TRUE    -> Esc cancels (b21): the copies AND the archiver
  abort := FALSE
  -> the RAM-disk lesson (his real find, 29.7.26: eight 880K ADFs
  -> against a 2MB machine): members used to stage through T: - RAM -
  -> on their way to the destination, so any member bigger than free
  -> RAM killed the run with a full RAM disk. The staging dir now
  -> lives BESIDE THE DESTINATION (its volume has the room by
  -> definition - the bytes are headed there), and landing a file
  -> becomes a same-volume Rename: instant, and the double write is
  -> gone with it.
  buildfull(stage, ppath[q], 'CFile-x.tmp')
  arcwipe(stage)    -> a stale tree from an interrupted run
  -> pre-scan BYTES: the bar advances by each extracted member's size, so
  -> a big member weighs more than a small one. A move's delete pass has
  -> no byte counter, so the bar just rests full while it runs.
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      IF edirs[b + i]
        arcmember(member, arcsub[p], enames[b + i])
        total := total + arcsizeunder(p, member)
      ELSE
        total := total + esize[b + i]
      ENDIF
    ENDIF
  ENDFOR
  progbyfile := TRUE     -> suppress copyfile's own byte ticks
  IF islzx(p)
    proglzx := 2         -> lzx extract: arcrunprog reads "( n / total )"
  ELSE
    progbybytes := TRUE  -> lha: arcrunprog reads "...ing: (.../total)"
  ENDIF
  IF total > 1 THEN progshow(total)
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stop = FALSE)
      IF edirs[b + i]
        nm := enames[b + i]
        arcmember(member, arcsub[p], nm)    -> the dir's full stored path
        buildfull(dfile, ppath[q], nm)
        IF pathtype(dfile) = 1
          showmsg('a file with that name is in the way')
        ELSEIF arcextracttree(p, member, stage) = FALSE
          IF abort = FALSE THEN faultmsg('could not extract the folder')
          stop := TRUE
        ELSE
          StrCopy(sfile, stage)
          StrAdd(sfile, '/')
          StrAdd(sfile, member)
          IF copytree(sfile, dfile, 0)
            ndone := ndone + 1
            IF ismove
              -> ONEXIT (both): flag for the commit like Del. DIRECT: remove
              -> now (lzx d deletes dir members; lha uses arcdeltree).
              IF arcwrite
                arcflagdel(p, member, TRUE)
                deferred := TRUE
              ELSEIF islzx(p)
                lzxdeltree(p, member)
                deld := TRUE
              ELSE
                arcdeltree(p, member)
                deld := TRUE
              ENDIF
            ENDIF
          ELSE
            stop := TRUE
          ENDIF
        ENDIF
      ELSE
        nm := enames[b + i]
        arcmember(member, arcsub[p], nm)
        StrCopy(tname, nm)
        buildfull(dfile, ppath[q], tname)
        doit := TRUE
        t := pathtype(dfile)
        IF t > 0
          IF force
            k := "o"
          ELSE
            StringF(mb, '"\s" exists: (s)kip (o)verwrite (r)ename?', tname)
            promptrow(mb)
            k := waitvanilla()
          ENDIF
          IF (k = "o") OR (k = "O")
            IF t = 2
              showmsg('the target exists as a directory')
              doit := FALSE
            ENDIF
          ELSEIF (k = "r") OR (k = "R")
            IF lineinput('new name: ', tname, 30, TRUE) = 0
              drawpaths()
              doit := FALSE
            ELSEIF EstrLen(tname) = 0
              doit := FALSE
            ELSE
              buildfull(dfile, ppath[q], tname)
              IF pathtype(dfile) = 2
                showmsg('that name is a directory')
                doit := FALSE
              ENDIF
            ENDIF
          ELSEIF k = 27
            drawpaths()
            stop := TRUE
            doit := FALSE
          ELSE
            doit := FALSE    -> skip
          ENDIF
        ENDIF
        IF doit
          StrCopy(sfile, stage)
          StrAdd(sfile, '/')
          StrAdd(sfile, member)
          makepath(sfile)
          DeleteFile(sfile)
          StrCopy(mb, stage)
          StrAdd(mb, '/')
          IF islzx(p)
            StringF(cmd, 'lzx x "\s" "\s" "\s"', arcpath[p], member, mb)
          ELSE
            StringF(cmd, 'lha -M x "\s" "\s" "\s"', arcpath[p], member, mb)
          ENDIF
          pfiles[0] := sfile
          psizes[0] := esize[b + i]
          pidx := 0
          pcred := 0
          res := arcpollrun(cmd, pfiles, psizes, 1, {pidx}, {pcred})
          IF res = -1 THEN res := arcrunprog(NIL, cmd)   -> old road
          DeleteFile('T:CFile-out')
          moved := FALSE
          IF abort
            stop := TRUE    -> cancelled: never land the partial extract
          ELSEIF (res = -1) OR (pathtype(sfile) <> 1)
            faultmsg('could not extract from the archive')
            stop := TRUE
          ELSE
            -> same volume by construction: land it with a Rename
            -> (the overwrite decision was already made above)
            IF pathtype(dfile) = 1 THEN DeleteFile(dfile)
            IF Rename(sfile, dfile)
              moved := TRUE
            ELSEIF copyfile(sfile, dfile)
              moved := TRUE    -> odd handler: the copy fallback
            ENDIF
          ENDIF
          IF moved
            ndone := ndone + 1
            IF ismove
              -> ONEXIT (both): defer to commit. DIRECT: remove now.
              IF arcwrite
                arcflagdel(p, member, FALSE)
                deferred := TRUE
              ELSEIF islzx(p)
                lzxdelmember(arcpath[p], member)
                deld := TRUE
              ELSE
                arcdelmember(arcpath[p], member)
                deld := TRUE
              ENDIF
            ENDIF
          ELSE
            stop := TRUE
          ENDIF
          DeleteFile(sfile)
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  cancelok := FALSE
  progoff()
  progbyfile := FALSE
  progbybytes := FALSE
  proglzx := 0
  arcwipe(stage)
  -> DIRECT move dropped members from the on-disk archive: reload the cache.
  -> A deferred (ONEXIT) move only flagged them - refreshall re-filters the
  -> cache and the flags must survive, so it must NOT reload. An abort that
  -> may have broken a DIRECT delete mid-run reloads too: the archive is
  -> whichever side of the rename the break landed on - read the truth.
  IF deld OR (abort AND ismove AND (arcwrite = FALSE))
    loadarchive(p, arcpath[p])
  ENDIF
  refreshall()
  IF abort
    StringF(mb, 'cancelled - \d of \d done', ndone,
            IF nmark > 0 THEN nmark ELSE 1)
    showmsg(mb)
  ELSEIF ndone > 0
    IF deferred
      StringF(mb, '\d file\s moved out (on exit)', ndone,
              IF ndone = 1 THEN '' ELSE 's')
    ELSE
      StringF(mb, '\d file\s \s', ndone, IF ndone = 1 THEN '' ELSE 's',
              IF ismove THEN 'moved out' ELSE 'copied out')
    ENDIF
    showmsg(mb)
  ENDIF
  abort := FALSE    -> clear it so a later internal copy/delete is not aborted
ENDPROC

-> c/m when the OTHER pane is an archive: add the selected file(s) into
-> it at the pane's current location. move = also delete the source.
-> ARCWRITE ONEXIT copy/move-IN: stage the source file(s)/tree into the
-> beside-the-archive tree and flag the members, instead of an lha add
-> per entry. A file over an existing member REPLACEs it (old deleted at
-> commit); a folder stages whole and every member joins the cache so it
-> browses at once. move drops the source only once it is safely staged.
PROC arcxfer_indefer(p, q, ismove, force)
  DEF b, nmark, i, pick, nm:PTR TO CHAR, member[CPATHLEN]:STRING,
      src[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING, stageroot[CPATHLEN]:STRING,
      mb[130]:STRING, k, stop=FALSE, ndone=0, doit, slot,
      st:PTR TO LONG, z:PTR TO LONG
  IF involume(p) OR efail[p] OR (ecount[p] = 0)
    showmsg('nothing to add from this pane')
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  cancelok := TRUE    -> Esc cancels (b21): the staging copies
  abort := FALSE
  arcstage(q, stageroot)
  st := amst[q]
  z := amsz[q]
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stop = FALSE)
      nm := enames[b + i]
      arcmember(member, arcsub[q], nm)
      buildfull(src, ppath[p], nm)
      StrCopy(sfile, stageroot)
      AddPart(sfile, member, CPATHLEN - 4)
      SetStr(sfile, StrLen(sfile))
      makepath(sfile)    -> the member's parent dirs, staging root included
      IF edirs[b + i]
        IF copytree(src, sfile, 0)
          arccacheput(q, member, 0, TRUE)    -> the folder itself
          arccachetree(q, sfile, member, 0)  -> and everything inside it
          ndone := ndone + 1
          IF ismove THEN arcwipe(src)
        ELSE
          IF abort = FALSE THEN faultmsg('could not stage the folder')
          stop := TRUE    -> cancelled: the source tree is never dropped
        ENDIF
      ELSE
        doit := TRUE
        slot := arccacheslot(q, member)
        -> a MST_DEL slot is a member deleted earlier this session: it
        -> looks gone in the pane, so copying over it replaces silently,
        -> no prompt. A live member (committed or pending) does prompt.
        IF (slot >= 0) AND (st[slot] <> MST_DEL)
          IF force
            k := "o"
          ELSE
            StringF(mb, '"\s" is in the archive: (s)kip (o)verwrite?', nm)
            promptrow(mb)
            k := waitvanilla()
          ENDIF
          IF (k = "o") OR (k = "O")
            doit := TRUE
          ELSEIF k = 27
            drawpaths()
            stop := TRUE
            doit := FALSE
          ELSE
            doit := FALSE
          ENDIF
        ENDIF
        IF doit
          IF copyfile(src, sfile)
            IF slot >= 0
              -> replace: a committed member becomes REPLACE (old deleted
              -> at commit); a pending add just re-stages, still an add
              IF st[slot] <> MST_ADD THEN st[slot] := MST_REPLACE
              z[slot] := esize[b + i]
            ELSE
              slot := arcadd(q, member, esize[b + i])
              IF slot >= 0 THEN st[slot] := MST_ADD    -> the fresh slot
            ENDIF
            ndone := ndone + 1
            IF ismove THEN zap(src, FALSE)
          ELSE
            stop := TRUE
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  cancelok := FALSE
  refreshall()
  IF abort
    StringF(mb, 'cancelled - \d of \d done', ndone,
            IF nmark > 0 THEN nmark ELSE 1)
    showmsg(mb)
  ELSEIF ndone > 0
    StringF(mb, '\d file\s \s (on exit)', ndone, IF ndone = 1 THEN '' ELSE 's',
            IF ismove THEN 'moved in' ELSE 'copied in')
    showmsg(mb)
  ENDIF
  abort := FALSE    -> clear it so a later internal copy/delete is not aborted
ENDPROC

PROC arcxfer_in(p, q, ismove, force)
  DEF b, nmark, i, pick, nm:PTR TO CHAR, member[CPATHLEN]:STRING,
      src[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING, topname[CPATHLEN]:STRING,
      cmd[700]:STRING, mb[130]:STRING, res, k, stop=FALSE, ndone=0,
      added=FALSE, doit, replace, total=0
  IF involume(p) OR efail[p] OR (ecount[p] = 0)
    showmsg('nothing to add from this pane')
    RETURN
  ENDIF
  -> ONEXIT (both lha and lzx): defer the add (staged, flagged, committed on
  -> leave). DIRECT: add immediately below.
  IF arcwrite
    arcxfer_indefer(p, q, ismove, force)
    RETURN
  ENDIF
  b := p * MAXENT
  nmark := markcount(p)
  cancelok := TRUE    -> Esc cancels (b21): staging, and the archiver run
  abort := FALSE
  -> pre-scan BYTES: the add bar advances by each added member's size
  statbytes := 0
  statfiles := 0
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      IF edirs[b + i]
        buildfull(src, ppath[p], enames[b + i])
        treestat(src, 0)    -> adds the tree's bytes to statbytes
      ELSE
        statbytes := statbytes + esize[b + i]
      ENDIF
    ENDIF
  ENDFOR
  total := statbytes
  IF abort THEN stop := TRUE    -> Esc already, during the pre-scan
  progbyfile := TRUE
  IF islzx(q)
    proglzx := 1         -> lzx add: arcrunprog reads "Adding (<size>)"
  ELSE
    progbybytes := TRUE
  ENDIF
  IF total > 1 THEN progshow(total)
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stop = FALSE)
      IF edirs[b + i]
        nm := enames[b + i]
        arcmember(member, arcsub[q], nm)
        buildfull(src, ppath[p], nm)
        IF EstrLen(arcsub[q]) = 0
          -> add straight from the source pane: -r stores nm/... at the
          -> archive root, no mirror copy needed
          IF islzx(q)
            StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[q], nm)
          ELSE
            StringF(cmd, 'lha -M -r a "\s" "\s"', arcpath[q], nm)
          ENDIF
          res := arcrunprog(ppath[p], cmd)
        ELSE
          -> mirror the tree under the arcsub prefix, then -r add its top
          arcwipe('T:CFile-a')
          StrCopy(sfile, 'T:CFile-a/')
          StrAdd(sfile, member)
          makepath(sfile)
          IF copytree(src, sfile, 0)
            firstcomp(topname, arcsub[q])
            IF islzx(q)
              StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[q], topname)
            ELSE
              StringF(cmd, 'lha -M -r a "\s" "\s"', arcpath[q], topname)
            ENDIF
            res := arcrunprog('T:CFile-a', cmd)
          ELSE
            res := -1
          ENDIF
        ENDIF
        DeleteFile('T:CFile-out')
        IF (res = -1) OR abort
          IF abort = FALSE THEN faultmsg('could not add the folder')
          stop := TRUE    -> cancelled: the source tree is never dropped
        ELSE
          added := TRUE
          ndone := ndone + 1
          IF ismove THEN arcwipe(src)    -> move: drop the source tree
        ENDIF
      ELSE
        nm := enames[b + i]
        arcmember(member, arcsub[q], nm)
        doit := TRUE
        replace := FALSE
        IF archasmember(q, member)
          IF force
            k := "o"
          ELSE
            StringF(mb, '"\s" is in the archive: (s)kip (o)verwrite?', nm)
            promptrow(mb)
            k := waitvanilla()
          ENDIF
          IF (k = "o") OR (k = "O")
            replace := TRUE    -> the delete waits until the copy is staged
          ELSEIF k = 27
            drawpaths()
            stop := TRUE
            doit := FALSE
          ELSE
            doit := FALSE
          ENDIF
        ENDIF
        IF doit
          arcwipe('T:CFile-a')
          StrCopy(sfile, 'T:CFile-a/')
          StrAdd(sfile, member)
          makepath(sfile)
          buildfull(src, ppath[p], nm)
          IF copyfile(src, sfile)
            IF EstrLen(arcsub[q]) > 0
              firstcomp(topname, arcsub[q])
            ELSE
              StrCopy(topname, nm)
            ENDIF
            -> now the source is safely staged, drop the old member so the
            -> add is not skipped/duplicated as "already present". (Esc
            -> between this delete and the add's finish leaves the member
            -> absent - the source file itself is never at risk.)
            IF replace
              IF islzx(q) THEN lzxdelmember(arcpath[q], member) ELSE arcdelmember(arcpath[q], member)
            ENDIF
            -> -r a from the scratch root: stores the tree-relative path, the
            -> only add form that keeps a subdirectory prefix (lzx -e too, so
            -> an empty subdir in the staged tree is archived)
            IF islzx(q)
              StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[q], topname)
            ELSE
              StringF(cmd, 'lha -M -r a "\s" "\s"', arcpath[q], topname)
            ENDIF
            res := arcrunprog('T:CFile-a', cmd)
            DeleteFile('T:CFile-out')
            IF (res = -1) OR abort
              IF abort = FALSE THEN faultmsg('could not add to the archive')
              stop := TRUE    -> cancelled: the source file survives
            ELSE
              added := TRUE
              ndone := ndone + 1
              IF ismove THEN zap(src, FALSE)
            ENDIF
          ELSE
            stop := TRUE
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  cancelok := FALSE
  progoff()
  progbyfile := FALSE
  progbybytes := FALSE
  proglzx := 0
  arcwipe('T:CFile-a')
  -> abort: the break may have raced the rebuild's finishing rename, so
  -> the archive is whichever side it landed on - re-read the truth
  IF added OR abort THEN loadarchive(q, arcpath[q])
  refreshall()
  IF abort
    StringF(mb, 'cancelled - \d of \d done', ndone,
            IF nmark > 0 THEN nmark ELSE 1)
    showmsg(mb)
  ELSEIF ndone > 0
    StringF(mb, '\d file\s \s', ndone, IF ndone = 1 THEN '' ELSE 's',
            IF ismove THEN 'moved in' ELSE 'copied in')
    showmsg(mb)
  ENDIF
  abort := FALSE    -> clear it so a later internal copy/delete is not aborted
ENDPROC

-> copy or move to the other pane: the marked set if the active pane
-> has marks, the selection otherwise. force = overwrite collisions.
-> Three phases: (1) resolve every collision up front - any refusal
-> or Esc cancels with nothing changed; (2) pre-scan the resolved set
-> for the progress denominator; (3) transfer it all in one go, the
-> bar running uninterrupted.
PROC doxfer(ismove, force)
  DEF p, q, i, b, s, nmark, nsel=0, r, la, lb, samevol=TRUE, ndone=0,
      anydir=FALSE, showbar=FALSE, haderr=FALSE, free, k,
      tname[110]:STRING, tpath[310]:STRING, mb[130]:STRING,
      fb1[12]:STRING, fb2[12]:STRING,
      iname[120]:STRING, itname[120]:STRING, isrc[320]:STRING
  p := active
  q := IF p = 0 THEN 1 ELSE 0
  IF iniso(p)
    isoxfer_out(p, q, ismove, force)    -> copy file(s) out of the image
    RETURN
  ENDIF
  IF iniso(q)
    showmsg('the CD image is read-only')
    RETURN
  ENDIF
  IF inarchive(p)
    arcxfer_out(p, q, ismove, force)    -> extract file(s) to the pane
    RETURN
  ENDIF
  IF inarchive(q)
    arcxfer_in(p, q, ismove, force)     -> add file(s) into the archive
    RETURN
  ENDIF
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
  -> phase 1: resolve the whole set before touching anything (an icon
  -> whose file is also marked is skipped - it travels as the sidecar)
  IF nmark > 0
    FOR i := 0 TO ecount[p] - 1
      IF markednodup(p, b + i)
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
    cancelok := TRUE    -> Esc during the pre-scan or the copy cancels the run
    abort := FALSE
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
    IF abort = FALSE    -> pre-scan not cancelled
      -> free-space check: if the copy won't fit on the target volume, ask
      -> before starting. Conservative - it does not credit space that an
      -> overwrite would free - so the user can always say yes.
      pfreeok[q] := FALSE    -> force a fresh Info() on the target
      free := freebytes(q)
      IF (free >= 0) AND (statbytes > free)
        fmtbytes(fb1, statbytes)
        fmtbytes(fb2, free)
        StringF(mb, 'needs \s, \s free - proceed? (y)es (n)o', fb1, fb2)
        promptrow(mb)
        k := waitvanilla()
        IF (k <> "y") AND (k <> "Y")
          cancelok := FALSE
          drawpaths()
          RETURN
        ENDIF
      ENDIF
      IF anydir OR (nsel > 1) OR (statbytes > 131072) THEN showbar := TRUE
      IF showbar THEN progshow(statbytes)
    ENDIF
  ENDIF
  -> phase 3: transfer, no questions left to ask (Esc stops it)
  FOR s := 0 TO nsel - 1
    IF (haderr = FALSE) AND (abort = FALSE)
      i := ridx[s]
      r := transferone(p, q, enames[b + i], rnames[s],
                       edirs[b + i] <> 0, ismove, samevol)
      IF r < 0 THEN haderr := TRUE
      IF r = 1 THEN ndone := ndone + 1
      -> the icon follows the resolved name (silent, best-effort): its
      -> target overwrites any existing one, the way the file itself did
      IF (haderr = FALSE) AND icons AND (isinfo(enames[b + i]) = FALSE)
        IF sidecarof(ppath[p], enames[b + i], isrc)
          StrCopy(iname, enames[b + i])
          StrAdd(iname, '.info')
          StrCopy(itname, rnames[s])
          StrAdd(itname, '.info')
          transferone(p, q, iname, itname, FALSE, ismove, samevol)
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  cancelok := FALSE
  progoff()
  refreshall()
  IF abort
    StringF(mb, 'cancelled - \d of \d done', ndone, nsel)
    showmsg(mb)
  ELSEIF haderr
    remsg()
  ENDIF
  abort := FALSE    -> clear it so a later internal copy/delete is not aborted
ENDPROC

PROC delone(p, i)
  DEF dpath[310]:STRING, ok, pm[130]:STRING, ipath[320]:STRING, k
  buildfull(dpath, ppath[p], enames[i])
  -> deleting a disk image WE have mounted: let go of it first -
  -> trackfile holds the file while loaded, so the delete could
  -> never succeed (his find, 30.7.26). The other pane inside the
  -> volume still refuses: unmounting under it is the yank hazard.
  k := damfindfile(dpath)
  IF k >= 0
    IF ncprefix(ppath[1 - p], damdev[k], EstrLen(damdev[k]))
      showmsg('that image is mounted - the other pane is inside it')
      gfails := gfails + 1
      RETURN FALSE
    ENDIF
    IF daeject(damdev[k]) = FALSE
      showmsg('that image is mounted and busy - try again in a moment')
      gfails := gfails + 1
      RETURN FALSE
    ENDIF
    SetStr(damdev[k], 0)    -> unmounted: the delete can now proceed
  ENDIF
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
  -> take the icon along (a drawer's icon is a sibling .info as well);
  -> best-effort, so a missing or stubborn icon never fails the delete
  IF ok AND icons AND (isinfo(enames[i]) = FALSE)
    IF sidecarof(ppath[p], enames[i], ipath) THEN zap(ipath, FALSE)
  ENDIF
ENDPROC ok

-> Del/D inside an archive: remove the selected member(s) - a file by
-> its exact name, a folder and everything under it. lha rewrites the
-> archive; the bar ticks per member removed.
PROC arcdelete(p)
  DEF b, nmark, i, pick, k, nm:PTR TO CHAR, member[CPATHLEN]:STRING,
      mb[130]:STRING, total=0, ndel=0, hasdir=FALSE, ok,
      stageroot[CPATHLEN]:STRING
  IF ecount[p] = 0 THEN RETURN
  b := p * MAXENT
  nmark := markcount(p)
  IF nmark > 0
    StringF(mb, 'delete \d marked from the archive? (y)es (n)o', nmark)
  ELSEIF edirs[b + esel[p]]
    StringF(mb, 'delete "\s" and all it holds from the archive? (y)es (n)o',
            enames[b + esel[p]])
  ELSE
    StringF(mb, 'delete "\s" from the archive? (y)es (n)o',
            enames[b + esel[p]])
  ENDIF
  promptrow(mb)
  k := waitvanilla()
  IF (k <> "y") AND (k <> "Y")
    drawpaths()
    RETURN
  ENDIF
  IF arcwrite
    -> ONEXIT (both lha and lzx): flag the members, leave the archive alone.
    -> They drop out of the pane at once (readarcdir hides MST_DEL) and the
    -> one batched delete (lha -Qw d / escaped lzx d) runs at commit, on
    -> leave or quit.
    FOR i := 0 TO ecount[p] - 1
      pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
      IF pick
        arcmember(member, arcsub[p], enames[b + i])
        arcflagdel(p, member, edirs[b + i])
        ndel := ndel + 1
      ENDIF
    ENDFOR
    readpane(p)    -> re-filter the cache; no reload, the flags must live
    drawpaths()
    drawpane(p)
    IF ndel > 0
      StringF(mb, '\d entr\s removed (on exit)', ndel,
              IF ndel = 1 THEN 'y' ELSE 'ies')
      showmsg(mb)
    ENDIF
    RETURN
  ENDIF
  IF islzx(p)
    -> DIRECT lzx: delete now (files by name, folders and all via lzxdeltree
    -> - lzx d removes stored dir members, so no rebuild).
    FOR i := 0 TO ecount[p] - 1
      pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
      IF pick
        arcmember(member, arcsub[p], enames[b + i])
        IF edirs[b + i] THEN lzxdeltree(p, member) ELSE lzxdelmember(arcpath[p], member)
        ndel := ndel + 1
      ENDIF
    ENDFOR
    loadarchive(p, arcpath[p])
    refreshall()
    IF ndel > 0
      StringF(mb, '\d entr\s deleted from the archive', ndel,
              IF ndel = 1 THEN 'y' ELSE 'ies')
      showmsg(mb)
    ENDIF
    RETURN
  ENDIF
  -> DIRECT lha with a directory in the selection: lha d cannot remove a
  -> -lhd- member, so a folder delete takes the rebuild path (extract,
  -> prune, repack) - the same one the deferred commit uses. Files-only
  -> deletes stay on the fast lha d path below.
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND edirs[b + i] THEN hasdir := TRUE
  ENDFOR
  IF hasdir
    FOR i := 0 TO ecount[p] - 1
      pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
      IF pick
        arcmember(member, arcsub[p], enames[b + i])
        arcflagdel(p, member, edirs[b + i])    -> flag, then rebuild at once
        ndel := ndel + 1
      ENDIF
    ENDFOR
    promptrow('writing changes to the archive')
    arcstage(p, stageroot)    -> no staging in DIRECT; rebuild skips overlay
    ok := arcrebuild(p, stageroot)
    loadarchive(p, arcpath[p])    -> reload the rebuilt archive, flags cleared
    refreshall()
    IF ok = FALSE
      showmsg('could not rebuild the archive - nothing deleted')
    ELSEIF ndel > 0
      StringF(mb, '\d entr\s deleted from the archive', ndel,
              IF ndel = 1 THEN 'y' ELSE 'ies')
      showmsg(mb)
    ENDIF
    RETURN
  ENDIF
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      IF edirs[b + i]
        arcmember(member, arcsub[p], enames[b + i])
        total := total + arccountunder(p, member)
      ELSE
        total := total + 1
      ENDIF
    ENDIF
  ENDFOR
  progbyfile := TRUE
  IF total > 1 THEN progshow(total)
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      nm := enames[b + i]
      arcmember(member, arcsub[p], nm)
      IF edirs[b + i]
        arcdeltree(p, member)
      ELSE
        arcdelmember(arcpath[p], member)
      ENDIF
      ndel := ndel + 1
    ENDIF
  ENDFOR
  progoff()
  progbyfile := FALSE
  progbybytes := FALSE
  loadarchive(p, arcpath[p])    -> rebuild the cache without the deleted
  refreshall()
  IF ndel > 0
    StringF(mb, '\d entr\s deleted from the archive', ndel,
            IF ndel = 1 THEN 'y' ELSE 'ies')
    showmsg(mb)
  ENDIF
ENDPROC

-> delete the marked set (one confirmation for the lot) or the
-> selection. Directories go recursively, contents and all.
PROC dodelete()
  DEF p, i, b, k, nmark, showbar=FALSE,
      dpath[310]:STRING, mb[120]:STRING
  p := active
  IF iniso(p)
    showmsg('the CD image is read-only')
    RETURN
  ENDIF
  IF inarchive(p)
    arcdelete(p)
    RETURN
  ENDIF
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
  cancelok := TRUE    -> Esc during the pre-scan or the delete cancels the run
  abort := FALSE
  -> deletes tick per entry, so pre-count the entries
  statbytes := 0
  statfiles := 0
  IF nmark > 0
    FOR i := 0 TO ecount[p] - 1
      IF markednodup(p, b + i)
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
      -> skip an icon whose file is also marked: it goes as that file's
      -> sidecar, so deleting it again would fault on the missing file
      IF markednodup(p, b + i) AND (abort = FALSE)
        delone(p, b + i)
      ENDIF
    ENDFOR
  ELSE
    delone(p, b + esel[p])
  ENDIF
  cancelok := FALSE
  progoff()
  refreshall()
  IF abort
    showmsg('delete cancelled')
  ELSEIF gfails = 1
    -> the stored fault text says which entry and why
    remsg()
  ELSEIF gfails > 1
    StringF(mb, '\d entries not deleted - last: \s', gfails, opmsg)
    showmsg(mb)
  ENDIF
  abort := FALSE    -> clear it so a later internal copy/delete is not aborted
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
      fl[10]:STRING, cmt[84]:STRING, ln[40]:STRING, cbuf[84]:STRING
  p := active
  IF inarchive(p) OR iniso(p)
    showmsg('file info is not available inside an archive yet')
    RETURN
  ENDIF
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
  infline(xx, yy, 6, 'hsparwed=bits c=note Esc=close')
  REPEAT
    flagstr(fl, mask)
    StringF(ln, 'flags: \s', fl)
    infline(xx, yy, 4, ln)
    k := waitvanilla()
    changed := FALSE
    IF k = 27
      done := TRUE
    ELSEIF (k = "c") OR (k = "C")
      -> edit the FileNote comment (the prompt takes the border row; the
      -> box sits below it, so they do not overlap). The field is capped
      -> to what fits the row - the ROM limit is 79, but a narrow screen
      -> takes fewer
      StrCopy(cbuf, cmt)
      r := ncols - 14
      IF r > 79 THEN r := 79
      IF r < 12 THEN r := 12
      IF lineinput('comment: ', cbuf, r, FALSE) = 1
        IF SetComment(fpath, cbuf)
          StrCopy(cmt, cbuf)
        ELSE
          faultmsg('cannot set comment')
        ENDIF
      ENDIF
      IF EstrLen(cmt) > 0
        StringF(ln, 'comment: \s', cmt)
      ELSE
        StrCopy(ln, 'comment: -')
      ENDIF
      infline(xx, yy, 5, ln)
      drawpaths()    -> wipe the input prompt from the border row
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
-> classify a buffer's leading bytes (<=512 examined). Factored out of
-> sniff so a caller that already read the file (grepwalk) can type it
-> without a second Open (I5).
PROC sniffmem(buf:PTR TO CHAR, n)
  DEF i, c, m, pr=0, esc=FALSE
  IF n > 512 THEN n := 512
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

PROC sniff(path)
  DEF fh, buf[520]:ARRAY OF CHAR, n
  -> ISO images first: their head is boot code or zeros (worthless to
  -> sniffmem), the truth lives at sector 16. Suffix-gated so plain
  -> files never pay the extra open.
  IF isoext(path)
    IF isomagic(path) THEN RETURN TY_ISO
  ENDIF
  -> ADF images: suffix + exactly a floppy's size (the only images
  -> trackfile mounts; the DOS/NDOS verdict is enteradf's to give)
  IF adfext(path)
    n := arcsizeof(path)
    IF (n = ADFDD) OR (n = ADFHD) THEN RETURN TY_ADF
  ENDIF
  IF (fh := Open(path, OLDFILE)) = NIL THEN RETURN TY_OTHER
  n := Read(fh, buf, 512)
  Close(fh)
ENDPROC sniffmem(buf, n)

-> render one text line (tabs to 8-column stops, controls as dots)
-> into a 78-column row buffer; returns the offset after the line
-> R3 (stage b6): colp receives the populated width (clamped to
-> ncols) so the caller can Text the prefix and RectFill the tail
PROC textrow(buf, len, off, rb, colp:PTR TO LONG)
  DEF col=0, c, r:PTR TO CHAR, s:PTR TO CHAR
  r := rb
  s := buf
  colp[0] := 0
  WHILE off < len
    c := s[off]
    off := off + 1
    IF c = 10
      colp[0] := IF col > ncols THEN ncols ELSE col
      RETURN off                 -> line done
    ENDIF
    IF c = 9
      REPEAT
        IF col < ncols THEN r[col] := 32
        col := col + 1
      UNTIL (col AND 7) = 0    -> X2: Mod is DIVS - a divide per tab
                               -> column, and unclamped col overflows it
    ELSEIF (c >= 32) AND ((c <= 126) OR (c >= 160))
      IF col < ncols THEN r[col] := c
      col := col + 1
    ELSEIF c <> 13
      IF col < ncols THEN r[col] := "."
      col := col + 1
    ENDIF
  ENDWHILE
  colp[0] := IF col > ncols THEN ncols ELSE col
ENDPROC off

-> offset of the line start before 'off' (scan back over the buffer)
PROC prevline(buf, off)
  DEF s:PTR TO CHAR, o
  s := buf
  o := off - 2    -> step over the LF that ends the previous line
  WHILE o >= 0    -> X3: nested, not AND - the eager AND read s[-1]
    IF s[o] = 10 THEN RETURN o + 1
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
-> R3 (stage b6): one viewer row - build, Text the populated
-> prefix, RectFill the tail (the space-pad Text of a full ncols is
-> gone). Returns the NEXT offset in text mode; hex advances by 16
-> at the caller. A row at/past EOF blanks and returns off as-is.
PROC viewrow(buf, len, off, mode, r)
  DEF rb[204]:ARRAY OF CHAR, i, w=0, y, n
  FOR i := 0 TO ncols - 1
    rb[i] := 32                  -> hexrow leaves gaps; prefill stays
  ENDFOR
  IF off < len
    IF mode = 1
      hexrow(buf, len, off, rb)
      n := len - off
      IF n > 16 THEN n := 16
      w := 58 + n
      IF w > ncols THEN w := ncols
    ELSE
      off := textrow(buf, len, off, rb, {w})
    ENDIF
  ENDIF
  y := panetop + (r * ch)
  -> R6 coda 2 (his hunt for instant): viewer rows never change in
  -> place, and every row they land on is ALREADY background - the
  -> entry scrub, the masked page fill before a full redraw, or a
  -> blit-vacated row. So: JAM1 (glyphs only, no per-cell background
  -> rendering), one plane, and NO tail fill at all. A first page is
  -> one full-depth scrub + 22 glyph-only one-plane Texts.
  IF w > 0
    rp.mask := flatmask
    SetDrMd(rp, RP_JAM1)
    SetAPen(rp, txtpen)
    Move(rp, x0, y + baseline)
    Text(rp, rb, w)
    SetDrMd(rp, RP_JAM2)
    rp.mask := 255
  ENDIF
ENDPROC off

-> the byte offset of the row `steps` text lines below `off`
PROC textskip(bp:PTR TO CHAR, len, off, steps)
  DEF o2
  o2 := off
  WHILE steps > 0
    WHILE (o2 < len) AND (bp[o2] <> 10)
      o2 := o2 + 1
    ENDWHILE
    IF o2 < len THEN o2 := o2 + 1
    steps := steps - 1
  ENDWHILE
ENDPROC o2

PROC viewfile(path, name, mode, bulk)
  DEF buf=NIL, bp:PTR TO CHAR, len, size, fh, top2=0, r, off, o2,
      class, code, qual, done=FALSE, dirty=TRUE, res2=0,
      mb[120]:STRING, mn:PTR TO CHAR, i, otop, d1, u1,
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
    IF (buf := New(size + 1)) = NIL    -> X3: the line scans and the
                                       -> ANSI parser peek one past len
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
  -> R6 coda (stage b8, his find: the first page visibly filled top
  -> to bottom at authentic speed): ONE full-depth entry scrub - it
  -> erases the previous surface's planes in a single blit, and it
  -> is what makes the MASKED row rendering below safe (the ccon
  -> narrowing rule: scrub unmasked, then narrow)
  SetAPen(rp, 0)
  RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
           panetop + Mul(visrows, ch) - 1)
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
        -> draw the page (R3 + R6 coda 2): ONE masked background
        -> fill for the whole area (plane 0 is the only plane with
        -> content since the entry scrub), then glyph-only rows
        rp.mask := flatmask
        SetAPen(rp, 0)
        RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
                 panetop + Mul(visrows, ch) - 1)
        rp.mask := 255
        off := top2
        FOR r := 0 TO visrows - 1
          IF mode = 1
            viewrow(buf, len, off, 1, r)
            off := off + 16
          ELSE
            off := viewrow(buf, len, off, 0, r)
          ENDIF
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
    otop := top2                 -> R3: for the one-row blit below
    IF (mode <> 2) AND (pgd <> 0)
      -> his find (b16): the Ctrl jumps used to WALK the step loops
      -> below - a full-file line scan just to reach an offset both
      -> ends already know. Jump straight: top is 0, bottom is vmax
      -> (computed at load). The +-30000 sentinels only come from
      -> the Ctrl arms; pages are visrows-sized and keep stepping.
      IF pgd <= -30000
        top2 := 0
        pgd := 0
      ELSEIF pgd >= 30000
        top2 := vmax
        pgd := 0
      ENDIF
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
      IF o2 <= vmax THEN top2 := o2
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
      ELSE
        pgd := 0
      ENDIF
      pgd := pgd + 1
      IF pgd > 0 THEN pgd := 0
    ENDWHILE
    IF (mode <> 2) AND (top2 <> otop) AND (done = FALSE)
      -> R3 (stage b6): a move of exactly one row is a blit + ONE
      -> viewrow; anything else repaints the page
      IF mode = 1
        d1 := otop + 16
        u1 := otop - 16
        IF u1 < 0 THEN u1 := 0
      ELSE
        d1 := textskip(bp, len, otop, 1)
        u1 := IF otop > 0 THEN prevline(buf, otop) ELSE 0
      ENDIF
      IF top2 = d1
        scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), 1, flatmask)
        IF mode = 1
          viewrow(buf, len, top2 + Mul(16, visrows - 1), 1, visrows - 1)
        ELSE
          viewrow(buf, len, textskip(bp, len, top2, visrows - 1), 0,
                  visrows - 1)
        ENDIF
      ELSEIF top2 = u1
        scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), -1, flatmask)
        viewrow(buf, len, top2, mode, 0)
      ELSE
        dirty := TRUE
      ENDIF
    ENDIF
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

-> the few verbs that still have no meaning inside an archive (pack,
-> unpack, shell) land here; c/m/r/n/Del/e and viewing all work inside
PROC arcreadonly()
  showmsg('that verb does not work inside an archive')
ENDPROC

-> create every directory along `path` up to (not including) the last
-> component. Each level is made in turn - CreateDir needs the parent
-> to exist already - and a device/assign root (ending ":") is skipped.
PROC makepath(path)
  DEF s:PTR TO CHAR, i, l, seg[CPATHLEN]:STRING, sl, lock
  s := path
  l := StrLen(path)
  FOR i := 0 TO l - 1
    IF s[i] = "/"
      StrCopy(seg, path, i)
      sl := StrLen(seg)
      IF sl > 0
        IF seg[sl - 1] <> ":"
          IF lock := CreateDir(seg) THEN UnLock(lock)
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
ENDPROC

-> view one member: extract it to a T: scratch dir (with its stored
-> path, so lha's own matching does the work), view by sniffed type,
-> then drop the temp. Read-only: an 'e' in the viewer does nothing.
PROC arcviewsel(p, sel)
  DEF nm:PTR TO CHAR, member[CPATHLEN]:STRING, cmd[700]:STRING,
      out[CPATHLEN]:STRING, res, ty
  nm := enames[(p * MAXENT) + sel]
  StrCopy(member, arcsub[p])
  IF EstrLen(member) > 0 THEN StrAdd(member, '/')
  StrAdd(member, nm)
  StrCopy(out, 'T:CFile-v/')
  StrAdd(out, member)
  -> make T:CFile-v AND every subdirectory the member sits in. lha,
  -> fed NIL: for input, cannot create a missing output directory (it
  -> would prompt), so a member in a subdir failed with "unable to open
  -> output file". Pre-building the path lets lha just write the file.
  makepath(out)
  DeleteFile(out)           -> no stale target to prompt an overwrite
  -> lha -M: no autoshow (LhA auto-DISPLAYS readme/.doc files via a con:
  -> "Press return" window that stalls under redirected I/O). lzx has no
  -> such thing and -M there means merge-groups, so lzx just uses `x`.
  IF arcfmt[p] = TY_LZX
    StringF(cmd, 'lzx x "\s" "\s" "\s"', arcpath[p], member, 'T:CFile-v/')
  ELSE
    StringF(cmd, 'lha -M x "\s" "\s" "\s"', arcpath[p], member, 'T:CFile-v/')
  ENDIF
  res := runcapture(NIL, cmd, 'T:CFile-out')
  DeleteFile('T:CFile-out')
  IF (res = -1) OR (pathtype(out) <> 1)
    showmsg('could not extract that file')
    RETURN
  ENDIF
  ty := sniff(out)
  IF ty = TY_ANSI
    viewfile(out, nm, 2, FALSE)
  ELSEIF ty = TY_TEXT
    IF viewfile(out, nm, 0, FALSE) = 1
      -> 'e' in the viewer: edit this member in place (arcedit works on
      -> the same selection, re-extracting into its own scratch)
      DeleteFile(out)
      arcedit(p)
      RETURN
    ENDIF
  ELSE
    viewfile(out, nm, 1, FALSE)
  ENDIF
  DeleteFile(out)
ENDPROC

-> view a file straight out of an ISO image: pulled into T:CFile-v
-> (the arcviewsel scratch), sniffed, viewed, deleted. The size gate
-> comes FIRST - a file the viewer would refuse anyway is never
-> extracted at all (T: is RAM on most systems).
PROC isoviewsel(p, sel)
  DEF nm:PTR TO CHAR, i, out[CPATHLEN]:STRING, fh, ty
  i := (p * MAXENT) + sel
  nm := enames[i]
  IF esize[i] > VIEWMAX
    showmsg('file too large to view (512KB cap for now)')
    RETURN
  ENDIF
  StrCopy(out, 'T:CFile-v/')
  StrAdd(out, nm)
  makepath(out)
  DeleteFile(out)
  IF (fh := Open(isopath[p], OLDFILE)) = NIL
    showmsg('cannot open the image file')
    RETURN
  ENDIF
  IF isoextract(fh, eext[i], esize[i], out, FALSE) = FALSE
    Close(fh)
    showmsg('could not read that file from the image')
    RETURN
  ENDIF
  Close(fh)
  ty := sniff(out)
  IF ty = TY_ANSI
    viewfile(out, nm, 2, FALSE)
  ELSEIF ty = TY_TEXT
    IF viewfile(out, nm, 0, FALSE) = 1
      showmsg('the CD image is read-only')    -> 'e' in the viewer
    ENDIF
  ELSE
    viewfile(out, nm, 1, FALSE)
  ENDIF
  DeleteFile(out)
ENDPROC

PROC doview()
  DEF p, i, ty, fpath[310]:STRING, cmd[680]:STRING
  p := active
  IF involume(p)
    showmsg('nothing to view in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  IF inarchive(p)
    i := (p * MAXENT) + esel[p]
    IF edirs[i] THEN showmsg('cannot view a directory') ELSE arcviewsel(p, esel[p])
    RETURN
  ENDIF
  IF iniso(p)
    i := (p * MAXENT) + esel[p]
    IF edirs[i] THEN showmsg('cannot view a directory') ELSE isoviewsel(p, esel[p])
    RETURN
  ENDIF
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
  ELSEIF ty = TY_ISO
    showmsg('a CD image: Enter goes inside')
  ELSEIF ty = TY_ADF
    showmsg('a disk image: Enter mounts and goes inside')
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
  DEF idx, s:PTR TO CHAR, l, vis=0, erb[204]:ARRAY OF CHAR,
      cc[4]:ARRAY OF CHAR, y
  idx := edvtop + r
  y := panetop + (r * ch)
  IF idx < ednum
    s := edl[idx]
    l := EstrLen(edl[idx])
    vis := l - edxoff
    IF vis > ncols THEN vis := ncols
    IF vis < 0 THEN vis := 0
    IF vis > 0 THEN CopyMem(s + edxoff, erb, vis)
  ENDIF
  -> R4 (stage b6): populated prefix + ONE tail fill - the full-width
  -> space-padded Text (and its ncols prefill loop) is gone.
  -> R6 coda: masked - editfile's entry fill is the unmasked scrub
  rp.mask := flatmask
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  IF vis > 0
    Move(rp, x0, y + baseline)
    Text(rp, erb, vis)
  ENDIF
  IF vis < ncols
    SetAPen(rp, 0)
    RectFill(rp, x0 + Mul(vis, cw), y, x0 + Mul(ncols, cw) - 1, y + ch - 1)
    SetAPen(rp, txtpen)
  ENDIF
  IF idx = edcur
    cc[0] := IF (edcol - edxoff) < vis THEN erb[edcol - edxoff] ELSE 32
    SetAPen(rp, 0)
    SetBPen(rp, txtpen)
    Move(rp, x0 + ((edcol - edxoff) * cw), y + baseline)
    Text(rp, cc, 1)
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
  ENDIF
  rp.mask := 255
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

-> make sure line `idx` can hold `need` characters, growing its buffer
-> (allocate a bigger String, copy the content over, swap it in) when the
-> current one is too small. Doubling keeps a run of inserts from
-> reallocating on every keystroke. FALSE only when the bigger String
-> could not be allocated - the caller then leaves the line unchanged.
-> The copy uses the line's current EstrLen, so callers must keep that in
-> step with the content (edload SetStr's per character while filling).
PROC edgrow(idx, need)
  DEF cur:PTR TO CHAR, ns, mx
  cur := edl[idx]
  mx := StrMax(cur)
  IF mx >= need THEN RETURN TRUE
  IF mx < EDLINIT THEN mx := EDLINIT
  REPEAT
    mx := mx + mx
  UNTIL mx >= need
  IF (ns := String(mx)) = NIL THEN RETURN FALSE
  StrCopy(ns, cur)
  DisposeLink(cur)
  edl[idx] := ns
ENDPROC TRUE

-> insert one character at the cursor (no redraw; caller batches). Grows
-> the line if it is full; FALSE only on an allocation failure.
PROC edinsch(c)
  DEF s:PTR TO CHAR, l, i
  l := EstrLen(edl[edcur])
  IF edgrow(edcur, l + 1) = FALSE THEN RETURN FALSE
  s := edl[edcur]    -> re-fetch: edgrow may have moved the buffer
  FOR i := l TO edcol + 1 STEP -1
    s[i] := s[i - 1]
  ENDFOR
  s[edcol] := c
  SetStr(edl[edcur], l + 1)
  edcol := edcol + 1
ENDPROC TRUE

-> load for editing: LF splits, CR dropped, tabs to spaces (8-stops).
-> Lines grow to any length; only the line COUNT (8192) and whole-file
-> size (512KB) are capped. -1 = failed (message shown).
PROC edload(path)
  DEF fh, buf=NIL, n, size=-1, i, c, col, s, ok=TRUE, le, k, rs,
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
  IF (s := String(EDLINIT)) = NIL THEN ok := FALSE
  IF ok
    edl[0] := s
    ednum := 1
    i := 0
    -> C2 (stage b4): line-at-a-time. The old loop paid an edgrow
    -> CALL and a SetStr CALL per CHARACTER - the whole cost of
    -> opening a big file at stock CPU. Now per line: find the end,
    -> MEASURE the final width (tabs to 8-stops, CRs dropped), ONE
    -> edgrow, CopyMem the clean runs between tabs/CRs, ONE SetStr.
    -> Same output byte-for-byte, harness-proven (b4test.e: tabs,
    -> CRLF, no trailing LF, empty file, empty lines, tab-at-eol).
    WHILE (i <= n) AND ok
      le := i                        -> the line spans [i, le)
      WHILE (le < n) AND (bp[le] <> 10)
        le := le + 1
      ENDWHILE
      col := 0                       -> measuring pass
      k := i
      WHILE k < le
        c := bp[k]
        IF c = 9
          col := (col OR 7) + 1      -> next 8-stop (X2: no DIVS)
        ELSEIF c <> 13
          col := col + 1             -> CRs dropped: Amiga text is LF
        ENDIF
        k := k + 1
      ENDWHILE
      IF edgrow(ednum - 1, col) = FALSE
        showmsg('not enough memory')
        ok := FALSE
      ELSE
        ln := edl[ednum - 1]         -> filling pass
        col := 0
        rs := i
        k := i
        WHILE k <= le
          c := IF k < le THEN bp[k] ELSE 10   -> sentinel: flush at end
          IF (c = 9) OR (c = 13) OR (k = le)
            IF k > rs
              CopyMem(bp + rs, ln + col, k - rs)
              col := col + (k - rs)
            ENDIF
            IF c = 9
              REPEAT
                ln[col] := 32
                col := col + 1
              UNTIL (col AND 7) = 0
            ENDIF
            rs := k + 1
          ENDIF
          k := k + 1
        ENDWHILE
        SetStr(edl[ednum - 1], col)
      ENDIF
      IF ok
        IF le < n                    -> the LF opens the next line
          IF ednum >= EDMAXL
            showmsg('too many lines to edit (8192 cap)')
            ok := FALSE
          ELSEIF (s := String(EDLINIT)) = NIL
            showmsg('not enough memory')
            ok := FALSE
          ELSE
            edl[ednum] := s
            ednum := ednum + 1
          ENDIF
        ENDIF
      ENDIF
      i := le + 1
    ENDWHILE
  ENDIF
  IF buf THEN Dispose(buf)
  IF ok = FALSE THEN edfree()
ENDPROC ok

-> I2: a save used to be TWO Write packets per line - 4000 synchronous
-> round trips for a 2000-line file, ~1.2s even on the PiStorm (packet
-> count is the whole cost; no CPU makes round trips free). Lines are
-> now assembled into copybuf and flushed in cbufsz chunks - two-ish
-> packets per save. Byte-identical output harness-proven (b2test.e:
-> exact-fit, one-over, giant-line, empty-line).
PROC edsave(path)
  DEF fh, i, ok=TRUE, used=0, l, wb:PTR TO CHAR
  IF samefile(path, 'PROGDIR:cfile.config') THEN wantreload := TRUE
  IF (fh := Open(path, NEWFILE)) = NIL
    faultmsg('cannot save')
    RETURN FALSE
  ENDIF
  wb := copybuf    -> free: edsave and copyfile are never concurrent
  FOR i := 0 TO ednum - 1
    IF ok
      l := EstrLen(edl[i])
      IF (used + l + 1) > cbufsz
        IF used > 0
          IF Write(fh, wb, used) < used THEN ok := FALSE
          used := 0
        ENDIF
      ENDIF
      IF ok
        IF (l + 1) > cbufsz
          -> a line longer than the whole buffer: write it direct
          IF Write(fh, edl[i], l) < l THEN ok := FALSE
          IF ok
            IF Write(fh, '\n', 1) < 1 THEN ok := FALSE
          ENDIF
        ELSE
          CopyMem(edl[i], wb + used, l)
          used := used + l
          wb[used] := 10
          used := used + 1
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  IF ok
    IF used > 0
      IF Write(fh, wb, used) < used THEN ok := FALSE
    ENDIF
  ENDIF
  Close(fh)
  IF ok = FALSE THEN faultmsg('write failed')
ENDPROC ok

-> the editor itself. Returns -1 = could not load (message shown),
-> 0 = left without saving, 1 = saved.
PROC editfile(path, name)
  DEF class, code, qual, done2=FALSE, saved=0, k, i, l, r, nl,
      s:PTR TO CHAR, ovtop, oxoff, ocr, cr
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
          l := EstrLen(edl[edcur]) - edcol    -> the tail after the cursor
          IF l < EDLINIT THEN l := EDLINIT
          IF (nl := String(l)) <> NIL
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
            -> R4 (stage b6): the split shifts only the rows BELOW -
            -> blit them down one and draw the two changed rows;
            -> bottom-edge splits blit the whole page up instead;
            -> any horizontal shift keeps the full repaint
            ocr := edcur - 1 - edvtop
            ovtop := edvtop
            oxoff := edxoff
            IF edfix()
              IF (edxoff = oxoff) AND (edvtop = (ovtop + 1))
                scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), 1, flatmask)
                IF visrows > 1 THEN edrow(visrows - 2)
                edrow(visrows - 1)
              ELSE
                edpage()
              ENDIF
            ELSE
              IF (ocr + 1) < visrows
                scrollone(x0, panetop + Mul(ocr + 1, ch), Mul(ncols, cw),
                          Mul(visrows - ocr - 1, ch), -1, flatmask)
              ENDIF
              edrow(ocr)
              IF (ocr + 1) < visrows THEN edrow(ocr + 1)
            ENDIF
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
          -> join with the line above, growing it to hold both
          l := EstrLen(edl[edcur - 1])
          IF edgrow(edcur - 1, l + EstrLen(edl[edcur]))
            edcol := l
            StrAdd(edl[edcur - 1], edl[edcur])
            DisposeLink(edl[edcur])
            FOR i := edcur TO ednum - 2
              edl[i] := edl[i + 1]
            ENDFOR
            ednum := ednum - 1
            edcur := edcur - 1
            edtouch(name)
            oxoff := edxoff
            IF edfix()
              edpage()
            ELSE
              -> R4: the join pulls the rows below UP one - blit them
              -> and draw the joined row + the revealed bottom row
              cr := edcur - edvtop
              IF (cr + 1) < visrows
                scrollone(x0, panetop + Mul(cr + 1, ch), Mul(ncols, cw),
                          Mul(visrows - cr - 1, ch), 1, flatmask)
              ENDIF
              edrow(cr)
              IF visrows > 1 THEN edrow(visrows - 1)
            ENDIF
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
          IF edgrow(edcur, l + EstrLen(edl[edcur + 1]))
            StrAdd(edl[edcur], edl[edcur + 1])
            DisposeLink(edl[edcur + 1])
            FOR i := edcur + 1 TO ednum - 2
              edl[i] := edl[i + 1]
            ENDFOR
            ednum := ednum - 1
            edtouch(name)
            IF edfix()
              edpage()
            ELSE
              cr := edcur - edvtop    -> R4: same shape as the
              IF (cr + 1) < visrows   -> backspace-join above
                scrollone(x0, panetop + Mul(cr + 1, ch), Mul(ncols, cw),
                          Mul(visrows - cr - 1, ch), 1, flatmask)
              ENDIF
              edrow(cr)
              IF visrows > 1 THEN edrow(visrows - 1)
            ENDIF
          ENDIF
        ENDIF
      ELSEIF code = 9    -> tab: spaces to the next 8-stop (grows the line)
        REPEAT
          r := edinsch(32)
        UNTIL (r = FALSE) OR ((edcol AND 7) = 0)    -> X2: no DIVS
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
        ovtop := edvtop
        oxoff := edxoff
        IF edfix()
          -> R4 (stage b6): a vertical edge cross is one blit + two
          -> rows; horizontal shifts move every row and repaint
          IF (edxoff = oxoff) AND (edvtop = (ovtop + 1))
            scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), 1, flatmask)
            IF visrows > 1 THEN edrow(visrows - 2)
            edrow(visrows - 1)
          ELSEIF (edxoff = oxoff) AND (edvtop = (ovtop - 1))
            scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), -1, flatmask)
            edrow(0)
            IF visrows > 1 THEN edrow(1)
          ELSE
            edpage()
          ENDIF
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
-> re-add an edited member from a scratch root, replacing what is there.
-> LhA's 'a' skips an existing member, so the old one is dropped first,
-> then -r a from the scratch (which holds only this member's tree).
-> Returns the add result; -1 means the caller should keep the scratch
-> so the edit is not lost.
PROC arcreadd(p, scratchroot, member)
  DEF topname[CPATHLEN]:STRING, cmd[700]:STRING, res
  firstcomp(topname, member)    -> member's first path component
  IF islzx(p)
    lzxdelmember(arcpath[p], member)
    StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[p], topname)
  ELSE
    arcdelmember(arcpath[p], member)
    StringF(cmd, 'lha -M -r a "\s" "\s"', arcpath[p], topname)
  ENDIF
  res := runcapture(scratchroot, cmd, 'T:CFile-out')
  DeleteFile('T:CFile-out')
ENDPROC res

-> e inside an archive: extract the selected member, edit it, and on
-> save re-add it in place. Text (or empty) members only, like the
-> normal editor. A failed re-add keeps the edit in T:CFile-x.
-> ARCWRITE ONEXIT edit: pull the member into the staging tree (or edit
-> the staged copy in place if it is a pending add/replace already), and
-> on save flag it REPLACE - the commit deletes the old member and adds
-> the edited staged copy. A pending add stays an add.
PROC arceditdefer(p, i, nm, member)
  DEF stageroot[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING, xdir[CPATHLEN]:STRING,
      cmd[700]:STRING, ty, r, res, slot, st:PTR TO LONG, z:PTR TO LONG,
      sz=0, lock, fib:PTR TO fileinfoblock, wasstaged
  arcstage(p, stageroot)
  StrCopy(sfile, stageroot)
  AddPart(sfile, member, CPATHLEN - 4)
  SetStr(sfile, StrLen(sfile))
  slot := arccacheslot(p, member)
  wasstaged := pathtype(sfile) = 1    -> already in the tree this session
  IF wasstaged = FALSE
    makepath(sfile)
    DeleteFile(sfile)
    StrCopy(xdir, stageroot)
    StrAdd(xdir, '/')
    IF islzx(p)
      StringF(cmd, 'lzx x "\s" "\s" "\s"', arcpath[p], member, xdir)
    ELSE
      StringF(cmd, 'lha -M x "\s" "\s" "\s"', arcpath[p], member, xdir)
    ENDIF
    res := runcapture(NIL, cmd, 'T:CFile-out')
    DeleteFile('T:CFile-out')
    IF (res = -1) OR (pathtype(sfile) <> 1)
      DeleteFile(sfile)
      faultmsg('could not extract for edit')
      RETURN
    ENDIF
  ENDIF
  ty := sniff(sfile)
  IF (ty <> TY_TEXT) AND (esize[i] <> 0)
    IF wasstaged = FALSE THEN DeleteFile(sfile)
    showmsg('only text files can be edited')
    RETURN
  ENDIF
  drawpaths()
  r := editfile(sfile, nm)
  IF r = 1
    IF lock := Lock(sfile, SHARED_LOCK)
      IF fib := AllocDosObject(DOS_FIB, NIL)
        IF Examine(lock, fib) THEN sz := fib.size
        FreeDosObject(DOS_FIB, fib)
      ENDIF
      UnLock(lock)
    ENDIF
    st := amst[p]
    z := amsz[p]
    IF slot >= 0
      IF st[slot] <> MST_ADD THEN st[slot] := MST_REPLACE
      z[slot] := sz
    ENDIF
    StrCopy(prevname, nm)
    -> a FULL redraw, not just drawpane: the editor painted over the whole
    -> frame (both panes and the view border), so the two-pane view has to
    -> be rebuilt or the editor's leftovers linger until the next redraw
    refreshsel(p)    -> R5: one draw, cursor pre-placed
  ELSE
    -> not saved: drop a fresh extract, keep a pre-staged edit untouched
    IF wasstaged = FALSE THEN DeleteFile(sfile)
    drawall()
  ENDIF
ENDPROC

PROC arcedit(p)
  DEF i, nm:PTR TO CHAR, member[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING,
      ty, r, res
  IF ecount[p] = 0 THEN RETURN
  i := (p * MAXENT) + esel[p]
  IF edirs[i]
    showmsg('cannot edit a directory')
    RETURN
  ENDIF
  nm := enames[i]
  arcmember(member, arcsub[p], nm)
  -> ONEXIT (both): defer the edit (staged, flagged REPLACE, committed on
  -> leave). DIRECT: re-add immediately through arcextractone/arcreadd.
  IF arcwrite
    arceditdefer(p, i, nm, member)
    RETURN
  ENDIF
  arcwipe('T:CFile-x')
  IF arcextractone(p, member) = FALSE
    arcwipe('T:CFile-x')
    faultmsg('could not extract for edit')
    RETURN
  ENDIF
  StrCopy(sfile, 'T:CFile-x/')
  StrAdd(sfile, member)
  ty := sniff(sfile)
  IF (ty <> TY_TEXT) AND (esize[i] <> 0)
    arcwipe('T:CFile-x')
    showmsg('only text files can be edited')
    RETURN
  ENDIF
  drawpaths()
  r := editfile(sfile, nm)
  IF r = 1
    res := arcreadd(p, 'T:CFile-x', member)
    IF res = -1
      loadarchive(p, arcpath[p])
      refreshall()
      showmsg('edit could not be re-added - kept in T:CFile-x')
    ELSE
      arcwipe('T:CFile-x')
      loadarchive(p, arcpath[p])
      StrCopy(prevname, nm)
      refreshsel(p)    -> R5: one draw, cursor pre-placed
    ENDIF
  ELSE
    arcwipe('T:CFile-x')
    drawall()
  ENDIF
ENDPROC

PROC doedit()
  DEF p, i, ty, r, fpath[310]:STRING
  p := active
  IF iniso(p)
    showmsg('the CD image is read-only - v views')
    RETURN
  ENDIF
  IF inarchive(p)
    arcedit(p)
    RETURN
  ENDIF
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
    rp.mask := flatmask         -> R6: the direct path's blit masks too
    ScrollRaster(rp, 0, ch, x0, panetop,
                 x0 + Mul(ncols, cw) - 1, panetop + Mul(visrows, ch) - 1)
    rp.mask := 255
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

-> R2 (0.4.1 stage b7): one console row from the MODEL - populated
-> prefix + one tail fill (trailing spaces never Text)
PROC conrow(mr, r)
  DEF m:PTR TO CHAR, w, y
  m := cmodel + Mul(mr, ncols)
  w := ncols
  WHILE (w > 0) AND (m[w - 1] = 32)
    w := w - 1
  ENDWHILE
  y := panetop + (r * ch)
  rp.mask := flatmask           -> R6 coda: livestart's entry fill
  SetAPen(rp, txtpen)           -> is the unmasked scrub
  SetBPen(rp, 0)
  IF w > 0
    Move(rp, x0, y + baseline)
    Text(rp, m, w)
  ENDIF
  IF w < ncols
    SetAPen(rp, 0)
    RectFill(rp, x0 + Mul(w, cw), y, x0 + Mul(ncols, cw) - 1, y + ch - 1)
    SetAPen(rp, txtpen)
  ENDIF
  rp.mask := 255
ENDPROC

-> R2: model-only newline - screen catch-up is the caller's settle
PROC cmnl(pendp:PTR TO LONG)
  DEF m:PTR TO CHAR, j
  ccol := 0
  IF crow < (visrows - 1)
    crow := crow + 1
  ELSE
    pendp[0] := pendp[0] + 1
  ENDIF
  cmrow := cmrow + 1    -> the caller's cap guard guarantees room
  m := cmodel + Mul(cmrow, ncols)
  FOR j := 0 TO ncols - 1
    m[j] := 32
  ENDFOR
ENDPROC

-> feed raw command output to the area. R2 (stage b7): MODEL-FIRST -
-> the whole chunk lands in cmodel while pending scrolls and a dirty
-> row range accumulate, then the screen settles ONCE per call: a
-> screenful+ of scrolls rebuilds the grid from the model (zero
-> blits - a full pack's spew costs repaints, not 34ms blits per
-> LF), anything less is ONE ScrollRaster of `pend` rows + the dirty
-> rows repainted. The CCON architecture, ported. Printable runs, LF,
-> CR (in-place progress counters), tabs, 80-col wrap, and the CSI
-> C/K pair lha uses all keep their exact old semantics - the parser
-> below IS the old one with draws turned into model writes. A NIL
-> model (allocation failed) or a full one (the CMAXL cap - the old
-> churn-the-last-line corner) hands the bytes to confeeddirect, the
-> old renderer kept verbatim.
PROC confeed(buf, n)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit, m:PTR TO CHAR,
      pend=0, dlo, dhi, r0, r, mr
  IF (cmodel = NIL) OR cmfull
    confeeddirect(buf, n)
    RETURN
  ENDIF
  s := buf
  dlo := cmrow + CMAXL    -> empty range
  dhi := -1
  WHILE (i < n) AND (cmfull = FALSE)
    IF cmrow >= (CMAXL - 1)
      cmfull := TRUE    -> on the last model row: settle what is
    ELSE                -> done, the direct path takes the rest
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
            m := cmodel + Mul(cmrow, ncols)
            FOR j := ccol TO ncols - 1
              m[j] := 32
            ENDFOR
            IF cmrow < dlo THEN dlo := cmrow
            IF cmrow > dhi THEN dhi := cmrow
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
        cmnl({pend})
        i := i + 1
      ELSEIF c = 13
        ccol := 0
        i := i + 1
      ELSEIF c = 9
        m := cmodel + Mul(cmrow, ncols)
        REPEAT
          m[ccol] := 32
          ccol := ccol + 1
        UNTIL ((ccol AND 7) = 0) OR (ccol >= ncols)    -> X2: no DIVS
        IF cmrow < dlo THEN dlo := cmrow
        IF cmrow > dhi THEN dhi := cmrow
        IF ccol >= 80 THEN cmnl({pend})
        i := i + 1
      ELSEIF c >= 32
        j := i
        WHILE (j < n) AND (s[j] >= 32) AND (s[j] <> 127) AND (s[j] <> $9B)
          j := j + 1
        ENDWHILE
        run := j - i
        WHILE (run > 0) AND (cmrow < (CMAXL - 1))
          IF ccol >= ncols THEN cmnl({pend})
          fit := ncols - ccol
          IF fit > run THEN fit := run
          CopyMem(s + i, cmodel + Mul(cmrow, ncols) + ccol, fit)
          IF cmrow < dlo THEN dlo := cmrow
          IF cmrow > dhi THEN dhi := cmrow
          ccol := ccol + fit
          i := i + fit
          run := run - fit
        ENDWHILE
      ELSE
        i := i + 1
      ENDIF
    ENDIF
  ENDWHILE
  -> the settle: screen catches up in one step
  r0 := cmrow - crow    -> the model row on screen row 0
  IF pend >= visrows
    FOR r := 0 TO visrows - 1
      conrow(r0 + r, r)
    ENDFOR
  ELSE
    IF pend > 0
      scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), pend,
                flatmask)    -> R6: dy rows in ONE masked blit
    ENDIF
    IF dhi >= dlo
      mr := dlo
      IF mr < r0 THEN mr := r0
      WHILE mr <= dhi
        conrow(mr, mr - r0)
        mr := mr + 1
      ENDWHILE
    ENDIF
  ENDIF
  IF i < n THEN confeeddirect(buf + i, n - i)    -> the cap corner
ENDPROC

-> the pre-R2 renderer, kept verbatim: serves a NIL model and the
-> post-cap churn corner (screen scrolls, last model line rewrites)
PROC confeeddirect(buf, n)
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
      UNTIL ((ccol AND 7) = 0) OR (ccol >= ncols)    -> X2: no DIVS
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
  cmfull := FALSE
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
      buf:PTR TO CHAR, n, s:PTR TO CHAR
  buf := pipebuf    -> I7a: 4KB shared pipe buffer, not 256B on the stack
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
    n := Read(rdr, buf, PIPESZ)
    WHILE n > 0
      confeed(buf, n)
      n := Read(rdr, buf, PIPESZ)
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

-> jump pane p to `path`: "" = the volume list; otherwise the path must lock
-> and be a directory, canonicalised via NameFromLock (device -> volume name,
-> no trailing slash) so Left/parentdir walks it afterwards. Returns TRUE on
-> the jump, FALSE (with a message) if the path is gone or is not a directory.
-> Shared by go-to (typed) and a bookmark jump (stored).
PROC gotopath(p, path)
  DEF lock, fib:PTR TO fileinfoblock, isdir=FALSE, canon[CPATHLEN]:STRING
  IF EstrLen(path) = 0
    SetStr(ppath[p], 0)    -> the volume list
  ELSE
    IF (lock := Lock(path, SHARED_LOCK)) = NIL
      faultmsg('cannot go there')
      RETURN FALSE
    ENDIF
    IF fib := AllocDosObject(DOS_FIB, NIL)
      IF Examine(lock, fib) THEN isdir := fib.direntrytype > 0
      FreeDosObject(DOS_FIB, fib)
    ENDIF
    IF isdir = FALSE
      UnLock(lock)
      showmsg('that is not a directory')
      RETURN FALSE
    ENDIF
    IF NameFromLock(lock, canon, CPATHLEN - 2) = 0 THEN StrCopy(canon, path)
    UnLock(lock)
    StrCopy(ppath[p], canon)
  ENDIF
  esel[p] := 0
  etop[p] := 0
  readpane(p)
  drawpaths()
  drawpane(p)
ENDPROC TRUE

-> g - type a path and jump the active pane straight there. Not available
-> inside an archive (Left out first).
PROC dogoto()
  DEF p, mx, buf[CPATHLEN]:STRING
  p := active
  IF inarchive(p) OR iniso(p)
    showmsg('leave the archive first (Left), then go to a path')
    RETURN
  ENDIF
  -> field width fits the border row (the "go to: " prompt + the guillemets)
  mx := ncols - 16
  IF mx < 20 THEN mx := 20
  IF mx > (CPATHLEN - 2) THEN mx := CPATHLEN - 2
  -> prefill with the current path when it fits, so a subdir is a quick edit
  IF involume(p) OR (EstrLen(ppath[p]) > mx)
    StrCopy(buf, '')
  ELSE
    StrCopy(buf, ppath[p])
  ENDIF
  IF lineinput('go to: ', buf, mx, FALSE) = 0
    drawpaths()
    RETURN
  ENDIF
  IF EstrLen(buf) = 0
    drawpaths()
    RETURN
  ENDIF
  gotopath(p, buf)
ENDPROC

-> store the active pane's location in bookmark slot `d` (0-9). Real
-> directories and the volume list only, not a spot inside an archive.
PROC bookmarkset(d)
  DEF mb[80]:STRING
  StrCopy(bmark[d], ppath[active])    -> "" = the volume list
  bmarkset[d] := 1
  StringF(mb, 'bookmark \d set: \s', d,
          IF EstrLen(ppath[active]) = 0 THEN '(volumes)' ELSE ppath[active])
  showmsg(mb)
ENDPROC

-> b: set a bookmark. Press b, then a digit 0-9 to store this location in
-> that slot (a plain two-key sequence - no modifier for the WM, FS-UAE or
-> the keymap to swallow). Any other key cancels. Jump with the bare digit.
PROC dobookmark()
  DEF k
  IF inarchive(active) OR iniso(active) OR (damunder(active) >= 0)
    showmsg('cannot bookmark a spot inside an archive or disk image')
    RETURN
  ENDIF
  promptrow('bookmark this location as? (0-9)')
  k := waitvanilla()
  IF (k >= "0") AND (k <= "9")
    bookmarkset(k - "0")
  ELSE
    drawpaths()    -> any other key cancels
  ENDIF
ENDPROC

-> one page of a results list: visrows rows from `vtop`, the selected one
-> inverted. tail TRUE = a long row shows its END (find-file: the filename);
-> FALSE = its START (content search: the path:line prefix).
-> one row of the results page (R7/R8, stage b6: single fill per
-> row, and the scroll path below draws rows alone)
PROC findrow(res:PTR TO LONG, cnt, vtop, sel, tail, r)
  DEF ln, s:PTR TO CHAR, l, y, ww
  ww := ncols
  y := panetop + (r * ch)
  ln := vtop + r
  IF ln >= cnt
    SetAPen(rp, 0)
    RectFill(rp, x0, y, x0 + Mul(ww, cw) - 1, y + ch - 1)
    RETURN
  ENDIF
  s := res[ln]
  l := StrLen(s)
  IF l > ww
    IF tail THEN s := s + (l - ww)    -> tail: show the end; else the start
    l := ww
  ENDIF
  IF ln = sel
    SetAPen(rp, txtpen)
    RectFill(rp, x0, y, x0 + Mul(ww, cw) - 1, y + ch - 1)
    SetAPen(rp, 0)
    SetBPen(rp, txtpen)
  ELSE
    SetAPen(rp, 0)
    RectFill(rp, x0, y, x0 + Mul(ww, cw) - 1, y + ch - 1)
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
  ENDIF
  Move(rp, x0, y + baseline)
  Text(rp, s, l)
  SetBPen(rp, 0)
ENDPROC

PROC drawfindpage(res:PTR TO LONG, cnt, vtop, sel, tail)
  DEF r
  FOR r := 0 TO visrows - 1
    findrow(res, cnt, vtop, sel, tail, r)
  ENDFOR
ENDPROC

-> show a results list as a selectable, scrollable page; Up/Down move
-> (Shift = page, Ctrl = ends), Enter picks (returns the index), Esc = -1.
-> tail controls the long-row truncation direction (see drawfindpage).
PROC findlist(res:PTR TO LONG, cnt, tail, verb)
  DEF sel=0, vtop=0, ns, class, code, qual, done=FALSE, pick=-1, hb[130]:STRING,
      osel, ovtop
  drawviewframe(TRUE)
  StringF(hb, '\d match\s - Up/Down, Enter \s, Esc cancels', cnt,
          IF cnt = 1 THEN '' ELSE 'es', verb)
  promptrow(hb)
  drawfindpage(res, cnt, vtop, sel, tail)
  WHILE done = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    qual := MsgQualifier()
    ns := sel
    IF class = IDCMP_VANILLAKEY
      IF code = 27
        done := TRUE
      ELSEIF code = 13
        pick := sel
        done := TRUE
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80
        IF code = RK_UP
          IF qual AND IEQUALIFIER_CONTROL
            ns := 0
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            ns := sel - (visrows - 1)
          ELSE
            ns := sel - 1
          ENDIF
        ELSEIF code = RK_DOWN
          IF qual AND IEQUALIFIER_CONTROL
            ns := cnt - 1
          ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            ns := sel + (visrows - 1)
          ELSE
            ns := sel + 1
          ENDIF
        ENDIF
      ENDIF
    ENDIF
    IF ns > (cnt - 1) THEN ns := cnt - 1
    IF ns < 0 THEN ns := 0
    IF (ns <> sel) AND (done = FALSE)
      -> R7 (stage b6): the pane's rule - sel-only move = two rows,
      -> vtop +-1 = one blit + two rows, jumps keep the full page
      osel := sel
      ovtop := vtop
      sel := ns
      IF sel < vtop THEN vtop := sel
      IF sel >= (vtop + visrows) THEN vtop := sel - visrows + 1
      IF vtop = ovtop
        findrow(res, cnt, vtop, sel, tail, osel - vtop)
        findrow(res, cnt, vtop, sel, tail, sel - vtop)
      ELSEIF vtop = (ovtop + 1)
        scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), 1, flatmask)
        IF visrows > 1 THEN findrow(res, cnt, vtop, sel, tail, visrows - 2)
        findrow(res, cnt, vtop, sel, tail, visrows - 1)
      ELSEIF vtop = (ovtop - 1)
        scrollone(x0, panetop, Mul(ncols, cw), Mul(visrows, ch), -1, flatmask)
        findrow(res, cnt, vtop, sel, tail, 0)
        IF visrows > 1 THEN findrow(res, cnt, vtop, sel, tail, 1)
      ELSE
        drawfindpage(res, cnt, vtop, sel, tail)
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC pick

-> f: recursive name search from the active pane's directory. Type a name
-> fragment; matching files and dirs are listed (case-insensitive substring)
-> and Enter jumps the pane to the chosen one. Esc during the search stops
-> it (partial results still shown). Real directories only.
PROC dofind()
  DEF p, res:PTR TO LONG, cnt=0, i, j=0, c, pat[42]:STRING, glob[90]:STRING,
      parsed=NIL:PTR TO CHAR, isglob=FALSE, pick, pp:PTR TO CHAR,
      hit[CPATHLEN]:STRING, dir[CPATHLEN]:STRING, nm[120]:STRING
  p := active
  IF inarchive(p) OR iniso(p)
    showmsg('find works in real directories - Left out of the archive')
    RETURN
  ENDIF
  IF involume(p)
    showmsg('enter a volume first, then find')
    RETURN
  ENDIF
  IF efail[p] THEN RETURN
  StrCopy(pat, '')
  IF lineinput('find (name or #?): ', pat, 40, FALSE) = 0
    drawpaths()
    RETURN
  ENDIF
  IF EstrLen(pat) = 0
    drawpaths()
    RETURN
  ENDIF
  IF (res := New(FINDMAX * 4)) = NIL
    showmsg('not enough memory to search')
    RETURN
  ENDIF
  -> a metachar means glob the whole name (Unix * -> AmigaDOS #?); plain
  -> text stays a case-insensitive substring
  IF hasmeta(pat)
    FOR i := 0 TO EstrLen(pat) - 1
      c := pat[i]
      IF c = "*"
        glob[j++] := "#"
        glob[j++] := "?"
      ELSE
        glob[j++] := c
      ENDIF
    ENDFOR
    glob[j] := 0
    SetStr(glob, j)
    IF (parsed := New(300))
      IF ParsePatternNoCase(glob, parsed, 300) >= 0 THEN isglob := TRUE
    ENDIF
  ENDIF
  showmsg('searching - Esc to stop')
  cancelok := TRUE
  abort := FALSE
  findwalk(ppath[p], 0, pat, parsed, isglob, res, {cnt})
  cancelok := FALSE
  abort := FALSE
  IF parsed THEN Dispose(parsed)
  IF cnt = 0
    Dispose(res)
    showmsg('nothing found')
    RETURN
  ENDIF
  pick := findlist(res, cnt, TRUE, 'jumps')    -> tail: show the filename end
  IF pick >= 0 THEN StrCopy(hit, res[pick])
  FOR i := 0 TO cnt - 1
    IF res[i] THEN DisposeLink(res[i])
  ENDFOR
  Dispose(res)
  drawall()
  IF pick >= 0
    -> split the match into its parent dir + name, jump there, land on it
    pp := PathPart(hit)
    StrCopy(dir, hit, pp - hit)
    StrCopy(nm, FilePart(hit))
    IF gotopath(p, dir)
      StrCopy(prevname, nm)
      selectbyname(p)
    ENDIF
  ENDIF
ENDPROC

-> recursively grep every TEXT file under `dir` for `needle` (case-insensitive
-> substring, per line). Each matching line records a full path in paths[] and
-> a "relpath:line: text" display string in disp[], up to FINDMAX. `root` is
-> the search start, trimmed off for the display. scanbuf (VIEWMAX) holds one
-> file at a time. Cancellable; heap path buffers.
PROC grepwalk(dir, depth, needle, root, scanbuf:PTR TO CHAR,
              paths:PTR TO LONG, disp:PTR TO LONG, cnt:PTR TO LONG)
  DEF lock=NIL, child=NIL, full=NIL,
      fh, n, i, ls, lineno, ty, e, sp, s, s2, rel:PTR TO CHAR, rl,
      ltxt[210]:STRING, dstr[400]:STRING,
      np:PTR TO CHAR, fn[44]:ARRAY OF CHAR, nl, j, c, c2, hit, le,
      es[1]:ARRAY OF eascan, sc:PTR TO eascan, ed:PTR TO exalldata
  IF depth > 20 THEN RETURN
  -> I5: fold the needle once per level; the scan below case-folds the
  -> buffer inline instead of copying every line out first
  np := needle
  nl := StrLen(np)
  IF nl > 40 THEN nl := 40
  FOR i := 0 TO nl - 1
    c := np[i]
    IF (c >= "a") AND (c <= "z") THEN c := c - 32
    fn[i] := c
  ENDFOR
  IF cnt[0] >= FINDMAX THEN RETURN
  IF checkabort() THEN RETURN
  child := String(CPATHLEN)
  full := String(CPATHLEN)
  IF (child = NIL) OR (full = NIL)
    IF child THEN DisposeLink(child)
    IF full THEN DisposeLink(full)
    RETURN
  ENDIF
  IF lock := Lock(dir, SHARED_LOCK)
    sc := es                    -> I3 (stage b3+): batched walk
    easbegin(sc, lock)
    ed := easnext(sc)
    WHILE (ed <> NIL) AND (cnt[0] < FINDMAX) AND (checkabort() = FALSE)
      StrCopy(full, dir)
      AddPart(full, ed.name, CPATHLEN - 4)
      SetStr(full, StrLen(full))
      IF ed.type > 0
        StrCopy(child, full)
        grepwalk(child, depth + 1, needle, root, scanbuf, paths, disp, cnt)
      ELSEIF (ed.size > 0) AND (ed.size <= VIEWMAX)
          -> I5: ONE read serves both the type sniff and the scan (the
          -> old path opened every candidate twice), and the scan runs
          -> over the raw buffer with a folded first-char skip - no
          -> per-line StrCopy/StrLen. Harness-proven against the old
          -> loop (b2test.e); two deliberate differences: a match past
          -> column 200 is now FOUND (display still truncates), and the
          -> old phantom DUPLICATE hit for a matching final line with a
          -> trailing LF is gone (it double-counted every such file).
          IF fh := Open(full, OLDFILE)
            n := Read(fh, scanbuf, VIEWMAX)
            Close(fh)
            IF n < 0 THEN n := 0
            ty := sniffmem(scanbuf, n)
            IF (ty = TY_TEXT) OR (ty = TY_ANSI)
              ls := 0
              lineno := 1
              i := 0
              WHILE (i < n) AND (cnt[0] < FINDMAX)
                c := scanbuf[i]
                IF c = 10
                  lineno := lineno + 1
                  ls := i + 1
                  i := i + 1
                ELSE
                  IF (c >= "a") AND (c <= "z") THEN c := c - 32
                  hit := FALSE
                  IF c = fn[0]
                    IF (i + nl) <= n
                      hit := TRUE
                      j := 1
                      WHILE (j < nl) AND hit
                        c2 := scanbuf[i + j]
                        IF (c2 >= "a") AND (c2 <= "z") THEN c2 := c2 - 32
                        IF c2 <> fn[j] THEN hit := FALSE
                        j := j + 1
                      ENDWHILE
                    ENDIF
                  ENDIF
                  IF hit
                    -> one record per line: capture it, then skip to
                    -> the line's end (the LF reruns the counters)
                    le := i
                    WHILE (le < n) AND (scanbuf[le] <> 10)
                      le := le + 1    -> scanbuf[n] read is safe: X3 +1
                    ENDWHILE
                    e := le - ls
                    IF e > 200 THEN e := 200
                    StrCopy(ltxt, IF e > 0 THEN scanbuf + ls ELSE '', e)
                    sp := EstrLen(ltxt)
                    IF (sp > 0) AND (ltxt[sp - 1] = 13) THEN SetStr(ltxt, sp - 1)
                    -> display the path relative to the search root
                    rel := full
                    rl := StrLen(root)
                    IF (StrLen(full) > rl) AND ncprefix(full, root, rl)
                      rel := full + rl
                      IF rel[0] = "/" THEN rel := rel + 1
                    ENDIF
                    StringF(dstr, '\s:\d: \s', rel, lineno, ltxt)
                    s := String(EstrLen(dstr) + 1)
                    s2 := String(EstrLen(full) + 1)
                    IF s AND s2
                      StrCopy(s, dstr)
                      StrCopy(s2, full)
                      disp[cnt[0]] := s
                      paths[cnt[0]] := s2
                      cnt[0] := cnt[0] + 1
                    ELSE
                      IF s THEN DisposeLink(s)
                      IF s2 THEN DisposeLink(s2)
                    ENDIF
                    i := le
                  ELSE
                    i := i + 1
                  ENDIF
                ENDIF
              ENDWHILE
            ENDIF
          ENDIF
        ENDIF
      ed := easnext(sc)
    ENDWHILE
    easend(sc)
    UnLock(lock)
  ENDIF
  DisposeLink(child)
  DisposeLink(full)
ENDPROC

-> t: recursive text search - grep every text file under the active pane's
-> directory for a substring; the matching lines list as "relpath:line: text"
-> and Enter opens the file in the viewer. Esc during the search stops it.
PROC docontent()
  DEF p, paths:PTR TO LONG, disp:PTR TO LONG, scanbuf=NIL:PTR TO CHAR, cnt=0,
      i, ty, needle[42]:STRING, pick, hit[CPATHLEN]:STRING, nm[120]:STRING
  p := active
  IF inarchive(p) OR iniso(p)
    showmsg('text search works in real directories - Left out first')
    RETURN
  ENDIF
  IF involume(p)
    showmsg('enter a volume first, then search')
    RETURN
  ENDIF
  IF efail[p] THEN RETURN
  StrCopy(needle, '')
  IF lineinput('search files for: ', needle, 40, FALSE) = 0
    drawpaths()
    RETURN
  ENDIF
  IF EstrLen(needle) = 0
    drawpaths()
    RETURN
  ENDIF
  paths := New(FINDMAX * 4)
  disp := New(FINDMAX * 4)
  scanbuf := New(VIEWMAX + 1)    -> X3: the scan peeks scanbuf[n]
  IF (paths = NIL) OR (disp = NIL) OR (scanbuf = NIL)
    IF paths THEN Dispose(paths)
    IF disp THEN Dispose(disp)
    IF scanbuf THEN Dispose(scanbuf)
    showmsg('not enough memory to search')
    RETURN
  ENDIF
  showmsg('searching text - Esc to stop')
  cancelok := TRUE
  abort := FALSE
  grepwalk(ppath[p], 0, needle, ppath[p], scanbuf, paths, disp, {cnt})
  cancelok := FALSE
  abort := FALSE
  Dispose(scanbuf)
  IF cnt = 0
    Dispose(paths)
    Dispose(disp)
    showmsg('no matches')
    RETURN
  ENDIF
  pick := findlist(disp, cnt, FALSE, 'opens')    -> show the line start
  IF pick >= 0 THEN StrCopy(hit, paths[pick])
  FOR i := 0 TO cnt - 1
    IF paths[i] THEN DisposeLink(paths[i])
    IF disp[i] THEN DisposeLink(disp[i])
  ENDFOR
  Dispose(paths)
  Dispose(disp)
  drawall()
  IF pick >= 0
    StrCopy(nm, FilePart(hit))
    ty := sniff(hit)
    IF ty = TY_ANSI
      viewfile(hit, nm, 2, FALSE)
    ELSE
      IF viewfile(hit, nm, 0, FALSE) = 1    -> 'e' in the viewer: edit it
        IF editfile(hit, nm) = 1 THEN refreshall() ELSE drawall()
      ENDIF
    ENDIF
  ENDIF
ENDPROC

-> a bare digit: jump the active pane to slot `d`. Not inside an archive.
PROC bookmarkjump(d)
  DEF p, mb[40]:STRING
  p := active
  IF inarchive(p) OR iniso(p)
    showmsg('leave the archive first (Left), then jump')
    RETURN
  ENDIF
  IF bmarkset[d] = 0
    StringF(mb, 'bookmark \d is empty', d)
    showmsg(mb)
    RETURN
  ENDIF
  gotopath(p, bmark[d])    -> shows its own error if the path is gone
ENDPROC

-> : - a shell command line, run in the active pane's directory
PROC docommand()
  DEF cmd[140]:STRING
  IF inarchive(active) OR iniso(active)
    showmsg('shell commands do not run inside an archive - Left exits')
    RETURN
  ENDIF
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
  IF iniso(p) OR iniso(q)
    showmsg('this works in real directories - Left out of the image first')
    RETURN
  ENDIF
  IF inarchive(p) OR inarchive(q)
    arcreadonly()
    RETURN
  ENDIF
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
      hdr[130]:STRING, s:PTR TO CHAR, l, tyc=NIL:PTR TO CHAR
  p := active
  q := IF p = 0 THEN 1 ELSE 0
  IF iniso(p) OR iniso(q)
    showmsg('this works in real directories - Left out of the image first')
    RETURN
  ENDIF
  IF inarchive(p) OR inarchive(q)
    arcreadonly()
    RETURN
  ENDIF
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
  -> I5: remember each pre-scan sniff so the action loop below doesn't
  -> open every file a second time (NIL cache = degrade to re-sniffing)
  tyc := New(ecount[p])
  -> pre-scan: is there anything unpackable in the set?
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick
      IF edirs[b + i] = 0
        buildfull(fpath, ppath[p], enames[b + i])
        ty := sniff(fpath)
        IF tyc THEN tyc[i] := ty
        IF (ty = TY_LHA) OR (ty = TY_LZX) OR (ty = TY_ZIP)
          narc := narc + 1
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  IF narc = 0
    IF tyc THEN Dispose(tyc)
    tyc := NIL
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
        IF tyc
          ty := tyc[i]
        ELSE
          ty := sniff(fpath)    -> cache alloc failed: sniff again
        ENDIF
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
  IF tyc THEN Dispose(tyc)
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
  IF inarchive(p)    -> a member file: view it (read-only)
    arcviewsel(p, esel[p])
    RETURN
  ENDIF
  IF iniso(p)        -> an image file: view it (read-only)
    isoviewsel(p, esel[p])
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
  ELSEIF (ty = TY_LHA) OR (ty = TY_LZX)
    enterarchive(p, fpath, ty)    -> Enter goes inside, like Right
  ELSEIF ty = TY_ISO
    enteriso(p, fpath)            -> Enter goes inside, like Right
  ELSEIF ty = TY_ADF
    enteradf(p, fpath)            -> Enter mounts and goes inside
  ELSEIF ty = TY_ZIP
    showmsg('zip: u unpacks it to the other pane, v lists it')
  ELSE
    viewfile(fpath, enames[i], 1, FALSE)
  ENDIF
ENDPROC

-> rebuild the active pane's visible listing from the saved full one,
-> keeping only the entries whose name contains `filt`. The name buffers
-> are only reordered (pointers), never freed, so the saved arrays can
-> put everything back on exit. Selection jumps to the first match.
PROC filterapply(p, snames:PTR TO LONG, sdirs:PTR TO CHAR, ssize:PTR TO LONG,
                 smark:PTR TO CHAR, sdate:PTR TO LONG, sext:PTR TO LONG,
                 fsrc:PTR TO LONG, fullcount, filt:PTR TO CHAR)
  DEF b, i, j=0
  b := p * MAXENT
  FOR i := 0 TO fullcount - 1
    IF nchas(snames[i], filt)
      -> restore saved entry i into the compacted visible slot j (all six
      -> fields, so the date column stays in step with the name)
      unsnapentry(i, snames, sdirs, ssize, sdate, smark, sext, b, j)
      fsrc[j] := i    -> which saved entry this visible row came from
      j++
    ENDIF
  ENDFOR
  ecount[p] := j
  esel[p] := 0
  etop[p] := 0
ENDPROC

-> the / live filter: type to narrow the active pane to matching names,
-> Up/Down walk the matches, Enter keeps the cursor on the highlighted one
-> in the restored full listing, Esc restores it where it was. Every key
-> is filter text, so no hotkey fires while filtering. The full listing is
-> snapshotted and put back untouched - marks and order survive.
PROC dofilter()
  DEF p, b, i, fullcount, origsel, esc=FALSE, done=FALSE, class, code, l,
      snames=NIL:PTR TO LONG, ssize=NIL:PTR TO LONG, sdate=NIL:PTR TO LONG,
      sdirs=NIL:PTR TO CHAR, smark=NIL:PTR TO CHAR, fsrc=NIL:PTR TO LONG,
      sext=NIL:PTR TO LONG,
      filt[42]:STRING, keepname[110]:STRING
  p := active
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  b := p * MAXENT
  fullcount := ecount[p]
  origsel := esel[p]
  snames := New(MAXENT * 4)
  ssize := New(MAXENT * 4)
  sdate := New(MAXENT * 4)
  sdirs := New(MAXENT)
  smark := New(MAXENT)
  fsrc := New(MAXENT * 4)
  sext := New(MAXENT * 4)
  IF (snames = NIL) OR (ssize = NIL) OR (sdate = NIL) OR (sdirs = NIL) OR
     (smark = NIL) OR (fsrc = NIL) OR (sext = NIL)
    IF snames THEN Dispose(snames)
    IF ssize THEN Dispose(ssize)
    IF sdate THEN Dispose(sdate)
    IF sdirs THEN Dispose(sdirs)
    IF smark THEN Dispose(smark)
    IF fsrc THEN Dispose(fsrc)
    IF sext THEN Dispose(sext)
    RETURN
  ENDIF
  FOR i := 0 TO fullcount - 1
    snapentry(i, snames, sdirs, ssize, sdate, smark, sext, b, i)
    fsrc[i] := i    -> identity until the first filter compacts the view
  ENDFOR
  StrCopy(filt, '')
  promptrow('')    -> dress the border row once; drawinput fills it
  drawinput('/', filt, 0, 40)
  WHILE done = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      IF code = 13
        IF ecount[p] > 0 THEN StrCopy(keepname, enames[b + esel[p]])
        done := TRUE
      ELSEIF code = 27
        esc := TRUE
        done := TRUE
      ELSEIF code = 32
        -> Space marks the highlighted match rather than typing a space -
        -> filter-then-mark is the point. The mark is written back to the
        -> saved set so it survives re-filtering and the restore on exit.
        IF ecount[p] > 0
          i := b + esel[p]
          emark[i] := IF emark[i] THEN 0 ELSE 1
          smark[fsrc[esel[p]]] := emark[i]
          IF esel[p] < (ecount[p] - 1)
            movedown()
          ELSE
            drawrow(p, esel[p] - etop[p])
          ENDIF
          drawinput('/', filt, EstrLen(filt), 40)
        ENDIF
      ELSEIF code = 8
        l := EstrLen(filt)
        IF l > 0
          SetStr(filt, l - 1)
          filterapply(p, snames, sdirs, ssize, smark, sdate, sext, fsrc, fullcount, filt)
          drawpane(p)
          drawinput('/', filt, EstrLen(filt), 40)
        ENDIF
      ELSEIF (code > 32) AND (code <= 255)
        l := EstrLen(filt)
        IF l < 40
          filt[l] := code
          SetStr(filt, l + 1)
          filterapply(p, snames, sdirs, ssize, smark, sdate, sext, fsrc, fullcount, filt)
          drawpane(p)
          drawinput('/', filt, EstrLen(filt), 40)
        ENDIF
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80
        IF code = RK_UP
          IF MsgQualifier() AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            pagemove(-(visrows - 1))
          ELSE
            moveup()
          ENDIF
          drawinput('/', filt, EstrLen(filt), 40)
        ELSEIF code = RK_DOWN
          IF MsgQualifier() AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
            pagemove(visrows - 1)
          ELSE
            movedown()
          ENDIF
          drawinput('/', filt, EstrLen(filt), 40)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  -> restore the full listing exactly as it was
  FOR i := 0 TO fullcount - 1
    unsnapentry(i, snames, sdirs, ssize, sdate, smark, sext, b, i)
  ENDFOR
  ecount[p] := fullcount
  Dispose(snames)
  Dispose(ssize)
  Dispose(sdate)
  Dispose(sdirs)
  Dispose(smark)
  Dispose(fsrc)
  Dispose(sext)
  drawpaths()    -> clear the filter prompt from the border row
  IF esc OR (EstrLen(keepname) = 0)
    esel[p] := origsel
    etop[p] := origsel - (visrows / 2)
    IF etop[p] > (fullcount - visrows) THEN etop[p] := fullcount - visrows
    IF etop[p] < 0 THEN etop[p] := 0
    drawpane(p)
  ELSE
    StrCopy(prevname, keepname)
    selectbyname(p)    -> lands the cursor on the match, centred, redraws
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
  drawfield(p)   -> R8 (stage b5): only the count/bytes SLOT changes -
ENDPROC          -> the full paths row ran markcount TWICE per keypress

-> a: mark every entry, A: mark none - a fast bulk set/clear. The border
-> row's marked count and total redraw with it.
PROC markall(p, val)
  DEF b, i
  IF involume(p) THEN RETURN
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  b := p * MAXENT
  FOR i := 0 TO ecount[p] - 1
    emark[b + i] := val
  ENDFOR
  drawpane(p)
  drawpaths()
ENDPROC

-> *: flip every mark - the marked set becomes the unmarked set
PROC markinvert(p)
  DEF b, i
  IF involume(p) THEN RETURN
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  b := p * MAXENT
  FOR i := 0 TO ecount[p] - 1
    emark[b + i] := IF emark[b + i] THEN 0 ELSE 1
  ENDFOR
  drawpane(p)
  drawpaths()
ENDPROC

-> +: mark every entry whose name matches a pattern, added to whatever
-> is already marked. Both AmigaDOS (#?.mod) and Unix-style globs (*.mod)
-> work - a typed '*' is translated to '#?' before parsing, so a keyboard
-> without '#' can still glob and the syntax is the familiar one either
-> way. '?' already means one character in both. Matching is case-
-> insensitive and whole-name, the way the shell matches.
PROC markpattern(p)
  DEF b, i, j=0, c, pat[44]:STRING, glob[90]:STRING, parsed:PTR TO CHAR,
      n=0, mb[80]:STRING
  IF involume(p) THEN RETURN
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  StrCopy(pat, '')
  IF lineinput('mark pattern: ', pat, 42, FALSE) = 0
    drawpaths()
    RETURN
  ENDIF
  IF EstrLen(pat) = 0
    drawpaths()
    RETURN
  ENDIF
  -> translate a Unix '*' to AmigaDOS '#?' (each '*' becomes two chars)
  FOR i := 0 TO EstrLen(pat) - 1
    c := pat[i]
    IF c = "*"
      glob[j++] := "#"
      glob[j++] := "?"
    ELSE
      glob[j++] := c
    ENDIF
  ENDFOR
  glob[j] := 0
  SetStr(glob, j)
  -> ParsePatternNoCase wants up to 2x the source plus slop
  IF (parsed := New(200)) = NIL THEN RETURN
  IF ParsePatternNoCase(glob, parsed, 200) >= 0
    b := p * MAXENT
    FOR i := 0 TO ecount[p] - 1
      IF MatchPatternNoCase(parsed, enames[b + i])
        emark[b + i] := 1
        n++
      ENDIF
    ENDFOR
  ENDIF
  Dispose(parsed)
  drawpane(p)
  drawpaths()
  StringF(mb, '\d entr\s matched', n, IF n = 1 THEN 'y' ELSE 'ies')
  showmsg(mb)
ENDPROC

-> re-sort a pane's existing listing in place (no re-read) under the
-> current mode, keeping the cursor on the same entry and its scroll sane
PROC resortpane(p)
  DEF b, i, selname[110]:STRING
  IF ecount[p] < 1 THEN RETURN
  b := p * MAXENT
  StrCopy(selname, enames[b + esel[p]])
  sortpane(p)
  esel[p] := 0
  FOR i := 0 TO ecount[p] - 1
    IF nccmp(enames[b + i], selname) = 0 THEN esel[p] := i
  ENDFOR
  etop[p] := esel[p] - (visrows / 2)
  IF etop[p] > (ecount[p] - visrows) THEN etop[p] := ecount[p] - visrows
  IF etop[p] < 0 THEN etop[p] := 0
ENDPROC

-> s: pick the sort mode. One key sets it - (n)ame, (s)ize, (d)ate - or
-> (r)everse toggles the direction; the setting is global and both panes
-> re-sort in place at once (dirs always stay ahead of files).
PROC dosort()
  DEF k, mb[70]:STRING, nm
  promptrow('sort: (n)ame  (s)ize  (d)ate  (r)everse')
  k := waitvanilla()
  IF k = "n"
    sortmode := 0
  ELSEIF k = "s"
    sortmode := 1
  ELSEIF k = "d"
    sortmode := 2
  ELSEIF (k = "r") OR (k = "R")
    sortrev := IF sortrev THEN FALSE ELSE TRUE
  ELSE
    drawpaths()
    RETURN
  ENDIF
  resortpane(0)
  resortpane(1)
  drawall()
  nm := IF sortmode = 0 THEN 'name' ELSE (IF sortmode = 1 THEN 'size' ELSE 'date')
  StringF(mb, 'sorted by \s\s', nm, IF sortrev THEN ' (reversed)' ELSE '')
  showmsg(mb)
ENDPROC

-> '=': measure the selected real directory with treestat (the same
-> walk the progress bar pre-counts with) and drop its byte total into
-> esize, so the size column shows it in place of "<DIR>" and a marked
-> dir now weighs into the border-row total. On demand only - walking
-> every directory on entry would freeze CFile on a real drive. The
-> figure lasts until the pane is re-read (which resets dirs to <DIR>).
PROC sizedir()
  DEF p, i, path[CPATHLEN]:STRING, member[CPATHLEN]:STRING,
      lock, sb, sf, r
  p := active
  IF involume(p) THEN RETURN
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  i := (p * MAXENT) + esel[p]
  IF edirs[i] = 0 THEN RETURN    -> a file already shows its size
  IF inarchive(p)
    -> inside an archive the sizes are already cached: just sum the
    -> member bytes under this folder's prefix (instant, no walk)
    arcmember(member, arcsub[p], enames[i])
    esize[i] := arcsizeunder(p, member)
  ELSEIF iniso(p)
    -> inside an image: resolve the folder, walk its extents
    arcmember(member, isosub[p], enames[i])
    IF (lock := Open(isopath[p], OLDFILE))    -> lock reused as a fh
      IF isofind(lock, isoroot[p], isorootsz[p], member, {sb}, {sf}, {r})
        IF r THEN esize[i] := isosum(lock, sb, sf, 0)
      ENDIF
      Close(lock)
    ENDIF
  ELSE
    buildfull(path, ppath[p], enames[i])
    showmsg('measuring - please wait')
    statbytes := 0
    statfiles := 0
    treestat(path, 0)
    esize[i] := statbytes
    clearmsg()    -> restores the paths row
  ENDIF
  drawrow(p, esel[p] - etop[p])
  drawpaths()    -> a marked measured dir now weighs into the border total
ENDPROC

-> extract one file member of pane p's archive into T:CFile-x, path
-> intact. TRUE if the file landed where expected.
PROC arcextractone(p, member)
  DEF cmd[700]:STRING, sfile[CPATHLEN]:STRING, res
  StrCopy(sfile, 'T:CFile-x/')
  StrAdd(sfile, member)
  makepath(sfile)
  DeleteFile(sfile)
  IF islzx(p)
    StringF(cmd, 'lzx x "\s" "\s" "\s"', arcpath[p], member, 'T:CFile-x/')
  ELSE
    StringF(cmd, 'lha -M x "\s" "\s" "\s"', arcpath[p], member, 'T:CFile-x/')
  ENDIF
  res := runcapture(NIL, cmd, 'T:CFile-out')
  DeleteFile('T:CFile-out')
ENDPROC (res <> -1) AND (pathtype(sfile) = 1)

-> r inside an archive: LhA has no rename, so extract the member (a
-> whole subtree for a folder) into the work area, rename it there,
-> add it back under the new name, then delete the old member. The
-> marked set renames one at a time like the real-file rename; the
-> stale cache is fine within the run - each entry's members are its
-> own - and one reload at the end refreshes everything.
PROC arcrename(p)
  DEF b, nmark, i, pick, r, stopped=FALSE, any=FALSE, exists, j,
      nm:PTR TO CHAR, isdir, ok, tname[110]:STRING,
      oldm[CPATHLEN]:STRING, newm[CPATHLEN]:STRING,
      oldp[CPATHLEN]:STRING, newp[CPATHLEN]:STRING,
      topname[CPATHLEN]:STRING, cmd[700]:STRING, res
  b := p * MAXENT
  nmark := markcount(p)
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stopped = FALSE)
      nm := enames[b + i]
      isdir := edirs[b + i]
      StrCopy(tname, nm)
      r := lineinput('rename to: ', tname, 30, TRUE)    -> TRUE bars / and :
      IF r = 0
        stopped := TRUE
      ELSEIF (EstrLen(tname) > 0) AND (nccmp(tname, nm) <> 0)
        exists := FALSE
        FOR j := 0 TO ecount[p] - 1
          IF nccmp(enames[b + j], tname) = 0 THEN exists := TRUE
        ENDFOR
        IF exists
          showmsg('a name like that is already here')
        ELSE
          arcmember(oldm, arcsub[p], nm)
          arcmember(newm, arcsub[p], tname)
          IF EstrLen(arcsub[p]) > 0
            firstcomp(topname, arcsub[p])
          ELSE
            StrCopy(topname, tname)
          ENDIF
          arcwipe('T:CFile-x')
          IF isdir
            ok := arcextracttree(p, oldm, 'T:CFile-x')
          ELSE
            ok := arcextractone(p, oldm)
          ENDIF
          IF ok = FALSE
            faultmsg('could not extract for rename')
            stopped := TRUE
          ELSE
            StrCopy(oldp, 'T:CFile-x/')
            StrAdd(oldp, oldm)
            StrCopy(newp, 'T:CFile-x/')
            StrAdd(newp, newm)
            IF Rename(oldp, newp) = FALSE
              faultmsg('cannot rename in the work area')
              stopped := TRUE
            ELSE
              IF islzx(p)
                StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[p], topname)
              ELSE
                StringF(cmd, 'lha -M -r a "\s" "\s"', arcpath[p], topname)
              ENDIF
              res := runcapture('T:CFile-x', cmd, 'T:CFile-out')
              DeleteFile('T:CFile-out')
              IF res = -1
                faultmsg('cannot add the renamed entry')
                stopped := TRUE
              ELSE
                -> the new name is safely in; drop the old member(s)
                IF islzx(p)
                  IF isdir THEN lzxdeltree(p, oldm) ELSE lzxdelmember(arcpath[p], oldm)
                ELSE
                  IF isdir THEN arcdeltree(p, oldm) ELSE arcdelmember(arcpath[p], oldm)
                ENDIF
                any := TRUE
                StrCopy(prevname, tname)
              ENDIF
            ENDIF
          ENDIF
          arcwipe('T:CFile-x')
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  IF any
    loadarchive(p, arcpath[p])
    IF nmark = 0 THEN refreshsel(p) ELSE refreshall()
  ELSE
    drawpaths()
  ENDIF
ENDPROC

PROC dorename()
  DEF p, i, b, nmark, r, pick, stopped=FALSE, any=FALSE,
      src2[310]:STRING, dst[310]:STRING, tname[110]:STRING,
      isrc[320]:STRING, idst[320]:STRING, itname[120]:STRING
  p := active
  IF iniso(p)
    showmsg('the CD image is read-only')
    RETURN
  ENDIF
  IF inarchive(p)
    arcrename(p)
    RETURN
  ENDIF
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] OR (ecount[p] = 0) THEN RETURN
  b := p * MAXENT
  nmark := markcount(p)
  -> the marked set renames one at a time (his thought); Esc stops
  -> the rest, an unchanged name skips that one. An icon whose file is
  -> also marked is skipped - it is renamed as that file's sidecar.
  FOR i := 0 TO ecount[p] - 1
    pick := IF nmark > 0 THEN emark[b + i] <> 0 ELSE i = esel[p]
    IF pick AND (stopped = FALSE) AND (infodup(p, b + i) = FALSE)
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
            -> the icon follows the new name (best-effort)
            IF icons AND (isinfo(enames[b + i]) = FALSE)
              IF sidecarof(ppath[p], enames[b + i], isrc)
                StrCopy(itname, tname)
                StrAdd(itname, '.info')
                buildfull(idst, ppath[p], itname)
                Rename(isrc, idst)
              ENDIF
            ENDIF
          ELSE
            faultmsg('cannot rename')
            stopped := TRUE
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  IF any
    -> I6 (stage b5): a rename touches only THIS pane's directory and
    -> its debris is border-row prompts - the other pane's pixels
    -> stay (it re-reads only if it shows the same directory)
    refreshpane(p, nmark = 0)
    IF msgup THEN remsg()
  ELSE
    drawpaths()
    IF msgup THEN remsg()
  ENDIF
ENDPROC

-> n: a name ending in "/" makes a directory; anything else opens
-> the editor on a NEW file - which only exists once it is saved
-> n inside an archive: a trailing "/" makes an empty directory member
-> ARCWRITE ONEXIT new: stage the file or empty directory into the
-> beside-the-archive tree and add a MST_ADD cache member so it shows at
-> once - no lha runs until the archive is committed. `member` is the
-> full stored path; a directory gets a trailing slash, the way lha
-> stores one. The staging tree is NOT wiped here - it accumulates until
-> commit.
PROC arcnewdefer(p, name, member, wantdir)
  DEF st:PTR TO LONG, stageroot[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING,
      mem2[CPATHLEN]:STRING, lock, r, sz=0, fib:PTR TO fileinfoblock, slot
  arcstage(p, stageroot)
  StrCopy(sfile, stageroot)
  AddPart(sfile, member, CPATHLEN - 4)
  SetStr(sfile, StrLen(sfile))
  makepath(sfile)    -> parent dirs, the staging root itself included
  IF wantdir
    IF (lock := CreateDir(sfile)) = NIL
      showmsg('cannot make the folder - is the archive disk writable?')
      RETURN
    ENDIF
    UnLock(lock)
    StrCopy(mem2, member)
    StrAdd(mem2, '/')    -> a stored empty-dir member carries a slash
    slot := arcadd(p, mem2, 0)
  ELSE
    drawpaths()
    r := editfile(sfile, name)    -> the file exists only if saved
    IF r <> 1
      DeleteFile(sfile)
      drawall()
      RETURN
    ENDIF
    IF lock := Lock(sfile, SHARED_LOCK)
      IF fib := AllocDosObject(DOS_FIB, NIL)
        IF Examine(lock, fib) THEN sz := fib.size
        FreeDosObject(DOS_FIB, fib)
      ENDIF
      UnLock(lock)
    ENDIF
    slot := arcadd(p, member, sz)
  ENDIF
  -> mark the slot arcadd just appended as a pending add
  IF slot >= 0
    st := amst[p]
    st[slot] := MST_ADD
  ENDIF
  StrCopy(prevname, name)
  refreshsel(p)    -> R5: one draw, cursor pre-placed
ENDPROC

PROC arcnew(p)
  DEF tname[40]:STRING, s:PTR TO CHAR, i, l, b, wantdir=FALSE, r, exists=FALSE,
      member[CPATHLEN]:STRING, sfile[CPATHLEN]:STRING, topname[CPATHLEN]:STRING,
      cmd[700]:STRING, res, lock
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
  b := p * MAXENT
  IF ecount[p] > 0
    FOR i := 0 TO ecount[p] - 1
      IF nccmp(enames[b + i], tname) = 0 THEN exists := TRUE
    ENDFOR
  ENDIF
  IF exists
    showmsg('that name is already here')
    RETURN
  ENDIF
  arcmember(member, arcsub[p], tname)
  -> ONEXIT (both): defer the new entry. DIRECT: add it immediately below.
  IF arcwrite
    arcnewdefer(p, tname, member, wantdir)
    RETURN
  ENDIF
  IF EstrLen(arcsub[p]) > 0
    firstcomp(topname, arcsub[p])
  ELSE
    StrCopy(topname, tname)
  ENDIF
  arcwipe('T:CFile-a')
  StrCopy(sfile, 'T:CFile-a/')
  StrAdd(sfile, member)
  makepath(sfile)    -> the member's parent directories
  IF wantdir
    IF (lock := CreateDir(sfile)) = NIL
      arcwipe('T:CFile-a')
      showmsg('cannot make the folder')
      RETURN
    ENDIF
    UnLock(lock)
    -> -e so the empty directory is actually stored (both archivers)
    IF islzx(p)
      StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[p], topname)
    ELSE
      StringF(cmd, 'lha -M -r -e a "\s" "\s"', arcpath[p], topname)
    ENDIF
    res := runcapture('T:CFile-a', cmd, 'T:CFile-out')
  ELSE
    drawpaths()
    r := editfile(sfile, tname)    -> the file exists only if saved
    IF r <> 1
      arcwipe('T:CFile-a')
      drawall()
      RETURN
    ENDIF
    IF islzx(p)
      StringF(cmd, 'lzx -r -e a "\s" "\s"', arcpath[p], topname)
    ELSE
      StringF(cmd, 'lha -M -r a "\s" "\s"', arcpath[p], topname)
    ENDIF
    res := runcapture('T:CFile-a', cmd, 'T:CFile-out')
  ENDIF
  DeleteFile('T:CFile-out')
  arcwipe('T:CFile-a')
  IF res = -1
    faultmsg('could not add to the archive')
    RETURN
  ENDIF
  loadarchive(p, arcpath[p])
  StrCopy(prevname, tname)
  refreshsel(p)    -> R5: one draw, cursor pre-placed
ENDPROC

PROC donew()
  DEF p, lock, tname[40]:STRING, dpath[310]:STRING,
      s:PTR TO CHAR, i, l, wantdir=FALSE, r
  p := active
  IF iniso(p)
    showmsg('the CD image is read-only')
    RETURN
  ENDIF
  IF inarchive(p)
    arcnew(p)
    RETURN
  ENDIF
  IF involume(p)
    showmsg('no file operations in the volume list')
    RETURN
  ENDIF
  IF efail[p] THEN RETURN
  StrCopy(tname, '')
  IF lineinput('new (/ = dir, .adf = blank disk image): ', tname, 31, FALSE) = 0
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
      refreshpane(p, TRUE)    -> I6: one-sided, prompt-only debris
    ELSE
      faultmsg('cannot create')
    ENDIF
  ELSEIF adfext(tname)
    -> the name picks the type, like the trailing slash does: a name
    -> ending .adf becomes a formatted blank disk image (his ask:
    -> a standard empty ADF for easy transfer to UAE elsewhere)
    docreateadf(p, dpath, tname)
  ELSE
    IF pathtype(dpath) > 0
      showmsg('that name already exists - e edits it')
      RETURN
    ENDIF
    drawpaths()
    r := editfile(dpath, tname)
    IF r = 1
      StrCopy(prevname, tname)
      refreshsel(p)    -> R5: one draw, cursor pre-placed
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
-> one page of the (scrollable) help: visrows lines from `vtop`, centred
-> over the pane area
PROC drawhelp(lines:PTR TO LONG, nlines, vtop, hindent)
  DEF r, ln
  SetAPen(rp, 0)
  RectFill(rp, x0, panetop, x0 + Mul(ncols, cw) - 1,
           panetop + Mul(visrows, ch) - 1)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR r := 0 TO visrows - 1
    ln := vtop + r
    IF ln < nlines
      Move(rp, x0 + (hindent * cw), panetop + (r * ch) + baseline)
      Text(rp, lines[ln], StrLen(lines[ln]))
    ENDIF
  ENDFOR
ENDPROC

-> ? / Help: the key list, scrollable with Up/Down (Shift = page, Ctrl =
-> ends) when it is taller than the pane area; any other key returns.
PROC helpscreen()
  DEF lines:PTR TO LONG, nlines=0, vtop=0, maxv, nv, hindent, over=FALSE,
      class, code, qual
  lines := ['CFile 0.4.1b3',
            '',
            'Tab ........ switch the active pane',
            'Up/Down .... move (Shift = page, Ctrl = first/last)',
            'Right/Left . enter dir/lha/lzx archive / parent, volumes',
            'g .......... go to a typed path',
            'f .......... find by name or #? pattern (recursive)',
            't .......... text search inside files (recursive grep)',
            'b + 0-9 .... set a bookmark here; a bare digit jumps to it',
            '/ .......... filter: type to narrow, Space marks a match',
            'F5 ......... rescan: re-read both panes from disk',
            'Enter ...... open: enter dir, view text, run a binary (asks)',
            'v .......... view text/ANSI/hex; with marks a tour',
            'e .......... edit a text file (e in the viewer works too)',
            'i .......... file info; h s p a r w e d toggle protection',
            'Space ...... mark/unmark (ops take the marks if any)',
            'a A * + .... mark all / none / invert / by pattern',
            '= / s ...... measure dir size / sort (name/size/date)',
            'c / C ...... copy to the other pane (C overwrites)',
            'm / M ...... move to the other pane (M overwrites)',
            'r / n ...... rename / new (a trailing / makes a directory)',
            'Del / D .... delete, directories and all (asks first)',
            'u / p ...... unpack / pack archive(s) (.lha/.lzx/.zip)',
            ': .......... run a shell command in this directory',
            '? / Help ... this help',
            'Esc ........ cancel a running copy/delete, else quit (asks)',
            '',
            '-- arrows scroll, any other key returns --',
            NIL]:LONG
  WHILE lines[nlines]
    nlines++
  ENDWHILE
  hindent := (ncols - 60) / 2
  IF hindent < 1 THEN hindent := 1
  maxv := nlines - visrows
  IF maxv < 0 THEN maxv := 0
  drawviewframe(TRUE)    -> closed border + the viewer's footer
  drawhelp(lines, nlines, vtop, hindent)
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
          -> a qualifier key on its own: not an answer, keep the help up
        ELSE
          over := TRUE
        ENDIF
      ENDIF
    ELSE
      over := TRUE    -> a vanilla key returns
    ENDIF
    IF nv > maxv THEN nv := maxv
    IF nv < 0 THEN nv := 0
    IF (nv <> vtop) AND (over = FALSE)
      vtop := nv
      drawhelp(lines, nlines, vtop, hindent)
    ENDIF
  ENDWHILE
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
      ELSEIF code = "a"    -> mark all
        markall(active, 1)
      ELSEIF code = "A"    -> mark none
        markall(active, 0)
      ELSEIF code = "*"    -> invert marks
        markinvert(active)
      ELSEIF code = "+"    -> mark by pattern (#?.mod ...)
        markpattern(active)
      ELSEIF (code = "s") OR (code = "S")    -> sort mode
        dosort()
      ELSEIF code = "="    -> measure the selected directory's size
        sizedir()
      ELSEIF code = "/"    -> live filter: narrow the pane by typing
        dofilter()
      ELSEIF (code = "g") OR (code = "G")    -> go to a typed path
        dogoto()
      ELSEIF (code = "f") OR (code = "F")    -> find files by name, recursively
        dofind()
      ELSEIF (code = "t") OR (code = "T")    -> text search inside files (grep)
        docontent()
      ELSEIF (code = "b") OR (code = "B")    -> set a bookmark (b then a digit)
        dobookmark()
      ELSEIF (code >= "0") AND (code <= "9")    -> jump to bookmark slot (digit)
        bookmarkjump(code - "0")
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
        ELSEIF code = RK_F5    -> re-read both panes
          rescan()
        ENDIF
      ENDIF
    ENDIF
    IF wantreload    -> the config was saved from the editor
      wantreload := FALSE
      applyconfig()
    ENDIF
  ENDWHILE
ENDPROC

-> ---- BENCH: temporary perf-campaign instrument -----------------------
-> `cfile BENCH <dir> [file] [needle]` (see perf-roadmap.md phase 0):
-> runs the hot paths programmatically with the UI open - pane scan,
-> full-pane draw, the cursor walk (the path hand-timing cannot reach:
-> a held key only measures the repeat rate), editor load/save, a copy,
-> the grep - timing each with DateStamp ticks (1/50s) and writing the
-> table to PROGDIR:cfile-bench.log (Linux-readable on the dir-drive).
-> Quits when done; saveconfig is skipped so a bench run never rewrites
-> cfile.config. Strip (or gate behind a debug flag) before release.

-> elapsed ms between two DateStamp results (3 LONGs: days,minute,tick).
-> Deltas only - each term is small, so the Muls stay in 32-bit range.
PROC bms(a:PTR TO LONG, b:PTR TO LONG)
ENDPROC Mul(b[0] - a[0], 86400000) + Mul(b[1] - a[1], 60000) + Mul(b[2] - a[2], 20)

-> bench writer: StrLen, not wline's EstrLen, so string LITERALS are safe
PROC bputs(fh, s)
ENDPROC Write(fh, s, StrLen(s))

-> one result row. Per-rep uses progadd's shift-both-down so the Div
-> quotient stays inside DIVS' 16-bit limit whatever the total.
PROC blog(fh, name, ms, reps)
  DEF line[300]:STRING, d, s=0, per
  d := ms
  WHILE d > 30000
    d := Shr(d, 1)
    s := s + 1
  ENDWHILE
  per := IF reps > 1 THEN Shl(Div(d, reps), s) ELSE ms
  StringF(line, '\s: \d ms total, \d reps, ~\d ms/rep\n', name, ms, reps, per)
  bputs(fh, line)
ENDPROC

PROC dobench()
  DEF fh, line[400]:STRING, t1[3]:ARRAY OF LONG, t2[3]:ARRAY OF LONG,
      i, steps, cnt=0, paths=NIL:PTR TO LONG, disp=NIL:PTR TO LONG,
      scanbuf=NIL:PTR TO CHAR
  IF (fh := Open('PROGDIR:cfile-bench.log', NEWFILE)) = NIL THEN RETURN
  StringF(line, 'bench: \s\n', {version} + 6)
  bputs(fh, line)
  StringF(line, 'cbufsz: \d\n', cbufsz)    -> which I1 ladder rung took
  bputs(fh, line)
  active := 0    -> the bench drives pane 0
  IF EstrLen(bdir) = 0
    bputs(fh, 'usage: cfile BENCH <dir> [file] [needle]\n')
    Close(fh)
    RETURN
  ENDIF
  IF gotopath(0, bdir) = FALSE
    StringF(line, 'cannot open bench dir "\s"\n', bdir)
    bputs(fh, line)
    Close(fh)
    RETURN
  ENDIF
  StringF(line, 'dir: \s (\d entries)\n', ppath[0], ecount[0])
  bputs(fh, line)

  -> scan: listing read + sort, no draw (readpane never draws)
  DateStamp(t1)
  FOR i := 1 TO 5 DO readpane(0)
  DateStamp(t2)
  blog(fh, 'scan   (readpane)', bms(t1, t2), 5)

  -> draw: the full-pane repaint every scroll-edge step pays today
  DateStamp(t1)
  FOR i := 1 TO 20 DO drawpane(0)
  DateStamp(t2)
  blog(fh, 'draw   (drawpane)', bms(t1, t2), 20)

  -> scroll: walk the bar top to bottom - the held-Down render path
  esel[0] := 0
  etop[0] := 0
  drawpane(0)
  steps := ecount[0] - 1
  IF steps > 0
    DateStamp(t1)
    WHILE esel[0] < (ecount[0] - 1)
      movedown()
    ENDWHILE
    DateStamp(t2)
    blog(fh, 'scroll (movedown)', bms(t1, t2), steps)
  ENDIF

  IF EstrLen(bfile)
    IF sniff(bfile) = TY_TEXT
      DateStamp(t1)
      FOR i := 1 TO 3
        edload(bfile)
        edfree()
      ENDFOR
      DateStamp(t2)
      blog(fh, 'edload (incl edfree)', bms(t1, t2), 3)
      IF edload(bfile)
        DateStamp(t1)
        FOR i := 1 TO 3 DO edsave('T:cfile-bench.tmp')
        DateStamp(t2)
        blog(fh, 'edsave (to T:)', bms(t1, t2), 3)
        edfree()
        DeleteFile('T:cfile-bench.tmp')
      ELSE
        -> seen on the 2MB stock config with the 424KB corpus: the 4th
        -> load peaks ~1.5MB in a fragmented pool. Use a smaller file.
        bputs(fh, 'edsave skipped (edload failed - file too big for this config?)\n')
      ENDIF
    ELSE
      bputs(fh, 'edload/edsave skipped (bench file is not text)\n')
    ENDIF
    -> copy: the CBUFSZ chunk loop (target on T: - measures the read
    -> side plus packet turnaround, not the target volume)
    DateStamp(t1)
    FOR i := 1 TO 3 DO copyfile(bfile, 'T:cfile-bench.tmp')
    DateStamp(t2)
    blog(fh, 'copy   (to T:)', bms(t1, t2), 3)
    DeleteFile('T:cfile-bench.tmp')
  ENDIF

  IF EstrLen(bneedle)
    paths := New(FINDMAX * 4)
    disp := New(FINDMAX * 4)
    scanbuf := New(VIEWMAX + 1)    -> X3: the scan peeks scanbuf[n]
    IF paths AND disp AND scanbuf    -> no derefs: eager AND is safe here
      cnt := 0
      DateStamp(t1)
      grepwalk(ppath[0], 0, bneedle, ppath[0], scanbuf, paths, disp, {cnt})
      DateStamp(t2)
      StringF(line, 'grep   ("\s", \d hits)', bneedle, cnt)
      blog(fh, line, bms(t1, t2), 1)
      FOR i := 0 TO cnt - 1
        IF paths[i] THEN DisposeLink(paths[i])
        IF disp[i] THEN DisposeLink(disp[i])
      ENDFOR
    ELSE
      bputs(fh, 'grep skipped (no memory for buffers)\n')
    ENDIF
    IF paths THEN Dispose(paths)
    IF disp THEN Dispose(disp)
    IF scanbuf THEN Dispose(scanbuf)
  ENDIF

  bputs(fh, 'bench done\n')
  Close(fh)
ENDPROC

PROC main() HANDLE
  ensureassigns()
  initbookmarks()    -> before loadconfig, which may fill the slots
  loadconfig()
  configensure()    -> create/complete cfile.config before the args override
  parseargs()
  initpanes()
  readpane(0)
  readpane(1)
  openui()
  drawall()
  IF benchmode
    dobench()
  ELSE
    eventloop()
  ENDIF
  arccommit(0)    -> flush any pane still inside a modified archive
  arccommit(1)
  daunmountall()  -> let go of every disk image we mounted
  closeui()
  IF benchmode = FALSE THEN saveconfig()    -> a bench run never rewrites config
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

version: CHAR '$VER: CFile 0.4.1b26 (30.7.26) E build',0