-> ccon/tests - the test files for the audit fixes
-> Kept in the repo on purpose. The Amiga-side ones normally live only
-> inside the FS-UAE disk image, which means they vanish the moment
-> that image is rebuilt; the point of these was to make a bug
-> provable rather than merely claimed, so they are saved here too.

# CCON tests

Two kinds. One runs on Linux and proves the logic; the others run on
the Amiga and prove the real thing.

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

## The older console tests - run on the Amiga

Same idea, written earlier for other fixes. Copy into `S:` and run
with `Type`, e.g. `Type S:ccon-bisect`. Each one prints what it
expects on the line above what it actually did, so a pass is just
"the two lines match".

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
