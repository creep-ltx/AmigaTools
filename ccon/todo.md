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
- [ ] **First-word command completion.** Tab on word one completes
      from the resident list (semaphore-walkable, no packets) and
      the path: C: plus the CLI's path chain (cli_CommandDir lock
      list — walk the sender's CLI like conbysender does, scan
      each lock with the M5b machinery). Ghost synergy: people
      run what they can complete.
- [ ] **Scrollback search.** The last KingCON/ViNCEd feature CCON
      lacks: a search key in the scrollback view (Ctrl+R while
      scrolled? `/` cooked-style prompt? decide), matches
      highlighted via the attr plane (style plane helps), n/N
      jumps, any output snaps live as ever. The Ctrl+R search
      machinery (srfind's fold-substring scan) generalizes from
      the history ring to the model rows.
- [ ] **Bracketed-paste safety.** RAMIGA-V currently replays LFs
      as Returns — a pasted multi-line snippet EXECUTES as it
      lands. zsh's answer, ours too: paste inserts inert text
      (ghost-adjacent highlight while fresh?), nothing runs until
      a real Enter. Keep a PASTEEXEC open option (or RAMIGA+
      SHIFT+V) for the old behaviour where wanted. Raw-mode paste
      (into Ed) stays byte-faithful, untouched.

### Parked for v1.2 — the big swing

- [ ] **Mount it AS CON: (and RAW:).** The KingCON crown: every
      console window in the system becomes a CCON window. Own
      release, own test ladder — the blast radius changes from
      "windows you asked for" to "every console the OS opens"
      (Startup-Sequence output, requesters' CON: opens, EndCLI,
      shells started before user-startup...). Open questions: keep
      answering 'CCON' to the V47 shell probe (OUR editor owns
      every prompt — the point) vs a per-mount startup arg;
      whether anything hardcodes CON: quirks CCON lacks (ICH/DCH
      and soft styles from Theme A are prerequisites); dn_Startup
      naming so one binary carries CON:/RAW:/CCON:/CRAW: cleanly.

## Design notes

- One stream, one window for M1 — fh.args is already a per-open id
  so multiple streams can come later without protocol changes.
- The window stays open after the last ACTION_END in M1, so the
  output can be inspected; real open/close semantics are M5.
- Debugging: no WriteF after the handshake (the no-DOS rule; E's
  lazy stdout would try to open a console). If logging is needed,
  render into the window or blink the screen.
