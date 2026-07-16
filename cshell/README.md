# CShell

A full-screen, keyboard-driven CLI for AmigaOS. This is the first
test slice — see `todo.md` for what it does and doesn't cover yet.
Standalone: no CMenu integration.

## What it does

CShell opens its own screen (cloned from the Workbench mode/size via
`SA_LIKEWORKBENCH`, like cfile and cmenu) and draws a frame: header
and footer bands loaded from `PROGDIR:cshell-mockup`, and a console
area between them that behaves like a real shell — type a command,
press Enter, its output streams live into the frame, and the next
prompt follows right after, exactly like the mockup shows.

`cd` is a built-in (it has to be — an external `cd` process changing
its own current directory wouldn't affect CShell's), and it's a real
`CurrentDir()` call, so it holds for the life of the process:
external commands you run afterwards inherit it, no per-command
directory juggling. `exit` and `quit` end the session. Everything
else runs as an external command via `SystemTagList`, with its
output rendered straight into the console area through `PIPE:` —
cfile's live console engine, adapted.

## Keys

- Typing echoes into the current line; `Backspace` deletes the last
  character. There's no mid-line cursor movement yet (no
  `Left`/`Right`/`Del`) — that's next, see `todo.md`.
- `Enter` runs the line.
- `Esc` clears the line you're typing without running it.

## Prompt

`DH0:path >` — the shell's actual current directory. A long path
truncates to its last two components with a leading `...`
(`DH0:.../cfile/testfolder >`) rather than wrapping.

## Files

- `cshell` — prebuilt AmigaOS binary.
- `cshell.e` — the source, Amiga E.
- `cshell-mockup` — the header/footer frame art, loaded at runtime
  (not compiled in — it has raw high-bit bytes that aren't safe to
  hand-transcribe into source).
- `todo.md` — build plan and what's deliberately deferred.

## Building

A prebuilt binary is committed. To build it yourself, compile
`cshell.e` with the E-VO E compiler:

```
evo cshell.e
```

## Verified behaviour

Compiled and run: the screen opens with the header/footer chrome
from `cshell-mockup` rendering correctly, typing and `Backspace`
work, `cd <name>` and `cd /` (AmigaDOS's parent-directory shorthand)
both correctly move the shell's own current directory via
`CurrentDir()`, `dir` as an external command streams its output live
through `PIPE:` and confirms a spawned command inherits the shell's
current directory, long-path prompt truncation (`DH0:.../cfile/testfolder >`)
works, and `exit` closes the session cleanly.

Not yet exercised: `quit` (only `exit` has been tried, though they
share the same code path), `Esc` to cancel a line, console-area
scrolling once output runs past the bottom row (`dir` output so far
hasn't been long enough to trigger it), the `cshell: PIPE: is not
available` and `cshell: cd: cannot find "..."` error paths, and
behaviour on a screen/font combination other than whatever this
first run used.
