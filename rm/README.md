# rm

A Unix-style delete command for AmigaDOS, written in Amiga E
([rm.e](rm.e)). Build it (or use the included binary) and install it
as `C:rm`.

`C:Delete` exists; `rm` is the muscle memory — and this one carries
the family manners (`ls`/`cp`/`mv`/`mkdir`): bundled flags, its own
pattern matching, one bad item never kills the batch, and a
"not deleted:" summary at the end.

## Usage

```
rm [-rfv] FILE | PATTERN ...
```

```
rm old.txt
rm #?.bak                         (pattern)
rm -r work:tmpdir                 (directory and contents)
rm -f locked.dat                  (strip delete protection first)
rm -rv ram:t                      (say what goes as it goes)
```

- Flags are bundled Unix-style — `-r`, `-f`, `-v`, or any mix — and
  `rm ?` prints usage.
- **Directories need `-r`**, like Unix (and unlike `Delete ALL`'s
  promptless enthusiasm). The tree is walked with an explicit work
  list, each directory scanned to completion before anything inside
  it is deleted, and directories are removed deepest-first once
  their contents are gone.
- **`-f` means force, the Amiga way**: a delete-protected file (the
  `d` bit) is skipped and listed by default; with `-f` the
  protection is stripped and the delete retried. A file another task
  holds open always refuses — `-f` cannot unlock it. `-f` also
  silences "no match".
- **Volume roots are refused unconditionally.** `rm -rf dh0:`
  answers "refusing to remove a volume root", full stop. No flag
  overrides it.
- **Links are deleted as links, never followed** — soft links and
  hard directory links both: the link entry goes, the target stays,
  and a linked ancestor can never turn `-r` into a cycle.
- `-v` lists each object as it is deleted (default silent).
- Ctrl-C is honoured between entries.
- Return code is the worst that happened: 0 clean, 5 something was
  skipped (see the list), 10 some item failed, 20 break.

Requires Kickstart 2.04+ (`MatchFirst()`, `DeleteFile()`,
`SetProtection()`).

## Safety model

Everything here follows one rule: destruction must be exactly what
was asked for, and nothing more.

- A directory that refuses to empty (a protected child without `-f`,
  a file in use) leaves its whole parent chain standing — each
  parent then reports "not empty" honestly, and nothing above the
  refusal is lost.
- The scan never deletes under a live directory walk (`ExNext` and
  deletion don't mix — the filesystem invalidates the walk); every
  directory is read to completion first.
- No native recursion: a work list plus a deepest-first unwind, so a
  pathological tree can't blow the stack.

## Building

The prebuilt `rm` binary is included in this directory — no compiler
needed; copy it to `C:rm` and go. To build it yourself, with the E-VO
compiler:

```
evo rm.e
```

This produces an AmigaOS loadseg()able executable.
