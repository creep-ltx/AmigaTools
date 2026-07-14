-> CMenu - full-screen text boot menu for AmigaOS
->
-> Meant to run *before* the normal Startup-Sequence (see
-> example-startup-sequence): it opens its own full-size screen, shows
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
->                       art; default DARK)
->   HEADERS [ON|OFF] dir   (directory with ANSI art headers; one is
->                       picked per run and drawn above the menu.
->                       OFF keeps the dir configured but hides them)
->   BACKGROUND [ON|OFF] path  (full-screen ANSI/ASCII background art
->                       instead of a header; path may be one file or
->                       a directory to rotate. The menu is laid out
->                       inside the art's free interior, which is
->                       auto-detected, so the art is never drawn
->                       over. Background art is line-height 8, so a
->                       PAL screen fits 32 rows - the art must match
->                       the display it is used on)
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
-> S writes S:CMenu/Config back (comment lines in the file do not
-> survive a rewrite), Esc returns to the menu.
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
       'dos/dos'

CONST MAXITEMS=10, NAMELEN=60, CPATHLEN=300, MAXTIMEOUT=999,
      ARTMAX=8000, HDRLINEMAX=12, BGLINEMAX=32,
      STYLE_LIGHT=0, STYLE_DARK=1, STYLE_ANSI=2,
      RK_UP=$4C, RK_DOWN=$4D    -> rawkey codes, cursor up/down

DEF nitems=0, nalloc=0, defitem=1, timeout=0, fallbk=FALSE,
    names[MAXITEMS]:ARRAY OF LONG,
    paths[MAXITEMS]:ARRAY OF LONG,
    hdrdir[304]:STRING, bgpath[304]:STRING,
    style=STYLE_DARK, showhdr=TRUE, showbg=FALSE,
    hdrbuf=NIL, hdrlines=0, bgbuf=NIL, bglines=0,
    bandr0=-1, bandr1=-1, bandmode=FALSE,
    scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    ownscr=FALSE, txtpen=1, softmask=0,
    winw, winh, rowh, baseline, starty, titley, warny, cnty, helpy,
    cstarty, metay, inputy, chelpy, clrx0=0, clrx1=0,
    counting=FALSE, secs=0, menumaxw=0,
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
  ENDIF
ENDPROC

PROC loadconfig()
  DEF fh, eof=FALSE, line[400]:STRING
  StrCopy(hdrdir, '')
  StrCopy(bgpath, '')
  IF fh := Open('S:CMenu/Config', OLDFILE)
    REPEAT
      IF ReadStr(fh, line) = -1 THEN eof := TRUE
      IF EstrLen(line) > 0 THEN parseline(line)
    UNTIL eof
    Close(fh)
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
  IF showbg THEN showhdr := FALSE    -> background wins if both are ON
ENDPROC

-> load an art file: path may be a plain file, or a directory to pick
-> a random file from. Returns an estring with the raw bytes, or NIL.
PROC loadart(artpath)
  DEF lock=NIL, fib=NIL:PTR TO fileinfoblock, count=0, idx, i, fh, len,
      buf=NIL, path[340]:STRING, ds[3]:ARRAY OF LONG, more
  IF EstrLen(artpath) = 0 THEN RETURN NIL
  IF (lock := Lock(artpath, SHARED_LOCK)) = NIL THEN RETURN NIL
  IF (fib := AllocDosObject(DOS_FIB, NIL)) = NIL
    UnLock(lock)
    RETURN NIL
  ENDIF
  StrCopy(path, '')
  IF Examine(lock, fib)
    IF fib.direntrytype > 0    -> a directory: rotate
      WHILE ExNext(lock, fib)
        IF fib.direntrytype < 0 THEN count++
      ENDWHILE
      IF count > 0
        DateStamp(ds)
        idx := Mod(ds[1] + ds[2], count)    -> minutes+ticks, random enough
        Examine(lock, fib)    -> restart the ExNext chain
        -> E's AND does not short-circuit, so ExNext must live in the
        -> loop body: in the condition it would run once more after
        -> i = idx and clobber the fib of the file just picked
        i := -1
        more := TRUE
        WHILE (i < idx) AND more
          IF ExNext(lock, fib)
            IF fib.direntrytype < 0 THEN i++
          ELSE
            more := FALSE
          ENDIF
        ENDWHILE
        IF i = idx
          StrCopy(path, artpath)
          AddPart(path, fib.filename, 336)
          SetStr(path, StrLen(path))
        ENDIF
      ENDIF
    ELSE    -> a plain file: use it directly
      StrCopy(path, artpath)
    ENDIF
  ENDIF
  FreeDosObject(DOS_FIB, fib)
  UnLock(lock)
  IF EstrLen(path) > 0
    IF fh := Open(path, OLDFILE)
      IF buf := String(ARTMAX)
        len := Read(fh, buf, ARTMAX)
        IF len > 0
          SetStr(buf, len)
        ELSE
          buf := NIL
        ENDIF
      ENDIF
      Close(fh)
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

