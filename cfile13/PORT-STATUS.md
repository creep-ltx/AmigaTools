# CFile13 — port status

The honest ledger of the KS1.3 back-port. Forked from CFile 0.5
(main, post-b51) on 1.8.26. Two stages; nothing is claimed done
until it compiles green, and nothing is claimed 1.3-clean until the
banned-call grep says zero AND a 1.3 boot proves it.

## Stage 1 — feature cuts (things 1.3 cannot have)

**DONE 1.8.26** — 12,191 → 10,761 lines (−1,430), binary 198K →
173K, compile green, zero code references to any cut API (the
banned-grep's only hits are the cut-marker comments).

| Cut | Notes |
|---|---|
| datatypes (pictures/sounds/type-id) | done — dtcall + its StackSwap machinery whole (nothing else used it); the i window's `type:` row stays and prints `-` |
| ptreplay mod playback | done — mods hex-view like any binary |
| StartNotify auto-refresh | done — wait loop is window-port-only now; F5 untouched. Took `CreateMsgPort` with it (nport was the sole caller), which RESOLVES that stage-2 row |
| ADF mount / blank-ADF / DMS | done — ~467 lines; `.adf`/`.dms` are plain files now; ISO byte-for-byte untouched |
| recursive grep (memory, not API) | done — the results-view renderer STAYS (find/history share it), only grep's legs went |
| mark-by-pattern (ParsePattern) | done — a/A/* remain. SIDE EFFECT, accepted: `f` find lost its `#?` glob leg too (same ParsePattern), so find is substring-only. A hand-rolled matcher can win both back later if missed |
| GetVar/SetVar | done — the one site was inside the datatypes viewer; gone with it |

## Stage 2 — V36+ calls to replace with V33 roads

**DONE 1.8.26** — 10,761 → 11,021 lines, binary 176K, compile green,
banned-call grep clean (comments only). The audit sweep caught SIX
V36 calls beyond the planned table: AddPart/FilePart/PathPart (own
versions), AssignLock (→ Execute C:Assign), FindDosEntry (→ the
doslist snapshot), SetFileDate (→ hand-rolled ACTION_SET_DATE
packet), Fault (→ 24-entry error-text table), and the runcmd
CON: AUTO/CLOSE/WAIT spec (V36 con-handler options → plain CON: +
press-RETURN). Memory ladders in: cmlines (4000/500 by AvailMem),
vbwinsz (256K/64K).

**Flags to carry to the boot gate:**
1. Esc cannot break a running archiver on 1.3 (C:Run names its own
   child; FindTask misses) — degrades to safe no-op, pumps ride to
   child exit.
2. The floppy MUST ship C:Run and C:Execute (dos Execute() needs
   them on 1.3) — stock 1.3 disks have both.
3. runcmd's fallback console on 1.3 lives on the WB screen and
   waits for RETURN (no AUTO/CLOSE/WAIT in the 1.3 con-handler).
4. Async runner stages through a T:CFile-run script so the
   BACKGROUND CLI owns the output redirect (1.3 has no FH
   refcounting) — the arcpollrun Lock-test semantics survive.

| 2.0+ call (sites) | 1.3 replacement | Status |
|---|---|---|
| `ExAll` (~5 call sites) | `ExNext` loop | not started |
| `OpenScreenTagList` | `OpenScreen` + `NewScreen`, `GetScreenData` for WB-clone sizing | not started |
| `OpenWindowTagList` | `OpenWindow` + `NewWindow` | not started |
| `LockPubScreen`/`PubScreenStatus` | cut — fallback becomes a plain window on the WB screen | not started |
| `AllocDosObject(DOS_FIB)` (~7) | `New(sizeof fileinfoblock)` (E New is longword-aligned) | not started |
| `SystemTagList`/`System` (~4) | `Execute()` (V33; output fh works) | not started |
| `DateToStr` | own days-since-1978 formatter (mind the 16-bit `Div` trap) | not started |
| `NameFromLock` | `ParentDir` walk + `Examine` names | not started |
| `SameLock` | compare `fl_Task` + `fl_Key` | not started |
| `LockDosList`/`NextDosEntry` | `Forbid` + RootNode→DosInfo BCPL walk | not started |
| `CreateMsgPort` | — | RESOLVED: gone with auto-refresh (nport was the only caller) |
| `CreateNewProc` (1) | avoid needing it (site to be examined) | not started |
| `GetBitMapAttr` (guarded ≥V39 already) | guard stays; on 1.3 the branch never runs | inherited from b51 |

## Gates

- **Compile:** `ecompile cfile13.e cfile13 LARGE` → "no errors",
  after every subsystem.
- **Banned-call grep:** zero code references to the stage-1 cut
  list; after stage 2, zero references to every call in the table
  above.
- **Boot (the only gate that counts):** FS-UAE A500/KS1.3 config —
  needs a 1.3 Kickstart ROM on the laptop (NOT yet set up); then
  real hardware for releases.
- **Regression along the way:** until stage 2 completes the binary
  still needs 2.04+; it should behave exactly like CFile minus the
  cut features, and can be smoke-tested on the existing 3.2 setup.

## Milestones

1. Stage 1 green: compiles, cut features absent. DONE 1.8.26
   (3.2 smoke-run still wanted). ← now: stage 2
2. Stage 2 green: banned-call grep zero, still runs on 3.2.
3. FIRST 1.3 BOOT: panes + navigate + copy on a booted FS-UAE
   KS1.3 floppy — the screenshot that answers the forum thread.
   **FIRST RUN 1.8.26: IT CAME UP.** 0.1b2 on his FS-UAE A500/1.3
   — no guru, panes drew, letters worked. Two soft bugs found by
   the boot, both 1.3-lore classics:
   (a) "Please insert volume PROGDIR" requester at startup —
   PROGDIR: is a V36 assign; config moved to S:cfile13.config,
   bench log to T:. FIXED in 0.1b3, on the ADF.
   (b) Arrow keys dead — on 1.3, requesting IDCMP_VANILLAKEY
   makes Intuition swallow every untranslatable key; the
   "falls through as RAWKEY when both flags set" behavior is
   V36. FIXED in 0.1b4: RAWKEY-only windows + raw→char
   translation through console.device unit -1 RawKeyConvert
   (keymap-honest — setmap s keeps åäö) behind a central input
   shim (waitim/pollim; all 11 loops + both GetMsg pumps
   converted); console opened via amigalib createPort/createExtIO
   — the CBoot road, his pointer. One code path, all OS versions.
   (c) RAM: shows 0K free and the copy precheck would refuse
   copies into it — the ram-handler (1.3 AND 3.x) reports itself
   permanently 100% full because it grows on demand. FIXED in
   0.1b5: when a full-report comes from the volume the handler
   hardcodes ("Ram Disk"), freebytes answers AvailMem(0) — free
   memory IS the RAM disk's free space. Candidate to graduate to
   main CFile (3.x shares the trait, just less painfully).
   (d) Copy and delete visibly wipe the whole screen at 7MHz —
   NOT a port bug: big CFile's refreshall() (full RectFill +
   every frame row) runs after every transfer verb, invisible on
   fast machines. His standing directive: "redraw the entire
   screen as little as possible, only what actually changes."
   FIXED for copy/move/delete in 0.1b6: refreshpanes(boxed) —
   re-read, restore only the THREE art rows the progress box
   straddles (frow = 4 cells/row), redraw pane content + paths
   row. Rename already rode refreshpane and was clean.
   FOLLOW-UP: ~17 more refreshall() sites (archive verbs, iso,
   unpack/pack) to audit one by one after the boot proves b6 —
   the same box-only-debris argument applies to most.
   BOOT-DISK NOTE (his question, answered 1.8.26): c:MakeDir is
   droppable (CFile13 only uses ROM CreateDir; it also self-creates
   and self-assigns RAM:T / RAM:Env via its own road and drops them
   at quit) — but c:Assign MUST stay on the disk: the 1.3 assign
   road IS Execute('assign ...'). Startup-sequence can shrink to
   stack/setmap/cfile13 if T:-after-quit is not wanted.
   0.1b6 ON THE ADF (with 68000 lha/lzx + UnZip 5.12 + C:Execute
   added same day). BOOT-PROVEN same day through b13; the evening
   session (all his boots, one find per build):
   b7 RAM: device-vs-volume head ("RAM:" start path showed 0K);
   b8 held-fault in the editor (failed save looked like nothing) +
   L:Disk-Validator onto the disk (floppy writes);
   b9 quietopen for the PIPE: probe (insert-volume requester);
   b10 runner diagnostics (temporary);
   b11 THE PACK FIX: livepipe had NO fallback - no PIPE: meant
   dopack/dounpack ran nothing at all; now runs synchronously
   captured to T:, poured through the same console feed. PACKING
   ON 1.3 PROVEN (LhA 1.38 - the 2.15 build was an OS2.0+ program,
   utility/gadtools imports, died mute; 1.38 is dos.library-pure);
   b12 lzx low-memory flags (-M64 -bi8 -bo16) - NOT ENOUGH:
   b13 verdict accepted + documented: LZX's encoder cannot fit in
   a 1MB machine with CFile13 resident; extraction expected fine;
   pack with lha (period-accurate). Diagnostics stripped.
   Boot-disk saga same evening: FS-UAE floppy WRITE OVERLAYS
   (.sdf) served stale tracks over every swapped ADF - error 121 +
   "Disk corrupt" with a provably clean image; fixed for good with
   writable_floppy_images=1 (plus launcher restart). Startup is
   his minimal four lines (echo/stack/setmap/cfile13, synchronous
   by choice); Echo aboard; UNLZX, SetMap.info, Makedir removed;
   cfile13.readme on the disk documents everything.
4. Memory pass: measure on 1MB, set MAXENT/buffer knobs from data.
   **1MB TARGET MET (1.8.26, measured):** on his A500/KS1.3 config
   (confirmed 1MB: 512K chip + 512K slow), CFile13 0.1b6 runs with
   462K free — code 167K + copybuf 64K (ladder-picked) + screen 60K
   + OS/shell/handlers ≈ 562K in use. No knob changes needed for
   1MB. The 512K stretch (chip_memory=512, slow_memory=0) remains
   unattempted — the ladders' 16K-copybuf/500-line-console floors
   exist for exactly that boot.
   **512K ATTEMPT #1 (0.1b14, 1.8.26, awaiting boot):** the first
   512K try ("can't open UI") died because the ladders' floors
   never triggered — 64K copybuf still ALLOCATES on 512K, then the
   60K screen starves. b14 adds free-memory-below-1MB rungs across
   the board: copybuf → 16K, console → 200 lines (16K), viewer
   window → 16K, editor line table starts at 1024 slots (edensure
   doubles on demand, its jump-to-8192 minimum retuned), and the
   screen drops to DEPTH 2 when chip is under 256K free — 40K
   instead of 60K and a third faster blits; pens remap (dirs green,
   errors yellow), the 3.x plane-mask trick now keys off depth too.
   Zero cost on 1MB+ (all rungs conditional). Expected 512K look:
   4 colours, ANSI art viewing miscolours (pens 4-7 alias down on
   2 planes) — cosmetic. FS-UAE config A500-512K.fs-uae created
   (chip 512 / slow 0 / direct writes / 1.3 ROM). lzx: cannot pack
   even on 1MB (encoder appetite, b13 verdict) — on 512K it is
   simply out of scope.
   **512K BOOT ACHIEVED same evening (b14): panes up, 19K free.**
   The depth-2 screen came up with dirs in colour 2's leftover
   bright green ("super ugly" — his verdict, correct); b15 gives
   depth-2 the SAME palette the full screen wears (colours 2/3 :=
   the depth-3 blue/magenta of pens 4/5), so 512K looks like 1MB
   minus four colours of ANSI art. 19K headroom reading: browsing/
   copy/view fine; first ':' costs the 16K console model; lha
   packing will be right at the edge; RAM: is nearly a no-op. The
   remaining knob if more room is ever needed: MAXENT 500→200
   (~24K of BSS) at the price of 200-entries-per-directory.
   **b16 (his pick from the squeeze menu):** BENCH stripped whole
   (dev scaffolding; globals, parser leg, main branch, the whole
   section - binary 180K → 176K) and the 512K copybuf rung retuned
   16K → 8K. Expected 512K headroom: ~19K → ~31K. The bigger
   knobs (WB-screen reclaim +40K, MAXENT +24K) stay on the shelf.
   **b17 (his compromise):** MAXENT 500→300 (compile-time, both
   configs; the seven entry arrays 22K→13K, readme documents the
   300 cap) and the 512K scrollback rung 200→100 lines (8K model).
   With b16's cuts: expected 512K headroom ~19K → ~40K+. Shelf
   still holds: WB-screen reclaim (+40K, costs the fallback
   shell), depth-1 emergency rung (+20K).
   First real data (1.8.26, his avail before/after on the 64MB 3.2
   setup): 641K total = 61K chip (the screen, exactly the 640x256x3
   bitmap) + 581K fast, OF WHICH ~256K is copybuf self-sized for a
   big machine (the AvailMem ladder already drops it to 64K/16K on
   small ones) and ~173K+BSS is the binary. Projected idle on 1MB:
   ~300-350K. The two LAZY landmines to defuse for 1MB: console
   scrollback cmodel = CMAXL 4000 x ncols = 320K on first ':' (needs
   an AvailMem ladder like copybuf's, ~500 lines on a small box);
   viewer window VBWIN caps at 256K per big view (same treatment).
5. Release artifact: a ready-to-write bootable .adf.
