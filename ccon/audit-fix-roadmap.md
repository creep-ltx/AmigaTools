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

## Batch 2, continued - the shipped B1 fix regressed - DONE (1.2b6, 21.7.26)

**The `1.2b3` fix above was not the end of B1.** Deployed alone it was
clean, but stacked with batch 3 in the working tree, an A/B pair on
hardware showed the fixed build leaving STALE CURSOR BLOCKS on screen -
two or three visible at once - where the build with B1's fix reverted
showed only one. The two `1.2b3` findings (the hole-in-the-row-below
fix, and this) were entangled through something not identified at the
time.

Two hypotheses were tried and disproved before the real cause was
found:

1. "The stale cursors predate the fix." No - the A/B showed one cursor
   reverted, three fixed.
2. "Clearing `edext` alongside `edlast` is what broke it, clear only
   `edlast`." No - a build doing exactly that (briefly `1.2b5`) still
   showed the stale blocks. `edanchortest.e` confirmed `edlast` alone
   still fixes B1's model corruption, so the model-side reasoning was
   right; the pixel-side reasoning was not.

**The actual cause:** `eraseedit()`'s `ancx >= cols` guard didn't just
skip the model mirror-zero loop, it `RETURN`ed out of the *entire*
proc - including the pixel repaint (`drawmodelrow` in the model
branch, `RectFill` otherwise). But `drawedit()` legitimately paints
through that same case (H4: `ancx = cols` is the pending-wrap anchor,
and its mirror loop computes `n = 0` there and rolls to the next row).
So every commit landing on that anchor left real, painted pixels with
nothing ever erasing them - the stale blocks, accumulating one per
occurrence.

