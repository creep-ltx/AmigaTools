# CCON — build plan

**The goal:** CCON: — an LTX console handler. What CON: is, what
KingCON and ViNCEd are: a mounted DOS handler speaking the packet
protocol, hosting any client — including the real shell inside
CShell's frame (swap one string: `CCON:0/0/0/0/CShell/WINDOW0x…`).
The one feature that justifies it: **output scrollback**, verified
impossible with the stock V47 con-handler (no such option in its
ROM option table). The renderer, the 4000-line scrollback model,
the line editor and the scroll keys were already built and
boot-tested in CShell 0.1 (commit 71e29b1) — they transplant in.

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
- [ ] **Ed's menus (parked after four system freezes).** Ed
      attaches menus to our window (DISK_INFO window ptr) and
      requests raw event reports (`CSI 2;10;11;12{`). The TRUE
      V47 report format was recovered from console.device 46.1's
      ROM builder ($13de): `CSI class;subclass;ie_Code;
      ie_Qualifier;addrhigh;addrlow;secs;micros|`. Reports in
      exactly that shape froze the entire input chain (mouse
      dead) with the address halves as mouse coords, as
      ItemAddress(strip,code), AND as 0;0 — three value
      experiments, identical freeze fingerprint (title-bar
      black box: mp=2, rdn=0, ring all READs). **SOLVED by
      disassembling C:Ed itself: Ed does IDCMP surgery on the
      console window — 3× ModifyIDCMP, 6× GetMsg, WaitPort,
      3× ReplyMsg on OUR UserPort. The report is just the wake-up
      call; Ed then reads the window's IDCMP directly. Two tasks
      consuming one message port (with the sigbit allocated in
      ours) = stolen messages, blocked WaitPort, dead input
      chain. Stock CON: survives because console.device never
      touches the window's IDCMP — it taps keys upstream via an
      input.device handler, so the UserPort is free for Ed to
      commandeer.** The real fix is architectural and has its
      own milestone below (input-handler input). Until then CCON
      swallows picks: menus render, Esc-x exits, nothing
      freezes, and no reports means Ed's IDCMP code stays
      asleep.
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
      **Remaining M5 polish (separate slice):** multiple streams,
      window-per-open semantics, CLOSE/WAIT option parsing from
      the open name, fail EXAMINE_FH (clib isatty probes it).
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
      qualifier keys ($60-$67) and key releases (bit 7).**
- [ ] **M6: input.device-handler input (the Ed-menus fix, and
      full console.device parity).** Move key acquisition out of
      IDCMP: add an input.device handler (IND_ADDHANDLER) below
      Intuition's priority, take the keys Intuition forwards when
      our window is active, keymap-convert, feed the same queues.
      The window's UserPort then stays untouched — free for Ed's
      ModifyIDCMP/GetMsg takeover, exactly like stock. Then the
      raw event reports (format recovered from console.device
      46.1, ROM $13de) can come back and Ed's menus work. Input
      handlers run in interrupt-ish context: queue events, signal
      the handler task, do the work there.

## Design notes

- One stream, one window for M1 — fh.args is already a per-open id
  so multiple streams can come later without protocol changes.
- The window stays open after the last ACTION_END in M1, so the
  output can be inspected; real open/close semantics are M5.
- Debugging: no WriteF after the handshake (the no-DOS rule; E's
  lazy stdout would try to open a console). If logging is needed,
  render into the window or blink the screen.
