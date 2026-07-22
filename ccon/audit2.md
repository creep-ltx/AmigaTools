-> audit2.md - CCON codebase audit, second pass, ccon-handler 1.2b14
-> Read 22.7.26 against ccon-handler.e as of 1.2b14 (6363 lines).
-> Line numbers are as-of that revision and will drift once fixes
-> land; every finding names the PROC too, which will not.
->
-> Static read only - nothing here was boot-verified. Same disclaimer
-> as audit.md: findings are ranked by whether the trigger is
-> REACHABLE, not by how bad the consequence sounds. Where a trigger
-> needs a specific sequence, that sequence is spelled out so it can
-> be tested rather than argued about. See audit2-roadmap.md for the
-> order to work them in.
->
-> This is a FRESH pass, not a re-read of audit.md. The whole original
-> audit (B1-B8/P1-P5/H1-H5) is closed and its fixes were re-verified
-> present in the current source before this pass started: P1 hoist,
-> P2 AND-mask, P4 curcon-caching (drawmrow caches k:=curcon), H1 fsp
-> rename, H2 WCMAX, H5 ihdrop comment, and every B/P landed. So the
-> ground here is new code (reflow, ACTION_DIE, history dedup, paste,
-> completion) plus TWO audit.md findings that were written up and
-> never implemented (P3, H3), re-opened below.

# CCON 1.2b14 audit, second pass

Scope: `ccon-handler.e`, the whole file, proc by proc. IDs continue
audit.md's numbering (that file went to B8/P5/H5) so the B/P/H space
stays global - a bisect or a commit message can name B10 without
ambiguity. Two IDs are RE-OPENED rather than new: P3 and H3, both
specified in audit.md, both never applied.

## Status

