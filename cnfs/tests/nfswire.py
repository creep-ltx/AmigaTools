#!/usr/bin/env python3
"""nfswire.py -- NFSv3-over-TCP wire prototype and protocol harness for cnfs.

Hand-rolled SunRPC + XDR + MOUNT3 + NFS3, no libraries: every byte this
script builds or parses is a byte the C handler will build or parse the
same way.  This file is the reference implementation.

Usage:
  nfswire.py probe  <host>                 portmap: where are mountd/nfsd
  nfswire.py mount  <host> <export>        MNT, print root filehandle
  nfswire.py ls     <host> <export> [dir]  READDIRPLUS one directory
  nfswire.py tree   <host> <export>        recursive listing
  nfswire.py cat    <host> <export> <path> READ whole file to stdout
  nfswire.py selftest <host> <export>      full read+write round-trip
"""
import socket, struct, sys, os

# ---------------------------------------------------------------- XDR ---

class Pack:
    def __init__(self): self.b = bytearray()
    def u32(self, v): self.b += struct.pack('>I', v & 0xffffffff); return self
    def u64(self, v): self.b += struct.pack('>Q', v); return self
    def opaque(self, data):            # variable-length opaque w/ pad to 4
        self.u32(len(data)); self.b += data; self.b += b'\0' * (-len(data) % 4)
        return self
    def string(self, s): return self.opaque(s.encode())

class Unpack:
    def __init__(self, data): self.d = data; self.o = 0
    def u32(self):
        v, = struct.unpack_from('>I', self.d, self.o); self.o += 4; return v
    def u64(self):
        v, = struct.unpack_from('>Q', self.d, self.o); self.o += 8; return v
    def opaque(self):
        n = self.u32(); v = self.d[self.o:self.o+n]; self.o += n + (-n % 4)
        return v
    def string(self): return self.opaque().decode()

# ------------------------------------------------------------- SunRPC ---

RPC_CALL, RPC_VERS = 0, 2
AUTH_NULL, AUTH_UNIX = 0, 1
PMAP_PROG, PMAP_VERS, PMAPPROC_GETPORT = 100000, 2, 3
MOUNT_PROG, MOUNT_VERS, MOUNTPROC3_MNT, MOUNTPROC3_UMNT = 100005, 3, 1, 3
NFS_PROG, NFS_VERS, NFS_PORT = 100003, 3, 2049
IPPROTO_TCP = 6

class RpcError(Exception): pass

