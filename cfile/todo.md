# CFile — missing features

What a file manager should have that CFile does not, roughly in the
order the friction hits a daily driver. Keys marked (?) are
suggestions, not decided.

## Roadmap

**0.3 RELEASED (22.7.26)** — inside-archive browse + full deferred write
model, sizes/sorting, `/` filter, mark all/pattern, `.info` sidecars,
F5 rescan, byte-weighted archive progress, comment editing, free-space
check, self-maintaining config. See CHANGELOG.md. Path there:
0.3b1 inside archives -> 0.3b2 sizes -> 0.3b3 deferred writes -> a run of
backlog polish.

**0.3.1 RELEASED (22.7.26)** — code-audit pass over 0.3: the editor's
200-char line cap removed (dynamic per-line buffers, no more silent
truncation), the `/` filter now carries the date column, a `deltree`
skip-list leak fixed, config read sized to the file, `arcadd` returns its
slot, the parallel-array entry moves folded into one primitive, and
`ARCWRITE ONEXIT` now defers an archive move-out too. See CHANGELOG.md.

**0.3.2 — lzx inside (COMPLETE on main, UNRELEASED)** — browse/view/copy/
move out+in/Del/new/rename/edit inside `.lzx` archives, with the same
deferred commit-on-exit as lha, plus the progress bar now ticking for lzx.
A point release, not a `.0`: it is the 0.3 archive system reaching one more
format, not a new capability. Turned out *simpler* than lha: LZX 1.21's `d`
removes a stored directory member directly (with the trailing slash), so no
rebuild path; `d` globs with no `-Qw`, so member names are `'`-escaped. Four
probe rounds captured lzx's real output first (~/Documents/Amiga/
lzxhelp.txt, lzxprobe[/2/3]). Docs updated. `$VER`/help not yet bumped, not
yet released.

## 0.4 and beyond — agreed plan (design pinned 23.7.26)

**0.4 is the daily-driver leap** — a genuine new capability class (reach,
search, extensibility), which is why it earns the `.0` and lzx does not.
Groups roughly in build order; the exact split into 0.4 / 0.5 / … gets
decided as each release is cut. **Mouse is decided against** — CFile is a
keyboard program by design (DOpus is for mouse users).

### Navigation

- [ ] **Bookmarks** — `Alt`+`1`..`0` sets a slot to the ACTIVE pane's
      location, bare `1`..`0` jumps back. 10 slots, real paths only (not a
      spot inside an archive). Digits are currently unbound; read `Alt`+digit
      as a raw key + `Alt` qualifier (a plain `Alt`+`1` through the keymap is
      layout-dependent). Session-only by default; **`SAVEBOOKMARKS ON|OFF`**
      (default OFF, parallels `SAVEDIRS`) persists the 10 slots to
      `cfile.config` on quit as `BOOKMARK1`..`BOOKMARK0`, self-maintaining
      like the other keys (`configensure` appends it to existing configs).
