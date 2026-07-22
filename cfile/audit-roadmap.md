# CFile — audit roadmap

Findings from the 0.3 code audit, ordered by severity, with a concrete fix
plan for each. All line numbers are against `cfile.e` at the time of audit
(commit `c3588a8`); re-check before editing.

Legend: `[ ]` open · `[~]` in progress · `[x]` done

---

## Medium

### [x] 1. Editor silently truncates lines longer than 200 chars (data loss)

**Fixed by removing the cap** (dynamic line buffers). The interim refuse-to-edit
guard was superseded: instead of capping lines at `EDLW=200`, each editor line
now grows on demand, so there is no line-length limit at all and no truncation
is possible.

- New `edgrow(idx, need)` (`cfile.e:4995`) reallocates a line's `String` to fit
  (doubling to amortise), copies the content, swaps it in. FALSE only on OOM.
- `EDLW` is gone; new `EDLINIT=120` is the initial per-line buffer size.
- `edinsch` grows before inserting (`cfile.e:5012`); `edload` streams into a
  growing buffer and `SetStr`s per character so `edgrow`'s copy is always
  correct; line split sizes the new line to its tail; backspace/del line-joins
  grow the target instead of the old `<= EDLW` fit check; the tab loop stops on
  an 8-stop or an allocation failure.
- Only caps left: line **count** (`EDMAXL=8192`) and whole-file size
  (`VIEWMAX=512KB`). A single line is therefore bounded by the 512KB file cap.
- Compiles clean (E-VO, no errors). `StrMax` confirmed available.

Runtime: **verified working** in FS-UAE on AmigaOS 3.2 — long lines load whole,
edit, and round-trip on save. (Pathological single-line files edit in O(line
length) per keystroke, but that is bounded by the 512KB file cap.)


- **Where:** `edload` `cfile.e:5078-5083` (drop past `EDLW=200`), saved back
  by `edsave` `cfile.e:5099-5104`.
- **Symptom:** Opening a text file that has any line > 200 characters and
  saving it permanently cuts that line to 200 — silently. The too-*many*-lines
  case (`5057`) already aborts the load with a message; over-long *lines* do not.
- **Why it matters:** It's the only finding that can lose user data, and it
  gives no warning. Startup scripts, long assign lines, and data files can
  carry >200-char lines.
- **Fix options (pick one):**
  1. **Refuse to edit** when any line would truncate: during `edload`, if a
     line reaches `EDLW` before its LF, set `ok := FALSE` and
     `showmsg('a line is too long to edit safely (200-char cap)')`, mirroring
     the line-count guard. Safest, smallest change.
  2. **Load read-only / mark dirty-unsafe:** load truncated but block `edsave`
     (or force "save as" to a new name) so the original is never overwritten.
  3. **Raise the cap** to `EDLW` large enough for real files and *still* guard
     with option 1 for the pathological case.
- **Recommendation:** Option 1 for 0.3.x (few lines, no data risk); revisit a
  higher cap later.
- **Test:** Make a file with one 300-char line, `e`, save, verify the line is
  intact (or that the edit was refused with a clear message).

---

## Low

### [x] 2. `/` filter misaligns the date column (visual)

**Fixed.** `edate` now travels through the filter like the other columns: a
new `sdate` snapshot array in `dofilter` (allocated, NIL-checked, filled,
restored, disposed alongside the rest), threaded into `filterapply` as a new
parameter which assigns `edate[b+j] := sdate[i]`. Compiles clean (E-VO, no
errors). Staged to FS-UAE. Root-cause cleanup (item 8) still open — this is the
third open-coded entry-move that had to be fixed by hand.

_Original finding:_

- **Where:** `dofilter` snapshot `cfile.e:6093-6095` omits `edate`;
  `filterapply` `cfile.e:6067-6084` never assigns `edate[b+j]`.
- **Symptom:** While a filter is active *and* `sortmode = 2` (date), each row's
  date column (`drawrow` `cfile.e:4835`) shows the date of whatever entry used
  to occupy that row, not the filtered name's date. Self-heals on filter exit
  (edate is never mutated).
- **Fix:** Add `edate` to the snapshot and to `filterapply`:
  - declare `sdate=NIL:PTR TO LONG`, `New(MAXENT * 4)`, add to the NIL-check
    and the `Dispose` block;
  - fill `sdate[i] := edate[b+i]` in the save loop (`6115-6121`);
  - pass it into `filterapply` and set `edate[b+j] := sdate[i]` (`6067-6079`);
  - restore `edate[b+i] := sdate[i]` in the restore loop (`6189-6194`) for
    symmetry (not strictly required, but keeps the pattern honest).
- **Root-cause note:** the parallel-array "move an entry" is open-coded in
  several places; a single `copyentry(dst, src)` helper covering
  name/dir/size/date/mark would prevent this class of omission (see item 8).
- **Test:** `s` → date, `/`, type a filter, confirm the date column matches
  each visible name.

### [x] 3. `deltree` leaks its skip-list when a dir has >16 undeletable entries

**Fixed.** The `999` sentinel was overloaded onto `nskip` (the allocated-string
count), so the `IF nskip <= 16` cleanup guard skipped disposal on give-up. Split
the sentinel into a separate `giveup` flag; `nskip` is now strictly the true
slot count, the cleanup unconditionally `DisposeLink`s `skip[0..nskip-1]`, and
the loop terminator / "dir stays behind" test use `giveup`. Behaviour unchanged;
the leak is gone (and the theoretical out-of-bounds skip-scan the `999` could
have caused is moot now too). Compiles clean, staged to FS-UAE.

