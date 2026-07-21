-> histdeduptest.e - harness for the full-dedup history change
->
-> The old histremember() collapsed only CONSECUTIVE repeats, so a
-> command re-run with others in between (ls -1 c: in ten interleaved
-> tests) was stored many times and cluttered the Up-arrow walk. The
-> new rule: a command exists at most ONCE, and re-running it MOVES it
-> to the newest position (zsh HIST_IGNORE_ALL_DUPS shape), so Up
-> reaches it in one press.
->
-> This is fiddly ring arithmetic - a duplicate is found mid-ring and
-> the newer entries shift down to close the hole before the new copy
-> lands at the end - so it is proved on data here before it goes near
-> the handler. The ring math is transcribed VERBATIM from
-> ccon-handler.e's histremember; keep the two identical.
->
-> Build: ecompile histdeduptest.e histdeduptest
-> Run:   vamos histdeduptest

MODULE 'dos/dos'

CONST HISTMAX=8        -> small, so wrap and full-ring dedup are reachable

DEF ghist[8]:ARRAY OF LONG,     -> the ring: E-string ptrs
    ghtotal, fails

-> the ring math under test - MUST stay identical to the handler's
PROC histremember(s:PTR TO CHAR)
  DEF avail, i, slot, found
  IF StrLen(s) = 0 THEN RETURN FALSE
  avail := Min(ghtotal, HISTMAX)
  -> already the newest? nothing changes (the old consecutive-dup case)
  IF avail > 0
    IF StrCmp(ghist[Mod(ghtotal - 1, HISTMAX)], s) THEN RETURN FALSE
  ENDIF
  -> does an OLDER copy exist? find its logical index (0 = oldest ..
  -> avail-1 = newest; the newest was just handled above so scan to
  -> avail-2). WHILE, not FOR, for a clean break.
  found := -1
  i := 0
  WHILE i < (avail - 1)
    slot := Mod(ghtotal - avail + i, HISTMAX)
    IF StrCmp(ghist[slot], s)
      found := i
      i := avail                    -> break
    ELSE
      i := i + 1
    ENDIF
  ENDWHILE
  IF found >= 0
    -> move-to-end: shift the newer entries DOWN over the dup, closing
    -> the hole (forward copy, each dest below its src, no overlap),
    -> then step ghtotal back so the append math and slot mapping use
    -> the reduced count. The entries keep their ghtotal-relative slots.
    FOR i := found TO avail - 2
      StrCopy(ghist[Mod(ghtotal - avail + i, HISTMAX)],
              ghist[Mod(ghtotal - avail + i + 1, HISTMAX)])
    ENDFOR
    ghtotal := ghtotal - 1
  ENDIF
  StrCopy(ghist[Mod(ghtotal, HISTMAX)], s)
  ghtotal := ghtotal + 1
ENDPROC TRUE

-> the live ring, newest last, as "a|b|c" - the order Up-arrow walks
-> backward through (last = first Up press)
PROC dump(out:PTR TO CHAR)
  DEF avail, idx, p, h:PTR TO CHAR, j
  avail := Min(ghtotal, HISTMAX)
  p := 0
  FOR idx := avail - 1 TO 0 STEP -1        -> oldest first for reading
    h := ghist[Mod(ghtotal - 1 - idx, HISTMAX)]
    j := 0
    WHILE h[j] <> 0
      out[p] := h[j]
      p := p + 1
      j := j + 1
    ENDWHILE
    IF idx > 0
      out[p] := "|"
      p := p + 1
    ENDIF
  ENDFOR
  out[p] := 0
ENDPROC

PROC check(tag, got:PTR TO CHAR, want:PTR TO CHAR)
  IF StrCmp(got, want)
    WriteF('    ok   \s\n', tag)
  ELSE
    WriteF('    FAIL \s\n         got  "\s"\n         want "\s"\n', tag, got, want)
    fails := fails + 1
  ENDIF