- [ ] **Go-to-path** — `g` opens a prompt; type a path, the active pane
      jumps there (Lock it first; error if it won't open).
- [ ] **Directory history** — back/forward through visited dirs. LOW prio.

### Search

- [ ] **Find file** — recursive name search from the current directory;
      results as a jump or a synthetic pane.
- [ ] **Content search** — grep-style text search inside files, results
      into the console frame.

### Configurable keys + user commands (the big refactor)

- [ ] Rebind the **main verb keys** from the config. The modal prompt keys
      (`s`/`d`/`c`, `y`/`n`) stay fixed — they are contextual.
- [ ] **User command keys** — bind a key to a shell command/script run on
      the selection, with substitution tokens:
      `{f}` selected entry's name · `{p}` active pane's dir · `{o}` other
      pane's dir · `{m}` the marked set, space-joined · `{ff}` full path of
      the selection (dir + name). e.g. `lha a {o}stuff.lha {m}` or
      `MyViewer {ff}`. Runs through the in-frame console (livecmd). Wants a
      new config section and turns the eventloop's hardcoded key->verb
      dispatch into a key->action table.

### Operation safety

- [ ] **Cancel a running op** — `Esc` during a big copy/move/delete/pack/
      archive aborts. Poll the window IDCMP non-blocking inside the copy /
      tree / arcrunprog loops. Leaves what is already done and reports
      "cancelled — N of M" (no rollback; the in-flight file's partial target
      is cleaned up). Small, high-trust.

### Smooth progress bars (the dream: ALL bars smooth)

- [ ] Copy/EXTRACT can go truly smooth: lha prints `(done/total)` and lzx
      `( run / total )` PER MEMBER as it works, so add the *delta* of the
      running count instead of one jump per file. (Regular file-copy already
      ticks per 16KB.) ADD/pack only prints the final size once
      (`Adding (N)`), no running counter — so an add bar can smooth BETWEEN
      files but each file stays one step unless we weight it by our own byte
      accounting during staging. Supersedes the old "per-byte progress inside
      a file" follow-up under 0.3b1.

### Comfort / nice, no hurry

- [ ] **Auto-refresh** — StartNotify on the pane dirs so external changes
      show without F5. FS-UAE dir-drive notification support unverified.
- [ ] **KEYMAP config** — e.g. `KEYMAP s`; run `C:SetKeyboard` at startup
      before the window opens (bootless non-US keyboards). Needs a bootless
      FS-UAE boot test; vamos cannot test it. (Detail under 0.3 candidates.)
- [ ] **Editor find / replace + goto-line + block copy-paste** — the
      built-in editor is cursor/insert/split/join only. LOW prio, but yes
      eventually.
- [ ] **DOpus-style icon info** — icon type, default tool, tooltypes in the
      `i` window. (Deferred since 0.1.)

## 0.3b3 — deferred archive writes (done)

Editing inside an lha no longer repacks per change. Delete/new/copy/
move/edit stage into a scratch tree on the archive's OWN volume (not T:,
which is normally RAM:T — a machine with little fast RAM would run out),
flag the cached members, and the pane shows the result live with a
"modified" tag. Leaving the archive or quitting commits the whole session
in as few as two LhA runs (one batched delete, one batched add); a
modified archive asks (s)ave/(d)iscard/(c)ancel first. `ARCWRITE ONEXIT`
is the default; `DIRECT` keeps the old repack-per-edit path.

The catch that shaped it: **LhA 2.15's `d` cannot remove a stored
directory (-lhd-) member** by any flag/slash form (probed), and `-r -e a`
re-adds a duplicate empty-dir member. So a commit that removes a directory
takes a rebuild path — extract the whole archive to the work tree, prune
the deleted paths, overlay the staged adds, repack with `-r -e`, swap in
on success only (a canary file guards against a failed extract clobbering
the original). The rebuild collapses duplicates for free, and DIRECT-mode
folder deletes route through it too. Two LhA gotchas found on hardware:
it auto-appends `.lha` to a suffixless archive name (the temp archive must
be named `*.lha` or the swap silently no-ops), and empty dirs must be
pre-built before extract (its NIL:-input can't create output dirs).

## 0.3b2 — sizes (done)

`fmtbytes` renders a byte count in <=5 chars ("937", "9.1K", "123K",
"1.4M", "1.9G"). The border row carries a fixed-width status slot per
pane: free space normally, the marked set's count + bytes while anything
is marked. Each pane row shows a right-aligned size column — a file's
bytes, "<DIR>" for a directory until `=` walks it (treestat) and drops
the real total in, which then also weighs into the marked-set total.

The sizes had been dead data since 0.1: `esize` was populated by readdir
and arcadd but never displayed, and `sortpane` swapped names and
dir-flags but NOT sizes — so the first thing to read `esize` (the border
total) showed every file a neighbour's bytes. Fixed by swapping esize in
sortpane too; it is now sort-tracked, so the size column and a future
sort-by-size can rely on it.

## 0.3b1 — inside archives (done)

`Right`/`Enter` on an lha archive goes inside it and the pane works
like a directory; `v e c m r n Del` all work on members. `lha v` is
parsed once on entry into a per-pane member cache and each level is
filtered out of that, so navigating costs no lha runs. Writes go
through LhA and rewrite the archive; the bar steps per file, driven
by counting lha's own per-file output over an async `PIPE:`.

Four LhA 2.15 behaviours cost boot tests and are worth remembering:

- `lha l` is the **terse** flag layout that hides paths — the listing
  to parse is `lha v`, whose Name column is the full stored path.
- Its Ratio field is variable width (`40.5%` vs `100.0%`), so the
  columns shift row to row: parse by **field count**, never by column.
- Fed `NIL:` for input, lha cannot create a missing output directory
  (it wants to prompt), so extraction into a subdirectory failed until
  CFile pre-built the path itself. `-M` is also needed or lha tries to
  autoshow readme/`.doc` members into a `con:` window that never opens.
- `lha a` flattens an explicit `sub/file` argument to `file`, and
  skips a member that already exists. Paths survive only through `-r`
  recursion of a directory, and replacing means delete-then-add.

Follow-ups (batching done in 0.3b3; lzx/zip is the b4 roadmap above):

- [~] **Per-byte progress inside a file** — folded into "Smooth progress
      bars" in the 0.4-and-beyond plan (extract can go smooth off lha's
      `(done/total)` / lzx's `( run / total )`; add can't).
