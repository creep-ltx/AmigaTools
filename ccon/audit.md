-> audit.md - CCON codebase audit, ccon-handler 1.2b1
-> Read 20.7.26 against ccon-handler.e as of 1.2b1 (5549 lines).
-> Line numbers are as-of that revision and will drift once fixes
-> land; every finding names the PROC too, which will not.
->
-> Static read only - nothing here was boot-verified. Findings are
-> ranked by whether the trigger is REACHABLE, not by how bad the
-> consequence sounds; where a trigger needs a specific sequence to
-> fire, that sequence is spelled out so it can be tested rather
-> than argued about. See audit-fix-roadmap.md for the order to
-> work them in.

# CCON 1.2b1 audit

Scope: `ccon-handler.e`, the whole file. Cross-checked against
`todo.md` so nothing already logged there is reported as new.

## Status

| Finding | State |
|---|---|
| P1, P2, P4, H1, H2, H5 | **fixed in 1.2b2** (batch 1, boot-tested 21.7.26) |
| B1, H4 | open - batch 2 |
| B2, B4 | open - batch 3 |
| B3 | open - batch 4 |
| P5 | open - batch 5 |
| B5, B6 | open - batch 6, decision first |

The findings below are kept as written at audit time, including for
the ones now fixed - the reasoning is the record of WHY the change was
made, and 1.2b2's todo.md entry points back here. Line numbers are
as-of 1.2b1 and have drifted; the PROC names have not.

---

## 1. Bugs

### B1 - `eraseedit()`'s early returns skip the `edlast`/`edext` reset

**Where:** `eraseedit()`, ccon-handler.e:3445-3489.

Two guards return before the reset at the bottom of the proc:

```
IF curcon.win = NIL THEN RETURN
IF curcon.ancx >= curcon.cols THEN RETURN  -> inverted RectFill = wild writes
...
curcon.edlast := 0                         -> not reached on either path
curcon.edext := 0
```

The b9 note (todo.md:1264) states why that reset exists: *"eraseedit
now zeroes edlast/edext after erasing so the tail never re-cleans at
a moved anchor (the theft pattern must not come back through the back
door)."* The `ancx >= cols` guard is the back door.

**Trigger, reachable:** `render()`'s printable-run loop leaves
`cx = cols` whenever a write ends exactly at the right margin
(`fit := cols - cx; cx := cx + fit`) - the pending-wrap state
documented as legal at `doresize` (:1857). `reanchor()` then parks
`ancx = cols`. On the NEXT `dowrite()`:

1. `eraseedit()` returns at once; `edlast` keeps N from the old anchor
2. `render()` writes new client text
3. `reanchor()` moves the anchor
4. `drawedit()` reads `oldl := curcon.edlast` = N and, where
   `oldl > l`, zeroes `N - l` model cells from the NEW anchor

**Consequence:** client text erased from the model at a moved anchor -
the exact theft pattern b9 closed, re-entered through the guard.
Any output whose last line is exactly `cols` wide qualifies: full-width
`ls` output, box drawing, a progress bar that fills the row.

**Fix:** zero `edlast`/`edext` before both `RETURN`s, or restructure so
the resets cannot be bypassed.

---

### B2 - `sbcnt` is not re-clamped when the window grows

**Where:** `doresize()`, ccon-handler.e:1825 (immediately after
`gridcalc()`).

The ring invariant is `sbcnt <= sbmax - rows`. `screenscroll()`
(:1829) enforces it on the way up. Nothing re-establishes it when
`gridcalc()` INCREASES `rows` underneath an already-large `sbcnt`.

**Trigger:** fill the scrollback, then enlarge the window.

**Consequence:** `scrollview()` clamps `viewoff` to a now-too-large
`sbcnt`; `redraw()`'s `idx := sbtop - viewoff + r` wraps into ring rows
the enlarged visible grid has already overwritten. Scrolling to the far
end shows duplicated or stale rows. Cosmetic, but it looks like model
corruption and will be reported as such.

**Fix:** after `gridcalc()` in `doresize()`:

```
IF curcon.sbcnt > (curcon.sbmax - curcon.rows)
  curcon.sbcnt := curcon.sbmax - curcon.rows
ENDIF
```

---

