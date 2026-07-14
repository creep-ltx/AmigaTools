-> CMenu - full-screen text boot menu for AmigaOS
->
-> Meant to run *before* the normal Startup-Sequence (see
-> Example-Startup-Sequence): it opens its own full-size screen, shows
-> a centered menu of items from S:CMenu/Config, and launches the
-> chosen one the same way CBoot launches its boot scripts (protect
-> +srwed, then Execute). CMenu exits after launching - it is a boot
-> menu, not a dock.
->
-> On-disk layout: C:CMenu, S:CMenu/Config, and the optional art in
-> S:CMenu/Headers/ and S:CMenu/Backgrounds/.
->
-> S:CMenu/Config format (one entry per line, max 10 items):
->   ; comment
->   Menu name|path-to-script-or-executable
->   DEFAULT n          (1-based index of the preselected item)
->   TIMEOUT secs       (auto-start DEFAULT after secs; 0/absent = wait)
->   STYLE LIGHT|DARK|ANSI  (LIGHT = grey bg/black text, DARK = black
->                       bg/white text, ANSI = DARK plus full-colour
->                       art; default LIGHT)
->   HEADERS [ON|OFF] dir   (directory with ANSI art headers; one is
->                       picked per run and drawn above the menu.
->                       OFF keeps the dir configured but hides them)
->   BACKGROUND [ON|OFF] path  (full-screen ANSI/ASCII background art
->                       instead of a header; path may be one file or
->                       a directory to rotate. The menu is laid out
->                       inside the art's free interior, which is
->                       auto-detected, so the art is never drawn
->                       over. Background art is line-height 8, so a
->                       PAL screen fits 32 rows. When rotating from
->                       a directory only art that fits the screen
->                       height is considered, so PAL/NTSC/interlace
->                       versions can live side by side)
->   MUSIC [RANDOM|REPEAT|OFF] path  (ProTracker music while the menu
->                       is shown; path may be one file or a directory
->                       - it and its subdirectories are scanned for
->                       name.mod / mod.name files. RANDOM picks a
->                       random module and jukeboxes to another when
->                       it ends; REPEAT loops the picked one; OFF is
->                       silent. Needs ptreplay.library in LIBS:;
->                       without it CMenu is silent. Playback stops
->                       before anything is launched)
->   FONT name/size     (e.g. FONT MicroKnight/8 - opened from FONTS:
->                       via diskfont.library; missing fonts fall back
->                       to Topaz/8. Art assumes 8-pixel-wide glyphs,
->                       so 8x8 fonts like the scene fonts fit best)
->
-> If S:CMenu/Config does not exist, CMenu opens straight into the
-> config screen so the menu can be set up on first boot, with the
-> default art paths prefilled; saving creates the S:CMenu drawer and
-> the file. If no header or background can actually be shown, the
-> plain version title is drawn at the top instead.
->
-> Header and background are mutually exclusive; background wins if
-> both are ON.
->
-> Keys: Up/Down select (wraps), Enter launches selection,
->       1-9 and 0 launch item 1-10 directly, C opens the config
->       screen, Esc exits without launching. Any key stops a
->       running countdown.
->
-> Config screen: edit the menu in place - A adds an item, E or Enter
-> edits the selected one (name, then path; Esc keeps the old value),
-> D deletes it, Shift+Up/Down moves it, Space makes it the default,
-> T sets the timeout, C cycles the style (the palette switches
-> immediately), H toggles the header, B toggles the background,
-> M toggles the music, S writes S:CMenu/Config back (comment lines
-> in the file do not survive a rewrite), Esc returns to the menu.
->
-> If S:CMenu/Config is missing or has no items, a built-in fallback
-> menu (Workbench -> S:Startup-Sequence-Normal, Shell -> C:NewShell)
-> is shown instead so a misconfigured setup still boots to something.
->
-> CMenu opens its own screen (mode and size like the Workbench,
-> depth 3), so PAL vs NTSC vs interlace vs RTG needs no detection at
-> all; the palette follows the STYLE setting. If that screen cannot
-> be opened it falls back to a window on the public screen, with
-> art colours stripped. The countdown is driven by IDCMP_INTUITICKS
-> (~10 per second), which is plenty accurate for a boot timeout.
->
-> The art renderer understands the codes 1996-era ANSI art actually
-> uses: SGR colour/style (ESC[0m, 1m bold, 4m underline, 30-37m
-> foreground, ;-combinations) and cursor-forward column skips
-> (ESC[nC). Anything else is consumed and ignored. In LIGHT and DARK
-> style the colours are stripped but the art keeps its shape.

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','devices/inputevent',
       'dos/dos','diskfont',
       'ptreplay','libraries/ptreplay'

CONST MAXITEMS=10, NAMELEN=60, CPATHLEN=300, MAXTIMEOUT=999,
      CFGARTLEN=2466,
      ARTMAX=8000, HDRLINEMAX=12, BGLINEMAX=64,
      STYLE_LIGHT=0, STYLE_DARK=1, STYLE_ANSI=2,
      MUS_OFF=0, MUS_RANDOM=1, MUS_REPEAT=2,
      RK_UP=$4C, RK_DOWN=$4D    -> rawkey codes, cursor up/down

DEF nitems=0, nalloc=0, defitem=1, timeout=0, fallbk=FALSE,
    names[MAXITEMS]:ARRAY OF LONG,
    paths[MAXITEMS]:ARRAY OF LONG,
    hdrdir[304]:STRING, bgpath[304]:STRING, muspath[304]:STRING,
    fontname[64]:STRING, fullfont[72]:STRING, fsize=8,
    style=STYLE_LIGHT, showhdr=TRUE, showbg=FALSE, musmode=MUS_RANDOM,
    noconf=FALSE, ptmod=NIL, musbit=-1, lastmus=-1, modcounter=0,
    muspick[340]:STRING,
    hdrbuf=NIL, hdrlines=0, bgbuf=NIL, bglines=0,
    bandr0=-1, bandr1=-1, bandmode=FALSE,
    cfgbuf=NIL, cfglines=0, cfgr0=-1, cfgr1=-1,
    scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    ownscr=FALSE, txtpen=1, softmask=0,
    winw, winh, rowh, baseline, starty, titley, warny, cnty, helpy,
    cstarty, metay, inputy, ctity, ch1y, ch2y, clrx0=0, clrx1=0,
    counting=FALSE, secs=0, menumaxw=0, msgticks=0,
    cbuf[100]:STRING,
    rc=0

PROC striptrail(e)
  DEF s:PTR TO CHAR, l
  s := e
  l := EstrLen(e)
  WHILE (l > 0) AND ((s[l-1] = " ") OR (s[l-1] = 9))
    l--
  ENDWHILE
  SetStr(e, l)
ENDPROC

-> the global names/paths arrays are NOT zero-initialised (E globals
-> live in the uncleared stack allocation), so slot reuse after delitem
-> is tracked with nalloc instead of a NIL test
PROC additem(name, path)
  IF nitems >= MAXITEMS THEN RETURN
  IF nitems >= nalloc
    IF (names[nitems] := String(NAMELEN)) = NIL THEN Raise("MEM")
    IF (paths[nitems] := String(CPATHLEN)) = NIL THEN Raise("MEM")
    nalloc++
  ENDIF
  StrCopy(names[nitems], name)
  StrCopy(paths[nitems], path)
  nitems++
ENDPROC

PROC delitem(i)
  DEF j, sn, sp
  sn := names[i]
  sp := paths[i]
  j := i
  WHILE j < (nitems - 1)
    names[j] := names[j+1]
    paths[j] := paths[j+1]
    j++
  ENDWHILE
  nitems--
  names[nitems] := sn    -> keep the allocations for reuse by additem
  paths[nitems] := sp
  IF (i + 1) < defitem
    defitem--
  ELSEIF (i + 1) = defitem
    defitem := 1
  ENDIF
ENDPROC

-> swap two items; the default follows the item it points to
PROC swapitems(a, b)
  DEF t
  t := names[a]
  names[a] := names[b]
  names[b] := t
  t := paths[a]
  paths[a] := paths[b]
  paths[b] := t
  IF defitem = (a + 1)
    defitem := b + 1
  ELSEIF defitem = (b + 1)
    defitem := a + 1
  ENDIF
ENDPROC

PROC stylename()
  IF style = STYLE_LIGHT THEN RETURN 'LIGHT'
  IF style = STYLE_ANSI THEN RETURN 'ANSI'
ENDPROC 'DARK'

PROC musname()
  IF musmode = MUS_RANDOM THEN RETURN 'RANDOM'
  IF musmode = MUS_REPEAT THEN RETURN 'REPEAT'
ENDPROC 'OFF'

-> parse "[RANDOM|REPEAT|OFF] path" into dest, return the mode
-> (no prefix = RANDOM; ON is tolerated as RANDOM)
PROC musmodepath(s, dest)
  DEF kw[8]:STRING, mode
  mode := MUS_RANDOM
  StrCopy(dest, s)
  striptrail(dest)
  MidStr(kw, dest, 0, 7)
  UpperStr(kw)
  IF StrCmp(kw, 'RANDOM ')
    StrCopy(dest, TrimStr(dest + 7))
  ELSEIF StrCmp(kw, 'REPEAT ')
    mode := MUS_REPEAT
    StrCopy(dest, TrimStr(dest + 7))
  ELSE
    MidStr(kw, dest, 0, 4)
    UpperStr(kw)
    IF StrCmp(kw, 'OFF ')
      mode := MUS_OFF
      StrCopy(dest, TrimStr(dest + 4))
    ELSE
      MidStr(kw, dest, 0, 3)
      UpperStr(kw)
      IF StrCmp(kw, 'ON ')
        StrCopy(dest, TrimStr(dest + 3))
      ENDIF
    ENDIF
  ENDIF
  striptrail(dest)
ENDPROC mode

-> parse "[ON|OFF] path" into dest, return the ON/OFF state
-> (no prefix = ON)
PROC onoffpath(s, dest)
  DEF kw[8]:STRING, on
  on := TRUE
  StrCopy(dest, s)
  striptrail(dest)
  MidStr(kw, dest, 0, 3)
  UpperStr(kw)
  IF StrCmp(kw, 'ON ')
    StrCopy(dest, TrimStr(dest + 3))
  ELSE
    MidStr(kw, dest, 0, 4)
    UpperStr(kw)
    IF StrCmp(kw, 'OFF ')
      on := FALSE
      StrCopy(dest, TrimStr(dest + 4))
    ENDIF
  ENDIF
  striptrail(dest)
ENDPROC on

PROC parseline(line)
  DEF s:PTR TO CHAR, l, p, kw[12]:STRING, tname[80]:STRING, tpath[340]:STRING
  s := line
  l := EstrLen(line)
  IF l > 0
    IF s[l-1] = 13 THEN SetStr(line, l-1)    -> tolerate CRLF files
  ENDIF
  s := TrimStr(line)
  IF StrLen(s) = 0 THEN RETURN
  IF s[0] = ";" THEN RETURN
  p := InStr(s, '|')
  IF p > 0
    MidStr(tname, s, 0, p)
    striptrail(tname)
    MidStr(tpath, s, p+1, ALL)
    striptrail(tpath)
    IF (EstrLen(tname) > 0) AND (StrLen(TrimStr(tpath)) > 0)
      additem(tname, TrimStr(tpath))
    ENDIF
    RETURN
  ENDIF
  -> keyword lines: KEYWORD value
  p := InStr(s, ' ')
  IF p <= 0 THEN RETURN
  MidStr(kw, s, 0, p)
  UpperStr(kw)
  s := TrimStr(s + p)
  IF StrLen(s) = 0 THEN RETURN
  IF StrCmp(kw, 'DEFAULT')
    defitem := Val(s)
  ELSEIF StrCmp(kw, 'TIMEOUT')
    timeout := Val(s)
  ELSEIF StrCmp(kw, 'STYLE')
    StrCopy(tname, s)
    striptrail(tname)
    UpperStr(tname)
    IF StrCmp(tname, 'LIGHT')
      style := STYLE_LIGHT
    ELSEIF StrCmp(tname, 'DARK')
      style := STYLE_DARK
    ELSEIF StrCmp(tname, 'ANSI')
      style := STYLE_ANSI
    ENDIF
  ELSEIF StrCmp(kw, 'HEADERS')
    showhdr := onoffpath(s, hdrdir)
  ELSEIF StrCmp(kw, 'BACKGROUND')
    showbg := onoffpath(s, bgpath)
  ELSEIF StrCmp(kw, 'MUSIC')
    musmode := musmodepath(s, muspath)
  ELSEIF StrCmp(kw, 'FONT')
    p := InStr(s, '/')
    IF p > 0
      MidStr(fontname, s, 0, p)
      striptrail(fontname)
      fsize := Val(TrimStr(s + p + 1))
    ELSE
      StrCopy(fontname, s)
      striptrail(fontname)
    ENDIF
    IF fsize <= 0 THEN fsize := 8
  ENDIF
ENDPROC

PROC loadconfig()
  DEF fh, eof=FALSE, line[400]:STRING
  StrCopy(hdrdir, '')
  StrCopy(bgpath, '')
  StrCopy(muspath, '')
  StrCopy(fontname, '')
  IF fh := Open('S:CMenu/Config', OLDFILE)
    REPEAT
      IF ReadStr(fh, line) = -1 THEN eof := TRUE
      IF EstrLen(line) > 0 THEN parseline(line)
    UNTIL eof
    Close(fh)
  ELSE
    -> first boot: go straight to the config screen, with the default
    -> art paths prefilled so H/B work and saving writes a complete
    -> default config
    noconf := TRUE
    StrCopy(hdrdir, 'S:CMenu/Headers')
    StrCopy(bgpath, 'S:CMenu/Backgrounds')
    StrCopy(muspath, 'S:CMenu/Music')
    showhdr := FALSE
    showbg := TRUE
    musmode := MUS_RANDOM
  ENDIF
  IF nitems = 0
    fallbk := TRUE
    additem('Workbench', 'S:Startup-Sequence-Normal')
    additem('Shell', 'C:NewShell')
    defitem := 1
    timeout := 0
  ENDIF
  IF (defitem < 1) OR (defitem > nitems) THEN defitem := 1
  IF timeout < 0 THEN timeout := 0
  IF timeout > MAXTIMEOUT THEN timeout := MAXTIMEOUT
  IF EstrLen(hdrdir) = 0 THEN showhdr := FALSE
  IF EstrLen(bgpath) = 0 THEN showbg := FALSE
  IF EstrLen(muspath) = 0 THEN musmode := MUS_OFF
  IF showbg THEN showhdr := FALSE    -> background wins if both are ON
ENDPROC

-> Workbench icon files are not content - every directory scan
-> must skip them
PROC isinfoname(name)
  DEF s:PTR TO CHAR, l, t[8]:STRING
  s := name
  l := StrLen(s)
  IF l < 5 THEN RETURN FALSE
  MidStr(t, s, l - 5, 5)
  LowerStr(t)
ENDPROC StrCmp(t, '.info')

-> ProTracker naming conventions: name.mod or mod.name
PROC ismodname(name)
  DEF s:PTR TO CHAR, l, t[8]:STRING
  s := name
  l := StrLen(s)
  IF l < 4 THEN RETURN FALSE
  MidStr(t, s, 0, 4)
  LowerStr(t)
  IF StrCmp(t, 'mod.') THEN RETURN TRUE
  MidStr(t, s, l - 4, 4)
  LowerStr(t)
ENDPROC StrCmp(t, '.mod')

-> count the files in a directory lock; -1 = the lock is a plain file.
-> modonly counts only ProTracker-named files
PROC countfiles(lock, fib:PTR TO fileinfoblock, modonly)
  DEF n=0, take
  IF Examine(lock, fib) = 0 THEN RETURN -1
  IF fib.direntrytype <= 0 THEN RETURN -1
  WHILE ExNext(lock, fib)
    IF fib.direntrytype < 0
      take := IF modonly THEN ismodname(fib.filename) ELSE TRUE
      IF isinfoname(fib.filename) THEN take := FALSE
      IF take THEN n++
    ENDIF
  ENDWHILE
ENDPROC n

-> position fib on the n'th file (0-based) of a directory lock.
-> E's AND does not short-circuit, so ExNext must live in the loop
-> body: in the condition it would run once more after i = n and
-> clobber the fib of the file just picked
PROC nthfile(lock, fib:PTR TO fileinfoblock, n, modonly)
  DEF i, more, take
  IF Examine(lock, fib) = 0 THEN RETURN FALSE
  IF fib.direntrytype <= 0 THEN RETURN FALSE
  i := -1
  more := TRUE
  WHILE (i < n) AND more
    IF ExNext(lock, fib)
      IF fib.direntrytype < 0
        take := IF modonly THEN ismodname(fib.filename) ELSE TRUE
        IF isinfoname(fib.filename) THEN take := FALSE
        IF take THEN i++
      ENDIF
    ELSE
      more := FALSE
    ENDIF
  ENDWHILE
ENDPROC (i = n)

-> read a file into an existing art buffer, returns the length
PROC readart(path, buf)
  DEF fh, len=0
  IF fh := Open(path, OLDFILE)
    len := Read(fh, buf, ARTMAX)
    Close(fh)
  ENDIF
  IF len < 0 THEN len := 0
  SetStr(buf, len)
ENDPROC len

-> load an art file: path may be a plain file, or a directory to pick
-> a random file from. Returns an estring with the raw bytes, or NIL.
PROC loadart(artpath)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, count, idx, buf=NIL,
      path[340]:STRING, ds[3]:ARRAY OF LONG
  IF EstrLen(artpath) = 0 THEN RETURN NIL
  IF (lock := Lock(artpath, SHARED_LOCK)) = NIL THEN RETURN NIL
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL
    UnLock(lock)
    RETURN NIL
  ENDIF
  StrCopy(path, '')
  count := countfiles(lock, fib, FALSE)
  IF count = -1    -> a plain file: use it directly
    StrCopy(path, artpath)
  ELSEIF count > 0
    DateStamp(ds)
    idx := Mod(ds[1] + ds[2], count)    -> minutes+ticks, random enough
    IF nthfile(lock, fib, idx, FALSE)
      StrCopy(path, artpath)
      AddPart(path, fib.filename, 336)
      SetStr(path, StrLen(path))
    ENDIF
  ENDIF
  FreeDosObject(DOS_FIB, fib)
  UnLock(lock)
  IF EstrLen(path) > 0
    IF buf := String(ARTMAX)
      IF readart(path, buf) = 0 THEN buf := NIL
    ENDIF
  ENDIF
ENDPROC buf

PROC countlines(buf, cap)
  DEF p:PTR TO CHAR, len, i, n
  IF buf = NIL THEN RETURN 0
  p := buf
  len := EstrLen(buf)
  n := 1
  FOR i := 0 TO len - 1
    IF p[i] = 10 THEN n++
  ENDFOR
  IF p[len-1] = 10 THEN n--    -> trailing newline, no extra row
  IF n > cap THEN n := cap
ENDPROC n

PROC pickheader()
  IF hdrbuf THEN RETURN
  hdrbuf := loadart(hdrdir)
  hdrlines := countlines(hdrbuf, HDRLINEMAX)
ENDPROC

-> find the largest run of art rows with no visible characters in the
-> central columns 8-71 - that run becomes the content band laid out
-> in (result in bandr0/bandr1 = art row indexes, -1 = none)
PROC scanband(buf, nlines)
  DEF p:PTR TO CHAR, len, i, c, col, row, v,
      busy[72]:ARRAY OF CHAR, cur0, curlen, best0, bestlen
  bandr0 := -1
  bandr1 := -1
  IF buf = NIL THEN RETURN
  FOR i := 0 TO BGLINEMAX - 1
    busy[i] := FALSE
  ENDFOR
  p := buf
  len := EstrLen(buf)
  col := 0
  row := 0
  i := 0
  WHILE (i < len) AND (row < nlines)
    c := p[i]
    IF c = 27    -> ESC: consume the sequence, honour column skips
      i++
      IF (i < len) AND (p[i] = "[")
        i++
        v := 0
        c := IF i < len THEN p[i] ELSE 0
        WHILE ((c >= "0") AND (c <= "9")) OR (c = ";")
          IF c = ";"
            v := 0
          ELSE
            v := (v * 10) + (c - "0")
          ENDIF
          i++
          c := IF i < len THEN p[i] ELSE 0
        ENDWHILE
        IF c <> 0 THEN i++
        IF c = "C" THEN col := col + (IF v = 0 THEN 1 ELSE v)
      ENDIF
    ELSEIF c = 10
      col := 0
      row++
      i++
    ELSEIF c = 13
      i++
    ELSEIF c = 32
      col++
      i++
    ELSEIF c > 32
      IF (col >= 8) AND (col <= 71) THEN busy[row] := TRUE
      col++
      i++
    ELSE
      i++
    ENDIF
  ENDWHILE
  cur0 := -1
  curlen := 0
  best0 := -1
  bestlen := 0
  FOR i := 0 TO nlines - 1
    IF busy[i] = FALSE
      IF cur0 = -1 THEN cur0 := i
      curlen++
      IF curlen > bestlen
        best0 := cur0
        bestlen := curlen
      ENDIF
    ELSE
      cur0 := -1
      curlen := 0
    ENDIF
  ENDFOR
  IF bestlen >= 4    -> anything smaller is useless for a menu
    bandr0 := best0
    bandr1 := (best0 + bestlen) - 1
  ENDIF
ENDPROC

-> pick a background. A rotation directory is filtered by screen fit:
-> candidates are tried from a random start and only art whose line
-> count fits the screen height is accepted (a plain file is used
-> as-is). Needs the screen open, so this runs after openui().
PROC pickbg()
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, count, start, try, n,
      path[340]:STRING, ds[3]:ARRAY OF LONG, fit=FALSE
  IF bgbuf THEN RETURN
  IF EstrLen(bgpath) = 0 THEN RETURN
  IF (lock := Lock(bgpath, SHARED_LOCK)) = NIL THEN RETURN
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL
    UnLock(lock)
    RETURN
  ENDIF
  count := countfiles(lock, fib, FALSE)
  IF count = -1    -> a plain file: use it as-is (too-tall art clips)
    FreeDosObject(DOS_FIB, fib)
    UnLock(lock)
    IF bgbuf := loadart(bgpath)
      bglines := countlines(bgbuf, BGLINEMAX)
      scanband(bgbuf, bglines)
    ENDIF
    RETURN
  ENDIF
  IF count > 0
    IF bgbuf := String(ARTMAX)
      DateStamp(ds)
      start := Mod(ds[1] + ds[2], count)
      try := 0
      WHILE (try < count) AND (fit = FALSE)
        n := Mod(start + try, count)
        IF nthfile(lock, fib, n, FALSE)
          StrCopy(path, bgpath)
          AddPart(path, fib.filename, 336)
          SetStr(path, StrLen(path))
          IF readart(path, bgbuf) > 0
            bglines := countlines(bgbuf, BGLINEMAX)
            -> must fit the screen and be tall enough to be real art
            IF (bglines >= 4) AND ((bglines * 8) <= winh) THEN fit := TRUE
          ENDIF
        ENDIF
        try++
      ENDWHILE
      IF fit = FALSE THEN bgbuf := NIL    -> nothing fits this screen
    ENDIF
  ENDIF
  FreeDosObject(DOS_FIB, fib)
  UnLock(lock)
  IF bgbuf THEN scanband(bgbuf, bglines)
ENDPROC

-> the compiled-in LTX frame shown on the config screen: copy the
-> static bytes into an estring and find its content band. Runs
-> before pickbg so bandr0/bandr1 end up holding the menu art's band.
PROC initcfgart()
  IF (cfgbuf := String(ARTMAX)) = NIL THEN RETURN
  CopyMem({cfgart}, cfgbuf, CFGARTLEN)
  SetStr(cfgbuf, CFGARTLEN)
  cfglines := countlines(cfgbuf, BGLINEMAX)
  scanband(cfgbuf, cfglines)
  cfgr0 := bandr0
  cfgr1 := bandr1
ENDPROC

-> count ProTracker modules (name.mod / mod.name) in a directory and
-> all its subdirectories, up to 4 levels deep. Path buffers come
-> from the heap so recursion barely touches the stack.
PROC countmods(dirpath, depth)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, n=0, sub
  IF depth > 4 THEN RETURN 0
  IF (lock := Lock(dirpath, SHARED_LOCK)) = NIL THEN RETURN 0
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL
    UnLock(lock)
    RETURN 0
  ENDIF
  IF Examine(lock, fib)
    IF fib.direntrytype > 0
      WHILE ExNext(lock, fib)
        IF fib.direntrytype < 0
          IF ismodname(fib.filename) THEN n++
        ELSE
          IF sub := String(340)
            StrCopy(sub, dirpath)
            AddPart(sub, fib.filename, 336)
            SetStr(sub, StrLen(sub))
            n := n + countmods(sub, depth + 1)
            DisposeLink(sub)
          ENDIF
        ENDIF
      ENDWHILE
    ENDIF
  ENDIF
  FreeDosObject(DOS_FIB, fib)
  UnLock(lock)
ENDPROC n

-> walk the same tree in the same order; when the global modcounter
-> reaches zero the matching file's full path is left in muspick
PROC findmod(dirpath, depth)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, sub, found=FALSE
  IF depth > 4 THEN RETURN FALSE
  IF (lock := Lock(dirpath, SHARED_LOCK)) = NIL THEN RETURN FALSE
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL
    UnLock(lock)
    RETURN FALSE
  ENDIF
  IF Examine(lock, fib)
    IF fib.direntrytype > 0
      WHILE (found = FALSE) AND (ExNext(lock, fib) <> 0)
        IF fib.direntrytype < 0
          IF ismodname(fib.filename)
            IF modcounter = 0
              StrCopy(muspick, dirpath)
              AddPart(muspick, fib.filename, 336)
              SetStr(muspick, StrLen(muspick))
              found := TRUE
            ELSE
              modcounter--
            ENDIF
          ENDIF
        ELSE
          IF sub := String(340)
            StrCopy(sub, dirpath)
            AddPart(sub, fib.filename, 336)
            SetStr(sub, StrLen(sub))
            found := findmod(sub, depth + 1)
            DisposeLink(sub)
          ENDIF
        ENDIF
      ENDWHILE
    ENDIF
  ENDIF
  FreeDosObject(DOS_FIB, fib)
  UnLock(lock)
ENDPROC found

-> start playing a random ProTracker module from MUSIC (a directory
-> and all its subdirectories are scanned for name.mod / mod.name
-> files; a plain file is used as-is). Needs ptreplay.library in
-> LIBS: - silently no music if it is not there.
PROC startmusic()
  DEF lock, fib:PTR TO fileinfoblock, count, idx, isdir=FALSE,
      path[340]:STRING, ds[3]:ARRAY OF LONG
  IF ptmod THEN RETURN
  IF musmode = MUS_OFF THEN RETURN
  IF EstrLen(muspath) = 0 THEN RETURN
  IF ptreplaybase = NIL
    IF (ptreplaybase := OpenLibrary('ptreplay.library', 0)) = NIL THEN RETURN
  ENDIF
  -> file or directory?
  IF (lock := Lock(muspath, SHARED_LOCK)) = NIL THEN RETURN
  IF fib := AllocDosObject(DOS_FIB, NIL)
    IF Examine(lock, fib)
      IF fib.direntrytype > 0 THEN isdir := TRUE
    ENDIF
    FreeDosObject(DOS_FIB, fib)
  ENDIF
  UnLock(lock)
  StrCopy(path, '')
  IF isdir
    count := countmods(muspath, 0)
    IF count > 0
      DateStamp(ds)
      idx := Mod(ds[1] + ds[2], count)
      -> the jukebox should not repeat the same module back to back
      IF (idx = lastmus) AND (count > 1) THEN idx := Mod(idx + 1, count)
      lastmus := idx
      modcounter := idx
      IF findmod(muspath, 0) THEN StrCopy(path, muspick)
    ENDIF
  ELSE
    StrCopy(path, muspath)
  ENDIF
  IF EstrLen(path) > 0
    IF ptmod := PtLoadModule(path)
      IF musbit = -1 THEN musbit := AllocSignal(-1)
      -> signal us when the module wraps, so we can jukebox
      IF musbit <> -1 THEN PtInstallBits(ptmod, musbit, -1, -1, -1)
      PtPlay(ptmod)
    ENDIF
  ENDIF
ENDPROC

-> jukebox: called from the INTUITICKS handlers - in RANDOM mode,
-> when the playing module has wrapped around, swap in another
-> random one. In REPEAT mode the module just keeps looping.
PROC checkjuke()
  DEF mask
  IF musmode <> MUS_RANDOM THEN RETURN
  IF ptmod = NIL THEN RETURN
  IF musbit = -1 THEN RETURN
  mask := Shl(1, musbit)
  IF SetSignal(0, mask) AND mask
    stopmusic()
    startmusic()
  ENDIF
ENDPROC

PROC stopmusic()
  IF ptmod
    PtStop(ptmod)
    PtUnloadModule(ptmod)
    ptmod := NIL
  ENDIF
ENDPROC

-> full music shutdown - MUST run before the chosen item is launched
-> so audio and the CIA timer are free again
PROC shutmusic()
  stopmusic()
  IF musbit <> -1
    FreeSignal(musbit)
    musbit := -1
  ENDIF
  IF ptreplaybase
    CloseLibrary(ptreplaybase)
    ptreplaybase := NIL
  ENDIF
ENDPROC

-> set palette and text pen for the current style (own screen only;
-> the fallback window lives on someone else's screen)
PROC applystyle()
  DEF pal
  IF ownscr = FALSE THEN RETURN
  IF style = STYLE_LIGHT
    -> grey bg, black text; 2-7 keep the ANSI colours
    pal := [$0AAA,$0000,$02C2,$0EE2,$055E,$0D2D,$02DD,$0EEE]:INT
    txtpen := 1
  ELSE
    -> classic ANSI 8-colour palette: black red green yellow blue
    -> magenta cyan white
    pal := [$0000,$0E22,$02C2,$0EE2,$055E,$0D2D,$02DD,$0EEE]:INT
    txtpen := 7
  ENDIF
  LoadRGB4(ViewPortAddress(win), pal, 8)
ENDPROC

PROC openui()
  DEF l, t[8]:STRING
  NEW ta
  ta.style := 0
  ta.flags := 0
  -> a FONT from the config is tried via diskfont.library; anything
  -> missing falls back to ROM Topaz/8 - a boot menu must never die
  -> over a font
  IF EstrLen(fontname) > 0
    StrCopy(fullfont, fontname)
    l := EstrLen(fullfont)
    IF l >= 5
      MidStr(t, fullfont, l - 5, 5)
      LowerStr(t)
    ENDIF
    IF StrCmp(t, '.font') = FALSE THEN StrAdd(fullfont, '.font')
    IF diskfontbase := OpenLibrary('diskfont.library', 0)
      ta.name := fullfont
      ta.ysize := fsize
      tf := OpenDiskFont(ta)
      CloseLibrary(diskfontbase)
      diskfontbase := NIL
    ENDIF
  ENDIF
  IF tf = NIL
    ta.name := 'topaz.font'
    ta.ysize := 8
    IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
  ENDIF
  scr := OpenScreenTagList(NIL,
    [SA_LIKEWORKBENCH, TRUE,
     SA_DEPTH,     3,
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     SA_TITLE,     'CMenu',
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
       WA_IDCMP,    IDCMP_RAWKEY OR IDCMP_VANILLAKEY OR IDCMP_INTUITICKS,
       TAG_DONE,    NIL])
  ELSE
    -> fallback: window on the public screen, no palette of our own
    ownscr := FALSE
    txtpen := 1
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
       WA_IDCMP,    IDCMP_RAWKEY OR IDCMP_VANILLAKEY OR IDCMP_INTUITICKS,
       TAG_DONE,    NIL])
    UnlockPubScreen(NIL, scr)
    scr := NIL
  ENDIF
  IF win = NIL THEN Throw("UI", 'window')
  rp := win.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  softmask := AskSoftStyle(rp)
  applystyle()
  winw := win.width
  winh := win.height
  rowh := tf.ysize + 2
  baseline := tf.baseline
  clrx0 := 0
  clrx1 := winw - 1
  titley := rowh
  warny  := titley + (rowh * 2)
  helpy  := winh - (rowh * 2)
  cnty   := helpy - (rowh * 2)
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

-> centered text at row top y, current pens
PROC ctext(s, y)
  DEF tl, x
  tl := TextLength(rp, s, StrLen(s))
  x := (winw - tl) / 2
  IF x < 0 THEN x := 0
  Move(rp, x, y + baseline + 1)
  Text(rp, s, StrLen(s))
ENDPROC

-> clear a text row, clipped to the content area (full width normally,
-> the art's interior in background mode so the art is never wiped)
PROC clearline(y)
  SetAPen(rp, 0)
  RectFill(rp, clrx0, y, clrx1, y + rowh - 1)
ENDPROC

-> the selection is marked with > and < flanking the item, always at
-> the width of the widest menu item plus one space on each side, so
-> the markers sit at the same columns for every item
PROC drawitem(i, selected)
  DEF y, s, tl, x
  y := starty + (i * rowh)
  s := names[i]
  tl := TextLength(rp, s, EstrLen(s))
  x := (winw - tl) / 2
  IF x < 8 THEN x := 8
  clearline(y)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x, y + baseline + 1)
  Text(rp, s, EstrLen(s))
  IF selected THEN drawmarks(i, TRUE)
ENDPROC

-> draw or erase just the > < marker cells of one row - navigation
-> touches nothing else, so moving the selection cannot flicker
PROC drawmarks(i, on)
  DEF y, lx, rx
  y := starty + (i * rowh)
  lx := ((winw - menumaxw) / 2) - 16
  rx := ((winw + menumaxw) / 2) + 8
  IF on
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
    Move(rp, lx, y + baseline + 1)
    Text(rp, '>', 1)
    Move(rp, rx, y + baseline + 1)
    Text(rp, '<', 1)
  ELSE
    SetAPen(rp, 0)
    RectFill(rp, lx, y, lx + 7, y + rowh - 1)
    RectFill(rp, rx, y, rx + 7, y + rowh - 1)
  ENDIF
ENDPROC

PROC drawmenu(sel)
  DEF i
  FOR i := 0 TO nitems - 1
    drawitem(i, i = sel)
  ENDFOR
ENDPROC

PROC drawcountdown()
  clearline(cnty)
  IF bandmode
    StringF(cbuf, 'Starting "\s" in \d', names[defitem - 1], secs)
  ELSE
    StringF(cbuf, 'Starting "\s" in \d - press any key to stop',
            names[defitem - 1], secs)
  ENDIF
  SetAPen(rp, txtpen)
  ctext(cbuf, cnty)
ENDPROC

PROC stopcount()
  IF counting
    counting := FALSE
    clearline(cnty)
  ENDIF
ENDPROC

-> draw ANSI/ASCII art. Understands SGR (ESC[...m: 0 reset, 1 bold,
-> 4 underline, 30-37 fg colour) and cursor-forward (ESC[nC); other
-> sequences are consumed and ignored. Colours only render in ANSI
-> style on the own screen; otherwise they are stripped but the
-> column skips still apply, so the art keeps its shape.
PROC renderart(buf, cap, top, lh)
  DEF p:PTR TO CHAR, len, i, j, c, col, row, x0, fg, sty,
      pv[8]:ARRAY OF LONG, np, v, colours
  colours := (style = STYLE_ANSI) AND ownscr
  p := buf
  len := EstrLen(buf)
  x0 := (winw - 640) / 2    -> art is drawn for 80 columns
  IF x0 < 0 THEN x0 := 0
  fg := 7
  sty := 0
  SetSoftStyle(rp, 0, softmask)
  SetAPen(rp, txtpen)
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
          IF colours
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
      -> draw the whole run of printable characters in one Text()
      -> call - per-character rendering is visibly slow on a 68000
      j := i
      WHILE (j < len) AND (p[j] >= 32)
        j++
      ENDWHILE
      Move(rp, x0 + (col * 8), top + (row * lh) + baseline)
      Text(rp, p + i, j - i)
      col := col + (j - i)
      i := j
    ELSE
      i++
    ENDIF
  ENDWHILE
  SetSoftStyle(rp, 0, softmask)
  SetAPen(rp, txtpen)
ENDPROC

PROC drawall(sel)
  DEF menutop, bgtop, x0, i, tl
  menumaxw := 0
  FOR i := 0 TO nitems - 1
    tl := TextLength(rp, names[i], EstrLen(names[i]))
    IF tl > menumaxw THEN menumaxw := tl
  ENDFOR
  clrx0 := 0
  clrx1 := winw - 1
  bandmode := FALSE
  helpy := winh - (rowh * 2)
  cnty  := helpy - (rowh * 2)
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  SetAPen(rp, txtpen)
  menutop := warny
  -> the background is only used if it loaded AND its free interior
  -> has room for the menu; anything less falls back to the header,
  -> and failing that to the plain title
  IF bgbuf AND showbg
    IF bandr0 >= 0
      IF (((bandr1 - bandr0) + 1) * 8) >= ((nitems + 3) * rowh)
        bandmode := TRUE
      ENDIF
    ENDIF
  ENDIF
  IF bandmode
    bgtop := (winh - (bglines * 8)) / 2
    IF bgtop < 0 THEN bgtop := 0
    renderart(bgbuf, BGLINEMAX, bgtop, 8)
    x0 := (winw - 640) / 2
    IF x0 < 0 THEN x0 := 0
    clrx0 := x0 + 64          -> art columns 8-71: the free interior
    clrx1 := (x0 + 576) - 1
    menutop := bgtop + (bandr0 * 8)
    helpy := (bgtop + ((bandr1 + 1) * 8)) - rowh
    cnty := helpy - rowh
  ELSEIF hdrbuf AND showhdr
    renderart(hdrbuf, HDRLINEMAX, 4, rowh)
    menutop := 4 + ((hdrlines + 1) * rowh)
  ELSE
    ctext('CMenu 0.4', titley)
  ENDIF
  IF fallbk THEN ctext('S:CMenu/Config missing or empty - built-in menu', warny)
  starty := menutop + ((cnty - menutop - (nitems * rowh)) / 2)
  IF starty < menutop THEN starty := menutop
  drawmenu(sel)
  IF counting THEN drawcountdown()
  SetAPen(rp, txtpen)
  IF bandmode
    ctext('Up/Down  Enter = start  1-0  C = config  Esc', helpy)
  ELSE
    ctext('Up/Down = select   Enter = start   1-0 = direct   C = config   Esc = quit', helpy)
  ENDIF
ENDPROC

-> ---------- config screen ----------

-> the title row lives on the art below the band and is drawn JAM2
-> without clearing, so everything rendered there is padded to a
-> constant width - the old text is erased, the frame around it is not
PROC titlemsg(s)
  DEF sl
  sl := StrLen(s)
  IF sl > 44 THEN sl := 44
  StrCopy(cbuf, '')
  WHILE EstrLen(cbuf) < ((44 - sl) / 2)
    StrAdd(cbuf, ' ')
  ENDWHILE
  StrAdd(cbuf, s, sl)
  WHILE EstrLen(cbuf) < 44
    StrAdd(cbuf, ' ')
  ENDWHILE
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  ctext(cbuf, ctity)
ENDPROC

PROC drawtitle(changed)
  msgticks := 0
  titlemsg(IF changed THEN 'CMenu Config  *unsaved*' ELSE 'CMenu Config')
ENDPROC

-> status messages replace the title for a couple of seconds; the
-> INTUITICKS handler brings the title back
PROC showmsg(s)
  titlemsg(s)
  msgticks := 25    -> ~2.5 seconds at ~10 ticks/second
ENDPROC

PROC drawinput(prompt, buf, y)
  DEF maxc, pl, bl, off, s:PTR TO CHAR
  clearline(y)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  pl := StrLen(prompt)
  bl := EstrLen(buf)
  maxc := (((clrx1 - clrx0) - 16) / 8) - 1    -> fits the content area
  off := 0
  IF (pl + bl) > maxc THEN off := (pl + bl) - maxc    -> show the tail
  s := buf
  Move(rp, clrx0 + 8, y + baseline + 1)
  Text(rp, prompt, pl)
  Text(rp, s + off, bl - off)
  SetAPen(rp, 0)
  SetBPen(rp, txtpen)
  Text(rp, ' ', 1)    -> block cursor
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
ENDPROC

-> in-window line editor: type/backspace, Enter accepts (returns 1),
-> Esc cancels (returns 0, buf is left as typed - caller keeps a backup)
PROC lineinput(prompt, buf, max, y)
  DEF class, code, l, res=-2, s:PTR TO CHAR
  s := buf
  drawinput(prompt, buf, y)
  WHILE res = -2
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      IF code = 13
        res := 1
      ELSEIF code = 27
        res := 0
      ELSEIF code = 8
        l := EstrLen(buf)
        IF l > 0
          SetStr(buf, l - 1)
          drawinput(prompt, buf, y)
        ENDIF
      ELSEIF (code >= 32) AND (code <> 127) AND (code <= 255)
        l := EstrLen(buf)
        IF l < max
          s[l] := code
          SetStr(buf, l + 1)
          drawinput(prompt, buf, y)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
  clearline(y)
ENDPROC res

-> one config row: default marker, name column, path column - all
-> relative to the content area so the table sits inside the frame
PROC drawcitem(i, selected)
  DEF y, nl, pl, maxp
  y := cstarty + (i * rowh)
  clearline(y)
  IF selected
    SetAPen(rp, txtpen)
    RectFill(rp, clrx0, y, clrx1, y + rowh - 1)
    SetAPen(rp, 0)
    SetBPen(rp, txtpen)
  ELSE
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
  ENDIF
  IF (i + 1) = defitem
    Move(rp, clrx0 + 24, y + baseline + 1)
    Text(rp, '*', 1)
  ENDIF
  nl := EstrLen(names[i])
  IF nl > 21 THEN nl := 21
  Move(rp, clrx0 + 40, y + baseline + 1)
  Text(rp, names[i], nl)
  maxp := ((clrx1 - clrx0) - 232) / 8
  pl := EstrLen(paths[i])
  IF pl > maxp THEN pl := maxp
  IF pl > 0
    Move(rp, clrx0 + 224, y + baseline + 1)
    Text(rp, paths[i], pl)
  ENDIF
  SetBPen(rp, 0)
ENDPROC

PROC drawcitems(csel)
  DEF i
  FOR i := 0 TO nitems - 1
    drawcitem(i, i = csel)
  ENDFOR
ENDPROC

-> the settings row plus the title row (which doubles as the unsaved
-> indicator; constant width so JAM2 rendering erases the old state
-> without clearing the art around it)
PROC drawmeta(changed)
  DEF ms, ss
  clearline(metay)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  ss := 'Dark'
  IF style = STYLE_LIGHT THEN ss := 'Light'
  IF style = STYLE_ANSI THEN ss := 'Ansi'
  ms := 'Off'
  IF musmode = MUS_RANDOM THEN ms := 'Random'
  IF musmode = MUS_REPEAT THEN ms := 'Repeat'
  StringF(cbuf, 'Default: \d  Timeout: \d  Style: \s  Hdr: \s  Bg: \s  Mus: \s',
          defitem, timeout, ss,
          IF showhdr THEN 'On' ELSE 'Off',
          IF showbg THEN 'On' ELSE 'Off',
          ms)
  ctext(cbuf, metay)
  drawtitle(changed)
ENDPROC

-> config screen per the mockup: the compiled-in LTX frame is ALWAYS
-> drawn (whatever the user's menu art settings), with everything
-> living inside its interior - three blank art rows below the logo,
-> then the item table, and the settings/help stack anchored at the
-> band bottom with the title on the art row just below it. The frame
-> is our own, so the full width between its borders (columns 1-78)
-> is known to be free on band rows. If the screen is too small for
-> the frame, the same layout uses the whole screen instead.
PROC drawcontrol(csel, changed)
  DEF artok=FALSE, bgtop, bandtop, bandbot, x0
  IF cfgbuf
    IF cfgr0 >= 0
      bgtop := (winh - (cfglines * 8)) / 2
      IF bgtop < 0 THEN bgtop := 0
      bandtop := (bgtop + (cfgr0 * 8)) + 24    -> 3 blank rows under logo
      bandbot := bgtop + ((cfgr1 + 1) * 8)
      IF (cfglines * 8) <= winh
        IF (bandbot - bandtop) >= ((nitems + 7) * rowh) THEN artok := TRUE
      ENDIF
    ENDIF
  ENDIF
  clrx0 := 0
  clrx1 := winw - 1
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  SetAPen(rp, txtpen)
  IF artok
    renderart(cfgbuf, BGLINEMAX, bgtop, 8)
    x0 := (winw - 640) / 2
    IF x0 < 0 THEN x0 := 0
    clrx0 := x0 + 8            -> our frame: columns 1-78 are usable
    clrx1 := (x0 + 632) - 1
    cstarty := bandtop
    ctity := bandbot - 1
    IF (ctity + rowh) > winh THEN ctity := winh - rowh
  ELSE
    cstarty := warny
    ctity := winh - rowh
  ENDIF
  ch2y := ctity - (rowh * 2)
  ch1y := ch2y - (rowh * 2)
  metay := ch1y - (rowh * 2)
  -> the add/edit/timeout prompt lives on the middle of the three
  -> blank rows between the logo and the first item
  IF artok
    inputy := cstarty - 16
  ELSE
    inputy := cstarty - rowh
  ENDIF
  drawcitems(csel)
  drawmeta(changed)
  SetAPen(rp, txtpen)
  ctext('Up/Down=Select Shift+Up/Down=Move Space=Default S=Save Esc=Back', ch1y)
  ctext('A=Add E=Edit D=Delete T=Timeout C=Style H=Header B=Background M=Music', ch2y)
ENDPROC

PROC wline(fh, s) IS Write(fh, s, StrLen(s))

PROC saveconfig()
  DEF fh, i, buf[420]:STRING, ok=FALSE, lock
  -> make sure the S:CMenu drawer exists before writing into it
  IF lock := Lock('S:CMenu', SHARED_LOCK)
    UnLock(lock)
  ELSE
    IF lock := CreateDir('S:CMenu') THEN UnLock(lock)
  ENDIF
  IF fh := Open('S:CMenu/Config', NEWFILE)
    ok := TRUE
    IF wline(fh, '; CMenu configuration - Name|path, DEFAULT n, TIMEOUT secs,\n; STYLE LIGHT|DARK|ANSI, HEADERS [ON|OFF] dir, BACKGROUND [ON|OFF] path\n') < 0 THEN ok := FALSE
    FOR i := 0 TO nitems - 1
      StringF(buf, '\s|\s\n', names[i], paths[i])
      IF wline(fh, buf) < 0 THEN ok := FALSE
    ENDFOR
    StringF(buf, 'DEFAULT \d\nTIMEOUT \d\nSTYLE \s\n', defitem, timeout,
            stylename())
    IF wline(fh, buf) < 0 THEN ok := FALSE
    IF EstrLen(fontname) > 0
      StringF(buf, 'FONT \s/\d\n', fontname, fsize)
      IF wline(fh, buf) < 0 THEN ok := FALSE
    ENDIF
    IF EstrLen(hdrdir) > 0
      StringF(buf, 'HEADERS \s \s\n',
              IF showhdr THEN 'ON' ELSE 'OFF', hdrdir)
      IF wline(fh, buf) < 0 THEN ok := FALSE
    ENDIF
    IF EstrLen(bgpath) > 0
      StringF(buf, 'BACKGROUND \s \s\n',
              IF showbg THEN 'ON' ELSE 'OFF', bgpath)
      IF wline(fh, buf) < 0 THEN ok := FALSE
    ENDIF
    IF EstrLen(muspath) > 0
      StringF(buf, 'MUSIC \s \s\n', musname(), muspath)
      IF wline(fh, buf) < 0 THEN ok := FALSE
    ENDIF
    Close(fh)
  ENDIF
ENDPROC ok

PROC controlscreen()
  DEF csel, class, code, done=FALSE, changed=FALSE, shifted, d, j,
      nbuf[64]:STRING, pbuf[304]:STRING, tbuf[8]:STRING
  csel := defitem - 1
  drawcontrol(csel, changed)
  WHILE done = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_INTUITICKS
      checkjuke()
      IF msgticks > 0
        msgticks--
        IF msgticks = 0 THEN drawtitle(changed)
      ENDIF
    ELSEIF class = IDCMP_VANILLAKEY
      IF code = 27
        done := TRUE
      ELSEIF (code = "a") OR (code = "A")
        IF nitems >= MAXITEMS
          showmsg('menu is full (10 items)')
        ELSE
          StrCopy(nbuf, '')
          IF lineinput('Name: ', nbuf, NAMELEN, inputy) AND (EstrLen(nbuf) > 0)
            StrCopy(pbuf, '')
            IF lineinput('Path: ', pbuf, CPATHLEN, inputy) AND (EstrLen(pbuf) > 0)
              additem(nbuf, pbuf)
              drawcitem(csel, FALSE)
              csel := nitems - 1
              drawcitem(csel, TRUE)
              changed := TRUE
              drawmeta(changed)
            ENDIF
          ENDIF
        ENDIF
      ELSEIF (code = "e") OR (code = "E") OR (code = 13)
        StrCopy(nbuf, names[csel])
        IF lineinput('Name: ', nbuf, NAMELEN, inputy) AND (EstrLen(nbuf) > 0)
          StrCopy(names[csel], nbuf)
          changed := TRUE
        ENDIF
        StrCopy(pbuf, paths[csel])
        IF lineinput('Path: ', pbuf, CPATHLEN, inputy) AND (EstrLen(pbuf) > 0)
          StrCopy(paths[csel], pbuf)
          changed := TRUE
        ENDIF
        drawcitem(csel, TRUE)
        drawmeta(changed)
      ELSEIF (code = "d") OR (code = "D")
        IF nitems <= 1
          showmsg('cannot delete the last item')
        ELSE
          d := csel
          delitem(d)
          IF csel >= nitems THEN csel := nitems - 1
          FOR j := d TO nitems - 1    -> rows below shifted up
            drawcitem(j, j = csel)
          ENDFOR
          clearline(cstarty + (nitems * rowh))    -> old last row
          IF csel < d THEN drawcitem(csel, TRUE)
          changed := TRUE
          drawmeta(changed)
        ENDIF
      ELSEIF code = " "
        defitem := csel + 1
        changed := TRUE
        drawcitems(csel)
        drawmeta(changed)
      ELSEIF (code = "t") OR (code = "T")
        StringF(tbuf, '\d', timeout)
        IF lineinput('Timeout (seconds, 0 = wait): ', tbuf, 3, inputy)
          timeout := Val(tbuf)
          IF timeout < 0 THEN timeout := 0
          IF timeout > MAXTIMEOUT THEN timeout := MAXTIMEOUT
          changed := TRUE
        ENDIF
        drawmeta(changed)
      ELSEIF (code = "c") OR (code = "C")
        style++
        IF style > STYLE_ANSI THEN style := STYLE_LIGHT
        applystyle()
        changed := TRUE
        drawcontrol(csel, changed)
      ELSEIF (code = "h") OR (code = "H")
        IF EstrLen(hdrdir) = 0
          showmsg('no HEADERS path in the config')
        ELSE
          showhdr := IF showhdr THEN FALSE ELSE TRUE
          IF showhdr
            showbg := FALSE
            pickheader()
          ENDIF
          changed := TRUE
          drawmeta(changed)
        ENDIF
      ELSEIF (code = "b") OR (code = "B")
        IF EstrLen(bgpath) = 0
          showmsg('no BACKGROUND path in the config')
        ELSE
          showbg := IF showbg THEN FALSE ELSE TRUE
          IF showbg
            showhdr := FALSE
            pickbg()
          ENDIF
          changed := TRUE
          drawmeta(changed)
        ENDIF
      ELSEIF (code = "m") OR (code = "M")
        IF EstrLen(muspath) = 0
          showmsg('no MUSIC path in the config')
        ELSE
          musmode++
          IF musmode > MUS_REPEAT THEN musmode := MUS_OFF
          IF musmode = MUS_OFF
            stopmusic()
          ELSE
            startmusic()
            IF ptmod = NIL THEN showmsg('nothing playing - library or mods missing')
          ENDIF
          changed := TRUE
          drawmeta(changed)
        ENDIF
      ELSEIF (code = "s") OR (code = "S")
        IF saveconfig()
          changed := FALSE
          fallbk := FALSE
          drawmeta(changed)
          showmsg('saved to S:CMenu/Config')
        ELSE
          showmsg('could not write S:CMenu/Config')
        ENDIF
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80    -> key down only, ignore releases
        shifted := MsgQualifier() AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
        IF code = RK_UP
          IF shifted
            IF csel > 0    -> move stops at the edge, no wrapping
              swapitems(csel, csel - 1)
              csel--
              changed := TRUE
              drawcitem(csel, TRUE)
              drawcitem(csel + 1, FALSE)
              drawmeta(changed)
            ENDIF
          ELSE
            drawcitem(csel, FALSE)
            csel := IF csel = 0 THEN nitems - 1 ELSE csel - 1
            drawcitem(csel, TRUE)
          ENDIF
        ELSEIF code = RK_DOWN
          IF shifted
            IF csel < (nitems - 1)
              swapitems(csel, csel + 1)
              csel++
              changed := TRUE
              drawcitem(csel, TRUE)
              drawcitem(csel - 1, FALSE)
              drawmeta(changed)
            ENDIF
          ELSE
            drawcitem(csel, FALSE)
            csel := IF csel = (nitems - 1) THEN 0 ELSE csel + 1
            drawcitem(csel, TRUE)
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

-> ---------- menu ----------

-> returns item index to launch, or -1 for exit without launching
PROC eventloop()
  DEF class, code, sel, idx, ticks=0, res=-2
  IF noconf    -> no config file yet: set the menu up first
    noconf := FALSE
    controlscreen()
  ENDIF
  sel := defitem - 1
  IF timeout > 0
    counting := TRUE
    secs := timeout
  ENDIF
  drawall(sel)
  WHILE res = -2
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_INTUITICKS
      checkjuke()
      IF counting
        ticks++
        IF ticks >= 10    -> intuiticks arrive ~10/sec
          ticks := 0
          secs--
          IF secs <= 0
            res := defitem - 1
          ELSE
            drawcountdown()
          ENDIF
        ENDIF
      ENDIF
    ELSEIF class = IDCMP_VANILLAKEY
      stopcount()
      IF code = 13
        res := sel
      ELSEIF code = 27
        res := -1
      ELSEIF (code >= "1") AND (code <= "9")
        idx := code - "1"
        IF idx < nitems THEN res := idx
      ELSEIF code = "0"
        IF nitems = MAXITEMS THEN res := 9
      ELSEIF (code = "c") OR (code = "C")
        controlscreen()
        IF sel >= nitems THEN sel := nitems - 1
        drawall(sel)
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80    -> key down only, ignore releases
        stopcount()
        IF code = RK_UP
          drawmarks(sel, FALSE)
          sel := IF sel = 0 THEN nitems - 1 ELSE sel - 1
          drawmarks(sel, TRUE)
        ELSEIF code = RK_DOWN
          drawmarks(sel, FALSE)
          sel := IF sel = (nitems - 1) THEN 0 ELSE sel + 1
          drawmarks(sel, TRUE)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC res

PROC main() HANDLE
  DEF idx, cmd[360]:STRING
  loadconfig()
  initcfgart()    -> before pickbg, which reuses the band scanner
  startmusic()    -> chip music while the menu is up
  openui()    -> art loading needs the screen size for fit filtering
  IF showhdr THEN pickheader()
  IF showbg THEN pickbg()
  idx := eventloop()
  closeui()
  shutmusic()    -> free audio and CIA before launching anything
  IF idx >= 0
    -> launch exactly the way CBoot launches boot scripts: make sure
    -> the script bit is set, then hand the quoted path to the shell
    -> (binaries LoadSeg and run; s-bit files run as scripts)
    StringF(cmd, 'protect "\s" +srwed', paths[idx])
    Execute(cmd, NIL, NIL)
    StringF(cmd, '"\s"', paths[idx])
    Execute(cmd, NIL, NIL)
  ENDIF
EXCEPT DO
  closeui()
  shutmusic()
  SELECT exception
    CASE "UI"
      WriteF('CMenu: cannot open UI (\s)\n', exceptioninfo)
      rc := 20
    CASE "MEM"
      WriteF('CMenu: out of memory\n')
      rc := 20
  ENDSELECT
  CleanUp(rc)
ENDPROC

-> the LTX frame, compiled in - drawn on the config screen always
cfgart: CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,46,95
  CHAR 32,32,32,95,46,32,32,32,32,32,32,32,32,32,32,95
  CHAR 95,32,32,32,95,95,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,46,95,32,32,32,95
  CHAR 46,10,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 41,40,92,32,47,41,40,32,32,32,32,32,32,32,32,32
  CHAR 47,32,47,32,32,47,32,47,95,32,32,32,32,32,95,95
  CHAR 32,95,95,32,32,32,32,32,32,32,32,32,41,40,92,32
  CHAR 47,41,40,10,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,96,46,32,94,32,46,39,32,32,32,32,32,32,32
  CHAR 95,47,32,32,124,95,47,32,95,95,47,95,95,32,95,47
  CHAR 32,32,124,32,32,92,95,32,32,32,32,32,32,32,96,32
  CHAR 32,94,32,32,39,10,183,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,33,32,161,32,33,32,32,32,32,32,32
  CHAR 32,124,32,32,32,32,124,32,32,32,96,41,32,32,32,124
  CHAR 62,32,32,32,95,32,32,32,60,46,32,32,32,32,32,32
  CHAR 32,33,32,161,32,33,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,183,10,124,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,33,32,32,32,32,32,32,32
  CHAR 32,32,96,45,45,45,45,94,45,45,46,95,95,95,95,95
  CHAR 124,45,45,45,45,124,95,95,95,95,124,32,32,32,32,32
  CHAR 32,32,32,32,33,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,124,10,166,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,10,58,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,183,10,124,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,124,10,124,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,124,10,124,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,124,10,124,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,124,10,124,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,124,10,124
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,124,10
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 10,124,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 124,10,124,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,124,10,124,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,124,10,124,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,124,10,124,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,124,10,124,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,124,10,124,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,124,10,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,10,124,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,124,10,124,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,124,10,124,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,124,10,124,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,124,10,124,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,124,10,124,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,124,10,124
  CHAR 32,32,32,32,32,32,92,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,47,32,32,32,32,32,32,124,10
  CHAR 124,32,32,32,32,32,32,92,92,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,47,47,32,32,32,32,32,32,124
  CHAR 10,96,45,45,45,45,45,45,32,92,45,32,45,45,45,45
  CHAR 45,32,47,45,32,45,45,45,45,45,45,32,45,247,45,32
  CHAR 65,32,76,65,84,69,88,32,80,82,79,68,85,67,84,105
  CHAR 79,78,33,32,45,247,45,32,45,45,45,45,45,45,32,45
  CHAR 92,45,45,45,45,45,32,45,47,32,45,45,45,45,45,45
  CHAR 39,10

version: CHAR '$VER: CMenu 0.4 (14.7.26)',0
