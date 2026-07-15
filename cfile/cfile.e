-> CFile - a two-pane text-style file manager for AmigaOS
->
-> Opens its own 640x256-style screen (SA_LIKEWORKBENCH) and draws a
-> compiled-in 80x31 character frame with two 38-column directory
-> panes side by side. v0.1 is a navigation proof of concept: the
-> left pane starts in DH0:, the right pane in DH1:.
->
-> Keys:
->   Tab         switch the active pane
->   Up/Down     move the selection (the list scrolls at the edges)
->   Right       enter the selected directory
->   Left        back to the parent directory (re-selects where you
->               came from), stops at the device root
->   H           help screen
->   Esc         quit
->
-> The current path of each pane is shown in the frame's border row
-> above the panes. The selection bar (inverted colours, in the active
-> pane only) marks both the selected entry and which pane is active.
-> Directories are listed first (in a different colour on the own
-> screen), then files, both sorted case-insensitively.
->
-> Build: ecompile cfile.e   (E-VO)

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','dos/dos'

CONST CPATHLEN=300, MAXENT=500, VISROWS=22, PANEW=38,
      RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F

DEF enames[1000]:ARRAY OF LONG,   -> entry names, MAXENT slots per pane
    edirs[1000]:ARRAY OF CHAR,    -> nonzero = entry is a directory
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
    ownscr=FALSE, txtpen=1, dirpen=1, errpen=1,
    winw, winh, baseline, x0, top, bordy, panetop,
    prevname[34]:STRING,
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
  StrCopy(ppath[0], 'DH0:')
  StrCopy(ppath[1], 'DH1:')
ENDPROC

PROC addentry(p, name, isdir)
  DEF i
  i := ecount[p]
  IF i >= MAXENT THEN RETURN
  IF i >= ealloc[p]
    IF (enames[(p * MAXENT) + i] := String(34)) = NIL THEN Raise("MEM")
    ealloc[p] := i + 1
  ENDIF
  StrCopy(enames[(p * MAXENT) + i], name)
  edirs[(p * MAXENT) + i] := isdir
  ecount[p] := i + 1
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

-> sort order: directories first, then files, alphabetical within each
PROC entbefore(p, i, j)
  DEF b, di, dj
  b := p * MAXENT
  di := edirs[b + i]
  dj := edirs[b + j]
  IF (di <> 0) AND (dj = 0) THEN RETURN TRUE
  IF (di = 0) AND (dj <> 0) THEN RETURN FALSE
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
        addentry(p, fib.filename, fib.direntrytype > 0)
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
     SA_TITLE,     'CFile',
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
  rp := win.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  IF ownscr
    -> Workbench-style palette: grey background, black text, blue
    -> directories; pens 2-7 keep the ANSI colours (red gives way to
    -> the black text pen)
    LoadRGB4(ViewPortAddress(win),
      [$0AAA,$0000,$02C2,$0EE2,$055E,$0D2D,$02DD,$0EEE]:INT, 8)
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
  baseline := tf.baseline
  x0 := (winw - 640) / 2
  IF x0 < 0 THEN x0 := 0
  top := (winh - 248) / 2    -> the frame is 31 rows of 8 pixels
  IF top < 0 THEN top := 0
  bordy   := top + 40    -> frame row 6: the border above the panes
  panetop := top + 48    -> frame rows 7-28: the listing rows
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
  x := IF p = 0 THEN 8 ELSE 328
ENDPROC x0 + x

-> one row of the compiled-in frame, 1-based
PROC frow(r)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  Move(rp, x0, top + ((r - 1) * 8) + baseline)
  Text(rp, {frameart} + ((r - 1) * 80), 80)
ENDPROC

PROC drawframe()
  DEF r
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  FOR r := 1 TO 31
    frow(r)
  ENDFOR
ENDPROC

