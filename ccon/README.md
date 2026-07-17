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
to the filesystem. Opens parse stock-CON: style —
`CCON:x/y/w/h/title/options` with CLOSE (gadget = EOF), WAIT
(window lingers for its gadget) and WINDOW0xADDR (borrow an
existing window; not yet exercised by a client) — and the window
closes with its last handle, so `EndShell` takes it away and
`echo >CCON:0/0/400/100/hi/WAIT hello` leaves one to read.
Next: M6, input.device-handler key input (Ed's menus). See
`todo.md`.

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
