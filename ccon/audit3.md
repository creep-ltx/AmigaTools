# CCON v1.2 — post-release audit (audit3)

Full read of `ccon-handler.e` (6823 lines, $VER `ccon-handler 1.2 (23.7.26)`,
tag `ccon-1.2` @ 2015ef3) plus `CCON-mountlist`, `ccon.doc`, `tests/`.
Read-only: nothing in this pass has been changed.

Numbering continues the earlier campaigns' style but in a fresh series (C1..)
so it cannot be confused with audit.md's B/P/H items.

---

## Verdict

The architecture is genuinely good and the two previous audit campaigns did
real work — the trust boundaries (`conok` at every packet entry), the
whole-or-nothing queue discipline (`inqroom`), the reflow harness, the
alt-screen snapshot, the B1/B7/B8 fixes: these are not the habits of a hobby
handler. What's left is mostly at the **edges the 1.2 features opened and the
old invariants never got re-checked against**: iconify bypassed two rules the
rest of the file obeys, and one invariant that a code comment *claims* to
enforce is not actually enforced.

Two findings can corrupt the heap. Both are new-ish surface, both are
narrow-trigger, neither would show in normal soak testing — which is exactly
why they survived.

| Severity | Count | Items |
|---|---|---|
| Heap corruption | 2 | C1, C2 |
| Use-after-free | 1 | C3 |
| Wild read | 1 | C4 |
| Silent data loss | 2 | C5, C6 |
| Resource leak | 1 | C7 |
| Correctness (visible, non-fatal) | 3 | C8, C9, C10 |
| Performance | 4 | P1..P4 |
| Consistency / dead code | 5 | X1..X5 |

---

## Correctness

### C1 — `sbmax` is never checked against `rows`: heap corruption with `LINES=n`

**Where:** `openwin()` 2126-2134, every ring accessor (`visrow` 2691,
`sarow` 2698, `ssrow` 2706, `swrow` 2724, `selvidx` 2954, `redraw` 3529,
`inschars` 4073, `delchars` 4104, `drawmodelcells` 4566, `drawmodelrow` 6556).

The model depth is chosen from `LINES=n` with a floor of 100 and a ceiling of
`SBMAXCAP`, and the comment at 2124 states the intent plainly:

> Floor 100: the visible grid must always fit inside the ring.

100 is not that guarantee. `gridcalc()` has already run at that point and
`curcon.rows` is known, but it is never consulted. Nothing anywhere — not
`openwin`, not `doresize` — enforces `sbmax > rows`.

Every ring accessor corrects the wrap with a **single subtraction**:

```e
i := curcon.sbtop + r
IF i >= curcon.sbmax THEN i := i - curcon.sbmax
ENDPROC curcon.sb + Mul(i, curcon.cols)
```

With `sbtop` at its maximum `sbmax-1` and `r = rows-1`, the pre-correction
index is `sbmax + rows - 2`; after one subtraction it is `rows - 2`. That is
still out of range as soon as **`rows >= sbmax + 2`**, and `sb` is only
`sbmax * cols` bytes. `outchr()` then writes `m[cx]` past the end of the
plane, into whatever E's heap put next to it.

