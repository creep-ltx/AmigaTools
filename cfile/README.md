# CFile

A two-pane, keyboard-driven text-mode file manager for AmigaOS.

![CFile browsing DH0: and DH1: on AmigaOS 3.2](screenshot.png)

Two directory panes inside a compiled-in 80x31 character frame. The
selection bar is the only highlight and lives in the active pane;
everything is done from the keyboard. Files are recognised by their
headers (hunk executable, lha/lzx/zip, ANSI, text), and each verb
does the natural thing for the type.

## Keys

| Key | Action |
|-----|--------|
| `Tab` | switch the active pane |
| `Up` / `Down` | move the selection (`Shift` = page, `Ctrl` = first/last) |
| `Right` | enter the selected directory or volume |
| `Left` | parent directory; at a device root, the volume list |
| `Enter` | open by type: enter a directory, view text/ANSI, run an executable (asks first), hex-view the rest |
| `v` | view: text pager, ANSI art with the classic palette, hex dump for binaries, contents listing for archives |
| `i` | info window: size, date, comment, and the protection bits — `h s p a r w e d` toggle them live |
| `Space` | mark/unmark the entry (and step down) |
| `c` / `C` | copy the selection or marked set to the other pane (`C` overwrites collisions) |
| `m` / `M` | move likewise (same volume is a rename; across volumes copies and deletes) |
| `r` | rename; with marks, one prompt per entry |
| `n` | new directory |
| `Del` / `D` | delete the selection or marked set, directories recursively (asks first) |
| `u` | unpack the selected archive — or every marked archive — into the other pane |
| `p` | pack the selection or marked set into an archive in the other pane |
| `:` | run a shell command in the active pane's directory |
| `?` / `Help` / `h` | help screen |
| `Esc` | quit (asks first) |

## File operations

Copy and move ask about name collisions per file —
`(s)kip (o)verwrite (r)ename?` — and all questions are asked *before*
anything is transferred, so cancelling leaves everything untouched.
Directories go recursively; copying preserves protection bits,
datestamps and comments; a directory can be merged into an existing
one. A centered progress bar (byte-accurate for copies) covers the
longer operations.

Deleting is recursive and resilient: a delete-protected entry asks
`unprotect? (y)es (n)o (a)ll`, an entry that will not go is skipped
and the rest of the run continues, and the summary names what
remains. Marks turn `c`/`m`/`Del`/`u` into bulk operations on the
whole set at once; `r` walks the marked set one prompt at a time.

## Archives

`u` unpacks lha, lzx and zip archives (recognised by their headers,
not their names) into the other pane's directory. `p` packs the
selection or marked set into a new archive there — the filename you
type picks the packer: `.lha`/`.lzh`, `.lzx` or `.zip`. The archiver
runs from the source directory, so archives contain clean relative
paths. `v` on an archive shows its contents listing in the viewer.

## The console

Commands (`u`, `p`, `:`, and running an executable with `Enter`)
stream their output live into the frame — CFile renders the bytes
itself through a `PIPE:`, no console window, no borders. When the
command finishes, the arrow keys (with `Shift`/`Ctrl`) scroll back
through up to 4000 lines of output; any other key returns to the
panes. `:` commands run with the active pane's directory as their
current directory, and both panes refresh afterwards.

## Display

CFile opens its own 8-colour screen (like Workbench, made public as
`CFILE`): grey background, black text, blue directories, black
selection bar that keeps the entry's type colour. Each pane's path
lives in the frame's border row; prompts and messages take that row
over between guillemets and give it back afterwards. Viewing ANSI art
switches the palette to the classic ANSI colours and restores it on
exit. If the screen cannot be opened, CFile falls back to a
borderless window on the public screen without its own palette.

## Files

- `cfile` — prebuilt AmigaOS binary (68000, AmigaOS 2.0+)
- `cfile.e` — the source, Amiga E
- `layout` — the frame mockup (ISO-8859-1); its border row shows the
  occupied style, the resting border lives in the embedded frame
- `console-and-view-layout` — the console/view frame mockup

## Building

A prebuilt binary is committed. To build it yourself, compile
`cfile.e` with the E-VO E compiler:

```
evo cfile.e
```

## Verified behaviour

Exercised on an AmigaOS 3.2 install (FS-UAE): pane navigation with
paging, the volume list, copy and move with collision prompts and
bulk marks, recursive deletes including delete-protected entries and
the unprotect prompts, sequential rename, the info window with live
protection-bit editing, text/ANSI/hex viewing (with the palette
restored on exit), archive unpacking singly and in bulk, `:`
commands, running executables, and the live console with scrollback.
The pack verb and the newest refinements (qualifier keys during
scrollback, the occupied-border style) were built last and have had
the least testing. One known limit: FS-UAE directory drives can hold
host filenames the Amiga side cannot see; CFile reports these as
"invisible entries remain" when they block a delete.
