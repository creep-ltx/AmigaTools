# amifetch

A tiny neofetch-style system info dump for AmigaOS. Run it from a Shell
and it prints CPU, FPU, video timing, chip/fast RAM, Kickstart version,
E-Clock frequency, and current stack size.

## Usage

```
amifetch
```

No arguments. Illustrative output (not yet verified on real hardware/
FS-UAE — see below) for a 68030/68882 system with 2MB chip + 8MB fast
RAM:

```
CPU:        68030
FPU:        68882
Video:      PAL (50Hz)
Chip RAM:   1847 K free / 2048 K total
Fast RAM:   8192 K free / 8192 K total
Exec:       40.10 (Kickstart)
E-Clock:    709379 Hz
Stack:      4096 bytes
```

## How it works

Everything comes from `exec.library`'s always-available `execbase`
global and one library call:

- **CPU/FPU** — `execbase.attnflags` is a cumulative bitfield (a
  68030 sets both the `AFF_68020` and `AFF_68030` bits), so this
  checks from the highest bit down and reports the first match.
- **Video timing** — `execbase.vblankfrequency` (50 for PAL, 60 for
  NTSC).
- **Chip/Fast RAM** — `AvailMem(MEMF_CHIP)` / `AvailMem(MEMF_FAST)`
  for free bytes, OR'd with `MEMF_TOTAL` for installed bytes.
- **Kickstart version** — `execbase`'s embedded `lib` node's
  `version`/`revision` fields (this is exec.library's own version,
  which is what "Kickstart version" means in practice).
- **E-Clock** — `execbase.eclockfrequency`, the timing reference used
  by `timer.device`.
- **Stack size** — this process's `pr_StackSize`, reached by casting
  the built-in `thistask` pointer to a `process` struct.

No `Lock()`/`Examine()`/filesystem access at all, so unlike `dupfind`
this one doesn't need real disk access to do its job — just real
exec.library structures, which still means real AmigaOS (or FS-UAE) to
verify against.

## Building

Compile `amifetch.e` with the E-VO E compiler:

```
evo amifetch.e
```

This produces an AmigaOS loadseg()able executable named `amifetch`.
