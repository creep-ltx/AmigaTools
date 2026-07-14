# CMenu

A full-screen text boot menu for AmigaOS. CMenu is meant to run *before*
the normal Startup-Sequence: it shows a centered menu of boot choices,
and the item you pick — a script or an executable — is launched the same
way [CBoot](../cboot) launches its boot scripts. CMenu exits after
launching; it is a boot menu, not a dock.

CMenu lives in a few well-known places:

```
C:CMenu                the program
S:CMenu/Config         the menu definition
S:CMenu/Headers/       optional ANSI header art
S:CMenu/Backgrounds/   optional full-screen background art
S:CMenu/Music/         optional ProTracker modules
LIBS:ptreplay.library  needed for the music (included)
```

The release archive mirrors that layout (`CMenu/C/`, `CMenu/S/CMenu/`),
so its drawers can be copied straight over `SYS:`.

The usual setup: rename your real Startup-Sequence to
`S:Startup-Sequence-Normal`, point a menu item at it, and replace
`S:Startup-Sequence` with the two-line `Example-Startup-Sequence` from
this directory:

```
run >nil: C:CMenu
endcli
```

## Configuration

CMenu reads `S:CMenu/Config` (see the example `Config` in this directory):

```
; comment lines start with ;
Workbench|S:Startup-Sequence-Normal
Demo|DH1:Demos/start-demo
Shell|C:NewShell
DEFAULT 1
TIMEOUT 10
STYLE ANSI
HEADERS ON S:CMenu/Headers
BACKGROUND OFF S:CMenu/Backgrounds
```

- `Menu name|path` — one item per line, up to 10 items. The path may
  point to a script or an executable.
- `DEFAULT n` — 1-based index of the preselected item (default 1).
- `TIMEOUT secs` — start the DEFAULT item automatically after that many
  seconds unless a key is pressed first. 0 or absent = wait forever.
- `STYLE LIGHT|DARK|ANSI` — the look: LIGHT is grey background with
  black text (the Workbench feel), DARK is black with white text, and
  ANSI is DARK plus full-colour header rendering. Default LIGHT.
- `HEADERS [ON|OFF] dir` — a directory of ANSI art files; CMenu picks
  one at random each run and draws it above the menu. `OFF` keeps the
  directory configured but hides the header. This repo directory
  contains a `Headers/` folder with a few classic 1996 scene headers to
  start from.
- `BACKGROUND [ON|OFF] path` — full-screen ANSI/ASCII background art
  instead of a header; the path may be a single file or a directory to
  rotate from. CMenu auto-detects the art's free interior (the largest
  run of rows with nothing in the central columns) and lays the menu,
  countdown, and help line out inside it — nothing is ever drawn over
  the art. Background art uses a tight 8-pixel line height, so a PAL
  screen fits 32 rows. When rotating from a directory, only art that
  fits the screen height is considered — so PAL, NTSC, and interlace
  versions can live side by side and each display picks from its own
  (if nothing fits, no background is shown). See `Backgrounds/` in
  this directory for a PAL example. Header and background are mutually
  exclusive — background wins if both are ON.
- `MUSIC [RANDOM|REPEAT|OFF] path` — ProTracker music while the menu
  is shown. The path may be a single file or a directory — the
  directory and all its subdirectories are scanned for `name.mod` /
  `mod.name` files, so `MUSIC RANDOM DH0:Modules` works on a whole
  collection. RANDOM picks a random module and jukeboxes to another
  one when it finishes; REPEAT loops the picked module; OFF is
  silent. Playback needs `ptreplay.library` in `LIBS:` (included in
  the release archive; without it CMenu is simply silent) and always
  stops before anything is launched.
- `FONT name/size` — e.g. `FONT MicroKnight/8`: render everything in a
  font from `FONTS:` instead of Topaz/8. A missing font falls back to
  Topaz/8, so a typo can't break the boot. Art column math assumes
  8-pixel-wide glyphs, so 8×8 fonts (like the classic scene fonts)
  fit best. Config file only — the config screen preserves the
  setting but doesn't edit it.

Workbench icon (`.info`) files in the art and music drawers are
ignored, so snapshotting a drawer can't break the rotation.

If `S:CMenu/Config` does not exist at all, CMenu boots straight into
the config screen on a built-in starter menu (Workbench →
`S:Startup-Sequence-Normal`, Shell → `C:NewShell`), with the default
art paths (`S:CMenu/Headers`, `S:CMenu/Backgrounds`) prefilled — so
everything can be set up on first boot, and saving creates the
`S:CMenu` drawer and writes a complete default config. If the file
exists but contains no items, the same built-in menu is shown with a
warning line, so a misconfigured setup still boots to something.
Whenever no header or background can actually be shown (nothing fits
the screen, or the art leaves no room for the menu), CMenu simply
shows its version title at the top instead.

You can also edit the configuration without leaving CMenu: pressing
**C** opens the config screen — framed by a built-in piece of LTX
ASCII art, whatever the menu itself is configured to look like — which
lists the items with the default marked `*` and edits everything in
place. Status messages briefly replace the title at the bottom of the
frame, and input prompts open just below the logo:

