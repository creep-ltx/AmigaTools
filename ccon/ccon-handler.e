-> ccon-handler.e - CCON: LTX console handler. Milestone 2: cooked reads.
-> The 0.1 CShell line editor (blip cursor, insert editing, word jumps,
-> history ring) transplanted into ACTION_READ: clients block on Read()
-> and get finished lines; typing, editing and type-ahead live here.
->
-> Test:  Mount CCON: FROM DEVS:CCON-mountlist
->        echo >CCON: hello            (writes still work)
->        type CCON:                   (each Return = a line in the shell;
->                                      Ctrl+\ = EOF ends it)
->        copy CCON: ram:t.txt         (lines land in the file)
->
-> How an E binary survives being started as a handler (verified by
-> disassembling E-VO's generated startup code): a handler process has no
-> CLI, so E's startup waits on the process port and takes the FIRST
-> message as the "Workbench startup message" - which for a handler is
-> DOS's mount startup packet. So the startup packet arrives in
-> `wbmessage`; clearing wbmessage afterwards disarms E's exit-time
-> ReplyMsg (the exit code reloads that same global), so the packet is
-> never replied twice.
->
-> Rule of the house: after the mount handshake this process makes NO
-> dos.library calls that send packets (Open/Lock/OpenDiskFont/...) -
-> DoPkt waits on pr_MsgPort, the same port our clients send to.
-> Intuition and graphics only; OpenFont reads ROM/memory fonts, so
-> topaz is safe where a disk font would not be. ReplyPkt/WaitPkt are
-> safe (PutMsg/WaitPort underneath), but the M2 loop multiplexes the
-> packet port with the window port via Wait(), so WaitPkt is gone.

MODULE 'intuition/intuition',
       'utility/tagitem',
       'exec/nodes','exec/ports',
       'graphics/text','graphics/rastport',
       'devices/inputevent',
       'dos/dos','dos/dosextens','dos/filehandler'

CONST MARGIN=4,
      LINEMAX=400,      -> longest editable input line
      HISTMAX=32,       -> prompt history ring, entries
      INQMAX=2048,      -> input byte queue (finished lines)
      RDMAX=16,         -> pending ACTION_READ packets
      RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F

DEF port:PTR TO mp,             -> our packet port = pr_MsgPort
    win=NIL:PTR TO window,
    rp=NIL:PTR TO rastport,
    tf=NIL:PTR TO textfont,
    cw, ch, baseline,           -> cell metrics (topaz: fixed)
    left, topy, cols, rows,     -> the text grid inside the window
    cx=0, cy=0,                 -> output cursor, in cells
    opens=0,
    -> the line editor (transplanted from CShell 0.1, commit 71e29b1)
    ebuf[404]:STRING,           -> the line being typed
    stash[404]:STRING,          -> half-typed line parked during history
    cpos=0,                     -> cursor inside ebuf
    ancx=0, ancy=0,             -> cell where the edit line is drawn
    hist[32]:ARRAY OF LONG, htotal=0, hpos=-1,
    -> cooked input plumbing
    inq[2048]:ARRAY OF CHAR, inqh=0, inqt=0,
    cesc=0, cnum=0,             -> CSI parser state, global so sequences
                                -> split across two writes still parse
    rdq[16]:ARRAY OF LONG, rdn=0,
    eofpend=FALSE,
    breaktask=NIL               -> who gets Ctrl+C..F (AROS con-handler
                                -> pattern: last client to FIND or READ,
                                -> unless ACTION_CHANGE_SIGNAL overrides)

PROC main()
  DEF proc:PTR TO process, msg:PTR TO mn, pkt:PTR TO dospacket,
      dnode:PTR TO devicenode, psig, wsig, im:PTR TO intuimessage,
      class, code, qual

  IF wbmessage = NIL
    WriteF('ccon-handler is a DOS handler; Mount starts it, not you.\n')
    WriteF('  Mount CCON: FROM DEVS:CCON-mountlist\n')
    WriteF('  echo >CCON: hello\n')
    RETURN 5
  ENDIF

  proc := FindTask(NIL)
  port := proc.msgport            -> embedded OBJECT -> its address
  msg := wbmessage
  wbmessage := NIL                -> disarm E's exit-time ReplyMsg
  pkt := msg.ln.name              -> a packet rides in its message's ln_Name

  dnode := Shl(pkt.arg3, 2)       -> BPTR to our DeviceNode
  dnode.task := port              -> future opens come straight to us
  ReplyPkt(pkt, DOSTRUE, 0)       -> mount handshake done

  psig := Shl(1, port.sigbit)
  WHILE TRUE
    wsig := 0
    IF win THEN wsig := Shl(1, win.userport.sigbit)
    Wait(psig OR wsig)
    -> drain the packet port
    REPEAT
      msg := GetMsg(port)
      IF msg THEN dopkt(msg.ln.name)
    UNTIL msg = NIL
    -> drain the window port
    IF win
      REPEAT
        im := GetMsg(win.userport)
        IF im
          class := im.class
          code := im.code
          qual := im.qualifier
          ReplyMsg(im)
          IF class = IDCMP_VANILLAKEY THEN dovanilla(code)
          IF class = IDCMP_RAWKEY THEN dorawkey(code, qual)
        ENDIF
      UNTIL im = NIL
    ENDIF
  ENDWHILE
ENDPROC

PROC dopkt(pkt:PTR TO dospacket)
  DEF len, old, id:PTR TO infodata, zp:PTR TO LONG, i, sender:PTR TO mp
  SELECT pkt.type
  CASE ACTION_FINDINPUT;  dofind(pkt)
  CASE ACTION_FINDOUTPUT; dofind(pkt)
  CASE ACTION_FINDUPDATE; dofind(pkt)
  CASE ACTION_END
    opens--                     -> window stays for inspection (M5: real
    IF opens <= 0 THEN breaktask := NIL   -> open/close semantics)
    ReplyPkt(pkt, DOSTRUE, 0)
  CASE ACTION_WRITE
    sender := pkt.port          -> the writer owns the break signal too:
    breaktask := sender.sigtask -> `list >CCON:` is opened by the SHELL,
                                -> but the WRITEs come from list itself -
                                -> this line is what makes Ctrl+C reach it
                                -> (AROS con-handler does the same)
    len := pkt.arg3
    eraseedit()
    render(pkt.arg2, len)
    reanchor()
    drawedit()
    ReplyPkt(pkt, len, 0)
  CASE ACTION_READ
    sender := pkt.port          -> the reader owns the break signal now
    breaktask := sender.sigtask -> (the AROS con-handler does the same)
    IF rdn < RDMAX
      rdq[rdn] := pkt           -> queue it; a finished line replies it
      rdn++
      satisfyreads()
    ELSE
      ReplyPkt(pkt, -1, ERROR_NO_FREE_STORE)
    ENDIF
  CASE ACTION_WAIT_CHAR
    -> arg1 = timeout in MICROseconds (AROS-verified). No timer.device
    -> yet, so answer what is true right now: input queued = DOSTRUE,
    -> nothing = DOSFALSE at once. M4 brings honest timed waits.
    IF inavail() > 0
      ReplyPkt(pkt, DOSTRUE, 0)
    ELSE
      ReplyPkt(pkt, DOSFALSE, 0)
    ENDIF
  CASE ACTION_SCREEN_MODE
    ReplyPkt(pkt, DOSTRUE, 0)   -> accepted, ignored; M4 brings raw mode
  CASE ACTION_CHANGE_SIGNAL
    -> arg2 = Task to signal on Ctrl+C..F (0 = just query); res2 = old
    old := breaktask
    IF pkt.arg2 THEN breaktask := pkt.arg2
    ReplyPkt(pkt, DOSTRUE, old)
  CASE ACTION_DISK_INFO
    -> the console curiosity: id_VolumeNode carries the WINDOW pointer,
    -> which is how programs find the console's window
    id := Shl(pkt.arg1, 2)      -> BPTR to InfoData
    zp := id
    FOR i := 0 TO 8
      zp[i] := 0
    ENDFOR
    id.disktype := $434F4E00    -> 'CON\0'
    id.volumenode := win
    ReplyPkt(pkt, DOSTRUE, 0)
  CASE ACTION_SEEK
    -> Seek on a console fails-with-style: -1 result, reason in res2
    -> (the Guru Book rule, same as the AROS con-handler)
    ReplyPkt(pkt, DOSTRUE, ERROR_ACTION_NOT_KNOWN)
  CASE ACTION_IS_FILESYSTEM
    ReplyPkt(pkt, DOSFALSE, 0)  -> we are a console, not a filesystem
  DEFAULT
    ReplyPkt(pkt, DOSFALSE, ERROR_ACTION_NOT_KNOWN)
  ENDSELECT
ENDPROC

PROC dofind(pkt:PTR TO dospacket)
  DEF fh:PTR TO filehandle, sender:PTR TO mp
  IF win = NIL THEN openwin()
  IF win
    fh := Shl(pkt.arg1, 2)      -> BPTR to the FileHandle DOS made
    fh.args := 1                -> our stream id (single stream for now)
    fh.interactive := DOSTRUE   -> we are a console
    opens++
    sender := pkt.port
    breaktask := sender.sigtask -> opener gets Ctrl+C..F by default
    ReplyPkt(pkt, DOSTRUE, 0)
  ELSE
    ReplyPkt(pkt, DOSFALSE, ERROR_NO_FREE_STORE)
  ENDIF
ENDPROC

PROC openwin()
  DEF ta:PTR TO textattr, i
  win := OpenWindowTagList(NIL,
    [WA_TITLE, 'CCON: M3b', WA_LEFT, 40, WA_TOP, 40,
     WA_WIDTH, 520, WA_HEIGHT, 160,
     WA_DRAGBAR, TRUE, WA_DEPTHGADGET, TRUE,
     WA_ACTIVATE, TRUE,
     WA_IDCMP, IDCMP_RAWKEY OR IDCMP_VANILLAKEY,
     TAG_DONE, NIL])
  IF win = NIL THEN RETURN
  rp := win.rport
  -> topaz 8: a ROM font - OpenFont sends no packets, OpenDiskFont would
  NEW ta
  ta.name := 'topaz.font'
  ta.ysize := 8
  ta.style := 0
  ta.flags := 0
  tf := OpenFont(ta)
  IF tf THEN SetFont(rp, tf)
  cw := rp.txwidth
  ch := rp.txheight
  baseline := rp.txbaseline
  left := win.borderleft + MARGIN
  topy := win.bordertop + MARGIN
  cols := Div(win.width - win.borderleft - win.borderright - MARGIN - MARGIN, cw)
  rows := Div(win.height - win.bordertop - win.borderbottom - MARGIN - MARGIN, ch)
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  FOR i := 0 TO HISTMAX - 1
    hist[i] := String(LINEMAX)
  ENDFOR
  StrCopy(ebuf, '')
  drawedit()                    -> the blip stands from the start
ENDPROC

-> ---------- output: a cell-grid renderer (CSI parsing comes with the
-> full CShell renderer transplant in a later milestone) ----------

PROC outnl()
  cx := 0
  cy++
  IF cy >= rows
    ScrollRaster(rp, 0, ch,
                 win.borderleft, win.bordertop,
                 win.width - win.borderright - 1,
                 win.height - win.borderbottom - 1)
    cy := rows - 1
    IF ancy > 0 THEN ancy--     -> the edit anchor scrolled with the rest
  ENDIF
ENDPROC

PROC outchr(c)
  DEF b[2]:ARRAY OF CHAR
  IF cx >= cols THEN outnl()
  b[0] := c
  Move(rp, left + Mul(cx, cw), topy + Mul(cy, ch) + baseline)
  Text(rp, b, 1)
  cx++
ENDPROC

-> erase from the output cursor to the end of its row (CSI K)
PROC eraseeol()
  DEF y
  y := topy + Mul(cy, ch)
  SetAPen(rp, 0)
  RectFill(rp, left + Mul(cx, cw), y, left + Mul(cols, cw) - 1, y + ch - 1)
  SetAPen(rp, 1)
ENDPROC

-> the 0.1 CShell renderer's CSI discipline, transplanted: consume
-> sequences WHOLE (state survives writes via cesc/cnum), honour C
-> (cursor forward) and K (erase to end of line), drop the rest
-> silently - dir's `ESC[0 q` window-bounds request included (M4
-> answers it; for now WAIT_CHAR = DOSFALSE makes dir fall back).
PROC render(buf, len)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit
  IF win = NIL THEN RETURN
  s := buf
  WHILE i < len
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
        IF c = "C"
          IF cnum < 1 THEN cnum := 1
          cx := cx + cnum
          IF cx > cols THEN cx := cols
        ELSEIF c = "K"
          eraseeol()
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
      outnl()
      i := i + 1
    ELSEIF c = 13
      cx := 0
      i := i + 1
    ELSEIF c = 8
      IF cx > 0 THEN cx--
      i := i + 1
    ELSEIF c = 9
      REPEAT
        outchr(32)
      UNTIL (Mod(cx, 8) = 0) OR (cx >= cols)
      i := i + 1
    ELSEIF ((c >= 32) AND (c <= 126)) OR (c >= 160)
      -> printable run: ASCII and Latin-1; $7F-$9F are controls.
      -> Batched Text() calls - dir listings are many bytes per write
      j := i
      WHILE (j < len) AND (((s[j] >= 32) AND (s[j] <= 126)) OR (s[j] >= 160))
        j := j + 1
      ENDWHILE
      run := j - i
      WHILE run > 0
        IF cx >= cols THEN outnl()
        fit := cols - cx
        IF fit > run THEN fit := run
        Move(rp, left + Mul(cx, cw), topy + Mul(cy, ch) + baseline)
        Text(rp, s + i, fit)
        cx := cx + fit
        i := i + fit
        run := run - fit
      ENDWHILE
    ELSE
      i := i + 1    -> other control bytes
    ENDIF
  ENDWHILE