_Original finding:_

- **Where:** `deltree` `cfile.e:2605-2623`.
- **Symptom:** When `skip[0..15]` are all allocated and another entry fails,
  `nskip` becomes `999`; cleanup guards with `IF nskip <= 16` and never
  `DisposeLink`s the 16 `String(108)` slots. Same on the `String()=NIL` OOM
  path. Bounded (~1.7 KB), rare, reclaimed at program exit.
- **Fix:** Free whatever was allocated regardless of the `999` sentinel. Track
  the real count separately, e.g. keep an `nalloc` that only counts successful
  `String` allocations and dispose `skip[0..nalloc-1]` unconditionally; or
  before setting `nskip := 999`, cap a local `freed := IF nskip > 16 THEN 16
  ELSE nskip` and loop to `freed-1`.
- **Test:** Hard to trigger naturally; a directory with 17+ delete-protected
  files, or inspect via a unit-style harness.

### [ ] 4. Recursion buffer inconsistency (stack pressure)

- **Where:** `arccachetree` `cfile.e:2870` uses stack `child[CPATHLEN]` /
  `mem[CPATHLEN]`; siblings `copytree`/`deltree`/`treestat` deliberately use
  heap `String(CPATHLEN)` ("E cannot size its stack for deep recursion",
  `cfile.e:2480`). Similar stack buffers in the extract/rebuild helpers.
- **Symptom:** ~600 B/frame × depth-20 ≈ 12 KB of stack on the copy-in-folder
  path; fine on a generous stack, risky on a small default CLI stack. Capped at
  depth 20, so no runaway.
- **Fix:** Move `child`/`mem` in `arccachetree` to `String(CPATHLEN)` from the
  heap, matching the sibling routines, and `DisposeLink` on exit. Consider a
  `$STACK` cookie / stack assertion at startup as belt-and-braces.
- **Test:** Copy a deep (10+ level) folder into an archive; confirm no
  corruption on a low-stack shell.

### [ ] 5. Move-out from an archive bypasses the deferred (ONEXIT) model

- **Where:** `arcxfer_out` `cfile.e:3487`, `3550`, reload at `3565`.
- **Symptom:** A move-out deletes the member immediately (via
  `arcdeltree`/`arcdelmember`) even under `ARCWRITE ONEXIT`, and the following
  `loadarchive` force-commits *all* other pending deferred edits first
  (`cfile.e:1030`). No data loss, but a single move-out silently flushes the
  whole "modified" session early — inconsistent with `Del`, which defers.
- **Fix (design decision, confirm intent):**
  - **Option A:** Make move-out defer too — flag the member `MST_DEL` after the
    extract succeeds, let commit remove it, instead of an immediate lha delete.
  - **Option B:** Leave as-is but document that move-out is an immediate,
    non-deferred operation (and drop the surprise early-commit by not calling
    `loadarchive` when nothing else is pending).
- **Recommendation:** Option A for model consistency, but it's the biggest
  behavioural change here — schedule deliberately, not as a drive-by.
- **Test:** Inside an archive: `Del` a file (see "modified"), then move another
  file out; verify the first deletion is still pending/committed as expected and
  the border state is coherent.

---

## Very low / edge

### [ ] 6. `arcadd` cap can mis-flag the previous member

- **Where:** callers do `IF amcnt[p] > 0 THEN st[amcnt[p]-1] := MST_ADD` after
  `arcadd` (e.g. `cfile.e:6584`, `3648`, `2862`); `arcadd` bails without
  incrementing on the `MAXMEM=1500` cap or `String()=NIL` (`cfile.e:941-947`).
- **Symptom:** At the cap/OOM, the flag lands on an existing member. Status-only
  corruption; needs ~1500 members or OOM.
- **Fix:** Have `arcadd` return the new slot index or `-1`; callers set the
  status only on a real slot. Removes the "trust amcnt-1" assumption everywhere.

### [ ] 7. Config rewrite truncates files > 4 KB

- **Where:** fixed `New(4096)` / `Read(...,4095)` in `loadconfig` (`257`),
  `saveconfig` (`388-390`), `configensure` (`545-547`).
- **Symptom:** A config grown past 4 KB is truncated on the pass-through
  rewrite. Practically impossible for this file, but a silent ceiling.
- **Fix:** Size the buffer from the file (`Examine` for size, or grow/loop the
  read); or at minimum detect `n = 4095` and refuse to rewrite rather than
  truncating.

---

## Cross-cutting cleanup (not bugs, prevents future ones)

### [ ] 8. A single "copy/move one entry" primitive for the parallel arrays

- **Rationale:** name/dir/size/date/mark are moved together in `sortpane`
  (`881`), `filterapply` (`6067`), and the filter save/restore (`6115`,
  `6189`). Item 2 exists because one of these forgot `edate`. A
  `copyentry(dstbase, dstidx, srcbase, srcidx)` (or a small record) makes the
  set atomic and self-documenting.

---

## Suggested sequencing

1. Item 1 (data safety) — ship in the next point release.
2. Item 2 + Item 8 together (fix the symptom and the root cause).
3. Items 3, 4, 6, 7 — batch as a "hardening" pass.
4. Item 5 — schedule as a deliberate design change with its own testing.
