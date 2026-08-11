# CCON source audit — 1.2.6b3 (audit5, the consolidated document)

Full read of `ccon-handler.e` at `$VER: ccon-handler 1.2.6b3 (27.7.26)`
(8405 lines, HEAD @ baead1e), delta-focused on the ~490 lines gained
since audit4's 1.2.5b1 baseline: the 1.2.5b2 audit-fix batch, the
b3–b8 "evening of Ed" ladder, and the three 1.2.6 features (iconify
gadget, complement cursor, drag and drop). Read-only: nothing in this
pass has been changed.

**This document replaces `audit.md`, `audit2.md`, `audit3.md`,
`audit4.md` and the three roadmap files** (his call, 28.7.26). The
retired texts remain in git history (`git log --all -- ccon/audit*.md`);
the changelog carries the release-level story of every fix that
shipped. What this document keeps from them is the part that must stay
live: **the ledger** — the current, code-verified status of every
prior finding ID — at the bottom. The ledger pass re-checked all 44
prior IDs against the current source; one materially stale row was
found and corrected there (old B8).

Method: four parallel read passes (the 1.2.6 features; the 1.2.5b2–b8
fixes incl. verification that audit4's D1–D3 landed as prescribed; the
whole-file cross-cutting sweeps; the ledger fact-check), then every
ranked finding re-verified against the cited lines before it was
written down.

Numbering is a fresh series (**A1..**) — B/P/H, C, D and E are taken
(audits 1–4 and the 1.2.4 render campaign).

**Status update (28.7.26): A1, A2, A7 and A8 are FIXED and
boot-verified in 1.2.6b4** — full findings in todo.md's 1.2.6b4
section, fix shapes in audit-roadmap.md Batch A. A1's fix clears the
1.2.6 release blocker. A2 was proven live by `tests/ccinfo0`
(res2=115 ERROR_BAD_NUMBER from a CCON: shell; res2=205 from stock
CON: = sender-routing, the negative control). **A3 and X1 are FIXED
and boot-verified in 1.2.6b5** (the `acceptreset()` factoring; the
A3 repro healed on the glass, conbench A/B b4-vs-b5 identical).
**A4 in 1.2.6b6, A5+A6 in 1.2.6b7, and A9+A10+A11 (both arms) +
X2–X5 in 1.2.6b8 — all boot-verified 28.7.26. THIS AUDIT IS
CLOSED: every finding fixed or written down, five batches
boot-green in one day (b4–b8).** The campaign itself was then
audited before release — **Audit6, the after-fixes pass, at the
bottom of this document** (fresh F-series vs 1.2.6b8 @380f8ec):
one narrow pre-existing accounting hole (F1) and four comment
repairs shipped as **1.2.6b9, boot-verified 28.7.26** — F4/F5 are
recorded behaviour. **Audit6 is closed.** The 1.2.6 release ladder
is what remains.

---

## Verdict

The b5–b8 Ed machinery is the strongest work in the delta: the
three-way close protocol covers its client shapes exactly, `alteat` is
render-scoped by construction despite being a global, and the
altpop/altrestore split honors the plane-mask invariant in both
directions. The audit4 fixes (D1–D3) all landed **exactly as
prescribed**, ELSE-arms and warnings included. The choke-point flush
discipline audit4 declared complete **still holds** across all three
new features — every path that observes the model or the glass
flushes first, with one argued-sound, undocumented exception (X2).

What broke is what always breaks here: the seams. b1's six lines
re-broke the oldest rule in the drain loop — with the rule's own
comment four lines below the new call (A1). The drop path re-ran most
of the house checklist impressively (lock hygiene, buffer caps,
nested-IF pointer discipline, no-DOS purity) and then skipped the two
guards that live in its own siblings (A3, A7). And audit4's X3
prediction — "the un-factored accept-reset list is how the next
D-item gets written" — came true verbatim: the third copy is missing
three of its five entries (A3).

| Severity | Count | Items |
|---|---|---|
| Crash / wild write | 2 | A1 (new in b1), A2 (pre-existing) |
| Corruption (wrong state/text) | 2 | A3, A4 |
| Corruption, narrow trigger | 1 | A6 |
| Cosmetic | 2 | A5, A10 |
| Hygiene | 4 | A7, A8, A9, A11 |
| Maintenance / comments | 5 | X1..X5 |
| Performance | carried | P-notes (all prior, none new) |

---

## Correctness

### A1 — the iconify gadget closes the window whose UserPort the drain loop is still reading

**Where:** main() 905–918 (dispatch), 882 (the re-fetch), 919–922 (the
invariant, stated); `doiconify()` 2493 → `hidewin()` 2540–2542.

```e
915              IF code = 1 THEN doiconify() ELSE doclosew()
...
918        UNTIL im = NIL
919        IF c.closereq             -> deferred: never CloseWindow while
920          c.closereq := FALSE     -> draining the port it owns
```

`doiconify()` on the Code=1 branch runs `hidewin()` →
`CloseWindow(curcon.win); curcon.win := NIL` synchronously, mid-drain
of that window's own UserPort. The message just dispatched was
non-NIL, so `UNTIL im = NIL` loops back to
`im := GetMsg(c.win.userport)` at 882 with `c.win = NIL` — a load
from absolute address $56 (win_UserPort off a NIL base). Whatever
lives there is treated as a MsgPort; a garbage non-NIL GetMsg return
then feeds `ReplyMsg(im)` a wild pointer, which **writes** through it.