### B3 - a full input queue truncates CSI reports mid-sequence

**Where:** `enqueue()` :5507; callers `ihreport()` :4758,
`sendreport()` :3211, `rawcsikey()` :4335.

`enqueue()` drops silently PER BYTE. Every report path emits a
multi-byte sequence one `enqueue()` at a time, so a full queue
delivers a PARTIAL CSI.

**Consequence:** worse than dropping the event. A truncated report
desyncs the client's CSI parser permanently; a dropped one costs a
single event. This is the failure mode that reads as "Ed went mad"
rather than "Ed missed a key".

**Trigger:** a client holding a fat `evmask` (e.g. `CSI 2{` mouse
reports) that stops reading. `ihreport` is ~50 bytes/event against
`INQMAX` 2048 - roughly 40 events fills it.

**Fix:** make reports atomic. Either check
`inavail() + needed < INQMAX` before the first byte and drop the whole
report, or add `enqueuestr(buf, len)` that does the check once. The
report builders already know their length (`StrLen(b)` + introducer +
terminator).

---

### B4 - a failed AUTO `openwin()` retries forever and accretes into the title

**Where:** `openwin()` :1534 (`IF curcon.win = NIL THEN RETURN`) vs
:1706 (`curcon.autopend := FALSE`).

`autopend` is cleared PAST the failure return, so `ensurewin()` (:1387)
retries `openwin()` on every subsequent packet for that console.

**Consequence:** repeated `LockPubScreen`/`OpenWindowTagList` per
write/read/wait; and in the `ihon = FALSE` fallback,
`StrAdd(curcon.wtitlebase, ' [no chain]')` (:1483) runs each time -
the title fills with `[no chain] [no chain] [no chain]...` up to
`wtitlebase`'s 84-char cap.

**Fix:** clear `autopend` (or set a separate `autofailed`) on the
failure path so a windowless AUTO console stops retrying.

---

### B5 - no `ACTION_DIE`

**Where:** `dopkt()` `DEFAULT` arm, :989.

Unmount/shutdown answers `ERROR_ACTION_NOT_KNOWN`. `main()` is
`WHILE TRUE` with no exit, so `ihring`, `ihis`, `fhstub`, the
input-chain hookup and the opened devices are never released.

**Consequence:** not a leak in a live system (the process is
immortal by design), but a mount/unmount cycle during development
leaves the previous chain handler installed. That is a
development-time hazard on the machine doing the boot tests.

**Fix:** a `CASE ACTION_DIE` that refuses (`DOSFALSE`) while
`conlist` is non-NIL, and otherwise removes the handler, closes the
devices and exits.

---

### B6 - `conbysender`'s list-head fallback is wrong for `ACTION_DISK_INFO`

**Where:** `conbysender()` :665, `ENDPROC conlist` at :696;
`ACTION_DISK_INFO` arm :955.

When the CLI-StandardInput, breaktask and active-window lookups all
miss, the caller gets SOMEONE ELSE'S console.

For `WAIT_CHAR`/`SCREEN_MODE` that is a harmless wrong answer. For
`DISK_INFO` it hands out `id.volumenode := curcon.win` - a window
pointer for a console the caller has no relationship with, which a
client like More will then `SetWindowTitles` and draw into.

**Fix:** fail `DISK_INFO` (`DOSFALSE`, `ERROR_OBJECT_NOT_FOUND`)
rather than guess. Guessing is defensible for the packets where the
wrong answer is merely wrong; it is not defensible for the one that
hands out a drawable window.

---

## 2. Performance

All of these sit in per-keystroke or per-byte paths, which is where
7MHz is actually felt.

### P1 - `curattr()` called once per cell in the main text path

**Where:** `render()` :3388.

```
FOR j2 := 0 TO fit - 1
  m[j2] := curattr()
ENDFOR
```

`curattr()` calls `fgpen()`, which does up to five `curcon.`
indirections and branches. That is a nested call per character on the
hottest output loop in the program - an 80-column line pays 80 of
them. Nothing in the loop can change the SGR state.

**Fix:** hoist - `at := curattr()` before the loop.

### P2 - `Mod`/`Div` on a power-of-two constant

**Where:** `enqueue()` :5509, `inavail()` :5516, `satisfyreads()`
:5539.

