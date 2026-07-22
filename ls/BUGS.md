-> BUGS.md - ls known bugs. Logged, not yet fixed.
-> ls 0.2 (20.7.26). Evidence lives in the entries; reproduce before
-> fixing, root-cause before trusting.

# ls bugs

## B1 - `ls -R` recurses into itself forever (empty-named entries)

**Found:** 22.7.26, running `ls -R DH0:` on the FS-UAE system drive.
Under CCON it froze the whole machine (see the CCON side separately -
ccon/audit2.md B12; that freeze is CCON's, this loop is ls's). Under
ViNCEd it did not freeze but looped visibly, and the output redirected
to a file (`>Amiga:lsoutput.txt`) is the evidence below.

**Symptom:** `-R` gets stuck re-listing the SAME directory forever. In
the captured dump it cycles on `DH0:AmigaTools/cmenu/` and
`DH0:AmigaTools/mvtest/` - note the TRAILING SLASH - re-emitting each
directory's contents endlessly:

```
DH0:AmigaTools/cmenu:        <- first pass, CORRUPTED (see below)

<5 blank lines>
background
bgdebug.log
cmenu
CMenu.config

DH0:AmigaTools/cmenu/:        <- re-listed, trailing slash, contents CORRECT
background
bgdebug.log
cmenu
CMenu.config
config-screen.txt
debug-hello.txt
header
hello
unused-headers
...                          <- and cmenu/ is queued again, forever
```

**Two layered defects:**

**(a) Entries come out with EMPTY names (the root).** `cmenu` really
holds 9 entries (correct in the `cmenu/` re-listing). Its FIRST listing
showed only 4 real names plus 5 BLANK lines - five entries lost their
`name`. Empty strings sort first, so they surface as the leading blank
rows. The re-listing of the same directory a moment later has all 9
names intact, so this is intermittent: the signature of a HEAP
OVERWRITE or an entry-collection bug, not a filesystem condition.

Suspects, unconfirmed - needs a vamos harness on `listdir`/`mkent`/
`output` to root-cause, do NOT guess-patch:
- the `dent` OBJECT has TWO char arrays (`name[110]` then `comm[80]`),
  and `name` is NOT last. amiga-e handler notes: "put CHAR arrays LAST
  for alignment." NAMELEN=110 is even so `comm` stays longword-aligned,
  which weakens this theory - but two trailing arrays is exactly the
  shape that bites, worth ruling out first.
- `gline := String(700)` is the shared line-format buffer; a `-R` child
  path plus a long name plus the long-format columns overrunning 700
  would corrupt whatever New() handed out next - and dents are New()'d.
- `AstrCopy(e.comm, fib.comment, 80)` into `comm[80]`: a full 80-char
  comment leaves no room for a terminator, so a later StrLen(comm) runs
  into the next object. Affects comm, not name, directly - but it is a
  latent overrun in the same struct.

**(b) An empty-named DIRECTORY entry recurses into the parent (the
amplifier).** `ls.e:505-506` builds each child path with
`AddPart(node.path, e.name)`. When a kept `isdir` entry has an empty
name, `AddPart("DH0:AmigaTools/cmenu", "")` yields
`DH0:AmigaTools/cmenu/`, and `Lock()` resolves a trailing slash right
back to `cmenu`. So `-R` queues `cmenu` as its own child and descends
into it forever. The path length stays FIXED (`cmenu/`, never
`cmenu//`), so memory is bounded - it loops, it does not leak.

**There is no cycle guard.** Even without the empty-name bug, a real
directory soft-link pointing at an ancestor would loop `-R` the same
way. `sortout()` queues every `isdir` child unconditionally.

**Fixes, in order:**
1. Defensive, cheap, stops the freeze now: in the `-R` queue loop
   (`sortout` :500-515) skip any entry whose `name[0] = 0`, and/or after
   `AddPart` skip if the child path is empty or ends in `/`/`:` (a
   self-reference). One line guards the observed loop.
