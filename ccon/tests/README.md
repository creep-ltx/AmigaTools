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

## Related, still only on the Amiga side

`S:ccon-bisect`, `S:ccon-progress`, `S:ccon-ichdch`, `S:ccon-styles`
and `S:ccon-osc` are the older console tests. `ccon-bisect`,
`ccon-progress` and `ccon-ichdch` are the regression check for this
area - they all passed after the 1.2b3 fix. They are not in the repo
yet and would be worth copying here for the same reason these are.
