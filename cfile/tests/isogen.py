#!/usr/bin/env python3
"""Minimal ISO9660 mastering for CFile's parser harness.

Builds small but structurally honest ISO9660 images (PVD, L/M path
tables, sector-aligned extents, records never straddling sectors,
even-length records with pad bytes) plus a JSON manifest of ground
truth (path -> size/md5/isdir) for the E-harness diff.

Independently verified with 7z (l + x) before anything trusts it.
"""
import hashlib
import json
import os
import struct
import sys

S = 2048  # logical sector


def both16(n):
    return struct.pack('<H', n) + struct.pack('>H', n)


def both32(n):
    return struct.pack('<I', n) + struct.pack('>I', n)


DATE7 = bytes([126, 7, 30, 12, 0, 0, 0])  # 2026-07-30 12:00 utc


class Node:
    def __init__(self, name, isdir, content=b''):
        self.name = name          # identifier as stored (files usually NAME;1)
        self.isdir = isdir
        self.content = content
        self.children = []        # dirs only
        self.extent = 0
        self.size = 0

    def record(self, name_override=None):
        name = self.name if name_override is None else name_override
        ident = name.encode('ascii')
        base = 33 + len(ident)
        pad = base % 2  # pad byte keeps records even-length
        rec = bytearray(base + pad)
        rec[0] = len(rec)
        rec[1] = 0
        rec[2:10] = both32(self.extent)
        rec[10:18] = both32(self.size)
        rec[18:25] = DATE7
        rec[25] = 2 if self.isdir else 0
        rec[26] = 0
        rec[27] = 0
        rec[28:32] = both16(1)
        rec[32] = len(ident)
        rec[33:33 + len(ident)] = ident
        return bytes(rec)


def build_dir_extent(node, parent):
    """Serialize a directory extent: '.', '..', then children, records
    never straddling a sector boundary."""
    out = bytearray()
    recs = [node.record('\x00'), parent.record('\x01')]
    recs += [c.record() for c in sorted(node.children, key=lambda c: c.name)]
    for rec in recs:
        room = S - (len(out) % S)
        if len(rec) > room:
            out += b'\x00' * room  # pad to sector edge; parser must skip
        out += rec
    if len(out) % S:
        out += b'\x00' * (S - len(out) % S)
    return bytes(out)


