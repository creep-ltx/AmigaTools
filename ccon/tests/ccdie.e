-> ccdie.e - send ACTION_DIE to CCON:'s handler, to test audit B5.
->
-> AmigaOS 3.x has no stock command that asks a handler to shut down,
-> so this hand-rolls the packet (the same PutMsg/WaitPort/GetMsg shape
-> ccon-handler's own fscall uses). It targets the CCON: device
-> specifically - a dedicated device whose process is separate from
-> whatever your shell runs on, so it can be told to die while your
-> shell keeps running.
->
-> B5 refuses to die (DOSFALSE) while a CCON: window is open, and tears
-> down cleanly (removes its input.device handler, closes its devices,
-> exits) when none is. So: open a CCON: window, use it, CLOSE it, then
-> run this. See tests/README.md for the full step-by-step.
->
-> Build: ecompile ccdie.e ccdie      (small model is fine)
-> Run on the Amiga: ccdie

MODULE 'dos/dos', 'dos/dosextens', 'exec/ports', 'exec/nodes'

PROC main()
  DEF dl:PTR TO doslist, port:PTR TO mp, rp:PTR TO mp,
      sp:PTR TO standardpacket, res

  -> find CCON:'s handler port (dol_Task) without opening any handle
  dl := LockDosList(LDF_READ OR LDF_DEVICES)
  dl := FindDosEntry(dl, 'CCON', LDF_DEVICES)
  port := NIL
  IF dl THEN port := dl.task
  UnLockDosList(LDF_READ OR LDF_DEVICES)
  IF port = NIL
    WriteF('CCON: has no running handler.\n')
    WriteF('Mounted? And referenced this boot (NewShell CCON:)?\n')
    RETURN
  ENDIF
  WriteF('CCON: handler port = $\h\n', port)

  rp := CreateMsgPort()
  IF rp = NIL THEN RETURN
  sp := New(SIZEOF standardpacket)
  IF sp = NIL
    DeleteMsgPort(rp)
    RETURN
  ENDIF
  sp.msg.ln.name := sp.pkt        -> a packet rides in its message
  sp.pkt.link := sp.msg           -> and points back at the message
  sp.pkt.type := ACTION_DIE
  sp.pkt.arg1 := 0
  sp.pkt.port := rp               -> reply here, a private port
  sp.msg.replyport := rp

  WriteF('sending ACTION_DIE...\n')
  PutMsg(port, sp.msg)
  WaitPort(rp)
  GetMsg(rp)
  res := sp.pkt.res1

  IF res
    WriteF('DOSTRUE (res1=\d): handler agreed - tearing down and exiting.\n', res)
    WriteF('Now: open a CCON: window again (a fresh handler should start\n')
    WriteF('clean), and check keys still echo right. A guru here = a\n')
    WriteF('teardown bug.\n')
  ELSE
    WriteF('DOSFALSE (res2=\d): refused. A CCON: window is still open -\n', sp.pkt.res2)
    WriteF('close every CCON: window and run this again.\n')
  ENDIF

  END sp
  DeleteMsgPort(rp)
ENDPROC
