-> ccon-handler.e - CCON: LTX console handler. Milestone 5: scrollback,
-> the point of it all. The 0.1 CShell scrollback model (commit 71e29b1)
-> transplanted and grown up for a full-screen console: a 4000-line byte
-> ring where the last `rows` lines ARE the visible grid, so cursor
-> positioning addresses into it and the top visible row slides into
-> history on every bottom scroll. Every draw is mirrored into the model;
-> viewing is a whole-grid redraw at an offset. Ctrl+Up/Down scrolls by
-> line (works in raw mode too - More, Ed), Shift+Up/Down by page
-> (cooked only; raw clients own shifted arrows as CSI T/S). Any output
-> or any other key snaps back to live.
->
-> Test:  Mount CCON: FROM DEVS:CCON-mountlist
->        NewShell CCON:
->        list SYS: then Shift+Up/Down, Ctrl+Up/Down; type = snap live
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
       'exec/nodes','exec/ports','exec/io','exec/tasks',
       'graphics/text','graphics/rastport',
       'devices/inputevent','devices/timer',
       'dos/dos','dos/dosextens','dos/filehandler'

CONST MARGIN=4,
      LINEMAX=400,      -> longest editable input line
      HISTMAX=32,       -> prompt history ring, entries
      INQMAX=2048,      -> input byte queue (finished lines)
      RDMAX=16,         -> pending ACTION_READ packets
      SBMAX=4000,       -> scrollback model, lines (like CShell 0.1)
      TCMAX=80,         -> tab completion: max candidates collected
      TCPOOLSZ=4096,    -> tab completion: candidate name pool, bytes
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
    evmask=0,                   -> raw input event classes requested via
                                -> CSI n { (Ed asks for 10 = MENULIST)
    -> the scrollback model (M5): SBMAX rows of cols bytes in a ring.
    -> The last `rows` ring lines are the VISIBLE grid: sbtop is the
    -> ring index of the top visible row, so a bottom scroll is sbtop++
    -> and the old top row becomes history with no copying. All index
    -> math is add/subtract wraps - no Mod, no DIVU anywhere near it.
    sb=NIL,                     -> the ring; NIL = scrollback disabled
    sbtop=0,                    -> ring index of the top visible row
    sbcnt=0,                    -> history lines above the screen (valid)
    viewoff=0,                  -> lines scrolled back; 0 = live
    wtitle[48]:STRING,          -> title-bar scroll indicator (persists:
                                -> Intuition keeps the pointer)
    -> tab completion (M5b): filesystem packets are HAND-ROLLED at exec
    -> level - built into fspkt, PutMsg'd to the filesystem's port,
    -> reply awaited on the PRIVATE fsport - so pr_MsgPort (the port
    -> our clients send to) is never touched and the no-DOS rule holds
    fsport=NIL:PTR TO mp,       -> private reply port for fs packets
    fspkt=NIL:PTR TO standardpacket,
    fsfib=NIL:PTR TO fileinfoblock,  -> longword-aligned (BPTR arg)
    fsname=NIL:PTR TO CHAR,     -> BSTR build buffer, longword-aligned
    fsdirport=NIL:PTR TO mp,    -> resolved: the filesystem's port,
    fsdirlock=0,                -> the lock being scanned,
    fsdirfree=FALSE,            -> and whether WE made it (must free)
    tcc[80]:ARRAY OF LONG,      -> candidates: ptrs into tcpool, each
    tcpool=NIL:PTR TO CHAR,     -> entry = [dirflag CHAR][name NUL]
    tcpu=0, tcn=0, tcmore=FALSE,
    tcactive=FALSE, tcsel=-1,   -> the menu: open?, highlighted index
    tcws=0, tcwend=0,           -> the word being completed, in ebuf
    tcmrows=0, tcmcols=0, tcmcolw=0, tcshown=0,
    tctmp[416]:STRING,          -> completion scratch
    tctail[404]:STRING          -> line tail during word replacement

PROC main()
  DEF proc:PTR TO process, msg:PTR TO mn, pkt:PTR TO dospacket,
      dnode:PTR TO devicenode, psig, wsig, im:PTR TO intuimessage,
      class, code, qual, mx, my, ia, secs, mics, tmp

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

  -> tab-completion plumbing (M5b): a private reply port and one
  -> hand-built StandardPacket; if anything fails, dotab just declines
  fsport := CreateMsgPort()
  fspkt := New(SIZEOF standardpacket)
  IF fspkt
    fspkt.msg.ln.name := fspkt.pkt   -> a packet rides in ln_Name,
    fspkt.pkt.link := fspkt.msg      -> and points back at its message
  ENDIF
  tmp := New(SIZEOF fileinfoblock + 4)   -> BPTR args must be longword-
  IF tmp THEN fsfib := Shl(Shr(tmp + 3, 2), 2)  -> aligned; round up
  tmp := New(260)
  IF tmp THEN fsname := Shl(Shr(tmp + 3, 2), 2)
  tcpool := New(TCPOOLSZ)

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
          IF class = IDCMP_VANILLAKEY THEN dovanilla(code, qual)
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
    snaplive()                  -> new output pulls the view back to live
    tcclose()                   -> and closes an open completion menu
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
        tcclose()
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
    [WA_TITLE, 'CCON: M5', WA_LEFT, 40, WA_TOP, 40,
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
  IF cols > 255 THEN cols := 255      -> redraw's row buffer is 256
  -> the scrollback ring: sized to the real grid width. New() zeroes
  -> (E heap is cleared), so the whole model starts as blank rows; a
  -> failed allocation just disables scrollback, the console still runs
  sb := New(Mul(SBMAX, cols))
  sbtop := 0
  sbcnt := 0
  viewoff := 0
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  FOR i := 0 TO HISTMAX - 1
    hist[i] := String(LINEMAX)
  ENDFOR
  StrCopy(ebuf, '')
  drawedit()                    -> the blip stands from the start
ENDPROC

-> ---------- the scrollback model (M5) ----------

-> pointer to the model row of visible screen row r (0 = top row).
-> Callers guard with IF sb - a NIL model means scrollback is off.
PROC visrow(r)
  DEF i
  i := sbtop + r
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC sb + Mul(i, cols)

PROC clearrow(m:PTR TO CHAR)
  DEF i
  FOR i := 0 TO cols - 1
    m[i] := 0
  ENDFOR
ENDPROC

-> redraw the whole grid from the model at the current view offset;
-> model zeroes render as spaces. viewoff = lines back, 0 = live.
PROC redraw()
  DEF r, idx, m:PTR TO CHAR, i, c, rowbuf[256]:ARRAY OF CHAR
  IF sb = NIL THEN RETURN
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  FOR r := 0 TO rows - 1
    idx := sbtop - viewoff + r
    IF idx < 0 THEN idx := idx + SBMAX
    IF idx >= SBMAX THEN idx := idx - SBMAX
    m := sb + Mul(idx, cols)
    FOR i := 0 TO cols - 1
      c := m[i]
      rowbuf[i] := IF c < 32 THEN 32 ELSE c
    ENDFOR
    Move(rp, left, topy + Mul(r, ch) + baseline)
    Text(rp, rowbuf, cols)
  ENDFOR
ENDPROC

-> the title bar doubles as the scroll-position indicator. The buffer
-> is a global: Intuition keeps the POINTER (the M4 telemetry lesson).
-> Known cosmetic gap: leaving scrollback restores our own title, so a
-> client retitle (More does one via DISK_INFO) is overwritten.
PROC settitle()
  IF viewoff > 0
    StringF(wtitle, 'CCON: M5  [scrollback -\d]', viewoff)
    SetWindowTitles(win, wtitle, -1)
  ELSE
    SetWindowTitles(win, 'CCON: M5', -1)
  ENDIF
ENDPROC

-> scroll the view by delta lines (positive = back in time), clamped
-> to the history actually stored; landing on live restores the blip
PROC scrollview(delta)
  IF sb = NIL THEN RETURN
  viewoff := viewoff + delta
  IF viewoff > sbcnt THEN viewoff := sbcnt
  IF viewoff < 0 THEN viewoff := 0
  redraw()
  settitle()
  IF (viewoff = 0) AND (rawmode = FALSE) THEN drawedit()
ENDPROC

-> any output or any non-scroll key returns the view to live
PROC snaplive()
  IF viewoff = 0 THEN RETURN
  viewoff := 0
  redraw()
  settitle()
  IF rawmode = FALSE THEN drawedit()
ENDPROC

-> ---------- output: a cell-grid renderer (CSI parsing comes with the
-> full CShell renderer transplant in a later milestone) ----------

-> scroll the whole screen up one line: pixels, model, edit anchor.
-> The old top row becomes history - just advance the ring, no copying.
PROC screenscroll()
  ScrollRaster(rp, 0, ch,
               win.borderleft, win.bordertop,
               win.width - win.borderright - 1,
               win.height - win.borderbottom - 1)
  IF ancy > 0 THEN ancy--       -> the edit anchor scrolled with the rest
  IF sb
    sbtop++
    IF sbtop >= SBMAX THEN sbtop := 0
    IF sbcnt < (SBMAX - rows) THEN sbcnt++
    clearrow(visrow(rows - 1))
  ENDIF
ENDPROC

PROC outnl()
  cx := 0
  cy++
  IF cy >= rows
    screenscroll()
    cy := rows - 1
  ENDIF
ENDPROC

PROC outchr(c)
  DEF b[2]:ARRAY OF CHAR, m:PTR TO CHAR
  IF cx >= cols THEN outnl()
  b[0] := c
  Move(rp, left + Mul(cx, cw), topy + Mul(cy, ch) + baseline)
  Text(rp, b, 1)
  IF sb
    m := visrow(cy)
    m[cx] := c
  ENDIF
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
  DEF r
  eraseeol()
  IF cy < (rows - 1)
    SetAPen(rp, 0)
    RectFill(rp, left, topy + Mul(cy + 1, ch),
             left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
    SetAPen(rp, 1)
    IF sb
      FOR r := cy + 1 TO rows - 1
        clearrow(visrow(r))
      ENDFOR
    ENDIF
  ENDIF
ENDPROC

-> L/M shift rows only inside the visible region, so the model copies
-> row CONTENTS between visible slots - the history above stays intact
PROC inslines(n)
  DEF r
  IF n < 1 THEN n := 1
  IF n > (rows - cy) THEN n := rows - cy
  ScrollRaster(rp, 0, -Mul(n, ch),
               left, topy + Mul(cy, ch),
               left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
  IF sb
    FOR r := rows - 1 TO cy + n STEP -1
      CopyMem(visrow(r - n), visrow(r), cols)
    ENDFOR
    FOR r := cy TO cy + n - 1
      clearrow(visrow(r))
    ENDFOR
  ENDIF
ENDPROC

PROC dellines(n)
  DEF r
  IF n < 1 THEN n := 1
  IF n > (rows - cy) THEN n := rows - cy
  ScrollRaster(rp, 0, Mul(n, ch),
               left, topy + Mul(cy, ch),
               left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
  IF sb
    FOR r := cy TO rows - 1 - n
      CopyMem(visrow(r + n), visrow(r), cols)
    ENDFOR
    FOR r := rows - n TO rows - 1
      clearrow(visrow(r))
    ENDFOR
  ENDIF
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
  DEF y, m:PTR TO CHAR, j
  IF cx >= cols THEN RETURN   -> inverted RectFill = wild writes
  y := topy + Mul(cy, ch)
  SetAPen(rp, 0)
  RectFill(rp, left + Mul(cx, cw), y, left + Mul(cols, cw) - 1, y + ch - 1)
  SetAPen(rp, 1)
  IF sb
    m := visrow(cy)
    FOR j := cx TO cols - 1
      m[j] := 0
    ENDFOR
  ENDIF
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
        IF sb THEN CopyMem(s + i, visrow(cy) + cx, fit)
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

PROC dovanilla(code, qual)
  DEF s:PTR TO CHAR, l, j, dup
  snaplive()                    -> typing returns the view to live
  IF rawmode
    -> raw: every key is just a byte for the client - Return is CR 13,
    -> Ctrl+C is byte 3 (no break signal), Ctrl+\ is byte 28 (no EOF)
    enqueue(code)
    inputarrived()
    RETURN
  ENDIF
  IF code = 9
    -> Tab: completion (M5b); Shift+Tab cycles the menu backwards
    dotab(qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT))
    RETURN
  ENDIF
  IF tcactive
    IF code = 13
      tcclose()   -> Enter ACCEPTS the selection and closes the menu;
      RETURN      -> the line stays put for a second Enter (zsh style)
    ELSEIF code = 27
      tcclose()   -> Esc closes the menu, the line survives
      RETURN
    ENDIF
    tcclose()     -> any other key closes it, then acts normally
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
  DEF s:PTR TO CHAR, l, avail, sh
  -> raw keys close an open completion menu - EXCEPT the qualifier
  -> keys themselves ($60-$67: Shift, Ctrl, Alt, Amiga - Shift+Tab
  -> starts with a bare Shift down-stroke) and key releases (bit 7)
  IF tcactive
    IF ((code AND $80) = 0) AND ((code < $60) OR (code > $67))
      tcclose()
    ENDIF
  ENDIF
  -> M5 scroll keys, checked before anything else: Ctrl+Up/Down by
  -> line in BOTH modes (raw clients never receive Ctrl-arrows -
  -> rawcsikey ignores the qualifier), Shift+Up/Down by page in
  -> cooked only (raw clients own shifted arrows as CSI T/S)
  sh := qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
  IF (code = RK_UP) OR (code = RK_DOWN)
    IF qual AND IEQUALIFIER_CONTROL
      scrollview(IF code = RK_UP THEN 1 ELSE -1)
      RETURN
    ELSEIF (sh <> 0) AND (rawmode = FALSE)
      scrollview(IF code = RK_UP THEN rows - 1 ELSE -(rows - 1))
      RETURN
    ENDIF
  ENDIF
  snaplive()                    -> any other key returns the view to live
  IF rawmode
    rawcsikey(code, qual)
    RETURN
  ENDIF
  s := ebuf
  l := StrLen(ebuf)
  IF code = RK_UP
    -> plain Up/Down walk the prompt history (output scrollback lives
    -> on Shift/Ctrl, above)
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

-> ---------- tab completion (M5b): the zsh menu, Amiga plumbing -----
-> Completing a word means reading a directory, and a handler must not
-> call packet-sending dos.library functions (Lock/ExNext would DoPkt
-> and wait on pr_MsgPort - the port our own clients send to). So the
-> packets are hand-rolled at exec level: LOCATE_OBJECT / EXAMINE_
-> OBJECT / EXAMINE_NEXT / FREE_LOCK go straight to the FILESYSTEM's
-> port with the private fsport as reply port. The client's current
-> directory for relative words comes from the blocked reader's own
-> process structure (pr_CurrentDir via the queued read packet's
-> sender); words with a ':' resolve through the DOS list
-> (LockDosList/FindDosEntry - semaphores, not packets). Struct
-> offsets cross-checked against amitools' libstructs.

-> one packet round-trip; the reply lands on fsport, never pr_MsgPort
PROC fscall(tport:PTR TO mp, act, a1, a2, a3)
  IF tport = NIL THEN RETURN 0
  IF tport = port THEN RETURN 0   -> never send to OURSELVES: deadlock
  fspkt.pkt.type := act
  fspkt.pkt.arg1 := a1
  fspkt.pkt.arg2 := a2
  fspkt.pkt.arg3 := a3
  fspkt.pkt.res1 := 0
  fspkt.pkt.res2 := 0
  fspkt.pkt.port := fsport
  fspkt.msg.replyport := fsport
  PutMsg(tport, fspkt.msg)
  WaitPort(fsport)
  GetMsg(fsport)
ENDPROC fspkt.pkt.res1

-> build a BSTR (length byte + chars) in the aligned buffer
PROC tcbstr(s:PTR TO CHAR)
  DEF l, i
  l := StrLen(s)
  IF l > 254 THEN l := 254
  fsname[0] := l
  FOR i := 0 TO l - 1
    fsname[i + 1] := s[i]
  ENDFOR
ENDPROC Shr(fsname, 2)

-> the FIB filename at packet level: some filesystems write a C
-> string, some a BCPL one (length byte first). Filenames never start
-> with a control byte, so first-byte < 32 = BCPL - covers both.
PROC tcfibname(out:PTR TO CHAR)
  DEF s:PTR TO CHAR, l, i
  s := fsfib.filename
  IF (s[0] > 0) AND (s[0] < 32)
    l := s[0]
    IF l > 107 THEN l := 107
    FOR i := 0 TO l - 1
      out[i] := s[i + 1]
    ENDFOR
    out[l] := 0
  ELSE
    i := 0
    WHILE (s[i] <> 0) AND (i < 107)
      out[i] := s[i]
      i++
    ENDWHILE
    out[i] := 0
  ENDIF
ENDPROC

-> case fold for matching: ASCII a-z and the Latin-1 lower half
PROC tcfold(c)
  IF (c >= "a") AND (c <= "z") THEN RETURN c - 32
  IF (c >= 224) AND (c <= 254) AND (c <> 247) THEN RETURN c - 32
ENDPROC c

PROC tcpref(name:PTR TO CHAR, pfx:PTR TO CHAR, len)
  DEF i
  FOR i := 0 TO len - 1
    IF name[i] = 0 THEN RETURN FALSE
    IF tcfold(name[i]) <> tcfold(pfx[i]) THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

PROC tccmp(a:PTR TO CHAR, b:PTR TO CHAR)
  DEF i, ca, cb
  i := 0
  WHILE TRUE
    ca := tcfold(a[i])
    cb := tcfold(b[i])
    IF ca < cb THEN RETURN -1
    IF ca > cb THEN RETURN 1
    IF ca = 0 THEN RETURN 0
    i++
  ENDWHILE
ENDPROC 0

-> the client whose directory a relative word completes in: the
-> blocked reader (its Read packet is queued while it waits on our
-> line), or the break owner as fallback; must be a Process
PROC tcclient()
  DEF t:PTR TO tc, pkt:PTR TO dospacket, sender:PTR TO mp
  t := NIL
  IF rdn > 0
    pkt := rdq[0]
    sender := pkt.port
    t := sender.sigtask
  ELSEIF breaktask
    t := breaktask
  ENDIF
  IF t = NIL THEN RETURN NIL
  IF t.ln.type <> NT_PROCESS THEN RETURN NIL
ENDPROC t

-> resolve the word's directory part into fsdirport + fsdirlock;
-> fsdirfree marks a lock WE made (tcfreelock returns it). Returns
-> FALSE when the path cannot be resolved without breaking the rules.
PROC tcresolve(dirpart:PTR TO CHAR)
  DEF proc:PTR TO process, fl:PTR TO filelock, i, colon, len, res,
      dl:PTR TO doslist, dcopy[300]:ARRAY OF CHAR,
      devname[40]:ARRAY OF CHAR
  fsdirport := NIL
  fsdirlock := 0
  fsdirfree := FALSE
  len := StrLen(dirpart)
  IF len > 280 THEN RETURN FALSE
  FOR i := 0 TO len
    dcopy[i] := dirpart[i]
  ENDFOR
  -> strip ONE trailing '/' (a dir word like `Docs/`) - but keep it
  -> after another '/' or a ':' (leading-slash parent refs, "SYS:/")
  IF len > 1
    IF (dcopy[len - 1] = "/") AND (dcopy[len - 2] <> "/") AND
       (dcopy[len - 2] <> ":")
      len := len - 1
      dcopy[len] := 0
    ENDIF
  ENDIF
  colon := -1
  i := 0
  WHILE (i < len) AND (colon = -1)
    IF dcopy[i] = ":" THEN colon := i
    i++
  ENDWHILE
  IF colon = -1
    -> relative: base = the client's own current directory
    proc := tcclient()
    IF proc = NIL THEN RETURN FALSE
    IF proc.currentdir = 0 THEN RETURN FALSE
    fl := Shl(proc.currentdir, 2)
    fsdirport := fl.task
    IF len = 0
      fsdirlock := proc.currentdir     -> scan the CWD itself; not ours
      RETURN TRUE                      -> to free
    ENDIF
    res := fscall(fsdirport, ACTION_LOCATE_OBJECT, proc.currentdir,
                  tcbstr(dcopy), SHARED_LOCK)
    IF res = 0 THEN RETURN FALSE
    fsdirlock := res
    fsdirfree := TRUE
    RETURN TRUE
  ENDIF
  -> a device, volume or assign name before the ':'
  IF colon > 36 THEN RETURN FALSE
  FOR i := 0 TO colon - 1
    devname[i] := dcopy[i]
  ENDFOR
  devname[colon] := 0
  dl := LockDosList(LDF_READ OR LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
  dl := FindDosEntry(dl, devname, LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
  IF dl = NIL
    UnLockDosList(LDF_READ OR LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
    RETURN FALSE
  ENDIF
  IF dl.type = DLT_DIRECTORY
    -> an assign: its lock is the base, the rest is relative to it
    fsdirlock := dl.lock
    UnLockDosList(LDF_READ OR LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
    IF fsdirlock = 0 THEN RETURN FALSE  -> late/nonbinding, unresolved
    fl := Shl(fsdirlock, 2)
    fsdirport := fl.task
    IF (colon + 1) < len
      res := fscall(fsdirport, ACTION_LOCATE_OBJECT, fsdirlock,
                    tcbstr(dcopy + colon + 1), SHARED_LOCK)
      IF res = 0 THEN RETURN FALSE
      fsdirlock := res
      fsdirfree := TRUE
    ENDIF
    RETURN TRUE
  ENDIF
  -> a volume or device: its handler port takes the whole "NAME:path"
  -> name against a zero lock (what dos.library itself does)
  fsdirport := dl.task
  UnLockDosList(LDF_READ OR LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
  IF fsdirport = NIL THEN RETURN FALSE  -> not mounted/started; starting
  res := fscall(fsdirport, ACTION_LOCATE_OBJECT, 0,  -> it needs DOS
                tcbstr(dcopy), SHARED_LOCK)
  IF res = 0 THEN RETURN FALSE
  fsdirlock := res
  fsdirfree := TRUE
ENDPROC TRUE

PROC tcfreelock()
  IF fsdirfree AND (fsdirlock <> 0)
    fscall(fsdirport, ACTION_FREE_LOCK, fsdirlock, 0, 0)
  ENDIF
  fsdirlock := 0
  fsdirfree := FALSE
ENDPROC

-> scan the resolved directory for names starting with the prefix
PROC tcscan(pfx:PTR TO CHAR, plen)
  DEF res, nbuf[112]:ARRAY OF CHAR, l, p:PTR TO CHAR
  tcn := 0
  tcpu := 0
  tcmore := FALSE
  res := fscall(fsdirport, ACTION_EXAMINE_OBJECT, fsdirlock,
                Shr(fsfib, 2), 0)
  IF res = 0 THEN RETURN
  IF fsfib.direntrytype <= 0 THEN RETURN   -> a file, not a directory
  WHILE fscall(fsdirport, ACTION_EXAMINE_NEXT, fsdirlock,
               Shr(fsfib, 2), 0)
    tcfibname(nbuf)
    l := StrLen(nbuf)
    IF l > 0
      IF (plen = 0) OR tcpref(nbuf, pfx, plen)
        IF (tcn < TCMAX) AND ((tcpu + l + 3) < TCPOOLSZ)
          p := tcpool + tcpu
          p[0] := IF fsfib.direntrytype > 0 THEN 1 ELSE 0
          CopyMem(nbuf, p + 1, l + 1)
          tcc[tcn] := p
          tcn++
          tcpu := tcpu + l + 2
        ELSE
          tcmore := TRUE
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

PROC tcsort()
  DEF i, j, key, go
  FOR i := 1 TO tcn - 1
    key := tcc[i]
    j := i - 1
    go := TRUE
    WHILE go
      IF j < 0
        go := FALSE
      ELSEIF tccmp(tcc[j] + 1, key + 1) > 0
        tcc[j + 1] := tcc[j]
        j--
      ELSE
        go := FALSE
      ENDIF
    ENDWHILE
    tcc[j + 1] := key
  ENDFOR
ENDPROC

-> length of the folded common prefix of all candidates
PROC tccommon()
  DEF l, i, k, a:PTR TO CHAR, b:PTR TO CHAR
  a := tcc[0] + 1
  l := StrLen(a)
  FOR k := 1 TO tcn - 1
    b := tcc[k] + 1
    i := 0
    WHILE (i < l) AND (b[i] <> 0) AND (tcfold(a[i]) = tcfold(b[i]))
      i++
    ENDWHILE
    l := i
  ENDFOR
ENDPROC l

-> replace ebuf[tcws..tcwend) with nl bytes at nt; FALSE = no fit
PROC tcreplace(nt:PTR TO CHAR, nl)
  DEF s:PTR TO CHAR, t:PTR TO CHAR, l, newlen, i
  s := ebuf
  l := StrLen(ebuf)
  newlen := tcws + nl + (l - tcwend)
  IF newlen >= LINEMAX THEN RETURN FALSE
  IF (ancx + newlen) >= (cols - 1) THEN RETURN FALSE
  StrCopy(tctail, s + tcwend)
  t := tctail
  FOR i := 0 TO nl - 1
    s[tcws + i] := nt[i]
  ENDFOR
  FOR i := 0 TO StrLen(tctail) - 1
    s[tcws + nl + i] := t[i]
  ENDFOR
  SetStr(ebuf, newlen)
  s[newlen] := 0
  tcwend := tcws + nl
  cpos := tcwend
ENDPROC TRUE

-> ---------- the menu below the prompt ----------

-> repaint one screen row from the live model (menu cleanup)
PROC drawmodelrow(r)
  DEF idx, m:PTR TO CHAR, i, c, rowbuf[256]:ARRAY OF CHAR
  IF sb = NIL THEN RETURN
  idx := sbtop + r
  IF idx >= SBMAX THEN idx := idx - SBMAX
  m := sb + Mul(idx, cols)
  FOR i := 0 TO cols - 1
    c := m[i]
    rowbuf[i] := IF c < 32 THEN 32 ELSE c
  ENDFOR
  SetAPen(rp, 1)
  SetBPen(rp, 0)
  Move(rp, left, topy + Mul(r, ch) + baseline)
  Text(rp, rowbuf, cols)
ENDPROC

PROC tcmenucalc()
  DEF i, l, maxl, p:PTR TO CHAR
  maxl := 1
  FOR i := 0 TO tcn - 1
    p := tcc[i]
    l := StrLen(p + 1) + p[0]   -> dirs show with a trailing '/'
    IF l > maxl THEN maxl := l
  ENDFOR
  tcmcolw := maxl + 2
  IF tcmcolw > cols THEN tcmcolw := cols
  tcmcols := Div(cols, tcmcolw)
  IF tcmcols < 1 THEN tcmcols := 1
  tcmrows := Div(tcn + tcmcols - 1, tcmcols)
  IF tcmrows > (rows - 1)       -> more than fits: show the first
    tcmrows := rows - 1         -> page, cycle within it
    tcmore := TRUE
  ENDIF
  tcshown := Mul(tcmrows, tcmcols)
  IF tcshown > tcn THEN tcshown := tcn
ENDPROC

PROC tcmenudraw()
  DEF idx, r, c, p:PTR TO CHAR, l, nb[260]:ARRAY OF CHAR
  FOR idx := 0 TO tcshown - 1
    r := Div(idx, tcmcols)
    c := idx - Mul(r, tcmcols)
    p := tcc[idx]
    l := StrLen(p + 1)
    CopyMem(p + 1, nb, l)
    IF p[0]
      nb[l] := "/"
      l++
    ENDIF
    WHILE l < tcmcolw
      nb[l] := 32
      l++
    ENDWHILE
    IF idx = tcsel
      SetAPen(rp, 0)
      SetBPen(rp, 1)
    ELSE
      SetAPen(rp, 1)
      SetBPen(rp, 0)
    ENDIF
    Move(rp, left + Mul(Mul(c, tcmcolw), cw),
         topy + Mul(ancy + 1 + r, ch) + baseline)
    Text(rp, nb, l)
  ENDFOR
  SetAPen(rp, 1)
  SetBPen(rp, 0)
ENDPROC

-> close the menu: the rows under it come back from the model
PROC tcclose()
  DEF r
  IF tcactive = FALSE THEN RETURN
  FOR r := 1 TO tcmrows
    drawmodelrow(ancy + r)
  ENDFOR
  tcactive := FALSE
  tcsel := -1
ENDPROC

-> Tab in the cooked editor. First Tab completes (whole match, or the
-> common prefix + the menu); further Tabs cycle the menu, Shift+Tab
-> backwards; Enter accepts and closes, Esc closes, anything else
-> closes and then acts normally.
PROC dotab(back)
  DEF s:PTR TO CHAR, l, i, sep, plen, cpl, p:PTR TO CHAR,
      dirp[300]:ARRAY OF CHAR
  IF tcactive
    IF tcshown = 0 THEN RETURN
    IF back
      tcsel := tcsel - 1
      IF tcsel < 0 THEN tcsel := tcshown - 1
    ELSE
      tcsel := tcsel + 1
      IF tcsel >= tcshown THEN tcsel := 0
    ENDIF
    p := tcc[tcsel]
    StrCopy(tctmp, p + 1)
    IF p[0] THEN StrAdd(tctmp, '/')
    IF tcreplace(tctmp, StrLen(tctmp)) THEN drawedit()
    tcmenudraw()
    RETURN
  ENDIF
  IF (fsport = NIL) OR (fspkt = NIL) OR (fsfib = NIL) OR
     (fsname = NIL) OR (tcpool = NIL) THEN RETURN
  s := ebuf
  l := StrLen(ebuf)
  -> the word: back from the cursor to the last space (v1: no quotes)
  i := cpos
  WHILE (i > 0) AND (s[i - 1] <> 32)
    i := i - 1
  ENDWHILE
  tcws := i
  tcwend := cpos
  -> split the word at its last '/' or ':': dirpart + prefix
  sep := tcws
  FOR i := tcws TO cpos - 1
    IF (s[i] = "/") OR (s[i] = ":") THEN sep := i + 1
  ENDFOR
  IF (sep - tcws) > 280 THEN RETURN
  FOR i := 0 TO sep - tcws - 1
    dirp[i] := s[tcws + i]
  ENDFOR
  dirp[sep - tcws] := 0
  plen := cpos - sep
  IF tcresolve(dirp) = FALSE
    DisplayBeep(NIL)
    RETURN
  ENDIF
  tcscan(s + sep, plen)
  tcfreelock()
  IF tcn = 0
    DisplayBeep(NIL)
    RETURN
  ENDIF
  tcsort()
  IF tcn = 1
    -> the one match: complete it, '/' opens a dir, ' ' ends a file
    p := tcc[0]
    StrCopy(tctmp, p + 1)
    StrAdd(tctmp, IF p[0] THEN '/' ELSE ' ')
    IF tcreplace(tctmp, StrLen(tctmp))
      drawedit()
    ELSE
      DisplayBeep(NIL)
    ENDIF
    RETURN
  ENDIF
  -> several: extend to the common prefix (filesystem case, from the
  -> first candidate), then the menu
  cpl := tccommon()
  IF cpl > 0
    p := tcc[0]
    FOR i := 0 TO cpl - 1
      tctmp[i] := p[1 + i]
    ENDFOR
    tctmp[cpl] := 0
    SetStr(tctmp, cpl)
    IF tcreplace(tctmp, cpl) THEN drawedit()
  ENDIF
  IF sb = NIL THEN RETURN   -> no model = no way to restore the rows
  tcmenucalc()              -> under a menu; prefix-only completion
  WHILE (ancy + tcmrows) > (rows - 1)
    screenscroll()          -> make room below the prompt; the edit
    IF cy > 0 THEN cy--     -> line's pixels scroll along, anchor and
  ENDWHILE                  -> output cursor track it
  tcsel := -1
  tcactive := TRUE
  tcmenudraw()
  IF tcmore THEN DisplayBeep(NIL)  -> more than the menu shows
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

vers: CHAR '$VER: ccon-handler 0.6 (17.7.26) CCON: LTX console handler M5b', 0
