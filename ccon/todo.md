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
- [ ] **M4: raw mode** — ACTION_SCREEN_MODE honoured, WAIT_CHAR,
      single-key reads; More and Ed work.
- [ ] **M5: the point of it all** — scrollback (Shift+Up/Down /
      Ctrl+Up/Down from the 0.1 model), then polish: multiple
      streams, ACTION_DISK_INFO (consoles answer it with their
      window), CHANGE_SIGNAL break forwarding, fail EXAMINE_FH
      (clib isatty probes it), window-per-open semantics, CLOSE/
      WAIT option parsing from the open name.

## Design notes

- One stream, one window for M1 — fh.args is already a per-open id
  so multiple streams can come later without protocol changes.
- The window stays open after the last ACTION_END in M1, so the
  output can be inspected; real open/close semantics are M5.
- Debugging: no WriteF after the handshake (the no-DOS rule; E's
  lazy stdout would try to open a console). If logging is needed,
  render into the window or blink the screen.
