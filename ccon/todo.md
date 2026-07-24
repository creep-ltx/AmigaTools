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
      1.0 also ships fish-style AUTOSUGGESTIONS (his call: "we
      absolutely NEED it") — drawedit finds the newest history
      entry the typed line prefixes (case-folded) and draws its
      continuation as grey ghost text: the blip cell carries the
      ghost's first char (accepted text lands exactly where shown),
      the rest clips to the blip's row, ghostpen() is WBPENS grey 8
      or the ObtainBestPen grey, and NO readable grey = no ghosts
      (a deffg ghost would read as typed text). Right/Shift+Right
      accept all (sgall, edcap-capped), Ctrl+Right one word + its
      space (sgword). Pixels only: never mirrored to the model, so
      never selected/copied/committed; eraseedit's clear-to-row-
      edge already erases it; vanishes under a selection repaint
      until the next keypress (the blip's known cosmetic, shared).
      Boot test: run two commands, type the first's prefix — grey
      ghost appears; Right completes it; Ctrl+Right takes one word
      at a time; typing a diverging char kills it; Return with a
      ghost showing runs ONLY the typed text; Up/Down history
      still work; ghost behaves on the wrapped edit line and never
      shows mid-line (cursor not at end).
      FIRST GHOST BOOT (18.7.26, inside CTerm's frame no less):
      works — two refinements from his fingers, same build night:
      (1) sgword copied token-then-spaces, so `ls` + Ctrl+Right
      took the bare space first and needed a second stroke for
      `-la`; fish order is spaces-ride-with-the-token — one stroke
      now. (2) Tab accepts the next ghost word too (his ask);
      plain Tab prefers a visible ghost, Shift+Tab FORCES the
      completion menu — the escape hatch when history shadows a
      filename (bare Shift+Tab meant nothing outside a menu).
      Re-test: `ls` → Ctrl+Right = `ls -la` in one stroke; Tab
      steps through ghost words; Shift+Tab with a ghost showing
      opens the completion menu; Tab with NO ghost still
      completes filenames.
      AND THE 1.0 MONSTER LAP (18.7.26, his call: "let's ship a
      fucking monster") — the whole readline tier in one build:
      (1) WHEEL SCROLLBACK: NewMouse rawkeys $7A/$7B pass ihkey's
      button filter and scroll 3 lines/tick in both modes, never
      snapping, never reaching the client; an open completion menu
      closes first (no smear). (2) KILL KEYS: Ctrl+U (kill to
      start), Ctrl+K (kill to end), Ctrl+W (word back, trailing
      spaces first), Ctrl+L (screen scrolls into HISTORY — a
      non-destructive clear, Shift+Up undoes it; prompt row lands
      at top). Ctrl+A/E deliberately NOT taken (Ctrl+C..F are
      break signals; Shift+arrows are the house home/end).
      (3) CTRL+R SEARCH: substring case-folded over the ring,
      newest first; the TITLE BAR carries [search: frag] (the
      prompt is client output — the title is ours; borrowed
      windows lose only the feedback), edit line shows the match
      live, Ctrl+R steps older, Backspace widens (re-searches
      from newest), Enter exits-and-COMMITS (falls through to the
      normal commit path), Esc restores the stashed line, cursor
      keys keep the match for editing, beep = no match (line
      kept, bash-style). srbuf/srstash per console.
      (4) DOUBLE/TRIPLE CLICK: DoubleClick() prefs timing, same
      row only; 2 = the clicked cell's class-run (word, or the
      whitespace gap), 3 = whole line; copied on the spot, no
      drag, no release needed, writers never parked (selon stays
      FALSE).
      **First monster boot: wheel, kill keys, clicks all GREEN;
      Ctrl+R "did nothing" — the TWO-PASS KEY TRAP, third sighting
      tonight (menu-Enter and the bare-Shift snap were the first
      two): every key runs dorawkey on its RAW pass before the
      keymap makes its vanilla byte, and the movement-exits-search
      hook sat unconditionally in dorawkey's cooked section — so
      the first letter after Ctrl+R exited search on its raw pass
      and typed normally. Fixed: only the four arrows exit search
      there. LESSON FOR ALL FUTURE dovanilla FEATURES: any state
      entered via a vanilla byte must not be torn down in dorawkey
      except by keys dorawkey itself consumes.
      Second boot: search WORKED but "the prompt is not changing" —
      title-bar feedback was the wrong place (bash eyes look at
      the prompt, and CTerm's borrowed frame has no title of ours
      anyway). Now an INVERSE [search: frag] chip draws in the
      line itself, ghost-style (pixels only, clipped to the blip's
      row, suppresses the autosuggestion while searching), srenter
      draws it immediately and srexit erases it; the title still
      mirrors it on owned windows.
      Third round, his design review: "shouldn't search replace
      the prompt?" — bash replaces, zsh goes below, fish pagers;
      his fingers are bash. And CCON can do bash BETTER than a
      terminal can: the prompt cells are IN the model, so the
      banner overdraws them (inverse, fragment tail kept when
      long, space-padded to the prompt width when short, pixels
      only) and srexit/srcancel restore the true prompt with one
      drawmodelrow. The after-line chip is retired. Re-test:
      Ctrl+R → the prompt becomes (search: ) instantly; the
      fragment fills it; Enter/Esc/arrows bring the real prompt
      back unharmed; works inside CTerm's frame too.**
      **Boot test:** wheel up/down over long output (cooked, and
      inside More for raw), wheel with menu open closes it then
      scrolls; Ctrl+W/U/K surgery on a fat command line; Ctrl+L
      then Shift+Up (the cleared screen is IN history); Ctrl+R
      → type a mid-line fragment → title shows it, match appears
      → Ctrl+R steps older → Enter RUNS it; Ctrl+R → Esc gives
      the old line back; double-click a filename in ls output →
      RAMIGA-V pastes it; triple-click a line; ghosts/completion/
      history/copy-paste regression.
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

## v1.1 — planned (two themes)

### Theme A: "fits your system" — compatibility gaps that bite daily

- [ ] **FONT option — `FONTname/size` in the open string.** The most
      visible 1.0 gap: everything is Topaz 8 unless a borrowed
      window brings its own font. THE WRINKLE, spotted before it
      cost a boot: OpenDiskFont() does DOS I/O on the caller's
      context — for a handler that is the no-DOS rule violated,
      deadlock territory (DoPkt waits on pr_MsgPort, our client
      port). So v1.1 accepts ALREADY-LOADED fonts only, via
      OpenFont() (ROM fonts, anything FixFonts/a terminal has
      loaded) — which covers the real use case, CTerm passing its
      own font. Disk-font loading needs a helper task or a
      mount-time load; deferred, design when wanted. Non-8x8
      cells: cw/ch/gridcalc already derive from the rastport font,
      but boot-verify the block cursor, blip, selection cell math
      and menu columns at a non-topaz size.
- [ ] **SGR 3/4/7 — italic, underline, inverse — as real soft
      styles.** Stock console renders these; CCON drops them (Ed
      is fine, but ports and BBS output lose face). The catch: the
      attr plane is a FULL byte (fg+bg nibbles), so styles need a
      third plane — roughly +300K/window at 1.0's geometry, which
      is why the memory knob below lands in the same release.
      Rendering: SetSoftStyle for 3/4, inverse = the drawselrow
      fg/bg swap the selection already does. All the batched run
      painters (drawmrow, drawselrow, render, outchr) grow a style
      dimension to their run-splitting.
- [ ] **The memory knob — `LINES=n` open option.** 4000-line model
      per window is ~600K at 80 cols; a 2MB real machine chokes.
      LINES=n clamps SBMAX per console (model allocation is
      already per-console since M10 — the knob the design punted
      is now trivial); consider a smaller default for windows
      opened WITHOUT the option when total consoles > 1. Pays for
      the style plane above.
- [ ] **Insert/delete character — CSI @ / CSI P.** Small renderer
      + model work (ScrollRaster horizontally inside the row, cell
      copies in visrow/sarow like L/M do between rows). Closes a
      compatibility hole a fullscreen app will eventually hit.
- [ ] **xterm title sequences — ESC]0;title BEL (and ST).** A
      feature and a bugfix in one: gives clients a proper retitle
      path AND properly fixes the More-retitle stomp (the console
      keeps the client title, appends its own [scrollback -n] /
      [search:] state to it instead of replacing it).

### 1.1b1 — Theme A built whole (19.7.26), awaiting boot

All five Theme A items in one build; compiled clean (LARGE), vamos
smoke test green (usage + refusal), deployed to L: with 1.0 kept
beside it as `ccon-handler-1.0`. Boxes above stay open until the
boot says so. How each landed:

- **FONT**: the open string splits fields on `/`, so `FONTname/size`
  arrives as TWO tokens — the parser sets `pfontexp` on the FONT
  token and a bare number as the NEXT token becomes the size
  (`FONT=name` and `LINES=n` forms accepted too). openwin appends
  `.font` when missing, opens via OpenFont ONLY (the no-DOS rule:
  loaded fonts — ROM plus whatever diskfont already pulled in),
  rejects proportional faces (FPF_PROPORTIONAL, the grid needs
  fixed cells) and falls back to topaz 8 silently. AskSoftStyle is
  captured per window (`softmask`) for the styles below.
- **SGR 3/4/7**: a third model plane `ss` (style bits: 1 italic,
  2 underline, 4 inverse) allocated/resized/freed with sb/sa —
  all three or none. Every painter grew the style dimension in its
  run-splitting: drawmrow, drawselrow (selection over an inverse
  cell re-inverts, xterm manners), render's batched runs, outchr,
  cursdraw/curserase. Italic/underline go through SetSoftStyle
  (only on change, `cursoft` tracks the rastport); inverse is a
  pen swap at paint time, never a stored-pen change — so the attr
  plane keeps its meaning and bg stays 3 bits. `setsoft(0)` at
  every painter's exit: the editor and cursor always draw plain.
- **LINES=n**: `sbmax` per console (floor 100, tcnum's cap 20000,
  default SBMAX 4000). Every model index — visrow/sarow/ssrow,
  screenscroll, doresize, redraw, selvidx, drawmodelrow — now wraps
  on curcon.sbmax. The knob that pays for the style plane.
- **CSI @ / CSI P**: inschars/delchars — horizontal ScrollRaster
  from the cursor to the row edge (positive dx moves content left,
  the screenscroll sign convention: insert scrolls by -n cells),
  model row shifted the same way in all three planes.
- **xterm titles**: OSC parser states in render (cesc 3 = body,
  4 = ESC-seen; BEL, $9C and ESC \ all terminate, $9D opens like
  ESC ]). The Ps number is skipped — 0/1/2 all retitle. The text
  becomes wtitlebase, so [scrollback -n]/[search:] append to it.
  AND the More-stomp fix: settitle now ADOPTS a foreign title it
  finds on the window (More retitles via the DISK_INFO window
  pointer and SetWindowTitles directly) as the new base instead of
  overwriting it on the next view flip.

Boot checklist (the usual ladder — every 1.0 feature must still
hold, they all repaint through the grown painters):

- [ ] plain boot: NewShell CCON: opens, types, completes, scrolls
- [ ] `echo "*e[3mit*e[0m *e[4mul*e[0m *e[7minv*e[0m"` — three
      styles render, survive Shift+Up into scrollback and back,
      select/copy over them, menu restore over them
- [ ] `NewShell CCON:0/0/640/200/test/FONTtopaz/9` — topaz 9 is
      the OTHER ROM size, guaranteed loaded: a real non-8x8 cell.
      Block cursor, blip, selection cells, completion menu columns
      all line up. (A disk font works only if something already
      loaded it — that is the designed limit, not a bug.)
- [ ] unknown font name → topaz 8, no crash
- [ ] `NewShell CCON:0/0/640/200/small/LINES=200` — scrollback
      stops at ~200 lines back, no wrap garbage
- [ ] CSI @/P: Ed or a test echo `*e[5@` / `*e[3P` mid-line —
      cells shift, colours/styles ride along
- [ ] `echo "*e]0;retitled*07"` (BEL) — title changes; scroll back
      and forth — suffix appends, title survives
- [ ] More a file, let it retitle, scroll back → More's title keeps
      the [scrollback -n] suffix instead of vanishing
- [ ] Ed still: menus, raw arrows, block cursor — the render parser
      grew states, Ed is the canary for parser regressions

### 1.1b2 — disk fonts via the helper process (19.7.26)

**Boot finding (1.1b1, 19.7.26):** FONT=microknight/8 came up
topaz 8 — and so did FONT=topaz/9. Loaded-fonts-only proved
useless in the FIRST MINUTE of real use: 3.1.4/3.2 moved even
topaz 9 out of the ROM onto disk, so a cold boot has nothing for
OpenFont to find but topaz 8. The "deferred, design when wanted"
helper-task from the plan above got wanted immediately.

**The design (the M5b trick's sibling):** the no-DOS rule binds
the HANDLER process — DoPkt waits on pr_MsgPort, the port clients
send to. A throwaway helper process has its own pr_MsgPort and
talks DOS freely. fontload() spawns one per FONT request
(CreateNewProc, NP_ENTRY, no input/output/dir/vars — nothing that
would make CreateNewProc itself send packets), sleeps on a
private signal while the helper runs OpenDiskFont, takes the
font back through a global. Client packets queue on the port
meanwhile; the open being served was waiting anyway. The helper
sets its pr_WindowPtr to -1 so a missing volume never throws a
requester, and ALWAYS signals, even on failure.

**The A4 wrinkle:** an NP_Entry process starts without E's data
base register. gluestub solves this for interrupts by reading A4
out of is_Data — but a process entry carries no is_Data. So the
stub is 24 bytes of machine code POKED AT RUNTIME with the glue
vector's address as an immediate: MOVEM save, MOVEA.L #fhgd,A3,
A4 and {fonthelper} loaded from the vector, JSR, MOVEM restore,
RTS. Encoding verified by machine68k disassembly before boot
(house rule: glue gets disassembled, not assumed). CacheClearU()
after poking. Fallback ladder intact: no helper -> OpenFont
(loaded fonts) -> topaz 8.

Boot checklist deltas (rest of the 1.1b1 ladder unchanged):

- [ ] `NewShell CCON:0/0/640/200/test/FONT=microknight/8` COLD —
      MicroKnight from disk, no prefs dance
- [ ] FONT=topaz/9 — the disk topaz 9, cells visibly taller
- [ ] unknown font name → topaz 8, no requester, no hang
- [ ] a second FONT window while the first lives (helper is
      spawn-per-request — no shared state to collide)
- [ ] `version l:ccon-handler` says 1.1b2

### 1.1b3 — the font telemetry boot (19.7.26)

**Boot finding (1.1b2):** FONT=MicroKnight/8 still topaz — but the
window OPENED, so the handler never hung in Wait: the failure is
in a rung that falls through, not a deadlock. Verified from the
Linux side before rebuilding (the 0.14 telemetry-boot discipline):
MicroKnight/8 IS on FONTS:; E's textfont offsets (ysize 20, style
22, flags 23) and textattr offsets are right, so the proportional
check is sound; process.windowptr = 184 is the TRUE pr_WindowPtr
(hand-counted 186 was wrong - E's module knew better); every NP_*
tag value matches dostags. Everything checkable without a boot
checks out - so 1.1b3 makes the Amiga tell us the rest.

**Telemetry:** the topaz fallback now appends ` [font eN]` to the
title when a FONT option was asked for. Decode:
  - no marker = the FONT option never PARSED (pfontname empty)
  - e13 = plumbing never came up at init (signal/stub alloc)
  - e14 = CreateNewProc itself failed
  - e11 = helper ran, no diskfont.library
  - e12 = helper ran, OpenDiskFont found no such name
  - e15 = font loaded fine but proportional, rejected by design
  - e10 = helper entered but neither branch finished (would hang
    before the window opens - seeing it printed is near-impossible)
  - a hang with no window = helper crashed before Signal (the stub)
Helper stack bumped to 16384 while in there. Marker and fherr come
OUT before 1.1 final.

- [ ] boot FONT=MicroKnight/8, read the title, decode above

### 1.1b4 — the telemetry was blind (19.7.26)

**Boot finding (1.1b3):** title showed plain "Test2", no marker —
and that told us NOTHING, twice over. (1) The b3 marker was
StrAdd'ed into wtitlebase AFTER OpenWindowTagList had already
painted the bar; Intuition keeps the POINTER and repaints only on
SetWindowTitles, so the marker sat invisible in the buffer (a
Shift+Up would have revealed it - the scrollback flip refreshes
the title). The M4 pointer lesson, forgotten in its own file.
(2) A no-marker title is also exactly what the b2 seglist shows,
and the boot's CLI numbering left doubt about which build was
even running. Telemetry that cannot distinguish its own absence
is not telemetry.

**b4:** every FONT attempt stamps ` [b4 font eN]` - e0 on SUCCESS
too - and pushes it with an explicit SetWindowTitles (the window
is open by then; the font block runs after OpenWindowTagList).
Reading the next screenshot is now unambiguous: no marker = FONT
never parsed OR an old build; [b4 font e0] + topaz glyphs = loaded
but not applied; eN = the decode table above.

- [ ] reboot, FONT=MicroKnight/8, read the title

### 1.1b5 — the shell eats the spec (19.7.26)

**Boot finding (1.1b4, FRESH boot):** still no marker. Everything
on the Linux side is now PROVEN: parsecon extracted verbatim into
a vamos harness parses 'ccon:0/0/640/80/Test/FONT=MicroKnight/8'
perfectly (pfontname/pfontsize/ta.name all right); the deployed
binary is md5-identical to the build; user-startup -> mountlist ->
L:ccon-handler chain checked file by file; the marker sits gated
on nothing but pfontname[0]. Ergo: the STRING reaching parsecon
is not the string typed. And the ROM coughed up the suspect:

    strings kicka1200.rom | grep -i 'con:'
    CON:///130/AmigaShell/CLOSE/SHELL/ICONIFY
    CON:///-1/AmigaDOS/Auto/NoClose/Smart

The V47 shell REBUILDS the window spec from its template - fields
it knows survive (geometry, title), foreign options (FONT=,
LINES=) are eaten before Open() ever reaches the handler. NewShell
was never a clean pipe.

**b5 telemetry:** the window title is now the EXACT name DOS
handed us (raw BSTR, 76 chars), with the [b4 font eN] stage
appended when a FONT parsed. One boot, two opens, full truth:

- [ ] `newshell ccon:0/0/640/80/test/FONT=microknight/8` - title
      shows what the shell REALLY passes
- [ ] `echo >ccon:0/0/640/80/test2/FONT=microknight/8/WAIT hello`
      - echo's Open() bypasses the shell: expect the raw spec in
      the title WITH the FONT tokens, [b4 font e0], and MicroKnight
      glyphs if the loader chain is healthy

If the split confirms, the fix direction: options must survive
without the shell's cooperation - mountlist Startup args as
device-wide defaults (the RAW precedent), and/or keep full spec
support for direct Open() clients (CTerm et al on stock 3.2 pass
specs verbatim).

**Boot verdict (b5, 02:19): title = `ccon:0/0/640/80/test/FONT`.**
The spec arrives VERBATIM - device name and all - and stops at the
'='. The CON: template theory above was wrong (honest correction):
the eater is the AmigaDOS COMMAND-LINE tokenizer, which treats
unquoted `X=Y` as ReadArgs keyword syntax and splits there. The
echo window "flashing briefly" confirms it: its redirect name was
cut at '=' too, which amputated /WAIT - window died with the
handle, correct CCON semantics. Every failed FONT boot tonight
used '='; the disk-font loader has never once actually run.

The cure costs nothing: the '='-less forms have parsed since b1
and are the stock idiom anyway (SCREENname, PENn, WINDOW0x):

    newshell ccon:0/0/640/80/test/FONTmicroknight/8
    newshell ccon:0/0/640/200/big/LINES8000

(or quote the whole spec when the '=' form is wanted). ccon.doc
must say this out loud in the FONT/LINES sections: NO '=' on a
shell command line unless the spec is quoted - the shell eats it,
silently, before any handler sees the name.

- [x] FONTmicroknight/8 (no '='): expect full spec in title,
      [b4 font e0], MicroKnight glyphs - the loader's FIRST real run
      -> **BOOT-GREEN (02:23):** full spec in the title, e0, and
      MicroKnight rendering. The helper process, the poked A4 stub,
      OpenDiskFont - the whole chain worked on its first genuine
      run. The '=' window beside it: truncated title, topaz - the
      culprit and the cure in one screenshot. Night lesson in one
      line: the code was right from b2; the SHELL ate the option
      and the first two telemetry builds could not see their own
      absence. Instrument until the failure has a name.

### 1.1b6 — telemetry out, ladder resumes (19.7.26)

b5's raw-name title and the [b4 font eN] stamp are OUT (fherr's
internal stage codes stay until 1.1 final - invisible, and the
next mystery will want them). Remaining Theme A ladder unchanged:
styles echo, FONTtopaz/11 for a real non-8x8 grid (topaz/11 is on
disk - and the loader now REACHES disk), LINES200, CSI @/P, OSC
titles, More retitle, Ed canary.

### 1.1b7 — @/P repaint from model + Tab belongs to completion (19.7.26)

**Boot results (b6 ladder, 02:36):**
- [x] SGR 3/4/7 GREEN: italic slants, underline underlines, inverse
      inverts, combos stack, SGR 23 drops italic mid-line. (Typed
      via s:ccon-styles - raw escape bytes written from the Linux
      side because the Swedish keymap has no reachable `*` in
      FS-UAE; the s:ccon-* trio stays for future ladders.)
- [x] OSC titles GREEN: title changed on the BEL sequence.
- [x] FONTtopaz/11 GREEN: real 11px grid, cursor/cells aligned.
- [x] LINES GREEN: LINES10 floored to 100, scroll range matches.
- [ ] CSI @/P FAILED on boot: both result rows wiped except the
      newly printed XYZ. The model shift was PROVEN right in a
      vamos harness (01234XYZ56789 / 0123489 exactly) - the
      horizontal ScrollRaster was the liar. b7 replaces it: shift
      the model, repaint the row FROM the model (one drawmrow).
      Pixels can no longer disagree with the model. ScrollRaster
      survives only for the sb=NIL degenerate case. RETEST:
      `type s:ccon-ichdch`.
- [x] Scrollback survival of styles: pending explicit check but
      styles repaint through drawmrow (menu restore already
      proved that path) - verify with Shift+Up while at it.

**Tab reclaimed (his call, 02:36):** `type s:c<Tab>` wanted the
completion menu, got history's ghost instead. Tab NEVER accepts
the ghost now - it is completion's key alone; ghosts accept via
Right/Shift+Right (all) and Ctrl+Right (word). Was: 1.0's "Tab
prefers a visible ghost". ccon.doc needs its Tab/ghost paragraphs
updated for 1.1 (his pass - the doc is his voice).

### 1.1b8 — the \r anchor theft: a 1.0 latent bug, caught by @/P (19.7.26)

**The bisect verdict (02:53, both a WB window and inside CTerm):**
t2 - pure CR overprint, not one CSI in it - FAILED. t3 (no CR)
passed everywhere. t1/t4/t5 fail only because their lines carry
\r. The scroll roundtrip left the wreckage unchanged: the MODEL
itself lost the digits. CSI @/P were innocent from the start -
b6's ScrollRaster and b7's repaint both told the truth about a
model that had already been robbed.

**The mechanism (the \r anchor theft):** a client write may end
mid-row - Type splits its output at \r. dowrite's tail then runs
reanchor() + drawedit(): the edit anchor parks at column 0 OF THE
CLIENT'S HALF-WRITTEN ROW. The NEXT write opens with eraseedit(),
which erased anchor-to-EOL, pixels AND model. The console stole
the client's row, then rendered the new bytes into the void.
LATENT SINCE THE MIRROR LANDED (0.25): every progress-style
overprint ("50%\r51%\r") was being robbed - invisible because
full-width overprinters repaint everything they lose. The @/P
test lines print LESS than they overwrite; that is the only
reason the theft ever showed.

**The b8 fix - erase only what the editor painted:** eraseedit
zeroes just the MIRRORED text cells (edlast of them, wrapped) and
repaints the touched rows whole from the model: blip/ghost/search-
banner pixels evaporate (not in the model), client cells COME BACK
(in it). New edext field = text + blip + ghost extent, set by
drawedit, bounds the repaint. Polish riding along: a blip parked
over client text now shows THAT char inverted (the block-cursor
rule) instead of a blank block. The sb=NIL branch keeps the old
full clear - nothing to restore from without a model.

- [x] retest: `type s:ccon-bisect` - all five lines must match
      their printed expectations, in a WB window AND in CTerm
      -> **BOOT-GREEN (03:03): all five, both windows.** t1
      01234XYZ89, t2 XYZ3456789, t3 0123456Q89, t4 01234   56789,
      t5 0123489 - byte-exact against the expectations.
- [x] retest: `type s:ccon-ichdch` (@/P proper)
      -> **BOOT-GREEN (03:03): 01234XYZ56789 / 0123489, both
      windows.** CSI @ and CSI P verified; the \r anchor theft is
      dead. With this, ALL FIVE Theme A features are boot-verified:
      FONT (MicroKnight/8 + topaz/11 from disk), SGR 3/4/7, LINES,
      CSI @/P, xterm titles.
- [ ] regression sweep - eraseedit is EVERY keystroke's eraser
      now repainting from model: type/edit/kill keys feel, ghost
      accept/reject, Ctrl+R banner in and out, completion menu,
      history walk, commit echo, wrapped long lines
- [ ] a real \r client: `copy` a big file with a progress
      printer, or lha - the 1.0-era theft should be gone
- [ ] More retitle + [scrollback -n] suffix appending (the last
      untested corner of the titles item)
- [ ] Ed canary (parser grew OSC states + @/P since 1.0)

### 1.1b9 — the sweep verdict: 29/30, one regression, one truth (19.7.26 morning)

**His full-night sweep (the bughunt file): 29 of 30 boxes green.**
Editor, ghosts/Tab split, Ctrl+R all exit paths, \r theft dead,
styles under stress, FONT ladder incl. helvetica-rejection, LINES
ceiling+resize, OSC, Ed, CTerm, craw, three-window life: GREEN.
Two findings:

1. **Flicker on Shift/Ctrl+Left/Right (b8 regression, fixed in
   b9):** b8's eraseedit repainted rows from the model and then
   drawedit painted the text AGAIN - every keystroke double-
   painted, visible as whole-line flicker on bare cursor moves.
   b9 inverts to paint-first: drawedit no longer pre-erases; the
   text paints IN PLACE (JAM2 - identical glyphs repaint
   invisibly), then a tail pass zeroes the mirror where the old
   text out-reached the new (cells l..oldl-1) and repaints stale
   pixels (old blip/ghost beyond the new extent) from the model
   via drawmodelcells (drawmodelrow's bounded sibling). eraseedit
   now zeroes edlast/edext after erasing so the tail never
   re-cleans at a moved anchor (the theft pattern must not come
   back through the back door). Standalone eraseedit callers
   (dowrite, commit, Ctrl+L, raw transitions) unchanged.
2. **More's --- More (xx%) --- bar stuck in scrollback history**
   (see 10:10 screenshot; the title adoption + suffix WORKED in
   the same shot): More paints its pager UI over the visible rows
   - which ARE the model's live window - and rows that later
   scroll off archive More's transient UI instead of transcript.
   Stock CON: corrupts identically; it just has no scrollback to
   show it. Not a bug in the b-series - an inherent property of
   scrollback-without-altscreen. Candidate real fix, HIS CALL
   (v1.1 or later): raw-session alternate screen - snapshot the
   visible model rows on cooked->raw, restore on raw->cooked
   (More/Ed/editors leave the transcript untouched, the unix
   less-on-xterm behavior; no console on the platform does this).
   Open question there: rows that SCROLL during raw (More's
   line-by-line Return advance) still leak into history unless
   raw-mode scrolls also stop archiving.

- [x] b9 boot: NO flicker (his word) - but two tail-cleanup bugs:
      Ctrl+Left/Right left a stale inverse block at the line END,
      and Ctrl+U left the killed first char inside the blip.
      Screenshots 10:30/10:31.

### 1.1b10 — tail fixes + the raw-session alternate screen (19.7.26)

**The two b9 sightings, both one-cause-one-line:**
1. Stale end-blip: newext counted the blip cell UNCONDITIONALLY,
   but the blip only occupies cell l when cpos = l - a cursor
   jumped into the interior left oldext = newext and the old end-
   blip standing. Now: newext = l, or l+1+ghost when cpos = l.
2. Killed char in the blip: the mirror-zeroing ran in the tail,
   AFTER the blip's b8 model-read - Ctrl+U's blip read the cell
   the paint had just abandoned. The zeroing now runs right after
   the text pass, before anything reads the model.

**The feature (his yes, this morning): raw-session alternate
screen.** altsave() on cooked->raw (after eraseedit: the vault
holds a clean transcript): visible rows x3 planes + cursor +
anchor + sbtop/sbcnt + geometry. altrestore() on raw->cooked:
ring rewound, rows copied back, cursor AND anchor restored
(reanchor skipped - the anchor is part of the restoration),
redraw. Raw-scrolled rows reclaim ring rows; sbcnt shrinks by
the overflow when a long raw session wraps into oldest history
(rawscr counts in screenscroll). A resize during raw discards
the snapshot (altdrop in doresize) - fallback is the old
behavior. Snapshot dies with the window (closewin). No memory =
no snapshot = 1.0 behavior. More/Ed now leave the transcript
EXACTLY as they found it - no console on the platform ever did
this.

- [ ] b10 boot: b9's two garbage sightings dead (Ctrl+Left/Right
      on long line, Ctrl+U from line end)
- [ ] more s:startup-sequence, page around, quit: the transcript
      is BACK, no More bar anywhere, Shift+Up history clean
- [ ] Ed a file, edit, save, quit: transcript restored the same
- [ ] More then RESIZE mid-More, quit: falls back gracefully
      (no restore, no crash)
- [ ] Ctrl+C break out of More (no clean exit): shell reprompts -
      what does the screen do? (snapshot stays armed until the
      next cooked SetMode... watch for weirdness, this is the
      one soft corner)

### 1.1b11 — the altscreen goes client-driven: CSI ?47h/l (19.7.26)

**b10 boot findings:** garbage markers DEAD (both b9 tail bugs
confirmed fixed). But More: its screen still there after quit and
history scroll dead — the SetMode coupling was WRONG. The truth,
dug out of More's own binary (strings + vamos dos-trace):

    V47 More brackets its pager session with CSI ?47h ... CSI ?47l
    — THE XTERM ALTERNATE-SCREEN PROTOCOL, in ROM-era Amiga
    software. Its ?47l (and final tidy writes) come AFTER the
    SetMode(0) — so b10's restore-at-SetMode fired mid-exit and
    More's trailing output stomped the restored transcript.

**b11:** the client drives it, xterm-exact. Parser grew the DEC
private marker (cpriv on '?'/'>' in CSI params); csidispatch:
?47h = altsave, ?47l = altrestore (mid-render is fine - dowrite's
own tail reanchors on the restored cursor). SetMode hooks removed
(raw/cooked back to b9 form). Scrollview refuses while ON the
altscreen (xterm manners - fixes the mid-More history leak
sighting). Safety net: an ACTION_END arriving while altvalid
(a Ctrl+C'd More never says ?47l) restores the transcript on the
dying handle. doresize/closewin drops unchanged.

**The altscreen CONTRACT (say it in the doc):** content viewed on
the alternate screen does NOT enter scrollback - exactly like
less/vim on xterm. Quit More: transcript back, More's pages gone.
Pre-More history intact. If he'd rather archive More's content
into history (option B), that is a different, discussable design.

- [x] b11 boot: **"works as intended!" (his words, 19.7 morning)**
      - More in/out clean, transcript restored, altscreen contract
      holding. The sweep is GREEN across the board.

### Before 1.1 ships (when the sweep is green)

- [x] strip fherr and its stage-sets (the b3 telemetry's insides)
      -> stripped; $VER = "1.1 (19.7.26)", the b-suffix dropped;
      RC compiled clean and deployed to L: for the final
      confidence boot. From here the diff is docs and ritual only.
- [x] RC2 (his catch during RC): a bare `newshell ccon:` now
      defaults to the Font Prefs "System Default Text" font
      (GfxBase DefaultFont - what stock CON: honors; already in
      memory, plain OpenFont reopens it, no helper involved),
      topaz 8 only as the last resort (unusable/proportional).
      Offsets probe-verified (gb_DefaultFont=154, mn.ln.name=10).
      RC2 boot check: `newshell ccon:` comes up in whatever Font
      Prefs says; set prefs to another mono font, reboot, check
      again; FONT option still overrides.

**RC2 aftermath - the SLASH trap (his very next boot, verified via
harness before touching code, per house rule):** `newshell
ccon:FONTtopaz/8` still came up in the prefs font, not topaz. Not
a defaults-code bug - a PARSER bug, confirmed with his exact
string fed through the same parsecon harness: "FONTtopaz" landed
in the poitional X field (not numeric, ignored) and "8" in Y
(pwy:=8) - option parsing needs 5 slashes to even START (field
index 5), so FONT never fired, and the (working-as-designed)
prefs-default fallback took over. The technically-correct spelling
was `ccon://///FONTtopaz/8` (verified) - five throwaway slashes to
reach an option. Nobody should have to count that.

**The fix (parseopt extraction, v1.1 "19.7.26b"):** the whole
option-dispatch chain (WAIT/CLOSE/.../FONT/LINES) moved into its
own PROC parseopt(tok), returning TRUE if it recognized the
token. Field 0 now tries tcnum FIRST (unchanged); if that fails
(non-numeric) AND parseopt recognizes the token as a real option,
the ENTIRE spec becomes options-only (geometry/title stay
default) - "ccon:FONTtopaz/8", "ccon:WAIT", "ccon:LINES200" all
just work, zero throwaway slashes. Mixing geometry WITH options
still needs the full positional spelling exactly as before
(`ccon:0/0/640/80/title/FONTtopaz/8`) - unaffected, regression-
tested via harness against every string verified earlier tonight
(byte-identical results, incl. blank-bname and geometry-only
opens). This is unrelated to the shell's '=' eating - that trap
is still real and still needs FONTname/n or a quoted spec; this
fix only removes the SLASH-COUNTING trap.

- [ ] boot: `newshell ccon:FONTtopaz/8` -> topaz, no slashes needed
- [ ] `newshell ccon:WAIT` and `newshell ccon:LINES200` - bare
      keyword shortcuts, both should just work
- [ ] `newshell ccon:0/0/640/80/test/FONTmicroknight/8` - the
      OLD fully-positional spelling, unchanged
- [ ] a bare `newshell ccon:` still honors Font Prefs (untouched
      by this parser change)
- [ ] decide the fate of s:ccon-styles/-osc/-ichdch/-bisect (keep
      as the house test deck? they cost nothing and found gold)
- [x] ccon.doc: FONT + LINES sections, Tab/ghost split (Tab is
      completion's alone now), the '=' warning, the slash-shortcut
      form, and the altscreen contract -> done (19.7.26b commit,
      "ccon 1.1b12"), $VER left at "1.1 (19.7.26b)" (unchanged,
      still the same boot-verified binary - only docs moved)
- [x] ccon.readme highlights line for 1.1 -> done, same commit
- [ ] $VER -> 1.1, drop the b-suffix; file_id.diz refresh;
      README.md release page section; lha + gh release - deferred
      to the real 1.1 tag, AFTER Theme B (his call, 19.7.26b: "we
      do not create a .lha archive for the beta")

### Theme B: "the plumbing" — the Unix tier that needs filesystem work

- [x] **Shared + persistent history — done, boot-confirmed
      ("It WORKS!!!!", 19.7.26).** Also where $VER stopped growing
      date-letter suffixes (1.1, 26b, 26c, 26d) — his call: plain
      sequential `1.1bN` from here on, no more dates in the
      string. Counting every deployed build since 1.1 started
      (b1-b11, the RC, RC2/26b, 26c, 26d = 15) landed the next one
      on **1.1b16** — the history file's move from S: to L: was
      folded into that same build. His calls on the two open
      questions: ONE shared history file (not split by device —
      CRAW: barely contributes anyway, raw mode bypasses history
      entirely), and HISTMAX 32 -> 200 (now a single ring per
      process instead of one per window, so 200 * LINEMAX is
      ~80K once, not 32 * N windows — a straight win).

      The move: `hist[32]`/`htotal`/`histdone` came OFF the
      console OBJECT and became process-global `ghist`/`ghtotal`
      (console keeps only `hpos`, the per-window Up/Down walk
      cursor — two windows can browse the shared ring
      independently). Every read site (sgfind's ghost match,
      srfind's Ctrl+R scan, histload's Up/Down, the Return-commit
      append) now points at the shared ring; the append itself
      became one shared `histremember(s)` (same dedupe rule,
      newest-collapses-with-previous, used by both live typing
      AND the disk load).

      Persistence is the M5b trick in reverse: `loadhistfile()`
      and `savehistfile()` hand-roll ACTION_FINDOUTPUT/FINDINPUT/
      WRITE/READ/END straight at L:'s filesystem port (reusing
      tcresolve/fscall/tcbstr verbatim — no new DOS-list code;
      his boot-test call: L:ccon-history, right next to the
      handler binary, not S: — a one-line tcresolve target swap).
      The one genuinely new piece: acting as the FINDOUTPUT/
      FINDINPUT CALLER instead of the answerer — a zeroed
      `filehandle` is allocated, its BPTR rides as arg1, the
      filesystem writes ITS OWN file id into `.args` (offset 36,
      cross-checked against amitools' FileHandleStruct —
      fh_Link/fh_Port/fh_Type/fh_Buf/fh_Pos/fh_End/fh_Funcs/
      fh_Func2/fh_Func3/fh_Args/fh_Arg2, SIZEOF 44, matches the E
      module field-for-field), reused as arg1 on every WRITE/
      READ/END after. Load runs once, at the first-ever console
      open this process serves (curcon must be a live console for
      tcresolve to scratch through — main() has none yet, so it
      cannot happen any earlier).

      **b17, his catch:** save only ran in conclose() when the
      LAST window across the process closed — a plain reset
      (not a clean close-all) lost the entire session's history,
      since that was the only save point. Fixed: `savehistfile()`
      now runs after EVERY committed command too (dovanilla's
      Return handler, right after `histremember`), not just on
      last-close. Rewritten to not regress interactively doing
      that: it used to fire one ACTION_WRITE packet PER history
      line (fine once, at close) — at 200 entries that's 200
      round-trips after every single Enter, which would be felt
      as lag. Now it batches the whole ring into one 2048-byte
      buffer, flushing via WRITE only when the buffer would
      overflow — a handful of packets per save regardless of
      ring size, not one per line. The old last-close save stays
      as a now-mostly-redundant safety net (conclose still calls
      it; it's a same-content rewrite in the normal case, cheap).

      **Verification note:** vamos could not close the loop this
      time — its dos.library does not back a `Lock()`'d file with
      a real handler process/port (`.task` reads back 0; vamos
      resolves paths on the host side, bypassing the packet layer
      entirely for guest calls), and `FindDosEntry` isn't
      implemented at all (logs "-> d0=0 (default)"). Confirmed by
      building the harness anyway and watching both fail exactly
      that way — not assumed. What COULD be verified on Linux was
      verified: the `filehandle` struct offsets against amitools'
      ground truth (above), and the packet field conventions
      (arg1=id/arg2=CPTR buffer/arg3=length for WRITE/READ, arg1=
      id for END) by reading ccon-handler.e's OWN dofind/dowrite/
      satisfyreads — code that has been boot-verified for months
      as the SERVER side of this exact protocol; the new code is
      its mirror image as a CLIENT, built from the same ground
      truth. This is FS-UAE boot-test territory now, same as the
      original M5b tab-completion packet code must have been.

      **b18, his catch:** Up/Down walked the WHOLE ring regardless
      of what was already typed — `ls` then Up surfaced `version
      l:ccon-handler` right alongside every `ls` command. This one
      IS pure in-memory logic (no packets, no filesystem), so
      unlike the save/load code above it COULD be fully proven on
      Linux: a throwaway harness (fake ghist ring, same
      histmatches/doup/dodown bodies) ran all four cases — filtered
      up, filtered down, unfiltered (empty prompt), filter matching
      nothing — and every one landed exactly on the expected line
      and hpos before the real build was touched.

      The fix: `histmatches(idx, pfx)` — does ring rank `idx` start
      with `pfx`, case-folded, empty `pfx` always TRUE. RK_UP/
      RK_DOWN now scan for the next/previous match instead of a
      flat `hpos +/- 1`; `curcon.stash` (already captured at walk
      start, previously only used as "the half-typed line to
      restore") doubles as the filter — no new per-console field.
      Fish/zsh convention: the filter is whatever was on the line
      when the FIRST Up fires, fixed for the whole walk; editing
      the recalled line mid-walk doesn't change it. A bare Up/Down
      on an empty prompt is `histmatches` with an empty filter, so
      it's the exact same code path as before, not a fork.
- [ ] **First-word command completion — tried, reverted, PARKED
      for later (19.7.26 night, "the more I try it the less I
      like it").** `dotab` captures whether
      the completed word is word one (`firstword`, before the
      dirpart-split loop reuses the `i` it was computed from) and,
      when it's word one AND no explicit path was typed (`dirp[0]
      = 0`), calls `tcscancmd()` instead of the usual tcresolve+
      tcscan — command completion, not filename completion. Word
      two+ and any explicit-path word one (`c:li<Tab>`) are
      completely untouched.

      `tcscancmd` gathers from two sources, exactly as the design
      called for: resident commands via `FindSegment(NIL, seg,
      TRUE)` under Forbid() (not a semaphore as first guessed —
      the real dos.library autodoc says Forbid(), "no packets"
      either way; filtered to `seg.uc = CMD_INTERNAL`, the
      documented "-2 = resident shell command" marker — CMD_SYSTEM
      -1 and ordinary loaded segments are NOT commands, excluded),
      then every lock in the CLI's own `cli_CommandDir` chain (the
      Path list — C: by default, more if he's `Path ADD`ed) via
      the same M5b directory-scan packets already used for normal
      completion. NOT the current directory — that's not where the
      shell looks either, by design.

      `tcscan`'s single-directory body split into `tcscanone(port,
      lock, pfx, plen)` (the scan) and `tcadd(name, isdir, hidden)`
      (the pool-pack), so `tcscancmd` can call the same machinery
      per Path entry without resetting between calls. `tcadd` also
      gained a dedupe check (`tchas`) — a command can legitimately
      be both resident AND a file in C:, and two sources merging
      into one list made that a real (if cosmetic) possibility for
      the first time; `tcscan`'s original single-directory call
      never needed it and still doesn't pay for it (an empty list
      makes `tchas` a fast no-op).

      `pathnode` (next/lock, two BPTRs) isn't in any stock E
      module — added by hand, cross-checked field-for-field
      against amitools' `PathStruct` (`path_Next`/`path_Lock`,
      nothing else) before use, the same discipline as the
      `FileHandleStruct` check for history. `FindSegment`'s
      contract (Forbid()-only, no locking, the -1/-2/-999 seg_UC
      meanings) came from the real dos.library autodoc found on
      disk, not memory — this one genuinely wasn't remembered
      correctly at first (thought semaphore, thought di_Handlers/
      DosInfo was the way in) and the autodoc caught it before any
      code was written, exactly the point of reading it first.

      **Verification split cleanly in two, same as history:** the
      dedupe/pool-packing logic (`tchas`/`tcadd`) is pure in-memory
      — fully proven with a throwaway harness (two colliding names
      from "different sources" collapse correctly case-fold, a
      forced pool overflow sets `tcmore` without corrupting
      anything). The resident-list walk and Path-chain walk are
      real OS integration — FindSegment found nothing under vamos
      (no Shell ever populated a resident list there, expected,
      not a failure) and the Path chain needs a live CLI process
      vamos doesn't model either. Both are FS-UAE boot-test
      territory, like the history packet code before it.

      **b20, his catch:** completion should find C: commands
      ALWAYS, whether or not C: happens to be sitting in the Path
      chain. The original design leaned on "C: is normally the
      first Path entry by default" — true in the ordinary case,
      but a real design smell (silently depending on a default
      nobody guarantees, and the whole function bailed out with
      NOTHING if `tcclient()`/`proc.cli` failed to resolve at all,
      taking C: down with it). Fixed: `tcresolve('C:')` +
      `tcscanone` run unconditionally, before the Path chain is
      even reached — C: is found whether or not the CLI resolves,
      whether or not Path was ever touched. `tchas` already
      deduped the common case (C: also in the chain); now it earns
      its keep in the uncommon one too.

      **b21, his catch — a real design problem, not a bug:**
      "hitting Tab in RAM: should obviously not show everything in
      C:." b20's model was EXCLUSION — word one searched ONLY the
      command sources, deliberately leaving the current directory
      out ("that's not where the shell looks"), technically true
      for command RESOLUTION but wrong for what Tab should ever
      DO: a bare Tab in RAM: dumped C:'s command list and showed
      nothing of RAM: at all. His fix, and the right one: MERGE,
      don't exclude. `tcscancmd` gained one more unconditional
      source — `tcresolve('')` (the exact CWD lookup plain word
      completion already used, just invoked directly) scanned via
      the same `tcscanone`/`tchas` machinery as C: and the Path
      chain. `d<Tab>` in RAM: now offers `demo/` from RAM: and
      `delete` from C: in one sorted, deduped menu — nothing
      hidden, nothing shadowed. A bare Tab goes back to reading as
      "your directory, plus commands," not "the whole command
      universe, minus your directory." Word two+ and explicit-path
      word one are still completely untouched — the merge only
      ever ADDS sources for the bare-word-one case, never removes.

      **PARKED (b22):** even merged, he didn't like it — C:/
      resident/Path entries mixed into the menu felt like clutter
      rather than help, and repeated use didn't change his mind
      ("the more I try it the less I like it"). Reverted: `dotab`
      no longer branches on word position at all, `firstword` is
      gone, every word (including the first) is plain filename
      completion again, unchanged from before Theme B #2 started.
      `tcscancmd`/`tcadd`/`tchas`/`tcscanone`/`pathnode` all stay
      in the source, compiled in but UNREFERENCED (the compiler
      says so, harmlessly) — the struct-offset verification and
      the resident-list/Path-chain plumbing don't have to be
      re-derived if this idea gets a different shape later (a
      SEPARATE key from Tab, maybe, rather than folded into it -
      undecided, not scheduled). `tcscan` keeps calling through
      `tcscanone`/`tcadd` internally — that refactor was a pure
      no-op split, nothing to revert there.

- [x] **Memory footprint pass (b23) — done, deployed, his boot
      test pending.** Started from two of his screenshots: a
      before/after `avail` around a bare `newshell ccon:` (delta
      ~1.03MB) and a WB titlebar mem-free before/after (delta
      ~1.06MB, same ballpark). Rather than guess the window's
      column count, he sent a THIRD screenshot — a ruler line
      (`123456789012...`) typed into that exact bare window and
      wrapped across several rows. Counted it two independent ways
      (the no-prompt wrapped rows, and the prompt-row's 13-char
      prefix + digit count) — both agreed: **70 columns**, not
      guessed. Model math from that: `3 planes x SBMAX(4000) x
      cols(70)` = 840,000 bytes, plus ~6.4K of fixed per-window
      strings, plus (if that was the session's first window) the
      one-time 80.8K shared history ring — ~927K predicted vs
      ~1.03-1.06MB measured, a ~128K gap left honestly unexplained
      rather than papered over with a guess.

      His question along the way: CCON opened in MicroKnight 7/7,
      not topaz 8, from a bare `newshell ccon:` — is that right?
      Checked against the real intuition.library autodoc (not
      memory): `GfxBase.DefaultFont` is documented as "sysfont 0 -
      old DefaultFont, fixed-width, the default," distinct from
      the Workbench screen's own (possibly proportional) font.
      Confirmed CCON reads the correct slot — if his Font Prefs'
      FIXED default is MicroKnight, stock CON: and every other
      console-type window would open in it too. Not a CCON bug;
      a Prefs fact, worth him checking `SYS:Prefs/Font` if topaz 8
      was actually expected there.

      The fix, his call from three options: **default SBMAX 4000
      -> 1000** (a straight 4x cut in the common case — LINES=n
      still opts up for anyone who wants more), plus a new
      **SBMAXCAP (4000)** ceiling on LINES=n itself, which had NO
      upper bound before (a typo could have asked for an enormous
      window — this was a real latent gap, not just a footprint
      tweak). `ccon.doc`/`ccon.readme`'s memory figures updated to
      the real math (~235K at 80 cols/1000 lines) — the old "~600K"
      number was ALREADY stale before today, predating the Theme A
      style plane; caught and fixed in the same pass. Also
      quietly dropped a doc line that had gone stale since Theme B
      #1 shipped ("History is per window and dies with it" — it
      hasn't, since b16).

      **Declined for now, his call still open:** bit-packing the
      style plane (`ss` uses 1 full byte per cell for 3 bits of
      real data — italic/underline/inverse — so ~5/8 of it is
      spare). Real savings on top of the SBMAX cut, but it touches
      every painter that reads/writes `ss` (drawmrow, clearrow,
      cursdraw, drawselrow, redraw, screenscroll, drawmodelrow,
      drawedit, csidispatch's SGR handling, altsave/altrestore) —
      explained the tradeoff, did not implement, waiting on
      whether he wants that scope taken on.

- [x] **The LINES384 mystery, solved — and a real bug fixed
      (b24).** His ViNCEd-vs-CCON comparison sequence
      (`newshell ccon:0/0/640/100/LINES384`) came back with numbers
      that made no sense — two supposedly-identical windows costing
      different amounts. Zoomed into his own screenshots character
      by character rather than re-guessing: the command he actually
      typed had explicit geometry, and with explicit geometry the
      open-string's field order is fixed — x/y/w/h/TITLE/options.
      Field 4 is unconditionally the title, no exceptions, so
      "LINES384" landed there as plain text and the depth option
      was NEVER applied — that window silently ran at the DEFAULT
      depth. No error, no warning. His own workaround (inserting a
      dummy "LINES" title first, pushing LINES384 into field 5)
      is exactly why one of his two "LINES384" windows worked and
      the other didn't.

      Real fix, not just a doc warning: field 4 now tries
      `parseopt()` FIRST. Every prefix-based option branch inside
      it (`SCREEN`/`PEN`/`WINDOW0X`/`LINES`/`FONT`) was tightened to
      fail closed — `matched := FALSE` unless the suffix actually
      parses — so a token only diverts from becoming the title when
      it's a GENUINE option, not just something that starts with
      the same letters. `torig[]` (a manual byte-copy, not
      `StrCopy` — `tok`/`torig` are plain fixed arrays, not
      `String()`-allocated E strings, the same trap `dirp[]` already
      routes around in `dotab()`) preserves the original casing,
      since `parseopt` folds its argument to uppercase in place
      even on a non-match.

      Verified with a harness (parsecon+parseopt extracted
      verbatim, post-fix) before touching the real build: the
      literal failing string now keeps the default title and
      correctly sets `plines=384`; ordinary titles including ones
      that merely START with a keyword ("My-Window", "Penguin")
      survive untouched; a real option in the title slot
      ("FONTtopaz/8", "WAIT") still works; every string
      boot-verified earlier tonight matches byte-for-byte, zero
      regressions. One accepted, disclosed gap: `FONT`/`SCREEN`
      immediately followed by more non-space text (e.g.
      "Fontwork") still gets swallowed — both accept any non-empty
      suffix as a valid name with no further validation, so a
      coincidental collision there can't be distinguished from a
      real one.

      Also deployed in the same build: temporary window-title
      telemetry (`[sbmax=N cols=N bytes=N]` prefix) so the
      original footprint questions can be answered directly from
      the title bar instead of more screenshot arithmetic — to be
      stripped once he's satisfied with the numbers.

      **The mystery, actually resolved (his own screenshot chain,
      re-read character by character):** window 4's telemetry
      title read `[sbmax=384 cols=87 bytes=33408]` — 384×87 =
      33,408 exactly, proving both the fix and the model math are
      correct. The residual "gap" between that confirmed number
      and the raw `avail` deltas turned out to be unrelated to
      CCON at all: every test opened its window via `newshell`,
      which creates a whole new Process (stack, CLI struct,
      environment) on top of whatever CCON itself allocates — the
      SAME category of cost a fresh ViNCEd shell also pays. Final
      head-to-head at matching depth (384 lines): ViNCEd ~246KB
      total, CCON ~439KB total, but CCON's actual scrollback model
      is a precise, telemetry-confirmed ~98KB of that — the rest is
      generic per-window process overhead, not a CCON inefficiency.

- [x] **Width/height=-1 fills the screen — done, deployed as
      "1.1b25", his boot test pending.** His ask, arriving mid
      footprint-hunt: `newshell ccon:0/0/-1/-1` should open a
      window covering the whole screen. `-1` is a genuinely new
      sentinel meaning "fill" — it couldn't reuse `tcnum()`'s
      existing failure return (`tcnum` has no minus-sign support
      at all, so `"-1"` was ALREADY read as "not a number" and
      silently ignored, defaults kept — the exact behavior the
      "0/0/-1/-1" curiosity earlier tonight quietly relied on
      without anyone asking for it). Field 2/3 (width/height) now
      check for the literal string `"-1"` before falling through
      to `tcnum`, so a real `-1` means fill while garbage still
      means "ignored, keep the default" as before.

      Resolution happens in `openwin()`, before the existing
      160×60 floor clamps (which would otherwise misread a
      still-unresolved `-1` as "way too small" and clamp it there
      instead of filling anything): the SAME `LockPubScreen` call
      that used to only fire for an explicit `SCREENname` now also
      fires whenever either field is `-1` and no name was given
      (`LockPubScreen(NIL)` — the default public screen), and that
      ONE lock both answers "how big" (`pubscr.width`/`.height`)
      and is the lock the window actually opens on — deliberately
      not two separate calls, so there's no window for the default
      screen to change between "measure" and "open on". A failed
      lock falls back to 640×200 rather than falling through to
      the tiny 160×60 minimum. Width and height resolve
      independently (`.../-1/300` fills width only).

      Verified via the same parsecon-harness discipline: the
      sentinel is captured correctly and independently per field,
      unaffected by the b24 title-slot fix (`0/0/-1/-1/Title` still
      gets `title="Title"`), and every previously-verified string
      still matches. The screen-side resolution itself (`pubscr.
      width`/`.height`, `LockPubScreen`) is real OS integration
      vamos doesn't model — FS-UAE boot-test territory, same as
      the history packet code and the resident-command walk before
      it. Boot-confirmed ("works great" + screenshot, a full-
      screen-edge-to-edge "Test" window, 19.7.26).

      **b26:** the b24 window-title telemetry (`[sbmax=N cols=N
      bytes=N]`) stripped now that both the LINES384 bug and the
      footprint numbers are settled — titles are plain again,
      nothing temporary left in the tree from tonight's footprint
      hunt.
- [x] **Bracketed-paste safety — two designs, the second one
      shipped (b27→b28) — deployed as "1.1b28", his boot test
      pending.** RAMIGA-V used to replay every LF in a pasted clip
      as a Return, so a multi-line paste EXECUTED line by line as
      it landed — no chance to see or stop a dangerous line before
      it ran.

      **b27, the first attempt (drip-feed):** only the first line
      landed live; anything past the first embedded LF queued in a
      new `pasteq` buffer and was fed back ONE LINE PER REAL ENTER
      via `pastepull()`, called from `dovanilla`'s Return-commit
      path. Fully harness-verified, boot-deployed — and wrong: his
      catch was that the queue advanced on ANY Enter, including a
      totally unrelated command he typed fresh after seeing only
      one pasted line. A queued line would silently pop up after
      that unrelated command finished, looking like paste content
      arriving from nowhere. Asked what he actually expected: "all
      lines pasted without any send (enter)" — the drip-feed model
      was never going to satisfy that, no matter how well-tested.

      **b28, the redesign:** the WHOLE clip lands live as ONE long,
      fully editable line — cursor movement, Backspace, Ctrl+W/U/K,
      all of it just work, because it reuses the width-wrap editing
      model completely unchanged. The one real design question was
      how to show an embedded newline in that single-line model
      without teaching `edcap()`/`edlastrow()` (which have NO
      concept of an explicit line break, only width-driven wrap) a
      new idea — that machinery is exactly what took three separate
      fixes to get right earlier tonight (the b8→b9→b10 eraseedit
      saga), and reopening it for this felt like the wrong trade.
      The answer: `PASTENL` (182, a Latin-1 pilcrow) stands in for
      an embedded LF while editing — chosen as a byte essentially
      never found in real command text. `pasteinsert()` does the
      substitution going in; `pasteundo()` reverses it in place,
      called from `dovanilla`'s Return-commit path AFTER
      `histremember()` (so Up/Down recall re-shows a pasted multi-
      line command correctly, still editable, exactly like a fresh
      paste) but BEFORE `render()`/`enqueue()` (so what actually
      echoes to the transcript and what the shell actually reads
      both have real newlines — `render()` was already newline-
      aware, since it draws all ordinary command output, and
      `enqueue()`/`satisfyreads()` were already LF-splitting by
      design, so the shell reads a multi-line commit as the several
      separate commands it always was, with ZERO changes to either).
      One Enter, once pressed, runs everything, in order — nothing
      runs before that. Esc clears the whole line, pilcrows and
      all, in one shot — it was already just ordinary `ebuf`
      content, no separate queue left to abandon.

      Deliberately NOT routed through `dovanilla`'s normal dispatch
      for the inserted text — `pasteinsert()` mirrors just its
      printable-character insert shape (shift-right, drop in,
      `SetStr`) directly, now also accepting the substituted
      pilcrow. `injectbyte()`'s old byte-by-byte `dovanilla(c,0)`
      call (still used for the forceexec/raw paths) would let a
      pasted Tab/Ctrl-R/Esc byte trigger completion/search/line-
      clear as a SIDE EFFECT of pasting — already true before
      tonight; the safe path avoids it, a stray control byte is
      just an odd literal character, never a triggered action.

      Two escape hatches back to the old instant-run behaviour,
      unchanged from b27: RAMIGA+SHIFT+V forces it for one paste
      (`ihmap[0]="V"` vs `"v"` — MapRawKey already folds Shift into
      the mapped letter, no new qualifier plumbing); the `PASTEEXEC`
      open option makes a whole window behave that way always. Raw
      mode is completely untouched — still `injectbyte`'s byte-
      faithful `enqueue()`, no substitution concept there at all.

      `pasteq`/`pastepull`/`pasteappend`/`PASTEQMAX` (b27's queue
      machinery) are gone entirely — the new design has nothing to
      queue, so there was nothing to keep. Net simpler than b27,
      not more complex, despite doing more.

      **Verified with a harness** before deployment, same as b27's
      was: a three-line paste producing the exact expected pilcrow-
      substituted string, `pasteundo()`'s exact reversal back to
      real LF bytes, a cursor-position insert into the MIDDLE of
      existing text (not just appending at the end), and a
      deliberately oversized paste against `edcap()`'s existing
      400-char cap (truncates cleanly, no overflow) — all landed
      exactly as designed.

      **PARKED follow-up: real multi-row paste display.** He asked,
      after seeing b28 boot: could the pasted lines show as actual
      separate visual rows instead of one wrapped line with pilcrow
      joins? Investigated properly before deciding, not waved off —
      read the FULL body of `drawedit()` this time, not just the
      functions it calls. The scope is real, not vague caution:
      EVERY position calculation in the edit-line renderer assumes
      pure width-driven wrapping, a straight-line map from "logical
      offset from the anchor" to "screen row/column" via `n / cols`
      and `Mul(row, cols)`. Counted at least six separate places
      that do this inside `drawedit()` alone — the main text paint
      loop, the old-text mirror-zeroing tail, the cursor blip
      position, the ghost position, the Ctrl+R search banner
      overlay, and the stale-pixel cleanup tail — plus `edlastrow()`,
      `edcap()`, `edroom()`, and `eraseedit()` as their own separate
      functions. An embedded newline forcing an early row break
      breaks the straight-line assumption EVERYWHERE at once; all of
      them would need to agree, consistently, or it's the b8→b9→b10
      saga again (erase extent and paint extent computed by two
      pieces of logic that quietly drifted apart) — except spread
      across a dozen call sites instead of two.

      Given that's the single most bug-prone code in the project
      (three confirmed incidents already, on ordinary single-line
      editing, with none of this extra complexity) and this was
      already a very long session, his call: park it for a session
      with a clearer head, keep the working, committed b28 pilcrow
      version as the safe baseline.

      **A sketch worth starting from, not a spec:** rather than
      re-deriving newline-aware row/column math ad hoc at each of
      those dozen call sites (repeating the exact mistake that
      caused b8→b10), centralize it — one `edrow(n)`/`edcol(n)`
      pair (or a single packed-return helper) that scans from the
      anchor counting `PASTENL` as a forced break, used EVERYWHERE
      `n / cols` currently appears. Harness-verify that pair alone
      first, exhaustively, against both the no-newline case (must
      match the OLD pure-division math byte-for-byte — regressing
      ordinary typing would be far worse than an imperfect paste
      feature) and various embedded-newline placements, before
      touching a single call site in the real function. Cursor
      movement keys (Left/Right/Home/End/word-jump) likely need NO
      changes at all — they already operate on `cpos` as a content
      index, not a screen position; only the RENDERING math is
      actually offset-dependent. Confirm that assumption with the
      harness too, don't assume it holds.

      **b29, superseding b28 — his honest reconsideration:** "I
      don't think we need multi-row copy/paste if it can't be done
      right. The weird little linebreak symbol does not really
      compare to a real multi row copy/paste." Fair, and it
      reframed the actual question: not "how do we fake multi-row"
      but "what's the RIGHT behaviour if we don't." Talked through
      three honest options — keep the pilcrow, revert to a FIXED
      drip-feed, or drop multi-line paste entirely (first line
      only, rest discarded with a beep). His call: the drip-feed,
      properly fixed.

      Back to b27's shape (`pasteq`/`pasteappend`/`pastepull`,
      re-added — `PASTENL`/`pasteinsert`'s substitution/`pasteundo`
      all removed again, no longer needed) — only the FIRST line
      lands live, looking exactly like typed text, zero new
      rendering concepts. What was ACTUALLY wrong with b27 wasn't
      the drip-feed concept, it was that the pending queue was
      invisible — his next ask, once he saw the choice laid out:
      "it needs a way to abort," and separately, a visible
      indicator so advancing the queue is never a silent surprise.

      First cut of the indicator went in the window title
      (`[paste: N more, Esc cancels]`) — simplest, zero new
      drawing. He preferred something more visible: "a greyed
      (hidden) line under or above the prompt." Built on the
      Tab-completion menu's OWN established pattern for exactly
      this problem (`tcmenucalc`/`tcmenudraw`/`tcclose`) rather
      than inventing a new one — `pastehintroom()` mirrors the
      menu's scroll-until-it-fits room-making, `pastehintshow()`
      mirrors its pixels-only draw/restore-from-model discipline,
      drawn in the same ghost pen (and gated on the same
      `ghostpen() >= 0` readable-grey check) the autosuggestions
      already use. Recomputed on every `drawedit()` call, same as
      the ghost and the Ctrl+R banner, so it tracks the current
      line's row as it grows/shrinks and needs no separate
      "hide the hint" call anywhere — Esc and the final `pastepull`
      both just leave `pasteq` empty, and the next `drawedit()`
      notices and erases it. One care point the menu's pattern
      didn't need: if the edit line's OWN paint has grown to reach
      the hint's old row (line got longer), erasing that row from
      the model would stomp the just-painted text — guarded with
      `IF pastehintrow > edlastrow(l)` before erasing.

      Esc's job (already correct in b27, just re-added here):
      clears the CURRENT line AND the whole queue in one shot —
      the hint literally says "Esc cancels all," so it has to.

      **Verified what harness verification can reach:** the queue
      walk itself (a four-line paste, three `pastepull()` calls,
      the line-count helper `pastelines()` reporting 3→2→1→0 in
      step, a 4th call past exhaustion staying a safe no-op) and
      the Esc-equivalent queue-clear — all pure in-memory, fully
      provable on Linux. The actual grey-row PAINT (`Move`/`Text`/
      `drawmodelrow`, the room-making scroll) is real Intuition
      drawing vamos cannot display or check — FS-UAE boot-test
      territory, like the rest of tonight's screen-facing work.

- [x] **Scrollback search (b30) — Theme B's last item, done,
      deployed as "1.1b30", his boot test pending.** The last
      KingCON/ViNCEd feature CCON lacked: a way to search the
      scrollback content itself, not just the command history.
      His choice on the trigger-key design question: "Ctrl+R,
      reused contextually" — no new key, no dedicated `/` prompt.
      Ctrl+R now branches on `viewoff`: at the live prompt it's
      still exactly the old history search, untouched; once
      scrolled back (`viewoff > 0`), the SAME key searches the
      scrollback rows instead. The two modes can never be active
      together, so reuse was safe rather than a hazard.

      Built as a near-total mirror of the existing Ctrl+R history-
      search state machine — new fields `sbsrch`/`sbidx`/`sbstash`
      alongside the old `srch`/`sridx`/`srbuf`, and new procs
      `sbenter`/`sbadd`/`sbback`/`sbnext`/`sbprev`/`sbexit`/
      `sbcancel` shaped exactly like `srenter`/`sradd`/`srback`/…
      — plus two new pieces the history version didn't need:
      `sbrowidx(v)` converts a scroll-offset `v` into the ring
      buffer's physical row index (the same `sbtop`-relative math
      `redraw()` already does, factored out), and `sbfind(fromv,
      dir)` does the actual fold-case substring scan across
      scrollback rows, INCLUSIVE of the starting row, walking in
      the given direction until a match or the history's edge.

      The one non-obvious step: proving `viewoff` itself is
      directly usable as `sbfind`'s "v" position, with no separate
      conversion layer — worked out on paper first (viewoff is
      already defined as "how many rows back from live," which is
      exactly what `sbrowidx` needs), then confirmed against a
      hand-built harness (`sbsearchtest.e`, a fake 10-row ring at
      cols=8, sbtop=2, sbcnt=5) rather than trusted on the
      derivation alone.

      Hooked into `dovanilla()` at the very TOP of the function,
      before `snaplive()` and before the raw-mode short-circuit —
      required so the feature works while scrolled back inside a
      raw client's output too (More, Ed), which was an explicit
      design requirement, not an afterthought. Three states
      handled there: actively typing a fragment (`sbsrch`, routes
      printable keys to `sbadd`, Ctrl+R to `sbnext`, Backspace to
      `sbback`, Esc to `sbcancel`, anything else exits typing via
      `sbexit` but keeps the match); not typing but still scrolled
      back and a fragment exists (`viewoff > 0`, routes Ctrl+R to
      re-enter typing, n/N to `sbnext`/`sbprev`); everything else
      falls through to the ordinary path unchanged.

      One design trap caught during the paper-design pass, before
      any code was written — not a bug found later: 'n'/'N' were
      first drafted as unconditional jump commands inside the
      active-typing branch too, which would have made searching
      for a fragment containing either letter (e.g. "run",
      "found") impossible. Fixed by scoping the n/N jump-shortcut
      to ONLY the not-typing state — while `sbsrch` is TRUE, 'n'
      and 'N' fall through to `sbadd()` like any other printable
      character.

      Esc restores the exact `viewoff` the search started from
      (stashed in `sbstash` at `sbenter()`), same abort discipline
      as the paste hint row right above this. Match highlighting
      (`sbhighlight`) paints the matched span of the bottom-most
      visible row in inverted colours directly via `Move`/`Text`/
      `SetAPen`/`SetBPen` — pixels only, no model change, same
      discipline as the ghost text and the paste hint.

      **Verified with a harness** (`sbsearchtest.e`) before
      touching the real build: `sbrowidx`'s v-to-ring-index
      mapping against a hand-derived table (including wraparound,
      e.g. v=5 → idx=9 on a 10-slot ring), forward search, case-
      fold search, an inclusive re-search from the found spot
      landing on itself, a deliberately-absent fragment returning
      not-found without crashing, backward search, and an out-of-
      range starting `v` (99) staying a safe no-op — all six exact
      matches against hand-derived expected values. The actual
      inverse-highlight PAINT and the `(search: frag)` title
      banner are real Intuition drawing vamos cannot check —
      FS-UAE boot-test territory, same as every other screen-
      facing item tonight.

      **b31, real bug found on first boot test, fixed same
      session.** His report: Ctrl+R always gave command-history
      search, scrolled back or not — b30's whole content-search
      entry point was dead on arrival. Root cause was NOT in any
      of the new sbsrch code, which traced out correct on paper —
      it was a pre-existing two-pass ordering fact that b30's
      design happened to collide with for the first time: every
      key crosses this handler TWICE, a RAWKEY event first (
      `dorawkey()`), then a VANILLAKEY event second (`dovanilla()`,
      where the whole sbsrch/Ctrl+R/n-N gate lives, guarded on
      `curcon.viewoff`). `dorawkey()` had one unconditional line —
      `snaplive()` for "any other key returns the view to live" —
      that fired on the RAW pass for literally every ordinary key,
      including Ctrl+R itself. `snaplive()` zeroes `viewoff`
      directly. So by the time the SAME keystroke's VANILLAKEY
      event reached `dovanilla()` a moment later, `viewoff` had
      already been reset to 0 by its own earlier pass — the gate
      never saw "scrolled back" as true, no matter how far back
      the user actually was. n/N-after-typing was silently broken
      the identical way (they're ungated ordinary letters on the
      raw pass too); only entering via Ctrl+R got caught by his
      testing.

      Fix, in `dorawkey()`: that snaplive() call is now conditional
      — it still fires unconditionally for the handful of raw keys
      that have NO vanilla counterpart at all and so would never
      reach `dovanilla()`'s own snaplive() otherwise (arrows in
      both modes, plus F1-F10/Help in raw mode, `rawcsikey()`'s
      complete special-key list) — everything else defers to
      `dovanilla()`'s existing, already-correct gate. Verified by
      tracing every call site by hand rather than guessing: Ctrl-
      arrows/Shift-arrows/wheel already RETURN before this line
      (untouched); plain arrows are explicitly kept in the eager
      list (unchanged behaviour, still needed since arrows never
      generate a VANILLAKEY event); every ordinary printable key,
      Ctrl+letter, Return, Backspace, Esc and Tab all DO generate a
      VANILLAKEY event, so `dovanilla()`'s own `snaplive()` call
      (already present, already firing for every case not consumed
      by the search guard) covers them with identical end-user
      behaviour to before — the only actual removal is the
      redundant EARLIER of two snaplive() calls that used to fire
      for those keys, not a behaviour change. One knowingly accepted,
      narrow edge case: an F-key or Help pressed while scrolled back
      in COOKED mode (not raw) has never been handled by `dorawkey()`
      at all beyond that side-effect un-scroll, and now does
      nothing whatsoever while scrolled — not a documented feature,
      nobody could have been relying on it.

      This is pure control-flow, not model math, so nothing new to
      harness — verified by hand-tracing every code path through
      the two-pass sequence for the specific keys this session's
      retest checklist covers (Ctrl+R, n, N, all four arrows in
      both modes, Ctrl/Shift+arrows, ordinary typing, Return/
      Backspace/Esc/Tab) before compiling. Deployed as "1.1b31",
      his boot test pending — this is the retest that actually
      exercises the b30 feature for the first time.

      **b32, two findings from that retest — one real bug, one
      stale doc claim.** He wrote both up directly in his private
      bughunt file rather than describing them in chat, `[v]`/`[x]`
      marks and observed-behaviour notes inline on the checklist —
      first time he's used the file that way; read it directly
      rather than asking him to re-describe.

      **Finding 1, real, fixed:** Enter while a scrollback search
      was still typing gave a new EMPTY PROMPT instead of just
      exiting search in place ("I get a new empty prompt"). Root
      cause was in the `ELSE` arm of `dovanilla()`'s `sbsrch`
      dispatch — the one that catches "any key that isn't Ctrl+R/
      Esc/Backspace/a fragment character," which correctly called
      `sbexit()` but then had no `RETURN`, so execution fell
      straight through into `snaplive()` and the ordinary Return-
      commit path a few lines down. For Enter specifically, that
      meant: exit search, THEN also run whatever's in the (empty)
      `ebuf`, i.e. act exactly like pressing Enter on a blank
      CCON: prompt. Every OTHER arm of that same `IF curcon.sbsrch`
      block already had its own `RETURN` — this was the one
      omission. Fix: `sbexit()` followed by `RETURN`, matching the
      pattern already used everywhere else in that block.

      Caught a second instance of the identical gap while fixing
      the first, not yet reported by him: arrow keys pressed mid-
      search never reached `dovanilla()`'s `sbsrch` block at all
      (arrows are raw-only, no vanilla byte), so they'd silently
      move the cursor in the — again, probably empty — edit line
      underneath a search banner that was still claiming to be
      active. `dorawkey()` already special-cases arrows to exit the
      OLDER `curcon.srch` (history search) for exactly this reason
      (`srexit()` on RK_UP/DOWN/LEFT/RIGHT, the comment calling it
      "the two-pass trap"); `curcon.sbsrch` just never got the same
      treatment when it was added in b30. Added an identical
      `IF curcon.sbsrch ... sbexit()` guard right next to the
      existing one.

      **Finding 2, not a bug — a stale doc claim, corrected:** "I
      can't go up in more. I can not scroll in ed" is CORRECT
      behaviour, not broken — Ed and More both run on the
      alternate screen (the ?47h/?47l xterm trick from Theme A)
      for essentially their whole session, and `scrollview()` has
      ALWAYS unconditionally refused while `curcon.altvalid` is
      TRUE (`IF curcon.altvalid THEN RETURN` — the exact fix that
      stopped More's own pager bars leaking into scrollback in the
      first place). What was actually wrong: `ccon.doc` section 10
      claimed "you can wheel back through More's display or a
      fullscreen program's output while it runs," and
      `ccon.readme` echoed the same claim — flatly contradicting
      section 13's own correct caveat ("except on the alternate
      screen... where scrolling is refused, xterm manners") two
      sections later in the SAME document. Section 10's claim
      predates the alternate-screen feature (or was simply never
      reconciled with it once added) and was never exercised until
      this retest actually tried it. Corrected both section 10 and
      the readme to match section 13's accurate framing: raw-mode
      scrollback genuinely works for a client that never takes the
      whole screen (CRAW:, plain streaming output) — Ed and More
      specifically are the standing exception, not the rule, since
      they're on the alternate screen for nearly their entire
      runtime. The b30 retest checklist's "raw mode" item was
      testing an impossible scenario as written; replaced it with
      the two scenarios that actually exercise raw-mode content
      search (CRAW: streaming past a screenful, and More/Ed's own
      restored transcript once quit).

      No harness needed for either — the Enter/arrow fix is pure
      control-flow (verified by hand-tracing the same way b31 was),
      and finding 2 turned out to need a document correction, not
      a code change. Deployed as "1.1b32", his boot test pending.

      **b33, his b32 retest: the Enter fix alone wasn't enough.**
      He marked the Enter checklist item `[x]` again — "enter puts
      me back at the prompt but the searched/marked item gone and
      not filled in. any other key exits the search and returns me
      to the prompt." That's a DIFFERENT symptom than b32's ("I get
      a new empty prompt") — no more accidental command execution,
      but still not the documented "keep the match on screen."

      Built an actual harness this time instead of hand-tracing
      again (`entertest.e` — the real `dovanilla()` sbsrch/viewoff
      block extracted verbatim, drawing calls stubbed to WriteF
      markers, model mutations kept real): sbenter → type "TARGET"
      char by char → Ctrl+R again → Enter, printing `sbsrch`/
      `viewoff` at each step. Result: Enter's own control flow is
      CORRECT — `sbexit()`+`RETURN` fires exactly as written,
      `snaplive()` is never reached, `viewoff` ends the run
      unchanged. So pure Enter, in isolation, was never actually
      broken at the model level.

      Two OTHER real bugs were still live, both in the same "two-
      pass trap" family as b31 and both plausibly what he actually
      triggered while probing "any other key" in the same test
      pass — either one would leave `sbsrch`/`viewoff` in a state
      that makes a LATER Enter genuinely misbehave too, which would
      explain why Enter looked broken again even though its own
      logic checks out:

      1. **Tab bypasses `sbsrch` entirely.** `dorawkey()`'s very
         first check intercepts Tab before `dovanilla()` ever runs
         (`IF (code=$42) AND (rawmode=FALSE) ... dotab(sh); RETURN
         TRUE`) — it already calls `srexit()` for the OLD history
         search there, but nobody taught it about `sbsrch` when b30
         added it. Pressing Tab mid content-search would open the
         completion menu while still scrolled back, leaving the
         search banner stuck and `sbsrch` never cleared. Fixed:
         `IF curcon.sbsrch THEN sbexit()` right next to the
         existing `srexit()` call.

      2. **The b32 arrow-key fix was incomplete.** b32 added
         `sbexit()` for arrows in `dorawkey()`'s search-mode-exit
         block, mirroring `curcon.srch`'s own arrow handling — but
         for `curcon.srch`, falling through afterward to the arrow-
         editing code below is the WHOLE POINT (the matched command
         is sitting in `curcon.ebuf`; the arrow should move the
         cursor inside it). `sbsrch` has no such command loaded —
         there is nothing to edit, only a scrolled position to keep
         looking at. Falling through anyway meant `drawedit()` ran
         with `curcon.viewoff` still non-zero. `drawedit()` has
         NEVER been viewoff-aware (nothing had ever called it while
         scrolled before this feature existed — every other caller
         always went through `snaplive()` first) — it unconditionally
         paints the live edit line straight onto the bottom rows,
         desyncing the SCREEN from a model that still correctly
         thinks it's scrolled. Exactly "back at the prompt" while
         the title and `viewoff` disagree. Fixed: arrows now
         `sbexit(); RETURN TRUE` immediately in `dorawkey()`,
         consuming the key completely instead of falling through -
         same treatment Enter already gets in `dovanilla()`.

      Lesson for the record: b31's hand-tracing was real and caught
      a real bug, but b32's follow-up hand-trace missed these two
      because it only re-verified the SAME code paths already
      touched, not the adjacent ones sharing the same trap. The
      harness this time forced an honest verdict on the ONE code
      path it covered (Enter: genuinely fine) instead of letting
      hand-tracing quietly cover for the paths it doesn't reach.

      Deployed as "1.1b33", his boot test pending.

      **b34, the b33 retest: a genuine design mismatch, not more
      bugs.** He tested Enter/Tab/arrows each in isolation as asked
      and reported all four `[x]` items in detail this time (asked
      specifically: "PLEASE read all X items"). The picture that
      came back was consistent and telling:

      - Enter, isolated: "I'm still in search, I can not see my
        prompt... I have no idea if anything is pasted into
        prompt... This IS NOT working." Matches the harness proof
        from b33 exactly — `sbsrch` correctly clears, `viewoff`
        correctly stays put, nothing executes. The CODE was right;
        the DESIGN (stay scrolled, matched text never touches the
        prompt) never matched what a bash-Ctrl+R user expects to
        happen when a search ends.
      - Tab, isolated: "gives me the tab menu IN SEARCH! Not at the
        prompt.!!" — b33's fix correctly stopped the search first,
        but the completion menu then opened on a still-scrolled
        view, which is disorienting even though technically
        "working as coded."
      - Arrows, isolated: "takes me out of search and into the
        prompt. If this is the intended behaviour it works." —
        the one that already felt right, purely as a side effect
        of b31's unrelated "arrows have no vanilla counterpart,
        always snap live" rule, not because anyone designed it
        that way for `sbsrch` specifically.
      - Raw mode / More+Ed: "SCROLLING IN MORE AND ED (OR ANY CLI
        APP) IS A MUST!" — strong pushback on the deliberate
        altscreen-blocks-scrollback rule from earlier tonight.

      Rather than guess at a fix that might trade one complaint for
      another, asked him directly (AskUserQuestion) instead of
      patching blind a third time:

      1. Should finishing a search ALWAYS return to the live
         prompt (matching what arrows already do by accident), even
         though that retires n/N's "keep browsing more matches
         without retyping Ctrl+R" convenience? His call: **yes,
         always return to live** (recommended option, his pick).
      2. For the More/Ed complaint specifically — was he trying to
         use PLAIN arrow keys for More/Ed's own internal paging (a
         possible real forwarding bug, distinct from the deliberate
         altscreen rule), or trying to use CCON's OWN scroll gesture
         (Shift/Ctrl+Up, wheel) to look back at what a STILL-RUNNING
         session had already shown (a real but much bigger feature
         asking to partially reverse tonight's earlier altscreen
         work)? His answer: **plain arrow keys for More's own
         paging.**

      **Fix 1, implemented:** `dovanilla()`'s sbsrch `ELSE` branch
      (Enter and every other non-search key) now calls `snaplive()`
      right after `sbexit()`, and `dorawkey()`'s Tab interception
      does the same before calling `dotab()` — both now behave
      exactly like arrows already did. n/N are NOT dead code: they
      still fire whenever `viewoff>0` by ANY other means (plain
      Shift/Ctrl+Up after a past search, with `srbuf` still holding
      the last fragment) — only the specific "still parked right
      after typing" moment goes away, which was the confusing part.

      **Fix 2, NOT a CCON bug — verified from the real client, not
      assumed:** read the actual `SYS:Utilities/More` binary's own
      strings (the S:More script just runs it; there is no More in
      C: at all, worth knowing for next time this comes up) — its
      OWN help text lists its supported keys explicitly: `<Space>`
      next page, `<Return>` next line, `<BackSpace>` previous page
      ("Less" style), `<`/`>` first/last page, `h` help. No mention
      of arrow keys anywhere, and no CSI/escape-recognition strings
      in the binary either. More was simply never written to
      understand arrow keys, on ANY console — this is a property of
      the client program's own key table, not something a console
      handler forwards differently. CCON already passes Space/
      Return/Backspace through untouched in raw mode; the fix here
      was explaining this to him with the actual evidence, not
      touching the handler. (Ed's arrow-key document navigation was
      already confirmed working in the b8 sweep — unaffected,
      unrelated to this question.)

      Deployed as "1.1b34", his boot test pending — this is also
      the point where his "PLEASE read all X items" request paid
      for itself: the OLD, pre-scrollback-search `[x]` on More's
      title stomping into history (section 8 of the file, way
      below) turned out to already be resolved by the b10
      alternate-screen work — stale, not a live bug, flagged to him
      rather than silently ignored or silently "fixed" again.

      **b35 — b34 was wrong on both counts, and this time he said
      so directly.** His retest of b34: Enter on a found "dir"
      match STILL landed on an empty prompt ("What is the purpose
      of a search that can't grab the result?"), and both the More
      and Ed verdicts were flatly rejected ("HOW THE FUCK CAN CON
      USE ARROWKEYS... IF IT HAS NOTHING TO DO WITH CCON" and a new,
      very specific, previously-unmentioned detail: "IN ED IF I
      SCROLL THE DOCUMENT ONLY THE BOTTOM ROW CHANGES! IN CON THE
      ENTIRE DOCUMENT IS SCROLLED"). Both complaints turned out to
      be real, and both were missed by b34's investigation for the
      same underlying reason: verifying a NEGATIVE claim ("this
      isn't a bug") from documentation/help-text/architecture
      intent is much weaker evidence than tracing the actual code
      path — b34 stopped one level too early on both.

      **Bug 1: scrollback content search never filled in the
      prompt — the actual root cause, not a design question.**
      Re-reading the OLD, working Ctrl+R history search
      (`srfind()`) side by side with `sbfind()` for the first time
      (should have been the very first thing checked back in b30)
      found the gap immediately: `srfind()` does
      `StrCopy(curcon.ebuf, h)` the moment it matches — the found
      HISTORY line lands on the prompt LIVE, as you type, which is
      exactly what makes bash-style Ctrl+R feel like "grabbing" a
      result. `sbfind()` NEVER did the equivalent — it moved
      `viewoff` and painted a highlight, but `curcon.ebuf` was
      never touched, so no matter which key ended the search there
      was never anything to land on the prompt. This was never a
      "should Enter return to live" design question at all (b34's
      framing was itself a symptom of missing the real gap) — it
      was a straightforwardly incomplete port of the history-search
      pattern to content search. Fixed: `sbfind()` now builds the
      matched row's text (right-trimmed of the model's
      never-written/blank tail, capped by `edcap()` exactly like
      `srfind()`) into `curcon.ebuf` on every match, live while
      typing. `sbenter()` now also stashes the pre-search `ebuf`
      into `curcon.srstash` (safe to share with history search —
      the two are mutually exclusive by construction) and
      `sbcancel()` restores it on Esc, mirroring `srenter()`/
      `srcancel()` exactly. b34's actual code change (Enter/Tab/
      arrows snapping live) stays — it's still correct and still
      wanted, it just wasn't the fix for THIS complaint, since
      landing on a live but EMPTY prompt was always going to read
      as broken regardless of scroll state.

      Verified via harness (`escsbtest.e`, extending the sbfind
      extraction pattern from b30): a fake 8-column row `"dir foo"`
      matched by fragment `"dir"` lands in `ebuf` as exactly
      `"dir foo"` (trailing model padding correctly stripped),
      `cpos` lands at 7. Exact match to hand-derived expectation.

      **Bug 2: Ed's "only the bottom row changes" — a real,
      previously undiscovered parser gap, unrelated to scrollback
      entirely.** Traced `render()`'s escape-sequence state machine
      for the first time end-to-end for this specific complaint
      (rather than reasoning about it from documentation) and found
      it directly: the `cesc = 1` state (the byte immediately after
      a bare ESC) only recognizes `[` (CSI) and `]` (OSC) — EVERY
      other byte, including the classic VT100 single-character
      Index (`ESC D`, scroll down one line at the bottom margin)
      and Reverse Index (`ESC M`, scroll up one line at the top
      margin), was being silently dropped, `cesc` reset to 0,
      nothing else happens. A full-screen editor scrolling its
      viewport by ONE line via a bare `ESC D`/`ESC M` (rather than
      clearing and repainting the whole screen, or using the
      heavier CSI L/M this handler already supports) would have
      that scroll command eaten entirely — then position its
      cursor and write the new line's text, which DOES show up,
      producing exactly "only the bottom row changes" while
      everything above it silently goes stale. This has nothing to
      do with the alternate-screen/scrollback work at all; it is a
      gap in the base escape parser that has presumably been there
      since Theme A, just never exercised by anything tested before
      (shell output doesn't emit bare Index/Reverse-Index; a
      full-screen document editor doing line-at-a-time scrolling
      is exactly the case that would).

      Fixed by adding `D`/`M`/`E` (Index/Reverse-Index/Next-Line)
      to the `cesc=1` dispatch: Index and Next-Line reuse the exact
      same cy-increment-then-`screenscroll()`-if-past-the-bottom
      logic `outnl()` already uses for ordinary LF-driven
      scrolling (Next-Line just also resets the column, matching
      CR+LF); Reverse Index reuses `inslines(1)` — already correct,
      already `ScrollRaster`-based, already model-synced — called
      at row 0 instead of at the cursor, since "insert one blank
      line and shift everything else down" is exactly what
      happens at the top margin. No new drawing code was written;
      both directions were solved by wiring the SAME already-
      proven primitives (`screenscroll`/`inslines`) to two bytes
      nothing had ever routed to them before.

      Verified via harness (same `escsbtest.e`): fed `ESC D` not at
      the bottom margin (cy increments, no scroll call) and at the
      bottom margin (scroll call fires, cy pins at rows-1); `ESC M`
      not at the top margin (cy decrements) and at the top margin
      (`inslines(1)` fires, cy stays 0); `ESC E` (cy increments,
      same as D); and three regression checks that `ESC [`/`ESC ]`
      still correctly start a CSI/OSC and `ESC` followed by an
      unrecognized byte still safely drops — all six matched
      exactly. The real `ScrollRaster`/pixel result still needs his
      eyes, same as every screen-facing change tonight.

      **On the More arrow-key question specifically**: left
      genuinely unresolved this beta. The Ed fix may incidentally
      help if More's own line-stepping ALSO relies on Index/Reverse
      Index internally (plausible, unconfirmed) — but the earlier
      claim that More's binary has no arrow-key awareness at all
      (from its help text and a `strings` pass) was too shallow a
      check to stand as a verdict, and won't be repeated as one.
      His b35 retest will show directly whether the Ed fix also
      moved this one.

      Deployed as "1.1b35", his boot test pending.

      **b36 — his b35 retest.** Search: confirmed working ("Search
      now works"), no further action. More: confirmed, in his own
      words, that arrow keys really don't page it — the b34 finding
      was right after all, just asserted with too little evidence
      at the time; now empirically settled by his own retest rather
      than a `strings` pass, closed for real.

      Ed's scroll bug is NOT fixed by the b35 ESC D/M/E change,
      and the failure mode he described is more specific than "no
      scroll happens": holding Down, only the BOTTOM row updates
      and everything above stays frozen; holding Up, only the TOP
      row updates and everything below stays frozen; Shift+Up/Down
      (page-at-a-time) redraws correctly. That symmetry doesn't
      match a simple "Index is being dropped" story — if it were
      just a dropped Index, cy would never reach the scroll trigger
      and nothing new would render at all, not just the one row. A
      third guess wasn't worth another beta of his anger if wrong
      again, so instead: added a genuinely temporary diagnostic
      (`dbgmark()`/`dbgring`, clearly labelled TEMPORARY at every
      touch point — the struct fields, the two call sites in
      `csidispatch()`/`render()`, and `settitle()`'s new rawmode
      branch) that records the last 16 escape/CSI final bytes
      Ed actually sends and shows them live in the window title
      as `[dbg:xxxxxxxxxxxxxxxx]` whenever `curcon.rawmode` is
      true. This is exactly the house rule from the FONT hunt and
      the More ?47h discovery: when a protocol question can be
      answered by instrumenting and reading the REAL bytes, do
      that instead of reasoning about it from outside. Ring math
      (oldest-to-newest reconstruction across the wrap point)
      verified via harness (`dbgringtest.e`) before deploying —
      fed it 18 marks into a 16-slot ring, got back exactly the
      expected last-16 sequence, byte for byte.

      His next boot: open Ed on a file long enough to scroll, hold
      Down for a few seconds, screenshot the title; do the same
      holding Up; do the same with Shift+Down as a control (the
      case that already works) for comparison. Whatever the title
      shows will have a name for the fix instead of a third guess.

      Separately noted, not yet investigated: "when opening ed I
      can see a glimpse of the prompt sticking down from the
      window border... ed should obviously open a new page." The
      cooked→raw `ACTION_SCREEN_MODE` transition (`eraseedit()` +
      `cursdraw()` only) never clears the whole window — only
      `altsave()`, triggered separately by the CLIENT's own CSI
      ?47h, snapshots anything, and `altsave()` itself is a pure
      MODEL copy with no visible repaint. So old cooked content can
      stay on screen, at least briefly, until Ed's own first writes
      cover it. Deliberately NOT touched yet: tying a screen clear
      to the raw-mode transition itself is exactly the design
      mistake already made and reverted once this session (the
      altscreen coupling that raced More's exit tidy-up, b10/b11)
      — inferring behaviour from a packet lifecycle event instead
      of what the client actually sends. Needs its own look, not a
      reflexive fix bundled into this beta.

      Deployed as "1.1b36" — a debug build, not a fix. His boot
      test is the diagnostic run, not a retest.

      **b37 — the b36 diagnostic was itself broken, AND he corrected
      a real misread.** His screenshot of Ed post-b36 showed a
      plain "CCON:" title, no `[dbg:...]` suffix at all — the ring
      (`dbgring`/`dbgn`) was filling correctly on every escape/CSI
      byte, but `dbgmark()` never actually called `settitle()`, so
      nothing ever pushed the ring into the real window title via
      `SetWindowTitles()`. A bug in the INSTRUMENTATION, not a clue
      about Ed — fixed by calling `settitle()` at the end of
      `dbgmark()` itself, refreshing the title live on every mark.

      Separately, and more importantly: his prior "of course it
      does not work paging up/down with the arrowkeys. How could I
      even expect that you would fix it?" was read as sarcastic
      AGREEMENT that More genuinely has no arrow-key paging (i.e.
      confirming the original b34 finding) — that was wrong. It was
      sarcasm about ME FAILING to fix it, not agreement that there
      was nothing to fix — confirmed emphatically the next message
      ("MORE IS NOT F*ING WORKING!!!!!!!!! AND NOT ED NEITHER!").
      `ccon-architecture.md`'s "closed for good" note from that
      misread needs correcting once More is actually investigated
      properly — `machine68k` (already used this session for the
      NP_Entry poke verification) is available for a real
      disassembly pass on `SYS:Utilities/More`, rather than the
      shallow `strings`/help-text check from b34 that started this
      whole misunderstanding. Not yet done as of this entry.

      Deployed as "1.1b37".

      **b38 — the dbgring paid for itself immediately.** With b37's
      title actually refreshing, his three screenshots gave a
      direct, unambiguous answer instead of another guess:

      - Holding Down in Ed: `[dbg:HHHHHSKHSKHSKHSK]` — a repeating
        H (CSI H, position) / S / K (CSI K, erase-to-EOL) cycle.
      - Shift+Down in Ed (the one that already worked):
        `[dbg:KHKHKHKHKHKHKHKH]` — K/H alternating, NO scroll
        command at all — it just repaints every visible line from
        scratch each time, which is exactly why it was never
        broken by anything in the parser.
      - More (page-back key): `[dbg:mmpHKmmmpqpHKmmm]` — mostly
        `m` (SGR, already handled) plus `H`/`K`, and two still-
        unrecognized finals (`p`, and `q` — `q` is actually already
        handled, DA/device-attributes report; `p` is not and is
        unexplained, noted for later, not chased this beta).

      The `S` in Ed's down-scroll ring is CSI **S** — SU, "Scroll
      Up" (ECMA-48/ANSI), parameterized, region-relative. This is
      NOT the same control as the bare `ESC D`/`ESC M` (IND/RI)
      b35 added — two genuinely different, both-real VT100 scroll
      mechanisms, and Ed uses the CSI-parameterized pair (`S`/`T`,
      SU/SD) for its plain-arrow line-at-a-time scrolling, not the
      bare-ESC pair. b35's fix was a real, correct fix for a real,
      separate gap — it just wasn't the one Ed's arrow-key path
      actually exercises, which explains why his retest showed
      literally no change from it.

      Fixed by implementing CSI S / CSI T in `csidispatch()`,
      calling new `scrollup(n)`/`scrolldown(n)` procs. Deliberately
      NOT built by reusing `inslines()`/`dellines()` directly: those
      are cursor-row-relative (correct for CSI L/M, which scroll
      from the CURSOR's row down — Insert/Delete Line is defined
      that way), but SU/SD scroll the WHOLE region regardless of
      where the cursor currently is. Since DECSTBM (scroll-region
      margins) still isn't implemented, "the whole region" is
      simply "the whole window," so `scrollup()`/`scrolldown()` are
      `dellines()`/`inslines()`'s exact `ScrollRaster`+model-shift
      shape, just anchored at row 0 always instead of `curcon.cy`.

      Verified via harness (`scrolltest.e`) before deploying: the
      model-shift math alone (skipping `ScrollRaster`, pixels vamos
      can't show) for `scrollup(1)`, `scrollup(2)`, `scrolldown(1)`,
      `scrolldown(2)` against a 5-row fake grid — all four matched
      hand-derived expected row contents exactly, including which
      rows end up cleared.

      The dbgring telemetry (b36/b37) stays live in this build —
      one more round to visually confirm the fix, and to keep
      watching in case Ed's up-arrow (Reverse case, presumably CSI
      T) or anything else still doesn't fully resolve. Strip it
      once he confirms clean.

      Deployed as "1.1b38". More's `strings`-based "not a bug" claim
      is STILL not properly re-verified (see the b37 entry above) —
      unrelated to this fix, not forgotten, next up.

      **b39 — Ed confirmed fixed ("thank god"), and a real
      disassembly of More at his explicit request** ("disassemble
      or disect or just mutilate more to find out how it works,
      maybe it can give us information that can be applied wider
      than just getting more to work").

      Tooling: `machine68k` (already used earlier this session for
      the NP_Entry poke verification) provides `CPU.disassemble_raw
      (pc, bytes)` — no full Amiga environment needed, just decode
      raw 68k bytes. Wrote a minimal AmigaOS hunk-file parser
      (`hunkparse.py`, HUNK_HEADER/CODE/DATA/BSS/RELOC32/RELOC16/
      SYMBOL/EXT/DEBUG/END, enough to extract hunk bodies — no
      relocation applied, unneeded for reading branch/compare logic
      against immediate values) to pull `SYS:Utilities/More`'s
      10148-byte CODE hunk out cleanly, then linearly disassembled
      the whole thing (`disasm.py`) to `more.dis`, one instruction
      per line with its file offset, for grepping.

      Found the actual keystroke loop by searching for dos.library
      `Read()` (LVO -$2A) call sites — 4 total, 3 were file I/O
      (a ~126-byte config read, a 4096-byte chunked read of the
      file being paged) and one real hit: `WaitForChar(fh, 200000)`
      (LVO -$CC) immediately followed by `Read(fh, buf, 1)` — a
      genuine one-byte-at-a-time keystroke reader, matching
      `ccon.doc`'s existing "More's single-key paging uses real
      timed WAIT_CHARs" note exactly.

      Traced the dispatch immediately after that single-byte read:
      byte `< $20` (control chars) falls through to "ignore, loop
      back and read the next byte" for anything not separately
      matched; byte `$20-$7e` (printable) is checked against digits
      (accumulating a repeat-count prefix, vi `5j`-style) and a
      small fixed table of command letters; byte `> $7e` — which
      covers DEL AND EVERY BYTE $80-$FF, meaning `$9B` (CSI)
      UNCONDITIONALLY — branches straight to the same "ignore, read
      next" path, no exceptions. There is no code anywhere in this
      dispatch that treats a byte as the start of a multi-byte
      escape sequence.

      **The actual, code-verified reason arrow keys don't work in
      More**: when CCON forwards an arrow key as `ESC [ A` (three
      bytes, `rawcsikey()`'s standard encoding), More's one-byte
      reader sees three completely independent, meaningless
      keystrokes — `ESC` swallowed as an unmatched control char,
      `[` and `A` each checked against the command-letter table and
      almost certainly matching nothing. This isn't a rejection of
      arrow keys specifically; More was simply never written with
      any concept of ANSI cursor sequences. True on any console,
      stock CON: included — settles the b34→b37 back-and-forth for
      real this time, with the actual mechanism proven from the
      compiled code rather than inferred from help text or an
      assertion in either direction.

      **The wider lesson he asked for**: Ed and More are NOT the
      same category of "raw client" despite both running through
      CCON's raw mode. Ed genuinely parses CSI sequences — proven
      twice now, via its output scrolling (`CSI S`/`T`, this
      session) and its menu system (CSI raw-event reports,
      disassembled earlier tonight). More does not; it's a single-
      byte reader from an earlier, simpler generation of Amiga CLI
      tooling. CCON speaking the ANSI protocol correctly (which it
      now does noticeably better after b35-b39) is the right and
      only correct design; whether a given CLIENT understands that
      protocol is entirely the client's own property, and no
      console-side cleverness can retrofit escape-sequence
      awareness into a binary that was never written to parse one.
      Filed as a settled architecture fact, not an open question.

      **Cleanup, same beta**: with Ed confirmed working, stripped
      the b36/b37 dbgring diagnostic entirely — the struct fields
      (`dbgn`/`dbgring`), `dbgmark()`, its two call sites in
      `csidispatch()`/`render()`, and `settitle()`'s temporary
      rawmode branch. `settitle()` is back to exactly its pre-b36
      shape. `ccon.doc`/`ccon.readme`'s Ed-scrolling line corrected
      from "Index/Reverse Index" (b35's guess, wrong mechanism) to
      "ANSI Scroll Up/Down" (the actual one, b38).

      Deployed as "1.1b39" — a normal build again, no debug
      scaffolding, nothing pending a boot test this round beyond
      ordinary confidence in what's already confirmed working.

      **b40 — the "settled" More verdict wasn't the whole story
      either.** His immediate next report: "I can't scroll up in
      more. If I press the up arrow it's the same page as is
      displayed that scrolls up, so I can scroll up for all
      eternity without going anywhere." Went back into `more.dis`
      (still on disk from b39) rather than re-guess from the b39
      summary, and found a SECOND dispatch path in the same
      keystroke loop that b39's trace missed: a state flag (tested
      right after `Read()`, before the byte-classification chain
      b39 documented) routes to an entirely separate block that
      DOES recognize `ESC` then `[` (or bare CSI `$9B` directly) as
      a sequence start, resetting several "position" registers to
      their CURRENT value rather than advancing them — a mechanism
      exactly consistent with "same page, going nowhere."

      Genuinely uncertain of the full picture this time (unlike the
      Ed CSI-S find, which was unambiguous once spotted) — the
      interaction between this path and the one b39 already traced
      needs more than hand-reading to pin down with confidence, and
      hand-tracing control flow has already burned this session
      once (see [[amigatools-workflow]]'s harness-over-hand-trace
      lesson). Live hypothesis: More may ALWAYS have sent something
      like this in response to arrow keys, harmlessly invisible
      before b38/b39 since CSI S/T were unimplemented no-ops — and
      only NOW visible, now that CCON actually acts on them (for
      Ed's benefit). If true, this isn't a new CCON regression, just
      a newly-exposed consequence of a real, correct fix.

      Rather than keep reading assembly, brought the b36-style
      dbgring back (title-bar `[dbg:...]`, CSI-final-byte-only this
      time — no need for the bare-ESC-D/M/E markers from the Ed
      hunt) to directly observe what More sends in response to
      arrow keys, same proven method as the Ed investigation.
      Waiting on his screenshots (Up a few times, Down a few times,
      Space/Backspace as a working-key control) before concluding
      anything definite.

      Deployed as "1.1b40" — diagnostic, not a fix.

      **b41 — the More arrow-key investigation, closed for real.**
      His screenshot (title `[dbg:mmpHKmmmpqpHKmmm]`, confirmed by
      him to be from pressing Up — a first read misjudged it as a
      repeat of the earlier "back a page" screenshot purely because
      the ring happened to look identical; he corrected that
      sharply and correctly, no second-guessing needed) settled the
      live hypothesis from the b40 entry: there is NO `S`/`T` in the
      ring anywhere. What IS there — `m`/`H`/`K` repeating — is
      the exact same shape as the ALREADY-CONFIRMED-WORKING page
      redraw (compare the b38 Shift+Down control ring:
      `KHKHKHKHKHKHKHKH`). So the b40 hypothesis (CCON's new CSI
      S/T support making a previously-invisible bad scroll command
      newly visible) is WRONG — ruled out cleanly by the absence of
      the very codes it depended on.

      What's actually happening, tying back to the b39/b40
      disassembly finds: pressing an arrow key in More triggers its
      ESC/CSI recognizer (the one found in b40 that resets internal
      "position" registers to their own current value instead of
      advancing them), and More then does a completely normal,
      correctly-functioning FULL PAGE REDRAW from that position —
      using the identical `H`/`K` mechanism as every other page
      redraw in this program. The redraw itself is not broken at
      all. It's just redrawing the position it was already at,
      because the arrow key confused which position that should be.
      This is 100% inside More's own compiled logic; CCON's role
      (parse and act on real CSI codes) is unrelated to this bug
      and there's nothing on the console side to change.

      Stripped the b40 dbgring immediately — same struct fields,
      `dbgmark()`, its one call site in `csidispatch()`, and
      `settitle()`'s temporary branch, all removed, `settitle()`
      back to its exact clean shape. Deployed as "1.1b41".

      **The More investigation is now closed, definitively, on
      three independently-confirmed facts** (not assertions): (1)
      its own keystroke loop reads one byte via `WaitForChar`+
      `Read(...,1)`; (2) it DOES have a real ESC/CSI recognizer,
      just one whose position-tracking gets reset rather than
      advanced by an arrow key; (3) the resulting "scroll" the user
      sees is a genuine, working full-page redraw landing on the
      wrong (unchanged) position — confirmed by the total absence
      of scroll commands in the observed byte trace. Nothing further
      to try here; this is a real, small bug in a ~2021-vintage
      Amiga utility binary, unrelated to and unfixable from CCON.

      **b42 — the b41 "closed for real" verdict was WRONG, and this
      time the proof was completely conclusive rather than another
      disassembly read.** He did the one test that actually settles
      an "is it the client or the console" question: same file,
      same version of More, run under STOCK CON: instead of CCON:.
      Two screenshots — Up arrow pressed a few times moved the
      percentage indicator from 99% down to 50%, with genuinely
      different file content on screen. More CAN navigate backward
      correctly on arrow keys. It just doesn't under CCON. Same
      binary, different console, different result — inescapably a
      CCON-side issue, not a bug inside More at all. The b41 "100%
      inside More's own compiled logic, unrelated to and unfixable
      from CCON" conclusion was flat wrong, and shouldn't have been
      written as settled without this exact kind of test having
      been run first.

      Found a concrete, well-justified candidate immediately:
      `rawcsikey()` (and `sendreport()`, the CSI-report responder)
      were both sending the CSI introducer as the bare 8-bit C1
      byte (`$9B`) for every special key — arrows, function keys,
      Help. Real AmigaOS raw-key reporting conventionally uses the
      two-byte 7-bit form (`ESC` `[`) instead, which is also far
      more universally understood by ANSI-aware programs in
      general. Switched both to `enqueue(27); enqueue("[")`.
      Deliberately did NOT touch `ihreport()` (the OTHER `$9B`-
      emitting proc) — that one's byte-for-byte ROM-disassembly-
      verified against the real console.device 46.1 event-report
      builder, a different protocol (Ed's CSI n{ raw-event
      subscription) with independently-confirmed-correct bytes;
      no reason to touch something already proven right.

      Genuinely uncertain whether this is the WHOLE fix or just A
      fix — the disassembly reading that led here (`more.dis`,
      still on disk) had already produced contradictory conclusions
      twice this stretch (b39's "no CSI recognition at all" wrong,
      b40's "CSI S/T" hypothesis wrong), so this change is offered
      as a concrete, justified, testable hypothesis based on the
      REAL discrepancy observed, not a re-asserted "this settles
      it." Deployed as "1.1b42" — needs his direct test: does Up/
      Down arrow now navigate correctly in More under CCON, and
      separately, does Ed's scrolling (already confirmed working,
      b38) still work with the encoding changed underneath it.

      **Confirmed, same beta: "Yes!!!!!!!!!!!!!!!!!!!!!!!!! Finally."**
      Up/Down arrow paging in More now works under CCON, ESC+'['
      was the actual fix, and Ed's scrolling survived the encoding
      change untouched. The b39-b42 More saga is genuinely closed
      this time, on real confirmed behavior, not another disassembly
      read. This also closes Theme B's arrow-key/scrolling thread
      entirely — see [[ccon-architecture]] for the full multi-round
      writeup and the process lesson it cost (stock CON: comparison
      should have run FIRST, not last).

      His immediate follow-up, a new and separate ask, not a bug:
      under stock CON:, More's page redraw appears to FLIP instantly
      to the new page; under CCON it visibly "scroll updates" row by
      row instead, which reads as more distracting. Assessed, not
      implemented: CCON draws every graphics op straight to the
      window as it parses it, no offscreen buffer, so a client's
      multi-row page redraw is genuinely progressive on screen;
      stock CON:'s hand-tuned ROM assembly likely just finishes
      within one screen refresh where CCON's higher-level per-row
      overhead (scrollback model bookkeeping included) can spread
      across a couple of frames, becoming visible. Two paths given
      to him: real fix (offscreen bitmap + one blit per redraw,
      genuine architecture change, touches every drawing call in
      the handler) vs. cheaper fix (trim per-row overhead, likely
      helps but doesn't GUARANTEE atomicity). His call on scope,
      not taken up yet — a real, separately-scoped ask, not folded
      into this beta.

      **b43 — two quick, independent asks, both cosmetic/geometry,
      both shipped same beta.** (1) Default window geometry changed
      from `40/40/520/160` to `0/18/640/130` — matches stock
      `newshell`'s own default CON: window exactly, his ask, so a
      bare `newshell ccon:` now looks and sits like the stock shell
      window rather than an arbitrary offset/size CCON picked on
      its own. Changed in both places that ground this default
      (the struct-init safety default and `parsecon()`'s real,
      actually-used default — kept in sync, matching the existing
      pattern where both blocks already mirrored each other).
      Side effect, not a coincidence to chase further: 640px width
      at topaz-8 works out to ~80 columns, which is what
      `ccon.doc`'s memory-footprint section already assumed as
      "the default" — the OLD 520px default was actually ~65
      columns, a small pre-existing doc/reality mismatch that this
      change happens to close rather than open.

      (2) The ~3px top-inset he screenshotted (CCON's prompt sits
      visibly lower than stock CON:'s, which starts flush against
      the border) — traced to `MARGIN=4` in `gridcalc()`, applied
      to BOTH `curcon.left` and `curcon.topy`. Changed to `MARGIN=0`.
      Low-risk: the borrowed-window path (`curcon.fwin`) already
      forces `i:=0` in the exact same calculation, so zero-margin
      was already live, exercised code, not new untested ground —
      this just makes it the default for ordinary windows too, not
      only borrowed ones. No doc numbers needed updating (the
      handbook never stated the old margin/geometry as specific
      pixel values, only described things generically).

      Deployed as "1.1b43", his boot test pending — pure visual/
      geometry changes, need his eyes on both: does the default
      window now match a stock `newshell` window's position/size
      and does the prompt sit flush at the top like CON:'s does.

      **b43 confirmed** ("the window and margin is now top notch").

      **b44 — the memory knob, his call.** Default `SBMAX` 1000 ->
      512 (a kinder default; 1000 was itself the 19.7.26 footprint-
      pass reduction from 1.0's 4000 hardcode — this continues that
      same direction rather than reversing it), `SBMAXCAP` (the
      `LINES=n` ceiling) 4000 -> 5000, room for beefier systems
      without removing the safety cap concept. `ccon.doc`/
      `ccon.readme` fully re-swept for every "1000"/"4000" mention
      (six spots across both files) plus the derived memory figure
      recalculated from the new default: `512 × 80 cols × 3 planes`
      = ~120K, replacing the old "~235K at 80 columns and the
      default 1000 lines" line everywhere it appeared.

      Deployed as "1.1b44". His instruction this round, explicit
      and in order: fix the scrollback default, THEN commit and
      push — double buffering (the More redraw-flicker ask from
      the previous entry) is next but deliberately not bundled
      into this commit.

      **b45 — mountlist consolidation, his observation.** Asked
      what CCON lacks vs CON:/ConMan/KingCON/ViNCEd; the "mount it
      AS CON:" parked item came up (see above), and he supplied the
      actual KingCON-mountlist file to show how the takeover really
      works (plain `Assign DISMOUNT` + `Mount FROM`, no handler
      code involved) — and pointed out in passing that KingCON's
      OWN mountlist is a SINGLE file with four device stanzas
      (`KCON:`/`KRAW:`/`CON:`/`RAW:`, all the same handler), while
      CCON was shipping the equivalent of `CCON:` and `CRAW:` as
      TWO separate files — "unnecessary." Real, correct observation:
      `Mount <device>: FROM <file>` selects just the named stanza
      out of a multi-entry mountlist, so nothing about AmigaDOS
      required the split. Consolidated `CRAW-mountlist` into
      `CCON-mountlist` as a second stanza (`Startup = "RAW"` on the
      `CRAW:` entry, unchanged from before) and deleted the now-
      redundant file. Swept every reference: `ccon.doc`,
      `ccon.readme`, `README.md` (install steps and FILES listings
      in all three), plus the one comment in `ccon-handler.e` that
      named `CRAW-mountlist` specifically. `Mount CCON: FROM
      DEVS:CCON-mountlist` / `Mount CRAW: FROM DEVS:CCON-mountlist`
      — same file, different device argument, matching exactly how
      KingCON's own install recipe uses its one file four times.
      No handler-behavior change; recompiled/redeployed anyway to
      keep the deployed binary's source comments in sync with the
      repo. Deployed as "1.1b45".

      **The "mount it AS CON:" item, actually tested, same day.**
      Added `CON:`/`RAW:` stanzas to the same `CCON-mountlist`
      (clearly marked EXPERIMENTAL in its header comment) so he
      could try the real takeover recipe: `Assign CON:/RAW:
      DISMOUNT` then `Mount CON:/RAW: FROM DEVS:CCON-mountlist`.
      Checked the source first for anything hardcoded to the literal
      device name `CCON:` that might misbehave: the V47 shell-probe
      answer (`id.disktype := $43434F4E`, "CCON") is DELIBERATELY
      never the literal `'CON\0'` regardless of what device name
      the handler is mounted under — it already works correctly as
      a CON: replacement with zero code changes, that was the whole
      point of the existing design. Two purely cosmetic loose ends,
      not blockers: the input.device interrupt node's debug label
      and the default window title both still say "CCON:" even
      when serving as CON:. Tested interactively first (typed at an
      already-open shell, not baked into `S:User-Startup` yet, so
      an existing shell stays on stock CON: as a recovery path if
      anything went sideways) — **his result: "Yes it works."** He
      then added it to his own `S:User-Startup` himself, same
      pattern as the CRAW: line earlier. First real, working proof
      that CCON can replace the system console, not just theory.

      **b46 — a real bug in the -1/-1 fill-screen feature, caught
      immediately by actually using the takeover.** His report:
      `newshell ccon:0/11/-1/-1` opened a window covering the WHOLE
      screen, ignoring the `0/11` position — he wanted it to fill
      only what's LEFT of the screen from that X/Y, not the raw
      screen dimensions regardless of where the window starts.
      Real bug, not a misunderstanding: `openwin()`'s -1 resolution
      (`curcon.pww := pubscr.width`) never subtracted `curcon.pwx`,
      so a window at a nonzero X/Y with -1 width ran that many
      pixels past the screen's right edge; same for Y/height.
      Fixed: `pubscr.width - curcon.pwx` / `pubscr.height -
      curcon.pwy`. Verified via harness (`fillscreentest.e`)
      before deploying: his exact case (0/11/-1/-1 on a 720×480
      screen) now lands the far edge EXACTLY on the screen edge
      (720, 480); an offset-both-axes case; the original 0/0/-1/-1
      case confirmed unaffected; the existing 160×60 floor clamp
      still catches a degenerate near-edge offset; and explicit
      (non-`-1`) width/height confirmed untouched by the change —
      five for five. `ccon.doc`'s geometry section corrected to
      describe "fills the REST of the screen, measured from X/Y"
      instead of the old, now-wrong "fills the screen" wording, with
      his exact `0/11/-1/-1` case added as a worked example. Deployed
      as "1.1b46".

### 1.2b1 — the window-bounds report spoke the wrong CSI (20.7.26)

First v1.2 beta. A phantom `1: Unknown command` turned up after every
`ls` under CCON — and only CCON, never ViNCEd, never stock CON:. It
shrugged off the first repro attempts (not after warm reboots, not
after a cold boot) until the pattern sharpened: it fired on the command
right after an `ls`, every time. His call: "ls is leaving garbage
behind."

Root cause was in CCON, not ls. `ls` sizes its columns the way stock
`C:Dir` does — write the window-bounds request `CSI 0 SP q`, read back
`CSI 1;1;rows;cols SP r` on the input stream. `sendreport()` was
introducing that report with the 7-bit `ESC [` two-byte form — the
raw-KEY convention from b42 (correct for More's arrows) — instead of
the 8-bit CSI `$9B` that console-to-client reports use, the way
`ihreport` already does and what `C:Dir`/`ls` scan for. `ls` looks for
`$9B`; it got `ESC` (ignored), then `[` ($5B), and since `$5B >= $40`
its parser treats that as the report's final byte — so it stopped after
two bytes and the real payload `1;1;rows;cols r` was left sitting in the
input queue, read as the next line: command `1`, unknown. ViNCEd works
because it sends the standard `$9B`.

The same bug also meant `ls` never actually read CCON's width — it
bailed before the params, so every `ls` under CCON silently fell back
to its 77-column default.

- **CCON:** `sendreport()` now emits `enqueue($9B)`, with a comment
  pinning down why it must be `$9B` and not `ESC[` here, so it doesn't
  get swept back into the b42 raw-key convention.
- **ls:** hardened in parallel to accept either introducer (`$9B` or
  `ESC[`), so it reads any console's report through to the terminator
  and this class of leak can't recur. Bumped 0.1 to 0.2.

His FS-UAE boot test confirmed all of it: no phantom command after any
`ls`, `mkdir -p test/test2` and `cp` run clean, and — the case vamos
can't reach, since it doesn't emulate `SameLock()` — `cp -f info info`
correctly answers "source and target are the same file" on real
hardware. Deployed as 1.2b1.

### 1.2b2 — a code audit, and its first batch (21.7.26)

A full read of `ccon-handler.e` (all 5549 lines) looking for flaws,
leaks, races and performance, written up as `audit.md` with a working
order in `audit-fix-roadmap.md`. Sixteen findings: six bugs (B1–B6),
five performance items (P1–P5), five hardening items (H1–H5). Nothing
was boot-verified at audit time — it is a static read, and both
documents say so, because a finding argued from the source is not the
same thing as a finding observed on the machine.

The two worth naming here, both still open:

- **B1 — `eraseedit()`'s early returns skip the `edlast`/`edext`
  reset.** The b9 note above is explicit that the reset exists so "the
  tail never re-cleans at a moved anchor (the theft pattern must not
  come back through the back door)" — and the `ancx >= cols` guard,
  added later for the inverted-RectFill problem, is that back door. A
  write ending exactly at the right margin leaves `cx = cols` (the
  pending-wrap state), `reanchor()` parks `ancx = cols`, the next
  `eraseedit()` bails with `edlast` still holding the old anchor's
  count, and `drawedit()` then zeroes `oldl - l` model cells measured
  from the NEW anchor. Reasoned, not yet reproduced — batch 2 states
  the repro (full-width line, then drag-select the row and check what
  the clipboard actually got; the model is what selection copies, so
  selection is the honest test, not the glass).
- **B2 — `sbcnt` is not re-clamped when a resize GROWS the grid.** The
  ring invariant is `sbcnt <= sbmax - rows`; `screenscroll()` enforces
  it on the way up, nothing re-establishes it when `gridcalc()`
  increases `rows` underneath it. Fill the scrollback, enlarge the
  window, scroll to the far end: stale rows.

**Batch 1 landed here** — the mechanical, no-behaviour-change items,
grouped so one boot test covers all six:

- **P1:** `render()`'s printable-run loop was calling `curattr()` —
  which calls `fgpen()` — once per CELL to fill the attr plane. A
  nested call per character on the hottest loop in the file; 80 of
  them for a full-width line. Nothing in a run can move the SGR state
  (`outnl()` scrolls, it does not recolour), so it is one evaluation
  now, hoisted with `cursty` beside it.
- **P2:** `INQMAX` is 2048 — a power of two — but `enqueue()`,
  `inavail()` and `satisfyreads()` were all doing `Mod(…, INQMAX)`, a
  DIVS per call, with `inavail()` sitting in a loop condition. Now
  `AND (INQMAX - 1)`: the same idiom the input-event ring already used
  (`ihring + Shl(n AND (IHMAX - 1), 5)`), it had just never reached the
  byte queue.
- **P4:** `drawmrow`, `drawselrow` and `drawmodelcells` take `curcon`
  and the fields they read per cell (`rp`, `cols`, `left`, `cw`,
  `deffg`, the row's pixel Y) through locals. E reloads the global and
  then the field on every `curcon.x` reference and cannot hoist that
  itself, and these are the procs a full redraw calls once per row.
  The row offset `idx * cols` was also being multiplied three times
  for the three planes — one Mul now — and `drawselrow` was resolving
  `selvidx(r)` three times for the same `r`, once per plane.
  `render()` was deliberately LEFT alone beyond P1: it calls out to
  `outnl`/`outchr`/`csidispatch`, so a wholesale caching pass there is
  a much larger diff to review for a much smaller win than the three
  pure paint procs, where the per-cell cost actually lives.
- **H1:** `loadhistfile()`/`savehistfile()` each declared a local
  `port` shadowing the GLOBAL `port` — our `pr_MsgPort`, the one
  clients send to. It worked (`fscall()` resolves the global in its own
  scope for its self-deadlock guard), but it was a loaded gun in the
  two procs where "our port" instead of "the filesystem's port" hangs
  the machine. Renamed `fsp`.
- **H2:** `WCMAX=8` for the WAIT_CHAR queue depth, which was a bare
  literal at the `wcn >=` test while every other queue had a named
  const. The OBJECT array still spells `8` literally, like `inq`/`rdq`/
  `wq` do — E wants a literal there; the const is for the code.
- **H5:** `ihdrop` annotated as deliberately write-only — a
  post-mortem field for a debugger or a telemetry build, not dead code
  someone should "tidy up".

Compiled clean (LARGE). The warning set is byte-identical to the
baseline build — the same three known A4/A5 inline-asm warnings, and an
UNREFERENCED list naming the same symbols (`vers`, `domenupick`'s five
stub params, `dopkt`'s `c`/`len`, the parked `tcscancmd`) with only the
line numbers moved, which is the check that says none of the new locals
are dangling. **Binary 73072 → 72728, 344 bytes smaller**: pulling a
call out of a per-character loop, folding the Muls and swapping
Mod/Div for AND all cut code as well as cycles.

His FS-UAE boot test passed: shell, `list SYS:` colours and wrapping,
scrollback paging, and the drag-select round trip — the last one being
the case that matters most here, since `drawselrow` is the only proc
that exercises the `selvidx` fold and selection copies from the MODEL,
not the glass. Deployed as 1.2b2.

One thing the deploy turned up, worth recording so it isn't
re-discovered: the binary sitting in `L/` was stamped **1.1b46**, not
1.2b1 — same 73072 bytes, differing from the committed build in exactly
28 contiguous bytes, all of them the `$VER` string. The code was
identical; the copy into `L/` had been taken from the build just before
the version bump. Harmless (the b42/`$9B` fix was present either way),
but it means "what version is deployed" cannot be read off the file
size, and the old binary is kept as `L/ccon-handler.bak` as the revert
point for this batch.

### 1.2b3 — audit batch 2: the theft pattern's back door (21.7.26)

B1 from the audit, and the first finding that went the whole route:
reasoned from source, proven in a harness, then proven again on real
hardware with an A/B pair. Both later steps changed the answer, which
is the argument for doing it this way.

**The bug.** `eraseedit()` cleared `edlast`/`edext` at the BOTTOM of
the proc, so its two early returns — `win = NIL`, and the
`ancx >= cols` guard added later for the inverted-RectFill problem —
skipped the clear. The b9 note says that clear exists so "the tail
never re-cleans at a moved anchor (the theft pattern must not come
back through the back door)"; the `ancx >= cols` guard *was* the back
door. Leave `edlast` set, let the anchor move, and `drawedit()`'s
`oldl > l` loop zeroes that many model cells measured from the NEW
anchor — client text, not editor text.

**What the harness changed.** `edanchortest.e` (throwaway, the
`fillscreentest.e`/`sbsearchtest.e` pattern: fake 10-row ring, the
anchor/extent logic transcribed, every pixel call dropped since
`drawmodelrow`/`drawmodelcells` read the model and never write it).
Two things came out of it that reading the source had not:

- The audit's trigger description was **too broad**. It claimed any
  output whose last line is exactly `cols` wide qualifies. Scenario B
  disproved that: an identical cols-wide write does nothing when the
  row the anchor lands on is blank. The real precondition is four
  things at once — margin-flush write, non-empty edit line, the line
  shrinking in the same `drawedit` that sees the moved anchor (which
  means the Enter-commit path specifically, since a plain write never
  touches `ebuf`), and content on the row the anchor lands on. So it
  needs content BELOW the prompt: `CSI H` positioning, a full-screen
  client's restored transcript, a prompt mid-screen. Not the everyday
  bottom-of-screen case.
- It caught a **wrong first draft of the fix**. "Just zero the fields
  at the top" would have skipped the erase on the normal path, because
  the erase loop reads the count. Scenario C was added to guard that
  and immediately earned its place. The shipped fix takes the extent
  into locals (`n`, `ext`) and clears the fields above both guards.

**What the A/B changed.** With only the fixed binary deployed, a clean
screen would have been ambiguous — "the fix works" and "the repro never
fired" look identical, and the first hardware run did come back clean.
So a second binary was built differing ONLY in this proc plus the
version string (source diff verified before compiling). Result:
`1.2b3-BROKEN-B1` punches a hole in the row directly below the echoed
command, exactly as wide as the typed line; `1.2b3` leaves that row
intact; everything else in the two screenshots is identical. B1 is a
real observable bug, not a latent-correctness tidy-up.

**H4, and a correction to the audit.** The audit offered "add the
guard to `drawedit`, or a comment saying why it isn't needed". That was
a false choice — the guard would have been **wrong**. `ancx = cols` is
the legal pending-wrap anchor and the editor still has to paint there;
a guard would have made the typed line invisible until the next write
moved the anchor. Hardware confirms typing renders normally at the
margin-parked prompt. `drawedit` now carries a comment explaining why
the asymmetry with `eraseedit` is correct: eraseedit's guard is about
an inverted RectFill, a pixel concern `drawedit` does not have.

**Regression:** `ccon-bisect` five for five, `ccon-progress` and
`ccon-ichdch` clean — the b8 theft-pattern gates, i.e. the direct gate
on this code path.

**New test scripts** in `S/`, house style (`Type` a byte file / a short
`Execute` script): `ccon-b1` fills the screen and sets an invisible
prompt that is only `CSI 7;999H` — csidispatch clamps the column to
`cols`, so it parks the anchor exactly on the right margin at ANY
window width without counting characters. `ccon-b1-fill` is the screen,
`ccon-b1-off` restores the prompt. Deployed as 1.2b3.

### Parked for v1.2 — the big swing

**Current standing (22.7.26, his priorities):** the whole audit2
campaign is done — findings closed, see `audit2.md`/`audit2-roadmap.md`;
live handler is 1.2b17. Of the four big-swing items below:
1. **Mount as CON:/RAW: — effectively DONE.** Proven in EXTENDED real
   use: he has run it as his system CON:/RAW: for a long time now with
   no issues. Core mechanism + running-as-system-console are battle-
   tested; only cosmetic polish remains (see the item).
2. **Double buffering — the PRIORITY.** His call: this is the one of
   the parked features that matters most for v1.2.
3. **ICONIFY — low priority.** "Nice to have, not very prioritized."
4. **DECSTBM — parked, no observed need** (no tested client sets margins).
Also still open from the FIRST audit: **B8** (raw-mode/Ed resize; root-
caused, fix reverted — see `audit.md`). And **P6** (fscall timeout)
documented with the real fix parked (`audit2.md` D).

- [x] **Mount it AS CON: (and RAW:) — proven in extended use, polish
      only remains (22.7.26).** He has run CCON mounted as the system
      CON:/RAW: for a long time now with no issues, so the blast-radius
      risk ("every console the OS opens") is retired in practice. What's
      left is now essentially just one deliberate design point. **The
      "CCON:" labels ARE fixed (1.2b18):** the input-handler node name
      (`ihis.ln.name`) and the default window title (`wtitlebase`) now
      read the REAL mounted device name from `dol_Name` at startup - a
      new `devname` global, filled from the DeviceNode's BSTR the same
      BPTR-then-`Shl(,2)` way the `rawdef` Startup read already uses,
      falling back to `CCON` defensively. So an untitled window under a
      `CON:` mount now titles "CON:", not "CCON:", and the input handler
      lists under its real name. A normal `CCON:` mount is byte-for-byte
      unchanged (`dol_Name` = "CCON"). That also retires the "`dn_Startup`
      naming so one binary knows which name it was mounted under" item -
      `devname` IS that knowledge. What remains is ONLY the probe-answer
      choice, and it is arguably a non-item: CCON always answers `'CCON'`
      to the V47 shell probe, which is DELIBERATE - it is exactly what
      hands the shell's line editing to us, the whole point of the
      takeover - so "correct as-is" is the honest read. The original
      write-up follows.

      The KingCON crown: every console window in the system becomes a
      CCON window. Own
      release, own test ladder — the blast radius changes from
      "windows you asked for" to "every console the OS opens"
      (Startup-Sequence output, requesters' CON: opens, EndCLI,
      shells started before user-startup...).

      **The mechanism itself, confirmed (his own knowledge of how
      KingCON does it, 19.7.26d) — no OS-level magic, plain
      AmigaDOS device management:**
      ```
      Assign CON: DISMOUNT
      Assign RAW: DISMOUNT
      Mount CON: FROM Devs:KingCON-mountlist
      Mount RAW: FROM Devs:KingCON-mountlist
      ```
      Dismount the stock device names, then Mount the SAME handler
      binary back under those names via a mountlist — exactly the
      shape CCON already ships (`DEVS/CCON-mountlist`, one file,
      `CCON:`/`CRAW:` stanzas — consolidated from two separate
      files into this single-file shape the same day, matching
      KingCON's own mountlist exactly once he pasted it and pointed
      out CCON's two-file version was unnecessary), just pointed at
      `CON:`/`RAW:` stanzas instead of `CCON:`/`CRAW:`. This
      meaningfully de-risks the item: the "become the
      system console" part needs no handler code at all, only a
      Startup-Sequence recipe and a mountlist — the remaining open
      questions are entirely about the HANDLER's own behavior once
      mounted under the stock names, not the mounting mechanism:
      keep answering 'CCON' to the V47 shell probe (OUR editor owns
      every prompt — the point) vs a per-mount startup arg that
      changes the probe answer; whether anything hardcodes CON:
      quirks CCON lacks (ICH/DCH and soft styles from Theme A are
      prerequisites, already shipped); `dn_Startup` naming so one
      binary carries CON:/RAW:/CCON:/CRAW: cleanly and knows which
      name it was mounted under.

- [ ] **ICONIFY — low priority (his call, 22.7.26): nice to have, not
      prioritized.** Stock CON:'s option, not implemented (`ccon.doc`
      LIMITATIONS has said so since Theme A). A gadget on the
      window that collapses it to a Workbench AppIcon and restores
      it on a click. Real, multi-part work, not a quick fix: needs
      an actual icon image asset; `AddAppIcon()`/`RemoveAppIcon()`
      from icon.library, which is DOS-touching and so needs the
      same helper-process escape already built for disk-loaded
      FONT (no-DOS rule); a new message class in the main Wait()/
      GetMsg() loop to catch AppIcon clicks (a separate port, not
      IDCMP); and a real design decision on what "iconified" means
      for a window whose entire state lives in `curcon` — hide-and-
      restore the actual window, or fully close it and reopen
      against the same model. Asked about 19.7.26d, deliberately
      not scoped further yet — "note it down for later," his words.

- [x] **Double buffering SHIPPED, and the More complaint SOLVED - but by
      a DIFFERENT fix than expected (1.2b23, 22.7.26). "he loves it".**
      Double buffering is in (1.2b21-b23): a SHARED offscreen back-buffer,
      client output accumulates in it and blits once per packet drain
      (`bufopen`/`bufflush`/`bufensure`, `bbactive`; `curcon.rp` funnels
      all drawing so the draw code was untouched). It makes multi-row
      writes atomic and fixed a black trail. BUT it did NOT fix More
      paging, because the More complaint was never a buffering problem:
      **More sends `^L` (form feed, byte 12) before every page to clear
      the screen, and `render()` never handled byte 12** - so More's page
      appended and SCROLLED instead of replacing. CON:/console.device
      clear on FF; `list` sends no `^L`, which is why `list` always
      scrolled right. Found by CAPTURING More's actual output bytes (the
      trace also showed `WFWFWF` - More round-trips one write per line, so
      no drain-batching could ever catch a page). Fixed in b23: `render()`
      treats `^L` as clear-screen + home. More now page-replaces like
      CON:. The double buffering stays (it earns its keep on multi-row
      writes), but the STAR was the one-byte form-feed fix - the "read
      what the client actually sends" habit again.
      **THEN made TRULY instant (1.2b24-b25): the `^L` page batches.** A
      `^L` marks the buffer a HELD page (`bbpage`); its flush waits past
      the per-drain point until the client's blocking READ, so a page More
      sends as many round-tripped line-writes shows in ONE blit - matching
      CON:/ViNCEd. `list` never sends `^L`, untouched. Two causes found
      via the "slow on WB, instant on my CTerm screen" clue + a B/L/F
      trace: (1) the READ trigger fired on More's MID-page CSI-report
      reads - fixed to flush only when the read will BLOCK (empty queue =
      page done); (2) the FIRST page's `CSI 6n` (cursor-pos request) was
      unanswered, so that read hit an empty queue and flushed early -
      added a Cursor Position Report responder (`sendcpr`). All pages
      instant on WB, boot-confirmed ("all pages draw instantly now!").
      Original write-up follows.

      The original scope question (kept for the record):
      (or a cheaper partial fix) for screen
      redraws. His observation: under stock CON:, a full-page
      client redraw (More paging) flips to the new page instantly;
      under CCON the same redraw is visibly progressive, "scroll
      updates" row by row, more distracting. Root cause: CCON draws
      every graphics op straight to the window's rastport as it
      parses each one, no offscreen buffer — a multi-row redraw is
      genuinely progressive on screen. Stock CON:'s hand-tuned ROM
      assembly likely just finishes within one screen refresh where
      CCON's higher-level per-row overhead (scrollback model
      bookkeeping included) can spread across a couple of frames.
      Two paths, given to him, not chosen yet: the real fix (an
      offscreen bitmap + one blit per redraw — guarantees atomicity,
      but touches every drawing call in the handler, a genuine
      architecture change) vs. the cheaper fix (trim per-row
      overhead so redraws usually finish within one frame — lower
      risk, but doesn't GUARANTEE the sweep never shows). Asked
      19.7.26d, his call on scope still open.

      **RECOMMENDED APPROACH (22.7.26 analysis, grounded in the code):**
      an offscreen BitMap that `curcon.rp` draws into, blitted to the
      window on flush. It is the SAFE choice precisely because every draw
      already funnels through `curcon.rp` (111 refs; ZERO `Move`/`Text`/
      `RectFill`/`ScrollRaster` bypass it - checked), and `openwin` sets
      `curcon.rp := curcon.win.rport`. So the todo "touches every drawing
      call" worry is wrong - the change is three small pieces, drawing
      code UNTOUCHED: (1) alloc an offscreen bitmap + RastPort by the
      window; (2) point `curcon.rp` at it; (3) add one `flush()` =
      `BltBitMapRastPort` offscreen -> `win.rport`. Flush per render (end
      of each WRITE's render): a More page arriving as a burst renders
      offscreen and lands in ONE blit - the atomic flip CON: shows.
      `ScrollRaster` still works (scrolls offscreen, then blit). Degrade
      like the ring does: alloc-fail -> `curcon.rp = win.rport`, no
      flush. Realloc on `doresize`. Stage it (B7 discipline): prove an
      offscreen-draw-then-blit round-trips PIXEL-IDENTICAL, then wire
      flush points one at a time, boot-test More paging.

      **Memory - shared vs per-window (his question, 22.7.26): START
      SHARED.** One screen-sized back-buffer, flushed per render. Two
      windows with two More instances is NOT a problem for it: CCON is a
      single process handling ONE packet at a time, so the two Mores'
      output is serialised - render More-A's WRITE and blit it to window
      A, THEN render More-B's WRITE and blit it to window B; the two
      renders never overlap, so the shared scratch cannot cross-
      contaminate no matter how many windows. Per-window buffers buy only
      one thing - batching a page split across several WRITEs (flush at
      the loop's settle point instead of per-render) - a fringe gain that
      costs ~60-80KB PER window. Switching shared->per-window later is
      cheap: only the flush TRIGGER changes (per-render -> settle-point),
      the drawing code does not move at all (still all through
      `curcon.rp`). So shared first, upgrade only if a real split-page
      case is ever seen.

- [ ] **DECSTBM (scroll-region margins).** Never implemented, and
      until now never even written down as a to-do — it was a
      passing comment (`ccon-handler.e`, `scrollup()`/`scrolldown()`:
      "we don't track DECSTBM margins") from the Ed/More CSI-S/T
      investigation (b38), promoted to a real tracked item
      20.7.26. Right now every scroll operation (`CSI L`/`M` insert/
      delete line, `CSI S`/`T` scroll up/down, bare `ESC D`/`M`
      index/reverse-index) treats the WHOLE window as the scrolling
      region — `CSI L`/`M` are cursor-row-relative (correct per
      spec), but `S`/`T`/bare-ESC always act on the full window
      regardless of any margin a client might have asked for. A
      client that sets a top/bottom margin (e.g. to keep a status
      line pinned while scrolling only the body) and then scrolls
      would get the WHOLE window scrolled, status line included -
      wrong, though not yet observed against a real client that
      actually sets margins (neither Ed nor More do, as far as
      anything this session's disassembly work found). Would need:
      recognizing `CSI top;bottom r` (DECSTBM) to set/clear a
      per-console margin pair, then threading that pair through
      `scrollup()`/`scrolldown()`/`inslines()`/`dellines()` (and
      probably `outnl()`/`screenscroll()`'s bottom-margin check) so
      "the whole window" becomes "the current margin, defaulting to
      the whole window when none is set." Not scoped further yet.

## 1.2.2 — the speed campaign, S2+S3 (23.7.26)

Background: his three-console conbench run (results in S:) put CCON at
11.6x stock CON: overall and 203s on scroll-nl. srbench (S4, C:srbench)
pinned the physics: ScrollRaster ~34.7ms whether it moves 1 line or 10,
text-78 1.3ms, rectfill 23.4ms — blit COUNT is the whole game. (Full
analysis in the perf notes outside the repo, his call.) The conbench
windows were 77 cols (size gadget eats the right border), so its 78-char
lines wrapped: every "line" was TWO scrolls. The handler was otherwise
exonerated — ~1.5ms/write of editor tax, everything else was scroll
count times 34.7ms.

$VER 1.2.2b1, deployed live + staged (L:ccon-handler-1.2.2b1,
.bak = 1.2.1). THE deferred-blit engine (df* procs, ccon-handler.e):
inside one render() the sequential paths (printables, LF, TAB, FF,
ESC D/E) write the MODEL only; dfflush() at packet end (or before any
pixel-touching escape: CSI J/K/L/M/S/T/@/P, ?47 alt screen, RI at top)
pays AT MOST one ScrollRaster + dirty-span repaints via drawmodelcells,
or NO blit + redraw() when a screenful+ scrolled by or a FF cleared the
page (the FF RectFill is gone entirely, not deferred). sb=NIL or
rows>256 consoles run the 1.2.1 path bit for bit. Write replies still
land AFTER pixels — S5 (ack-then-render) deliberately NOT taken.

Harness: tests/defertest.e (vamos) — legacy and deferred engines
reimplemented over cell grids, screens+models+cursors+wrap flags+ring
compared after every packet. PASS: 10 directed + 4000 seeded-random
packets identical. (Harness lesson re-learned: Mod is a DIVS — a
24-bit dividend overflows the 16-bit quotient and rnd(39) returned
156, the fill loop trampled the globals. Two "failure" runs were the
harness corrupting itself; the engine never was wrong.)

Expected on the next conbench run (same 640x246 windows, honest
sync-off): scroll-nl 203s -> ~19s (one 31ms blit per 10-LF packet);
block-4k 27.3s -> well under 1s (dffull: zero blits, one 29-row
repaint per 4K packet — should now BEAT stock CON:'s 7.0s);
plain-lines 27.9s -> ~15s (the wrap's two scrolls merge into one
2-line blit); clear-page ~10s -> ~1s (no FF fill, one repaint pass
per page). bytewise/cursor-pos/erase-eol barely move — that is S1's
job, not started yet.

Boot checklist (REBOOT FIRST — the running handler keeps its seglist):

- [ ] plain boot: NewShell CCON: opens, types, completes, scrolls
- [ ] `type ccon.doc` full-speed — visibly faster, text intact at the
      end (spot-check the tail against a CON: type of the same file),
      no doubled or missing rows after the long scroll
- [ ] `dir SYS: ALL` or `list SYS:` — burst output correct, Ctrl+C
      still breaks it
- [ ] scroll-nl feel: `echo` a file of blank lines / rerun conbench —
      the 203s row collapses
- [ ] More a file: pages flip instantly (the 1.2 ^L+CSI-6n behaviour),
      page CONTENT complete on every flip (dffull path), q leaves a
      sane shell
- [ ] Ed the same file: arrows scroll (ESC D / CSI S paths — S flushes,
      D defers), insert/delete lines mid-screen, menus, resize while
      open (B8 regression watch), quit clean
- [ ] styles still: `echo "*e[3mit*e[0m *e[4mul*e[0m *e[7minv*e[0m"`,
      then Shift+Up into scrollback and back over it (deferred writes
      land attrs through the same model the view reads)
- [ ] select/copy during and after a long type — selection cleared by
      output as before, no stale highlight cells
- [ ] paste a multi-line clip into the shell — the paste hint row and
      edroom's immediate screenscroll still behave (they run OUTSIDE
      render, kept the old blit)
- [ ] iconify mid-`type`, reopen — transcript intact (writes park in
      the queue, flushwq replays through the new engine)
- [ ] resize after a deferred-heavy session — reflow (B7) intact: the
      wrap flags are written by dfnl/dfwrapnl now, same values, same
      rows
- [ ] a second CCON window: interleaved output in both, no cross-window
      smear (df state is global but settles inside every packet)
- [x] conbench rerun (his, 12:24, S:conbench-ccon-results2.txt):
      TOTAL 288.68 -> 54.00 (5.3x, now 2.2x stock vs 11.6x).
      plain-lines 14.44 (~predicted), scroll-nl 19.14 (~predicted),
      block-4k 0.36? = dffull zero-blit, 19x FASTER than stock CON:,
      wrap-long 2.56, clear-page 6.04 (prediction ~1s was wrong, the
      engine is right: 77-col wrap makes a page 40 rows, the last ~6
      lines per page each carry a 2-row scroll packet - re-derived
      within 6%). bytewise/cursor-pos/erase-eol/sgr unchanged BY
      DESIGN - S1 territory. The engine's numbers land on the model.

### 1.2.2b2 — S1, the blip-only eraseedit fast path (23.7.26)

Every cooked write brackets render() with eraseedit()/drawedit(), and
during command output the editor is EMPTY - yet eraseedit repainted
the whole anchor row (drawmodelrow, a full-width Text) to unpaint one
blip cell. That was ~1.6ms of the 1.85ms bytewise tax. Now: when the
last drawedit painted only the blip (edlast=0, edext<=1, srch off,
model present), repaint exactly the one normalized anchor cell via
drawmodelcells and return. All four guards are load-bearing (mirrored
text / ghost / banner / no-model each still take the full body - see
the comment block in eraseedit). Bookkeeping identical: edlast taken
at top as always (B1 rule), edext reset on the new exit.

Harnessed, not hand-traced (the b32 lesson): tests/ederasetest.e runs
OLD full-row eraseedit vs NEW fast path in lockstep over screen+model
grids - blip lifecycle, \r-parked anchors (b8), pending-wrap anchors,
banner, ghost, typed text - 9 directed + 3000 random cycles, pixel-
identical. The harness misfired twice before it ran true, BOTH times
its own fault (fed the engines different random bytes; flipped srch
before the erase, a state the handler can't reach - srexit/srcancel
verified in source to heal the banner themselves before any
eraseedit). Verified srch discipline is what makes the srch guard
sufficient.

Expected: bytewise 2.22 -> ~0.6s, cursor-pos 0.92 -> ~0.4, erase-eol
0.96 -> ~0.4, sgr-colour 7.36 -> ~5.5, More's keystroke echo snappier.
plain-lines/scroll-nl move little (blit-floor bound, S5 territory).

Boot checklist (REBOOT FIRST):

- [ ] plain boot, type at the prompt - blip follows, no stale blocks,
      no prompt damage (the B1/b10 regression watch)
- [ ] type a command, Left-arrow into the middle, type more, Enter -
      interior editing repaints right (n>0 path untouched, but this
      is the minefield's perimeter)
- [ ] Ctrl+R, type a fragment (banner replaces prompt), Ctrl+R again,
      Esc - banner in/out clean, prompt restored (srch guard)
- [ ] ghost suggestion: type a prefix of an old command - grey ghost
      shows; output arriving while it shows erases it clean (edext>1
      declines the fast path)
- [ ] a \r progress bar (ccon-b1-fill deck or `working: N%` loop) -
      blip parked over client text gives the cell back uninverted
      (the b8 shape, now via the 1-cell repaint)
- [ ] More a file - echo/keystroke feel, pages still instant
- [x] conbench rerun (his, 12:52, S:conbench-ccon-results3.txt):
      bytewise 2.22 -> 0.66 (predicted ~0.6; tax 1.85 -> 0.55ms/write,
      stock is ~0.35), cursor-pos 0.92 -> 0.22? (= stock's 0.20?),
      erase-eol 0.96 -> 0.52, sgr-colour 7.36 -> 4.96 (stock 4.70,
      6% off), clear-page 6.04 -> 5.56, small shavings everywhere
      else. TOTAL 47.16 - campaign to date 288.68 -> 47.16, 11.6x ->
      1.9x of stock. Remaining gap = plain-lines/scroll-nl/clear-page
      blit floor (S5 territory).

### 1.2.2b3 + b4 — S5, accept-then-render (23.7.26, his green light:
### "I'm confident that you will absolutely own this!")

The last lever. After S1-S3, the whole remaining gap to stock CON:
(47.16 vs 24.86) is one synchronous 31-34ms ScrollRaster per
line-bearing packet in plain-lines/scroll-nl/clear-page. And there is
no half measure available: DOS Write() BLOCKS its caller until the
reply, so a single-threaded client can never queue two writes - the
only way k lines reach one render pass is to reply BEFORE rendering.
That is what stock con-handler has always done; now CCON does too.

Mechanism: a per-console 4K write-behind buffer (console.wob).
dowrite copies the payload (client's buffer is only valid until the
reply), replies at once, and flushout() renders from OUR copy.
- b3 (WODEFER=FALSE): flush immediately after the reply. Semantics
  change, render pattern bit-identical to b2 - one packet per pass.
  Proves the ordering plumbing in isolation.
- b4 (WODEFER=TRUE): flush on a 20ms one-shot (second timerequest on
  tport, device cloned from treq), on buffer-full, or at any choke
  point. A burst pools 15-25 lines per flush -> ONE blit through the
  S3 engine for all of them. This is the payoff build.
Big writes (>4K) and wob=NIL consoles keep the b2 synchronous path.

The choke points (every path that must see settled output flushes
first; flushout is one compare when empty): ACTION_READ (More's
CSI-6n handshake: the flush parses the 6n and queues the report
before the read looks), WAIT_CHAR (conbench's SYNC probe stays
honest), SCREEN_MODE (bytes render under the mode they were written
in), END, dovanilla/dorawkey (transcript before keystroke),
selmouse (anchor math; during a drag writes park AND flushexpired
holds that console's bytes - the stock output-freeze, kept),
dopaste, doresize (reflow reads the model), doclosew, doiconify,
conclose. Screen and model always lag TOGETHER, so screen/model
coherence is untouched by construction; what moved is only when
pixels land relative to the reply.

Boot plan (two boots, the A/B ladder):
1) REBOOT into b3 (live now). Everything should look and feel
   EXACTLY like b2 - any difference is an ordering bug:
   - [ ] type/dir/list, More (pages+q), Ed (arrows/insert/resize/
         menus), Ctrl+C break mid-list
   - [ ] select/copy during output (freeze still holds), paste,
         iconify mid-type + restore, second window
   - [ ] conbench: expect roughly b2 numbers (maybe a hair better -
         client compute now overlaps render)
2) `Copy L:ccon-handler-1.2.2b4 L:ccon-handler`, REBOOT. Same
   checklist AGAIN, plus:
   - [ ] output latency feel: prompt/echo appear instantly (20ms is
         under perception); NO visible lag or stutter in Ed/More
   - [ ] conbench sync-off: plain-lines and scroll-nl should
         COLLAPSE (~2s each), clear-page ~1s, TOTAL somewhere near
         12-15s = FASTER THAN STOCK's 24.86
   - [ ] conbench WITH SYNC once on each of CCON/CON:/ViNCEd - the
         honest comparison now that all three defer (CCON's SYNC
         flush is real: WAIT_CHAR renders everything first)
Revert points: L:ccon-handler-1.2.2b3, .bak = b2.

**BOOT-GREEN BOTH RUNGS (his boots, 23.7.26 13:36 + 13:39, results4/5):**
b3 conbench 47.18 vs b2's 47.16 - statistically identical, plumbing
proven, More/Ed/Iconify/Ctrl+R all smooth. b4: TOTAL 2.42s sync-off -
10x FASTER than stock CON:'s 24.86 - plain-lines 0.56 (8 buffer-full
dffull flushes x ~38ms + round trips: the render is real, just
pooled), scroll-nl 0.10?, everything else '?'-fast. Same smooth
canaries. NOTE for any published claim: b4 sync-off carries the same
deferred-reply optimism as ViNCEd/stock always did (that was the
point) - the honest cross-console comparison is now a SYNC campaign,
still to be run. CAMPAIGN CLOSED: 288.68s (1.2.1) -> 2.42s sync-off /
render throughput at block-4k economics; S1+S2+S3+S5 all shipped,
committed after this green.

## 1.2.3 — plane-masked rendering (the sync-line hunt, 23.7.26)

The last measured gap to stock: one full-window ScrollRaster costs
~34ms against stock's ~17 per line under barriers. srbench 0.2 ruled
out every primitive theory (direct BltBitMap = 34.8, ScrollRasterBF =
35.2, no layer overhead exists); the 3.2 ROM's console.device 46.1,
split out with romtool and read with machine68k, gave up the real
trick at site $2592: it pokes a used-planes byte into rp_Mask before
its ONE ScrollRaster call, so the blitter skips planes the text never
touched. Maintenance at $3c00: pens OR'd, snapped to %0001/%0011/$FF,
floored via GetBitMapAttr(BMA_FLAGS) (BMF_STANDARD -> 1, else $FF =
RTG safety), reset on clear. Measured on our machine: 34.8 full /
17.4 mask-3 (= stock TO THE DECIMAL) / 8.8 mask-1.

1.2.3b1 (deployed live + staged, .bak = 1.2.2): the same trick, CCON
shape. Per-console mpens/mmask/mfloor; penuse() grows the mask in
setpens() and curattr() - the only two transcript pen sources (the
erase fills are pen 0) - BEFORE the first draw with any new pen;
gridcalc probes the floor (idempotent, resize/reopen-safe; mpens
deliberately survives - we have scrollback, stock does not, so
stock's clear-time reset is structurally wrong here: any ring row can
come back on screen). Applied as a bracket around render() ONLY -
which is overlay-free by construction (eraseedit/curserase run before
it), so the pen-8 ghost, the completion menu, the Ctrl+R banner and
the paste hint all draw AND erase at full depth: they can neither
pollute the mask nor leave plane droppings a masked blit would skip.
A bare transcript (pens 0-1) rides tier 1: every scroll, fill and
glyph in render at ~quarter blit cost.

Harness: tests/masktest.e - the invariant simulated at the plane
level (masked ops touch only masked planes, reference runs full
depth, recompose-and-compare after every op). Run 1 (rules kept):
clean over 4000 ops. Control A (grow-after-draw) and control B
(overlay left standing across a masked scroll - the ghost-droppings
shape, handler-position drifting with the text while the plane bits
stay) BOTH corrupt, proving the harness can see. PASS.

Boot checklist (REBOOT FIRST) - the risk surface is COLOURS, so look
at everything with colour-suspicious eyes:

- [ ] plain boot, type, dir, type ccon.doc - text correct, and
      noticeably snappier under sync-heavy shapes
- [ ] ls (colours!) - correct colours; then MORE plain output after -
      still correct (mask went wide and stays, = 1.2.2 behaviour)
- [ ] scrollback through the coloured history and back - colours
      intact in both directions (mpens never reset is what makes
      this safe - watch it prove itself)
- [ ] ghost suggestion over a busy screen - grey ghost renders,
      output erases it clean, NO grey droppings anywhere (the
      pen-8-outside-the-mask case, control B's real-world twin)
- [ ] Ctrl+R banner in/out; completion menu open/close over output
- [ ] More + Ed (Ed uses pens 2/3 - tier 3) - pages, arrows,
      insert/delete lines, resize, quit clean
- [ ] selection over coloured text, copy, paste back
- [ ] iconify mid-ls, restore - colours intact (mpens survives with
      the model)
- [ ] CTerm borrowed window - floor probe on ITS screen, all of the
      above briefly
- [ ] conbench CCON SYNC rerun - sync-line is the number: ~3.9s if
      the session touched pens 2-3, ~2.1s pure transcript (stock:
      3.40)

### 1.2.3b2 — narrowing + THE b1 bug (23.7.26, his sync run 16:11)

His b1 SYNC run proved the mask works (plain-lines 1.22 -> 0.32?,
rep-1 tier-1 blits) and exposed the design's cost in one table:
conbench's OWN sgr tests run before sync-line, the never-reset mask
went $FF, and sync-line sat unchanged at 6.70. An order artifact of
the benchmark - and the real limitation (one ls = wide forever).

Analysing that interaction found a REAL b1 bug: penuse grows mmask
mid-packet, but the render bracket had already loaded the OLD mask
into rp_Mask - so the FIRST coloured output after a plain session
drew with its planes masked off (wrong colours for one packet, self-
healing on the next repaint; the masktest sim missed it by modelling
one mask variable where the code has two).

b2 (deployed live + staged; .bak still = 1.2.2):
- maskcalc pushes mmask into rp_Mask whenever the bracket is open
  (maskon global) - mask changes reach the blitter the moment they
  are computed. The bug fix.
- NARROWING, rule (c): the mask may shrink only immediately after
  the whole visible region was repainted/cleared at the OLD mask.
  maskscan() (visible attrs + live SGR pens, ~2KB, microseconds)
  runs at: form feed (legacy = right after the fill; deferred = after
  dfflush's dffull redraw, via the dfnarrow flag), doresize (reflow
  can pull coloured HISTORY into view - scan goes BOTH directions),
  altrestore (widen BEFORE repainting the restored transcript),
  reopenwin. History rows do not bind the mask: scrollback repaints
  unmasked and snaplive full-redraws before any masked render.
- masktest extended: rule (c) ops in the kept-rules soak + control C
  (restore without rescan) + control D (narrow before the clear) -
  4000 ops clean, ALL FOUR controls corrupt as they must. PASS.

Boot checklist (REBOOT FIRST):
- [ ] FRESH window, ls IMMEDIATELY - colours correct from the very
      first line (the b1 bug's exact shape)
- [ ] ls, then More a file - page flips narrow the mask; paging feel
- [ ] ls, then clear, then dir - colours gone, speed back (narrow)
- [ ] resize wider after coloured output has scrolled up - the
      history that comes into view keeps its colours (control C's
      real-world twin)
- [ ] Ed: open on coloured transcript, quit - transcript colours
      intact (altrestore rescan)
- [ ] iconify a coloured window, restore - colours intact
- [ ] ghost/banner/menu over everything, as b1's list
- [ ] conbench SYNC rerun - per-test FFs now narrow between tests:
      sync-line should read ~2.1-2.5s (stock: 3.40) IN the standard
      run, no fresh window needed

## 1.2.4 — the 15/15 hunt (his call, 23.7.26 evening: beat both
## competitors in EVERY test; no asm, no file split - pure E)

Roadmap in the perf notes (outside repo). The stock-timing scoreboard
to beat: 10 rows lost, all reducing to (A) per-packet CPU cost at
14MHz and (B) the choke-flush conservatism for pixel escapes.

### 1.2.4b1 — E1: the eight escapes join the engine (23.7.26)

CSI K/J/@/P/L/M/S/T are model ops with dirty marks now. The old
procs' model code is UNTOUCHED - under dfon they just skip their
pixel op (ScrollRaster/RectFill/drawmrow) and mark the affected
rows/spans; dfflush repaints from the model with everything else the
packet did. The eight dfflush() calls in csidispatch are gone, plus
RI's top-margin flush. Legacy (sb=NIL) consoles keep immediate blits.
Consequences: no per-op blit, full S5 pooling for escape-heavy
streams, and ops that cancel inside a flush window (Ed's L+M pairs)
cost only the model moves - the same deferral dividend console.device
has always collected. The ?47 alt-screen switches KEEP their flush
(they swap the whole model; rare; correct).

Harness: defertest v2 - both engines grew the eight ops (same model
semantics, immediate screen mirror vs dirty marks) plus cursor-jump
ops whose coordinates are a pure function of the op byte (identical
across both replay loops - no RNG desync, the burst() lesson).
PASS: 10 directed + 4000 random packets, engines identical, first run.

Boot checklist (REBOOT FIRST) - the risk surface is the ESCAPE
CLIENTS, so Ed and More carry this one:

- [ ] Ed: open a file, arrows everywhere, PAGE up/down, insert and
      delete lines mid-screen, join/split lines, menus, resize,
      save+quit - the full workout; Ed is the L/M/S/@/P client
- [ ] Ed scroll feel: line-scroll (CSI S) latency - should feel THE
      SAME or snappier (ops pool ≤20ms; if it feels laggy, say so)
- [ ] More: pages, /search (uses erase ops), q - page content
      complete every flip
- [ ] shell: a \r progress bar with CSI K (erase-eol shape) renders
      clean; type during output
- [ ] ls colours + scrollback + everything from the 1.2.3 list once,
      quickly (mask interactions with the new deferred ops)
- [ ] conbench SYNC stock config: erase-eol / insdel-char /
      insdel-line / vt-frame are the rows E1 targets - expect all
      four to flip or near-flip
- [ ] conbench SYNC dev config once too (regression watch on the
      already-won rows)

### 1.2.4b2 — E2, the CPU diet (23.7.26, boot-green, his runs)

All five courses in one build: (a) generation-counter dirty flags
(one ++ invalidates every mark; the per-packet O(rows) clear+scan
loops are GONE, array swept once per 255 arms); (b) dirty lo/hi
bounds (dfscroll shifts and dfflush scans only live rows); (c)
blank runs are masked RectFills in drawmrow AND drawmodelcells, not
Text-ed spaces; (d) long attr/style mirror fills ride exec CopyMem
from prefilled run buffers (short runs keep the loop - sgr-perchar
must not pay 256-byte refills per 8-cell run); (e) printable-class
table + the printable branch hoisted FIRST in render's dispatch
(was bottom of a ten-compare cascade). defertest sim mirrored the
gen+bounds bookkeeping and promptly caught its own v1/v2 split
brain (two mark procs, one still writing boolean dirt - the
handler's single dfmark was never wrong); unified, PASS 4010.

RESULTS (his runs): stock TOTAL 121.70 -> 106.76, SEVEN of 15 rows
won (insdel-char FLIPPED past CON:'s 2.88 at 2.72; erase-eol held;
sync-line 6.00 -> 5.38); dev TOTAL 4.42. DIAGNOSIS of the remaining
eight: cadence, not CPU - at 14MHz the CLIENT's write rate outruns
the 20ms timer's pooling, so flushes run near-per-packet and every
flush pays its blit; the dev config pools 60 packets a window and
collapses the same rows to 0.04?. Stock CON: wins those rows via
device-queue backpressure pooling. Hence:

### 1.2.4b3 — E4: drain-on-flush (23.7.26, deployed, awaiting boot)

When the flush timer fires, swaccept() sweeps the port for
consecutive ACTION_WRITEs that can legally join a write-behind
buffer (conok, no selection drag, not iconified, fits) - accepting
them with dowrite's exact state resets and replies - and STOPS at
the first packet it cannot take, stashing it untouched; the main
loop dispatches the stash through normal dopkt AFTER the flush.
Batch size now grows with load (the ROM's own backpressure trick at
our layer); idle latency stays the 20ms timer. Sweeping happens
ONLY on the timer path - choke flushes (reads, keys, modes, close)
are byte-identical to b2, which is the whole ordering argument.

Boot checklist (REBOOT FIRST):
- [ ] the full canary lap: Ed workout, More, ls colours +
      scrollback, Ctrl+R, ghost, selection DURING heavy output
      (parked writes + stash interplay), iconify mid-output,
      TWO windows with interleaved output (the sweep feeds foreign
      consoles' buffers - cross-window ordering eyes)
- [ ] Ctrl+C mid-list (breaktask set at sweep-accept too)
- [ ] conbench SYNC stock: scroll-nl vs 4.06 is the headline;
      insdel-line vs 3.02, vt-frame vs 3.44, clear-page vs 8.54,
      sgr-colour vs 16.52, sgr-perchar vs 7.90, cursor-pos vs 3.44
- [ ] conbench SYNC dev once (regression watch)

**b3 VERDICT (his runs 19:5x): stock 106.94 / dev 4.38 - IDENTICAL
to b2. The sweep was a no-op by construction: main's drain has
already emptied the port into the buffers before the timer is seen.
AND his catch: "Ed feels kinda sluggish with 1.2.4b3" - E1 removed
the choke-flushes that had made Ed accidentally synchronous, and
Ed parks its read BEFORE painting, so the read-choke never fires:
every paint waited for the 20ms timer.**

### 1.2.4b4 — E4 second draft + Ed's feel (23.7.26, deployed)

- E4c, the Ed fix: a console with a PARKED read or WaitForChar is
  interactive - dowrite flushes eagerly instead of arming the
  timer. Pending input = latency beats batching; dir/type have no
  parked read and keep full pooling.
- E4 rounds: flushexpired is a bounded backpressure loop now
  (render, sweep what arrived DURING the render, render again, max
  4 rounds; a stashed non-joiner ends the burst) - the packets
  that matter arrive while a flush renders, not before it.
- E4b: clearrow's three 77-iteration E loops are three CopyMems
  (ROM asm). At chip-ram-effective 14MHz those loops were ~1ms per
  scrolled LINE - ten per scroll-nl packet, the row's real cost.

Boot: the b3 checklist above, plus ED FEEL FIRST - it should be
back to 1.2.3 snappiness (pending-read flush = per-keystroke
rendering); if it still drags, say so before anything else.

### 1.2.4b6 — E5: blank-scroll skip (23.7.26, real-HW-driven)

His A1200+PiStorm (real AGA) exposed what emulation hid: scroll-nl
5.60 vs stock CON: 0.18 (31x) - we ScrollRaster BLANK scrolls on a
big 82x53 window at real silicon speed; CON skips them. One row =
5.4 of CCON's 13.4 real-HW total; fixing it flips a 5% overall LOSS
to a 38% win.

The fix: per-console curcon.vblank - TRUE = the visible model region
is provably all-blank, so a scroll moves blank->blank and clears an
already-blank strip = a pixel no-op the blitter skips (both
screenscroll and dfflush's catch-up). Sound because at scroll time
both modes have ALREADY erased the cursor/blip (curserase/eraseedit
run before render), so visible-model-blank == visible-pixels-blank.
Tracking is O(1): TRUE on form feed, FALSE on any glyph to the
visible region (the printable run, outchr, dfputc), and recomputed
accurately at the ONE chokepoint every full repaint flows through -
vblankscan() at the end of redraw() (resize/reopen/altrestore/
scrollback/dffull all route through it; scrolled-back views report
FALSE since visrow addresses live rows not history). A TRUE is never
a lie - only a real clear sets it.

Harness: defertest gained the flag + skip in the deferred engine
(legacy always-blits = reference); honest run 4010 packets identical
(skip is transparent when it fires), and a CONTROL forcing the flag
TRUE-always diverges at the first content-then-scroll packet - the
harness can see, so the PASS is real.

Boot checklist (REBOOT FIRST):
- [ ] scroll-nl feel: a file of blank lines / conbench scroll-nl -
      should be near-instant now (was the 5.6s real-HW dog)
- [ ] REGRESSION WATCH - content scrolling must still be perfect:
      dir SYS: ALL, type a long file, ls - text scrolls correctly,
      nothing frozen or stale at the top
- [ ] Ed: page up/down through a document - the disappearing-rows
      thing he noticed; blank regions skip, content regions blit
- [ ] clear then output then scroll - the vblank TRUE->FALSE flip
- [ ] scrollback up into history then back (viewoff path -> FALSE)
- [ ] iconify/restore, resize, More, colours - vblankscan chokepoint
- [ ] REAL HARDWARE conbench if available: scroll-nl vs 0.18 is the
      whole point; expect CCON total ~8s vs CON 12.8

## 1.2.5b1 — overlay pens: ghosts on 32+ colour / RTG screens

His real-A1200 report (24.7.26): fish autosuggestions never appear on
the 720p 32-bit Workbench; testing pinned the boundary EXACTLY at the
pen count — works up to 16 colours, dead at 32 and up. Root cause is
the `IF v > 15` guard on the ObtainBestPen table (anstab): on a 32+
colour screen the best grey/blue come back as pens >15, the guard
releases them (rightly - the model's attr plane stores fg/bg as one
NIBBLE per cell), anstab[0] stays -1, and drawedit() never even runs
sgfind() - so Right had nothing to accept, matching his "if it was
just invisible I could have pressed Right" observation precisely.

Fix: two per-console OVERLAY pens (ovgrey $555, ovblue $88F) obtained
beside anstab with NO cap - the ghost and the completion menu are
pixels-only (drawn full-depth, erased full-depth, never stored in the
model), so the nibble rule was never theirs to obey. ghostpen() and
menupen() fall back to them only after the existing branches, so
screens that work today resolve pens exactly as before. Obtained in
both openwin sites, released in both teardown sites with anstab.

Boot checklist (REBOOT FIRST):
- [ ] 16-colour WB (default): ghost + menu colours unchanged - the
      no-regression check, pens resolve through anstab as before
- [ ] ScreenMode to 32+ colours: type a command, retype its prefix -
      GREY GHOST APPEARS, Right accepts whole, Ctrl+Right one word
- [ ] same screen: Tab menu shows blue dirs / grey hidden entries
- [ ] iconify/restore + resize on the deep screen (reopen re-obtains,
      teardown releases - no pen leak, colours survive the cycle)
- [ ] REAL HARDWARE 720p 32-bit: the reported case itself
- [ ] ls colours on the deep screen: still via anstab (capped, model
      rule) - EXPECTED still default-pen there; NOT a regression,
      lifting that needs an attr-plane widening (a 1.3 thing)

## 1.2.5b2 — the audit4 fixes (24.7.26)

Fourth audit (ccon/audit4.md, D-series) over everything since 1.2.1:
the perf campaign's new surface. Three fixes, all deployed as b2:

- **D1** `dowrite` accepted a NEGATIVE pkt.arg3 into CopyMem (unsigned
  size = ~4GB copy, machine gone) - a regression the S5 accept path
  introduced; 1.2.1's render() made negative len a harmless no-op, and
  swaccept always had the `arg3 >= 0` guard. Now: reply -1 /
  ERROR_BAD_NUMBER, both accept sites agree.
- **D2** E5's vblank flag never saw editor paint: drawedit paints IN
  PLACE (b9, no pre-erase) and mirrors into the model without touching
  the flag, so the three screenscroll callers OUTSIDE the dorender
  bracket (edroom, dotab menu room, pastehintroom) could skip a blit
  with real pixels to move - line stays, ring/anchor advance. Fix =
  vbrecheck() at the three seams: TRUE flag is re-earned via
  vblankscan (mirrored cells are model cells, so it answers honestly),
  sb=NIL goes conservative FALSE. NOT fixed in drawedit - that would
  clear the flag after every cooked write's blip repaint and kill the
  whole E5 scroll-nl win.
- **D3** dfd[] never initialized (the E-globals-are-garbage rule the
  file states twice) - a garbage byte equal to the first live dfgen
  (1) merged noise spans into the first packets after mount. Now
  zeroed in main()'s existing table loop.

Boot checklist (REBOOT FIRST):
- [ ] plain regression eyes: dir/list/type flow, Ed session, More
      paging, resize, iconify/restore - nothing moved (D1/D3 are
      guards, D2 only fires on a provably-blank page)
- [ ] D2 case: fresh window, `type` a file that ends with a form feed
      (or Ctrl+L an empty shell), then type a line at the bottom row
      until it wraps - the line must SCROLL UP, not duplicate/stay
- [ ] D2 menu case: same blank-page state, type a partial path, Tab -
      completion menu appears with the edit line scrolled correctly
      above it
- [ ] D3 eyes: first commands after reboot show NO garbage flicker in
      the right margin (was always subtle/rare - absence is the pass)
- [ ] conbench quick pass on 1.2.5b2: scroll-nl still ~CON-beating
      (the E5 skip must still fire - vbrecheck must NOT have
      pessimised the write path; it is only called from editor room
      procs, never from render)

## Design notes

- One stream, one window for M1 — fh.args is already a per-open id
  so multiple streams can come later without protocol changes.
- The window stays open after the last ACTION_END in M1, so the
  output can be inspected; real open/close semantics are M5.
- Debugging: no WriteF after the handshake (the no-DOS rule; E's
  lazy stdout would try to open a console). If logging is needed,
  render into the window or blink the screen.
