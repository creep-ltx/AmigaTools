-> audit-fix-roadmap.md - working order for the 1.2b1 audit findings
-> Companion to audit.md; finding IDs (B1-B6, P1-P5, H1-H5) are that
-> file's. Ordered so that the cheap, unfalsifiable changes land
-> first and the ones that need a real boot test land alone, where a
-> bisect can name them.
->
-> Nothing here was boot-verified. Every batch below states what
-> would prove it, because a fix that cannot be shown failing before
-> and passing after is not a fix, it is a hope.

# Fix roadmap

Six batches. Batches 1-3 are safe to work straight through. Batch 4
onward each want their own boot test and their own commit.

Build/deploy per the usual routine: ecompile via vamos, copy
`ccon-handler` to the FS-UAE AmigaOS3.2 `L/`, reboot, mount, test.

---

## Batch 1 - mechanical, no behaviour change - DONE (1.2b2, 21.7.26)

**Findings:** P1, P2, P4, H1, H2, H5

**Outcome:** all six landed in one commit. Compiled clean (LARGE) with
a warning/UNREFERENCED set byte-identical to the baseline build, so no
new locals dangling. Binary 73072 -> 72728, 344 bytes smaller. Boot
test passed: shell, `list SYS:` colour and wrapping, scrollback
paging, drag-select round trip.

**Deviation from the plan below, deliberate:** `render()` got P1 only,
not the P4 caching pass. It calls out to `outnl`/`outchr`/
`csidispatch`, so caching there is a much bigger diff to review for a
much smaller win than the three pure paint procs. If `render()` is
wanted too it should be its own commit. See todo.md 1.2b2.

**Also learned during deploy:** the binary in `L/` was stamped 1.1b46
though the code matched 1.2b1 (28 differing bytes, all `$VER`). Deploy
now keeps `L/ccon-handler.bak` as the revert point. Do not infer the
deployed version from file size.

The original plan follows, kept for the record.

Every item is a local rewrite with no semantic change. They can share
one commit and one boot test, because if the boot comes up and a
`list SYS:` renders correctly, all of them are exercised.

| # | Change | File position |
|---|---|---|
| P1 | Hoist `at := curattr()` out of the per-cell loop | `render()` :3388 |
| P2 | `Mod(..., INQMAX)` -> `AND (INQMAX - 1)` (3 sites) | `enqueue`/`inavail`/`satisfyreads` |
| P4 | Cache `c := curcon` in the paint procs; fold the repeated `selvidx(r)` and `Mul(idx, cols)` | `drawmrow`, `drawselrow`, `drawmodelcells`, `render` |
| H1 | Rename local `port` -> `fsp` | `loadhistfile`, `savehistfile` |
| H2 | Add `WCMAX=8`, use it at the two literal sites | CONST block, `dopkt` :906 |
| H5 | Surface or annotate `ihdrop` | `ihchain` :4639 |

**Do P2 and P4 as separate edits even inside the one commit** - P4
touches the same lines as P1 in `render()`, and doing them in one pass
makes it harder to see that the attr hoist is the only semantic-shaped
change in the batch.

**Verify:** boot, `NewShell CCON:`, `list SYS:`, type a line, scroll
back with Shift+Up. Colours, wrapping and scrollback all still right =
batch is good. The typing latency improvement from P2 will not be
visible yet - P3 is where that lives.

**Risk:** near zero. H1 is a rename; if it compiles it is correct.

---

## Batch 2 - the anchor guard (B1 + H4) - DONE (1.2b3, 21.7.26)

**Findings:** B1, H4

**Outcome:** the repro-first sequencing below was worth it twice over.

1. A throwaway harness (`edanchortest.e`) extracted the anchor/extent
   logic over a fake ring and reproduced the model corruption - and
   pinned a precondition the audit had OVERSTATED. A cols-wide write
   turned out to be necessary but not sufficient: the row the
   post-commit anchor lands on must also hold content. audit.md B1 is
   corrected accordingly.
2. The harness also caught a wrong first draft of the FIX. "Zero the
   fields at the top" would have skipped the erase on the normal path,
   because the erase loop reads the count. Scenario C was added to
   guard that specifically, and the shipped fix takes the extent into
   locals instead.
3. Because only the fixed binary was deployed, a clean result would
   have been ambiguous - "the fix works" and "the repro never fired"
   look identical. So an A/B pair was built, differing ONLY in this
   proc plus the version string (source diff verified). On hardware:
   `1.2b3-BROKEN-B1` punches a hole in the row below the echoed
   command, exactly as wide as the typed line; `1.2b3` leaves it
   intact. Everything else in the two screenshots is identical.

