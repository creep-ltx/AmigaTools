# CFile — performance audit (post-0.4)

A hunt for speed, run with the measured playbook from the CCON campaigns
(`~/Projects/AmigaReferences/`): blit COUNT is the master metric
(~34ms per ScrollRaster-class call on the target, regardless of rows
moved; a full-row `Text` ~1.3ms; a full-window `RectFill` ~23ms),
Text-ed spaces lose to `RectFill`, packet round trips dominate real
filesystems, and per-char proc calls are real time at authentic CPU
speed. All line numbers are against `cfile.e` at commit `e0f2257`
(the 0.4 release); re-check before editing.

**The emulation caveat, up front:** almost every I/O finding here is
invisible on FS-UAE dir-drives (the host filesystem absorbs packet
round trips), and the rendering findings are softened by FS-UAE's
faster-than-real blitter — the same way the blank-scroll cost hid from
CCON until the real A1200. The PiStorm A1200 with real FFS media is
where all of these surface. Do not judge a fix "not worth it" from an
emulator run.

Legend: `[ ]` open · `[~]` in progress · `[x]` done

---

## The shortlist (bang for the buck, in order)

1. **R1** pane scroll-by-one → ScrollRaster + 2 rows (every held arrow key)
2. **C1** `sortpane` O(n²) selection sort (every navigation, ×2 panes per refresh)
3. **I1** copy buffer 16KB → 64KB+ (a one-constant change)
4. **I2** `edsave` writes two packets per line (worst packet amplifier in the file)
5. **C2** `edload` ~4 proc calls per byte (editor open time)
6. **R2** console: one blit per `confeed`, not one per LF (the pre-1.2.2 CCON bug replayed)
7. **I3** ExAll batching in `readdir` (real-media navigation)
8. **R3/R4** viewer + editor scroll-by-one → ScrollRaster; RectFill the blank tails
9. **I4** `arcxfer_out` spawns lha once per file (bulk extract)
10. **R5** `drawall` paints pane interiors twice; F5 draws both panes twice
11. **R6** `rp_Mask` plane masking (multiplies every scroll fix above)
12. **C3** `infodup`/`nameismarked` eager AND = quadratic icon handling

Plus four correctness fixes found along the way (X1–X4) that cost
nothing and should ride whichever release this becomes.

---

## R — Rendering (blit count)

There is exactly ONE `ScrollRaster` call in 8174 lines (the console's,
line 6164). Every other moving surface repaints itself row by row.

### [ ] R1. Pane scroll-by-one = full 22-row repaint

- **Where:** `moveup` 2312-2325, `movedown` 2327-2340 → `drawpane`
  2057-2062 → `drawrow` 1985-2055.
- **Today:** cursor moves *inside* the window redraw only 2 rows (good).
  But once the selection crosses the pane edge, `etop` shifts by 1 and
  `drawpane` repaints all ~22 rows — ~22 RectFills + ~44 Texts per
  keystroke while holding Down through a long directory. The hottest
  interactive path in the program.
- **Fix:** when `etop` changes by exactly ±1, ScrollRaster the pane
  interior by one cell height, then `drawrow` the newly exposed edge row
  and the two bar rows. Fall back to `drawpane` for jumps >1.
- **Impact: HIGH** — every scroll step of every long listing.

### [ ] R2. Console renders one ScrollRaster per LF, Text-per-char tabs

- **Where:** `connl` 6158-6176 (the blit at 6164), `confeed` 6185-6271
  (tab loop 6239-6247); feeds `livecmd`, pack, unpack, run-binary.
- **Today:** every LF once the area is full = one full-width blit. A
  256-byte pipe chunk with 4 lines = 4 blits (~34ms each). Tabs are
  `Move`+`Text(' ',1)` per column. This is exactly the architecture
  CCON measured at 11.6× slower than necessary.
- **Fix:** `cmodel` already exists and is authoritative (scrollback
  reads it). Make `confeed` model-first: land the whole chunk in the
  model, accumulate pending scrolls + dirty rows, settle ONCE per call —
  if pend ≥ visrows rebuild the grid from the model (0 blits), else one
  ScrollRaster of `pend` rows + repaint dirty rows. The tab loop
  disappears into the row repaint.
- **Impact: HIGH** — the `:` console, pack and unpack are the most
  output-heavy surfaces in CFile.