-> the pane paths live in the border row above the panes, drawn plain;
-> the selection bar alone shows which pane is active. Deep paths show
-> their tail end, truncated to 32 characters.
PROC drawpaths()
  DEF p, s[40]:STRING, l, x
  frow(6)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  FOR p := 0 TO 1
    l := EstrLen(ppath[p])
    IF l > 32
      MidStr(s, ppath[p], l - 32, 32)
    ELSE
      StrCopy(s, ppath[p])
    ENDIF
    x := IF p = 0 THEN 24 ELSE 344
    Move(rp, x0 + x, bordy + baseline)
    Text(rp, ' ', 1)
    Text(rp, s, EstrLen(s))
    Text(rp, ' ', 1)
  ENDFOR
  SetBPen(rp, 0)
ENDPROC

PROC drawrow(p, r)
  DEF idx, x, y, s, l
  x := panex(p)
  y := panetop + (r * 8)
  idx := etop[p] + r
  SetAPen(rp, 0)
  RectFill(rp, x, y, x + 303, y + 7)
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
  IF l > PANEW THEN l := PANEW
  IF (p = active) AND (idx = esel[p])
    -> the bar keeps the entry's type colour: blue text for a
    -> directory, grey for a file (unless the fallback screen left
    -> dirpen = txtpen, which would vanish into the bar)
    SetAPen(rp, txtpen)
    RectFill(rp, x, y, x + 303, y + 7)
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
  Text(rp, s, l)
  SetBPen(rp, 0)
ENDPROC

PROC drawpane(p)
  DEF r
  FOR r := 0 TO VISROWS - 1
    drawrow(p, r)
  ENDFOR
ENDPROC

PROC drawall()
  drawframe()
  drawpaths()
  drawpane(0)
  drawpane(1)
ENDPROC

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
  IF esel[p] >= (etop[p] + VISROWS)
    etop[p] := esel[p] - VISROWS + 1
    drawpane(p)
  ELSE
    drawrow(p, esel[p] - 1 - etop[p])
    drawrow(p, esel[p] - etop[p])
  ENDIF
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
  IF edirs[i] = 0 THEN RETURN    -> files do nothing in v0.1
  AddPart(ppath[p], enames[i], CPATHLEN - 4)
  SetStr(ppath[p], StrLen(ppath[p]))
  esel[p] := 0
  etop[p] := 0
  readdir(p)
  drawpaths()
  drawpane(p)
ENDPROC

PROC parentdir()
  DEF p, s:PTR TO CHAR, l, i, cut=-1, colon=-1, start, b
  p := active
  s := ppath[p]
  l := EstrLen(ppath[p])
  FOR i := 0 TO l - 1
    IF s[i] = "/" THEN cut := i
    IF s[i] = ":" THEN colon := i
  ENDFOR
  start := IF cut >= 0 THEN cut + 1 ELSE colon + 1
  IF start >= l THEN RETURN    -> already at the device root
  MidStr(prevname, ppath[p], start, l - start)
  SetStr(ppath[p], IF cut >= 0 THEN cut ELSE colon + 1)
  esel[p] := 0
  etop[p] := 0
  readdir(p)
  -> re-select the directory we just came out of
  IF ecount[p] > 0
    b := p * MAXENT
    FOR i := 0 TO ecount[p] - 1
      IF nccmp(enames[b + i], prevname) = 0 THEN esel[p] := i
    ENDFOR
    etop[p] := esel[p] - 10
    IF etop[p] > (ecount[p] - VISROWS) THEN etop[p] := ecount[p] - VISROWS
    IF etop[p] < 0 THEN etop[p] := 0
  ENDIF
  drawpaths()
  drawpane(p)
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

PROC helptext(s, y)
  Move(rp, x0 + 152, y + baseline)
  Text(rp, s, StrLen(s))
ENDPROC

PROC helpscreen()
  DEF y
  SetAPen(rp, 0)
  RectFill(rp, x0 + 8, panetop, x0 + 631, panetop + (VISROWS * 8) - 1)
  SetAPen(rp, txtpen)
  SetBPen(rp, 0)
  y := panetop + 24
  helptext('CFile 0.1', y)
  helptext('Tab ......... switch pane', y + 24)
  helptext('Up/Down ..... move the selection', y + 40)
  helptext('Right ....... enter the selected directory', y + 56)
  helptext('Left ........ back to the parent directory', y + 72)
  helptext('H ........... this help', y + 88)
  helptext('Esc ......... quit', y + 104)
  helptext('press any key', y + 136)
  waitkey()
  drawall()