**Reachable:** `CCON:0/0/-1/-1/LINES100` on a 1280x1024 RTG screen is 126 rows
against a 100-row ring. Any tall window plus a deliberately small `LINES` does
it, and `LINES` is documented as the knob for small machines, so a user
following the docs on a big screen is the exact victim. Not reachable at the
512 default (you'd need a 4096px-tall window).

`doresize()` has the same hole from the other direction: it never revisits
`sbmax`, so growing a `LINES=100` window past 102 rows walks into it too.

**Fix:** after `gridcalc()`, `IF v < (curcon.rows + 2) THEN v := curcon.rows + 2`,
and re-apply on the grow path in `doresize()` (reallocating the planes there,
or refusing to grow the grid past the ring). Belt-and-braces: make the wrap
corrections loops (`WHILE`, as `rfslot()` and `sbrowidx()` already correctly
do) so a future violation degrades to a wrong row rather than a wild write.

---

### C2 — Iconify restores stale geometry, leaving the model at the wrong stride

**Where:** `reopenwin()` 1875-1889; `doresize()` 2555.

`reopenwin()` opens the window with `WA_WIDTH, curcon.pww` /
`WA_HEIGHT, curcon.pwh` — and `pww/pwh/pwx/pwy` are **only ever written by
`parsecon()`**, i.e. they are the geometry from the open string. Verified: no
write to any of the four outside `coninit`/`parsecon`/`openwin`'s `-1`
resolution.

So a user who resizes or moves a CCON window and then iconifies gets it back
at its *original* size and position. That alone is a visible bug. The
dangerous half is what it does to the model:

1. Window opens at 80 cols; `sb/sa/ss` allocated with stride 80.
2. User drags it narrower; `doresize()` reflows to stride 60 and sets
   `curcon.cols := 60`.
3. RightAmiga+I; `hidewin()` closes the window, keeps everything else.
4. Click the AppIcon; `reopenwin()` opens at `pww` = the original width,
   `gridcalc()` sets `curcon.cols := 80` — **but the planes are still stride
   60 and nothing reallocates or reflows.**
5. `redraw()` reads `sb + Mul(idx, 80)` out of a `sbmax * 60` buffer — out of
   bounds by up to a third of the allocation, and every subsequent `outchr`
   writes there.

**Reachable:** resize-then-iconify is completely ordinary use. This is the one
I'd fix first on trigger frequency.

**Fix:** in `hidewin()`, snapshot the live window before closing —
`pwx := win.leftedge`, `pwy := win.topedge`, `pww := win.width`,
`pwh := win.height`. That fixes the stride mismatch *and* the
"window jumps back" complaint in one line each. (Guard: `reopenwin()` should
still verify `cols`/`rows` against the model and reflow or reallocate if they
disagree, since a screen-mode change between hide and restore can also move
them.)

---

### C3 — `doappmsg()` trusts a console pointer without `conok()`: use-after-free

**Where:** `doappmsg()` 1807-1822.

```e
IF am.type = AMTYPE_APPICON
  c := am.userdata
  IF c AND c.appicon        -> c is dereferenced unvalidated
```

Every other place in the file that receives a console pointer from outside
validates it against the list first — `dopkt`'s END/WRITE/READ (1136, 1164,
1177), `conbysender` (963), `ihdrain` (5782), `timerexpired` (1087). The
AppMessage path is the one exception, and it is the one path whose pointer can
outlive its console:

- An iconified console is windowless, so `ACTION_END` with `opens <= 0` takes
  the `ELSE conclose(c)` arm at 1158 — an iconified console **can** be
  disposed.
- `main()` drains the window ports (where the close lands) **before** it drains
  `wbport` (683-741). An AppMessage double-clicked in the same loop pass is
  processed after the console is `Dispose`d.
- `c.appicon` then reads freed memory, and if it reads non-zero,
  `RemoveAppIcon()` is called on garbage.

**Reachable:** double-click the AppIcon at the moment the client holding the
last handle exits. Narrow, but it is a genuine dangling dereference and the
codebase already has the exact guard it needs.

**Fix:** `IF conok(c) AND c.appicon`. One word.

---

### C4 — `dopaste()` chunk walk: B11's fix stops at negative, misses the overflow

**Where:** `dopaste()` 3293-3321.

B11 correctly killed the infinite loop from `sz < 0`. But `sz` is read straight
from an untrusted clipboard and the step is unguarded on the other side:

```e
i := i + 8 + sz + (sz AND 1)
```

`sz = $7FFFFFF0` is *positive*, passes the B11 guard, and overflows `i` to a
negative value. `(i + 8) <= got` is then still true, so the loop continues with
`lw := clipbuf + i` — a pointer well before `clipbuf` — reading garbage as the
next chunk id/size. `take := Min(sz, got - i - 8)` is likewise nonsense.

