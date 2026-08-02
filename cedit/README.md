# cedit

A GUI text editor for AmigaOS: tabs for open files (only once there
is more than one — a single document keeps the row for text), a
line-number gutter, border scrollbars with the system's own arrows, a
status row, and syntax highlighting that knows **Amiga E** first.

**Not finished.** This is `0.1b5` — it edits, saves, undoes and talks
to the clipboard. See
[roadmap.md](roadmap.md) for where it is going and what is already
done.

## Why

CygnusEd is alive and sold, GoldED is shareware, and neither properly
knows Amiga E — the language most of this collection is written in.
cedit is free, knows E, and is part of the toolchain: CFile manages,
cedit writes, cdiff compares.

It is **not** a replacement for CFile's built-in editor. CFile stays a
keyboard program with an editor aboard; cedit is what `ENV:EDITOR`
points at when you want a window.

## Usage

```
cedit [FILE ...]
```

Each file named gets its own tab. From Workbench: double-click a
project icon with cedit as its default tool, or drop several on the
cedit icon — same result.

Keys at b2: the cursor keys move the caret, Shift+up/down pages,
Shift+left/right goes to the start and end of the line, and
Ctrl+left/right jumps by word (the CCON line editor's assignment).
Return, Backspace, Del and Tab do what they say. The mouse wheel and
the scrollbars SCROLL without moving the caret — a scrollbar is for
looking around, and taking the caret along would lose your place.

Project menu:

| | |
|---|---|
| `New` (Amiga+N) | a blank page in a new tab |
| `Open...` (O) | replaces the file in the current tab |
| `Open New...` (D) | opens a file in a new tab |
| `Close` (K) | closes the active tab |
| `Close All` | closes everything, leaves one blank page |
| `Save` (S) | saves the active tab; untitled goes to Save As |
| `Save As...` (A) | the requester |
| `Quit` (Q) | |

Up to 16 documents at once. Click a tab to switch to it, or its `x` to close it. When there are more tabs than fit, `<` and `>` appear at
the ends of the bar — each only when there is somewhere to go that
way. Anything
that would throw away unsaved changes asks first, with Cancel as the
default — and Close All and Quit ask **once** for the whole set
rather than once per document.

Edit menu: `Undo` (Amiga+Z), `Redo` (Amiga+Y), `Mark` (B), `Cut` (X),
`Copy` (C), `Paste` (V).

**Selecting**: drag with the mouse, or press Amiga+B to drop an
anchor and move the caret — the range between is the selection. Esc
drops it, and typing over it replaces it. Shift+arrows keep their
paging and line-end jobs, which matter on a keyboard with no
PgUp/PgDn.

The clipboard is `clipboard.device` unit 0 in IFF FTXT — the same
format the console family uses — so a copy here pastes into a `CON:`
shell, into Ed, or into MultiView, and back again. One undo takes back
a whole typing run, not a letter at a time — a run ends when you move
the cursor. Undoing back to the last save marks the file unmodified
again, and redoing away from it marks it changed.

Settings menu: line numbers, status bar, fast scroll, and **Tab size**
1–10. Every one of them writes straight back to the icon, so the menu
and the tooltypes never disagree.

Saving writes back the line endings the file arrived with — LF, CRLF
or CR — and does not add a final newline to a file that had none. The
new text goes to a sibling `.new` file and only replaces the original
once it is completely written, so a failed save costs a stray file
rather than a truncated source.

### Tooltypes

All optional, all inert when absent, so a shell launch is unchanged.
`FONT=topaz/8` · `TABSIZE=1..10` · `GUTTER=YES|NO` (line numbers) ·
`STATUSBAR=YES|NO` · `FASTSCROLL=YES|NO` · `DRAWER=` where the file
requester starts · `OPENSCREEN=name` and `SCREENDEPTH=n` for a screen
of cedit's own · `PUBSCREEN=name` to attach to somebody else's ·
`LEFT= TOP= WIDTH= HEIGHT=`.

The Settings menu writes its toggles straight back to the icon, so
menu and tooltype never disagree.

## How it is built

cedit is C, cross-compiled with
[Bebbo's](https://github.com/bebbo/amiga-gcc) `m68k-amigaos-gcc`.

Two things it does not own. The GUI chassis is
[`../ltxgui/ltxwin.c`](../ltxgui) — window, screen, font, border
scrollbars, tab bar, status row, the row painter and the deferred-paint
scroll engine — written and boot-proven inside cdiff and lifted out
when cedit became the second tool that wanted it. Both tools build from
that one file. And the text buffer is `edbuf.c`: pure logic, no Amiga
headers, so a harness proves it on the host *and* under vamos before
anything boots.

```
make test && make
```

`make test` runs the buffer harness both ways. Running both is not
belt-and-braces: cdiff found a `gcc -O2` miscompilation on m68k that
was invisible to a host-only test and silent at `-Wall`.
