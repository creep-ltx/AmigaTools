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
- [ ] **M5: the point of it all** — scrollback (Shift+Up/Down /
      Ctrl+Up/Down from the 0.1 model), then polish: multiple
      streams, window-per-open semantics, CLOSE/WAIT option
      parsing from the open name, fail EXAMINE_FH (clib isatty
      probes it).
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
