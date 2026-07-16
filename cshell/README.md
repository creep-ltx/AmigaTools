# CShell

A full-screen, keyboard-driven CLI for AmigaOS.

**Where this is going:** CShell is being rebuilt as a real console
*handler* (what CON: is, what KingCON and ViNCEd are) — mounted as
`CSH:`, speaking the DOS packet protocol, hosting the actual
AmigaDOS shell, so anything running inside can write, read, ask,
and go raw. The build plan and milestones live in `todo.md`. What
is described below is the first build: an application-style
frontend that proved the renderer, the line editor, the history
and the scrollback — all of which transplant into the handler. Its
one structural limit: commands it launches cannot read input
(they get `NIL:`), so interactive programs don't work inside it.

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
directory juggling. Bare `cd` prints the current directory, and the
Linux reflexes translate: `cd ..` climbs (AmigaDOS spells it `/`),
`cd ../..` climbs twice, `./` means here. `ls` is a built-in too: a
Linux-style listing of the current directory (or `ls <path>`) —
names sorted case-insensitively, multi-column filled
down-then-across the way ls does it, directories marked with a
trailing `/`. Options combine (`ls -lt`): `-l` long format
(`hsparwed` protection flags, size, date, name), `-1` one per line,
`-t` newest first, `-S` biggest first, `-r` reversed. `cls`/`clear`
push the visible console into the scrollback and show a clean one
(`Ctrl+Up` still reaches everything). `history` lists the prompt
history, numbered. `help` shows the built-ins and the keys. `df`
lists every mounted volume with size, used, free and how full.
`less <file>` pages through a text file — `Space` = next page,
`Enter` = next line, `Esc`/`q` = enough — and `cat <file>` pours it
out without pausing. (The name `more` is deliberately not taken:
that's a standard Amiga command in the path.) `exit` and `quit` end
the session. Everything else runs as an external command via
`SystemTagList`, with its output rendered straight into the console
area through `PIPE:` — cfile's live console engine, adapted.

## Keys

- Typing inserts at the cursor — the inverted cell in the input
  line. `Left`/`Right` move it, `Ctrl+Left`/`Right` jump by word,
  `Shift+Left`/`Right` jump to start/end. `Backspace` deletes
  before it, `Del` deletes under it.
- `Enter` runs the line.
- `Esc` clears the line you're typing without running it.
- `Up`/`Down` walk the prompt history (32 entries, consecutive
  repeats stored once); going below the newest entry brings back
  the line you were typing.
- `Ctrl+Up`/`Ctrl+Down` scroll the console output history by line,
  `Shift+Up`/`Shift+Down` by page — up to 4000 lines. The two are
  independent: walking the prompt history never moves a scrolled
  console view, and running a command snaps the view back to the
  live output position.

## Prompt

`DH0:path >` — the shell's actual current directory. A long path
truncates to its last two components with a leading `...`
(`DH0:.../cfile/testfolder >`) rather than wrapping.

The prompt lives on a fixed input row at the bottom of the console
area, directly above the footer — output scrolls in the region
above it and can never push it around, wrap it, or land mid-line
after it (ANSI art without a trailing newline used to do exactly
that). When a line is run, the prompt and the command are echoed
into the scroll region, so the transcript still reads like a
classic shell session.

## Files

- `cshell` — prebuilt AmigaOS binary.
- `cshell.e` — the source, Amiga E.
- `cshell-mockup` — the header/footer frame art for the 80-column
  Topaz grid, loaded at runtime (not compiled in — it has raw
  high-bit bytes that aren't safe to hand-transcribe into source).
- `cshell-mockup-microknight7` — the same art sized for the
  91-column grid a 7×7 font gives; loads when the font does.
- `todo.md` — the handler build plan and milestones.

CShell opens in MicroKnight7/7 when `FONTS:` has it (proportional
fonts are refused) and falls back to Topaz/8 — hardcoded for now,
a config file arrives with the handler rebuild. The art follows
the font.

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

Later runs verified: escape-sequence swallowing against real ANSI
art (the glyphs render, the codes vanish), the block-aligned
header/footer art, the fixed input row staying planted under
scrolling output, finished lines echoing into the transcript,
console-area scrolling, `cd` to another device, and a failed
command's error text arriving through the pipe.

Changed since, compiled but not yet re-exercised: MicroKnight7/7
as the default font with its own 91-column mockup (Topaz/8 and the
80-column art as the fallback), the cursor blip
with mid-line editing (`Left`/`Right`, `Ctrl` word jumps, `Shift`
ends, insert, `Backspace`/`Del`), the built-ins `ls` (with
options), `cls`/`clear`, `history`, `help`, `df`, `less` and `cat`,
`cd ..`/`cd ../..`, prompt history on
`Up`/`Down` and console scrollback on `Ctrl`/`Shift`+`Up`/`Down`
(4000-line model, view restored when a command runs), the prompt stays
visible while a command runs (only the typed line is wiped — keys
pressed meanwhile queue up and reach the next line), output fills from
the bottom of the console area (next to the prompt) instead of the
top, CSI cursor-forward and erase-line are now honoured the way
cfile's console does (ANSI art draws its transparent gaps with
cursor-forward — swallowing it shifted everything left and merged
the shapes, which is what top3.ANS exposed), a trailing line feed
no longer opens a blank row between output and prompt (the bottom
scroll is deferred until something actually draws), typing accepts
Latin-1 characters beyond ASCII (å, ä, ö), bare `cd` prints the
current directory, and `Esc` erases the abandoned line from the
screen.