| Finding | Kind | Reachable | State |
|---|---|---|---|
| B12 | freeze | any runaway/unbounded-output client | open - HARD LOCK, mechanism not yet located (22.7.26) |
| P3 | perf | every keystroke | **re-opened** - written in audit.md, never implemented |
| B9 | leak | every window open | open |
| B11 | robustness | crafted/buggy clipboard | open |
| B10 | correctness | extreme geometry only | open |
| P6 | robustness | wedged/slow filesystem | open (was audit.md's P5 tail) |
| H3 | hardening | latent, not live | **re-opened** - covered by closewin today |
| H6 | cleanliness | n/a | open |

Ranked hardest-to-avoid first. P3 and B9 fire in normal daily use; B11
and B10 need a specific trigger; H3/H6 are hygiene.

---

## 1. Performance

### P3 - history search does a DIVS per entry, per keystroke, with no early-out (RE-OPENED)

**Where:** `sgfind()` :4690, called from `drawedit()` :4295 (so: on
every keystroke at line-end); `srfind()` :4419 (every keystroke in
Ctrl+R mode). Both walk the shared history ring.

This is audit.md's P3, verbatim, still true. It was the one original
finding that was written up (audit.md section 2, P3) but never landed -
it is not in the audit.md status table, and the code confirms it:

```
FOR idx := 0 TO avail - 1
  IF curcon.sghost = NIL              -> guard is INSIDE the loop
    h := ghist[Mod(ghtotal - 1 - idx, HISTMAX)]   -> DIVS every iteration
    IF StrLen(h) > l                              -> StrLen every iteration
      ...
      IF ok THEN curcon.sghost := h
```

Two independent costs, both per keypress:

1. **`Mod(..., HISTMAX)` is a real DIVS.** HISTMAX is 200, not a power
   of two, so unlike the input ring (which P2 already converted to
   `AND (INQMAX - 1)`) this cannot be a mask. ~140 cycles on a 68000,
   200 of them, ~4ms - on top of the `StrLen` of every entry (up to
   400 bytes) and, on a length match, a fold-compare loop.
2. **No early break.** The `IF curcon.sghost = NIL` guard sits inside
   the FOR. Once a ghost is found the body is skipped but the loop
   STILL runs to `avail - 1`. `srfind()` has the identical shape
   (`IF got = FALSE` inside the loop). So even the best case - a match
   on the newest entry - pays the full 200 iterations of loop overhead.

The worst case is the common one: typing a command that is NOT a prefix
of anything in history walks all 200 entries, full cost, on every
character. This is exactly the "linux finger memory" hot path - it is
felt as typing latency on 7MHz, which is the machine this targets.

**Correctness note:** the `Mod` here is NOT the negative-argument guru
class (todo.md:63). `avail := Min(ghtotal, HISTMAX)` and `idx` in
`[0, avail-1]` keep `ghtotal - 1 - idx` in `[ghtotal-avail, ghtotal-1]`,
non-negative by construction. So this is purely a speed fix - but the
manual-wrap form retires the whole `Mod`-on-negative class as a bonus.

**Fix (as audit.md wrote it, two independent halves):**

- replace `Mod` with a decrementing index and a manual wrap
  (`i := ghtotal - 1; ... i--; IF i < 0 THEN i := HISTMAX - 1`), so the
  ring walk is add/subtract only - the same discipline the render paths
  already hold (todo.md's "no Mod/DIVU in render paths" rule; this is
  a per-keystroke path and should obey it too);
- give `sgfind()` an early `RETURN` the moment it sets `sghost`, and
  `srfind()` an early `RETURN`/break the moment `got` is TRUE.

The two halves are separable; the early-out alone removes the
best-case waste, the manual-wrap alone removes the DIVS. Do both.

### P6 - `fscall()` has no timeout on `WaitPort` (was audit.md's P5 tail)

**Where:** `fscall()` :5472, the `WaitPort(fsport)` at :5484.

Audit.md's P5 closed the per-Enter history rewrite but explicitly left
this: "`fscall()` has no timeout on `WaitPort(fsport)`. A wedged or
spinning-up filesystem freezes every console this process serves." It
is promoted to its own ID here so the roadmap can carry it rather than
leaving it as a footnote to a closed finding.

`fscall()` is the hand-rolled exec-level packet primitive
(`PutMsg` -> `WaitPort` -> `GetMsg`) that tab completion and every
history-file operation ride. It sends to a foreign filesystem port and
blocks the whole handler process until that filesystem replies. There
is no timeout: a filesystem that is spinning up (a floppy, a slow
network mount) or wedged never replies, and the handler - a single
process serving every CCON: window - is stuck in `WaitPort`, including
the window that would show the error.

**Reachable:** the Tab path (`tcscan` -> `tcscanone` -> `fscall`) and
the Enter path (`histappend`/`savehistfile` -> `fscall`), plus the
one-time `loadhistfile` at first open. Any of these against L: or a
completion target on a slow/absent device.

**Fix:** not a one-liner, and it should not be smuggled into another
batch. A real timeout means interleaving a `timer.device` request with
the reply `WaitPort` (wait on both signals; on timer-first, abort the
packet or give up on it) - genuine work, its own commit. At MINIMUM,
a comment at `fscall()` naming the risk, so the next reader does not
have to rediscover that the primitive can hang the box. audit.md's P5
entry asked for the comment and it was not added; add it.

---

## 2. Bugs

### B12 - a client that never stops writing HARD-FREEZES the whole machine

**Where:** the output/write path - `dowrite()` :1153, `render()`, and
whatever the main loop does (or fails to do) between client packets.
The exact freezing instruction is NOT yet located; this entry records
what is known and what is ruled out, not a mechanism dressed as one.

**Found:** 22.7.26, running `ls -R DH0:` under CCON. `ls -R` has its own
infinite-loop bug (ls/BUGS.md B1) that makes it emit output forever with
BOUNDED memory. That is the trigger, not the cause: any client that
produces unbounded output - a runaway program, a `type` on an enormous
file, a stuck loop - is the same input to CCON.

**Symptom:** after a while of the flood, the WHOLE machine freezes -
**mouse dead, no guru, nothing responds.** Not slow: dead. Only recovery
is a reset.

**This is CCON's, proved the cheapest way (the ViNCEd/stock-CON:
comparison this project keeps re-learning to run FIRST):** the SAME
`ls -R DH0:`, the SAME infinite output, under **ViNCEd does NOT freeze
the machine** - it loops visibly and stays alive (it even let the output
be redirected to a file). Same client, same flood, different console,
different outcome. So the freeze is something CCON does under sustained
output that ViNCEd does not.

**What is ruled OUT (so the next person does not re-check them):**
- **CCON leaking memory per write.** `dowrite()` and `render()` allocate
  NOTHING per write; the scrollback ring is a fixed New() at window
  open and is written in place. Verified by read.
