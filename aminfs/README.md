# AmiNFS

An NFSv3 client filesystem for AmigaOS — mount a Linux export or a
NAS share as an ordinary Amiga volume. A DOS handler speaking the
packet protocol on one side and SunRPC/XDR/MOUNT3/NFS3 over TCP
through `bsdsocket.library` on the other. Drop the DOSDriver icon in
`DEVS:DOSDrivers` for automount, or keep it in Storage and `Mount`
from the CLI; `NFSDismount` stops a handler cleanly and the next
access remounts it fresh.

Why write a new one: every existing Amiga NFS client descends from
`ch_nfsc` (1994) — NFSv2 over UDP — and modern Linux kernels have
**removed NFSv2 serving entirely** (no `CONFIG_NFSD_V2`, and
nfs-utils disables UDP). A v2 client has no server left to talk to.
AmiNFS speaks v3 over TCP against a stock kernel `nfsd`, and against
a Synology NAS unchanged.

**Status: 0.1 (pre-release).** Every build boot-verified on real
hardware (A1200 + PiStorm/Emu68) against Linux kernel nfsd and
Synology DSM; every transfer in the log below byte-compared on the
server side, most of them minimum-of-3 with the fault injectors on.
The binary is 68000-clean (verified by disassembly scan) and safe by
default: pipelining is off (`DEPTH=1` *is* the plain synchronous
path), buffers are ~100 KB. Fair warning with the fair claim: the
Amiga-side stacks exercised so far are Emu68's lwIP `bsdsocket` —
Roadshow/AmiTCP-family testing is still ahead.

## Speed

Measured, not vibed — on the reference machine (A1200 + PiStorm,
Wi-Fi-attached Linux server), with the tuned options
(`RSIZE=65536 WSIZE=16384 DEPTH=8`):

| workload                        | result                    |
|---------------------------------|---------------------------|
| 22.8 MB file via `c:Copy`       | 14.2 MB/s read, 13.1 write |
| 2.5 GB file, 512 K-buffer reader | **65.6 MB/s sustained**   |
| 2.5 GB via a 64 K-buffer app    | 11.4 MB/s                 |
| 100 × 10 KB files               | 143/s read, 45/s write    |

Writes go UNSTABLE with a COMMIT at close and the write verifier
tracked per file — a server that restarts mid-file fails the
`Close()` loudly instead of losing bytes silently. The pipelined
paths (reads and writes both) were driven through every failure mode
by built-in fault injectors — simulated short transfers and
transport death — to byte-identical results before any speed was
claimed. On a CPU-bound real-NIC machine the pipeline buys little
and costs nothing: leave `DEPTH` alone and you have the synchronous
handler.

## What's in the drawer

- `nfs-handler` — the filesystem, goes in `L:`
- `NFSDismount` — clean stop by device name, goes in `C:`
- `NFS0` — a documented DOSDriver to copy and edit
- `AmiNFS.doc` — the full manual: installation, every mount option,
  Linux/NAS server setup (including the firewall hunt), tuning
- `tests/nfswire.py` — the protocol harness: a hand-rolled
  RPC/XDR/NFS3 client for Linux that doubles as the reference
  implementation and regression gate

## Quick start

Amiga side: `nfs-handler` into `L:`, `NFSDismount` into `C:`, edit
the `NFS0` DOSDriver's `Startup` line (host, export path, options),
put it in `SYS:Storage/DOSDrivers`, and:

    Mount SYS:Storage/DOSDrivers/NFS0
    List NFS0:

Drag it to `DEVS:DOSDrivers` when you want it at every boot — the
handler connects lazily, so mounting before the network is up costs
nothing. Linux side, one `/etc/exports` line and three firewall
ports; the Synology needs nothing at all. Details and the options
table: `AmiNFS.doc`.

## Building

Cross-compiled with Bebbo's `m68k-amigaos-gcc` (`make`). The handler
is built `-nostartfiles -nostdlib` — its entry point is a jmp in
`entry.c`, linked first, and the file provides its own `memcpy`-class
primitives plus the `__mulsi3`/`udivmod` helpers this libgcc lacks.
The lab notebook (`todo.md`) keeps the full build-by-build story,
including the one-day 0.17 → 13.1 MB/s write campaign and the traps
found on the way.
