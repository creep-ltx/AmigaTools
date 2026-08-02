# cdiff — a visual diff for AmigaOS

The tool the platform never got: side-by-side file compare in a
window, with a real diff algorithm underneath. Born 1.8.26 from the
observation that maintaining a fork (cfile vs cfile13) means living
inside a 12,000-line diff with no way to *see* it on the machine.

The first C-language member of the C* family — built with Bebbo's
m68k-amigaos-gcc instead of Amiga E, chosen for the RKM-verbatim API
documentation and the newer optimizer. The testing discipline is
unchanged: the engine is pure logic, proven by a harness that runs
on the host AND under vamos before anything boots.

## Usage

    cdiff FILE1/A,FILE2/A,TEXT/S

GUI (default): a window on the Workbench screen, FILE1 left, FILE2
right, changed rows as blue bar rows with a `< | >` marker column
and receding line numbers in the gutter.

Started from Workbench (no arguments), the window opens empty and
the **Project** menu supplies the files: *Open Files...* asks for
the left then the right file (ASL requester, one by one), *Open
Left/Right...* swaps a single side later, *Quit* leaves. The same
menu works in a CLI-started window.

| key | action |
|---|---|
| cursor up/down | scroll one row (shift = page) |
| space / b | page down / up |
| t / e | top / end |
| n / p | next / previous hunk |
| Esc / Backspace | back to the Tree (never quits) |
| Amiga+Q | quit |

`TEXT`: unified-style listing to stdout — and the on-target test
road under vamos, where the GUI cannot run.

## Engine

Patience diff (the git-patience shape): lines unique in both files
anchor a longest-increasing-subsequence chain; recursion fills the
gaps; non-unique leftovers become honest replace blocks. O(N) extra
memory, heap-only work arrays, depth-capped recursion — a
shell-default stack survives any input (`__stack = 65536` belt and
braces). Hash collisions are handled conservatively: a collision can
only demote an anchor, never fabricate a false match.

Measured (vamos, emulated 68k): cfile.e vs cfile13.e — 12,210 vs
11,149 lines — in 2.5s: 489 hunks, +1083 −2145.

## Building

    make            # cross-compile with /opt/amiga gcc
    make test       # harness: host cc AND m68k-under-vamos
    make deploy     # copy into the FS-UAE Dump drive

## Status

0.1b1 — first light. See roadmap.md.
