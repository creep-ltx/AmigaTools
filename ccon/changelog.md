# CCON changelog

CCON — an LTX console handler for AmigaOS: a mounted DOS handler
speaking the packet protocol, hosting any client, with the one feature
stock V47 `CON:` cannot do — **output scrollback**. It can also be
mounted as the system `CON:`/`RAW:`.

Beta build numbers (e.g. 1.2b16) are in parentheses as references.
Dates are release/build dates. 1.0 and 1.1 are released and tagged;
1.2 is in development.

---

## [Unreleased] — 1.2

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

### Known limitations
- Resizing a **raw-mode client's** window (e.g. Ed) can leave stale
  pixels and does not re-lay-out the client — the console repaint for a
  raw client is not wired up (B8).
- `fscall` (Tab completion and the history file) has no timeout, so a
  wedged or still-spinning-up filesystem blocks the handler until it
  replies (P6).

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
