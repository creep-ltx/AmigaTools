# mv

A Unix-style move command for AmigaDOS — implemented twice: once in
Amiga E ([mv.e](mv.e)) and once in 68000 assembly ([mv.asm](mv.asm)).
Identical behaviour, identical argument template; build whichever one
you like and install it as `C:mv`.

| Implementation | Binary size |
|---|---|
| mv.e (E-VO) | 2864 bytes |
| mv.asm (vasm) | 1104 bytes |

Speed is identical — a move spends all its time inside dos.library —
so the assembly version's win is size, not speed.

## Usage

```
mv FROM/A TO/A
```

```
mv oldname newname                (rename)
mv work:file work:archive/file    (move within a volume)
mv work:file work:archive         (into a directory, keeping its name)
mv work:file ram:                 (cross-volume: copy + delete)
mv work:somedir work:elsewhere    (directories move too, same volume)
```

- If `TO` is an existing directory, `FROM` is moved into it under its
  own name.
- An existing file is never overwritten (`object already exists`).
- Cross-volume moves preserve the protection bits and datestamp, and
  a failed copy deletes the partial target rather than leaving half a
  file behind. If the copy succeeds but the source can't be deleted
  (e.g. delete-protected), that's reported and the return code is
  5 (WARN).
- Moving a *directory* across volumes would need a recursive copy and
  is refused for now.

Requires Kickstart 2.04+ (`ReadArgs()`, `AddPart()`, `SetFileDate()`).

## Why AmigaDOS almost had this already

AmigaDOS `Rename` is secretly most of `mv`: at the filesystem level a
rename is just a directory-entry relink, so `Rename()` moves a file —
or a whole directory — anywhere on the same volume in one cheap call.
The name just hides it.

What it can't do is cross volumes: that fundamentally requires
copy-then-delete, and `Rename()` fails there with
`ERROR_RENAME_ACROSS_DEVICES`. So `mv` simply tries `Rename()` first,
and only when it fails with exactly that error does it fall back to
copying the data (32KB chunks), carrying over the protection bits and
datestamp, and deleting the source.

## Building

The E version, with the E-VO compiler:

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
rename, move-into-directory, cross-volume copy+delete with datestamp
and protection bits intact, existing-target refusal, cross-volume
directory refusal, and same-volume directory moves.