- **The client OOMing the box.** `ls -R`'s loop re-lists the same
  directory with a FIXED-length path (`cmenu/`, never `cmenu//`), so its
  own memory is bounded - it does not exhaust RAM. If it did, ViNCEd
  would freeze too. It does not.
- **CCON RENDERING the flood (ruled out 22.7.26, the key update).** A
  second run sent `ls -R`'s output to a FILE (`>Amiga:...`) instead of
  the window - CCON was idle, rendering nothing - and it STILL hard-
  froze (mouse dead, hard shutdown required). So the freeze is not in the
  render/scroll/per-write path at all. The earlier "per-write cycle
  chokes" hypothesis is dead.

**REVISED leading hypothesis (22.7.26), still a hypothesis:** `ls` is
provably CORRUPTING THE HEAP (ls/BUGS.md B1: the blank-name pattern is
progressive and systematic - 18/14/10/6 blanks across successive
re-listings in the CCON capture, a textbook heap-overwrite signature).
The one thing CCON does even while idle is run its **input.device chain
handler** on every input event (including mouse moves); its structures
(`ihring`, the chain hookup) live in the shared system heap. So: `ls`'s
overwrite clobbers those structures -> the next mouse move runs the
corrupted handler IN input.device's context -> it faults/spins there ->
input.device dies -> mouse frozen, whole machine dead, no guru. This
fits all symptoms AND explains the ViNCEd differential: ViNCEd installs
no input.device chain handler, so the same `ls` corruption has no fatal
target there. If correct, the ROOT is ls's heap bug and CCON's chain is
collateral - but a console whose in-heap structures are a fatal target
for any heap-scribbling client is still a hardening concern.

**DECISIVE TEST RUN (22.7.26) - REFUTES a CCON bug.** The EXACT command
that froze CCON (`ls -R Amiga: >file`) was run under ViNCEd: it FROZE
ViNCEd identically - mouse dead, Ctrl+C dead, hard shutdown. Same client,
same target, BOTH consoles hard-lock. The freeze is CONSOLE-INDEPENDENT:
`ls` corrupts the shared heap (ls/BUGS.md B1) badly enough to take down a
machine with no memory protection, whichever console hosts the shell. The
input-chain hypothesis below is REFUTED (ViNCEd installs no chain handler
yet died the same). The earlier "CCON freezes, ViNCEd survives" was a
TARGET difference - the `Amiga:` tree corrupts fast, the `DH0:` ViNCEd
run was stopped before it got there - not a console difference.
Everything from here to the Status line is the chase as it stood BEFORE
this test, kept as the record; it assumed a CCON bug and is superseded.

**What the symptom CONSTRAINS (mouse dead, not just unresponsive):** a
mouse that stops moving means **input.device itself is blocked**, i.e. a
true HARD LOCK, not task-level CPU starvation. A CCON main task merely
pinned rendering forever would leave the mouse alive (input.device is a
higher-priority task/interrupt path) and would at worst make CCON
unresponsive while the pointer still moved. Mouse-dead therefore points
at one of:
- **the input chain (`ihchain`/`ihdrain`), which runs IN input.device's
  task**, blocking or spinning. The ring is documented to DROP when full
  (`ihdrop`), which SHOULD keep input.device alive - so if this is the
  cause, either the drop path is not actually reached under this load,
  or the main loop starves the drain while it services a packet flood,
  and something downstream blocks input.device rather than dropping.
- **a `Forbid()`/`Disable()` held too long or across a loop** somewhere
  reachable from the write/scroll path (the list is Forbid-bracketed on
  mutation, and the design explicitly relies on Forbid holding off
  input.device's task - a Forbid that is entered and not promptly left
  under flood would freeze exactly like this).
- **main-loop fairness**: if the loop drains ALL pending client packets
  in a tight inner loop without ever servicing the input signal, input
  backs up; combined with either of the above this is the freeze.

**Reachable:** needs SUSTAINED / unbounded output, so not the everyday
case (normal commands finish and the machine is fine - the user's
repeated `ls -a c:` never froze). But any runaway client reaches it, and
the consequence is the worst in either audit: a dead machine, unsaved
work in every other program lost. High severity, narrower trigger.

