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

## Keys

- **Up/Down** — move the selection (wraps around)
- **Enter** — launch the selected item
- **1–9, 0** — launch item 1–10 directly
- **Esc** — exit without launching anything
- Any key stops a running countdown

## How it works

- The window is a borderless Intuition window opened at
  `(0, barheight+1)` and sized from the actual screen's width, height,
  and title-bar height — so PAL, NTSC, interlace, and RTG modes all
  come out right without any mode detection. At early boot, when no
  Workbench screen exists yet, `OpenWorkBench()` is called first to
  bring one up.
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

Menu rendering below the screen title bar, Up/Down/Enter/digit/Esc
handling, the countdown (including cancel-on-keypress), and launching
of both script and executable items have been exercised from a Shell on
an AmigaOS 3.2 install (FS-UAE). Running CMenu in its intended place —
before the Startup-Sequence at boot — has not been exercised yet.
