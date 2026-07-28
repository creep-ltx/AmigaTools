# CUtils

Unix-style file commands for AmigaDOS — `ls`, `cp`, `mv`, `mkdir`
and `rm` — written in Amiga E, one small binary each, made to be
copied into `C:` and used without thinking. The name is the point
twice over: they are the core utils your fingers already know, and
they are the utils that live in `C:`.

| Command | Version | What it is |
|---------|---------|------------|
| [ls](ls.doc) | [0.3.4](../../../releases/tag/ls-v0.3.4) | directory lister — `-la`, colors, columns sized by asking the console, sorts, patterns, safe `-R` |
| [cp](cp.doc) | [0.1.2](../../../releases/tag/cp-v0.1.2) | copy — patterns, recursive trees, metadata carried like `Copy CLONE`, non-destructive by default |
| [mv](mv.doc) | [0.5](../../../releases/tag/mv-v0.5) | move — `Rename()` on the same volume, copy+delete across volumes, whole directory trees all-or-nothing |
| [mkdir](mkdir.doc) | [0.1.1](../../../releases/tag/mkdir-v0.1.1) | make directory — `-p` builds the missing parents in place |
| [rm](rm.doc) | [0.1](../../../releases/tag/rm-v0.1) | delete — `-r` trees deepest-first, `-f` strips the d-bit the Amiga way, roots refused unconditionally |

Each command keeps its own version and its own release; this
directory is the family home. The Aminet archive (`ltx-cutils.lha`)
carries a single **pack version** of its own — pack 0.1.0 =
ls 0.3.4 / cp 0.1.2 / mv 0.5 / mkdir 0.1.1 / rm 0.1 — bumped
whenever the archive is repacked with newer commands. Per-command reference docs live in
the `<command>.doc` files (AmigaDOS command-doc style, readable
with `More` on the Amiga); the full code audit that shaped the
current versions is [tools-audit.md](tools-audit.md).

## The family manners

All five share one set of rules, so learning one is learning all:

- **Bundled Unix flags**, hand-parsed on purpose — `ls -la`,
  `cp -fr`, `rm -rfv`. A deliberate break from ReadArgs style,
  because muscle memory is the entire reason these exist. `cmd ?`
  still answers with usage, as an AmigaDOS command should.
- **Each command matches its own patterns** (`MatchFirst()` /
  `MatchNext()`), AmigaDOS-style — `rm #?.bak` works the same way
  `Delete #?.bak` does; plain names and patterns take one code
  path. Quotes group, `*n`/`*e` get their control meanings.
- **Non-destructive by default.** `cp` and `mv` skip existing
  targets and list them at the end (`-f` to replace, `SameLock()`
  guarded so `file file` can never destroy your only copy);
  `rm` refuses directories without `-r`, skips d-bit-protected
  files without `-f`, refuses volume roots unconditionally, and
  never follows a link anywhere.
- **Metadata is the default, not a flag.** Protection bits,
  datestamp and filenote travel with every copy and move — the
  `Copy CLONE` behaviour, because on the Amiga that is the
  sensible default.
- **One bad item never kills the batch.** Errors are reported,
  the rest still runs, and the return code is the worst that
  happened: 0 clean, 5 something was skipped (and listed),
  10 something failed, 20 break. Ctrl-C is honoured between
  entries and inside copies. More than 32 arguments is a hard
  error, never a silent truncation.
- **No native recursion, ever.** Trees are walked with explicit
  work lists (a deep tree can't blow the stack), directories are
  scanned to completion before anything inside them is touched,
  and deletes unwind deepest-first so every directory delete
  meets an already-empty directory.

## Files

- `<cmd>.e` — the sources, Amiga E.
- `<cmd>` — prebuilt AmigaOS binaries, ready for `C:`.
- `<cmd>.doc` — per-command reference, AmigaDOS command-doc style.
- `cutils.readme` — the combined Aminet-style readme.
- `tools-audit.md` — the 27.7.26 family code audit and fix ladder.
- `ls-bugs.md` — the ls `-R` freeze investigation, root-caused to a
  runtime allocator misuse (`Dispose()` on `NEW`'d objects); kept
  because the story is the best documentation of the discipline
  all five now follow.

Assembly twins of ls/cp/mv/mkdir were retired in July '26 — the
few-KB size wins weren't worth hand-porting every change. They
live on in git history and the old release archives.

## Building

With the E-VO compiler, each command builds standalone:

```
evo ls.e
evo cp.e
evo mv.e
evo mkdir.e
evo rm.e
```

Each produces an AmigaOS loadseg()able executable. Requires
Kickstart 2.04+ at runtime.

## Status

All five are boot-proven on AmigaOS 3.2 (FS-UAE and a real
A1200/PiStorm): the full audit boot deck — d-bit handling, a
protected leaf keeping its parent directories alive, in-use and
volume-root refusals, soft-link loops on real FFS, cross-volume
moves with the filenote intact — ran green on 27.7.26.