**Next step is TELEMETRY, not a blind fix** (the house rule, and this is
exactly the kind of bug that punishes guessing). Instrument, under a
deliberately-throttled or bounded flood so the box can still be read:
whether the main loop ever services input while WRITE packets are
pending; whether `ihring` is dropping (`ihdrop` climbing) or the chain
is blocking; whether any `Forbid`/`Disable` nests or is left set across
`render`/`screenscroll`. ViNCEd is the working oracle - the fix target
is whatever CCON does differently under an endless writer. Do NOT
reproduce it full-speed on a machine with unsaved state; it hard-locks.

**Status: CLOSED - NOT a CCON bug (22.7.26).** The ViNCEd repro (top of
this entry) proves it console-independent: root cause is ls/BUGS.md B1
(heap corruption + infinite `-R` recursion). There is no reasonable CCON
fix - any app that scribbles the shared heap can freeze an AmigaOS box,
and ViNCEd defends no better. Lesson re-paid (see amigatools-workflow):
run the cheap client-vs-console comparison BEFORE theorising about the
console's internals - the input-chain theory was plausible, careful, and
wrong, and one ViNCEd run beat it. The fix lives in the `ls` project.

### B9 - `openwin()` leaks a `NEW ta` on every window open

**Where:** `openwin()` :1715 (`NEW ta`), inside the
`IF curcon.fwin = FALSE` arm.

Every non-borrowed window open allocates a fresh `textattr` with
`NEW ta` and never frees it. It is pure scratch - `ta` feeds
`fontload()`/`OpenFont()` and nothing else; the opened font lands in
`curcon.tf`, not `ta` - so after `openwin()` returns the pointer is
lost. A grep of the whole file confirms `NEW ta` is the only one and
there is no `END ta` / `Dispose(ta)` anywhere.

E's `NEW` memory rides the process New/String list and is reclaimed by
`CLEANUPALL`/`FREEBUFFERS` - but only when `main()` RETURNS, i.e. at
process exit. For an immortal handler that is *never* in normal life
(only on ACTION_DIE, B5). So this is an unbounded accrual: ~8 bytes
(`SIZEOF textattr`: name PTR + ysize + style + flags) per window open,
held until the handler dies.

**Trigger, reachable:** any repeated open/close - `NewShell CCON:`
in a loop, or a session that opens and closes many windows over days.
~8 bytes each means it is slow (~130k opens per leaked MB), but it is
real, unbounded, and exactly the class this project cares about: a
handler that is up for weeks should not accrete anything per-operation.

**Consequence:** slow FastMem exhaustion on a long-lived handler that
churns windows. Not a crash risk on any realistic timescale, but a true
leak in code whose whole teardown story (B5) is about freeing every
non-E-tracked resource - and this one IS E-tracked, so it hides from
that reasoning while still never being freed in practice.

**Fix:** make `ta` a stack object - `DEF ta:textattr` and drop the
`NEW` (E object locals are stack-allocated and `ta` evaluates to their
address, so the `ta.name := ...` assignments and the `fontload(ta)` /
`OpenFont(ta)` calls are unchanged) - or, if kept on the heap for any
reason, `END ta` before every `RETURN`/exit of `openwin()`. The stack
form is preferred: it is one-per-call by construction and cannot leak.

### B11 - `dopaste()` trusts the IFF chunk size and can loop forever

**Where:** `dopaste()` :2913, the chunk-walk loop :2936-2951.

```
WHILE (i + 8) <= got
  lw := clipbuf + i
  id := lw[0]
  sz := lw[1]                    -> UNTRUSTED: any app writes the clip
  IF id = $43485253
    ...
  ENDIF
  i := i + 8 + sz + (sz AND 1)   -> i can go BACKWARD if sz < 0
ENDWHILE
```

`sz` is read straight from the clipboard IFF stream, which is written
by any program on the system - it is not our data and not validated. E
LONGs are signed, so a chunk claiming a negative size (a hostile clip,
or a corrupt/truncated one) makes `i := i + 8 + sz + (sz AND 1)` fail
to advance: at `sz <= -8` the increment is `<= 0`, `i` stalls or
decreases, `(i + 8) <= got` stays true, and the `WHILE` spins forever.
That hangs the handler PROCESS - single-threaded, so every CCON: window
this handler serves freezes, not just the one that pasted.

