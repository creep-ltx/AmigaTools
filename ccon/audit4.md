# CCON v1.2.5b1 — the perf-campaign audit (audit4)

Full read of the ~1080 lines `ccon-handler.e` gained since audit3's baseline
(`ccon-1.2.1`), in the context of the whole file (7960 lines, $VER
`ccon-handler 1.2.5b1 (24.7.26)`, HEAD @ 511ec49). That surface is the
entire speed program: S1 blip-only eraseedit and the S2+S3 deferred-blit
engine and S5 accept-then-render (1.2.2), plane-masked rendering (1.2.3),
E1–E5 (1.2.4), and the 1.2.5b1 overlay pens. Read-only: nothing in this
pass has been changed.

*Status 24.7.26: D1–D3 fixed and deployed as 1.2.5b2 (boot checklist in
todo.md); P1–P3 and X1–X3 remain notes.*

Numbering is a fresh series (D1..) so it cannot be confused with audit.md's
B/P/H or audit3's C-series.

---

## Verdict

The campaign held the file's standards, and in one respect exceeded them:
the **choke-point discipline is complete**. I went looking for a packet or
event path that observes the model or the glass without `flushout()` first
and found none — READ, WAIT_CHAR, SCREEN_MODE, END, close, both key procs,
mouse/selection, paste, resize, iconify, the close gadget, `conclose`. The
selection interplay is airtight end to end: pre-flush at drag start, park
while held, and `flushwq()` on *every* path that kills a drag, including
resize and window death. That is the hard part of an accept-then-render
console, and it is done.

What's left is the same shape audit3 found: **omissions at the seams the
new code opened**. The new accept path trusts a packet field the old path
never had to (D1) — and the sweep sibling ten lines below it carries the
exact guard, so the rule was known. E5's soundness argument is argued
precisely and correctly for every in-render scroll, and then the flag is
read by three scroll sites *outside* that argument's reach (D2). And the
engine's dirty arrays skipped the E-globals-are-garbage house rule that
this very file states twice and handles in the same init loop (D3).

| Severity | Count | Items |
|---|---|---|
| Crash / wild write (regression) | 1 | D1 |
| Visible corruption (self-healing) | 1 | D2 |
| Cosmetic transient (uninit state) | 1 | D3 |
| Performance | 3 | P1..P3 |
| Consistency / maintenance | 3 | X1..X3 |

---

## Correctness

### D1 — `dowrite()` accepts a negative-length write into `CopyMem`

**Where:** `dowrite()` 1526, 1555–1563; contrast `swaccept()` 1665.

```e
len := pkt.arg3
...
IF (curcon.wob = NIL) OR (len > WOBSZ)      -> negative len: not taken
...
IF (curcon.wolen + len) > WOBSZ THEN ...    -> negative len: not taken
CopyMem(pkt.arg2, curcon.wob + curcon.wolen, len)
```

A negative `arg3` sails past both guards and reaches `CopyMem`, whose size
parameter is unsigned — a ~4 GB copy through the write-behind buffer and
everything after it. Machine gone.

This is a **regression**: 1.2.1's `dowrite` handed `len` straight to
`render()`, whose `WHILE i < len` made a negative length a harmless no-op
reply. The accept path changed the failure mode from "nothing happens" to
"the heap is destroyed". And the guard was *known* — `swaccept()` at 1665
checks `(pkt.arg3 >= 0)` before doing the identical `CopyMem`. Same
one-word-asymmetry class as audit3's C3 (`conok` on five paths out of six).

**Reachable:** any buggy or hostile client issuing ACTION_WRITE with a
negative arg3 — a miscomputed length in one E or C program is enough. Not
reachable from correct DOS calls, which is why it survived soak.

**Fix:** one line after `len := pkt.arg3`:
`IF len < 0 THEN (ReplyPkt(pkt, -1, ERROR_BAD_NUMBER); RETURN)` — or clamp
to 0 and reply 0, matching whichever answer stock CON: gives. Parity with
`swaccept` either way.

---

### D2 — E5's `vblank` flag does not see editor paint: three out-of-render scrolls can skip a blit that had pixels to move

