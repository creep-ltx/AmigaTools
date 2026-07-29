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

## Disk images — plan DRAFT (30.7.26, pending Tobias's sign-off)

**The ask (30.7.26):** `.iso` and `.adf` support. ISO read-only
("usually cd/dvd"). ADF read/write — mount them, with a way to
unmount — plus creating a standard empty `.adf` "for saving stuff
for easy transfer to UAE on other systems". Planning first.

**The shape — two different animals on purpose:**
- **ISO = the archive-pane model, read-only.** No mounting at all:
  ISO9660 is uncompressed and simple (one volume descriptor at a
  fixed offset, directory records with explicit extents), so CFile
  parses it natively and the pane browses it exactly like an lha —
  view, copy out with the smooth bar (WE do the reads, so the b17
  bar applies directly, no poller), write verbs refused. Zero
  dependencies. Directories read lazily per-entry (an ISO can dwarf
  the 1500-member archive cache; ISO dirs are a real tree, so read
  one directory's records on demand like readdir does).
- **ADF = a real mount, never a parser.** Read/write means the real
  filesystem does the thinking — hand-writing FFS block allocation
  is how disks get corrupted. GROUND TRUTH from his install
  (checked on the host, 30.7.26): `Devs/trackfile.device` v2.46 +
  **`C:DAControl` 2.34 — the 3.2 shell front-end for it** (System/
  Mounter 47.11 is RDB-partitions-only, a different tool; the first
  plan draft missed DAControl because its name greps for neither
  "mount" nor "disk"). Full semantics from the shipped
  `dacontrol.help` (375 lines, read on the host): LOAD mounts an
  ADF on a DAn: device (default READ-ONLY; WRITEPROTECTED=NO for
  writable — CFile's default, per his read/write ask), EJECT
  [SAFEEJECT=YES] [TIMEOUT>=5] STOP unmounts (busy volume = wait
  then clean error; a loaded image cannot be deleted/moved until
  ejected), **CREATE LABEL=x FILESYSTEMTYPE=FFS DISKTYPE=DD makes a
  formatted, labeled, mounted-writable blank in ONE command** (the
  hand-rolled root-block generator is unnecessary), INFO
  SHOWVOLUMES = parseable device/file/volume table, SETENV →
  DA_LASTDEVICE, DEVICE=DAn: pins the unit, DD=880K / HD=1760K
  only. So the WHOLE ADF side is the lha/lzx external-command
  pattern — no NDK, no LVO stubs; every CFile verb works on the
  mounted volume for free, both panes, real writes into the .adf.
- **DMS rides along after all** (he fetched xdms 30.7.26: Amiga
  binary in C:, Linux binary in ~/Downloads; readdisk too): `.dms`
  is a COMPRESSED track archive, not an image — unpack via xdms to
  a temp `.adf` BESIDE the file (the T:/RAM lesson stands), then
  it's just an ADF. Read-only by nature (repack = later, if ever).

**Build order (each stage boot-gated, house rhythm):**
1. **Probe round `daprobe` — DONE 30.7.26, all questions closed**
   (script + assets in Amiga:/Amiga:datest, output daprobe.out,
   host-side verification with md5 + xdftool). Findings that shape
   the build:
   - LOAD on a pinned DEVICE=DAn:, writable, dir-drive-hosted
     image: all work. Write-back PROVEN (checksum diff + xdftool
     sees the written file; flushes to the .adf even while
     mounted). CREATE = formatted+labeled+mounted-writable in one
     command, xdftool-validated FFS; volume name = LABEL.
   - DON'T parse DAControl output beyond pass/fail: the INFO
     Device column runs name+unit together ("DA0000") and CREATE's
     messages miss a newline. CFile pins DAn: itself, keeps its own
     file↔device table, and resolves device→volume via the DosList
     like the volume list already does. (DA_LASTDEVICE works but is
     unneeded.)
   - THE YANK SURPRISE: default EJECT SUCCEEDED with the shell's
     CWD inside the volume — trackfile behaves like a real floppy,
     the medium can be pulled from under live locks ("please
     replace" zombies). DAControl will NOT protect us: CFile must
     do its own in-use discipline (refuse unmount while either
     pane is inside; step panes out first; then eject).
   - TRANSIENT IN-USE: EJECT SAFEEJECT=YES right after
     create+write failed once with "object is in use" (validator/
     flush still busy). Unmount = try, on failure Delay ~1-2s and
     retry once or twice, then report honestly.
   - Unformatted image mounts fine (volume "-") and any DOS access
     pops the system "Not a DOS disk" requester → CFile pre-sniffs
     the bootblock ('DOS'+flag) and refuses NDOS images with its
     own message (and suppresses requesters via pr_WindowPtr
     around its own probing accesses).
   - Eject on an empty unit is safe; STOP leaves the DAn: node as
     an empty drive (harmless).
2. **ISO stage — BUILT 30.7.26 = 0.4.1b22, BOOT-GREEN** ("iso
   works, I can go inside, copy out, view").
   Harness first (isoh.e in the job tmp): the parser procs were
   proven under vamos against three Python-mastered images
   (generator isogen.py, independently verified by 7z: 143
   entries, 0 mismatches) — recursive listings diffed against the
   manifests and ALL 132 files extracted byte-perfect (md5),
   covering 8.3 + `;1` stripping, trailing-dot names, lowercase/
   no-version names, a dir extent spanning 3 sectors (the
   records-never-straddle padding rule), 8-deep nesting, a 3MB
   file, an empty file. THEN transplanted verbatim into cfile.e:
   TY_ISO sniff (.iso suffix gate + CD001 magic - the head is
   boot code/zeros, worthless to sniffmem), enteriso/leaveiso/
   readisodir (LAZY per-directory reads, no member cache - an ISO
   can dwarf MAXMEM; isofind re-walks from the root so no stale
   extent state), eext = the SIXTH parallel entry field riding
   swapentry/snapentry/unsnapentry + the / filter snapshot (the
   esize lesson, applied before first boot), isoviewsel (size gate
   BEFORE the T: extract), isoxfer_out + isoextracttree (direct
   reads through copybuf: the bar is byte-smooth by construction,
   Esc lands mid-file, m refused - read-only), = sums via isosum,
   all write/nav verbs guarded (Del/n/r/e/p/u/g/b/f/t/:). Dirs
   list with size 0 so the column shows <DIR>; their extent size
   is re-resolved at use. Known bounds, stated: 500 entries per
   directory (the real-dir cap), >2GB images unreadable (32-bit
   Seek - no Amiga FS can hold one anyway), plain ISO9660 level
   1/2 names (Joliet/RockRidge/Amiga extensions = follow-up).
   Test images staged in Amiga:datest/ (basic/bigdir/mixed.iso).
3-5. **ADF mount + unmount + create — BUILT 30.7.26 = 0.4.1b23,
   hardened b24-b26, ALL BOOT-GREEN 30.7.26 ("All green!").** All three stages collapsed into one build
   because DAControl carries them all. TY_ADF sniff = .adf suffix
   + exactly a floppy's byte size (901120/1802240, the only sizes
   trackfile takes). ENTER MOUNTS: enteradf refuses NDOS images
   before mounting (bootblock must open "DOS" - the daprobe
   requester-storm lesson), runs `DAControl LOAD "<file>"
   WRITEPROTECTED=NO SETENV QUIET`, reads DA_LASTDEVICE (never
   parses DAControl output - the probe's rule), records the mount
   in an 8-slot table (device/file/return-dir/name) and jumps the
   pane to the DAn: device. Entering an already-mounted image just
   jumps (mounting one file twice is the crash the checksums
   option exists to prevent). LEAVE OFFERS UNMOUNT: Left at the
   device root prompts (y)/(n)-keep/Esc-stay; unmount refuses
   while the OTHER pane sits anywhere under the device (prefix
   check - OUR in-use discipline, since DAControl happily yanks
   through live locks), ejects with SAFEEJECT=YES TIMEOUT=5 STOP
   + one retry after a beat (the transient-validator lesson), and
   returns to the .adf's directory with it reselected. Quit
   unmounts everything ours (daunmountall after the arccommits).
   CREATE: `n` with a name ending .adf makes a formatted blank -
   the name picks the type exactly like the trailing slash does -
   via DAControl CREATE (FFS his default, DD, LABEL = the stem),
   which formats AND mounts it writable in one stroke; the mount
   is recorded so Enter jumps in and quit cleans up. v on an
   image file hints instead of hex-viewing into the 512KB cap.
   Known bounds, stated: needs C:DAControl (3.2) - detected at
   runtime with a clear message, everything else in CFile works
   without it; a volume entered via the VOLUME LIST under its
   volume name is invisible to the unmount guard (device-name
   prefix only); 8 concurrent image mounts.
   **b24 (30.7.26, his first boot find): b23 trusted DA_LASTDEVICE
   to learn the mounted unit - a stale env value recorded the WRONG
   device, so his created image "unmounted" (the wrong, empty unit)
   yet stayed held by trackfile: undeletable forever. Fix = PIN the
   device ourselves on BOTH roads (LOAD/CREATE DEVICE=DAn:, ladder
   over units not in our table until one takes - the probe proved
   pinning; env read deleted outright, table entries now CERTAIN;
   a failed CREATE try clears its leftover file so the next unit
   try is not "already exists"). PLUS the UX hole he hit: deleting
   a mounted image now UNMOUNTS IT FIRST automatically in delone
   (other-pane-inside still refuses - the yank discipline), instead
   of unprotect-prompting into "in use". BOOT-GREEN with b25/b26.**
   **b25 (30.7.26, his call): SAVEDIRS must never remember a DAn:
   path - quitting inside a mounted image now points the pane back
   at the .adf's parent directory before the unmounts (else next
   start begs "insert DA3: in any drive"). Done in daunmountall,
   which runs before saveconfig.**
   **b26 (30.7.26, his call): b closes the loophole - bookmarks now
   refuse anywhere inside a container: archive, ISO, or a MOUNTED
   image volume (new damunder(p) prefix helper, also tidying the
   quit remap). Jumping an already-saved stale bookmark still fails
   soft ("cannot go there").**
6. **DMS stage** — sniff `DMS!` magic, unpack via xdms beside the
   file (detached + byte-poller bar against the known 880K? probe
   xdms's output behavior), then enter the resulting ADF.
7. **Docs/help/release.**

**Decisions (Tobias, 30.7.26):** Enter on a `.adf` mounts + jumps
in (leave offers unmount, quit always unmounts ours); blank ADF
defaults to FFS; create-image extends the `n` prompt; version
framing decided later ("we worry about versioning later").

## 0.4 and beyond — agreed plan (design pinned 23.7.26)

**0.4 is the daily-driver leap** — a genuine new capability class (reach,
search, extensibility), which is why it earns the `.0` and lzx does not.
Groups roughly in build order; the exact split into 0.4 / 0.5 / … gets
decided as each release is cut. **Mouse is decided against** — CFile is a
keyboard program by design (DOpus is for mouse users).

### Navigation

- [x] **Bookmarks** — DONE (shipped; SAVEBOOKMARKS included) — `Alt`+`1`..`0` sets a slot to the ACTIVE pane's
      location, bare `1`..`0` jumps back. 10 slots, real paths only (not a
      spot inside an archive). Digits are currently unbound; read `Alt`+digit
      as a raw key + `Alt` qualifier (a plain `Alt`+`1` through the keymap is
      layout-dependent). Session-only by default; **`SAVEBOOKMARKS ON|OFF`**
      (default OFF, parallels `SAVEDIRS`) persists the 10 slots to
      `cfile.config` on quit as `BOOKMARK1`..`BOOKMARK0`, self-maintaining
      like the other keys (`configensure` appends it to existing configs).
- [x] **Go-to-path** — DONE (shipped) — `g` opens a prompt; type a path, the active pane
      jumps there (Lock it first; error if it won't open).
- [ ] **Directory history** — back/forward through visited dirs. LOW
      prio. **The `h` key is reserved for it since 0.4.1b27** (30.7.26,
      his call): help answers only to `?` and the Help key now.

### Search

- [x] **Find file** — DONE (shipped in 0.4 as `f`): recursive name
      search, substring or `#?`/`*` pattern, selectable results list,
      `Enter` jumps.
- [x] **Content search** — DONE (shipped in 0.4 as `t`): greps text
      files under here, hits list as `path:line: text`, `Enter` opens
      the file in the viewer.

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

- [x] **Cancel a running op** — DONE in two acts: 0.4 shipped `Esc`
      for copy/move/delete and searches (checkabort polling, partial
      target cleaned, "cancelled — N of M"); 0.4.1b21 extended it to
      ARCHIVE transfers (the detached/piped archiver is handed the
      shell break via a per-instance NP_NAME, nothing partial lands,
      a cancelled move never loses its source) and b22's ISO copy-out
      cancels mid-file.

### Smooth progress bars (the dream: ALL bars smooth)

- [x] **DONE, and better than the sketch** (0.4.1 b17-b20, "the bar
      chapter"): plain copies adapt their chunk to the run's
      bytes-per-pixel (pixel-continuous across a marked set), and
      archive EXTRACT went beyond pipe-parsing entirely — the archiver
      runs detached while CFile polls the growing destination files
      and credits honest byte deltas straight off the disk ("exactly
      what I wanted"). b22's ISO copy-out is byte-smooth by
      construction (our own reads). Still per-member, as predicted:
      ADD/pack (the compressed size is unknowable in advance;
      ADD-side polling of the growing archive is parked in
      perf-roadmap.md).

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
