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
       'exec/nodes','exec/ports','exec/io',
       'graphics/text','graphics/rastport',
       'devices/inputevent','devices/timer',
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
    cesc=0,                     -> CSI parser state, global so sequences
    cpar[4]:ARRAY OF LONG,      -> split across two writes still parse;
    cnp=0,                      -> up to 4 parameters (H needs row;col)
    rdq[16]:ARRAY OF LONG, rdn=0,
    eofpend=FALSE,
    breaktask=NIL,              -> who gets Ctrl+C..F (AROS con-handler
                                -> pattern: last client to FIND, READ or
                                -> WRITE, unless CHANGE_SIGNAL overrides)
    rawmode=FALSE,              -> ACTION_SCREEN_MODE: DOSTRUE = raw
    tport=NIL:PTR TO mp,        -> timer.device plumbing for WAIT_CHAR
    treq=NIL:PTR TO timerequest,
    timerarmed=FALSE,
    wcq[8]:ARRAY OF LONG, wcn=0,-> pending ACTION_WAIT_CHAR packets
    evmask=0                    -> raw input event classes requested via
                                -> CSI n { (Ed asks for 10 = MENULIST)

PROC main()
  DEF proc:PTR TO process, msg:PTR TO mn, pkt:PTR TO dospacket,
      dnode:PTR TO devicenode, psig, wsig, im:PTR TO intuimessage,
      class, code, qual, mx, my, ia, secs, mics

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

  -> timer.device for real WAIT_CHAR timeouts (all exec, no packets);
  -> if any step fails, treq stays NIL and WAIT_CHAR answers at once
  tport := CreateMsgPort()
  IF tport
    treq := CreateIORequest(tport, SIZEOF timerequest)
    IF treq
      IF OpenDevice('timer.device', UNIT_MICROHZ, treq, 0) <> 0
        DeleteIORequest(treq)
        treq := NIL
      ENDIF
    ENDIF
  ENDIF

  psig := Shl(1, port.sigbit)
  WHILE TRUE
    wsig := 0
    IF win THEN wsig := Shl(1, win.userport.sigbit)
    IF tport THEN wsig := wsig OR Shl(1, tport.sigbit)
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
          mx := im.mousex
          my := im.mousey
          ia := im.iaddress
          secs := im.seconds
          mics := im.micros
          ReplyMsg(im)
          IF class = IDCMP_VANILLAKEY THEN dovanilla(code)
          IF class = IDCMP_RAWKEY THEN dorawkey(code, qual)
          IF class = IDCMP_MENUPICK THEN domenupick(code, qual, ia, secs, mics)
        ENDIF
      UNTIL im = NIL
    ENDIF
    -> drain the timer port: an expiry times out the head WAIT_CHAR
    IF tport
      REPEAT
        msg := GetMsg(tport)
        IF msg
          timerarmed := FALSE
          timerexpired()
        ENDIF
      UNTIL msg = NIL
    ENDIF
  ENDWHILE
ENDPROC

-> ---------- WAIT_CHAR timing ----------

PROC armtimer(us)
  IF treq = NIL THEN RETURN
  IF us < 1 THEN us := 1
  treq.io.command := TR_ADDREQUEST
  treq.time.secs := Div(us, 1000000)
  treq.time.micro := Mod(us, 1000000)
  SendIO(treq)
  timerarmed := TRUE
ENDPROC

PROC canceltimer()
  IF timerarmed
    AbortIO(treq)
    WaitIO(treq)      -> eats the reply even if it completed first
    timerarmed := FALSE
  ENDIF
ENDPROC

PROC timerexpired()
  DEF pkt:PTR TO dospacket, nxt:PTR TO dospacket, i
  IF wcn = 0 THEN RETURN
  pkt := wcq[0]
  FOR i := 1 TO wcn - 1
    wcq[i - 1] := wcq[i]
  ENDFOR
  wcn--
  ReplyPkt(pkt, DOSFALSE, 0)
  IF wcn > 0
    nxt := wcq[0]     -> queued waiters restart their full timeout when
    armtimer(nxt.arg1) -> they reach the head - approximate, noted
  ENDIF
ENDPROC

-> input became available: wake every WAIT_CHAR, then feed the reads
PROC satisfywaits()
  DEF i
  IF wcn = 0 THEN RETURN
  IF inavail() = 0 THEN RETURN
  canceltimer()
  FOR i := 0 TO wcn - 1
    ReplyPkt(wcq[i], DOSTRUE, 0)
  ENDFOR
  wcn := 0
ENDPROC

PROC inputarrived()
  satisfywaits()
  satisfyreads()
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
    IF rawmode
      render(pkt.arg2, len)     -> raw: the app owns the screen, no blip
    ELSE
      eraseedit()
      render(pkt.arg2, len)
      reanchor()
      drawedit()
    ENDIF
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
    -> arg1 = timeout in MICROseconds (AROS-verified): input queued =
    -> DOSTRUE now; timeout 0 = DOSFALSE now; else park the packet and
    -> let timer.device answer (input arrival wakes all waiters)
    IF inavail() > 0
      ReplyPkt(pkt, DOSTRUE, 0)
    ELSEIF (pkt.arg1 <= 0) OR (treq = NIL) OR (wcn >= 8)
      ReplyPkt(pkt, DOSFALSE, 0)
    ELSE
      wcq[wcn] := pkt
      wcn++
      IF wcn = 1 THEN armtimer(pkt.arg1)
    ENDIF
  CASE ACTION_SCREEN_MODE
    -> arg1: DOSTRUE = raw, 0 = cooked. Raw parks the line editor -
    -> keys become bytes, the client owns echo and screen
    IF pkt.arg1
      IF rawmode = FALSE
        rawmode := TRUE
        eraseedit()
      ENDIF
    ELSE
      IF rawmode
        rawmode := FALSE
        reanchor()
        drawedit()
      ENDIF
    ENDIF
    ReplyPkt(pkt, DOSTRUE, 0)
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
    -> 'CCON', deliberately NOT 'CON\0': the V47 shell probes
    -> DISK_INFO and if it sees 'CON\0' it keeps SetMode(2) and runs
    -> ITS OWN line editor (ROM shell_47.47, disassembled at $669A:
    -> SetMode(fh,2), DISK_INFO, cmpi #'CON\0', else SetMode(fh,0)).
    -> Answering 'CCON' makes the shell revert us to cooked and hand
    -> editing to the console - which is the whole point of CCON.
    id.disktype := $43434F4E
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
    [WA_TITLE, 'CCON: M4', WA_LEFT, 40, WA_TOP, 40,
     WA_WIDTH, 520, WA_HEIGHT, 160,
     WA_DRAGBAR, TRUE, WA_DEPTHGADGET, TRUE,
     WA_ACTIVATE, TRUE,
     WA_IDCMP, IDCMP_RAWKEY OR IDCMP_VANILLAKEY OR IDCMP_MENUPICK,
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

PROC csistart()
  cesc := 2
  cnp := 0
  cpar[0] := 0
  cpar[1] := 0
  cpar[2] := 0
  cpar[3] := 0
ENDPROC

-> the full-screen vocabulary: what More and Ed actually speak.
-> A/B/C/D cursor moves, H/f position (row;col, 1-based), J erase
-> below, K erase to EOL, L/M insert/delete lines, `0 q` = the
-> window-bounds request, answered on the INPUT stream as
-> CSI 1;1;rows;cols SPACE r (how dir learns it can do columns).
-> Everything else is consumed silently.
PROC csidispatch(c)
  DEF n, i
  n := cpar[0]
  IF c = "A"
    IF n < 1 THEN n := 1
    cy := cy - n
    IF cy < 0 THEN cy := 0
  ELSEIF c = "B"
    IF n < 1 THEN n := 1
    cy := cy + n
    IF cy >= rows THEN cy := rows - 1
  ELSEIF c = "C"
    IF n < 1 THEN n := 1
    cx := cx + n
    IF cx > cols THEN cx := cols
  ELSEIF c = "D"
    IF n < 1 THEN n := 1
    cx := cx - n
    IF cx < 0 THEN cx := 0
  ELSEIF (c = "H") OR (c = "f")
    cy := n - 1
    IF cy < 0 THEN cy := 0
    IF cy >= rows THEN cy := rows - 1
    cx := cpar[1] - 1
    IF cx < 0 THEN cx := 0
    IF cx > cols THEN cx := cols
  ELSEIF c = "J"
    erasebelow()
  ELSEIF c = "K"
    eraseeol()
  ELSEIF c = "L"
    inslines(n)
  ELSEIF c = "M"
    dellines(n)
  ELSEIF c = "q"
    IF n = 0 THEN sendreport()
  ELSEIF c = "{"
    -> SET RAW EVENTS: report the listed IECLASSes on the input
    -> stream (this is how Ed's menus reach it through the console)
    FOR i := 0 TO cnp
      IF (cpar[i] >= 0) AND (cpar[i] <= 31)
        evmask := evmask OR Shl(1, cpar[i])
      ENDIF
    ENDFOR
  ELSEIF c = "}"
    -> RESET RAW EVENTS
    FOR i := 0 TO cnp
      IF (cpar[i] >= 0) AND (cpar[i] <= 31)
        evmask := evmask - (evmask AND Shl(1, cpar[i]))
      ENDIF
    ENDFOR
  ENDIF
ENDPROC

-> a menu pick becomes a raw input event report on the input stream:
-> CSI class;subclass;keycode;qualifiers;x;y;seconds;micros| - Ed
-> put the menu strip on our window (found via DISK_INFO's window
-> pointer) and reads the picks back this way. THE TRAP (paid for
-> with two full system freezes): for menu events x;y are NOT
-> coordinates - the RKM says "Intuition address (x<<16+y)". The
-> reader rebuilds a POINTER from them (to walk the NextSelect
-> chain), so they must carry the IntuiMessage's IAddress - mouse
-> coordinates in those fields become a wild dereference inside
-> Intuition's menu handling, and the whole input chain dies.
-> MENU PICKS ARE DELIBERATELY SWALLOWED. The experiment log
-> (17.7.26, four system freezes): Ed attaches menus to our window
-> and requests raw event reports (CSI 2;10;11;12{). The true V47
-> report format was recovered from console.device 46.1's own
-> builder (ROM offset $13de): CSI class;subclass;ie_Code;
-> ie_Qualifier;addrhigh;addrlow;secs;micros| - and reports in
-> exactly that format froze the whole input chain (mouse dead)
-> no matter what the address halves carried: mouse coordinates,
-> ItemAddress(strip,code), or 0;0. Whatever Ed's report parser
-> expects, it is not decoded yet - the next step is disassembling
-> Ed's own parser, not another guess. Until then: menus render
-> but picks vanish, Ed exits with Esc-x - and every OTHER M4
-> feature (raw mode, WAIT_CHAR, bounds report, More, editing)
-> is boot-verified working.
PROC domenupick(code, qual, ia, secs, mics)
ENDPROC

PROC erasebelow()
  eraseeol()
  IF cy < (rows - 1)
    SetAPen(rp, 0)
    RectFill(rp, left, topy + Mul(cy + 1, ch),
             left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
    SetAPen(rp, 1)
  ENDIF
ENDPROC

PROC inslines(n)
  IF n < 1 THEN n := 1
  IF n > (rows - cy) THEN n := rows - cy
  ScrollRaster(rp, 0, -Mul(n, ch),
               left, topy + Mul(cy, ch),
               left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
ENDPROC

PROC dellines(n)
  IF n < 1 THEN n := 1
  IF n > (rows - cy) THEN n := rows - cy
  ScrollRaster(rp, 0, Mul(n, ch),
               left, topy + Mul(cy, ch),
               left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
ENDPROC

-> the answer to `CSI 0 SPACE q`, injected straight into the input
-> stream where the asker's Read finds it
PROC sendreport()
  DEF b[24]:STRING, i
  enqueue($9B)
  StringF(b, '1;1;\d;\d', rows, cols)
  FOR i := 0 TO StrLen(b) - 1
    enqueue(b[i])
  ENDFOR
  enqueue(32)
  enqueue("r")
  inputarrived()
ENDPROC

-> erase from the output cursor to the end of its row (CSI K)
PROC eraseeol()
  DEF y
  IF cx >= cols THEN RETURN   -> inverted RectFill = wild writes
  y := topy + Mul(cy, ch)
  SetAPen(rp, 0)
  RectFill(rp, left + Mul(cx, cw), y, left + Mul(cols, cw) - 1, y + ch - 1)
  SetAPen(rp, 1)
ENDPROC

-> the 0.1 CShell renderer's CSI discipline, transplanted and grown
-> up: consume sequences WHOLE (state survives split writes via
-> cesc/cpar/cnp), dispatch the full-screen set (csidispatch), drop
-> the rest silently.
PROC render(buf, len)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit
  IF win = NIL THEN RETURN
  s := buf
  WHILE i < len
    c := s[i]
    IF cesc = 1    -> after ESC: '[' opens a CSI, else two-byte seq
      IF c = "["
        csistart()
      ELSE
        cesc := 0
      ENDIF
      i := i + 1
    ELSEIF cesc = 2    -> CSI parameters end at the final byte >= $40
      IF (c >= "0") AND (c <= "9")
        cpar[cnp] := Mul(cpar[cnp], 10) + (c - 48)
        IF cpar[cnp] > 999 THEN cpar[cnp] := 999
      ELSEIF c = ";"
        cnp := cnp + 1
        IF cnp > 3 THEN cnp := 3
        cpar[cnp] := 0
      ELSEIF c >= $40
        csidispatch(c)
        cesc := 0
      ENDIF
      i := i + 1
    ELSEIF c = 27
      cesc := 1
      i := i + 1
    ELSEIF c = $9B
      csistart()
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
  IF ancx >= cols THEN RETURN -> inverted RectFill = wild writes
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
  IF rawmode
    -> raw: every key is just a byte for the client - Return is CR 13,
    -> Ctrl+C is byte 3 (no break signal), Ctrl+\ is byte 28 (no EOF)
    enqueue(code)
    inputarrived()
    RETURN
  ENDIF
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
    inputarrived()
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

-> raw-mode special keys become the console.device byte sequences.
-> Mapping recalled from the RKM console chapter (arrows verified by
-> use; shifted arrows and F-keys flagged for a boot check): Up/Down/
-> Right/Left = CSI A/B/C/D, shifted = CSI T / S / SPACE @ / SPACE A,
-> F1-F10 = CSI 0~..9~, shifted F = CSI 10~..19~, Help = CSI ?~
PROC rawcsikey(code, qual)
  DEF sh
  sh := qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
  IF code = RK_UP
    enqueue($9B)
    IF sh THEN enqueue("T") ELSE enqueue("A")
  ELSEIF code = RK_DOWN
    enqueue($9B)
    IF sh THEN enqueue("S") ELSE enqueue("B")
  ELSEIF code = RK_RIGHT
    enqueue($9B)
    IF sh THEN enqueue(32)
    IF sh THEN enqueue("@") ELSE enqueue("C")
  ELSEIF code = RK_LEFT
    enqueue($9B)
    IF sh THEN enqueue(32)
    IF sh THEN enqueue("A") ELSE enqueue("D")
  ELSEIF (code >= $50) AND (code <= $59)     -> F1..F10
    enqueue($9B)
    IF sh THEN enqueue("1")
    enqueue(48 + (code - $50))
    enqueue("~")
  ELSEIF code = $5F                          -> Help
    enqueue($9B)
    enqueue("?")
    enqueue("~")
  ELSE
    RETURN
  ENDIF
  inputarrived()
ENDPROC

PROC dorawkey(code, qual)
  DEF s:PTR TO CHAR, l, avail
  IF rawmode
    rawcsikey(code, qual)
    RETURN
  ENDIF
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
        IF (c = 10) AND (rawmode = FALSE) THEN stop := TRUE
      ENDWHILE
      ReplyPkt(pkt, n, 0)
    ENDIF
  ENDWHILE
ENDPROC

vers: CHAR '$VER: ccon-handler 0.4 (17.7.26) CCON: LTX console handler M4', 0