ENDPROC

PROC eventloop()
  DEF class, code, done=FALSE
  WHILE done = FALSE
    class := WaitIMessage(win)
    code := MsgCode()
    IF class = IDCMP_VANILLAKEY
      IF code = 27
        done := TRUE
      ELSEIF code = 9
        switchpane()
      ELSEIF (code = "h") OR (code = "H")
        helpscreen()
      ENDIF
    ELSEIF class = IDCMP_RAWKEY
      IF code < $80    -> key down only, ignore releases
        IF code = RK_UP
          moveup()
        ELSEIF code = RK_DOWN
          movedown()
        ELSEIF code = RK_RIGHT
          enterdir()
        ELSEIF code = RK_LEFT
          parentdir()
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

PROC main() HANDLE
  initpanes()
  readdir(0)
  readdir(1)
  openui()
  drawall()
  eventloop()
  closeui()
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

-> the frame, compiled in: 31 rows of 80 characters, no separators.
-> Rows 7 and 28 are the mockup's first/last-listing-row markers with
-> the placeholder text blanked out.
frameart: CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,46,95
  CHAR 32,32,32,95,46,32,32,32,32,32,32,32,32,32,95,95
  CHAR 32,32,32,95,95,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,46,95,32,32,32,95,46
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,41,40
  CHAR 92,32,47,41,40,32,32,32,32,32,32,32,32,47,32,47
  CHAR 32,32,47,32,47,95,32,32,32,32,32,95,95,32,95,95
  CHAR 32,32,32,32,32,32,32,32,32,41,40,92,32,47,41,40
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,96,46
  CHAR 32,94,32,46,39,32,32,32,32,32,32,95,47,32,32,124
  CHAR 95,47,32,95,95,47,95,95,32,95,47,32,32,124,32,32
  CHAR 92,95,32,32,32,32,32,32,32,96,32,32,94,32,32,39
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 183,32,32,32,32,32,32,32,32,32,32,32,32,32,32,33
  CHAR 32,161,32,33,32,32,32,32,32,32,124,32,32,32,32,124
  CHAR 32,32,32,96,41,32,32,32,124,62,32,32,32,95,32,32
  CHAR 32,60,46,32,32,32,32,32,32,32,33,32,161,32,33,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,183
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,33,32,32,32,32,32,32,32,32,96,45,45,45,45,94
  CHAR 45,45,46,95,95,95,95,95,124,45,45,45,45,124,95,95
  CHAR 95,95,124,32,32,32,32,32,32,32,32,32,33,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 166,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 45,45,45,45,45,45,45,46,46,45,45,45,45,45,45,45
  CHAR 45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,45
  CHAR 45,45,45,45,45,45,45,45,45,45,45,45,45,45,45,166
  CHAR 58,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,183
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,124,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,124,33,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,92,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,33,58,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,32,32,32,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,47,32,32,32,32,32,32,124
  CHAR 124,32,32,32,32,32,32,92,92,32,32,32,32,32,32,32
  CHAR 32,32,32,104,32,61,32,104,101,108,112,32,32,32,32,32
  CHAR 32,32,32,32,32,32,32,32,183,32,32,32,32,32,32,32
  CHAR 32,32,32,32,69,115,99,32,61,32,81,117,105,116,32,32
  CHAR 32,32,32,32,32,32,32,47,47,32,32,32,32,32,32,124
  CHAR 96,45,45,45,45,45,45,32,92,45,32,45,45,45,45,45
  CHAR 32,47,45,32,45,45,45,45,45,45,32,45,247,45,32,65
  CHAR 32,76,65,84,69,88,32,80,82,79,68,85,67,84,105,79
  CHAR 78,33,32,45,247,45,32,45,45,45,45,45,45,32,45,92
  CHAR 45,45,45,45,45,32,45,47,32,45,45,45,45,45,45,39

version: CHAR '$VER: CFile 0.1 (15.7.26) E build',0
