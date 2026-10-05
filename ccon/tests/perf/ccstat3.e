/* ccstat2 - read (and optionally zero) CCON.prof counters. usage: ccstat2 [RESET] */
MODULE 'exec/ports', 'exec/nodes', 'exec/io', 'timer', 'devices/timer'

PROC main()
  DEF p:PTR TO mp, d:PTR TO LONG, i, v[64]:ARRAY OF LONG, reset, freq,
      tr:PTR TO timerequest, ev:eclockval, us, names
  reset := InStr(arg, 'RESET') >= 0
  names := ['busy', 'idle', 'dopkt', 'flushout', 'render', 'dfflush',
            'drawmrow', 'dfspans', 'frun', 'dfstart', 'dorender', 'dpaint',
            'ppsetup', 'drawcells', 'fcall3', 'dpplanar', 'C frun', 'C scroll', 'C ppaint', 'C full', 'C lock', 'C lfrun', 'C cfout', 'C wacc', 'C 8', 'C 9', 'C 10', 'C 11', 'C 12', 'C 13', 'C 14']
  tr := NEW tr
  IF OpenDevice('timer.device', UNIT_ECLOCK, tr, 0) = 0
    timerbase := tr.io.device
    freq := ReadEClock(ev)
  ELSE
    RETURN 10
  ENDIF
  Forbid()
  p := FindPort('CCON.prof')
  IF p
    d := p + SIZEOF mp + 2
    d := And(d + 3, $FFFFFFFC)
    FOR i := 0 TO 61
      v[i] := d[i]
      IF reset THEN d[i] := 0
    ENDFOR
  ENDIF
  Permit()
  CloseDevice(tr)
  IF p = NIL
    WriteF('no CCON.prof port\n')
    RETURN 5
  ENDIF
  IF reset THEN RETURN 0
  WriteF('  phase          total ms     count    us/call\n')
  WriteF('  rows painted \d, cells \d, mask sum \d, rows scrolled \d\n', v[48], v[49], v[50], v[51])
  FOR i := 0 TO 30
    us := IF v[Shl(i, 1) + 1] THEN Div(Mul(Div(v[Shl(i, 1)], v[Shl(i, 1) + 1]), 1000), Div(freq, 1000)) ELSE 0
    IF v[Shl(i, 1) + 1] THEN WriteF('  \l\s[12] \r\d[10] \r\d[9] \r\d[10]\n', ListItem(names, i),
           Div(v[Shl(i, 1)], Div(freq, 1000)), v[Shl(i, 1) + 1], us)
  ENDFOR
ENDPROC
