-> audit2-roadmap.md - working order for the second-pass audit findings
-> Companion to audit2.md; finding IDs (P3, P6, B9, B10, B11, H3, H6)
-> are that file's, continuing audit.md's global B/P/H numbering.
-> Ordered the same way batch 1 of the first campaign was: the cheap,
-> unfalsifiable changes land first and the ones that need a real boot
-> test or a repro land alone, where a bisect can name them.
->
-> Nothing here is boot-verified. Every batch states what would prove
-> it - a fix that cannot be shown failing before and passing after is
-> not a fix, it is a hope. (The first campaign was overturned by its
-> own harness THREE times - B1, B2, B7 - so this is not a slogan.)

# Fix roadmap, second pass

Four batches. Batch A is safe to work straight through in one commit.
Batches B, C and D each want their own commit; B and C want a real
before/after, D is mostly a decision.

Build/deploy per the usual routine: ecompile via vamos, copy
`ccon-handler` to the FS-UAE AmigaOS3.2 `L/` (keep `L/ccon-handler.bak`
as the revert point - do NOT infer the deployed version from file
size, the 1.2b2 deploy taught that), reboot, mount, test.

Bump `$VER` per deployed build, plain sequential from 1.2b14 (next is
1.2b15 - note the reverted B8 drain experiment also used b15/b15b in
git history but was never a shipped version, so 1.2b15 is free).

---

## Batch A - mechanical, one commit - B9, H3, H6 - DONE (1.2b15, 22.7.26)

**Findings:** B9 (the `ta` leak), H3 (condispose completeness), H6
(the stray Han bytes).

**Outcome:** all three landed in 1.2b15. Compiled clean (LARGE) - E-VO
accepts `DEF ta:textattr` as a stack object (the preferred B9 form, no
`END ta` fallback needed), the UNREFERENCED set is byte-identical to
the baseline (parked `domenupick` params, `tcscancmd`, `vers` - no new
dangling local, `ta` is referenced), and the three pre-existing A4/A5
inline-asm warnings are unchanged. Binary 77860 -> 77956, +96 bytes -
the eight H3 disposes; B9 is roughly neutral (a NEW call traded for
stack setup). Non-ASCII sweep clean.

**Boot test passed (22.7.26):** `NewShell CCON:`, `ls -l c:` ~10 times,
scrolled back through the full history. Window opened (openwin runs with
the stack textattr - font loaded, grid measured, text rendered), and
scrollback read cleanly through the `sb`/`sa`/`ss` model planes for
every row - the direct evidence that B9's storage-class change and the
planes around H3 are intact. The one path not exercised is window CLOSE
(where condispose runs), but H3 is guarded no-ops today (planes NIL from
closewin), so its only failure mode would be a double-free the guards
prevent.

The plan as written follows, kept for the record.

All three are local, unfalsifiable-by-inspection changes with no
behaviour a smoke test could show differently. They share one commit
and one boot test: if the box comes up and `NewShell CCON:` opens,
renders `list SYS:`, and closes cleanly, all three are exercised.

| # | Change | File position |
|---|---|---|
| B9 | `DEF ta:textattr` stack object, drop the `NEW` | `openwin()` :1715 |
| H3 | NIL-checked `Dispose`/`CloseFont` for `sb`/`sa`/`ss`/`sw`/`tf`/`altm`/`alta`/`alts` | `condispose()` :840 |
| H6 | `完全` -> `completely` | comment :2979 |

**Do B9 as its own edit and eyeball the compile.** The `NEW ta` ->
`DEF ta:textattr` change relies on E treating an object local as
stack-allocated with `ta` evaluating to its address. If that holds,
`ta.name := ...` and `fontload(ta)`/`OpenFont(ta)` compile unchanged
and the leak is gone. If E-VO does something surprising here (this is
the language that does not short-circuit OR/AND and mis-sizes bare
object members - see amiga-e-handler-tricks), the fallback is to keep
`NEW ta` and add `END ta` before every exit of `openwin()` instead -
same effect, uglier. Confirm which one compiled clean in the commit
message.

**H3 is belt-and-suspenders and must stay that way** - the planes are
NIL after `closewin()` runs, so every `Dispose` here is a guarded no-op
today. The point is that `condispose` becomes complete on its own
terms, not that it does work. NIL-check every one; an unguarded
`Dispose` of an already-freed plane is a double-free.

