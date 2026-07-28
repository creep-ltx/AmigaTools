-> audit-roadmap.md - working order for the audit5 findings.
-> Companion to audit.md (the consolidated document); finding IDs
-> (A1-A11, X1-X5) are that file's. The A-series is fresh - B/P/H, C,
-> D and E were taken by the four retired audits and the 1.2.4 render
-> campaign, and mixing IDs would make "is A3 fixed?" ambiguous forever.
->
-> Same ordering rule every campaign has used: the cheap, unfalsifiable
-> changes land together in one commit; anything that needs a real
-> before/after lands alone, where a bisect can name it. And the
-> standing verification creed: a fix that cannot be shown failing
-> before and passing after is not a fix, it is a hope - stated per
-> batch below, including the two batches where the honest answer is
-> "code-read only, no live repro exists on a healthy system".
->
-> STATUS: Batch A BOOT-GREEN 28.7.26 (deployed as 1.2.6b4; all 8
-> checklist items pass, findings in todo.md's 1.2.6b4 section).
-> ccinfo0 proved A2 both ways: res2=115 ERROR_BAD_NUMBER from a
-> CCON: shell, res2=205 ERROR_OBJECT_NOT_FOUND from stock CON:
-> (sender-routing, the documented negative control). A1 boot-green
-> = THE 1.2.6 RELEASE BLOCKER IS CLEARED. His call 28.7.26: ALL
-> batches (A-E) land before the release. Batch B (A3+X1 =
-> acceptreset) = 1.2.6b5 BOOT-GREEN same day, all six rows incl.
-> the A3 repro healed + conbench A/B b4-vs-b5 identical (5.70; the
-> SGR drift vs the 1.2.4-era baseline is a PARKED perf note in
-> todo.md, not this campaign's). C-E next.

# Fix roadmap, fifth pass

## Is this a big job?

**No — and this time without the asterisks.** Eleven findings, and
nine of them are between one and ~ten lines. Nothing redesigns
anything: every fix either enforces a rule the file already believes
it follows (A1's drain deferral, A3's accept resets, A7's NIL wall)
or keeps a promise a comment already makes (A4's "insert nothing
rather than something wrong").

| ID | Fix | Size |
|---|---|---|
| A1 | `iconreq` flag, deferred like `closereq` | ~4 lines + 1 field |
| A2 | NIL guard on DISK_INFO's arg1 | 1 line |
| A7 | `dotab`'s fs NIL wall at the top of `dodrop()` | 1 line |
| A8 | save/restore `areaptrn`/`areaptsz` beside `om` | 2 lines |
| A3+X1 | factor `acceptreset()`, call from all three sites | ~10 lines net |
| A4 | `fscall2()` returning res2 + one check in `lockpath` | ~8 lines |
| A5 | state-only selection clear in `doresize()` | 2 lines |
| A6 | hoist `altsave()` above the resize paint block | move, ~0 net |
| A9 | beep when the close-report is dropped | 1 line |
| A10 | FF/TAB disarm `alteat` | 2 lines |
| A11 | whole-drop room check before any enqueue | ~10 lines |
| X2-X5 | comments (doactive coherence, flushout net, altpop dependence, stack note) | prose |

The one item with any real design surface is A11 (precompute the
drop's total queue demand), and it is optional-tier — the trigger
needs a genuinely full 2KB queue.

---

## Version and release shape

**A1 gates the 1.2.6 release.** The iconify gadget shipped in b1 and
is the release's headline (Timm's wishlist); it must not ship with
its only trigger being a latent wild pointer. Everything else here is
severity-ranked below the release bar — b2/b3 shipped nothing worse
than what 1.2.5 already carried.

Working builds continue the beta ladder from the deployed b3:
**1.2.6b4, b5, ...**, beta suffix dropped at the release. Batch A is
the minimum the release waits for; batches B-D are same-campaign
material and cheap enough to ride along; batch E can trail into
1.2.6 or wait for a later point release without guilt.

Build/deploy per the usual routine: `ecompile ccon-handler.e
ccon-handler LARGE`, copy to FS-UAE AmigaOS3.2 `L:`, keep the
previous build staged by version name as the revert point, **reboot**
(a running handler keeps its seglist), test. State explicitly after
each compile whether the binary reached `L:` or only the repo.

---

## Batch A — the blocker + the mechanical guards — A1, A2, A7, A8 (one commit, 1.2.6b4)

**A1 — defer the gadget's iconify past the drain.** New console
field `iconreq` (`New()` zeroes it — no init needed, the house rule
observed this time). In main()'s CLOSEWINDOW dispatch:
`IF code = 1 THEN c.iconreq := TRUE ELSE doclosew()`. After
`UNTIL im = NIL`, beside the closereq check:
`IF c.iconreq THEN (c.iconreq := FALSE; curcon := c; doiconify())`.
RAMIGA+I keeps its direct call — it runs from `ihkey`, outside the
window-port drain, where closing the window is legal.

Two details to keep straight:
- Order against `closereq`: run `iconreq` FIRST. A close and an
  iconify in the same drain (possible: gadget click + `EndShell`
  racing) must end closed, not iconified — conclose after doiconify
  handles the windowless console correctly (parked packets replied,
  AppIcon removed via the existing teardown), the other order would
  `CloseWindow` a window `hidewin` already closed.
- `doiconify()`'s own guards (win-NIL, fwin, appicon-already) make a
  stale or doubled request a no-op — no extra belt needed.

**A2 — DISK_INFO validates arg1 before writing through it.** After
the `conbysender` block, before the Shl:
`IF pkt.arg1 = 0 THEN (ReplyPkt(pkt, DOSFALSE, ERROR_BAD_NUMBER); RETURN)`.
Packet still replied on the new arm — the reply-every-packet sweep
stays complete.

**A7 — the drop path gets `dotab`'s NIL wall.** At the top of
`dodrop()`, the sibling's line verbatim:
`IF (fsport = NIL) OR (fspkt = NIL) OR (fsfib = NIL) OR (fsname = NIL) THEN RETURN`
(drop silently — the AppMessage is still ReplyMsg'd by `doappmsg`,
locks are Workbench's, nothing leaks).

**A8 — `curfill()` restores what it borrows.** Save
`curcon.rp.areaptrn`/`areaptsz` beside `om`, restore both after the
fill — the three-line shape the drawmode already uses. The
unconditional NIL-reset arm goes away with it.

**Proving it.**
- A1 has a live repro and it is the feature itself: the gadget
  worked on the b1 boot only because of what address $56 held. The
  before/after that can actually be SEEN: add nothing — the fix is
  structural, and the boot test is the gadget exercised hard (below)
  plus the reasoning recorded here. If a visible before is wanted,
  the b1 binary is still staged (`L:` keeps version-named builds) —
  but deliberately crashing the FS-UAE install chasing a
  luck-dependent wild read is not required for a fix whose violated
  invariant is stated in the file's own comment.
- A2/A7 have no healthy-system repro (the triggers are buggy
  clients and mount-time alloc failure). The house answer exists
  already: `tests/ccdie.e` is a packet-sending test client. A
  sibling `tests/ccinfo0.e` — open `CCON:`, send ACTION_DISK_INFO
  with arg1=0 via DoPkt, print "survived" — is ~20 lines, proves A2
  on the machine before/after (before = guru or trashed low memory;
  after = ERROR_BAD_NUMBER reply, machine fine). Worth writing; the
  A7 arm stays code-read-only (alloc failure at mount is not
  reachable on demand).

**Boot checklist (1.2.6b4, reboot first, `Version L:ccon-handler`):**
- [ ] iconify gadget clicked on a live shell — parks to AppIcon,
      double-click restores, transcript intact (the b1 rows, re-run
      on the safe path)
- [ ] gadget HAMMERED: iconify/restore five times fast, then gadget
      + EndShell in quick succession — no guru, console ends clean
- [ ] gadget over Ed (frame classes act while parked) — parks and
      restores like RA+I
- [ ] WAIT window: gadget parks it, restore, close gadget still
      kills it
- [ ] RA+I still iconifies everywhere, incl. a borrowed CTerm frame
- [ ] `ccinfo0` test client: replies ERROR_BAD_NUMBER, machine fine
- [ ] ghost cursor on an inactive window still checkerboards; blip
      and block cursor unchanged (A8 touched their shared painter)
- [ ] drag-and-drop regression: drop a file, a drawer, a disk icon —
      paths insert as before (A7's guard must be invisible)

---

## Batch B — the accept-reset factoring — A3 + X1 (one commit, 1.2.6b5)

The audit4-X3 debt, paid the way it should have been paid then: one
`acceptreset()` proc — `IF curcon.sbsrch THEN sbexit()` /
`clearsel()` / `snaplive()` / `tcclose()` — called from `dowrite`'s
accept block, `swaccept`, and `dodrop` (after `flushout`, before the
insert loop). `dowrite`/`swaccept` keep their `breaktask` refresh
beside the call (it is packet-side, not input-side, and dodrop must
NOT take it). Net: three copies become one, the third copy's three
missing entries appear, and the fourth caller — whenever a feature
adds one — cannot forget what it never has to remember.

`snaplive()` stays deliberately reset-free (the 1610 comment) —
`acceptreset()` is exactly the caller-side bundle that comment says
every caller owes.

**Proving it.** The A3 repro is four user actions, boot-testable
before AND after:
- Before (on b4): scroll back, Ctrl+R, type a fragment, drop an icon
  on the window — the path vanishes on the next Esc, the next
  keystroke feeds the search fragment.
- After (b5): same actions — search exits, path sits on the edit
  line, next keystroke types normally.

**Boot checklist (1.2.6b5):**
- [ ] the A3 repro above, healed
- [ ] drop with the completion menu open — menu closes, path
      inserts, next Enter commits the line (not eaten by the menu)
- [ ] drop with a standing highlight — highlight clears like any
      keystroke
- [ ] plain drop regression: file/drawer/disk, cooked and into Ed
      (raw) — unchanged
- [ ] dowrite/swaccept regression (the factoring touched the hot
      accept path): `list` a big dir with a highlight standing —
      highlight clears, output flows; Ctrl+R then `dir` in another
      window — that window unaffected; type-ahead during output
- [ ] conbench quick pass — accept-path cost unchanged (the factor
      is a call, not new work; verify the number anyway)

---

## Batch C — the parent-hop truth — A4 (one commit, 1.2.6b6)

`fscall2(task, act, a1, a2, a3, res2ptr)`: the existing `fscall`
body with one extra line reading `fspkt.pkt.res2` after the wait;
`fscall` becomes `fscall2(..., NIL)` (or stays and shares a body —
whichever reads cleaner in E). In `lockpath`'s walk:
`par := fscall2(fl.task, ACTION_PARENT, cur, 0, 0, {r2})`, then
`IF (par = 0) AND (r2 <> 0) THEN ok := FALSE`. The root still ends
the walk with `r2 = 0`; a failed hop now fails the WHOLE drop —
the promise at 2428 kept on all three arms.

**Proving it.** The honest statement: there is no on-demand repro —
ACTION_PARENT failure needs a low-memory or wedged filesystem at
exactly the right packet. What CAN be verified:
- The root case still works (every successful drop exercises it —
  any drop from any volume proves `r2 = 0` at the root or nothing
  would ever insert).
- The failure arm is code-symmetric with the EXAMINE failure arm
  two lines above, which the same walk already takes on demand
  (drop something, delete it mid-drag — not worth staging; the arm
  is four lines and reviewable).
This is the same verification class as audit3's C3: an inspection
fix, labelled as such.

**Boot checklist (1.2.6b6):**
- [ ] drops still resolve: RAM:, the boot volume, a deep path, a
      drawer (trailing `/`), a disk icon (`Vol:`), spaces quoted
- [ ] multi-icon drop unchanged
- [ ] Tab completion regression (`fscall` was touched): `cd Ut<Tab>`,
      `dir SYS:Prefs/<Tab>`, menu cycling — unchanged

---

## Batch D — the resize seams — A5 + A6 (one commit, 1.2.6b7)

**A5** — in `doresize()`, replace the `clearsel()` call with the
state-only clear (`curcon.sello := -1; curcon.selhi := -1`; `selon`
is already forced FALSE on the next line). The full clear+redraw at
the bottom of `doresize` owes the pixels anyway — the same argument
b8 made for `altpop()`, applied to the call between its two
already-fixed neighbours. `clearsel()` itself is untouched for its
other callers.

**A6** — hoist the `IF wasalt THEN altsave()` block above the
raw/cooked paint block (`cursdraw`/`drawedit`). Raw path indifferent
(cursdraw is pixels-only); cooked path now snapshots a model without
the edit-line mirror. Per audit.md's warning: hoist the SNAPSHOT,
do not reorder `drawedit` after it inside the cooked arm —
`drawedit`'s `edroom` can scroll and desync `altsbtop`.

**Proving it.** A5 has a clean before/after on the glass:
- Before (b6): drag a highlight across several rows, release,
  shrink the window with the size gadget — bottom/right border
  shows overpainted cells until a frame redraw.
- After (b7): same actions — border clean immediately.
A6 is inspection-tier (no shipped client is cooked+altscreen); its
regression surface IS the b7/b8 machinery, so the Ed/More resize
rows below carry it.

**Boot checklist (1.2.6b7):**
- [ ] the A5 repro above, healed; repeat with the highlight standing
      during a More page (drag mid-More, release, resize)
- [ ] selection regression: drag/copy/paste, double- and
      triple-click, cross-window paste — unchanged
- [ ] Ed: resize mid-edit — repaints to new size, transcript
      restored on quit, border intact through the dance (the b7/b8
      rows, re-run — A6 moved code inside their proc)
- [ ] More: resize mid-page, next keypress repaints, quit restores
- [ ] scrollback + selection after several resizes (model realloc
      path unchanged but adjacent)

---

## Batch E — the hygiene sweep — A9, A10, A11, X2-X5 (one sitting, ride-along or later)

- **A9**: `DisplayBeep(NIL)` when `ihreport`'s room check refuses
  the class-11 close report — the C5 audibility rule. (The one-slot
  replay is over-engineering for a wedged-client corner; beep and
  done.)
- **A10**: clear `alteat` in the FF and TAB branches of `render()`
  — "any output disarms". CSI motion stays armed (ESC8's family,
  the feature's whole point).
- **A11**: optional tier. If taken: `dodrop` resolves all paths
  into a scratch tally first, one `inqroom(total)` decides the
  whole drop, one beep refuses it whole. If not taken: document
  the per-icon granularity in ccon.doc's LIMITATIONS.
- **X2**: the two-line comment at `doactive()` stating the
  no-flush coherence argument (model and glass lag together;
  redress reads values pending bytes cannot move; becomes a live
  desync site if accept ever mutates cursor state pre-render).
- **X3**: audit4-X2's comment at `flushout()`'s discard arm —
  "unreachable by construction, every hide path flushes; kept as
  a net."
- **X4**: one sentence at the `altdrop()` belt — the reflow's
  correctness depends on `altpop()` succeeding whenever `altvalid`.
- **X5**: nothing to change — the stack note lives in audit.md;
  optionally one line in the mountlist comment block where the
  10000-byte stack is already discussed.

**Boot checklist:** the standing regression sweep once (typing,
completion, scrollback, Ctrl+R, More, Ed, copy/paste, iconify,
drop) — batch E's code arms are one line each in paths the sweep
already exercises; the comments compile to nothing.

---

## Deliberately NOT in this campaign

- **The fscall timeout (audit2 P6).** Still his call, unchanged by
  this roadmap — but the re-decide sentence belongs in todo.md now:
  the exposure grew from Tab/Enter/first-open to drag-and-drop, the
  most casual gesture yet, and the real fix (timer-interleaved wait,
  fail the operation not the handler) is the same size it was two
  audits ago.
- **The carried perf notes** (audit3 P1 wheel redraw, P3 histpersist,
  P4 reflow peak, audit4 P1-P3): notes until a benchmark row or a
  real client complains. P1 remains the one that would be FELT if
  fixed (wheel scrolling on 68k) — it needs its own boot-tested
  build, not a ride-along.
- **audit3's leftovers** (C5 tail pump, C6 overturn, X2 wrap idiom):
  unchanged standing, recorded in audit.md's ledger.
