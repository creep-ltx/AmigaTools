-> histdeduptest.e - harness for the full-dedup history change, and
-> (v1.2.7) for the per-console walk order layered on top of it
->
-> The old histremember() collapsed only CONSECUTIVE repeats, so a
-> command re-run with others in between (ls -1 c: in ten interleaved
-> tests) was stored many times and cluttered the Up-arrow walk. The
-> new rule: a command exists at most ONCE, and re-running it MOVES it
-> to the newest position (zsh HIST_IGNORE_ALL_DUPS shape), so Up
-> reaches it in one press.
->
-> v1.2.7 (Timm's mail): each ring entry also records WHICH console
-> committed it (ghcon; NIL = loaded from disk), and every console
-> walks the ring in ITS OWN order - own commits newest-first, then
-> everyone else's newest-first (historder). Section G proves that
-> ordering: interleaved shells, the NIL disk case, retag on a
-> consecutive dup from another shell, owner riding a move-to-end,
-> and a wrapped ring.
->
-> This is fiddly ring arithmetic - a duplicate is found mid-ring and
-> the newer entries shift down to close the hole before the new copy
-> lands at the end - so it is proved on data here before it goes near
-> the handler. The ring math is transcribed VERBATIM from
-> ccon-handler.e's histremember; keep the two identical. historder
-> is the same transcription with (con, out) parameters standing in
-> for curcon.horder - the handler adds only the hover/ghver cache
-> check on top of the loops here.
->
-> Build: ecompile histdeduptest.e histdeduptest
-> Run:   vamos histdeduptest

MODULE 'dos/dos'

CONST HISTMAX=8        -> small, so wrap and full-ring dedup are reachable

DEF ghist[8]:ARRAY OF LONG,     -> the ring: E-string ptrs
    ghcon[8]:ARRAY OF LONG,     -> v1.2.7: the committing console (NIL = disk)
    ghver,                      -> v1.2.7: bumped on any ring/owner mutation
    ghtotal, fails

-> the ring math under test - MUST stay identical to the handler's
PROC histremember(s:PTR TO CHAR, owner)
  DEF avail, i, slot, found
  IF StrLen(s) = 0 THEN RETURN FALSE
  avail := Min(ghtotal, HISTMAX)
  -> already the newest? the RING does not change (the old
  -> consecutive-dup case) - but the OWNER can: this console just
  -> typed the line, so its walk should file it under "own". No bump
  -> when the owner already matches.
  IF avail > 0
    slot := Mod(ghtotal - 1, HISTMAX)
    IF StrCmp(ghist[slot], s)
      IF owner
        IF ghcon[slot] <> owner
          ghcon[slot] := owner
          ghver++
        ENDIF
      ENDIF
      RETURN FALSE
    ENDIF
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
      ghcon[Mod(ghtotal - avail + i, HISTMAX)] :=       -> v1.2.7: the
        ghcon[Mod(ghtotal - avail + i + 1, HISTMAX)]    -> owners ride
    ENDFOR                                              -> the shift
    ghtotal := ghtotal - 1
  ENDIF
  StrCopy(ghist[Mod(ghtotal, HISTMAX)], s)
  ghcon[Mod(ghtotal, HISTMAX)] := owner
  ghtotal := ghtotal + 1
  ghver++                       -> every cached walk order is stale
ENDPROC TRUE

PROC histslot(idx) IS Mod(ghtotal - 1 - idx, HISTMAX)

-> the per-console walk order under test - the handler's historder
-> with (con, out) for curcon/curcon.horder and no hover cache;
-> the two passes MUST stay identical to the handler's
PROC historder(con, out:PTR TO INT)
  DEF avail, idx, slot, n
  avail := Min(ghtotal, HISTMAX)
  n := 0
  IF avail > 0
    slot := histslot(0)
    FOR idx := 0 TO avail - 1
      IF ghcon[slot] = con
        out[n] := slot
        n++
      ENDIF
      slot := slot - 1
      IF slot < 0 THEN slot := HISTMAX - 1
    ENDFOR
    slot := histslot(0)
    FOR idx := 0 TO avail - 1
      IF ghcon[slot] <> con
        out[n] := slot
        n++
      ENDIF
      slot := slot - 1
      IF slot < 0 THEN slot := HISTMAX - 1
    ENDFOR
  ENDIF
ENDPROC n

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

-> con's WALK order as "c|b|a|x" - FIRST Up press first (own
-> newest-first, then foreign newest-first); the reverse reading
-> direction from dump() above, deliberately: this is what the
-> user experiences pressing Up repeatedly
PROC dumporder(con, out:PTR TO CHAR)
  DEF ord[8]:ARRAY OF INT, n, idx, p, h:PTR TO CHAR, j
  n := historder(con, ord)
  p := 0
  FOR idx := 0 TO n - 1
    h := ghist[ord[idx]]
    j := 0
    WHILE h[j] <> 0
      out[p] := h[j]
      p := p + 1
      j := j + 1
    ENDWHILE
    IF idx < (n - 1)
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
    ghcon[i] := NIL
  ENDFOR
  ghtotal := 0
