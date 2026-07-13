# mv

A Unix-style move command for AmigaDOS — implemented twice: once in
Amiga E ([mv.e](mv.e)) and once in 68000 assembly ([mv.asm](mv.asm)).
Identical behaviour, identical argument template; build whichever one
you like and install it as `C:mv`.

| Implementation | Binary size |
|---|---|
| mv.e (E-VO) | 4288 bytes |
| mv.asm (vasm) | 2272 bytes |

Speed is identical — a move spends all its time inside dos.library —
so the assembly version's win is size, not speed.

## Usage

```
mv FROM/A/M TO/A [OVERWRITE]
```

```
mv oldname newname                (rename)
mv work:file work:archive/file    (move within a volume)
mv work:file work:archive         (into a directory, keeping its name)
mv work:file ram:                 (cross-volume: copy + delete)
mv work:somedir work:elsewhere    (directories move too, same volume)
mv #?.mod mods:                   (AmigaDOS pattern)
mv a.txt b.txt c.txt work:stuff   (multiple sources)
mv #?.iff pics: OVERWRITE         (replace existing targets)
```

- `FROM` takes any number of names and/or AmigaDOS patterns. With
  several files or a pattern, `TO` must be an existing directory; a
  single plain name keeps the simple rename/move behaviour.
- If `TO` is an existing directory, sources are moved into it under
  their own names.
- An existing target is **skipped** by default; skipped files are
  listed at the end and the return code is 5 (WARN). `OVERWRITE`
  deletes and replaces the target instead — after checking (with
  `SameLock()`) that source and target aren't the same object, so
  `mv file file OVERWRITE` can never delete your only copy.
- Cross-volume moves preserve the protection bits and datestamp, and
  a failed copy deletes the partial target rather than leaving half a
  file behind. If the copy succeeds but the source can't be deleted
  (e.g. delete-protected), that's reported and the return code is 5.
- Moving a *directory* across volumes would need a recursive copy and
  is refused.
- Ctrl-C is honoured between files and between copy chunks; a break
  mid-copy removes the partial target file.
- Errors on one file are reported and the rest of the batch still
  runs. Return code is the worst that happened: 0 clean, 5 skips,
  10 errors, 20 break.

Requires Kickstart 2.04+ (`ReadArgs()`, `MatchFirst()`, `AddPart()`,
`SetFileDate()`).

## Why AmigaDOS almost had this already

AmigaDOS `Rename` is secretly most of `mv`: at the filesystem level a
rename is just a directory-entry relink, so `Rename()` moves a file —
or a whole directory — anywhere on the same volume in one cheap call.
The name just hides it.

What it can't do is cross volumes: that fundamentally requires
copy-then-delete, and `Rename()` fails there with
`ERROR_RENAME_ACROSS_DEVICES`. So `mv` simply tries `Rename()` first
for every file, and only when it fails with exactly that error does
it fall back to copying the data (32KB chunks), carrying over the
protection bits and datestamp, and deleting the source.

Plain names and patterns are handled uniformly: every `FROM` argument
runs through `MatchFirst()`/`MatchNext()`, which expands wildcards
and matches literal names with the same code path.

## Building

Both prebuilt binaries are included in this directory — `mv` (the E
build) and `mv-asm` (the assembly build). No compiler needed; copy
either one to `C:mv` and go.

To build them yourself — the E version, with the E-VO compiler:

```
evo mv.e
```

The assembly version, with [vasm](http://sun.hasenbraten.de/vasm/):

```
vasmm68k_mot -Fhunkexe -nosym -o mv mv.asm
```

Both produce an AmigaOS loadseg()able executable. The asm source uses
Devpac-style Motorola syntax and plain 68000 instructions, so other
assemblers should cope with at most minor tweaks.

Both versions were verified on a real AmigaOS 3.2 install (FS-UAE):
rename, move-into-directory, pattern expansion, cross-volume
copy+delete with datestamp and protection bits intact across repeated
moves, skip-and-list-at-end, OVERWRITE replacement, the
`mv file file OVERWRITE` self-move guard, existing-target and
cross-volume-directory refusals, Ctrl-C mid-copy, and same-volume
directory moves.