`INQMAX` is 2048. Each `Mod(..., INQMAX)` is a DIVS, and `inavail()`
is a loop condition. The right idiom is already in the file for the
input ring (`ihring + Shl(n AND (IHMAX - 1), 5)`) - it just never
reached the byte queue.

**Fix:** `AND (INQMAX - 1)`.

### P3 - history lookups do a DIVS per entry, per keystroke

**Where:** `sgfind()` :4030, `srfind()` :3761, `histmatches()` :4084,
`histload()` :4093 - all `Mod(ghtotal - 1 - idx, HISTMAX)`.

`HISTMAX` is 200, not a power of two, so it is a real division.
`sgfind()` runs from `drawedit()` on EVERY keystroke and walks all 200
entries: worst case ~200 DIVS (~140 cycles each on 68000, ~4ms) plus
200 `StrLen`s of up to 400 bytes, per keypress.

**Fix, two independent halves:**

- replace the `Mod` with a decrementing index and a manual wrap
  (`i--; IF i < 0 THEN i := HISTMAX - 1`)
- give `sgfind()` an early `RETURN` after it sets `sghost`. It
  currently guards with `IF curcon.sghost = NIL` INSIDE the FOR and
  still iterates to 200 after a hit. `srfind()` has the same shape
  (`IF got = FALSE` inside the loop).

Note: the `Mod`-on-negative class already bit this codebase once -
todo.md:63, `hist[Mod(-1,32)]` on empty history. Current call sites
are bounded (`avail := Min(ghtotal, HISTMAX)`), so this is a speed
fix, not a correctness one - but the manual-wrap form removes the
class entirely.

### P4 - `curcon.` indirection in the paint loops

Every `curcon.cols` is a load of `curcon` followed by a load of the
field; E will not hoist it. In `drawmrow()`, `drawselrow()`,
`drawmodelcells()` and `render()`'s inner loops that is several
redundant loads per iteration.

**Fix:** cache `c := curcon` as a `PTR TO console` local at the top of
the paint procs and use `c.cols`. Shortens the lines as a side effect.

Same family, smaller:

- `drawselrow()` :2135-2137 calls `selvidx(r)` three times for one `r`
- `drawmrow()` :1992-1994 computes `Mul(idx, curcon.cols)` three times
- `inslines`/`dellines`/`scrollup`/`scrolldown` do 6 `Mul`s per row via
  the `visrow`/`sarow`/`ssrow` trio

### P5 - `savehistfile()` on every Enter

**Where:** `dovanilla()` commit path :4210; `savehistfile()` :5060.

Each call is `tcresolve('L:')` (a `LockDosList` + a `LOCATE_OBJECT`
round trip) -> `FREE_LOCK` -> `FINDOUTPUT` -> up to 200 lines rewritten
in 2KB `WRITE`s -> `END`. Roughly 6+ synchronous packet round trips and
up to ~16KB of file I/O, and the handler task is blocked in
`WaitPort(fsport)` for all of it - so EVERY CCON: window this process
serves stalls, not just the one that pressed Enter.

The reasoning for moving off last-window-close (todo.md:1474) is
right; the implementation is a full-ring rewrite where an append would
do.

**Fix, cheapest first:**

- keep the file open (`FINDUPDATE` + seek to end), write only the new
  line
- or: set a dirty flag and flush from the existing `timer.device` tick
  a few seconds later, so a burst of commands costs one write

**Related, worth a comment at minimum:** `fscall()` (:4786) has no
timeout on `WaitPort(fsport)`. A wedged or spinning-up filesystem
freezes every console this process serves - including the one that
would display the error. This is on the Tab path too, not just Enter.

---

## 3. Consistency and hardening

Not bugs. Each is a place where the invariant is held by argument
rather than by code.

### H1 - `port` is shadowed in the two procs where it deadlocks

`loadhistfile()` :5011 and `savehistfile()` :5061 both declare a local
`port:PTR TO mp` over the global packet port.

Correct today - `fscall()`'s `IF tport = port THEN RETURN 0`
self-deadlock guard resolves `port` in its own scope. But any future
edit inside those two procs that means "our packet port" silently gets
the filesystem's port, in the two procs where that mistake hangs the
machine.

