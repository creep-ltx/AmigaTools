# CCON

An LTX console handler for AmigaOS — the `CON:` family (CON:,
KingCON, ViNCEd) grown at home. A mounted DOS handler speaking the
packet protocol, with output scrollback as its reason to exist:
the stock 3.2 con-handler has none (verified against its ROM
option table), and commands talk to the handler, so no application
can add it from outside. The endgame is CShell handing its frame
window to `CCON:` instead of `CON:`.

**Status: milestone 1 — proof of life, boot-verified on an
AmigaOS 3.2 install (FS-UAE).** The skeleton mounts, answers the
packet protocol (FINDINPUT/FINDOUTPUT/FINDUPDATE, READ as EOF,
WRITE, END) and renders writes into a plain window. Nothing
beyond that yet — see `todo.md` for the plan and the verified
groundwork.

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
