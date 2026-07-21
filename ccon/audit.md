-> audit.md - CCON codebase audit, ccon-handler 1.2b1
-> Read 20.7.26 against ccon-handler.e as of 1.2b1 (5549 lines).
-> Line numbers are as-of that revision and will drift once fixes
-> land; every finding names the PROC too, which will not.
->
-> Static read only - nothing here was boot-verified. Findings are
-> ranked by whether the trigger is REACHABLE, not by how bad the
-> consequence sounds; where a trigger needs a specific sequence to
-> fire, that sequence is spelled out so it can be tested rather
-> than argued about. See audit-fix-roadmap.md for the order to
-> work them in.

# CCON 1.2b1 audit

Scope: `ccon-handler.e`, the whole file. Cross-checked against
`todo.md` so nothing already logged there is reported as new.

## Status

| Finding | State |
|---|---|
| P1, P2, P4, H1, H2, H5 | **fixed in 1.2b2** (batch 1, boot-tested 21.7.26) |
| B1, H4 | **fixed in 1.2b6** (batch 2, harness + A/B hardware proof, corrected after a 1.2b3 regression - see B1) |
| B2, B4 | **fixed in 1.2b7** (batch 3, harness + hardware-verified 21.7.26) |
| B3 | **fixed in 1.2b8** (batch 4, one positive A/B repro, not a matched pair - 21.7.26) |
| P5 | **fixed in 1.2b11** (append not full rewrite; hardware-verified on the on-disk file 22.7.26) |
| B5 | **fixed in 1.2b13** (ACTION_DIE teardown; hardware-verified with ccdie - clean tear-down, fresh re-mount, busy-refuse - 22.7.26) |
| B6 | **fixed in 1.2b12** (DISK_INFO fails rather than guessing; telemetry proved the fallback never fires - 22.7.26) |
| B7 | **fixed in 1.2b10 / 1.2b10a** (true reflow, CON: parity - pixel-identical round trip; gadget regression fixed, gates clean 21.7.26) |
| B8 | open - new finding 21.7.26 (raw-mode/Ed resize clips + stale pixels; NOT a B7 regression, proved by A/B) |

The findings below are kept as written at audit time, including for
the ones now fixed - the reasoning is the record of WHY the change was
made, and 1.2b2's todo.md entry points back here. Line numbers are
as-of 1.2b1 and have drifted; the PROC names have not.

---

## 1. Bugs

### B1 - `eraseedit()`'s early returns skip the `edlast`/`edext` reset

**Where:** `eraseedit()`, ccon-handler.e:3445-3489.

Two guards return before the reset at the bottom of the proc:

```
IF curcon.win = NIL THEN RETURN
IF curcon.ancx >= curcon.cols THEN RETURN  -> inverted RectFill = wild writes
...
curcon.edlast := 0                         -> not reached on either path
curcon.edext := 0
```

The b9 note (todo.md:1264) states why that reset exists: *"eraseedit
now zeroes edlast/edext after erasing so the tail never re-cleans at
a moved anchor (the theft pattern must not come back through the back
door)."* The `ancx >= cols` guard is the back door.

**Trigger, reachable:** `render()`'s printable-run loop leaves
`cx = cols` whenever a write ends exactly at the right margin
(`fit := cols - cx; cx := cx + fit`) - the pending-wrap state
documented as legal at `doresize` (:1857). `reanchor()` then parks
`ancx = cols`. On the NEXT `dowrite()`:

1. `eraseedit()` returns at once; `edlast` keeps N from the old anchor
2. `render()` writes new client text
3. `reanchor()` moves the anchor
4. `drawedit()` reads `oldl := curcon.edlast` = N and, where
   `oldl > l`, zeroes `N - l` model cells from the NEW anchor

**Consequence:** client text erased from the model at a moved anchor -
the exact theft pattern b9 closed, re-entered through the guard.

**Trigger, CORRECTED (21.7.26).** This section first said "any output
whose last line is exactly `cols` wide qualifies". That was too broad,
and the harness caught it: an identical cols-wide write does NO damage
when the row the anchor lands on is blank. All four of these have to
hold at once:

1. a write ends flush on the right margin, so `reanchor` parks
   `ancx = cols`, AND
2. the edit line is non-empty when Enter is pressed (`edlast > 0`), AND
3. the line SHRINKS in the same `drawedit` that sees the moved anchor -
   in practice the Enter-commit path specifically, since a plain
   `dowrite` never touches `ebuf`, so its stale `edlast` is consumed
   against an equal `l` and nothing is zeroed, AND
4. the row the post-commit anchor lands on still holds content