### [ ] R3. Text/hex viewer: one-line scroll repaints all 22 rows, each a space-padded full-width Text

- **Where:** `viewfile` 5124-5313 (page loop 5199-5224), `textrow`
  4965-4986, `hexrow` 4998-5021.
- **Today:** any scroll sets `dirty` → 22 full-row Texts (~29ms+), row
  buffers pre-filled with spaces so short lines mostly Text blanks.
- **Fix:** ±1 scrolls → ScrollRaster + render only the incoming row;
  per row, Text the populated prefix and RectFill the tail.
- **Impact: HIGH** — `v` is a core verb; held-key scrolling is ~22× the
  necessary work.

### [ ] R4. Editor: edge scroll, line split and line join all repaint the full page

- **Where:** `edpage` 5533-5538, `edrow` 5504-5531, `edfix` 5541-5559;
  Enter split 5764-5783, backspace-join 5795-5811, del-join 5822-5834.
- **Today:** in-window cursor moves are 2 `edrow`s (good); crossing the
  edge, Enter, and joins run `edpage()` — 22 space-padded full-width
  Texts. Insert/delete-line is the console `L`/`M` lesson: it should be
  one ScrollRaster of the rows below + 1-2 row paints.
- **Fix:** (a) edge scroll → ScrollRaster + exposed row + old cursor
  row; (b) split/join → ScrollRaster the sub-rectangle below the cursor
  ±1 row, then `edrow` the changed row(s); (c) `edrow` Texts the used
  prefix, RectFills the tail.
- **Impact: HIGH** at authentic CPU speed, MED accelerated.

### [ ] R5. `drawall` paints pane interiors twice; F5 and friends draw both panes twice

- **Where:** `drawframe` 1849-1856 (+ `frow` 1842-1847), `drawall`
  2064-2069, `rescan` 2082-2099, `selectbyname` 2102-2114; same
  drawall-then-selectbyname double in `parentdir` 2474-2479, `dorename`
  7604-7606, `dofind` 6667-6676, `arcnew`/`donew`, `arceditdefer`.
- **Today:** `drawframe` full-window RectFills (~23ms), then Texts all
  ~31 frame rows at full width *including the pane interiors as spaces*,
  then `drawpane` ×2 paints those same interiors again — three passes.
  `rescan` then calls `selectbyname` per pane, each ending in another
  full `drawpane`: both panes drawn TWICE per F5.
- **Fix:** `frow` skips pane-row interiors (the RectFill already blanked
  them); give `selectbyname` a no-draw flag (or set esel/etop before
  `drawall`). Consider a single-pane `refreshpane` for one-sided ops
  (see I6).
- **Impact: MED-HIGH** — `drawall`/`refreshall` run after every verb and
  every viewer/editor/help exit.

### [ ] R6. `rp_Mask` is never used — the ROM's plane-mask trick applies

- **Where:** screen is own-screen SA_DEPTH 3 (1635). Console/viewer/
  editor surfaces draw pens 0/1 only → mask `%001` = the blitter skips
  2 of 3 planes (srbench: per-plane-linear, 34.8→8.8ms class). Pane/
  frame surfaces use pens {0,1,4,5} → mask `%101`, plane 1 provably
  untouched. Sites today: `connl` 6164, `drawframe` 1852, pane-area
  RectFills 6278/5738/5036/7848 — plus every ScrollRaster R1-R4 adds.
- **Fix:** compute a `basemask` per surface at openui; floor via
  `GetBitMapAttr(BMA_FLAGS)` and force `$FF` when `ownscr=FALSE` (never
  mask a pubscreen/RTG). Bracket blit sites; restore `$FF` for the ANSI
  viewer (all pens) and any full-depth overlay. Narrowing is
  structurally safe: every surface fully repaints on entry.
- **Impact: MED alone, HIGH combined** — makes every scroll fix above
  ~2-3× cheaper on real silicon.

### [ ] R7. Find/search result list: cursor move repaints the whole page

- **Where:** `drawfindpage` 6515-6544, `findlist` 6549-6598.
- **Fix:** mirror the pane rule — sel-only change = 2 rows; vtop ±1 =
  ScrollRaster + 1 row. Also drop the double RectFill on the selected
  row (same pattern as R8).
- **Impact: MED.**

### [ ] R8. Small double-draws and space-pad Texts

