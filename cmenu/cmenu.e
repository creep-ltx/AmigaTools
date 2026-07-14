-> CMenu - full-screen text boot menu for AmigaOS
->
-> Meant to run *before* the normal Startup-Sequence (see
-> example-startup-sequence): it opens a borderless window covering the
-> whole Workbench screen, shows a centered menu of items from
-> S:CMenu.config, and launches the chosen one the same way CBoot
-> launches its boot scripts (protect +srwed, then Execute).
-> CMenu exits after launching - it is a boot menu, not a dock.
->
-> S:CMenu.config format (one entry per line, max 10 items):
->   ; comment
->   Menu name|path-to-script-or-executable
->   DEFAULT n      (1-based index of the preselected item, default 1)
->   TIMEOUT secs   (auto-start DEFAULT after secs; 0/absent = wait)
->
-> Keys: Up/Down select (wraps), Enter launches selection,
->       1-9 and 0 launch item 1-10 directly, C opens the config
->       screen, Esc exits without launching. Any key stops a
->       running countdown.
->
-> Config screen: edit the menu in place - A adds an item, E or Enter
-> edits the selected one (name, then path; Esc keeps the old value),
-> D deletes it, Shift+Up/Down moves it, Space makes it the default,
-> T sets the timeout, S writes S:CMenu.config back (comment lines in
-> the file do not survive a rewrite), Esc returns to the menu.
->
-> If S:CMenu.config is missing or has no items, a built-in fallback
-> menu (Workbench -> S:Startup-Sequence-Normal, Shell -> C:NewShell)
-> is shown instead so a misconfigured setup still boots to something.
->
-> The window is sized from the actual screen (width/height), so PAL
-> vs NTSC vs interlace vs RTG needs no detection at all. The
-> countdown is driven by IDCMP_INTUITICKS (~10 per second), which is
-> plenty accurate for a boot timeout.

MODULE 'intuition/intuition','intuition/screens',
       'graphics/text','graphics/rastport',
       'utility/tagitem','devices/inputevent'

CONST MAXITEMS=10, NAMELEN=60, CPATHLEN=300, MAXTIMEOUT=999,
      RK_UP=$4C, RK_DOWN=$4D    -> rawkey codes, cursor up/down

DEF nitems=0, nalloc=0, defitem=1, timeout=0, fallbk=FALSE,
    names[MAXITEMS]:ARRAY OF LONG,
    paths[MAXITEMS]:ARRAY OF LONG,
    scr=NIL:PTR TO screen,
    win=NIL:PTR TO window,
    tf=NIL:PTR TO textfont,
    ta=NIL:PTR TO textattr,
    rp=NIL:PTR TO rastport,
    winw, winh, rowh, baseline, starty, titley, warny, cnty, helpy,
    cstarty, metay, inputy,
    counting=FALSE, secs=0,
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
  MidStr(kw, s, 0, 7)
  UpperStr(kw)
  IF StrCmp(kw, 'DEFAULT')
    defitem := Val(TrimStr(s+7))
  ELSEIF StrCmp(kw, 'TIMEOUT')
    timeout := Val(TrimStr(s+7))
  ENDIF
ENDPROC

PROC loadconfig()
  DEF fh, eof=FALSE, line[400]:STRING
  IF fh := Open('S:CMenu.config', OLDFILE)
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
ENDPROC

PROC openui()
  OpenWorkBench()    -> ensure the Workbench screen exists (early boot)
  IF (scr := LockPubScreen(NIL)) = NIL THEN Throw("UI", 'no public screen')
  NEW ta
  ta.name := 'topaz.font'
  ta.ysize := 8
  ta.style := 0
  ta.flags := 0
  IF (tf := OpenFont(ta)) = NIL THEN Throw("UI", 'topaz.font/8')
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
  IF win = NIL THEN Throw("UI", 'window')
  rp := win.rport
  SetFont(rp, tf)
  SetDrMd(rp, RP_JAM2)
  winw := win.width
  winh := win.height
  rowh := tf.ysize + 2
  baseline := tf.baseline
  titley := rowh
  warny  := titley + (rowh * 2)
  helpy  := winh - (rowh * 2)
  cnty   := helpy - (rowh * 2)
  cstarty := titley + (rowh * 2)
  metay   := cstarty + ((MAXITEMS + 1) * rowh)
  inputy  := helpy - (rowh * 2)
ENDPROC

PROC closeui()
  IF win
    CloseWindow(win)
    win := NIL
  ENDIF
  IF tf
    CloseFont(tf)
    tf := NIL
  ENDIF
  IF scr
    UnlockPubScreen(NIL, scr)
    scr := NIL
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

PROC clearline(y)
  SetAPen(rp, 0)
  RectFill(rp, 0, y, winw - 1, y + rowh - 1)
ENDPROC

PROC drawitem(i, selected)
  DEF y, s, tl, x
  y := starty + (i * rowh)
  s := names[i]
  tl := TextLength(rp, s, EstrLen(s))
  x := (winw - tl) / 2
  IF x < 8 THEN x := 8
  clearline(y)
  IF selected
    SetAPen(rp, 1)
    RectFill(rp, x - 8, y, x + tl + 7, y + rowh - 1)
    SetAPen(rp, 0)
    SetBPen(rp, 1)
  ELSE
    SetAPen(rp, 1)
    SetBPen(rp, 0)
  ENDIF
  Move(rp, x, y + baseline + 1)
  Text(rp, s, EstrLen(s))
  SetBPen(rp, 0)