Same class of hole B11 closed, same line. **Fix:** clamp against the buffer, not
just against zero: `IF (sz < 0) OR (sz > (got - i - 8)) THEN i := got`.

---

### C5 — Pasting into a raw client silently truncates at ~2 KB

**Where:** `dopaste()` 3311-3314, `injectbyte()` 3330, `enqueue()` 6771.

In raw mode (or with `PASTEEXEC`), the whole clip is pushed through
`injectbyte` → `enqueue` in one tight loop, and `inputarrived()` is called
**once, afterwards** (3323). `enqueue` silently drops when the ring is full, and
`INQMAX` is 2048. So a paste into Ed larger than ~2047 bytes loses everything
past the cap, with no beep, no hint, no error.

This is also the one place that ignores the B3 whole-or-nothing discipline the
rest of the file follows so carefully (`sendreport`, `sendcpr`, `ihreport`,
`rawcsikey` all ask `inqroom()` first).

**Fix:** interleave — call `inputarrived()` whenever the queue passes a
high-water mark so the blocked reader drains it, or feed the tail through the
existing `pasteq` mechanism the cooked path already has.

Related, lower stakes: the cooked commit path (`dovanilla` code 13, 5305-5308)
also enqueues the line byte-by-byte with no `inqroom()` check. `LINEMAX` is 400
against a 2048 ring so it is hard to hit, but it is the same inconsistency.

---

### C6 — `dowrite()` discards output on `wq` overflow while iconified

**Where:** `dowrite()` 1317-1325.

```e
ELSE
  ReplyPkt(pkt, pkt.arg3, 0)   -> overflow (rare): accept + discard output
```

Replying with the full byte count tells the writer "all written" and throws the
bytes away. `WQMAX` is 8, and because parked writes are unreplied, that is 8
*concurrent writer tasks*, so it really is rare — but the failure mode is silent
corruption of a transcript rather than backpressure. Replying `-1` with
`ERROR_NO_FREE_STORE` (what the windowless path at 1328 already does) would at
least be honest.

---

### C7 — `diskfont.library` is opened and never closed

**Where:** `fonthelper()` 1752; `killhandler()` 756-834.

```e
IF diskfontbase = NIL THEN diskfontbase := OpenLibrary('diskfont.library', 36)
```

`killhandler()` closes `keymapbase` and `workbenchbase` and is scrupulous about
device/port/signal ordering — but `diskfontbase` is never closed. Any handler
that ever served a `FONT` option leaves diskfont.library's OpenCnt permanently
raised after `ACTION_DIE`, so it can never be expunged. Small, but it is the
only outlier in an otherwise complete teardown.

**Fix:** `IF diskfontbase THEN CloseLibrary(diskfontbase); diskfontbase := NIL`
in `killhandler()`. (Safe: `fontload()` blocks on `Wait(fhsig)` so no helper can
be mid-flight when the loop exits.)

---

### C8 — `reopenwin()` failure strands the console with no way back

**Where:** `doappmsg()` 1811-1818.

The AppIcon is removed *before* `reopenwin()` is attempted, and `reopenwin()`
can fail (`IF curcon.win = NIL THEN RETURN`, 1891 — out of memory, or the public
screen it wants is gone). The console is then windowless **and** iconless: no
AppIcon to click, no window to close, and `dowrite` answers
`ERROR_NO_FREE_STORE` forever. The only exit is the client giving up.

**Fix:** re-`AddAppIconA` if `reopenwin()` returns with `win = NIL`.

---

### C9 — `snaplive()` does not leave scrollback-search mode

**Where:** `snaplive()` 3688, `dovanilla()` 5210.

A client write while `sbsrch` is active calls `snaplive()`, which resets
`viewoff` and repaints live — but leaves `curcon.sbsrch` TRUE. The next
keystroke therefore takes the `sbsrch` branch and `sbfind()` yanks the view back
to a match. Visible weirdness ("my window jumped"), no memory consequence.

**Fix:** `curcon.sbsrch := FALSE` in `snaplive()` (or call `sbexit()`).

---

### C10 — `edcap()` can go negative, and four trim loops then run away

