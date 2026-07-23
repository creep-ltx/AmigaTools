# CCON changelog

CCON — an LTX console handler for AmigaOS: a mounted DOS handler
speaking the packet protocol, hosting any client, with the one feature
stock V47 `CON:` cannot do — **output scrollback**. It can also be
mounted as the system `CON:`/`RAW:`.

Beta build numbers (e.g. 1.2b16) are in parentheses as references.
Dates are release/build dates. 1.0, 1.1, 1.2, 1.2.1 and 1.2.2 are
released and tagged.

---

## [1.2.2] — 2026-07-23 (tag `ccon-1.2.2`)

The speed release. It opened with a benchmark reading CCON at 11.6x
slower than stock CON: and closed, the same day, with CCON 4x FASTER
than stock under render barriers — and the only console tested whose
barrier numbers match its unbarriered ones. Three engine changes,
each proven by a Linux-side harness before it touched the machine,
each boot-verified after (builds 1.2.2b1–b4). The benchmark written
to measure it, conbench, grew into its own tool in this collection.

### Changed
- **Rendering is model-first now** (b1). A write's bytes land in the
  scrollback model, and the screen catches up with at most ONE
  scroll blit per write — or none at all when a whole screenful (or
  a form feed) went past, in which case the grid is rebuilt from the
  model and the form feed's full-window clear is simply gone. 1.2.1
  paid one full-window blit per scrolled ROW, at ~34ms each on the
  measured target; a 4K burst paid fifty-one of them, now it pays
  zero.
- **The prompt no longer taxes every write** (b2). Erasing the
  editor's cursor blip used to repaint the whole prompt row under
  each arriving write; when the input line is empty it now repaints
  exactly the one cell the blip occupies. The per-write overhead
  dropped from 1.85ms to 0.55ms — More's keystroke echo territory.
- **Writes are answered ahead of the pixels** (b3/b4). A write's
  bytes are copied and the writer released at once; rendering
  follows within a frame (20ms), and bursts pool so many lines share
  one blit. This is the bargain stock CON: and ViNCEd have always
  made, made here with the ordering kept honest: reads (More's
  cursor-position handshake included), mode switches, keystrokes,
  selection, paste, resize, iconify and close all settle pending
  output first. Writes over 4K, and consoles mounted with no
  scrollback model, keep the fully synchronous path. Output still
  freezes while you drag a selection.

### Numbers
On the same A1200/030, same 640x246 window, same day: the original
nine-test conbench suite took 1.2.1 288.68 seconds and takes 1.2.2
2.42. With full render barriers — the measure no write-behind buffer
can hide from — the extended suite reads CCON 18.46s, stock CON:
74.16s, ViNCEd 111.68s.

### Notes
- Unbarriered benchmark numbers are now optimistic for CCON exactly
  as they always were for stock and ViNCEd; conbench's SYNC mode is
  the honest comparison.
- The measured remaining gap to stock is a single number: one
  full-window ScrollRaster costs ~34ms against stock's ~17ms
  per-line render under barriers. Invisible in use (bursts batch),
  and a candidate for a future look at the scroll primitive itself.

## [1.2.1] — 2026-07-23 (tag `ccon-1.2.1`)

A point release with no new features: the findings of a third read of
the source (`audit3.md`, worked per `audit3-roadmap.md`), applied. Two
of them could corrupt memory.

### Fixed
- **An iconified window came back at the wrong size, and could corrupt
  its own scrollback doing it.** Restoring rebuilt the window from the
  size in the original open string rather than the size it actually had,
  so a window you had resized returned to its first shape — and the
  transcript, which is stored at the old width, was then read at the new
  one. Restore now returns the window exactly as you left it, position
  and all.
- **A tall window with a small `LINESn` could write past its own
  scrollback buffer.** The ring is now always kept larger than the
  window is tall; a `LINESn` too small for the window is quietly raised
  to fit. Growing a window beyond its ring leaves the extra rows blank
  rather than showing recycled text.
- **Clicking an AppIcon whose console had just closed** could touch
  freed memory. The console is validated first, as it already was
  everywhere else.
- **A malformed clipboard could send the paste parser off the end of
  its buffer.** Chunk sizes are now bounded in both directions, not just
  against negatives.
- **Pasting more than about 2000 bytes into a raw fullscreen program**
  (Ed) silently lost the tail. It still stops there, but the window now
  beeps instead of dropping it in silence — see the manual, section 17.
- **A failed window restore left a console with no window and no icon**,
  unreachable. The icon goes back up so you can try again.