- [x] **Archive dir sizing** — done. `=` inside an archive sums the
      member sizes under the folder (arcsizeunder over the amsz cache),
      filling the size column instantly, no walk.

## 0.3 candidates — "fast in the hand"

- [x] **`/` filter with live narrowing** — done. `/` narrows the pane
      to case-insensitive substring matches as you type; Up/Down walk
      the matches, Space marks one (so filter-then-mark works), Enter
      keeps the cursor on the match in the restored full listing, Esc
      restores it. The full listing is snapshotted and put back
      untouched, so marks and sort order survive; no disk re-read.
- [x] **Manual rescan** — done. F5 re-reads both panes (keeping each
      cursor). Leaving an archive also auto-refreshes both panes, so the
      other pane picks up the changed archive file's size.
- [x] **Mark all / none / invert / by pattern** — done. `a`/`A` mark
      all/none, `*` inverts, `+` marks by pattern via
      ParsePatternNoCase/MatchPatternNoCase over the pane. Both a
      `*.mod` glob (translated to `#?`) and native AmigaDOS `#?.mod`
      work — the glob alias also helps keyboards that can't type `#`.
- [x] **.info sidecars** — done. `ICONS ON` (default) makes
      copy/move/delete/rename carry a file or drawer's `<name>.info`
      along; a file and its icon both marked is handled once (infodup).
      `ICONS OFF` restores the old behaviour. Filesystem ops only for
      now — archive copy/move does not carry sidecars yet.
- [x] **`s` sort options** — done. `s` picks name/size/date or
      reverse; both panes re-sort in place (marks and cursor kept),
      dirs stay first, size default largest-first and date newest-first.
      A new `edate` field (days*1440+minute) feeds date sort on real
      dirs. Persist the choice with a `SORT name|size|date [rev]` config
      key; the s key overrides it for the session.
- [x] **Free space + marked totals** — done in 0.3b2, border row.
- [ ] **`KEYMAP` config key** — e.g. `KEYMAP s` for a Swedish
      keymap when started without a Startup-Sequence. `C:` is a
      standard boot assign (present even bootless, unlike ENV:/T:),
      so running C:SetKeyboard at startup — before the window
      opens, so key translation uses it from the first keystroke —
      should do it. Verify the mechanism (SetKeyboard vs
      keymap.library directly) against the autodocs; vamos cannot
      test this, needs a bootless FS-UAE boot test.

## Nice, cheap, no hurry

- [x] **Comment editing** — done. `c` in the `i` window edits the
      FileNote (lineinput, capped to the row width) and SetComment saves
      it. Also: copy/move now free-space-checks the target volume first
      (real dir-to-dir; archive copy-in/out still to do).
- [x] **Directory size on demand** — done in 0.3b2 as `=` (fills the
      size column via treestat), not the `i` window.
- [x] **Size/date columns** — done. Size column shipped in 0.3b2; the
      column now shows a compact date instead (DateToStr, day+month)
      when sorted by date, so it rides the `s` sort with no extra key
      or width. A new `edate` field feeds it (see the `s` sort item).

## Bigger, later

Moved up into **0.4 and beyond — agreed plan** (near the top): find file, content
search, configurable keys + user commands, and DOpus-style icon info are all
captured there with their decisions. **Mouse support is decided against** —
CFile is a keyboard program by design.

## Code notes, when a reason appears

- [ ] **ltxui.m split** — the frame composer / grid / console
      machinery moves to a module when a second tool wants it, not
      before.
- [ ] **StartNotify on cfile.config** — external edits (from a
      shell editor) could trigger the live reload the in-CFile
      editor already does. FS-UAE directory-drive support for
      notification is unverified.