ENDPROC

-> ---------- the line editor, out-of-band of the output cursor:
-> drawing never moves cx/cy, so committed lines render from the
-> anchor exactly where the client's prompt left the output ----------

PROC reanchor()
  ancx := cx
  ancy := cy
ENDPROC

PROC eraseedit()
  DEF y
  IF win = NIL THEN RETURN
  y := topy + Mul(ancy, ch)
  SetAPen(rp, 0)
  RectFill(rp, left + Mul(ancx, cw), y, left + Mul(cols, cw) - 1, y + ch - 1)
  SetAPen(rp, 1)
ENDPROC

-> the cell at cpos is drawn inverted - the blip - so the cursor is
-> visible for mid-line editing (transplant of 0.1 redrawinput)
PROC drawedit()
  DEF y, s:PTR TO CHAR, l, cch[2]:ARRAY OF CHAR
  IF win = NIL THEN RETURN
  eraseedit()
  y := topy + Mul(ancy, ch)
  SetBPen(rp, 0)
  Move(rp, left + Mul(ancx, cw), y + baseline)
  Text(rp, ebuf, StrLen(ebuf))
  s := ebuf
  l := StrLen(ebuf)
  cch[0] := 32
  IF cpos < l THEN cch[0] := s[cpos]
  SetAPen(rp, 0)
  SetBPen(rp, 1)
  Move(rp, left + Mul(ancx + cpos, cw), y + baseline)
  Text(rp, cch, 1)
  SetAPen(rp, 1)
  SetBPen(rp, 0)
