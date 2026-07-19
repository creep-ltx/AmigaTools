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
-> M10 step A (0.21): every per-window global lives in the one
-> `console` OBJECT now, reached only through `curcon` - the
-> struct-ification the window-per-open design (todo.md M10) needs
-> first. One console still; behaviour must be identical to 0.20.
->
-> M10 step B (0.22): a window per open. Consoles live on a list;
-> every create-open builds its own (options parse per open - the M9
-> wall comes down), `*`/CONSOLE: opens attach to the sender's
-> console via its CLI StandardInput fh_Args. curcon is set at the
-> dispatch boundaries only: packets by fh_Arg1 or sender, window
-> events by UserPort, chain events by the console tag in the ring
-> slot, timer expiry by timercon. WAIT windows linger but nothing
-> re-attaches: a new open is a new window, the stock CON: way.
->
-> v1.1 Theme A (1.1b1): FONTname/size in the open string (already-
-> LOADED fonts only - OpenFont, never OpenDiskFont, the no-DOS
-> rule), SGR 3/4/7 as real soft styles in a third model plane,
-> LINES=n as the per-console memory knob that pays for it, CSI @/P
-> insert/delete character, and xterm OSC title sequences
-> (ESC]0;title BEL) - which also end the More-retitle stomp:
-> settitle adopts a foreign title as the new base.
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
       'intuition/screens',
       'graphics/view','graphics/gfxbase',
       'utility/tagitem',
       'exec/nodes','exec/ports','exec/io','exec/tasks',
       'exec/interrupts',
       'graphics/text','graphics/rastport','graphics/gfx',
       'devices/inputevent','devices/timer','devices/input',
       'devices/clipboard',
       'dos/dos','dos/dosextens','dos/filehandler','dos/dostags',
       'keymap','diskfont'

CONST MARGIN=4,
      LINEMAX=400,      -> longest editable input line
      HISTMAX=200,      -> shared prompt history ring, entries (v1.1
                        -> Theme B: ONE ring per process now, not per
                        -> window, so this can be generous - 200 *
                        -> LINEMAX is ~80K once, not 32 * N windows)
      INQMAX=2048,      -> input byte queue (finished lines)
      RDMAX=16,         -> pending ACTION_READ packets
      SBMAX=1000,       -> scrollback model, lines - the DEFAULT
                        -> depth (his footprint pass, 19.7.26: 4000
                        -> was the 1.0 hardcode; LINES=n opts UP,
                        -> capped at SBMAXCAP below)
      SBMAXCAP=4000,    -> LINES=n ceiling - no accidental multi-MB
                        -> windows from a typo or a big number
      TCMAX=80,         -> tab completion: max candidates collected
      TCPOOLSZ=4096,    -> tab completion: candidate name pool, bytes
      WQMAX=16,         -> writes parked during a selection drag
      CLIPMAX=16384,    -> clipboard transfer buffer, bytes
      PASTENL=182,      -> Latin-1 pilcrow (P): the visible stand-in
                        -> for an embedded newline while a multi-line
                        -> paste is still being edited - real command
                        -> text essentially never contains one
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
  con:LONG          -> M10b: the console the event was captured for
ENDOBJECT

-> a CLI's command path (cli_CommandDir): a plain BPTR-linked list
-> of these, one per Path entry, unchanged since 1.x - not in any
-> stock E module, cross-checked against amitools' PathStruct
-> (path_Next/path_Lock, two BPTRs, nothing else).
OBJECT pathnode
  next:LONG
  lock:LONG
ENDOBJECT

