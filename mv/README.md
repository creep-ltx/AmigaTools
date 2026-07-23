# mv

A Unix-style move command for AmigaDOS, written in Amiga E
([mv.e](mv.e)). Build it (or use the included binary) and install it
as `C:mv`.

An assembly sibling (`mv.asm`) was retired — it had frozen at the
old `OVERWRITE`/`BACKUP` keyword interface and the few KB of size
win weren't worth hand-porting every change. It lives on in git
history and the old release archives.

## Usage

```
mv [-fb] FROM ... TO
```

```
mv oldname newname                (rename)
mv work:file work:archive/file    (move within a volume)
mv work:file work:archive         (into a directory, keeping its name)
mv work:file ram:                 (cross-volume: copy + delete)
mv work:somedir work:elsewhere    (directories move too, same volume)
mv #?.mod mods:                   (AmigaDOS pattern)
mv a.txt b.txt c.txt work:stuff   (multiple sources)
mv -f #?.iff pics:                (replace existing targets)
mv -b config work:app             (existing target -> config.mvbak)
```

- Flags are bundled Unix-style — `-f`, `-b`, or `-fb` — matching `ls`
  and the rest of this set; the last path is `TO`, everything before
  it is a source. `mv ?` prints usage.
- `FROM` takes any number of names and/or AmigaDOS patterns. With
  several files or a pattern, `TO` must be an existing directory; a
  single plain name keeps the simple rename/move behaviour.
- If `TO` is an existing directory, sources are moved into it under
  their own names.
- An existing target is **skipped** by default; everything that wasn't
  moved is listed under `not moved:` at the end, return code 5 (WARN).
  This is deliberately safer than Unix `mv`'s silent clobber — it's
  effectively `mv -n`. `-f` deletes and replaces the target instead —
  after checking (with `SameLock()`) that source and target aren't the
  same object, so `mv -f file file` can never delete your only copy.
- `-b` renames the existing target to `<name>.mvbak` first, then moves
  the source in. If that backup name is already taken the file is
  **refused** — nothing is touched, the reason is printed, and it joins
  the not-moved list (return code 10). The `.mvbak` suffix belongs to
  this tool (unlike `.old`, which people hand-craft for their own
  backups), so `-bf` is allowed and means "replace the stale `.mvbak`"
  — `-f` consistently sanctions destroying exactly one thing: alone
  it's the target, with `-b` it's the old backup.
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

Requires Kickstart 2.04+ (`MatchFirst()`, `AddPart()`, `SetFileDate()`).

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

The prebuilt `mv` binary is included in this directory — no compiler
needed; copy it to `C:mv`. To build it yourself, with the E-VO
compiler:

```
evo mv.e
```

This produces an AmigaOS loadseg()able executable.

The `-f`/`-b` E build has been exercised under the E-VO toolchain
(vamos): usage, bad-flag rejection, rename, move-into-directory,
pattern expansion, multiple sources into a directory, skip-and-list-at-
end, `-f` replacement, and `-b` rescue to `.mvbak`. The underlying
behaviours it inherits unchanged — cross-volume copy+delete with
datestamp and protection bits intact across repeated moves, the
`mv -f file file` self-move guard, existing-target and cross-volume-
directory refusals, Ctrl-C mid-copy, and same-volume directory moves —
were verified earlier on an AmigaOS 3.2 install (FS-UAE) under the
previous keyword build. A fresh FS-UAE boot-test of the `-f`/`-b` build
is worth doing before relying on it, since the self-move guard depends
on `SameLock()`, which the emulator does not reproduce.