So it needs content BELOW the prompt, which is not the everyday
bottom-of-screen shell case - reachable via `CSI H` positioning, a
full-screen client's restored transcript, or a prompt sitting
mid-screen.

**Status, CORRECTED (21.7.26): FIXED in 1.2b6, not 1.2b3.** The 1.2b3
fix below was real - harness (`edanchortest.e`) proved the model
corruption and pinned the precondition; an A/B pair differing ONLY in
this proc showed the gap appear and disappear in FS-UAE, damage width
always equal to the typed line's length - but it was not the end of
the story. Deployed alongside batch 3, a further A/B pair showed the
"fixed" build leaving STALE CURSOR BLOCKS on screen, two or three
visible at once, where the reverted build showed only one.

Two hypotheses were tried and disproved: that the stale cursors
predated the fix (no - the A/B showed one reverted, three fixed), and
that clearing `edext` alongside `edlast` was the cause (no - a build
clearing `edlast` only, briefly `1.2b5`, still showed the blocks).

**The actual cause:** the `ancx >= cols` guard did not just skip the
model reset, it `RETURN`ed out of the WHOLE proc - including the pixel
repaint (`drawmodelrow` / `RectFill`). But `drawedit()` legitimately
paints through that same case (H4, below: `ancx = cols` is the
pending-wrap anchor), so every commit landing there left real, painted
pixels with nothing ever erasing them.

