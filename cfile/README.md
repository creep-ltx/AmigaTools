# CFile

A two-pane, keyboard-driven text-mode file manager for AmigaOS.

**Status: proof of concept / first draft.** Navigation works; nothing
else exists yet. The panes are hardcoded to `DH0:` (left) and `DH1:`
(right), and there are no file operations — no copy, move, delete,
rename or view. The point of this version is the frame, the pane
machinery, and the keyboard feel.

## Keys

| Key | Action |
|-----|--------|
| `Tab` | switch the active pane |
| `Up` / `Down` | move the selection (long listings scroll at the edges) |
| `Right` | enter the selected directory |
| `Left` | back to the parent directory, stopping at the device root |
| `H` | help screen |
| `Esc` | quit |

Going `Left` re-selects the directory you just came out of, so
`Left`/`Right` round-trips don't lose your place in a listing.

## Display

CFile opens its own 8-colour screen (like Workbench) and draws a
compiled-in 80x31 character frame with two 38-column directory panes,
22 entries visible in each. The current path of each pane is shown in
the frame's border row above the panes (deep paths show their tail
end).

Listings are sorted directories first, then files, case-insensitively.
Directories are blue, files black, on a grey background. The selection
bar — black, in the active pane only — keeps the entry's type colour:
blue text means you are on a directory, grey text on a file. A path
that cannot be read (no disk in the drive, for instance) shows a
message instead of a listing.

If the screen cannot be opened, CFile falls back to a borderless
window on the public screen without its own palette.

## Files

- `cfile` — prebuilt AmigaOS binary (68000, AmigaOS 2.0+)
- `cfile.e` — the source, Amiga E
- `layout` — the frame mockup (ISO-8859-1) the embedded art block was
  generated from

## Building

A prebuilt binary is committed. To build it yourself, compile
`cfile.e` with the E-VO E compiler:

```
evo cfile.e
```

## Verified behaviour

The proof of concept has been run on an AmigaOS 3.2 install (FS-UAE):
both panes list their volumes, the selection and pane switch behave as
described, and directories can be entered and left with the expected
re-selection. Long-listing scrolling and the public-screen fallback
have not been specifically exercised yet.