2. Real cycle guard: track visited directories by a stable key
   (`fib.diskkey` + the volume's `DosList`/lock) and refuse to queue one
   already on the pending list or already visited. Fixes link cycles too.
3. Root-cause (a): harness `listdir` over a fake/real directory under
   vamos, dump each `mkent`'d `e.name`, and find where the 5-of-9
   blanking happens. Until that is understood, 1+2 only mask it -
   the same corruption may show elsewhere (wrong sizes, wrong dates).

**Console-independent - it is ls, not the console (proved 22.7.26).**
First it looked like a CCON bug (froze CCON, ViNCEd survived a `DH0:`
run). But running the EXACT freezing command (`ls -R Amiga: >file`) under
ViNCEd froze ViNCEd identically - mouse dead, Ctrl+C dead, hard shutdown.
Same client, same target, BOTH consoles hard-lock. So `ls` corrupts the
shared heap badly enough to take down an AmigaOS box (no memory
protection) whichever console hosts it. The "ViNCEd survived" run earlier
was a TARGET difference (`DH0:` got stopped before the fatal overwrite),
not a console one. CCON audit2.md B12 is CLOSED as misattributed.

**Extra evidence for (a) being a HEAP OVERWRITE:** a second capture
(`Amiga:Download`, ~26 entries) showed the blank count shrinking by
exactly 4 across successive re-listings - 18, 14, 10, 6 blanks, names
filling in alphabetically - i.e. as the heap layout drifts each
iteration, fewer `dent` name buffers land in the clobbered region. That
progressive, regular drift is a heap-overwrite fingerprint, not a
filesystem race. The freeze came FAST (~4 re-listings, 1320 bytes), so
the overwrite reaches something fatal quickly once `-R` starts looping.

## Status

**B1 loop GUARDED in ls 0.3 (22.7.26)** - fix (1) applied: `sortout`'s
`-R` queue now skips `isdir` entries with an empty name
(`IF e.isdir AND (e.name[0] <> 0)`), so a blank-named entry can no longer
produce the `path/` self-reference that made `-R` recurse into the same
directory forever. This stops the machine-freezing runaway regardless of
WHY the name blanked. Compiled clean (ls.e 0.3, +28 bytes). NEEDS AN
AMIGA BOOT TEST: `ls -R Amiga:` should now traverse and TERMINATE
instead of freezing.

**GUARD CONFIRMED ON HARDWARE (22.7.26).** With ls 0.3, `ls -R Amiga:`
under BOTH CCON and ViNCEd traverses real subdirectories with NO
self-recursion (`grep '/:$'` on both captures: empty) and does not freeze
- the loop and the machine-freeze are gone. Side effect of the guard, as
expected: when a DIRECTORY's name blanks it is skipped (not recursed),
so `-R` is now safe but INCOMPLETE when the corruption hits a subdir -
e.g. `Download/LZX_Y2Kfix` was recursed in the ViNCEd run (name survived)
and skipped in the CCON run (name blanked). The two captures diverge
because different subdirs blank per run.

**STILL OPEN - the name corruption (root cause), and it is AMIGA-SPECIFIC.**
The guard stops the fatal loop but not the blanking (still 17-18 blanks
in `Download`'s ~26 entries, intermittent per run). NEW evidence: it does
NOT reproduce under vamos - a 27-entry `Download`-shaped directory listed
recursively on Linux comes out PERFECT, every name present, zero blanks.
So it is not a plain logic bug in `listdir`/`sortout`/`mkent`/`sortarr`
(those run identically under vamos and are clean). It depends on
something the real Amiga does and vamos does not: real FFS `Examine`/
`ExNext` behaviour, `gfib` alignment/reuse against a real filesystem, or
the Amiga memory allocator's fragmentation state after the `-R` `pnode`
churn. Root-causing it therefore needs AMIGA-SIDE telemetry (a dbglog-
style instrumented ls that dumps each `ExNext` filename and each mkent'd
`e.name`), NOT a Linux harness. Do NOT guess-patch. A visited-directory
cycle guard (fix 2) is still worth adding for real soft-link cycles,
independently.

`ls -a`/`ls -1` on a single directory are unaffected (no recursion); only
`-R` reaches any of this.
