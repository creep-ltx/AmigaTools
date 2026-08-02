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
- [ ] Arrows on the scrollers - reopen ONLY from the b25 base, one
      build, and abandon again if it does not render first try.
- [ ] A status row: hunk i/N, +a −d, position %.

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
