# CCON — build plan

**The goal:** CCON: — an LTX console handler. What CON: is, what
KingCON and ViNCEd are: a mounted DOS handler speaking the packet
protocol, hosting any client — including the real shell inside
CTerm's frame (swap one string: `CCON:0/0/0/0/CTerm/WINDOW0x…`).
The one feature that justifies it: **output scrollback**, verified
impossible with the stock V47 con-handler (no such option in its
ROM option table). The renderer, the 4000-line scrollback model,
the line editor and the scroll keys were already built and
boot-tested in CTerm 0.1 (commit 71e29b1) — they transplant in.

## Verified facts (16.7.26, before any handler code)

- **E binaries can be handlers — the wbmessage trick, proven by
  disassembling E-VO's generated startup code:** a handler process
  has no CLI, so E's startup does WaitPort/GetMsg on the process
  port and captures the FIRST message — DOS's mount startup packet
  — into the `wbmessage` global. The exit code replies whatever
  that global still holds (reloads the same A4 slot), so
  `wbmessage := NIL` after taking the packet disarms the
  double-reply. Also seen in the disassembly: E swaps to its own
  10000-byte allocated stack before `main()`, so mountlist
  StackSize only covers the prologue.
- **Packet layouts** (from the local E includes, dos/dosextens.e +
  dos/filehandler.e): dospacket link/port/type/res1/res2/arg1-7;
  packet rides in its exec message's ln_Name; reply = ReplyPkt
  (dos.library, non-blocking); loop = WaitPkt on pr_MsgPort.
  FIND*: arg1 = BPTR FileHandle (set fh.args = our id,
  fh.interactive = DOSTRUE for a console). READ/WRITE: arg1 =
  fh_Arg1, arg2 = buffer, arg3 = length; res1 = bytes (0 = EOF,
  -1 = error). devicenode.task := our port at startup.
- **The no-DOS rule:** after the mount handshake the handler must
  not call packet-sending dos.library functions (Open, Lock, …) —
  DoPkt waits on pr_MsgPort, the same port clients send to.
  Intuition/graphics calls are fine (con-handler itself opens
  windows).

## Milestones

- [x] **M0: protocol homework** — constants from dosextens.e, the
      startup mechanics from the actual generated code (above), the
      FIND/READ/WRITE/END argument tables. Done 16.7.26.
- [x] **M1: proof of life — PASSED first boot, 16.7.26.**
      Mount handshake, FIND*/END, ACTION_WRITE rendered dumbly
      into a plain WB window, READ = EOF. Boot-verified:
      `Mount CCON: FROM DEVS:CCON-mountlist` then
      `echo >CCON: hello` — window appeared, hello rendered,
      prompt returned (all packets replied). The wbmessage trick
      works on the real OS. vamos cannot test any of this;
      FS-UAE only.
- [x] **M2: cooked reads — boot-verified 16.7.26.**
      ACTION_READ backed by the 0.1 line editor (blip
      cursor, insert editing, Ctrl word jumps, Shift ends, 32-line
      history with the half-typed-line stash); reads queue and get
      finished lines (one line per read, short buffers get the
      rest next read); type-ahead works by construction; EOF on
      Ctrl+\ (one-shot). The loop multiplexes the packet port and
      the window port via Wait() — WaitPkt is gone. Topaz 8 via
      OpenFont (ROM font: no packets — OpenDiskFont would break
      the no-DOS rule; the font milestone must solve that).
      Found and fixed on transplant: 0.1's history dedupe
      evaluated hist[Mod(-1,32)] on empty history (E OR doesn't
      short-circuit) — survivable in an app, a guru in a handler.
- [x] **M3: host the real shell — boot-verified 16.7.26.**
      `NewShell CCON:` ran a real shell (CLI 3) in the handler's
      window: prompt, dir, list, EndShell clean. Ctrl+C broke a
      running `list >CCON:` mid-stream. Packet semantics taken
      from the AROS con-handler source (real working code, not
      memory): ACTION_CHANGE_SIGNAL (arg2 = Task to break-signal,
      0 = query, res2 = old task), ACTION_DISK_INFO (zeroed
      InfoData, id_DiskType = 'CON\0', id_VolumeNode = the WINDOW
      pointer — how programs find the console window), Ctrl+C..F
      forwarded to the break owner (default: last FIND/READ/WRITE
      sender's mp_SigTask — the WRITE half found by boot test:
      the SHELL opens `list >CCON:`'s redirect, but the WRITEs
      come from list itself, so only a write-side refresh makes
      Ctrl+C reach the running command; cleared when opens hits
      0), ACTION_SEEK = DOSTRUE + ERROR_ACTION_NOT_KNOWN in res2
      (Guru Book rule), ACTION_IS_FILESYSTEM = DOSFALSE.
      **M3b (same day):** the 0.1 consume-whole CSI parser
      transplanted into the renderer (C and K honoured, state
      survives split writes — dir's `ESC[0 q` bounds request no
      longer prints), ACTION_WAIT_CHAR answered from the queue
      (DOSTRUE if input waits, immediate DOSFALSE otherwise — no
      timer yet), printable runs batched into single Text() calls.
