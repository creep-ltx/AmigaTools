# AmigaTools

A collection of small tools for AmigaOS.

## Tools

| Tool | Description |
|---|---|
| [dupfind](dupfind/) | Recursively scan a directory for duplicate files, with fast header-based, hash-confirmed checksum, or exact full-byte comparison modes. |
| [cboot](cboot/) | Boot selector — hold a mouse button or Amiga key at boot to jump straight into a different startup-sequence. |
| [amifetch](amifetch/) | neofetch-style dump of CPU/FPU, video timing, chip/fast RAM, Kickstart version, E-Clock, and stack size. |
| [cutils](cutils/) | **CUtils** — Unix-style file commands as one family: `ls`, `cp`, `mv`, `mkdir`, `rm`. Bundled `-la`-style flags, per-command AmigaDOS pattern matching, non-destructive by default (skips listed, `-f` to mean it, volume roots refused), metadata carried like `Copy CLONE`, trees walked with work lists and deleted deepest-first. One binary each for `C:`, per-command `.doc` references, separate versions per command. |
| [cmenu](cmenu/) | Full-screen text boot menu — runs before the Startup-Sequence and launches the chosen script or executable. Default item with countdown, rotating ANSI art headers or full-screen backgrounds, LIGHT/DARK/ANSI colour styles, ProTracker chip music while the menu is up, and a built-in config screen that edits everything in place. |
| [cfile](cfile/) | Two-pane keyboard-driven text-mode file manager — copy/move/delete/rename with marks (all/none/invert/by-pattern), `.info` icon sidecars, and collision prompts, recursive directory operations with a progress bar, per-row size column with on-demand directory measuring, free-space and marked totals, sort by name/size/date (with a date column), live `/` type-to-filter, go-to-path and ten `b`+digit bookmarks, recursive find-by-name and in-file text search, cancel a running copy/delete/archive transfer with Esc, F5 rescan, volume list, text/ANSI/hex viewer, built-in text editor, browse and edit inside lha and lzx archives with deferred batched writes (commit or discard on leave), archive packing and unpacking, byte-by-byte progress bars, browse inside ISO images (read-only, no dependencies), mount ADF disk images read/write and create formatted blanks (via 3.2's DAControl), full-screen datatype picture viewer with zoom and pan, sound playback at true tempo, ProTracker mod playback, live in-frame console with scrollback, protection-bit editor, shell commands, and a config file with custom fonts, live reload and remembered pane paths. Current release: [0.4](../../releases/tag/cfile-v0.4). |
| [cterm](cterm/) | Terminal — a real AmigaDOS shell in a full-screen art-framed screen: a borderless window handed to the console handler of your choice (`CON:`, `CCON:`, `KCON:`, …) via the `WINDOW` option, plus a `FROM` startup script for aliases. Shell, line editing, raw mode, More and Ed are all the OS's own. Named CShell before 0.3. |
| [ccon](ccon/) | `CCON:` — a console handler, the CON:/KingCON class: a mounted DOS handler speaking the packet protocol, hosting a real shell (`NewShell CCON:`) with output scrollback (the one thing stock CON: cannot be given from outside), a modern line editor with history/ghosts/completion/Ctrl+R (ghosts on RTG/deep screens too, as of 1.2.5), iconify-to-Workbench (a real title-bar gadget as of 1.2.6, plus RightAmiga+I), drag-and-drop of Workbench icons as quoted shell arguments, a complement-mode cursor drawn the ROM's way (checkerboard ghost on inactive windows), an alternate-screen contract for Ed and More that survives close gadgets and mid-session resizes, KingCON-style `CON:`/`RAW:` takeover — and a model-first, plane-masked render engine that, as of 1.2.4, runs five times faster than stock CON: on real hardware (A1200 + PiStorm) with render barriers on. Current release: [1.2.6](../../releases/tag/ccon-1.2.6). |
| [conbench](conbench/) | Console speed benchmark — fifteen workloads (line output, block writes, colour runs, full-screen repaints, insert/delete blits) timed from the client side of the packet interface, with a SYNC barrier mode, a per-line `sync-line` test that exposes write-behind deferral, and a window-size probe that warns when the geometry would skew the comparison. |

Each tool lives in its own subdirectory with its own README covering
usage, how it works, and how to build it. Prebuilt binaries are
included right in the tool directories (cboot's full release archives
live under [Releases](../../releases) instead), so no compiler is
needed — copy the binary somewhere in your path and go. Each release
also carries an `.lha` archive; cmenu's is laid out with `C/`, `S/`,
and `Libs/` drawers that copy straight over `SYS:`.

## Building

Tools here are written in [Amiga E](https://en.wikipedia.org/wiki/E_(programming_language))
and compiled with the E-VO compiler:

```
evo <toolname>.e
```

This produces a native AmigaOS loadseg()able executable.

cboot is the exception — it is written in 68000 assembly, buildable
with [vasm](http://sun.hasenbraten.de/vasm/):

```
vasmm68k_mot -Fhunkexe -nosym -o cboot cboot.asm
```
