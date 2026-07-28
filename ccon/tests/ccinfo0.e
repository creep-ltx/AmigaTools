-> ccinfo0.e - send ACTION_DISK_INFO with a NIL InfoData to CCON:'s
-> handler, to test audit5 A2.
->
-> A correct client never does this (Info() always passes a real
-> buffer), so no stock command can exercise the guard - this
-> hand-rolls the malformed packet, the same PutMsg/WaitPort/GetMsg
-> shape ccdie.e uses. DISK_INFO carries no file handle; the handler
-> routes it by SENDER (conbysender: the caller's CLI stdin), so this
-> MUST be run from inside a CCON: window or it never reaches a
-> console at all (ERROR_OBJECT_NOT_FOUND - a valid pass for the
-> routing, but not the guard under test).
->
-> Before the A2 fix (1.2.6b3 and earlier): the handler zeroes
-> addresses 0-35 - the ExecBase pointer at 4 included - and the
-> machine is on borrowed time. AFTER: DOSFALSE + ERROR_BAD_NUMBER
-> and everything keeps running.
->
-> Build: ecompile ccinfo0.e ccinfo0      (small model is fine)
-> Run on the Amiga, FROM A CCON: SHELL: ccinfo0

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
  sp.pkt.type := ACTION_DISK_INFO
  sp.pkt.arg1 := 0                -> THE test: a NIL InfoData BPTR
  sp.pkt.port := rp               -> reply here, a private port
  sp.msg.replyport := rp

  WriteF('sending ACTION_DISK_INFO with arg1=0 (NIL InfoData)...\n')
  PutMsg(port, sp.msg)
  WaitPort(rp)
  GetMsg(rp)
  res := sp.pkt.res1

  IF res
    WriteF('res1=\d (DOSTRUE): the handler ANSWERED a NIL InfoData -\n', res)
    WriteF('the A2 guard is missing. Addresses 0-35 were just zeroed;\n')
    WriteF('reboot NOW, do not trust this session.\n')
  ELSE
    WriteF('res1=0, res2=\d: refused clean - the A2 guard works\n', sp.pkt.res2)
    WriteF('(expected res2 = ERROR_BAD_NUMBER; ERROR_OBJECT_NOT_FOUND\n')
    WriteF('means the packet found no console - run this from a\n')
    WriteF('CCON: shell, not a stock one).\n')
  ENDIF

  END sp
  DeleteMsgPort(rp)
ENDPROC