**Verify:** boot, `NewShell CCON:`, `list SYS:`, scroll back with
Shift+Up, close. Renders and closes clean = batch is good. None of the
three changes anything visible - B9's win is invisible per-open, H3 is
a no-op today, H6 is a comment. This batch is proved by "still works",
not by a new behaviour.

**Risk:** near zero. H6 is a comment; H3 is guarded no-ops; B9 is a
storage-class change that either compiles correct or does not compile.

---

## Batch B - the per-keystroke history walk - P3

**Finding:** P3 (RE-OPENED - audit.md wrote it, it was never applied).

The single highest-value item here: it is on the hottest interactive
path (`drawedit` -> `sgfind` every keystroke, `srfind` every keystroke
in Ctrl+R) and it is felt as typing latency on 7MHz, which is the whole
point of the machine.

Two independent halves, both in audit2.md P3:

1. **Kill the DIVS.** Replace `Mod(ghtotal - 1 - idx, HISTMAX)` with a
   decrementing index and a manual wrap. Apply to `sgfind()` :4699 and
   `srfind()` :4430 at minimum; the same `Mod` shape also lives in
   `histmatches()`/`histload()` (:4753, :4762) which run on the Up/Down
   walk - fold those in the same pass, they are the same idiom and the
   same fix. Do NOT touch the `histremember`/`savehistfile` dedup
   `Mod`s (:5697-5816) in this batch - those are cold-path (commit
   time, not keystroke time) and the ring math there is verified
   against histdeduptest.e; leave the harness's model matching the
   code.
2. **Add the early-out.** `sgfind()` gets a `RETURN` the moment it sets
   `curcon.sghost`; `srfind()` gets a `RETURN` (returning `got`) the
   moment `got` becomes TRUE. Both currently keep looping to `avail-1`
   after the hit with the guard uselessly inside the FOR.

The two halves are separable and could even be two commits, but they
touch the same two procs so one commit is fine. Keep them as distinct
EDITS within it - the early-out is a control-flow change, the manual
wrap is arithmetic, and a bisect reader should see which is which.

**Verify - this one has a real, feelable before/after.** The failure
mode is latency, so time it, do not just smoke-test:

- fill history to ~200 entries (the persisted `L:ccon-history` from
  daily use already does this, or replay a script of 200 commands);
- type a long line that is NOT a prefix of any history entry (forces
  the full 200-entry walk with no early hit) and judge the per-key
  responsiveness before and after. The audit's estimate is ~4ms/key of
  DIVS alone plus the StrLens - it should be perceptible on the target
  hardware with a full ring, and if it is NOT perceptible either way,
  say so in todo.md and downgrade P3 to "correct but unmeasurable"
  rather than claiming a win that cannot be seen.

**Correctness gate:** ghost suggestions and Ctrl+R search must still
find the SAME entries as before - the walk order (newest-first) and the
match test are unchanged, only the index arithmetic and the loop exit
move. Type a known prefix, confirm the ghost still appears; Ctrl+R a
known substring, confirm it still lands. A harness on `sgfind`'s
index sequence (old `Mod` form vs new manual-wrap form producing the
identical slot order) would prove the arithmetic before boot, the way
histdeduptest.e proved the dedup - cheap insurance given this file's
history of "obviously equivalent" rewrites that were not.

**Risk:** low-moderate. The logic is simple but it is on the most-typed
path in the file, and an off-by-one in the manual wrap would silently
show the wrong history entry as a ghost. Own commit; the harness above
is worth the ten minutes.

---

## Batch C - two robustness one-liners - B10, B11

**Findings:** B10 (selcopy LF overflow), B11 (dopaste infinite loop).

Independent of each other and of everything above. One commit is fine;
each wants its own repro to be honest, because both are "cannot happen
in normal use" bugs and a smoke test proves nothing about either.

1. **B11 - forward-progress guard in `dopaste()`** :2951. Compute the
   step and refuse a non-positive one: `step := 8 + sz + (sz AND 1);
   IF step <= 0 THEN <break the WHILE>; i := i + step`. Or the blunter
   `IF sz < 0 THEN RETURN` before the inject. A well-formed clip always
   steps forward, so nothing legitimate changes.
   **Repro:** write a malformed FTXT to the clipboard with a CHRS (or
   any) chunk whose size longword is negative, then RAMIGA-V. Before:
   the handler hangs (every CCON: window freezes - so test with a
   second window open and confirm IT freezes too, that is the whole
   severity). After: paste does nothing or pastes the valid prefix, no
   hang. Crafting the bad clip is the work - a tiny helper that
   `CMD_WRITE`s a hand-built FORM/FTXT with `sz = -16` in the chunk
   header. If that is more than the fix is worth right now, land it
   reasoned-not-reproduced (like B4 was) and say so in todo.md - the
   guard is obviously correct on its own terms.

