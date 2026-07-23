# conbench

A console speed benchmark for AmigaOS — CON:, CCON:, KingCON,
ViNCEd, or any other DOS console handler. Fifteen workloads, from
plain `dir`-style line output to full-screen editor repaints, timed
from the client side of the packet interface, with the tooling to
tell an honestly fast console from one that is merely quick to say
"done".

Born during the CCON 1.2.2 performance campaign, where it first
measured the problem (one ScrollRaster per scrolled row, 34ms each)
and then measured the fixes; kept as its own tool because the
questions it answers — *is my console fast, and is it telling the
truth about it?* — are not specific to any one handler.

## Usage

Run it **inside** the console you want to measure — it writes its
test output to stdout, so the console under test is whichever one
the shell is running in:

```
NewShell CCON:                        (then, in that window)
conbench CCON TO RAM:conbench.txt

NewShell CON:                         (then, in that window)
conbench CON TO RAM:conbench.txt SYNC
```

```
conbench NAME <label> [TO file] [REPS n] [SCALE n] [SYNC] [FORCE]
```

| Argument | Meaning |
|---|---|
| `NAME` | the label written into the result file — call it what you like |
| `TO file` | results **append** here (default `RAM:conbench.txt`), so runs from several consoles land side by side |
| `REPS n` | run the whole suite n times, keep the best time per test (default 3) — the defence against another task stealing a slice |
| `SCALE n` | multiply every workload — raise it when results come back `?`-flagged |
| `SYNC` | end every test with a `WaitForChar` barrier — see *Honesty*, below |
| `FORCE` | allow a non-console stdout (smoke-testing under vamos); the numbers then mean nothing |

The window names each running test, so the deliberately blank ones
(`scroll-nl`, `insdel-line` — they scroll and blit *empty* rows by
design) don't read as a hang.

## Sample output

```
==========================================================
console : SYNC-CCON   (conbench 0.3)
when    : 23-Jul-26 14:45:21
window  : 77x29
WARNING : only 77 cols - the 78-char line tests WRAP
          (widen the window past 78 text columns to compare)
run     : reps 3, scale 1, sync ON

  test              bytes    secs      bytes/s
  --------------------------------------------------
  plain-lines      64464    1.22       52839
  block-4k         64464    0.68       94800
  ...
  sync-line        15800    6.66        2372
  --------------------------------------------------
  TOTAL           435138   18.46       23571
```

## The tests

| Test | What it measures |
|---|---|
| `plain-lines` | 816 × 78-char lines, one `Write()` per line — the ordinary shape of command output, the number most people mean by "is my console fast" |
| `block-4k` | the same bytes in 4K writes — against `plain-lines`, separates per-packet cost from drawing cost |
| `block-32k` | 414 lines in **one** `Write()` — catches big-write slow paths (bounded copy buffers, synchronous fallbacks) |
| `bytewise` | one `Write()` per character — what unbuffered single-character output (More's echo) actually does; nearly pure packet round-trip |
| `scroll-nl` | 12000 bare newlines — the scroll path with no glyphs at all. Visually blank by design |
| `wrap-long` | 300-char lines, no newlines — the console wraps them itself |
| `sgr-colour` | colour changes several times per line — the `ls` colours case |
| `sgr-perchar` | a colour change before **every** glyph — run length one, the worst case for run-batched rendering |
| `cursor-pos` | absolute positioning + short text — the CSI parser and random grid access |
| `vt-frame` | position + erase-EOL + text for every row, repeatedly — the full-screen editor/pager repaint, sized to the probed window |
| `insdel-line` | CSI L/M insert/delete line — real region blits no console can defer past. Visually blank by design |
| `insdel-char` | CSI @/P open/close a mid-line gap — row-tail cell shifts |
| `clear-page` | form feed + a screenful, 40 pages — the More page-flip path |
| `erase-eol` | CR + text + erase-to-EOL — the progress-bar idiom |
| `sync-line` | `plain-lines` with a render barrier after **every** line — see below |

## Honesty — read this before believing a number

A console is a DOS handler: `Write()` blocks until the handler
replies. What conbench times is therefore *"how long the handler
takes to accept the output"* — and a console that replies first and
draws later looks faster here than it renders. That is not
hypothetical; it is how every fast console on the platform works
(stock con-handler, ViNCEd, and CCON from 1.2.2 on). Three tools to
see through it:

- **`SYNC`** ends each test with a `WaitForChar(fh, 0)` — a packet
  the handler must dequeue behind the writes it is holding. Not a
  guaranteed pixel barrier, but if a console's numbers move between
  a plain and a SYNC run, that console defers, and its plain numbers
  are optimistic.
- **`sync-line`** applies that barrier after *every line*, inside
  one test — the closest the packet interface gets to an honest
  per-line figure, on every console alike. The gap between
  `plain-lines` and `sync-line` *is* the deferral.
- The **window probe** (CSI `0 SPACE q`, answered on the input
  stream) records the real text grid in the result file, and warns
  when the window is too narrow for the 78-column line tests —
  in a 77-column window every "line" silently becomes a
  wrap-plus-double-scroll, and the table measures something else.

For the record, the first full three-way SYNC run (A1200/030,
AmigaOS 3.2, 23.7.26): CCON 1.2.2 **18.46s**, stock CON: **74.16s**,
ViNCEd **111.68s** — and ViNCEd's sync-*off* total was 0.18s, which
is the whole honesty argument in two numbers.

Small-workload rows (`insdel-line`, `insdel-char`) fit entirely
inside a deferring console's write-behind buffer, so their sync-off
timings swing with flush timing — identical work has measured
anywhere from 0.00 to 4.9s. Use `SYNC` for those rows.

## Making the comparison fair

- **Same window size** — the probe records it; check the lines match.
- **Same screen depth** — more bitplanes is more blitting for everyone.
- **Same font** — cell size changes the grid (MicroKnight/8 gives
  77×29 in a 640×246 window; a 7-pixel font gives 91 columns).
- **Nothing else running** — a busy Workbench steals from whoever is
  measured second.
- Results under half a second are flagged `?` — raise `SCALE` rather
  than trusting them. Timing resolution is one tick, 1/50s.

## Building

Written in [Amiga E](https://en.wikipedia.org/wiki/E_(programming_language)),
compiled with the E-VO compiler:

```
evo conbench.e
```

A prebuilt binary is included.

## History

- **0.1** (23.7.26) — nine tests, written to measure CCON against
  CON: and ViNCEd; found CCON 11.6× slower than stock and started
  the ccon 1.2.2 performance campaign. Lived in `ccon/tests/` then.
- **0.2** — suite doubled, six new tests, and the window probe made
  to work: answers read from `Input()` (they never arrived on
  `Output()`), then the reply parser done right on the third try —
  3.2-family replies append pixel fields after cols, a CSI
  introducer must not count as a field; a field exists only where
  digits were seen. Result files from this arc are stamped 2.0–2.2,
  before the renumbering to house style.
- **0.3** — each test announces itself in the window (the blank-by-
  design tests no longer look like a hang), and conbench moved out
  of ccon's test drawer into a tool of its own.
