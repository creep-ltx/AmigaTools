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
- [x] **b102: busy pointer while working** (his ask, and the third
      of directory mode's parked items). SetWindowPointer with
      WA_BusyPointer around loaddiff and scandirs, plus
      WA_PointerDelay so it only appears if the job actually takes a
      moment - a fast load never flashes it. WRAPPED rather than
      threaded through: loaddiff has four exit paths and every one
      would have had to clear the pointer, so the inner function was
      renamed and the wrapper does it once. V39+; older Kickstarts
      keep the normal pointer, as they always did.
- [x] **b103: the intra-line span snaps off split words** (his find,
      from a screenshot). Character-exact trimming cut INSIDE tokens:
      two MODULE lines both containing "'d" (one "'dos", the other
      "'devices") made the prefix eat it, shifting the span one
      character right so it began mid-word and ended on a stray "d".
      Now each boundary backs off a split word - the front always
      (the prefix was common, so marking more of it is honest), the
      back only while the characters moving into the suffix genuinely
      match on both sides.
      It only ever shrinks the span or grows it at the FRONT, never
      at the back: growing outward to whole words would tidy "1000"
      vs "600" (still marked "10"/"6") but would also mark text that
      DID NOT CHANGE on the other side, and marking unchanged text is
      the one thing this must not do.
      Footnote worth keeping: he reported it after misreading the
      screenshot - he saw "'d" and did not spot it was "'dos" versus
      "'devices". The reason was wrong and the report was still
      right, because a highlight that starts mid-word reads as broken
      whether or not the arithmetic behind it is correct.
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
- [x] **b73-b81: TOOLTYPES** (his ask; a config file explicitly NOT
      wanted — the icon carries the settings). Read from the
      WBStartup message, which `smain` had been discarding as
      `(void)argv`. All optional and inert when absent, so a shell
      launch is unchanged — and nothing here is reachable from CLI,
      which is worth remembering when testing.
      Final set: **OPENSCREEN** (opens a screen of our own, cloned
      from Workbench, published under that name), **SCREENDEPTH**
      (bitplanes for it, 2-8; nothing without OPENSCREEN; floored at
      2 because cdiff draws in pens 0-3 and a 2-colour screen has no
      pen 2 or 3), **PUBSCREEN** (attaches to somebody else's public
      screen), **FONT** (family/size, `.font` appended; PROPORTIONAL
      FONTS ARE REFUSED — every measurement here is columns x fw, so
      a variable-width face would render nonsense, not merely look
      wrong), **EDITOR** (beats ENV:EDITOR), **DRAWER**, **TABSIZE**
      (mask when a power of two, modulo otherwise — the roadmap's own
      warning about DIVU in a per-cell loop), **LEFT/TOP/WIDTH/
      HEIGHT**. Project icons dropped on the cdiff icon load too:
      two as a pair, one as the left side.
      **Three of his corrections shaped the final set, and two of
      them were deletions:**
      *VIEW removed (b75)* — dead by construction, not merely
      marginal: TREE re-set a view gdirmode had already set and BOTH
      re-set the zero default, so two of four values could never do
      anything on any machine.
      *PUBSCREEN removed (b77), then rebuilt (b78-b80)* — as shipped
      it only ATTACHED to a screen someone else had published, so on
      a machine where nothing publishes one it was inert. His read:
      the useful version OPENS a cloned screen. That became
      OPENSCREEN, deliberately NOT called PUBSCREEN because that
      keyword already means the opposite throughout Amiga software.
      With OPENSCREEN in place PUBSCREEN came back at b80 meaning
      exactly what it conventionally means — the pair is unambiguous,
      and OPENSCREEN's screen is itself public, so there is now
      something worth attaching to. Precedence: own screen, then a
      named one, then Workbench.
      *WIDTH/HEIGHT = -1 (b81)* — his ask, and it exposed a bug in
      the defaults: an absent WIDTH used the FULL screen width while
      ignoring LEFT, so `LEFT=100` ran the window exactly 100px off
      the right edge. Size is now measured FROM the position, so -1
      and "absent" both mean "reach the edge" and neither can
      overrun.
      The screen is closed by closemain() with the window, so an
      iconify never strands an empty cdiff screen on the display.
      The AppIcon also wears HIS icon now (DupLock of our drawer +
      the tool name from WBStartup), falling back to the generic
      tool image — the couple of lines promised at b72.
- [x] **b82-b86: THE STATUS ROW** — hunk i/N, +a −d and position %,
      in its own row above the bottom border. ONE padded Text (the
      b66 rule), sitting OUTSIDE the scroll rect so ScrollRaster
      never disturbs it, hooked into flushpaint() beside
      updscrollers() so it costs one repaint per BURST rather than
      per keypress. Hunk starts are cached and invalidated at the
      same five points as the width scan — identical lifetime, so
      they were mirrored mechanically rather than hand-picked.
      His three corrections: the text is PINNED one pixel off the
      border rather than riding the text grid (b83), so the gap does
      not vary with window height; a shine rule above it with one
      blank pixel between, calcgrid reserving those two pixels so
      content can never reach the divider (b84-b85, tried in
      SHADOWPEN and put back to SHINEPEN by eye); and both rules now
      run to the true PIXEL edge (b86) — they used to stop at
      viscols*fw, short of the right border by the remainder, which
      is why the left met the border and the right did not. That
      also exposed a sliver 0..fw-1 px wide down the right of the
      content that NOTHING had ever painted since b66 removed the row
      fills; it is now cleared once per drawpage, full height, since
      the scroll rect stops at the cell grid and never touches it.
- [x] **b87: SETTINGS MENU + non-destructive tooltype write** (his
      design: the menu IS the setting). Settings/Status bar toggles
      the row and writes STATUSBAR=YES/NO back to the icon, so the
      choice survives the next launch; the checkmark starts wherever
      the tooltype left it. The write does NOT go through
      PutDiskObject — his own point, and AmigaReferences says why:
      that rewrites the file from icon.library's in-memory parse and
      silently drops whatever the running version did not understand.
      It is the SPLICE instead, ported from CFile 0.5b51 (proven on
      400 real .info files): header + rebuilt tooltype block + suffix,
      every other byte copied untouched, and any failed bounds check
      means we leave the icon alone. Matching compares the text
      before the '=', so a parenthesised (STATUSBAR=NO) is left
      exactly where he put it.
- [x] **b88-b95: THE SCROLL "ARTIFACTS" — NOT A BUG IN THIS PROGRAM.**
      Six builds, and the fault was never in cdiff. The chase:
      WaitBlit after the scroll (b91, blitter/CPU race - wrong);
      ScrollRaster instead of ScrollWindowRaster (b93, wrong
      primitive - wrong, though it did drop the >= V39 guard and is
      what the rest of the family uses); a Fast scroll toggle to
      bisect blit vs row drawing (b92 - HIS bisection, and the first
      useful step); telemetry in the status row after the window
      title proved too narrow with two paths open (b89-b90, his
      design: a MODE of the row, not a suffix on it).
      The telemetry read `ct23 cr25 fh8 st226 rb222 | d3 483>486` -
      every number RIGHT, which is what redirected the search. Then
      his screenshots showed the seam falling BOTH ways (bottom ahead
      in one, behind in another), which no geometry error can do.
      **Settled by the question I should have asked first: does it
      survive when you stop?** It does not. It clears the instant
      scrolling stops, is identical on a stock A1200 PAL Hires with
      no RTG, and is indifferent to blit primitive or to having no
      blit at all. It is raster tearing: a 25-row repaint outlasts a
      20ms frame, so the beam displays part of the old frame and part
      of the new.
      b95 keeps WaitTOF() before the flush repaint - it does not cure
      the tearing, it makes the seam land in a CONSISTENT place
      instead of wandering, which reads as "scrolling fast" rather
      than "broken". Fast scroll stays a toggle, defaulting OFF,
      because one blit displacing 200 pixels mid-frame is more
      visible than rows being rewritten.
      LESSON, and it cost six builds: before debugging a visual
      artifact, establish whether it SURVIVES the thing that caused
      it. Transient and persistent are different worlds, and no
      amount of code-reading tells them apart.
- [x] **b96: BINARIES ARE REFUSED** (his question: "should I really
      be able to open files like binaries, images, .info files,
      modules, samples, archives?"). No — and the old behaviour was
      not merely useless, it MISLED. A line diff of a binary breaks
      "lines" at stray 0x0A bytes that mean nothing and renders every
      non-printable as '.', so two rows that genuinely differ were
      flagged as changed and drawn as a bar WHILE LOOKING IDENTICAL:
      the tool saying "these differ" and then showing nothing. That
      is the same lie b24 refused for the Tree's same-size pairs and
      the find refuses by only searching what is on screen.
      Detection is a NUL byte in the first 8K - the standard test,
      reliable for Amiga text, and cheap because only the head is
      scanned. The check runs BEFORE diff_split, so a binary never
      becomes a DLine per stray newline (which was also the real
      memory risk on a file with no lines in it at all).
      In its place, the honest verdict the machinery already had:
      both sizes and the offset of the first differing byte, or that
      the bytes are identical. The GUI shows a requester, TEXT prints
      the same and exits 5 (WARN) - the TEXT road is the regression
      gate, so it must not disagree with the GUI about what a binary
      is. Proven under vamos across all four cases (text pair,
      binaries differing, binaries identical, one of each) before it
      reached a boot.
      Deliberately NOT built: an override for a file that is mostly
      text with a stray NUL. His call to start with refuse-and-report;
      the escape hatch waits until there is a real case for it.
- [ ] Whether SCREENDEPTH=2 measurably beats a 4-plane Workbench on
      his machine. Blit cost is per bitplane, so it should — worth
      confirming rather than assuming.

- [x] **b104-b105: DIFFERENCES ONLY** (his ask). Settings /
      Differences only, **Amiga+D**: unchanged runs collapse to a
      centred marker row, "-- 47 lines --", drawn in WHITE (b105,
      his eye) so the marker RECEDES - it says "nothing here", and
      the same palette hierarchy b4 used to push the gutter back.
      The design is a DISPLAY MAP over the active view: each entry is
      either a real row index or a NEGATIVE number carrying how many
      rows were collapsed there. vcount() returns the map length, so
      scrolling, the scrollbars, the status row and the position
      percentage keep working with no idea the filter exists - only
      three places translate a display index into content (the two
      row painters, and rowhas/calchunks for find and the hunk
      counter). Rebuilt lazily and invalidated at the same five
      points as the width scan and hunk index; same lifetime, so they
      were mirrored mechanically rather than picked by hand.
      **CONTEXT=n** (default 3) keeps that many unchanged rows either
      side of a change - context is what makes this readable rather
      than merely shorter, since a changed line with nothing around
      it is hard to place. Toggling maps the current top row across
      so the reader stays where they were, and n/p treat markers as
      boundaries. File views only, by construction: the Tree already
      shows only differing entries.
      **FASTSCROLL=YES/NO** added in the same build (his ask) so that
      setting survives a launch too, written back from the menu like
      STATUSBAR. Differences only is deliberately NOT persisted - it
      is a mode you flip while reading, not a preference.

- [x] **b106: the shell start, and a leaked library** (his question:
      "what happens if it's started without an icon?"). Workbench
      cannot launch it without one, so the real case is a SHELL
      start: readtooltypes never runs, every default applies, the
      AppIcon uses the generic tool image, and the Settings toggles
      apply for the session with nothing to write them back to.
      Two things that question exposed. icon.library was opened
      TWICE on a Workbench start - once in smain for the tooltypes,
      again in guimode - and closed once, leaking a reference every
      run. And bare `cdiff` from a shell FAILED with "required
      argument missing": FILE1/A,FILE2/A meant the one road that can
      show the window without knowing both names was the one road you
      could not take from a shell. Both files are optional now (`cdiff`
      opens empty, `cdiff onefile` fills that side and asks for the
      other, exactly like a single dropped icon); TEXT still requires
      both, because a listing of nothing is not a listing.
- [x] **b107-b109: FONT=Topaz/8** (his find, and three of his
      observations solved it). It rendered in a thin ~6px face
      instead of topaz 8. **The mechanism: FONTS:topaz.font on disk
      offers only size 11, so diskfont SCALED it down to 8** - and a
      squeezed topaz still lays out correctly on a character grid,
      which is why nothing looked broken, only wrong. The real topaz
      8 and 9 live in ROM, and were never consulted because
      OpenFont's list is case-sensitive: "Topaz.font" misses
      "topaz.font", so the search fell through to disk.
      Fixed three ways: try the ROM/memory list FIRST via OpenFont
      and only then OpenDiskFont; validate on BOTH roads (refuse
      proportional, refuse anything not FPF_DESIGNED, refuse a
      different height); and retry the whole search lowercased, since
      the font list is case-sensitive while the filesystem is not.
      b108's retry was gated on a NULL return, which never happens
      when diskfont hands back something scaled - a rejected font now
      falls through to the next road instead of ending the search.
      His three data points did the work: only Topaz broke,
      MicroKnight/8 was fine EVEN as the Workbench font, and
      FONTS:topaz has 11 only. I was wrong twice before that: I
      abandoned the correct scaled-font theory when the WB font came
      up, then predicted the fallback would give him topaz when his
      system font is MicroKnight7/7.

## 0.1b3 — directory mode

- [x] **DIRECTORY MODE (build b16, 1.8.26)** — `cdiff DIR1 DIR2`
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
      free.
      **BOOT GATE CLOSED 2.8.26, his verdict: "I have tried it and
      it works."** Two of the three knowingly-parked items are
      settled: the content check for same-size pairs shipped at b24
      (the chunked byte compare), and the busy pointer at b102. The
      third is still open and now has its own entry below.
- [ ] **ExAll batching for the tree scan** (CFile's I3 lesson) — the
      scanner walks with ExNext one entry at a time. It matters on
      real media, not on a hard file: a big drawer on a floppy or a
      slow IDE is where the difference shows. Worth measuring on his
      hardware before writing it, the way SCREENDEPTH should be.
- [ ] Intra-line highlight in the single-file tabs — b97 does the
      Both tab only, because the paired line is not in that view.
      Needs a reverse line->row map (an int per line per side), which
      is real memory on a 12000-line pair; measure before assuming
      it is affordable.

## 0.1b4 — engine deepening

- [ ] **Myers middle-snake — BUILT (b99), MEASURED, REMOVED (b101).**
      Patience anchors on lines unique in BOTH files, so a block with
      no unique lines degrades to "delete all n, insert all m". Myers
      fixes exactly that, and the implementation worked: three
      harness cases proved it, and proved they had TEETH (with the
      cap forced to 0 they failed with exactly 0 equal lines).
      It was removed anyway, on his call, because it was measured:
      on the real cfile/cfile13 pair it cost **+9% time for TWO extra
      matched lines and 71 more hunks**, and comparing the outputs
      showed most of the difference was hunk boundaries shifting
      rather than better alignment. The cause: rec() trims the common
      prefix and suffix BEFORE middle() is reached, so genuinely
      anchorless blocks are rare in a fork-style diff — Myers only
      ever got the leftovers.
      Removal verified by the op stream returning byte-for-byte to
      the pre-Myers baseline (489 hunks, +1083/-2145, against b99's
      560/+1081/-2143).
      LESSON: this was a roadmap item that sounded better than it
      measured. Building it was the only way to find that out, and
      deleting it afterwards is the right end to that story - not a
      wasted build. Reopened as a known, deliberate limitation rather
      than a promise: if a real file pair ever shows a block that
      badly needs it, the measurement is here to argue against, and
      the git history has the working implementation.
- [x] **b97-b98, b100: INTRA-LINE CHANGE HIGHLIGHT** (his pick, and
      the one that changes daily use most). On a '|' row, trim the
      longest common prefix and suffix and mark what is left — two
      cheap scans instead of a character-level LCS, which is what
      real edits look like: an identifier renamed, a number changed.
      Compared in EXPANDED column space, using the same tab rule and
      control-char substitution drawtext renders with, so the span
      can never disagree with what is on screen. Up to three Text
      runs per side (before / changed / after), each pixel still
      written exactly once. b98: BLACK on the bar's own blue (his
      call) rather than b97's inversion to blue-on-white, so the row
      still reads as one surface. Only '|' rows, and only the Both
      tab — the single-file tabs would need a reverse line->row map.
      **b100: a COMPILER BUG, found from his screenshot.** He asked
      why the D in DEF was a different colour. The span was starting
      one character in on every changed line. The prefix scan was
      a THREE-term condition:
          while (p < la && p < lb && ca[p] == cb[p]) p++;
      and bebbo's gcc MISCOMPILES that at -O2 on m68k: it returned
      p=1 where the answer is 11. -O1 and -O0 are correct, and so is
      the two-term suffix loop beside it. Adding a printf inside the
      function also "fixed" it — the giveaway. Hoisting the bound
      out of the condition fixes it at -O2 (and is better code: one
      compare per iteration instead of two).
      LESSON: the engine has a host-AND-target harness precisely so
      the two can be compared, and I spent a long time on pixel
      forensics of a screenshot before running the target build under
      vamos. One command would have shown the divergence
      immediately. When behaviour differs from what the source says,
      run it on the target BEFORE analysing the display.
- [ ] Intra-line change highlight on `|` rows (char-level diff of
      the paired lines).

## Parked

- Merge/copy-hunk actions (left→right) — an editor's
  responsibilities creep in; decide after directory mode.
- MUI/ReAction front-end — GadTools-free custom draw is serving.
