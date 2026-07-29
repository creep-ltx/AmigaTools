# CFile — performance roadmap

The fix campaign for `perf-audit.md` (finding IDs R/I/C/X refer there).
Shape mirrors the CCON perf ladder: staged betas, each independently
boot-testable, cheap-and-safe first, the render engine last, the mask
after the engine it multiplies. Cut a release after any beta — the
split into 0.4.1 / later gets decided as we go. (HISTORY: it began as
a point release on the 0.3.1 precedent — then the line grew disk
images, the media suite and the byte-honest bars, and was PROMOTED TO
0.5 on 30.7.26, his call; configurable-keys + user-commands moved to
0.6. Entries below keep the 0.4.1bNN names they wore when built.)

Line numbers in the audit are against `cfile.e` @ `e0f2257`; re-check
before each edit.

Legend: `[ ]` open · `[~]` in progress · `[x]` done

---

## Phase 0 — baseline (before touching anything)

- [ ] **Test assets on the Amiga side** (a one-shot shell script can
      build them): a 500-entry drawer (`gendir` of numbered files), the
      same drawer icon-heavy (every file + a `.info` sidecar), an
      ~8000-line text file, a 10–20MB binary, a 50+-member `.lha` with
      subdirs, a source tree for `t` (the AmigaTools checkout works).