**Reachable:** paste (RAMIGA-V) with a malformed or hostile FTXT clip
in unit 0. `take := Min(sz, got - i - 8)` is separately clamped so the
`CHRS` inject does no OOB read - the ONLY failure is the non-progress
loop, but that failure wedges the box.

**Fix:** require forward progress. Either bail on a bad size
(`IF sz < 0 THEN RETURN` / break) or compute the step and refuse to
loop unless it is strictly positive (`step := 8 + sz + (sz AND 1);
IF step <= 0 THEN <break>; i := i + step`). A well-formed clip always
has `sz >= 0`, so no legitimate paste is affected.

### B10 - `selcopy()`'s inter-row LF write is unguarded (bounded overflow)

**Where:** `selcopy()` :2845; the guarded char copy at :2864
(`IF len < (CLIPMAX - 64)`) versus the UNguarded LF at :2870-2871.

The per-character copy into `clipbuf` is capped:

```
IF len < (CLIPMAX - 64)
  p[len] := IF c < 32 THEN 32 ELSE c
  len++
ENDIF
```

but the newline written between rows is not:

```
IF r < r1
  p[len] := 10              -> no `len <` guard
  len++
ENDIF
```

The `- 64` headroom is an argument, not a bound: it assumes at most a
screen's worth of trailing LFs after the text saturates. `p` is
`clipbuf + 20` (past the IFF header), so `p[len]` overruns `clipbuf`
(16384 bytes) once `len` reaches `CLIPMAX - 20`. From the saturation
point (`CLIPMAX - 64`) that is 44 more LF increments.

**Reachable, but only at extreme geometry.** Selection height is bounded
by the VISIBLE grid - `cellat()` returns a visible-row cell, so `r0..r1`
in `selcopy` is at most `rows - 1`, not the whole scrollback. On a
typical window (a few tens of rows) 44 rows of headroom is plenty and
the argument holds. It breaks only where `rows` can exceed ~44 AND the
selected text is dense enough to hit `CLIPMAX - 64` first: a tall
hi-res screen with a small font (a 1024-high screen at a 6px font is
~170 rows) selected full-window with substantial content. Then every
row past saturation adds an unguarded LF, `len` runs past the buffer
end by up to `(rows - 44)` bytes, and `clipbuf`'s heap neighbour is
corrupted.

**Consequence:** heap corruption on copy - a delayed guru or silent
damage rather than an immediate one, since it scribbles past `clipbuf`
into whatever New() handed out next. Bounded (tens to low hundreds of
bytes at the worst plausible geometry), but real.

**Fix:** guard the LF the same way the chars are guarded -
`IF len < (CLIPMAX - 64) THEN p[len] := 10; len++` (or a shared
`putclip(c)` helper both paths call, so the headroom rule lives in one
place). The trailing pad write at :2882 (`IF pad THEN p[len] := 0`)
is then also inside the headroom by the same argument.

---

## 3. Consistency and hardening

### H3 - `condispose()` still does not free the model planes (RE-OPENED)

**Where:** `condispose()` :840.

audit.md's H3, unchanged: `condispose()` frees the ten E-strings
(`ebuf`/`stash`/`wtitle`/`wtitlebase`/`tctmp`/`tctail`/`tcpool`/`srbuf`/
`srstash`/`pasteq`) and the console itself, but NOT the seven model
planes (`sb`/`sa`/`ss`/`sw`/`tf`/ the alt-screen `altm`/`alta`/`alts`).

**Still not a live leak, for the same reason as before.** `condispose`
is only ever reached from `conclose()`, which calls `closewin()` first,
and `closewin()` now frees `sb`/`sa`/`ss`/`sw`/`tf` (:1957-1976) and
calls `altdrop()` for the alt-screen planes. The `win = NIL` early
return in `closewin` provably cannot have allocated planes (openwin
returns before the ring alloc on failure). So today every plane is
freed before `condispose` runs.

But it is an invariant held by ARGUMENT - "closewin always runs first
and always frees them" - and `condispose` is exactly the proc a future
teardown path would call directly, expecting it to be complete. The B7
work already added the `sw` plane to `closewin`'s free list; the same
plane is absent from `condispose`, widening the gap.

