# ls

A Unix-style directory lister for AmigaDOS, for fingers that type
`ls -la` faster than they can think `List`. A single small E
binary for `C:`.

```
ls [-1ahlrRSt] [path | pattern ...]
  -l  long listing (protection, size, date, filenote)
  -a  show .info files and hidden (h-bit) entries
  -h  human-readable sizes (K, M, G)
  -t  sort by date, newest first
  -S  sort by size, largest first
  -r  reverse sort order
  -R  recurse into directories
  -1  one entry per line
```

Flags are hand-parsed Unix bundles (`ls -lah work:`) — a
deliberate break from ReadArgs style, since muscle memory is the
tool's whole reason to exist. `ls ?` still answers with usage.

How ls semantics map onto AmigaDOS:

- `-a` reveals `.info` files and h-bit entries — the closest
  thing the Amiga has to dotfiles. Both are hidden by default.
- `-l` prints `hsparwed` protection bits, byte size, the DOS
  datestamp, and the filenote on a continuation line.
- Multi-column output is sized by asking the console: the CSI
  `0 q` window-bounds request, the same exchange C:Dir uses.
  Redirected or piped output falls back to one entry per line.
- Directories are colored on interactive output.
- A pattern argument (`ls #?.e`) lists the matches themselves;
  a directory argument lists its contents.

Return codes: 0 clean, 5 a path could not be accessed, 10 bad
arguments, 20 break (Ctrl+C is honoured mid-listing).

## Files

- `ls.e` — the source, Amiga E.
- `ls` — prebuilt AmigaOS binary, E build.
- `ls.asm` — the same tool in 68000 assembly.
- `ls-asm` — prebuilt AmigaOS binary, asm build (about half the size).

## Building

```
evo ls.e
vasmm68k_mot -Fhunkexe -nosym -o ls-asm ls.asm
```

## Status

Both builds boot-verified on an AmigaOS 3.2 install (FS-UAE):
columns and the width probe against both the stock CON: console
and the CCON: handler, colors, window-resize adaptation,
redirect fallback, Ctrl+C. The two builds are also differentially
tested against each other under vamos — byte-identical output
across the whole flag matrix.

Found while building: E's `Mod()` with a divisor over 64K raises
a CPU exception (the same 16-bit DIVU floor as `/`) — the
human-size tiers use pure shifts instead.