- `drawrow` 1991-1992 + 2021-2022: selected rows RectFilled twice —
  branch on selection before filling. **MED** (×22 per pane draw).
- `drawinput` 2194-2217: trailing pad is a `Text` of up to 80 spaces —
  one RectFill. Fires in every prompt. **LOW-MED.**
- Scrollback `liveend` 6391-6404 and help 7845-7859/7936-7941: full
  page (help: full RectFill ~23ms) per scroll line → ScrollRaster + one
  row. **LOW-MED.**
- `switchpane` 2362 calls `drawpaths()` though nothing on that row
  changes; `togglemark` 7290 redraws the full paths row for a ≤10-char
  field (and `drawpaths` runs O(n) markcount/markbytes per call) — a
  `drawfield(p)` for the fixed slot. **LOW** but on the mark-run path.
- `drawansipage` 5029-5119 re-runs the SGR parser from byte 0 and full
  RectFills per scroll row — a per-row (offset,fg,sty) index built at
  load fixes the CPU half. **LOW-MED**, niche path.
- Pen-set churn in `frow`/`drawrow`/`edrow` loops — hoist the constant
  SetAPen/SetBPen out. **LOW**, free while touching R1/R5.

---

## I — Real-media I/O (packet count)

### [ ] I1. Copy buffer is 16KB

- **Where:** `CBUFSZ=16384`, allocated once (initpanes, 208), used by
  `copyfile` 2572-2613.
- **Today:** 2 packet round trips per 16KB. 64-256KB chunks are the
  classic 2-4× throughput win on real FFS/CF/HD.
- **Fix:** try-allocate 256K→64K→16K at startup, keep what succeeds
  (the ~287KB footprint matters on small machines). Progress/Esc are
  already per-chunk and stay correct; `progadd` only paints on pixel
  growth, so bigger chunks even reduce draw calls.
- **Impact: HIGH** — one constant.

### [ ] I2. `edsave` writes two packets per line

- **Where:** 5708-5723.
- **Today:** `Write(fh, line)` + `Write(fh, LF, 1)` per line — an
  8000-line file is 16,000 filesystem round trips. The worst packet
  amplifier in the file; also runs on archive-member edits and `n`
  new-file saves.
- **Fix:** assemble into copybuf, flush at ~64KB — one Write per chunk.
  ~15 lines.
- **Impact: HIGH** (editor save on anything real, floppies especially).

### [ ] I3. Directory scans are one ExNext packet per entry — no ExAll anywhere

- **Where:** `readdir` 1305-1344; also `treestat` 2671, `findwalk` 2720,
  `grepwalk` 6685, `copytree` 2791, `arccachetree` 3186, `arcaddstaged`
  3672, `arcrepack` 3713.
- **Today:** a 500-entry dir = 500+ round trips; the recursive walkers
  multiply per subdirectory. ExAll batches dozens of entries per call —
  the classic 3-10× real-media directory-read win.
- **Fix:** one `exallscan(lock, cb)` helper (ExAllControl, 16-32KB
  buffer, ED_COMMENT) with ExNext fallback for handlers that fail it.
  Wire `readdir` first, then the walkers.
- **Impact: HIGH** on real media (readdir), MED (walkers).

### [ ] I4. Bulk archive copy-out spawns lha once PER FILE

- **Where:** `arcxfer_out` 3918-4090 (per-file loop 3989-4066).
- **Today:** 50 marked members = 50 lha loads + 50 full archive header
  walks. Directories already batch (`arcextracttree` 3520, 600-char
  command batching) — files don't, only because collision prompts
  interleave.
- **Fix:** resolve all collisions/renames first (the doxfer phase-1
  pattern already in the file), then batch members into as few lha runs
  as the tree path uses, then rename into place.
- **Impact: HIGH** for the everyday "copy a bunch of files out of an
  .lha" case.

### [ ] I5. `grepwalk` opens every candidate file twice and copies every line

- **Where:** 6685-6768 (`sniff` at 6713, re-open 6715-6717, line loop
  6720-6756).
- **Today:** sniff opens/reads 512/closes, then the grep re-opens and
  reads the whole file; then every line is StrCopy'd into `ltxt` and
  `nchas` re-derives both StrLens and folds case per char — ~3 passes
  over every byte plus a copy per line.
