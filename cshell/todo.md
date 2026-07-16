# CShell — build plan

A full-screen, keyboard-driven CLI for AmigaOS. Standalone for now —
no CMenu integration, no assumptions about being launched from or
returning to anything else. That link comes later, once CShell and
CMenu both know what shape it should take.

Roughly in build order: a screen with nothing on it needs to exist
before a prompt can blink on it, and a prompt needs to exist before
history or completion mean anything.

## First test slice — compiled and run

Compiled and exercised: screen open (chrome from `cshell-mockup`
rendered correctly), typing/`Backspace`, `cd <name>` and `cd /`
(AmigaDOS's parent-directory shorthand) both moving the shell's real
current directory, `dir` as an external command proving the `PIPE:`
streaming path and that spawned commands inherit the shell's current
directory, long-path prompt truncation, and a clean `exit`. See
`README.md`'s "Verified behaviour" for the exact list and what's
still untried (`quit`, `Esc`, console scrolling, the error paths).

- [x] **Own screen** — `SA_LIKEWORKBENCH` clone of cfile's `openui()`,
      with the same borderless-public-screen fallback.
- [x] **REPL skeleton** — prompt, read a line, dispatch, loop; only
      `exit`/`quit` ends it.
- [x] **PIPE: streaming exec** — `runexternal()`, cfile's
      `livepipe()` engine adapted (see Command execution below).
- [x] **Persistent current directory** — `docd()` calls
      `CurrentDir()` for real, so it holds for the process's life;
      no per-command Lock/restore dance needed since spawned
      commands just inherit it.
- [x] **Prompt line** — `DH0:path >` with `...`-truncation, from
      `cshell-mockup`, in `trimpath()`.
- [x] **Background/decoration chrome** — header/footer bands loaded
      at runtime from `PROGDIR:cshell-mockup` (not hand-transcribed
      into the source — the art has raw high-bit bytes not safe to
      retype by hand) and drawn once; the console area between them
      scrolls independently via `ScrollRaster`.
- [x] **ANSI passthrough — answered**: cfile's own live console
      (`confeed`) only ever handled cursor-forward and erase-line,
      never SGR colour, so there was no existing colour-handling
      code to adapt. CShell's `confeed` swallows escape sequences
      byte-by-byte for now; real SGR interpretation (colour) is
      still open, tracked below.

Simplifications specific to this slice, to keep it small enough to
actually get right without a compiler to check against:

- [ ] **Mid-line cursor editing** — typing is append/Backspace only
      right now (`replinput()`); no Left/Right/Del, unlike cfile's
      `lineinput()`. Worth lifting cfile's cursor-walk logic in
      directly once the append-only version is confirmed working.
- [ ] **Frame/grid module split** — `cshell.e` re-derives its own
      small screen/console setup rather than sharing code with
      cfile. cfile's todo flagged an `ltxui.m` split "when a second
      tool wants it" — still not done; revisit once both tools'
      consoles are proven and the duplication is annoying rather
      than hypothetical.

## Command execution

- [x] **PIPE: streaming exec** — see above.
- [x] **Persistent current directory** — see above.
- [ ] **Built-in vs external split** — `cd`, `exit`/`quit` done.
      `history` and `clear` still make sense once there's history to
      show and a reason to clear the console; `help` too.
- [ ] **Exit status** — decide whether/how a failed command's return
      code surfaces (prompt colour? inline marker? nothing yet?).

## Line editing & history

- [ ] **Prompt-line editing** — append/Backspace only so far (see
      above); still needs cfile's cursor walk and
      `Shift`+`Left`/`Right` start/end jumps.
- [ ] **Command history** — ring buffer, `Up`/`Down` to recall,
      size configurable.
- [ ] **Tab completion** — paths and (maybe) command names. Not in
      cfile at all — the single biggest new piece of interaction
      code this project needs. Flag as the riskiest estimate here.

## Display

- [x] **Prompt line** — done, see above.
- [ ] **Scrollback** — output that scrolls off the console area is
      gone for good right now (`ScrollRaster` with no backing
      model); cfile's ~4000-line buffer approach is the template
      once this needs revisiting.
- [ ] **ANSI passthrough (colour)** — see the "answered" note above;
      swallowing SGR codes instead of interpreting them is the
      actual gap now, not an open question.

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
- [x] **Background/decoration art** — `cshell-mockup` added: header
      band with flanking face icons, a wide-open scrollback area,
      and a footer band with a group tag. Chrome is top/bottom
      bands only; everything between is live console area.