2. **B10 - guard the inter-row LF in `selcopy()`** :2870. Either wrap
   the LF write in the same `IF len < (CLIPMAX - 64)` the char copy
   uses, or factor a `putclip(c)` that both the char and LF paths call
   so the headroom rule lives once. Fix the trailing pad write at :2882
   under the same rule while there.
   **Repro is awkward by design** - it needs `rows > ~44` AND a
   full-window dense selection saturating 16KB, i.e. a tall hi-res
   screen with a small font. If the test setup can open a screen tall
   enough (say 480+ rows-worth via a small font on a big screen),
   select-all-and-copy a full window of dense text and watch for a
   guru/corruption before and clean copy after. If the geometry is not
   reachable on the test rig, land it reasoned-not-reproduced: the
   overflow is arithmetic and the fix is the same guard the adjacent
   line already has, so this is a "make the headroom argument into an
   actual bound" change, not a behavioural one. Record which way it
   went.

**Risk:** low. B11 only refuses a malformed step; B10 only tightens a
write already meant to be bounded. Neither touches a normal path.

---

## Batch D - the filesystem-wait timeout - P6

**Finding:** P6 (was audit.md's P5 tail, promoted).

Two levels, and the roadmap should not pretend the big one is cheap:

1. **Minimum, do it now: the comment.** audit.md's P5 asked for a
   comment at `fscall()` naming the no-timeout risk and it was never
   added. Add it at :5472 - "WaitPort has no timeout; a wedged or
   spinning-up filesystem blocks THIS handler process, freezing every
   CCON: window it serves, on the Tab and Enter and startup-load
   paths." One line of prose, zero risk, so the next reader does not
   rediscover that the primitive can hang the box. Can ride in Batch A
   if wanted - it is just a comment.

2. **Real fix, its own piece of work, NOT smuggled anywhere.** A timeout
   means `fscall()` waits on TWO signals - the reply port and a
   `timer.device` request - and on timer-first gives up on the packet.
   The wrinkles are real: an abandoned packet is still owned by the
   filesystem and may reply later into a port we have moved on from
   (the reply must be drained or the packet must not be reused until it
   comes back), and every caller must handle a "timed out" return
   distinct from a "failed" one. This is comparable in weight to the B5
   teardown, not to a batch-A one-liner. Scope it separately; decide
   whether it is worth doing at all before writing it, since a wedged
   filesystem is a rare event and the current behaviour (hang) is at
   least not data-losing.

**Verify (the real fix, if attempted):** point a completion or a
history write at a device guaranteed to stall - an empty floppy drive
mid-spin-up is the classic - and confirm the handler recovers after the
timeout instead of freezing every window. Hard to stage reliably; part
of why the decision comes first.

**Risk:** the comment is zero. The real fix is moderate-to-high - it
touches the primitive every completion and history op rides, and a
mishandled abandoned-packet reply is its own class of guru. Own commit,
own boot test, own bisect file if pursued.

---

## Not scheduled

- **P6's real fix** may simply be declined - a rare hang that loses no
  data, against real complexity and its own guru surface. The comment
  (Batch A/D level 1) is the floor; the timer interleave is optional.
- Everything in audit2.md section 5 (CSI J/K params, cooked-commit
  enqueue, the recognised-chunk size read) stays out of scope for the
  reasons given there.

---

## Suggested commit sequence

```
1. ccon 1.2b15: audit2 batch A - stack the font textattr (B9),
                complete condispose (H3), scrub a stray comment (H6)
2. ccon 1.2b16: audit2 P3 - history walk drops the per-key DIVS and
                stops looping past the match
3. ccon 1.2b17: audit2 batch C - selcopy row-LF bound (B10),
                dopaste forward-progress guard (B11)
4. (decision first) fscall timeout - comment now, timer interleave if
   it is judged worth the weight
```

Batches B and C each want their own boot test before the next starts -
B because it is on the most-typed path and an off-by-one shows the
wrong ghost, C because both are repro-or-declare and should not be
bundled with an unrelated change if a bisect is ever needed.