**Fix (unchanged from audit.md):** NIL-checked `Dispose`/`CloseFont`
for the seven planes in `condispose`, guarded so double-free is
impossible (they are NIL after closewin ran). Costs nothing at runtime
and makes the proc self-evidently complete instead of correct-by-
coincidence-with-its-only-caller.

### H6 - stray non-ASCII bytes in a comment

**Where:** `pasteinsert()`'s doc comment :2979.

The line reads `-> SEES is always完全 ordinary, single-line, ACTUAL`
- two Han characters (完全, "completely") are embedded mid-sentence,
the only non-ASCII bytes in the entire 6363-line file (verified by a
`grep -P '[^\x00-\x7F]'` sweep). Harmless to the compiler, but it is
an obvious edit artefact in an otherwise-clean file whose commentary
is a deliberate part of its quality. Scrub it (`always completely
ordinary`).

---

## 4. What is right (second pass)

The first audit's "what is right" still stands; these are things the
NEW code got right, worth recording so they are not second-guessed.

**The reflow engine did NOT rewrite the ring.** `reflowring()` /
`rfemit()` / `rfmark()` rejoin logical lines through ONE added byte per
row (the `sw` soft-wrap plane) and re-wrap at the new width, leaving
`visrow`/`sarow`/`ssrow`/`selvidx`/`redraw`/`drawmrow` untouched. The
audit had called level-2 reflow "a rewrite of the ring's
representation"; the cheaper structure was found instead, and it is
harness-proven pixel-identical on the round trip. `rfnewrow`'s clear-
on-advance (with the comment explaining the phantom-row hazard when the
reflow outgrows the ring) is the kind of edge the harness earned.

**The escape parser is properly bounded.** `csistart()` resets `cnp`,
`cpriv` and all four `cpar` slots; the accumulator clamps `cnp` to 3
(the `cpar[4]` bound) and values to 999; `cpriv` is reset per sequence,
so a stale DEC-private `?` from one CSI cannot misfire the alt-screen
path on the next. No parameter path can overflow.

**The completion lock lifecycle is airtight.** `tcresolve()` releases
its `LockDosList` on all three exits, `fsdirfree` cleanly separates an
owned LOCATE lock from a borrowed assign/CWD lock, and every FALSE
return leaves `fsdirfree = FALSE` so the `dotab` path that skips
`tcfreelock` on failure leaks nothing. `dotab` pairs `tcresolve` with
`tcfreelock` on the success path.

**`killhandler()` is exactly scoped.** It frees ONLY the exec resources
E's exit does not track (the input.device handler FIRST, then
devices/ports/library/signals), and deliberately leaves `clipbuf`/
`fspkt`/`fsfib`/`fsname` to `CLEANUPALL` because they ARE E-tracked and
allocated once. That reasoning is correct - and it is also precisely
why B9 hides: `ta` is E-tracked too, so it is invisible to this proc's
logic, yet unlike those one-time buffers it is allocated per-open and
never actually reclaimed until exit.

**History dedup is sound.** `histremember()`'s move-to-end (shift the
newer entries down over the dup, step `ghtotal` back, append) keeps one
copy per command; the file may accumulate dups because the append path
cannot rewrite an old line, but it is bounded to `[0, 2*HISTMAX)` and
re-deduped on every load and every trim. The `Mod` sites here are all
non-negative by construction (`Min(ghtotal, HISTMAX)` bounding). All
documented, all matching the harness (histdeduptest.e).

---

## 5. Not in scope, deliberately

- **`CSI J`/`K` ignoring their parameter** (:3432-3435) - only "erase
  below" / "erase to EOL" are implemented, no `1`/`2` variants. A
  documented completeness limit matching what More/Ed actually send,
  not a defect.
- **The cooked commit path enqueues line bytes without `inqroom`**
  (:4869-4872) - unlike B3's report case, a full cooked queue dropping
  input bytes is benign (the reader is simply behind), not a parser
  desync. Leave it.
- **`dopaste`'s IFF size read for a chunk it does not recognise** - the
  only real hazard there is the non-progress loop (B11); the size
  itself is used correctly for known chunks. Fixing B11 covers it.
- Everything audit.md listed as out-of-scope (`tcscancmd`,
  `domenupick`, `WINDOW0xADDR`, `rearmtimer` re-arm, the ihchain
  address-reuse race) remains out of scope for the same reasons.