-> M10 step A: everything per-window lives in ONE console object; the
-> globals this file grew through M1-M9 became these fields, reached
-> only through `curcon` - the current console. For now exactly one is
-> made, at mount time: behaviour must be identical to 0.20. The
-> console LIST, per-open routing and window-per-open semantics are
-> the next steps (todo.md M10). Byte arrays sit at the end so every
-> LONG field keeps its natural alignment.
OBJECT console
  next:LONG                     -> M10b: the console list (singly
                                -> linked; ihchain walks it too, so
                                -> mutations are Forbid-bracketed)
  armed                         -> chain may take keys: set LAST in
                                -> openwin, cleared FIRST in closewin
  -> the window and its text grid
  win:PTR TO window
  rp:PTR TO rastport
  tf:PTR TO textfont
  cw, ch, baseline              -> cell metrics (topaz: fixed)
  left, topy, cols, rows        -> the text grid inside the window
  cx, cy                        -> output cursor, in cells
  cursx, cursy                  -> raw block cursor; -1 = not painted
  -> copy & paste (M7)
  selon                         -> a drag is in progress
  selanc, selcur                -> anchor/current cell, row*cols+x
  sello, selhi                  -> the standing highlight, [lo,hi)
  selvo                         -> viewoff the selection was made at
  wq[16]:ARRAY OF LONG          -> writers parked during a drag
  wqn
  opens                         -> open handles on this console
  -> the line editor (CTerm 0.1 transplant)
  ebuf:PTR TO CHAR              -> the line being typed (E-string)
  stash:PTR TO CHAR             -> half-typed line parked during history
  cpos                          -> cursor inside ebuf
  ancx, ancy                    -> cell where the edit line is drawn
  edlast                        -> chars the last drawedit painted
  edext                         -> cells of the last paint INCLUDING
                                -> blip and ghost (erase extent)
  sghost:PTR TO CHAR            -> fish-style autosuggestion: the
                                -> history entry the typed line
                                -> prefixes (NIL = none); ghost text
                                -> is its tail, drawn grey
  -> Ctrl+R incremental history search (readline)
  srch                          -> search mode is on
  sridx                         -> history index of the match; -1 none
  srbuf:PTR TO CHAR             -> the search fragment (E-string)
  srstash:PTR TO CHAR           -> the line as it was at Ctrl+R
  -> double/triple click (word/line select)
  dcsec, dcmic                  -> time of the last SELECTDOWN
  dccnt                         -> click run length: 1 drag, 2 word,
  dcrow                         -> 3 line; same-row clicks only
  tcmrow0                       -> completion menu's first row, frozen
  hpos                          -> Theme B: the ring itself (ghist/
                                -> ghtotal) is process-shared now;
                                -> only the walk position stays here
  -> cooked input plumbing
  inqh, inqt                    -> head/tail of the inq ring below
  cesc                          -> CSI parser state (survives split
  cpar[4]:ARRAY OF LONG         -> writes; up to 4 parameters)
  cnp
  cpriv                         -> a '?'/'>' rode the params (v1.1b11:
                                -> CSI ?47h/l is More's altscreen)
  rdq[16]:ARRAY OF LONG         -> pending ACTION_READ packets
  rdn
  eofpend
  breaktask                     -> who gets Ctrl+C..F (AROS pattern)
  rawmode                       -> ACTION_SCREEN_MODE: DOSTRUE = raw
  wcq[8]:ARRAY OF LONG          -> pending ACTION_WAIT_CHAR packets
  wcn
  evmask                        -> raw event classes via CSI n{
  -> the scrollback model (M5)
  sb                            -> the ring; NIL = scrollback disabled
  sa                            -> its attr plane: fg/bg nibble per cell
  ss                            -> v1.1: the style plane - bit0 italic,
                                -> bit1 underline, bit2 inverse; third
                                -> byte per cell, what LINES pays for
  sbtop                         -> ring index of the top visible row
  sbcnt                         -> history lines above the screen
  sbmax                         -> v1.1: model lines THIS console keeps
                                -> (LINES=n; default SBMAX)
  viewoff                       -> lines scrolled back; 0 = live
  -> raw-session alternate screen (v1.1b10): More/Ed restore the
  -> transcript on exit instead of leaving their UI in it
  altm, alta, alts              -> saved visible rows, three planes
  altvalid
  altcx, altcy, altancx, altancy
  altsbtop, altsbcnt
  altrows, altcols              -> geometry at snapshot; a resize
                                -> during raw discards the snapshot
  rawscr                        -> rows scrolled away during raw
  -> SGR state (M5d)
  deffg, curfg, curbg, bold, can16
  cursty                        -> v1.1: current soft style bits (see ss)
  softmask                      -> AskSoftStyle: what the font can fake
  cursoft                       -> soft style now set on the rastport
  wbpens                        -> WBPENS: plain 30-33 are WB pens
  cursgr                        -> an explicit 3x is in effect
  anstab[8]:ARRAY OF LONG       -> foreign screens: ObtainBestPen picks
  anscm                         -> the colormap they came from
  -> per-open window spec (M5c/M9), parsed from the open name
  pwx, pwy, pww, pwh
  waitmode, closegad
  fwptr                         -> WINDOW0xADDR: borrow this window
  fwin, oldidcmp                -> borrowed-window bookkeeping
  closereq                      -> close gadget seen; close after drain
  pauto                         -> AUTO: window on first I/O
  autopend                      -> an AUTO open waits, windowless
  pnoborder, pnodrag, pnodepth, pnosize, pbackdrop, pinactive
  pasteexec                     -> Theme B: PASTEEXEC open option -
                                -> the OLD RAMIGA-V behaviour (every
                                -> LF runs its line) for this window
  plines                        -> v1.1 LINES=n parsed (0 = default)
  pfontsize, pfontexp           -> v1.1 FONTname/size parse state (the
                                -> size rides the NEXT '/'-token)
  oscn, oscsk                   -> v1.1 xterm OSC title parser state
  wtitle:PTR TO CHAR            -> title + scroll indicator (E-string;
                                -> persists: Intuition keeps the ptr)
  wtitlebase:PTR TO CHAR        -> the parsed window title (E-string)
  -> tab completion (M5b)
  fsdirport:PTR TO mp           -> resolved: the filesystem's port,
  fsdirlock                     -> the lock being scanned,
  fsdirfree                     -> and whether WE made it (must free)
  tcc[80]:ARRAY OF LONG         -> candidates: ptrs into tcpool, each
  tcpool:PTR TO CHAR            -> entry = [flags CHAR][name NUL]
  tcpu, tcn, tcmore
  tcactive, tcsel               -> the menu: open?, highlighted index
  tcws, tcwend                  -> the word being completed, in ebuf
  tcmrows, tcmcols, tcmcolw, tcshown
  tctmp:PTR TO CHAR             -> completion scratch (E-string)
  tctail:PTR TO CHAR            -> line tail during word replacement
  -> byte arrays last (alignment)
  inq[2048]:ARRAY OF CHAR       -> input byte queue (finished lines)
  pscrname[64]:ARRAY OF CHAR    -> SCREENname: a public screen
  pfontname[40]:ARRAY OF CHAR   -> v1.1 FONT: the requested face
  osct[84]:ARRAY OF CHAR        -> v1.1: OSC title being collected
ENDOBJECT

DEF port:PTR TO mp,             -> our packet port = pr_MsgPort
    -> M10a: THE console. Everything per-window is inside it; what
    -> stays out here is genuinely shared across any future windows -
    -> the ports, the devices, the one input chain, the fs plumbing.
    curcon:PTR TO console,      -> NIL between dispatches is legal now
    conlist=NIL:PTR TO console, -> every living console (M10b)
    timercon=NIL:PTR TO console,-> whose WAIT_CHAR head the timer serves
    clipport=NIL:PTR TO mp,     -> clipboard.device (M7), opened lazily
    clipreq=NIL:PTR TO ioclipreq,
    clipbuf=NIL:PTR TO CHAR,
    tport=NIL:PTR TO mp,        -> timer.device plumbing for WAIT_CHAR
    treq=NIL:PTR TO timerequest,
    timerarmed=FALSE,
    rawdef=FALSE,               -> Startup="RAW": streams open raw (M9)
    -> tab-completion fs plumbing (M5b): hand-rolled packets ride a
    -> private reply port so pr_MsgPort is never touched (no-DOS rule)
    fsport=NIL:PTR TO mp,       -> private reply port for fs packets
    fspkt=NIL:PTR TO standardpacket,
    fsfib=NIL:PTR TO fileinfoblock,  -> longword-aligned (BPTR arg)
    fsname=NIL:PTR TO CHAR,     -> BSTR build buffer, longword-aligned
    -> v1.1 Theme B: ONE shared prompt history for every window this
    -> process serves (was per-console) - persisted to L:ccon-history,
    -> loaded once at the first-ever open, saved when the last window
    -> closes. hpos (the per-window Up/Down walk position) and the
    -> Ctrl+R search state stay on the console - two windows can
    -> browse the same shared ring independently.
    ghist[HISTMAX]:ARRAY OF LONG, -> the ring: E-string ptrs
    ghtotal=0,                  -> running count (Mod HISTMAX for slot)
    ghistloaded=FALSE,           -> disk load attempted once
    -> M6: the input.device chain - ONE per process, by design (the
    -> M10 decision: N chain handlers is the wrong shape)
    ihgd[2]:ARRAY OF LONG,      -> glue data: [E's A4][{ihchain}]
    ihcapa4=0,                  -> A4, captured by inline asm at start
    ihis=NIL:PTR TO is,         -> the interrupt in input.device's chain
    ihport=NIL:PTR TO mp,
    ihreq=NIL:PTR TO iostd,
    ihon=FALSE,
    ihtask=NIL, ihsigbit=-1, ihsig=0,
    ihring=NIL:PTR TO CHAR,     -> IHMAX slots, stride 32
    ihhead=0, ihtail=0,         -> free-running; slot = n AND (IHMAX-1)
    ihdrop=0,                   -> events lost to a full ring
    ihie=NIL:PTR TO inputevent, -> rebuilt event for MapRawKey
    ihiebuf[8]:ARRAY OF LONG,   -> its longword-aligned storage
    -> v1.1b2: the disk-font loader - a throwaway helper process
    -> runs OpenDiskFont on our behalf (it has its own pr_MsgPort,
    -> so the no-DOS rule stays whole); the handler sleeps on fhsig
    fhok=FALSE,                 -> the plumbing came up at init
    fhstub=NIL:PTR TO CHAR,     -> poked machine code: the NP_Entry
    fhgd[2]:ARRAY OF LONG,      -> stub and its [A4][{fonthelper}]
    fhcapa4=0,                  -> glue vector (the gluestub pattern)
    fhsigbit=-1, fhsig=0,
    fhtask=NIL,
    fhta=NIL:PTR TO textattr,   -> the request: in
    fhfont=NIL,                 -> the result: out
    ihmap[36]:ARRAY OF CHAR     -> MapRawKey result bytes

PROC main()
  DEF proc:PTR TO process, msg:PTR TO mn, pkt:PTR TO dospacket,
      dnode:PTR TO devicenode, psig, wsig, im:PTR TO intuimessage,
      class, code, qual, mx, my, ia, secs, mics, tmp,
      stps:PTR TO CHAR, c:PTR TO console, cnext,
      wp:PTR TO INT, lp:PTR TO LONG

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
  -> M9: one binary, two devices - a mountlist with Startup = "RAW"
  -> (CRAW-mountlist) makes this instance open its streams raw by
  -> default, the RAW: counterpart. dn_Startup holds a BPTR to a
  -> BSTR when it is not a small integer.
  tmp := dnode.startup
  IF tmp > 1024
    stps := Shl(tmp, 2)
    IF stps[0] = 3
      IF (tcfold(stps[1]) = "R") AND (tcfold(stps[2]) = "A") AND
         (tcfold(stps[3]) = "W") THEN rawdef := TRUE
    ENDIF
  ENDIF
  -> M10b: no console exists until the first open makes one - dofind
  -> builds them, the list carries them, curcon may be NIL between
  -> dispatches and every dispatch boundary sets it before use
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

  -> v1.1 Theme B: the shared history ring's strings, allocated once
  -> here; the disk LOAD happens later, at the first real console
  -> open (histinit is curcon-scoped like tcresolve - no console
  -> exists yet at this point in main() for it to scratch through)
  FOR tmp := 0 TO HISTMAX - 1
    ghist[tmp] := String(LINEMAX)
  ENDFOR

  -> v1.1b2: the disk-font loader plumbing. The helper's entry is
  -> 24 bytes of hand-poked machine code: an NP_Entry process
  -> starts WITHOUT E's A4 data base, so the stub loads it from
  -> fhgd exactly the way gluestub loads it from is_Data - only
  -> the vector address rides as an immediate poked in here, since
  -> a process entry carries no is_Data pointer. Exec-only; if any
  -> step fails, fhok stays FALSE and FONT falls back to OpenFont.
  fhtask := FindTask(NIL)
  fhsigbit := AllocSignal(-1)
  fhstub := New(32)
  IF (fhsigbit >= 0) AND (fhstub <> NIL)
    fhsig := Shl(1, fhsigbit)
    MOVE.L A4,fhcapa4
    fhgd[0] := fhcapa4
    fhgd[1] := {fonthelper}
    wp := fhstub
    wp[0] := $48E7              -> MOVEM.L D2-D7/A2-A6,-(A7)
    wp[1] := $3F3E
    wp[2] := $267C              -> MOVEA.L #fhgd,A3
    lp := fhstub + 6            -> the immediate (even, 68000-legal)
    lp[0] := fhgd
    wp[5] := $2853              -> MOVEA.L (A3),A4
    wp[6] := $206B              -> MOVEA.L 4(A3),A0
    wp[7] := $0004
    wp[8] := $4E90              -> JSR (A0)
    wp[9] := $4CDF              -> MOVEM.L (A7)+,D2-D7/A2-A6
    wp[10] := $7CFC
    wp[11] := $4E75             -> RTS
    CacheClearU()               -> poked code vs instruction cache
    fhok := TRUE
  ENDIF

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
    c := conlist                  -> M10b: every console's UserPort
    WHILE c                       -> joins the wait mask
      IF c.win THEN wsig := wsig OR Shl(1, c.win.userport.sigbit)
      c := c.next
    ENDWHILE
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
    -> drain every console's window port - UNLESS that console's
    -> client asked for raw event reports (Ed). Disassembling C:Ed
    -> (18.7.26) showed it never touches this port at all (no
    -> ModifyIDCMP/GetMsg on our window; the LVO hits that suggested
    -> it were rexxsyslib collisions - Ed's ARexx machinery). The
    -> park stays anyway: with the chain on, the only IDCMP class
    -> left is CLOSEWINDOW, and deferring a close-gadget click while
    -> a raw-events client (Ed fullscreen) owns the session beats
    -> tearing the window down under it. Leftovers drain when the
    -> mask clears (CSI }, cooked reversion, close). A closereq may
    -> destroy the console inside the walk - the next pointer is
    -> taken FIRST.
    c := conlist
    WHILE c
      cnext := c.next
      IF c.win
        curcon := c
        IF (ihon = FALSE) OR (c.evmask = 0)
          REPEAT
            im := GetMsg(c.win.userport)
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
              IF class = IDCMP_MOUSEBUTTONS THEN selmouse(code, secs, mics)
              IF class = IDCMP_MOUSEMOVE THEN selmouse($FF, 0, 0)
              IF class = IDCMP_NEWSIZE THEN doresize()
              IF class = IDCMP_CLOSEWINDOW THEN doclosew()
            ENDIF
          UNTIL im = NIL
        ENDIF
        IF c.closereq             -> deferred: never CloseWindow while
          c.closereq := FALSE     -> draining the port it owns
          conclose(c)
        ENDIF
      ENDIF
      c := cnext
    ENDWHILE
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

-> M10a: a console starts life here. New() zeroed it; these are the
-> fields whose ground state is not zero, plus the six strings that
-> were static globals before the OBJECT move (an OBJECT field cannot
-> be a STRING - they are E-strings off the heap now, made once).
-> FALSE = allocation failure: the caller refuses the mount rather
-> than run half-built.
PROC coninit(c:PTR TO console)
  c.cursx := -1                 -> no block cursor painted
  c.selanc := -1
  c.selcur := -1
  c.sello := -1                 -> no standing highlight
  c.selhi := -1
  c.hpos := -1                  -> not walking the history
  c.tcsel := -1                 -> no completion pick
  c.deffg := 1
  c.curfg := 1
  c.pwx := 40                   -> parsecon() re-derives these per
  c.pwy := 40                   -> first-open; ground them anyway
  c.pww := 520
  c.pwh := 160
  c.ebuf := String(404)
  c.stash := String(404)
  c.wtitle := String(112)
  c.wtitlebase := String(84)
  c.tctmp := String(416)
  c.tctail := String(404)
  c.tcpool := New(TCPOOLSZ)     -> NIL is survivable: dotab declines
  c.srbuf := String(64)
  c.srstash := String(404)
  c.sridx := -1
  IF (c.ebuf = NIL) OR (c.stash = NIL) OR (c.wtitle = NIL) OR
     (c.wtitlebase = NIL) OR (c.tctmp = NIL) OR (c.tctail = NIL) OR
     (c.srbuf = NIL) OR (c.srstash = NIL)
    RETURN FALSE
  ENDIF
ENDPROC TRUE

-> ---------- the console list (M10b) ----------

-> only ever trust a console pointer that is ON the list: packets
-> carry fh_Arg1 from clients, ring slots carry tags captured before
-> a close could land - both are validated here before use
PROC conok(c)
  DEF p:PTR TO console
  p := conlist
  WHILE p
    IF p = c THEN RETURN TRUE
    p := p.next
  ENDWHILE
ENDPROC FALSE

-> ihchain walks the list from input.device's task, so mutations are
-> Forbid-bracketed (it IS a task, not a real interrupt - Forbid
-> holds it off; single stores would almost be enough, but paid-for
-> lessons say almost is not a word for a handler)
PROC conadd(c:PTR TO console)
  Forbid()
  c.next := conlist
  conlist := c
  Permit()
ENDPROC

PROC conrm(c:PTR TO console)
  DEF p:PTR TO console
  Forbid()
  IF conlist = c
    conlist := c.next
  ELSE
    p := conlist
    WHILE p
      IF p.next = c
        p.next := c.next
        p := NIL
      ELSE
        p := p.next
      ENDIF
    ENDWHILE
  ENDIF
  Permit()
ENDPROC

-> the ARMED console whose window this is; NIL = not ours (armed
-> gates the chain: a half-built openwin window takes nothing yet)
PROC conbywin(w)
  DEF p:PTR TO console
  IF w = NIL THEN RETURN NIL
  p := conlist
  WHILE p
    IF p.armed AND (p.win = w) THEN RETURN p
    p := p.next
  ENDWHILE
ENDPROC NIL

-> route a handle-less packet (WAIT_CHAR, SCREEN_MODE, DISK_INFO,
-> CHANGE_SIGNAL) or a `*`/CONSOLE: open to the SENDER's console:
-> its CLI's StandardInput filehandle carries our console pointer in
-> fh_Args - the routing the packet protocol always wanted (commands
-> run inside the CLI process on AmigaDOS, so More and Ed resolve
-> this way too). Fallbacks: the active window, then the list head.
PROC conbysender(pkt:PTR TO dospacket)
  DEF sender:PTR TO mp, t:PTR TO tc, proc:PTR TO process,
      cli:PTR TO commandlineinterface, fh:PTR TO filehandle,
      c, ib:PTR TO intuitionbase, p:PTR TO console
  t := NIL
  sender := pkt.port
  IF sender THEN t := sender.sigtask
  IF t
    IF t.ln.type = NT_PROCESS
      proc := t
      IF proc.cli
        cli := Shl(proc.cli, 2)
        IF cli.standardinput
          fh := Shl(cli.standardinput, 2)
          c := fh.args
          IF conok(c) THEN RETURN c
        ENDIF
      ENDIF
    ENDIF
    -> a WB-launched client has no CLI: the console this task last
    -> opened, read or wrote is its best claim (More does Open then
    -> SetMode from the same task, breaktask tracks exactly that)
    p := conlist
    WHILE p
      IF p.breaktask = t THEN RETURN p
      p := p.next
    ENDWHILE
  ENDIF
  ib := intuitionbase
  c := conbywin(ib.activewindow)
  IF c THEN RETURN c
ENDPROC conlist

-> everything a console owns goes back to the heap (the window
-> resources went down in closewin already)
PROC condispose(c:PTR TO console)
  IF c.ebuf THEN Dispose(c.ebuf)
  IF c.stash THEN Dispose(c.stash)
  IF c.wtitle THEN Dispose(c.wtitle)
  IF c.wtitlebase THEN Dispose(c.wtitlebase)
  IF c.tctmp THEN Dispose(c.tctmp)
  IF c.tctail THEN Dispose(c.tctail)
  IF c.tcpool THEN Dispose(c.tcpool)
  IF c.srbuf THEN Dispose(c.srbuf)
  IF c.srstash THEN Dispose(c.srstash)
  Dispose(c)
ENDPROC

-> a console dies: window resources down, off the list, ring slots
-> scrubbed (ihdrain validates against the list too, but a LATER
-> console could reuse the same heap address - scrub, don't hope),
-> memory freed. curcon may come out NIL; every dispatch sets it.
PROC conclose(c:PTR TO console)
  DEF e:PTR TO ihev, n
  curcon := c
  closewin()                    -> replies parked writers/reads/waits
  conrm(c)
  -> Theme B: belt-and-suspenders - every command already flushes
  -> the ring (dovanilla's Return commit), so this is normally a
  -> same-content rewrite. Kept for the one gap that isn't: a
  -> console dying with unsaved state some OTHER way. curcon is
  -> still c here (about to be disposed) - savehistfile needs a
  -> live console to scratch tcresolve's fields through, and
  -> conlist is NIL (the last window) so there is nothing else to
  -> use.
  IF conlist = NIL THEN savehistfile()
  n := ihtail
  WHILE n <> ihhead
    e := ihring + Shl(n AND (IHMAX - 1), 5)
    IF e.con = c THEN e.con := NIL
    n := n + 1
  ENDWHILE
  condispose(c)
  curcon := conlist
  rearmtimer()                  -> another console's waiters may be
ENDPROC                         -> owed the timer now

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

-> the ONE timer request serves one console at a time: timercon's
-> head waiter. When it goes quiet, the next console with waiters
-> gets a fresh full timeout - the same approximation the single
-> queue already documented, per console now.
PROC rearmtimer()
  DEF p:PTR TO console, pkt:PTR TO dospacket
  IF timerarmed THEN RETURN
  IF treq = NIL THEN RETURN
  p := conlist
  WHILE p
    IF p.wcn > 0
      pkt := p.wcq[0]
      timercon := p
      armtimer(pkt.arg1)
      RETURN
    ENDIF
    p := p.next
  ENDWHILE
  timercon := NIL
ENDPROC

PROC timerexpired()
  DEF pkt:PTR TO dospacket, i, c:PTR TO console
  c := timercon
  timercon := NIL
  IF conok(c)
    IF c.wcn > 0
      pkt := c.wcq[0]
      FOR i := 1 TO c.wcn - 1
        c.wcq[i - 1] := c.wcq[i]
      ENDFOR
      c.wcn := c.wcn - 1
      ReplyPkt(pkt, DOSFALSE, 0)
    ENDIF
  ENDIF
  rearmtimer()
ENDPROC

-> input became available on curcon: wake every one of ITS
-> WAIT_CHARs, then feed the reads
PROC satisfywaits()
  DEF i
  IF curcon.wcn = 0 THEN RETURN
  IF inavail() = 0 THEN RETURN
  IF timercon = curcon
    canceltimer()
    timercon := NIL
  ENDIF
  FOR i := 0 TO curcon.wcn - 1
    ReplyPkt(curcon.wcq[i], DOSTRUE, 0)
  ENDFOR
  curcon.wcn := 0
  rearmtimer()
ENDPROC

PROC inputarrived()
  satisfywaits()
  satisfyreads()
ENDPROC

-> M10b routing: handle-carrying packets (END/READ/WRITE) find their
-> console in fh_Arg1 - the pointer dofind stored, validated against
-> the list before trust; handle-less console packets (WAIT_CHAR,
-> SCREEN_MODE, CHANGE_SIGNAL, DISK_INFO) route by their SENDER
-> (conbysender). curcon is set at exactly these boundaries.
PROC dopkt(pkt:PTR TO dospacket)
  DEF len, old, id:PTR TO infodata, zp:PTR TO LONG, i, sender:PTR TO mp,
      c:PTR TO console
  SELECT pkt.type
  CASE ACTION_FINDINPUT;  dofind(pkt)
  CASE ACTION_FINDOUTPUT; dofind(pkt)
  CASE ACTION_FINDUPDATE; dofind(pkt)
  CASE ACTION_END
    c := pkt.arg1
    IF conok(c) = FALSE
      ReplyPkt(pkt, DOSFALSE, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
    curcon := c
    c.opens := c.opens - 1
    -> b11 safety net: a client that DIED on the alternate screen
    -> (Ctrl+C'd More) never sends ?47l - its closing handle
    -> restores the transcript instead of leaving it lost forever
    IF c.altvalid AND c.win
      IF altrestore()
        IF c.rawmode = FALSE THEN drawedit()
      ENDIF
    ENDIF
    IF c.opens <= 0
      c.opens := 0
      c.breaktask := NIL
      IF c.win
        IF c.waitmode = FALSE   -> stock CON: semantics: the window
          conclose(c)           -> dies with its last handle; WAIT
        ENDIF                   -> lingers for its close gadget and
      ELSE                      -> dies by conclose there. A window-
        conclose(c)             -> less console (AUTO never opened)
      ENDIF                     -> has nothing to linger for.
    ENDIF
    ReplyPkt(pkt, DOSTRUE, 0)
  CASE ACTION_WRITE
    c := pkt.arg1
    IF conok(c) = FALSE
      ReplyPkt(pkt, -1, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
    curcon := c
    IF curcon.selon AND (curcon.wqn < WQMAX)
      curcon.wq[curcon.wqn] := pkt            -> a drag holds the screen still: the
      curcon.wqn := curcon.wqn + 1                     -> writer waits, unreplied, until the
    ELSE                        -> button releases (stock console
      dowrite(pkt)              -> behaviour - output freezes while
    ENDIF                       -> you select)
  CASE ACTION_READ
    c := pkt.arg1
    IF conok(c) = FALSE
      ReplyPkt(pkt, -1, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
    curcon := c
    ensurewin()                 -> an AUTO window appears on read too
    sender := pkt.port          -> the reader owns the break signal now
    curcon.breaktask := sender.sigtask -> (the AROS con-handler does the same)
    IF curcon.rdn < RDMAX
      curcon.rdq[curcon.rdn] := pkt           -> queue it; a finished line replies it
      curcon.rdn := curcon.rdn + 1
      satisfyreads()
    ELSE
      ReplyPkt(pkt, -1, ERROR_NO_FREE_STORE)
    ENDIF
  CASE ACTION_WAIT_CHAR
    c := conbysender(pkt)       -> no handle rides this packet
    IF c = NIL
      ReplyPkt(pkt, DOSFALSE, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
    curcon := c
    ensurewin()
    -> arg1 = timeout in MICROseconds (AROS-verified): input queued =
    -> DOSTRUE now; timeout 0 = DOSFALSE now; else park the packet and
    -> let timer.device answer (input arrival wakes all waiters)
    IF inavail() > 0
      ReplyPkt(pkt, DOSTRUE, 0)
    ELSEIF (pkt.arg1 <= 0) OR (treq = NIL) OR (curcon.wcn >= 8)
      ReplyPkt(pkt, DOSFALSE, 0)
    ELSE
      curcon.wcq[curcon.wcn] := pkt
      curcon.wcn := curcon.wcn + 1
      rearmtimer()              -> no-op while another head is armed
    ENDIF
  CASE ACTION_SCREEN_MODE
    c := conbysender(pkt)       -> no handle here either
    IF c = NIL
      ReplyPkt(pkt, DOSFALSE, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
    curcon := c
    ensurewin()                 -> mode changes imply a console soon
    -> arg1: DOSTRUE = raw, 0 = cooked. Raw parks the line editor -
    -> keys become bytes, the client owns echo and screen
    IF pkt.arg1
      IF curcon.rawmode = FALSE
        curcon.rawmode := TRUE
        tcclose()
        eraseedit()
        cursdraw()              -> the block cursor appears at once
      ENDIF
    ELSE
      IF curcon.rawmode
        curcon.rawmode := FALSE
        curserase()             -> the blip owns cooked mode
        reanchor()              -> (b11: the altscreen no longer rides
        drawedit()              -> SetMode - More's ?47l comes AFTER
      ENDIF                     -> this packet and restores then)
      -> a client reverting to cooked is done with its raw event
      -> reports too (Ed does not send CSI } on exit); clearing the
      -> mask also resumes the parked UserPort drain (M6)
      curcon.evmask := 0
      setidcmp()                -> and MOUSEBUTTONS comes back
    ENDIF
    ReplyPkt(pkt, DOSTRUE, 0)
  CASE ACTION_CHANGE_SIGNAL
    c := conbysender(pkt)
    IF c = NIL
      ReplyPkt(pkt, DOSFALSE, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
    curcon := c
    -> arg2 = Task to signal on Ctrl+C..F (0 = just query); res2 = old
    old := curcon.breaktask
    IF pkt.arg2 THEN curcon.breaktask := pkt.arg2
    ReplyPkt(pkt, DOSTRUE, old)
  CASE ACTION_DISK_INFO
    c := conbysender(pkt)       -> which window? the sender's console
    IF c = NIL                  -> (More's retitle, Ed's menu strip
      ReplyPkt(pkt, DOSFALSE, ERROR_OBJECT_NOT_FOUND)
      RETURN                    -> both hang off this pointer)
    ENDIF
    curcon := c
    -> the console curiosity: id_VolumeNode carries the WINDOW pointer,
    -> which is how programs find the console's window
    ensurewin()                 -> the asker wants a window pointer
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
    id.volumenode := curcon.win
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
  ensurewin()                   -> an AUTO window appears on first
  IF curcon.win = NIL                  -> output; no window at all = the
    ReplyPkt(pkt, -1, ERROR_NO_FREE_STORE)  -> write cannot land
    RETURN
  ENDIF
  sender := pkt.port            -> the writer owns the break signal too:
  curcon.breaktask := sender.sigtask   -> `list >CCON:` is opened by the SHELL,
                                -> but the WRITEs come from list itself -
                                -> this line is what makes Ctrl+C reach it
                                -> (AROS con-handler does the same)
  len := pkt.arg3
  clearsel()                    -> output takes the highlight with it
  snaplive()                    -> new output pulls the view back to live
  tcclose()                     -> and closes an open completion menu
  IF curcon.rawmode
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
  WHILE i < curcon.wqn
    dowrite(curcon.wq[i])              -> FIFO: writers resume in order
    i++
  ENDWHILE
  curcon.wqn := 0
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
-> one open-string option, folded + dispatched. Split out of
-> parsecon (v1.1b12) so the f=0 special case below - a keyword AS
-> THE VERY FIRST FIELD, no geometry slashes at all - can share it
-> with the normal post-title route. Returns TRUE when tok named a
-> real option; unrecognized tokens are dropped either way (house
-> rule), the return only matters to the f=0 caller.
PROC parseopt(tok:PTR TO CHAR)
  DEF tok2[84]:ARRAY OF CHAR, v, c, matched=TRUE
  -> fold to upper case in place, then compare - keeping the raw
  -> token (tok2) for case-preserving values
  v := 0
  WHILE tok[v]
    tok2[v] := tok[v]
    tok[v] := tcfold(tok[v])
    v++
  ENDWHILE
  tok2[v] := 0
  -> v1.1 FONT: fields split on '/', so "FONTname/size" arrives
  -> as TWO tokens - a bare number right after a FONT is its size
  c := -1
  IF curcon.pfontexp THEN c := tcnum(tok)
  curcon.pfontexp := FALSE
  IF c >= 1
    curcon.pfontsize := c
  ELSEIF StrCmp(tok, 'WAIT')
    curcon.waitmode := TRUE
    curcon.closegad := TRUE        -> WAIT needs the gadget to end
  ELSEIF StrCmp(tok, 'CLOSE')
    curcon.closegad := TRUE
  ELSEIF StrCmp(tok, 'NOCLOSE')
    curcon.closegad := FALSE
  ELSEIF StrCmp(tok, 'AUTO')
    curcon.pauto := TRUE           -> the window waits for first I/O
  ELSEIF StrCmp(tok, 'NOBORDER')
    curcon.pnoborder := TRUE
  ELSEIF StrCmp(tok, 'NODRAG')
    curcon.pnodrag := TRUE
  ELSEIF StrCmp(tok, 'NODEPTH')
    curcon.pnodepth := TRUE
  ELSEIF StrCmp(tok, 'NOSIZE')
    curcon.pnosize := TRUE
  ELSEIF StrCmp(tok, 'BACKDROP')
    curcon.pbackdrop := TRUE
  ELSEIF StrCmp(tok, 'INACTIVE')
    curcon.pinactive := TRUE
  ELSEIF StrCmp(tok, 'PASTEEXEC')
    -> Theme B: opt this WHOLE window back into the 1.0/pre-safety
    -> behaviour - every RAMIGA-V runs each pasted line as it lands,
    -> no queueing. RAMIGA+SHIFT+V still overrides per-paste even
    -> without this option; this is for someone who wants that to
    -> just always be how the window behaves.
    curcon.pasteexec := TRUE
  ELSEIF StrCmp(tok, 'SCREEN', 6)
    -> SCREENname, stock syntax: open on that public screen
    -> (name taken case-preserved from the raw token). A bare
    -> "SCREEN" with nothing after is NOT a match - matters now
    -> that field 4 (the title) tries this too: a title that
    -> merely STARTS with a keyword must fall through to being
    -> a title, not a silently-broken option.
    v := 6
    c := 0
    WHILE tok2[v] AND (c < 63)
      curcon.pscrname[c] := tok2[v]
      c++
      v++
    ENDWHILE
    curcon.pscrname[c] := 0
    IF c = 0 THEN matched := FALSE
  ELSEIF StrCmp(tok, 'WBPENS')
    -> translate the classic Workbench pens when a program
    -> hardcodes them: C:Ed prints its body text as SGR 31
    -> ("pen 1" = BLACK on the WB palette) and highlights as
    -> 33 (WB blue). On an ANSI palette pen 1 is red, so a
    -> client that owns such a screen (CTerm's dark theme)
    -> sends WBPENS and plain 30-33 become theme pens
    -> instead: 30->0, 31->deffg, 32->15, 33->12. Bold forms
    -> (1;3x - the ls scheme) and backgrounds are untouched.
    curcon.wbpens := TRUE
  ELSEIF StrCmp(tok, 'PEN', 3)
    -> PENn: the default text pen (CTerm sends PEN7 with its
    -> ANSI palette, where pen 1 is ANSI red)
    v := tcnum(tok + 3)
    IF (v >= 1) AND (v <= 15) THEN curcon.deffg := v ELSE matched := FALSE
  ELSEIF StrCmp(tok, 'WINDOW0X', 8)
    v := 0
    c := 8
    WHILE tok[c]
      IF (tok[c] >= "0") AND (tok[c] <= "9")
        v := Shl(v, 4) + (tok[c] - 48)
      ELSEIF (tok[c] >= "A") AND (tok[c] <= "F")
        v := Shl(v, 4) + (tok[c] - 55)
      ELSE
        matched := FALSE
      ENDIF
      c++
    ENDWHILE
    IF matched THEN curcon.fwptr := v
  ELSEIF StrCmp(tok, 'LINES', 5)
    -> v1.1: the memory knob - model depth per console. tcnum
    -> already caps at 20000; openwin floors at 100, ceilings at
    -> SBMAXCAP (4000, the OLD 1.0-era default).
    v := 5
    IF tok[v] = "=" THEN v := 6
    v := tcnum(tok + v)
    IF v >= 0 THEN curcon.plines := v ELSE matched := FALSE
  ELSEIF StrCmp(tok, 'FONT', 4)
    -> v1.1: FONTname/size - name case-preserved from the raw
    -> token; ".font" is appended in openwin when missing
    v := 4
    IF tok2[v] = "=" THEN v := 5
    c := 0
    WHILE tok2[v] AND (c < 35)
      curcon.pfontname[c] := tok2[v]
      c++
      v++
    ENDWHILE
    curcon.pfontname[c] := 0
    IF c > 0 THEN curcon.pfontexp := TRUE ELSE matched := FALSE
  ELSE
    matched := FALSE
  ENDIF
ENDPROC matched

PROC parsecon(bname)
  DEF s:PTR TO CHAR, l, i, f, tl, v, c, optmode=FALSE,
      tok[84]:ARRAY OF CHAR, torig[84]:ARRAY OF CHAR
  curcon.pwx := 40
  curcon.pwy := 40
  curcon.pww := 520
  curcon.pwh := 160
  StrCopy(curcon.wtitlebase, 'CCON:')
  curcon.waitmode := FALSE
  curcon.closegad := TRUE              -> stock 3.2 shape: close gadget on
  curcon.fwptr := NIL                  -> (NOCLOSE removes it)
  curcon.deffg := 1
  curcon.wbpens := FALSE
  curcon.pauto := FALSE
  curcon.pnoborder := FALSE
  curcon.pnodrag := FALSE
  curcon.pnodepth := FALSE
  curcon.pnosize := FALSE
  curcon.pbackdrop := FALSE
  curcon.pinactive := FALSE
  curcon.pasteexec := FALSE            -> Theme B: safe paste is the
                                        -> default; PASTEEXEC opts out
  curcon.pscrname[0] := 0              -> global array: garbage until set
  curcon.plines := 0                   -> v1.1: LINES/FONT re-ground per
  curcon.pfontname[0] := 0             -> open like everything else
  curcon.pfontsize := 0
  curcon.pfontexp := FALSE
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
    IF optmode
      parseopt(tok)              -> once the shortcut fires, every
                                 -> further token is an option too
    ELSEIF f = 0
      v := tcnum(tok)
      IF v >= 0
        curcon.pwx := v
      ELSEIF parseopt(tok)
        -> v1.1b12: the FIRST field wasn't a number and NAMED a
        -> real option - "ccon:FONTtopaz/8" with no geometry at
        -> all, the shape he actually reached for. The whole spec
        -> becomes options-only (x/y/w/h/title stay default); to
        -> mix geometry WITH options, spell the positional fields
        -> as before (ccon:0/0/640/80/title/FONTtopaz/8) - unquoted
        -> '=' is still the shell's, not ours (see dofind/parsecon
        -> notes) - this shortcut sidesteps the OTHER trap instead:
        -> counting slashes just to reach the options field.
        optmode := TRUE
      ENDIF
    ELSEIF f = 1
      v := tcnum(tok)
      IF v >= 0 THEN curcon.pwy := v
    ELSEIF f = 2
      -> his ask, 19.7.26: width/height=-1 fills the screen (openwin
      -> resolves the sentinel once it has a screen to measure).
      -> tcnum() itself has no minus-sign support and would just
      -> read "-1" as invalid (silently ignored, the OLD behaviour)
      -> - the literal string is checked first so it means FILL,
      -> not "leave the default".
      IF StrCmp(tok, '-1')
        curcon.pww := -1
      ELSE
        v := tcnum(tok)
        IF v >= 0 THEN curcon.pww := v
      ENDIF
    ELSEIF f = 3
      IF StrCmp(tok, '-1')
        curcon.pwh := -1
      ELSE
        v := tcnum(tok)
        IF v >= 0 THEN curcon.pwh := v
      ENDIF
    ELSEIF f = 4
      -> the title-slot footgun (his catch, 19.7.26): with explicit
      -> geometry given, field 4 is ALWAYS the title - so
      -> "0/0/640/100/LINES384" silently made "LINES384" the
      -> TITLE and never touched plines at all, no error, no
      -> warning. Now field 4 tries parseopt FIRST; every prefix
      -> branch in it fails closed (matched=FALSE) unless its
      -> suffix genuinely parses, so an ordinary title merely
      -> STARTING with a keyword ("Screensaver-log", "Penguin")
      -> still falls through and becomes the title exactly as
      -> before - only a token that actually parses as a real
      -> option (LINES384, FONTtopaz/8, WAIT, PEN7, ...) gets
      -> diverted.
      IF tl > 0
        -> parseopt folds tok to uppercase IN PLACE even when it
        -> ends up not matching - a title must keep its real case,
        -> so save it before the call, not after. A manual copy,
        -> not StrCopy: tok/torig are plain fixed arrays, not
        -> String()-allocated E strings, and StrCopy needs the
        -> latter's hidden header (the same trap dirp's own
        -> byte-loop below already routes around).
        FOR v := 0 TO tl - 1
          torig[v] := tok[v]
        ENDFOR
        torig[tl] := 0
        IF parseopt(tok) = FALSE THEN StrCopy(curcon.wtitlebase, torig)
      ENDIF
    ELSE
      parseopt(tok)
    ENDIF
    f++
  ENDWHILE
ENDPROC

-> M10b: a window per open - the stock CON: family shape. Every
-> create-open builds its OWN console (its options finally parse per
-> open: the M9 wall comes down); `*` and CONSOLE: opens attach to
-> the SENDER's console instead - the reopen-your-own-console idiom
-> (AROS con-handler does the same split). WAIT windows linger until
-> their gadget, but nothing re-attaches to them any more: a new
-> open is a new window now, which is what stock CON: does too.
PROC dofind(pkt:PTR TO dospacket)
  DEF fh:PTR TO filehandle, sender:PTR TO mp, c:PTR TO console,
      s:PTR TO CHAR, l, i, att
  -> classify the name: no ':' with a leading '*' = attach; device
  -> part CONSOLE = attach; no name at all can only mean the
  -> sender's console; anything else = a fresh window
  att := FALSE
  IF pkt.arg3
    s := Shl(pkt.arg3, 2)       -> a BSTR: length byte, then chars
    l := s[0]
    i := 1
    WHILE (i <= l) AND (s[i] <> ":")
      i++
    ENDWHILE
    IF i > l
      IF l > 0
        IF s[1] = "*" THEN att := TRUE
      ENDIF
    ELSEIF i = 8
      IF (tcfold(s[1]) = "C") AND (tcfold(s[2]) = "O") AND
         (tcfold(s[3]) = "N") AND (tcfold(s[4]) = "S") AND
         (tcfold(s[5]) = "O") AND (tcfold(s[6]) = "L") AND
         (tcfold(s[7]) = "E") THEN att := TRUE
    ENDIF
  ELSE
    att := TRUE
  ENDIF
  IF att
    c := conbysender(pkt)
    IF c = NIL
      ReplyPkt(pkt, DOSFALSE, ERROR_OBJECT_NOT_FOUND)
      RETURN
    ENDIF
  ELSE
    c := New(SIZEOF console)
    IF c
      IF coninit(c) = FALSE
        condispose(c)           -> frees whatever coninit got
        c := NIL
      ENDIF
    ENDIF
    IF c = NIL
      ReplyPkt(pkt, DOSFALSE, ERROR_NO_FREE_STORE)
      RETURN
    ENDIF
    curcon := c
    -> Theme B: the shared history ring loads from L:ccon-history
    -> once, on this process's first-ever real window - curcon must
    -> already be a live console for tcresolve to scratch through,
    -> so this cannot happen any earlier than here (main() has none)
    IF ghistloaded = FALSE
      ghistloaded := TRUE
      loadhistfile()
    ENDIF
    parsecon(pkt.arg3)          -> THIS open's spec, nobody else's
    conadd(c)                   -> listed unarmed: the chain ignores
    IF c.pauto                  -> it until openwin's last line
      c.autopend := TRUE        -> AUTO (M9): the open succeeds
    ELSE                        -> windowless; first real I/O makes
      openwin()                 -> the window (ensurewin)
      IF c.win = NIL
        conrm(c)
        condispose(c)
        curcon := conlist
        ReplyPkt(pkt, DOSFALSE, ERROR_NO_FREE_STORE)
        RETURN
      ENDIF
    ENDIF
  ENDIF
  curcon := c
  fh := Shl(pkt.arg1, 2)        -> BPTR to the FileHandle DOS made
  fh.args := c                  -> the console pointer IS the stream
  fh.interactive := DOSTRUE     -> id: packets route by it now
  c.opens := c.opens + 1
  sender := pkt.port
  c.breaktask := sender.sigtask -> opener gets Ctrl+C..F by default
  ReplyPkt(pkt, DOSTRUE, 0)
ENDPROC

-> an AUTO window materializes on the first packet that needs one
PROC ensurewin()
  IF (curcon.win = NIL) AND curcon.autopend THEN openwin()
ENDPROC

-> the text grid from the window's current dimensions. A borrowed
-> window is sized to an exact grid by its owner: no margin inset
-> there, or the columns drift off the owner's art.
PROC gridcalc()
  DEF i
  i := MARGIN
  IF curcon.fwin THEN i := 0
  curcon.left := curcon.win.borderleft + i
  curcon.topy := curcon.win.bordertop + i
  curcon.cols := Div(curcon.win.width - curcon.win.borderleft - curcon.win.borderright - i - i, curcon.cw)
  curcon.rows := Div(curcon.win.height - curcon.win.bordertop - curcon.win.borderbottom - i - i, curcon.ch)
  IF curcon.cols > 255 THEN curcon.cols := 255      -> redraw's row buffer is 256
  IF curcon.cols < 2 THEN curcon.cols := 2
  IF curcon.rows < 1 THEN curcon.rows := 1
ENDPROC

-> ---------- disk fonts (v1.1b2) ----------
-> OpenDiskFont from the handler is the no-DOS rule violated: DoPkt
-> waits on pr_MsgPort, the same port our clients send to. But the
-> rule binds THIS process only - a throwaway helper process has
-> its own pr_MsgPort and talks DOS freely. fontload spawns one per
-> request (only when a FONT option is present), sleeps on a
-> private signal while it works - client packets just queue on the
-> port meanwhile - and gets the loaded font back through fhfont.
-> Fonts are system-global once in memory, so closewin's CloseFont
-> works on them the same as on a ROM font.

-> runs ON THE HELPER process (A4 restored by the poked stub)
PROC fonthelper()
  DEF p:PTR TO process
  p := FindTask(NIL)
  p.windowptr := -1             -> no "please insert volume" boxes
  IF diskfontbase = NIL THEN diskfontbase := OpenLibrary('diskfont.library', 36)
  IF diskfontbase THEN fhfont := OpenDiskFont(fhta)
  Signal(fhtask, fhsig)         -> ALWAYS - the handler is waiting
ENDPROC

PROC fontload(ta:PTR TO textattr)
  DEF f=NIL
  IF fhok
    fhta := ta
    fhfont := NIL
    SetSignal(0, fhsig)         -> no stale wakeups
    IF CreateNewProc([NP_ENTRY, fhstub,
                      NP_NAME, 'ccon-fontload',
                      NP_STACKSIZE, 16384,
                      NP_COPYVARS, FALSE,
                      NP_CURRENTDIR, 0,
                      NP_INPUT, 0,
                      NP_OUTPUT, 0,
                      NP_CLOSEINPUT, FALSE,
                      NP_CLOSEOUTPUT, FALSE,
                      TAG_DONE, NIL])
      Wait(fhsig)
      f := fhfont
    ENDIF
  ENDIF
  -> no helper (or no diskfont.library): loaded fonts still resolve
  IF f = NIL THEN f := OpenFont(ta)
ENDPROC f

PROC openwin()
  DEF ta:PTR TO textattr, i, idc, scrn:PTR TO screen, v,
      pr:PTR TO CHAR, pg:PTR TO CHAR, pb:PTR TO CHAR,
      pubscr:PTR TO screen, fname[48]:ARRAY OF CHAR, fl, ok,
      gfx:PTR TO gfxbase, dfont:PTR TO textfont, mnode:PTR TO mn
  curcon.fwin := FALSE
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
  IF curcon.fwptr
    -> WINDOW0x: render into a window someone else owns. We take its
    -> IDCMP over (the owner must stop reading it - the Ed lesson:
    -> two tasks on one UserPort kill the input chain) and hand it
    -> back untouched on close.
    curcon.win := curcon.fwptr
    curcon.fwin := TRUE
    curcon.oldidcmp := curcon.win.idcmpflags
    ModifyIDCMP(curcon.win, idc)
  ELSE
    -> the fallback is a failure state now - say so where a
    -> screenshot shows it (chain-on and fallback windows behave
    -> identically until Ed's menus are tried)
    IF ihon = FALSE THEN StrAdd(curcon.wtitlebase, ' [no chain]')
    -> M9: SCREENname opens on that public screen (locked for the
    -> OpenWindow only - the window itself then holds the screen);
    -> the no-name/failed case is NIL = the default public screen,
    -> which is exactly where windows went before. Locked here
    -> (not just when SCREENname is given) whenever -1/-1 needs a
    -> screen to measure, so the SAME lock that answers "how big"
    -> is the one the window actually opens on - no re-resolving
    -> "the default screen" a second time and risking a different
    -> answer between the two calls.
    pubscr := NIL
    IF curcon.pscrname[0]
      pubscr := LockPubScreen(curcon.pscrname)
    ELSEIF (curcon.pww = -1) OR (curcon.pwh = -1)
      pubscr := LockPubScreen(NIL)
    ENDIF
    -> his ask, 19.7.26: WIDTH/HEIGHT=-1 fills the screen he's
    -> opening on. A failed lock (named screen gone, or the
    -> default somehow unavailable) falls back to a sane fixed
    -> size rather than leaving the -1 sentinel to hit the floor
    -> clamps below and open as a tiny 160x60 window instead.
    IF pubscr
      IF curcon.pww = -1 THEN curcon.pww := pubscr.width
      IF curcon.pwh = -1 THEN curcon.pwh := pubscr.height
    ENDIF
    IF curcon.pww = -1 THEN curcon.pww := 640
    IF curcon.pwh = -1 THEN curcon.pwh := 200
    IF curcon.pww < 160 THEN curcon.pww := 160
    IF curcon.pwh < 60 THEN curcon.pwh := 60
    curcon.win := OpenWindowTagList(NIL,
      [WA_TITLE, curcon.wtitlebase, WA_LEFT, curcon.pwx, WA_TOP, curcon.pwy,
       WA_WIDTH, curcon.pww, WA_HEIGHT, curcon.pwh,
       WA_DRAGBAR, IF curcon.pnodrag THEN FALSE ELSE TRUE,
       WA_DEPTHGADGET, IF curcon.pnodepth THEN FALSE ELSE TRUE,
       WA_ACTIVATE, IF curcon.pinactive THEN FALSE ELSE TRUE,
       WA_CLOSEGADGET, curcon.closegad,
       WA_SIZEGADGET, IF curcon.pnosize THEN FALSE ELSE TRUE,
       WA_BORDERLESS, curcon.pnoborder,
       WA_BACKDROP, curcon.pbackdrop,
       WA_PUBSCREEN, pubscr,
       WA_MINWIDTH, 160, WA_MINHEIGHT, 60,
       WA_MAXWIDTH, -1, WA_MAXHEIGHT, -1,
       WA_IDCMP, idc,
       TAG_DONE, NIL])
    IF pubscr THEN UnlockPubScreen(NIL, pubscr)
  ENDIF
  IF curcon.win = NIL THEN RETURN
  curcon.rp := curcon.win.rport
  IF curcon.fwin = FALSE
    -> topaz 8: a ROM font - OpenFont sends no packets, OpenDiskFont
    -> would not be safe. A BORROWED window keeps the font its owner
    -> set on the rastport (CTerm's frame carries MicroKnight).
    -> v1.1 FONT: fontload goes to DISK through the helper process
    -> (v1.1b2 - loaded-only proved useless the first minute: 3.2
    -> keeps even topaz 9 on disk now). A name nowhere to be found,
    -> or a proportional face (the grid needs fixed cells), falls
    -> back to topaz 8 silently.
    NEW ta
    ta.name := 'topaz.font'
    ta.ysize := 8
    ta.style := 0
    ta.flags := 0
    IF curcon.pfontname[0]
      fl := StrLen(curcon.pfontname)
      CopyMem(curcon.pfontname, fname, fl + 1)
      ok := FALSE                -> ".font" appended unless present
      IF fl >= 5
        IF (fname[fl - 5] = ".") AND (tcfold(fname[fl - 4]) = "F") AND
           (tcfold(fname[fl - 3]) = "O") AND (tcfold(fname[fl - 2]) = "N") AND
           (tcfold(fname[fl - 1]) = "T") THEN ok := TRUE
      ENDIF
      IF ok = FALSE THEN CopyMem('.font', fname + fl, 6)
      ta.name := fname
      ta.ysize := IF curcon.pfontsize > 0 THEN curcon.pfontsize ELSE 8
      curcon.tf := fontload(ta)
      IF curcon.tf
        IF curcon.tf.flags AND $20     -> FPF_PROPORTIONAL: the grid
          CloseFont(curcon.tf)         -> needs fixed cells
          curcon.tf := NIL
        ENDIF
      ENDIF
      IF curcon.tf = NIL
        ta.name := 'topaz.font'
        ta.ysize := 8
      ENDIF
    ELSE
      -> no FONT option (v1.1): the user's Font Prefs "System
      -> Default Text" font - GfxBase DefaultFont, exactly what
      -> stock CON: honors and 1.1b hardcoded past. The system
      -> holds it open and IN MEMORY, so plain OpenFont reopens it
      -> by name/size - no helper needed. Unusable (proportional,
      -> or the reopen fails) drops to topaz 8, his spec.
      gfx := gfxbase
      dfont := gfx.defaultfont
      IF dfont
        mnode := dfont              -> tf_Message.mn_Node.ln_Name
        ta.name := mnode.ln.name
        ta.ysize := dfont.ysize
        curcon.tf := OpenFont(ta)
        IF curcon.tf
          IF curcon.tf.flags AND $20     -> FPF_PROPORTIONAL
            CloseFont(curcon.tf)
            curcon.tf := NIL
          ENDIF
        ENDIF
      ENDIF
      IF curcon.tf = NIL
        ta.name := 'topaz.font'
        ta.ysize := 8
      ENDIF
    ENDIF
    IF curcon.tf = NIL THEN curcon.tf := OpenFont(ta)
    IF curcon.tf THEN SetFont(curcon.rp, curcon.tf)
  ENDIF
  curcon.cw := curcon.rp.txwidth
  curcon.ch := curcon.rp.txheight
  curcon.baseline := curcon.rp.txbaseline
  -> v1.1 styles: what italic/underline the rastport can fake on
  -> this font (borrowed windows measured too)
  curcon.softmask := AskSoftStyle(curcon.rp)
  curcon.cursoft := 0
  gridcalc()
  -> the scrollback ring + its attr and style planes: sized to the
  -> real grid width. New() zeroes (E heap is cleared), so the model
  -> starts as blank rows with attr 0; a failed allocation just
  -> disables scrollback, the console still runs. v1.1: LINES=n is
  -> the depth knob (a 2MB machine can ask for a shallow ring where
  -> 1.0 hardcoded 4000 lines - and the style plane is the third
  -> byte per cell that knob pays for). Floor 100: the visible grid
  -> must always fit inside the ring.
  v := curcon.plines
  IF v = 0 THEN v := SBMAX
  IF v < 100 THEN v := 100
  IF v > SBMAXCAP THEN v := SBMAXCAP
  curcon.sbmax := v
  curcon.sb := New(Mul(curcon.sbmax, curcon.cols))
  curcon.sa := New(Mul(curcon.sbmax, curcon.cols))
  curcon.ss := New(Mul(curcon.sbmax, curcon.cols))
  IF (curcon.sb = NIL) OR (curcon.sa = NIL) OR (curcon.ss = NIL)
    IF curcon.sb THEN Dispose(curcon.sb)
    IF curcon.sa THEN Dispose(curcon.sa)
    IF curcon.ss THEN Dispose(curcon.ss)
    curcon.sb := NIL
    curcon.sa := NIL
    curcon.ss := NIL
  ENDIF
  curcon.sbtop := 0
  curcon.sbcnt := 0
  curcon.viewoff := 0
  -> SGR ground state; bright pens exist when the screen is deep
  -> enough (rp.bitmap is the screen's for a normal window)
  curcon.can16 := FALSE
  IF curcon.rp.bitmap
    IF curcon.rp.bitmap.depth >= 4 THEN curcon.can16 := TRUE
  ENDIF
  -> the ANSI/WB separation (the two colour worlds must not share
  -> pen numbers): WBPENS in the open name declares the screen's
  -> palette truly ANSI (CTerm sends it) and the pen conventions
  -> apply as-is. On any OTHER screen the pens mean whatever the
  -> user's palette says, so ANSI colour INTENT - the bold+3x
  -> forms ls uses - is translated by COLOUR instead:
  -> ObtainBestPen picks the screen's closest real match for each
  -> bright ANSI colour. Plain 3x stays raw pens there (stock
  -> console semantics - what Ed and every WB-pen program wants).
  -> Pens above 15 will not fit the attr plane's nibble and are
  -> released on the spot; -1 falls back to the default pen.
  curcon.anscm := NIL
  FOR i := 0 TO 7
    curcon.anstab[i] := -1             -> E global arrays start as garbage
  ENDFOR
  IF curcon.wbpens = FALSE
    -> the bright half of the CTerm palette, one nibble per gun
    pr := [$5, $F, $5, $F, $8, $F, $5, $F]:CHAR
    pg := [$5, $5, $F, $F, $8, $5, $F, $F]:CHAR
    pb := [$5, $5, $5, $5, $F, $F, $F, $F]:CHAR
    scrn := curcon.win.wscreen
    IF scrn
      curcon.anscm := scrn.viewport.colormap
      IF curcon.anscm
        FOR i := 0 TO 7
          v := ObtainBestPenA(curcon.anscm,
                 Mul(pr[i], $11111111),
                 Mul(pg[i], $11111111),
                 Mul(pb[i], $11111111), NIL)
          IF v > 15
            ReleasePen(curcon.anscm, v)
            v := -1
          ENDIF
          curcon.anstab[i] := v
        ENDFOR
      ENDIF
    ENDIF
  ENDIF
  curcon.curfg := curcon.deffg
  curcon.curbg := 0
  curcon.bold := FALSE
  curcon.cursgr := FALSE
  curcon.cursty := 0
  curcon.oscn := 0
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
  -> a fresh console: every per-window state starts over
  curcon.cx := 0
  curcon.cy := 0
  curcon.ancx := 0
  curcon.ancy := 0
  curcon.inqh := 0
  curcon.inqt := 0
  curcon.cesc := 0
  curcon.eofpend := FALSE
  curcon.rawmode := FALSE
  curcon.evmask := 0
  curcon.tcactive := FALSE
  curcon.tcsel := -1
  curcon.cpos := 0
  curcon.hpos := -1
  StrCopy(curcon.ebuf, '')
  curcon.rawmode := rawdef             -> the CRAW: device opens raw
  curcon.autopend := FALSE             -> an AUTO wait ends here
  IF curcon.rawmode
    cursdraw()                  -> raw: the block cursor at home
  ELSE
    drawedit()                  -> the blip stands from the start
  ENDIF
  setidcmp()                    -> selection's MOUSEBUTTONS joins the
  ReportMouse(TRUE, curcon.win)        -> set (evmask is 0 here) and motion
                                -> events exist when a drag asks
  -> armed last: the chain handler takes nothing until the per-window
  -> state above is fully rebuilt (conbywin checks this flag)
  curcon.armed := TRUE
ENDPROC

-> real close semantics (M5c): pending reads answer EOF, pending
-> WAIT_CHARs answer FALSE, the model is returned to the heap, and a
-> borrowed window goes back to its owner with its IDCMP restored
PROC closewin()
  DEF i
  IF curcon.win = NIL
    -> a windowless console (an AUTO whose open failed) can still
    -> hold parked packets - they MUST be replied before the console
    -> memory goes away, or their senders hang forever
    IF timercon = curcon
      canceltimer()
      timercon := NIL
    ENDIF
    WHILE curcon.wcn > 0
      curcon.wcn := curcon.wcn - 1
      ReplyPkt(curcon.wcq[curcon.wcn], DOSFALSE, 0)
    ENDWHILE
    WHILE curcon.rdn > 0
      curcon.rdn := curcon.rdn - 1
      ReplyPkt(curcon.rdq[curcon.rdn], 0, 0)
    ENDWHILE
    RETURN
  ENDIF
  curcon.armed := FALSE         -> disarm the chain handler FIRST;
                                -> its captured leftovers are scrubbed
                                -> by conclose (other consoles' events
                                -> stay in the ring untouched now)
  curcon.cursx := -1                   -> the window takes the cursor with it
  curcon.selon := FALSE                -> a drag dies with the window; parked
  curcon.sello := -1                   -> writers MUST be replied or their
  curcon.selhi := -1                   -> tasks hang forever
  flushwq()
  IF timercon = curcon          -> the timer may be serving another
    canceltimer()               -> console's waiters - leave it be
    timercon := NIL             -> then (conclose rearms after us)
  ENDIF
  WHILE curcon.wcn > 0
    curcon.wcn := curcon.wcn - 1
    ReplyPkt(curcon.wcq[curcon.wcn], DOSFALSE, 0)
  ENDWHILE
  WHILE curcon.rdn > 0
    curcon.rdn := curcon.rdn - 1
    ReplyPkt(curcon.rdq[curcon.rdn], 0, 0)
  ENDWHILE
  curcon.tcactive := FALSE
  curcon.tcsel := -1
  -> obtained ANSI pens go back to the screen with the window
  IF curcon.anscm
    FOR i := 0 TO 7
      IF curcon.anstab[i] >= 0 THEN ReleasePen(curcon.anscm, curcon.anstab[i])
      curcon.anstab[i] := -1
    ENDFOR
    curcon.anscm := NIL
  ENDIF
  IF curcon.fwin
    ReportMouse(FALSE, curcon.win)     -> hand the flag back the way the
    ModifyIDCMP(curcon.win, curcon.oldidcmp)  -> owner had it
  ELSE
    CloseWindow(curcon.win)
  ENDIF
  curcon.win := NIL
  curcon.rp := NIL
  curcon.fwin := FALSE
  IF curcon.tf
    CloseFont(curcon.tf)
    curcon.tf := NIL
  ENDIF
  IF curcon.sb
    Dispose(curcon.sb)
    curcon.sb := NIL
  ENDIF
  IF curcon.sa
    Dispose(curcon.sa)
    curcon.sa := NIL
  ENDIF
  IF curcon.ss
    Dispose(curcon.ss)
    curcon.ss := NIL
  ENDIF
  altdrop()                     -> the snapshot dies with the window
  curcon.eofpend := FALSE
  curcon.rawmode := FALSE
  curcon.evmask := 0
ENDPROC

-> M8: the window has a new size (the gadget, or a borrowed
-> window's owner resized). The grid is recomputed and the
-> scrollback model follows: the ring is cols-stride, so a width
-> change reallocates it and row-copies the old content - rows
-> stay rows, no reflow, same as the rest of the console family.
-> A height loss scrolls the tail into history; everything
-> repaints from the model, and a raw-events client that asked
-> for class 12 (Ed does, CSI 12{) gets the report and
-> re-measures itself.
PROC doresize()
  DEF oc, nsb:PTR TO CHAR, nsa:PTR TO CHAR, nss:PTR TO CHAR, r, n,
      evb[8]:ARRAY OF LONG, e:PTR TO ihev
  IF curcon.win = NIL THEN RETURN
  altdrop()                     -> a resize orphans the raw snapshot
  tcclose()                     -> restores rows at the OLD geometry
  clearsel()
  curcon.selon := FALSE                -> a drag dies with the old grid
  curcon.cursx := -1                   -> a full repaint follows anyway
  curcon.viewoff := 0
  oc := curcon.cols
  gridcalc()
  IF curcon.sb
    IF curcon.cols <> oc
      nsb := New(Mul(curcon.sbmax, curcon.cols))
      nsa := New(Mul(curcon.sbmax, curcon.cols))
      nss := New(Mul(curcon.sbmax, curcon.cols))
      IF (nsb = NIL) OR (nsa = NIL) OR (nss = NIL)
        IF nsb THEN Dispose(nsb)
        IF nsa THEN Dispose(nsa)
        IF nss THEN Dispose(nss)
        Dispose(curcon.sb)             -> degraded: the console runs on
        Dispose(curcon.sa)             -> without scrollback rather than
        Dispose(curcon.ss)             -> rendering through a wrong-
        curcon.sb := NIL               -> stride model
        curcon.sa := NIL
        curcon.ss := NIL
      ELSE
        n := Min(oc, curcon.cols)
        FOR r := 0 TO curcon.sbmax - 1
          CopyMem(curcon.sb + Mul(r, oc), nsb + Mul(r, curcon.cols), n)
          CopyMem(curcon.sa + Mul(r, oc), nsa + Mul(r, curcon.cols), n)
          CopyMem(curcon.ss + Mul(r, oc), nss + Mul(r, curcon.cols), n)
        ENDFOR
        Dispose(curcon.sb)
        Dispose(curcon.sa)
        Dispose(curcon.ss)
        curcon.sb := nsb
        curcon.sa := nsa
        curcon.ss := nss
      ENDIF
    ENDIF
  ENDIF
  IF curcon.cx > curcon.cols THEN curcon.cx := curcon.cols  -> cols itself = pending wrap, legal
  WHILE curcon.cy > (curcon.rows - 1)         -> height shrank: the rows above the
    curcon.sbtop := curcon.sbtop + 1                     -> cursor scroll into history
    IF curcon.sbtop >= curcon.sbmax THEN curcon.sbtop := 0
    IF curcon.sbcnt < (curcon.sbmax - curcon.rows) THEN curcon.sbcnt := curcon.sbcnt + 1
    curcon.cy := curcon.cy - 1
    IF curcon.ancy > 0 THEN curcon.ancy := curcon.ancy - 1
  ENDWHILE
  IF curcon.ancx > (curcon.cols - 1) THEN curcon.ancx := curcon.cols - 1
  IF curcon.ancy > (curcon.rows - 1) THEN curcon.ancy := curcon.rows - 1
  SetAPen(curcon.rp, 0)                -> clear the inner window (margins
  RectFill(curcon.rp, curcon.win.borderleft, curcon.win.bordertop,  -> included), then
           curcon.win.width - curcon.win.borderright - 1,    -> repaint from the
           curcon.win.height - curcon.win.borderbottom - 1)  -> model
  SetAPen(curcon.rp, curcon.deffg)
  redraw()
  settitle()
  IF curcon.rawmode
    cursdraw()
  ELSE
    drawedit()
  ENDIF
  IF curcon.evmask AND Shl(1, IECLASS_SIZEWINDOW)
    e := evb
    e.cls := IECLASS_SIZEWINDOW
    e.sub := 0
    e.code := 0
    e.qual := 0
    e.addr := curcon.win
    e.secs := 0
    e.mics := 0
    ihreport(e)
  ENDIF
  flushwq()                     -> any writers parked by a dying drag
ENDPROC

-> the close gadget: EOF to the reader (stock CON: CLOSE semantics);
-> a lingering WAIT window (no opens left) dies on the click. The
-> actual CloseWindow is deferred past the event drain (closereq).
PROC doclosew()
  IF curcon.opens <= 0
    curcon.closereq := TRUE
  ELSE
    curcon.eofpend := TRUE
    satisfyreads()
  ENDIF
ENDPROC

-> ---------- the scrollback model (M5) ----------

-> pointer to the model row of visible screen row r (0 = top row).
-> Callers guard with IF sb - a NIL model means scrollback is off.
PROC visrow(r)
  DEF i
  i := curcon.sbtop + r
  IF i >= curcon.sbmax THEN i := i - curcon.sbmax
ENDPROC curcon.sb + Mul(i, curcon.cols)

-> the attr-plane twin of visrow
PROC sarow(r)
  DEF i
  i := curcon.sbtop + r
  IF i >= curcon.sbmax THEN i := i - curcon.sbmax
ENDPROC curcon.sa + Mul(i, curcon.cols)

-> the style-plane twin (v1.1): bit0 italic, bit1 underline,
-> bit2 inverse - allocated with sb/sa, all three or none
PROC ssrow(r)
  DEF i
  i := curcon.sbtop + r
  IF i >= curcon.sbmax THEN i := i - curcon.sbmax
ENDPROC curcon.ss + Mul(i, curcon.cols)

-> the pen SGR state draws with right now. On an ANSI screen
-> (WBPENS) bold lifts the 8 base colours to the bright pens; on
-> any other screen bold+explicit-3x goes through the
-> ObtainBestPen table instead (real colours on the user's
-> palette), and bare bold recolours nothing.
PROC fgpen()
  IF curcon.bold AND (curcon.curfg < 8)
    IF curcon.wbpens
      IF curcon.can16 THEN RETURN curcon.curfg + 8
    ELSEIF curcon.cursgr
      IF curcon.anstab[curcon.curfg] >= 0 THEN RETURN curcon.anstab[curcon.curfg]
    ENDIF
  ENDIF
ENDPROC curcon.curfg

PROC curattr() IS fgpen() OR Shl(curcon.curbg, 4)

-> v1.1 soft styles: point the rastport at a cell's style bits only
-> when they change (SetSoftStyle is a call per run otherwise).
-> bit0 italic -> FSF_ITALIC ($4), bit1 underline -> FSF_UNDERLINED
-> ($1); bit2 inverse is a pen swap at paint time, not a font style.
PROC setsoft(sty)
  DEF w
  w := 0
  IF sty AND 1 THEN w := w OR $4
  IF sty AND 2 THEN w := w OR $1
  w := w AND curcon.softmask
  IF w <> curcon.cursoft
    SetSoftStyle(curcon.rp, w, curcon.softmask)
    curcon.cursoft := w
  ENDIF
ENDPROC

-> live-output pens from the SGR state: inverse (SGR 7) swaps
PROC setpens()
  IF curcon.cursty AND 4
    SetAPen(curcon.rp, curcon.curbg)
    SetBPen(curcon.rp, fgpen())
  ELSE
    SetAPen(curcon.rp, fgpen())
    SetBPen(curcon.rp, curcon.curbg)
  ENDIF
ENDPROC

PROC clearrow(r)
  DEF i, m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR
  m := visrow(r)
  a := sarow(r)
  stp := ssrow(r)
  FOR i := 0 TO curcon.cols - 1
    m[i] := 0
    a[i] := 0
    stp[i] := 0
  ENDFOR
ENDPROC

-> paint one MODEL ring row (by ring index) at pixel row y, in
-> attr-batched runs - the piece redraw, drawmodelrow and the menu
-> restore share, and where the colours come back from
PROC drawmrow(idx, y)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, i, j, at, c, sy,
      fg, bg, rowbuf[256]:ARRAY OF CHAR
  m := curcon.sb + Mul(idx, curcon.cols)
  a := curcon.sa + Mul(idx, curcon.cols)
  stp := curcon.ss + Mul(idx, curcon.cols)
  FOR i := 0 TO curcon.cols - 1
    c := m[i]
    rowbuf[i] := IF c < 32 THEN 32 ELSE c
  ENDFOR
  i := 0
  WHILE i < curcon.cols
    at := a[i]
    sy := stp[i]
    j := i
    WHILE (j < curcon.cols) AND (a[j] = at) AND (stp[j] = sy)
      j++
    ENDWHILE
    fg := at AND 15
    bg := Shr(at, 4) AND 7
    IF sy AND 4                 -> inverse cell: the drawselrow swap
      IF fg = bg THEN fg := curcon.deffg
      SetAPen(curcon.rp, bg)
      SetBPen(curcon.rp, fg)
    ELSE
      SetAPen(curcon.rp, fg)
      SetBPen(curcon.rp, bg)
    ENDIF
    setsoft(sy)
    Move(curcon.rp, curcon.left + Mul(i, curcon.cw), y + curcon.baseline)
    Text(curcon.rp, rowbuf + i, j - i)
    i := j
  ENDWHILE
  setsoft(0)
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
  DEF m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, x, c, at, sy,
      fg, bg, t, b[2]:ARRAY OF CHAR
  IF (curcon.win = NIL) OR (curcon.sb = NIL) OR (curcon.viewoff > 0) THEN RETURN
  x := IF curcon.cx >= curcon.cols THEN curcon.cols - 1 ELSE curcon.cx
  m := visrow(curcon.cy)
  a := sarow(curcon.cy)
  stp := ssrow(curcon.cy)
  c := m[x]
  b[0] := IF c < 32 THEN 32 ELSE c
  at := a[x]
  sy := stp[x]
  fg := at AND 15
  bg := Shr(at, 4) AND 7
  IF sy AND 4                   -> an inverse cell shows its EFFECTIVE
    t := fg                     -> video first; the cursor inverts that
    fg := bg
    bg := t
  ENDIF
  IF fg = bg THEN fg := curcon.deffg
  SetAPen(curcon.rp, bg)               -> inverse video: glyph in the cell's
  SetBPen(curcon.rp, fg)               -> background, block in its foreground
  setsoft(sy)
  Move(curcon.rp, curcon.left + Mul(x, curcon.cw), curcon.topy + Mul(curcon.cy, curcon.ch) + curcon.baseline)
  Text(curcon.rp, b, 1)
  setsoft(0)
  curcon.cursx := x
  curcon.cursy := curcon.cy
ENDPROC

PROC curserase()
  DEF m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, c, at, sy,
      fg, bg, t, b[2]:ARRAY OF CHAR
  IF curcon.cursx < 0 THEN RETURN
  IF curcon.win AND curcon.sb
    m := visrow(curcon.cursy)
    a := sarow(curcon.cursy)
    stp := ssrow(curcon.cursy)
    c := m[curcon.cursx]
    b[0] := IF c < 32 THEN 32 ELSE c
    at := a[curcon.cursx]
    sy := stp[curcon.cursx]
    fg := at AND 15
    bg := Shr(at, 4) AND 7
    IF sy AND 4                 -> the cell exactly as drawmrow paints
      t := fg
      fg := bg
      bg := t
      IF fg = bg THEN fg := curcon.deffg
    ENDIF
    SetAPen(curcon.rp, fg)
    SetBPen(curcon.rp, bg)
    setsoft(sy)
    Move(curcon.rp, curcon.left + Mul(curcon.cursx, curcon.cw), curcon.topy + Mul(curcon.cursy, curcon.ch) + curcon.baseline)
    Text(curcon.rp, b, 1)
    setsoft(0)
  ENDIF
  curcon.cursx := -1
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
  i := curcon.sbtop - curcon.selvo + r
  IF i < 0 THEN i := i + curcon.sbmax
  IF i >= curcon.sbmax THEN i := i - curcon.sbmax
ENDPROC i

-> the mouse position as a linear cell (row*cols+x); -1 = off-grid
PROC cellat()
  DEF mx, my, x, r
  IF curcon.win = NIL THEN RETURN -1
  mx := curcon.win.mousex - curcon.left
  my := curcon.win.mousey - curcon.topy
  IF (mx < 0) OR (my < 0) THEN RETURN -1
  x := mx / curcon.cw                  -> cell metrics are single digits -
  r := my / curcon.ch                  -> DIVU-safe
  IF (x >= curcon.cols) OR (r >= curcon.rows) THEN RETURN -1
ENDPROC Mul(r, curcon.cols) + x

-> paint one view row like drawmrow, but cells inside [lo,hi) draw
-> inverse video (fg=bg empties get deffg, the block-cursor rule)
PROC drawselrow(r, lo, hi)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, i, j, at, c, s,
      sy, sw, fg, bg, base, y, rowbuf[256]:ARRAY OF CHAR
  m := curcon.sb + Mul(selvidx(r), curcon.cols)
  a := curcon.sa + Mul(selvidx(r), curcon.cols)
  stp := curcon.ss + Mul(selvidx(r), curcon.cols)
  y := curcon.topy + Mul(r, curcon.ch)
  base := Mul(r, curcon.cols)
  FOR i := 0 TO curcon.cols - 1
    c := m[i]
    rowbuf[i] := IF c < 32 THEN 32 ELSE c
  ENDFOR
  i := 0
  WHILE i < curcon.cols
    at := a[i]
    sy := stp[i]
    s := ((base + i) >= lo) AND ((base + i) < hi)
    j := i
    WHILE (j < curcon.cols) AND (a[j] = at) AND (stp[j] = sy) AND
          ((((base + j) >= lo) AND ((base + j) < hi)) = s)
      j++
    ENDWHILE
    fg := at AND 15
    bg := Shr(at, 4) AND 7
    sw := s
    IF sy AND 4 THEN sw := (sw = FALSE)  -> selection over an inverse
                                         -> cell re-inverts (xterm)
    IF sw
      IF fg = bg THEN fg := curcon.deffg
      SetAPen(curcon.rp, bg)
      SetBPen(curcon.rp, fg)
    ELSE
      SetAPen(curcon.rp, fg)
      SetBPen(curcon.rp, bg)
    ENDIF
    setsoft(sy)
    Move(curcon.rp, curcon.left + Mul(i, curcon.cw), y + curcon.baseline)
    Text(curcon.rp, rowbuf + i, j - i)
    i := j
  ENDWHILE
  setsoft(0)
ENDPROC

-> repaint view rows rmin..rmax against selection [lo,hi)
PROC selrepaint(rmin, rmax, lo, hi)
  DEF r
  IF curcon.sb = NIL THEN RETURN
  curserase()
  IF rmin < 0 THEN rmin := 0
  IF rmax > (curcon.rows - 1) THEN rmax := curcon.rows - 1
  FOR r := rmin TO rmax
    drawselrow(r, lo, hi)
  ENDFOR
  IF curcon.rawmode THEN cursdraw()
ENDPROC

-> drop the standing highlight (any output, any key, a fresh click)
PROC clearsel()
  DEF lo
  IF curcon.sello >= 0
    lo := curcon.sello
    curcon.sello := -1
    IF curcon.viewoff = curcon.selvo THEN selrepaint(lo / curcon.cols, (curcon.selhi - 1) / curcon.cols, 0, 0)
    curcon.selhi := -1                 -> (a scrolled view was repainted by
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
  IF curcon.win = NIL THEN RETURN
  idc := IDCMP_CLOSEWINDOW OR IDCMP_NEWSIZE
  IF ihon = FALSE
    idc := idc OR IDCMP_RAWKEY OR IDCMP_VANILLAKEY OR IDCMP_MENUPICK
  ENDIF
  IF (curcon.evmask AND Shl(1, IECLASS_RAWMOUSE)) = 0
    idc := idc OR IDCMP_MOUSEBUTTONS
    IF curcon.selon THEN idc := idc OR IDCMP_MOUSEMOVE
  ENDIF
  ModifyIDCMP(curcon.win, idc)
ENDPROC

-> the selection machine: one IDCMP mouse message (cd = the code:
-> SELECTDOWN $68, SELECTUP $E8, or $FF for a MOUSEMOVE). Positions
-> come from the window NOW, not the message - coarse under a fast
-> drag, and exactly what Ed's own class-2 handler does.
-> a run of quick clicks on the same row escalates the selection:
-> one = drag anchor as ever, two = the word under the pointer,
-> three = the whole line - xterm manners, DoubleClick() timing
-> (the user's own prefs), copy on the spot with no release needed
PROC selclicks(c)
  DEF r, x, x0, x1, m:PTR TO CHAR, sp, base
  r := c / curcon.cols
  x := c - Mul(r, curcon.cols)
  base := Mul(r, curcon.cols)
  curcon.selvo := curcon.viewoff
  m := curcon.sb + Mul(selvidx(r), curcon.cols)
  IF curcon.dccnt = 2
    -> the word: the run of the clicked cell's class - text selects
    -> text, a click in whitespace selects the gap
    sp := m[x] <= 32
    x0 := x
    WHILE (x0 > 0) AND ((m[x0 - 1] <= 32) = sp)
      x0--
    ENDWHILE
    x1 := x
    WHILE (x1 < (curcon.cols - 1)) AND ((m[x1 + 1] <= 32) = sp)
      x1++
    ENDWHILE
    curcon.sello := base + x0
    curcon.selhi := base + x1 + 1
  ELSE
    curcon.sello := base       -> the whole line; selcopy trims the
    curcon.selhi := base + curcon.cols  -> trailing blanks anyway
  ENDIF
  selrepaint(r, r, curcon.sello, curcon.selhi)
  selcopy()
ENDPROC

PROC selmouse(cd, csec, cmic)
  DEF c, lo, hi, plo, phi, r
  IF curcon.sb = NIL THEN RETURN       -> no model, no selection
  IF cd = IECODE_LBUTTON
    clearsel()
    IF (curcon.rawmode = FALSE) AND curcon.tcactive THEN tcclose()
    c := cellat()
    IF c >= 0
      r := c / curcon.cols
      IF DoubleClick(curcon.dcsec, curcon.dcmic, csec, cmic) AND
         (r = curcon.dcrow)
        curcon.dccnt := curcon.dccnt + 1
        IF curcon.dccnt > 3 THEN curcon.dccnt := 3
      ELSE
        curcon.dccnt := 1
      ENDIF
      curcon.dcsec := csec
      curcon.dcmic := cmic
      curcon.dcrow := r
      IF curcon.dccnt >= 2
        selclicks(c)            -> word/line select + copy; no drag
      ELSE
        curcon.selon := TRUE
        curcon.selvo := curcon.viewoff
        curcon.selanc := c
        curcon.selcur := c
        setidcmp()              -> motion reports on for the drag
      ENDIF
    ENDIF
  ELSEIF cd = (IECODE_LBUTTON OR IECODE_UP_PREFIX)
    IF curcon.selon
      curcon.selon := FALSE
      setidcmp()                -> and off again
      IF curcon.selcur <> curcon.selanc
        curcon.sello := Min(curcon.selanc, curcon.selcur)
        curcon.selhi := Max(curcon.selanc, curcon.selcur) + 1
        selcopy()               -> release = copy, no extra keystroke
      ELSE
        selrepaint(curcon.selanc / curcon.cols, curcon.selanc / curcon.cols, 0, 0)
      ENDIF
      flushwq()                 -> the parked writers resume
    ENDIF
  ELSEIF cd = IECODE_NOBUTTON
    IF curcon.selon
      c := cellat()
      IF (c >= 0) AND (c <> curcon.selcur)
        plo := Min(curcon.selanc, curcon.selcur)
        phi := Max(curcon.selanc, curcon.selcur)
        curcon.selcur := c
        lo := Min(curcon.selanc, curcon.selcur)
        hi := Max(curcon.selanc, curcon.selcur)
        selrepaint(Min(lo, plo) / curcon.cols, Max(hi, phi) / curcon.cols, lo, hi + 1)
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
  IF curcon.sb = NIL THEN RETURN
  IF clipopen() = FALSE THEN RETURN
  p := clipbuf + 20             -> text starts after the IFF headers
  len := 0
  r0 := curcon.sello / curcon.cols
  r1 := (curcon.selhi - 1) / curcon.cols
  FOR r := r0 TO r1
    base := Mul(r, curcon.cols)
    x0 := Max(curcon.sello - base, 0)
    x1 := Min(curcon.selhi - base, curcon.cols)
    m := curcon.sb + Mul(selvidx(r), curcon.cols)
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
-> inject it as typed input. Raw hands the client the bytes as they
-> are, byte-faithful, always - a raw client (Ed) owns its own
-> screen, there is no "line" for a paste to prematurely commit.
-> Cooked is the safety question: forceexec (RAMIGA+SHIFT+V) or the
-> PASTEEXEC open option replay every LF as a Return, 1.0-style,
-> each pasted line running the instant it lands - the DEFAULT now
-> is safer (his call, Theme B): the WHOLE clip lands live as one
-> long, fully editable line (embedded newlines shown as a PASTENL
-> pilcrow, real Return/Backspace/kill keys all just work - see
-> pasteinsert), and NONE of it runs until a real Enter commits it,
-> at which point it all runs at once, in order, like any terminal
-> paste - so a pasted `rm important-file` sits there to be seen
-> and edited out, not executed before you can react.
PROC dopaste(forceexec)
  DEF got, i, id, sz, take, c, scr[32]:ARRAY OF CHAR,
      lw:PTR TO LONG, b:PTR TO CHAR, exec
  IF curcon.selon THEN RETURN
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
  exec := forceexec OR curcon.rawmode OR curcon.pasteexec
  i := 12
  WHILE (i + 8) <= got
    lw := clipbuf + i
    id := lw[0]
    sz := lw[1]
    IF id = $43485253           -> CHRS: inject its text
      b := clipbuf + i + 8
      take := Min(sz, got - i - 8)
      IF exec
        FOR c := 0 TO take - 1
          injectbyte(b[c])
        ENDFOR
      ELSE
        pasteinsert(b, take)
      ENDIF
    ENDIF
    i := i + 8 + sz + (sz AND 1)
  ENDWHILE
  IF exec
    IF curcon.rawmode THEN inputarrived()
  ELSE
    drawedit()                  -> pasteinsert never draws itself -
  ENDIF                         -> one clean paint after the whole
                                -> clip is in, not one per line
ENDPROC

PROC injectbyte(c)
  IF curcon.rawmode
    enqueue(c)                  -> the client sees paste as input
  ELSE
    IF c = 10 THEN c := 13      -> LF = Return to the line editor
    dovanilla(c, 0)
  ENDIF
ENDPROC

-> safe-paste insert: the WHOLE clip becomes literal text at the
-> cursor in one go - NOT via dovanilla, deliberately: a pasted
-> Tab/Ctrl-R/Esc byte must never trigger completion or search or a
-> line-clear, it should just be an odd-looking literal character,
-> the same way a stray control byte typed by hand would be if this
-> codepath ever saw it. An embedded LF becomes PASTENL (a pilcrow,
-> chosen as a byte vanishingly unlikely to appear in real command
-> text) rather than a raw newline - reusing the ALREADY-CORRECT
-> width-wrap editing model unchanged (edcap/edlastrow have never
-> heard of a newline, and teaching them one meant reopening the
-> exact eraseedit/drawedit machinery that took three fixes to get
-> right earlier tonight). The whole pasted block is fully visible
-> and fully editable - cursor movement, Backspace, kill keys, all
-> of it - as one long line that wraps by width like any other.
-> pasteundo() reverses the substitution at commit time, so what
-> actually RUNS still has real newlines in it.
PROC pasteinsert(b:PTR TO CHAR, take)
  DEF s:PTR TO CHAR, l, cap, k, c, j
  s := curcon.ebuf
  l := StrLen(s)
  cap := edcap()
  FOR k := 0 TO take - 1
    c := b[k]
    IF c = 10 THEN c := PASTENL
    IF ((c >= 32) AND (c <= 126)) OR (c >= 160)
      IF l < cap
        FOR j := l - 1 TO curcon.cpos STEP -1
          s[j + 1] := s[j]
        ENDFOR
        s[curcon.cpos] := c
        l := l + 1
        curcon.cpos := curcon.cpos + 1
      ENDIF
    ENDIF
  ENDFOR
  SetStr(curcon.ebuf, l)
ENDPROC

-> reverse pasteinsert's substitution on a committed line: PASTENL
-> back to a real LF, in place. Called right before a commit is
-> echoed/enqueued, never before - the edit line itself keeps
-> showing the pilcrow right up to the moment it actually runs.
PROC pasteundo(s:PTR TO CHAR, l)
  DEF i
  FOR i := 0 TO l - 1
    IF s[i] = PASTENL THEN s[i] := 10
  ENDFOR
ENDPROC

-> redraw the whole grid from the model at the current view offset;
-> model zeroes render as spaces. viewoff = lines back, 0 = live.
PROC redraw()
  DEF r, idx
  IF curcon.sb = NIL THEN RETURN
  FOR r := 0 TO curcon.rows - 1
    idx := curcon.sbtop - curcon.viewoff + r
    IF idx < 0 THEN idx := idx + curcon.sbmax
    IF idx >= curcon.sbmax THEN idx := idx - curcon.sbmax
    drawmrow(idx, curcon.topy + Mul(r, curcon.ch))
  ENDFOR
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
ENDPROC

-> the title bar doubles as the scroll-position indicator. The buffer
-> is a global: Intuition keeps the POINTER (the M4 telemetry lesson).
-> v1.1 closes the 1.0 cosmetic gap: a title that is not ours on the
-> window (More finds the window via DISK_INFO and SetWindowTitles
-> it DIRECTLY) is adopted as the new base first, so the scrollback
-> and search suffixes append to a client retitle instead of
-> stomping it on the next view flip.
PROC settitle()
  DEF t:PTR TO CHAR
  IF curcon.fwin THEN RETURN   -> a borrowed window keeps its owner's title
  IF curcon.win
    t := curcon.win.title
    IF (t <> curcon.wtitle) AND (t <> curcon.wtitlebase) AND
       (t <> NIL) AND (t <> -1)
      StrCopy(curcon.wtitlebase, t)
    ENDIF
  ENDIF
  IF curcon.viewoff > 0
    StringF(curcon.wtitle, '\s  [scrollback -\d]', curcon.wtitlebase, curcon.viewoff)
    SetWindowTitles(curcon.win, curcon.wtitle, -1)
  ELSE
    SetWindowTitles(curcon.win, curcon.wtitlebase, -1)
  ENDIF
ENDPROC

-> ---------- xterm window titles (v1.1) ----------
-> ESC ] 0 ; title BEL (BEL, $9C or ESC \ all terminate): the client
-> retitles the window - the proper path More never had. The text
-> becomes wtitlebase, so the [scrollback -n] and [search:] suffixes
-> ride on top of it like on any other title.
PROC oscstart()
  curcon.cesc := 3
  curcon.oscn := 0
  curcon.oscsk := TRUE
ENDPROC

PROC oscdone()
  curcon.osct[curcon.oscn] := 0
  IF curcon.oscn > 0
    StrCopy(curcon.wtitlebase, curcon.osct)
    settitle()
  ENDIF
ENDPROC

-> scroll the view by delta lines (positive = back in time), clamped
-> to the history actually stored; landing on live restores the blip
PROC scrollview(delta)
  IF curcon.sb = NIL THEN RETURN
  IF curcon.altvalid THEN RETURN  -> no scrollback ON the alternate
                                  -> screen (xterm manners; the raw
                                  -> rows there are More's business)
  curcon.viewoff := curcon.viewoff + delta
  IF curcon.viewoff > curcon.sbcnt THEN curcon.viewoff := curcon.sbcnt
  IF curcon.viewoff < 0 THEN curcon.viewoff := 0
  redraw()                      -> the grid repaint wiped any block
  curcon.cursx := -1                   -> cursor pixels with it
  settitle()
  IF curcon.viewoff = 0
    IF curcon.rawmode THEN cursdraw() ELSE drawedit()
  ENDIF
ENDPROC

-> ---------- the raw-session alternate screen (v1.1b10) ----------
-> The More finding from the b8 sweep: a fullscreen client paints
-> its UI over the visible rows - which ARE the model's live window
-> - so its pager bars ended up archived in scrollback where the
-> transcript should be. Stock CON: corrupts identically, it just
-> has no scrollback to show it. The cure no Amiga console had: on
-> cooked->raw the visible rows are SNAPSHOT; on raw->cooked they
-> come back, cursor and anchor too - More and Ed leave the
-> transcript exactly as they found it (less-on-xterm manners).
-> Rows that scroll away DURING raw reclaim ring rows; if that
-> wrapped far enough to eat the oldest history, sbcnt shrinks by
-> the overflow (rawscr counts, screenscroll feeds it).

PROC altdrop()
  IF curcon.altm THEN Dispose(curcon.altm)
  IF curcon.alta THEN Dispose(curcon.alta)
  IF curcon.alts THEN Dispose(curcon.alts)
  curcon.altm := NIL
  curcon.alta := NIL
  curcon.alts := NIL
  curcon.altvalid := FALSE
ENDPROC

PROC altsave()
  DEF r, n
  altdrop()
  IF curcon.sb = NIL THEN RETURN
  n := Mul(curcon.rows, curcon.cols)
  curcon.altm := New(n)
  curcon.alta := New(n)
  curcon.alts := New(n)
  IF (curcon.altm = NIL) OR (curcon.alta = NIL) OR (curcon.alts = NIL)
    altdrop()                   -> no memory: raw runs unsnapshotted
    RETURN
  ENDIF
  FOR r := 0 TO curcon.rows - 1
    CopyMem(visrow(r), curcon.altm + Mul(r, curcon.cols), curcon.cols)
    CopyMem(sarow(r), curcon.alta + Mul(r, curcon.cols), curcon.cols)
    CopyMem(ssrow(r), curcon.alts + Mul(r, curcon.cols), curcon.cols)
  ENDFOR
  curcon.altcx := curcon.cx
  curcon.altcy := curcon.cy
  curcon.altancx := curcon.ancx
  curcon.altancy := curcon.ancy
  curcon.altsbtop := curcon.sbtop
  curcon.altsbcnt := curcon.sbcnt
  curcon.altrows := curcon.rows
  curcon.altcols := curcon.cols
  curcon.rawscr := 0
  curcon.altvalid := TRUE
ENDPROC

-> TRUE = the pre-raw screen is back on model and glass; the caller
-> skips reanchor (the saved anchor is part of the restoration)
PROC altrestore()
  DEF r, over
  IF curcon.altvalid = FALSE THEN RETURN FALSE
  IF (curcon.altrows <> curcon.rows) OR (curcon.altcols <> curcon.cols)
    altdrop()
    RETURN FALSE
  ENDIF
  curcon.sbtop := curcon.altsbtop
  over := curcon.rawscr - (curcon.sbmax - curcon.rows - curcon.altsbcnt)
  curcon.sbcnt := curcon.altsbcnt
  IF over > 0 THEN curcon.sbcnt := curcon.sbcnt - over
  IF curcon.sbcnt < 0 THEN curcon.sbcnt := 0
  FOR r := 0 TO curcon.rows - 1
    CopyMem(curcon.altm + Mul(r, curcon.cols), visrow(r), curcon.cols)
    CopyMem(curcon.alta + Mul(r, curcon.cols), sarow(r), curcon.cols)
    CopyMem(curcon.alts + Mul(r, curcon.cols), ssrow(r), curcon.cols)
  ENDFOR
  curcon.cx := curcon.altcx
  curcon.cy := curcon.altcy
  curcon.ancx := curcon.altancx
  curcon.ancy := curcon.altancy
  altdrop()
  curcon.viewoff := 0
  redraw()
  settitle()
ENDPROC TRUE

-> any output or any non-scroll key returns the view to live
PROC snaplive()
  IF curcon.viewoff = 0 THEN RETURN
  curcon.viewoff := 0
  redraw()
  curcon.cursx := -1
  settitle()
  IF curcon.rawmode THEN cursdraw() ELSE drawedit()
ENDPROC

-> ---------- output: a cell-grid renderer (CSI parsing comes with the
-> full CTerm renderer transplant in a later milestone) ----------

-> scroll the whole screen up one line: pixels, model, edit anchor.
-> The old top row becomes history - just advance the ring, no copying.
PROC screenscroll()
  ScrollRaster(curcon.rp, 0, curcon.ch,
               curcon.win.borderleft, curcon.win.bordertop,
               curcon.win.width - curcon.win.borderright - 1,
               curcon.win.height - curcon.win.borderbottom - 1)
  IF curcon.ancy > 0 THEN curcon.ancy := curcon.ancy - 1       -> the edit anchor scrolled with the rest
  IF curcon.sb
    curcon.sbtop := curcon.sbtop + 1
    IF curcon.sbtop >= curcon.sbmax THEN curcon.sbtop := 0
    IF curcon.sbcnt < (curcon.sbmax - curcon.rows) THEN curcon.sbcnt := curcon.sbcnt + 1
    IF curcon.rawmode THEN curcon.rawscr := curcon.rawscr + 1
    clearrow(curcon.rows - 1)   -> (rawscr: altrestore's overflow
  ENDIF                         -> accounting, see the alt procs)
ENDPROC

PROC outnl()
  curcon.cx := 0
  curcon.cy := curcon.cy + 1
  IF curcon.cy >= curcon.rows
    screenscroll()
    curcon.cy := curcon.rows - 1
  ENDIF
ENDPROC

PROC outchr(c)
  DEF b[2]:ARRAY OF CHAR, m:PTR TO CHAR
  IF curcon.cx >= curcon.cols THEN outnl()
  b[0] := c
  setpens()
  setsoft(curcon.cursty)
  Move(curcon.rp, curcon.left + Mul(curcon.cx, curcon.cw), curcon.topy + Mul(curcon.cy, curcon.ch) + curcon.baseline)
  Text(curcon.rp, b, 1)
  IF curcon.sb
    m := visrow(curcon.cy)
    m[curcon.cx] := c
    m := sarow(curcon.cy)
    m[curcon.cx] := curattr()
    m := ssrow(curcon.cy)
    m[curcon.cx] := curcon.cursty
  ENDIF
  curcon.cx := curcon.cx + 1
ENDPROC

PROC csistart()
  curcon.cesc := 2
  curcon.cnp := 0
  curcon.cpriv := FALSE
  curcon.cpar[0] := 0
  curcon.cpar[1] := 0
  curcon.cpar[2] := 0
  curcon.cpar[3] := 0
ENDPROC

-> the full-screen vocabulary: what More and Ed actually speak.
-> A/B/C/D cursor moves, H/f position (row;col, 1-based), J erase
-> below, K erase to EOL, L/M insert/delete lines, `0 q` = the
-> window-bounds request, answered on the INPUT stream as
-> CSI 1;1;rows;cols SPACE r (how dir learns it can do columns).
-> Everything else is consumed silently.
PROC csidispatch(c)
  DEF n, i, v
  n := curcon.cpar[0]
  IF c = "A"
    IF n < 1 THEN n := 1
    curcon.cy := curcon.cy - n
    IF curcon.cy < 0 THEN curcon.cy := 0
  ELSEIF c = "B"
    IF n < 1 THEN n := 1
    curcon.cy := curcon.cy + n
    IF curcon.cy >= curcon.rows THEN curcon.cy := curcon.rows - 1
  ELSEIF c = "C"
    IF n < 1 THEN n := 1
    curcon.cx := curcon.cx + n
    IF curcon.cx > curcon.cols THEN curcon.cx := curcon.cols
  ELSEIF c = "D"
    IF n < 1 THEN n := 1
    curcon.cx := curcon.cx - n
    IF curcon.cx < 0 THEN curcon.cx := 0
  ELSEIF (c = "H") OR (c = "f")
    curcon.cy := n - 1
    IF curcon.cy < 0 THEN curcon.cy := 0
    IF curcon.cy >= curcon.rows THEN curcon.cy := curcon.rows - 1
    curcon.cx := curcon.cpar[1] - 1
    IF curcon.cx < 0 THEN curcon.cx := 0
    IF curcon.cx > curcon.cols THEN curcon.cx := curcon.cols
  ELSEIF c = "J"
    erasebelow()
  ELSEIF c = "K"
    eraseeol()
  ELSEIF c = "L"
    inslines(n)
  ELSEIF c = "M"
    dellines(n)
  ELSEIF c = "@"
    inschars(n)                 -> v1.1: ICH, the L/M pattern sideways
  ELSEIF c = "P"
    delchars(n)                 -> v1.1: DCH
  ELSEIF c = "h"
    -> CSI ?47h - ENTER the alternate screen (b11: the client
    -> drives it, xterm-exact - V47's More brackets its whole
    -> pager session with ?47h/?47l, VERIFIED in its binary; the
    -> b10 SetMode coupling raced More's own exit tidy-up)
    IF curcon.cpriv AND (n = 47) THEN altsave()
  ELSEIF c = "l"
    IF curcon.cpriv AND (n = 47) THEN altrestore()
  ELSEIF c = "m"
    -> SGR (M5d): reset, bold (bright pens on a 16-pen screen),
    -> 30-37 fg, 39 default fg, 40-47 bg, 49 default bg
    FOR i := 0 TO curcon.cnp
      v := curcon.cpar[i]
      IF v = 0
        curcon.curfg := curcon.deffg
        curcon.curbg := 0
        curcon.bold := FALSE
        curcon.cursgr := FALSE
        curcon.cursty := 0
      ELSEIF v = 1
        curcon.bold := TRUE
      ELSEIF v = 22
        curcon.bold := FALSE
      ELSEIF v = 3
        -> v1.1 soft styles: italic (3/23), underline (4/24),
        -> inverse (7/27) - the styles stock CON: renders and 1.0
        -> dropped; they live in the model's third plane
        curcon.cursty := curcon.cursty OR 1
      ELSEIF v = 23
        curcon.cursty := curcon.cursty AND 6
      ELSEIF v = 4
        curcon.cursty := curcon.cursty OR 2
      ELSEIF v = 24
        curcon.cursty := curcon.cursty AND 5
      ELSEIF v = 7
        curcon.cursty := curcon.cursty OR 4
      ELSEIF v = 27
        curcon.cursty := curcon.cursty AND 3
      ELSEIF (v >= 30) AND (v <= 37)
        curcon.curfg := v - 30
        curcon.cursgr := TRUE
        -> WBPENS (see parsecon): plain 30-33 are WB pen numbers
        -> from programs like Ed, not ANSI colours - retarget them
        -> at the theme. Bold forms keep ANSI positions (fgpen()
        -> lifts to the bright half before this map could matter).
        IF curcon.wbpens AND curcon.can16 AND (curcon.bold = FALSE) AND (v <= 33)
          IF v = 30
            curcon.curfg := 0
          ELSEIF v = 31
            curcon.curfg := curcon.deffg
          ELSEIF v = 32
            curcon.curfg := 15
          ELSE
            curcon.curfg := 12
          ENDIF
        ENDIF
      ELSEIF v = 39
        curcon.curfg := curcon.deffg
        curcon.cursgr := FALSE
      ELSEIF (v >= 40) AND (v <= 47)
        curcon.curbg := v - 40
      ELSEIF v = 49
        curcon.curbg := 0
      ENDIF
    ENDFOR
  ELSEIF c = "q"
    IF n = 0 THEN sendreport()
  ELSEIF c = "{"
    -> SET RAW EVENTS: report the listed IECLASSes on the input
    -> stream (this is how Ed's menus reach it through the console)
    FOR i := 0 TO curcon.cnp
      IF (curcon.cpar[i] >= 0) AND (curcon.cpar[i] <= 31)
        curcon.evmask := curcon.evmask OR Shl(1, curcon.cpar[i])
      ENDIF
    ENDFOR
    setidcmp()                  -> CSI 2{ pulls MOUSEBUTTONS out of
                                -> IDCMP: the client's class-2
                                -> reports need the events to pass
                                -> downstream (the MENUPICK lesson)
  ELSEIF c = "}"
    -> RESET RAW EVENTS
    FOR i := 0 TO curcon.cnp
      IF (curcon.cpar[i] >= 0) AND (curcon.cpar[i] <= 31)
        curcon.evmask := curcon.evmask - (curcon.evmask AND Shl(1, curcon.cpar[i]))
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
  IF curcon.cy < (curcon.rows - 1)
    SetAPen(curcon.rp, 0)
    RectFill(curcon.rp, curcon.left, curcon.topy + Mul(curcon.cy + 1, curcon.ch),
             curcon.left + Mul(curcon.cols, curcon.cw) - 1, curcon.topy + Mul(curcon.rows, curcon.ch) - 1)
    SetAPen(curcon.rp, curcon.deffg)
    IF curcon.sb
      FOR r := curcon.cy + 1 TO curcon.rows - 1
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
  IF n > (curcon.rows - curcon.cy) THEN n := curcon.rows - curcon.cy
  ScrollRaster(curcon.rp, 0, -Mul(n, curcon.ch),
               curcon.left, curcon.topy + Mul(curcon.cy, curcon.ch),
               curcon.left + Mul(curcon.cols, curcon.cw) - 1, curcon.topy + Mul(curcon.rows, curcon.ch) - 1)
  IF curcon.sb
    FOR r := curcon.rows - 1 TO curcon.cy + n STEP -1
      CopyMem(visrow(r - n), visrow(r), curcon.cols)
      CopyMem(sarow(r - n), sarow(r), curcon.cols)
      CopyMem(ssrow(r - n), ssrow(r), curcon.cols)
    ENDFOR
    FOR r := curcon.cy TO curcon.cy + n - 1
      clearrow(r)
    ENDFOR
  ENDIF
ENDPROC

PROC dellines(n)
  DEF r
  IF n < 1 THEN n := 1
  IF n > (curcon.rows - curcon.cy) THEN n := curcon.rows - curcon.cy
  ScrollRaster(curcon.rp, 0, Mul(n, curcon.ch),
               curcon.left, curcon.topy + Mul(curcon.cy, curcon.ch),
               curcon.left + Mul(curcon.cols, curcon.cw) - 1, curcon.topy + Mul(curcon.rows, curcon.ch) - 1)
  IF curcon.sb
    FOR r := curcon.cy TO curcon.rows - 1 - n
      CopyMem(visrow(r + n), visrow(r), curcon.cols)
      CopyMem(sarow(r + n), sarow(r), curcon.cols)
      CopyMem(ssrow(r + n), ssrow(r), curcon.cols)
    ENDFOR
    FOR r := curcon.rows - n TO curcon.rows - 1
      clearrow(r)
    ENDFOR
  ENDIF
ENDPROC

-> CSI @ / CSI P (v1.1): insert/delete blank cells inside the row.
-> b7: the model row is shifted, then the ROW IS REPAINTED FROM THE
-> MODEL (one drawmrow) - the b6 horizontal ScrollRaster wiped the
-> row on boot while the model shift was provably right (harness-
-> verified); a repaint from the model cannot disagree with it.
-> The blitter path survives only for the no-model degenerate case.
PROC inschars(n)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, j, y, idx
  IF curcon.cx >= curcon.cols THEN RETURN
  IF n < 1 THEN n := 1
  IF n > (curcon.cols - curcon.cx) THEN n := curcon.cols - curcon.cx
  y := curcon.topy + Mul(curcon.cy, curcon.ch)
  IF curcon.sb
    m := visrow(curcon.cy)
    a := sarow(curcon.cy)
    stp := ssrow(curcon.cy)
    FOR j := curcon.cols - 1 TO curcon.cx + n STEP -1
      m[j] := m[j - n]
      a[j] := a[j - n]
      stp[j] := stp[j - n]
    ENDFOR
    FOR j := curcon.cx TO curcon.cx + n - 1
      m[j] := 0
      a[j] := 0
      stp[j] := 0
    ENDFOR
    idx := curcon.sbtop + curcon.cy
    IF idx >= curcon.sbmax THEN idx := idx - curcon.sbmax
    drawmrow(idx, y)
  ELSE
    ScrollRaster(curcon.rp, -Mul(n, curcon.cw), 0,
                 curcon.left + Mul(curcon.cx, curcon.cw), y,
                 curcon.left + Mul(curcon.cols, curcon.cw) - 1, y + curcon.ch - 1)
  ENDIF
ENDPROC

PROC delchars(n)
  DEF m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, j, y, idx
  IF curcon.cx >= curcon.cols THEN RETURN
  IF n < 1 THEN n := 1
  IF n > (curcon.cols - curcon.cx) THEN n := curcon.cols - curcon.cx
  y := curcon.topy + Mul(curcon.cy, curcon.ch)
  IF curcon.sb
    m := visrow(curcon.cy)
    a := sarow(curcon.cy)
    stp := ssrow(curcon.cy)
    FOR j := curcon.cx TO curcon.cols - 1 - n
      m[j] := m[j + n]
      a[j] := a[j + n]
      stp[j] := stp[j + n]
    ENDFOR
    FOR j := curcon.cols - n TO curcon.cols - 1
      m[j] := 0
      a[j] := 0
      stp[j] := 0
    ENDFOR
    idx := curcon.sbtop + curcon.cy
    IF idx >= curcon.sbmax THEN idx := idx - curcon.sbmax
    drawmrow(idx, y)
  ELSE
    ScrollRaster(curcon.rp, Mul(n, curcon.cw), 0,
                 curcon.left + Mul(curcon.cx, curcon.cw), y,
                 curcon.left + Mul(curcon.cols, curcon.cw) - 1, y + curcon.ch - 1)
  ENDIF
ENDPROC

-> the answer to `CSI 0 SPACE q`, injected straight into the input
-> stream where the asker's Read finds it
PROC sendreport()
  DEF b[24]:STRING, i
  enqueue($9B)
  StringF(b, '1;1;\d;\d', curcon.rows, curcon.cols)
  FOR i := 0 TO StrLen(b) - 1
    enqueue(b[i])
  ENDFOR
  enqueue(32)
  enqueue("r")
  inputarrived()
ENDPROC

-> erase from the output cursor to the end of its row (CSI K)
PROC eraseeol()
  DEF y, m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, j
  IF curcon.cx >= curcon.cols THEN RETURN   -> inverted RectFill = wild writes
  y := curcon.topy + Mul(curcon.cy, curcon.ch)
  SetAPen(curcon.rp, 0)
  RectFill(curcon.rp, curcon.left + Mul(curcon.cx, curcon.cw), y, curcon.left + Mul(curcon.cols, curcon.cw) - 1, y + curcon.ch - 1)
  SetAPen(curcon.rp, curcon.deffg)
  IF curcon.sb
    m := visrow(curcon.cy)
    a := sarow(curcon.cy)
    stp := ssrow(curcon.cy)
    FOR j := curcon.cx TO curcon.cols - 1
      m[j] := 0
      a[j] := 0
      stp[j] := 0
    ENDFOR
  ENDIF
ENDPROC

-> the 0.1 CTerm renderer's CSI discipline, transplanted and grown
-> up: consume sequences WHOLE (state survives split writes via
-> cesc/cpar/cnp), dispatch the full-screen set (csidispatch), drop
-> the rest silently.
PROC render(buf, len)
  DEF s:PTR TO CHAR, i=0, j, c, run, fit, m:PTR TO CHAR, j2
  IF curcon.win = NIL THEN RETURN
  s := buf
  WHILE i < len
    c := s[i]
    IF curcon.cesc = 1    -> after ESC: '[' opens a CSI, ']' an OSC
      IF c = "["
        csistart()
      ELSEIF c = "]"
        oscstart()        -> v1.1: xterm title sequence
      ELSE
        curcon.cesc := 0
      ENDIF
      i := i + 1
    ELSEIF curcon.cesc = 3    -> OSC body: ESC]0;title BEL (or ST)
      IF (c = 7) OR (c = $9C)
        oscdone()
        curcon.cesc := 0
      ELSEIF c = 27
        curcon.cesc := 4      -> ESC inside the OSC: ST coming?
      ELSEIF curcon.oscsk AND (c >= "0") AND (c <= "9")
        -> the Ps number skipped: 0, 1 and 2 all retitle here
      ELSEIF curcon.oscsk AND (c = ";")
        curcon.oscsk := FALSE
      ELSE
        curcon.oscsk := FALSE
        IF (curcon.oscn < 80) AND (c >= 32)
          curcon.osct[curcon.oscn] := c
          curcon.oscn := curcon.oscn + 1
        ENDIF
      ENDIF
      i := i + 1
    ELSEIF curcon.cesc = 4    -> ESC \ is ST; anything else aborts
      IF c = 92 THEN oscdone()
      curcon.cesc := 0
      i := i + 1
    ELSEIF curcon.cesc = 2    -> CSI parameters end at the final byte >= $40
      IF (c >= "0") AND (c <= "9")
        curcon.cpar[curcon.cnp] := Mul(curcon.cpar[curcon.cnp], 10) + (c - 48)
        IF curcon.cpar[curcon.cnp] > 999 THEN curcon.cpar[curcon.cnp] := 999
      ELSEIF c = ";"
        curcon.cnp := curcon.cnp + 1
        IF curcon.cnp > 3 THEN curcon.cnp := 3
        curcon.cpar[curcon.cnp] := 0
      ELSEIF (c = "?") OR (c = ">")
        curcon.cpriv := TRUE    -> DEC private marker (More: ?47h/l)
      ELSEIF c >= $40
        csidispatch(c)
        curcon.cesc := 0
      ENDIF
      i := i + 1
    ELSEIF c = 27
      curcon.cesc := 1
      i := i + 1
    ELSEIF c = $9B
      csistart()
      i := i + 1
    ELSEIF c = $9D
      oscstart()          -> the 8-bit OSC introducer
      i := i + 1
    ELSEIF c = 10
      outnl()
      i := i + 1
    ELSEIF c = 13
      curcon.cx := 0
      i := i + 1
    ELSEIF c = 8
      IF curcon.cx > 0 THEN curcon.cx := curcon.cx - 1
      i := i + 1
    ELSEIF c = 9
      REPEAT
        outchr(32)
      UNTIL (Mod(curcon.cx, 8) = 0) OR (curcon.cx >= curcon.cols)
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
        IF curcon.cx >= curcon.cols THEN outnl()
        fit := curcon.cols - curcon.cx
        IF fit > run THEN fit := run
        setpens()
        setsoft(curcon.cursty)
        Move(curcon.rp, curcon.left + Mul(curcon.cx, curcon.cw), curcon.topy + Mul(curcon.cy, curcon.ch) + curcon.baseline)
        Text(curcon.rp, s + i, fit)
        IF curcon.sb
          CopyMem(s + i, visrow(curcon.cy) + curcon.cx, fit)
          m := sarow(curcon.cy) + curcon.cx
          FOR j2 := 0 TO fit - 1
            m[j2] := curattr()
          ENDFOR
          m := ssrow(curcon.cy) + curcon.cx
          FOR j2 := 0 TO fit - 1
            m[j2] := curcon.cursty
          ENDFOR
        ENDIF
        curcon.cx := curcon.cx + fit
        i := i + fit
        run := run - fit
      ENDWHILE
    ELSE
      i := i + 1    -> other control bytes
    ENDIF
  ENDWHILE
  setsoft(0)        -> the editor and cursor draw plain, always
ENDPROC

-> ---------- the line editor, out-of-band of the output cursor:
-> drawing never moves cx/cy, so committed lines render from the
-> anchor exactly where the client's prompt left the output ----------

PROC reanchor()
  curcon.ancx := curcon.cx
  curcon.ancy := curcon.cy
ENDPROC

-> the edit line WRAPS (stock shell behaviour): it may span several
-> rows below the anchor, and growing past the bottom row scrolls
-> the whole screen up, prompt and all - the anchor tracks it.

-> the most chars the line can hold: LINEMAX, or every cell from
-> the anchor to the bottom-right corner minus one for the blip
PROC edcap() IS Min(LINEMAX - 1, Mul(curcon.rows, curcon.cols) - curcon.ancx - 1)

-> the last row a line of n chars (plus its blip cell) touches
PROC edlastrow(n) IS curcon.ancy + ((curcon.ancx + n) / curcon.cols)

-> scroll until that fits on screen (the dotab menu loop's pattern)
PROC edroom(n)
  WHILE (edlastrow(n) > (curcon.rows - 1)) AND (curcon.ancy > 0)
    screenscroll()
    IF curcon.cy > 0 THEN curcon.cy := curcon.cy - 1
  ENDWHILE
ENDPROC

-> v1.1b8: erase ONLY what the editor painted. 1.0 erased from the
-> anchor to EOL - pixels AND model - which STOLE CLIENT ROWS: a
-> write may legally end mid-row (Type splits at \r), reanchor
-> parks the anchor on the client's half-written row, and the next
-> write's eraseedit destroyed it before its bytes arrived. Full-
-> width overprinters ("50%\r51%\r") repaint what they lose, so
-> 1.0 never showed it; the ccon-bisect t2 boot (19.7.26) did.
-> Now: the model loses just the MIRRORED text cells (the editor's
-> own), and the touched rows repaint whole from the model - blip,
-> ghost and search-banner pixels evaporate (they are not in the
-> model), client cells COME BACK (they are).
PROC eraseedit()
  DEF y, r, r1, x0, m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, j,
      cc
  IF curcon.win = NIL THEN RETURN
  IF curcon.ancx >= curcon.cols THEN RETURN -> inverted RectFill = wild writes
  IF curcon.sb
    cc := curcon.ancx
    r := curcon.ancy
    FOR j := 0 TO curcon.edlast - 1
      IF r <= (curcon.rows - 1)
        m := visrow(r)
        a := sarow(r)
        stp := ssrow(r)
        m[cc] := 0
        a[cc] := 0
        stp[cc] := 0
      ENDIF
      cc := cc + 1
      IF cc >= curcon.cols
        cc := 0
        r := r + 1
      ENDIF
    ENDFOR
    r1 := edlastrow(curcon.edext)
    IF r1 > (curcon.rows - 1) THEN r1 := curcon.rows - 1
    FOR r := curcon.ancy TO r1
      drawmodelrow(r)
    ENDFOR
  ELSE
    -> no model: nothing to restore from - the old full clear
    r1 := edlastrow(curcon.edext)
    IF r1 > (curcon.rows - 1) THEN r1 := curcon.rows - 1
    x0 := curcon.ancx
    SetAPen(curcon.rp, 0)
    FOR r := curcon.ancy TO r1
      y := curcon.topy + Mul(r, curcon.ch)
      RectFill(curcon.rp, curcon.left + Mul(x0, curcon.cw), y,
               curcon.left + Mul(curcon.cols, curcon.cw) - 1, y + curcon.ch - 1)
      x0 := 0                 -> continuation rows clear full width
    ENDFOR
    SetAPen(curcon.rp, curcon.deffg)
  ENDIF
  curcon.edlast := 0            -> the paint is gone; drawedit's b9
  curcon.edext := 0             -> tail cleanup must not re-clean
ENDPROC

-> repaint cells x0..x1 of view row r from the model - drawmodelrow's
-> bounded sibling, for the b9 drawedit tail cleanup
PROC drawmodelcells(r, x0, x1)
  DEF idx, m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, i, j, at,
      sy, c, fg, bg, rowbuf[256]:ARRAY OF CHAR
  IF curcon.sb = NIL THEN RETURN
  IF x0 < 0 THEN x0 := 0
  IF x1 > (curcon.cols - 1) THEN x1 := curcon.cols - 1
  IF x0 > x1 THEN RETURN
  idx := curcon.sbtop + r
  IF idx >= curcon.sbmax THEN idx := idx - curcon.sbmax
  m := curcon.sb + Mul(idx, curcon.cols)
  a := curcon.sa + Mul(idx, curcon.cols)
  stp := curcon.ss + Mul(idx, curcon.cols)
  FOR i := x0 TO x1
    c := m[i]
    rowbuf[i] := IF c < 32 THEN 32 ELSE c
  ENDFOR
  i := x0
  WHILE i <= x1
    at := a[i]
    sy := stp[i]
    j := i
    WHILE (j <= x1) AND (a[j] = at) AND (stp[j] = sy)
      j++
    ENDWHILE
    fg := at AND 15
    bg := Shr(at, 4) AND 7
    IF sy AND 4
      IF fg = bg THEN fg := curcon.deffg
      SetAPen(curcon.rp, bg)
      SetBPen(curcon.rp, fg)
    ELSE
      SetAPen(curcon.rp, fg)
      SetBPen(curcon.rp, bg)
    ENDIF
    setsoft(sy)
    Move(curcon.rp, curcon.left + Mul(i, curcon.cw), curcon.topy + Mul(r, curcon.ch) + curcon.baseline)
    Text(curcon.rp, rowbuf + i, j - i)
    i := j
  ENDWHILE
  setsoft(0)
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
ENDPROC

-> the cell at cpos is drawn inverted - the blip - so the cursor is
-> visible for mid-line editing (transplant of 0.1 redrawinput,
-> grown row-wrapping). The typed text is MIRRORED into the model
-> (0.25): the overlay used to be pixels only, so drag-selecting the
-> prompt line repainted its rows from empty model cells - the text
-> vanished and the copy came out blank. In the model it selects,
-> copies and survives selection repaints like any other cell;
-> commit erases it and renders the real line over the same cells.
PROC drawedit()
  DEF s:PTR TO CHAR, l, cch[2]:ARRAY OF CHAR, i, n, r, xc, bc,
      m:PTR TO CHAR, a:PTR TO CHAR, stp:PTR TO CHAR, j, gp,
      g:PTR TO CHAR, gn, gcol, gext, cc, sd[80]:STRING,
      oldl, oldext, newext, c0, c1, rr, n2, x0, x1
  IF curcon.win = NIL THEN RETURN
  -> b9: NO pre-erase - the b8 erase-then-paint repainted every row
  -> twice per keystroke and the whole line flickered on bare
  -> cursor moves (the sweep's finding). The text now paints IN
  -> PLACE (JAM2 covers the old pixels; identical glyphs repaint
  -> invisibly); what the new paint no longer covers is cleaned at
  -> the END from the old extent (see the tail below).
  oldl := curcon.edlast
  oldext := curcon.edext
  l := StrLen(curcon.ebuf)
  edroom(l)
  s := curcon.ebuf
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
  i := 0
  r := curcon.ancy
  xc := curcon.ancx
  WHILE i < l
    n := Min(curcon.cols - xc, l - i)
    Move(curcon.rp, curcon.left + Mul(xc, curcon.cw), curcon.topy + Mul(r, curcon.ch) + curcon.baseline)
    Text(curcon.rp, s + i, n)
    IF curcon.sb
      CopyMem(s + i, visrow(r) + xc, n)
      a := sarow(r) + xc
      stp := ssrow(r) + xc
      FOR j := 0 TO n - 1
        a[j] := curcon.deffg    -> deffg on background 0, the same
        stp[j] := 0             -> attr the pixels are drawn with;
      ENDFOR                    -> the edit line is never styled
    ENDIF
    i := i + n
    xc := 0
    r := r + 1
  ENDWHILE
  -> zero the MIRROR where the old text out-reaches the new (cells
  -> l..oldl-1) - BEFORE the blip below reads the model (b10: the
  -> Ctrl+U ghost-of-the-killed-char sighting: the blip's model
  -> read must never see the cells this paint just abandoned)
  IF curcon.sb
    IF oldl > l
      j := l
      cc := curcon.ancx + l
      rr := curcon.ancy
      WHILE cc >= curcon.cols
        cc := cc - curcon.cols
        rr := rr + 1
      ENDWHILE
      WHILE j < oldl
        IF rr <= (curcon.rows - 1)
          m := visrow(rr)
          a := sarow(rr)
          stp := ssrow(rr)
          m[cc] := 0
          a[cc] := 0
          stp[cc] := 0
        ENDIF
        j := j + 1
        cc := cc + 1
        IF cc >= curcon.cols
          cc := 0
          rr := rr + 1
        ENDIF
      ENDWHILE
    ENDIF
  ENDIF
  -> the autosuggestion: only with the cursor at the end, only on a
  -> screen with a readable grey. The blip cell carries the ghost's
  -> FIRST character (inverse, fish fashion - accepted text lands
  -> exactly where it was shown); the rest draws grey, clipped to
  -> the blip's row. Pixels only: eraseedit clears every touched
  -> row to its right edge, so the ghost needs no bookkeeping.
  curcon.sghost := NIL
  gp := ghostpen()
  IF (curcon.cpos = l) AND (gp >= 0) AND (curcon.srch = FALSE) THEN sgfind()
  cch[0] := 32
  IF curcon.cpos < l
    cch[0] := s[curcon.cpos]
  ELSEIF curcon.sghost
    g := curcon.sghost
    cch[0] := g[l]
  ENDIF
  bc := curcon.ancx + curcon.cpos
  r := bc / curcon.cols
  IF (cch[0] = 32) AND (curcon.sb <> NIL)
    -> a \r-parked anchor (b8): the blip may sit over CLIENT text -
    -> show that char inverted, the block-cursor rule
    m := visrow(curcon.ancy + r)
    cc := m[bc - Mul(r, curcon.cols)]
    IF cc >= 32 THEN cch[0] := cc
  ENDIF
  SetAPen(curcon.rp, 0)
  SetBPen(curcon.rp, curcon.deffg)
  Move(curcon.rp, curcon.left + Mul(bc - Mul(r, curcon.cols), curcon.cw),
       curcon.topy + Mul(curcon.ancy + r, curcon.ch) + curcon.baseline)
  Text(curcon.rp, cch, 1)
  gext := 0
  IF curcon.sghost
    g := curcon.sghost
    gcol := bc - Mul(r, curcon.cols) + 1
    gn := Min(StrLen(g) - l - 1, curcon.cols - gcol)
    IF gn > 0
      SetAPen(curcon.rp, gp)
      SetBPen(curcon.rp, 0)
      Move(curcon.rp, curcon.left + Mul(gcol, curcon.cw),
           curcon.topy + Mul(curcon.ancy + r, curcon.ch) + curcon.baseline)
      Text(curcon.rp, g + l + 1, gn)
      gext := gn                -> ghost cells join the erase extent
    ENDIF
  ENDIF
  -> Ctrl+R feedback REPLACES the prompt, the bash way: the prompt
  -> cells (0..ancx-1 on the anchor row) are overdrawn with an
  -> inverse (search: frag) banner - pixels only, the model still
  -> holds the real prompt, so srexit/srcancel restore it
  -> perfectly with one drawmodelrow. Long fragments keep their
  -> TAIL visible; short banners pad inverse to the full prompt
  -> width so no prompt fragment peeks out.
  IF curcon.srch
    IF curcon.ancx > 0
      StringF(sd, '(search: \s)', curcon.srbuf)
      gn := StrLen(sd)
      WHILE (StrLen(sd) < curcon.ancx) AND (StrLen(sd) < 79)
        StrAdd(sd, ' ')
      ENDWHILE
      SetAPen(curcon.rp, 0)
      SetBPen(curcon.rp, curcon.deffg)
      Move(curcon.rp, curcon.left,
           curcon.topy + Mul(curcon.ancy, curcon.ch) + curcon.baseline)
      IF gn > curcon.ancx
        Text(curcon.rp, sd + (gn - curcon.ancx), curcon.ancx)
      ELSE
        Text(curcon.rp, sd, Min(StrLen(sd), curcon.ancx))
      ENDIF
    ENDIF
  ENDIF
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
  -> the b9 tail: repaint stale pixels (old blip/ghost beyond the
  -> new extent) from the model. Interior cells need nothing: the
  -> text pass painted over them. b10: the blip cell counts into
  -> the extent ONLY when the blip actually sits at the line end
  -> (cpos = l) - counting it unconditionally left the old end-
  -> blip standing when the cursor jumped into the interior (the
  -> Ctrl+Left garbage-marker sighting).
  newext := l
  IF curcon.cpos = l THEN newext := l + 1 + gext
  IF curcon.sb
    IF oldext > newext
      c0 := curcon.ancx + newext        -> stale cells, linear from
      c1 := curcon.ancx + oldext - 1    -> the anchor ROW's start
      rr := Div(c0, curcon.cols)
      n2 := Div(c1, curcon.cols)
      WHILE rr <= n2
        IF (curcon.ancy + rr) <= (curcon.rows - 1)
          x0 := c0 - Mul(rr, curcon.cols)
          x1 := c1 - Mul(rr, curcon.cols)
          drawmodelcells(curcon.ancy + rr, x0, x1)
        ENDIF
        rr := rr + 1
      ENDWHILE
    ENDIF
  ENDIF
  curcon.edlast := l
  curcon.edext := newext        -> text + the blip cell + any ghost
ENDPROC

-> ---------- Ctrl+R incremental history search (readline) ----------
-> The prompt is CLIENT output, so the search state lives where the
-> console owns pixels: the edit line shows the current match live,
-> the TITLE BAR shows the fragment - [search: frag]. Typing narrows
-> (substring, case-folded, anywhere in the line - unlike the ghost,
-> which is prefix-only), Ctrl+R again steps to older matches, Enter
-> takes the match and RUNS it, Esc restores the pre-search line,
-> and any movement key keeps the match for editing. No readable
-> title on a borrowed window (CTerm's frame) - search still works,
-> only the fragment display is lost there.

PROC srtitle()
  DEF f:PTR TO CHAR, i
  IF curcon.fwin THEN RETURN
  IF curcon.win = NIL THEN RETURN
  StrCopy(curcon.wtitle, '[search: ')
  f := curcon.srbuf
  i := 0
  WHILE (f[i] <> 0) AND (i < 60)
    StrAdd(curcon.wtitle, f + i, 1)
    i++
  ENDWHILE
  StrAdd(curcon.wtitle, ']')
  SetWindowTitles(curcon.win, curcon.wtitle, -1)
ENDPROC

-> newest match at index >= from whose line CONTAINS the fragment;
-> TRUE = found (ebuf/cpos/sridx updated), FALSE = kept as it was
PROC srfind(from)
  DEF avail, idx, h:PTR TO CHAR, fl, hl, i, j, ok, f:PTR TO CHAR,
      got
  fl := StrLen(curcon.srbuf)
  IF fl = 0 THEN RETURN FALSE
  f := curcon.srbuf
  got := FALSE
  avail := Min(ghtotal, HISTMAX)
  IF from < 0 THEN from := 0
  FOR idx := from TO avail - 1
    IF got = FALSE
      h := ghist[Mod(ghtotal - 1 - idx, HISTMAX)]
      hl := StrLen(h)
      i := 0
      WHILE (got = FALSE) AND (i <= (hl - fl))
        ok := TRUE
        FOR j := 0 TO fl - 1
          IF tcfold(h[i + j]) <> tcfold(f[j]) THEN ok := FALSE
        ENDFOR
        IF ok
          got := TRUE
          curcon.sridx := idx
          StrCopy(curcon.ebuf, h)
          WHILE StrLen(curcon.ebuf) > edcap()
            SetStr(curcon.ebuf, StrLen(curcon.ebuf) - 1)
          ENDWHILE
          curcon.cpos := StrLen(curcon.ebuf)
        ENDIF
        i++
      ENDWHILE
    ENDIF
  ENDFOR
ENDPROC got

PROC srenter()
  IF curcon.srbuf = NIL THEN RETURN
  curcon.srch := TRUE
  StrCopy(curcon.srstash, curcon.ebuf)
  StrCopy(curcon.srbuf, '')
  curcon.sridx := -1
  srtitle()
  drawedit()                    -> the [search: ] chip appears NOW
ENDPROC

PROC sradd(code)
  IF StrLen(curcon.srbuf) >= 60 THEN RETURN
  StrAdd(curcon.srbuf, [code, 0]:CHAR, 1)
  IF srfind(curcon.sridx) = FALSE THEN DisplayBeep(NIL)
  srtitle()                     -> the current match may still hold -
  drawedit()                    -> bash keeps it, so do we
ENDPROC

PROC srback()
  DEF l
  l := StrLen(curcon.srbuf)
  IF l > 0
    SetStr(curcon.srbuf, l - 1)
    curcon.sridx := -1
    srfind(0)                   -> widening prefers the newest again
  ENDIF
  srtitle()
  drawedit()
ENDPROC

PROC srnext()
  IF srfind(curcon.sridx + 1) = FALSE THEN DisplayBeep(NIL)
  srtitle()
  drawedit()
ENDPROC

-> leave search mode keeping the match in the line (Enter commits
-> it right after; movement keys edit it)
PROC srexit()
  curcon.srch := FALSE
  curcon.hpos := -1
  settitle()
  IF curcon.sb THEN drawmodelrow(curcon.ancy)  -> the real prompt
  drawedit()                                   -> comes back from
ENDPROC                                        -> the model

-> Esc: the search never happened
PROC srcancel()
  curcon.srch := FALSE
  StrCopy(curcon.ebuf, curcon.srstash)
  curcon.cpos := StrLen(curcon.ebuf)
  curcon.hpos := -1
  settitle()
  IF curcon.sb THEN drawmodelrow(curcon.ancy)
  drawedit()
ENDPROC

-> ---------- fish-style autosuggestions ----------
-> While you type, the newest history entry the line prefixes shows
-> its continuation as grey ghost text after the blip; Right (or
-> Shift+Right/End) accepts all of it, Ctrl+Right one word. The
-> ghost is pixels only - never in the model, never in the commit,
-> gone the moment the line stops matching. Case-folded matching
-> (tcfold), verbatim acceptance from the history string.

-> the pen the ghost draws with; -1 = no readable grey exists on
-> this screen, so no suggestions are shown at all (a ghost in the
-> default pen would read as typed text - worse than nothing)
PROC ghostpen()
  IF curcon.wbpens AND curcon.can16 THEN RETURN 8
  IF curcon.anstab[0] >= 0 THEN RETURN curcon.anstab[0]
ENDPROC -1

-> newest history entry strictly longer than ebuf that ebuf
-> prefixes, case-folded; result in curcon.sghost
PROC sgfind()
  DEF l, avail, idx, h:PTR TO CHAR, i, ok, s:PTR TO CHAR
  curcon.sghost := NIL
  s := curcon.ebuf
  l := StrLen(curcon.ebuf)
  IF l = 0 THEN RETURN
  avail := Min(ghtotal, HISTMAX)
  FOR idx := 0 TO avail - 1
    IF curcon.sghost = NIL
      h := ghist[Mod(ghtotal - 1 - idx, HISTMAX)]
      IF StrLen(h) > l
        ok := TRUE
        FOR i := 0 TO l - 1
          IF tcfold(h[i]) <> tcfold(s[i]) THEN ok := FALSE
        ENDFOR
        IF ok THEN curcon.sghost := h
      ENDIF
    ENDIF
  ENDFOR
ENDPROC

-> accept the whole suggestion (Right/Shift+Right at line end)
PROC sgall()
  StrCopy(curcon.ebuf, curcon.sghost)
  WHILE StrLen(curcon.ebuf) > edcap()
    SetStr(curcon.ebuf, StrLen(curcon.ebuf) - 1)
  ENDWHILE
  curcon.cpos := StrLen(curcon.ebuf)
ENDPROC

-> accept one word of it (Ctrl+Right or Tab): leading spaces ride
-> along with the token they precede, fish fashion - from `ls` a
-> ghost of ` -la` comes across in ONE stroke, not a space first
PROC sgword()
  DEF s:PTR TO CHAR, g:PTR TO CHAR, l, i, cap
  s := curcon.ebuf
  g := curcon.sghost
  l := StrLen(curcon.ebuf)
  cap := edcap()
  i := l
  WHILE (g[i] = 32) AND (l < cap)
    s[l] := g[i]
    l++
    i++
  ENDWHILE
  WHILE (g[i] <> 0) AND (g[i] <> 32) AND (l < cap)
    s[l] := g[i]
    l++
    i++
  ENDWHILE
  s[l] := 0
  SetStr(curcon.ebuf, l)
  curcon.cpos := l
ENDPROC

-> does history entry idx (0 = newest) start with pfx, case-folded?
-> an empty pfx matches everything - the plain, unfiltered Up/Down
-> walk (an empty prompt) is just this with a no-op filter, not a
-> separate code path.
PROC histmatches(idx, pfx:PTR TO CHAR)
  DEF h:PTR TO CHAR, pl, i
  pl := StrLen(pfx)
  IF pl = 0 THEN RETURN TRUE
  h := ghist[Mod(ghtotal - 1 - idx, HISTMAX)]
  IF StrLen(h) < pl THEN RETURN FALSE
  FOR i := 0 TO pl - 1
    IF tcfold(h[i]) <> tcfold(pfx[i]) THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

-> put history entry idx (0 = newest) into ebuf, cut to fit
PROC histload(idx)
  StrCopy(curcon.ebuf, ghist[Mod(ghtotal - 1 - idx, HISTMAX)])
  WHILE StrLen(curcon.ebuf) > edcap()
    SetStr(curcon.ebuf, StrLen(curcon.ebuf) - 1)
  ENDWHILE
ENDPROC

PROC dovanilla(code, qual)
  DEF s:PTR TO CHAR, l, j, k
  snaplive()                    -> typing returns the view to live
  IF curcon.rawmode
    -> raw: every key is just a byte for the client - Return is CR 13,
    -> Ctrl+C is byte 3 (no break signal), Ctrl+\ is byte 28 (no EOF)
    enqueue(code)
    inputarrived()
    RETURN
  ENDIF
  -> Ctrl+R search mode swallows its own keys; Enter exits keeping
  -> the match and FALLS THROUGH to the normal commit (bash runs the
  -> match), any unhandled key exits keeping the match and acts
  IF curcon.srch
    IF code = 18
      srnext()
      RETURN
    ELSEIF code = 27
      srcancel()
      RETURN
    ELSEIF code = 8
      srback()
      RETURN
    ELSEIF ((code >= 32) AND (code <= 126)) OR (code >= 160)
      sradd(code)
      RETURN
    ELSE
      srexit()
    ENDIF
  ENDIF
  IF code = 18
    srenter()                   -> Ctrl+R: into search mode
    RETURN
  ENDIF
  IF code = 9
    -> Tab: completion (M5b); Shift+Tab cycles the menu backwards
    dotab(qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT))
    RETURN
  ENDIF
  IF curcon.tcactive
    IF code = 13
      tcclose()   -> Enter ACCEPTS the selection and closes the menu;
      RETURN      -> the line stays put for a second Enter (zsh style)
    ELSEIF code = 27
      tcclose()   -> Esc closes the menu, the line survives
      RETURN
    ENDIF
    tcclose()     -> any other key closes it, then acts normally
  ENDIF
  s := curcon.ebuf
  l := StrLen(curcon.ebuf)
  IF code = 13
    -> commit: echo the line into the transcript, feed the readers.
    -> Theme B: history remembers a pasted line with its PASTENL
    -> pilcrows still in it (so Up/Down recall re-shows them
    -> correctly, still editable, exactly like a fresh paste would)
    -> - only AFTER that does pasteundo turn them back into the
    -> real newlines render()/enqueue() need, so a multi-line paste
    -> echoes as proper multi-row output and the shell reads it as
    -> the several separate commands it always was.
    eraseedit()
    IF l > 0
      histremember(curcon.ebuf)  -> shared ring (Theme B)
      -> flush to disk on every command, not just last-window-close -
      -> a reset/crash mid-session must not cost the whole session
      -> (his catch: closing every window was the only save point,
      -> so an unclean reboot lost everything since the last close)
      savehistfile()
    ENDIF
    pasteundo(curcon.ebuf, l)
    render(curcon.ebuf, l)
    outnl()
    FOR j := 0 TO l - 1
      enqueue(s[j])
    ENDFOR
    enqueue(10)
    StrCopy(curcon.ebuf, '')
    curcon.cpos := 0
    curcon.hpos := -1
    reanchor()
    drawedit()
    inputarrived()
  ELSEIF code = 28
    -> Ctrl+\ : EOF for the next (or a waiting) read
    curcon.eofpend := TRUE
    satisfyreads()
  ELSEIF (code >= 3) AND (code <= 6)
    -> Ctrl+C..F: forward the break to the current break owner
    IF curcon.breaktask
      Signal(curcon.breaktask, Shl(SIGBREAKF_CTRL_C, code - 3))
    ENDIF
  ELSEIF code = 27
    -> a pending multi-line paste (its embedded newlines still
    -> showing as PASTENL pilcrows) is just ordinary ebuf content
    -> now - clearing the line clears all of it, nothing separate
    -> left over to surprise a later Enter
    StrCopy(curcon.ebuf, '')
    curcon.cpos := 0
    drawedit()
  ELSEIF code = 8
    -> Backspace: delete before the cursor, close the gap
    IF curcon.cpos > 0
      FOR j := curcon.cpos TO l - 1
        s[j - 1] := s[j]
      ENDFOR
      SetStr(curcon.ebuf, l - 1)
      curcon.cpos := curcon.cpos - 1
      drawedit()
    ENDIF
  ELSEIF code = 127
    -> Del: delete under the cursor
    IF curcon.cpos < l
      FOR j := curcon.cpos + 1 TO l - 1
        s[j - 1] := s[j]
      ENDFOR
      SetStr(curcon.ebuf, l - 1)
      drawedit()
    ENDIF
  ELSEIF code = 21
    -> Ctrl+U (readline): kill from line start to the cursor
    IF curcon.cpos > 0
      FOR j := curcon.cpos TO l - 1
        s[j - curcon.cpos] := s[j]
      ENDFOR
      SetStr(curcon.ebuf, l - curcon.cpos)
      curcon.cpos := 0
      drawedit()
    ENDIF
  ELSEIF code = 11
    -> Ctrl+K (readline): kill from the cursor to line end
    IF curcon.cpos < l
      SetStr(curcon.ebuf, curcon.cpos)
      s[curcon.cpos] := 0
      drawedit()
    ENDIF
  ELSEIF code = 23
    -> Ctrl+W (readline): delete the word before the cursor -
    -> trailing spaces first, then the token, gap closed
    IF curcon.cpos > 0
      j := curcon.cpos
      WHILE (j > 0) AND (s[j - 1] = 32)
        j--
      ENDWHILE
      WHILE (j > 0) AND (s[j - 1] <> 32)
        j--
      ENDWHILE
      FOR k := curcon.cpos TO l - 1
        s[k - (curcon.cpos - j)] := s[k]
      ENDFOR
      SetStr(curcon.ebuf, l - (curcon.cpos - j))
      curcon.cpos := j
      drawedit()
    ENDIF
  ELSEIF code = 12
    -> Ctrl+L (readline): clear the screen, keep the line - the
    -> visible rows scroll into HISTORY (Shift+Up brings them back;
    -> nothing is destroyed), the prompt row lands at the top
    eraseedit()
    WHILE curcon.cy > 0
      screenscroll()
      curcon.cy := curcon.cy - 1
    ENDWHILE
    drawedit()
  ELSEIF ((code >= 32) AND (code <= 126)) OR (code >= 160)
    -> Latin-1 high half too: Swedish keymaps type beyond ASCII;
    -> typed characters insert at the cursor, not just append
    IF l < edcap()
      FOR j := l - 1 TO curcon.cpos STEP -1
        s[j + 1] := s[j]
      ENDFOR
      s[curcon.cpos] := code
      SetStr(curcon.ebuf, l + 1)
      curcon.cpos := curcon.cpos + 1
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
  DEF s:PTR TO CHAR, l, avail, sh, idx
  sh := qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
  -> Tab can arrive as a RAW key when the keymap has no vanilla
  -> mapping for its shifted form: dispatch it to completion too
  IF (code = $42) AND (curcon.rawmode = FALSE)
    IF curcon.srch THEN srexit()
    dotab(sh)
    RETURN TRUE
  ENDIF
  -> raw keys close an open completion menu - EXCEPT the qualifier
  -> keys themselves ($60-$67: Shift, Ctrl, Alt, Amiga - Shift+Tab
  -> starts with a bare Shift down-stroke), key releases (bit 7),
  -> and the keys dovanilla treats specially WHILE the menu is open:
  -> Return $44 / keypad Enter $43 (accept + close, line stays for a
  -> second Enter - zsh menu-select) and Esc $45 (close, line
  -> survives). Closing here first made Enter EXECUTE the line and
  -> Esc WIPE it - dovanilla saw tcactive already FALSE. Latent
  -> since M6 put every key through this proc; the IDCMP path
  -> delivered Return as VANILLAKEY only and never showed it.
  IF curcon.tcactive
    IF ((code AND $80) = 0) AND ((code < $60) OR (code > $67)) AND
       (code <> $44) AND (code <> $43) AND (code <> $45)
      tcclose()
    ENDIF
  ENDIF
  -> the mouse wheel scrolls the view in BOTH modes, three lines a
  -> tick (NewMouse: wheel up/down ride the input stream as rawkeys
  -> $7A/$7B); like Ctrl-arrows it never snaps and never reaches
  -> the client
  IF code = $7A
    scrollview(3)
    RETURN TRUE
  ELSEIF code = $7B
    scrollview(-3)
    RETURN TRUE
  ENDIF
  -> M5 scroll keys, checked before anything else: Ctrl+Up/Down by
  -> line in BOTH modes (raw clients never receive Ctrl-arrows -
  -> rawcsikey ignores the qualifier), Shift+Up/Down by page in
  -> cooked only (raw clients own shifted arrows as CSI T/S)
  IF (code = RK_UP) OR (code = RK_DOWN)
    IF qual AND IEQUALIFIER_CONTROL
      scrollview(IF code = RK_UP THEN 1 ELSE -1)
      RETURN TRUE
    ELSEIF (sh <> 0) AND (curcon.rawmode = FALSE)
      scrollview(IF code = RK_UP THEN curcon.rows - 1 ELSE -(curcon.rows - 1))
      RETURN TRUE
    ENDIF
  ENDIF
  -> a bare qualifier down-stroke is not "any other key": Shift
  -> pressed to BEGIN Shift+Up paging must not snap a scrolled view
  -> back to live (the M5b menu lesson, applied to the view at
  -> last). Bit 7 covers releases for the IDCMP fallback - the
  -> chain path already drops those in ihkey.
  IF ((code AND $80) <> 0) OR ((code >= $60) AND (code <= $67)) THEN RETURN TRUE
  snaplive()                    -> any other key returns the view to live
  IF curcon.rawmode
    RETURN rawcsikey(code, qual)
  ENDIF
  -> ONLY the arrows exit search mode here (keeping the match for
  -> editing): every ordinary key passes through this proc on its
  -> RAW pass before the keymap makes its vanilla byte - an
  -> unconditional exit killed the search before the letter could
  -> reach it (the two-pass trap, third sighting tonight)
  IF curcon.srch
    IF (code = RK_UP) OR (code = RK_DOWN) OR
       (code = RK_LEFT) OR (code = RK_RIGHT) THEN srexit()
  ENDIF
  s := curcon.ebuf
  l := StrLen(curcon.ebuf)
  IF code = RK_UP
    -> Up/Down walk the prompt history (output scrollback lives on
    -> Shift/Ctrl, above). Whatever was on the line when the walk
    -> STARTS becomes a prefix filter for the whole walk (fish/zsh
    -> style) - an empty prompt filters nothing, so this is also
    -> the plain unfiltered walk, not a separate path. Editing the
    -> recalled line mid-walk does not change the filter; stash
    -> was already captured.
    avail := ghtotal
    IF avail > HISTMAX THEN avail := HISTMAX
    IF curcon.hpos = -1 THEN StrCopy(curcon.stash, curcon.ebuf)  -> the half-typed line / filter
    idx := curcon.hpos + 1
    WHILE (idx < avail) AND (histmatches(idx, curcon.stash) = FALSE)
      idx++
    ENDWHILE
    IF idx < avail
      curcon.hpos := idx
      histload(curcon.hpos)
      curcon.cpos := StrLen(curcon.ebuf)
      drawedit()
    ENDIF
  ELSEIF code = RK_DOWN
    IF curcon.hpos >= 0
      idx := curcon.hpos - 1
      WHILE (idx >= 0) AND (histmatches(idx, curcon.stash) = FALSE)
        idx--
      ENDWHILE
      curcon.hpos := idx
      IF curcon.hpos = -1
        StrCopy(curcon.ebuf, curcon.stash)    -> back to the half-typed line
      ELSE
        histload(curcon.hpos)
      ENDIF
      curcon.cpos := StrLen(curcon.ebuf)
      drawedit()
    ENDIF
  ELSEIF code = RK_LEFT
    -> Shift = all the way (the house rule), Ctrl = word jump
    IF qual AND IEQUALIFIER_CONTROL
      WHILE (curcon.cpos > 0) AND (s[curcon.cpos - 1] = 32)
        curcon.cpos := curcon.cpos - 1
      ENDWHILE
      WHILE (curcon.cpos > 0) AND (s[curcon.cpos - 1] <> 32)
        curcon.cpos := curcon.cpos - 1
      ENDWHILE
    ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
      curcon.cpos := 0
    ELSEIF curcon.cpos > 0
      curcon.cpos := curcon.cpos - 1
    ENDIF
    drawedit()
  ELSEIF code = RK_RIGHT
    IF (curcon.cpos = l) AND (curcon.sghost <> NIL)
      -> the ghost accepts (fish): Right and Shift+Right take all
      -> of it, Ctrl+Right the next word and its trailing space
      IF qual AND IEQUALIFIER_CONTROL
        sgword()
      ELSE
        sgall()
      ENDIF
    ELSEIF qual AND IEQUALIFIER_CONTROL
      WHILE (curcon.cpos < l) AND (s[curcon.cpos] <> 32)
        curcon.cpos := curcon.cpos + 1
      ENDWHILE
      WHILE (curcon.cpos < l) AND (s[curcon.cpos] = 32)
        curcon.cpos := curcon.cpos + 1
      ENDWHILE
    ELSEIF qual AND (IEQUALIFIER_LSHIFT OR IEQUALIFIER_RSHIFT)
      curcon.cpos := StrLen(curcon.ebuf)
    ELSEIF curcon.cpos < l
      curcon.cpos := curcon.cpos + 1
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
-> Each console's `armed` flag is the arming switch: the main task
-> sets it only while a fully initialized window exists, and the
-> console list itself is only ever mutated under Forbid (this proc
-> runs in input.device's TASK, which Forbid holds off).
PROC ihchain(list:PTR TO inputevent)
  DEF ev:PTR TO inputevent, ib:PTR TO intuitionbase, e:PTR TO ihev,
      take, got, c, k:PTR TO console
  got := FALSE
  IF conlist                    -> M10b: whichever ARMED console owns
    ib := intuitionbase         -> the active window takes the events;
    k := conbywin(ib.activewindow)  -> its pointer rides the ring slot
    IF k
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
          IF k.evmask AND Shl(1, c) THEN take := TRUE
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
            e.con := k
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
  DEF e:PTR TO ihev, c
  WHILE ihtail <> ihhead
    e := ihring + Shl(ihtail AND (IHMAX - 1), 5)
    c := e.con                  -> the console the chain captured for;
    IF conok(c)                 -> a scrubbed or dead tag is dropped
      curcon := c
      IF e.cls = IECLASS_RAWKEY
        IF curcon.evmask AND Shl(1, IECLASS_RAWKEY)
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
  IF ((cd >= $68) AND (cd <= $7F)) AND
     (cd <> $7A) AND (cd <> $7B) THEN RETURN  -> buttons, comm codes
                                -> - but the NewMouse wheel pair
                                -> passes: dorawkey scrolls on them
  IF cd < $60 THEN clearsel()   -> any real key drops the highlight
                                -> (bare qualifiers keep it)
  IF (curcon.selon = FALSE) AND (curcon.wqn > 0) THEN flushwq()
                                -> belt: a lost button-up (ring
                                -> overflow) must not park writers
                                -> forever
  IF q AND IEQUALIFIER_RCOMMAND
    -> RAMIGA-V pastes (M7). Other RAMIGA combos fall through
    -> unchanged. Theme B: MapRawKey already folded Shift into the
    -> mapped letter, so "V" (Shift held) IS the RAMIGA+SHIFT+V
    -> override - force the old every-line-runs behaviour for just
    -> this one paste, no PASTEEXEC option needed for a one-off.
    n := ihmaprawkey(e)
    IF n = 1
      IF (ihmap[0] = "v") OR (ihmap[0] = "V")
        dopaste(ihmap[0] = "V")
        RETURN
      ENDIF
      IF (ihmap[0] = "c") OR (ihmap[0] = "C")
        -> RAMIGA-C re-copies the standing highlight - release
        -> already copied, but the stock muscle memory is free
        IF curcon.sello >= 0 THEN selcopy()
        RETURN
      ENDIF
    ENDIF
  ENDIF
  IF dorawkey(cd, q) THEN RETURN
  n := ihmaprawkey(e)
  IF curcon.rawmode
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
  IF curcon.rdn > 0
    pkt := curcon.rdq[0]
    sender := pkt.port
    t := sender.sigtask
  ELSEIF curcon.breaktask
    t := curcon.breaktask
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
  curcon.fsdirport := NIL
  curcon.fsdirlock := 0
  curcon.fsdirfree := FALSE
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
    curcon.fsdirport := fl.task
    IF len = 0
      curcon.fsdirlock := proc.currentdir     -> scan the CWD itself; not ours
      RETURN TRUE                      -> to free
    ENDIF
    res := fscall(curcon.fsdirport, ACTION_LOCATE_OBJECT, proc.currentdir,
                  tcbstr(dcopy), SHARED_LOCK)
    IF res = 0 THEN RETURN FALSE
    curcon.fsdirlock := res
    curcon.fsdirfree := TRUE
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
    curcon.fsdirlock := dl.lock
    UnLockDosList(LDF_READ OR LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
    IF curcon.fsdirlock = 0 THEN RETURN FALSE  -> late/nonbinding, unresolved
    fl := Shl(curcon.fsdirlock, 2)
    curcon.fsdirport := fl.task
    IF (colon + 1) < len
      res := fscall(curcon.fsdirport, ACTION_LOCATE_OBJECT, curcon.fsdirlock,
                    tcbstr(dcopy + colon + 1), SHARED_LOCK)
      IF res = 0 THEN RETURN FALSE
      curcon.fsdirlock := res
      curcon.fsdirfree := TRUE
    ENDIF
    RETURN TRUE
  ENDIF
  -> a volume or device: its handler port takes the whole "NAME:path"
  -> name against a zero lock (what dos.library itself does)
  curcon.fsdirport := dl.task
  UnLockDosList(LDF_READ OR LDF_DEVICES OR LDF_VOLUMES OR LDF_ASSIGNS)
  IF curcon.fsdirport = NIL THEN RETURN FALSE  -> not mounted/started; starting
  res := fscall(curcon.fsdirport, ACTION_LOCATE_OBJECT, 0,  -> it needs DOS
                tcbstr(dcopy), SHARED_LOCK)
  IF res = 0 THEN RETURN FALSE
  curcon.fsdirlock := res
  curcon.fsdirfree := TRUE
ENDPROC TRUE

PROC tcfreelock()
  IF curcon.fsdirfree AND (curcon.fsdirlock <> 0)
    fscall(curcon.fsdirport, ACTION_FREE_LOCK, curcon.fsdirlock, 0, 0)
  ENDIF
  curcon.fsdirlock := 0
  curcon.fsdirfree := FALSE
ENDPROC

-> ---------- v1.1 Theme B: shared + persistent history ----------
-> Writing a file from a handler is the M5b trick in reverse: no
-> Open/Write/Close (those DoPkt on pr_MsgPort - the no-DOS rule),
-> so ACTION_FINDOUTPUT/FINDINPUT/WRITE/READ/END are hand-rolled at
-> exec level instead, same fscall()/tcresolve() plumbing tab
-> completion already proved. The one new piece is acting as the
-> CALLER of FINDOUTPUT/FINDINPUT rather than the answerer: a zeroed
-> filehandle is allocated here (SIZEOF filehandle, offsets cross-
-> checked against amitools' FileHandleStruct - fh_Args at 36, the
-> field this code reads back as .args), its BPTR rides as arg1, and
-> the filesystem writes ITS OWN per-file id into .args - reused as
-> arg1 on every WRITE/READ/END that follows, exactly as fh.args
-> carries the console pointer for OUR clients in dofind() above.

-> add a line to the shared ring: newest last, consecutive repeats
-> collapse to one. Shared by live Enter-commits and by loading
-> L:ccon-history at startup - one dedupe rule for both.
PROC histremember(s:PTR TO CHAR)
  DEF dup
  IF StrLen(s) = 0 THEN RETURN
  dup := FALSE
  IF ghtotal > 0
    IF StrCmp(ghist[Mod(ghtotal - 1, HISTMAX)], s) THEN dup := TRUE
  ENDIF
  IF dup = FALSE
    StrCopy(ghist[Mod(ghtotal, HISTMAX)], s)
    ghtotal := ghtotal + 1
  ENDIF
ENDPROC

-> read L:ccon-history (oldest line first) into the shared ring. A
-> missing file is not an error - first run ever, or S: not yet
-> assigned this early. Runs once, at the first real console open
-> (curcon must already be live for tcresolve to scratch through).
PROC loadhistfile()
  DEF fh:PTR TO filehandle, res, port:PTR TO mp, id, i, n,
      buf[256]:ARRAY OF CHAR, line[LINEMAX + 4]:ARRAY OF CHAR, lp, c
  IF tcresolve('L:') = FALSE THEN RETURN
  port := curcon.fsdirport
  fh := New(SIZEOF filehandle)
  IF fh = NIL
    tcfreelock()
    RETURN
  ENDIF
  res := fscall(port, ACTION_FINDINPUT, Shr(fh, 2), curcon.fsdirlock,
                tcbstr('ccon-history'))
  tcfreelock()
  IF res = 0
    Dispose(fh)
    RETURN                      -> no history file yet
  ENDIF
  id := fh.args
  lp := 0
  n := fscall(port, ACTION_READ, id, buf, 255)
  WHILE n > 0
    FOR i := 0 TO n - 1
      c := buf[i]
      IF c = 10
        line[lp] := 0
        IF lp > 0 THEN histremember(line)
        lp := 0
      ELSEIF lp < LINEMAX - 1
        line[lp] := c
        lp++
      ENDIF
    ENDFOR
    n := fscall(port, ACTION_READ, id, buf, 255)
  ENDWHILE
  IF lp > 0
    line[lp] := 0
    histremember(line)
  ENDIF
  fscall(port, ACTION_END, id, 0, 0)
  Dispose(fh)
ENDPROC

-> write the shared ring to L:ccon-history, oldest entry first (the
-> conventional shell-history order). Called after EVERY committed
-> command now (a reset before any window closes must not cost the
-> whole session), so this batches entries into ONE buffer and
-> flushes it in a handful of WRITEs, not one packet per line - 200
-> individual round-trips after every Enter would be felt as lag.
-> Best-effort: a WRITE failure partway through does not abort the
-> loop, ACTION_END still runs to release whatever was opened.
PROC savehistfile()
  DEF fh:PTR TO filehandle, res, port:PTR TO mp, id, i, avail,
      buf[2048]:ARRAY OF CHAR, bp, s:PTR TO CHAR, l
  IF ghtotal = 0 THEN RETURN
  IF tcresolve('L:') = FALSE THEN RETURN
  port := curcon.fsdirport
  fh := New(SIZEOF filehandle)
  IF fh = NIL
    tcfreelock()
    RETURN
  ENDIF
  res := fscall(port, ACTION_FINDOUTPUT, Shr(fh, 2), curcon.fsdirlock,
                tcbstr('ccon-history'))
  tcfreelock()
  IF res = 0
    Dispose(fh)
    RETURN
  ENDIF
  id := fh.args
  avail := Min(ghtotal, HISTMAX)
  bp := 0
  FOR i := 0 TO avail - 1
    s := ghist[Mod(ghtotal - avail + i, HISTMAX)]
    l := 0
    WHILE (s[l] <> 0) AND (l < LINEMAX)
      IF bp >= 2048
        fscall(port, ACTION_WRITE, id, buf, bp)
        bp := 0
      ENDIF
      buf[bp] := s[l]
      bp++
      l++
    ENDWHILE
    IF bp >= 2048
      fscall(port, ACTION_WRITE, id, buf, bp)
      bp := 0
    ENDIF
    buf[bp] := 10
    bp++
  ENDFOR
  IF bp > 0 THEN fscall(port, ACTION_WRITE, id, buf, bp)
  fscall(port, ACTION_END, id, 0, 0)
  Dispose(fh)
ENDPROC

-> is name already a candidate? (case-folded) - only matters once a
-> word can gather candidates from more than one source (Theme B
-> command completion: resident list + several Path directories can
-> legitimately name the same command)
PROC tchas(name:PTR TO CHAR)
  DEF i
  FOR i := 0 TO curcon.tcn - 1
    IF tccmp(curcon.tcc[i] + 1, name) = 0 THEN RETURN TRUE
  ENDFOR
ENDPROC FALSE

-> append one candidate to the pool - the packing tcscanone and
-> tcscancmd both need, factored out once there were two sources
PROC tcadd(name:PTR TO CHAR, isdir, hidden)
  DEF l, p:PTR TO CHAR
  IF tchas(name) THEN RETURN
  l := StrLen(name)
  IF (curcon.tcn >= TCMAX) OR ((curcon.tcpu + l + 3) >= TCPOOLSZ)
    curcon.tcmore := TRUE
    RETURN
  ENDIF
  p := curcon.tcpool + curcon.tcpu
  p[0] := IF isdir THEN 1 ELSE 0
  IF hidden THEN p[0] := p[0] OR 2
  CopyMem(name, p + 1, l + 1)
  curcon.tcc[curcon.tcn] := p
  curcon.tcn := curcon.tcn + 1
  curcon.tcpu := curcon.tcpu + l + 2
ENDPROC

-> scan ONE directory (port/lock) for names starting with the
-> prefix, appending into whatever the pool already holds - the
-> single-directory case (tcscan) resets first; the multi-source
-> case (tcscancmd) resets once and calls this per Path entry
PROC tcscanone(port:PTR TO mp, lock, pfx:PTR TO CHAR, plen)
  DEF res, nbuf[112]:ARRAY OF CHAR, l
  res := fscall(port, ACTION_EXAMINE_OBJECT, lock, Shr(fsfib, 2), 0)
  IF res = 0 THEN RETURN
  IF fsfib.direntrytype <= 0 THEN RETURN   -> a file, not a directory
  WHILE fscall(port, ACTION_EXAMINE_NEXT, lock, Shr(fsfib, 2), 0)
    tcfibname(nbuf)
    l := StrLen(nbuf)
    IF l > 0
      IF (plen = 0) OR tcpref(nbuf, pfx, plen)
        tcadd(nbuf, fsfib.direntrytype > 0, tchidname(nbuf, l, fsfib.protection))
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

-> scan the resolved directory for names starting with the prefix
PROC tcscan(pfx:PTR TO CHAR, plen)
  curcon.tcn := 0
  curcon.tcpu := 0
  curcon.tcmore := FALSE
  tcscanone(curcon.fsdirport, curcon.fsdirlock, pfx, plen)
ENDPROC

-> PARKED (19.7.26 night) - dotab() no longer calls this. Tried as
-> word-one command completion (resident + C: + Path, later merged
-> with the current directory too), but he found it cluttered the
-> menu with entries he didn't want mixed into plain filename
-> completion and asked to revert. Left compiled-in and unused so
-> the plumbing (FindSegment/resident list, the pathnode/Path-chain
-> walk, all struct-offset-verified) doesn't have to be re-derived
-> if this gets picked back up later - see todo.md Theme B #2.
->
-> What it did: resident commands (memory-resident, Forbid()-
-> walkable via FindSegment, no packets - RKM: "must Forbid() lock
-> the list to use this call"), the current directory, C: always,
-> and every directory in the CLI's command path (cli_CommandDir).
PROC tcscancmd(pfx:PTR TO CHAR, plen)
  DEF seg:PTR TO segment, proc:PTR TO process,
      cli:PTR TO commandlineinterface, pnb, pn:PTR TO pathnode,
      fl:PTR TO filelock, port:PTR TO mp
  curcon.tcn := 0
  curcon.tcpu := 0
  curcon.tcmore := FALSE
  Forbid()
  seg := FindSegment(NIL, NIL, TRUE)
  WHILE seg
    IF seg.uc = CMD_INTERNAL
      IF (plen = 0) OR tcpref(seg.name, pfx, plen) THEN tcadd(seg.name, FALSE, FALSE)
    ENDIF
    seg := FindSegment(NIL, seg, TRUE)
  ENDWHILE
  Permit()
  -> the current directory too - his catch: word-one completion
  -> was searching ONLY where the shell would find something to
  -> RUN, which meant sitting in RAM: and hitting Tab showed C:'s
  -> commands while ignoring RAM: entirely. Merge, don't exclude -
  -> `d<Tab>` in RAM: should offer `demo/` from RAM: AND `delete`
  -> from C: in the same menu, not pick one source and hide the
  -> other. tcresolve('') is the exact same CWD lookup plain word
  -> completion already used (tcclient's blocked-reader current
  -> dir) - just called explicitly instead of from a typed dirpart.
  IF tcresolve('')
    tcscanone(curcon.fsdirport, curcon.fsdirlock, pfx, plen)
    tcfreelock()
  ENDIF
  -> C: always, regardless of the Path chain below - the shell
  -> finds C: commands whether or not Path was ever touched,
  -> completion should too. tchas already dedupes against anything
  -> the chain also turns up (C: is normally in it by default).
  IF tcresolve('C:')
    tcscanone(curcon.fsdirport, curcon.fsdirlock, pfx, plen)
    tcfreelock()
  ENDIF
  proc := tcclient()
  IF proc = NIL THEN RETURN
  IF proc.cli = 0 THEN RETURN
  cli := Shl(proc.cli, 2)
  pnb := cli.commanddir
  WHILE pnb
    pn := Shl(pnb, 2)
    IF pn.lock
      fl := Shl(pn.lock, 2)
      port := fl.task
      IF port THEN tcscanone(port, pn.lock, pfx, plen)
    ENDIF
    pnb := pn.next
  ENDWHILE
ENDPROC

PROC tcsort()
  DEF i, j, key, go
  FOR i := 1 TO curcon.tcn - 1
    key := curcon.tcc[i]
    j := i - 1
    go := TRUE
    WHILE go
      IF j < 0
        go := FALSE
      ELSEIF tccmp(curcon.tcc[j] + 1, key + 1) > 0
        curcon.tcc[j + 1] := curcon.tcc[j]
        j--
      ELSE
        go := FALSE
      ENDIF
    ENDWHILE
    curcon.tcc[j + 1] := key
  ENDFOR
ENDPROC

-> length of the folded common prefix of all candidates
PROC tccommon()
  DEF l, i, k, a:PTR TO CHAR, b:PTR TO CHAR
  a := curcon.tcc[0] + 1
  l := StrLen(a)
  FOR k := 1 TO curcon.tcn - 1
    b := curcon.tcc[k] + 1
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
  s := curcon.ebuf
  l := StrLen(curcon.ebuf)
  newlen := curcon.tcws + nl + (l - curcon.tcwend)
  IF newlen > edcap() THEN RETURN FALSE
  IF curcon.tcactive
    -> the menu's rows are frozen (tcmrow0): while it is open a
    -> candidate may not grow the line down into it
    IF (curcon.ancx + newlen + 1) > Mul(curcon.tcmrow0 - curcon.ancy, curcon.cols) THEN RETURN FALSE
  ENDIF
  StrCopy(curcon.tctail, s + curcon.tcwend)
  t := curcon.tctail
  FOR i := 0 TO nl - 1
    s[curcon.tcws + i] := nt[i]
  ENDFOR
  FOR i := 0 TO StrLen(curcon.tctail) - 1
    s[curcon.tcws + nl + i] := t[i]
  ENDFOR
  SetStr(curcon.ebuf, newlen)
  s[newlen] := 0
  curcon.tcwend := curcon.tcws + nl
  curcon.cpos := curcon.tcwend
ENDPROC TRUE

-> ---------- the menu below the prompt ----------

-> repaint one screen row from the live model (menu cleanup)
PROC drawmodelrow(r)
  DEF idx
  IF curcon.sb = NIL THEN RETURN
  idx := curcon.sbtop + r
  IF idx >= curcon.sbmax THEN idx := idx - curcon.sbmax
  drawmrow(idx, curcon.topy + Mul(r, curcon.ch))
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
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
  IF flag AND 2                 -> hidden-class grey
    IF curcon.wbpens THEN RETURN 8
    IF curcon.anstab[0] >= 0 THEN RETURN curcon.anstab[0]
    RETURN curcon.deffg
  ENDIF
  IF flag AND 1                 -> directory blue
    IF curcon.wbpens THEN RETURN 12
    IF curcon.anstab[4] >= 0 THEN RETURN curcon.anstab[4]
    RETURN 3                    -> the classic WB blue pen
  ENDIF
ENDPROC curcon.deffg

PROC tcmenucalc()
  DEF i, l, maxl, p:PTR TO CHAR
  maxl := 1
  FOR i := 0 TO curcon.tcn - 1
    p := curcon.tcc[i]
    l := StrLen(p + 1) + (p[0] AND 1)  -> dirs show a trailing '/'
    IF l > maxl THEN maxl := l
  ENDFOR
  curcon.tcmcolw := maxl + 2
  IF curcon.tcmcolw > curcon.cols THEN curcon.tcmcolw := curcon.cols
  curcon.tcmcols := Div(curcon.cols, curcon.tcmcolw)
  IF curcon.tcmcols < 1 THEN curcon.tcmcols := 1
  curcon.tcmrows := Div(curcon.tcn + curcon.tcmcols - 1, curcon.tcmcols)
  IF curcon.tcmrows > (curcon.rows - 1)       -> more than fits: show the first
    curcon.tcmrows := curcon.rows - 1         -> page, cycle within it
    curcon.tcmore := TRUE
  ENDIF
  curcon.tcshown := Mul(curcon.tcmrows, curcon.tcmcols)
  IF curcon.tcshown > curcon.tcn THEN curcon.tcshown := curcon.tcn
ENDPROC

PROC tcmenudraw()
  DEF idx, r, c, p:PTR TO CHAR, l, nb[260]:ARRAY OF CHAR
  FOR idx := 0 TO curcon.tcshown - 1
    r := Div(idx, curcon.tcmcols)
    c := idx - Mul(r, curcon.tcmcols)
    p := curcon.tcc[idx]
    l := StrLen(p + 1)
    CopyMem(p + 1, nb, l)
    IF p[0] AND 1
      nb[l] := "/"
      l++
    ENDIF
    WHILE l < curcon.tcmcolw
      nb[l] := 32
      l++
    ENDWHILE
    IF idx = curcon.tcsel
      SetAPen(curcon.rp, 0)
      SetBPen(curcon.rp, curcon.deffg)
    ELSE
      SetAPen(curcon.rp, menupen(p[0]))
      SetBPen(curcon.rp, 0)
    ENDIF
    Move(curcon.rp, curcon.left + Mul(Mul(c, curcon.tcmcolw), curcon.cw),
         curcon.topy + Mul(curcon.tcmrow0 + r, curcon.ch) + curcon.baseline)
    Text(curcon.rp, nb, l)
  ENDFOR
  SetAPen(curcon.rp, curcon.deffg)
  SetBPen(curcon.rp, 0)
ENDPROC

-> close the menu: the rows under it come back from the model
PROC tcclose()
  DEF r
  IF curcon.tcactive = FALSE THEN RETURN
  FOR r := 0 TO curcon.tcmrows - 1
    drawmodelrow(curcon.tcmrow0 + r)
  ENDFOR
  curcon.tcactive := FALSE
  curcon.tcsel := -1
ENDPROC

-> Tab in the cooked editor. First Tab completes (whole match, or the
-> common prefix + the menu); further Tabs cycle the menu, Shift+Tab
-> backwards; Enter accepts and closes, Esc closes, anything else
-> closes and then acts normally.
PROC dotab(back)
  DEF s:PTR TO CHAR, l, i, sep, plen, cpl, p:PTR TO CHAR,
      dirp[300]:ARRAY OF CHAR
  IF curcon.tcactive
    IF curcon.tcshown = 0 THEN RETURN
    IF back
      curcon.tcsel := curcon.tcsel - 1
      IF curcon.tcsel < 0 THEN curcon.tcsel := curcon.tcshown - 1
    ELSE
      curcon.tcsel := curcon.tcsel + 1
      IF curcon.tcsel >= curcon.tcshown THEN curcon.tcsel := 0
    ENDIF
    p := curcon.tcc[curcon.tcsel]
    StrCopy(curcon.tctmp, p + 1)
    IF p[0] AND 1 THEN StrAdd(curcon.tctmp, '/')
    IF tcreplace(curcon.tctmp, StrLen(curcon.tctmp)) THEN drawedit()
    tcmenudraw()
    RETURN
  ENDIF
  -> v1.1 (19.7.26, the s:ccon-* lesson): Tab NEVER accepts the
  -> ghost any more - `type s:c<Tab>` wanted the completion menu
  -> and got history's suggestion instead. Tab is completion's key,
  -> whole and alone; ghosts are accepted by Right/Shift+Right (all)
  -> and Ctrl+Right (word) only. 1.0 had Tab prefer a visible ghost.
  IF (fsport = NIL) OR (fspkt = NIL) OR (fsfib = NIL) OR
     (fsname = NIL) OR (curcon.tcpool = NIL) THEN RETURN
  s := curcon.ebuf
  l := StrLen(curcon.ebuf)
  -> the word: back from the cursor to the last space (v1: no quotes)
  i := curcon.cpos
  WHILE (i > 0) AND (s[i - 1] <> 32)
    i := i - 1
  ENDWHILE
  curcon.tcws := i
  curcon.tcwend := curcon.cpos
  -> split the word at its last '/' or ':': dirpart + prefix
  sep := curcon.tcws
  FOR i := curcon.tcws TO curcon.cpos - 1
    IF (s[i] = "/") OR (s[i] = ":") THEN sep := i + 1
  ENDFOR
  IF (sep - curcon.tcws) > 280 THEN RETURN
  FOR i := 0 TO sep - curcon.tcws - 1
    dirp[i] := s[curcon.tcws + i]
  ENDFOR
  dirp[sep - curcon.tcws] := 0
  plen := curcon.cpos - sep
  -> candidates are BARE names: replacement must start after the
  -> dirpart, or `version l:c<Tab>` eats its "l:" (latent since
  -> M5b - plain words never showed it, path words always did)
  curcon.tcws := sep
  -> Theme B #2 (word-one command completion) tried and reverted,
  -> parked for later (19.7.26 night) - cluttered the menu with
  -> C:/resident/Path entries he didn't want mixed into plain
  -> filename completion. tcscancmd() and its plumbing stay in the
  -> source, unused, for whenever it's picked back up (see todo.md).
  -> Every word, including the first, is plain filename completion
  -> again - the pre-Theme-B-#2 behaviour, unchanged.
  IF tcresolve(dirp) = FALSE
    DisplayBeep(NIL)
    RETURN
  ENDIF
  tcscan(s + sep, plen)
  tcfreelock()
  IF curcon.tcn = 0
    DisplayBeep(NIL)
    RETURN
  ENDIF
  tcsort()
  IF curcon.tcn = 1
    -> the one match: complete it, '/' opens a dir, ' ' ends a file
    p := curcon.tcc[0]
    StrCopy(curcon.tctmp, p + 1)
    StrAdd(curcon.tctmp, IF (p[0] AND 1) THEN '/' ELSE ' ')
    IF tcreplace(curcon.tctmp, StrLen(curcon.tctmp))
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
    p := curcon.tcc[0]
    FOR i := 0 TO cpl - 1
      curcon.tctmp[i] := p[1 + i]
    ENDFOR
    curcon.tctmp[cpl] := 0
    SetStr(curcon.tctmp, cpl)
    IF tcreplace(curcon.tctmp, cpl) THEN drawedit()
  ENDIF
  IF curcon.sb = NIL THEN RETURN   -> no model = no way to restore the rows
  tcmenucalc()              -> under a menu; prefix-only completion
  WHILE ((edlastrow(StrLen(curcon.ebuf)) + curcon.tcmrows) > (curcon.rows - 1)) AND (curcon.ancy > 0)
    screenscroll()          -> make room below the (wrapped) edit
    IF curcon.cy > 0 THEN curcon.cy := curcon.cy - 1     -> line; its pixels scroll along, anchor
  ENDWHILE                  -> and output cursor track it
  curcon.tcmrow0 := edlastrow(StrLen(curcon.ebuf)) + 1
  curcon.tcsel := -1
  curcon.tcactive := TRUE
  tcmenudraw()
  IF curcon.tcmore THEN DisplayBeep(NIL)  -> more than the menu shows
ENDPROC

-> ---------- cooked input plumbing ----------

PROC enqueue(c)
  DEF nt
  nt := Mod(curcon.inqt + 1, INQMAX)
  IF nt <> curcon.inqh               -> full queue drops (should never happen)
    curcon.inq[curcon.inqt] := c
    curcon.inqt := nt
  ENDIF
ENDPROC

PROC inavail() IS Mod(curcon.inqt - curcon.inqh + INQMAX, INQMAX)

-> reply queued reads while finished-line bytes (or an EOF) are there;
-> a read gets at most one line - cooked semantics - and a short buffer
-> gets the rest of the line on its next read
PROC satisfyreads()
  DEF pkt:PTR TO dospacket, dst:PTR TO CHAR, max, n, c, i, stop
  WHILE (curcon.rdn > 0) AND ((inavail() > 0) OR curcon.eofpend)
    pkt := curcon.rdq[0]
    FOR i := 1 TO curcon.rdn - 1
      curcon.rdq[i - 1] := curcon.rdq[i]
    ENDFOR
    curcon.rdn := curcon.rdn - 1
    IF inavail() = 0
      curcon.eofpend := FALSE          -> EOF is one-shot
      ReplyPkt(pkt, 0, 0)
    ELSE
      dst := pkt.arg2
      max := pkt.arg3
      n := 0
      stop := FALSE
      WHILE (n < max) AND (stop = FALSE) AND (inavail() > 0)
        c := curcon.inq[curcon.inqh]
        curcon.inqh := Mod(curcon.inqh + 1, INQMAX)
        dst[n] := c
        n++
        IF (c = 10) AND (curcon.rawmode = FALSE) THEN stop := TRUE
      ENDWHILE
      ReplyPkt(pkt, n, 0)
    ENDIF
  ENDWHILE
ENDPROC

vers: CHAR '$VER: ccon-handler 1.1b28 CCON: LTX console handler', 0
