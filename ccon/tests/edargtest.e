-> edargtest.e - harness for the 1.2.8b2 editor batch (the KingCON
-> everyday-keys mail): Ctrl+P's argument finder and the two word
-> jumps.
->
-> Claims under test:
->   1. edlastarg() finds the last ARGUMENT before the cursor the way
->      the shell would split it - a quoted run is one argument,
->      spaces and all, and *" inside quotes does not close it.
->      KingCON's Ctrl+P walks back to the last space and never looks
->      at quotes: `"my string here` repeats just `here`.
->   2. edrepeat() inserts that argument at the cursor whole-or-
->      nothing, with the separator the line needs: nothing after a
->      space, a space after a closed argument, and `" ` after an
->      argument whose quote is still open - the original gets closed,
->      the copy stays open for typing on.
->   3. edjumpl/edjumpr: Alt jumps by space-separated word, Ctrl by
->      path component (space, '/' and ':' all separate) - KingCON's
->      lbC003C84/lbC003CE6 vs lbC003D1E/lbC003D9E pair.
->
-> edlastarg, edsep, edjumpl, edjumpr are VERBATIM from
-> ccon-handler.e; edrepeat has curcon.ebuf/cpos/edcap() swapped for
-> the globals below and DisplayBeep for a counter.
->
-> Build: ecompile edargtest.e edargtest
-> Run:   vamos edargtest

DEF ebuf[404]:STRING, cpos, cap, beeps, fails

PROC edlastarg(s:PTR TO CHAR, cpos)
  DEF i, st, en, open, inq, c, go
  st := -1
  en := -1
  open := FALSE
  i := 0
  WHILE i < cpos
    WHILE (i < cpos) AND (s[i] = 32)
      i++
    ENDWHILE
    IF i < cpos
      st := i
      inq := FALSE
      go := TRUE
      WHILE go AND (i < cpos)
        c := s[i]
        IF inq
          IF (c = "*") AND ((i + 1) < cpos)
            i++                   -> the escaped character rides along
          ELSEIF c = 34
            inq := FALSE
          ENDIF
          i++
        ELSEIF c = 32
          go := FALSE
        ELSE
          IF c = 34 THEN inq := TRUE
          i++
        ENDIF
      ENDWHILE
      en := i
      open := inq
    ENDIF
  ENDWHILE
ENDPROC st, en, open

PROC edrepeat()
  DEF s:PTR TO CHAR, l, st, en, open, n, sepn, tot, j
  s := ebuf
  l := StrLen(ebuf)
  st, en, open := edlastarg(s, cpos)
  IF st < 0 THEN RETURN FALSE
  n := en - st
  sepn := 0
  IF open
    sepn := 2
  ELSEIF s[cpos - 1] <> 32
    sepn := 1
  ENDIF
  tot := n + sepn
  IF (l + tot) > cap
    beeps++
    RETURN FALSE
  ENDIF
  FOR j := l - 1 TO cpos STEP -1
    s[j + tot] := s[j]
  ENDFOR
  j := cpos
  IF open
    s[j] := 34
    j++
  ENDIF
  IF sepn > 0
    s[j] := 32
    j++
  ENDIF
  CopyMem(s + st, s + j, n)
  SetStr(ebuf, l + tot)
  s[l + tot] := 0
  cpos := cpos + tot
ENDPROC TRUE

PROC edsep(c, path)
  IF c = 32 THEN RETURN TRUE
  IF path = FALSE THEN RETURN FALSE
ENDPROC (c = "/") OR (c = ":")

PROC edjumpl(s:PTR TO CHAR, p, path)
  WHILE (p > 0) AND edsep(s[p - 1], path)
    p--
  ENDWHILE
  WHILE (p > 0) AND (edsep(s[p - 1], path) = FALSE)
    p--
  ENDWHILE
ENDPROC p

PROC edjumpr(s:PTR TO CHAR, p, l, path)
  WHILE (p < l) AND (edsep(s[p], path) = FALSE)
    p++
  ENDWHILE
  WHILE (p < l) AND edsep(s[p], path)
    p++
  ENDWHILE
ENDPROC p

PROC edkillto(s:PTR TO CHAR, l, from, upto)
  DEF k
  FOR k := upto TO l - 1
    s[k - (upto - from)] := s[k]
  ENDFOR
ENDPROC l - (upto - from)

-> Ctrl/Alt+Backspace (back=TRUE) and Ctrl/Alt+Del, as dovanilla runs them
PROC kill(name:PTR TO CHAR, line:PTR TO CHAR, at, back, path, want:PTR TO CHAR, wantpos)
  DEF j
  StrCopy(ebuf, line)
  cpos := at
  IF back
    IF cpos > 0
      j := edjumpl(ebuf, cpos, path)
      SetStr(ebuf, edkillto(ebuf, StrLen(ebuf), j, cpos))
      cpos := j
    ENDIF
  ELSEIF cpos < StrLen(ebuf)
    j := edjumpr(ebuf, cpos, StrLen(ebuf), path)
    SetStr(ebuf, edkillto(ebuf, StrLen(ebuf), cpos, j))
  ENDIF
  IF StrCmp(ebuf, want) AND (cpos = wantpos)
    WriteF('ok   \s\n', name)
  ELSE
    WriteF('FAIL \s\n     got  [\s] cpos=\d\n     want [\s] cpos=\d\n',
           name, ebuf, cpos, want, wantpos)
    fails++
  ENDIF
