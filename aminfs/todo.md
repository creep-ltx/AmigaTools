# AmiNFS — NFSv3 client filesystem handler for AmigaOS 3.2

The goal: mount a Linux NFS export as an Amiga volume. Icon in
DEVS:DOSDrivers for automount, or keep it in Storage and `Mount NFS0:`
from the CLI; dismount via a small C: tool. Written in C (Bebbo gcc,
the wasabid recipe), speaking NFSv3 over TCP through bsdsocket.library.

Why v3/TCP and not the existing clients: every known Amiga NFS client
is ch_nfsc (1994) or its descendant anfs (dormant since 2015) — NFSv2
over UDP — and modern Linux removed NFSv2 serving entirely (no
CONFIG_NFSD_V2 in this kernel; rpc.nfsd dropped v2 too). v3 is the
floor now, and TCP sidesteps nfs-utils's disabled-by-default UDP.

Decided 14.8.26: write our own (not port anfs), in C (not E).

## Milestones

- M1: Linux side. nfsd export of ~/nfs-share + Python wire prototype
  (tests/nfswire.py) = reference implementation + permanent protocol
  harness. CLOSED 14.8.26 — selftest ALL GREEN against live nfsd
  (`nfswire.py selftest 192.168.68.117 /home/creep/nfs-share`):
  READDIRPLUS tree walk, 2MB pattern read verified byte-for-byte,
  CREATE/WRITE/readback/RENAME/REMOVE/RMDIR cycle clean.
  NOTE: always test via the LAN address, never localhost — the export
  is scoped to 192.168.68.0/24 and 127.0.0.1 gets NFS3ERR_ACCES.
  Same source-address view the Amiga has.
- M2: read-only handler. LOOKUP/GETATTR/READDIRPLUS/READ mapped to
  ACTION_LOCATE_OBJECT/EXAMINE/EXAMINE_NEXT/FINDINPUT/READ/SEEK +
  IS_FILESYSTEM/DISK_INFO. Browsable from cfile = the day-one payoff.
- M3: write path. CREATE/WRITE/SETATTR/REMOVE/RMDIR/MKDIR/RENAME →
  FINDOUTPUT/FINDUPDATE/ACTION_WRITE/DELETE/CREATE_DIR/RENAME_OBJECT,
  SET_PROTECT/SET_DATE mapping (Amiga protection bits vs mode).
- M4: perf. Attribute cache with TTL, readahead on sequential READ,
  write clustering (UNSTABLE writes + COMMIT).
- M5: polish. DOSDrivers entry + icon, C:nfsctl dismount (ACTION_DIE
  teardown per ccon discipline), reconnect after server restart
  (fh's survive — that's the point of NFS statelessness).

## Wire facts (from the prototype; verify each against C later)

- TCP record marking: 4-byte big-endian length, high bit = last frag.
- AUTH_UNIX cred: stamp, machinename string, uid, gid, gids<>.
  Server squashes anyway (all_squash,anonuid=1000) so uid mapping is
  a non-problem for a single-user Amiga.
- mountd port is dynamic → portmap GETPORT (prog 100000 v2 proc 3,
  port 111) at mount time; nfsd itself is fixed 2049.
- MOUNT3 MNT gives the root fh (opaque, up to 64 bytes — treat as
  blob, never parse).
- Live-server numbers (14.8.26): mountd tcp 20048 (dynamic, via
  portmap), nfsd 2049 fixed; FSINFO rtpref/wtpref = 1MB (server's
  preference — the handler will use ~32KB per READ/WRITE, its call),
  maxfilesize = 2^63-1.

## The b1-b6 bring-up (14.8.26) — and the outbound-TCP mystery

First boot chapter, all RAM:-staged (zero persistence, reboot cleans):
- b1 built -nostartfiles/-nostdlib; TRAP: string literals land at .text
  offset 0 ahead of functions — an Amiga would execute "dos.library"
  as opcodes. Fix = entry.c with nothing but a jmp, linked first.
  Verify with objdump: offset 0 must be `jmp _handler_main`.
- libgcc has __udivsi3 but NOT __umodsi3 → own shift-subtract udivmod,
  no / or % anywhere.
