-> ikeys.e - type keys into the active window, as the keyboard would:
-> raw key events written into input.device (IND_WRITEEVENT), so every
-> input handler - CCON's own chain included - sees them. For driving the
-> checklists remotely (wasabi run 'ikeys ...'); wasabi itself does not
-> synthesise keys, by design.
->
-> ikeys "TEXT"   plain characters go through MapANSI (the active keymap)
->   {tab} {ret} {esc} {bs} {del} {up} {down} {left} {right} {space}
->   a prefix on any of those or on a single character:
->     c- Ctrl   s- Shift   a- Alt   la- left Amiga   ra- right Amiga
->     e.g. {c-h} {c-bs} {s-tab} {a-tab} {ra-i} {c-a-left}
->   {wN}   wait N ticks (50 = 1 s)
-> Every key is a down and an up event, 2 ticks apart.
->
-> Build: ecompile ikeys.e ikeys

MODULE 'exec/io', 'exec/ports', 'devices/input', 'devices/inputevent',
       'keymap'

DEF req:PTR TO iostd, ie:PTR TO inputevent

PROC sendkey(code, qual)
  ie.nextevent := NIL
  ie.class := IECLASS_RAWKEY
  ie.subclass := 0
  ie.code := code
  ie.qualifier := qual
  ie.eventaddress := NIL
  req.command := IND_WRITEEVENT
  req.data := ie
  req.length := SIZEOF inputevent
  DoIO(req)
  Delay(1)
  ie.nextevent := NIL
  ie.class := IECLASS_RAWKEY
  ie.code := code OR IECODE_UP_PREFIX
  ie.qualifier := qual
  req.command := IND_WRITEEVENT
  req.data := ie
  req.length := SIZEOF inputevent
  DoIO(req)
  Delay(1)
ENDPROC

-> a character's raw code and qualifiers on the active keymap, -1 = none
PROC mapchar(c, qp:PTR TO LONG)
  DEF s[2]:ARRAY OF CHAR, b[16]:ARRAY OF CHAR
  s[0] := c
  IF MapANSI(s, 1, b, 8, NIL) < 1 THEN RETURN -1
  qp[0] := b[1]
ENDPROC b[0]

PROC named(n:PTR TO CHAR)
  IF StrCmp(n, 'tab') THEN RETURN $42
  IF StrCmp(n, 'ret') THEN RETURN $44
  IF StrCmp(n, 'esc') THEN RETURN $45
  IF StrCmp(n, 'bs') THEN RETURN $41
  IF StrCmp(n, 'del') THEN RETURN $46
  IF StrCmp(n, 'up') THEN RETURN $4C
  IF StrCmp(n, 'down') THEN RETURN $4D
  IF StrCmp(n, 'right') THEN RETURN $4E
  IF StrCmp(n, 'left') THEN RETURN $4F
  IF StrCmp(n, 'space') THEN RETURN $40
ENDPROC -1

PROC main()
  DEF port, s:PTR TO CHAR, i, j, t[40]:STRING, q, code, mq, n, bad=0
  keymapbase := OpenLibrary('keymap.library', 37)
  IF keymapbase = NIL THEN RETURN 20
  port := CreateMsgPort()
  req := CreateIORequest(port, SIZEOF iostd)
  ie := New(SIZEOF inputevent)
  IF (req = NIL) OR (ie = NIL) THEN RETURN 20
  IF OpenDevice('input.device', 0, req, 0) <> 0 THEN RETURN 20
  s := arg                        -> E hands over the raw line: drop one
  i := 0                          -> pair of outer quotes (and the newline)
  n := StrLen(s)
  WHILE (n > 0) AND (s[n - 1] <= " ") DO n--
  IF (n >= 2) AND (s[0] = 34) AND (s[n - 1] = 34)
    i := 1
    n--
  ENDIF
  s[n] := 0
  WHILE s[i]
    IF s[i] = "{"
      j := i + 1
      WHILE (s[j] <> "}") AND (s[j] <> 0) DO j++
      StrCopy(t, s + i + 1, j - i - 1)
      i := IF s[j] THEN j + 1 ELSE j
      IF t[0] = "w"
        Delay(Val(t + 1))
      ELSE
        q := 0
        LOOP
          IF StrCmp(t, 'c-', 2)
            q := q OR IEQUALIFIER_CONTROL
            StrCopy(t, t + 2)
          ELSEIF StrCmp(t, 's-', 2)
            q := q OR IEQUALIFIER_LSHIFT
            StrCopy(t, t + 2)
          ELSEIF StrCmp(t, 'a-', 2)
            q := q OR IEQUALIFIER_LALT
            StrCopy(t, t + 2)
          ELSEIF StrCmp(t, 'la-', 3)
            q := q OR IEQUALIFIER_LCOMMAND
            StrCopy(t, t + 3)
          ELSEIF StrCmp(t, 'ra-', 3)
            q := q OR IEQUALIFIER_RCOMMAND
            StrCopy(t, t + 3)
          ELSE
            JUMP pdone
          ENDIF
        ENDLOOP
pdone:
        code := named(t)
        IF (code < 0) AND (StrLen(t) = 1)
          mq := 0
          code := mapchar(t[0], {mq})
          q := q OR mq
        ENDIF
        IF code >= 0 THEN sendkey(code, q) ELSE bad++
      ENDIF
    ELSE
      mq := 0
      code := mapchar(s[i], {mq})
      IF code >= 0 THEN sendkey(code, mq) ELSE bad++
      i++
    ENDIF
  ENDWHILE
  CloseDevice(req)
  DeleteIORequest(req)
  DeleteMsgPort(port)
  CloseLibrary(keymapbase)
  IF bad THEN WriteF('ikeys: \d key(s) not mapped\n', bad)
ENDPROC IF bad THEN 5 ELSE 0
