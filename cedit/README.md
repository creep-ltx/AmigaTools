# cedit

A GUI text editor for AmigaOS: tabs for open files, a line-number
gutter, border scrollbars with the system's own arrows, a status row,
and syntax highlighting that knows **Amiga E** first.

**Not finished.** This is `0.1b1` — read-only. See
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
cedit [FILE]
```

From Workbench: double-click a project icon with cedit as its default
tool, or drop one on the cedit icon.

Keys at b1 (read-only): cursor up/down scroll, Shift = page, `space`
and `b` page, `t`/`e` top and end, cursor left/right pan, mouse wheel,
and the border scrollbars. `Amiga+Q` quits.

### Tooltypes

All optional, all inert when absent, so a shell launch is unchanged.
`FONT=topaz/8` · `TABSIZE=` · `GUTTER=YES|NO` (line numbers) ·
`STATUSBAR=YES|NO` · `FASTSCROLL=YES|NO` · `OPENSCREEN=name` and
`SCREENDEPTH=n` for a screen of cedit's own · `PUBSCREEN=name` to
attach to somebody else's · `LEFT= TOP= WIDTH= HEIGHT=`.

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
