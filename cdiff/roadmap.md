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

- [x] **Changed rows as BAR rows** (built 1.8.26, deployed): pen-3
      fill + white text, the CFile selection-bar look — the
      screenshot showed pen-3 text on WB gray barely reads, and an
      empty-line insert is now a visible bar, not a naked marker.
- [ ] Line numbers in the gutter (both sides).
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
