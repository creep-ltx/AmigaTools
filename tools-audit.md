# tools-audit.md — ls / cp / mv / mkdir code audit + rm plan

Audited 27.7.26 against ls 0.3.2, cp 0.1.1, mv 0.4, mkdir 0.1 (all
sources read end-to-end, 2174 lines, plus ls/BUGS.md history). Verdicts:
CONFIRMED = the defect is provable from the code as read; PLAUSIBLE =
needs a repro before fixing. House rules assumed throughout: reproduce
before fixing, root-cause before trusting (the B1 lesson: every
guess-patch made before the vamos reproducer was wrong).

Overall verdict: this family is in good shape. The Dispose/END class is
fully exorcised (B1, 24.7.26), the work-list-not-recursion and
16-bit-division disciplines hold everywhere, error paths consistently
IoErr()-before-WriteF, and mkdir is clean end to end. What the audit
found is one shared argument-cap hazard, one Ctrl+C double-free window
in ls, and a short tail of behavior gaps — plus the rm design at the
bottom.

---

## A — findings common to all four tools

### A1 — MAXARGS overflow silently drops arguments; in cp/mv the
### dropped one is TO  [CONFIRMED, the one real hazard in this audit]

`parseargs` collects at most MAXARGS=32 paths; the 33rd and later
tokens are silently ignored (`IF np < MAXARGS` ... else nothing, not
even a message).

For ls and mkdir that is silent incompleteness. For cp and mv it is
worse: `gto := paths[npaths-1]` — the last *collected* path becomes TO.
With 33+ arguments the real destination is the token that got dropped,
and **the 32nd source is promoted to TO**. The multi-source guard
("TO must be an existing directory") catches it when the 32nd source is
a file — but when it is a directory (entirely plausible in a long batch
move), every earlier source is copied/moved INTO a directory the user
named as a *source*. `mv` relocates 31 files somewhere unintended;
with `-f` it will also delete same-named targets inside it. No data is
destroyed outright, but files land far from where the command said.

33 explicit tokens is rare interactively and routine in generated
scripts (`List LFORMAT >script` is the house idiom, commands.txt).

Fix (all four): when a path arrives and `np` is already MAXARGS, error
out — `Throw("ARG"...)`-style hard stop, "too many arguments (max 32)".
Never silently truncate an argument list whose last element is load-
bearing. One added ELSE per tool.

### A2 — parseargs/setflags/checkbreak/setrc are quadruplicated
### verbatim  [maintenance note, not a bug]

~90 lines of identical tokenizer per tool, and rm will make it five.
A1's fix has to be applied four (five) times — exactly the failure mode
duplication invites. Options: (a) live with it — each tool stays a
single self-contained .e, the house preference; (b) a small shared
module (`tools/targs.m`) exporting the tokenizer with a per-tool flag
callback. Recommendation: (a) for now, revisit if a third shared change
lands. Either way A1 goes in via careful ×4 application, verified by
`grep -c 'too many arguments'` = 4.

### A3 — no `--` end-of-options  [polish, park]