This is the exact violation the `closereq` machinery four lines below
exists to prevent, and the true-close branch (`doclosew`, Code 0)
honors it. The old RAMIGA+I path is safe — it calls `doiconify()`
from `ihkey`, outside the window-port drain. The b1 boot pass ("It
works, of course it does") means address $56's contents happened to
parse as an idle port on that machine — luck, not soundness; a
different ROM/MapROM/RTG layout can detonate it.

**Reachable:** every click of the new gadget — the feature's only
trigger.

**Fix:** the house pattern, one flag: in the drain,
`IF code = 1 THEN c.iconreq := TRUE ELSE doclosew()`; beside the
closereq check after `UNTIL im = NIL`:
`IF c.iconreq THEN (c.iconreq := FALSE; curcon := c; doiconify())`.
New console field — `New()` zeroes it, no init needed. RAMIGA+I keeps
its direct call.

---

### A2 — `ACTION_DISK_INFO` zeroes 36 bytes through an unvalidated client BPTR: `arg1 = 0` wipes low memory

**Where:** `dopkt` 1522–1526.

```e
    id := Shl(pkt.arg1, 2)      -> BPTR to InfoData
    zp := id
    FOR i := 0 TO 8
      zp[i] := 0
```

`arg1` is the only packet argument in the dispatch that is *written
through* with no validation. A client passing NIL (a failed
allocation it never checked) makes `id = 0` and the loop zeroes
addresses 0–35 — including ExecBase's pointer at 4 — before
`disktype`/`volumenode` land there too. Pre-existing (1.2.1-era, not
a regression), same class as audit4's D1: READ/WRITE buffer trust is
inherent to the protocol and shared with stock handlers, but this is
the one case where **we** proactively write through a client pointer,
and it is one line to guard.

**Reachable:** any buggy client calling Info() on a console with a
NIL InfoData. Not reachable from correct DOS calls.

**Fix:** before the Shl:
`IF pkt.arg1 = 0 THEN (ReplyPkt(pkt, DOSFALSE, ERROR_BAD_NUMBER); RETURN)`.

---

### A3 — `dodrop()` skips the accept-time reset trio: the audit4-X3 prediction, come true

**Where:** `dodrop()` 2338–2353; the pattern it misses: `dowrite`
1614–1617, `swaccept` 1748–1751, `ihkey` 7389–7391.

A drop is "input, same manners as a keystroke" (its own comment), but
between `flushout` and the insert it runs only `snaplive()` — not the
`IF curcon.sbsrch THEN sbexit()` / `clearsel()` / `tcclose()` trio
that both accept siblings carry (the audit3-C9 fix relocated exactly
there because `snaplive()` deliberately does not do it itself — the
1610 comment says every caller must). Three consequences:

1. **Ctrl+R scrollback-search active** (`sbsrch`): the drop
   pasteinserts into the *match* line while the user's real line sits
   stashed; `sbsrch` stays TRUE, so the next keystroke feeds the
   search fragment (`sbadd` → `sbfind` yanks the view to a stale
   match) and Esc restores the stash — **the dropped path silently
   vanishes**. Audit3 C9's exact shape, reintroduced on the newest
   input path (third sighting of this species).
2. **Completion menu open** (`tcactive`): the path inserts under the
   frozen menu; `tcreplace`'s spans are stale and the next Enter is
   eaten by the menu-close guard instead of committing.
3. **Standing highlight:** output kills it, keys kill it, a drop
   leaves it standing. Cosmetic.

**Reachable:** (1) is four user actions, no client needed.

**Fix:** mirror 1614–1617 after the win-NIL guard — or do X1 below
properly and give all three sites the one `acceptreset()` this file
now owes twice over.

---

### A4 — `lockpath()` cannot tell a failed parent hop from the root: a wrong path is inserted, not nothing

**Where:** `lockpath()` 2456, 2462; `fscall()` 7522–7524; the
contradicted contract at 2428–2430.

```e
2456        par := fscall(fl.task, ACTION_PARENT, cur, 0, 0)
...
2462    cur := par                  -> par = 0 on the root: the walk ends
```

`fscall` returns only `res1`; ACTION_PARENT's failure (res1=0, reason
in the discarded res2) is indistinguishable from reaching the root
(also 0). A mid-walk failure ends the walk early with `ok` still
TRUE, and the emit loop crowns the last-collected *directory* segment
with `":"` — `sub:file` instead of `DH0:Work/sub/file`, inserted at
the cursor as if typed. The block comment promises the opposite:
"FALSE = a hop failed … insert nothing rather than something wrong" —
the guard exists for EXAMINE failure (2458–2459) and overflow
(2448–2449), but not for the one call whose failure hides inside its
success value.

**Reachable:** ACTION_PARENT allocates a lock; under the classic 68k
memory squeeze or an FS hiccup it fails with res2=ERROR_NO_FREE_STORE.
Rare — but the failure mode is silent wrong text on a command line,
plausibly executed against the wrong file.

**Fix:** an `fscall2(..., res2ptr)` variant that reads
`fspkt.pkt.res2` after the wait; treat `(par = 0) AND (res2 <> 0)` as
`ok := FALSE`. One extra check at one call site.

---

### A5 — `doresize()`'s `clearsel()` repaints at the OLD grid into the already-resized window

**Where:** `doresize()` 3374 (before `gridcalc()` at 3391) →
`clearsel()` → `selrepaint()` (rmax clamped to the OLD `rows - 1`) →
`drawselrow()` (paints all OLD `cols`).

