# CFile — changelog

A two-pane, keyboard-driven text-mode file manager for AmigaOS.

## 0.3.1 (2026-07-22)

A code-audit pass over 0.3: one data-loss fix, a consistency fix for the
deferred archive model, and a batch of hardening. No new features.

**The editor no longer caps line length.** A line longer than 200
characters used to be silently cut on load, and saving wrote the cut back
— losing the tail. Lines now grow as needed; only the line count (8192)
and the 512 KB whole-file limit remain.

**`ARCWRITE ONEXIT` now defers a move-out too.** Moving a file or folder
*out* of an archive used to delete the member from disk immediately, even
under ONEXIT. It now waits for the commit like every other archive edit —
the member leaves the pane at once, the border shows `modified`, and the
deletion lands on leave or quit. (Discarding on leave therefore turns a
move-out into a copy.)

**The `/` filter keeps the date column aligned** when the panes are
sorted by date.

**Hardening.** A directory delete with many undeletable entries no longer
leaks its skip list; a recursive archive-cache walk takes its path buffers
from the heap; a full member cache can no longer mis-flag an entry; and a
hand-edited config larger than 4 KB is read and rewritten whole instead of
clipped.

## 0.3 (2026-07-22)

Archives you can go *inside* and work like a directory, the deferred write
model that makes editing them painless, and a long run of daily-driver
polish.

**Inside lha archives.** `Right`/`Enter` on an `.lha` goes inside it and
the pane behaves like a directory — the tree is listed a level at a time,
filtered from a single `lha v` parsed on entry, so moving around costs
nothing. Most verbs work in there: view a member, edit one in place,
copy/move files and whole folders both out and in and across
subdirectories, rename, delete, and make new files or empty directories.
All confirmed against LhA 2.15.

**Deferred archive writes (`ARCWRITE ONEXIT`, the default).** Edits are
held while you browse: the pane updates at once, the archive on disk is
left alone, and the border shows `modified`. Leaving the archive (or
quitting) commits the whole session in as few as two LhA runs; a modified
archive asks first — `(s)ave`, `(d)iscard` or `(c)ancel`. Staging lives on
the archive's own volume, not in RAM. Because LhA cannot remove a stored
directory, a folder delete rebuilds the archive to drop it (clearing any
duplicate entries in passing). `ARCWRITE DIRECT` keeps the old
repack-on-every-edit behaviour.

**Sizes.** Each row carries a size in its own column — a file's bytes,
`<DIR>` for a directory until `=` measures it (inside archives too, summed
from the cached member sizes). The border row shows the volume's free
space, or the marked set's count and total while anything is marked.

**Sorting.** `s` sorts both panes by name, size or date, reversible, with
directories always ahead of files; the column shows a compact date when
sorted by date. The start-up order is remembered by the `SORT` config key.

**Finding and marking.** `/` filters the pane live as you type (`Space`
marks a match, `Enter` keeps the cursor on it); `a`/`A` mark all/none,
`*` inverts, and `+` marks by pattern — a `*.mod` glob or an AmigaDOS
`#?.mod` pattern.

**More.** `.info` icons ride along on copy/move/delete/rename (`ICONS`
config key); `F5` re-reads both panes; the progress bar weighs archive
members by byte size; `c` in the `i` window edits the FileNote; copy/move
checks the target volume has room before it starts; and the config file
writes itself when missing and appends any new setting automatically, each
under a `;` comment.

## 0.2 (2026-07-16)

The frame is no longer a compiled-in 80×31 bitmap — it is composed at
start-up from measured mockup pieces for whatever fixed-width font the
config names, so a small font gives a wider, taller grid and the same
layout. `topaz` always means the ROM font; anything proportional or
leaving less than an 80×18 grid falls back to Topaz/8.

- **Config file** — `PROGDIR:cfile.config`: `LEFT`/`RIGHT` start paths
  (`(volumes)` = the volume list), `SAVEDIRS ON|OFF`, `FONT name/size`.
  The command line overrides the paths; `SAVEDIRS` rewrites only the
  `LEFT`/`RIGHT` lines, comments and hand edits pass through verbatim.
  Editing the config in CFile's own editor applies it live, and a bad
  value keeps the last good setup.
- **`e` — a text editor in the frame** (`Shift` = page/line ends, `Ctrl`
  = first/last line, `Enter` splits, `Backspace`/`Del` join; `Esc` asks
  to save only when modified).
- **`n` — new** — a name ending in `/` makes a directory, anything else
  opens the editor on a new file, created only when saved.
- **`v` with marks** — a bulk view tour: `Right` = next (consumes the
  mark), `Left` = back, `Esc` keeps the unviewed files marked.
- Volume list shows assigns below the volumes.
- `ENV:`/`T:` created at start when missing (`RAM:Env`, `RAM:T`), so
  CFile runs without a Startup-Sequence and removes only what it made.
- `Shift+Left`/`Right` jump to the start/end in every text prompt.

## 0.1 (2026-07-15)

The first working two-pane manager — everything keyboard-driven inside the
full-screen character frame.

- Two directory panes and a volume list past the device roots, so both
  panes reach anywhere.
- **Copy / move / delete / rename** with `Space`-marking for bulk sets;
  every collision question asked before anything transfers; recursive
  directory operations; protection bits, datestamps and comments
  preserved on copy.
- **Resilient deletes** — unprotect prompts (`y`/`n`/all), skip-and-
  continue on stubborn entries, honest reporting of invisible host names
  on FS-UAE directory drives. A centred, byte-accurate progress bar.
- **Type sniffing by header** — `Enter` opens by type; `v` views: a text
  pager, ANSI art in the classic palette (switched in live), a hex dump,
  or an archive's contents listing.
- **Archives** — `u` unpacks lha/lzx/zip (bulk with marks), `p` packs;
  the typed extension picks the archiver, relative paths inside.
- **In-frame console** — command output rendered by CFile itself through
  `PIPE:`, CSI-aware, with scrollback of up to 4000 lines.
- **`i`** — info window with live protection-bit editing.
- **`:`** — a shell command in the active pane's directory.
- `Shift`/`Ctrl` arrow paging, the `Help` key, and a quit confirm.