- **Fix:** read once, sniff from the buffer's first 512 bytes; scan the
  raw buffer with a folded-needle first-char skip loop, build the
  display string only on hits, count LFs incrementally.
- **Impact: MED-HIGH** for `t` over source trees (this is the verb's
  whole runtime). Same double-open pattern in `bulkview` 5317 and
  `dounpack` 7035/7063 (cache the sniff) — LOW each.

### [ ] I6. `refreshall` re-reads + re-sorts BOTH panes after one-sided ops

- **Where:** `refreshall` 2073-2077; ~27 call sites (rename, delete,
  edsave, archive edits…).
- **Fix:** `refreshpane(p)` where only one pane changed; refresh the
  other only when it shows the same path (`StrCmp(ppath[0],ppath[1])`).
  Pairs with R5's double-draw fix.
- **Impact: MED-HIGH** on real media (a one-file rename currently costs
  two directory scans + two sorts).

### [ ] I7. Smaller packet trims

- `arcrunprog` 3334 / `livepipe` 6299 read PIPE: in 256-byte chunks —
  bump to 4KB, the parsers are already split-safe. **LOW-MED**, trivial.
- `deltree` 2855-2960 re-locks and re-scans the dir per deleted child
  (~4-5 packets per file) — snapshot names per level in bounded chunks,
  delete from the snapshot. **MED** for bulk deletes on real FFS.

---

## C — CPU at authentic speed (algorithms & E hot paths)

### [ ] C1. `sortpane` is a selection sort: O(n²) proc-call compares on every listing

- **Where:** `sortpane` 1015-1028, `entbefore` 992-1011, `nccmp`
  910-922; runs from `readdir`/`readarcdir`/`readvolumes`/`resortpane` —
  and `refreshall` pays it for BOTH panes.
- **Today:** 500 entries ≈ 125k `entbefore` calls ≈ ~1M char-fold
  iterations per read — seconds at stock speed, every Right into a big
  drawer. ("Fine for one directory's worth" holds at ~100, not 500.)
- **Fix (either):** (a) Shell sort or binary-insertion keeping
  `entbefore` as-is (~15 lines; FFS delivers near-sorted names, so
  insertion is near-linear in practice); (b) cache a case-folded key at
  addentry time (first 4 upper bytes packed in a LONG) so most compares
  are one LONG compare, `nccmp` only on ties. `swapentry`'s 5-field
  swap is fine — selection sort's O(n) swaps was the right instinct;
  only the compare count is wrong.
- **Impact: HIGH** — the most-felt fix in daily navigation at real CPU
  speeds.

### [ ] C2. `edload` makes ~4 proc calls per byte loaded

- **Where:** 5611-5706 (char path 5691-5698, tab path 5679-5689).
- **Today:** one Read slurps the file (good), then the line builder
  calls `edgrow` + `SetStr` per character — >1M calls for a large file
  before the editor opens; visible pause even at 50KB on stock CPU.
- **Fix:** scan ahead to the LF, `edgrow` once to the final width,
  CopyMem the run (tab-free common case), one SetStr per line. Same
  structure, 10-50× fewer calls.
- **Impact: HIGH** (editor open), MED accelerated.

### [ ] C3. `infodup`/`nameismarked`: eager AND makes icon handling quadratic

- **Where:** `nameismarked` 968-976 (the AND at 973), `infodup`
  981-986; call sites `doxfer` 4397, `dodelete` 4698/4722, `dorename`
  7575.
- **Today:** E's AND doesn't short-circuit, so `infodup` runs for every
  entry (marked or not) and `nameismarked`'s `nccmp` runs even when the
  mark byte is 0. A drawer of 250 files + 250 icons, all marked:
  ~125,000 `nccmp` calls just deciding what to skip.
- **Fix:** nest the guards — three-line change, removes the whole
  quadratic term. (The codebase knows this rule — see readdir's own
  comment at 1321 — these sites missed it.)
- **Impact: MED** (icon-heavy drawers are the Workbench norm).

### [ ] C4. Per-row `DateToStr` in date-sort mode

- **Where:** `drawrow` 2042 → `datestr` 882-906.
- **Today:** every visible row of every redraw pays a DOS `DateToStr`
  library call when sortmode=2.
- **Fix:** cache the 5-char "DDMon" per entry at readdir time, or a
  one-slot memo. **Impact: MED-LOW** (date mode only).

