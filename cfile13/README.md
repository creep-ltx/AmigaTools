# CFile13

A two-pane, keyboard-driven text-mode file manager for AmigaOS —
the Kickstart 1.3 fork of [CFile](../cfile/), cut down to boot from
a floppy on the machines that started it all.

Born from a forum question: *can CFile go on a bootable floppy in a
KS1.3 environment?* CFile proper needs Kickstart 2.04. This fork is
the answer for everything below that — an A500 with 1.3 ROMs, a
rescue disk, a machine with 1MB and no hard drive.

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
- lha / lzx / zip archives through the external binaries
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

**Not yet bootable on 1.3 — work in progress.** See
[PORT-STATUS.md](PORT-STATUS.md) for the honest state of the
API back-port (stage 1: feature cuts; stage 2: replacing every
2.0-only OS call with its 1.3 equivalent). Until stage 2 lands,
the binary still requires 2.04+ like its parent.

## Requirements (target)

- Kickstart 1.3 (V34); should also run on anything later
- 1MB RAM (512K chip + 512K any); 512K-only is a stretch goal
- lha / lzx / zip binaries for archive work (on the floppy)

## Building

Same toolchain as CFile: E-VO 3.9.4 — `ecompile cfile13.e cfile13
LARGE` on the dev machine, or `evo cfile13.e` on a real Amiga.