**Fix as applied (1.2b6):** the extent-into-locals fix below stands
for the model side. For the pixel side, `eraseedit()` no longer bails
on `ancx >= cols` - since `ancx` is clamped to `cols` everywhere it is
set, that condition only ever means `ancx = cols` exactly, so the
start cell is normalised to row `ancy+1`, col `0` (the same wrap
`drawedit`'s own mirror loop already computes) and the proc runs its
full body - mirror-zero loop, model repaint, `RectFill` - against that
cell instead. Confirmed with temporary telemetry across six boot
passes and four window geometries (including a narrower column count):
the wrap path fires with correct normalised coordinates every time,
and every screenshot shows exactly one cursor, never more.

**Fix as first applied (1.2b3, the model-corruption half only):** take
the extent into locals and clear the fields ABOVE both guards. Note it
is NOT "zero the fields at the top" - the erase loop reads the count,
so zeroing first would skip the erase on the normal path (the
harness's scenario C exists to catch exactly that mistake, and did).

---

### B2 - `sbcnt` is not re-clamped when the window grows

**Where:** `doresize()`, ccon-handler.e:1825 (immediately after
`gridcalc()`).

The ring invariant is `sbcnt <= sbmax - rows`. `screenscroll()`
(:1829) enforces it on the way up. Nothing re-establishes it when
`gridcalc()` INCREASES `rows` underneath an already-large `sbcnt`.

**Trigger:** fill the scrollback, then enlarge the window.

**Consequence, CORRECTED (21.7.26).** The diagnosis above is right that
the invariant breaks, but it named the wrong symptom AND proposed a fix
that measurably makes things worse. Both were caught by the harness
(`sbresizetest.e`), and the correction matters more than the original
finding did.

The real defect is not the count: it is that `doresize()` handles
SHRINK symmetrically - advancing `sbtop`, pushing the rows above the
cursor into history - and handles GROW **not at all**. So the visible
window simply extends DOWNWARD over ring rows that have already been
recycled. Enlarging a window with a full scrollback shows ancient lines,
out of order, in the newly exposed rows. That is visible immediately at
`viewoff = 0`, without scrolling anywhere.

**The clamp this section originally proposed is NOT a fix.** Measured
over the harness's two cases, bad rows: current logic 3, clamp 4,
symmetric grow 0. The clamp only changes how far back you may scroll,
leaves the recycled rows untouched, and cuts off history that WAS
readable - worse than doing nothing.

**Fix as applied (1.2b7):** the mirror of the shrink loop. For each row
gained, step `sbtop` back one and drop `sbcnt` by one, pulling history
down into the new space, with `cy`/`ancy` following it; rows history
cannot fill are genuinely new and get cleared so they show blank rather
than recycled text. This keeps `sbcnt <= sbmax - rows` for free, which
is what the clamp was reaching for by the wrong route.

**Status: FIXED in 1.2b7.** Harness-verified, and hardware-confirmed
21.7.26: `ccon-b2`/`ccon-b2-fill` (`ccon/tests/`) write 60 numbered
rows, deliberately more than any tested window height. A 5-row window
showing rows 57-60 grown to 30 rows showed 32-60 - dead sequential,
nothing repeated or reordered, exactly the pulled-down history the fix
predicts.

---

### B3 - a full input queue truncates CSI reports mid-sequence

**Where:** `enqueue()` :5507; callers `ihreport()` :4758,
`sendreport()` :3211, `rawcsikey()` :4335.

`enqueue()` drops silently PER BYTE. Every report path emits a
multi-byte sequence one `enqueue()` at a time, so a full queue
delivers a PARTIAL CSI.

**Consequence:** worse than dropping the event. A truncated report
desyncs the client's CSI parser permanently; a dropped one costs a
single event. This is the failure mode that reads as "Ed went mad"
rather than "Ed missed a key".

**Trigger:** a client holding a fat `evmask` (e.g. `CSI 2{` mouse
reports) that stops reading. `ihreport` is ~50 bytes/event against
`INQMAX` 2048 - roughly 40 events fills it.

**Fix as applied (1.2b8):** `inqroom(n)` predicate
(`(INQMAX-1) - inavail() >= n`), asked once per report before any byte
of it is written. `rawcsikey()`'s branches each know their own fixed
length once `sh` is resolved, so each got its own guard rather than a
shared `enqueuestr()` buffer-and-length call.

**Status: FIXED in 1.2b8.** A/B pair with `INQMAX` shrunk to 64 and
the three guards stripped back out on the broken side (source diff
verified to be exactly those changes). The broken build showed a
report with a field merged mid-record
(`...911467|2;0;255;327682;0` - a stray digit landed inside what
should have been a fresh value), confirming the byte-drop truncation
this finding describes. The fixed build's comparison round used a
different drive and wasn't a matched A/B, so this rests on the one
positive repro plus the fix's own narrowness, not a clean before/after
pair like B1/B2 got.

---

### B4 - a failed AUTO `openwin()` retries forever and accretes into the title

**Where:** `openwin()` :1534 (`IF curcon.win = NIL THEN RETURN`) vs
:1706 (`curcon.autopend := FALSE`).

`autopend` is cleared PAST the failure return, so `ensurewin()` (:1387)
retries `openwin()` on every subsequent packet for that console.

**Consequence:** repeated `LockPubScreen`/`OpenWindowTagList` per
write/read/wait; and in the `ihon = FALSE` fallback,
`StrAdd(curcon.wtitlebase, ' [no chain]')` (:1483) runs each time -
the title fills with `[no chain] [no chain] [no chain]...` up to
`wtitlebase`'s 84-char cap.

**Fix as applied (1.2b7):** clear `autopend` on `openwin()`'s failure
return, so one attempt is all a console gets. Reasoned, not
reproduced - forcing `OpenWindowTagList` to fail on demand is more
instrumentation than the finding is worth, and the change only removes
a retry.

---

### B5 - no `ACTION_DIE`

**Where:** `dopkt()` `DEFAULT` arm, :989.

Unmount/shutdown answers `ERROR_ACTION_NOT_KNOWN`. `main()` is
`WHILE TRUE` with no exit, so `ihring`, `ihis`, `fhstub`, the
input-chain hookup and the opened devices are never released.

**Consequence:** not a leak in a live system (the process is
immortal by design), but a mount/unmount cycle during development
leaves the previous chain handler installed. That is a
development-time hazard on the machine doing the boot tests.

**Fix as applied (1.2b13):** a `CASE ACTION_DIE` that refuses
(`DOSFALSE`, `ERROR_OBJECT_IN_USE`) while `conlist` is non-NIL;
otherwise clears the DeviceNode's `dn_Task` (so DOS re-mounts a fresh
handler on the next open), replies `DOSTRUE`, and sets `dieing` to end
`main()`'s loop - now `WHILE dieing = FALSE`. `killhandler()` then
releases only the EXEC resources E's exit does not track:
`IND_REMHANDLER` first (before E frees `ihis`/`ihring` under a live
interrupt), close the three devices, delete the IO requests and message
ports, close keymap, free both signals. The `New()`/`String()` memory
rides E's list and is freed by `CLEANUPALL`/`FREEBUFFERS` when `main()`
returns - freeing it here too would double-free.

**Status: FIXED in 1.2b13, hardware-verified 22.7.26.** Tested with
`ccdie` (tests/ccdie.e), which sends `ACTION_DIE` since no stock
command does. An idle CCON: handler (port `$400F9B94`) with its input
handler installed replied `DOSTRUE` and tore down with NO guru;
re-opening CCON: started a genuinely NEW process (port `$400F9C24` -
the changed port proves the old one actually died and DOS re-mounted
fresh), which rendered `list` and echoed keys correctly (the input
chain was cleanly removed and reinstalled). A second `ccdie` with a
window open was refused with `res2 = 202` (`ERROR_OBJECT_IN_USE`),
verifying the busy guard. This also confirmed the reasoning that E
re-initializes globals on re-entry and DOS reuses the seglist - the
one part that could not be checked from Linux.

---

### B6 - `conbysender`'s list-head fallback is wrong for `ACTION_DISK_INFO`

**Where:** `conbysender()` :665, `ENDPROC conlist` at :696;
`ACTION_DISK_INFO` arm :955.

When the CLI-StandardInput, breaktask and active-window lookups all
miss, the caller gets SOMEONE ELSE'S console.

For `WAIT_CHAR`/`SCREEN_MODE` that is a harmless wrong answer. For
`DISK_INFO` it hands out `id.volumenode := curcon.win` - a window
pointer for a console the caller has no relationship with, which a
client like More will then `SetWindowTitles` and draw into.

**Fix as applied (1.2b12):** `conbysender()` gained a `guess` flag.
`DISK_INFO` passes `FALSE` and gets `NIL` -> `ERROR_OBJECT_NOT_FOUND`
instead of the list head; the other four callers
(`WAIT_CHAR`/`SCREEN_MODE`/`CHANGE_SIGNAL` and the `*`/`CONSOLE:` open,
where attaching to the active console is the intended behaviour) pass
`TRUE` and keep the guess.

**De-risked with telemetry before the change, per the roadmap.** A
throwaway 1.2b11 build logged every fallback to `L:ccon-dbg.log` with
the packet type, the live console count, and the sender task name.
Across More, Ed and shell probing in ONE and TWO windows, the
list-head fallback NEVER fired - not one line - so the real lookups
resolve every client that actually sends these packets. The audit's
worry ("the fallback exists because some client did not resolve any
other way") did not materialise for the tested clients, and the
single-console case the finding did not consider (where the head guess
IS the right console) never arose either. So failing `DISK_INFO` costs
nothing observed and is strictly safer if an untested client ever
reaches it.

**Status: FIXED in 1.2b12, telemetry-de-risked 22.7.26.** A confirming
boot round (More retitles its window, Ed's menu strip works, both in
two windows) is the only thing outstanding, and the telemetry already
showed those paths never touch the changed fallback.

---

### B7 - width-shrink permanently deletes ring content beyond the new column count

**Where:** `doresize()`, ccon-handler.e:1851-1881 (the `curcon.cols <>
oc` reallocation block).

**Found:** exploratory boot testing, not the original systematic audit
(21.7.26).

Every row of the scrollback ring is reallocated at the new column
stride whenever the window's WIDTH changes. Only `Min(oc, curcon.cols)`
bytes per row are copied from the old buffer into the new one; the old
buffer is then `Dispose()`d in full, in the same breath.

**Trigger:** type or receive a line wider than the CURRENT window, then
shrink the window narrower than that line.

**Consequence:** every character past the new column count is not
clipped from the display, it is destroyed - the byte is never copied,
and the buffer holding it is freed immediately after. This runs over
EVERY row in the ring, not only the visible ones, so scrollback history
wider than the new width is truncated too. Growing the window back
afterward cannot recover any of it, because nothing is left to
recover. Reported live: a long line typed in Ed vanished past the
border on shrink and did not return on grow.

`todo.md` (M8, 0.18) documents "no reflow (family behaviour)" as the
intended trade-off, matching stock `CON:`'s clip-not-rewrap resize
behaviour.

**That defence is FALSIFIED (21.7.26), by direct A/B on hardware.**
The same long line typed into Ed, the same shrink, the same grow, run
once under stock `CON:` and once under `CCON:`:

- **stock `CON:`** - shrink clips the line to the new width; growing
  back **restores the full text**.
- **`CCON:`** - shrink clips; growing back shows the text still
  truncated, byte-identical to the shrunk state
  (`This is a test of CCON's ability to` / `multiple lines and have
  the window r`). The characters are gone, not merely unrendered.

So stock `CON:` clips the VIEW and keeps the DATA. "Family behaviour"
describes the visual result and not the storage behaviour, and it is
the storage behaviour that differs. Whether CCON's destructive version
was a deliberate call or an unexamined side effect of the fixed-stride
ring is still not established, but it is no longer defensible as
matching the family.

**MECHANISM CONFIRMED (21.7.26), Ed taken out of the loop.**
`ccon-b7`/`ccon-b7-fill` (`ccon/tests/`) echo a 100-column ruler and
marker into a plain Shell, which does NOT redraw on resize - so
whatever survives a shrink/grow came from the console's own buffer,
not from a client re-sending it. Run under both consoles:

- **`CCON:`** - shrunk to ~40 columns and grown back, the ruler still
  stops at `30....:..` and the marker at `B7-START------------------`.
  Destroyed. The rows that DID survive are the ones already shorter
  than the shrunk width (`.80....:...90....:..100`, and the wrapped
  `-----------B7-END` tail) - exactly the per-row truncation signature
  this finding predicts.
- **stock `CON:`** - shrunk and grown back **fully restored**,
  identical to the original.

So the cause is CCON's own ring storage, as written here. Not a
client-notification problem.

**And stock `CON:` does MORE than keep the data - it REFLOWS.** At the
shrunk width its marker line spans THREE rows, and
`-> B7-END and ..100 come back on grow` re-wraps mid-word into
`B7-END an` / `d ..100 come back on grow`. That is a console holding
LOGICAL LINES and re-wrapping them to the current width, then
re-wrapping again on grow. `todo.md` M8's "rows stay rows, no reflow -
family behaviour" is therefore wrong in both halves: the family
reflows, and it does not lose data.

CCON has no logical-line concept at all - `render()` wraps as it
writes and the ring stores finished SCREEN rows, so the wrap position
is baked in at write time and cannot be recomputed later.

**Fix:** still a decision, now an informed one. Two honest levels:

- **Non-destructive storage (cheaper).** Keep ring rows at their
  original width - allocate the new stride as `Max(old, new)`, or keep
  a separate logical-width per row - so a shrink only affects what is
  RENDERED and a later grow restores. Result: shrink clips (no
  reflow), grow restores everything. Not CON:-identical, but the data
  loss is gone, which is the part that bites.
- **True reflow (CON: parity, structural).** Store logical lines and
  re-wrap on every resize. This is a real rewrite of the ring's
  representation, not a patch to `doresize()`, and it interacts with
  scrollback indexing, selection coordinates and `edlastrow()` math
  throughout.

Doing nothing is now the weakest option: it is no longer defensible as
"what the family does", because the family demonstrably does better.

**Still open, SEPARATELY:** the original Ed repro is not fully
explained by this. Ed is a raw-mode client that owns the screen and
re-draws itself on resize, so under `CON:` its restore may have been
Ed redrawing rather than `CON:` reflowing (reflow is a cooked-mode
behaviour). If Ed redraws under `CON:` but not under `CCON:`, there is
a SECOND finding about the class-12 resize report `todo.md` M8 says Ed
asks for - worth a separate check, and not covered by fixing the ring.

**Status: FIXED in 1.2b10, gadget regression fixed in 1.2b10a** (level
2, true reflow - CON: parity), staged 1.2b9 (the wrap plane) ->
reflowtest.e (the algorithm on data) -> 1.2b10 (wired into doresize)
-> 1.2b10a (the paint-in-doresize gadget fix).

**Hardware proof, 21.7.26.** `ccon-b7` under CCON, wide -> shrunk ->
grown back. At the shrunk width the ruler re-wraps to `..90....:..10`
/ `0` and the marker to `B7-EN` / `D` - splitting mid-token across
rows, which is REFLOW, not preservation, and is what stock `CON:` was
seen doing in its own run. Grown back, the text region of the before
and after screenshots is PIXEL-IDENTICAL: 0 differing pixels across
406220, once aligned for a 1px vertical offset (the window was regrown
to 720px against the original 699). Not "looks right" - bit-for-bit.

**A gadget regression, found and fixed (1.2b10a).** The 1.2b10 reflow
put `eraseedit()` at the top of `doresize()` for its model side effect
(clearing the edit line's mirrored cells so they do not reflow as
client text). But `eraseedit` also PAINTS, and by then Intuition has
resized the window while `curcon.rows/cols/topy` are still the old
geometry - so its `drawmodelrow`/`RectFill` ran at old coordinates
into the new smaller window, over the border where the sizing gadget
lives, and it was never redrawn. A/B on hardware: gadget present on
b9, gone on b10. Fixed with `dropeditmirror()` - the model clearing
with none of the painting, which was pure waste anyway since
`doresize` clears and redraws right after.

**Regression gates re-run under 1.2b10a and clean:** `ccon-bisect`
(five cases), `ccon-progress`, `ccon-ichdch` - the b8 theft-pattern
tests, the direct gate on the `eraseedit`/`drawedit` paths stage 3
disturbed. All match their printed expectations, no missing text or
artefacts, gadget intact.

**How it was done without rewriting the ring.** The audit first
called this "a rewrite of the ring's representation". That was wrong,
and cheaper was available: the grid stays exactly as it is, and the
ONLY thing added is a per-ring-row flag saying whether a row is a
soft-wrap continuation (`sw`, one byte per row against three existing
planes of sbmax*cols). With that, `reflowring()` can rejoin logical
lines and re-wrap them at any width. visrow/sarow/ssrow, selvidx,
redraw, screenscroll and drawmrow were all left untouched.

---

### B8 - resizing a raw-mode client (Ed) clips its content and leaves stale pixels

**Where:** `doresize()`, the raw path - `curcon.rawmode = TRUE`, no
alternate screen (Ed does not use `?47h`, unlike More).

**Found:** boot testing after B7, 21.7.26. NOT the original audit, and
NOT a B7 regression - see below.

**Trigger:** open Ed (or any raw client that owns the screen and does
not re-render on a size event), type a line that wraps, resize the
window.

**Symptoms, two distinct ones:**

1. The client's content is CLIPPED to the new width and the tail is
   lost - the wrapped continuation does not re-wrap and does not come
   back on grow.
2. Growing the window back leaves STALE PIXEL FRAGMENTS from the old
   wide layout scattered in the newly-revealed area (`w`, `d`, `l r`,
   `u` in the repro), which a later click only partly clears.

**This is NOT B7, and NOT a B7 regression - proved by A/B on
hardware.** The same Ed session, the same resize, run under 1.2b9 (no
reflow at all) and 1.2b10a (the shipped reflow), behaves IDENTICALLY:
same clipping on shrink, same stale fragments on grow, tail
unrecoverable in both. So the reflow neither causes nor cures this -
in raw mode its rewrap never becomes visible (the shrunk view clips
rather than re-wrapping, in both builds). B7's cooked-mode fix stands.

**Why the two problems are separate:**

- Problem 1 is largely the CLIENT's: a raw client positions its own
  screen and only re-lays-it-out if it handles `IECLASS_SIZEWINDOW`.
  This Ed apparently does not, so nothing re-wraps its text. CCON
  cannot re-wrap it either, because in raw mode the ring holds a
  screen the client drew, not a transcript of logical lines - the
  reflow's premise (soft-wrap flags marking continuations) does not
  hold for content the client positioned itself. Whether CCON should
  even reflow in raw mode is an open question; the evidence says its
  effect is currently invisible there anyway.
- Problem 2 IS CCON's: after a resize the newly-exposed area should
  come up clean and it does not fully. The `doresize()` clear +
  `redraw()` is leaving remnants in the raw path. This is the
  tractable half and the place to start.

**Fix: not designed.** Needs its own investigation - first, whether
this Ed asks for size events at all (does `evmask` carry the
`IECLASS_SIZEWINDOW` bit when it is active?), and second, why the
enlarge clear leaves fragments. Do it with telemetry, not by reading:
this is a pixel problem and the reflow harness models data, not glass.

**Status: open - new finding, own investigation, not started.**

---

## 2. Performance

All of these sit in per-keystroke or per-byte paths, which is where
7MHz is actually felt.

### P1 - `curattr()` called once per cell in the main text path

**Where:** `render()` :3388.

```
FOR j2 := 0 TO fit - 1
  m[j2] := curattr()
ENDFOR
```

`curattr()` calls `fgpen()`, which does up to five `curcon.`
indirections and branches. That is a nested call per character on the
hottest output loop in the program - an 80-column line pays 80 of
them. Nothing in the loop can change the SGR state.

**Fix:** hoist - `at := curattr()` before the loop.

### P2 - `Mod`/`Div` on a power-of-two constant

**Where:** `enqueue()` :5509, `inavail()` :5516, `satisfyreads()`
:5539.

`INQMAX` is 2048. Each `Mod(..., INQMAX)` is a DIVS, and `inavail()`
is a loop condition. The right idiom is already in the file for the
input ring (`ihring + Shl(n AND (IHMAX - 1), 5)`) - it just never
reached the byte queue.

**Fix:** `AND (INQMAX - 1)`.

### P3 - history lookups do a DIVS per entry, per keystroke

**Where:** `sgfind()` :4030, `srfind()` :3761, `histmatches()` :4084,
`histload()` :4093 - all `Mod(ghtotal - 1 - idx, HISTMAX)`.

`HISTMAX` is 200, not a power of two, so it is a real division.
`sgfind()` runs from `drawedit()` on EVERY keystroke and walks all 200
entries: worst case ~200 DIVS (~140 cycles each on 68000, ~4ms) plus
200 `StrLen`s of up to 400 bytes, per keypress.

**Fix, two independent halves:**

- replace the `Mod` with a decrementing index and a manual wrap
  (`i--; IF i < 0 THEN i := HISTMAX - 1`)
- give `sgfind()` an early `RETURN` after it sets `sghost`. It
  currently guards with `IF curcon.sghost = NIL` INSIDE the FOR and
  still iterates to 200 after a hit. `srfind()` has the same shape
  (`IF got = FALSE` inside the loop).

Note: the `Mod`-on-negative class already bit this codebase once -
todo.md:63, `hist[Mod(-1,32)]` on empty history. Current call sites
are bounded (`avail := Min(ghtotal, HISTMAX)`), so this is a speed
fix, not a correctness one - but the manual-wrap form removes the
class entirely.

### P4 - `curcon.` indirection in the paint loops

Every `curcon.cols` is a load of `curcon` followed by a load of the
field; E will not hoist it. In `drawmrow()`, `drawselrow()`,
`drawmodelcells()` and `render()`'s inner loops that is several
redundant loads per iteration.

**Fix:** cache `c := curcon` as a `PTR TO console` local at the top of
the paint procs and use `c.cols`. Shortens the lines as a side effect.

Same family, smaller:

- `drawselrow()` :2135-2137 calls `selvidx(r)` three times for one `r`
- `drawmrow()` :1992-1994 computes `Mul(idx, curcon.cols)` three times
- `inslines`/`dellines`/`scrollup`/`scrolldown` do 6 `Mul`s per row via
  the `visrow`/`sarow`/`ssrow` trio

### P5 - `savehistfile()` on every Enter

**Where:** `dovanilla()` commit path :4210; `savehistfile()` :5060.

Each call is `tcresolve('L:')` (a `LockDosList` + a `LOCATE_OBJECT`
round trip) -> `FREE_LOCK` -> `FINDOUTPUT` -> up to 200 lines rewritten
in 2KB `WRITE`s -> `END`. Roughly 6+ synchronous packet round trips and
up to ~16KB of file I/O, and the handler task is blocked in
`WaitPort(fsport)` for all of it - so EVERY CCON: window this process
serves stalls, not just the one that pressed Enter.

The reasoning for moving off last-window-close (todo.md:1474) is
right; the implementation is a full-ring rewrite where an append would
do.

**Fix as applied (1.2b11): append, no persistent handle.** Each commit
now `FINDUPDATE` (open without truncating) -> `SEEK` to end -> `WRITE`
the one new line -> `END`. Four packets regardless of history length,
and no truncate-and-rewrite-every-block. `histremember()` returns
whether it actually appended (not a dedup'd repeat) so the file tracks
the ring, and `histfilelines` counts the file so the append path trims
with a full `savehistfile()` once the file reaches 2x the ring cap -
bounding it to `[0, 2*HISTMAX)` lines and paying the rewrite only once
every HISTMAX commits. The first write on a fresh system goes through
`FINDOUTPUT` (reliable create) rather than trusting `FINDUPDATE`'s
create-on-missing.

The persistent-handle option (keep the file open across commits) was
rejected: it is shared state to release on every teardown path
(`conclose`, and `ACTION_DIE` once B5 exists), and the per-commit open
is cheap next to the block rewrite it saves. The dirty-flag + timer
option was rejected too - it reintroduces the crash-loss window that
todo.md:1474 deliberately moved away from.

**Status: FIXED in 1.2b11, hardware-verified 22.7.26.** The on-disk
`L:ccon-history` was inspected directly after a real session: it grew
by append with new commands at the end in order, zero consecutive
duplicate lines (dedup gate held across a whole session), no
corruption, and reloaded cleanly across a reboot. The trim-at-2x path
is the existing `savehistfile()` on a counter, verified by
construction.

**Still worth a comment at minimum (NOT done here):** `fscall()` has no
timeout on `WaitPort(fsport)`. A wedged or spinning-up filesystem
freezes every console this process serves - including the one that
would display the error. This is on the Tab path too, not just Enter.
Left open as its own small item.

---

## 3. Consistency and hardening

Not bugs. Each is a place where the invariant is held by argument
rather than by code.

### H1 - `port` is shadowed in the two procs where it deadlocks

`loadhistfile()` :5011 and `savehistfile()` :5061 both declare a local
`port:PTR TO mp` over the global packet port.

Correct today - `fscall()`'s `IF tport = port THEN RETURN 0`
self-deadlock guard resolves `port` in its own scope. But any future
edit inside those two procs that means "our packet port" silently gets
the filesystem's port, in the two procs where that mistake hangs the
machine.

**Fix:** rename the local to `fsp`.

### H2 - `wcq` depth is a bare literal

`RDMAX`, `WQMAX`, `INQMAX`, `TCMAX`, `IHMAX` are all named. The
WAIT_CHAR queue is `wcq[8]` (:208) with `curcon.wcn >= 8` hardcoded at
:906.

**Fix:** `WCMAX=8` alongside the others.

### H3 - `condispose` has no safety net for the model planes

`condispose()` :700 frees the ten E-strings but not `sb`/`sa`/`ss`/
`altm`/`alta`/`alts`/`tf`.

Currently sound: `closewin()` is only ever called from `conclose()`,
and its `win = NIL` early-return case provably cannot have allocated
planes (`openwin()` returns before the ring allocation on failure).
But that is an invariant held by argument, and `condispose` is exactly
where a future path would break it.

**Fix:** NIL-checked `Dispose` calls for all seven. Costs nothing and
makes the proc self-evidently complete.

### H4 - `drawedit` lacks the `ancx >= cols` guard `eraseedit` has

`eraseedit()` guards it (:3449); `drawedit()` (:3545) does not.

It happens to work out - the first mirror iteration computes `n = 0`
and rolls to the next row consistently with the blip math at :3634-3646
- but two procs that must agree on the same anchor disagreeing on its
legal range is the kind of thing that bites on the next edit.

**Resolved 1.2b3: COMMENT, and the guard would have been WRONG.** The
audit offered "add the guard, or a comment"; that was a false choice.
`ancx = cols` is the legal pending-wrap anchor and the editor still has
to paint there - a guard would have made the typed line invisible until
the next write moved the anchor. Confirmed on hardware: at the
margin-parked prompt in the B1 repro, typing renders normally on the
row below. The comment now in `drawedit` says why the asymmetry with
`eraseedit` is correct (eraseedit's guard is about an inverted
RectFill, a pixel concern `drawedit` does not have).

### H5 - `ihdrop` is write-only

Incremented at :4639, never read.

**Fix:** surface it (title bar under a debug flag, or on the
`CSI n{` report path) or state in the comment that it is a
post-mortem field read only under a debugger.

---

## 4. What is right

Worth recording, because several of these are things that are
normally got wrong and they are the reason the rest of the file is
auditable at all.

**The no-DOS rule and its two escape hatches.** Recognising that
`DoPkt` waits on `pr_MsgPort` - the same port clients send to - and
then building two DIFFERENT legitimate escapes: a throwaway helper
process with its own `pr_MsgPort` for `OpenDiskFont` (:1419), and
hand-rolled exec-level packets on a private reply port for the
filesystem (:4786). Most handlers deadlock here and never learn why.

**Pointer validation as a discipline.** `conok()` (:608) checking
every console pointer arriving from `fh_Arg1` or a ring slot before
trusting it - and the comment noting that a LATER console could reuse
the same heap address, so scrubbing the ring (:732) is not redundant
with the list check. Right paranoia, right place.

**The chain/list concurrency design is correct for stated reasons.**
Single-writer `ihhead`/`ihtail` (lock-free, sound on 68k for aligned
longs); `Forbid`-bracketed list mutation with the note that
input.device is a TASK so `Forbid` genuinely holds it off; `armed` set
last in `openwin` and cleared first in `closewin` so a half-built
window takes nothing. Three independent layers, each justified rather
than assumed.

**Every parked packet is replied before the memory goes away.**
`closewin()` (:1723) covers this on both the windowed and windowless
paths; the `wcq`/`rdq` drains and `flushwq()` are unconditional.
Unreplied packets are the single most common way a handler hangs a
machine, and it is covered.

**Degraded modes instead of refusals.** Failed chain hookup -> IDCMP
fallback. Failed ring allocation -> console runs without scrollback.
Failed helper -> `OpenFont`. Failed resize realloc -> drop the model
rather than render through a wrong stride. Failed `ObtainBestPen` ->
-1 and no ghost. The right posture for a 2MB target.

**Reading the real binaries instead of guessing.** The `'CCON'` vs
`'CON\0'` DISK_INFO finding (:970) - disassembling ROM shell 47.47 at
`$669A` to discover that answering `'CON\0'` makes the shell keep its
OWN line editor - would have been unfindable by experiment. Same for
Ed's report dispatcher at `$1708` and the `$9B` vs `ESC[` split
between `ihreport` and `rawcsikey`.

**The commentary.** It records why, records what was verified against
what was assumed, and records abandoned designs and the reason they
were abandoned (b28's pilcrow markers; the parked `tcscancmd` at
:3163). That is what made this audit possible - intent could be
checked against implementation instead of reverse-engineered from it.