- **Up/Down** — select an item
- **Shift+Up/Down** — move the selected item up/down in the menu
- **A** — add an item (name, then path)
- **E** or **Enter** — edit the selected item (Esc keeps the old value)
- **D** — delete the selected item (the last one can't be deleted)
- **Space** — make the selected item the default
- **T** — set the timeout
- **C** — cycle the style (LIGHT → DARK → ANSI, the palette switches
  immediately)
- **H** — toggle the header on/off
- **B** — toggle the background on/off (switching one of H/B on turns
  the other off)
- **M** — cycle the music mode (OFF → RANDOM → REPEAT, takes effect
  immediately)
- **S** — write the changes back to `S:CMenu/Config`
- **Esc** — return to the menu

Changes take effect immediately but are only persisted with **S**.
Note that saving rewrites the file, so comment lines in a hand-edited
config don't survive it. The `HEADERS` and `BACKGROUND` paths themselves
can't be edited from the config screen, but saving preserves them.

## Keys

- **Up/Down** — move the selection (wraps around)
- **Enter** — launch the selected item
- **1–9, 0** — launch item 1–10 directly
- **C** — open the config screen
- **Esc** — exit without launching anything
- Any key stops a running countdown

## How it works

- CMenu opens its own screen (mode and size cloned from the Workbench
  prefs via `SA_LIKEWORKBENCH`, depth 3) — so PAL, NTSC, interlace,
  and RTG modes all come out right without any mode detection, and
  headers get their eight colours regardless of the Workbench screen
  depth. The palette follows the STYLE setting (grey/black for LIGHT,
  the classic 8-colour ANSI palette for DARK and ANSI) and is switched
  live with `LoadRGB4()` when the style is cycled. If the screen can't
  be opened, CMenu falls back to a borderless window on the public
  screen with header colours stripped.
- The header renderer understands what 1996-era ANSI art actually
  uses: SGR colour and style codes (`ESC[0m`, `1m` bold, `4m`
  underline, `30-37m` foreground, `;`-combinations) and cursor-forward
  column skips (`ESC[nC`). Unknown sequences are consumed and ignored.
  In LIGHT and DARK style the colours are stripped but the column
  skips still apply, so the art keeps its shape. Art is drawn for 80
  columns and centred on wider screens.
- Text is rendered in Topaz/8 (opened explicitly — it lives in ROM, so
  there is no disk-font dependency at boot time). The selected item is
  marked with `>` and `<` flanking it, always at the width of the
  widest menu item plus one space, so the markers sit at the same
  columns for every item.
- Redrawing is surgical: art is drawn in whole-run `Text()` batches
  (per-character rendering visibly crawls on a 68000), moving the
  selection only touches the four marker cells, and config-screen
  actions repaint just the rows they changed — so nothing flickers.
- The countdown is driven by `IDCMP_INTUITICKS` (roughly ten per
  second) — accurate enough for a boot timeout, with no `timer.device`
  boilerplate.
- Launching mirrors CBoot exactly: `protect "<path>" +srwed` first (so
  scripts run even if their script bit was never set), then
  `Execute('"<path>"')` — the shell LoadSegs and runs executables, and
  runs s-bit files as scripts.

## Building

A prebuilt `cmenu` binary is included in this directory — no compiler
needed, just copy it to `C:`.

To build it yourself, compile `cmenu.e` with the E-VO E compiler:

```
evo cmenu.e
```

This produces an AmigaOS loadseg()able executable named `cmenu`.

## Verified behaviour

Menu rendering, Up/Down/Enter/digit/Esc handling, the countdown
(including cancel-on-keypress), and launching of both script and
executable items have been exercised on an AmigaOS 3.2 install
(FS-UAE), both from a Shell and in CMenu's intended place — started
from a minimal Startup-Sequence at boot, with the countdown expiring
into the default item and continuing into `S:Startup-Sequence-Normal`.
The config screen has been exercised too: adding, editing, deleting,
and moving items, changing the default and timeout, and saving — with
the rewritten `S:CMenu/Config` feeding the menu correctly on the next
run. Header rotation and rendering (colours, bold/underline, column
skips, colour-stripped mode, and the no-header fallback) have been
exercised with real 1996 ANSI art, on CMenu's own screen, booted from
a minimal Startup-Sequence — as have the STYLE cycling (with its live
palette switch), the header and background toggles in the config
screen (including saving them and getting them back on the next
boot), and the full-screen background mode with the menu laid out
inside a bordered frame, countdown included. Rotation directories
with a single file and with several files both pick correctly, and
navigation with a full 10-item menu is flicker-free. The 0.4 additions have been exercised too: the fit
filter both rejecting too-tall art and picking the fitting file from
a mixed directory, the first-boot config screen with its prefilled
default paths writing a complete config, the plain-title fallback
when no art can be shown, Workbench `.info` files being skipped in
the rotation directories, MUSIC playing at boot in its RANDOM and
REPEAT modes (and stopping cleanly before the launched item takes
over), and the framed config screen with its timed status messages
and under-the-logo input prompts. The `FONT` setting has not been
exercised yet.
