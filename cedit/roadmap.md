# cedit — roadmap

A GUI text editor on cdiff's chassis: tabs for open files, a
line-number gutter, border scrollbars with the system's own arrows,
a status row, and syntax highlighting that knows Amiga E first.

Staged betas, each independently boot-testable, the CFile rhythm.
Legend: `[ ]` open · `[~]` in progress · `[x]` done

## Why this one, and why now (decided 2.8.26)

CygnusEd is alive and sold; GoldED is shareware. Neither properly
knows **Amiga E** — the language most of this family is written in.
That, plus being free and part of the toolchain (cfile manages,
cedit writes, cdiff compares, all three eventually talking over
ARexx), is what cedit is for. Not "the Amiga needs another editor."

The reason it is the next project rather than a someday one: cdiff
already built the hard parts and boot-proved them. The tab bar is
real Intuition bevel-language tabs with pixel hit ranges, the status
row is tooltype- and menu-driven with cached numbers, the gutter
recedes by palette hierarchy, and `drawtext()` is already a
multi-run pen-switching row painter. Syntax colouring is that
painter driven by a lexer instead of by an intra-line diff span.

**Not** a replacement for CFile's internal editor. CFile stays a
keyboard program with an editor aboard; cedit is what `ENV:EDITOR`
points at when you want a window.

## The shape

- **Plain subdirectory of AmigaTools, not a subrepo.** Every tool
  here is a subdir, and the shared chassis makes one repo mandatory
  anyway. CFile13 is the standing warning about forks: it needed a
  whole `PORT-STATUS.md` ledger to track the drift.
- **C, Bebbo's `m68k-amigaos-gcc`**, same flags as cdiff, harness-
  first: pure logic (the lexer) builds on the host AND under vamos,
  and both are run, because of the `-O2` m68k miscompilation cdiff
  found the hard way.
- **Lift, don't fork.** The chassis moves to `ltxgui/ltxwin.{c,h}`
  at top level; cdiff and cedit both build against it. This is the
  `ltxui.m` rule finally firing — the machinery moves to a module
  when a second tool wants it, and a second tool now does.
- **The `Buffer` struct exists from b1**, with one buffer in it, so
  tabs at b4 are a data change and not a rewrite. cdiff can keep
  `view`/`hoff`/scroll-top as globals because it has exactly two
  files; cedit cannot.

## 0.1b0 — the chassis split (cdiff pays, cedit spends)

No cedit code at all. Surgery on a program that renders correctly,
so the gate is that it still does. Split in two on contact with the
file: the leaves lift by pure code motion, the render core does not
(see b0b), and mixing them would put 1,500 unverifiable lines into
one bisection.

### b0a — the leaves — BUILT 2.8.26, AWAITING BOOT

- [x] **`ltxgui/ltxwin.{c,h}` created** (397 lines) and built from
      cdiff's own Makefile via `-I../ltxgui`, not copied — one fix,
      both tools. `.clangd` carries the same `-I` for the editor.
- [x] Moved, verbatim with their build-tag comments: the library
      bases, `win`, `ttoollock`/`ttoolname`, `goodfont`/`tryfont`
      (the b109 font road), `busy` (b102), and the whole b87 icon
      splice — `rdw`/`rdl`/`wrl`/`skipimage`/`ttlocate`/`ttnamed`/
      `iconset` — plus the typed tooltype readers `tteq`/`ttdim`/
      `ttnum`/`ttstr`.
- [x] **`readtooltypes` stays in cdiff**: WHICH tooltypes exist is
      the app's business, the typed readers are the chassis's. That
      is the boundary that will let cedit have its own keyword set
      without touching ltxwin.
- [x] The chassis state keeps its names (`win`, `ttoollock`, …), so
      63 uses of `win` and 8 of `ttoolname` in cdiff.c compile
      untouched. A rename would have turned a code move into a
      160-site edit.
- [x] cdiff.c 4,246 → 3,968 lines. Builds clean at `-O2 -Wall`,
      `make test` ALL GREEN on host and under vamos, and TEXT mode
      runs correctly under vamos — which also proves the moved
      library-base definitions still keep libnix's auto-open modules
      out of the link (vamos has no intuition.library to open).
      Binary 77,016 → 77,108 bytes, +92 from the separate
      translation unit.
- [ ] **BOOT GATE:** window opens, `FONT=` still opens the font
      asked for, the busy pointer still appears on a slow load, and
      the Settings menu's STATUSBAR/FASTSCROLL toggles still write
      back to the icon. Those four exercise every line that moved.

### b0b — the render core (NEXT)

Not code motion. `drawstatus`, `updscrollers`, `paintscroll`,
`scrollto`, `flushpaint`, `proptrack`, `sethoff` and `arrowstep` all
call back into cdiff's content model — `vcount()`, `vtop()`,
`htotal()`, `drawone()`, `drawrows()` — so the scroll engine cannot
move without an interface. That interface is the point: cdiff's
model is Rows and DLines, cedit's is a Buffer, and the chassis must
not know which.

- [ ] A small callback struct the app fills in at init: total rows,
      the active scroll top, total columns, paint-one-row,
      paint-all-rows, compose-the-status-string.
- [ ] Then the move: `rp` and the cell metrics, the grid geometry,
      the border scrollbars end to end (`mksysi`, `mkarrow`,
      `addscrollers`, `updscrollers`, `proptrack`, `arrowstep`), the
      scroll engine (`paintscroll`, `scrollto`, `flushpaint`,
      `inputwaiting`, the typed dirty flags), the row-paint
      primitives (`drawtext`, `drawnum`), the tab bar, the status
      row, window/screen open+close, iconify/uniconify, and the
      requesters (`erq`, `centerreq`, ASL `askfile`).