ENDPROC

PROC drawmenu(sel)
  DEF i
  FOR i := 0 TO nitems - 1
    drawitem(i, i = sel)
  ENDFOR
ENDPROC

PROC drawcountdown()
  clearline(cnty)
  StringF(cbuf, 'Starting "\s" in \d - press any key to stop',
          names[defitem - 1], secs)
  SetAPen(rp, 1)
  ctext(cbuf, cnty)
ENDPROC

PROC stopcount()
  IF counting
    counting := FALSE
    clearline(cnty)
  ENDIF
ENDPROC

PROC drawall(sel)
  starty := (winh - (nitems * rowh)) / 2
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  SetAPen(rp, 1)
  ctext('CMenu 0.2', titley)
  IF fallbk THEN ctext('S:CMenu.config missing or empty - built-in menu', warny)
  drawmenu(sel)
  IF counting THEN drawcountdown()
  SetAPen(rp, 1)
  ctext('Up/Down = select   Enter = start   1-0 = direct   C = config   Esc = quit', helpy)
ENDPROC

-> ---------- config screen ----------

PROC showmsg(s)
  clearline(inputy)
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  ctext(s, inputy)
ENDPROC

PROC drawinput(prompt, buf, y)
  DEF maxc, pl, bl, off, s:PTR TO CHAR
  clearline(y)
  SetAPen(rp, 1)
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
  SetBPen(rp, 1)
  Text(rp, ' ', 1)    -> block cursor
  SetAPen(rp, 1)
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
    SetAPen(rp, 1)
    RectFill(rp, 8, y, winw - 9, y + rowh - 1)
    SetAPen(rp, 0)
    SetBPen(rp, 1)
  ELSE
    SetAPen(rp, 1)
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
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  StringF(cbuf, 'Default: \d   Timeout: \d\s', defitem, timeout,
          IF changed THEN '   - unsaved changes, S = save -' ELSE '')
  ctext(cbuf, metay)
ENDPROC

PROC drawcontrol(csel, changed)
  SetAPen(rp, 0)
  RectFill(rp, 0, 0, winw - 1, winh - 1)
  SetAPen(rp, 1)
  ctext('CMenu Config', titley)
  drawcitems(csel)
  drawmeta(changed)
  SetAPen(rp, 1)
  ctext('Up/Down = select   Shift+Up/Down = move   Space = default', helpy)
  ctext('A=add  E=edit  D=del  T=timeout  S=save  Esc=back', helpy + rowh)
ENDPROC

PROC wline(fh, s) IS Write(fh, s, StrLen(s))

PROC saveconfig()
  DEF fh, i, buf[420]:STRING, ok=FALSE
  IF fh := Open('S:CMenu.config', NEWFILE)
    ok := TRUE
    IF wline(fh, '; CMenu configuration - Name|path, DEFAULT n, TIMEOUT secs\n') < 0 THEN ok := FALSE
    FOR i := 0 TO nitems - 1
      StringF(buf, '\s|\s\n', names[i], paths[i])
      IF wline(fh, buf) < 0 THEN ok := FALSE
    ENDFOR
    StringF(buf, 'DEFAULT \d\nTIMEOUT \d\n', defitem, timeout)
    IF wline(fh, buf) < 0 THEN ok := FALSE
    Close(fh)
  ENDIF
ENDPROC ok

PROC controlscreen()
  DEF csel, class, code, done=FALSE, changed=FALSE, shifted,
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
              csel := nitems - 1
              changed := TRUE
            ENDIF
          ENDIF
          drawcontrol(csel, changed)
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
        drawcontrol(csel, changed)
      ELSEIF (code = "d") OR (code = "D")
        IF nitems <= 1
          showmsg('cannot delete the last item')
        ELSE
          delitem(csel)
          IF csel >= nitems THEN csel := nitems - 1
          changed := TRUE
          drawcontrol(csel, changed)
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
        drawcontrol(csel, changed)
      ELSEIF (code = "s") OR (code = "S")
        IF saveconfig()
          changed := FALSE
          fallbk := FALSE
          drawcontrol(csel, changed)
          showmsg('saved to S:CMenu.config')
        ELSE
          showmsg('could not write S:CMenu.config')
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
              drawcitems(csel)
              drawmeta(changed)
            ENDIF
          ELSE
            csel := IF csel = 0 THEN nitems - 1 ELSE csel - 1
            drawcitems(csel)
          ENDIF
        ELSEIF code = RK_DOWN
          IF shifted
            IF csel < (nitems - 1)
              swapitems(csel, csel + 1)
              csel++
              changed := TRUE
              drawcitems(csel)
              drawmeta(changed)
            ENDIF
          ELSE
            csel := IF csel = (nitems - 1) THEN 0 ELSE csel + 1
            drawcitems(csel)
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
          sel := IF sel = 0 THEN nitems - 1 ELSE sel - 1
          drawmenu(sel)
        ELSEIF code = RK_DOWN
          sel := IF sel = (nitems - 1) THEN 0 ELSE sel + 1
          drawmenu(sel)
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC res

PROC main() HANDLE
  DEF idx, cmd[360]:STRING
  loadconfig()
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

version: CHAR '$VER: CMenu 0.2 (14.7.26)',0