ENDPROC

PROC reset()
  DEF i
  FOR i := 0 TO HISTMAX - 1
    ghist[i] := String(64)
    StrCopy(ghist[i], '')
  ENDFOR
  ghtotal := 0
ENDPROC

PROC add(s) IS histremember(s)

PROC main()
  DEF b[400]:ARRAY OF CHAR, r
  fails := 0
  WriteF('histdeduptest - full history dedup, move-to-end\n\n')

  -> ---- A: the user's case - a command interleaved with others ----
  WriteF('--- A: ls repeated with other commands between ---\n')
  reset()
  add('ls -1 c:'); add('cd ram:'); add('ls -1 c:')
  add('echo hi'); add('ls -1 c:')
  dump(b)
  WriteF('    ring: \s\n', b)
  check('ls stored once, newest', b, 'cd ram:|echo hi|ls -1 c:')

  -> ---- B: consecutive repeat is still a no-op (returns FALSE) ----
  WriteF('\n--- B: consecutive repeat does not grow or reorder ---\n')
  reset()
  add('one'); add('two')
  r := add('two')                       -> consecutive dup
  dump(b)
  WriteF('    ring: \s  (add returned \d)\n', b, r)
  check('consecutive dup ignored', b, 'one|two')
  IF r <> FALSE
    WriteF('    FAIL consecutive dup should return FALSE\n')
    fails := fails + 1
  ELSE
    WriteF('    ok   returned FALSE (no file append)\n')
  ENDIF

  -> ---- C: move-to-end returns TRUE (so the file gets the new copy) --
  WriteF('\n--- C: a moved command reports TRUE for the file append ---\n')
  reset()
  add('a'); add('b')
  r := add('a')                         -> exists older -> moves to end
  dump(b)
  WriteF('    ring: \s  (add returned \d)\n', b, r)
  check('a moved to newest', b, 'b|a')
  IF r <> TRUE
    WriteF('    FAIL a move-to-end should return TRUE\n')
    fails := fails + 1
  ELSE
    WriteF('    ok   returned TRUE\n')
  ENDIF

  -> ---- D: dedup of the OLDEST entry, ring not yet full ----
  WriteF('\n--- D: re-run the oldest command ---\n')
  reset()
  add('first'); add('mid'); add('last'); add('first')
  dump(b)
  WriteF('    ring: \s\n', b)
  check('oldest moved to newest', b, 'mid|last|first')

  -> ---- E: OVERFLOW - fill past HISTMAX, oldest falls off ----
  WriteF('\n--- E: ring overflow drops the oldest unique ---\n')
  reset()
  add('c0'); add('c1'); add('c2'); add('c3')
  add('c4'); add('c5'); add('c6'); add('c7')   -> ring full (8)
  add('c8')                                     -> c0 falls off
  dump(b)
  WriteF('    ring: \s\n', b)
  check('c0 dropped, c8 newest', b, 'c1|c2|c3|c4|c5|c6|c7|c8')

  -> ---- F: dedup across a WRAPPED ring ----
  WriteF('\n--- F: move-to-end when the ring has wrapped ---\n')
  reset()
  add('d0'); add('d1'); add('d2'); add('d3')
  add('d4'); add('d5'); add('d6'); add('d7')   -> full
  add('d8'); add('d9')                          -> wrapped: d0,d1 gone
  -> ring is now d2..d9; re-run d5 (mid-ring, wrapped storage)
  add('d5')
  dump(b)
  WriteF('    ring: \s\n', b)
  check('d5 moved to newest across wrap', b, 'd2|d3|d4|d6|d7|d8|d9|d5')

  WriteF('\n---------------------------------------------\n')
  IF fails = 0
    WriteF('all checks passed - safe to wire into histremember\n')
  ELSE
    WriteF('\d CHECK(S) FAILED\n', fails)
  ENDIF
ENDPROC