### [ ] C5. Micro: `readarcdir` O(n²) subdir dedup; root-level `ncprefix` waste

- `arcdirseen` 1360-1368 linear-scans all added entries per subdir
  component — worst case 1500×500 folded compares per keypress inside a
  big archive. Cheapest fix: check the last-added dir name first
  (archive listings group by directory). **MED.**
- 1396: `(pl=0) OR ncprefix(...)` calls `ncprefix` for every member
  even at archive root (and for MST_DEL members) — nested IF. **LOW.**

---

## X — Correctness found along the way (free, take with any release)

### [ ] X1. `freebytes` DIVS overflow: the >2GB guard never fires

- **Where:** 1899, `Div(2147483647, bpb)`.
- With bpb=512 the quotient is 4,194,303 — past DIVS' 16-bit limit, so
  the result is garbage and the guard is dead; `Mul(nfree,bpb)` can wrap
  negative on big volumes → free-space display breaks on exactly the
  volumes `fmtbytes`' "1.9G" case wants. Fix: bpb is a power of two —
  compare with shifts instead of Div.

### [ ] X2. `Mod(col, 8)` tab stops: a DIVS per tab column, and unclamped `col` can overflow it

- **Where:** `textrow` 4977, `edload` 5689, `editfile` ~5838, `confeed`
  6247 (confeed is clamped, safe).
- In textrow/edload `col` is not clamped; a line past ~262,143 chars
  pushes the quotient past 16 bits → garbage remainder → mis-tab or
  spin. A 512KB no-LF file with tabs that passes `sniff` suffices.
  Fix: `(col AND 7) = 0` everywhere — kills the cycles and the trap in
  one token.

### [ ] X3. One-past-the-end reads from eager AND/OR (latent, read-only)

- `viewfile` 5282 reads `bp[len]`; `prevline` 4993 reads `s[-1]`;
  `grepwalk` 6728 reads `scanbuf[n]` (exact-VIEWMAX files);
  `drawansipage` 5104 reads `p[len]`. Harmless today (reads), same
  pattern as the reference's `hist[Mod(-1,32)]` guru. Cheapest fix:
  allocate view/scan buffers `New(size+1)` (slurpfh already does —
  that's why the config parsers are safe); `prevline` needs a nested IF.

### [ ] X4. `loadarchive` capture buffer caps at 128KB

- **Where:** 1258-1303 (New(131072), Read cap 1287-1294). A verbose
  `lha v` of ~1500 long-pathed members can hit the cap and silently
  truncate the member list. Size-to-fit (slurpfh-style) read of the
  T: capture file.

---

## Healthy paths — verified, leave alone

- **Progress bars** (`progadd` 2640-2660): delta-strip RectFill, paints
  only on pixel growth, DIVS-safe shift-then-divide. The one drawing
  path that already follows the playbook.
- **`fmtbytes`** 843-877: every quotient bounded. Correct.
- **Filter `/`** (`dofilter`/`filterapply`): snapshot model, no disk
  re-read, no re-sort per keystroke; its cost is the R1-class redraw,
  not FS. (Optional micro: narrow the current match set on typed chars.)
- **Archive member cache**: `lha v` parsed once per archive entry,
  navigation filters the cache — the design comment is honoured.
- **`checkabort`**: GetMsg poll per chunk, no busy-waits anywhere, no
  Delay() in the file; idle paths block in WaitIMessage.
- **Config I/O**: load/ensure once at startup, save once at quit;
  bookmarks touch memory only.
- **Per-entry slots** (`addentry` 748-761): high-watered and reused, no
  realloc churn.
- **String-kind discipline**: StringF/StrLen on plain buffers,
  StrCopy/StrAdd only on String() memory — no silent no-op sites found.
- **`nccmp`/`nchas`/`ncprefix`**: per-char inline folding, zero
  allocations — the right primitives; C1/C3 are about call COUNT, not
  their internals.

---

## Suggested campaign shape

Mirrors the CCON ladder: land the one-constant and nested-IF wins first
(I1, C3, X1, X2), then the packet batchers (I2, I3, I5, I7), then the
render engine work R1→R2→R3/R4 sharing one `scrollone(area)` helper,
bracket everything with R6's mask, finish with C1/C2 and the R5/I6
double-work cleanups. Benchmark before/after on the real A1200 — the
emulator will understate every one of these.