- **Output arriving during a scrollback search** left the search half
  on, so the next keypress jumped the view back to the match.
- **`diskfont.library` was opened and never closed** by any handler that
  had loaded a `FONT`, so it could never be flushed from memory.
- A one-row window could hang the line editor in a loop.

### Changed
- **Faster output.** The render loop no longer re-reads the window
  geometry through a global for every character, and sets its pens once
  per run instead of once per screen row — the same treatment three
  drawing routines already had.

### Internal
- New test harness `tests/sbmaxtest.e`, which reproduced the scrollback
  overrun as a computed index and corrected the fix's own reasoning
  about where the boundary lies.

---

## [1.2] — 2026-07-23 (tag `ccon-1.2`)

### Added
- **Iconify.** `RightAmiga+I` sends a window to the Workbench as an
  AppIcon — the window vanishes while its console keeps running (output
  that arrives while iconified pauses until you restore). Double-click
  the icon to bring the window back exactly as it was: scrollback,
  a half-typed command line, cursor, colours and all. Works in a raw
  full-screen client (Ed) too. The icon is built into the handler, so
  there is nothing to install.
- **Full-screen paging like `CON:`.** Form feed (`^L`) now clears the
  screen and homes the cursor, so More — and any full-screen program
  that repaints — replaces the page instead of scrolling it. A Cursor
  Position Report responder (`CSI 6n` → `CSI row;col R`) keeps a client
  that probes the cursor on its first page in step.
- **`CON:`/`RAW:` labels reflect the real mount name.** When CCON is
  mounted as the system `CON:`/`RAW:`, the input-handler node name and
  the default window title read the device's `dol_Name` instead of a
  hardcoded "CCON". (1.2b18)

### Changed
- Raw-mode arrow and function keys use the 8-bit `$9B` CSI introducer
  (what stock `CON:` sends), so **Ed's cursor navigation works**. 1.1
  had switched these to the 7-bit `ESC[` form for More's paging, but Ed
  reads that leading `ESC` as its command line (stray "blue" command
  text) — the same way `ESC[` broke `ls`. Both Ed and More page and
  navigate correctly on `$9B`.
- The window-bounds report uses the 8-bit CSI (`$9B`), fixing a phantom
  `1` command turning up after every `ls`/`dir`. (1.2b1)
- History stores each command once, moving a repeat to the newest
  position (zsh `HIST_IGNORE_ALL_DUPS`). (1.2b14)

### Fixed
- **Resizing a fullscreen program's window (Ed)** now repaints and
  sends the size report, so the client re-measures and redraws instead
  of leaving a stale frame — the resize event was previously never even
  seen for a raw-mode client (B8). (Ed doesn't re-wrap text to a
  narrower window, the same as under `CON:` — that's the editor's own
  behaviour.)

### Fixed — first audit (a full static read of the handler)
- Edit-line erase no longer leaves a stale paint extent at a
  margin-parked anchor (B1). (1.2b3–b6)
- Growing a window pulls scrollback history down instead of exposing
  recycled ring rows (B2). (1.2b7)
- CSI / event reports enqueue whole-or-nothing, so a full input queue
  can't truncate a report and desync a client's parser (B3). (1.2b8)
- A failed AUTO window open stops retrying on every packet (B4). (1.2b7)
- `ACTION_DIE` teardown — the handler unmounts cleanly (development-time
  remount; refuses while a window is open) (B5). (1.2b13)
- `DISK_INFO` fails rather than handing a caller a stranger's window
  (B6). (1.2b12)
- A width change now **re-wraps** the transcript (`CON:` parity) instead
  of destroying every character past the new column count (B7).
  (1.2b9–b10a)
- The per-keystroke history walk drops a division-per-entry and stops at
  the first match (P3). (1.2b16)
- History persists by appending one line per commit instead of
  rewriting the whole ring on every Enter (P5). (1.2b11)
- Hot-path micro-optimizations and hardening: per-run attribute hoist,
  power-of-two queue masking, paint-loop locals, shadowed-port rename,
  named constants (P1/P2/P4/H1/H2/H5). (1.2b2)

### Fixed — second audit
- `openwin` no longer leaks a `textattr` on every window open (B9).
  (1.2b15)
- `selcopy`'s inter-row LF is bounded — no clipboard-buffer overflow at
  extreme window geometry (B10). (1.2b17)
- `dopaste` refuses a malformed (negative-size) IFF chunk, so a bad
  clipboard can't wedge the handler (B11). (1.2b17)