- [ ] **cdiff keeps** `diff.c`, the tree walker, the intra-line
      span, its row model (`drawside`, `drawrow`, `drawdirrow`,
      `drawline`, hunks, the diffstat), find, and its menus.
- [ ] **Three widenings** — the risky part, because each changes the
      signature of a function that currently renders right:
      1. `drawtext()` takes a char buffer plus a **run list**
         (start, pen, bg), not a `DLine*` and one highlight span.
         cdiff's intra-line highlight becomes a 3-run list; the
         lexer will hand it N. The b66 rule holds: every pixel
         written exactly once, runs adjacent and never overlapping.
      2. `drawtabs()` takes an array of labels and returns hit
         ranges, instead of knowing view ids 0–3.
      3. `drawstatus()` takes the string the app composed, instead
         of reaching into the diffstat. b82's lesson travels with
         it: whatever fills that string must be cheap or cached.
- [ ] **GATE: cdiff boot-green, visually unchanged.** Same window,
      same tabs, same scrolling, same status row, on the same
      screenshot pair as before the split. Nothing about cedit
      begins until that passes.
- [ ] Scrolling is the thing to watch hardest here: b62's
      coalescing, b91's `WaitBlit` barrier and b93's choice of
      `ScrollRaster` over `ScrollWindowRaster` are all in the code
      being moved, and all three were paid for in builds.

## 0.1b1 — one buffer, read-only

- [ ] `Buffer`: line table (the CFile `edensure`/`edgrow` model —
      doubling table, per-line allocation, no line-length cap),
      cursor, scroll top, `hoff`, dirty flag, path, and a
      per-line lexer-state byte reserved but unused.
- [ ] Load a file, display it in the lifted chassis: gutter,
      scrollbars, status row, mouse wheel, horizontal pan.
- [ ] **GATE: it opens a file and scrolls exactly like cdiff does.**
      If the chassis lift was clean this is nearly free, and that is
      the point of gating here.

## 0.1b2 — editing, and save

- [ ] Cursor movement, insert, delete, backspace, newline, join.
- [ ] Dirty flag, title/status marker, save, save-as.
- [ ] cdiff's `ENV:EDITOR` launch now has something to point at.
- [ ] GATE: edit and save a real file on target, re-diff it in cdiff
      and see exactly the change you made.

## 0.1b3 — undo

- [ ] Undo/redo stack per buffer. Coalesce a typing run into one
      entry — the same instinct as coalescing a held-key input
      burst.

## 0.1b4 — multi-buffer, and closeable tabs

- [ ] N buffers; tabs labelled with basenames, ellipsised when
      narrow.
- [ ] A close box per tab: a second hit range tested before the tab
      body, drawn in the same bevel primitives so it follows the WB
      palette.
- [ ] Closing a dirty buffer prompts; so does quitting with any
      dirty buffer.
- [ ] **Overflow** — three tabs never outgrow a PAL Hires window,
      twelve open files do. What cdiff does today is clip the last
      tab to the window edge and give any that still don't fit a
      zero-width hit range (`tabx[i] = tabe[i] = winr`) — correct
      for a fixed three, wrong here, because a tab you cannot reach
      is a file you cannot reach. Scroll the bar, or a `»`
      more-indicator. Decide before the array shape is fixed.

## 0.1b5 — the E lexer, behind a toggle

- [ ] One state byte per line (normal / in-block-comment /
      in-string). An edit re-lexes from that line until the state
      byte matches what it was — almost always one line. A scroll
      lexes only the rows that entered.
- [ ] E first: `->` line comments, `/* */`, `'` strings, `PROC`/
      `ENDPROC`/`DEF`/`OBJECT`/`PTR TO`/`HANDLE`. Corpus: 31,906
      lines of E in cfile, ccon and cfile13 alone (39,183 across the
      family), lexed on the host by the harness before anything
      boots.
- [ ] **Pen map chosen by screen depth, not by taste.** On a
      4-colour WB there are about three usable pens — comment,
      keyword, everything else. `OPENSCREEN=` + `SCREENDEPTH=3`
      gives eight and a real scheme fits. Same lesson as "no dark
      grey on a 4-colour WB", generalised.
- [ ] **`HIGHLIGHT` toggle from day one, and measure it.** Plain row
      = one `Text()` call; a highlighted C row = five to eight.
      Count them on the 020 before highlighting is allowed to
      default on. If the number is bad it goes off by default, or
      it goes entirely — the Myers rule.

## Later, not promised

ASL open/save wired to the menus · find and replace (cdiff's find
is already lifted) · C and 68k asm lexers · block select and
indent · an ARexx port, so CFile can hand it a file and cdiff can
be told to compare what was just saved · Kickstart 1.3 is not even
a question here — the chassis is V36+ throughout.

## Open questions

- **Gutter regrow.** When typing pushes 999 lines to 1000, does the
  gutter widen and shove the text right? Leaning: size once at load
  with a minimum of 4, regrow only on save or reload — text that
  shifts under the cursor mid-keystroke is worse than a wasted
  column.
- **How much of `drawside` is really cdiff's?** The bar fill and
  gutter call look generic; the diff colouring does not. May be
  worth splitting one level lower during b0, may be worth leaving
  alone until b1 proves what cedit actually needs.
