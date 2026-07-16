# CShell — build plan

**The ruling (2026-07-16): CShell is a real CLI.** Not a program
that looks like a console — a mounted console *handler* (what CON:
is, what KingCON and ViNCEd are), speaking the DOS packet protocol,
hosting the actual AmigaDOS shell. Any command run inside it can
write, read, ask, and go raw. The first build (the application +
PIPE: renderer in today's `cshell.e`) hit its architectural ceiling
the moment an interactive command needed stdin: commands got `NIL:`
input by construction. That ceiling is not patchable — the handler
architecture removes it.

## What transplants from the current build (the hard parts exist)

- **confeed** — the write-side renderer: CSI parsing (consume-whole,
  C/K honoured), tabs, wrap, deferred bottom scroll → becomes
  `ACTION_WRITE`.
- **The scrollback model** — 4000 rendered lines + Ctrl/Shift
  scrolling → a handler-side feature, exactly where KingCON keeps it.
- **replinput** — blip cursor, insert editing, word jumps, Shift
  ends, the 32-entry history ring → becomes the handler's
  cooked-mode line editor (this is where KingCON does history too).
- **The chrome** — screen, mockup bands, fixed input row: the
  handler owns its window; all of it stays.
- **ensureassigns, trimpath, the mockup loader** — unchanged.

The REPL/dispatch skeleton is what gets replaced: the *system
shell* provides cd, path, prompt, scripts, S:Shell-Startup. The
built-ins survive as tiny standalone C: commands (see M5) — usable
from any shell, which is where they always belonged.

## Milestones

- [ ] **M0: protocol homework** — before any code: verify the
      console packet protocol against real sources (RKM: DOS
      Manual, NDK autodocs/includes, the PIPE: handler source,
      KingCON source if findable). Minimum set to confirm:
      ACTION_READ / ACTION_WRITE, ACTION_SCREEN_MODE (cooked/raw),
      ACTION_WAIT_CHAR, ACTION_CHANGE_SIGNAL, ACTION_DISK_INFO
      (consoles answer it with their window!), FINDINPUT/
      FINDOUTPUT/END (open/close), and how EOF (Ctrl+\) is
      signalled. Packet numbers and reply rules from the docs, not
      from memory — this protocol is exactly the territory where
      recalled details lie.
- [ ] **M1: handler skeleton** — a process with a packet port,
      mounted at runtime (verify: MakeDosEntry/AddDosEntry vs a
      DEVS:DOSDrivers mountfile) as `CSH:`. Opens, renders
      ACTION_WRITE through the transplanted confeed into the
      chrome'd screen, closes clean. Test from a normal shell:
      `echo >CSH: hello` — vamos cannot test any of this, the loop
      is FS-UAE boot tests from day one.
- [ ] **M2: cooked reads** — ACTION_READ backed by the transplanted
      line editor: blip, insert editing, word jumps, history,
      scrollback keys; EOF handling. Test: `Ask` and a y/n Delete
      prompt running inside CSH:.
- [ ] **M3: host the real shell** — `NewShell CSH:` (and CShell the
      launcher = mount + open + start shell + wait). Native cd,
      prompt, path, scripts. **This is "real CLI" achieved.**
- [ ] **M4: raw mode** — ACTION_SCREEN_MODE raw + WAIT_CHAR +
      single-key reads. More, Ed, interactive fullscreen programs
      work. The last of the ceiling gone.
- [ ] **M5: the extras return** — `ls` (with its options), `df`,
      `cat`/`less` as standalone AmigaTools C: commands; config
      file (FONT like cfile, history/scrollback sizes, art paths);
      the font-relative grid; CMenu integration (a menu item
      opening a CSH: shell and getting control back).

## Design notes carried over

- The fixed input row + standing prompt: keep. It solved the
  empty-row and mid-line-prompt problems structurally, and ViNCEd
  proves the pattern in a real handler.
- Bottom-up fill, deferred scroll, cls-pushes-into-scrollback:
  keep - they are renderer behaviours, orthogonal to the protocol.
- Break/Ctrl-C: in the handler world this becomes honest - the
  handler knows the shell's process and can signal CTRL_C the way
  real consoles do (verify the mechanism in M0).
- The `more` name conflict resolved itself: system More will just
  work in M4.

## The old build

`cshell.e` as of the pivot still compiles and runs as the
application-style frontend; it stays in history as the proving
ground for the renderer, editor and scrollback until the handler
supersedes it.