**Where:** `edcap()` 4378; trim loops in `srfind` 4853, `sbfind` 5011,
`sgall` 5137, `histload` 5199.

```e
PROC edcap() IS Min(LINEMAX - 1, Mul(curcon.rows, curcon.cols) - curcon.ancx - 1)
```

With `rows = 1` and a pending-wrap anchor (`ancx = cols`, legal and explicitly
supported everywhere else), this is `-1`. The trim idiom is:

```e
WHILE StrLen(curcon.ebuf) > edcap()
  SetStr(curcon.ebuf, StrLen(curcon.ebuf) - 1)
ENDWHILE
```

At length 0 against `edcap = -1` the condition is still true, so it calls
`SetStr(ebuf, -1)` — which writes the terminator at `s[-1]`, inside the E-string
header — and then keeps going, walking backwards through the heap forever.

`rows >= 2` makes `edcap >= cols - 1 >= 1`, so this needs a one-row grid. Our
own `WA_MINHEIGHT` of 60 prevents that for owned windows at any sane font, but a
**borrowed window** (`WINDOW0xADDR`, which is exactly what CTerm's frame handoff
uses) is adopted at 1965 with no size floor at all.

**Fix:** floor it — `Max(0, ...)` — and factor the four copies into one
`edfit()` helper. The duplication is how one of them would get missed anyway.

---

## Performance

### P1 — `scrollview()` does a full-window repaint per wheel tick

**Where:** `scrollview()` 3584-3598.

Every scroll — including a three-line mouse-wheel tick — calls `redraw()`,
which repaints **every row** through `drawmrow()`'s per-row attribute-run scan,
and then `settitle()` → `SetWindowTitles()`, which makes Intuition refresh the
title bar. On a 25-row window that is ~25 rows of work to expose 3.

This is the biggest remaining win in the file. `ScrollRaster` the retained rows
and draw only the newly exposed ones (the code already does exactly this in
`screenscroll`, `inslines`, `dellines`, `scrollup`, `scrolldown`), and skip
`settitle()` when the `[scrollback -n]` digits have not actually changed.
Roughly an order of magnitude on wheel scrolling on 68k.

### P2 — `render()` does not hoist `curcon`, though the audit-P4 procs do

**Where:** `render()` 4182-4361, `outchr()` 3739.

audit2 P4 correctly hoisted `curcon` into a local `k` in `drawmrow`,
`drawselrow` and `drawmodelcells` — because E reloads the global *and then* the
field on every `curcon.x` reference and cannot hoist that itself. `render()` is
the hotter proc (it runs on every byte of output) and never got the same
treatment: its printable-run loop touches `curcon.cx`, `.cols`, `.rp`, `.left`,
`.cw`, `.topy`, `.ch`, `.baseline`, `.sb` on every pass. audit P1 hoisted `at`
and `sty` out of the per-cell loop but stopped there.

Same change, same proc shape, measurably the hottest path in the console.

### P3 — `histpersist()` blocks the whole handler on every Enter

**Where:** `histpersist()` 6355, `histappend()` 6311, `fscall()` 5932.

Every committed command does `tcresolve('L:')` + FINDUPDATE + SEEK + WRITE + END
— five synchronous packet round-trips — and `fscall()`'s `WaitPort` blocks the
handler **process**, i.e. *every* CCON window it serves, not just the one that
pressed Enter. On a floppy-backed or network `L:` that is a per-command stall
across all windows. Once every 200 commits it is a full rewrite instead.

Not wrong (it is a deliberate, documented trade for crash-safety), but it is the
one design decision in the file whose cost scales with someone else's hardware.
Batching (append on a timer, or on N commits) would keep most of the safety at a
fraction of the cost.

### P4 — Resize doubles peak model memory

**Where:** `reflowring()` 2417-2427.

