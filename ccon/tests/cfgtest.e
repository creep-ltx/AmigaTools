-> cfgtest.e - the 1.2.7b8/b9 config reader and options, proven on Linux
->
-> b8 gave CCON: a defaults file, L:ccon.cfg, whose whole design is
-> that it has NO parser of its own: parsecon grounds the built-ins,
-> replays the file through parseopt, then parses the open string, so
-> the precedence rule
->     built-in  <  L:ccon.cfg  <  the open string
-> is the order of three calls and nothing else. That makes the file
-> side pure string work - splitting, trimming, section state - which
-> is exactly what vamos can prove and a boot cannot show you.
->
-> b9 adds the keys the file exists for: geometry as EDGES
-> (LEFT/TOP/RIGHT/BOTTOM, -1 = fill) and pins for the three derived
-> colour roles (DIRS/HIDDEN/GHOST), plus TEXT= as PEN='s name.
->
-> Every proc between the two markers below is the handler's own,
-> VERBATIM (the harness-extraction discipline) - keep them
-> byte-identical to ccon-handler.e or this proves nothing. Only the
-> file READ (loadcfgfile: tcresolve + FINDINPUT/READ/END) stays
-> boot-tested; it is the same no-DOS plumbing loadhistfile has been
-> running since v1.1.
->
-> Build: ecompile cfgtest.e cfgtest
-> Run:   vamos cfgtest

MODULE 'dos/dos'

CONST TCMAX=80, TCPOOLSZ=4096
CONST RK_UP=$4C, RK_DOWN=$4D, RK_RIGHT=$4E, RK_LEFT=$4F

-> the fields the extracted procs touch, same names and shapes as the
-> handler's console object so the verbatim procs compile unchanged
OBJECT con
  waitmode, closegad, pauto, pnoborder, pnodrag, pnodepth, pnosize,
  pbackdrop, pinactive, pasteexec, wbpens, deffg, fwptr, plines,
  pfontsize, pfontexp,
  pwx, pwy, pww, pwh, pwr, pwb,
  pdirs, phid, pghost, pcfgdef,
  pcfgsect[40]:ARRAY OF CHAR,
  wtitlebase:PTR TO CHAR,
  piconpath[104]:ARRAY OF CHAR,
  drifill, ovhid, ovgrey, can16,
  anstab[8]:ARRAY OF LONG,
  tcc[80]:ARRAY OF LONG,
  tcpool:PTR TO CHAR,
  tcpu, tcn, tcmore, tcsel, tcshown, tcmcols,
  pscrname[64]:ARRAY OF CHAR,
  pfontname[36]:ARRAY OF CHAR
ENDOBJECT

DEF curcon:PTR TO con, cc:con, fails, tests

-> ---- the handler's procs, verbatim from ccon-handler.e ----
PROC tcfold(c)
  IF (c >= "a") AND (c <= "z") THEN RETURN c - 32
  IF (c >= 224) AND (c <= 254) AND (c <> 247) THEN RETURN c - 32