A file literally named `-something` cannot be addressed — the leading
dash always parses as flags (or throws ARG). Unix solves this with
`--`. Park: rename such a file with quotes… also impossible (quotes
don't stop flag detection — `"-x"` still starts with `-`). If it ever
bites, the fix is the Unix one: a bare `--` token stops flag parsing.
Worth doing when rm lands (rm is where `-`-named junk files need
deleting).

---

## L — ls 0.3.2

### L1 — Ctrl+C during pattern output double-frees the anchor
### [CONFIRMED — crash window, the audit's top fix]

`listmatches()` (ls.e:367): the normal path runs `MatchEnd(ap);
Dispose(ap)` and then goes on to `sortout(head, ...)` — and `sortout`
→ `output` → `checkbreak()` can `Throw("BRK")`. The EXCEPT block tests
`IF ap` — but `ap` was never NIL'd after the normal-path Dispose — and
runs `MatchEnd` + `Dispose` a second time on the freed pointer.
MatchEnd on an already-ended anchor walks freed achain memory and
Dispose double-frees — heap corruption of exactly the class B1 spent
two days exorcising, triggered by nothing more exotic than Ctrl+C
while a pattern listing prints.

cp and mv are immune by shape: their per-match work happens inside the
match loop, nothing throwable runs after their normal MatchEnd.

Fix: `ap := NIL` immediately after the normal-path `Dispose(ap)` (the
EXCEPT guard then does its job). Two lines. A vamos repro is easy if
wanted: pattern-match a big directory and SetSignal a fake break before
output.

### L2 — no cycle guard: `-R` follows a directory soft-link into an
### ancestor forever  [CONFIRMED by design reading; BUGS.md fix-2,
### still open, carried into this audit]

`sortout` queues every kept `isdir` child unconditionally (the
empty-name guard only catches blank names). A `MakeLink SOFT` loop —
the "famously half-broken corner" (commands.txt) — loops `-R` forever
at bounded memory. Fix per BUGS.md: a visited set keyed on
`fib_DiskKey` + volume identity, checked before queueing; refuse
re-entry. Also stop *descending* soft-links at all: `ExNext` reports
`fib_DirEntryType = ST_SOFTLINK` (3) for them — list the link, never
queue it (matches Unix `ls -R`, which does not follow symlinks).
The diskkey set then remains as defense in depth against hard-link
cycles only.

### L3 — BUGS.md suspect (comm[80] overrun) is RETIRED  [verified]

`AstrCopy(e.comm, fib.comment, 80)` clamps to 79 chars + NUL —
AstrCopy's max includes the terminator. The FIB comment field is 80
bytes likewise. No overrun exists; BUGS.md's third suspect paragraph
can be struck on the next BUGS.md edit.

### L4 — gline can clamp on wide terminals, bleeding color
### [PLAUSIBLE — needs a wide-console repro]

`gline := String(700)` but a row costs up to `twidth` name/pad chars
plus ~10 bytes of CSI per colored entry. On a wide RTG shell (240
cols, many short names → ~80 columns × ~12 bytes ≈ 960) the E-string
clamps: silent truncation, and if the cut lands between a color-on and
its `CSI 0m`, the grey/blue bleeds into everything after. Never seen on
the 77/91-col dailies — width is the trigger. Fix: allocate gline
after termwidth() as `String(Mul(twidth,12)+64)`, floor 700.

---

## C — cp 0.1.1

### C1 — `cp -r` into its own subtree runs away  [CONFIRMED by
### design reading; documented as "don't" in the header]

`cp -r dir dir/sub` (or `cp -r #? to` where `to` matches the pattern):
`copydir` scans src *while* the growing destination sits inside it —
each pass re-copies the copies. Bounded only by disk space; filling a
volume is destructive-adjacent, and this family's charter is
non-destructive by default. The docs saying "don't" was fine for 0.1;
the guard is cheap enough to owe: before `copytree`, Lock(src), then
walk dst's ParentDir() chain comparing `SameLock` — a hit refuses with
"cp: cannot copy \s into itself". Costs a handful of locks once per
tree.

### C2 — `-f` deletes the target before the copy is known to succeed
### [design note, decide-and-document]

`prepfile` DeleteFile()s the old target, then `copyfile` may still fail
(source unreadable, disk full) — old target gone, new one deleted as
partial: net data loss of the *target* on a failed copy. Unix cp -f has
the same shape, but ours could do better: copy to `<name>.cptmp` in the
target dir, then delete+Rename on success. Verdict wanted: safer-swap
(more code, temp-name cleanup paths) vs document-the-Unix-shape. Either
outcome should be written down in cp.readme.

### C3 — cross-tool consistency: cp preserves the filenote, mv does not
(see M1 — the fix belongs in mv).

---

## M — mv 0.4

### M1 — cross-volume move drops the filenote  [CONFIRMED]

`copymove()` carries protection + datestamp but never `SetComment` —
a same-volume `mv` (pure Rename) keeps the note, a cross-volume one
silently strips it. cp preserves it (`copyfile` does all three). Fix:
`Examine` already ran (ifib) — add the two lines cp has, guarded on
`ifib.comment[0]`.

### M2 — cross-volume directory move is refused  [feature gap, pairs
### with rm]

Documented and honest ("not supported"), but it is the remaining
Rename-vs-mv gap (commands.txt calls Rename's refusal "the canonical
one"). The machinery is already written: cp's copytree + the post-order
delete rm needs anyway. Plan: after rm 0.1 proves the deltree engine,
mv 0.5 = copytree(src,dst) + rm's post-order delete of src on full
success (any skip/failure leaves the source untouched, delete nothing —
all-or-nothing per tree, no half-moved state).

### M3 — `mv #? dir` where dir matches the pattern  [verified OK,
### add to test deck]

`Rename(dir, dir/dir)` — the filesystem refuses moving a directory
into itself (object-in-use class error), reported, batch continues.
Correct by accident today; a test row keeps it correct on purpose.

---

## K — mkdir 0.1

### K1 — `-p` reports a mid-path FILE obstruction one component late
### [CONFIRMED, cosmetic]

`makestep` maps ERROR_OBJECT_EXISTS → success without checking WHAT
exists; a file at `a/b` in `mkdir -p a/b/c` "succeeds" at b, then c
fails with a generic fault naming the wrong component. `makefinal`
already has the isdir() check and the right message ("exists and is
not a directory") — makestep should use the same on the EXISTS path.
Otherwise mkdir is the cleanest of the four; nothing else found.

---

## rm — the plan (rm 0.1)

The missing family member; C:Delete exists but `rm` is the muscle
memory, and Delete ALL's prompt-less recursion is exactly what this
family would NOT ship. mv-shaped source (~450 lines), same tokenizer
(A1 fix included from birth), same rc convention (0/5/10/20), same
"not deleted:" summary list.

Usage: `rm [-rfv] FILE | PATTERN ...`

Semantics, in family style — non-destructive bias throughout:

- **Plain files**: MatchFirst/MatchNext per argument (patterns and
  names uniform, as cp/mv). DeleteFile; failure reported, batch
  continues. No match without -f = error ("no match"), rc 10 — Unix rm
  manners.
- **Delete-protected files** (the d-bit — the Amiga's own safety):
  refused by default, listed under "not deleted:" (rc 5). With `-f`:
  SetProtection(path, 0) then retry — that is what force *means* on
  AmigaDOS. In-use files (ERROR_OBJECT_IN_USE) always refuse — -f
  cannot unlock another task's file.
- **Directories**: refused without `-r` ("use -r"), like cp. With
  `-r`: explicit work-list walk (never native recursion — the ls -R
  lesson), each directory fully ExNext-scanned into a collected list
  BEFORE any delete inside it (never delete under a live ExNext — the
  filesystem-invalidates-the-walk rule, cfile's deltree lesson), files
  deleted as encountered, subdirs queued; every visited directory is
  pushed on a LIFO and the LIFO unwound at the end — deepest first, so
  each rmdir meets an already-emptied directory. A directory that
  refuses to empty (protected/in-use child) leaves its whole parent
  chain standing, each reported once.
- **Soft-links**: never descended (ST_SOFTLINK entries get
  DeleteFile on the link itself, with or without -r) — deleting a
  link must never delete through it, and not following them kills the
  cycle risk in the same line.
- **Volume roots are refused unconditionally**: `rm -rf dh0:` answers
  "rm: refusing to remove a volume root" and rc 10. No override flag
  in 0.1 — Format and Delete ALL exist for the one day a decade that
  is really meant. Detection: the path, with a possible single
  trailing '/' stripped, ends in ':' — plus the empty-name guard.
- **-v** prints each path as it goes (default silent, Unix manners);
  Ctrl+C honoured between entries; NEW/END discipline (the B1 rule)
  on every node from day one; no -i in 0.1 (per-file prompting wants
  raw-console plumbing and EOF semantics — 0.2 if wanted).

Test deck for the boot pass: plain file / pattern / no match with and
without -f / d-bit file ± -f / in-use file / empty dir ± -r / nested
tree -r / tree with protected leaf (parents must survive) / soft-link
to file and to dir / `rm -rf ram:t` full round-trip / volume root
refusal / 33-argument line (A1).

---

## Suggested ladder

(Version rule, his call 27.7.26: one +0.0.1 per tool for the whole
fix batch — 0.x bumps are for features. Steps 1–5 DONE 27.7.26, all
vamos-green, deployed to FS-UAE C:, committed individually.)

1. **ls 0.3.3** — DONE @e4810f9. L1 (ap := NIL), L2 (softlink
   no-descend + diskkey set, zero keys stand down), L4 (gline from
   twidth), A1. A/B vs 0.3.2 on the system-drive tree: byte-identical
   across 2920 lines.
2. **cp 0.1.2** — DONE @da00c83. A1, C1 (self-subtree refusal — via
   NameFromLock canonical-path prefix, NOT SameLock/diskkey: both
   probed unusable under vamos, SameLock always DOSTRUE and keys
   per-lock-instance), C2 documented in cp.readme (decided: document
   the Unix shape, no temp-and-swap).
3. **mv 0.4.1** — DONE @dd89a08. A1, M1 (filenote).
4. **mkdir 0.1.1** — DONE @f612fcb. A1, K1.
5. **rm 0.1** — DONE @3161ff7. The plan below, built as planned;
   vamos deck green incl. post-order tree delete and volume-root
   refusal. d-bit ±-f rows need real FFS = the boot deck.
6. **mv 0.5** — DONE 27.7.26 (post boot-green): cross-volume
   directory move, all-or-nothing per tree (any copy failure wipes
   the partial destination and leaves the source untouched; clean
   landing required; roots and link-bearing trees refused). vamos
   caveat discovered en route: Rename never fails ACROSS_DEVICES
   there (os.rename on one host fs; ALL failures map to
   OBJECT_IN_USE), so the deck ran through a force-the-tree-path
   test build + a FAIL.txt-throw injection — full move, renamed
   landing, existing-dst refusal, mid-tree abandon (dst wiped,
   source diff-identical), root refusal, all green. The trigger
   condition itself (RENAME_ACROSS_DEVICES on dirs) is real-DOS
   behaviour, boot-proven by 0.4's refusal message. Boot row GREEN 27.7.26:
   real cross-volume dir move on the Amiga, both files and the
   filenote survived ("mv boot test green"). LADDER CLOSED 1-6,
   every row proven.

Boot deck: **ALL GREEN 27.7.26** ("All tests green!") — rm's d-bit
pair, the protected-leaf-parents-survive row, in-use refusal and
volume-root refusal, ls Ctrl+C pattern break and the FFS soft-link
loop, cp self-subtree refusal, mv cross-volume filenote, mkdir
wrong-component fix. The batch is boot-proven; step 6 unblocked.