- `condispose` frees the model planes on its own terms (H3); stray
  non-ASCII bytes scrubbed from a comment (H6). (1.2b15)
- A runaway-client machine freeze was traced to the `ls` tool (it
  looped forever on empty-named directory entries), **not** CCON —
  proved console-independent and closed as misattributed (B12).

---

## [1.1] — 2026-07-20 (tag `ccon-1.1`, released on Aminet)

### Added — Theme A (per-window display)
- **FONT option** — a per-window disk font, loaded through a throwaway
  helper process to respect the no-DOS rule; a bare open uses the
  user's Font Prefs "System Default Text" font.
- **Soft styles** — italic (SGR 3/23), underline (4/24) and inverse
  (7/27), the styles stock `CON:` renders and 1.0 dropped.
- **Alternate screen** — the xterm `CSI ?47h`/`?47l` contract that
  More and Ed bracket their sessions with; content viewed there does
  not enter scrollback.
- **LINES=n** — per-window scrollback depth.
- SGR bright/bold pens, OSC window titles, `ESC D`/`M`/`E` and
  `CSI S`/`T` scroll primitives.

### Added — Theme B (input tier)
- **Shared, persistent, filtered command history** across every window
  (`L:ccon-history`), prefix-filtered on Up/Down (fish/zsh style).
- **Bracketed-paste safety** — a multi-line paste drips one line per
  real Enter with a visible grey hint row; nothing from a paste ever
  auto-runs.
- **Scrollback search** — Ctrl+R searches the transcript, contextual on
  the view offset.

### Added — the `CON:`/`RAW:` takeover
- CCON can be mounted as the system `CON:`/`RAW:` — one mountlist with
  four stanzas (`CCON:`/`CRAW:`/`CON:`/`RAW:`). (1.1b46)
- `WIDTH`/`HEIGHT` = `-1` fills the remaining screen.

### Fixed
- More's special-key encoding switched from the bare 8-bit C1 byte to
  the 7-bit `ESC[` form, fixing arrow-key paging under CCON (found by
  disassembling More and running it under stock `CON:` for comparison).
- Ed's plain-arrow scrolling (`CSI S`/`T` and `ESC D`/`M`).
- Window geometry matches stock `CON:`; a kinder default scrollback
  depth.

---

## [1.0] — 2026-07-19 (tag `ccon-1.0`)

First release: a complete one-process / many-windows console handler
(the AROS shape, not KingCON's fork-per-window).

### Added
- **Output scrollback** — the feature that justifies CCON, a fixed-size
  ring model the whole display reads from (redraws, selection, menu
  restore, the prompt-banner restore).
- Full-screen client support: `CSI` cursor moves, `H`/`f` position,
  insert/delete line and char, erase, SGR colours — what More and Ed
  actually speak.
- A readline-tier line editor: Ctrl+U/K/W kills, word motion, and
  insert-at-cursor rather than append-only.
- fish-style autosuggestions (ghosts) from history, accepted with
  Right / Shift+Right / Ctrl+Right.
- zsh-style Tab completion, driven by hand-rolled filesystem packets on
  a private reply port (the no-DOS-rule escape hatch).
- Drag-select copy to the clipboard, with word / line click escalation
  (xterm manners, `DoubleClick` timing) and the mouse wheel.
- The input.device chain hookup — keys are taken upstream like stock
  `console.device`, so a client like Ed can commandeer the window and
  its menus reach it as `IECLASS_MENULIST`.
- Stock `CON:` open/close semantics, borrowed windows (`WINDOW0x`),
  public-screen selection (`SCREENname`), and the `CRAW:` raw variant.
- A full handbook (`ccon.doc`).

---

## 0.x — development milestones

- **M1** — proof of life: an E binary running as a mounted DOS handler
  (the `wbmessage` capture, the no-DOS rule).
- **M2 / M3** — the line editor moves in, then a real shell is hosted.
- **M4** — raw mode, real `WAIT_CHAR` timeouts via `timer.device`, the
  window-bounds report; two ROM secrets (the V47 shell probe, the menu
  route). (0.11)
- **M5 / M5b / M5c** — scrollback (the point of it all), zsh Tab
  completion, and stock open/close semantics.
- **0.12** — SGR colours and input.device chain input — and Ed works.
- **0.17** — copy & paste (M7); the edit line wraps.
- **0.19** — window resize (M8); the ANSI and Workbench colour worlds
  part ways.
- **0.20** — the stock option set; `CRAW:` joins the family.
- **0.21 → 1.0** — the per-console object (M10 step A), then a window
  per open — the console handler complete.
