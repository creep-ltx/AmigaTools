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
- [x] **M5: the point of it all — scrollback BUILT 17.7.26,
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
- [x] **M5b: zsh-style tab completion — BUILT 17.7.26, awaiting
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
- [x] **M5d: SGR colours — BUILT 17.7.26, awaiting its boot
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
- [x] **M6: input.device-handler input — BUILT 17.7.26 ($VER 0.9),
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

- [x] **M8: window resize — BUILT 18.7.26 ($VER 0.18),
      BOOT-CONFIRMED same day.** WA_SIZEGADGET + WA_MIN/MAX limits on own windows,
      IDCMP_NEWSIZE in the base set (borrowed windows react too
      if their owner ever resizes). doresize(): grid recomputed
      (gridcalc, shared with openwin), and the scrollback model
      follows - the ring is cols-stride, so a width change
      reallocates both planes and row-copies the old content
      (rows stay rows, no reflow - family behaviour); allocation
      failure degrades to no-scrollback rather than rendering
      through a wrong-stride model. Height loss scrolls the tail
      into history (cursor/anchor clamped), everything repaints
      from the model, the wrapped edit line re-wraps at the new
      width for free, and a raw client holding CSI 12{ gets the
      class-12 report - Ed re-measures itself, exactly why it
      asks. Open menus/selections/drags die cleanly first.
      **Boot test:** drag the size gadget on a `NewShell CCON:`
      window - (1) shrink/grow width: text re-clips per row (no
      reflow), prompt+wrapped edit line re-wrap, typing works at
      the new width, dir columns adapt (client asks per command);
      (2) shrink height: bottom-anchored tail scrolls into
      history (Shift+Up shows it); (3) scrollback + selection +
      copy still work after several resizes (model realloc); (4)
      Ed: resize mid-edit - Ed re-draws itself to the new size
      (class-12 report path); (5) More: page width adapts on the
      next file.

- [x] **ANSI/WB colour separation — 0.19 (18.7.26),
      BOOT-CONFIRMED same day.** His WB-screen report: ls colours washed out — the
      mirror image of the Ed bug (ls assumes ANSI pen positions,
      Ed assumes WB ones; C:List emits no SGR at all, binary
      checked). The separation, CTerm as declarer: WBPENS in the
      open name = "this palette is truly ANSI" → conventions
      as-is (bright pens, WB-pen translation). NO declaration =
      foreign screen → plain 3x stays RAW pens (stock
      console.device semantics, Ed natively right), and ANSI
      colour INTENT — the bold+3x forms — translates by COLOUR:
      ObtainBestPenA per bright ANSI colour against the screen's
      colormap at open (released at close; pens >15 rejected,
      the attr plane's nibble). Bare SGR 1 without a 3x
      recolours nothing (cursgr flag). Completion menu follows
      (anstab greys/blues, classic pen-3 blue fallback).
      **Boot test (WB `NewShell CCON:`):** ls — dirs real blue,
      hidden real grey, plain black; Ed — black text, blue
      status; then inside CTerm ANSI — everything as before
      (wbpens path untouched).

- [x] **M9: the stock option set + CRAW: — BUILT 18.7.26 ($VER
      0.20), boot 18.7.26: 0.20 live, CRAW: CONFIRMED (own
      window - it is its own handler process, the architecture
      demonstrating itself), close-gadget default + regression
      all green. The window OPTIONS could not be exercised: they
      parse on the FIRST open only, and a shell held the window,
      so every test open attached to it - the M5c single-window
      rule, now the visible wall. Hence M10.** The V47 option table (read from ROM
      con-handler 47.19 at $1c34) minus the premium tier: AUTO
      (open succeeds windowless, ensurewin() materializes the
      window on the first WRITE/READ/WAIT_CHAR/SCREEN_MODE/
      DISK_INFO; an AUTO that never opened resets with its last
      close), SCREENname (LockPubScreen for the OpenWindow, name
      case-preserved from the raw token, NIL/failed = default
      public screen), NOBORDER, NODRAG, NODEPTH, NOSIZE,
      BACKDROP, INACTIVE, NOCLOSE — and the close gadget is now
      ON by default like a stock 3.2 shell window (CLOSE kept
      for compatibility). CRAW: = second mountlist, same binary,
      Startup = "RAW" (dn_Startup BSTR, >1024 = BPTR heuristic):
      that instance opens streams raw from byte one; the block
      cursor stands at home on open. Skipped for later: SMART/
      SIMPLE (we are effectively smart-refresh), ALT, ICONIFY.
      **Boot test:** (1) `NewShell CCON:` — close gadget present
      by default now, click = EOF/EndShell; (2)
      `echo >CCON:0/0/300/80/auto/AUTO/WAIT hi` — window appears
      only when echo writes; also `dir >CCON:.../AUTO/CLOSE`;
      (3) `Mount CRAW: FROM DEVS:CRAW-mountlist` +
      `type file >CRAW:0/0/400/120/t/WAIT` — raw window, block
      cursor; (4) NOBORDER/NODRAG/BACKDROP/INACTIVE windows look
      and act the part; (5) SCREENWorkbench opens there
      explicitly; (6) regression: CTerm WINDOW0x unaffected,
      resize/colours/copy-paste as before.

- [x] **M10: a window per open — COMPLETE, the full B/C/D/E ladder
      BOOT-PASSED 18.7.26 on the 0.24/0.25 boots: two shells two
      windows, options per open (AUTO/WAIT confirmed), cross-window
      copy/paste both directions including INTO a raw CRAW: window,
      CRAW: process alongside CCON:'s (item E's screenshot shows
      Startup-sequence in a CRaw window with a paste landed in it).
      Edit-line selection works since 0.25 (the drawedit mirror).
      Final 1.0 fix: a bare qualifier down-stroke no longer snaps
      a scrolled view to live — pressing Shift mid-Ctrl+Up-scroll
      to switch to paging used to throw the view to the prompt
      first (the M5b bare-Shift menu lesson, applied to snaplive;
      bit-7 releases excepted too for the IDCMP fallback).
      CTerm's WINDOW0x handoff carried forward from its 0.20
      verification (architecture beneath it unchanged) - re-verify
      casually on the next CTerm session. Released as 1.0.
      STEP A BOOT-PASSED 18.7.26 ($VER 0.21): the full regression
      sweep green on one shell. A bonus specimen from the boot: two
      shells on the shared console showed `ls`'s bounds-report
      being stolen by the other shell's queued read ("nknown
      command" - the report's CSI bytes eaten by the renderer in
      the echoed error) - the exact input-routing disease steps
      B-E cure, photographed live.**
      **Step A (the struct-ification): every per-window global —
      ~100 of them — moved into ONE `console` OBJECT reached only
      through `curcon`; shared state (ports, timer/clipboard/input
      devices, keymap, fs plumbing, the one chain) stays global.
      The rename was scripted (word-boundary, string/comment-safe)
      and the compiler was the net: the old globals ceased to
      exist, so any missed site failed the build. E adaptations:
      the six `:STRING` globals became E-strings allocated once in
      coninit() (OBJECT fields cannot be STRING), and field ++/--
      became `:=` forms (member inc/dec not relied on). The object
      is New()ed at mount time — allocation failure now REFUSES the
      mount (ReplyPkt DOSFALSE) instead of running half-built.
      Byte arrays sit last in the object so LONG fields stay
      aligned. tcpool moved per-console (4K each — per-window menus
      must not share candidate storage in step B).
      **THE BUILD GREW PAST THE 16-BIT SMALL MODEL: compile with
      `LARGE` now** (`ecompile ccon-handler.e ccon-handler LARGE`) —
      member indirection pushed string-pool references out of 32k
      range. Verified against the 0.20 binary before deploy, not
      assumed: startup stage 2 is byte-identical except the two
      expected constants (startup allocation $40f0→$2eb8 — the
      static arrays moved to the heap object — and the LINK A4
      frame), wbmessage still captured into (-$24,A4) by the same
      code, and gluestub's 22 bytes are identical, so the handler
      trick and the chain hookup survive the model change. Smoke-
      tested under vamos (the no-mount usage path runs, exit 5).
      Deployed as L:ccon-handler (0.20 kept as L:ccon-handler-0.20).
      **Boot test (step A = behaviour IDENTICAL to 0.20):**
      `Version L:ccon-handler` says 0.21, then the standing
      regression sweep — `NewShell CCON:` typing/å-ä-ö/history/
      Ctrl+word-jumps/Tab completion menu incl. Shift+Tab/
      scrollback keys/Ctrl+C break/dir/More paging/Ed (menus,
      block cursor, resize mid-edit)/copy&paste both ways/window
      resize/EndShell closes; `echo >CCON:0/0/300/80/auto/AUTO/WAIT
      hi`; CRAW: raw window; CTerm WINDOW0x handoff. Anything that
      behaves differently from 0.20 is a step-A bug.
      **STEP B BUILT 18.7.26 ($VER 0.22), awaiting its boot test —
      a window per open, live.** Consoles are a singly-linked list
      (mutations Forbid-bracketed: ihchain walks it from
      input.device's TASK, which Forbid holds off — it is not a
      real interrupt). Every create-open builds its own console:
      coninit + parsecon per open (the M9 options finally apply to
      every window), openwin per open, destroyed on the last END
      (conclose: closewin → unlink → ring-scrub → Dispose).
      `*` and CONSOLE: opens ATTACH to the sender's console instead:
      pr_CLI → cli_StandardInput → fh_Args = the console pointer,
      validated against the list before trust; fallbacks are the
      sender-as-breaktask walk (WB-launched clients with no CLI —
      More's Open-then-SetMode pattern), the active window, the
      list head. curcon is set ONLY at dispatch boundaries:
      END/READ/WRITE by fh_Arg1 (validated — a stale handle gets
      ERROR_OBJECT_NOT_FOUND, not a guru), WAIT_CHAR/SCREEN_MODE/
      CHANGE_SIGNAL/DISK_INFO by conbysender (they carry NO handle),
      window events by the per-console UserPort walk (closereq may
      destroy a console mid-walk: next pointer taken first), chain
      events by a console tag in the ring slot (ihev grew `con`;
      conclose scrubs dead tags — ihdrain validates too, but a
      later console could reuse the address), timer expiry by
      `timercon`. The ONE timer request serves one console's head
      waiter at a time; the next console with waiters gets a fresh
      full timeout (the documented approximation, per-console now).
      Arming: `armed` per console, set LAST in openwin, cleared
      FIRST in closewin — conbywin gates the chain on it, so a
      half-built window takes nothing (the old ihwin discipline,
      per console). A windowless console (failed AUTO open) replies
      its parked packets before its memory goes away.
      **Behaviour changes, both stock-CON:-faithful:** a WAIT
      window still lingers for its gadget but nothing RE-ATTACHES
      to it any more — a new open is a new window (0.20's re-attach
      was the single-window rule's workaround); and a bare
      `list >CCON:` redirect gets its own default window now, like
      `>CON:0/0//100` does on stock.
      **Memory knob (punted as designed):** every window gets the
      full SBMAX model — ~600K/window at 80 cols. Fine on the 64MB
      FS-UAE box; revisit for small real hardware (a SECONDARY
      option or a smaller default ring are the candidates).
      **Boot test (the B/C/D/E ladder):**
      (B) `Version L:ccon-handler` = 0.22; `NewShell CCON:` twice —
      TWO windows now, CLI numbers distinct; type in each: input
      stays with its window (the stolen-bounds-report screenshot
      cannot recur: `ls` in both windows, correct columns in both);
      EndShell in one closes ONLY that window; keys follow the
      ACTIVE window (the chain routes by ActiveWindow).
      (C) the M9 option list, per open at last:
      `NewShell CCON:60/30/500/120/LTX-Shell` (geometry+title with
      another shell already up), `echo >CCON:0/0/300/80/a/AUTO/WAIT
      hi` (window on first write, lingers), NOBORDER/BACKDROP/
      INACTIVE/NOSIZE/SCREENWorkbench opens, a CLOSE-gadget EOF,
      `NewShell CCON:0/0/400/150/W8/WAIT` → EndShell → linger →
      gadget kills it, and a NEW open while it lingers opens its
      OWN window (the behaviour change, deliberate).
      (D) per-window regression: Ed in window 1 while a shell works
      in window 2 (menus, block cursor, class-12 resize), More
      paging in one while the other scrolls, copy in one window →
      RAMIGA-V into the other (and into stock CON:), scrollback/
      completion/history per window, Ctrl+C breaks the RIGHT
      window's command, drag-select freezes only ITS window's
      writer, resize each window independently.
      (E) `Mount CRAW: FROM DEVS:CRAW-mountlist` + a CRAW window
      beside two CCON windows — separate process, both lists alive;
      CTerm's WINDOW0x handoff still lands on its frame.
      **Step B also retires:** the M5c "second open shares the
      window" documented limitation, and the M9 "options parse on
      the first open only" wall — re-test both READMEs' claims
      after the boot and update them.
      **First 0.22 boot (18.7.26): two windows with distinct CLI
      numbers CONFIRMED. Found on the same boot — a LATENT M5b
      completion bug, fixed in 0.23:** tcreplace replaced the word
      from tcws (the WHOLE word, dirpart included) while candidates
      are bare names, so `version l:c<Tab>` completed to
      `version ccon-handler` — the `l:` eaten. Plain words never
      showed it, which is how it survived every M5b boot. Fix:
      `tcws := sep` once the dirpart is split off, so replacement
      starts after it. Re-test on the next reboot:
      `version l:c<Tab>` → `version l:ccon-handler`,
      `type S:Startup-se<Tab>` → keeps its `S:`,
      `dir SYS:Prefs/<Tab>` → menu candidates keep `SYS:Prefs/`
      while cycling, and plain `cd Ut<Tab>` unchanged.
      **Second latent find, fixed in 0.24 — Enter in the menu
      EXECUTED the line (his `ed S:<Tab>` pick ran `ed S:CMenu/`),
      Esc would have WIPED it. Latent since M6:** every key goes
      through dorawkey now, and its close-menu-on-any-raw-key
      clause fired on Return's raw $44 BEFORE dovanilla could see
      tcactive - so the zsh accept-and-stay semantics (boot-proven
      on the pre-M6 IDCMP path, where Return arrives as VANILLAKEY
      only) silently died there. Fix: the clause excepts $44/$43
      (Return/keypad Enter) and $45 (Esc) so dovanilla's tcactive
      guards run again. Re-test: menu open → Enter accepts, line
      STAYS (second Enter executes); menu open → Esc closes, line
      survives; any other key still closes the menu and acts.
      **0.24 boot (18.7.26): completion fixes CONFIRMED (l:c keeps
      its l:, menu-Enter accepts-and-stays, menu-Esc keeps the
      line), AUTO/WAIT window confirmed, two shells two windows
      confirmed, cross-window copy/paste from committed text
      confirmed. Third latent find, fixed in 0.25: drag-selecting
      the EDIT LINE blanked its text and copied nothing - the
      overlay was pixels only, so drawselrow repainted its rows
      from empty model cells. Fix: drawedit MIRRORS the typed text
      into the model (deffg attr) and eraseedit empties the mirror
      with the pixels - the prompt line now selects, copies and
      survives selection repaints like any cell; commit renders
      the real line over the same cells, so the transcript path is
      unchanged. Known cosmetic remainder: the blip vanishes
      between a copy-release and the next keypress.
      Re-test on the 0.25 boot: type at the prompt WITHOUT Enter,
      drag over the typed text - it highlights and STAYS VISIBLE -
      release, RAMIGA-V in another window pastes it; then the
      commit/history/scrollback/completion quick sweep (the edit
      line took a new code path).**
      **Decision: ONE process, many windows** (the AROS
      con-handler shape), NOT the KingCON per-window fork:
      CreateNewProc from inside a handler risks internal DOS
      packet traffic on pr_MsgPort (unverifiable without a ROM
      dig), and forked instances would each need their own
      timer/clipboard/input-chain hookups - N chain handlers is
      the wrong shape. CRAW: already proves per-process works,
      but only per-DEVICE.
      **State:** a `console` OBJECT absorbs every per-window
      global (window/grid/cursor, SGR state, model sb/sa/sbtop/
      sbcnt/viewoff, editor + history, inq/rdq/wcq, breaktask,
      rawmode/evmask, selection, completion state, parse
      results, edlast/tcmrow0/anstab...). Shared stays global:
      the ports, timer.device, clipboard.device,
      keymap.library, the ONE input chain, fsport.
      **THE MIGRATION TRICK - "current console":** procs keep
      their bodies; the per-window globals become curcon.fields
      and `curcon` is set at the dispatch boundaries only:
      packets by arg1 (fh_Arg1 = fh.args = the console pointer,
      validated against the list - the routing the packet
      protocol always wanted), window events by UserPort ->
      console, chain drains by a console tag added to the ihev
      ring slot, timer expiry by scan. Almost no proc
      signatures change.
      **Routing details:** FIND* parse per open now (the M9
      options finally apply to every window); `*`/CONSOLE:-
      style opens map to the SENDER's console by walking the
      opener's CLI streams (pr_CLI -> cli_StandardInput ->
      fh.args = console) with active-window fallback - same for
      DISK_INFO/More/Ed. The main loop Wait mask ORs every
      console's UserPort sigbit (rebuilt on open/close); the
      park rule and evmask go per-console. ihchain matches
      IntuitionBase.ActiveWindow against the console list
      instead of one ihwin.
      **Open knob:** the model is SBMAX*cols*2 bytes per
      window - either all windows get 4000 lines (memory-fat)
      or secondaries get a smaller ring; decide at migration.
      **Testing ladder:** (A) struct-ified single console,
      behaviour identical - boot; (B) two shells, two windows -
      boot; (C) the M9 option list re-run, per open this time;
      (D) Ed/More/CTerm/copy-paste regression per window; (E)
      CCON: and CRAW: simultaneously.

## Design notes

- One stream, one window for M1 — fh.args is already a per-open id
  so multiple streams can come later without protocol changes.
- The window stays open after the last ACTION_END in M1, so the
  output can be inspected; real open/close semantics are M5.
- Debugging: no WriteF after the handshake (the no-DOS rule; E's
  lazy stdout would try to open a console). If logging is needed,
  render into the window or blink the screen.
