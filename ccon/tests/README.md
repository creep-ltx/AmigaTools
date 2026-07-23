-> ccon/tests - the test files for the audit fixes
-> Kept in the repo on purpose. The Amiga-side ones normally live only
-> inside the FS-UAE disk image, which means they vanish the moment
-> that image is rebuilt; the point of these was to make a bug
-> provable rather than merely claimed, so they are saved here too.

# CCON tests

Two kinds. One runs on Linux and proves the logic; the others run on
the Amiga and prove the real thing.

## ccdie.e - runs on the Amiga, tests B5 (ACTION_DIE teardown)

A tiny program that sends an `ACTION_DIE` packet to CCON:'s handler,
because no stock AmigaOS command does. Build with `ecompile ccdie.e
ccdie`, copy `ccdie` into `C:`.

B5 makes the handler tear down cleanly (remove its input.device
handler, close its devices, exit) on unmount, instead of running
forever with a stale chain handler. To test:

1. Boot, `Version L:ccon-handler` -> confirm the build.
2. `NewShell CCON:` - this starts CCON:'s handler process and installs
   its input.device handler. Type a bit, then CLOSE the window
   (`EndCLI` or the close gadget). The process keeps running idle with
   its handler still installed - the leak B5 fixes.
3. From your boot AmigaShell (NOT a CCON: window), run `ccdie`.
   - `DOSTRUE ... tearing down` = it agreed to die.
   - `DOSFALSE ... refused` = a CCON: window is still open; close it.
4. Confirm no guru, then `NewShell CCON:` again - a fresh handler
   should start and keys should echo correctly. A crash, or keys
   misbehaving, means the teardown was wrong.

SAVE AN FS-UAE STATE before step 3: a teardown bug can hang the
machine (reset recovers). Fallback build: `Copy L:ccon-handler-1.2b12
L:ccon-handler` (before B5), then reboot.

## edanchortest.e - runs on Linux

A small standalone program that recreates the console's edit-line
bookkeeping over a fake screen, so a bug can be reproduced in seconds
without booting anything.

```
ecompile edanchortest.e edanchortest
vamos edanchortest
```

It prints its own verdict. Three scenarios:

- **A** - the bug: a full-width line, then typing, then Enter, with
  content on the row below. Reports how many cells were destroyed.
- **B** - the control: the same thing with a blank row below. Nothing
  should be destroyed. This is what proved the bug needs content
  underneath, which the audit originally got wrong.
- **C** - the guard on the fix itself: a normal prompt, where the
  erase must still happen. This one caught the first version of the
  fix being wrong, so do not delete it.

Written for audit finding B1 (fixed in 1.2b3). Re-run it if anything
in `eraseedit()` or `drawedit()` is ever touched again - it either
says the numbers still line up, or it says you just broke something.

## reflowtest.e - runs on Linux

Recreates the scrollback ring and the resize reflow over fake data,
so the wide->narrow->wide round trip can be proved without booting.

```
ecompile reflowtest.e reflowtest
vamos reflowtest
```

Seven checks with its own verdict: the round trip keeps the text, line
boundaries survive a narrow pass, a grow re-joins a wrapped line,
full-width rows stay separate lines (a hard newline is not a wrap),
ring overflow keeps the NEWEST content, the cursor stays in the grid,
and the edit anchor lands after its prompt. Written for B7 (fixed in
1.2b10). Re-run it if `reflowring()` or the `sw` wrap plane is
touched - it caught four defects during development, including a
destination row not cleared on ring wraparound.

## sbmaxtest.e - runs on Linux

Carries `visrow()`'s two lines of ring-index arithmetic verbatim and
sweeps every `(sbtop, row)` pair, reporting the worst index each
geometry can produce against the plane's real bounds.

```
ecompile sbmaxtest.e sbmaxtest
vamos sbmaxtest
```