-> find the largest run of background rows with no visible characters
-> in the central columns 8-71 - that run becomes the content band the
-> menu is laid out in (bandr0/bandr1 = art row indexes, -1 = none)
PROC scanband()
  DEF p:PTR TO CHAR, len, i, c, col, row, v,
      busy[40]:ARRAY OF CHAR, cur0, curlen, best0, bestlen
  bandr0 := -1
  bandr1 := -1
  IF bgbuf = NIL THEN RETURN
  FOR i := 0 TO BGLINEMAX - 1
    busy[i] := FALSE
  ENDFOR
  p := bgbuf
  len := EstrLen(bgbuf)
  col := 0
  row := 0
  i := 0
  WHILE (i < len) AND (row < bglines)
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
  FOR i := 0 TO bglines - 1
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

PROC pickbg()
  IF bgbuf THEN RETURN
  bgbuf := loadart(bgpath)
  bglines := countlines(bgbuf, BGLINEMAX)
  scanband()
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
  NEW ta
  ta.name := 'topaz.font'
  ta.ysize := 8
  ta.style := 0
  ta.flags := 0
  IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
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
  chelpy := winh - (rowh * 2)
  cstarty := titley + (rowh * 2)
  metay   := cstarty + ((MAXITEMS + 1) * rowh)
  inputy  := chelpy - (rowh * 2)
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
  IF bgbuf AND showbg
    bgtop := (winh - (bglines * 8)) / 2
    IF bgtop < 0 THEN bgtop := 0
    renderart(bgbuf, BGLINEMAX, bgtop, 8)
    IF bandr0 >= 0
      IF (((bandr1 - bandr0) + 1) * 8) >= ((nitems + 3) * rowh)
        bandmode := TRUE
        x0 := (winw - 640) / 2
        IF x0 < 0 THEN x0 := 0
        clrx0 := x0 + 64          -> art columns 8-71: the free interior
        clrx1 := (x0 + 576) - 1
        menutop := bgtop + (bandr0 * 8)
        helpy := (bgtop + ((bandr1 + 1) * 8)) - rowh
        cnty := helpy - rowh
      ENDIF
    ENDIF
  ELSEIF hdrbuf AND showhdr
    renderart(hdrbuf, HDRLINEMAX, 4, rowh)
    menutop := 4 + ((hdrlines + 1) * rowh)
  ELSE
    ctext('CMenu 0.3', titley)
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

PROC showmsg(s)
  clearline(inputy)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  ctext(s, inputy)
ENDPROC

PROC drawinput(prompt, buf, y)
  DEF maxc, pl, bl, off, s:PTR TO CHAR
  clearline(y)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  pl := StrLen(prompt)
  bl := EstrLen(buf)
  maxc := ((winw - 32) / 8) - 1    -> chars that fit, minus the cursor
  off := 0
  IF (pl + bl) > maxc THEN off := (pl + bl) - maxc    -> show the tail
  s := buf
  Move(rp, 16, y + baseline + 1)
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

PROC drawcitem(i, selected)
  DEF y, nl, pl, maxp
  y := cstarty + (i * rowh)
  clearline(y)
  IF selected
    SetAPen(rp, txtpen)
    RectFill(rp, 8, y, winw - 9, y + rowh - 1)
    SetAPen(rp, 0)
    SetBPen(rp, txtpen)
  ELSE
    SetAPen(rp, txtpen)
    SetBPen(rp, 0)
  ENDIF
  IF (i + 1) = defitem
    Move(rp, 16, y + baseline + 1)
    Text(rp, '*', 1)
  ENDIF
  nl := EstrLen(names[i])
  IF nl > 22 THEN nl := 22
  Move(rp, 32, y + baseline + 1)
  Text(rp, names[i], nl)
  maxp := (winw - 232) / 8
  pl := EstrLen(paths[i])
  IF pl > maxp THEN pl := maxp
  IF pl > 0
    Move(rp, 216, y + baseline + 1)
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

PROC drawmeta(changed)
  clearline(metay)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  StringF(cbuf, 'Default: \d  Timeout: \d  Style: \s  Hdr: \s  Bg: \s\s',
          defitem, timeout, stylename(),
          IF showhdr THEN 'ON' ELSE 'OFF',
          IF showbg THEN 'ON' ELSE 'OFF',
          IF changed THEN '  *unsaved*' ELSE '')
  ctext(cbuf, metay)
ENDPROC

PROC drawcontrol(csel, changed)
  clrx0 := 0
  clrx1 := winw - 1
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  SetAPen(rp, txtpen)
  ctext('CMenu Config', titley)
  drawcitems(csel)
  drawmeta(changed)
  SetAPen(rp, txtpen)
  ctext('Up/Down = select   Shift+Up/Down = move   Space = default', chelpy)
  ctext('A=add  E=edit  D=del  T=timeout  C=style  H=header  B=backgr  S=save  Esc', chelpy + rowh)
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
    IF class = IDCMP_VANILLAKEY
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
          showmsg('no HEADERS directory in the config')
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
  IF showhdr THEN pickheader()
  IF showbg THEN pickbg()
  openui()
  idx := eventloop()
  closeui()
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

version: CHAR '$VER: CMenu 0.3 (14.7.26)',0