- `Mount NFS0: FROM file` needs the CLASSIC stanza format (name + #);
  the bare DOSDriver format only works from DEVS:DOSDrivers.
- Mount hands Startup over WITH ITS QUOTES in the BSTR — strip them.
- Handler mechanics ALL GREEN on the real A1200: mount handshake,
  packet loop (1027/8/25/7/27 seen), volume node, error replies,
  lazy bsdsocket open. KPrintF telemetry via wasabi debug = the eyes.
- THEN THE WALL: connect() to the Linux box fails errno 53
  (ECONNABORTED), and nstat TcpPassiveOpens proves NO SYN EVER
  ARRIVES. Evidence matrix (tcptest CLI probe, rc=errno):
    loopback 127.0.0.1:1234      CONNECTED
    self-LAN .114:1234           CONNECTED
    router .1:80                 ECONNREFUSED = real SYN+RST round trip
    linux .117: 111/2049/5099    errno 53, zero packets arrive
  So outbound TCP WORKS to wired peers; only NEW flows toward the
  Wi-Fi-attached Linux box vanish — while ESTABLISHED wasabi flows to
  the same host run constantly (conntrack lets replies through).
  Prime suspect: a host firewall on wlan0 dropping NEW inbound SYNs.
  (Not the handler, not lwIP sockaddr, not ARP: same failure from a
  plain CLI process; bsdsocket.library 4.103 = Emu68 lwIP.)
- SOLVED: ufw. INPUT policy drop, ufw-user-input EMPTY, established
  flows pass via conntrack (why wasabi always worked). His rule:
  `ufw allow from 192.168.68.0/24 to any port 111,2049,20048 proto tcp`.
  (`command -v ufw` had lied earlier - /usr/sbin not in sandbox PATH.)

## FIRST LIGHT 14.8.26 - b6 GREEN ON REAL A1200

`List NFS7:` walks the share, `List NFS7:Docs` resolves subdirs,
`Type NFS7:README.txt` prints a file living on the Linux disk, and
`Copy NFS7:pattern.bin RAM:` moved 2MB that cmp-verified BYTE-FOR-BYTE
back on Linux. Copy wall time ~0.5s = multi-MB/s effective read.
Full chain in telemetry: GETPORT -> mountd:20048 -> MNT (fh 28 bytes)
-> nfsd:2049 -> LOCATE/EXAMINE/EXNEXT/FINDINPUT/READ/END all clean.
Protection bits show ----rwed, dates land (UTC - see below).

Known rough edges for b7+:
- EXAMINE on a file lock: name '?', size 0 (needs real GETATTR + the
  leaf name stored in the lock at LOCATE time).
- Timestamps are UTC; his wall clock is CEST. TZ= mount option later.
- probe_net() diagnostic + per-packet DBG spam: strip for b7.
- Blocking connect/recv with no timeout: a dead server wedges the
  handler (and any shell touching it). SO_RCVTIMEO or WaitSelect
  timeout before recv - do this BEFORE the write path.
- wasabi run output sometimes swallowed (List's went missing twice,
  then streamed fine) - wasabi-side quirk, not cnfs; watch it.

## 14.8.26 afternoon: b8+b9 = the rest of the day-one ask, DELIVERED

- b8: probe/spam stripped; REAL TIMEOUTS (non-blocking connect +
  WaitSelect 5s, WaitSelect 10s before every recv - a dead server can
  no longer wedge the handler); GETATTR-backed EXAMINE with leaf names
  stored in locks (List NFS9:pattern.bin shows real size now);
  Startup options VOLUME= UID= GID=. All green on real iron.
- b9: THE WRITE PATH, all server-side-verified on the real A1200:
  Makedir/Echo>/Copy(2MB NFS->NFS byte-identical)/Rename/Protect
  (rd -> mode 444)/Delete/rmdir. FILE_SYNC writes for now; UNSTABLE+
  COMMIT clustering is the M4 perf campaign.
- NFSDismount (C: tool): ACTION_DIE by device name; refuses while in
  use; UnLockDosList BEFORE DoPkt (handler DIE takes the write lock -
  holding read = mutual deadlock). Dismount -> "no handler running" ->
  next access remounts from the kept seglist. Full mortal cycle green.
- Mount mechanics NAILED (stock AUX file proves it, not just ours):
  `Mount X: FROM file` parses ONLY MountList stanzas; bare DOSDriver
  files mount by DIRECT PATH (`Mount SYS:Storage/DOSDrivers/NFS0`) or
  from DEVS:DOSDrivers at boot. Volume name routes only after first
  DEVICE access (handler must run to add the volume node).
- INSTALLED on his A1200 (additive, boot untouched): L:nfs-handler,
  C:NFSDismount, SYS:Storage/DOSDrivers/NFS0 (moodbox = ~/Amiga on
  192.168.68.117) + NFS1 (NAS = Synology 192.168.68.118
  /volume1/homes/creep UID=1026 GID=100) + PC0-copied icons.
  He drags to DEVS:DOSDrivers when he wants boot automount.
- NAS: GREEN end to end - Synology accepted the Amiga's MNT directly
  (mountd port 892 via portmap, no DSM changes), NAS: volume lists his
  real home share on the A1200. moodbox share awaits his exports line.

## Open questions

- Handler main loop: WaitSelect on socket + packet-port signal bit in
  one call (proven primitive, see AmigaReferences
  network-daemon-and-patching.md). Confirm no starvation pattern.
- Filename charset: Latin-1 (Amiga) vs UTF-8 (Linux) — decide policy
  for non-ASCII names (pass-through first, revisit).
- Amiga-side stack on the A1200 is lwIP bsdsocket (Emu68). Check
  lwIP's WaitSelect fidelity early — it's the one primitive we can't
  do without.
- Volume name / device name: NFS0: device, volume from export string
  or a NAME= tooltype/mount option.