ENDPROC

-> put history entry idx (0 = newest) into ebuf, cut to fit the row
PROC histload(idx)
  StrCopy(ebuf, hist[Mod(htotal - 1 - idx, HISTMAX)])
  WHILE (ancx + StrLen(ebuf)) >= (cols - 1)
    SetStr(ebuf, StrLen(ebuf) - 1)
  ENDWHILE
ENDPROC

PROC dovanilla(code)
  DEF s:PTR TO CHAR, l, j, dup
  s := ebuf
  l := StrLen(ebuf)
  IF code = 13
    -> commit: echo the line into the transcript, feed the readers
    eraseedit()
    render(ebuf, l)
    outnl()
    FOR j := 0 TO l - 1
      enqueue(s[j])
    ENDFOR
    enqueue(10)
    -> remember the line: newest first, consecutive repeats once.
    -> (E's OR does not short-circuit: the 0.1 one-liner evaluated
    -> hist[Mod(-1,32)] on an empty history - survivable in an app,
    -> a guru in a handler - hence the nested IF.)
    dup := FALSE
    IF htotal > 0
      IF StrCmp(hist[Mod(htotal - 1, HISTMAX)], ebuf) THEN dup := TRUE
    ENDIF
    IF (l > 0) AND (dup = FALSE)
      StrCopy(hist[Mod(htotal, HISTMAX)], ebuf)
      htotal := htotal + 1
    ENDIF
    StrCopy(ebuf, '')
    cpos := 0
    hpos := -1
    reanchor()
    drawedit()
    satisfyreads()
  ELSEIF code = 28
    -> Ctrl+\ : EOF for the next (or a waiting) read
    eofpend := TRUE
    satisfyreads()
  ELSEIF (code >= 3) AND (code <= 6)
    -> Ctrl+C..F: forward the break to the current break owner
    IF breaktask
      Signal(breaktask, Shl(SIGBREAKF_CTRL_C, code - 3))
    ENDIF
  ELSEIF code = 27
    StrCopy(ebuf, '')
    cpos := 0
    drawedit()
  ELSEIF code = 8
    -> Backspace: delete before the cursor, close the gap
    IF cpos > 0
      FOR j := cpos TO l - 1
        s[j - 1] := s[j]
      ENDFOR
      SetStr(ebuf, l - 1)
      cpos := cpos - 1
      drawedit()
    ENDIF
  ELSEIF code = 127
    -> Del: delete under the cursor
    IF cpos < l
      FOR j := cpos + 1 TO l - 1
        s[j - 1] := s[j]
      ENDFOR
      SetStr(ebuf, l - 1)
      drawedit()
    ENDIF
  ELSEIF ((code >= 32) AND (code <= 126)) OR (code >= 160)
    -> Latin-1 high half too: Swedish keymaps type beyond ASCII;
    -> typed characters insert at the cursor, not just append
    IF (l < LINEMAX) AND ((ancx + l) < (cols - 1))
      FOR j := l - 1 TO cpos STEP -1
        s[j + 1] := s[j]
      ENDFOR
      s[cpos] := code
      SetStr(ebuf, l + 1)
      cpos := cpos + 1
      drawedit()
    ENDIF
  ENDIF