**Where:** readers: `edroom()` 5468 (called from `drawedit()` 5769), the
dotab menu-room loop 7891–7894, `pastehintroom()` 4151. Writers that miss:
`drawedit()` 5779–5795 (paints and mirrors, never touches `vblank`).
Safe by construction: every in-render scroll (4420, 4594), and the Ctrl+L
site 6540 (runs after `eraseedit()`).

The E5 soundness argument — "at scroll time both modes have ALREADY erased
the cursor/blip, so visible-model-blank equals visible-pixels-blank" — is
exactly right for the scrolls inside the `dorender()` bracket, which is
where the flag pays. But `screenscroll()` kept three callers *outside* any
bracket, and at those moments the argument's premise is false:
`drawedit()` deliberately paints **in place with no pre-erase** (the b9
flicker fix, 5760–5765) and mirrors its cells into the model without
clearing `vblank`. So:

1. Client writes FF, positions the cursor low (`CSI 20;1H`), and reads —
   a prompt-less full-screen dialogue. `vblank` is TRUE, honestly: the
   transcript is blank.
2. User types; `drawedit()` paints the line and mirrors it. `vblank`
   stays TRUE — now a lie in both pixels and model.
3. The line wraps past the last row (or Tab opens the completion menu, or
   a queued paste wants its hint row): `edroom()`/the menu loop/`
   pastehintroom()` call `screenscroll()` to make room — and the blit is
   **skipped**. The ring, `ancy` and `cy` all advance; the painted line
   does not move. The comment at 7893 says the contract out loud: "its
   pixels scroll along" — they don't.

Result: the edit line (or hint row) sits one row below where the model
says it is; the menu draws relative to the new rows over the stale glass.
No memory consequence — the model is right, the glass is wrong — and the
next full repaint heals it. But it is real, visible, and lives exactly on
the "invariant argued here, read over there" seam.

**Fix:** re-establish the premise at the three seams, don't weaken the
flag. At the top of `edroom()` and `pastehintroom()` and before the menu
loop: `IF curcon.sb THEN vblankscan() ELSE curcon.vblank := FALSE`. The
mirrored cells are in the model, so `vblankscan()` answers honestly (and
early-exits on the first one); the `ELSE` arm covers LINES=0 consoles,
where nothing can verify and conservative-FALSE is the only sound answer.
**Do not** clear `vblank` in `drawedit()` instead — the blip repaint after
every cooked write would leave the flag permanently FALSE and quietly
disable E5's entire scroll-nl win (the blip is erased before render, which
is precisely why the in-render reads stay sound).

Worth a masktest-style control in `tests/defertest.e`'s vein: paint, skip,
compare — the b32 lesson says don't hand-trace this one either.

---

### D3 — `dfd`/`dfx0`/`dfx1` are never initialized: first-generation garbage collisions

**Where:** DEF block 512–514; `main()`'s table loop 642–646 initializes
`prtbl` and `zerorun` in the same breath and skips these three;
`dfstart()` 4478 (first arm sets `dfgen := 1`, sweep only at wrap);
`dfmark()` 4542; `dfflush()` 4582.

"E globals start as garbage" is stated twice in this file (`anstab`,
`zerorun`) and honored both times. The engine's dirty arrays are the
exception: after mount, `dfd` holds heap noise, and the first arm makes
the live generation **1** — any garbage byte that happens to be 1 makes
`dfmark`'s merge path (`IF dfd[r] = dfgen`) treat noise in `dfx0`/`dfx1`
as an existing span. The repaint then runs `drawmodelcells(r, x0, x1)`
with `x1` up to 255: reads past the row's real columns (past the plane's
end for high ring rows — out-of-bounds heap *reads*), and paints garbage
glyphs right of the text area, clipped by the layer. In-range cells
repaint from the model and are therefore correct — which is why this
looks like, at worst, a brief flicker of margin garbage on the first few
packets after mount, and why nobody has seen it.