ENDPROC

-> ---------- the checks ----------

PROC rep(name:PTR TO CHAR, line:PTR TO CHAR, at, want:PTR TO CHAR, wantpos)
  StrCopy(ebuf, line)
  cpos := IF at < 0 THEN StrLen(ebuf) ELSE at
  edrepeat()
  IF StrCmp(ebuf, want) AND (cpos = wantpos)
    WriteF('ok   \s\n', name)
  ELSE
    WriteF('FAIL \s\n     got  [\s] cpos=\d\n     want [\s] cpos=\d\n',
           name, ebuf, cpos, want, wantpos)
    fails++
  ENDIF
ENDPROC

PROC jmp(name:PTR TO CHAR, got, want)
  IF got = want
    WriteF('ok   \s\n', name)
  ELSE
    WriteF('FAIL \s  got \d want \d\n', name, got, want)
    fails++
  ENDIF
ENDPROC

PROC main()
  DEF p:PTR TO CHAR
  cap := 400
  rep('plain word, cursor on it', 'rename foo', -1, 'rename foo foo', 14)
  rep('plain word, after a space', 'rename foo ', -1, 'rename foo foo', 14)
  rep('several trailing spaces', 'rename foo   ', -1, 'rename foo   foo', 16)
  rep('closed quote is one argument', 'rename "my string here"', -1,
      'rename "my string here" "my string here"', 40)
  rep('closed quote, after a space', 'rename "my string here" ', -1,
      'rename "my string here" "my string here"', 40)
  rep('OPEN quote - the mail''s case', 'rename "my string here', -1,
      'rename "my string here" "my string here', 39)
  rep('*" does not close the quote', 'echo "a*" b"', -1,
      'echo "a*" b" "a*" b"', 20)
  rep('quote glued to a prefix', 'copy dh0:"my dir"/x', -1,
      'copy dh0:"my dir"/x dh0:"my dir"/x', 34)
  rep('mid-line: the tail survives', 'rename foo bar', 10,
      'rename foo foo bar', 14)
  rep('mid-word: the word so far', 'rename foobar', 10,
      'rename foo foobar', 14)
  rep('empty line does nothing', '', -1, '', 0)
  rep('only spaces does nothing', '   ', -1, '   ', 3)
  rep('cursor at 0 does nothing', 'dir', 0, 'dir', 0)
  cap := 12
  beeps := 0
  rep('no room: whole or nothing', 'rename foo', -1, 'rename foo', 10)
  jmp('... and it beeped', beeps, 1)
  cap := 14
  rep('exactly fits', 'rename foo', -1, 'rename foo foo', 14)

  p := 'copy dh0:work/my file.txt ram:'
  ->    0    5    10   15   20   25
  jmp('alt-left  from end', edjumpl(p, 30, FALSE), 26)
  jmp('alt-left  again', edjumpl(p, 26, FALSE), 17)
  jmp('alt-left  at 0 stays', edjumpl(p, 0, FALSE), 0)
  jmp('ctrl-left from end (skips the colon)', edjumpl(p, 30, TRUE), 26)
  jmp('ctrl-left inside the path', edjumpl(p, 17, TRUE), 14)
  jmp('ctrl-left to after dh0:', edjumpl(p, 14, TRUE), 9)
  jmp('ctrl-left over dh0:', edjumpl(p, 9, TRUE), 5)
  jmp('alt-right from 0', edjumpr(p, 0, 30, FALSE), 5)
  jmp('alt-right over the path', edjumpr(p, 5, 30, FALSE), 17)
  jmp('ctrl-right stops after dh0:', edjumpr(p, 5, 30, TRUE), 9)
  jmp('ctrl-right stops after work/', edjumpr(p, 9, 30, TRUE), 14)
  jmp('ctrl-right at end stays', edjumpr(p, 30, 30, TRUE), 30)
  kill('alt-bs: last word', 'copy dh0:a b', 12, TRUE, FALSE, 'copy dh0:a ', 11)
  kill('alt-bs: over trailing space', 'copy dh0:a ', 11, TRUE, FALSE, 'copy ', 5)
  kill('ctrl-bs: one path component', 'copy dh0:work/x', 15, TRUE, TRUE, 'copy dh0:work/', 14)
  kill('ctrl-bs: through the slash', 'copy dh0:work/', 14, TRUE, TRUE, 'copy dh0:', 9)
  kill('bs at 0: nothing', 'dir', 0, TRUE, FALSE, 'dir', 0)
  kill('alt-bs mid-line keeps tail', 'aa bb cc', 5, TRUE, FALSE, 'aa  cc', 3)
  kill('alt-del: word + space', 'aa bb cc', 3, FALSE, FALSE, 'aa cc', 3)
  kill('ctrl-del: path component', 'copy dh0:work/x', 5, FALSE, TRUE, 'copy work/x', 5)
  kill('del at end: nothing', 'dir', 3, FALSE, FALSE, 'dir', 3)
  kill('alt-del last word', 'aa bb', 3, FALSE, FALSE, 'aa ', 3)
  WriteF('\n\d failure(s)\n', fails)
ENDPROC
