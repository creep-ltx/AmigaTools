# CMenu

A full-screen text boot menu for AmigaOS. CMenu is meant to run *before*
the normal Startup-Sequence: it shows a centered menu of boot choices,
and the item you pick — a script or an executable — is launched the same
way [CBoot](../cboot) launches its boot scripts. CMenu exits after
launching; it is a boot menu, not a dock.

The usual setup: rename your real Startup-Sequence to
`S:Startup-Sequence-Normal`, point a menu item at it, and replace
`S:Startup-Sequence` with the two-line `example-startup-sequence` from
this directory:

```
run >nil: C:CMenu
endcli
```

## Configuration

CMenu reads `S:CMenu.config` (see the example in this directory):

```
; comment lines start with ;
Workbench|S:Startup-Sequence-Normal
Demo|DH1:Demos/start-demo
Shell|C:NewShell
DEFAULT 1
TIMEOUT 10
```

- `Menu name|path` — one item per line, up to 10 items. The path may
  point to a script or an executable.
- `DEFAULT n` — 1-based index of the preselected item (default 1).
- `TIMEOUT secs` — start the DEFAULT item automatically after that many
  seconds unless a key is pressed first. 0 or absent = wait forever.

If `S:CMenu.config` is missing or contains no items, CMenu does not
die — it shows a built-in fallback menu (Workbench →
`S:Startup-Sequence-Normal`, Shell → `C:NewShell`) with a warning line,
so a misconfigured setup still boots to something.

You can also edit the configuration without leaving CMenu: pressing
**C** opens the config screen, which lists the items with the default
marked `*` and edits everything in place:

- **Up/Down** — select an item
- **Shift+Up/Down** — move the selected item up/down in the menu
- **A** — add an item (name, then path)
- **E** or **Enter** — edit the selected item (Esc keeps the old value)
- **D** — delete the selected item (the last one can't be deleted)
- **Space** — make the selected item the default
- **T** — set the timeout
- **S** — write the changes back to `S:CMenu.config`
- **Esc** — return to the menu

Changes take effect immediately but are only persisted with **S**.
Note that saving rewrites the file, so comment lines in a hand-edited
config don't survive it.

## Keys

- **Up/Down** — move the selection (wraps around)
- **Enter** — launch the selected item
- **1–9, 0** — launch item 1–10 directly
- **C** — open the config screen
- **Esc** — exit without launching anything
- Any key stops a running countdown

## How it works

- The window is a borderless Intuition window covering the whole
  screen, sized from the actual screen's width and height — so PAL,
  NTSC, interlace, and RTG modes all come out right without any mode
  detection. At early boot, when no Workbench screen exists yet,
  `OpenWorkBench()` is called first to bring one up.
- Text is rendered in Topaz/8 (opened explicitly — it lives in ROM, so
  there is no disk-font dependency at boot time). The selected item is
  drawn as an inverse-video bar using pens 0 and 1 only, readable on
  any screen depth.
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
the rewritten `S:CMenu.config` feeding the menu correctly on the next
run.