ENDPROC

PROC add(s) IS histremember(s, NIL)

PROC main()
  DEF b[400]:ARRAY OF CHAR, r, cona, conb, v
  fails := 0
  cona := 1000                  -> fake console ptrs: only ever
  conb := 2000                  -> compared, never dereferenced
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

  -> ---- G: v1.2.7 per-console walk order ----
  WriteF('\n--- G1: two shells interleaved - each walks its own first ---\n')
  reset()
  histremember('a', cona); histremember('b', cona)
  histremember('x', conb); histremember('c', cona)
  dump(b)
  WriteF('    ring: \s\n', b)
  check('shared ring unchanged by owners', b, 'a|b|x|c')
  dumporder(cona, b)
  WriteF('    A walks: \s\n', b)
  check('A: own c,b,a first, then x', b, 'c|b|a|x')
  dumporder(conb, b)
  WriteF('    B walks: \s\n', b)
  check('B: own x first, then c,b,a', b, 'x|c|b|a')

  WriteF('\n--- G2: disk-loaded (NIL) lines are foreign to everyone ---\n')
  reset()
  add('d0')                             -> a loadhistfile line
  histremember('a1', cona)
  dumporder(cona, b)
  WriteF('    A walks: \s\n', b)
  check('A: own a1, then disk d0', b, 'a1|d0')
  dumporder(conb, b)
  WriteF('    B walks: \s\n', b)
  check('B: no own - plain newest-first', b, 'a1|d0')

  WriteF('\n--- G3: consecutive dup from ANOTHER shell retags the owner ---\n')
  reset()
  histremember('p', cona); histremember('z', cona)
  v := ghver
  r := histremember('z', conb)          -> ring unchanged, owner -> B
  IF (r = FALSE) AND (ghver = (v + 1))
    WriteF('    ok   returned FALSE, ghver bumped for the retag\n')
  ELSE
    WriteF('    FAIL retag: r=\d ghver \d -> \d (want FALSE, +1)\n', r, v, ghver)
    fails := fails + 1
  ENDIF
  v := ghver
  histremember('z', conb)               -> same owner again: no bump
  IF ghver = v
    WriteF('    ok   same-owner repeat does not bump ghver\n')
  ELSE
    WriteF('    FAIL same-owner repeat bumped ghver\n')
    fails := fails + 1
  ENDIF
  dumporder(cona, b)
  WriteF('    A walks: \s\n', b)
  check('A: z now foreign, own p first', b, 'p|z')
  dumporder(conb, b)
  WriteF('    B walks: \s\n', b)
  check('B: z own now', b, 'z|p')

  WriteF('\n--- G4: move-to-end carries the NEW owner ---\n')
  reset()
  histremember('one', cona); histremember('two', cona)
  histremember('one', conb)             -> B re-runs A''s command
  dump(b)
  WriteF('    ring: \s\n', b)
  check('one moved to newest', b, 'two|one')
  dumporder(cona, b)
  WriteF('    A walks: \s\n', b)
  check('A: one now foreign - own two first', b, 'two|one')
  dumporder(conb, b)
  WriteF('    B walks: \s\n', b)
  check('B: owns one', b, 'one|two')

  WriteF('\n--- G5: order across a wrapped ring, mixed owners ---\n')
  reset()
  histremember('e0', cona); histremember('e1', cona)
  histremember('e2', cona); histremember('e3', cona)
  histremember('e4', conb); histremember('e5', conb)
  histremember('e6', conb); histremember('e7', conb)   -> full
  histremember('e8', cona)                              -> e0 falls off
  dumporder(cona, b)
  WriteF('    A walks: \s\n', b)
  check('A: own e8,e3..e1, then foreign e7..e4', b, 'e8|e3|e2|e1|e7|e6|e5|e4')
  dumporder(conb, b)
  WriteF('    B walks: \s\n', b)
  check('B: own e7..e4, then foreign e8,e3..e1', b, 'e7|e6|e5|e4|e8|e3|e2|e1')

  WriteF('\n---------------------------------------------\n')
  IF fails = 0
    WriteF('all checks passed - safe to wire into histremember\n')
  ELSE
    WriteF('\d CHECK(S) FAILED\n', fails)
  ENDIF
ENDPROC
