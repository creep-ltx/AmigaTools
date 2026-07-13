# amifetch

A tiny neofetch-style system info dump for AmigaOS. Run it from a Shell
and it prints CPU, FPU, video timing, chip/fast RAM, Kickstart version,
E-Clock frequency, and current stack size.

## Usage

```
amifetch [MEM unit] [CHIP unit] [FAST unit]
```

`unit` is one of `B`, `KB`, or `MB` (case-insensitive). `MEM` sets the
default for both Chip and Fast RAM; `CHIP`/`FAST` override it
individually. With nothing given, both default to `KB`. `MB` is shown
with one decimal place (`xx.x MB`); `B`/`KB` are whole numbers.

```
amifetch
amifetch MEM=MB
amifetch MEM=MB CHIP=B
amifetch CHIP=B FAST=MB
amifetch CHIP KB FAST B
```

Verified output on a real AmigaOS 3.2 install (FS-UAE, 68030, 2MB
chip + 64MB Zorro III fast):

```
1.AmigaOS3.2:AmigaTools> amifetch
CPU:        68030
FPU:        none
Video:      PAL (50Hz)
Chip RAM:   1965 KB free / 2032 KB total
Fast RAM:   64704 KB free / 65536 KB total
Exec:       47.7 (Kickstart)
E-Clock:    709379 Hz
Stack:      4096 bytes

1.AmigaOS3.2:AmigaTools> amifetch MEM=MB CHIP=B
CPU:        68030
FPU:        none
Video:      PAL (50Hz)
Chip RAM:   2012280 B free / 2080768 B total
Fast RAM:   63.1 MB free / 64.0 MB total
Exec:       47.7 (Kickstart)
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

### A real compiler bug, and how the unit conversion avoids it

The first working version divided raw byte counts by 1024 with the
plain `/` operator. Chip RAM (a couple million bytes) displayed fine;
Fast RAM (tens of millions of bytes) came back as garbage — e.g.
`66100000/1024` returned `-25824` instead of `64550`. Isolated with a
series of throwaway diagnostic builds (ruled out `AvailMem()`,
`WriteF()` argument count/order, and variable reuse in turn), the
actual bug turned out to be `/` itself: on a 32-bit dividend past a
few million, it silently returns the low 16 bits of the dividend,
sign-extended, as though no division happened at all. `Shr(x,10)`
(right-shift by 10, equivalent to `/1024`) gives the correct answer
every time, so all RAM math here goes through `Shl()`/`Shr()`/`Mod()`
instead of `/` or `*`. Worth remembering for any future tool here that
divides a value that isn't guaranteed small.

## Building

Compile `amifetch.e` with the E-VO E compiler:

```
evo amifetch.e
```

This produces an AmigaOS loadseg()able executable named `amifetch`.
