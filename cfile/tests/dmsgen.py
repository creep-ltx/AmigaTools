#!/usr/bin/env python3
"""Minimal DMS writer (store mode) for CFile's DMS-stage testing.

Packs an 880K ADF into a NOCOMP (cmode 0) DMS archive, per the format
as read from the xDMS 1.3 source (pfile.c): 56-byte header 'DMS!' with
CRC16/ARC over bytes 4..53, then 80 tracks of 11264 bytes, each with a
20-byte 'TR' header (usum = 16-bit byte sum of unpacked data, dcrc =
CRC of packed data, hcrc = CRC of the first 18 header bytes).

Verify every output with the real xdms (t + u, byte-compare) before
trusting it - the generator/verifier/consumer three-way rule.
"""
import sys
import time


def crc16(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc >> 1) ^ 0xA001) if crc & 1 else crc >> 1
    return crc & 0xFFFF


def be16(v):
    return bytes([(v >> 8) & 0xFF, v & 0xFF])


TRACKLEN = 11264  # 2 heads x 11 sectors x 512
NTRACKS = 80


def pack(adfpath, dmspath):
    adf = open(adfpath, 'rb').read()
    assert len(adf) == TRACKLEN * NTRACKS, f"not an 880K ADF: {len(adf)}"

    hdr = bytearray(56)
    hdr[0:4] = b'DMS!'
    hdr[10:12] = be16(0)                      # geninfo
    t = int(time.time())
    hdr[12:16] = t.to_bytes(4, 'big')         # date
    hdr[16:18] = be16(0)                      # lowest track
    hdr[18:20] = be16(NTRACKS - 1)            # highest track
    total = TRACKLEN * NTRACKS
    hdr[21:24] = total.to_bytes(3, 'big')     # packed size (store = same)
    hdr[25:28] = total.to_bytes(3, 'big')     # unpacked size
    hdr[46:48] = be16(111)                    # "created with DMS 1.11"
    hdr[50:52] = be16(0)                      # disk type
    hdr[52:54] = be16(0)                      # main cmode: NOCOMP
    hdr[54:56] = be16(crc16(hdr[4:54]))       # header CRC (bytes 4..53)

    out = [bytes(hdr)]
    for n in range(NTRACKS):
        data = adf[n * TRACKLEN:(n + 1) * TRACKLEN]
        th = bytearray(20)
        th[0:2] = b'TR'
        th[2:4] = be16(n)                     # track number
        th[6:8] = be16(TRACKLEN)              # pklen1
        th[8:10] = be16(TRACKLEN)             # pklen2
        th[10:12] = be16(TRACKLEN)            # unpklen
        th[12] = 0                            # flags
        th[13] = 0                            # cmode NOCOMP
        th[14:16] = be16(sum(data) & 0xFFFF)  # usum (unpacked checksum)
        th[16:18] = be16(crc16(data))         # dcrc (packed data CRC)
        th[18:20] = be16(crc16(th[0:18]))     # header CRC
        out.append(bytes(th))
        out.append(data)
    open(dmspath, 'wb').write(b''.join(out))
    print(f"{dmspath}: {NTRACKS} tracks, store mode")


if __name__ == '__main__':
    pack(sys.argv[1], sys.argv[2])
