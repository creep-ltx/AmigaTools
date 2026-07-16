# CShell — build plan

A full-screen, keyboard-driven CLI for AmigaOS. Standalone for now —
no CMenu integration, no assumptions about being launched from or
returning to anything else. That link comes later, once CShell and
CMenu both know what shape it should take.

Roughly in build order: a screen with nothing on it needs to exist
before a prompt can blink on it, and a prompt needs to exist before
history or completion mean anything.

## Foundation

- [ ] **Own screen** — clone cmenu's `SA_LIKEWORKBENCH` approach so
      PAL/NTSC/interlace/RTG all come out right with no mode
      detection. Borderless-window fallback on the public screen if
      the screen can't open, same as cfile/cmenu.
- [ ] **Font handling** — disk font from config with a Topaz/8
      fallback (cfile's rule: reject proportional fonts and anything
      that leaves less than a usable grid).
- [ ] **Frame/grid layout** — cfile's todo already flags an
      `ltxui.m` split "when a second tool wants it, not before."
      CShell is that second tool: decide whether the frame composer
      and console-render code move to a shared module now, or get
      re-derived once and reconciled later.
- [ ] **REPL skeleton** — prompt, read a line, dispatch, redraw,
      loop. This replaces cfile's `:` (run one command, return to
      the panes) with a loop that never returns on its own — only
      `exit`/`quit` ends it.

## Command execution

- [ ] **PIPE: streaming exec** — adapt cfile's console engine
      (stream a running command's output straight into the frame,
      no console window, no borders) as the execution path for
      external commands.
- [ ] **Persistent current directory** — cfile's `:` runs a command
      in the active pane's directory and forgets it; CShell needs a
      real shell-style `CurrentDir()` that persists across commands
      for the life of the process.
- [ ] **Built-in vs external split** — `cd` *must* be a built-in
      (an external child process changing its own current directory
      doesn't affect the parent). Candidates for built-in: `cd`,
      `exit`/`quit`, `history`, `clear`, maybe `help`. Everything
      else goes through the PIPE: exec path unchanged.
- [ ] **Exit status** — decide whether/how a failed command's return
      code surfaces (prompt colour? inline marker? nothing yet?).

## Line editing & history

- [ ] **Prompt-line editing** — reuse cfile's cursor walk and
      `Shift`+`Left`/`Right` start/end jumps.
- [ ] **Command history** — ring buffer, `Up`/`Down` to recall,
      size configurable.
- [ ] **Tab completion** — paths and (maybe) command names. Not in
      cfile at all — the single biggest new piece of interaction
      code this project needs. Flag as the riskiest estimate here.

## Display

- [ ] **Scrollback** — reuse cfile's ~4000-line buffer and its
      arrow-key (`Shift`/`Ctrl`) scroll-back behaviour.
- [ ] **Prompt line** — current directory at minimum; format
      probably wants to be configurable eventually, but a fixed
      format is fine to start.
- [ ] **ANSI passthrough** — check what cfile's PIPE: renderer
      actually does with SGR colour codes in a command's output
      (cfile's own header renderer parses SGR/cursor-forward, but
      that's a different code path from the live console stream) —
      confirm whether CLI tools that colour their own output show up
      right, or whether that needs adding.

## Configuration

- [ ] **Config file** — same conventions as cfile/cmenu: plain text,
      `;` comments, live-reload-on-edit-and-save. Needs at least
      `FONT`, history size, scrollback size; style (LIGHT/DARK/ANSI
      palette, cmenu-style) is a natural fit too.
- [ ] **Startup directory** — where CShell's `CurrentDir()` starts;
      probably `SAVEDIRS`-style persistence (cfile) is worth
      matching rather than reinventing.

## Later / deliberately deferred

- [ ] **CMenu integration** — launch-from and return-to-hub. Not
      started on purpose (see top of file); revisit once cmenu grows
      the "wait and re-loop instead of exit" change it needs for
      *any* sub-tool to hand control back.
- [ ] **Background/decoration art** — mockup ASCII coming next, will
      shape how much of the frame is "chrome" vs. live console area.