**H4 resolved as a COMMENT, and the guard would have been wrong** - see
audit.md. `ancx = cols` is the legal pending-wrap anchor and the editor
must still paint there.

**Regression:** the existing gates all still pass - `ccon-bisect` five
for five, `ccon-progress`, `ccon-ichdch`. Those are the b8
theft-pattern tests, i.e. the direct gate on this code path.

**Test scripts added** to `S/` in the house `Type`-a-byte-file style:
`ccon-b1` (Execute; fills the screen and sets an invisible prompt that
parks the anchor on the margin via `CSI 7;999H`, width-independent
because csidispatch clamps the column to `cols`), `ccon-b1-fill`,
`ccon-b1-off`.

The original plan follows, kept for the record.

These are one problem seen from both ends: `eraseedit` and `drawedit`
disagree about whether `ancx >= cols` is a legal state. Fix them
together or the next reader will re-derive the disagreement.

1. **B1:** zero `edlast`/`edext` before BOTH early `RETURN`s in
   `eraseedit()` (:3448, :3449). Preferred shape: set them at the top
   of the proc, before the guards, since the semantics are "the paint
   this proc was told about is gone" and both returns mean exactly
   that.
2. **H4:** either add the matching guard to `drawedit()` or write the
   comment explaining why `ancx = cols` is safe there (the first
   mirror iteration computes `n = 0` and rolls to the next row
   consistently with the blip math). A comment is acceptable; silence
   is not.

**Verify - this one needs a real repro, not a smoke test.** The
trigger is a write ending exactly at the right margin. Produce it
deliberately:

- size the window to a known `cols`
- `echo` a string of exactly `cols` characters with no newline
- then trigger a second write and confirm the first line's tail
  survives in the model, not just on glass (scroll back and look, or
  drag-select the row and check what lands in the clipboard - the
  model is what selection copies, so selection is the honest test)

Before the fix that row should lose its tail cells; after, it should
not. If it does not reproduce, say so in todo.md and downgrade B1 to
"argued, not observed" rather than quietly keeping the fix.

**Risk:** low, but it is on the edit-line paint path, which is the
most-touched code in the file. Own commit, own boot test.

---

## Batch 3 - two bounded correctness fixes

**Findings:** B2, B4

Independent of each other and of everything above. One commit is fine;
two boot tests are not needed, but two repros are.

1. **B2 - `sbcnt` clamp.** Three lines after `gridcalc()` in
   `doresize()`. Repro: fill the scrollback, enlarge the window,
   Shift+Up to the far end. Duplicated/stale rows before, clean
   history after.
2. **B4 - AUTO retry.** Clear `autopend` on `openwin()`'s failure
   return. Repro is awkward to force honestly (it needs `openwin` to
   fail), so the cheap proof is the title: with `ihon = FALSE` and a
   deliberately unopenable window spec, `wtitlebase` should not
   accumulate `[no chain]` repeats. If forcing the failure is more
   trouble than it is worth, land the fix and record in todo.md that
   it is reasoned-not-reproduced.

**Risk:** low. B2 only tightens a clamp; B4 only stops a retry.

---

## Batch 4 - atomic reports (B3)

**Finding:** B3

The first batch that adds a function rather than editing one.

Add `enqueuestr(b:PTR TO CHAR, len)` (or an `inqroom(n)` predicate)
that checks `inavail() + len < INQMAX` once and either writes the
whole span or drops it whole. Convert the three report builders:

- `ihreport()` :4758 - introducer + `StrLen(b)` + `|`
- `sendreport()` :3211 - introducer + `StrLen(b)` + space + `r`
- `rawcsikey()` :4335 - the fixed 3-5 byte forms

All three already know their length before the first byte, so no
buffering change is needed - just compute the total and ask once.

**Verify:** the failure mode is what to test, and it is hard to
provoke by hand. Cheapest honest proof: temporarily shrink `INQMAX`
to something small (64), boot, and drive a client that reports
(Ed with its `CSI 12{ 2{ 10{ 11{`). Before the fix Ed's parser should
misbehave once the queue fills; after, it should merely miss events.
Restore `INQMAX` before committing.

If that is more instrumentation than it is worth right now, the fix is
still correct on its own terms and cheap - but land it in its own
commit so a later bisect can reach it.

**Risk:** low-moderate. Touches the input queue, which every client
reads through. Own commit.

---

## Batch 5 - `savehistfile()` restructure (P5)

**Finding:** P5, plus the `fscall()` timeout note

The largest change here and the one with the most design freedom, so
it goes last among the fixes. Two candidate shapes, in order of
preference:

**Option A - append only.** Keep the ring in memory as now, but on
commit write ONE line: `FINDUPDATE` (or keep a handle open across
commits), seek to end, write the line. The full-ring rewrite then only
happens where it is genuinely needed - at last-window-close, or when
the ring wraps and the file needs truncating to `HISTMAX` lines.

Cost: a persistent open handle on `L:ccon-history`, which is state the
handler must release correctly on every teardown path
(`conclose`, and `ACTION_DIE` once B5 exists). That is the real work.

**Option B - dirty flag + timer flush.** Set `histdirty := TRUE` on
commit; flush from the existing `timer.device` tick a few seconds
later. A burst of commands costs one write. No persistent handle, so
no new teardown obligation - but it reintroduces a small loss window
on an unclean reboot, which is exactly what todo.md:1474 moved away
from.

**Recommendation:** A if the handle lifecycle can be made clean;
B otherwise. B is strictly better than today either way.

**Also in this batch:** at minimum add a comment at `fscall()` :4786
naming the no-timeout risk (a wedged filesystem freezes every console
this process serves, on both the Enter and the Tab path). An actual
timeout needs a second timer request and is probably a separate piece
of work - do not smuggle it in here.

**Verify:** time a burst of ten commands before and after, on the
slowest device the test setup can offer. The improvement should be
obvious without instrumentation; if it is not, the fix did not do what
it was supposed to.

**Risk:** moderate. Own commit, own boot test, and worth a bisect file
if anything downstream gets strange.

---

## Batch 6 - policy decisions (B5, B6)

**Findings:** B5, B6

Both are behaviour changes rather than bug fixes, so they want a
decision before they want code.

**B5 - `ACTION_DIE`.** Refuse while `conlist` is non-NIL, otherwise
tear down (remove the input handler, close input/timer/clipboard,
free `ihring`/`ihis`/`fhstub`) and exit. Mostly a development-quality
improvement: it makes mount/unmount cycles on the test machine clean.
Worth doing, low urgency.

**B6 - `DISK_INFO` fallback.** Change `conbysender()`'s list-head
guess to a failure for `DISK_INFO` specifically, leaving the guess in
place for `WAIT_CHAR`/`SCREEN_MODE`/`CHANGE_SIGNAL` where a wrong
answer is merely wrong.

This one is a genuine judgement call and it could break something:
the fallback exists because some client did not resolve any other way.
If the chain (CLI StandardInput -> breaktask -> active window) is in
practice always sufficient for the clients that ask for `DISK_INFO`
(More, Ed), failing is strictly safer. If it is not, failing breaks
them.

**Suggested approach:** instrument before changing. Add a temporary
counter or telemetry line on the list-head fallback path, boot, run
the usual More/Ed/shell rounds, and see whether it is ever taken. If
it never fires, the change is free. If it fires, the question is which
client and why - and that answer is more valuable than the fix.

---

## Not in scope, deliberately

- **`tcscancmd()` (:3163)** - dead but documented as deliberately
  parked, with the reasoning intact. Leave it. Removing it would cost
  the plumbing rediscovery it exists to prevent.
- **`domenupick()` (:3040)** - empty stub with five unused params,
  reachable only in the `ihon = FALSE` fallback where picks are
  deliberately swallowed. Documented. Leave it.
- **`WINDOW0xADDR` taking an arbitrary pointer** - inherent to the
  CON:-compatible feature, not a defect.
- **`rearmtimer()` re-arming with the full original timeout** - a
  starvation vector in principle, documented as an accepted
  approximation. Not worth the complexity of tracking elapsed time
  per waiter unless something is actually observed to hang.
- **`ihchain` / `conclose` address-reuse race** - the window requires
  the main task to preempt input.device's task, which cannot happen at
  their relative priorities. Correct as written; noted only so it is
  not re-derived as a bug later.

---

## Suggested commit sequence

```
1. [DONE 1.2b2] audit batch 1 - hoist curattr, power-of-two inq, paint-loop locals
2. [DONE 1.2b3] eraseedit's early returns must not leave a stale paint extent
3. ccon 1.2b4: clamp sbcnt when a resize grows the grid; stop AUTO retrying a failed open
4. ccon 1.2b5: CSI reports enqueue whole or not at all
5. ccon 1.2b6: history persists by append, not by rewriting the ring per command
6. (after a decision) ACTION_DIE; DISK_INFO stops guessing
```

Batches 2, 4 and 5 each want their own boot test before the next one
starts - they are the three that could plausibly regress something,
and keeping them separated is what makes a bisect cheap if one does.