The b8 lesson — old-grid paint overdraws the resized window's border,
and the layer covers border pixels — is documented on **both
neighbors** of this call: `altpop()` three lines above ("the paint
half runs at the OLD grid and overdrew the resized window's border")
and `dropeditmirror()` below ("its PAINT ran at the old geometry into
the already-shrunk window, wiping the sizing gadget"). `clearsel()`
between them still repaints every selection row full-width at old
coordinates when a standing highlight dies with the resize. The final
heal RectFills only the inner region — border pixels stay overpainted
until Intuition redraws the frame. With `wasalt` there is a second
facet (the repaint shows restored transcript under the client's alt
page) but the full repaint below heals that one immediately.

**Reachable:** any window with a standing highlight, shrink it. Also
during a More session (More holds no event mask, so drag-select works
mid-page).

**Fix:** replace the call with a state-only clear
(`curcon.sello := -1; curcon.selhi := -1`) — the full repaint below
owes the pixels anyway, the same reasoning b8 applied to `altpop()`.
`clearsel()` itself stays for its other callers.

---

### A6 — the mid-resize re-snapshot captures the edit-line mirror for a cooked alt-screen client

**Where:** `doresize()` 3493–3506: `drawedit()` (3496) runs before
`altsave()` (3499); contrast the `?47h`-time snapshot, which runs
inside the render bracket after `eraseedit()`.

For a **cooked** client holding the alternate screen, `drawedit()`
mirrors the edit line's cells into the model and `altsave()` then
snapshots those rows — so the eventual `?47l` restores the edit line
as phantom transcript text, in the model, archived into scrollback.
A miniature of the exact wound class b7 closed ("nothing of the
client's page ever touches the ring" — here it is our own editor's
page). Raw clients — More and Ed, the only real alt-screen users —
are unaffected (`cursdraw` is pixels-only), which is why nothing has
been seen. Found independently by two passes.

**Reachable:** only a cooked client that sends `?47h`, then a resize,
then `?47l`. No shipped client does this today; the invariant is
stated absolutely, so it is a finding, not a note.

**Fix:** hoist the `IF wasalt THEN altsave()` block above the
raw/cooked paint block (raw indifferent, cooked snapshots a clean
model). Do **not** merely reorder drawedit after altsave inside the
cooked arm — `drawedit`'s `edroom` can scroll and desync `altsbtop`.

---

### A7 — the drop path uses the fs plumbing without `dotab`'s NIL wall

**Where:** `dodrop()`/`droppath()`/`lockpath()` (all via `fscall`);
the guard the sibling carries: `dotab()` 8264–8265
(`IF (fsport = NIL) OR (fspkt = NIL) OR (fsfib = NIL) OR (fsname = NIL) … RETURN`).

If `fspkt`/`fsfib`/`fsname` failed to allocate at mount (main()
tolerates it), a drop writes packet fields through NIL — or hands the
target filesystem a zero FIB BPTR, making **it** write 260 bytes at
address 0. Near-theoretical (alloc failure at mount + a drop), but
the one-word-asymmetry class again: the guard exists ten screens away
in the exact sibling. (`loadhistfile`/`savehistfile` share this
pre-existing exposure; noted.)

**Fix:** `dotab`'s guard line at the top of `dodrop()`.

---

### A8 — `curfill()` clobbers a borrowed rastport's AreaPtrn

**Where:** `curfill()` 3864–3872.

`om := drawmode` is saved and restored; `areaptrn`/`areaptsz` are
unconditionally forced to NIL/0 — even when the ghost pattern was
never installed, and even on a **borrowed** CTerm frame, where winact
ghosting explicitly applies and any pattern the owner keeps on its
own rastport is silently destroyed by every cursor paint. Owned
windows: harmless.

**Fix:** save/restore both fields beside `om` — the three-line shape
the drawmode already uses.

---

### A9 — a full input queue eats a requested close-gadget click whole

**Where:** `doclosew()` 3540–3550 → `ihreport()` 7472 (room check
fails → silent RETURN).

For the Ed path the click's only effect is the queued class-11
report; with `inq` full (wedged client, ~2 KB backlog) the report is
dropped and there is no fallback — no report, no EOF, no closereq.
Stock discards *unrequested* clicks; this discards a **requested**
one. Narrow (a wedged client wasn't going to run its quit flow
anyway) and retryable once the queue drains.

**Fix (if wanted):** `DisplayBeep(NIL)` when the room check fails on
this path (the C5 audibility rule), or a one-slot pending flag
replayed from `inputarrived()`.

---

### A10 — `alteat` survives non-printable output: FF/TAB then a working LF loses that LF

**Where:** armed 5146; cleared at 5560 (printables), 5779 (the eaten
LF), 5842 (render exit) — but not by FF (5795), TAB spaces, or CSI
motion.

A hypothetical alt-screen client whose exit packet is
`?47l · FF · LF` (or TAB then LF) loses a newline doing real work.
Ed's proven packet (`?47l ESC8 \n`) and More's (nothing after
`?47l`) are unaffected. Render-scoped by construction, so the
exposure is strictly in-packet.

**Fix:** clear `alteat` in the FF and TAB branches ("any output
disarms"); leave CSI motion armed — that is ESC8's own family, and
disarming there defeats the feature.

---

### A11 — multi-icon drops are whole-or-nothing per *icon*, not per drop; cooked overflow is silent

**Where:** `droppath()` 2412–2417 (raw: per-path `inqroom` + beep in
`dodrop`'s FOR loop); `pasteinsert()` 4407 (cooked: per-char
`IF l < cap`, no else).

A 5-icon drop into a nearly-full raw queue can deliver icons 1, 2, 3,
5 — one beep, a silently incomplete *and reordered-by-omission*
argument list. The todo spec's "a drop that does not fit beeps
instead of half-arriving" treats the drop as the unit. Cooked side:
characters past `edcap` drop with no signal at all. Both need a
genuinely full queue / very long paths, hence hygiene.

**Fix:** resolve all paths first, test room once, beep-and-abort the
whole drop; cooked: beep when any character was refused.

---

## Maintenance (X) and performance (P)

- **X1 — `acceptreset()` is now owed three times.** audit4's X3
  (factor the accept-time reset list shared by `dowrite`/`swaccept`)
  was not done; b3 wrote the third copy and lost three entries in the
  copying (A3). The two old sites are verified in sync today —
  line-for-line — but the prediction has now come true once. Factor
  it while A3 has the sites open.
- **X2 — `doactive()` is the one glass-touching event path with no
  pre-flush, and the argument for why that is sound is written
  nowhere.** It holds only because model and glass lag *together*
  under accept-then-render and redress reads values the pending bytes
  cannot have moved (`reanchor` runs only inside `dorender`). If a
  future change lets `wob` bytes move `cx/cy/ancx/ancy` before
  render, this becomes a live desync site with no warning comment.
  Either add the (cheap) `flushout` for uniformity or write the
  two-line coherence argument down. Found by two passes
  independently.
- **X3 — audit4 X2 still owed:** `flushout()`'s win=NIL discard arm
  still lacks its "unreachable by construction; kept as a net"
  comment (byte-identical to the 1.2.5b1 baseline).
- **X4 — the b7 reflow's correctness depends on `altpop()` succeeding
  whenever `altvalid`** (a FALSE return there would archive the
  client's page — the exact b7 wound). Unreachable today; one
  sentence at the `altdrop()` belt would keep it that way.
- **X5 — stack headroom note:** `droppath` + `lockpath` add ~2.0 KB
  of frames (pb 620 + tb 560; segb 400 + sgo/sgl 192 + nb 110) on
  E's 10000-byte runtime stack. Fits with room; remember it the next
  time a buffer joins this call chain.

- **P — the parked `fscall` timeout (old audit2 P6) got its third
  caller family and its most casual trigger yet.** Tab/Enter/first
  open could always hang every CCON window on a wedged filesystem;
  drag and drop now does it with a mouse gesture, up to 3+hops calls
  per icon. Both feature passes flagged the escalation. Still his
  call — but the re-decide note this ledger carries (below) now has
  a stronger case than when audit3 wrote it.
- **P — carried, all confirmed still accurate at 1.2.6b3:**
  `scrollview()` full-redraw + `settitle()` per wheel tick (audit3
  P1 — still the largest interactive cost on 68k); `histpersist`
  blocks the process per Enter (audit3 P3, parked design trade);
  reflow doubles peak model memory (audit3 P4); audit4's P1–P3
  render notes (WAIT_CHAR pollers forfeit aggregation; `vblankscan`
  worst-case-on-blank; `dffull` RectFills a blank screen). None
  worth code until a client or a benchmark row says otherwise.

---

## Verified sound

The load-bearing re-verifications, condensed from all four passes:

- **The audit4 fixes landed exactly as prescribed.** D1: negative-len
  guard at `dowrite` 1602–1605 (reply -1/ERROR_BAD_NUMBER, parity
  with `swaccept` 1744, packet still replied; a negative-len write
  stashed by `swaccept` re-dispatches into the same reply). D2:
  `vbrecheck()` 4628–4631 carries the prescribed line *including the
  ELSE arm* for LINES=0 consoles, called at all three prescribed
  seams (`pastehintroom` 4519, `edroom` 5881, dotab menu loop 8334);
  the warning was heeded — `drawedit()` contains no vblank write; an
  exhaustive `screenscroll()` caller sweep found no new unguarded
  site. D3: `dfd[tmp] := 0` at 683 in the canonical init loop.
- **The choke-point discipline holds at 1.2.6b3.** Every
  model/glass-observing path flushes first — checked each: END 1388,
  READ 1430, WAIT_CHAR 1452, SCREEN_MODE 1475, dowrite's sync/join
  paths, conclose 1265, doiconify 2490, doresize 3346, doclosew 3537
  (the class-11 report included), selmouse 4123, dopaste 4281,
  dovanilla 6756, dorawkey 7063, dodrop 2341. `flushwq()` on every
  drag-death path: release, resize, closewin (windowed and
  windowless), the lost-button-up belt; iconify mid-drag legally
  re-parks and replays. The one no-flush exception is argued sound
  and is X2.
- **All 15 SELECT packet cases reply on all branches** — checked
  each, including every error arm, park-and-reply-later path
  (satisfyreads/satisfywaits/timer/closewin) and the DIE/default
  arms. `fh_Arg1` conok-validated on END/READ/WRITE and in swaccept;
  every non-packet entry (UserPort walk with next-taken-first, ring
  drain with conclose scrub, timer, sweepstash re-entry, AppMessages)
  resolves its console against the live list before trust. The one
  write-through-unvalidated-arg1 exception is A2.
- **Resource lifecycle clean.** New acquires: `gpat` (chip)
  freed in killhandler — the one allocation E's exit doesn't track,
  correctly hand-freed; `appwin` removed strictly before its window
  dies on all three exits (hidewin 2536–2539, closewin 3079–3082,
  DIE-implies-empty-list); AppIcon and AppWindow never coexist. Old
  ladders re-verified at the new version: openwin failure unwind,
  reopenwin stride-mismatch drop, reflow all-four-or-none, alt-plane
  idempotent drops, pens symmetric across hide/reopen/close,
  abort-before-delete on the timer clone. `lockpath` frees every
  intermediate lock on every arm including both failure exits; the
  drop's argument locks are correctly left to Workbench, resolved
  before the unconditional ReplyMsg.
- **The no-DOS rule survived its riskiest feature yet.** Drag-and-
  drop path resolution is pure hand-rolled packets on the private
  fsport — no NameFromLock, no Lock, no GetDiskObject anywhere in
  the delta; AddAppWindowA/RemoveAppWindow/AddAppIconA are
  workbench.library list-ops, not packet senders; `fscall` still
  refuses our own port (closing the self-drop deadlock).
- **The complement cursor's XOR discipline is airtight.** The one
  non-idempotent primitive has exactly two callers, both protected:
  `cursdraw` self-erases first; `drawedit`'s blip paints full-depth
  JAM2 Text over the cell before every fill. Erase is
  repaint-from-model — idempotent by construction, the right erase
  for an XOR mark. `curfill` runs only outside the masked bracket
  (render restores mask $FF before any caller), and both fills are
  erased full-depth before the next masked render. `winact` is
  ground-truthed from WFLG_WINDOWACTIVE at both open sites, kept
  current by always-on frame classes; `doactive`'s three guards
  (same-state, win-NIL, viewoff) each hold. `gpat` is
  NIL-survivable at its one read site.
- **The b5–b8 Ed machinery is internally consistent.** The stale-
  evmask hazard is closed twice over (SCREEN_MODE 0 clears the whole
  mask — the comment even names Ed's missing CSI }; closewin clears
  it too). `alteat` cannot cross a packet, a console, or an event
  (armed only in-render, killed at render exit; the residual
  in-packet case is A10). The altpop/altsave ordering around
  gridcalc is right (dims compared old-to-old, reflow reads real
  transcript); altsave-at-new-geometry fails soft to the pre-b11
  behavior; the class-12 report is sent after re-arm, so Ed's
  repaint lands on the re-armed session; a non-subscribing client
  degrades exactly as the doc claims.
- **The E-trap sweep on the delta came back clean.** Every new
  global DEF-initialized or covered by New()-zeroing + coninit; every
  new AND/OR site evaluates only safe operands (the C3 nested-IF
  discipline extended to the new AppMessage drop branch); no new
  client-derived CopyMem length; no new Mod/DIVU on unbounded
  values; every drop-path buffer cap checked before its write
  (lockpath's 398/24/cap chain, droppath's 548/558/620 chain,
  tcbstr/tcfibname clamps covering both BSTR and C-string FIBs).
- **Drop-while-X surfaces covered by construction:** scrolled-back →
  snaplive precedes the insert; iconified → win-NIL guard (the
  AppWindow doesn't exist then anyway); mid-resize → window ports
  drain before wbport in the same wake; raw client → whole-path
  inqroom + one inputarrived; wa_Lock=0 left-outs skipped;
  drawer/volume drops emit `Vol:dir/` and `Vol:` per spec. Borrowed
  frames never register an AppWindow (the "CTerm: no drop target"
  todo row is real) — and a borrowed frame's iconify gadget, if its
  owner tagged one, is deliberately swallowed by the fwin guard.

---

## The ledger — every prior finding ID, verified against 1.2.6b3

Status re-checked in the source (not just the docs) by the ledger
pass, 28.7.26. "Fixed" rows were confirmed present; only deltas from
the old docs' claims are annotated.

**audit1 (1.2b1 pass):** B1 eraseedit theft ✓fixed b6 · B2 resize
grow ✓b7 · B3 CSI truncation ✓b8 · B4 AUTO retry ✓b7 · B5 ACTION_DIE
✓b13 · B6 conbysender ✓b12 · B7 width reflow ✓b10a ·
**B8 raw-resize — the doc said OPEN; it is FIXED** (1.2b25 @
1c989df: the always-drain with `parked` suppressing only input
classes; the 1.2b15 "fix reverted" breakage was the ESC[ arrow-key
bug, misattributed; hardened for mid-alt resize in 1.2.5b7/b8;
audit1's "Ed does not use ?47h" premise was disproven by the b6
EDDBG telemetry — Ed brackets its session with the alt screen) ·
P1 curattr ✓ · P2 Mod/Div ✓ · P3 history walk ✓b16 · P4 curcon
hoist ✓ · P5 hist rewrite ✓b11 · H1–H5 ✓ (H4 resolved-as-comment,
by design).

**audit2 (1.2b14 pass):** B9 textattr leak ✓b15 · B10 selcopy LF
✓b17 · B11 paste spin ✓b17 (subsumed by C4) · B12 runaway freeze
✓closed, was ls, not CCON · P6 fscall timeout — **still parked**
(comment present at 7495–7509, WaitPort 7522 timeout-less; see the
P-note above: exposure widened by dnd, re-decide requested) · H3
condispose planes ✓b15 · H6 stray bytes ✓.

**audit3 (1.2 pass):** C1 sbmax floor ✓1.2.1 (both directions) · C2
iconify geometry ✓ (+sbcols belt) · C3 doappmsg conok ✓ (discipline
extended to the 1.2.6b3 drop branch) · C4 chunk overflow ✓ · C5 raw
paste ceiling — partial by design (beep ships, tail-pump never
built; documented) · C6 iconified wq accept+discard — deliberate,
his call stands (1580) · C7 diskfont close ✓ · C8 icon-less strand
✓ · C9 snaplive/sbsrch ✓ (relocated to the accept sites — and A3 is
its third-sighting echo) · C10 edcap ✓ · P1 scrollview wheel —
**still open** (4679–4693), the big interactive perf item · P2 ✓ ·
P3 histpersist — parked · P4 reflow peak — parked · X1 ✓ · X2
wrap-idiom unification — not done (mitigated by C1's floor) · X3 tf
comment — not done · X4 SGR-cap doc note — not done · X5 255-col
doc ✓ (plus LINES + paste-limit wording).

**audit4 (1.2.5b1 pass):** D1/D2/D3 ✓ fixed 1.2.5b2 exactly as
prescribed (verified in detail above) · P1/P2/P3 — accurate,
unactioned by intent · X1 WODEFER arm — deliberate, unchanged · X2
flushout comment — **not done** (now this doc's X3) · X3
acceptwrite factoring — **not done, and its prediction came true**
(now this doc's X1/A3).

**Genuinely open at 1.2.6b3, the whole list:** A1–A11 above; X1–X5;
audit3 P1 (wheel redraw), audit2 P6 (fscall timeout, parked), audit3
P3 (histpersist, parked), audit3 P4 (reflow peak, parked), audit3 C5
tail-pump (never built, documented), audit3 C6 (deliberate), audit3
X2/X3/X4 (hygiene/doc debt), audit4 P1–P3 (notes).

---

## Great / Good / Meh / Bad / Terrible

### Great

- **The b6 EDDBG habit paid for the whole ledger.** Capturing Ed's
  actual exit bytes settled `alteat`'s design, disproved audit1's
  B8 premise, and turned "fix reverted, cause unknown" into "the
  arrow-key bug, misattributed" — the read-what-the-client-sends
  discipline keeps outranking every hypothesis.
- **`alteat` is a global that provably cannot leak.** Armed only
  inside render, killed unconditionally at render exit — scope by
  construction where the language offers none. The right way to do
  a one-shot in E.
- **The drop path's packet plumbing.** Hand-rolled ACTION_PARENT
  walks with per-arm lock hygiene, whole-or-nothing segment
  buffers, and BSTR/C-string FIB tolerance — the no-DOS rule held
  through the feature most likely to break it.
- **The XOR cursor shipped with its hazard already understood** —
  "repaint is idempotent, a second XOR is not" was written before
  the code, and the two-caller discipline enforces it.

### Good

- The three-way close protocol's client-shape coverage, including
  the stale-evmask double-close (SCREEN_MODE + closewin).
- The altpop/altrestore split and the b8 border lesson applied at
  the site that taught it.
- D1–D3 landing letter-perfect, ELSE-arms included — prescriptions
  are being read, not skimmed.

### Meh

- The accept-reset list existing three times (X1). Twice was
  "fragile by construction"; three times with a divergent copy is a
  bug factory in production.
- `doactive`'s soundness argument living in no comment (X2).

### Bad

- **A1** — six lines, and one of them re-broke the drain loop's
  oldest rule with the rule's own comment four lines away. Audit3
  said it about the first iconify, audit4 said it about the accept
  path, and it is still true: *new seams must re-run the old
  checklist* — especially the six-line features, because nobody
  audits six lines.
- **A4** — a contract stated in the block comment ("insert nothing
  rather than something wrong") and honored on two of three failure
  arms. The third arm's failure is invisible in res1, which is
  precisely why it needed the comment's promise kept.

### Terrible

Nothing. Four audits and a consolidation in, the file's failure
species has never changed: seams, not confusion. The invariants are
real, the instruments exist, and every crash-class find in this
pass is one flag or one line from closed.

---

## Suggested order

1. **A1** — one flag + two lines, crash-class, the release blocker
   for 1.2.6.
2. **A3 + X1 together** — factor `acceptreset()`, call it from all
   three sites; closes the corruption and retires the prediction.
3. **A2** — one line.
4. **A4** — `fscall2` + one check.
5. **A7** — one guard line, while the drop file is open.
6. **A5** — swap a call for two assignments.
7. **A6** — hoist `altsave` above the paint block.
8. **A8–A11, X2–X5** — the hygiene sweep, one sitting.
9. The P-notes stay notes — except the fscall-timeout re-decide,
   which now has three trigger families and deserves its sentence
   in todo.md.

---

# Audit6 — the after-fixes pass (28.7.26, vs 1.2.6b8 @380f8ec)

The audit5 fix campaign (b4–b8, five batches, one day) audited before
it ships — the same discipline every prior campaign got. Method:
two independent review passes run in parallel (an adversarial
fix-verifier working item-by-item against audit5's prescriptions,
and an exhaustive caller-sweeper over every proc the campaign
touched: pasteinsert's new return, fscall's delegation — all 25
sites — acceptreset's four constituents from three contexts,
alteat's new clears against Ed's real exit packet, iconreq's
lifecycle, altsave's moved call), plus an author pass focused on b4
(written by a session that died before its code was ever re-read).
Every finding below re-verified against the cited lines before it
was written down. Fresh series: **F1..F7**.

## Findings

### F1 — cooked scrolls while a snapshot is armed were never counted: `rawscr` is fed only under `rawmode`

**Where:** `screenscroll()` 4940, `dfscroll()` 5013; the accounting
they starve: `altpop()`/`altrestore()`'s `over` computation (4871).

`altpop()`'s content restore is index-self-consistent (the saved
rows are copied back at the restored `sbtop`), so `rawscr` guards
exactly one thing: the ring-WRAP overflow — scrolls during an alt
session that recycled ring rows far enough to eat the oldest
history, which must shrink `sbcnt` on restore. Both scroll sites
count only `IF rawmode`. A **cooked** client holding the alt screen
(none shipped — More and Ed are raw; the same hypothetical as A6)
scrolls via `drawedit`→`edroom`→`screenscroll` on every spilling
edit line, uncounted — `over` understated, `sbcnt` restored too
high, and the oldest history row after `?47l` is a recycled row
shown as a wrong join. **Pre-existing since the alt machinery** (any
in-session keystroke scroll had the hole); the b8 A6 hoist added one
more instance (the doresize `drawedit` now follows the re-snapshot)
and the review of that hoist is what surfaced it. Same
reachability tier as A6: no shipped client. **Fix (b9): count the
scroll whenever `altvalid`, not only under `rawmode` — one line at
each site, closing every instance at once (keystrokes and resize
alike).**

### F2 — the X2 comment's parenthetical is false as written

`doactive()`'s new coherence comment says "reanchor runs inside
dorender only" — `reanchor()` also runs at the SCREEN_MODE
cooked-revert (1504) and the Return commit (6992). Both flush
first, so the safety ARGUMENT stands; the stated reason doesn't,
and a wrong written-down reason is how the next edit goes wrong.
**Fix (b9): reword — pending wob bytes move the anchor only through
dorender; every other mover flushes first.**

### F3 — the X5 stack sentence names the wrong deepest path

The mountlist comment claims drop resolution
(dodrop/dropbuild/lockpath, ~2.1 KB) is the deepest handler path.
The history-save chain is deeper: `savehistfile` carries
`buf[2048]` and calls `tcresolve` (`dcopy[300]` + `devname[40]`) ≈
2.5 KB, reached from dovanilla→histpersist and conclose. Headroom
conclusion (10000-byte E stack) unaffected. **Fix (b9): correct the
sentence.**

### F4 — a drop larger than the queue is refused forever, and the write-up doesn't say so (NOTE, kept)

A11's whole-drop check refuses `total > INQMAX-1` (2047) even
against an EMPTY queue — the beep suggests "retry when it drains"
but no drain can ever make it fit; the old per-icon code delivered
what fit. This is whole-or-nothing semantics taken to its honest
edge (delivering a silently truncated argument LIST is the exact
A11 wound), so the behaviour stands — **fix (b9): one comment line
at the check acknowledging the edge.** A future escape hatch, if
ever wanted, is per-icon delivery when a single drop can never fit.

### F5 — the total=0 early return skips the old incidental eofpend wake (NOTE, accepted)

A fully-failed raw drop used to still call `inputarrived()`, which
could incidentally serve a standing `eofpend` to a queued reader;
the A11 early return skips that. Arguably more correct (a failed
drop performing an unrelated EOF delivery was an accident), zero
shipped-client impact. Recorded, no change.

### F6 — a line-number comment went stale the same day it was written

The b6 lockpath comment cites "the 2463 promise"; b8's edits moved
the promise header to ~2493. Line numbers belong in audit documents
(dated, versioned), not in code comments. **Fix (b9): reword to
name the header, not the line.**

### F7 — the A7 wall's comment still says `droppath`

`dodrop()`'s guard comment names a proc b8 renamed to `dropbuild`.
**Fix (b9): rename in the comment.**

## Verified clean

A1 (New-zeroed iconreq, per-console drain, clear-before-act,
iconreq-then-closereq cannot double-CloseWindow — closewin removes
the AppIcon first and replies every parked packet on the windowless
arm; ihkey's direct call runs in ihdrain before the window walk) ·
A2 (guard placement, DOSFALSE + ERROR_BAD_NUMBER) · A7 (all four
globals, before any use) · A8 (single exit, restore on it) · A3+X1
(all four constituents curcon-pure from all three contexts;
breaktask stays packet-side; tcclose mid-swaccept repaints a
settled model — the packet's bytes are not yet in wob) · A4 (all 24
fscall sites 5-arg; no caller reads fspkt.res2 after return; {r2}
legal on a stack local; strictly sequential fspkt use incl. the A11
double resolve; locks freed on every arm) · A5 (clearsel's only
state was sello/selhi; the XOR cursor's pixels die under the
unconditional inner RectFill; stale selvo gated by sello=-1) · A6
(landed as prescribed, ?47h-shape preconditions matched — F1 is the
surviving edge, pre-existing) · A9 (IECLASS_CLOSEWINDOW is
doclosew's exact class; ihreport runs only in the handler task, so
DisplayBeep is legal) · A10 (TAB clear first-in-branch, FF clear
covers both dfon arms, ESC8's bytes cannot reach either — cesc
routing verified byte-by-byte) · A11 (pb/tb bounds proven, 563 max
against 620; per-icon belt makes partial arguments impossible under
any dropbuild return; pasteinsert's flag only counts cap-refused
printables; dopaste legally discards the new return) · X3 (the
discard arm IS unreachable: every hide path flushes first) · X4
(altvalid implies a current-grid snapshot, altpop's grid check
cannot fail at doresize entry) · plus the general pass: no new
Mod/DIVS hazards, E-VO one-liner forms valid, $VER bumped.

## Verdict

The campaign held: eleven fixes and five comment items, and the
worst thing the after-pass found is a pre-existing accounting hole
in the same no-shipped-client corner the fix it reviewed was
hardening (F1), plus four comment corrections — two of them in
comments this very campaign wrote (F2, F6): documentation written
at speed rots at speed. F1's one-line-per-site fix and the comment
repairs ship as **1.2.6b9**; F4/F5 are recorded behaviour, kept.

---

# Audit7 — the 1.2.7 config campaign (11.8.26, vs 1.2.7b15 @2317ddd)

An author pass over b4–b15: the palette work (b4–b7), the config
file and its keys (b8–b9), device completion (b10), the resize
repaint fix (b11), the menu's arrow walk and Esc-abort (b12–b13),
the grounding directives and TITLE= (b14), and ICON= (b15).

Every finding below was traced in the source and, where it is a
defect, fixed and proven — F1 in the harness, F2 by inspection —
shipped as **1.2.7b16**.

## Findings

**F1 — a grounding directive at field 4 lost the title AND grounded
nothing.** *(defect, b14 regression, fixed)*

b14 matches `DEFAULTS` and `CONFIG` in `parseopt` deliberately: the
f=0 shortcut only switches a spec to options-only when the first
field names a real option, so without a match `CCON:DEFAULTS/LINES384`
would read `LINES384` as a window Y. But `parsecon`'s field 4 uses
that same return the other way round — `IF parseopt(tok) = FALSE THEN
StrCopy(wtitlebase, torig)` — so a *matched* token is not a title.

And the pre-scan deliberately skips fields 1–4, precisely so a window
called `DEFAULTS` is not silently grounded. Net effect: the token did
nothing at all. `newshell "CCON:0/18/640/130/DEFAULTS"` produced a
window titled `CCON:` — neither grounded nor titled, the name simply
dropped. Titles of `DEFAULTS`, or anything beginning `CONFIG`
(`Configuration`), were legal before b14.

This also made a line in b15's boot checklist untrue as written; it
had been ticked with the batch without being exercised.

Fix: `cfgisdirective()`, the same question with no side effects, and
field 4 asks it before deciding. `IF cfgisdirective(tok) OR
(parseopt(tok) = FALSE) THEN` title. The f=0 shortcut is untouched.
Harness section R, 7 checks including the pure-predicate property
that it grounds and selects nothing.

**F2 — the arrow walk out-ranked a live content search.** *(defensive,
fixed)*

b12's intercept sits above both the close-on-any-key block and
`dorawkey`'s `sbsrch` arrow handling, so with both live the menu
would eat arrows the search owns — the exact hazard the C9 note
warns about.

Not reachable today: `sbenter()` needs `viewoff > 0`, and every way
of scrolling back (plain arrows now walk the menu, Ctrl/Shift arrows
and the wheel all pass through the close block first) closes the
menu before the view moves. But that is an invariant proved three
procs away and one edit from being false. `AND (curcon.sbsrch =
FALSE)` on the intercept costs one term and removes the dependency.

**F3 — `iconload` adds a blocking point at iconify time.** *(recorded
behaviour, no change)*

`iconload` does `CreateNewProc` + `Wait(fhsig)`, blocking the whole
handler process — every CCON window it serves — until the helper
signals. Same shape as `fontload`, but `fontload` blocks during
`openwin` where a window is being built anyway, while this blocks
inside the event drain on a gadget click. Bounded by the same thing
that bounds `fontload`: one filesystem round trip, and audit2 P6's
no-timeout note already covers a wedged volume. Once per console, and
only for a console that both sets `ICON=` and is iconified.

**F4 — `tcadd`'s `dev` arm re-sets bit 0.** *(cosmetic, no change)*

`IF dev THEN p[0] := p[0] OR 5` sets bits 0 and 2, while `isdir`
above has already set bit 0 for the only caller that passes `dev`.
Harmless and idempotent, and the OR-5 is what makes the flag correct
if a future caller ever passes `dev` without `isdir`. Left as is,
noted so the redundancy reads as deliberate.

## Verified clean

- **The ICON= lifetime**, the one that could have crashed.
  `killhandler` closes `iconbase` *before* anything would call
  `FreeDiskObject`, which would be a use-after-close — except
  `ACTION_DIE` refuses while `conlist <> NIL`, so every console has
  already been through `conclose` → `condispose` → `FreeDiskObject`
  by the time the library closes. Sound by construction, and the
  construction is load-bearing: if `ACTION_DIE` ever stopped refusing
  a busy device, this becomes both a leak and a bad call.
- **b11's `tcdrop` in `doresize`.** Everything between it and the
  full clear+redraw is state assignment and model-only work
  (`clearsel` state, `dropeditmirror`, `gridcalc`); nothing needs the
  menu rows painted. The pixels are owed by the redraw regardless.
- **`loadcfgfile`'s allocation.** All four exits `Dispose(fh)` or
  never allocated; `tcfreelock()` on both paths that took a lock.
  Runs per open now rather than once per handler life, so a leak
  here would have compounded per window.
- **Stack.** `parsecon` (~200) → `loadcfgfile` (buf 256 + line 260)
  → `cfgsect` → `cfgapply` (tok 84) → `parseopt` (tok2 84) peaks
  around 1 KB of the 10000-byte E stack. `tcresolve`'s ~350 is
  returned before the read loop, and `cfgpre` returns before
  `loadcfgfile` is called, so neither is additive. Well under
  `savehistfile`'s ~2.5 KB, which still owns the mountlist's
  StackSize note.
- **`tcstem` before first use.** `String(416)` from `coninit` is a
  valid empty E-string, and the Esc path is reachable only while
  `tcactive`, which is only set after the snapshot is taken.
- **`tcgridmove` arithmetic.** `tcmcols < 1` guarded before the only
  `Mod`/`Div`; `tcshown - 1 - c` cannot go negative because
  `c = Mod(n, tcmcols)` with `n < tcshown`. Both proven in harness
  section M, including the 0- and 1-entry grids.
- **`cfgapply`'s ICON copy.** Bounded at 102 into a 104 array with
  room for the terminator.

## Verdict

The config campaign held up better than the palette campaign that
preceded it, and for a structural reason: `parseopt` stayed the
single place an option is applied, so the file and the open string
could not drift, and the whole precedence rule reduced to the order
of three calls. Almost everything the audit could have found there
was found by the harness first — 153 checks over nineteen procs
extracted verbatim.

Both real findings are at the seams, again, and both in the same
place: where a NEW keyword meets the field-4 title rule (F1) or an
EXISTING key-consumption order (F2). That is the third campaign in a
row where the seams were the whole story, which is an argument for
looking there first next time rather than last.

**Audit7 closed**, F1 and F2 fixed as 1.2.7b16, cfgtest 153/153,
**boot-verified 11.8.26** ("All green") — including the field-4 title
case F1 had broken, which is the one the b15 checklist had ticked
without exercising.