Written for audit3 C1: `openwin()` floored the model depth at 100 lines
and never compared it to the window's row count, while every ring
accessor corrects its wrap with a single subtraction. The harness
reproduces the escape as a computed index - `sbmax=100, rows=126`
reaches 124 in a plane whose legal range is 0..99 - and then pins the
boundary: the escape begins at `rows >= sbmax + 2`.

That result **corrected the fix's own reasoning**, which is why the
harness exists rather than an argument. The index minimum is
`sbmax >= rows - 1`, not the `rows + 1` first claimed; the shipped
floor is `rows + 2` for a different reason, namely that `sbmax - rows`
is also the scrollback capacity, so the bare index minimum would buy a
safe ring with no history in it. Re-run it if the floor in `openwin()`,
the clamp in `doresize()`, or any of the ring accessors change.

## ccon-b1, ccon-b1-fill, ccon-b1-off - run on the Amiga

The same bug, on real hardware. Copy all three into `S:` on the Amiga
side, then:

```
Execute S:ccon-b1
```

The screen fills with rows of `#` and the prompt goes invisible - that
is deliberate, it is only a cursor move. Then type:

```
Echo x >NIL:
```

and press Enter. Look at the row directly below the echoed command.

- a gap punched into the `#`, as wide as what you typed = **broken**
- an unbroken row of `#` = **fixed**

Put your prompt back with:

```
Execute S:ccon-b1-off
```

The invisible prompt is `CSI 7;999H`. The console clamps the column to
the real window width, so this parks the cursor exactly on the right
edge at any window size - no counting characters, no need to know how
wide the window is.

`ccon-b1-fill` contains raw escape bytes and is marked `binary` in
`.gitattributes` so the bytes stay exact.

## ccon-b2, ccon-b7 - run on the Amiga with Execute

Two more `Execute` scripts, same shape as ccon-b1 (they start with `;`
and drive a `Type` of their own `-fill` companion).

- **ccon-b2** - `Execute S:ccon-b2`, then drag the window TALLER.
  Written for B2 (grown window pulling history down, 1.2b7). The new
  bottom rows should continue the numbered sequence in order, not show
  old rows out of order.
- **ccon-b7** - `Execute S:ccon-b7`, then shrink the window NARROWER
  than the text and grow it back. Written for B7 (reflow on resize,
  1.2b10). The ruler and `B7-END` marker must survive the round trip;
  they re-wrap mid-token at the narrow width and come back intact on
  grow. Run it under stock `CON:` too - that is the parity target.

## The older console tests - run on the Amiga with Type, NOT Execute

Same idea, written earlier for other fixes. These are RAW-BYTE files
(they start with the escape sequences themselves, e.g. `t1 ...`), so
run them with `Type`, e.g. `Type S:ccon-bisect` - NOT `Execute`, which
makes the shell try to run the first bytes as a command and answer
`Unknown command`. (The `ccon-b*` scripts above are the opposite: they
start with `;` and want `Execute`.) Each one prints what it expects on
the line above what it actually did, so a pass is just "the two lines
match".

- **ccon-bisect** - five overprint cases (carriage return, cursor
  moves, insert, delete). This is the main regression check for the
  edit line and the scrollback model: if a change breaks the console's
  handling of client text, this is usually what notices.
- **ccon-progress** - progress-bar style overprints, the kind a
  program makes when it rewrites `50%` into `51%` on the same row.
- **ccon-ichdch** - insert-character and delete-character.
- **ccon-styles** - italic, underline, inverse and colour.
- **ccon-osc** - a program retitling the window, and the scrollback
  indicator appending to that new title rather than stomping it.

All three of the first ones passed after the 1.2b3 fix; they are the
gate to re-run whenever the edit line or the model changes.

These are fed to the console byte for byte - the escape sequences and
the bare carriage returns are the test - so they are marked `binary`
in `.gitattributes` and must not be "tidied up" by anything that
rewrites line endings.
