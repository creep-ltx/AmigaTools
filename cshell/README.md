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

- `cshell.e` — the source, Amiga E. No prebuilt binary yet.
- `cshell-mockup` — the header/footer frame art, loaded at runtime
  (not compiled in — it has raw high-bit bytes that aren't safe to
  hand-transcribe into source).
- `todo.md` — build plan and what's deliberately deferred.

## Building

```
evo cshell.e
```

## Verified behaviour

**None yet.** This was written without access to an E compiler, so
`cshell.e` has not been compiled, let alone run on real hardware or
FS-UAE/vamos. Treat it as a draft to build and test, not working
code — the same bar cfile and cmenu's own "Verified behaviour"
sections hold themselves to, just not met yet here. Things most
likely to need a fix once it actually compiles: the `PIPE:`
streaming path (adapted from cfile's proven `livepipe`, but not
retested here), `NameFromLock`/empty-string `Lock('')` for reading
the current directory (used for the first time in this codebase —
no prior tested reference for it in cfile or cmenu), and the console
area's row/column math for whatever screen mode it actually opens
on.
