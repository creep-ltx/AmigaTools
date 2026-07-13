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

This produces an AmigaOS loadseg()able executable; rename it to
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

## Other implementations

An in-progress hand-written 68k assembly rewrite exists outside this
repo, aimed at a smaller binary than the E version. It isn't included
here yet — the earlier (LMB/RMB-only) version of it has been verified
booting on real hardware/FS-UAE, but the current extended version
(with LAmiga/RAmiga) hasn't, so it's not ready to publish alongside
the verified E source.