The three new planes are allocated before the three old ones are freed, so a
width change momentarily holds `2 * sbmax * cols * 3` bytes. At the default
512×80 that is 240 KB peak (fine). At `LINES5000` on a 200-column window it is
~6 MB peak against 3 MB steady — and the failure path is graceful (scrollback is
dropped), but "resize my big window and lose my scrollback" is a poor outcome on
the machines that asked for `LINES5000` in the first place. A row-at-a-time
reflow through a single-row scratch buffer would avoid it.

Also `fscall()`'s missing timeout (audit2 P6) is still open and still means a
wedged filesystem freezes every CCON window. Deliberately parked, correctly
documented — I'd only note that the exposure grew when history persistence moved
onto the per-Enter path, since the number of `fscall()` sites a normal session
touches went from "when you press Tab" to "every command".

---

## Consistency and code health

**X1 — Dead code in `dorawkey()`, 5582-5592.** The `sbsrch` arrow check appears
twice; the first block `RETURN TRUE`s for exactly the codes the second tests, so
the second is unreachable. Leftover from the two-pass-trap fix.

**X2 — Ring wrap correction is written two different ways.** `rfslot()` (2340)
and `sbrowidx()` (4935) loop; the other ten sites do a single `IF`. The looping
form is the correct one and the single-`IF` form is what makes C1 fatal rather
than merely wrong. Pick one.

**X3 — `condispose()`'s plane frees are documented as unreachable** (996-1005,
audit2 H3). That reasoning is sound and I'd keep them — but the same argument
does not hold for `c.tf`: `closewin()` closes the font on the *window* path
only, and `condispose` is the sole net for a console disposed straight from
`dofind`'s failure arm (1697). Fine today because `openwin` failure returns
before the font is opened; worth a comment saying so, since it is load-bearing.

**X4 — SGR is capped at four parameters.** `render()` clamps `cnp` at 3
(4265), so `ESC[0;1;31;40;7m` merges its 5th parameter into `cpar[3]` and the
earlier one is lost. Nothing in the Amiga tool set emits that, but it is a
silent spec gap rather than a documented limit.

**X5 — `cols` is capped at 255** (`gridcalc` 1731) because `rowbuf` is 256.
A 1600px-wide window at a 6px font is 266 columns; the right edge is silently
unusable. The cap is correct given the buffers — it just is not in `ccon.doc`.

**Docs:** `ccon.doc:41` describes `LINES=n` as asking for *more* ("up to 5000"),
which undersells it — it is equally the knob for asking for *less*, which is
how the source describes it and is precisely the configuration C1 punishes. Worth
a sentence, and worth stating the 100-line floor.

**Mountlist / tests:** no issues found. The four-stanza `CCON-mountlist` is
consistent with `devname` handling and the doc's takeover recipe; `tests/`
carries the four harnesses the comments reference, and the sources match what
the code claims they proved.

---

## Great / Good / Meh / Bad / Terrible

### Great

- **The no-DOS rule, and the two escapes from it.** Recognising that `DoPkt`
  waits on the same port your clients send to, then building *two* correct
  escapes — hand-rolled exec-level packets on a private reply port (`fscall`),
  and a throwaway helper process with its own `pr_MsgPort` for `OpenDiskFont`
  (`fonthelper` + the 24-byte poked `NP_Entry` stub) — is the strongest thing in
  this codebase. The stub is correct down to the even-alignment of the immediate
  and the `CacheClearU()`.
- **The input.device chain instead of IDCMP.** Diagnosing four freezes as a
  UserPort ownership fight and answering it by taking keys where console.device
  takes them, at pri 20 so menu picks arrive pre-digested as `IECLASS_MENULIST`
  — that is the right answer, not a workaround, and it is what made Ed work.
- **`armed` + `conok` + Forbid-bracketed list mutation.** The concurrency story
  between the main task and input.device's task is genuinely airtight: `armed`
  gates capture, `conok` re-validates on drain, `conclose` scrubs ring slots
  *and* the drain re-checks because a later console could reuse the address.
  That last sentence is the kind of thing people get wrong; it is right here.
  (C3 is the single place the discipline was not applied.)
