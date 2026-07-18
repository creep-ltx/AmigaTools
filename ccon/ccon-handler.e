-> ccon-handler.e - CCON: LTX console handler. Milestone 6: input the
-> way console.device does it. Keys no longer arrive through the
-> window's IDCMP: an input.device handler (IND_ADDHANDLER, priority
-> below Intuition) captures events for our window while it is active,
-> copies them into a ring and signals the handler task, which runs
-> them through keymap.library. The UserPort sits idle - free for Ed
-> to commandeer with its ModifyIDCMP/GetMsg surgery, which is what
-> froze the machine four times under the IDCMP design - and the raw
-> event reports (CSI n{) are live again, carrying Intuition's real
-> ie_EventAddress. M5 scrollback, M5b completion, M5c open
-> semantics, M5d colours all ride on top unchanged; if the chain
-> hookup fails, ihon stays FALSE and the boot-proven IDCMP path is
-> the fallback, end to end.
->
-> Test:  Mount CCON: FROM DEVS:CCON-mountlist
->        NewShell CCON:
->        list SYS: then Shift+Up/Down, Ctrl+Up/Down; type = snap live
->        then Ed on a file - the menus should WORK now
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

MODULE 'intuition/intuition','intuition/intuitionbase',
       'utility/tagitem',
       'exec/nodes','exec/ports','exec/io','exec/tasks',
       'exec/interrupts',
       'graphics/text','graphics/rastport','graphics/gfx',
       'devices/inputevent','devices/timer','devices/input',
       'devices/clipboard',
       'dos/dos','dos/dosextens','dos/filehandler',
       'keymap'

CONST MARGIN=4,
      LINEMAX=400,      -> longest editable input line
      HISTMAX=32,       -> prompt history ring, entries
      INQMAX=2048,      -> input byte queue (finished lines)
      RDMAX=16,         -> pending ACTION_READ packets
      SBMAX=4000,       -> scrollback model, lines (like CTerm 0.1)
      TCMAX=80,         -> tab completion: max candidates collected
      TCPOOLSZ=4096,    -> tab completion: candidate name pool, bytes
      WQMAX=16,         -> writes parked during a selection drag
      CLIPMAX=16384,    -> clipboard transfer buffer, bytes
      IHMAX=64,         -> input-event ring, slots (power of two)
      IHPRI=20,         -> chain position: below Intuition's 50, above
                        -> console.device's 0 - menu operations arrive
                        -> already digested into IECLASS_MENULIST
      RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F

-> one captured input event (M6). The ring stride is 32 (Shl, no Mul
-> in the input.device context); addr carries ie_EventAddress, which
-> for RAWKEY is the dead-key prev-down bytes MapRawKey composes from
OBJECT ihev
  cls:CHAR
  sub:CHAR
  code:INT
  qual:INT
  pad:INT
  addr:LONG
  secs:LONG
  mics:LONG
ENDOBJECT

DEF port:PTR TO mp,             -> our packet port = pr_MsgPort
    win=NIL:PTR TO window,
    rp=NIL:PTR TO rastport,
    tf=NIL:PTR TO textfont,
    cw, ch, baseline,           -> cell metrics (topaz: fixed)
    left, topy, cols, rows,     -> the text grid inside the window
    cx=0, cy=0,                 -> output cursor, in cells
    cursx=-1, cursy=0,          -> where the raw-mode block cursor is
                                -> painted right now; -1 = not painted
    -> copy & paste (M7): drag-select on the M6 chain's mouse events,
    -> copy to clipboard.device unit 0 as IFF FTXT on release,
    -> RAMIGA-V injects the clip as typed input
    selon=FALSE,                -> a drag is in progress
    selanc=-1, selcur=-1,       -> anchor/current cell, row*cols+x
    sello=-1, selhi=-1,         -> the standing highlight, [lo,hi)
    selvo=0,                    -> viewoff the selection was made at
    wq[16]:ARRAY OF LONG,       -> writers wait while a drag holds
    wqn=0,                      -> the screen still (stock behaviour)
    clipport=NIL:PTR TO mp,
    clipreq=NIL:PTR TO ioclipreq,
    clipbuf=NIL:PTR TO CHAR,
    opens=0,
    -> the line editor (transplanted from CTerm 0.1, commit 71e29b1)
    ebuf[404]:STRING,           -> the line being typed
    stash[404]:STRING,          -> half-typed line parked during history
    cpos=0,                     -> cursor inside ebuf
    ancx=0, ancy=0,             -> cell where the edit line is drawn
    edlast=0,                   -> chars the last drawedit painted
                                -> (eraseedit must clear that many)
    tcmrow0=0,                  -> completion menu's first row, frozen
                                -> at open (the wrapped edit line may
                                -> change height while cycling)
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
    sa=NIL,                     -> its attr plane: one byte per cell -
                                -> fg pen in the low nibble, bg in the
                                -> high - so colours survive redraws
    sbtop=0,                    -> ring index of the top visible row
    sbcnt=0,                    -> history lines above the screen (valid)
    viewoff=0,                  -> lines scrolled back; 0 = live
    -> SGR state (M5d): CSI ...m renders now. deffg comes from the
    -> open name's PEN option (CTerm passes PEN7 on its ANSI screen);
    -> bold maps to the bright pens 8-15 when the screen is deep
    -> enough (can16), the 1996 ANSI-art convention
    deffg=1, curfg=1, curbg=0, bold=FALSE, can16=FALSE,
    wbpens=FALSE,               -> WBPENS option: plain SGR 30-33
                                -> are WB pens, retarget at theme
    wtitle[112]:STRING,         -> title-bar scroll indicator (persists:
                                -> Intuition keeps the pointer)
    -> tab completion (M5b): filesystem packets are HAND-ROLLED at exec
    -> level - built into fspkt, PutMsg'd to the filesystem's port,
    -> reply awaited on the PRIVATE fsport - so pr_MsgPort (the port
    -> our clients send to) is never touched and the no-DOS rule holds
    fsport=NIL:PTR TO mp,       -> private reply port for fs packets
    fspkt=NIL:PTR TO standardpacket,
    fsfib=NIL:PTR TO fileinfoblock,  -> longword-aligned (BPTR arg)
    fsname=NIL:PTR TO CHAR,     -> BSTR build buffer, longword-aligned
    -> M5c: per-open window spec, parsed from the open name
    -> "CCON:x/y/w/h/title/options" (options: CLOSE, WAIT, WINDOW0x)
    pwx=40, pwy=40, pww=520, pwh=160,
    waitmode=FALSE, closegad=FALSE,
    fwptr=NIL,                  -> WINDOW0xADDR: borrow this window
    fwin=FALSE, oldidcmp=0,     -> borrowed-window bookkeeping
    closereq=FALSE,             -> close gadget seen; close after drain
    histdone=FALSE,             -> hist strings are made only once
    wtitlebase[84]:STRING,      -> the parsed window title
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
    tctail[404]:STRING,         -> line tail during word replacement
    -> M6: keys come from the input.device chain, not the window's
    -> IDCMP - console.device's architecture. The interrupt's code is
    -> gluestub; ihchain runs in input.device's task and fills ihring;
    -> the main loop drains it on ihsig. ihon=FALSE falls back to the
    -> boot-proven IDCMP path (0.8 behaviour) end to end.
    ihgd[2]:ARRAY OF LONG,      -> glue data: [E's A4][{ihchain}]
    ihcapa4=0,                  -> A4, captured by inline asm at start
    ihis=NIL:PTR TO is,         -> the interrupt in input.device's chain
    ihport=NIL:PTR TO mp,
    ihreq=NIL:PTR TO iostd,
    ihon=FALSE,
    ihwin=NIL,                  -> take events for THIS window when it
                                -> is the active one; NIL = take nothing
    ihtask=NIL, ihsigbit=-1, ihsig=0,
    ihring=NIL:PTR TO CHAR,     -> IHMAX slots, stride 32
    ihhead=0, ihtail=0,         -> free-running; slot = n AND (IHMAX-1)
    ihdrop=0,                   -> events lost to a full ring
    ihie=NIL:PTR TO inputevent, -> rebuilt event for MapRawKey
    ihiebuf[8]:ARRAY OF LONG,   -> its longword-aligned storage
    ihmap[36]:ARRAY OF CHAR     -> MapRawKey result bytes

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

  -> M6: hook into the input.device chain (console.device's own
  -> architecture: keys are taken upstream, the window's UserPort
  -> stays idle for clients like Ed to commandeer). Every step is
  -> exec-only. If anything fails, ihon stays FALSE and the window
  -> falls back to IDCMP keys - the boot-proven 0.8 path.
  ihtask := FindTask(NIL)
  ihsigbit := AllocSignal(-1)
  ihring := New(Shl(IHMAX, 5))
  ihie := ihiebuf
  -> keymap.library is NOT one of E's auto-opened four - the module
  -> only declares the base. It lives in ROM, so OpenLibrary is pure
  -> exec, no packets. (Found by disassembly: the compiled MapRawKey
  -> stub jumps through keymapbase, and nothing had ever set it.)
  keymapbase := OpenLibrary('keymap.library', 36)
  IF (ihsigbit >= 0) AND (ihring <> NIL) AND (keymapbase <> NIL)
    ihsig := Shl(1, ihsigbit)
    MOVE.L A4,ihcapa4
    ihgd[0] := ihcapa4
    ihgd[1] := {ihchain}
    ihport := CreateMsgPort()
    IF ihport
      ihreq := CreateIORequest(ihport, SIZEOF iostd)
      IF ihreq
        IF OpenDevice('input.device', 0, ihreq, 0) = 0
          ihis := New(SIZEOF is)
          IF ihis
            ihis.ln.type := NT_INTERRUPT
            ihis.ln.pri := IHPRI
            ihis.ln.name := 'CCON'
            ihis.data := ihgd
            ihis.code := {gluestub}
            ihreq.command := IND_ADDHANDLER
            ihreq.data := ihis
            DoIO(ihreq)
            IF ihreq.error = 0 THEN ihon := TRUE
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDIF

  psig := Shl(1, port.sigbit)
  WHILE TRUE
    wsig := 0
    IF win THEN wsig := Shl(1, win.userport.sigbit)
    IF tport THEN wsig := wsig OR Shl(1, tport.sigbit)
    IF ihon THEN wsig := wsig OR ihsig
    Wait(psig OR wsig)
    -> drain the packet port
    REPEAT
      msg := GetMsg(port)
      IF msg THEN dopkt(msg.ln.name)
    UNTIL msg = NIL
    -> drain the captured input events (M6)
    IF ihon THEN ihdrain()
    -> drain the window port - UNLESS a client asked for raw event
    -> reports (Ed). Disassembling C:Ed (18.7.26) showed it never
    -> touches this port at all (no ModifyIDCMP/GetMsg on our window;
    -> the LVO hits that suggested it were rexxsyslib collisions -
    -> Ed's ARexx machinery). The park stays anyway: with the chain
    -> on, the only IDCMP class left is CLOSEWINDOW, and deferring a
    -> close-gadget click while a raw-events client (Ed fullscreen)
    -> owns the session beats tearing the window down under it.
    -> Leftovers drain when the mask clears (CSI }, cooked
    -> reversion, close).
    IF win
      IF (ihon = FALSE) OR (evmask = 0)
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
            IF class = IDCMP_MOUSEBUTTONS THEN selmouse(code)
            IF class = IDCMP_MOUSEMOVE THEN selmouse($FF)
            IF class = IDCMP_CLOSEWINDOW THEN doclosew()
          ENDIF
        UNTIL im = NIL
      ENDIF
      IF closereq                 -> deferred: never CloseWindow while
        closereq := FALSE         -> draining the port it owns
        closewin()
      ENDIF
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
    opens--
    IF opens <= 0
      opens := 0
      breaktask := NIL
      IF win
        IF waitmode = FALSE     -> stock CON: semantics: the window
          closewin()            -> closes with its last handle; WAIT
        ENDIF                   -> lingers for its close gadget (and a
      ENDIF                     -> new open re-attaches to it)
    ENDIF
    ReplyPkt(pkt, DOSTRUE, 0)
  CASE ACTION_WRITE
    IF selon AND (wqn < WQMAX)
      wq[wqn] := pkt            -> a drag holds the screen still: the
      wqn++                     -> writer waits, unreplied, until the
    ELSE                        -> button releases (stock console
      dowrite(pkt)              -> behaviour - output freezes while
    ENDIF                       -> you select)
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
        cursdraw()              -> the block cursor appears at once
      ENDIF
    ELSE
      IF rawmode
        rawmode := FALSE
        curserase()             -> the blip owns cooked mode
        reanchor()
        drawedit()
      ENDIF
      -> a client reverting to cooked is done with its raw event
      -> reports too (Ed does not send CSI } on exit); clearing the
      -> mask also resumes the parked UserPort drain (M6)
      evmask := 0
      setidcmp()                -> and MOUSEBUTTONS comes back
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
  CASE ACTION_EXAMINE_FH
    -> consoles fail this (the Guru Book rule); clib's isatty probes
    -> it and takes the failure as "yes, a terminal"
    ReplyPkt(pkt, DOSFALSE, ERROR_ACTION_NOT_KNOWN)
  DEFAULT
    ReplyPkt(pkt, DOSFALSE, ERROR_ACTION_NOT_KNOWN)
  ENDSELECT
ENDPROC

-> one ACTION_WRITE, for the dispatcher and for the parked-write
-> flush after a selection drag ends
PROC dowrite(pkt:PTR TO dospacket)
  DEF sender:PTR TO mp, len
  sender := pkt.port            -> the writer owns the break signal too:
  breaktask := sender.sigtask   -> `list >CCON:` is opened by the SHELL,
                                -> but the WRITEs come from list itself -
                                -> this line is what makes Ctrl+C reach it
                                -> (AROS con-handler does the same)
  len := pkt.arg3
  clearsel()                    -> output takes the highlight with it
  snaplive()                    -> new output pulls the view back to live
  tcclose()                     -> and closes an open completion menu
  IF rawmode
    curserase()                 -> raw: the app owns the screen, no blip
    render(pkt.arg2, len)       -> - but the console owns the block
    cursdraw()                  -> cursor (Ed's only position marker)
  ELSE
    eraseedit()
    render(pkt.arg2, len)
    reanchor()
    drawedit()
  ENDIF
  ReplyPkt(pkt, len, 0)
ENDPROC

PROC flushwq()
  DEF i
  i := 0
  WHILE i < wqn
    dowrite(wq[i])              -> FIFO: writers resume in order
    i++
  ENDWHILE
  wqn := 0
ENDPROC

-> a decimal field; -1 = empty or not a number (keep the default)
PROC tcnum(t:PTR TO CHAR)
  DEF v=0, i=0
  IF t[0] = 0 THEN RETURN -1
  WHILE t[i]
    IF (t[i] < "0") OR (t[i] > "9") THEN RETURN -1
    v := Mul(v, 10) + (t[i] - 48)
    IF v > 20000 THEN v := 20000
    i++
  ENDWHILE
ENDPROC v

-> parse the open name "CCON:x/y/w/h/title/options" into the pw*
-> globals. Every field may be empty; options are CLOSE (close
-> gadget = EOF), WAIT (window lingers for its close gadget) and
-> WINDOW0xADDR (borrow an existing window - CON:-compatible, the
-> exact string CTerm's frame handoff sends). Unknown options are
-> ignored. Field order is stock CON:'s.
PROC parsecon(bname)
  DEF s:PTR TO CHAR, l, i, f, tl, v, c, tok[84]:ARRAY OF CHAR
  pwx := 40
  pwy := 40
  pww := 520
  pwh := 160
  StrCopy(wtitlebase, 'CCON:')
  waitmode := FALSE
  closegad := FALSE
  fwptr := NIL
  deffg := 1
  wbpens := FALSE
  IF bname = 0 THEN RETURN
  s := Shl(bname, 2)            -> a BSTR: length byte, then chars
  l := s[0]
  i := 1
  WHILE (i <= l) AND (s[i] <> ":")
    i++
  ENDWHILE
  IF i > l THEN RETURN          -> no ':' at all: all defaults
  i++
  f := 0
  WHILE i <= l
    tl := 0
    WHILE (i <= l) AND (s[i] <> "/")
      IF tl < 80
        tok[tl] := s[i]
        tl++
      ENDIF
      i++
    ENDWHILE
    i++                         -> past the '/'
    tok[tl] := 0
    IF f = 0
      v := tcnum(tok)
      IF v >= 0 THEN pwx := v
    ELSEIF f = 1
      v := tcnum(tok)
      IF v >= 0 THEN pwy := v
    ELSEIF f = 2
      v := tcnum(tok)
      IF v >= 0 THEN pww := v
    ELSEIF f = 3
      v := tcnum(tok)
      IF v >= 0 THEN pwh := v
    ELSEIF f = 4
      IF tl > 0 THEN StrCopy(wtitlebase, tok)
    ELSE
      -> an option: fold to upper case in place, then compare
      v := 0
      WHILE tok[v]
        tok[v] := tcfold(tok[v])
        v++
      ENDWHILE
      IF StrCmp(tok, 'WAIT')
        waitmode := TRUE
        closegad := TRUE        -> WAIT needs the gadget to end
      ELSEIF StrCmp(tok, 'CLOSE')
        closegad := TRUE
      ELSEIF StrCmp(tok, 'WBPENS')
        -> translate the classic Workbench pens when a program
        -> hardcodes them: C:Ed prints its body text as SGR 31
        -> ("pen 1" = BLACK on the WB palette) and highlights as
        -> 33 (WB blue). On an ANSI palette pen 1 is red, so a
        -> client that owns such a screen (CTerm's dark theme)
        -> sends WBPENS and plain 30-33 become theme pens
        -> instead: 30->0, 31->deffg, 32->15, 33->12. Bold forms
        -> (1;3x - the ls scheme) and backgrounds are untouched.
        wbpens := TRUE
      ELSEIF StrCmp(tok, 'PEN', 3)
        -> PENn: the default text pen (CTerm sends PEN7 with its
        -> ANSI palette, where pen 1 is ANSI red)
        v := tcnum(tok + 3)
        IF (v >= 1) AND (v <= 15) THEN deffg := v
      ELSEIF StrCmp(tok, 'WINDOW0X', 8)
        v := 0
        c := 8
        WHILE tok[c]
          IF (tok[c] >= "0") AND (tok[c] <= "9")
            v := Shl(v, 4) + (tok[c] - 48)
          ELSEIF (tok[c] >= "A") AND (tok[c] <= "F")
            v := Shl(v, 4) + (tok[c] - 55)
          ENDIF
          c++
        ENDWHILE
        fwptr := v
      ENDIF
    ENDIF
    f++
  ENDWHILE
ENDPROC

PROC dofind(pkt:PTR TO dospacket)
  DEF fh:PTR TO filehandle, sender:PTR TO mp
  IF win = NIL
    parsecon(pkt.arg3)          -> the FIRST open decides the window;
    openwin()                   -> later opens attach to it as-is
  ENDIF
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
  DEF ta:PTR TO textattr, i, idc
  fwin := FALSE
  -> M6: with the input.device handler on, keys never touch IDCMP -
  -> the UserPort carries only the close gadget, stock console.device
  -> shape. IDCMP_MENUPICK must NOT be set: with it, Intuition delivers
  -> a menu pick as an IntuiMessage to the UserPort and it never enters
  -> the input stream - without it, the pick travels downstream as an
  -> IECLASS_MENULIST input event, which is what ihchain catches and
  -> ihreport turns into the CSI report Ed's parser reads (this is
  -> exactly how Ed works on a stock CON: window, which carries no
  -> MENUPICK either - console.device picks the event up at pri 0).
  -> Without the chain, the boot-proven IDCMP key path stays as it was.
  idc := IDCMP_CLOSEWINDOW
  IF ihon = FALSE THEN idc := idc OR IDCMP_RAWKEY OR IDCMP_VANILLAKEY OR IDCMP_MENUPICK
  IF fwptr
    -> WINDOW0x: render into a window someone else owns. We take its
    -> IDCMP over (the owner must stop reading it - the Ed lesson:
    -> two tasks on one UserPort kill the input chain) and hand it
    -> back untouched on close.
    win := fwptr
    fwin := TRUE
    oldidcmp := win.idcmpflags
    ModifyIDCMP(win, idc)
  ELSE
    IF pww < 160 THEN pww := 160
    IF pwh < 60 THEN pwh := 60
    -> the fallback is a failure state now - say so where a
    -> screenshot shows it (chain-on and fallback windows behave
    -> identically until Ed's menus are tried)
    IF ihon = FALSE THEN StrAdd(wtitlebase, ' [no chain]')
    win := OpenWindowTagList(NIL,
      [WA_TITLE, wtitlebase, WA_LEFT, pwx, WA_TOP, pwy,
       WA_WIDTH, pww, WA_HEIGHT, pwh,
       WA_DRAGBAR, TRUE, WA_DEPTHGADGET, TRUE,
       WA_ACTIVATE, TRUE,
       WA_CLOSEGADGET, closegad,
       WA_IDCMP, idc,
       TAG_DONE, NIL])
  ENDIF
  IF win = NIL THEN RETURN
  rp := win.rport
  IF fwin = FALSE
    -> topaz 8: a ROM font - OpenFont sends no packets, OpenDiskFont
    -> would not be safe. A BORROWED window keeps the font its owner
    -> set on the rastport (CTerm's frame carries MicroKnight).
    NEW ta
    ta.name := 'topaz.font'
    ta.ysize := 8
    ta.style := 0
    ta.flags := 0
    tf := OpenFont(ta)
    IF tf THEN SetFont(rp, tf)
  ENDIF
  cw := rp.txwidth
  ch := rp.txheight
  baseline := rp.txbaseline
  -> a borrowed window is sized to an exact grid by its owner: no
  -> margin inset there, or the columns drift off the owner's art
  i := MARGIN
  IF fwin THEN i := 0
  left := win.borderleft + i
  topy := win.bordertop + i
  cols := Div(win.width - win.borderleft - win.borderright - i - i, cw)
  rows := Div(win.height - win.bordertop - win.borderbottom - i - i, ch)
  IF cols > 255 THEN cols := 255      -> redraw's row buffer is 256
  -> the scrollback ring + its attr plane: sized to the real grid
  -> width. New() zeroes (E heap is cleared), so the model starts as
  -> blank rows with attr 0; a failed allocation just disables
  -> scrollback, the console still runs
  sb := New(Mul(SBMAX, cols))
  sa := New(Mul(SBMAX, cols))
  IF (sb = NIL) OR (sa = NIL)
    IF sb THEN Dispose(sb)
    IF sa THEN Dispose(sa)
    sb := NIL
    sa := NIL
  ENDIF
  sbtop := 0
  sbcnt := 0
  viewoff := 0
  -> SGR ground state; bright pens exist when the screen is deep
  -> enough (rp.bitmap is the screen's for a normal window)
  can16 := FALSE
  IF rp.bitmap
    IF rp.bitmap.depth >= 4 THEN can16 := TRUE
  ENDIF
  curfg := deffg
  curbg := 0
  bold := FALSE
  SetAPen(rp, deffg)
  SetBPen(rp, 0)
  IF histdone = FALSE           -> the history survives window
    FOR i := 0 TO HISTMAX - 1   -> close/reopen; allocate once
      hist[i] := String(LINEMAX)
    ENDFOR
    histdone := TRUE
  ENDIF
  -> a fresh console: every per-window state starts over
  cx := 0
  cy := 0
  ancx := 0
  ancy := 0
  inqh := 0
  inqt := 0
  cesc := 0
  eofpend := FALSE
  rawmode := FALSE
  evmask := 0
  tcactive := FALSE
  tcsel := -1
  cpos := 0
  hpos := -1
  StrCopy(ebuf, '')
  drawedit()                    -> the blip stands from the start
  setidcmp()                    -> selection's MOUSEBUTTONS joins the
  ReportMouse(TRUE, win)        -> set (evmask is 0 here) and motion
                                -> events exist when a drag asks
  -> armed last: the chain handler takes nothing until the per-window
  -> state above is fully rebuilt
  ihwin := win
ENDPROC

-> real close semantics (M5c): pending reads answer EOF, pending
-> WAIT_CHARs answer FALSE, the model is returned to the heap, and a
-> borrowed window goes back to its owner with its IDCMP restored
PROC closewin()
  IF win = NIL THEN RETURN
  ihwin := NIL                  -> disarm the chain handler FIRST; then
  ihtail := ihhead              -> discard whatever it already captured
  cursx := -1                   -> the window takes the cursor with it
  selon := FALSE                -> a drag dies with the window; parked
  sello := -1                   -> writers MUST be replied or their
  selhi := -1                   -> tasks hang forever
  flushwq()
  canceltimer()
  WHILE wcn > 0
    wcn--
    ReplyPkt(wcq[wcn], DOSFALSE, 0)
  ENDWHILE
  WHILE rdn > 0
    rdn--
    ReplyPkt(rdq[rdn], 0, 0)
  ENDWHILE
  tcactive := FALSE
  tcsel := -1
  IF fwin
    ReportMouse(FALSE, win)     -> hand the flag back the way the
    ModifyIDCMP(win, oldidcmp)  -> owner had it
  ELSE
    CloseWindow(win)
  ENDIF
  win := NIL
  rp := NIL
  fwin := FALSE
  IF tf
    CloseFont(tf)
    tf := NIL
  ENDIF
  IF sb
    Dispose(sb)
    sb := NIL
  ENDIF
  IF sa
    Dispose(sa)
    sa := NIL
  ENDIF
  eofpend := FALSE
  rawmode := FALSE
  evmask := 0
ENDPROC

-> the close gadget: EOF to the reader (stock CON: CLOSE semantics);
-> a lingering WAIT window (no opens left) dies on the click. The
-> actual CloseWindow is deferred past the event drain (closereq).
PROC doclosew()
  IF opens <= 0
    closereq := TRUE
  ELSE
    eofpend := TRUE
    satisfyreads()
  ENDIF
ENDPROC

-> ---------- the scrollback model (M5) ----------

-> pointer to the model row of visible screen row r (0 = top row).
-> Callers guard with IF sb - a NIL model means scrollback is off.
PROC visrow(r)
  DEF i
  i := sbtop + r
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC sb + Mul(i, cols)

-> the attr-plane twin of visrow
PROC sarow(r)
  DEF i
  i := sbtop + r
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC sa + Mul(i, cols)

-> the pen SGR state draws with right now: bold lifts the 8 base
-> colours to the bright half when the screen has 16 pens
PROC fgpen()
  IF can16 AND bold AND (curfg < 8) THEN RETURN curfg + 8
ENDPROC curfg

PROC curattr() IS fgpen() OR Shl(curbg, 4)

PROC clearrow(r)
  DEF i, m:PTR TO CHAR, a:PTR TO CHAR
  m := visrow(r)
  a := sarow(r)
  FOR i := 0 TO cols - 1
    m[i] := 0
    a[i] := 0
  ENDFOR
ENDPROC

-> paint one MODEL ring row (by ring index) at pixel row y, in
-> attr-batched runs - the piece redraw, drawmodelrow and the menu
-> restore share, and where the colours come back from
PROC drawmrow(idx, y)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, i, j, at, c,
      rowbuf[256]:ARRAY OF CHAR
  m := sb + Mul(idx, cols)
  a := sa + Mul(idx, cols)
  FOR i := 0 TO cols - 1
    c := m[i]
    rowbuf[i] := IF c < 32 THEN 32 ELSE c
  ENDFOR
  i := 0
  WHILE i < cols
    at := a[i]
    j := i
    WHILE (j < cols) AND (a[j] = at)
      j++
    ENDWHILE
    SetAPen(rp, at AND 15)
    SetBPen(rp, Shr(at, 4) AND 7)
    Move(rp, left + Mul(i, cw), y + baseline)
    Text(rp, rowbuf + i, j - i)
    i := j
  ENDWHILE
ENDPROC

-> the raw-mode block cursor: stock console.device always shows a
-> filled cell at the cursor, and Ed draws no marker of its own -
-> it relies on the console's. Cooked mode has the blip instead.
-> The block is the cell from the model in inverse video; an empty
-> cell (attr 0, fg=bg) gets deffg so the block is never invisible.
-> Discipline: curserase() before anything repaints or scrolls the
-> grid, cursdraw() after - the write path wraps render() with the
-> pair, so interior ScrollRasters never smear a painted cursor.
PROC cursdraw()
  DEF m:PTR TO CHAR, a:PTR TO CHAR, x, c, at, fg, bg,
      b[2]:ARRAY OF CHAR
  IF (win = NIL) OR (sb = NIL) OR (viewoff > 0) THEN RETURN
  x := IF cx >= cols THEN cols - 1 ELSE cx
  m := visrow(cy)
  a := sarow(cy)
  c := m[x]
  b[0] := IF c < 32 THEN 32 ELSE c
  at := a[x]
  fg := at AND 15
  bg := Shr(at, 4) AND 7
  IF fg = bg THEN fg := deffg
  SetAPen(rp, bg)               -> inverse video: glyph in the cell's
  SetBPen(rp, fg)               -> background, block in its foreground
  Move(rp, left + Mul(x, cw), topy + Mul(cy, ch) + baseline)
  Text(rp, b, 1)
  cursx := x
  cursy := cy
ENDPROC

PROC curserase()
  DEF m:PTR TO CHAR, a:PTR TO CHAR, c, at, b[2]:ARRAY OF CHAR
  IF cursx < 0 THEN RETURN
  IF win AND sb
    m := visrow(cursy)
    a := sarow(cursy)
    c := m[cursx]
    b[0] := IF c < 32 THEN 32 ELSE c
    at := a[cursx]
    SetAPen(rp, at AND 15)      -> the cell exactly as drawmrow paints
    SetBPen(rp, Shr(at, 4) AND 7)
    Move(rp, left + Mul(cursx, cw), topy + Mul(cursy, ch) + baseline)
    Text(rp, b, 1)
  ENDIF
  cursx := -1
ENDPROC

-> ---------- copy & paste (M7) ----------
-> Drag-select with the left button: the M6 chain hands us button and
-> motion events (positions read live from the window, the pattern
-> Ed's own class-2 handler uses), cells highlight in inverse video,
-> and RELEASE copies the marked text to clipboard.device unit 0 as
-> IFF FTXT - the format the stock console family shares, so a CCON
-> copy pastes into a stock CON: shell and the other way around.
-> While the button is down, ACTION_WRITEs are parked unreplied -
-> output freezes under a drag exactly like the stock console - and
-> flushed on release. RAMIGA-V reads unit 0 and injects the text as
-> typed input: through the line editor when cooked (LF becomes
-> Return), straight to the client's queue when raw (pasting into Ed).
-> Selection rides IDCMP (setidcmp - the 0.14 telemetry boot proved
-> Intuition passes only button DOWNS below it, so the chain cannot
-> carry a drag), and therefore works in the fallback too; paste
-> needs the chain's keymap path (ihon).

-> model ring index of view row r, at the viewoff the selection holds
PROC selvidx(r)
  DEF i
  i := sbtop - selvo + r
  IF i < 0 THEN i := i + SBMAX
  IF i >= SBMAX THEN i := i - SBMAX
ENDPROC i

-> the mouse position as a linear cell (row*cols+x); -1 = off-grid
PROC cellat()
  DEF mx, my, x, r
  IF win = NIL THEN RETURN -1
  mx := win.mousex - left
  my := win.mousey - topy
  IF (mx < 0) OR (my < 0) THEN RETURN -1
  x := mx / cw                  -> cell metrics are single digits -
  r := my / ch                  -> DIVU-safe
  IF (x >= cols) OR (r >= rows) THEN RETURN -1
ENDPROC Mul(r, cols) + x

-> paint one view row like drawmrow, but cells inside [lo,hi) draw
-> inverse video (fg=bg empties get deffg, the block-cursor rule)
PROC drawselrow(r, lo, hi)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, i, j, at, c, s, fg, bg, base, y,
      rowbuf[256]:ARRAY OF CHAR
  m := sb + Mul(selvidx(r), cols)
  a := sa + Mul(selvidx(r), cols)
  y := topy + Mul(r, ch)
  base := Mul(r, cols)
  FOR i := 0 TO cols - 1
    c := m[i]
    rowbuf[i] := IF c < 32 THEN 32 ELSE c
  ENDFOR
  i := 0
  WHILE i < cols
    at := a[i]
    s := ((base + i) >= lo) AND ((base + i) < hi)
    j := i
    WHILE (j < cols) AND (a[j] = at) AND
          ((((base + j) >= lo) AND ((base + j) < hi)) = s)
      j++
    ENDWHILE
    fg := at AND 15
    bg := Shr(at, 4) AND 7
    IF s
      IF fg = bg THEN fg := deffg
      SetAPen(rp, bg)
      SetBPen(rp, fg)
    ELSE
      SetAPen(rp, fg)
      SetBPen(rp, bg)
    ENDIF
    Move(rp, left + Mul(i, cw), y + baseline)
    Text(rp, rowbuf + i, j - i)
    i := j
  ENDWHILE
ENDPROC

-> repaint view rows rmin..rmax against selection [lo,hi)
PROC selrepaint(rmin, rmax, lo, hi)
  DEF r
  IF sb = NIL THEN RETURN
  curserase()
  IF rmin < 0 THEN rmin := 0
  IF rmax > (rows - 1) THEN rmax := rows - 1
  FOR r := rmin TO rmax
    drawselrow(r, lo, hi)
  ENDFOR
  IF rawmode THEN cursdraw()
ENDPROC

-> drop the standing highlight (any output, any key, a fresh click)
PROC clearsel()
  DEF lo
  IF sello >= 0
    lo := sello
    sello := -1
    IF viewoff = selvo THEN selrepaint(lo / cols, (selhi - 1) / cols, 0, 0)
    selhi := -1                 -> (a scrolled view was repainted by
  ENDIF                         -> redraw already - state only)
ENDPROC

-> recompute the window's IDCMP from state. The rules, each one a
-> paid-for lesson: keys ride the chain when ihon (M6); MENUPICK
-> must stay OUT so menu picks pass downstream as IECLASS_MENULIST
-> (the Ed fix); MOUSEBUTTONS is how selection gets its clicks -
-> Intuition passes only button DOWNS below it, the 0.14 telemetry
-> boot proved it, so drag-select cannot ride the chain - but it
-> must come OUT while a client holds CSI 2{ (Ed's mouse reports
-> need the events downstream, the MENUPICK lesson again);
-> MOUSEMOVE is in only mid-drag, so no motion flood otherwise.
PROC setidcmp()
  DEF idc
  IF win = NIL THEN RETURN
  idc := IDCMP_CLOSEWINDOW
  IF ihon = FALSE
    idc := idc OR IDCMP_RAWKEY OR IDCMP_VANILLAKEY OR IDCMP_MENUPICK
  ENDIF
  IF (evmask AND Shl(1, IECLASS_RAWMOUSE)) = 0
    idc := idc OR IDCMP_MOUSEBUTTONS
    IF selon THEN idc := idc OR IDCMP_MOUSEMOVE
  ENDIF
  ModifyIDCMP(win, idc)
ENDPROC

-> the selection machine: one IDCMP mouse message (cd = the code:
-> SELECTDOWN $68, SELECTUP $E8, or $FF for a MOUSEMOVE). Positions
-> come from the window NOW, not the message - coarse under a fast
-> drag, and exactly what Ed's own class-2 handler does.
PROC selmouse(cd)
  DEF c, lo, hi, plo, phi
  IF sb = NIL THEN RETURN       -> no model, no selection
  IF cd = IECODE_LBUTTON
    clearsel()
    IF (rawmode = FALSE) AND tcactive THEN tcclose()
    c := cellat()
    IF c >= 0
      selon := TRUE
      selvo := viewoff
      selanc := c
      selcur := c
      setidcmp()                -> motion reports on for the drag
    ENDIF
  ELSEIF cd = (IECODE_LBUTTON OR IECODE_UP_PREFIX)
    IF selon
      selon := FALSE
      setidcmp()                -> and off again
      IF selcur <> selanc
        sello := Min(selanc, selcur)
        selhi := Max(selanc, selcur) + 1
        selcopy()               -> release = copy, no extra keystroke
      ELSE
        selrepaint(selanc / cols, selanc / cols, 0, 0)
      ENDIF
      flushwq()                 -> the parked writers resume
    ENDIF
  ELSEIF cd = IECODE_NOBUTTON
    IF selon
      c := cellat()
      IF (c >= 0) AND (c <> selcur)
        plo := Min(selanc, selcur)
        phi := Max(selanc, selcur)
        selcur := c
        lo := Min(selanc, selcur)
        hi := Max(selanc, selcur)
        selrepaint(Min(lo, plo) / cols, Max(hi, phi) / cols, lo, hi + 1)
      ENDIF
    ENDIF
  ENDIF
ENDPROC

-> clipboard.device is IO-request-only - no DOS packets, so it is
-> handler-safe the same way timer.device is. Opened lazily on the
-> first copy or paste, then kept.
PROC clipopen()
  IF clipreq THEN RETURN TRUE
  IF clipport = NIL THEN clipport := CreateMsgPort()
  IF clipport = NIL THEN RETURN FALSE
  clipreq := CreateIORequest(clipport, SIZEOF ioclipreq)
  IF clipreq = NIL THEN RETURN FALSE
  IF OpenDevice('clipboard.device', PRIMARY_CLIP, clipreq, 0) <> 0
    DeleteIORequest(clipreq)
    clipreq := NIL
    RETURN FALSE
  ENDIF
  IF clipbuf = NIL THEN clipbuf := New(CLIPMAX)
  IF clipbuf = NIL THEN RETURN FALSE
ENDPROC TRUE

-> the marked cells as text: model rows joined with LF, trailing
-> blanks trimmed per row - wrapped in IFF FORM FTXT / CHRS, written
-> to unit 0 (CMD_WRITE the whole form, CMD_UPDATE commits)
PROC selcopy()
  DEF p:PTR TO CHAR, lw:PTR TO LONG, len, r, base, x0, x1, x, c,
      m:PTR TO CHAR, r0, r1, pad
  IF sb = NIL THEN RETURN
  IF clipopen() = FALSE THEN RETURN
  p := clipbuf + 20             -> text starts after the IFF headers
  len := 0
  r0 := sello / cols
  r1 := (selhi - 1) / cols
  FOR r := r0 TO r1
    base := Mul(r, cols)
    x0 := Max(sello - base, 0)
    x1 := Min(selhi - base, cols)
    m := sb + Mul(selvidx(r), cols)
    WHILE (x1 > x0) AND (m[x1 - 1] < 33)
      x1--                      -> trailing blanks go
    ENDWHILE
    FOR x := x0 TO x1 - 1
      c := m[x]
      IF len < (CLIPMAX - 64)
        p[len] := IF c < 32 THEN 32 ELSE c
        len++
      ENDIF
    ENDFOR
    IF r < r1
      p[len] := 10              -> LF between rows, the FTXT way
      len++
    ENDIF
  ENDFOR
  IF len = 0 THEN RETURN
  pad := len AND 1
  lw := clipbuf
  lw[0] := $464F524D            -> 'FORM'
  lw[1] := 12 + len + pad       -> FTXT + CHRS header + text
  lw[2] := $46545854            -> 'FTXT'
  lw[3] := $43485253            -> 'CHRS'
  lw[4] := len
  IF pad THEN p[len] := 0
  clipreq.command := CMD_WRITE
  clipreq.data := clipbuf
  clipreq.length := 20 + len + pad
  clipreq.offset := 0
  clipreq.clipid := 0
  DoIO(clipreq)
  IF clipreq.error = 0
    clipreq.command := CMD_UPDATE
    DoIO(clipreq)
  ENDIF
ENDPROC

-> RAMIGA-V: read unit 0, dig the CHRS text out of the FTXT form,
-> inject it as typed input. Cooked runs every byte through the line
-> editor (LF becomes Return, so a pasted command line executes like
-> a typed one); raw hands the client the bytes as they are.
PROC dopaste()
  DEF got, i, id, sz, take, c, scr[32]:ARRAY OF CHAR,
      lw:PTR TO LONG, b:PTR TO CHAR
  IF selon THEN RETURN
  IF clipopen() = FALSE THEN RETURN
  clipreq.command := CMD_READ
  clipreq.data := clipbuf
  clipreq.length := CLIPMAX
  clipreq.offset := 0
  clipreq.clipid := 0
  DoIO(clipreq)
  got := IF clipreq.error = 0 THEN clipreq.actual ELSE 0
  REPEAT                        -> the read cycle must run dry to
    clipreq.command := CMD_READ -> release the clip, clipbook rule
    clipreq.data := scr
    clipreq.length := 32
    DoIO(clipreq)
  UNTIL (clipreq.actual <= 0) OR (clipreq.error <> 0)
  IF got < 20 THEN RETURN
  lw := clipbuf
  IF (lw[0] <> $464F524D) OR (lw[2] <> $46545854) THEN RETURN
  i := 12
  WHILE (i + 8) <= got
    lw := clipbuf + i
    id := lw[0]
    sz := lw[1]
    IF id = $43485253           -> CHRS: inject its text
      b := clipbuf + i + 8
      take := Min(sz, got - i - 8)
      FOR c := 0 TO take - 1
        injectbyte(b[c])
      ENDFOR
    ENDIF
    i := i + 8 + sz + (sz AND 1)
  ENDWHILE
  IF rawmode THEN inputarrived()
ENDPROC

PROC injectbyte(c)
  IF rawmode
    enqueue(c)                  -> the client sees paste as input
  ELSE
    IF c = 10 THEN c := 13      -> LF = Return to the line editor
    dovanilla(c, 0)
  ENDIF
ENDPROC

-> redraw the whole grid from the model at the current view offset;
-> model zeroes render as spaces. viewoff = lines back, 0 = live.
PROC redraw()
  DEF r, idx
  IF sb = NIL THEN RETURN
  FOR r := 0 TO rows - 1
    idx := sbtop - viewoff + r
    IF idx < 0 THEN idx := idx + SBMAX
    IF idx >= SBMAX THEN idx := idx - SBMAX
    drawmrow(idx, topy + Mul(r, ch))
  ENDFOR
  SetAPen(rp, deffg)
  SetBPen(rp, 0)
ENDPROC

-> the title bar doubles as the scroll-position indicator. The buffer
-> is a global: Intuition keeps the POINTER (the M4 telemetry lesson).
-> Known cosmetic gap: leaving scrollback restores our own title, so a
-> client retitle (More does one via DISK_INFO) is overwritten.
PROC settitle()
  IF fwin THEN RETURN   -> a borrowed window keeps its owner's title
  IF viewoff > 0
    StringF(wtitle, '\s  [scrollback -\d]', wtitlebase, viewoff)
    SetWindowTitles(win, wtitle, -1)
  ELSE
    SetWindowTitles(win, wtitlebase, -1)
  ENDIF
ENDPROC

-> scroll the view by delta lines (positive = back in time), clamped
-> to the history actually stored; landing on live restores the blip
PROC scrollview(delta)
  IF sb = NIL THEN RETURN
  viewoff := viewoff + delta
  IF viewoff > sbcnt THEN viewoff := sbcnt
  IF viewoff < 0 THEN viewoff := 0
  redraw()                      -> the grid repaint wiped any block
  cursx := -1                   -> cursor pixels with it
  settitle()
  IF viewoff = 0
    IF rawmode THEN cursdraw() ELSE drawedit()
  ENDIF
ENDPROC

-> any output or any non-scroll key returns the view to live
PROC snaplive()
  IF viewoff = 0 THEN RETURN
  viewoff := 0
  redraw()
  cursx := -1
  settitle()
  IF rawmode THEN cursdraw() ELSE drawedit()
ENDPROC

-> ---------- output: a cell-grid renderer (CSI parsing comes with the
-> full CTerm renderer transplant in a later milestone) ----------

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
    clearrow(rows - 1)
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
  SetAPen(rp, fgpen())
  SetBPen(rp, curbg)
  Move(rp, left + Mul(cx, cw), topy + Mul(cy, ch) + baseline)
  Text(rp, b, 1)
  IF sb
    m := visrow(cy)
    m[cx] := c
    m := sarow(cy)
    m[cx] := curattr()
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
  DEF n, i, v
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
  ELSEIF c = "m"
    -> SGR (M5d): reset, bold (bright pens on a 16-pen screen),
    -> 30-37 fg, 39 default fg, 40-47 bg, 49 default bg
    FOR i := 0 TO cnp
      v := cpar[i]
      IF v = 0
        curfg := deffg
        curbg := 0
        bold := FALSE
      ELSEIF v = 1
        bold := TRUE
      ELSEIF v = 22
        bold := FALSE
      ELSEIF (v >= 30) AND (v <= 37)
        curfg := v - 30
        -> WBPENS (see parsecon): plain 30-33 are WB pen numbers
        -> from programs like Ed, not ANSI colours - retarget them
        -> at the theme. Bold forms keep ANSI positions (fgpen()
        -> lifts to the bright half before this map could matter).
        IF wbpens AND can16 AND (bold = FALSE) AND (v <= 33)
          IF v = 30
            curfg := 0
          ELSEIF v = 31
            curfg := deffg
          ELSEIF v = 32
            curfg := 15
          ELSE
            curfg := 12
          ENDIF
        ENDIF
      ELSEIF v = 39
        curfg := deffg
      ELSEIF (v >= 40) AND (v <= 47)
        curbg := v - 40
      ELSEIF v = 49
        curbg := 0
      ENDIF
    ENDFOR
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
    setidcmp()                  -> CSI 2{ pulls MOUSEBUTTONS out of
                                -> IDCMP: the client's class-2
                                -> reports need the events to pass
                                -> downstream (the MENUPICK lesson)
  ELSEIF c = "}"
    -> RESET RAW EVENTS
    FOR i := 0 TO cnp
      IF (cpar[i] >= 0) AND (cpar[i] <= 31)
        evmask := evmask - (evmask AND Shl(1, cpar[i]))
      ENDIF
    ENDFOR
    setidcmp()
  ENDIF
ENDPROC

-> Menu picks, resolved (18.7.26) by doing what the old freeze log
-> demanded: disassembling Ed's own parser instead of guessing a
-> fifth time. C:Ed (3.2, 24396 bytes): at startup it sends four
-> single-param SREs - CSI 12{ 2{ 10{ 11{ - and its report
-> dispatcher (code $1708) switches on param 0 of a parsed
-> CSI class;subclass;code;qualifier;ah;al;secs;mics| report.
-> For class 10 it reads ONLY the code field: ItemAddress(strip,
-> code), runs the Ed command hung off the MenuItem's +$22
-> extension, then follows item.NextSelect ($20) until MENUNULL.
-> The address halves that cost four freezes of guessing are never
-> read for menus (class 2 uses them not at all either - it divides
-> MouseX/Y by the rastport font cell to get Ed's mouse cell).
-> So the route is the stock-CON: one: no IDCMP_MENUPICK on the
-> window (openwin), Intuition sends the pick downstream as
-> IECLASS_MENULIST, ihchain captures it under Ed's CSI 10{ mask,
-> ihreport emits the V47 report, Ed walks the strip. This proc is
-> only reachable in the ihon=FALSE fallback, where MENUPICK is
-> still in the IDCMP set and picks stay deliberately swallowed -
-> the boot-proven 0.8 shape.
PROC domenupick(code, qual, ia, secs, mics)
ENDPROC

PROC erasebelow()
  DEF r
  eraseeol()
  IF cy < (rows - 1)
    SetAPen(rp, 0)
    RectFill(rp, left, topy + Mul(cy + 1, ch),
             left + Mul(cols, cw) - 1, topy + Mul(rows, ch) - 1)
    SetAPen(rp, deffg)
    IF sb
      FOR r := cy + 1 TO rows - 1
        clearrow(r)
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
      CopyMem(sarow(r - n), sarow(r), cols)
    ENDFOR
    FOR r := cy TO cy + n - 1
      clearrow(r)
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
      CopyMem(sarow(r + n), sarow(r), cols)
    ENDFOR
    FOR r := rows - n TO rows - 1
      clearrow(r)
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
  DEF y, m:PTR TO CHAR, a:PTR TO CHAR, j
  IF cx >= cols THEN RETURN   -> inverted RectFill = wild writes
  y := topy + Mul(cy, ch)
  SetAPen(rp, 0)
  RectFill(rp, left + Mul(cx, cw), y, left + Mul(cols, cw) - 1, y + ch - 1)
  SetAPen(rp, deffg)
  IF sb
    m := visrow(cy)
    a := sarow(cy)
    FOR j := cx TO cols - 1
      m[j] := 0
      a[j] := 0
    ENDFOR
  ENDIF
ENDPROC

-> the 0.1 CTerm renderer's CSI discipline, transplanted and grown
-> up: consume sequences WHOLE (state survives split writes via
-> cesc/cpar/cnp), dispatch the full-screen set (csidispatch), drop
-> the rest silently.
PROC render(buf, len)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit, m:PTR TO CHAR, j2
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
        SetAPen(rp, fgpen())
        SetBPen(rp, curbg)
        Move(rp, left + Mul(cx, cw), topy + Mul(cy, ch) + baseline)
        Text(rp, s + i, fit)
        IF sb
          CopyMem(s + i, visrow(cy) + cx, fit)
          m := sarow(cy) + cx
          FOR j2 := 0 TO fit - 1
            m[j2] := curattr()
          ENDFOR
        ENDIF
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

-> the edit line WRAPS (stock shell behaviour): it may span several
-> rows below the anchor, and growing past the bottom row scrolls
-> the whole screen up, prompt and all - the anchor tracks it.

-> the most chars the line can hold: LINEMAX, or every cell from
-> the anchor to the bottom-right corner minus one for the blip
PROC edcap() IS Min(LINEMAX - 1, Mul(rows, cols) - ancx - 1)

-> the last row a line of n chars (plus its blip cell) touches
PROC edlastrow(n) IS ancy + ((ancx + n) / cols)

-> scroll until that fits on screen (the dotab menu loop's pattern)
PROC edroom(n)
  WHILE (edlastrow(n) > (rows - 1)) AND (ancy > 0)
    screenscroll()
    IF cy > 0 THEN cy--
  ENDWHILE
ENDPROC

PROC eraseedit()
  DEF y, r, r1, x0
  IF win = NIL THEN RETURN
  IF ancx >= cols THEN RETURN -> inverted RectFill = wild writes
  r1 := edlastrow(edlast)
  IF r1 > (rows - 1) THEN r1 := rows - 1
  x0 := ancx
  SetAPen(rp, 0)
  FOR r := ancy TO r1
    y := topy + Mul(r, ch)
    RectFill(rp, left + Mul(x0, cw), y,
             left + Mul(cols, cw) - 1, y + ch - 1)
    x0 := 0                   -> continuation rows clear full width
  ENDFOR
  SetAPen(rp, deffg)
ENDPROC

-> the cell at cpos is drawn inverted - the blip - so the cursor is
-> visible for mid-line editing (transplant of 0.1 redrawinput,
-> grown row-wrapping)
PROC drawedit()
  DEF s:PTR TO CHAR, l, cch[2]:ARRAY OF CHAR, i, n, r, xc, bc
  IF win = NIL THEN RETURN
  l := StrLen(ebuf)
  edroom(l)
  eraseedit()
  s := ebuf
  SetAPen(rp, deffg)
  SetBPen(rp, 0)
  i := 0
  r := ancy
  xc := ancx
  WHILE i < l
    n := Min(cols - xc, l - i)
    Move(rp, left + Mul(xc, cw), topy + Mul(r, ch) + baseline)
    Text(rp, s + i, n)
    i := i + n
    xc := 0
    r := r + 1
  ENDWHILE
  cch[0] := 32
  IF cpos < l THEN cch[0] := s[cpos]
  bc := ancx + cpos
  r := bc / cols
  SetAPen(rp, 0)
  SetBPen(rp, deffg)
  Move(rp, left + Mul(bc - Mul(r, cols), cw),
       topy + Mul(ancy + r, ch) + baseline)
  Text(rp, cch, 1)
  SetAPen(rp, deffg)
  SetBPen(rp, 0)
  edlast := l
ENDPROC

-> put history entry idx (0 = newest) into ebuf, cut to fit
PROC histload(idx)
  StrCopy(ebuf, hist[Mod(htotal - 1 - idx, HISTMAX)])
  WHILE StrLen(ebuf) > edcap()
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
    IF l < edcap()
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
    RETURN FALSE      -> not a special: the caller maps it to bytes
  ENDIF
  inputarrived()
ENDPROC TRUE

-> returns TRUE when the key is fully handled here (M6 uses that to
-> know when to run the keymap instead); the legacy IDCMP path
-> ignores the result - vanilla bytes arrive as their own events there
PROC dorawkey(code, qual)
  DEF s:PTR TO CHAR, l, avail, sh
  sh := qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
  -> Tab can arrive as a RAW key when the keymap has no vanilla
  -> mapping for its shifted form: dispatch it to completion too
  IF (code = $42) AND (rawmode = FALSE)
    dotab(sh)
    RETURN TRUE
  ENDIF
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
  IF (code = RK_UP) OR (code = RK_DOWN)
    IF qual AND IEQUALIFIER_CONTROL
      scrollview(IF code = RK_UP THEN 1 ELSE -1)
      RETURN TRUE
    ELSEIF (sh <> 0) AND (rawmode = FALSE)
      scrollview(IF code = RK_UP THEN rows - 1 ELSE -(rows - 1))
      RETURN TRUE
    ENDIF
  ENDIF
  snaplive()                    -> any other key returns the view to live
  IF rawmode
    RETURN rawcsikey(code, qual)
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
  -> arrows are consumed here even as no-ops: their keymap image is a
  -> CSI string, never cooked input
ENDPROC (code = RK_UP) OR (code = RK_DOWN) OR (code = RK_LEFT) OR (code = RK_RIGHT)

-> ---------- input.device-handler input (M6) ----------
-> Keys are taken from the input.device chain, where console.device
-> takes its own: an Interrupt added with IND_ADDHANDLER at priority
-> IHPRI - below Intuition (50), so menu operations arrive already
-> digested into IECLASS_MENULIST events, above console.device (0).
-> The window's UserPort is left idle for clients like Ed to
-> commandeer with ModifyIDCMP/GetMsg - the stock-CON: architecture
-> that ended the Ed-menus freezes.

-> gluestub is the interrupt's is_Code. input.device JSRs it with
-> A0 = the event chain and A1 = is_Data (ihgd). An E proc reaches
-> its globals through A4 (E-VO frames them with LINK A4 in the
-> startup), so the stub restores the A4 captured at startup, saves
-> the registers E procs clobber freely, and calls ihchain with the
-> chain as its one stack argument (E-VO convention: caller pushes,
-> caller cleans, result in D0). All of that - including "a proc
-> with no arguments and no locals gets NO prologue, the MOVEM
-> really is the first instruction" - was read out of the generated
-> code with the machine68k disassembler, not assumed.
PROC gluestub()
  MOVEM.L D2-D7/A2-A6,-(A7)
  MOVE.L  A1,A3
  MOVE.L  (A3),A4
  MOVE.L  A0,-(A7)
  MOVE.L  4(A3),A0
  JSR     (A0)
  ADDQ.L  #4,A7
  MOVEM.L (A7)+,D2-D7/A2-A6
  RTS
ENDPROC

-> Runs inside input.device's task on input.device's stack. Rules of
-> this context: no waiting, no allocating, no library calls except
-> the one Signal - copy, neutralize, get out. Events for our window
-> while it is the active one are copied into the ring and turned
-> into IECLASS_NULL; everything else passes through untouched.
-> ihwin is the arming switch: the main task sets it only while a
-> fully initialized window exists.
PROC ihchain(list:PTR TO inputevent)
  DEF ev:PTR TO inputevent, ib:PTR TO intuitionbase, e:PTR TO ihev,
      take, got, c
  got := FALSE
  IF ihwin
    ib := intuitionbase
    IF ib.activewindow = ihwin
      ev := list
      WHILE ev
        c := ev.class
        take := FALSE
        -> mouse events are NOT taken for selection here: the 0.14
        -> telemetry boot proved Intuition passes only the button
        -> DOWNS this far - select-up and motion never reach pri 20.
        -> Selection rides IDCMP instead (setidcmp), like KingCON.
        IF c = IECLASS_RAWKEY
          take := TRUE
        ELSEIF (c > IECLASS_RAWKEY) AND (c <= IECLASS_MAX)
          IF evmask AND Shl(1, c) THEN take := TRUE
        ENDIF
        IF take
          IF (ihhead - ihtail) < IHMAX
            e := ihring + Shl(ihhead AND (IHMAX - 1), 5)
            e.cls := c
            e.sub := ev.subclass
            e.code := ev.code
            e.qual := ev.qualifier
            e.addr := ev.eventaddress
            e.secs := ev.timestamp.secs
            e.mics := ev.timestamp.micro
            ihhead := ihhead + 1
            got := TRUE
          ELSE
            ihdrop := ihdrop + 1
          ENDIF
          ev.class := IECLASS_NULL
        ENDIF
        ev := ev.nextevent
      ENDWHILE
    ENDIF
  ENDIF
  IF got THEN Signal(ihtask, ihsig)
ENDPROC list

-> main-task side: drain the ring. RAWKEY becomes editor/queue input
-> through the same procs the IDCMP path used; every other captured
-> class was requested via CSI n{ and becomes a raw event report.
PROC ihdrain()
  DEF e:PTR TO ihev
  WHILE ihtail <> ihhead
    e := ihring + Shl(ihtail AND (IHMAX - 1), 5)
    IF win                      -> late events after closewin: dropped
      IF e.cls = IECLASS_RAWKEY
        IF evmask AND Shl(1, IECLASS_RAWKEY)
          ihreport(e)           -> class 1 requested as reports: the
        ELSE                    -> client owns the keys raw
          ihkey(e)
        ENDIF
      ELSE
        ihreport(e)             -> every other class only enters the
      ENDIF                     -> ring under the client's CSI n{ mask
    ENDIF
    ihtail := ihtail + 1
  ENDWHILE
ENDPROC

-> one key event: the raw specials first (same dispatch the IDCMP
-> path used), then the keymap for everything it declined. Releases
-> are dropped whole - nothing here ever used them, and letting them
-> through would snap the scrollback view on every key-up.
PROC ihkey(e:PTR TO ihev)
  DEF cd, q, n, i
  cd := e.code AND $FFFF
  q := e.qual AND $FFFF
  IF cd AND IECODE_UP_PREFIX THEN RETURN
  IF (cd >= $68) AND (cd <= $7F) THEN RETURN  -> buttons, comm codes
  IF cd < $60 THEN clearsel()   -> any real key drops the highlight
                                -> (bare qualifiers keep it)
  IF (selon = FALSE) AND (wqn > 0) THEN flushwq()
                                -> belt: a lost button-up (ring
                                -> overflow) must not park writers
                                -> forever
  IF q AND IEQUALIFIER_RCOMMAND
    -> RAMIGA-V pastes (M7). Other RAMIGA combos fall through
    -> unchanged.
    n := ihmaprawkey(e)
    IF n = 1
      IF (ihmap[0] = "v") OR (ihmap[0] = "V")
        dopaste()
        RETURN
      ENDIF
      IF (ihmap[0] = "c") OR (ihmap[0] = "C")
        -> RAMIGA-C re-copies the standing highlight - release
        -> already copied, but the stock muscle memory is free
        IF sello >= 0 THEN selcopy()
        RETURN
      ENDIF
    ENDIF
  ENDIF
  IF dorawkey(cd, q) THEN RETURN
  n := ihmaprawkey(e)
  IF rawmode
    -> raw: the mapped bytes go to the client as they are - this is
    -> where letters, Return=CR, Ctrl+C=3 and multi-byte F-key
    -> strings come from now
    IF n > 0
      FOR i := 0 TO n - 1
        enqueue(ihmap[i])
      ENDFOR
      inputarrived()
    ENDIF
  ELSE
    -> cooked: only single-byte images reach the line editor -
    -> Intuition's VANILLAKEY delivered exactly those; multi-byte
    -> images are F-key CSI strings and were never cooked input
    IF n = 1 THEN dovanilla(ihmap[0], q)
  ENDIF
ENDPROC

-> rebuild a real InputEvent for keymap.library (ROM - no packets).
-> addr carries the dead-key prev-down bytes, so Swedish dead-key
-> composition works exactly as it did under Intuition's mapping
PROC ihmaprawkey(e:PTR TO ihev)
  DEF ie:PTR TO inputevent, n
  ie := ihie
  ie.nextevent := NIL
  ie.class := IECLASS_RAWKEY
  ie.subclass := e.sub
  ie.code := e.code
  ie.qualifier := e.qual
  ie.eventaddress := e.addr
  ie.timestamp.secs := e.secs
  ie.timestamp.micro := e.mics
  n := MapRawKey(ie, ihmap, 32, NIL)
  IF n < 0 THEN n := 0          -> overflow: drop, never overrun
ENDPROC n

-> a captured event becomes a raw input event report on the input
-> stream, in the true V47 shape recovered from console.device
-> 46.1's own builder (ROM $13de): CSI class;subclass;code;
-> qualifier;addrhigh;addrlow;secs;micros| - and the address halves
-> now carry Intuition's own ie_EventAddress passed through, not a
-> reconstruction (the old freeze experiments had to guess here;
-> the freezes themselves were the UserPort fight, solved above)
PROC ihreport(e:PTR TO ihev)
  DEF b[64]:STRING, i
  enqueue($9B)
  StringF(b, '\d;\d;\d;\d;\d;\d;\d;\d',
          e.cls, e.sub, e.code AND $FFFF, e.qual AND $FFFF,
          Shr(e.addr, 16) AND $FFFF, e.addr AND $FFFF,
          e.secs AND $7FFFFFFF, e.mics)
  FOR i := 0 TO StrLen(b) - 1
    enqueue(b[i])
  ENDFOR
  enqueue("|")
  inputarrived()
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
          IF tchidname(nbuf, l, fsfib.protection)
            p[0] := p[0] OR 2
          ENDIF
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
  IF newlen > edcap() THEN RETURN FALSE
  IF tcactive
    -> the menu's rows are frozen (tcmrow0): while it is open a
    -> candidate may not grow the line down into it
    IF (ancx + newlen + 1) > Mul(tcmrow0 - ancy, cols) THEN RETURN FALSE
  ENDIF
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
  DEF idx
  IF sb = NIL THEN RETURN
  idx := sbtop + r
  IF idx >= SBMAX THEN idx := idx - SBMAX
  drawmrow(idx, topy + Mul(r, ch))
  SetAPen(rp, deffg)
  SetBPen(rp, 0)
ENDPROC

-> hidden-class: the h protection bit, or a case-blind ".info"
-> suffix with a stem (ls's rule, mirrored)
PROC tchidname(n:PTR TO CHAR, l, prot)
  DEF i
  IF prot AND $80 THEN RETURN TRUE
  IF l < 6 THEN RETURN FALSE
  i := l - 5
  IF n[i] <> "." THEN RETURN FALSE
  IF tcfold(n[i + 1]) <> "I" THEN RETURN FALSE
  IF tcfold(n[i + 2]) <> "N" THEN RETURN FALSE
  IF tcfold(n[i + 3]) <> "F" THEN RETURN FALSE
  IF tcfold(n[i + 4]) <> "O" THEN RETURN FALSE
ENDPROC TRUE

-> menu colours mirror ls: hidden-class grey (grey needs 16 pens),
-> directories blue (bright blue on 16 pens, the classic WB blue
-> pen 3 otherwise), everything else in the default pen
PROC menupen(flag)
  IF flag AND 2 THEN RETURN IF can16 THEN 8 ELSE deffg
  IF flag AND 1 THEN RETURN IF can16 THEN 12 ELSE 3
ENDPROC deffg

PROC tcmenucalc()
  DEF i, l, maxl, p:PTR TO CHAR
  maxl := 1
  FOR i := 0 TO tcn - 1
    p := tcc[i]
    l := StrLen(p + 1) + (p[0] AND 1)  -> dirs show a trailing '/'
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
    IF p[0] AND 1
      nb[l] := "/"
      l++
    ENDIF
    WHILE l < tcmcolw
      nb[l] := 32
      l++
    ENDWHILE
    IF idx = tcsel
      SetAPen(rp, 0)
      SetBPen(rp, deffg)
    ELSE
      SetAPen(rp, menupen(p[0]))
      SetBPen(rp, 0)
    ENDIF
    Move(rp, left + Mul(Mul(c, tcmcolw), cw),
         topy + Mul(tcmrow0 + r, ch) + baseline)
    Text(rp, nb, l)
  ENDFOR
  SetAPen(rp, deffg)
  SetBPen(rp, 0)
ENDPROC

-> close the menu: the rows under it come back from the model
PROC tcclose()
  DEF r
  IF tcactive = FALSE THEN RETURN
  FOR r := 0 TO tcmrows - 1
    drawmodelrow(tcmrow0 + r)
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
    IF p[0] AND 1 THEN StrAdd(tctmp, '/')
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
    StrAdd(tctmp, IF (p[0] AND 1) THEN '/' ELSE ' ')
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
  WHILE ((edlastrow(StrLen(ebuf)) + tcmrows) > (rows - 1)) AND (ancy > 0)
    screenscroll()          -> make room below the (wrapped) edit
    IF cy > 0 THEN cy--     -> line; its pixels scroll along, anchor
  ENDWHILE                  -> and output cursor track it
  tcmrow0 := edlastrow(StrLen(ebuf)) + 1
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

vers: CHAR '$VER: ccon-handler 0.17 (18.7.26) CCON: LTX console handler M7', 0
