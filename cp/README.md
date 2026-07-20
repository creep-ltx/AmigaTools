# cp

A Unix-style copy command for AmigaDOS, written in Amiga E ([cp.e](cp.e)).
Bundled `-flags` like `ls`, non-destructive by default like `mv`, with
AmigaDOS pattern support and recursive directory copy. Build it and
install it as `C:cp`.

## Usage

```
cp [-fr] FROM ... TO
```

```
cp file newname                 (copy to a new name)
cp file work:archive/           (into a directory, keeping its name)
cp -r dir work:backup           (recursive directory copy)
cp #?.txt ram:                  (AmigaDOS pattern)
cp a.txt b.txt c.txt work:stuff (multiple sources)
cp -f old.iff pics:             (replace an existing target)
```

- Flags are bundled Unix-style — `-f`, `-r`, or `-fr` — matching `ls`
  and the rest of this set; the last path is `TO`, everything before
  it is a source. `cp ?` prints usage.
- `FROM` takes any number of names and/or AmigaDOS patterns. With
  several files or a pattern, `TO` must be an existing directory; a
  single plain source may name its copy directly. Into an existing
  directory, sources are copied under their own names.
- An existing target is **skipped** by default; everything that wasn't
  copied is listed under `not copied:` at the end, return code 5
  (WARN). `-f` deletes and replaces the target instead — after
  checking (with `SameLock()`) that source and target aren't the same
  object, so `cp -f file file` can never destroy your only copy. A
  directory is never replaced with a file.
- Metadata is preserved by default — protection bits, datestamp, and
  filenote are carried to the copy, the way `Copy CLONE` does. There
  is no `-p` flag: preserving is the sensible Amiga default.
- `-r` copies directories. The tree is walked with an explicit work
  list rather than native recursion, so a deep tree can't blow the
  stack: each directory is recreated at the destination, its files
  copied, its subdirectories queued. An existing target directory is
  merged into, and files inside follow the same skip/`-f` rule.
  Without `-r`, a directory source is refused. (Copying a directory
  into its own subtree is not guarded against — don't.)
- Ctrl-C is honoured between files and between copy chunks; a broken
  or failed copy removes the partial target rather than leaving half a
  file behind.
- Errors on one file are reported and the rest of the batch still
  runs. Return code is the worst that happened: 0 clean, 5 skips,
  10 errors, 20 break.

Requires Kickstart 2.04+ (`MatchFirst()`, `AddPart()`, `CreateDir()`,
`SetFileDate()`, `SetComment()`).

## How it works

`cp` is `mv`'s sibling: at the file level it is `mv` without the final
delete. It always copies the data (in 32KB chunks) and carries over the
protection bits, datestamp, and filenote. The target is written only
when `-f` clears the way or nothing is there already; otherwise it is
left untouched and reported.

Plain names and patterns are handled uniformly: every `FROM` argument
runs through `MatchFirst()`/`MatchNext()`, which expands wildcards and
matches literal names with the same code path.

`-r` deliberately avoids native recursion. A deep directory tree would
sink the stack; instead `cp` keeps an explicit work list of
source/destination directory pairs and drains it breadth-first, so every
parent is created before its children.

## Building

The prebuilt `cp` binary is included in this directory — no compiler
needed; copy it to `C:cp` and go.

To build it yourself, with the E-VO compiler:

```
evo cp.e
```

This produces an AmigaOS loadseg()able executable.
