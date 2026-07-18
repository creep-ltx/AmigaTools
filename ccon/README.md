# CCON

An LTX console handler for AmigaOS — the `CON:` family (CON:,
KingCON, ViNCEd) grown at home. A mounted DOS handler speaking the
packet protocol, with output scrollback as its reason to exist:
the stock 3.2 con-handler has none (verified against its ROM
option table), and commands talk to the handler, so no application
can add it from outside. The endgame is CTerm handing its frame
window to `CCON:` instead of `CON:`.

**Status: milestones 1–4 boot-verified on an AmigaOS 3.2 install
(FS-UAE).** `NewShell CCON:` runs a real AmigaShell in the
handler's window — prompt, dir, list, EndShell — with the CTerm
0.1 line editor behind ACTION_READ (blip cursor, insert editing,
word jumps, 32-line history, type-ahead, EOF on Ctrl+\) and
Ctrl+C reaching a running command (break forwarding, AROS
con-handler semantics). M4 added raw mode and the full-screen CSI
set: multi-column `dir` via the window-bounds report (also probed
by this repo's `ls`), More paging, Ed fullscreen editing,
WAIT_CHAR with real timer.device timeouts. M5 — output
scrollback, the reason the handler exists — is boot-verified too:
a 4000-line model behind the renderer, viewed with Shift+Up/Down
(page) and Ctrl+Up/Down (line, raw mode too); any output or other
key snaps back to live. The cooked editor has zsh-style
tab completion (menu below the prompt, Tab cycles, Shift+Tab
backwards, Enter accepts), built on hand-rolled filesystem
packets — a handler cannot call packet-sending dos.library
functions, so LOCATE/EXAMINE ride a private reply port straight
to the filesystem. The renderer speaks SGR: colour codes in
output (reset, bold, 30–37 foreground, 40–47 background) render
with real pens, bold mapping to the bright pens on a 16-pen
screen, and the scrollback model carries an attribute plane so
colours survive scroll-back redraws. A `PEN` option in the open
name sets the default text pen (CTerm sends `PEN7` on its ANSI
screen, where pen 1 is red), and a `WBPENS` option retargets
plain SGR 30–33: those are Workbench pen numbers to OS programs
— C:Ed hardcodes `ESC[31m` for its body text because pen 1 is
black on a Workbench screen — so under WBPENS 31 renders as the
default text pen, 33 as the theme blue, 32 bright white, 30
background, while bold forms (`1;3x`, the `ls` scheme) and
backgrounds keep their ANSI positions. Opens parse stock-CON: style —
`CCON:x/y/w/h/title/options` with the stock option set: CLOSE
and NOCLOSE (the gadget — present by default like a 3.2 shell
window, click = EOF), WAIT (window lingers for its gadget), AUTO
(the open succeeds windowless and the window appears on first
real I/O — the classic debug-console idiom), SCREENname (open on
a named public screen), NOBORDER, NODRAG, NODEPTH, NOSIZE,
BACKDROP, INACTIVE, WINDOW0xADDR (borrow an existing window),
plus CCON's own PEN and WBPENS — and the window closes with its
last handle, so `EndShell` takes it away and
`echo >CCON:0/0/400/100/hi/WAIT hello` leaves one to read. A
second mountlist mounts the same binary as `CRAW:` (Startup =
"RAW"): its streams open in raw mode from the first byte, the
RAW: counterpart.
M6 moves key acquisition where
console.device keeps its own: an input.device handler below
Intuition's chain position captures events for the active CCON
window and the handler task runs them through keymap.library,
and the raw input event reports (`CSI n{`) are live. The window
also stops asking for menu picks over IDCMP — the stock
con-handler opens its window with no IDCMP classes at all (read
from the 47.19 ROM tag list), because a pick delivered to the
UserPort never enters the input stream: without IDCMP_MENUPICK
it arrives as an IECLASS_MENULIST event the chain handler can
report. That report is exactly what Ed's menu code consumes —
its parser (disassembled, C:Ed code $1708) looks up the report's
code field with ItemAddress and walks NextSelect, so menus over
CCON: work the same way they do over CON: — boot-verified: Ed's
menus drop and pick. Raw mode also renders the console block
cursor now (an inverse-video cell from the scrollback model at
the cursor position): full-screen programs like Ed draw no
marker of their own and rely on the console's, exactly as on
stock CON:. If the chain hookup fails, keys fall back to the
window path and the window title gains a ` [no chain]` marker.
M7 — boot-verified — is copy & paste: drag-select with the left
button — inverse-video highlight, output frozen mid-drag exactly
like the stock console (writers wait, unreplied, until the
button releases) — and releasing copies the text to
clipboard.device unit 0 as IFF FTXT, the format the stock
console family shares, so selections travel both ways between
CCON and CON: windows. RAMIGA-V pastes (RAMIGA-C re-copies a
standing highlight): the clip is injected as typed input —
through the line editor when cooked, straight to the client when
raw, which is how text lands in Ed. Selection works on whatever
the view shows, scrollback included. The mouse events ride
IDCMP, not the input chain — a telemetry boot proved Intuition
consumes select-up and motion below its own chain position, so a
drag simply cannot be seen from down there; the flag juggling
this requires (MOUSEBUTTONS out while a client holds `CSI 2{`,
MOUSEMOVE in only mid-drag) lives in one place. The cooked edit
line also wraps across rows now, stock-shell style: growing past
the bottom scrolls the screen, the prompt walks up, and the
completion menu freezes its rows so cycling candidates cannot
overwrite it.
Windows resize (M8): the scrollback model is reallocated and
row-copied on a width change (rows stay rows — no reflow, family
behaviour), a height loss scrolls the tail into history, the
wrapped edit line re-wraps at the new width, and a raw client
that asked for class-12 reports (Ed does) is told and re-measures
itself. And the two colour worlds are kept apart: `WBPENS` in the
open name declares the screen's palette truly ANSI (CTerm sends
it) and the pen conventions apply as-is — on any other screen,
plain SGR 3x stays raw pens (stock semantics, what WB-pen
programs like Ed mean) while the bold+3x forms — ANSI colour
intent, the `ls` scheme — are translated by colour through
ObtainBestPen against the screen's own palette, so directories
are genuinely blue on a stock Workbench too. See `todo.md`.

## Try it

```
copy ccon-handler L:
copy CCON-mountlist DEVS:
Mount CCON: FROM DEVS:CCON-mountlist
echo >CCON: hello
```

The handler process starts on first reference, opens its window
and prints the line.

## Files

- `ccon-handler.e` — the source, Amiga E.
- `ccon-handler` — prebuilt AmigaOS binary.
- `CCON-mountlist` — mountlist for `DEVS:`.
- `CRAW-mountlist` — the raw-by-default second device.
- `todo.md` — milestones and the verified protocol facts.

## Building

```
evo ccon-handler.e
```

## The E handler trick

An E binary started as a handler has no CLI, so the E runtime's
startup code waits on the process message port and captures the
first message — which is DOS's mount startup packet — into the
`wbmessage` global, believing it a Workbench startup message. The
handler takes the packet from there, replies it itself, and sets
`wbmessage := NIL` so the runtime's exit code (which would reply
the same message again) stays quiet. Verified by disassembling the
generated startup code, not assumed.
