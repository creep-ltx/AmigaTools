# CBoot

A small boot selector for AmigaOS. Hold a mouse button or an Amiga key
while booting to jump straight into a different startup-sequence — no
Early Startup menu, no manual boot-picking.

Currently at **v1.4**. Older releases are tagged in this repo's git
history (`v1.3`) rather than kept as separate source files — see
[Versions](#versions) below.

## Boot modes

| Mode | Trigger |
|---|---|
| Default | No mouse button or Amiga key held at boot |
| LMB | Left mouse button held at boot |
| RMB | Right mouse button held at boot |
| LAmiga | Left Amiga key held at boot |
| RAmiga | Right Amiga key held at boot |

If both a mouse button and an Amiga key are held at the same time, the
mouse button takes priority.

Hold **Ctrl** (alone, or together with a mouse button/Amiga key) to
enter the control center for that boot mode instead of booting it —
lets you edit, replace, or test-boot a different script without
installing it.

CBoot can also be started with an optional argument to only check a
subset of modes:

```
run >nil: C:CBoot          ; checks all four (LMB, RMB, LAmiga, RAmiga) - default
run >nil: C:CBoot mouse    ; only LMB/RMB
run >nil: C:CBoot amiga    ; only LAmiga/RAmiga
```

Full behaviour and installation steps: [cboot.readme](cboot.readme).

## Building

Compile `cboot.e` with the E-VO E compiler:

```
evo cboot.e
```

There is also a hand-written 68000 assembly port, [cboot.asm](cboot.asm),
also boot-verified. Assemble with [vasm](http://sun.hasenbraten.de/vasm/):

```
vasmm68k_mot -Fhunkexe -nosym -o CBoot cboot.asm
```

Either way the result is an AmigaOS loadseg()able executable; name it
`CBoot` to match the installation instructions in
[cboot.readme](cboot.readme).

## Testing — this is not a Shell tool

Unlike `dupfind`, CBoot can't be smoke-tested by just running it from
a Shell prompt. It's designed to run from `S:Startup-Sequence` during
a reboot, reads mouse-button/keyboard state at boot time, and its
control center is interactive (ASL file requester). Verifying a
change means:

1. Building and copying `CBoot` to `C:` on a real Amiga or an emulator
   (e.g. FS-UAE) with `S:CBoot/Default`, `S:CBoot/LMB`, etc. set up per
   [cboot.readme](cboot.readme)'s installation steps.
2. Adding the `run >nil: C:CBoot` line to `S:Startup-Sequence` (see
   [example-startup-sequence](example-startup-sequence)).
3. Actually rebooting while holding each mouse button/Amiga key/Ctrl
   combination you want to exercise, since there's no way to fake
   "boot-time key state" from a running system.

A clean compile only proves the source is syntactically valid, not
that any boot mode actually works.

## Versions

| Tag | Notes |
|---|---|
| `v1.3` | First release with Amiga E source included; LMB/RMB + control center. |
| `v1.4` | Adds LAmiga/RAmiga boot modes and the `mouse`/`amiga` command-line argument; smaller filesize. |

Diff any two releases with e.g. `git diff v1.3 v1.4 -- cboot/cboot.e`.

## The assembly port

[cboot.asm](cboot.asm) is a hand-written 68000 assembly port of the
v1.4 feature set (all four boot modes, `mouse`/`amiga` argument,
control center), aimed at a smaller binary — it assembles to 3240
bytes against the E version's 4384. Its header documents how every
LVO and struct offset was derived rather than recalled.

Both sources are boot-verified on a real AmigaOS 3.2 install
(FS-UAE): all four boot modes (LMB, RMB, LAmiga, RAmiga) and the
Ctrl control-center entry have been exercised through real reboots
in each. The one path not yet reboot-tested in the asm port is the
optional `mouse`/`amiga` argument restriction.