def master(root, volid, outpath, manifest_path):
    # collect dirs breadth-first (path table order), then assign extents
    dirs = [root]
    i = 0
    while i < len(dirs):
        dirs[i].bfs_index = i + 1  # path table numbering is 1-based
        for c in dirs[i].children:
            if c.isdir:
                dirs.append(c)
        i += 1

    # first pass: sizes. Dir sizes need child extents for records, but the
    # record LAYOUT doesn't depend on extent values, so sizes are stable.
    def dir_size(node, parent):
        return len(build_dir_extent(node, parent))

    parents = {id(root): root}
    for d in dirs:
        for c in d.children:
            parents[id(c)] = d

    # layout: [16]=PVD, [17]=terminator, [18]=L path table, [19]=M path
    # table (each < 2048 here), then dir extents in BFS order, then files.
    lba = 20
    for d in dirs:
        d.size = dir_size(d, parents[id(d)])
        d.extent = lba
        lba += d.size // S
    allfiles = []

    def walk_files(d):
        for c in d.children:
            if c.isdir:
                walk_files(c)
            else:
                allfiles.append(c)
    walk_files(root)
    for f in allfiles:
        f.size = len(f.content)
        f.extent = lba
        lba += max(1, (f.size + S - 1) // S)
    total_sectors = lba

    # path tables
    def path_table(be):
        out = bytearray()
        for d in dirs:
            ident = b'\x00' if d is root else d.name.encode('ascii')
            parent_no = 1 if d is root else parents[id(d)].bfs_index
            out += bytes([len(ident), 0])
            out += struct.pack('>I' if be else '<I', d.extent)
            out += struct.pack('>H' if be else '<H', parent_no)
            out += ident
            if len(ident) % 2:
                out += b'\x00'
        return bytes(out)

    pt_l = path_table(False)
    pt_m = path_table(True)
    assert len(pt_l) <= S, "path table exceeds one sector (test images only)"

    # PVD
    pvd = bytearray(S)
    pvd[0] = 1
    pvd[1:6] = b'CD001'
    pvd[6] = 1
    pvd[8:40] = b' ' * 32
    pvd[40:72] = volid.ljust(32).encode('ascii')
    pvd[80:88] = both32(total_sectors)
    pvd[120:124] = both16(1)
    pvd[124:128] = both16(1)
    pvd[128:132] = both16(S)
    pvd[132:140] = both32(len(pt_l))
    pvd[140:144] = struct.pack('<I', 18)
    pvd[148:152] = struct.pack('>I', 19)
    rootrec = root.record('\x00')
    pvd[156:156 + len(rootrec)] = rootrec
    for off, ln in ((190, 128), (318, 128), (446, 128), (574, 128),
                    (702, 37), (739, 37), (776, 37)):
        pvd[off:off + ln] = b' ' * ln
    zdate = b'0' * 16 + b'\x00'
    for off in (813, 830, 847, 864):
        pvd[off:off + 17] = zdate
    pvd[881] = 1

    term = bytearray(S)
    term[0] = 255
    term[1:6] = b'CD001'
    term[6] = 1

    with open(outpath, 'wb') as f:
        f.write(b'\x00' * (16 * S))
        f.write(pvd)
        f.write(term)
        f.write(pt_l + b'\x00' * (S - len(pt_l)))
        f.write(pt_m + b'\x00' * (S - len(pt_m)))
        for d in dirs:
            assert f.tell() == d.extent * S
            f.write(build_dir_extent(d, parents[id(d)]))
        for fl in allfiles:
            assert f.tell() == fl.extent * S
            f.write(fl.content)
            if fl.size % S:
                f.write(b'\x00' * (S - fl.size % S))
            elif fl.size == 0:
                f.write(b'\x00' * S)

    # manifest: stored-name paths, with the display name the parser
    # should produce (version ;N stripped, trailing dot stripped)
    man = {}

    def disp(name):
        n = name.split(';')[0]
        if n.endswith('.'):
            n = n[:-1]
        return n

    def walk(d, prefix):
        for c in d.children:
            p = prefix + disp(c.name)
            if c.isdir:
                man[p] = {'dir': True}
                walk(c, p + '/')
            else:
                man[p] = {'dir': False, 'size': c.size,
                          'md5': hashlib.md5(c.content).hexdigest()}
    walk(root, '')
    with open(manifest_path, 'w') as f:
        json.dump(man, f, indent=1, sort_keys=True)
    print(f"{outpath}: {total_sectors} sectors, {len(man)} entries")


def mk(name, content):
    return Node(name, False, content)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '.'

    # 1) basic: 8.3 uppercase, nested dirs, empty dir
    root = Node('', True)
    root.children = [
        mk('README.TXT;1', b'hello from the basic image\n'),
        mk('DATA.BIN;1', bytes(range(256)) * 20),
        Node('SUB', True), Node('MT', True),
    ]
    sub = root.children[2]
    sub.children = [mk('B.TXT;1', b'file inside SUB\n'), Node('DEEP', True)]
    sub.children[1].children = [mk('C.TXT;1', b'deep file content here\n')]
    master(root, 'BASIC', f'{out}/basic.iso', f'{out}/basic.json')

    # 2) bigdir: root dir extent spans several sectors (padding rule)
    root = Node('', True)
    root.children = [mk(f'F{i:03d}.TXT;1',
                        (f'payload of file number {i}\n' * (i % 7 + 1)).encode())
                     for i in range(120)]
    master(root, 'BIGDIR', f'{out}/bigdir.iso', f'{out}/bigdir.json')

    # 3) mixed: longer/lowercase names, no-version names, dot edges,
    #    8-deep nesting, a 3MB binary, zero-byte file
    import random
    random.seed(42)
    big = bytes(random.getrandbits(8) for _ in range(3 * 1024 * 1024))
    root = Node('', True)
    root.children = [
        mk('VeryLongFileName.data;1', b'long name payload\n'),
        mk('lowercase.txt', b'no version suffix here\n'),
        mk('NOEXT', b'name without extension or version\n'),
        mk('A.B.C.TXT;1', b'dots galore\n'),
        mk('TRAIL.;1', b'trailing dot identifier\n'),
        mk('EMPTY.FIL;1', b''),
        mk('BIG.BIN;1', big),
        Node('D1', True),
    ]
    d = root.children[-1]
    for i in range(2, 9):
        nd = Node(f'D{i}', True)
        d.children = [nd] if i < 9 else []
        if i == 8:
            nd.children = [mk('BOTTOM.TXT;1', b'eight levels down\n')]
        d = nd
    master(root, 'MIXED', f'{out}/mixed.iso', f'{out}/mixed.json')


if __name__ == '__main__':
    main()