**Fix:** rename the local to `fsp`.

### H2 - `wcq` depth is a bare literal

`RDMAX`, `WQMAX`, `INQMAX`, `TCMAX`, `IHMAX` are all named. The
WAIT_CHAR queue is `wcq[8]` (:208) with `curcon.wcn >= 8` hardcoded at
:906.

**Fix:** `WCMAX=8` alongside the others.

### H3 - `condispose` has no safety net for the model planes

`condispose()` :700 frees the ten E-strings but not `sb`/`sa`/`ss`/
`altm`/`alta`/`alts`/`tf`.

Currently sound: `closewin()` is only ever called from `conclose()`,
and its `win = NIL` early-return case provably cannot have allocated
planes (`openwin()` returns before the ring allocation on failure).
But that is an invariant held by argument, and `condispose` is exactly
where a future path would break it.

**Fix:** NIL-checked `Dispose` calls for all seven. Costs nothing and
makes the proc self-evidently complete.

### H4 - `drawedit` lacks the `ancx >= cols` guard `eraseedit` has

`eraseedit()` guards it (:3449); `drawedit()` (:3545) does not.

It happens to work out - the first mirror iteration computes `n = 0`
and rolls to the next row consistently with the blip math at :3634-3646
- but two procs that must agree on the same anchor disagreeing on its
legal range is the kind of thing that bites on the next edit.

**Fix:** add the guard, or a comment stating why it is not needed. See
also B1, which is the same guard causing a real bug at the other end.

### H5 - `ihdrop` is write-only

Incremented at :4639, never read.

**Fix:** surface it (title bar under a debug flag, or on the
`CSI n{` report path) or state in the comment that it is a
post-mortem field read only under a debugger.

---

## 4. What is right

Worth recording, because several of these are things that are
normally got wrong and they are the reason the rest of the file is
auditable at all.

**The no-DOS rule and its two escape hatches.** Recognising that
`DoPkt` waits on `pr_MsgPort` - the same port clients send to - and
then building two DIFFERENT legitimate escapes: a throwaway helper
process with its own `pr_MsgPort` for `OpenDiskFont` (:1419), and
hand-rolled exec-level packets on a private reply port for the
filesystem (:4786). Most handlers deadlock here and never learn why.

**Pointer validation as a discipline.** `conok()` (:608) checking
every console pointer arriving from `fh_Arg1` or a ring slot before
trusting it - and the comment noting that a LATER console could reuse
the same heap address, so scrubbing the ring (:732) is not redundant
with the list check. Right paranoia, right place.

**The chain/list concurrency design is correct for stated reasons.**
Single-writer `ihhead`/`ihtail` (lock-free, sound on 68k for aligned
longs); `Forbid`-bracketed list mutation with the note that
input.device is a TASK so `Forbid` genuinely holds it off; `armed` set
last in `openwin` and cleared first in `closewin` so a half-built
window takes nothing. Three independent layers, each justified rather
than assumed.

**Every parked packet is replied before the memory goes away.**
`closewin()` (:1723) covers this on both the windowed and windowless
paths; the `wcq`/`rdq` drains and `flushwq()` are unconditional.
Unreplied packets are the single most common way a handler hangs a
machine, and it is covered.

**Degraded modes instead of refusals.** Failed chain hookup -> IDCMP
fallback. Failed ring allocation -> console runs without scrollback.
Failed helper -> `OpenFont`. Failed resize realloc -> drop the model
rather than render through a wrong stride. Failed `ObtainBestPen` ->
-1 and no ghost. The right posture for a 2MB target.

**Reading the real binaries instead of guessing.** The `'CCON'` vs
`'CON\0'` DISK_INFO finding (:970) - disassembling ROM shell 47.47 at
`$669A` to discover that answering `'CON\0'` makes the shell keep its
OWN line editor - would have been unfindable by experiment. Same for
Ed's report dispatcher at `$1708` and the `$9B` vs `ESC[` split
between `ihreport` and `rawcsikey`.

**The commentary.** It records why, records what was verified against
what was assumed, and records abandoned designs and the reason they
were abandoned (b28's pilcrow markers; the parked `tcscancmd` at
:3163). That is what made this audit possible - intent could be
checked against implementation instead of reverse-engineered from it.