ENDPROC

PROC dorawkey(code, qual)
  DEF s:PTR TO CHAR, l, avail
  s := ebuf
  l := StrLen(ebuf)
  IF code = RK_UP
    -> plain Up/Down walk the prompt history (output scrollback: M5)
    avail := htotal
    IF avail > HISTMAX THEN avail := HISTMAX
    IF hpos < (avail - 1)
      IF hpos = -1 THEN StrCopy(stash, ebuf)  -> the half-typed line
      hpos := hpos + 1
      histload(hpos)
      cpos := StrLen(ebuf)
      drawedit()
    ENDIF
  ELSEIF code = RK_DOWN
    IF hpos >= 0
      hpos := hpos - 1
      IF hpos = -1
        StrCopy(ebuf, stash)    -> back to the half-typed line
      ELSE
        histload(hpos)
      ENDIF
      cpos := StrLen(ebuf)
      drawedit()
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
    drawedit()
  ELSEIF code = RK_RIGHT
    IF qual AND IEQUALIFIER_CONTROL
      WHILE (cpos < l) AND (s[cpos] <> 32)
        cpos := cpos + 1
      ENDWHILE
      WHILE (cpos < l) AND (s[cpos] = 32)
        cpos := cpos + 1
      ENDWHILE
    ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
      cpos := StrLen(ebuf)
    ELSEIF cpos < l
      cpos := cpos + 1
    ENDIF
    drawedit()
  ENDIF
