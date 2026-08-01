# CFile13

A two-pane, keyboard-driven text-mode file manager for AmigaOS —
the Kickstart 1.3 fork of [CFile](../cfile/), cut down to boot from
a floppy on the machines that started it all.

Born from a forum question: *can CFile go on a bootable floppy in a
KS1.3 environment?* CFile proper needs Kickstart 2.04. This fork is
the answer for everything below that — an A500 with 1.3 ROMs, a
rescue disk, a machine with 1MB — or 512K — and no hard drive.

**Boot-proven.** [cfile13.adf](cfile13.adf) in this directory is the
shipping artifact: write it to a floppy (or mount it in an
emulator) and a stock A500 with Kickstart 1.3 boots straight into
CFile13. On 512K it adapts itself — a 4-colour screen in the same
palette, smaller buffers — and leaves ~40K of working room; on 1MB
it runs full-dress with ~520K free.

## What it is

CFile13 is a **fork, not a port-in-progress of the main line**: it
started as a copy of the CFile 0.5 source and was cut down and
back-ported. The pane engine, viewer, editor and archive handling
are the same debugged code. It is deliberately **less actively
developed** than CFile: the feature set freezes at 1.0, and fixes
are cherry-picked from the main line when they apply.

## What stays

- Two panes, volume list, full navigation
- Copy / move / delete / rename / new directory, with the
  byte-weighted progress bar
- Marks (all / none / invert), sorting, the `/` filter
- Text, ANSI and hex viewing; the internal text editor
- lha / lzx / zip archives through the external binaries (the
  boot disk ships LhA 1.38 — the one LhA that runs on 1.3; LZX
  extracts but its encoder cannot fit a 1MB machine, so packing
  is lha's job)
- **ISO browsing** — CFile reads ISO 9660 itself, no OS support
  needed, so it works even on 1.3
- Protection bits and file comments; bookmarks; directory history
- The `i` info window with icon tooltype viewing/editing
  (non-destructive file splice — no icon.library needed to write)

## What 1.3 cannot have (cut, with reasons)

| Feature | Why it cannot exist on 1.3 |
|---|---|
| Auto-refresh of panes | `StartNotify()` does not exist — no filesystem notification before 2.0. `F5` rescans manually. |
| Picture / sound viewing | datatypes.library is OS 3.0+. CANDIDATE ROAD BACK for pictures: a native IFF ILBM viewer — parse BMHD/CMAP/CAMG/BODY by hand, decode ByteRun1 straight into a screen's planes, LoadRGB4 the palette. Pure V33, covers the classic formats (DPaint art, screenshots, HAM/EHB) on the native chipset. Backlogged, post-first-boot |
| ProTracker mod playback | ptreplay.library itself requires OS 2.04+ (verified 1.8.26) — no road back short of a hand-rolled Paula replayer |
| ADF mounting | `DAControl`/trackfile.device are OS 3.2 |
| Mark by pattern | `ParsePattern()` is 2.0+; a hand-rolled matcher may earn its way back. (`f` find lost its `#?` glob mode to the same cut — substring search remains) |
| Recursive text search | cut for memory footprint, not API — may return with a small capped buffer |

## Status

**Boot-proven on Kickstart 1.3 (0.1b17, 1.8.26)** — seventeen
builds in one day, from first source copy to a 512K boot with room
to spare. [PORT-STATUS.md](PORT-STATUS.md) is the full ledger:
every cut, every V36 call rebuilt on a V33 road, and the
boot-gate evening's one-find-per-build history (PROGDIR:, the
VANILLAKEY swallow, the ram-handler's 100%-full report, the
FS-UAE overlay trap, the OS2.0-only LhA 2.15...).
[cfile13.readme](cfile13.readme) is the on-disk user readme:
what works, the limitations, and which files the boot floppy
needs.

## Requirements

- Kickstart 1.3 (V34) through 3.2 — one binary, runtime-adaptive
- 512K RAM minimum (4-colour screen, ~40K working room);
  1MB+ recommended (full 8-colour screen, big buffers)
- Panes hold 300 entries each (main CFile: 500)

## Building

Same toolchain as CFile: E-VO 3.9.4 — `ecompile cfile13.e cfile13
LARGE` on the dev machine, or `evo cfile13.e` on a real Amiga.
