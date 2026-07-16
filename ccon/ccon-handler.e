-> ccon-handler.e - CCON: LTX console handler. Milestone 1: mount, speak
-> the DOS packet protocol, render ACTION_WRITE into a plain window.
->
-> Test:  Mount CCON: FROM DEVS:CCON-mountlist
->        echo >CCON: "hello from the packet side"
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
-> dos.library calls that send packets (Open/Lock/...) - DoPkt waits on
-> pr_MsgPort, the same port our clients send to. Intuition and graphics
-> only. ReplyPkt/WaitPkt are safe (PutMsg/WaitPort underneath).

MODULE 'intuition/intuition',
       'utility/tagitem',
       'exec/nodes','exec/ports',
       'graphics/rastport',
       'dos/dos','dos/dosextens','dos/filehandler'

CONST MARGIN=4

DEF port:PTR TO mp,             -> our packet port = pr_MsgPort
    win=NIL:PTR TO window,
    ch,                         -> line height (font)
    opens                       -> open stream count

PROC main()
  DEF proc:PTR TO process, msg:PTR TO mn, pkt:PTR TO dospacket,
      dnode:PTR TO devicenode, len

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

  WHILE TRUE
    pkt := WaitPkt()
    SELECT pkt.type
    CASE ACTION_FINDINPUT;  dofind(pkt)
    CASE ACTION_FINDOUTPUT; dofind(pkt)
    CASE ACTION_FINDUPDATE; dofind(pkt)
    CASE ACTION_END
      opens--                     -> window stays: M1 keeps it for inspection
      ReplyPkt(pkt, DOSTRUE, 0)
    CASE ACTION_WRITE
      len := pkt.arg3
      render(pkt.arg2, len)
      ReplyPkt(pkt, len, 0)
    CASE ACTION_READ
      ReplyPkt(pkt, 0, 0)         -> EOF for now; M2 brings the line editor
    CASE ACTION_SCREEN_MODE
      ReplyPkt(pkt, DOSTRUE, 0)   -> accepted, ignored; M4 brings raw mode
    DEFAULT
      ReplyPkt(pkt, DOSFALSE, ERROR_ACTION_NOT_KNOWN)
    ENDSELECT
  ENDWHILE
ENDPROC

PROC dofind(pkt:PTR TO dospacket)
  DEF fh:PTR TO filehandle
  IF win = NIL THEN openwin()
  IF win
    fh := Shl(pkt.arg1, 2)      -> BPTR to the FileHandle DOS made
    fh.args := 1                -> our stream id (single stream for now)
    fh.interactive := DOSTRUE   -> we are a console
    opens++
    ReplyPkt(pkt, DOSTRUE, 0)
  ELSE
    ReplyPkt(pkt, DOSFALSE, ERROR_NO_FREE_STORE)
  ENDIF
ENDPROC

PROC openwin()
  DEF rp:PTR TO rastport
  win := OpenWindowTagList(NIL,
    [WA_TITLE, 'CCON: M1', WA_LEFT, 40, WA_TOP, 40,
     WA_WIDTH, 520, WA_HEIGHT, 160,
     WA_DRAGBAR, TRUE, WA_DEPTHGADGET, TRUE,
     WA_ACTIVATE, TRUE,
     TAG_DONE, NIL])
  IF win = NIL THEN RETURN
  rp := win.rport
  ch := rp.txheight
  SetAPen(rp, 1)
  Move(rp, win.borderleft + MARGIN, win.bordertop + MARGIN + rp.txbaseline)
ENDPROC

-> M1 renderer: LF/CR/TAB plus printable bytes, pixel wrap, crude scroll.
-> The real renderer (CSI parser, scrollback) transplants in later.
PROC render(buf, len)
  DEF i, c, rp:PTR TO rastport
  IF win = NIL THEN RETURN
  rp := win.rport
  FOR i := 0 TO len - 1
    c := Char(buf + i) AND $FF
    IF c = 10
      newline(rp)
    ELSEIF c = 13
      Move(rp, win.borderleft + MARGIN, rp.cp_y)
    ELSEIF c = 9
      Text(rp, '  ', 2)
    ELSEIF c >= 32
      Text(rp, buf + i, 1)
      IF rp.cp_x > (win.width - win.borderright - 10) THEN newline(rp)
    ENDIF
  ENDFOR
ENDPROC

PROC newline(rp:PTR TO rastport)
  DEF y
  y := rp.cp_y + ch
  IF y > (win.height - win.borderbottom - 2)
    ScrollRaster(rp, 0, ch,
                 win.borderleft, win.bordertop,
                 win.width - win.borderright - 1,
                 win.height - win.borderbottom - 1)
    y := rp.cp_y
  ENDIF
  Move(rp, win.borderleft + MARGIN, y)
ENDPROC

vers: CHAR '$VER: ccon-handler 0.1 (16.7.26) CCON: LTX console handler M1', 0