- [~] **Built-in BENCH mode** — the primary instrument (stopwatch only
      for what it can't reach: whole-op feel on real media). A
      temporary CLI mode `cfile BENCH <dir> [file] [needle]` that runs
      the hot paths programmatically ×N and logs tick-timed results
      (`DateStamp()` deltas, 1/50s resolution) to
      `PROGDIR:cfile-bench.log` (Linux-readable on the dir-drive):
      pane scan (readpane ×5), pure render (drawpane ×20), the scroll
      walk (movedown across the whole listing — hand-timing this only
      measures key repeat), editor load ×3 + save ×3 (to T:), copy ×3
      (to T:), grep. Kept as the per-beta regression gate, demoted to a
      debug flag (or dropped) before release.
      **BUILT 24.7.26** (`dobench()` + helpers before `main()`,
      `BENCH` branch in parseargs, saveconfig skipped in bench mode so
      a run never rewrites the config; timing/format math proven by
      vamos harness `bmtest.e`, compiles clean, binary deployed to the
      FS-UAE install). Test assets on the drive:
      `PROGDIR:bench/dir500` (480 files + 20 subdirs, `needle` planted
      every 10th file) and `PROGDIR:bench/lines8000.txt` (424KB).
      First run, from a shell:
      `cfile BENCH PROGDIR:bench/dir500 PROGDIR:bench/lines8000.txt needle`
      — boot test pending; flip to `[x]` when the log looks sane.
- [ ] **Baseline the feel cases** (FS-UAE A1200-Stock config for CPU
      costs, dir-drive for correctness, real A1200 when the drive is
      hooked up — real FFS media is where the I-class items show at
      all; BENCH numbers where the mode covers it, stopwatch for the
      rest):
      1. enter the 500-entry drawer (sort cost)
      2. hold Down through it (scroll cost)
      3. copy the big binary (throughput)
      4. `e` the 8000-line file: open, then save (edload/edsave)
      5. bulk delete in the icon drawer, everything marked (C3)
      6. `t` a substring over the source tree (grep)
      7. copy 20 marked members out of the big .lha (I4)
      8. `:` run `list` (console feed)
- [ ] Keep numbers in a table at the bottom of this file, one column
      per beta — the campaign's closing table writes itself.

---

## 0.4.1b1 — one-liners and dead-cheap wins (I1, C3, X1, X2, I7a)

All low-risk, no structural change; one beta, one boot pass.

- [~] **I1** `CBUFSZ` try-ladder: allocate 256K → 64K → 16K at startup,
      keep what succeeds (footprint note: small-RAM machines must still
      run). Copy/Esc/progress logic untouched — it's already per-chunk.
- [~] **C3** nested-IF the eager ANDs: `nameismarked` 973, the
      `infodup` call sites (doxfer 4397, dodelete 4698/4722, dorename
      7575 — also stop calling it after `stopped`).
- [~] **X1** `freebytes` >2GB guard: replace the overflowing
      `Div(2147483647, bpb)` with a shift compare (bpb is a power of
      two).
- [~] **X2** tab stops: `Mod(col,8)` → `(col AND 7)` in textrow 4977,
      edload 5689, editfile ~5838, confeed 6247.
- [~] **I7a** PIPE: reads 256B → 4KB in arcrunprog 3334 / livepipe
      6299 (parsers are split-safe byte machines already).
- [ ] **Boot gate:** big-file copy visibly faster on real media (or at
      least unchanged on dir-drive); icon-drawer bulk delete no longer
      stalls; tabs render identically in viewer+editor (a tabbed source
      file A/B'd against 0.4); free-space row sane on the largest
      volume available; pack/unpack progress still ticks.
      **Bench gate PASSED 24.7.26:** all rows within ±2% of baseline
      (b1 column in the table) — no regressions. copy=93 unchanged on
      the dir-drive is the audit's emulation caveat measured: packet
      round trips are free there, so I1/I7a verify on real FFS only.
      Eyeball items above still pending; then flip to [x].
- [x] **b2 instrument tweak:** DONE — log the chosen `cbufsz` in the bench
      header so the ladder's pick is visible per config.

## 0.4.1b2 — packet batching, self-contained (I2, I5, X3, X4)

**BUILT + DEPLOYED 24.7.26** ($VER 0.4.1b2, live + `cfile-041b2` A/B
copy; cbufsz now in the bench header). Harness `b2test.e`: ALL GREEN —
edsave byte-identical across exact-fit/one-over/giant-line/empty-line,
grep scanner equal to old everywhere except two DELIBERATE differences:
(1) a match past column 200 is now found (display still truncates);
(2) **a real 0.4 bug found by the harness: the old scanner recorded a
PHANTOM DUPLICATE hit (lineno+1, same text) for any file whose last
line matches and ends with LF** — StrCopy with length 0 left the
previous line's text in place for the end-of-buffer pass. The real-HW
log proves it in the wild: "136 hits" over 68 needle files = every one
double-counted. **Next bench run: expect grep hits 136 → 68 — a fix,
not a regression.**

**STOCK BENCH LANDED 24.7.26 (b2 column): edsave 2506 → 373 ms (6.7×),
grep 7800 → 4380 ms (1.8×) with the honest 68 hits; everything else
within noise.** And the new cbufsz header line earned its keep on day
one: it read **16384** — the I1 ladder had silently fallen through,
because **E-VO `String()` returns NIL for any size ≥ 32767**
(vamos-proven, `strsz.e`; the E-string header's length fields cap it).
copybuf is a raw byte buffer, so the ladder now allocates with `New()`
— respun and deployed as **build 0.4.1b3** (build numbers free-run
like ccon's; this is still campaign stage b2). Stock copy stays ~16KB
irrelevant on dir-drive; the real-FFS copy verdict needs the b3 build
on the A1200.

- [~] **I2** `edsave` buffered: assemble lines into copybuf, flush at
      ~CBUFSZ, one final flush. Error path must still report a failed
      Write and not lose the tail. (Also serves archive-member edits
      and `n` new-file saves.)
- [~] **I5** `grepwalk` single-pass: read once, sniff from the buffer's
      first 512 bytes, scan the raw buffer with a folded-needle
      first-char skip, build display strings only on hits, count LFs
      incrementally. Same double-open fix (cache the sniff) in
      `bulkview` and `dounpack` while in there.
- [~] **X3** buffers to `New(size+1)` (viewfile/scanbuf/ansipage);
      nested IF in `prevline`.
- [~] **X4** `loadarchive` capture: size-to-fit read (slurpfh-style)
      instead of the fixed 128KB cap.
- [x] **Harness gate (vamos, before booting):** DONE (b2test.e) — grep rewrite proved
      against the old one — same match set + line numbers over a test
      tree with edge files (match at byte 0, at EOF, no trailing LF,
      exactly-512B file, binary that fails sniff).
- [ ] **Boot gate:** 8000-line save near-instant; `t` over the source
      tree visibly faster with identical results; view/edit round-trip
      of a no-trailing-LF file unchanged; enter the biggest archive on
      disk (member list complete).

## 0.4.1b3 — ExAll in the walkers (I3)

Own beta: touches every directory read, needs the fallback proven.

**BUILT + DEPLOYED 28.7.26 as build 0.4.1b4** (numbers free-run; this
is campaign stage b3): live `cfile` + staged `cfile-041b4` in the
FS-UAE drawer. Compile clean (opentry UNREFERENCED = pre-existing).

- [~] One `exallscan` helper — landed as a caller-frame ITERATOR
      (`eascan` object, `easbegin/easnext/easend`) instead of a hook:
      E calls through proc pointers awkwardly, and stack-state means
      recursive walkers can nest scans for free. ExAllControl via
      AllocDosObject, 16KB buffer, `ED_COMMENT`, **ExNext fallback**
      when the FIRST ExAll call errors (nothing served yet = no
      duplicates); abort drains remaining batches instead of
      depending on V39 ExAllEnd. No short-circuit ANDs (the readdir
      rule, kept).
- [x] `readdir` wired — **BOOT-GREEN 28.7.26** (build 0.4.1b4:
      listings identical on dir-drive/FFS/RAM:, verbs regression-
      eyed — the ExAll arm's first live run, passed).
- [~] **ALL seven remaining walkers converted** (build 0.4.1b5,
      BUILT + DEPLOYED 28.7.26, staged `cfile-041b5`): `treestat`,
      `findwalk`, `grepwalk`, `copytree`, `arccachetree`,
      `arcaddstaged`, `arcrepack` all ride the iterator; per-walker
      policies preserved (abort conditions, heap path buffers,
      copytree fails on a died scan exactly as it failed on a died
      Examine; the lha command batchers keep their 600-char split).
      Leftover fib users are legitimate single-object Examines
      (pathtype, copyattribs, the i window, the archive size
      probe) — out of I3's scope. **Walker verb sweep BOOT-GREEN
      28.7.26 ("All the verbs works") — stage b3 is CLOSED: every
      directory read in the program is batched.**
- [~] **I7b** `deltree` collect-then-delete rides this build:
      DTCHUNK=100 names snapshotted per scan (heap, not the
      20-deep frame), deletes run from the snapshot, rescan ONLY on
      truncation — and a complete (untruncated) snapshot ends the
      level with no confirming rescan at all. Skip-list, abort,
      giveup, sawany/invisible-entries policies all preserved.
- [x] **Harness gate (vamos, b3test.e): ALL GREEN 28.7.26** — A/B
      listing old-ExNext vs exallscan IDENTICAL over a 132-entry
      scratch dir (name/type/size/days/mins per entry), running on
      the FALLBACK road (vamos rejects ExAll — so the fallback is
      the live-tested arm, and vamos CANNOT test the ExAll arm: the
      ls-0.3.4 lesson says name that plainly). Chunked delete with
      DTCHUNK forced to 10: 14 truncation rounds, 154-file tree
      fully removed, empty-dir and nested arms exercised.
- [ ] **Boot gate (the ExAll arm's FIRST live run is here):**
      listings identical (names, sizes, dates, comments — the `c`
      comment column is why ED_COMMENT) on dir-drive AND a real-FFS
      partition AND RAM:; find/grep/`=`/copy/delete all
      regression-eyed; bulk delete faster on FFS; bench scan row on
      Stock config expected ~unchanged (sort C1 dominates at stock
      CPU — the ExAll win is real-media packets, the A1200 shows it).

## 0.4.1b4 — the algorithm swaps, harness-proven (C1, C2, C4, C5)

Both big items are pure functions of their inputs — prove them under
vamos against the old code before any boot (the masktest discipline).

**BUILT + DEPLOYED 28.7.26 as build 0.4.1b6** (live + staged
`cfile-041b6`). Harness `b4test.e`: **ALL GREEN** — sort A/B over 18
configs (2/37/500 entries × all 3 sort modes × sortrev on/off ×
unique/tied key sets: exact order match vs the old sort on unique
keys; sortedness + permutation + tier invariants on ties), edload
A/B byte-identical over a 9-file corpus (tabs at 0/mid/8-boundary/
EOL, CRLF + lone CR, no trailing LF, empty file, blank runs, >EDLINIT
lines, a 600-byte randomized mix).

- [~] **C1** `sortpane` → Shell sort (Knuth gaps), `entbefore` +
      `swapentry` kept as-is. The folded-key second step stays in
      reserve if stock numbers still drag.
- [~] **C2** `edload` line-at-a-time: measure pass (tabs to 8-stops,
      CRs dropped), ONE edgrow to final width, CopyMem for the clean
      runs, ONE SetStr per line — the per-CHARACTER edgrow+SetStr
      call pair is gone.
- [~] **C4** date column memo — DEVIATION from the spec, for the
      better: `datestr` is a pure function of the datekey, so the
      per-slot cache is VALUE-keyed (edds 8B string + eddk tag =
      the key it was computed for). A reordered slot mismatches its
      tag and self-heals on the next draw — so swapentry/snapentry
      DON'T carry it and the esize lesson has no new exposure.
      Repaints and scrolls stop calling DateToStr entirely.
- [~] **C5** `arcdirseen` scans BACKWARD (member lists name same-dir
      entries in runs, so the just-added dir answers on the first
      probe); readarcdir's root-level filter NESTED (the eager
      AND/OR ran ncprefix for every deleted member and every member
      at root).
- [x] **Boot gate GREEN 29.7.26 — "the drawer is instant now!"**
      (his words). 500-entry entry near-instant at stock CPU, editor
      pause gone, date-sort scroll smooth, archive nav snappy, sort
      order matches. Stage b4 CLOSED. (A bench run for the closing
      table can happen any time — the staged builds keep the
      columns fillable.)

## 0.4.1b5 — double-work cleanups (R5, I6, R8 smalls)

Draw-count reductions with existing machinery; no new blit paths yet.

**BUILT + DEPLOYED 29.7.26 as build 0.4.1b7** (live + staged
`cfile-041b7`). Pure draw-path restructuring - no pure functions to
harness under vamos; the gate is visual, stated honestly below.

- [~] **R5** `frow` draws only the four border cells on pane rows
      (verified: no ctab art piece lands on rows 6..nrows-4, and the
      composer writes only those columns there); `selectbyname` split
      into `placebyname` (locate+centre, NO draw) + the old shape;
      `rescan` places both cursors before its one `drawall`; ALL
      seven refreshall-then-selectbyname doubles converted to
      `refreshsel(p)` (edit-save-in-archive, arc-edit re-add, arcnew,
      arcnewdefer, donew's file arm, the two marked-set conditionals).
- [~] **I6** `refreshpane(p, place)` - one-sided refresh; the other
      pane re-reads only on a same-directory match, else its pixels
      are untouched; border row redrawn for the field slots. Wired
      into dorename + donew's CreateDir arm ONLY - the verbs whose
      debris is border-row prompts. Delete/copy KEEP refreshall on
      purpose: their progress box paints over both panes and
      refreshall's full-frame erase is what removes it.
- [~] **R8** drawrow: ONE fill per row (bar rows were filled black
      then again in the bar pen); drawinput's up-to-80-space pad
      Text -> one RectFill; switchpane drops its no-op drawpaths;
      togglemark repaints only the FLDW slot via new `drawfield(p)`
      (the full row ran markcount TWICE per Space press).
- [x] **Boot gate GREEN 29.7.26.** Border art intact, verb screens
      correct, one-sided verbs leave the other pane untouched,
      mark-run smooth, progress box still erased. Stage b5 CLOSED.

## 0.4.1b6 — the scroll engine (R1, R7, R3, R4)

One shared helper, wired surface by surface, each boot-tested before
the next (the inside-lha staging rhythm).

**Build 0.4.1b8 (29.7.26, DEPLOYED + staged): scrollone + the PANE
wired** — surface-by-surface per this section's own rhythm; R7/R3/R4
follow after the pane's boot verdict.

- [~] **`scrollone(x, y, w, h, dy)`** — landed: one ScrollRaster of
      the rectangle by ±one cell row (dy=+1 up, -1 down).
- [x] **R1** pane: moveup/movedown edge crosses = one blit + TWO
      drawrows (the entering row + the de-barred old selection row;
      visrows=1 guarded); jumps >1 keep `drawpane` (pagemove, the
      filter, selectbyname untouched). **BOOT-GREEN 29.7.26 —
      "scrolling is smooth!"**
- [x] **R7** find/search results — BOOT-GREEN 29.7.26 (build 0.4.1b9,
      drawfindpage split into findrow (single fill per row - the R8
      double-fill on the selected row died with it) + the pane's
      exact rule: sel-only = 2 rows, vtop ±1 = one blit + 2 rows,
      jumps keep the full page.
- [x] **R3** viewer — BOOT-GREEN 29.7.26 (build 0.4.1b10): new
      `viewrow` Texts the populated prefix + RectFills the tail
      (textrow reports its width via out-param; hex keeps its gap
      prefill); ±1 scroll = one blit + ONE viewrow (down-row offset
      via textskip / +16*rows in hex); pages/jumps keep the full
      repaint; ANSI mode untouched (art rows, own palette).
- [x] **R4** editor — BOOT-GREEN 29.7.26 (build 0.4.1b11): edrow =
      prefix + one tail fill (ncols prefill loop gone; cursor cell
      guarded past line end); vertical edge cross = full-rect blit +
      2 rows (horizontal edxoff shifts keep edpage - every row
      moves); Enter split = sub-rect blit DOWN below the cursor + 2
      rows (bottom-edge split = full-rect blit up); both joins =
      sub-rect blit UP + the joined row + the revealed bottom row.
- [x] **Boot gates: ALL FOUR SURFACES GREEN 29.7.26** (pane, find
      list, viewer text+hex, editor incl. splits/joins at edges and
      the save round-trip). STAGE b6 CLOSED — every scrolling
      surface rides scrollone. (Fallback-WINDOW overlap caveat noted,
      untested — own-screen is the shipping config.)

## 0.4.1b7 — console model-first (R2)

The one structural rewrite; isolated on purpose.

**BOOT-GREEN 29.7.26 (build 0.4.1b12) — STAGE b7 CLOSED.**

- [~] `confeed` is model-first: the old parser verbatim with draws
      turned into model writes + dirty-range marks; settle ONCE per
      chunk (pend >= visrows = grid rebuild from model, zero blits;
      else one ScrollRaster of pend + conrow the dirty rows, prefix
      Text + tail fill). The old renderer is KEPT verbatim as
      `confeeddirect`, serving the NIL-model fallback and the
      CMAXL-cap churn corner via a `cmfull` latch (loop-top guard:
      on the last model row the direct path takes the remaining
      bytes mid-chunk, old behavior exactly).
- [ ] **Boot gate:** `:` `list`, `dir`, a full pack and unpack —
      output identical to 0.4 (A/B screenshots), scrollback intact,
      progress markers still parsed (arcrunprog reads the pipe, not
      the console — unaffected, but eye it), Esc/prompt rows undamaged.

## 0.4.1b8 — plane masking (R6)

Last, because it multiplies every blit the campaign just created.

**BUILT + DEPLOYED 29.7.26 as build 0.4.1b13** (live + staged).

- [~] Masks landed as SCROLL-BLIT-ONLY (tighter than the spec, on
      purpose): `panemask` %101 + `flatmask` %001 computed at openui
      only when own-screen AND GetBitMapAttr says planar-standard
      (RTG floor; pubscreen fallback resets both to 255); scrollone
      gained a mask param (all 13 call sites wired: pane=%101,
      findlist/viewer/editor/console=%001), the console settle rides
      it (pend rows in one masked blit) and connl's direct-path blit
      brackets too. Text and ALL fills stay full-depth - surface
      ENTRY repaints are the unmasked scrub that keeps the ccon
      narrowing rule structurally true (a masked entry fill would
      have left another surface's plane-1 droppings alive under the
      panes; not worth the invariant surface for fill-speed).
- [x] Narrowing audit: entry repaints unmasked by construction (see
      above) - nothing to re-confirm per surface.
- [x] **Boot gate GREEN 29.7.26** (surface-flip tour clean, ANSI
      full-colour). His follow-on find: the viewer's FIRST page
      visibly filled top-to-bottom at speed — always true, finally
      visible. **R6 coda (builds b14+b15):** viewer entry got the
      missing full-depth scrub (one blit erases the prior surface,
      and it makes masked rendering safe); edrow/conrow render
      masked (their entries already scrub); and — his "hunt for
      instant" — viewer rows went JAM1: rows never change in place
      and always land on clean background (entry scrub, the masked
      page-fill before a full redraw, or a blit-vacated row), so a
      first page = ONE scrub + 22 glyph-only one-plane Texts, zero
      tail fills. Console/editor rows keep JAM2 (they overwrite in
      place). And b16 (his find on the 2000/8000-line corpus): the
      viewer's Ctrl+Up/Down jumps WALKED the step loops - a
      full-file line scan to reach offsets both ends already know
      (0 and the load-time vmax) - now direct assignments; Shift
      pages keep stepping. **b15+b16 GREEN 29.7.26 ("that's more like it") - STAGE b8 + codas CLOSED. THE CAMPAIGN'S CODE IS COMPLETE: every R/I/C/X item landed or accounted for, builds b1-b16, every stage boot-green.**
- [ ] fallback pubscreen run entirely unmasked (untested);
      real-A1200 scroll feel re-measured (drive not hooked up).

## The bar chapter (post-campaign, 29-30.7.26, builds b17-b21)

His ask, verbatim: a true byte-by-byte progress bar, "not chunks,
not per file" - the thing no Amiga file manager has.

- [x] **b17** copies: the bar already filled at PIXEL resolution -
      the chunkiness was the update rate. copyfile's chunk now
      adapts to the RUN's bytes-per-pixel (Shr(progtotal,8), floor
      16KB, cap cbufsz): one pixel per update, pixel-continuous
      across a marked set. GREEN ("works great").
- [x] **b18** lzx extract: harvest the "( run / total )" pipe
      redraws as clamped deltas. (Superseded on the primary road by
      b20; still serves the fallback.)
- [x] **b19** THE RAM-DISK BUG (his real-iron find, 8x880K ADFs vs
      2MB): copy-out staged members through T: - now stages BESIDE
      THE DESTINATION and lands files by same-volume Rename (the
      double write is gone). "Broken unpack" was fallout (PIPE: +
      T:CFile-out suffocating on the full RAM disk). GREEN.
- [x] **b20** THE BYTE-POLLER - the bar he asked for: archiver runs
      DETACHED (SYS_ASYNCH, no pipe pump), a Delay(1) poll Examines
      the file being written and progadds honest growth deltas
      against the cache's known sizes in archive order; run-done =
      EXCLUSIVE Lock on the child-owned T:CFile-out succeeds.
      Wired: arcxfer_out single-file + arcextracttree (one cursor
      across batched runs); pipe road kept as fallback only.
      **GREEN 30.7.26: "exactly what I wanted."**
- [x] **b21** ESC CANCELS ARCHIVE TRANSFERS (his ask 30.7.26: "when
      copying out (or into) an archive, Esc to cancel would be
      nice"). The detached/piped child launches under a per-instance
      NP_NAME (SystemTagList passes NP_ tags to CreateNewProc, and
      the command runs INSIDE that named process), so Esc = FindTask
      inside Forbid + Signal SIGBREAKF_CTRL_C - lha/lzx honour break
      and rebuild to a temp, so the archive itself is never the
      casualty. Wiring: arcpollrun checks Esc every tick; arcrunprog
      checks between pipe chunks plus a BOUNDED (~5s) WaitForChar
      pacing loop for silent stretches (correctness never rests on
      PIPE: supporting it); the xfer verbs arm cancelok like the
      plain-copy road. The landmine defused: async runs return
      LAUNCH-success, so every caller now checks `abort` before
      landing files (partial extracts never Rename into place),
      before move-deletes (source survives a cancelled run), and
      reloads the cache when a break may have raced a rebuild's
      finishing rename. Cancel latency: extract ~a tick; add =
      per-member at worst (per 1/5s where PIPE: can WaitForChar).
      Known window, documented in-source: Esc between a DIRECT
      replace's member-delete and its re-add leaves the member
      absent (the source file is never at risk). **GREEN 30.7.26
      ("All green!") - NP_NAME-through-SystemTagList proven on 3.2.**
- [ ] Follow-ups parked: lha/lzx ADD-side polling (archive growth,
      clamped - total compressed size unknowable); arcrename's T:
      work area onto the arcsibling pattern; the pipewc probe is
      MOOT for the poller (kept in C: as a curiosity).

---

## Release ladder (after soak)

- [ ] Soak: a day of daily-driving all verbs, both archive formats,
      dir-drive + real FFS.
- [ ] Re-run the Phase-0 table (stock config + real A1200), close the
      campaign with before/after numbers.
- [ ] Drop to `$VER CFile 0.5 (date)` (promoted from 0.4.1, his
      call 30.7.26 — the line outgrew a point release).
- [ ] CHANGELOG 0.5 entry (drafted, on main), README/readme
      touch-ups — Tobias approves copy, then mechanics: commit, tag
      `cfile-v0.5`, GH release, `cfile-0.5.lha` (cfile/cfile +
      cfile/cfile.readme).

## Deliberately NOT in this campaign

- **I4** batched archive copy-out (per-file lha spawns): real win, but
  it reshapes the collision-prompt flow — a feature-sized change that
  fits better beside the 0.5 refactor than inside a perf point release.
  Parked, not dropped.
- **R8-ansi** ANSI-viewer row index: niche path, tiny audience — take
  it only if b6 leaves appetite.
- Filter-narrowing micro-opts, running mark counters: audit says the
  paths are already healthy; don't gild them.

## Baseline / results table

BENCH rows (ms/rep from cfile-bench.log; dir500 = 500 entries, corpus =
lines8000.txt 424KB unless noted). **First stock-config baseline landed
24.7.26** — and it confirms the audit's three big claims on the first
run: scan is the O(n²) sort + ExNext, scroll ≈ draw because every step
past the first screenful is a full-pane repaint (R1), edload is C2's
per-byte call overhead. Note from that run: on the 2MB stock machine
the 424KB corpus OOMs the 4th edload (peak ~1.5MB in a fragmented
pool) — the 'not enough memory' message by the pane is that, harmless;
use `lines2000.txt` (108KB) for the editor rows on Stock, lines8000 on
configs with fast RAM. The bench now logs 'edsave skipped' when it
happens.

Stock column = run 2 (24.7.26, lines2000.txt corpus). Run-to-run
repeatability on the dir rows was ±2% (scan 26792/26760, scroll 84/82,
grep 7640/7800) — the instrument is a trustworthy gate. **Run 1's
edload figure (14640 ms/rep "for 424KB") was POISONED and is quoted
nowhere:** its reps were already OOM-failing partway (a failed edload
bails early and cheap — the same trap as ccon's b15 poisoned-verdict),
which is why run 2's honest 108KB load costs MORE than run 1's fake
424KB one. Editor + copy rows are quoted at the 108KB/2000-line corpus
for Stock; the one clean 424KB datapoint from run 1 is copy = 346 ms.

| bench row | 0.4 stock | 0.4 real | b1 | b2 | b3 | b4 | b5 | b6 | b7 | b8 |
|---|---|---|---|---|---|---|---|---|---|---|
| scan (readpane, ms/rep) | 26760 | 84 | 26672 | 26672 | | | | | | |
| draw (drawpane, ms/rep) | 80 | 12 | 80 | 81 | | | | | | |
| scroll (movedown, ms/step) | 82 | 10 | 82 | 84 | | | | | | |
| edload (108K/2000ln, ms/rep) | 12552 | 813 | 12846 | 12460 | | | | | | |
| edsave (108K/2000ln, ms/rep) | 2513 | 1213 | 2506 | 300² | | | | | | |
| copy (108K→T:, ms/rep) | 93 | 33 | 93 | 86 | | | | | | |
| grep (dir500, ms) | 7800 | 660 | 7800 | 4380¹ | | | | | | |

¹ b2 onward reports the HONEST hit count (68) — earlier columns'
timings scanned the same bytes but reported 136 via the phantom-dup
bug, so the times stay comparable, only the count changed.
² Final stage-b2 figure, from build 0.4.1b3 (the String→New ladder
respin, header confirming cbufsz 65536 on stock). The String-capped
build measured 373. Stage-b2 stock gate CLOSED; the PiStorm b3-build
run still owed (expect the edsave collapse + the first honest copy
number).

Per-unit reads worth keeping in view: edload ≈ **116 µs/byte** (C2's
per-char call chain, measured); edsave = 4000 Write packets in 2513 ms
≈ **0.63 ms/packet** (I2: a save is packet count, nothing else); copy
93 ms = 7 × 16KB chunks ≈ 13 ms/chunk (I1's lever); scroll 82 ≈ draw
80 (R1: a scroll step IS a full repaint today).

**REAL-A1200 COLUMN LANDED 24.7.26** (his A1200 + PiStorm32 Lite/CM4,
b1 binary, `Dump:` volume off the PiStorm SD). Calibrate what "real"
means here — the machine is **real chipset, sci-fi CPU**: Emu68 on the
CM4 runs 68k code beyond any 68060, while AGA/blitter/chip bus are the
physical silicon, and the SD storage is faster than period media. So
per finding class:
- **R (blits): this column is ground truth.** draw 12 / scroll 10 are
  genuine AGA numbers; scroll ≈ draw = R1 on real silicon; scrollone
  should cut a step to ~1–2 ms for every AGA owner.
- **I (packets): this column is the cleanest instrument there is** —
  with compute effectively free, whatever still costs time is
  round-trip structure. **edsave 1213 ms on a CM4 is the campaign's
  smoking gun: 4000 synchronous Writes at ~0.30 ms each; I2's
  buffering makes it two.** Grep 660 ms = I5's double-opens. Period
  storage would only make these bigger.
- **C (CPU): this column says NOTHING about real 68k silicon** — the
  CM4 flattens C1/C2 to invisibility. The stock 14MHz-020 column is
  the honest proxy; real accelerator owners (030/50, 060) sit between
  the columns (scan would still be seconds on an 030, ~1s on an 060).
  C1/C2 stay in b4 on their own merits for non-PiStorm users.
**Leverage on his machine: b2 ≫ b6 > everything else; C-class fixes
are for the rest of the userbase.** The build order stands — b2 next.

Stopwatch feel cases (real media / whole-op, where BENCH doesn't
reach): copy 10–20MB on real FFS · icon-drawer bulk delete · 20
members out of a .lha · `:` list output.

| feel case | 0.4 stock | 0.4 real | after campaign |
|---|---|---|---|
| copy 10–20MB file | | | |
| icon-drawer bulk delete | | | |
| 20 members out of .lha | | | |
| `:` list output | | | |