ENDPROC c

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
  -> ---- 1.2.7b8: the inverses ----
  -> Every boolean below needs a way to be spoken BOTH ways, because
  -> L:ccon.cfg can now set any of them for every window on the
  -> system and the rule is that a runtime open string outranks the
  -> file. Without these, a config that says NOBORDER could not be
  -> overridden by any open string in existence - the precedence
  -> would be a claim, not a fact. CLOSE/NOCLOSE was the only pair
  -> that already existed.
  -> NOWAIT clears waitmode ONLY: WAIT forces the close gadget on
  -> because it needs one to end, but that is a forcing, not part of
  -> what WAIT means - taking the gadget away here would be a second,
  -> unasked-for change.
  ELSEIF StrCmp(tok, 'NOWAIT')
    curcon.waitmode := FALSE
  ELSEIF StrCmp(tok, 'CLOSE')
    curcon.closegad := TRUE
  ELSEIF StrCmp(tok, 'NOCLOSE')
    curcon.closegad := FALSE
  ELSEIF StrCmp(tok, 'AUTO')
    curcon.pauto := TRUE           -> the window waits for first I/O
  ELSEIF StrCmp(tok, 'NOAUTO')
    curcon.pauto := FALSE
  ELSEIF StrCmp(tok, 'NOBORDER')
    curcon.pnoborder := TRUE
  ELSEIF StrCmp(tok, 'BORDER')
    curcon.pnoborder := FALSE
  ELSEIF StrCmp(tok, 'NODRAG')
    curcon.pnodrag := TRUE
  ELSEIF StrCmp(tok, 'DRAG')
    curcon.pnodrag := FALSE
  ELSEIF StrCmp(tok, 'NODEPTH')
    curcon.pnodepth := TRUE
  ELSEIF StrCmp(tok, 'DEPTH')
    curcon.pnodepth := FALSE
  ELSEIF StrCmp(tok, 'NOSIZE')
    curcon.pnosize := TRUE
  ELSEIF StrCmp(tok, 'SIZE')
    curcon.pnosize := FALSE
  ELSEIF StrCmp(tok, 'BACKDROP')
    curcon.pbackdrop := TRUE
  ELSEIF StrCmp(tok, 'NOBACKDROP')
    curcon.pbackdrop := FALSE
  ELSEIF StrCmp(tok, 'INACTIVE')
    curcon.pinactive := TRUE
  ELSEIF StrCmp(tok, 'ACTIVE')
    curcon.pinactive := FALSE
  ELSEIF StrCmp(tok, 'PASTEEXEC')
    -> Theme B: opt this WHOLE window back into the 1.0/pre-safety
    -> behaviour - every RAMIGA-V runs each pasted line as it lands,
    -> no queueing. RAMIGA+SHIFT+V still overrides per-paste even
    -> without this option; this is for someone who wants that to
    -> just always be how the window behaves.
    curcon.pasteexec := TRUE
  ELSEIF StrCmp(tok, 'NOPASTEEXEC')
    curcon.pasteexec := FALSE
  -> the exact-match inverses sit BEFORE their prefix-matched
  -> positives. Not needed today (StrCmp(tok,'SCREEN',6) cannot match
  -> "NOSCREE" and StrCmp(tok,'FONT',4) cannot match "NOFO"), but a
  -> prefix rule that grows a character later would silently start
  -> eating its own inverse, and that failure is invisible.
  ELSEIF StrCmp(tok, 'NOSCREEN')
    curcon.pscrname[0] := 0        -> back to the default public screen
  ELSEIF StrCmp(tok, 'SCREEN', 6)
    -> SCREENname, stock syntax: open on that public screen
    -> (name taken case-preserved from the raw token). A bare
    -> "SCREEN" with nothing after is NOT a match - matters now
    -> that field 4 (the title) tries this too: a title that
    -> merely STARTS with a keyword must fall through to being
    -> a title, not a silently-broken option.
    v := 6
    IF tok2[v] = "=" THEN v := 7    -> 1.2.7b8: the '=' form, as
    c := 0                          -> LINES/FONT already had
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
  ELSEIF StrCmp(tok, 'NOWBPENS')
    curcon.wbpens := FALSE
  ELSEIF StrCmp(tok, 'PEN', 3)
    -> PENn: the default text pen (CTerm sends PEN7 with its
    -> ANSI palette, where pen 1 is ANSI red)
    -> 1.2.7b8: the '=' skip LINES and FONT have always had. An open
    -> string cannot carry an unquoted '=' (the shell eats it, see the
    -> warning in parsecon's notes), but L:ccon.cfg is KEY=value
    -> throughout - and without this, PEN=7 handed tcnum the string
    -> "=7", got -1 back, and was dropped without a sound.
    -> PEN=0 stays refused by the range test below: text drawn in the
    -> background colour is a window that looks broken.
    v := 3
    IF tok[v] = "=" THEN v := 4
    v := tcnum(tok + v)
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
    -> SBMAXCAP (5000, v1.1b44 - room for beefier systems).
    v := 5
    IF tok[v] = "=" THEN v := 6
    v := tcnum(tok + v)
    IF v >= 0 THEN curcon.plines := v ELSE matched := FALSE
  -> ---- 1.2.7b9: geometry as EDGES, for the config file ----
  -> LEFT/TOP are pwx/pwy under a name; RIGHT/BOTTOM are the edges,
  -> folded into pww/pwh by openwin once there is a screen to measure.
  -> Each checks the literal "-1" BEFORE tcnum, exactly as parsecon's
  -> positional width/height do: tcnum has no minus support and its -1
  -> return already means "invalid, leave the default", so without
  -> this the two meanings collide and FILL reads as DO NOTHING.
  ELSEIF StrCmp(tok, 'LEFT', 4)
    v := 4
    IF tok[v] = "=" THEN v := 5
    v := tcnum(tok + v)
    IF v >= 0 THEN curcon.pwx := v ELSE matched := FALSE
  ELSEIF StrCmp(tok, 'TOP', 3)
    v := 3
    IF tok[v] = "=" THEN v := 4
    v := tcnum(tok + v)
    IF v >= 0 THEN curcon.pwy := v ELSE matched := FALSE
  ELSEIF StrCmp(tok, 'RIGHT', 5)
    v := 5
    IF tok[v] = "=" THEN v := 6
    IF StrCmp(tok + v, '-1')
      curcon.pwr := -1             -> fill to the screen edge
    ELSE
      v := tcnum(tok + v)
      IF v >= 0 THEN curcon.pwr := v ELSE matched := FALSE
    ENDIF
  ELSEIF StrCmp(tok, 'BOTTOM', 6)
    v := 6
    IF tok[v] = "=" THEN v := 7
    IF StrCmp(tok + v, '-1')
      curcon.pwb := -1
    ELSE
      v := tcnum(tok + v)
      IF v >= 0 THEN curcon.pwb := v ELSE matched := FALSE
    ENDIF
  -> ---- 1.2.7b9: the colour roles ----
  -> TEXT= is PEN= under the name the config file wants; PEN stays
  -> forever, CTerm sends PEN7 on its frame handoff and it has been
  -> documented since v1.1.
  ELSEIF StrCmp(tok, 'TEXT', 4)
    v := 4
    IF tok[v] = "=" THEN v := 5
    v := tcnum(tok + v)
    IF (v >= 1) AND (v <= 15) THEN curcon.deffg := v ELSE matched := FALSE
  -> DIRS/HIDDEN/GHOST pin what b4-b7 derive from the screen. NOT
  -> nibble-capped like the text pen: these never enter the attr
  -> plane, they are chrome drawn straight to the RastPort (ovgrey is
  -> explicitly "UNCAPPED - a pixels-only user"), so 0..255.
  -> 0 is refused for the same reason PEN=0 is: the window's own
  -> clear is SetAPen(0) + RectFill, so pen 0 IS the background and
  -> an entry drawn in it is not dim, it is gone. The DERIVED path
  -> already says as much - menupen tests drifill > 0 and falls
  -> through to deffg when the fill role resolves to pen 0.
  -> A pin is an OVERRIDE, and worth knowing what it overrides: the
  -> derivation exists because hardcoded pens 8/12 broke on Timm's
  -> CGX, on CTerm ("yellow = no thank you") and on the boot screen.
  -> Someone pinning a number is opting back into that failure mode
  -> for a palette they know. Absent = keep scanning.
  ELSEIF StrCmp(tok, 'DIRS', 4)
    v := 4
    IF tok[v] = "=" THEN v := 5
    v := tcnum(tok + v)
    IF (v >= 1) AND (v <= 255) THEN curcon.pdirs := v ELSE matched := FALSE
  ELSEIF StrCmp(tok, 'HIDDEN', 6)
    v := 6
    IF tok[v] = "=" THEN v := 7
    v := tcnum(tok + v)
    IF (v >= 1) AND (v <= 255) THEN curcon.phid := v ELSE matched := FALSE
  ELSEIF StrCmp(tok, 'GHOST', 5)
    v := 5
    IF tok[v] = "=" THEN v := 6
    v := tcnum(tok + v)
    IF (v >= 1) AND (v <= 255) THEN curcon.pghost := v ELSE matched := FALSE
  -> 1.2.7b14: both were read by cfgpre BEFORE any of this ran, so
  -> there is nothing to do here. They are matched all the same, for
  -> two reasons: parsecon's f=0 shortcut only switches the whole
  -> spec to options-only when the first field names a REAL option
  -> (CCON:DEFAULTS/LINES384 would otherwise parse LINES384 as a
  -> window Y), and an unmatched token at field 4 becomes the title.
  ELSEIF StrCmp(tok, 'DEFAULTS')
    matched := TRUE
  ELSEIF StrCmp(tok, 'CONFIG', 6)
    matched := TRUE
  ELSEIF StrCmp(tok, 'NOFONT')
    curcon.pfontname[0] := 0       -> back to the Font Prefs default
    curcon.pfontsize := 0
    curcon.pfontexp := FALSE       -> already cleared above; explicit
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

PROC edgefold()
  IF curcon.pwr <> -2
    IF curcon.pwr = -1
      curcon.pww := -1
    ELSE
      curcon.pww := curcon.pwr - curcon.pwx
    ENDIF
    curcon.pwr := -2
  ENDIF
  IF curcon.pwb <> -2
    IF curcon.pwb = -1
      curcon.pwh := -1
    ELSE
      curcon.pwh := curcon.pwb - curcon.pwy
    ENDIF
    curcon.pwb := -2
  ENDIF
ENDPROC

PROC menupen(flag)
  IF flag AND 2                 -> hidden-class grey
    IF curcon.phid >= 0 THEN RETURN curcon.phid
    IF curcon.ovhid >= 0 THEN RETURN curcon.ovhid
    RETURN curcon.deffg         -> no dimming grey exists: visible,
  ENDIF                         -> merely undimmed
  IF flag AND 1                 -> directory colour
    IF curcon.pdirs >= 0 THEN RETURN curcon.pdirs
    IF curcon.drifill > 0 THEN RETURN curcon.drifill
  ENDIF                         -> drifill 0 = fill IS the menu's pen-0
ENDPROC curcon.deffg            -> background: fall through, readable

PROC ghostpen()
  IF curcon.pghost >= 0 THEN RETURN curcon.pghost   -> 1.2.7b9 pin
  IF curcon.wbpens AND curcon.can16 THEN RETURN 8
  IF curcon.anstab[0] >= 0 THEN RETURN curcon.anstab[0]
ENDPROC curcon.ovgrey   -> the uncapped overlay grey (32+ colours,

PROC cfgrefuse(tok:PTR TO CHAR)
  DEF t[12]:ARRAY OF CHAR, i
  FOR i := 0 TO 11 DO t[i] := 0
  i := 0
  WHILE (i < 8) AND tok[i]
    t[i] := tcfold(tok[i])
    i++
  ENDWHILE
  IF StrCmp(t, 'WINDOW0X', 8) THEN RETURN TRUE
  -> 1.2.7b14: the two grounding directives are open-string only.
  -> CONFIG inside the file would let a section select another
  -> section - chaining, and loops with it - and DEFAULTS inside the
  -> file is a contradiction: the file IS the defaults.
  IF StrCmp(t, 'DEFAULTS') THEN RETURN TRUE
ENDPROC StrCmp(t, 'CONFIG', 6)

PROC cfgdirective(tok:PTR TO CHAR)
  DEF t[84]:ARRAY OF CHAR, i, v, c
  i := 0
  WHILE tok[i] AND (i < 80)
    t[i] := tcfold(tok[i])
    i++
  ENDWHILE
  t[i] := 0
  IF StrCmp(t, 'DEFAULTS')
    curcon.pcfgdef := TRUE
    RETURN TRUE
  ENDIF
  IF StrCmp(t, 'CONFIG', 6) = FALSE THEN RETURN FALSE
  v := 6
  IF t[v] = "=" THEN v := 7
  c := 0
  WHILE t[v] AND (c < 38)
    curcon.pcfgsect[c] := t[v]   -> kept folded: sections match blind
    c++
    v++
  ENDWHILE
  curcon.pcfgsect[c] := 0
  IF c = 0 THEN RETURN FALSE     -> a bare CONFIG names nothing, and
ENDPROC TRUE                     -> fails closed like SCREEN does

PROC cfgpre(bname)
  DEF s:PTR TO CHAR, l, i, f, tl, tok[84]:ARRAY OF CHAR, optmode=FALSE
  curcon.pcfgdef := FALSE
  curcon.pcfgsect[0] := 0
  IF bname = 0 THEN RETURN
  s := Shl(bname, 2)
  l := s[0]
  i := 1
  WHILE (i <= l) AND (s[i] <> ":")
    i++
  ENDWHILE
  IF i > l THEN RETURN
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
    i++
    tok[tl] := 0
    IF optmode OR (f = 0) OR (f >= 5)
      IF cfgdirective(tok) AND (f = 0) THEN optmode := TRUE
    ENDIF
    f++
  ENDWHILE
ENDPROC

PROC cfgrest(line:PTR TO CHAR, key:PTR TO CHAR, kl)
  DEF i, t[12]:ARRAY OF CHAR
  IF kl > 10 THEN RETURN -1
  FOR i := 0 TO 11 DO t[i] := 0
  i := 0
  WHILE (i < kl) AND line[i]
    t[i] := tcfold(line[i])
    i++
  ENDWHILE
  IF StrCmp(t, key, kl) = FALSE THEN RETURN -1
  IF line[kl] <> "=" THEN RETURN -1
  i := kl + 1
  WHILE (line[i] = " ") OR (line[i] = 9) DO i++
ENDPROC i

PROC cfgapply(line:PTR TO CHAR)
  DEF i, tl, tok[84]:ARRAY OF CHAR
  -> 1.2.7b14: TITLE= takes the REST OF THE LINE, verbatim - no '/'
  -> split, no whitespace split - so a title may contain both. The
  -> one key that opts out of the token rules, because a title is
  -> prose and not a value. Its case survives because nothing has
  -> folded this line: cfgsect only folds inside the brackets of a
  -> section header, and parseopt folds a copy of its own token.
  -> Bounded by wtitlebase being String(84) - E's StrCopy will not
  -> write past an E-string's maxlen, so a long title truncates.
  -> An open string keeps using positional field 4 for this; a
  -> field-4 title cannot hold a '/' anyway, which is the whole
  -> reason TITLE= is a file key.
  i := cfgrest(line, 'TITLE', 5)
  IF i >= 0
    StrCopy(curcon.wtitlebase, line + i)
    RETURN
  ENDIF
  -> 1.2.7b15: ICON= is the other rest-of-line key, for a harder
  -> reason than TITLE's - a path CONTAINS '/', and every other value
  -> here is split on it. Written WITHOUT ".info": GetDiskObject
  -> appends that itself.
  i := cfgrest(line, 'ICON', 4)
  IF i >= 0
    tl := 0
    WHILE line[i] AND (tl < 102)
      curcon.piconpath[tl] := line[i]
      tl++
      i++
    ENDWHILE
    curcon.piconpath[tl] := 0
    RETURN
  ENDIF
  i := 0
  WHILE line[i]
    WHILE (line[i] = " ") OR (line[i] = 9) OR (line[i] = "/") DO i++
    tl := 0
    WHILE line[i] AND (line[i] <> " ") AND (line[i] <> 9) AND
          (line[i] <> "/")
      IF tl < 80
        tok[tl] := line[i]
        tl++
      ENDIF
      i++
    ENDWHILE
    tok[tl] := 0
    IF tl > 0
      IF cfgrefuse(tok) = FALSE THEN parseopt(tok)
    ENDIF
  ENDWHILE
  -> a FONT with no size must not swallow the first bare number on
  -> the NEXT line: name/size is a within-line contract, and parseopt
  -> only clears the flag when it sees another token at all
  curcon.pfontexp := FALSE
ENDPROC

PROC cfgsect(line:PTR TO CHAR, sect:PTR TO CHAR, insect)
  DEF i, j, n
  i := 0
  WHILE line[i] AND (line[i] <> ";") AND (line[i] <> "#") DO i++
  line[i] := 0
  WHILE (i > 0) AND ((line[i - 1] = " ") OR (line[i - 1] = 9))
    i--
    line[i] := 0
  ENDWHILE
  j := 0
  WHILE (line[j] = " ") OR (line[j] = 9) DO j++
  IF line[j] = 0 THEN RETURN insect      -> blank/comment: no change
  IF line[j] = "["
    j++
    n := j
    WHILE line[n] AND (line[n] <> "]") DO n++
    line[n] := 0                         -> a missing ']' just ends
    WHILE (line[j] = " ") OR (line[j] = 9) DO j++
    WHILE (n > j) AND ((line[n - 1] = " ") OR (line[n - 1] = 9))
      n--
      line[n] := 0
    ENDWHILE
    i := j
    WHILE line[i]
      line[i] := tcfold(line[i])
      i++
    ENDWHILE
    RETURN StrCmp(line + j, sect)
  ENDIF
  IF insect THEN cfgapply(line + j)
ENDPROC insect

PROC tcsuffix(f)
  IF f AND 4 THEN RETURN ":"
  IF f AND 1 THEN RETURN "/"
ENDPROC " "

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

PROC tchas(name:PTR TO CHAR)
  DEF i
  FOR i := 0 TO curcon.tcn - 1
    IF tccmp(curcon.tcc[i] + 1, name) = 0 THEN RETURN TRUE
  ENDFOR
ENDPROC FALSE

PROC tcadd(name:PTR TO CHAR, isdir, hidden, dev)
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
  IF dev THEN p[0] := p[0] OR 5
  CopyMem(name, p + 1, l + 1)
  curcon.tcc[curcon.tcn] := p
  curcon.tcn := curcon.tcn + 1
  curcon.tcpu := curcon.tcpu + l + 2
ENDPROC

PROC tcpref(name:PTR TO CHAR, pfx:PTR TO CHAR, len)
  DEF i
  FOR i := 0 TO len - 1
    IF name[i] = 0 THEN RETURN FALSE
    IF tcfold(name[i]) <> tcfold(pfx[i]) THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

PROC tcgridmove(code)
  DEF n, c, k
  IF curcon.tcshown <= 0 THEN RETURN -1
  IF curcon.tcsel < 0 THEN RETURN 0   -> nothing picked yet: the first
  n := curcon.tcsel                   -> arrow simply picks one
  IF code = RK_RIGHT
    n := n + 1
    IF n >= curcon.tcshown THEN n := 0
  ELSEIF code = RK_LEFT
    n := n - 1
    IF n < 0 THEN n := curcon.tcshown - 1
  ELSE
    IF curcon.tcmcols < 1 THEN RETURN n
    c := Mod(n, curcon.tcmcols)
    IF code = RK_DOWN
      n := n + curcon.tcmcols
      IF n >= curcon.tcshown THEN n := c    -> off the bottom of this
    ELSE                                    -> column: back to its top
      n := n - curcon.tcmcols
      IF n < 0                              -> off the top: to the
        k := Div(curcon.tcshown - 1 - c, curcon.tcmcols)   -> LAST entry
        n := c + Mul(k, curcon.tcmcols)     -> this column really has
      ENDIF
    ENDIF
  ENDIF
ENDPROC n

-> ---- end verbatim ----

-> tok/torig in the handler are plain fixed arrays, not String()
-> E-strings, so StrCopy is out here for the same reason parsecon
-> spells its title save as a byte loop
PROC bcopy(d:PTR TO CHAR, s:PTR TO CHAR)
  DEF i=0
  WHILE s[i]
    d[i] := s[i]
    i++
  ENDWHILE
  d[i] := 0
ENDPROC

PROC checkn(tag, got, want)
  tests := tests + 1
  IF got = want
    WriteF('    ok   \s (\d)\n', tag, got)
  ELSE
    WriteF('    FAIL \s\n         got  \d\n         want \d\n',
           tag, got, want)
    fails := fails + 1
  ENDIF
ENDPROC

PROC checks(tag, got:PTR TO CHAR, want:PTR TO CHAR)
  tests := tests + 1
  IF StrCmp(got, want)
    WriteF('    ok   \s ("\s")\n', tag, got)
  ELSE
    WriteF('    FAIL \s\n         got  "\s"\n         want "\s"\n',
           tag, got, want)
    fails := fails + 1
  ENDIF
ENDPROC

-> parsecon's grounding, verbatim in effect: every p* field back to
-> its built-in before the file is replayed
PROC ground()
  cc.waitmode := FALSE
  cc.closegad := TRUE
  cc.fwptr := NIL
  cc.deffg := 1
  cc.wbpens := FALSE
  cc.pauto := FALSE
  cc.pnoborder := FALSE
  cc.pnodrag := FALSE
  cc.pnodepth := FALSE
  cc.pnosize := FALSE
  cc.pbackdrop := FALSE
  cc.pinactive := FALSE
  cc.pasteexec := FALSE
  cc.pscrname[0] := 0
  cc.plines := 0
  cc.pfontname[0] := 0
  cc.pfontsize := 0
  cc.pfontexp := FALSE
  cc.pwx := 0
  cc.pwy := 18
  cc.pww := 640
  cc.pwh := 130
  cc.pwr := -2
  cc.pwb := -2
  cc.pdirs := -1
  cc.phid := -1
  cc.pghost := -1
  cc.pcfgdef := FALSE
  cc.pcfgsect[0] := 0
  StrCopy(cc.wtitlebase, 'CCON:')
  cc.piconpath[0] := 0
  -> not parsecon's to ground - openwin derives these from the screen;
  -> the tests set them where a derived value is what's under test
  cc.drifill := -1
  cc.ovhid := -1
  cc.ovgrey := -1
  cc.can16 := FALSE
  cc.anstab[0] := -1
  cc.tcn := 0
  cc.tcpu := 0
  cc.tcmore := FALSE
  cc.tcsel := -1
  cc.tcshown := 0
  cc.tcmcols := 0
ENDPROC

-> loadcfgfile's line loop with the file read taken out: the same
-> "insect starts TRUE only for DEFAULT" rule, the same cfgsect per
-> line. Does NOT ground - so two feeds in a row are exactly the
-> [DEFAULT]-then-[section] layering CONFIG= will do.
PROC feed(lines:PTR TO LONG, n, sect:PTR TO CHAR)
  DEF i, b[300]:ARRAY OF CHAR, insect
  insect := StrCmp(sect, 'DEFAULT')
  FOR i := 0 TO n - 1
    bcopy(b, lines[i])
    insect := cfgsect(b, sect, insect)
  ENDFOR
ENDPROC

-> one token as an OPEN STRING would deliver it (parseopt folds its
-> argument in place, so it needs a writable buffer)
PROC opt(s:PTR TO CHAR)
  DEF b[84]:ARRAY OF CHAR
  bcopy(b, s)
ENDPROC parseopt(b)

-> the flag byte tcadd packed for candidate i
-> a BSTR (length byte, then chars) in a long-aligned buffer, which
-> is what an open string arrives as
PROC mkbstr(buf:PTR TO CHAR, t:PTR TO CHAR)
  DEF l
  l := StrLen(t)
  buf[0] := l
  CopyMem(t, buf + 1, l)
ENDPROC Shr(buf, 2)

PROC flagof(i)
  DEF p:PTR TO CHAR
  p := cc.tcc[i]
ENDPROC p[0]

PROC main()
  DEF bb[40]:ARRAY OF LONG
  fails := 0
  tests := 0
  curcon := cc
  cc.tcpool := New(TCPOOLSZ)
  cc.wtitlebase := String(84)
  WriteF('cfgtest - the b8 L:ccon.cfg reader\n\n')

  WriteF('--- A: a flat file, no sections at all ---\n')
  -> the rule that keeps sections opt-in: lines before any header
  -> belong to [DEFAULT], so the simplest possible config works
  -> without anyone knowing the concept exists
  ground()
  feed(['LINES=2000', 'PEN=7', 'NOCLOSE'], 3, 'DEFAULT')
  checkn('LINES=2000 lands', cc.plines, 2000)
  checkn('PEN=7 lands', cc.deffg, 7)
  checkn('NOCLOSE lands', cc.closegad, FALSE)

  WriteF('--- B: the = forms b8 had to add ---\n')
  -> PEN and SCREEN never had the "=" skip LINES and FONT have. In an
  -> open string that never showed, because the shell eats an
  -> unquoted '=' anyway - the config file is the first place the
  -> spelling is even reachable, and PEN=7 was silently dropped.
  ground()
  feed(['PEN=7'], 1, 'DEFAULT')
  checkn('PEN=7 (the b8 fix)', cc.deffg, 7)
  ground()
  opt('PEN7')
  checkn('PEN7 still works (open string)', cc.deffg, 7)
  ground()
  feed(['SCREEN=Workbench'], 1, 'DEFAULT')
  checks('SCREEN=name (the b8 fix)', cc.pscrname, 'Workbench')
  ground()
  opt('SCREENWorkbench')
  checks('SCREENname still works', cc.pscrname, 'Workbench')
  ground()
  feed(['PEN=0'], 1, 'DEFAULT')
  checkn('PEN=0 refused, text stays visible', cc.deffg, 1)

  WriteF('--- C: comments, trimming, blanks ---\n')
  ground()
  feed(['; a whole-line comment', '   LINES=1500   ; trailing',
        '', '# a hash comment', '        '], 5, 'DEFAULT')
  checkn('the one real setting landed', cc.plines, 1500)
  checkn('nothing else moved', cc.deffg, 1)
  -> the documented price of one comment rule for the whole file
  ground()
  feed(['SCREEN=My;Screen'], 1, 'DEFAULT')
  checks('; ends a value (documented limit)', cc.pscrname, 'My')

  WriteF('--- D: sections ---\n')
  ground()
  feed(['[DEFAULT]', 'LINES=2000', '[tall]', 'LINES=4000', 'NOCLOSE'],
       5, 'DEFAULT')
  checkn('[DEFAULT] applied', cc.plines, 2000)
  checkn('[tall] not applied', cc.closegad, TRUE)
  ground()
  feed(['[DEFAULT]', 'LINES=2000', '[tall]', 'LINES=4000', 'NOCLOSE'],
       5, 'TALL')
  checkn('[tall] alone applied', cc.plines, 4000)
  checkn('[tall] NOCLOSE applied', cc.closegad, FALSE)
  -> what CONFIG=tall will do: DEFAULT first, then the section over
  -> it - a profile states only its differences
  ground()
  feed(['[DEFAULT]', 'LINES=2000', 'PEN=7', '[tall]', 'LINES=4000'],
       5, 'DEFAULT')
  feed(['[DEFAULT]', 'LINES=2000', 'PEN=7', '[tall]', 'LINES=4000'],
       5, 'TALL')
  checkn('layered: the section wins on LINES', cc.plines, 4000)
  checkn('layered: DEFAULT survives on PEN', cc.deffg, 7)
  ground()
  feed(['[DEFAULT]', 'LINES=2000', '[tall]', 'LINES=4000'], 4, 'NOPE')
  checkn('an unknown section applies nothing', cc.plines, 0)
  -> case and stray blanks inside the brackets
  ground()
  feed(['[  TaLl  ]', 'LINES=4000'], 2, 'TALL')
  checkn('header folded and trimmed', cc.plines, 4000)
  -> pre-header lines are DEFAULT's, and a later section is not
  ground()
  feed(['LINES=2000', '[tall]', 'LINES=4000'], 3, 'DEFAULT')
  checkn('pre-header lines belong to DEFAULT', cc.plines, 2000)

  WriteF('--- E: the inverses (the precedence rule made true) ---\n')
  -> each of these is a boolean the FILE can now set for every window
  -> on the system; without an inverse the open string could not take
  -> it back, and "runtime trumps the file" would be a claim only
  ground()
  feed(['NOBORDER', 'NODRAG', 'NODEPTH', 'NOSIZE', 'BACKDROP',
        'INACTIVE', 'PASTEEXEC', 'WBPENS', 'AUTO', 'WAIT',
        'SCREEN=Workbench', 'FONT=topaz/8'], 12, 'DEFAULT')
  checkn('config set NOBORDER', cc.pnoborder, TRUE)
  opt('BORDER')
  checkn('BORDER takes it back', cc.pnoborder, FALSE)
  opt('DRAG')
  checkn('DRAG takes it back', cc.pnodrag, FALSE)
  opt('DEPTH')
  checkn('DEPTH takes it back', cc.pnodepth, FALSE)
  opt('SIZE')
  checkn('SIZE takes it back', cc.pnosize, FALSE)
  opt('NOBACKDROP')
  checkn('NOBACKDROP takes it back', cc.pbackdrop, FALSE)
  opt('ACTIVE')
  checkn('ACTIVE takes it back', cc.pinactive, FALSE)
  opt('NOPASTEEXEC')
  checkn('NOPASTEEXEC takes it back', cc.pasteexec, FALSE)
  opt('NOWBPENS')
  checkn('NOWBPENS takes it back', cc.wbpens, FALSE)
  opt('NOAUTO')
  checkn('NOAUTO takes it back', cc.pauto, FALSE)
  opt('NOSCREEN')
  checks('NOSCREEN takes it back', cc.pscrname, '')
  opt('NOFONT')
  checks('NOFONT takes it back', cc.pfontname, '')
  checkn('NOFONT clears the size too', cc.pfontsize, 0)
  -> NOWAIT clears waitmode ONLY: WAIT forced the gadget on, but
  -> that is a forcing, not part of what WAIT means
  checkn('WAIT set the close gadget', cc.closegad, TRUE)
  opt('NOWAIT')
  checkn('NOWAIT clears waitmode', cc.waitmode, FALSE)
  checkn('NOWAIT leaves the gadget alone', cc.closegad, TRUE)

  WriteF('--- F: what the file may not carry ---\n')
  -> WINDOW0x is CTerm's live frame handoff. Stored in a file it is
  -> a pointer to a window that died with the last boot, and every
  -> console on the system would try to borrow that corpse.
  ground()
  feed(['WINDOW0x1234'], 1, 'DEFAULT')
  checkn('WINDOW0x refused from the file', cc.fwptr, NIL)
  ground()
  opt('WINDOW0X1234')
  checkn('WINDOW0x still works from an open string', cc.fwptr, $1234)

  WriteF('--- G: FONT, where the / split earns itself ---\n')
  ground()
  feed(['FONT=topaz/8'], 1, 'DEFAULT')
  checks('name from FONT=name/size', cc.pfontname, 'topaz')
  checkn('size from FONT=name/size', cc.pfontsize, 8)
  -> ".font" stays legal inside the value - which is exactly why the
  -> separator could not be a '.'
  ground()
  feed(['FONT=topaz.font/8'], 1, 'DEFAULT')
  checks('.font suffix survives', cc.pfontname, 'topaz.font')
  checkn('size still read', cc.pfontsize, 8)
  ground()
  feed(['FONT=topaz'], 1, 'DEFAULT')
  checks('a bare FONT= name', cc.pfontname, 'topaz')
  checkn('no size given, none invented', cc.pfontsize, 0)
  -> name/size is a WITHIN-LINE contract: a sizeless FONT must not
  -> reach onto the next line and eat the first number it finds
  ground()
  feed(['FONT=topaz', '8', 'LINES=300'], 3, 'DEFAULT')
  checkn('pfontexp does not cross a line', cc.pfontsize, 0)
  checkn('and the next line parses normally', cc.plines, 300)

  WriteF('--- H: precedence, end to end ---\n')
  ground()
  feed(['LINES=2000', 'PEN=7', 'FONT=topaz/8'], 3, 'DEFAULT')
  opt('LINES384')
  checkn('the open string outranks the file', cc.plines, 384)
  checkn('and leaves what it did not mention', cc.deffg, 7)
  checks('font untouched too', cc.pfontname, 'topaz')

  WriteF('--- I: geometry as edges, parsed ---\n')
  ground()
  feed(['LEFT=100', 'TOP=50', 'RIGHT=740', 'BOTTOM=250'], 4, 'DEFAULT')
  checkn('LEFT=', cc.pwx, 100)
  checkn('TOP=', cc.pwy, 50)
  checkn('RIGHT= held raw for openwin', cc.pwr, 740)
  checkn('BOTTOM= held raw for openwin', cc.pwb, 250)
  -> tcnum has no minus support and its -1 return already means
  -> "invalid, leave the default", so FILL has to be caught as a
  -> literal string first or the two meanings collide
  ground()
  feed(['RIGHT=-1', 'BOTTOM=-1'], 2, 'DEFAULT')
  checkn('RIGHT=-1 is FILL, not "ignore me"', cc.pwr, -1)
  checkn('BOTTOM=-1 is FILL', cc.pwb, -1)
  ground()
  opt('LEFT100')
  checkn('the bare open-string form too', cc.pwx, 100)
  ground()
  feed(['RIGHT=fish'], 1, 'DEFAULT')
  checkn('junk leaves the key unset', cc.pwr, -2)

  WriteF('--- J: edgefold - the edges are EXCLUSIVE ---\n')
  -> the window spans LEFT..RIGHT, so the SIZE follows from the pair
  -> and the same RIGHT means different widths from different LEFTs.
  -> (His correction, 11.8.26, to "RIGHT=640 fills a 640-wide
  -> screen": true only from LEFT=0. The edge is the edge.)
  ground()
  feed(['LEFT=0', 'RIGHT=640'], 2, 'DEFAULT')
  edgefold()
  checkn('LEFT=0 RIGHT=640 -> 640 wide', cc.pww, 640)
  ground()
  feed(['LEFT=100', 'RIGHT=640'], 2, 'DEFAULT')
  edgefold()
  checkn('LEFT=100 RIGHT=640 -> 540 wide, same right edge', cc.pww, 540)
  ground()
  feed(['LEFT=100', 'RIGHT=740'], 2, 'DEFAULT')
  edgefold()
  checkn('width = RIGHT - LEFT', cc.pww, 640)
  ground()
  feed(['TOP=18', 'BOTTOM=200'], 2, 'DEFAULT')
  edgefold()
  checkn('height = BOTTOM - TOP', cc.pwh, 182)
  ground()
  feed(['RIGHT=-1'], 1, 'DEFAULT')
  edgefold()
  checkn('FILL passes through as pww=-1', cc.pww, -1)
  ground()
  edgefold()
  checkn('no edges given: fold is a no-op', cc.pww, 640)
  -> a RIGHT left of LEFT yields a negative width and lands on
  -> openwin's existing 160/60 floors - old safety, not new
  ground()
  feed(['LEFT=500', 'RIGHT=100'], 2, 'DEFAULT')
  edgefold()
  checkn('inverted edges go negative for the floor', cc.pww, -400)
  -> THE audit3 C2 CASE. hidewin snapshots the LIVE geometry into
  -> pwx/pww so a restore rebuilds the window the user actually
  -> shaped. A surviving pwr would recompute pww from a stale edge
  -> against the NEW pwx and silently undo that snapshot - so the
  -> fold clears itself and the second call must change nothing.
  ground()
  feed(['LEFT=0', 'RIGHT=640'], 2, 'DEFAULT')
  edgefold()
  cc.pwx := 300                 -> hidewin: the user dragged and resized
  cc.pww := 200
  edgefold()
  checkn('a second fold cannot undo hidewin"s snapshot', cc.pww, 200)

  WriteF('--- K: the colour pins ---\n')
  -> a pin is read at the POINT OF USE, never written into
  -> drifill/ovhid/ovgrey: those are OBTAINED pens with a ReleasePen
  -> lifecycle, and a pinned number was never obtained
  ground()
  feed(['DIRS=3'], 1, 'DEFAULT')
  cc.drifill := 5               -> what the screen derived
  checkn('DIRS pin outranks the derived FILLPEN', menupen(1), 3)
  ground()
  cc.drifill := 5
  checkn('unpinned keeps the derived FILLPEN', menupen(1), 5)
  ground()
  feed(['HIDDEN=2'], 1, 'DEFAULT')
  cc.ovhid := 9
  checkn('HIDDEN pin outranks the b6 scan', menupen(2), 2)
  ground()
  cc.ovhid := 9
  checkn('unpinned keeps the scan', menupen(2), 9)
  ground()
  cc.deffg := 7
  checkn('no scan, no pin: visible, merely undimmed', menupen(2), 7)
  ground()
  feed(['GHOST=6'], 1, 'DEFAULT')
  cc.wbpens := TRUE
  cc.can16 := TRUE              -> would otherwise force pen 8
  checkn('GHOST pin outranks even the WBPENS case', ghostpen(), 6)
  ground()
  cc.ovgrey := 4
  checkn('unpinned ghost falls to the obtained grey', ghostpen(), 4)
  -> pen 0 is the background - the window clear is SetAPen(0) +
  -> RectFill - so an entry drawn in it is not dim, it is gone
  ground()
  feed(['DIRS=0', 'HIDDEN=0', 'GHOST=0', 'TEXT=0'], 4, 'DEFAULT')
  checkn('DIRS=0 refused', cc.pdirs, -1)
  checkn('HIDDEN=0 refused', cc.phid, -1)
  checkn('GHOST=0 refused', cc.pghost, -1)
  checkn('TEXT=0 refused', cc.deffg, 1)
  ground()
  feed(['TEXT=7'], 1, 'DEFAULT')
  checkn('TEXT= is PEN= under the config"s name', cc.deffg, 7)

  WriteF('--- L: tab candidates - devices, dirs, files ---\n')
  -> b10: device/volume/assign names complete too, so du<Tab> can
  -> reach DUMP:. A device sets bits 0 AND 2 on purpose - bit 0 keeps
  -> every existing reader (menu width, dir colour, the no-space
  -> rule) working untouched, bit 2 only changes which character
  -> follows the name.
  ground()
  tcadd('readme', FALSE, FALSE, FALSE)
  tcadd('devs', TRUE, FALSE, FALSE)
  tcadd('.info', FALSE, TRUE, FALSE)
  tcadd('backup', TRUE, TRUE, FALSE)
  tcadd('DUMP', TRUE, FALSE, TRUE)
  checkn('five candidates collected', cc.tcn, 5)
  checkn('a plain file', flagof(0), 0)
  checkn('a directory', flagof(1), 1)
  checkn('a hidden file', flagof(2), 2)
  checkn('a hidden directory', flagof(3), 3)
  checkn('a device: bits 0 and 2', flagof(4), 5)
  -> the suffix, the whole reason bit 2 exists
  checkn('a file gets the closing space', tcsuffix(0), 32)
  checkn('a directory gets /', tcsuffix(1), 47)
  checkn('a device gets :', tcsuffix(5), 58)
  checkn('a hidden dir still gets /', tcsuffix(3), 47)
  -> a device reads as a directory everywhere else, which is what
  -> keeps it out of the mask conversation and in the dir colour
  ground()
  cc.drifill := 5
  checkn('a device takes the dir colour', menupen(5), 5)
  checkn('the no-space rule still sees it', 5 AND 1, 1)
  -> prefix matching is case-blind, so du reaches DUMP
  checkn('du matches DUMP', tcpref('DUMP', 'du', 2), TRUE)
  checkn('dv does not', tcpref('DUMP', 'dv', 2), FALSE)

  WriteF('--- M: walking the menu with the arrows ---\n')
  -> a 4-wide grid of 10 entries, so the last row is SHORT (8, 9) -
  -> the only part of a row-major grid that needs any care
  ground()
  cc.tcshown := 10
  cc.tcmcols := 4
  cc.tcsel := -1
  checkn('first arrow just picks one', tcgridmove(RK_DOWN), 0)
  cc.tcsel := 0
  checkn('Right steps one', tcgridmove(RK_RIGHT), 1)
  cc.tcsel := 9
  checkn('Right wraps the whole list', tcgridmove(RK_RIGHT), 0)
  cc.tcsel := 0
  checkn('Left wraps backwards', tcgridmove(RK_LEFT), 9)
  cc.tcsel := 5
  checkn('Left steps one', tcgridmove(RK_LEFT), 4)
  cc.tcsel := 0
  checkn('Down moves a whole row', tcgridmove(RK_DOWN), 4)
  cc.tcsel := 4
  checkn('Down again', tcgridmove(RK_DOWN), 8)
  -> column 0 holds 0/4/8, so Down from its last entry comes back to
  -> its own top - not into column 1
  cc.tcsel := 8
  checkn('Down wraps within the column', tcgridmove(RK_DOWN), 0)
  -> column 2 holds only 2 and 6: the short last row must not invent
  -> an entry 10 that does not exist
  cc.tcsel := 6
  checkn('a short column wraps at its real end', tcgridmove(RK_DOWN), 2)
  cc.tcsel := 2
  checkn('Up from the top of a short column', tcgridmove(RK_UP), 6)
  cc.tcsel := 0
  checkn('Up from the top of a full column', tcgridmove(RK_UP), 8)
  cc.tcsel := 4
  checkn('Up moves a whole row', tcgridmove(RK_UP), 0)
  cc.tcsel := 9
  checkn('Up from the last entry', tcgridmove(RK_UP), 5)
  -> degenerate grids must not move or divide by anything silly
  ground()
  cc.tcshown := 0
  cc.tcmcols := 4
  cc.tcsel := 0
  checkn('an empty menu refuses to move', tcgridmove(RK_DOWN), -1)
  ground()
  cc.tcshown := 1
  cc.tcmcols := 4
  cc.tcsel := 0
  checkn('one entry: Down stays', tcgridmove(RK_DOWN), 0)
  checkn('one entry: Up stays', tcgridmove(RK_UP), 0)
  checkn('one entry: Right stays', tcgridmove(RK_RIGHT), 0)

  WriteF('--- N: the grounding directives ---\n')
  -> DEFAULTS and CONFIG= decide what the window starts FROM, so they
  -> are read by a pre-scan before any option is applied - otherwise
  -> a CONFIG= named last would overwrite the options typed before it
  ground()
  checkn('DEFAULTS is a directive', cfgdirective('DEFAULTS'), TRUE)
  checkn('and sets the skip', cc.pcfgdef, TRUE)
  ground()
  checkn('CONFIG=name', cfgdirective('CONFIG=tall'), TRUE)
  checks('the section, folded', cc.pcfgsect, 'TALL')
  ground()
  checkn('CONFIGname, the shell-safe form', cfgdirective('CONFIGtall'), TRUE)
  checks('same section', cc.pcfgsect, 'TALL')
  ground()
  checkn('a bare CONFIG names nothing', cfgdirective('CONFIG'), FALSE)
  checkn('an ordinary option is not a directive',
         cfgdirective('LINES=200'), FALSE)
  -> both are refused INSIDE the file: CONFIG there would let a
  -> section select another section, and DEFAULTS there is a
  -> contradiction - the file IS the defaults
  checkn('CONFIG refused in the file', cfgrefuse('CONFIG=tall'), TRUE)
  checkn('DEFAULTS refused in the file', cfgrefuse('DEFAULTS'), TRUE)
  checkn('an ordinary key is not refused', cfgrefuse('LINES=200'), FALSE)

  WriteF('--- O: the pre-scan, and where it will not look ---\n')
  ground()
  cfgpre(mkbstr(bb, 'CCON:CONFIG=tall'))
  checks('field 0 is scanned (the no-geometry shortcut)',
         cc.pcfgsect, 'TALL')
  ground()
  cfgpre(mkbstr(bb, 'CCON:DEFAULTS'))
  checkn('DEFAULTS at field 0', cc.pcfgdef, TRUE)
  ground()
  cfgpre(mkbstr(bb, 'CCON:DEFAULTS/CONFIG=tall'))
  checkn('both, after a field-0 directive', cc.pcfgdef, TRUE)
  checks('and the section with it', cc.pcfgsect, 'TALL')
  ground()
  cfgpre(mkbstr(bb, 'CCON:0/18/640/130/Build/CONFIG=tall'))
  checks('field 5 is scanned', cc.pcfgsect, 'TALL')
  -> THE safety case: field 4 is the TITLE. A window legitimately
  -> titled "CONFIG=tall" or "DEFAULTS" must not ground itself.
  ground()
  cfgpre(mkbstr(bb, 'CCON:0/18/640/130/CONFIG=tall'))
  checks('field 4 is the title, NOT scanned', cc.pcfgsect, '')
  ground()
  cfgpre(mkbstr(bb, 'CCON:0/18/640/130/DEFAULTS'))
  checkn('a window titled DEFAULTS does not ground itself',
         cc.pcfgdef, FALSE)
  ground()
  cfgpre(mkbstr(bb, 'CCON:'))
  checks('a bare spec finds nothing', cc.pcfgsect, '')
  ground()
  cfgpre(0)
  checkn('no spec at all is safe', cc.pcfgdef, FALSE)

  WriteF('--- P: TITLE= takes the rest of the line ---\n')
  ground()
  checkn('the offset past TITLE=', cfgrest('TITLE=Build', 'TITLE', 5), 6)
  checkn('case-blind', cfgrest('title=x', 'TITLE', 5), 6)
  checkn('the = is required', cfgrest('TITLE Build', 'TITLE', 5), -1)
  checkn('not every key', cfgrest('LINES=200', 'TITLE', 5), -1)
  -> the whole point: no token split, so spaces AND slashes survive
  ground()
  feed(['TITLE=My Build Shell'], 1, 'DEFAULT')
  checks('spaces survive', cc.wtitlebase, 'My Build Shell')
  ground()
  feed(['TITLE=Work/Build'], 1, 'DEFAULT')
  checks('a slash survives', cc.wtitlebase, 'Work/Build')
  ground()
  feed(['TITLE=   Padded'], 1, 'DEFAULT')
  checks('leading blanks trimmed', cc.wtitlebase, 'Padded')
  -> and it does not disturb the ordinary keys around it
  ground()
  feed(['LINES=300', 'TITLE=Build', 'PEN=7'], 3, 'DEFAULT')
  checks('title landed', cc.wtitlebase, 'Build')
  checkn('the key before it', cc.plines, 300)
  checkn('the key after it', cc.deffg, 7)

  WriteF('--- Q: ICON=, the other rest-of-line key ---\n')
  -> a path CONTAINS '/', and every other value in the file is split
  -> on it - which is the whole reason ICON cannot be a token
  ground()
  feed(['ICON=SYS:Prefs/CCon'], 1, 'DEFAULT')
  checks('a path with slashes survives whole', cc.piconpath,
         'SYS:Prefs/CCon')
  ground()
  feed(['ICON=Work:My Icons/Shell'], 1, 'DEFAULT')
  checks('spaces survive too', cc.piconpath, 'Work:My Icons/Shell')
  ground()
  feed(['ICON=  DH0:icons/ccon  '], 1, 'DEFAULT')
  checks('blanks trimmed both ends', cc.piconpath, 'DH0:icons/ccon')
  ground()
  checkn('the = is required here too', cfgrest('ICON x', 'ICON', 4), -1)
  -> and it leaves the ordinary keys around it alone
  ground()
  feed(['LINES=300', 'ICON=SYS:Prefs/CCon', 'PEN=7'], 3, 'DEFAULT')
  checks('the icon landed', cc.piconpath, 'SYS:Prefs/CCon')
  checkn('the key before it', cc.plines, 300)
  checkn('the key after it', cc.deffg, 7)
  -> no ICON line at all: nothing set, so the baked-in icon stands
  ground()
  feed(['LINES=300'], 1, 'DEFAULT')
  checks('absent means the baked-in icon', cc.piconpath, '')

  WriteF('\n')
  IF fails = 0
    WriteF('ALL GREEN - \d/\d\n', tests, tests)
  ELSE
    WriteF('\d FAILURES of \d\n', fails, tests)
  ENDIF
ENDPROC
