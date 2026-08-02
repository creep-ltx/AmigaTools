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
- [x] **b13: horizontal scroll + window resize** — left/right pans
      the text (gutter pinned, tab stops absolute); size gadget +
      IDCMP_NEWSIZE re-grids and re-clamps every view's top.
- [x] **b14: two resize finds** (his screenshots) — the no-files
      hint and tab labels now clip to window width instead of
      overpainting the border; drawpage clears the sub-cell slack
      margins so a resize can't leave stale pixels beside them.
- [x] **b17-b19: the Unpacked/ guru, three ways** (his find: a
      guru closing cdiff after opening two big real drawers) —
      walkdir's path buffer moved off the stack onto the heap;
      the fraudulent `__stack` (nothing in this libnix reads it,
      proven by nm) removed; main became a StackSwap trampoline
      onto a 64K heap stack whenever the task's own stack measures
      small. b19 fixed the trampoline's OWN exit crash: gcc merges
      SP cleanup across calls, so the swapped work must be an
      argument-less noinline function - verified by re-reading the
      disassembly tail. **BOOT-GREEN on real 3.2, stack 4096, no
      Stack/STACK tooltype needed.**
- [x] **b25/b26: mouse citizenship, first pass** (his verdict: "a
      CLI program in a GUI, no scrollbar, can't click anything") —
      proportional border prop-gadgets synced to every scroll
      source (keys, wheel, hunk jump, tab switch); Tree click
      selects, double-click opens (DoubleClick() timing). b26
      tried hand-rolled sysiclass arrow images at the scroller
      ends - built clean, but **his boot screenshot showed no
      arrows at all**, just the bare knob track.
- [x] **b27: scrap the hand-rolled arrows, use GadTools' own**
      (his correction: "please do not reinvent the wheel", after
      he pointed at the ReAction and GadTools wiki pages himself)
      — root cause of b26's invisible arrows: a plain struct
      Gadget cannot render a BOOPSI class image without
      GFLG_GADGIMAGE, never set. Rather than patch that, switched
      the whole scroller to gadtools.library's own SCROLLER_KIND
      (CreateGadget) - it builds its own correctly-imaged knob AND
      arrow-button pair, and drives their click-and-hold repeat
      itself via IDCMP_INTUITICKS entirely inside gadtools.library
      (confirmed against the real installed NDK headers, not
      memory: ARROWIDCMP/SCROLLERIDCMP, GTSC_Total/Visible/Top,
      GT_SetGadgetAttrs/GT_GetGadgetAttrs, GT_GetIMsg/GT_ReplyIMsg
      required once real GadTools gadgets exist). Also fixed the
      OTHER b26 finding in the same screenshot: the horizontal
      scrollbar showed a partial knob from a fixed 512-column
      guess even when nothing on screen overflowed. GTSC_Total now
      comes from a real per-view max-line-width scan (tab-expanded
      to match rendering, cached, invalidated on load/scandirs/
      view-switch) - a side that fits shows a full-body knob, the
      honest "nothing to scroll" signal. Border geometry derived
      from real border widths only (no guessed corner-reservation
      constant): the vertical scroller stops above the bottom
      border row, the horizontal stops left of the right border
      column, leaving exactly the corner cell for the system size
      gadget. **His boot: NOTHING rendered - not even a bare
      track** (worse than b26's arrow-less-but-visible knob).
- [x] **b28: PGA_Freedom, the tag that was missing all along** -
      root cause of b27's blank scrollers, found by chasing real
      documentation instead of guessing again: orientation is NOT
      inferred from a gadget's Width-vs-Height aspect (that b27
      claim was fabricated from vague memory, never verified).
      GadTools scrollers take an explicit `PGA_Freedom` tag
      (LORIENT_VERT / LORIENT_HORIZ, `intuition/gadgetclass.h`)
      and DEFAULT TO HORIZONTAL when it's omitted - so both
      scrollers, including the narrow/tall vertical one, were
      silently built horizontal, a degenerate box in the wrong
      axis that rendered as nothing. Also: GTSC_Arrows must be
      explicitly requested (arrows are opt-in, not automatic) -
      value is the arrow's cross-axis size, matched to the
      gadget's own thickness. Sourcing note: a Blitz Basic 2
      gadtools wrapper guide found on the FS-UAE drive named the
      tag first, but the FACT that decided the fix was independently
      confirmed straight from the real C NDK header the toolchain
      ships (`grep -rn PGA_Freedom /opt/amiga/.../gadtools.h`) -
      not trusted from the Blitz source itself. **His boot: STILL
      nothing** - identical symptom to b27, meaning the orientation
      fix was real but not THE blocker; something more basic (a
      NULL from CreateGadget, or a degenerate border-width
      assumption never actually verified) is failing the same way
      both times, and a third blind C-level fix would just be a
      third guess.
- [x] **b29: telemetry build** - window-title diagnostics instead
      of a third guess. Superseded by b30 before he had to boot it:
      re-reading the build history answered the question the
      telemetry was going to ask.
- [x] **b30: THE ANSWER - one flag, and a wrong turn undone.**
      Read from the git history rather than guessed. The chain:
      **b25 put raw Intuition prop gadgets in the window borders
      and they RENDERED** (his screenshot #14 shows both tracks).
      **b26 added sysiclass arrow images and they did not** -
      because `mkarrow` set `Flags = rel` and never set
      **`GFLG_GADGIMAGE`** (intuition.h 0x0004: *"set if
      GadgetRender and SelectRender point to an Image structure,
      clear if they point to Border structures"*). Without it
      Intuition walked each sysiclass Image as a `struct Border`
      and drew nothing. **b27 then diagnosed that flag correctly
      in its own source comment - and instead of setting it, threw
      away the working prop gadgets for GadTools SCROLLER_KIND**,
      which is a client-area widget kind, not a border one: hence
      "nothing at all", twice, and hence b28's PGA_Freedom fix
      being real but irrelevant to the actual blocker.
      b30 restores b25/b26's proven border props verbatim and adds
      the single missing bit. Kept from the detour: the real
      per-view max-width scan (a fitting view now shows a
      full-length knob) and `sethoff()` as the one clamp path.
      Added: `propfrac()` shift-down guard so MAXPOT x line-count
      cannot overflow a 32-bit multiply on files past ~32K lines
      (CFile's own progadd pattern). Event loop back to plain
      GetMsg/ReplyMsg - GT_GetIMsg is only required for GadTools
      *gadgets*, never for its menus.
- [x] **b45: REVERT TO b25 - the arrow road is abandoned** (his
      call: "the latest build was a complete rebuild and it looks
      terrible... revert to an earlier build before we tried to
      add scrollbars and arrows"). `cdiff.c` restored verbatim
      from b25, the last state whose scrollers he SAW render (his
      screenshot #14, both tracks). Everything from b26 on was one
      chase after arrow images that never appeared: b26 sysiclass
      without GFLG_GADGIMAGE, b27 the GadTools SCROLLER_KIND
      detour, b28 PGA_Freedom, b30 the flag restored, b31-b38 the
      geometry grind, b39/b40 propgclass, b41-b44 pixel nudges -
      and then 0.2b1 threw the whole custom renderer away for a
      ReAction listbrowser that looked worse than any of it.
      Discarded here in one step. The ENGINE was never implicated:
      `diff.c`/`diff.h` are byte-identical at b25 and 0.2b1, and
      the harness is ALL GREEN on host and vamos after the revert.
      **What b25 has: border prop scrollers that render, Tree
      click-to-select and double-click-to-open. What it has not:
      arrows.** That is the accepted trade - the arrows cost a
      whole night and never arrived.
      LESSON, the expensive one: b26 was a cosmetic addition on
      top of a WORKING widget, and it broke the widget. Nine
      builds then argued with the breakage instead of dropping the
      cosmetic. When an addition breaks something that rendered,
      the first move is to remove the addition, not to debug it.
- [x] **b46-b57: the scrollers and the arrows, by his eye** — the
      arrow road reopened from the b25 base exactly as the rule
      above required, and it rendered FIRST TRY, because b30's
      post-mortem was taken as given instead of re-derived:
      `mkarrow` sets **GFLG_GADGIMAGE** (verified in the shipped NDK
      header, `intuition.h:296`, not from memory). Everything after
      that was his eye, one pixel at a time: track insets (b46/b47),
      arrows down 1px (b53), track grown 1px down and 17px right
      (b54-b57). Arrow sizes are MEASURED back from each image and
      each pair measured separately - b48 sized both pairs off the
      up arrow, correct only while they happened to match.
      **THE FINDING, worth more than the pixels:** this sysiclass
      IGNORES `IA_Width`/`IA_Height`. b49 asked +2 and b51 asked +4;
      both were silently discarded and the arrows stayed natural
      size through two builds that did nothing. Proven by b51's
      window-title telemetry reading `nat 13 req 17 got 13` - the
      b29 pattern paying for itself a second time. `SYSIA_Size` is
      the only lever that works, so b52 measures all three sizes at
      startup and picks the smallest that reaches the target
      (LOWRES 13 / MEDRES 18 / HIRES 18 on his 256-line PAL WB).
- [x] **b50: RefreshWindowFrame, not RefreshGList** (his find, and
      the diagnosis was entirely his: "they look bad on open and
      resize, but click outside the window and back and they come
      good"). Deactivating makes Intuition redraw the window FRAME -
      border background first, THEN the border gadgets. RefreshGList
      only paints gadget imagery, so every refresh of ours stamped
      the arrows onto stale border pixels. Every gadget in this
      window is a border gadget; RefreshGList has no business here.
- [x] **b58: the horizontal knob tells the truth** (his find: a
      shrunken, draggable knob over an EMPTY window). The pan range
      was `#define HTOT 512`, a guess. Replaced by b27's one keeper,
      the cached per-view widest-EXPANDED-line scan. Empty content
      needs no special case: gmaxw 0 -> htotal == viscols -> body
      full, pot 0, and a knob filling its track is one Intuition
      will not let the mouse drag. The flat 440 clamp in two places
      went with it; keys, arrows and knob now share `sethoff`.
- [x] **b59-b61: tabs and keys, his calls** — active tab takes the
      page background instead of FILLPEN blue, marked only by the
      base rule breaking open under it; tab bar 2px shorter, off the
      bottom; **Esc POPS ONLY and never quits** - quitting is
      Amiga+Q or the close gadget. Three stale "Esc quits" claims
      corrected in the Keys window, the file header and README.
- [x] **b62-b66: the scroll stutter** (his find, and his bisection
      solved it: "up/down clean, Shift+up/down and left/right
      glitchy" - which is precisely the split between the blit path
      and `drawrows()`). Two mistakes of mine on the way, both worth
      keeping written down. b62 deferred painting to the end of an
      input burst but always paid the debt with a full `drawpage`,
      making a SINGLE keypress dearer than the incremental scroll it
      replaced; and it flushed only after the message loop exited,
      which during a knob drag never happens, so the content froze
      until the button came up. b63/b64 typed the debt (page / rows
      / scroll-from / cursor / knob), flush the moment the port is
      empty AND at least every 4 messages, and drive a knob drag
      from INTUITICKS as well as MOUSEMOVE so it cannot depend on
      one delivery path. b64 also fixed a bug b62 introduced: with
      the paint deferred, `drawpage()` inside BeginRefresh drew
      NOTHING while EndRefresh still cleared the damage.
      **The real defect was underneath all of that, and predates the
      revert:** every row was filled grey, filled again in FILLPEN,
      then written into - two full-width fills per changed row. One
      or two entering rows hid it; forty rows repainted in place did
      not. b65 fills once in the final colour; b66 removes the fills
      entirely - `Text()` paints its own background, so a padded
      span puts glyphs and surface down in ONE blit and no row can
      be caught half-painted. b66 also fixed a latent clip: the old
      `ex[512]` held the line from column 0 and stopped padding once
      hoff+width passed 512.
      LESSON: scheduling was not the bug, it only exposed one. Three
      builds went into WHEN to paint before the cost of HOW each row
      painted got looked at.
- [x] **b67-b68: FIND** (his ask, with a MultiView-style Navigation
      menu as the model): Find... / Find Next / Find Previous on
      Amiga+F and Amiga+N, the third deliberately shortcut-less like
      the menu he pointed at. The requester is a real GadTools
      STRING_KIND — his standing "use the OS's own" rule — reusing
      the VisualInfo the menus already hold, and using GT_GetIMsg/
      GT_ReplyIMsg, which become mandatory the moment real GadTools
      *gadgets* (not just its menus) live in a window.
      Case-insensitive substring over the ACTIVE view's rows: Both
      searches either side of a row, a single-file tab searches that
      file, the Tree searches paths. Searching what is on screen is
      the contract — a hit he could not see would be a lie. Wraps at
      both ends. One pass counts every match AND picks the hit, so
      the title can say `[Find "x" 3/17]` honestly; counting costs
      the same scan the search needs anyway, and being exact after a
      reload beats caching a number that can rot.
      The hit is centred and marked by a caret in a reserved column
      0, drawn on the plain background so it stays legible on a
      changed row too. The Tree gets no caret — a find there moves
      the selection cursor, which already marks the row.
      **b68, his call:** that column is reserved ONLY while a find is
      current. b67 reserved it always, which shifted a text layout he
      had already signed off for a feature that is idle most of the
      time. Since the grid is cached (cx0/cvis/halfw/gutw), gofind
      re-grids BEFORE scrolling, and drawpage reconciles for the
      paths that drop a find without going through gofind (reload,
      view switch, rescan) — the term survives those, the hit cannot,
      because findrow is an index in one view's numbering.
- [x] **b69-b71: APPWINDOW DROPS** (his ask: "dropping files onto
      the window needs to exist"). A dropped icon picks its side by
      WHERE it lands — content width split 40/20/40, left band sets
      the left, right band the right, the narrow middle asks with a
      Left/Right/Cancel requester. Two icons dropped together fill
      both in the order given; position cannot disambiguate two, so
      it is not consulted.
      The bands are fixed fractions and identical in EVERY view —
      empty window, Both, the single-file tabs, the Tree — rather
      than tied to the pane geometry. **His correction is why:** the
      marker column only carries `|`/`<`/`>` on DIFFERING rows, so
      there is no drawn boundary to aim at, and an empty window (the
      likeliest moment to drop) has nothing at all. AppWindow also
      reports only the drop — there are no drag-over events, so
      nothing can highlight a target mid-drag. A gesture aimed at an
      invisible line must at least never change meaning.
      **b71, his find:** a single DRAWER takes a side too, because
      the two drawers to compare are rarely in the same place on the
      drive and often cannot be dragged together. Each side holds a
      file or a drawer; dropping one clears the other on that side,
      so a session can switch between file and tree compare by
      dropping alone. The title reports a half-set pair ("now drop
      the RIGHT drawer") — without it the window just looks idle —
      and a drawer-versus-file mismatch says so instead of silently
      doing nothing.
      Degrades quietly throughout: no workbench.library, no port, or
      a failed AddAppWindow simply means drops are not offered.
- [x] **b70: the stale `defer` flag** — a bug of MINE from b63, found
      by his report that a dropped pair loaded but the window did not
      change until it was activated again. `flushpaint()` cleared
      `defer` only on the path where something was owed, so a message
      owing no painting left the flag armed. Harmless for as long as
      every painter ran inside the IDCMP drain (which re-arms it per
      message anyway) — and a real defect the moment anything painted
      from OUTSIDE that drain. The app port was the first thing that
      ever did. `defer` is now cleared before the early return, and
      the app-message branch flushes for itself.
      LESSON: a flag that is only ever correct because of where it
      happens to be set is not correct, it is lucky.
- [ ] A status row: hunk i/N, +a −d, position %.
- [x] **b72: ICONIFY** (his ask) — **boot-verified: "works as
      intended"**. The tag is in the shipped NDK after all, as
      `WA_IconifyGadget` (WA_Dummy + 0x60 = $800000C3) — the exact
      value AmigaReferences recorded from E-VO's modules, so no
      hand-defined constant and the reference is confirmed against
      the header. THE TRAP, avoided only because it was written down
      first: the click arrives as IDCMP_CLOSEWINDOW with **Code ==
      1**, and cdiff's handler was a bare `CLOSEWINDOW -> done`, so
      setting the tag without branching on Code would have made the
      new gadget QUIT the program.
      Window setup/teardown split into openmain()/closemain() so the
      window can be destroyed and rebuilt with the loaded diff, the
      view and every scroll position untouched. The lifetime rule
      that matters: the AppWindow is per-window, the message PORT is
      not — it outlives the window because that is how the AppIcon
      reaches us while hidden. closemain() nulls every pointer it
      frees so a reopen rebuilds instead of double-freeing.
      If the AppIcon cannot be made the window comes straight back,
      rather than leaving the program running and unreachable. While
      hidden, settitle/drawpage/flushpaint are no-ops — several
      paths call them and `win` is NULL.
      Open: the AppIcon uses GetDefDiskObject(WBTOOL), the generic
      tool icon (his call: fine for now, he will draw one later).
      The tooltype build has the program's path from WBStartup, so
      pointing it at his own icon becomes a couple of lines. Icons
      dropped ON the AppIcon restore the window but do not load -
      the drop bands are meaningless with no window.
- [ ] **Tooltypes** (his ask; a config file is explicitly NOT wanted,
      the icon carries the settings) — read from the WBStartup
      message, which `smain` currently discards as `(void)argv`.
      Planned: FONT, EDITOR, DRAWER, PUBSCREEN, TABSIZE (tab width is
      hardcoded 8 today), LEFT/TOP/WIDTH/HEIGHT, VIEW. Two project
      icons dropped on the cdiff icon should diff as a pair - the
      Workbench half of the same gesture.

## 0.1b3 — directory mode

- [~] **DIRECTORY MODE (build b16, 1.8.26)** — `cdiff DIR1 DIR2`
      or Open Files... with two DRAWERS (empty File field in the
      requester): both trees walked (recursive ExNext, own lock +
      AllocDosObject fib per level), sorted case-insensitively,
      merged - L/R one-sided, D size-differ, S same-size; content
      truth on demand via Enter (the real diff). The Tree tab
      joins the bar ahead of the file three; selection cursor
      (Latin-1 >> on the gray), Enter opens the pair, Backspace
      returns, n/p walk non-same entries, 0 jumps to the Tree.
      TEXT mode with two dirs prints the compare listing - the
      scanner's vamos harness road (crafted-tree cases + the
      cfile/cfile13 pair GREEN before any boot) and a CLI tool for
      free. Boot gate pending. Parked knowingly: ExAll batching
      (CFile I3 - matters on real media), content hash for
      same-size pairs, a busy pointer during big scans.

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