**Fix:** one line in the existing 0..255 init loop (`dfd[tmp] := 0` —
DFROWS is 256, the loop already fits), or init `dfgen := 255` so the very
first `dfstart()` performs the wrap sweep. Either restores the house rule.

---

## Performance

### P1 — A WAIT_CHAR-polling client forfeits all aggregation

`dowrite()` 1566–1580: the E4c rule — parked read or WAIT_CHAR at accept
time ⇒ flush immediately — is right for Ed, and the comment tells that
story well. Note the other client shape it catches: a program that parks
WAIT_CHAR with a long timeout as a keyboard poll *while streaming output*
(status monitors, game loops) pays a full render per write, permanently.
Still faster than 1.2.1 (S1–S3 hold; one blit per write, not per row),
but the S5 pooling is silently off for exactly the client class that
scrolls the most per second. Not wrong — latency-beats-batching is a
defensible default — but if a real client ever "feels 1.2.2 again", this
is where to look. A middle path exists (flush only when `wolen` exceeds a
few lines instead of always) if one ever shows up.

### P2 — `vblankscan()` pays full price exactly when the screen is blank

`vblankscan()` 4225 runs inside every `redraw()`. On any screen with text
it early-exits within a few cells; on a genuinely blank screen it walks
all rows × cols (~2.2K byte reads in an E loop — low-single-digit ms at
14 MHz, by the E4b arithmetic). Blank-screen full redraws are rare
(resize of an empty window, FF-only flush), so this is a note, not a
finding — but it is the one scan in the file whose worst case is its
common-trigger case inverted.

### P3 — `dffull` on an all-blank screen RectFills every row

A packet whose scrolls reach `dfpend >= rows` on a blank screen (60 bare
newlines into a 50-row window) flips to rebuild mode, and `redraw()`
dutifully blank-run-fills every row of an already-blank window. E5 skips
the *scroll* blit but nothing skips the rebuild. Rare (conbench's 10-NL
packets never trip it); a `vblank`-check before the dffull redraw's row
loop would close it if it ever matters.

### Still open from earlier audits

- audit3 P1: `scrollview()` still full-redraws per wheel tick (4290).
  Exposure shrank — E2c turns blank runs into fills and the mask cheapens
  the blits — but the per-tick `redraw()` + `settitle()` remains, and it
  is still the largest interactive cost on 68k.
- audit3 P3 / audit2 P6: `histpersist()` on the per-Enter path, and
  `fscall()`'s missing timeout. Both deliberately parked; inputs unchanged
  since audit3's re-decide note.

---

## Consistency and code health

**X1 — `WODEFER=FALSE` keeps the b3 arm compiled in** (1581–1583). A
staging artifact, same genre as the A/B constants the file has always
kept; the comment says what it proved. Fine — noted only so a future
byte-hunt knows it's deliberate.

**X2 — `flushout()`'s `win = NIL` discard arm is a net, and should say
so** (1614–1617). Every hide/close path pre-flushes (`doiconify` 2245,
`conclose` 1197, `doclosew` 3220, END 1320), so bytes can't legitimately
be in `wob` when the window is gone. The arm is right to exist — but it
silently discards *replied-as-written* output, so it deserves the
condispose-style comment (audit3 X3 precedent): "unreachable by
construction because every hide path flushes; kept as a net."

**X3 — `swaccept()` hand-copies `dowrite()`'s accept-time resets**
(1667–1673: breaktask, sbexit, clearsel, snaplive, tcclose). Correct
today, verified line for line — but any future rule added to one accept
site must be remembered at the other, and audit3's C9 (`sbsrch`) shows
exactly how one-site fixes happen. Factor an `acceptwrite(pkt, c)` helper
both callers share; the duplication is how the next D-item gets written.

**Docs:** `ccon.doc`/`ccon.readme` are still at 1.2.4 wording — expected
mid-beta; the 1.2.5 release ladder will carry the overlay-pen story.
**Mountlist/tests:** unchanged since audit3 apart from the new harnesses;
`tests/` sources match what the code comments claim they proved
(masktest's deliberate-corruption controls remain the best habit in the
suite). conbench/srbench were not deep-audited here — they are tools, not
the handler.