- **B7's soft-wrap plane.** Identifying that the model could not distinguish a
  wrapped row from a newline-terminated one, adding one byte per *row* to fix it,
  and developing the reflow on data in `reflowtest.e` before touching the
  handler. Four defects caught in the harness instead of on hardware.
- **Comments that record what was disproved.** The `eraseedit` B1 note — three
  attempts, why clearing `edext` was over-reach, what the A/B pair showed — is
  more valuable than the code it annotates.

### Good

- Whole-or-nothing report queuing (`inqroom`), and the reasoning about why a
  truncated CSI is worse than a dropped one.
- The alternate-screen snapshot (`altsave`/`altrestore`) with the `rawscr`
  overflow accounting — no other Amiga console does this.
- `conbysender`'s three-tier lookup, and B6's decision to fail `DISK_INFO`
  rather than hand a stranger's window to a guess.
- `parseopt`'s fail-closed prefix branches, so a title that merely *starts* with
  a keyword stays a title.
- ACTION_DIE teardown ordering: interrupt out before E frees its memory,
  CloseDevice before DeleteIORequest before DeleteMsgPort, `ihdevopen` tracked
  separately because `ihreq` cannot answer "did OpenDevice succeed".
- Deferred `CloseWindow` via `closereq` — never close a window while draining
  the port it owns.

### Meh

- **`ghist` costs ~82 KB at mount time, unconditionally** — 200 × `String(400)`
  allocated in `main()` before any window exists, and paid even by a `CON:`
  stanza that will only ever serve one window. Lazy allocation, or sizing the
  strings on demand, would give most of it back on the 2 MB machines the
  `LINES` knob exists for.
- `ihdrop` is write-only by design. Defensible, but a `CSI`-reportable counter
  or a title-bar hint would cost nothing and make "keys went missing" diagnosable
  in the field rather than under a debugger.
- `tcscancmd()` and its whole Path/resident-list plumbing are compiled in and
  unreachable (parked at 6423). Correctly documented, but it is ~50 lines of
  dead weight in a handler that counts bytes elsewhere.
- All AppIcons are named `'CCON'` with the same image, so several iconified
  windows are indistinguishable on the desktop. `wtitlebase` is right there.
- `ACTION_SEEK` replies `DOSTRUE` where the comment says "-1 result" — the same
  value, but the comment and the code read as if they disagree.

### Bad

- **C1 and C2**: two paths to heap corruption, both from an invariant that is
  stated in a comment and not enforced in code. C1's comment ("the visible grid
  must always fit inside the ring") is the more troubling of the two, because
  the file *knows* the rule and simply does not check it.
- **C3**: the one trust boundary out of six that skipped `conok`, on the one
  path whose pointer can outlive its object.
- **C5**: raw paste truncating at 2 KB in silence, in a file that is otherwise
  rigorous about never truncating a message.
- The 1.2 iconify feature reused none of the existing validation habits —
  C2, C3 and C8 are all "iconify did not check what the rest of the file
  checks". Worth treating as one lesson rather than three bugs.

### Terrible

Nothing. Genuinely — there is no code in here I'd call bad craft. The worst
findings are omissions at new seams, not confusion about what the machine is
doing. The closest thing to a systemic worry is that **`fscall()` has no timeout
and now runs on the per-Enter path** (audit2 P6, deliberately parked): one
wedged mount freezes every CCON window on the system, including whichever one
would have shown you the error, and 1.2 made that path far hotter than it was
when the decision to park it was taken. That is worth re-deciding, not because
the original reasoning was wrong but because the inputs to it changed.

---

## Suggested order

1. **C2** — highest trigger frequency (resize + iconify is ordinary use), and
   the fix is four assignments in `hidewin()`.
2. **C1** — worst consequence; two lines in `openwin` plus the `doresize` grow
   path.
3. **C3** — one word (`conok`).
4. **C8** — a few lines, same proc as C3.
5. **C5**, **C4**, **C7**, **C9**, **C10**, **X1**.
6. **P1** (wheel scrolling), then **P2** (`render` hoist) — both are
   mechanical, both are the largest remaining speed on the table.
