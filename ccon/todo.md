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
- [ ] **M2: cooked reads** — ACTION_READ backed by the 0.1 line
      editor (blip, insert editing, history); EOF on Ctrl+\.
      Test: `Ask` and a y/n prompt inside CCON:.
- [ ] **M3: host the real shell** — `NewShell CCON:`; then CShell
      speaks `CCON:…/WINDOW0x` instead of `CON:` and gets its
      frame back with our renderer inside.
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