- [x] **M4: raw mode — boot-verified 17.7.26** (multi-column dir
      via our bounds report, More raw paging + its DISK_INFO
      window-retitle trick, Ed fullscreen editing with å/ä/ö,
      Esc-x exit; ONE parked gap: see the menu item below).
- [x] **Ed's menus (four system freezes; resolved 18.7.26 by
      disassembling Ed's parser — BOOT-CONFIRMED same day, menus
      drop and pick).** Ed attaches
      menus to our window (DISK_INFO window ptr) and requests raw
      event reports at startup: four single-param SREs, `CSI 12{`
      `2{` `10{` `11{` (bytes at file 0x2083; reset `12} 2} 10}`
      on exit). The TRUE V47 report format was recovered from
      console.device 46.1's ROM builder ($13de): `CSI class;
      subclass;ie_Code;ie_Qualifier;addrhigh;addrlow;secs;
      micros|`. **C:Ed's report dispatcher (code $1708) switches
      on param 0: class 10 reads ONLY the code field —
      ItemAddress(strip, code), runs the Ed command hung off the
      MenuItem's +$22 extension (gadtools USERDATA), follows
      item.NextSelect ($20) until MENUNULL. The address halves
      that cost four freezes of guessing are never read for
      menus; class 2 divides MouseX/Y by the rastport font cell
      (utility SDivMod32) for Ed's mouse cell, class 11 feeds a
      2-char quit command, class 12 re-measures the window. And
      Ed NEVER touches the window's UserPort: an earlier LVO scan
      pinned "3× ModifyIDCMP, 6× GetMsg, WaitPort on OUR port" on
      it, but base-tracking every site (the JSR (d16,A6)
      ambiguity trap struck again) resolves them all to
      rexxsyslib — CreateRexxMsg/CreateArgstring/DeleteRexxMsg,
      Ed's ARexx port "ed" — and its own pr_MsgPort/reply ports.
      The two-consumers-on-one-port theory is disproven; what
      actually froze the old builds is unpinned (the reports were
      synthesized from IDCMP MENUPICK then — that whole surface
      is gone now).** The route Ed is really built against is the
      stock one, verified in ROM: con-handler 47.19 opens its
      window with WA_IDCMP=0 (tag at module $1bda), so menu picks
      reach console.device downstream as IECLASS_MENULIST — with
      IDCMP_MENUPICK set, Intuition delivers to the UserPort
      instead and the chain never sees the pick. Fix in 0.10:
      openwin sets NO IDCMP_MENUPICK while the M6 chain is on;
      ihchain catches class 10 under Ed's mask and ihreport
      already speaks the exact format the $1708 dispatcher
      parses. Fallback (ihon=FALSE) keeps MENUPICK + swallowed
      picks — the boot-proven 0.8 shape.
      **THE V47 SHELL HANDSHAKE (found by disassembling ROM
      shell_47.47 after typing went dead):** at startup the shell
      calls SetMode(fh,2), sends ACTION_DISK_INFO and compares
      id_DiskType against 'CON\0' ($434F4E00, module offset $669A
      onward). Match → the shell keeps mode 2 and runs ITS OWN
      line editor (HISTSIZE/NOHISTSKIPDUPS env vars, ESC[0 q
      bounds request — all in the shell, not the console). No
      match → SetMode(fh,0) and the CONSOLE owns editing. CCON
      answers id_DiskType='CCON' ($43434F4E) deliberately: the
      shell reverts us to cooked and OUR editor (blip, history,
      insert editing) owns the prompt — boot-verified: prompt,
      typing, echo, list, dir all working, raw=0 confirmed via
      title-bar telemetry. Undocumented anywhere; ROM bytes only.
      Likely also why console-side editors like KingCON fight the
      3.2 shell. AROS's 'CON\0' answer predates the V47 shell.
      ACTION_SCREEN_MODE honoured (raw parks the line editor; keys
      become bytes: Return = CR, Ctrl+C = byte 3 — no break, no
      EOF, the RKM raw contract); special keys become console
      sequences (arrows CSI A-D, shifted CSI T/S/SPACE@/SPACEA,
      F1-F10 CSI 0~..9~, shifted 1x~, Help CSI ?~ — shifted/F-key
      codes recalled from the RKM, need a boot check); reads
      deliver byte-granular in raw. WAIT_CHAR with REAL timeouts
      via timer.device (µs; input arrival wakes all waiters,
      expiry answers the head; queued waiters restart their full
      timeout on reaching the head — approximation). The renderer
      grew the full-screen CSI set: multi-parameter parsing,
      A/B/C/D moves, H/f position, J erase-below, K, L/M
      insert/delete lines — and answers `CSI 0 SPACE q` with
      CSI 1;1;rows;cols SPACE r on the input stream, so dir can
      go multi-column. **Boot test:** `dir` (multi-column now?),
      `more <file>` (single-key paging), Ed (fullscreen editing,
      arrows), Ctrl+C still breaks list, cooked editing/history
      unchanged after a raw program exits.
- [ ] **M5: the point of it all — scrollback BUILT 17.7.26,
      awaiting its boot test.** The 0.1 model transplanted and
      grown up for a full-screen console: a 4000-line byte ring
      (SBMAX × cols, allocated at window-open, New() = zeroed)
      where the last `rows` ring lines ARE the visible grid —
      sbtop indexes the top visible row, so a bottom scroll is
      sbtop++ and the old top line becomes history with no
      copying. Every draw is mirrored into the model: text runs
      (CopyMem beside each Text), tab spaces, K/J erases, L/M
      insert/delete (row-content copies inside the visible region
      only — history above stays intact); cursor moves touch
      nothing. All ring math is add/subtract wraps — no Mod, no
      DIVU (the ls lesson). Viewing = whole-grid redraw at
      viewoff; keys: Ctrl+Up/Down by line in BOTH modes (raw
      clients never receive Ctrl-arrows), Shift+Up/Down by page
      in cooked only (raw clients own shifted arrows as CSI T/S).
      Any write or any other key snaps the view back to live —
      cooked snap redraws the edit line. Title bar shows
      `[scrollback -n]` while scrolled (global buffer — Intuition
      keeps the pointer). Known cosmetic gap: leaving scrollback
      restores our own title, stomping a client retitle (More's).
      E semantics vamos-verified before deploy: FOR empty ranges
      (both directions) run zero times; inline IF-expression
      arguments work.
      **Boot test:** `NewShell CCON:`, `list SYS:` past a
      screenful → Shift+Up (pages back, title shows offset),
      Ctrl+Up/Down (line), Shift+Down back to live (blip
      returns), type while scrolled (snaps live), `dir` while
      scrolled-back output still snaps; then More a long file,
      Ctrl+Up mid-page (scrollback over raw), space (snaps live,
      paging continues), q; Ed still opens/edits/exits clean.
- [x] **M5c: real CON: open/close semantics — BOOT-PASSED
      17.7.26** (EndShell closes the window, geometry+title,
      WAIT lingers + gadget kills it, CLOSE=EOF, WAIT echo
      inspection, reopen, scrollback+completion all confirmed;
      WINDOW0x still needs its CTerm 0.3 client). The open name is parsed stock-CON:
      style: `CCON:x/y/w/h/title/options`, every field optional,
      options CLOSE (close gadget = EOF to the reader), WAIT
      (window lingers for its close gadget; a new open re-attaches)
      and WINDOW0xADDR (borrow an existing window — accepts the
      exact string CTerm 0.2 sends to CON:; we ModifyIDCMP it
      ours and restore on close, owner must stop reading its
      UserPort — the Ed lesson). The window now CLOSES on the last
      ACTION_END (stock semantics — `echo >CCON: hi` flashes;
      use /WAIT to inspect): pending reads answer EOF, pending
      WAIT_CHARs answer FALSE, the scrollback model is Dispose()d
      (vamos-verified that Dispose really frees New memory —
      50 cycles of the 252K model), fonts closed, and a fresh open
      re-creates everything from its own spec (history ring
      survives, allocated once). Close gadget handling is deferred
      past the event drain (never CloseWindow the port you are
      draining). EXAMINE_FH answers DOSFALSE +
      ERROR_ACTION_NOT_KNOWN explicitly (Guru Book; clib isatty).
      Title bar shows the parsed title; the scroll indicator
      appends to it; borrowed windows keep their owner's title.
      **Boot test:** `NewShell CCON:` (as before, but EndShell now
      CLOSES the window), `NewShell CCON:60/30/500/120/LTX-Shell`
      (geometry+title), `NewShell CCON:0/0/400/150/W8/WAIT` →
      EndShell → window lingers → close gadget kills it,
      a CLOSE-option shell → gadget click = EOF = shell ends,
      `echo >CCON:0/0/400/100/hi/WAIT hello` (window stays,
      shows hello), reopen after close (fresh model, history
      kept), scrollback+completion still fine. WINDOW0x has no
      client to exercise yet — that boot test belongs to the
      CTerm 0.3 handoff.
      **Remaining polish (later):** multiple simultaneous streams
      (needs research: how one-task handlers route `*`/CONSOLE:
      opens — KingCON forks a process per window, ViNCEd doesn't;
      until then a second open shares the window, documented).
      **M5 scrollback BOOT-PASSED 17.7.26** (scroll keys, type-snap,
      More over raw all confirmed; Ed menus render dead as parked —
      the M6 item, expected).
- [ ] **M5b: zsh-style tab completion — BUILT 17.7.26, awaiting
      its boot test.** Tab completes the word at the cursor; one
      match completes whole ('/' after a dir, ' ' after a file),
      several complete to the common prefix and open a menu of
      candidates below the prompt (drawn out-of-band, restored
      from the scrollback model on close); further Tabs cycle
      with the pick highlighted, Shift+Tab backwards, Enter
      accepts and closes (the line stays for a second Enter, zsh
      menu-select style), Esc closes, any other key closes and
      acts normally. Row space is made by scrolling the prompt up.
      **The plumbing (the interesting part):** a handler must not
      call packet-sending dos.library functions, so directory
      reading is HAND-ROLLED packets — ACTION_LOCATE_OBJECT /
      EXAMINE_OBJECT / EXAMINE_NEXT / FREE_LOCK built into one
      StandardPacket and PutMsg'd straight to the FILESYSTEM's
      port with a private reply port (never pr_MsgPort, so the
      no-DOS rule holds and clients can't interleave). The
      client's CWD for relative words: the blocked reader's
      pr_CurrentDir, found via the queued read packet's sender
      (its Read is parked in rdq while it waits for our line).
      Words with ':' resolve via LockDosList/FindDosEntry
      (semaphores, not packets): assigns scan from dol_Lock,
      volumes/devices get the whole "NAME:path" against a zero
      lock. fscall refuses to send to our own port (deadlock
      guard, covers `CCON:` paths). FIB filenames at packet level
      are C strings from some filesystems, BCPL from others —
      first-byte<32 heuristic covers both (filenames never start
      with a control byte). Struct offsets (pr_CurrentDir 152,
      fl_Task 12, dol_Task/dol_Lock 8/12, fib_FileName 8)
      cross-checked against amitools' libstructs. String logic
      (sort/common-prefix/replace/fold) vamos-tested VERBATIM via
      extracted procs; E AND/OR line continuation also
      vamos-verified. Limits (v1, deliberate): no quoted-word
      parsing, no completion when the reader's CWD lock is 0, ≤80
      candidates / one menu page (beep signals more), no
      volume-name completion for a bare word.
      **Boot test:** `NewShell CCON:`, `cd SYS:` then `cd Ut<Tab>`
      (completes to Utilities/), `type S:Startup-se<Tab>`,
      something ambiguous like `dir D<Tab>` (menu appears, Tab
      cycles, Shift+Tab back, Enter accepts, Esc closes, typing
      closes), `dir RAM:<Tab>`, `dir SYS:Prefs/<Tab>`, a
      no-match beep, and completion while type-ahead (no Read
      pending) after `list` — plus More/Ed still fine after.
      **First boot round (17.7.26): found+fixed — the bare Shift
      DOWN-STROKE is its own IDCMP_RAWKEY and closed the menu
      before Shift+Tab could arrive; menu-close now ignores
      qualifier keys ($60-$67) and key releases (bit 7). Second
      finding: Shift+Tab can arrive as RAW $42 when the keymap
      has no vanilla mapping for it — raw $42 now dispatches to
      dotab too. AND THE TEST-LOOP LESSON: a running handler
      keeps its loaded code — deploying L:ccon-handler does
      NOTHING until the next boot/remount. Every handler fix
      needs a reboot to actually test. Shift+Tab cycling
      boot-confirmed after the reboot (17.7.26).**
- [ ] **M5d: SGR colours — BUILT 17.7.26, awaiting its boot
      test.** The renderer speaks CSI ...m: 0 reset, 1 bold
      (bright pens 8-15 when the screen has 16 — the ANSI-art
      convention; depth probed via rp.bitmap), 22, 30-37 fg,
      39, 40-47 bg, 49. The scrollback model grew an attribute
      plane (second SBMAX×cols ring, fg nibble + bg nibble per
      cell) so colours survive scroll-back redraws — drawmrow
      paints attr-batched runs and is shared by redraw, live
      row repaint and menu restore. The default text pen is the
      PEN open-name option (CTerm sends PEN7 on its 16-pen ANSI
      screen where pen 1 is red); every hardcoded pen-1 became
      deffg (edit line, blip, completion menu). Erases stay
      background-0 (v1: CSI K with a coloured bg erases black).
      Paired: CTerm 0.4 ANSI mode now opens depth 4 with the
      16-colour palette (8 = the grey his scheme wants) and
      band ANSI art maps bold to bright pens; ls colours
      directories blue (1;34) and hidden-class entries grey
      (1;30) in BOTH builds (16-combo differential still
      byte-identical; the colour path itself is interactive-only
      — boot verifies it). FIRST BOOT ROUND PASSED (his
      screenshot: blue dirs, grey .infos, light-grey text, red
      art) except the completion menu drew plain — SECOND ROUND:
      menu candidates now colour like ls (flag byte grew a
      hidden bit; hidden grey, dirs bright blue, WB-blue pen 3
      on screens without 16 pens), and CTerm opens 16 pens in
      BOTH themes (non-ANSI = CMenu-LIGHT grown to 16) so the
      scheme works on the classic light look too.
- [ ] **M6: input.device-handler input — BUILT 17.7.26 ($VER 0.9),
      deployed as a SEPARATE TEST DEVICE, awaiting its boot test.**
      Key acquisition moved out of IDCMP: an Interrupt added with
      IND_ADDHANDLER at priority 20 (below Intuition's 50 — menu
      operations arrive already digested into IECLASS_MENULIST —
      above console.device's 0). The interrupt's is_Code is an E
      proc: a glue stub whose MOVEM really is the first instruction
      (a 0-arg/0-local E-VO proc gets NO prologue — read out of the
      generated code), restores the A4 captured at startup from
      is_Data, saves D2-D7/A2-A6 (E procs clobber freely), calls
      ihchain with the chain as its one stack arg (caller pushes,
      caller cleans, result in D0 — all disasm-verified, including
      the compiled install block, field offsets, the pure asl.l Shl
      helper it borrows, and Signal = LVO -324). ihchain runs in
      input.device's task: events for our window while it is ACTIVE
      (IntuitionBase.ActiveWindow, offset $34 verified) are copied
      into a 64-slot ring (stride 32, free-running indices, no
      Mod/Mul) and neutralized to IECLASS_NULL; the main loop
      drains on a private signal. RAWKEY downs run through the
      existing dispatch (dorawkey/rawcsikey grew a consumed flag),
      then keymap.library MapRawKey — NOT auto-opened by E, only
      the big four are; the disasm caught the NIL base — with the
      dead-key bytes riding in ie_EventAddress, so Swedish
      composition survives. Cooked feeds only 1-byte images to
      dovanilla (Intuition-VANILLAKEY parity; multi-byte = F-key
      CSI strings); raw enqueues all mapped bytes. Releases are
      dropped whole (nothing used them; letting them through would
      snap the scrollback view on key-up). Raw event reports are
      LIVE again for evmask classes, carrying Intuition's REAL
      ie_EventAddress (the freeze experiments had to guess here —
      the freezes were the UserPort fight, not the report format).
      With the chain on, keys never touch IDCMP, and 0.10
      (18.7.26) finished the shape: the window carries ONLY
      IDCMP_CLOSEWINDOW (stock con-handler 47.19 opens with
      WA_IDCMP=0, read from the ROM tag list) — IDCMP_MENUPICK
      would make Intuition deliver menu picks to the UserPort
      instead of downstream as IECLASS_MENULIST, which is the
      route Ed's disassembled parser actually consumes (see the
      Ed's-menus item above; the first 0.9 boot showed menus
      dropping but picks dead — consistent with the pick dying in
      the parked port, though a silent fall back to ihon=FALSE
      would look identical, so 0.10 also appends " [no chain]" to
      the window title whenever the fallback is in effect: one
      glance now separates the two). While evmask is set the
      UserPort drain is PARKED —
      not for the disproven two-consumers theory, but to defer a
      close-gadget click while a raw-events client owns the
      session; leftovers drain when the mask clears (CSI },
      cooked reversion — SetMode 0 clears evmask, Ed sends no
      CSI } — or close). Every failure path (no signal, no ring,
      no keymap.library, no port/req/device/interrupt) leaves
      ihon=FALSE = the boot-proven IDCMP path end to end.
      **Deployed as L:ccon-handler ($VER 0.10 18.7.26; the 0.8
      build is kept beside it as L:ccon-handler-m5), so the M5d
      round-2 colour check and this experiment share the same
      test window.**
      **BOOT RESULT 18.7.26: menus WORK — drop and pick confirmed
      by Tobias on the 0.10 boot.** Follow-up in 0.11 (same day):
      raw mode never rendered a cursor, and Ed draws no marker of
      its own — on stock CON: the console.device block cursor is
      Ed's position marker. 0.11 adds it: an inverse-video cell
      from the model at (cx,cy), deffg block on empty cells so it
      is never invisible; curserase()/cursdraw() wrap the raw
      write path (so interior ScrollRasters never smear it), the
      SetMode transitions (appears on raw, yields to the blip on
      cooked), and the scrollback view (hidden while viewing,
      back on snap). Cooked keeps the blip — no double cursor.
      Second follow-up, 0.12 (18.7.26): Ed's text rendered RED
      under CTerm's dark theme — not a CCON bug: C:Ed hardcodes
      Workbench pen numbers (four `ESC[33m`/`ESC[31m` pairs in
      the binary: status messages in 33 = WB blue, body text
      restored with 31 = WB BLACK), and the ANSI palette puts red
      at pen 1. Ed has no colour option (ReadArgs template
      checked). Fix: new `WBPENS` open option — plain SGR 30-33
      retarget as WB pens at the theme (30→0, 31→deffg, 32→15,
      33→12; 16-pen screens only, bold forms and backgrounds
      untouched so the ls scheme and ANSI positions survive);
      CTerm sends `/PEN7/WBPENS` on its ANSI screen (cterm
      rebuilt + deployed). Light theme needs nothing (its pen 1
      is already black = WB semantics).
      **Boot test (reboot first — handler seglists only reload
      then):** `Version L:ccon-handler` should say 0.12, then
      `NewShell CCON:` — (1) regression: typing, å/ä/ö, history,
      Ctrl+word-jumps, Tab completion menu incl. Shift+Tab,
      scrollback keys, Ctrl+C break, `dir`, More paging, window
      drag/close gadget, EndShell; (2) menus in Ed: CONFIRMED
      WORKING on the 0.10 boot (pick → IECLASS_MENULIST → ihchain
      → V47 report → Ed's ItemAddress walk); still to check: Ed's
      mouse cell-click positioning (class 2 reports), Esc-x clean
      exit, cooked after; (3) NEW in 0.11: the block cursor — Ed
      shows a filled cell at the edit position, it moves with
      typing/cursor keys, More shows one at its prompt, no ghost
      blocks left behind by scrolling, scrollback view hides it
      and snap-back restores it, and back at the shell prompt the
      cooked blip is the only cursor; (4) NEW in 0.12: Ed's text
      is grey (not red) under CTerm's dark theme, Ed's status
      messages show in blue, and `ls` colours are unchanged
      (blue dirs, grey hidden); (5) two-window check: a stock
      CON: shell alongside — keys go to whichever window is
      active.
- [x] **M7: copy & paste — 0.13 built on chain mouse, DISPROVEN
      by the 0.14 telemetry boot (title counters M40 S1: button
      DOWNS reach pri 20, select-up and motion NEVER do —
      Intuition consumes them; V412 P0 proved RAMIGA-V arrives
      and maps fine, clip was just empty). 0.15 reroutes mouse
      onto IDCMP, the KingCON way: setidcmp() recomputes the
      window's flags from state — MOUSEBUTTONS in whenever no
      client holds CSI 2{ (out while Ed owns the mouse: class-2
      reports need the events downstream, the MENUPICK lesson
      applied to mouse), MOUSEMOVE in only mid-drag
      (WA-less ReportMouse(TRUE) makes motion exist, the IDCMP
      bit gates delivery). Selection therefore works in the
      IDCMP fallback too; paste stays chain-only (keymap path).
      RAMIGA-C re-copies a standing highlight (the +400 tell was
      him trying it — free muscle-memory win). Still in: 0.14
      title telemetry, strip before commit.** The selection
      machine itself is unchanged, reading positions live from
      win.mousex/y (the pattern Ed's own class-2 handler uses,
      per its disassembly). **0.15 selection/copy/paste
      BOOT-CONFIRMED same day ("It works!").**
- [x] **Wrapped edit line — 0.16 (18.7.26), BOOT-CONFIRMED same
      day. Telemetry stripped in 0.17 (the committed build).** The
      cooked line was hard-capped at one row (insert refused past
      the right edge). Now it wraps like the stock shell: the
      overlay spans rows below the anchor, growing past the
      bottom scrolls the whole screen (edroom — the dotab menu
      loop's pattern, anchor and output cursor track), the blip
      wraps with it, eraseedit clears every row the previous
      draw used (edlast), and capacity is LINEMAX or the grid
      below the anchor, whichever is smaller (edcap). History
      recall truncates to the same cap. The completion menu's
      rows freeze at open (tcmrow0) and cycling rejects
      candidates that would grow the line down into the menu.
      **Boot test:** type past the right edge — the line wraps
      and editing works across rows (cursor keys, word jumps,
      backspace over the boundary, blip on the right row); type
      until the screen scrolls (prompt walks up); Return
      commits a wrapped line correctly into the transcript and
      scrollback; history-recall a long line; Tab completion
      with a wrapped line (menu sits below the LAST row, cycling
      candidates never overwrites the menu); paste a long line
      (RAMIGA-V) — it wraps as it types. Cells highlight in inverse video
      (drawselrow: attr-batched runs split at the selection
      boundary, fg=bg empties get deffg like the block cursor);
      RELEASE copies to clipboard.device unit 0 as IFF FORM
      FTXT/CHRS — the stock console family's format, so CCON⇄
      stock CON: interop both ways is the acid test. While the
      button is down, ACTION_WRITEs are PARKED unreplied (wq,
      16 deep) — output freezes under a drag like the stock
      console — and flushed FIFO on release; closewin and a
      lost-button-up belt (any key while wqn>0) also flush, so
      writers can never hang. RAMIGA-V pastes: CMD_READ unit 0
      (read cycle run dry — clipboard rule), parse FTXT, inject
      CHRS text as typed input — cooked feeds the line editor
      byte by byte (LF→Return, so a pasted command executes),
      raw enqueues verbatim (pasting into Ed). Selection lives
      on whatever the view shows, scrollback included (copy an
      old error without snapping). Clipboard.device is
      IO-request-only = handler-safe (the timer.device rule),
      opened lazily, kept. Any output/real key/fresh click
      clears the highlight; bare qualifiers keep it. Chain-only:
      the IDCMP fallback has no selection and no paste.
      **Boot test:** reboot, Version = 0.13; (1) drag over shell
      text — inverse highlight follows, release keeps it; (2)
      `RAMIGA-V` in the same window — the text types back
      (multi-line = lines execute); (3) drag during `list` of
      something long — output FREEZES mid-drag, resumes on
      release; (4) interop: copy in CCON, RAMIGA-V into a stock
      CON: shell; select+copy in stock CON:, RAMIGA-V into CCON;
      (5) scroll back (Shift+Up), select old text, copy, snap
      live, paste; (6) paste into Ed (raw path); click in Ed
      does NOT start a selection (Ed owns the mouse via CSI 2{);
      (7) regression: menus in Ed still pick, block cursor
      clean, completion menu closes on click.

## Design notes

- One stream, one window for M1 — fh.args is already a per-open id
  so multiple streams can come later without protocol changes.
- The window stays open after the last ACTION_END in M1, so the
  output can be inspected; real open/close semantics are M5.
- Debugging: no WriteF after the handshake (the no-DOS rule; E's
  lazy stdout would try to open a console). If logging is needed,
  render into the window or blink the screen.
