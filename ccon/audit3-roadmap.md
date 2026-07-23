-> audit3-roadmap.md - working order for the third-pass audit findings.
-> Companion to audit3.md; finding IDs (C1-C10, P1-P4, X1-X5) are that
-> file's. Deliberately a FRESH series, not a continuation of audit.md /
-> audit2.md's global B/P/H numbering - this pass reads the RELEASED 1.2
-> source, and mixing the IDs would make "is B9 fixed?" ambiguous forever.
->
-> Same ordering rule the two earlier campaigns used: the cheap,
-> unfalsifiable changes land first in one commit; anything that needs a
-> real before/after lands alone, where a bisect can name it.
->
-> STATUS: shipped as 1.2.1 (tag ccon-1.2.1, PR #8). C2 - the fix the
-> campaign turned on - was verified on hardware: resize, iconify,
-> restore, and the window came back at the right size with its
-> transcript intact. Every batch below states what would prove it.
-> A fix that cannot be shown failing before and passing after is not a
-> fix, it is a hope. (Campaign one was overturned by its own harness
-> three times - B1, B2, B7 - so this is not a slogan.)

# Fix roadmap, third pass

## Is this a big job?

**No.** That is the honest headline and it is worth stating before the
batches, because "ten correctness findings" reads worse than it is.

Eight of the ten are between one word and eight lines:

| ID | Fix | Size |
|---|---|---|
| C3 | `IF conok(c) AND c.appicon` | 1 word |
| C4 | clamp `sz` against the buffer, not just zero | 1 line |
| C9 | `curcon.sbsrch := FALSE` in `snaplive()` | 1 line |
| C10 | floor `edcap()` at 0 | 1 line |
| X1 | delete the unreachable duplicate block | -11 lines |
| C7 | `CloseLibrary(diskfontbase)` in `killhandler` | 4 lines |
| C6 | reply `-1`/`ERROR_NO_FREE_STORE` instead of faking success | 2 lines |
| C1 | floor `sbmax` at `rows + 2`, re-apply on resize | ~6 lines |
| C8 | re-add the AppIcon when `reopenwin()` fails | ~5 lines |
| C2 | snapshot live geometry in `hidewin()` + stride guard | ~8 lines |
| C5 | drain the queue mid-paste | ~8 lines |

**Two of those estimates turned out wrong, and the corrections are in the
batch write-ups below rather than quietly patched into this table:**
**C5 cannot be fixed in 8 lines** (the drain does not work - see Batch C),
and **C6 was deliberately not done at all** (see Batch A). The rest held.

The two perf items are the only real work: **P2** is mechanical (the
same `curcon` hoist audit2-P4 already did three times, applied to
`render()`), and **P1** is the only genuinely NEW logic in the campaign
(~35 lines, and it reuses `ScrollRaster` exactly as five existing procs
already do).

Nothing here redesigns anything. There is no architectural change, no
new state, no new packet, no new invariant the rest of the file has to
learn. Every fix either enforces a rule the file already believes it
follows (C1, C2, C3) or deletes an exception to one (C5, X1).

---

## Version and release shape

Working builds bump `$VER` sequentially from the released **1.2** as
**1.2.1b1, 1.2.1b2, ...**, dropping the beta suffix at the end.

The precedent is CFile: 0.3 shipped, its post-release code audit shipped
as **0.3.1** - a point release that is exactly "the audit, applied".
This campaign is the same shape and should carry the same label.

**DECIDED: 1.2.1, a point release.** His call, taken 23.7.26 - the two
heap fixes should not wait behind a feature.

Build/deploy per the usual routine: `ecompile ccon-handler.e
ccon-handler LARGE`, copy to the FS-UAE AmigaOS3.2 `L/`, keep
`L/ccon-handler.bak` as the revert point, **reboot** (a running handler
keeps its seglist), mount, test. State explicitly after each compile
whether the binary reached `L:` or only the repo - the 1.2b15 deploy
taught that the hard way.

---

## Batch A - mechanical, one commit - C3, C4, C7, C9, C10, X1 - DONE (1.2.1b1)

**Outcome: six of the seven landed. C6 was deliberately NOT changed.**
Compiles clean (LARGE); the three pre-existing A4/A5 inline-asm warnings
are unchanged and the compiler's UNREFERENCED set is the same nine names
as the released 1.2 baseline (`vers, mics, qual, ia, c, code, len,
tcscancmd, secs`) - so no new dangling local was introduced.

**C3 came with a trap worth recording.** The obvious spelling,
`IF conok(c) AND c.appicon`, IS STILL THE BUG: **E's AND does not
short-circuit** (the file documents this itself, in the histslot note in
`dorawkey`), so that form evaluates `c.appicon` - reading the freed
console - regardless of what `conok` returned. It has to be nested `IF`s.
A "one word fix" that would have compiled, looked right, and fixed
nothing.

**C6 - not done, on purpose.** The plan was to reply
`-1`/`ERROR_NO_FREE_STORE` instead of faking success when `wq` overflows
while iconified. On a closer look that trades a near-unreachable silent
loss for a reachable behaviour change, in the wrong direction:

- The path needs **eight concurrent blocked writer tasks**, because
  parked writes are unreplied and therefore block their writer. One
  shell plus a running command is two.
- The windowless case four lines below - which the plan cited as the
  precedent - is **permanent** (no window will ever appear), so an error
  is the honest answer there. The iconified case is **temporary**: the
  window is coming back. For a temporary condition the right answer is
  to block, which is exactly what parking already does for the first
  eight.
- Turning it into a write error would make a running command fail or
  exit where it previously continued.

Left as-is, with the existing comment already saying plainly that it
accepts and discards. Raising `WQMAX` would be the real improvement if
anyone ever hits it. **This is a judgement call and it is his to
overturn** - it is recorded here rather than silently taken.

**C3 - `doappmsg()` validates the console.** `IF conok(c) AND c.appicon`.
The proc already has the pointer; `conok` is already the file's answer to
exactly this question at five other boundaries. Nothing else changes.

**C4 - `dopaste()` clamps the chunk size.** B11 rejected `sz < 0`;
extend it to reject a size that cannot fit what was actually read:
`IF (sz < 0) OR (sz > (got - i - 8)) THEN i := got`. Same guard site,
same exit, one more condition.

**C6 - `dowrite()` stops faking success on `wq` overflow.** Reply
`-1` / `ERROR_NO_FREE_STORE` (what the windowless path four lines below
already does) instead of `pkt.arg3`, so a discarded write is reported
rather than silently swallowed.

**C7 - `killhandler()` closes `diskfont.library`.** Guarded
`CloseLibrary` + NIL, placed beside the existing `keymapbase` /
`workbenchbase` closes so the teardown stays readable in one block. Safe
by construction: `fontload()` blocks on `Wait(fhsig)`, so no helper can
be mid-flight when `main()`'s loop exits.

**C9 - `snaplive()` leaves scrollback-search mode.** One assignment. The
current state (view snapped live, `sbsrch` still TRUE) makes the next
keystroke yank the view back to a match.

**C10 - `edcap()` cannot go negative.** Wrap the existing expression in
`Max(0, ...)`. This is the whole fix; the four duplicated trim loops then
terminate correctly without being touched. (Factoring them into one
`edfit()` helper is the tidier answer and is listed as X-work below - it
is a refactor, not a bug fix, and does not belong in the same commit as a
memory-safety change.)

**X1 - delete the unreachable `sbsrch` block** in `dorawkey()`. The
preceding block `RETURN TRUE`s for exactly the four codes it tests.

**What proves Batch A:** the box boots, `NewShell CCON:` opens, a paste
still pastes (C4 path), Ctrl+R-scrolled-back search still behaves (C9),
and `Unmount CCON:` / the `ccdie` test still tears down cleanly (C7).
None of these are new tests - they are the existing deck. C3's window is
too narrow to reproduce deliberately; it is an inspection fix and is
stated as such.

---

## Batch B - the two heap findings - DONE (1.2.1b1)

**Outcome: both landed, and C1's boundary was MEASURED, not reasoned.**
New harness `tests/sbmaxtest.e` (run under vamos, house pattern) carries
`visrow()`'s two lines verbatim and sweeps every `(sbtop, row)` pair.

It reproduced the bug exactly as audit3 described - `sbmax=100, rows=126`
reaches **index 124 in a plane whose legal range is 0..99**, escaping on
325 of 12600 pairs - and then it corrected me on the boundary:

- escape begins at `rows >= sbmax + 2` (confirmed),
- therefore the *index* minimum is `sbmax >= rows - 1`, **not** `rows + 1`
  as the roadmap and my first code comment both claimed.

`rows + 2` is still the right floor, but the honest reason is different
and the comment now says so: `sbmax - rows` is **also the scrollback
capacity** (`screenscroll()`'s `IF sbcnt < (sbmax - rows)`), so a ring
floored at the bare index minimum would be safe and have *zero* lines of
history in it. `rows + 2` is the smallest value that is both safe and
still a scrollback. The harness asserts all of this, including a sweep
over every window height 1..400 with and without the floor.

**C2 landed as planned plus one extra.** The four-assignment geometry
snapshot in `hidewin()` is the fix. The belt turned out to need real
state: to notice a stride disagreement you have to know the stride, and
"it equals `cols`" was precisely the assumption that failed. So the
console object gained one field, **`sbcols`** - the stride the planes
were actually allocated with - set in the two places that allocate them
(`openwin`, `reflowring`) and checked in `reopenwin`. On disagreement the
model is dropped (the existing degraded path), because losing a
transcript is a bad day and indexing past a plane is a corrupt heap.

**C1's doresize half took the cheap option, deliberately.** Growing a
window taller than its ring is capped by clamping `rows` to
`sbmax - 2` rather than growing the ring. Growing it properly would mean
passing the OLD `sbmax` into `reflowring()` - it uses the field for both
its source walk and its destination allocation - i.e. a signature change
to the one proc whose own header says to read `tests/reflowtest.e` before
touching it. With the open-time floor in place the clamp can only bite
when someone asks for a small `LINES` and then grows the window far
beyond it, and the cost is unused space at the bottom, which a window
whose height is not an exact multiple of the cell height already has.
Blank rows, not a corrupt heap. Written up here as the follow-up if it
ever actually annoys anyone.

### The plan as written follows, kept for the record.

These are the reason the campaign is not "whenever". They want their own
commit so a bisect can name them, and they want a deliberate repro.

**C1 - `sbmax` must exceed `rows`.**

`openwin()` already calls `gridcalc()` before it sizes the ring, so
`curcon.rows` is in hand and unused. Add the floor after the existing
clamps:

```
IF v < (curcon.rows + 2) THEN v := curcon.rows + 2
```

`+2`, not `+1`: the accessors' single-subtraction wrap escapes at
`rows >= sbmax + 2`, so `sbmax = rows + 1` is the last safe value and
`rows + 2` is the honest floor with a margin.

`doresize()` needs the mirror: a window grown taller than the ring hits
the same wall from the other side. The model planes are already
reallocated on a width change; a height change that pushes `rows + 2`
past `sbmax` must now do the same (or refuse the extra rows). Cheapest
correct answer: treat it exactly like the width case - if
`curcon.rows + 2 > curcon.sbmax`, raise `sbmax` and rebuild the planes
through the existing reflow path rather than inventing a second one.

Optional hardening, same commit or the one after: convert the ten
single-`IF` wrap corrections to `WHILE`, matching `rfslot()` and
`sbrowidx()` which already do it right. That does not fix C1 - the floor
does - but it downgrades any future violation from a wild write to a
wrong row.

**What proves C1:** `NewShell CCON:0/0/-1/-1/LINES100` on the tallest
screen mode available, fill it with output, scroll back. Before the fix
that is writing past the plane; after it, `sbmax` is `rows + 2` and the
`LINES100` request is quietly honoured as "the minimum that is safe".
Harness alternative (preferred, and the campaign's own habit): extend
`sbresizetest.e` with a `rows > sbmax` case - it already owns the ring
arithmetic and would show the escape as a computed index, no pixels or
boot required.

**C2 - iconify must restore the geometry it actually had.**

In `hidewin()`, before `CloseWindow`:

```
curcon.pwx := curcon.win.leftedge
curcon.pwy := curcon.win.topedge
curcon.pww := curcon.win.width
curcon.pwh := curcon.win.height
```

That is the whole fix for both halves - the window comes back where and
how it was (the visible bug), and because `reopenwin()`'s `gridcalc()`
then derives the SAME `cols` the model was built with, the stride
mismatch cannot arise.

Belt, because "cannot arise" has been wrong in this file before:
`reopenwin()` should compare `curcon.cols` after `gridcalc()` against the
stride the planes were allocated with and reflow (or drop the model, the
existing degraded path) if they disagree. A screen-mode change between
hide and restore can move the numbers even with correct pw*.

**What proves C2:** open a CCON window, drag it clearly narrower,
RightAmiga+I, click the AppIcon. Before: it returns at its ORIGINAL
width with a corrupted transcript. After: it returns exactly as it was
left, transcript intact. This one is fully visible - a screenshot pair
settles it, and per the house rule they can be pixel-diffed if the claim
is challenged.

---

## Batch C - C5, C8 - DONE, but C5 only PARTLY (1.2.1b1)

**C8 landed as planned** - the AppIcon goes back up if `reopenwin()`
fails, so a console can no longer be stranded invisible and unkillable.

**C5 - the planned fix DOES NOT WORK, and this is the correction that
matters most in this file.** The roadmap said "call `inputarrived()`
inside the loop, letting the blocked reader drain it, ~8 lines". That is
wrong, and it is wrong for a reason this project has already paid to
learn once:

`inputarrived()` replies the READ packets **already queued**. Ed reads
**one byte at a time** - its keystroke loop was disassembled during the
More hunt: `WaitForChar()` then `Read(fh, buf, 1)`. Its *next* read
arrives as a packet on our port, and we are inside `dopaste`, inside the
main loop, **not draining packets**. So one `inputarrived()` moves one
byte and the queue is full again. The "drain" is a no-op dressed as a
fix.

Actually raising the ceiling needs a raw paste **tail** that refills
`inq` from `satisfyreads()` as the client consumes it - new per-console
state plus a pump, its own commit and its own boot test. That is a
feature, not a line in a memory-safety batch, and it is not in this
campaign.

**What landed instead: the truncation is now AUDIBLE.** The raw branch
checks `inqroom(1)` per byte and `DisplayBeep`s if the clip did not fit.
That does not raise the 2 KB ceiling and the code comment says so in as
many words. It converts silent data loss into a signal the user can act
on, which is the honest half-measure - and it does not pretend to be the
other half.

**Owed:** document the raw-paste size limit in `ccon.doc` LIMITATIONS
(the doc pass, with X4/X5), and decide whether the tail pump is worth
building.

### The plan as written follows, kept for the record.

Both are "a path that gives up silently should not".

**C5 - raw paste must not truncate at 2 KB.** `dopaste()`'s exec branch
pushes the whole clip through `injectbyte` and only calls
`inputarrived()` at the end, so everything past `INQMAX-1` is dropped.
Fix: call `inputarrived()` inside the loop whenever the queue is nearly
full, letting the blocked reader drain it before continuing. The reader
is a real process and will consume - this is the same cooperative shape
`satisfyreads` already relies on.

Second-choice design if that proves awkward on hardware: route the
overflow through the existing `pasteq` tail mechanism, which cooked mode
already uses for exactly this problem. Preferring the drain because it
needs no new state.

**C8 - a failed `reopenwin()` must not strand the console.** Re-add the
AppIcon if `curcon.win` is still NIL after the attempt, so the user can
click again rather than owning an invisible, unkillable console.

**What proves Batch C:** copy a >4 KB text file to the clipboard, paste
into Ed, count the bytes that arrive. C8's failure path cannot be
triggered on demand without forcing an OpenWindow failure; it is an
inspection fix and says so.

---

## Batch D - performance - P2 DONE, **P1 DELIBERATELY NOT DONE**

**P2 landed (1.2.1b1).** `render()`'s printable-run loop now hoists the
seven geometry fields it was re-reading through the `curcon` global on
every wrap chunk (`rp`, `left`, `cw`, `topy`, `ch`, `baseline`, `cols`)
- exactly the treatment audit2-P4 gave `drawmrow`, `drawselrow` and
`drawmodelcells`, applied at last to the proc every byte of output passes
through. `cx`/`cy` and the `sb`/`sbtop` lookups are deliberately NOT
hoisted: `outwrapnl()` moves the first pair and the `screenscroll()`
inside it advances the ring.

Bonus from the same argument: `setpens()` and `setsoft()` moved OUT of
the chunk loop to once per run. Nothing inside the loop can move the SGR
state - the identical reasoning audit-P1 used for `at`/`sty` two lines
above - so setting them per chunk was re-answering a settled question,
and `setpens` does two real `SetAPen`/`SetBPen` calls each time.

**P1 is NOT done, and that is a decision, not an omission.**

It is the most user-visible improvement in the campaign and I stopped
short of it on purpose. P1 rewrites `scrollview()` to `ScrollRaster` the
retained rows instead of repainting all of them - **new rendering logic**,
in the one area of this file with the worst track record: the b8/b9/b10
`drawedit` saga took three iterations and two boot tests to settle, and
double buffering was built, shipped default-off and then deleted after
hardware showed what static reading could not.

I cannot boot-test. This project's own rule, written after 1.1 shipped
the unverified `ESC[` arrow encoding and quietly broke Ed for a release
cycle: **an "unconfirmed, pending retest" fix that ships is a landmine.**
Everything in 1.2.1b1 is either a bounds check, a guard, a deletion or a
hoist - all provable by reading and by harness. P1 is not, so it waits
for a session where the before/after can actually be seen.

When it is picked up: `ScrollRaster` the retained rows and draw only the
newly exposed ones, the shape `screenscroll`, `inslines`, `dellines`,
`scrollup` and `scrolldown` all already use; and skip `settitle()` when
the `[scrollback -n]` digits have not changed. Expect roughly an order of
magnitude on wheel scrolling.

### The plan as written follows, kept for the record.

**P2 first** (cheaper, zero risk): hoist `curcon` and the fields
`render()`'s printable-run loop re-reads per byte into locals, exactly as
audit2-P4 did for `drawmrow`, `drawselrow` and `drawmodelcells`. Same
proc shape, same reasoning, applied to the hottest proc in the file.
Provable with any large `type` of a long file, timed.

**P1 second** (the only new logic): `scrollview()` currently calls
`redraw()` - every row - to expose three. Replace with `ScrollRaster` of
the retained rows plus a draw of only the newly exposed ones, the shape
`screenscroll`, `inslines`, `dellines`, `scrollup` and `scrolldown` all
already use. Also skip `settitle()` when the `[scrollback -n]` digits
have not changed. Expect roughly an order of magnitude on wheel
scrolling.

**Not in this campaign:** P3 (history persistence blocking every window
on five packets per Enter) and P4 (reflow's doubled peak memory) are
design trade-offs with his fingerprints on them, not defects. They are
written up in audit3.md so the cost is on record; changing either is a
decision, not a fix.

---

## Not scheduled

**X2** (unify the ring-wrap idiom) folds into Batch B as optional
hardening. **X3** (comment the load-bearing `tf` reasoning), **X4** (SGR
four-parameter cap), **X5** (255-column cap undocumented) and the
`ccon.doc` LINES wording are documentation and comment work - real, but
they belong with the next doc pass, not with memory-safety commits.

**audit2 P6** (`fscall` has no timeout) stays parked, as he decided -
with one note added to audit3.md: 1.2 moved history persistence onto the
per-Enter path, so the number of `fscall` sites a normal session touches
went from "when you press Tab" to "every command". The parking decision
was sound on its inputs; the inputs changed. Worth re-deciding, not worth
overriding.

---

## Status

| | |
|---|---|
| **Done in 1.2.1** | C1, C2, C3, C4, C5 (partial), C7, C8, C9, C10, X1, P2 |
| **Hardware-verified** | C2 end to end (resize, iconify, restore: right geometry AND intact transcript), plus a clean boot and normal use |
| **Not separately re-tested** | C1's tall-window repro, C9, C5's beep, C7's unmount. C3/C8/C10 have no on-demand repro by nature |
| **Deliberately not done** | C6 (his call to overturn), P1 (needs a boot test) |
| **Owed** | the doc pass (X3, X4, X5, the raw-paste limit, LINES wording) |
| **Still parked** | audit2 P6 (`fscall` timeout), P3, P4 |

Compiles clean under `ecompile ... LARGE`. Warnings and the UNREFERENCED
set are identical to the released 1.2 baseline. Binary 83388 -> 84076
(+688 bytes, almost all of it the `reopenwin` stride guard and the
`sbmaxtest`-justified floor).

**Released as 1.2.1** (tag `ccon-1.2.1`), merged via PR #8.

---

## Boot checklist for 1.2.1b1

Deployed to `L:ccon-handler`; the released 1.2 binary is preserved as
`L:ccon-handler.1.2` and `L:ccon-handler.bak`. **Reboot** - a running
handler keeps its seglist, so copying to `L:` alone changes nothing.

Confirm the right binary is live first: `version L:ccon-handler` should
say **1.2.1**. If it says 1.2, the reboot did not take. (This is not a
theoretical check: during this campaign a `$VER` bump was made AFTER the
last compile, and the "deployed" binary was still stamped 1.2. Read the
version out of the FILE, not the source.)

**Item 6 below PASSED on hardware** - he resized, iconified and restored,
and it came back correctly with its transcript intact. That is C2
confirmed in both halves and the result the campaign turned on. The rest
of the list stands as written for anyone re-running it.

**Regression - nothing should have changed:**
1. `NewShell CCON:` opens, type, Tab-complete, Up/Down history, Ctrl+R.
2. `list SYS:` then Shift+Up/Down and Ctrl+Up/Down, mouse wheel.
3. `Ed s:startup-sequence` - menus, arrows, resize the window while Ed is
   running (B8), quit and check the transcript came back (altscreen).
4. The raw-byte decks: `type s:ccon-styles`, `s:ccon-osc`,
   `s:ccon-ichdch`, `s:ccon-progress`, `s:ccon-bisect`.
5. `More` a long file - pages should still flip instantly, not scroll.

**The fixes themselves:**
6. **C2, the one that matters.** Open a CCON window, drag it clearly
   NARROWER, `RightAmiga+I`, click the AppIcon. It must come back *at the
   size and place you left it* with the transcript intact. Before this
   build it returned at its ORIGINAL width with a corrupted transcript.
   Worth a screenshot pair.
7. **C2 again, the other direction** - resize WIDER, iconify, restore.
8. **C1.** `NewShell CCON:0/0/-1/-1/LINES100` on the tallest screen mode
   available; fill it with output and scroll back. Should behave
   normally - the ring is silently floored to `rows + 2`.
9. **C9.** Scroll back, Ctrl+R, type a fragment, then let a command
   produce output (or wait for one). The view should stay live instead of
   jumping back to the match on your next keypress.
10. **C5.** Copy a >4 KB text file to the clipboard and paste into Ed
    (`RightAmiga+V`). It will still truncate at ~2 KB - that is known and
    unfixed - but it must now **beep** when it does.
11. **C7.** `Unmount CCON:` (or run `tests/ccdie`) and re-mount. Should
    tear down and come back cleanly.

**Not reproducible on demand** (inspection fixes, stated as such): C3
needs an AppIcon double-click racing a console close; C8 needs an
OpenWindow failure; C10 needs a one-row borrowed window.

If anything regresses: `Copy L:ccon-handler.1.2 L:ccon-handler` and
reboot.
