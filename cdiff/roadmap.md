# cdiff — roadmap

Staged betas, each independently boot-testable, the CFile rhythm.
Legend: `[ ]` open · `[~]` in progress · `[x]` done

## 0.1b1 — engine + first window

- [x] Patience diff engine, pure logic (diff.c), harness-proven:
      host cc + m68k-under-vamos, 210 cases + tamper control, ALL
      GREEN 1.8.26. Stress: cfile.e vs cfile13.e in 2.5s (vamos).
- [x] TEXT mode — unified-style stdout, doubles as the vamos road.
- [x] GUI first cut: WB-screen window, side-by-side rows, custom
      Text/RectFill drawing, keyboard scroll, hunk jump (n/p).
- [x] **Boot gate: FIRST RUN GREEN 1.8.26** (his screenshot) —
      window up on WB, sides aligned, del/ins rows marked, the
      trailing-empty-line insert rendered honestly (a naked `>` —
      correct, but unreadable; fixed in b2). Full-file scroll and
      hunk-jump eyeballing still wanted. KS1.3 curiosity boot —
      OpenWindowTags is V36+, so 1.3 needs the CFile13 treatment
      (plain OpenWindow + NewWindow) — parked, not promised.

## 0.1b2 — the daily-driver polish

- [x] **Changed rows as BAR rows** — **BOOT-GREEN 1.8.26** (second
      screenshot): pen-3 fill + white text, the CFile selection-bar
      look; the empty-line insert reads as a solid bar. The
      screenshot-fix-screenshot loop closed in one round.
- [x] Line numbers in the gutter (both sides), width sized to the
      longer file, dropped whole when the window is too narrow;
      b4: gutter recedes by palette hierarchy (his ask - no dark
      grey on a 4-colour WB): blue-on-gray plain, black-on-blue
      under the bar.
- [~] **b5: Workbench start + the Project menu** (his ask): argc==0
      opens the window empty; GadTools menu (Open Files... one by
      one / Open Left / Open Right / Quit), ASL requester that
      remembers its drawer, errors via EasyRequest (a WB start has
      no shell). Files swappable mid-session from a CLI start too.
      LESSON: base pointers must be strong-initialized (= NULL) or
      libnix auto-open drags gadtools/asl into startup and the
      binary dies where they don't exist - vamos caught it, the
      TEXT road is the regression gate that matters.
- [x] **b7: TABS** (his ask, after loading real .e files - "a
      chopped-off version of the two files"): Both / Left / Right,
      the single tabs full-width with per-line change bars; 1/2/3
      or Tab switches, the bar is clickable; a tab switch carries
      the scroll position through the row list so all three views
      stay anchored on the same spot.
- [x] **b8: the tab bar goes GUI** (his ask) - Intuition bevels in
      the screen's DrawInfo pens, active tab filled and breaking
      the base rule open.
- [x] **b9: the edit road + F5** (his ask "what do we do when we
      want to edit") - Edit menu hands a side to ENV:EDITOR (Ed
      fallback) via SystemTags + AUTO console; rediff-in-place
      keeps view and position. Reload for external changes.
- [x] **b10: Shift+Tab cycles back** - the keymap lesson: Shift+Tab
      has NO vanilla translation, it falls through as RAWKEY 0x42.
- [x] **b11: mouse wheel** - NewMouse RAWKEY 0x7A/0x7B, 3 lines a
      notch, shift = page.
- [x] **b12: the R1 scroll rule** (his find: "artifacts/stutter...
      maybe learn from CCon and CFile") - a step was drawpage();
      now ONE ScrollWindowRaster of the content rect + only the
      entering rows, tab bar untouched by scrolling, jumps repaint
      content only. **BOOT-GREEN 1.8.26: "Amazing, what a
      difference."** The campaign lesson holds: blit count is the
      metric, and it transfers to a new codebase in one build.
- [ ] Horizontal scroll (left/right keys) for long lines.
- [ ] Window resize (WFLG_SIZEGADGET + IDCMP_NEWSIZE re-grid).
- [ ] A status row: hunk i/N, +a −d, position %.
- [ ] ScrollRaster for ±1 row scroll + the R1 two-row rule —
      the CFile campaign lesson, applied from birth this time.

## 0.1b3 — directory mode

- [ ] `cdiff DIR1 DIR2` — tree compare: added / missing / differing
      (size+date first, content hash on demand), drill into a file
      diff with Enter, Left back out. The CFile two-pane instincts,
      pointed at trees.

## 0.1b4 — engine deepening

- [ ] Myers middle-snake inside replace blocks (the non-unique
      fallback today) — bounded memory, better alignment in
      repetitive code.
- [ ] Intra-line change highlight on `|` rows (char-level diff of
      the paired lines).

## Parked

- Merge/copy-hunk actions (left→right) — an editor's
  responsibilities creep in; decide after directory mode.
- MUI/ReAction front-end — GadTools-free custom draw is serving.
