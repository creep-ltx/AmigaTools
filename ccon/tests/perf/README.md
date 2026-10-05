# CCON performance tools (1.2.8b9-b12)

The measuring kit behind CCON's speed work. Everything runs from Linux
against FS-UAE (driven over the network with `wasabi`, the daemon
wasabid running on the Amiga) or under vamos. Build the C tools with
bebbo's `m68k-amigaos-gcc -O1 -noixemul`, the E tools with `ecompile`.

## The rules that made the numbers trustworthy

- **Measure the floor first.** `nullc.c` (+ `nullent.s`, linked first so
  the entry point is code, not a string) is a DOS handler that answers
  every packet at once and draws nothing. Mount it (`NUL-mountlist`) and
  run `conbench NULL ... FORCE >NUL0:`: what it scores is what no console
  can remove (stock A1200 ~12.4 s, PiStorm ~6.9 s at SCALE 10).
- **Never trust one run.** `ab.sh NAME1 BUILD1 NAME2 BUILD2 [rounds]`
  cold-starts FS-UAE for every run (`live30.sh`), alternates the two
  builds, and prints a per-test table. Single runs drift +-0.1-0.2 s on a
  30 s total; three alternating rounds each settle it.
- **Every check must be able to fail.** Plant a bug (one store left out,
  a width halved) and see the test catch it before believing a pass.
- **On a stock A1200 with a Hires Workbench**, straight-line code costs
  ~1.3 us an instruction (every fetch is a chip access) while cached
  loops cost their memory accesses (~2.5-3 us each). Count instructions
  on paths, accesses in loops.

## The tools

| File | What it does |
|---|---|
| `uae9.sh CONFIG` | start FS-UAE and move its window to mango workspace 9 |
| `live30.sh BUILD NAME` | cold start, BUILD as L:ccon-handler, conbench SYNC SCALE 1 REPS 3 in a 77x30 window |
| `live30c.sh` | the same with `CFG=` and `SCALE=` |
| `ab.sh` | alternating A/B of two builds (see above) |
| `prof.py / profc.py / profl.py IN OUT` | patch EClock phase counters into a copy of ccon-handler.e (profl: busy/idle only; profc: + the C counters, needs `PROF=1 engine/build.sh`) |
| `ccstat3.e` | read/reset the counters (port CCON.prof) |
| `prof2.sh / prof3.sh BUILD tests...` | one conbench test at a time (`cbone.e`) with the counters |
| `btest.c`, `ptest2.c` | time engine.bin's frun / ppaint on the machine, several blobs side by side |
| `pcmp.c OLD NEW [n]` | painter differential test: random rows into memory planes, both blobs, byte compare (vamos or the Amiga) |
| `vt3.c / vts.c / vtc.c` | drivers (plain line / sgr line / cursor writes) for vamos instruction traces |
| `trace2.sh DRIVER BLOB N` | vamos `-I` trace mapped to functions and C source lines (a `-g` build of the same code, checked byte-identical) |
| `icount.py / lcount.py` | the trace counters (per function / per asm label) |
| `pxab2.sh BUILD FILE` | pixel A/B: FILE typed into a DPFORCE and a NODIRECT window (JUMP0), row hashes compared at five x positions |
| `pxab3.sh` | the same through `slowtype.c` (a line + Delay(1)): forces the scroll-blit path |
| `pxdet.sh` | determinism check: one mode twice |
| `pxtest.txt`, `pxscroll2.txt` | the styles test and the scroll stress test |