class RpcClient:
    """One TCP connection to one RPC program.  Record-marked stream."""
    def __init__(self, host, port, prog, vers, uid=0, gid=0):
        self.prog, self.vers, self.xid = prog, vers, 1
        self.uid, self.gid = uid, gid
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def _cred_unix(self, p):
        body = Pack().u32(0).string('cnfs').u32(self.uid).u32(self.gid).u32(0)
        p.u32(AUTH_UNIX).opaque(bytes(body.b))          # cred
        p.u32(AUTH_NULL).u32(0)                         # verf
        return p

    def call(self, proc, args=b''):
        self.xid += 1
        hdr = Pack().u32(self.xid).u32(RPC_CALL).u32(RPC_VERS)
        hdr.u32(self.prog).u32(self.vers).u32(proc)
        self._cred_unix(hdr)
        msg = bytes(hdr.b) + args
        # TCP record mark: length with high bit = last fragment
        self.sock.sendall(struct.pack('>I', 0x80000000 | len(msg)) + msg)
        reply = self._recv_record()
        u = Unpack(reply)
        xid, mtype, stat = u.u32(), u.u32(), u.u32()
        if xid != self.xid or mtype != 1 or stat != 0:
            raise RpcError(f'rpc reply xid={xid} mtype={mtype} stat={stat}')
        u.u32(); u.opaque()                             # verf flavor+body
        accept = u.u32()
        if accept != 0:
            raise RpcError(f'rpc accept_stat={accept}')
        return u

    def _recv_record(self):
        out, last = b'', False
        while not last:
            mark, = struct.unpack('>I', self._recvn(4))
            last, n = bool(mark & 0x80000000), mark & 0x7fffffff
            out += self._recvn(n)
        return out

    def _recvn(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk: raise RpcError('connection closed mid-record')
            buf += chunk
        return buf

    def close(self): self.sock.close()

def getport(host, prog, vers):
    pm = RpcClient(host, 111, PMAP_PROG, PMAP_VERS)
    args = Pack().u32(prog).u32(vers).u32(IPPROTO_TCP).u32(0)
    port = pm.call(PMAPPROC_GETPORT, bytes(args.b)).u32()
    pm.close()
    return port

# -------------------------------------------------------------- MOUNT3 ---

def mount_root(host, export, uid, gid):
    port = getport(host, MOUNT_PROG, MOUNT_VERS)
    mc = RpcClient(host, port, MOUNT_PROG, MOUNT_VERS, uid, gid)
    u = mc.call(MOUNTPROC3_MNT, bytes(Pack().string(export).b))
    status = u.u32()
    if status != 0: raise RpcError(f'MNT status={status} (NFS3ERR)')
    fh = u.opaque()
    n = u.u32(); [u.u32() for _ in range(n)]            # auth flavors
    mc.close()
    return fh

# ---------------------------------------------------------------- NFS3 ---

NFS3_OK = 0
(NULL, GETATTR, SETATTR, LOOKUP, ACCESS, READLINK, READ, WRITE, CREATE,
 MKDIR, SYMLINK, MKNOD, REMOVE, RMDIR, RENAME, LINK, READDIR, READDIRPLUS,
 FSSTAT, FSINFO, PATHCONF, COMMIT) = range(22)

ERRNAMES = {2:'NOENT',13:'ACCES',17:'EXIST',20:'NOTDIR',21:'ISDIR',
            28:'NOSPC',30:'ROFS',63:'NAMETOOLONG',66:'NOTEMPTY',70:'STALE'}

def fattr3(u):
    a = {}
    a['type'] = u.u32(); a['mode'] = u.u32(); a['nlink'] = u.u32()
    a['uid'] = u.u32(); a['gid'] = u.u32()
    a['size'] = u.u64(); a['used'] = u.u64()
    u.u32(); u.u32()                                    # rdev
    a['fsid'] = u.u64(); a['fileid'] = u.u64()
    a['atime'] = (u.u32(), u.u32()); a['mtime'] = (u.u32(), u.u32())
    a['ctime'] = (u.u32(), u.u32())
    return a

def post_op_attr(u):
    return fattr3(u) if u.u32() else None

def post_op_fh(u):
    return u.opaque() if u.u32() else None

def wcc_data(u):
    if u.u32(): u.u64(); u.u32(); u.u32(); u.u32(); u.u32()   # pre_op size+times
    post_op_attr(u)

def sattr3_default(mode=None):
    p = Pack()
    if mode is None: p.u32(0)
    else:            p.u32(1).u32(mode)
    p.u32(0).u32(0).u32(0)                              # no uid/gid/size
    p.u32(0).u32(0)                                     # don't touch times
    return p

class Nfs3:
    def __init__(self, host, export, uid=1000, gid=1000):
        self.rootfh = mount_root(host, export, uid, gid)
        self.c = RpcClient(host, NFS_PORT, NFS_PROG, NFS_VERS, uid, gid)

    def _check(self, u, what):
        st = u.u32()
        if st != NFS3_OK:
            raise RpcError(f'{what}: NFS3ERR_{ERRNAMES.get(st, st)}')
        return u

    def fsinfo(self):
        u = self._check(self.c.call(FSINFO, bytes(Pack().opaque(self.rootfh).b)),
                        'FSINFO')
        post_op_attr(u)
        return {'rtmax': u.u32(), 'rtpref': u.u32(), 'rtmult': u.u32(),
                'wtmax': u.u32(), 'wtpref': u.u32(), 'wtmult': u.u32(),
                'dtpref': u.u32(), 'maxfilesize': u.u64()}

    def lookup(self, dirfh, name):
        args = Pack().opaque(dirfh).string(name)
        u = self._check(self.c.call(LOOKUP, bytes(args.b)), f'LOOKUP {name}')
        fh = u.opaque(); attr = post_op_attr(u)
        return fh, attr

    def readdirplus(self, dirfh):
        entries, cookie, verf = [], 0, b'\0' * 8
        while True:
            args = Pack().opaque(dirfh).u64(cookie)
            args.b += verf
            args.u32(8192).u32(32768)                   # dircount, maxcount
            u = self._check(self.c.call(READDIRPLUS, bytes(args.b)),
                            'READDIRPLUS')
            post_op_attr(u)
            verf = u.d[u.o:u.o+8]; u.o += 8
            while u.u32():                              # entry follows
                u.u64()                                 # fileid
                name = u.string()
                cookie = u.u64()
                attr = post_op_attr(u); fh = post_op_fh(u)
                if name not in ('.', '..'):
                    entries.append((name, attr, fh))
            if u.u32(): return entries                  # eof

    def read_all(self, fh, size, chunk=32768):
        data, off = b'', 0
        while off < size:
            args = Pack().opaque(fh).u64(off).u32(chunk)
            u = self._check(self.c.call(READ, bytes(args.b)), 'READ')
            post_op_attr(u)
            count, eof = u.u32(), u.u32()
            data += u.opaque(); off += count
            if eof: break
        return data

    def create(self, dirfh, name, mode=0o644):
        args = Pack().opaque(dirfh).string(name).u32(0)   # UNCHECKED
        args.b += sattr3_default(mode).b
        u = self._check(self.c.call(CREATE, bytes(args.b)), f'CREATE {name}')
        fh = post_op_fh(u); post_op_attr(u); wcc_data(u)
        return fh if fh else self.lookup(dirfh, name)[0]

    def write(self, fh, offset, data, stable=2):        # 2 = FILE_SYNC
        args = Pack().opaque(fh).u64(offset).u32(len(data)).u32(stable)
        args.opaque(data)
        u = self._check(self.c.call(WRITE, bytes(args.b)), 'WRITE')
        wcc_data(u)
        return u.u32()                                  # count written

    def mkdir(self, dirfh, name):
        args = Pack().opaque(dirfh).string(name)
        args.b += sattr3_default(0o755).b
        u = self._check(self.c.call(MKDIR, bytes(args.b)), f'MKDIR {name}')
        fh = post_op_fh(u); post_op_attr(u); wcc_data(u)
        return fh

    def remove(self, dirfh, name, isdir=False):
        args = Pack().opaque(dirfh).string(name)
        self._check(self.c.call(RMDIR if isdir else REMOVE, bytes(args.b)),
                    f'REMOVE {name}')

    def rename(self, fromdir, fromname, todir, toname):
        args = Pack().opaque(fromdir).string(fromname)
        args.opaque(todir).string(toname)
        self._check(self.c.call(RENAME, bytes(args.b)), f'RENAME {fromname}')

    def walk(self, path):
        """path like 'Docs/notes.txt' from root -> (fh, attr)"""
        fh, attr = self.rootfh, None
        for part in [p for p in path.split('/') if p]:
            fh, attr = self.lookup(fh, part)
        return fh, attr

# ---------------------------------------------------------------- CLI ---

TYPENAMES = {1: '-', 2: 'd', 3: 'b', 4: 'c', 5: 'l', 6: 's', 7: 'p'}

def cmd_probe(host):
    for name, prog, vers in (('mountd', MOUNT_PROG, MOUNT_VERS),
                             ('nfsd', NFS_PROG, NFS_VERS)):
        print(f'{name}: tcp port {getport(host, prog, vers)}')

def cmd_ls(host, export, sub=''):
    fs = Nfs3(host, export)
    dirfh = fs.walk(sub)[0] if sub else fs.rootfh
    for name, attr, _fh in sorted(fs.readdirplus(dirfh)):
        t = TYPENAMES.get(attr['type'], '?') if attr else '?'
        size = attr['size'] if attr else 0
        print(f'{t} {size:>10} {name}')

def cmd_tree(host, export):
    fs = Nfs3(host, export)
    def rec(fh, prefix):
        for name, attr, efh in sorted(fs.readdirplus(fh)):
            isdir = attr and attr['type'] == 2
            print(f'{prefix}{name}{"/" if isdir else ""}')
            if isdir:
                rec(efh if efh else fs.lookup(fh, name)[0], prefix + '  ')
    rec(fs.rootfh, '')

def cmd_cat(host, export, path):
    fs = Nfs3(host, export)
    fh, attr = fs.walk(path)
    sys.stdout.buffer.write(fs.read_all(fh, attr['size']))

def cmd_mount(host, export):
    fh = mount_root(host, export, 1000, 1000)
    print(f'root fh ({len(fh)} bytes): {fh.hex()}')

def cmd_selftest(host, export):
    fs = Nfs3(host, export)
    info = fs.fsinfo()
    print(f'FSINFO: rtpref={info["rtpref"]} wtpref={info["wtpref"]} '
          f'maxfile={info["maxfilesize"]}')
    # read side: pattern.bin must match the generator exactly
    fh, attr = fs.walk('pattern.bin')
    data = fs.read_all(fh, attr['size'])
    expect = b''.join(struct.pack('>I', i) for i in range(0, 2*1024*1024, 4))
    assert data == expect, 'pattern.bin mismatch'
    print(f'READ: pattern.bin {len(data)} bytes verified')
    # write side: create, write, read back, rename, remove
    d = fs.mkdir(fs.rootfh, 'selftest-tmp')
    f = fs.create(d, 'hello.txt')
    payload = b'written from nfswire.py\n' * 100
    n = fs.write(f, 0, payload)
    assert n == len(payload), f'short write {n}'
    back = fs.read_all(f, len(payload))
    assert back == payload, 'readback mismatch'
    print(f'WRITE: {n} bytes round-tripped')
    fs.rename(d, 'hello.txt', d, 'renamed.txt')
    fs.remove(d, 'renamed.txt')
    fs.remove(fs.rootfh, 'selftest-tmp', isdir=True)
    print('RENAME/REMOVE/RMDIR: ok')
    print('selftest: ALL GREEN')

if __name__ == '__main__':
    cmds = {'probe': cmd_probe, 'mount': cmd_mount, 'ls': cmd_ls,
            'tree': cmd_tree, 'cat': cmd_cat, 'selftest': cmd_selftest}
    if len(sys.argv) < 3 or sys.argv[1] not in cmds:
        print(__doc__); sys.exit(1)
    cmds[sys.argv[1]](*sys.argv[2:])
