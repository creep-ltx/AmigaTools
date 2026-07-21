# mkdir

A Unix-style make-directory command for AmigaDOS — implemented twice:
once in Amiga E ([mkdir.e](mkdir.e)) and once in 68000 assembly
([mkdir.asm](mkdir.asm)). Identical behaviour; build whichever one you
like and install it as `C:mkdir`.

| Implementation | Binary size |
|---|---|
| mkdir.e (E-VO) | 3712 bytes |
| mkdir.asm (vasm) | 1664 bytes |

Speed is identical — making a directory is all dos.library — so the
assembly version's win is size, not speed.

## Usage

```
mkdir [-p] DIR ...
```

```
mkdir work:newdir                 (one directory)
mkdir a b c                       (several at once)
mkdir -p work:a/b/c               (create missing parents)
mkdir -p ram:deep/nested/dir
```

- Flags are bundled Unix-style — `-p` — matching `ls`/`cp`/`mv` in this
  set; `mkdir ?` prints usage.
- Without `-p`, each `DIR` is created directly: its parent must already
  exist, and an existing `DIR` is an error (like Unix `mkdir`).
- With `-p`, every missing directory along the path is created — so
  `mkdir -p work:a/b/c` makes `a`, then `a/b`, then `a/b/c` — and an
  already-existing directory is **not** an error (the whole point of
  `-p`). A path component that already exists as a *file* is an error:
  you can't descend through it. Device/volume names (the part before
  `:`) are never created, only descended into.
- `DIR` names are literal — no pattern expansion. `mkdir "#?"` makes a
  directory called `#?`, not one per match. (The shell doesn't expand
  them either; on AmigaDOS each command matches its own patterns, and
  mkdir has nothing to match against.)
- Ctrl-C is honoured between directories.
- Errors on one `DIR` are reported and the rest still run. Return code
  is the worst that happened: 0 clean, 10 some directory failed,
  20 break.

Requires Kickstart 2.04+ (`CreateDir()`, `Lock()`, `Examine()`).

## How -p works

AmigaDOS `MakeDir` creates a single directory; it won't build a chain.
`mkdir -p` walks the path and creates each missing level in turn, in
place: copy the path into a buffer, then step through it, and at every
`/` that closes a real name, temporarily terminate the string there and
`CreateDir()` the prefix so far. An intermediate that already exists is
fine (`ERROR_OBJECT_EXISTS` is swallowed); a real failure stops just
that path. The device/volume head (everything up to `:`) is stepped
over, never created, and empty pieces from a leading or doubled `/`
(AmigaDOS parent-hops) are skipped too.

The last component is special: under `-p` an existing directory there
is success, but an existing *file* of that name is reported as "exists
and is not a directory" rather than silently accepted.

One shared subtlety across this tool set: `IoErr()` is read *before* the
error message is written, because a successful `Write()` zeroes it on
real AmigaDOS — read it afterwards and `PrintFault()` gets a 0, which
prints nothing at all, not even the newline.

## Building

Both prebuilt binaries are included in this directory — `mkdir` (the E
build) and `mkdir-asm` (the assembly build). No compiler needed; copy
either one to `C:mkdir` and go.

To build them yourself — the E version, with the E-VO compiler:

```
evo mkdir.e
```

The assembly version, with [vasm](http://sun.hasenbraten.de/vasm/):

```
vasmm68k_mot -Fhunkexe -nosym -o mkdir-asm mkdir.asm
```

Both produce an AmigaOS loadseg()able executable. The asm source uses
Devpac-style Motorola syntax and plain 68000 instructions.

The E build has been boot-tested on an AmigaOS 3.2 install (FS-UAE):
`mkdir -p` nested creation, and the error reporting (a missing parent
prints its fault on its own line). The assembly build is verified under
vamos to produce byte-identical output to the E build across the full
behaviour matrix — a fresh FS-UAE pass on `mkdir-asm` is worth doing
before relying on it.
