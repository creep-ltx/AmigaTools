# CTerm — what's next

**The architecture (settled 16.7.26, by experiment):** CTerm = own
screen + mockup art bands + a borderless window handed to the
standard console handler via `CON:`'s `WINDOW 0xaddr` option + a
real UserShell via `Execute('', console, NIL)`. Proven by
`contest.e` on the AmigaOS 3.2 install: real stdin, raw mode, Ed
fullscreen in the frame with menus. The write-a-handler plan
(M0–M5, see git history) is retired — the OS console already is
the handler, and everything the application-style CTerm simulated
(and more) comes for free.

## Near

- [ ] **Output scrollback (Shift+Up/Down)** — wanted; verified
      impossible from outside: the stock 3.2 con-handler (V47, its
      ROM option table checked directly) has no scrollback, and
      commands talk to the handler, not to CTerm. Two real paths:
      **ViNCEd** (Richter's handler, scrollback + raw mode, solid
      enough that OS 3.9 shipped it as the system console — test
      the WINDOW option like KingCON was tested), or **our own
      handler** — the retired plan below, whose hard parts
      (renderer, 4000-line scrollback model, scroll keys) were
      already built and boot-tested in the 0.1 proving ground
      (commit 71e29b1).

- [ ] **First boot test of the real cterm** — MicroKnight7 via
      SA_FONT: does the console inherit the screen font? (The
      contest ran in Topaz.) If not, find the console's font
      switch (SetFont on the window rastport is already done;
      console.device may want CD_SETDEFAULTKEYMAP-style
      configuration instead — verify, don't guess).
- [x] **KingCON as an optional upgrade — tried, dropped (16.7.26).**
      KingCON 1.3 gurus with AN_ASYNCPKT on this 3.2 install even
      on a bare `NewShell KCON:`, no CTerm involved (raised
      handler StackSize didn't help). Not our bug, not our
      dependency. If scrollback/completion in the frame is ever
      wanted again, candidates: a healthier modern handler
      (ViNCEd?) via the same WINDOW spec, or the retired
      own-handler plan below.
- [ ] **Shell dress** — a `PROMPT` and greeting via an optional
      `S:CTerm-Startup` (Execute a script before the interactive
      shell, or document the user's own Shell-Startup aliases:
      `alias exit endshell` for the Linux reflex).

## The standalone commands (rescued from the first CTerm)

The first build's built-ins were good ideas that belong in `C:` as
real commands, usable from ANY shell — each is a small tool in the
AmigaTools spirit:

- [ ] **ls** — Linux-style listing: multi-column filled
      down-then-across, `-l` (hsparwed flags, size, date), `-1`,
      `-t`, `-S`, `-r`. The sniffed-and-sorted machinery exists in
      git history, needs only a CLI wrapper.
- [ ] **df** — volumes with size/used/free/full%.
- [ ] **cat** / a `less`-style pager — though the system More now
      works, so the pager is optional.
- [ ] his mv already exists and is superior (cross-device).

## Later

- [ ] **Config file** — font name/size, art paths, maybe the
      screen mode; same conventions as cfile/cmenu.
- [ ] **CMenu integration** — a menu item that opens CTerm and
      returns to the menu at EndShell (CMenu's wait-and-reloop
      change).
- [ ] **Own console handler** — the retired M0–M5 plan, kept only
      as a someday: the one reason left is owning scrollback and
      completion without the KingCON dependency. The packet
      protocol facts gathered for M0 (FINDINPUT/READ/WRITE tables,
      fh_Port interactivity, WAIT_CHAR, CHANGE_SIGNAL break
      forwarding, EXAMINE_FH/isatty gotcha) are in the git history
      of this file if that day comes.
