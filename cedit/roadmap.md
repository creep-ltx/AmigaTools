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

## 0.1b2 — editing, and save — BUILT 2.8.26, AWAITING BOOT

- [x] **The edit primitives are in `edbuf.c`**, harness-proven both
      roads before a single key was wired: `edinsch`, `eddelch`,
      `edsplitline`, `edjoinline`, on a private `rowopen`/`rowclose`
      that move all four arrays together or not at all. Every one
      returns 0 only on out of memory and leaves the buffer usable.
- [x] **Tests for what actually breaks**: every edit checked on the
      LENGTH, the NUL *and* the text, because a `memmove` that
      forgets the terminator renders fine and saves garbage. Insert
      at head/middle/end, delete at head/middle/end and past the
      end, 400 characters typed one at a time across the per-line
      doubling boundary, split at column 0 / mid / end of line, join
      back, join at the last line as a no-op, and `maxw` staying
      honest across all of it.
- [x] **The caret is complemented over the cell**, the ROM's way and
      CCON's — it inverts whatever glyph is under it, so it reads on
      any pen pair and erasing is the same operation again. Painted
      inside `erow()`, so every repaint that reaches that row carries
      it: a scroll's entering row, a refresh, a resize.
- [x] **Minimal redraw, per the standing rule.** Typing repaints ONE
      row. Moving the caret repaints two — the row it left and the
      row it reached — through the chassis's `ltx_appowed`/`flushapp`
      debt, with the damaged row held as a BUFFER index so it
      survives a scroll in the same burst. Only a split or a join
      escalates to `dirtyrows`, and only because every row below
      really did move.
- [x] `SetWindowTitles` repaints the whole title bar, so the dirty
      marker is only written when `dirty` actually changes state —
      otherwise a per-keystroke title update would undo the point of
      repainting one row.
- [x] **Keys**: cursor moves the caret (Shift = page / line ends,
      Ctrl = word jumps, the CCON assignment); the wheel and the
      scrollbars scroll WITHOUT moving the caret. b1's `t`/`e`/
      `space`/`b` shortcuts are gone — in an editor `b` types a b.
      A goal column is kept, so walking down past a short line does
      not drag the caret to its end.
- [x] **Save writes back what it read**: the line endings the file
      arrived with (LF/CRLF/CR, detected at load), and no final
      newline added to a file that had none. Otherwise the first
      save of a CRLF file would make cdiff show every line changed.
- [x] **Save is non-destructive**: the text goes to a sibling `.new`
      first and only replaces the original once completely written,
      so a failed save costs a stray file rather than a truncated
      source. CFile's charter, same reason.
- [x] **The save BYTES are harness-checked**, not trusted: the
      serializer lives in `edbuf` (`bufbytes`/`bufserialize`) and the
      suite round-trips LF/CRLF/CR, no-final-newline, blank lines,
      a single line, an empty file, and an edited buffer keeping its
      original endings — byte for byte, both roads. A save that
      mangles a file is the worst bug an editor can have, so it is
      the one thing not left to a boot test. It found one: an empty
      document was saving as a 1-byte file; opening and saving an
      empty file now leaves it empty.
- [x] Quitting with unsaved changes asks first, with Cancel as the
      safe default. Pulled forward from b4 — losing work to a stray
      close gadget was not worth deferring.
- [x] **No "nothing loaded" hint, and no empty state at all** (his
      call). cdiff needs two files before it can do anything, so an
      empty cdiff window has to say so; an empty EDITOR window is a
      new document with the caret already in it.
- [x] **No tab bar for a single document** (his call). One document
      has nothing to switch between, and its name is already in the
      title bar and the status row — so a one-tab bar would spend a
      whole row of text saying what is said twice over. The chassis
      gained `ltx_tabbar`: 0 means no bar height AND no gap under
      it, with the content starting at the top border. It defaults
      to 1, so cdiff is untouched. cedit sets it from the open
      document count, so b4's tabs appear the moment there are two.
- [x] Three bugs found by reading it back before deploying: typing
      into a buffer with no file loaded indexed a NULL line table
      (an empty document is now one empty line, always); `eflush`
      repainted the same row twice on every keystroke; and the
      "no file loaded" hint sat over a document being typed into.