---

## Great / Good / Meh / Bad / Terrible

### Great

- **The choke-point sweep is complete.** Every path that must observe
  settled output flushes first, and the selection story — pre-flush at
  drag start, park while held, `flushwq` on every drag-death path — has
  no gap I could find. For an accept-then-render conversion of a
  ten-thousand-line handler, that is the whole ballgame, and it was won.
- **"Write() blocks the caller, so queue depth ≤ 1 → aggregation
  requires early reply."** The single load-bearing insight of S5, stated
  plainly and built on. The b3/b4 staging — prove the ordering plumbing
  with identical render pattern, then turn deferral on — is the strongest
  methodology habit in the file, and it's now been used twice (S5, E5's
  forced-lie control).
- **The mask system is written as a proof.** Grow-before-draw, bracket-
  only, narrow-only-after-full-repaint-at-old-mask — invariants named,
  each violation the harness's control run must produce, and the b5
  altrestore catch shows the rules working both directions on a real bug.
- **`dfscroll`'s scroll-cleared-rows argument.** "The catch-up blit's
  vacated strip is the same mechanism 1.2.1's per-line scroll used —
  nothing new is being trusted." Exactly the right way to extend an old
  invariant instead of re-proving it.
- **E4's second draft honesty.** The b3 sweep was measured to be a no-op,
  the comment says so, and the render-then-sweep loop that replaced it is
  justified by the shape of the thing it imitates (console.device's
  device queue). Comments that record disproofs remain this codebase's
  signature.

### Good

- The `ftreq` clone (io_Device/io_Unit copy, only `treq` closes), the
  pointer-discriminated tport drain, and the abort-before-delete teardown
  order — all textbook.
- `sweepstash`'s single-slot "ordering is sacred" rule, with the stashed
  packet re-entering normal dispatch before the port is touched again.
- `swaccept`'s guard stack mirrors `dopkt`'s answers (`conok` → the same
  error reply), minus the one asymmetry that is D1.
- The E2 diet: generation-counter O(1) invalidation, range-bounded dirty
  scans, the exact-old-predicate `prtbl`. Measured, minimal, each with
  its price argued (the 16-byte CopyMem threshold, the per-attr-change
  refill cost).
- E5's forced-lie defertest control — the optimization ships with the
  instrument that would catch its own invariant breaking.

### Meh

- The accept-time reset list existing twice (X3) — correct now, fragile
  by construction.
- `flushexpired`'s four-round cap is justified only by "bounds latency";
  a sentence on why four (and not two, or until-dry) would future-proof
  the number.
- `vblank`'s writers are spread across five sites with the lifecycle
  documented only at the field — after D2's fix there will be seven, and
  the field comment becomes the only map. Fine today; worth keeping true.

### Bad

- **D1** — the new accept path introduced a trust hole the old path never
  had, with the correct guard sitting ten lines away in its sweep
  sibling. The audit3 lesson ("iconify reused none of the file's
  validation habits") has a 1.2.2 echo: *new seams must re-run the old
  checklist*.
- **D2** — an invariant argued rigorously for the bracket was silently
  extended to three scroll sites outside the bracket. The argument was so
  good it made the flag look global; the comment at 7893 even asserts the
  behavior the bug breaks.

### Terrible

Nothing — again. The perf campaign paid its complexity budget honestly:
every engine has a harness, every deferral has a forcing flush, the two
regressions the campaign itself caught (b1 mid-packet mask, b5 restore-
narrows) were caught by the invariants' own instruments, and the
real-hardware run outranked the emulator when they disagreed. The three
D-items are seam omissions, not confusion — the same species audit3
found, one campaign further out.

---

## Suggested order

1. **D1** — one line, crash-class, restores parity with `swaccept`.
2. **D3** — one line in the existing init loop.
3. **D2** — three call-site rechecks + a defertest-style control; the
   only one needing a harness.
4. **X3** — factor `acceptwrite()` while D1 has both sites open anyway.
5. **X2** — one comment.
6. P1/P2/P3 — notes for the file, none worth code until a client or a
   benchmark row says otherwise.
