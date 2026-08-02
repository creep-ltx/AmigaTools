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

### b0b — the render core — BUILT 2.8.26, AWAITING BOOT

Not code motion, and that was the whole point. `drawstatus`,
`updscrollers`, `paintscroll`, `scrollto`, `flushpaint`, `proptrack`
and `sethoff` all reached into cdiff's content model, so the engine
could not move without an interface — and that interface is what
lets cedit hand the same engine a Buffer.

- [x] **The `LtxApp` vtable** — eight questions, the entire surface
      between chassis and app: `rowcount`, `toprow`, `colcount`,
      `paintrow`, `paintrows`, `pageall`, `statustext`, `flushapp`.
      cdiff fills it with `vcount`/`vtop`/`htotal`/`drawone`/
      `drawrows`/`drawpage` and two small adapters; `ltx_setapp()`
      runs first thing in guimode, and every chassis painter
      no-ops until it has been called.
- [x] **The three widenings**, all done:
      1. `ltx_drawruns()` takes N runs, not three. cdiff's b97
         intra-line span became a 3-run list built by the same
         arithmetic (source columns → visible, same clamps, empty
         span still collapsing to one full-width run). Tab
         expansion split off into `ltx_expandvis()`, which is what
         cedit's lexer will feed.
      2. `ltx_drawtabs()` takes labels and an active INDEX and
         fills `ltx_tabx`/`ltx_tabe`, instead of knowing view ids
         0–3. What the tabs MEAN stayed in cdiff.
      3. `drawstatus()` takes the app-composed left-hand text and
         owns the padding, the right-aligned percentage and the
         rule above. cdiff's hunk binary-search moved into its
         `statustext` adapter, still lazily rebuilt.
- [x] Also moved: the grid (`ltx_calcgrid`), the screen pens, the
      border scrollers end to end, the scroll engine with b62's
      coalescing / b91's `WaitBlit` / b93's `ScrollRaster` intact,
      and screen+window+font opening behind an `LtxWinSpec`.
- [x] **What stayed cdiff's:** `diff.c`, the tree walker, the
      intra-line span, the row model, find, the menus, and the
      composition of a page. Chassis = widgets, app = composition.
- [x] cdiff.c 3,968 → 3,229 lines; ltxgui 397 → 1,507. Clean at
      `-O2 -Wall`, `make test` ALL GREEN both roads, TEXT mode
      byte-identical under vamos. Binary 77,108 → 78,200.
- [ ] **BOOT GATE: visually unchanged.** Same window, same tabs,
      same scrolling, same status row, on the same screenshot pair
      as before. Watch scrolling hardest — b62, b91 and b93 were
      each paid for in builds, and all three are in the moved code.
- [ ] Two deliberate behaviour changes to know about before boot:
      1. `y0` had to be renamed (`gy0`, with `x0` → `gx0` to keep
         the pair): as a non-static extern it collided with gcc's
         Bessel builtin `y0` and warned on every build.
      2. If `OpenWindowTags` fails on a screen of OUR OWN, the
         chassis no longer calls `UnlockPubScreen` on it. The old
         code unlocked a screen it had never locked. Rare path,
         real fix, but it IS a change.
- [ ] Deferred out of b0b on purpose: the requesters (`erq`,
      `centerreq`, ASL `askfile`). Generic and small, but cedit b1
      does not need them, and every extra moved line widens the
      bisection if this boot goes wrong.

## 0.1b1 — one buffer, read-only — BUILT 2.8.26, AWAITING BOOT

- [x] **`edbuf.{c,h}`** — the buffer as PURE logic, no Amiga headers,
      so a harness builds and runs it on the host AND under vamos.
      The CFile `edensure`/`edgrow` model: a doubling line table of
      independently grown per-line buffers, no line cap and no line
      count cap. Chosen over a gap buffer for what the rest of cedit
      needs — rendering row N is an O(1) lookup, the gutter number IS
      the index, and b5's lexer state is one byte alongside.
- [x] **The `Buffer` struct carries b2–b5's fields already** (cursor,
      dirty, per-line `lex`, per-buffer `top`/`hoff`), with exactly
      one buffer in it. Tabs at b4 are a data change, not a rewrite.
- [x] **`tests/edtest.c`, ALL GREEN both roads** — line endings (LF,
      CR, CRLF, mixed, no trailing newline, empty file, lone
      newline, blank lines), table growth to 5,000 lines, a
      4,999-character line, free-then-reuse, and absolute tab-stop
      arithmetic on both the mask and modulo roads. Plus a tamper
      control that feeds a deliberately wrong expectation and
      requires the suite to notice — a suite that cannot fail proves
      nothing.
- [x] **The whole GUI is the lifted chassis**: window/screen/font via
      `LtxWinSpec`, border scrollbars, tab bar, status row, gutter,
      row painter, and the deferred-paint scroll engine driven
      through the `LtxApp` vtable. cedit's own GUI code is the eight
      adapters, a page composer and an event loop.
- [x] Tooltypes: `FONT=`, `TABSIZE=`, `GUTTER=`, `STATUSBAR=`,
      `FASTSCROLL=`, `OPENSCREEN=`/`SCREENDEPTH=`, `PUBSCREEN=`,
      `LEFT=`/`TOP=`/`WIDTH=`/`HEIGHT=`. The Settings menu writes
      back to the icon through the chassis's `iconset`.
- [x] Builds clean at `-O2 -Wall`; binary 36K.
- [ ] **BOOT GATE: it opens a file and scrolls exactly like cdiff.**
      Same gutter, same scrollbars, same status row, same feel on
      held keys / Shift+page / knob drag / wheel / resize. If the
      lift was clean this is nearly free — which is the point of
      gating here rather than after editing exists.
- [ ] Known limit inherited from the chassis: `LTX_MAXCOLS` is 256,
      so a window wider than 256 cells clips the painted row. Fine
      on PAL Hires (80), a real ceiling on a big RTG screen. cdiff
      has always had it; worth lifting when something actually meets
      it.

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
