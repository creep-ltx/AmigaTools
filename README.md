# AmigaTools

A collection of small tools for AmigaOS.

## Tools

| Tool | Description |
|---|---|
| [dupfind](dupfind/) | Recursively scan a directory for duplicate files, with fast header-based, hash-confirmed checksum, or exact full-byte comparison modes. |
| [cboot](cboot/) | Boot selector — hold a mouse button or Amiga key at boot to jump straight into a different startup-sequence. |
| [amifetch](amifetch/) | neofetch-style dump of CPU/FPU, video timing, chip/fast RAM, Kickstart version, E-Clock, and stack size. |
| [mv](mv/) | Unix-style move with pattern support — Rename() on the same volume, copy+delete across volumes, skip/OVERWRITE/BACKUP on collisions. In both Amiga E and 68k assembly. |
| [cmenu](cmenu/) | Full-screen text boot menu — runs before the Startup-Sequence and launches the chosen script or executable. Default item with countdown, rotating ANSI art headers or full-screen backgrounds, LIGHT/DARK/ANSI colour styles, ProTracker chip music while the menu is up, and a built-in config screen that edits everything in place. |

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

Some tools also come in 68000 assembly, buildable with
[vasm](http://sun.hasenbraten.de/vasm/):

```
vasmm68k_mot -Fhunkexe -nosym -o <toolname> <toolname>.asm
```
