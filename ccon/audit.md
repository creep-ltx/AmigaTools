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
boot-green in one day (b4–b8).** What remains is the 1.2.6 release
ladder, not audit work.

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