**The fix ("normalise"):** instead of bailing, `eraseedit()` now
normalises the start cell to row `ancy+1`, col `0` (the same wrap
`drawedit`'s own mirror loop already computes) and runs its full body
- mirror-zero loop, model repaint, and the no-model `RectFill` -
against that cell. `ancx` is clamped to `cols` everywhere it is set,
so `ancx >= cols` only ever means `ancx = cols` exactly; the guard is
gone, not patched, because normalising also retires its original job
(an un-normalised `ancx = cols` fed to the no-model `RectFill` would
left>right invert it - the "wild writes" the old guard's comment
named).

**Proof, not argument:** temporary telemetry (`dbglog()`, hand-rolled
`fscall()`/`tcresolve()` packets to `L:ccon-dbg.log`, the same plumbing
`savehistfile()` uses, since the no-DOS rule forbids a handler calling
`Open()` on itself) logged every time the wrap path fired: raw
`ancx`/`ancy`, `edlast`, `edext`, `cols`, `rows`, and the computed
`ax0`/`ay0`/`r1`. Six boot passes across four window geometries -
`rows`/`cols` of 8/77, 5/77, 6/77, 21/77 (x2), 7/77, and 7/**27** (a
genuinely different column count, not just row count) - all showed the
wrap path firing with correct normalised coordinates every time, and
every screenshot showed exactly one cursor marker, never more. The one
screenshot with trailing `#` characters after the echoed command line
is the pre-existing fill pattern showing past the shorter typed text
(no clear-to-EOL on command echo, expected CLI behaviour), not a stale
editor pixel. Telemetry has since been stripped (mechanical removal,
no logic touched) and confirmed to still compile clean.

**Regression:** not re-run explicitly this round, but nothing in the
normalise fix touches the non-wrap path (`ax0`/`ay0` equal
`curcon.ancx`/`curcon.ancy` whenever `ancx < cols`), so the earlier
`ccon-bisect`/`ccon-progress`/`ccon-ichdch` gates are unaffected by
construction.

---

## Batch 3 - two bounded correctness fixes - DONE (1.2b7, 21.7.26)

**Findings:** B2, B4

**Outcome:** the harness overturned the plan for a third time, and this
was the worst of the three - the fix written into audit.md would have
made the bug WORSE while looking like a fix.

`sbresizetest.e` compared three options over two cases. Bad rows:
current logic 3, the audit's sbcnt clamp 4, symmetric grow 0. The
clamp only changes how far back you may scroll; it leaves the recycled
rows exactly as they were and cuts off history that was readable.

The real defect was never the count. `doresize()` handles SHRINK
symmetrically and GROW not at all, so a grown window extends downward
over recycled ring rows - visible at once, no scrolling needed. The
shipped fix mirrors the shrink loop: step `sbtop` back per row gained,
pulling history down, clearing whatever history cannot fill.

The harness also caught its OWN first draft being unfaithful: `emit()`
scrolled before writing, so a fresh screen filled bottom-up where the
real `outnl()` fills top-down and only scrolls once full. That made the
low-history case look broken in every mode. Worth remembering that a
harness is only evidence once its model matches the thing it models.

B4 shipped as reasoned-not-reproduced, as this plan allowed for -
forcing `OpenWindowTagList` to fail is more instrumentation than the
finding is worth, and the change only removes a retry.

**Hardware test, done (21.7.26).** `ccon-b2`/`ccon-b2-fill`
(`ccon/tests/`) write 60 numbered rows - deliberately more than any
window height tested holds, so the ring is guaranteed to carry more
history than one screen. A 5-row window showing rows 57-60, grown to
30 rows, showed 32-60: dead sequential, nothing repeated or reordered.
That is exactly the pulled-down history the fix predicts, not the
recycled-ring garbage the bug produced. Two screenshots, before and
after the grow, same window, same boot.

The original plan follows, kept for the record.

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

## Batch 4 - atomic reports (B3) - DONE (1.2b8, 21.7.26)

**Finding:** B3

**Outcome:** `inqroom(n)` landed as the predicate (`(INQMAX-1) -
inavail() >= n`), not a separate `enqueuestr()` - `rawcsikey()`'s
branches each know a different fixed length depending on `sh`, which
fits a per-branch guard-then-enqueue-loop better than a single
concatenate-then-call helper. All three sites now measure their body
before writing a single byte and bail whole on `inqroom() = FALSE`.

**Verify, done as an A/B pair (not just reasoned).** A throwaway
`INQMAX=64` build with the three guards stripped back out
(`1.2b8-INQ64-BROKEN`) against the same shrink with the guards kept
(`1.2b8-INQ64-FIXED`) - source diff verified to be exactly the eight
guard lines plus the version string, same discipline as the B1 pair.

Round 1 (broken): playing in Ed then dropping back to the Shell showed
leaked `ihreport()` text - expected either way, since Ed reads reports
in raw mode fast enough this is normally invisible, and leftover bytes
get echoed once a cooked reader (the Shell) picks them up - but one
report showed a field merged mid-record (`...911467|2;0;255;327682;0`,
where a stray `2` landed inside what should have been a fresh `32768`),
confirming the byte-drop truncation B3 describes.

Round 2 (fixed) used a different drive (window resize + key-mashing
rather than round 1's Ed+mouse movement) and showed only short
unstructured fragments, not `ihreport()`'s `;`-delimited format at all
- consistent with ordinary keystrokes, not report corruption, but not
a matched comparison with round 1 either. Not repeated with a matched
drive; shipping on round 1's positive repro plus the fix's own
narrowness (whole-or-nothing is straightforwardly correct on its
terms) rather than insisting on a clean round 2.

The original plan follows, kept for the record.

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

## Batch 5 - `savehistfile()` restructure (P5) - DONE (1.2b11, 22.7.26)

**Finding:** P5, plus the `fscall()` timeout note

**Outcome: append per commit, no persistent handle, trim on wrap.**
Option A's append shape, but WITHOUT the persistent handle - each
commit opens `FINDUPDATE`, seeks to end, writes its one line, closes
(four packets, no block rewrite). `histremember()` now returns whether
it actually appended so the file gates on real additions, and a
`histfilelines` counter triggers a full `savehistfile()` rewrite once
the file reaches 2x the ring cap, bounding it to `[0, 2*HISTMAX)`. The
persistent handle was rejected precisely because of the teardown
obligation named below; the dirty-flag+timer option was rejected for
reintroducing the crash-loss window todo.md:1474 moved away from.

**Verified on the on-disk file** (the advantage of L: being a host
directory): after a real session `L:ccon-history` grew by append,
newest last, in order, with zero consecutive duplicates and no
corruption, and reloaded across a reboot. The trim path is the
existing rewrite on a counter, verified by construction.

**The `fscall()` timeout note was NOT done** - left as its own small
open item (a comment at minimum; a real timeout needs a second timer
request and is separate work).

The original plan follows, kept for the record. Two candidate shapes,
in order of preference:

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

## Batch 6 - policy decisions (B5, B6) - BOTH DONE (22.7.26)

**Findings:** B5, B6

Both are behaviour changes rather than bug fixes, so they want a
decision before they want code.

**B5 - `ACTION_DIE`. DONE (1.2b13).** Refuses (`ERROR_OBJECT_IN_USE`)
while `conlist` is non-NIL; otherwise clears `dn_Task`, replies
`DOSTRUE`, ends the loop, and `killhandler()` releases the exec
resources (input.device handler FIRST, then devices/ports/library/
signals) while E's exit frees the New/String memory.

Hardware-verified with `ccdie` (tests/ccdie.e), which sends the packet
since no stock command does: the idle handler tore down with no guru,
re-opening CCON: started a NEW process (the handler port changed,
proving the old one died and DOS re-mounted fresh), keys echoed
correctly (input chain cleanly removed + reinstalled), and a second
`ccdie` with a window open was refused with `ERROR_OBJECT_IN_USE`. The
untested risks from the commit message (E re-initialises globals on
re-entry, DOS reuses the seglist, CLEANUPALL runs cleanly for this
handler) all held.

**B6 - `DISK_INFO` fallback. DONE (1.2b12).** `conbysender()` gained a
`guess` flag; `DISK_INFO` passes FALSE and fails
(`ERROR_OBJECT_NOT_FOUND`) instead of returning the list head, the
other four callers keep the guess.

The instrument-first approach below was followed exactly. A throwaway
1.2b11 build logged every list-head fallback to `L:ccon-dbg.log` with
the packet type, the console count and the sender task name. Across
More, Ed and shell probing in one and two windows, it NEVER FIRED -
the real lookups resolved every client - so the change was free, and
the single-console case the finding overlooked (head guess = correct
console) never arose either. Telemetry then stripped.

The original plan follows, kept for the record.

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

## Batch 7 - B7, width-shrink destroys ring content - DONE (1.2b10a, 21.7.26)

**Finding:** B7, found in exploratory boot testing 21.7.26, not the
original systematic audit - see audit.md.

Not a bounded correctness fix like B2-B4: `doresize()`'s width-change
path reallocates every ring row at the new column stride and copies
only `Min(old_cols, new_cols)` bytes before disposing the old buffer,
so shrinking a window narrower than a line permanently deletes
everything past the new width - not just from the display, from
memory. Growing back afterward cannot recover it. Live-reported: a
long line typed in Ed vanished on shrink and did not return on grow.

**Mechanism confirmed 21.7.26** with `ccon-b7`/`ccon-b7-fill`, which
take Ed out of the loop entirely: a 100-column ruler echoed into a
plain Shell (no client redraw on resize), shrunk and grown back.
`CCON:` stays truncated, stock `CON:` restores completely. The cause
is CCON's own ring storage, not a client-notification problem.

**`todo.md` (M8, 0.18)'s "rows stay rows, no reflow - family
behaviour" is wrong in both halves.** Stock `CON:` REFLOWS - at the
shrunk width its marker line spans three rows and a sentence re-wraps
mid-word - so it holds LOGICAL LINES and re-wraps them per resize, and
it loses nothing. CCON has no logical-line concept at all: `render()`
wraps as it writes and the ring stores finished SCREEN rows, so the
wrap position is baked in and cannot be recomputed.

**This wants a decision, same shape as B5/B6, before it wants code.**
Two honest levels, detailed in audit.md:

1. **Non-destructive storage (cheaper).** Allocate the new stride as
   `Max(old, new)` (or carry a logical width per row) so a shrink only
   affects rendering and a grow restores. Shrink clips rather than
   reflows - not CON:-identical, but the data loss is gone.
2. **True reflow (CON: parity, structural).** Store logical lines and
   re-wrap on resize. A rewrite of the ring's representation, not a
   patch to `doresize()`; touches scrollback indexing, selection
   coordinates and the `edlastrow()` math.

Doing nothing is now the weakest option - it can no longer be
justified as matching the family.

**Outcome: fixed as level 2 (true reflow), in three stages so a bisect
could name any regression.**

1. `1.2b9` - the `sw` wrap plane: one byte per ring row, set at the
   two margin-wrap sites, cleared by real newlines, dropped
   conservatively across the CSI region ops and the alt-screen
   restore. Nothing read it, so it was a no-behaviour-change commit by
   construction (`wrapf` compiling as UNREFERENCED was the check).
2. `reflowtest.e` - the algorithm proved on data under vamos before it
   went near the handler. Seven cases. It caught four things: a wrong
   EXPECTATION of mine, a harness that did not scroll (the same
   unfaithfulness sbresizetest.e hit), an `AND 15` mask on a
   non-power-of-two ring writing out of bounds underneath passing
   checks, and a real algorithm bug - a destination row not cleared on
   ring wraparound, which showed the oldest line reappearing at the
   BOTTOM of the window. Extending it to track the ANCHOR then forced
   a fifth fix: the source range was emitting blank rows below the
   cursor as empty logical lines, pushing real content into history.
3. `1.2b10` - wired into `doresize()`. Two things the harness forced
   into the real code: `eraseedit()` now runs at the top of
   `doresize()` alongside tcclose/altdrop/clearsel (all four undo an
   overlay at the OLD geometry - without it the reflow carries the
   edit line's mirrored cells as client text and drawedit then paints
   the line a second time), and the cursor and anchor are carried
   THROUGH the reflow as tracked positions rather than clamped after.

**The audit's "rewrite of the ring's representation" was wrong** -
that estimate is what made level 2 look expensive. The grid stays
exactly as it is; the only thing missing was per-row knowledge of
whether a break was a soft wrap. visrow/sarow/ssrow, selvidx, redraw,
screenscroll and drawmrow were never touched.

**Hardware proof:** `ccon-b7`, wide -> shrunk -> grown. The shrunk
state re-wraps mid-token (`..90....:..10` / `0`, `B7-EN` / `D`), which
is reflow and not preservation. Grown back, the text region is
PIXEL-IDENTICAL to the original - 0 differing pixels across 406220,
once aligned for a 1px offset from the window being regrown slightly
taller.

**One regression on the way, fixed (1.2b10a).** 1.2b10 called
`eraseedit()` at the top of `doresize()`, which PAINTS at the old
geometry into the already-resized window and wiped the sizing gadget
on every shrink (A/B: present on b9, gone on b10). `dropeditmirror()`
does the model clearing without the paint. gadget confirmed back on
hardware, and the b8 theft-pattern gates (`ccon-bisect`,
`ccon-progress`, `ccon-ichdch`) re-run clean under 1.2b10a - no
missing text, no artefacts, gadget intact.

**Separate, still open:** whether the original Ed repro is fully
explained by this. Ed owns the screen in raw mode and redraws itself
on resize, so `CON:`'s Ed-side restore may have been Ed redrawing, not
`CON:` reflowing. If Ed redraws under `CON:` but not under `CCON:`,
that is a SECOND finding about the class-12 resize report, and fixing
the ring will not address it. **This became B8 - see below.**

---

## Batch 8 (new, unscheduled) - B8, raw-mode (Ed) resize

**Finding:** B8, found boot testing after B7 (21.7.26) - see audit.md.

Resizing a raw client (Ed) clips its content and loses the tail, and
growing back leaves stale pixel fragments from the old wide layout.

**Confirmed NOT a B7 regression by A/B on hardware:** 1.2b9 (no
reflow) and 1.2b10a (reflow) behave identically in raw mode. So the
reflow's effect is invisible there and B7 is untouched by this. It is
pre-existing raw-mode behaviour, first surfaced now because this was
the session's first raw-client resize.

Two separable problems: (1) the client's own content is not re-laid-
out, which is largely the client's job on a size event and may be
unfixable from CCON; (2) the enlarge leaves stale pixels, which IS
CCON's - the `doresize()` clear + `redraw()` does not bring the
newly-exposed area up clean in the raw path. Problem 2 is the
tractable half and the place to start.

**Investigated 22.7.26 - root cause found, fix attempted and reverted.
See audit.md B8 for the full account.** In brief: `doresize()` never
ran for Ed (the window-port drain was parked whole for a raw client
with an evmask, and `doresize`'s only caller is `IDCMP_NEWSIZE` inside
it) - telemetry-confirmed, zero raw-mode `doresize` entries across an
Ed resize. Making it run (1.2b15) repainted correctly but disrupted Ed:
the size report desynced Ed's parser, and even with the report
disabled, `doresize` merely running left Ed's arrow keys broken and its
edit area stuck at the old size. Reverted to 1.2b14. A real fix needs
dedicated work on the raw-client resize protocol (Ed's own
raw-mode behaviour), not a quick patch; the cosmetic-only impact does
not justify another Ed regression. Left open, now understood.

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
3. [DONE 1.2b4] grown window pulls history down; stop AUTO retrying a failed open
4. ccon 1.2b5: CSI reports enqueue whole or not at all
5. ccon 1.2b6: history persists by append, not by rewriting the ring per command
6. (after a decision) ACTION_DIE; DISK_INFO stops guessing
```

Batches 2, 4 and 5 each want their own boot test before the next one
starts - they are the three that could plausibly regress something,
and keeping them separated is what makes a bisect cheap if one does.