- [ ] **BOOT GATE:** type into a file and see one row repaint, not a
      page. Then: caret follows on all four edges, Return/Backspace/
      Del at line boundaries, word jumps, Tab, a save that reloads
      identical in cdiff, and the unsaved-changes prompt.
- [x] **MULTI-DOCUMENT, pulled forward from b4** — his Project menu
      spec only makes sense with tabs, so b2 grew them: New (blank
      page in a NEW tab), Open (replaces the current tab), Open New
      (a tab of its own), Close (the active tab), Close All (leaves
      one blank page), Save (active tab; untitled falls through to
      Save As), Save As, Quit. Up to 16 at once; click a tab to
      switch. `cedit a.c b.c` and a multi-icon drop both fill tabs.
      **There is always at least one document** — closing the last
      leaves a blank page rather than an empty window, which is the
      same end state Close All produces.
      The b1 design paid off exactly as intended: Buffer already
      carried its own top, hoff, cursor and dirty flag, so this was
      an array plus one save/restore of the chassis's single hoff -
      not a rewrite.
- [x] Unsaved-changes prompts: per document for Close and a
      replacing Open, and **once for the whole set** for Close All
      and Quit — being asked eight times running is how a user
      learns to click through prompts without reading them.
- [x] **Tab size 1–10 from the menu** (his ask), radio-style: in
      GadTools that is CHECKIT plus a mutual-exclude mask naming
      every other item at that level. `TABSIZE=` now reads the same
      1–10 range, so menu and tooltype can always express the same
      thing, and the pick writes back to the icon like every other
      setting. It is the one settings change that repaints the page:
      every line's expanded width moved, and so did the caret's
      column.
- [x] **The requesters lifted** — `ltx_msg` and `ltx_askfile` (with
      a save-mode flag and one `FileRequester` kept for the life of
      the program, so it remembers the drawer). Left behind at b0b
      on purpose; cedit's Open and Save As are the second caller,
      which is exactly when they move. cdiff now calls the chassis
      versions rather than keeping its own copies.
- [ ] Not yet: undo — which is b3, and the reason to be careful with
      this build until it exists.
