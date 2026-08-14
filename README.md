# AmigaTools

A collection of small tools for AmigaOS.

## Tools

| Tool | Description |
|---|---|
| [amifetch](amifetch/) | neofetch-style dump of CPU/FPU, video timing, chip/fast RAM, Kickstart version, E-Clock, and stack size. |
| [aminfs](aminfs/) | **AmiNFSv3** — NFSv3 client filesystem: mount a Linux export or a NAS share as an ordinary Amiga volume (device, volume name, Workbench icon). NFSv3 over TCP against a stock kernel nfsd or a Synology, read/write with COMMIT-on-close and write-verifier tracking, mount options for volume name, identity, time zone, transfer sizes and request pipelining (off by default — the synchronous path is the default path), clean dismount via `NFSDismount`, reboot-free handler upgrades. Measured on real hardware: 13–14 MB/s through `c:Copy` both ways, 65 MB/s reads through a large application buffer. **Canonical home: [AmiNFSv3](https://github.com/creep-ltx/AmiNFSv3)** — this copy remains while the monorepo transitions. |
| [cboot](cboot/) | Boot selector — hold a mouse button or Amiga key at boot to jump straight into a different startup-sequence. |
| [ccon](ccon/) | `CCON:` — a console handler, the CON:/KingCON class: a mounted DOS handler speaking the packet protocol, hosting a real shell (`NewShell CCON:`) with output scrollback (the one thing stock CON: cannot be given from outside), a modern line editor with history/ghosts/completion/Ctrl+R (ghosts on RTG/deep screens too, as of 1.2.5; device-name completion and an arrow-walkable menu as of 1.2.7), iconify-to-Workbench (a real title-bar gadget as of 1.2.6, plus RightAmiga+I, with your own AppIcon as of 1.2.7), drag-and-drop of Workbench icons as quoted shell arguments, a complement-mode cursor drawn the ROM's way (checkerboard ghost on inactive windows), an alternate-screen contract for Ed and More that survives close gadgets and mid-session resizes, KingCON-style `CON:`/`RAW:` takeover — and a model-first, plane-masked render engine that, as of 1.2.4, runs five times faster than stock CON: on real hardware (A1200 + PiStorm) with render barriers on. an optional defaults file (`L:ccon.cfg`, as of 1.2.7) whose every key is an open-string option, with named profiles and the open string always outranking it. Current release: [1.2.7](../../releases/tag/ccon-1.2.7). |
| [cdiff](cdiff/) | **cdiff** — visual diff: two files side by side in a window, with a real patience diff engine underneath (the git-patience shape), not a line-by-line eyeball. Tabs for Both/Left/Right and a Tree tab when given two DRAWERS — the pair walked, sorted and merged, with one-sided, size-differ and same-size-but-bytes-differ verdicts, Enter for the real diff of any pair. Changed rows read as selection bars, line-number gutters, hunk jump, horizontal pan for long lines, border scrollbars with the system's own arrows, mouse wheel, click and double-click. Edit a side through `ENV:EDITOR` and re-diff in place, F5 to reload. `TEXT` mode prints a unified-style listing to stdout, which doubles as the on-target test road under vamos. The first C-language member of the family — built with Bebbo's m68k-amigaos-gcc, engine proven by a harness that runs on the host AND under vamos before anything boots. |
| [cfile](cfile/) | Two-pane keyboard-driven text-mode file manager — copy/move/delete/rename with marks (all/none/invert/by-pattern), `.info` icon sidecars, and collision prompts, recursive directory operations with a progress bar, per-row size column with on-demand directory measuring, free-space and marked totals, sort by name/size/date (with a date column), live `/` type-to-filter, go-to-path and ten `b`+digit bookmarks, recursive find-by-name and in-file text search, cancel a running copy/delete/archive transfer with Esc, F5 rescan, volume list, text/ANSI/hex viewer, built-in text editor, browse and edit inside lha and lzx archives with deferred batched writes (commit or discard on leave), archive packing and unpacking, byte-by-byte progress bars, browse inside ISO images (read-only, no dependencies), mount ADF disk images read/write and create formatted blanks (via 3.2's DAControl), full-screen datatype picture viewer with zoom and pan, sound playback at true tempo, ProTracker mod playback, live in-frame console with scrollback, protection-bit editor, shell commands, and a config file with custom fonts, live reload and remembered pane paths. Current release: [0.4](../../releases/tag/cfile-v0.4). |
| [cfile13](cfile13/) | **CFile13** — the Kickstart 1.3 fork of cfile, boot-proven on a stock 68000 A500 with as little as 512K: the same pane engine, viewer, editor, archive browsing (lha/lzx/zip, LhA 1.38 aboard), ISO browsing and non-destructive icon-tooltype editor, back-ported onto pure V33 roads (ExNext scans, struct screen opens, `Execute()` runners, a Forbid doslist walk, console.device keymap translation) with runtime memory rungs (4-colour screen and small buffers on 512K, full dress on 1MB+). Ships as [cfile13.adf](cfile13/cfile13.adf) — a ready-to-write bootable rescue floppy with Swedish keymap, Disk-Validator and 68000 archivers. Deliberately less actively developed than cfile; the port ledger lives in [PORT-STATUS.md](cfile13/PORT-STATUS.md). |
| [cmenu](cmenu/) | Full-screen text boot menu — runs before the Startup-Sequence and launches the chosen script or executable. Default item with countdown, rotating ANSI art headers or full-screen backgrounds, LIGHT/DARK/ANSI colour styles, ProTracker chip music while the menu is up, and a built-in config screen that edits everything in place. |
| [conbench](conbench/) | Console speed benchmark — fifteen workloads (line output, block writes, colour runs, full-screen repaints, insert/delete blits) timed from the client side of the packet interface, with a SYNC barrier mode, a per-line `sync-line` test that exposes write-behind deferral, and a window-size probe that warns when the geometry would skew the comparison. |
| [cterm](cterm/) | Terminal — a real AmigaDOS shell in a full-screen art-framed screen: a borderless window handed to the console handler of your choice (`CON:`, `CCON:`, `KCON:`, …) via the `WINDOW` option, plus a `FROM` startup script for aliases. Shell, line editing, raw mode, More and Ed are all the OS's own. Named CShell before 0.3. |
| [cutils](cutils/) | **CUtils** — Unix-style file commands as one family: `ls`, `cp`, `mv`, `mkdir`, `rm`. Bundled `-la`-style flags, per-command AmigaDOS pattern matching, non-destructive by default (skips listed, `-f` to mean it, volume roots refused), metadata carried like `Copy CLONE`, trees walked with work lists and deleted deepest-first. One binary each for `C:`, per-command `.doc` references, separate versions per command. |
| [dupfind](dupfind/) | Recursively scan a directory for duplicate files, with fast header-based, hash-confirmed checksum, or exact full-byte comparison modes. |

Each tool lives in its own subdirectory with its own README covering
usage, how it works, and how to build it. Prebuilt binaries are
included right in the tool directories (cboot's full release archives
live under [Releases](../../releases) instead), so no compiler is
needed — copy the binary somewhere in your path and go. Each release
also carries an `.lha` archive; cmenu's is laid out with `C/`, `S/`,
and `Libs/` drawers that copy straight over `SYS:`.

## Building

Most tools here are written in [Amiga E](https://en.wikipedia.org/wiki/E_(programming_language))
and compiled with the E-VO compiler:

```
evo <toolname>.e
```

This produces a native AmigaOS loadseg()able executable.

**cdiff** is the exception — C, cross-compiled with
[Bebbo's](https://github.com/bebbo/amiga-gcc) `m68k-amigaos-gcc` —
chosen for the RKM-verbatim API documentation and the newer optimizer.
It builds through its own `Makefile`, which also runs the diff engine's
test harness on the host *and* under vamos before anything is deployed:

```
cd cdiff && make test && make
```

(`cutils/mkdir.c` is also C — a function-for-function twin of `mkdir.e`
written to compare the two languages side by side. The shipped `cutils`
binaries are the E ones.)