ENDPROC

-> ---------- cooked input plumbing ----------

PROC enqueue(c)
  DEF nt
  nt := Mod(inqt + 1, INQMAX)
  IF nt <> inqh               -> full queue drops (should never happen)
    inq[inqt] := c
    inqt := nt
  ENDIF
ENDPROC

PROC inavail() IS Mod(inqt - inqh + INQMAX, INQMAX)

-> reply queued reads while finished-line bytes (or an EOF) are there;
-> a read gets at most one line - cooked semantics - and a short buffer
-> gets the rest of the line on its next read
PROC satisfyreads()
  DEF pkt:PTR TO dospacket, dst:PTR TO CHAR, max, n, c, i, stop
  WHILE (rdn > 0) AND ((inavail() > 0) OR eofpend)
    pkt := rdq[0]
    FOR i := 1 TO rdn - 1
      rdq[i - 1] := rdq[i]
    ENDFOR
    rdn--
    IF inavail() = 0
      eofpend := FALSE          -> EOF is one-shot
      ReplyPkt(pkt, 0, 0)
    ELSE
      dst := pkt.arg2
      max := pkt.arg3
      n := 0
      stop := FALSE
      WHILE (n < max) AND (stop = FALSE) AND (inavail() > 0)
        c := inq[inqh]
        inqh := Mod(inqh + 1, INQMAX)
        dst[n] := c
        n++
        IF c = 10 THEN stop := TRUE
      ENDWHILE
      ReplyPkt(pkt, n, 0)
    ENDIF
  ENDWHILE
ENDPROC

vers: CHAR '$VER: ccon-handler 0.3.1 (16.7.26) CCON: LTX console handler M3b', 0