- [x] **b4's two remaining tab items, both done, both in the
      chassis** (his design):
      1. **A close box on every tab** — a small `x` at the tab's
         right end, tested BEFORE the tab body so a click on it can
         never read as "switch to this tab". `sysiclass CLOSEIMAGE`
         (the window border's own close gadget) was tried and
         **removed on his call**: it is sized for a TITLE BAR, so at
         topaz 8 nothing the class offers fits a tab, and using it
         would have meant growing the tab bar to suit — a row of
         text spent on a prettier gadget. The attempt is gone rather
         than left dormant, because a latent branch would have
         switched the tabs to an image by itself the day someone
         picked a larger font. Clicking one switches
         to that tab and then goes through the same `doclose()` the
         menu uses, so the unsaved-changes prompt lives in exactly
         one place. `ltx_drawtabs` takes a `closable` flag; cdiff
         passes 0, because its tabs are views and there is nothing
         to close.
      2. **Scroll arrows when the tabs do not fit** — `<` at the
         left end and `>` at the right, each drawn only when that
         direction is actually available, with both slots reserved
         while scrolling is in force so the tabs do not shuffle
         sideways as you page through them. Off-screen tabs get a
         zero-width hit range, so a hit test can never land on
         something that is not drawn.
      The conflict that took a second pass: the bar also has to keep
      the ACTIVE tab visible, since the menu can switch to a
      document off the end of it — but doing that on every redraw
      would undo the user's own scrolling the instant it was drawn.
      So it only recentres when the active tab actually CHANGED.
      Switching follows the document; scrolling stays where it is
      put.
      **The right-hand edge took five rounds and a screenshot**, and
      the lesson is b29's: three of those rounds were guesses at
      where the client area ends, and all three were wrong. What
      finally settled it was on-target telemetry (the window's own
      W/BorderRight/xend printed into its title) plus a 4-colour
      screen grab measured pixel by pixel. Two real defects came
      out of it, neither where I kept looking:
      1. The page's slack strip started at `gy0` instead of `conty`,
         so it repainted the sub-cell remainder — 0 to fw-1 pixels
         wide, in background grey — straight over the right end of
         the tab bar, *after* the bar had drawn. Every adjustment
         inside `ltx_drawtabs` was being painted over, which is
         exactly why one build "looked exactly the same". Same bug
         in cdiff's `drawpage`, fixed there too.
      2. The rule's break-open-under-the-active-tab step drew
         BACKWARDS when that tab was scrolled out of view: an
         off-screen tab carries a zero-width hit range parked at
         `winr`, so the span became `[tabe-2 .. tabx+1]` and ran
         across the last client column into Intuition's own border
         bevel. That is the grey pixel that survived until a resize
         — the border is Intuition's to repaint, and only
         `RefreshWindowFrame` does it. With no visible active tab
         the rule is simply unbroken now.
      Also his eye: the right arrow sat flush against the client
      edge and read as reaching into the border, so it moved 3px
      left and the tabs gave up the same 3.
      Hit testing moved into the chassis too (`ltx_tabclick`), so
      the boxes on screen and the boxes being tested are the same
      numbers by construction — cdiff uses it as well now.

## 0.1b3 — undo — BUILT 2.8.26, AWAITING BOOT

- [x] **Command records, not snapshots** — a 5,000-line file cannot
      afford a copy per keystroke on an 8MB machine, and the inverse
      of every edit here is exactly one other edit. Four ops: INS,
      DEL, SPLIT, JOIN.
- [x] **The primitives record, not the call sites.** `edinsch`,
      `eddelch`, `edsplitline` and `edjoinline` push their own undo
      records, so no path can change a buffer without becoming
      undoable — worth more than any amount of care at the callers.
      Undo applies its inverse back through those same primitives
      with a `uapply` flag set, so it can never drift from what an
      edit actually does.
- [x] **One array, one cursor**: records below `utop` are undoable,
      records at or above it are redoable, a fresh edit throws the
      latter away. Bounded at 500; the oldest falls off rather than
      the newest being refused.
- [x] **A typing RUN is one undo**, not one per letter — the same
      instinct as coalescing a held-key input burst. The run
      continues only while the next character lands exactly where
      the last ended on the same line, and any cursor movement ends
      it. Backspace and Del coalesce too, and they grow the stored
      text at opposite ends: Backspace walks left, Del stays put.
- [x] **INS carries its text, not just a count.** Writing it the
      other way produced a record that could be undone but never
      redone — caught while implementing, not after.
- [x] **The save point moves with the file**: `dirty` is
      `utop != usaved`, so undoing back to the last save clears it
      and redoing away sets it again. When the stack overflows and
      the record that would reach the saved state falls off the end,
      the save point is abandoned rather than lied about.
- [x] Repaint follows the chassis's own rules: a structural undo
      moved every row below it and gets a content repaint; anything
      else touched one line and goes through the same one-row damage
      path that typing uses.
- [x] **Harness ALL GREEN both roads**, and it caught two things
      during the build: `ed_marksaved` moved the save point without
      reclearing `dirty`, and one of my own tests constructed a join
      that could not happen. Coverage: run coalescing, run breaking,
      a run only continuing where the last character ended,
      Backspace and Del order, structural undo/redo of split and
      join at the right seam, redo discarded by a new edit, dirty
      tracking in both directions, undo/redo past the ends as
      no-ops, a load leaving nothing on the stack, and the bound.
- [ ] **BOOT GATE:** type a word, one Amiga+Z takes the word back.
      Then Return/Backspace/Del at line boundaries undone, redo,
      undo after a save marking the file unmodified again, and the
      status row's `[no undo]` marker appearing at the bottom of the
      stack.

## 0.1b4 — multi-buffer, and closeable tabs — DONE AT b2

Pulled forward: his Project menu spec (New / Open / Open New / Close
/ Close All / Save / Save As) only makes sense with tabs, so the
whole of b4 landed inside b2 and its tab work. Everything on this
list is done and boot-green — the documents, the close boxes, the
overflow arrows, the per-document prompts. See the b2 entry above,
which carries the detail and the two edge bugs it cost.

## 0.1b5 — selection and the clipboard — BUILT 2.8.26, AWAITING BOOT

His ask, and his call on how selection works: **mouse drag plus an
anchor key**, with Shift+arrows left alone — their paging matters on
a keyboard with no PgUp/PgDn, and the mouse did nothing in the text
area, so nothing had to be rebound. It is also how CCON selects.

- [x] **The clipboard is CCON's design in C**: `clipboard.device`
      unit 0, IFF `FORM FTXT` with a `CHRS` chunk, `CMD_WRITE` then
      `CMD_UPDATE` to commit, padded to an even length; and on read
      the cycle is **run dry** afterwards or the clip is never
      released. IO-request only, no DOS packets. That format is what
      the console family shares, so a cedit copy pastes into a stock
      `CON:`, into Ed, into MultiView — and back.
- [x] **AmigaReferences has no clipboard section** — only a note
      that E must open the device itself. cedit is the second user
      after CCON, so this is now owed a page there.
- [x] **Selection lives in `edbuf`**: an anchor plus the cursor,
      sorted by `ed_selrange` because a drag can go backwards, and
      an empty range is deliberately *not* a selection — Copy on one
      beeps rather than quietly putting an empty clip on the system.
- [x] **Undo groups**, added for this: everything between
      `ed_group`/`ed_ungroup` undoes as ONE step, so a paste is one
      undo and not thirty, and a range delete is one. Nested groups
      keep the outermost, so the delete inside a paste stays part of
      the paste.
- [x] Range delete works back to front so the coordinates ahead of
      it never move; `ed_instext` splits on LF, CR and CRLF alike.
- [x] **The N-run painter finally earns its keep** — b0b widened it
      for the lexer, and the selection is its first real user: up to
      three runs per row (before, selected, after), each written
      exactly once, so a selected row is still one pass and never
      half-painted. The caret hides inside a live selection: the
      range is the statement.
- [x] A click lands on a PIXEL and the buffer is indexed by
      CHARACTER, with a tab spanning many columns — so `ed_col2x`
      walks the line's tab stops exactly as the painter does. Tested.
- [x] Typing, Return, Backspace and Del all replace a live
      selection, in one undo step. Dragging past the window edge
      scrolls. Esc drops a selection; Amiga+B toggles the anchor.
- [x] Harness ALL GREEN both roads: ranges forwards and backwards,
      within a line and across lines, byte counts agreeing with the
      text, single-step undo of both range delete and multi-line
      paste, every line ending accepted on insert, and the
      column-to-index mapping through a tab.
- [ ] **BOOT GATE:** drag-select across lines and see the inverse
      run follow the drag; Amiga+C then Amiga+V; a cut and one undo
      bringing all of it back; and a copy pasting into a `CON:`
      shell to prove the FTXT interop.

## 0.1b6 — the E lexer — BUILT 2.8.26, AWAITING BOOT

The reason cedit exists rather than being another editor.

- [x] **`elex.{c,h}`, pure logic**, harness-proven on host and vamos
      exactly as `edbuf` is. Knows nothing about pens, screens or
      columns: it hands back spans in SOURCE character positions and
      the renderer decides what they look like.
- [x] **One state byte per line** (`lex[i]` = the state line i
      *starts* in), so a row can be coloured knowing only that byte.
      After an edit, `ed_lexdirty` walks forward and **stops the
      moment a recomputed state matches the stored one** — a change
      inside a line almost never reaches the next, so it is one
      line of work in the ordinary case and only runs long when a
      block comment was opened or closed.
- [x] E's real shape, not a C lexer with different keywords: `->` to
      end of line, **nested** `/* */` (E nests them, so the state is
      a depth and not a flag), `'…'` and `"…"` with backslash
      escapes, `$hex`/`%binary`, and whole-word uppercase keywords —
      because E is case sensitive and a variable called `to` or a
      field called `list` is very common.
- [x] **The corpus is the test.** The harness lexes cfile.e,
      ccon-handler.e, cfile13.e and cmenu.e — **33,735 lines** nobody
      wrote with a lexer in mind — and asserts spans are ordered,
      start at 0, never run past the line, and that the comment state
      **closes at 0 at end of file**. All four compile, so that last
      one is real evidence and not a tautology.
- [x] **A SECOND gcc `-O2` m68k miscompilation, found by the vamos
      leg.** `runs[i].cls != runs[i-1].cls` on an `unsigned char`
      struct field reported a false match on data that printed
      correctly one statement earlier. Host fine, `-O0`/`-O1` fine,
      the same loop over the `int` field beside it fine, and a
      `printf` in the body fine. Every rewrite of the *comparison*
      still failed; widening the *field* to `int` fixed it. Written
      up in AmigaReferences/toolchain-and-testing.md beside cdiff's
      b100. It also matters for the product, not just the test —
      `push()` compares that field on every span.
- [x] **The colours answer his question.** Content had been drawn in
      four pens; the furniture already used the screen's own. On a
      stock 4-colour WB the honest scheme is ONE distinction that
      reads well — comments and strings recede to blue — because
      three that all look alike is worse than one that works. With
      `OPENSCREEN=` + `SCREENDEPTH=3` pens 4–7 are cedit's: comment
      green, string amber, keyword blue, number mauve, with 0–3 left
      exactly as Workbench set them so tabs, gutter and selection
      stay native. On somebody else's screen it degrades rather than
      repainting another program's palette.
- [x] Syntax and selection merge into ONE run list per row, the
      selection winning where they overlap, every run written exactly
      once — so a highlighted, partly-selected row is still one pass
      and can never be caught half-painted.
- [x] `HIGHLIGHT=` tooltype and a Settings menu toggle that writes
      back to the icon.
- [x] **Scrolling, and the option that should never have been one.**
      He measured cedit against Annotate and called it a slideshow.
      Two causes, both mine. The small one: `erow` called `explen()`
      per span and `explen` walks from column zero, so a row with six
      spans walked its line twelve times over — now one pass converts
      every span start and both selection ends together. The large
      one: `FASTSCROLL` **defaulted to OFF**, inherited from cdiff's
      b94, so every one-line scroll repainted every row and since b6
      lexed every one of them too. Annotate does exactly what our
      fast path does (`annDraw.c scrollnormal()`: ClipBlit the
      content rectangle, redraw only the entering lines) — we simply
      were not doing it.
      **His verdict: remove the option entirely** — code, tooltype
      and menu, in both tools. It was a bisection tool from b92 that
      outlived its question, and a setting whose only effect is to
      make things worse is a trap, not a choice. The distance guard
      stays: a jump of a page or more is still repainted whole,
      because one pass beats a huge blit plus a full repaint.
      **cdiff gets faster for free** — it had the same inverted
      default since b94.
- [ ] **BOOT GATE:** open a `.e` file and see comments recede. Then
      `OPENSCREEN=cedit`/`SCREENDEPTH=3` for the full scheme. And the
      measurement that was promised at b0: scroll a long `.e` file
      with Syntax colour on and off and see whether the difference is
      felt on the 020 — if it is, the default changes.
- [x] **The scrolling campaign is CLOSED, and the probe counters are
      out** — the status row is `name L/n C` again, and `pb_*` is
      gone from both the chassis and cedit. His telemetry shots on
      cfile13.e say the inversion we wanted actually happened: full
      repaints `F8`/`F12`/`F23` against blits `b55`/`b71`/`b87`, so
      the blit path now carries the ordinary case and the whole-page
      repaint is the exception it was always meant to be.
      **One thing stays unexplained on purpose:** scrolling is still
      quicker with the pointer OUTSIDE the window. Ruled out along
      the way — message traffic (MOUSEMOVE and INTUITICKS were taken
      out of IDCMP entirely and the gap survived), the paint path,
      and the coalescing cap. The remaining suspect is the pointer
      sprite over the region being blitted, which is DMA we do not
      own. His call, and the right one: it is a difference in feel
      now rather than a slideshow, and the next hour is worth more
      spent on find than on the last 20%.

## 0.1b7 — find, replace, and the jumps — BUILT 3.8.26, AWAITING BOOT

His ask, in one beta because the three are independent and each is
boot-testable on its own: Find / Find Next / Find Previous, Replace,
Goto Line, top and bottom of file, and auto-indent on Return.

- [x] **The searcher is in `edbuf`**, harness-proven both roads before
      a key was wired. `ed_search` takes a direction, a fold flag and
      a wrap flag; forward starts AT the position given and backward
      strictly BEFORE it, which is exactly what makes Find Next and
      Find Previous step OFF a match already under the cursor instead
      of finding it again forever.
- [x] **A pattern never spans a line break**, because it comes from a
      string gadget which cannot hold one. That single fact is what
      keeps the whole feature small: every match lies inside one line,
      so a replacement is a delete and an insert at one place, never a
      structural change, and one row repaints.
- [x] **The wrap re-searches the line it started on.** Visiting each
      line once misses a match earlier on the starting line, and a
      wrap that silently skips matches is worse than no wrap at all.
      There is a test for exactly that case in both directions.
- [x] **The match is SELECTED, not just scrolled to** — the anchor at
      its start, the cursor at its end. It costs nothing because b5
      already paints a selected run, and it removes the need for any
      "current match" state: Find Next searches from the cursor (the
      END of the last match) and Find Previous from the anchor (its
      START), so neither can re-find where it stands.
- [x] **A REAL undo bug came out of this, and it was not new.**
      `ed_group` always refused to re-enter, but `ed_ungroup` cleared
      unconditionally - so a nested group ended the OUTER one and the
      rest of it fell out into separate undo steps. Nothing had ever
      nested until replace-all called a grouped `ed_replaceat` inside
      its own group, and it broke on the first run of the new test.
      Grouping is a depth count now. Found by the harness, in the
      first minute, exactly where that discipline is supposed to pay.
- [x] **Replace All is ONE undo step** and reports its count. Scanning
      resumes PAST each replacement, so "a" -> "aa" terminates instead
      of eating itself; there is a test for the growing case, the
      shrinking case and replacing with nothing.
- [x] **Replace shows before it destroys.** The first press finds and
      selects; the next replaces it and moves on. And before
      overwriting a selection it asks the searcher whether a match
      really starts exactly there - the right SHAPE is not proof of
      the right TEXT, and any hand-made selection of the same length
      would otherwise have been overwritten.
- [x] **`ltx_askfields` - the form requester, lifted into the
      chassis.** cdiff has had a one-field Find box since its b67;
      cedit's Replace wants two fields and a toggle and Goto wants
      one, which is the second caller that means LIFT rather than
      copy. N labelled fields (string or checkbox), a row of buttons
      and a Cancel it adds itself; values written back only on an
      accept, so a cancel cannot half-edit the caller's strings.
      **cdiff's `askfind` is now four lines of "what to ask for"** -
      about 100 lines of gadtools deleted from it - and the two tools
      cannot drift apart on requester behaviour again.
      Its VisualInfo is made and freed HERE rather than borrowed from
      the app: b76 already found that a VisualInfo is screen-specific
      and using the app's on a window opened elsewhere is wrong.
- [x] **Auto-indent copies the indent of the line you left**, clamped
      to what was actually BEFORE the cursor - so Return pressed in
      the middle of the leading whitespace does not manufacture indent
      that was never typed. The split and the indent are one undo
      step: one Return, one Amiga+Z. `AUTOINDENT=` plus a Settings
      toggle, defaulting ON, because this is an editor for indented
      languages and the cost of it being wrong is one Backspace.
- [x] **Ctrl+Up / Ctrl+Down are the ends of the file.** Ctrl already
      means "the big version of this move" on left/right, where it is
      a word jump, so the pair reads the same way.
- [x] **The shortcuts are what was left.** N is New and P would have
      paired with it, but Amiga+N for New is older than this program
      and not worth breaking for a mnemonic - so Find Next and Find
      Previous take G and H, adjacent under one finger, with **F3 and
      Shift+F3** wired as well because that is the muscle memory
      actually in people's hands. F = Find, R = Replace, T = Replace
      Next, J = Goto Line.
- [x] Harness ALL GREEN both roads, and the coverage is the awkward
      cases rather than the happy one: forward from the match itself,
      backward never re-finding it, both wrap directions including the
      start-line revisit, overlapping matches ("aa" in "aaaa"), a
      single-line buffer wrapping onto itself, an empty document, a
      pattern longer than any line, the empty pattern, case folding in
      both directions, and every auto-indent shape including Return at
      column 0 and inside the whitespace.
- [ ] **BOOT GATE:** Amiga+F for a word in a long `.e` file and see it
      selected and scrolled to; F3 walks forward, Shift+F3 back, and
      both wrap with the "not found" requester only when it really is
      absent. Then Replace on something harmless, Replace All with the
      count, one Amiga+Z taking ALL of it back. Amiga+J to a line
      number, Ctrl+Up and Ctrl+Down. And Return inside indented E code
      landing under the previous line's first character.
- [ ] Watch for: the requester opening on the right screen with
      `PUBSCREEN=` or `OPENSCREEN=` set - that is the one thing the
      harness cannot see, and it is where cdiff's b76 bug lived.

### b7b — the prompt row, after seeing Ed — BUILT 3.8.26

He put three Ed 47.2 screenshots next to it and called them "nice and
clean": Ed asks on its bottom line - `String:`, `Search:`, `Replace:`
with a block caret - and never opens a window at all. His question
was whether to insert a line above the status bar or borrow the
status bar itself.

- [x] **Borrow it.** Inserting a row means the grid changes, the
      content reflows and the whole page repaints, twice, to collect
      one short string - and the standing rule is that only what
      changed gets redrawn. Borrowing paints ONE row and paints it
      back. The status text is also exactly what is not wanted while
      typing a search: the line number under the cursor is about to
      change anyway.
- [x] `ltx_askline` in the chassis, with Ed's own labels because he
      liked them. The caret is COMPLEMENTED over the cell, the same
      way the document caret is, so it reads on any palette and
      erasing it is the same operation again - no second colour
      chosen for a screen we do not own. The text scrolls sideways
      when it outgrows the row, including on entry, so a long
      previous answer does not open with its caret off the end.
- [x] **`ltx_flash`** - "not found", "12 occurrences replaced" - in
      the status row until the next key, instead of a requester that
      has to be dismissed before typing can continue. That is the
      whole reason this is cheaper than what b7 shipped this morning.
- [x] **The prompt owns the message port while it is up**, so a
      resize during one never reaches the app's loop. The chassis
      re-measures its half and sets `ltx_tookresize`; cedit settles
      the rest in `askstr`, in one place, because the gutter width is
      the app's and it follows viscols. Found by reading it back, not
      by a boot.
- [x] **Case folding moved to Settings** (`IGNORECASE=`, default NO):
      a one-line prompt has no room for the checkbox the requester
      had, and it is a standing preference rather than a per-search
      one anyway. Replace splits into **Replace...** (walks one at a
      time) and **Replace All...**, which is what the button row used
      to do.
- [x] **The requester is NOT deleted.** With `STATUSBAR=NO` there is
      no row to borrow, and manufacturing one would repaint the whole
      page - the exact cost this design exists to avoid - so that
      case falls back to `ltx_askfields`, which cdiff still uses for
      its own Find.
- [ ] **BOOT GATE:** Amiga+F and see `String:` in the status row with
      the block caret, type, Return, and the row goes back to being
      the status row. Esc at the prompt leaves the old search string
      untouched. A search that fails says so in the row and the
      message clears on the next key. Then Amiga+R for the
      `Search:` / `Replace:` pair, and Replace All's count.

## Later, not promised

C and 68k asm lexers · Select All, block indent/outdent, delete
line and delete word · an ARexx port, so CFile can hand it a file
and cdiff can be told to compare what was just saved · running EC
on the buffer and landing the caret on the error line, which is the
one thing no other editor does for E · Revert · a `+N` start-at-line
argument, the `ENV:EDITOR` convention · a `.bak` on save ·
Kickstart 1.3 is not even a question here — the chassis is V36+
throughout.

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
