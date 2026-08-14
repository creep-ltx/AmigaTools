/*
 * AmiNFSv3 nfs-handler - an NFSv3-over-TCP client filesystem for AmigaOS 3.x.
 *
 * Speaks SunRPC/XDR/MOUNT3/NFS3 through bsdsocket.library to a stock
 * Linux kernel nfsd. The wire logic mirrors tests/nfswire.py, which is
 * the reference implementation - when in doubt, that file is the truth.
 *
 * Built with -nostartfiles -nostdlib: the entry point is the first
 * function in this file (-fno-toplevel-reorder keeps it there), there
 * is no CLI and no startup code. DOS starts us with the mount packet
 * on our pr_MsgPort.
 *
 * The handler is synchronous: each packet's NFS round-trip completes
 * before the reply. One Amiga, one user - the simplicity is worth more
 * than overlap. Connects lazily on first use, so mounting at boot
 * before the TCP stack is up costs nothing.
 *
 * Read/write since b9. Since b10 writes go UNSTABLE with a COMMIT at
 * close - the write verifier is tracked, so a server reboot that eats
 * uncommitted data fails the Close() instead of losing bytes silently.
 */

#include <exec/types.h>
#include <exec/memory.h>
#include <exec/execbase.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <dos/filehandler.h>
#include <proto/exec.h>
#include <proto/dos.h>

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/ioctl.h>
#include <proto/bsdsocket.h>

struct ExecBase *SysBase;
struct DosLibrary *DOSBase;
struct Library *SocketBase;

/* entry.c jumps here; it is linked first so the seglist starts with code */
LONG handler_main(void);

static const char verstag[] __attribute__((used)) =
    "$VER: nfs-handler 0.1b21 (14.8.2026)";

/* ------------------------------------------------------------------ */
/* mini libc (we link with -nostdlib; gcc also emits calls to these)  */

void *memcpy(void *dst, const void *src, __SIZE_TYPE__ n)
{
    UBYTE *d = dst; const UBYTE *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int v, __SIZE_TYPE__ n)
{
    UBYTE *d = dst;
    while (n--) *d++ = (UBYTE)v;
    return dst;
}

static int c_memcmp(const void *a, const void *b, __SIZE_TYPE__ n)
{
    const UBYTE *x = a, *y = b;
    while (n--) { if (*x != *y) return *x - *y; x++; y++; }
    return 0;
}

static LONG c_strlen(const char *s) { const char *p = s; while (*p) p++; return p - s; }

/* This libgcc also lacks __mulsi3 (32x32 multiply on plain 68000);
 * provide it so ordinary '*' keeps working everywhere. */
LONG __mulsi3(LONG a, LONG b)
{
    ULONG ua = a, ub = b, r = 0;
    while (ub) {
        if (ub & 1) r += ua;
        ua <<= 1;
        ub >>= 1;
    }
    return (LONG)r;
}

/* -nostdlib means no reliable __udivsi3/__umodsi3; divide by hand */
static ULONG udivmod(ULONG n, ULONG d, ULONG *rem)
{
    ULONG q = 0, r = 0;
    LONG i;
    for (i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) { r -= d; q |= 1UL << i; }
    }
    if (rem) *rem = r;
    return q;
}

static char lower(char c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

static LONG names_equal_nocase(const char *a, LONG alen, const char *b, LONG blen)
{
    LONG i;
    if (alen != blen) return 0;
    for (i = 0; i < alen; i++)
        if (lower(a[i]) != lower(b[i])) return 0;
    return 1;
}

/* ------------------------------------------------------------------ */
/* KPrintF-grade telemetry via exec RawPutChar (LVO -516).            */
/* wasabid's debug stream captures this: `wasabi debug` shows it live. */

static void kputc(char c)
{
    register char rd0 asm("d0") = c;
    register struct ExecBase *ra6 asm("a6") = SysBase;
    asm volatile ("jsr -516(%%a6)"
                  : : "r"(rd0), "r"(ra6) : "d1", "a0", "a1", "cc", "memory");
}

static void kput(const char *s) { while (*s) kputc(*s++); }

static void kputu(ULONG v)
{
    char buf[12]; int i = 12;
    do {
        ULONG r;
        v = udivmod(v, 10, &r);
        buf[--i] = '0' + r;
    } while (v);
    while (i < 12) kputc(buf[i++]);
}

#define DBG(x)      do { kput("AmiNFSv3: "); kput(x); kputc('\n'); } while (0)
#define DBG2(x, n)  do { kput("AmiNFSv3: "); kput(x); kputu(n); kputc('\n'); } while (0)

/* ------------------------------------------------------------------ */
/* protocol constants (mirrors nfswire.py)                            */

#define RPC_CALL        0
#define RPC_VERS        2
#define AUTH_NULL       0
#define AUTH_UNIX       1

#define PMAP_PROG       100000
#define PMAP_VERS       2
#define PMAP_GETPORT    3
#define PMAP_PORT       111

#define MOUNT_PROG      100005
#define MOUNT_VERS      3
#define MOUNTPROC_MNT   1

#define NFS_PROG        100003
#define NFS_VERS        3
#define NFS_PORT        2049

#define NFS3_GETATTR    1
#define NFS3_SETATTR    2
#define NFS3_LOOKUP     3
#define NFS3_READ       6
#define NFS3_WRITE      7
#define NFS3_CREATE     8
#define NFS3_MKDIR      9
#define NFS3_REMOVE     12
#define NFS3_RMDIR      13
#define NFS3_RENAME     14
#define NFS3_COMMIT     21
#define NFS3_READDIRPLUS 17
#define NFS3_FSSTAT     18

#define NF3REG          1
#define NF3DIR          2

#define CONN_TIMEOUT    5              /* seconds, connect */
#define RECV_TIMEOUT    10             /* seconds, per recv */

#define FHSIZE_MAX      64
/* Transfer sizes are runtime options (RSIZE=/WSIZE=). Defaults suit a

 * On Emu68's lwIP keep WSIZE <= 65536: larger blocked sends wake on a
 * coarse timer, ~485ms per chunk (measured). */
#define RSIZE_DEFAULT   65536
#define WSIZE_DEFAULT   32768
#define XFER_MIN        4096
#define XFER_MAX        131072
#define REPBUF_EXTRA    4096
#define REQBUF_EXTRA    768
#define NAME_MAX_AMIGA  106

/* ------------------------------------------------------------------ */
/* state                                                              */

struct DirEnt {
    ULONG  fileid;
    ULONG  size;
    ULONG  mode;
    ULONG  ftype;
    ULONG  mtime;                      /* unix seconds */
    UBYTE  fhlen;
    UBYTE  fh[FHSIZE_MAX];
    UBYTE  namelen;
    char   name[NAME_MAX_AMIGA + 1];
};

#define DIRCHUNK_N 16
struct DirChunk {
    struct DirChunk *next;
    LONG   used;
    struct DirEnt e[DIRCHUNK_N];
};

struct CLock {
    struct FileLock  fl;               /* must be first: BADDR of this */
    struct CLock    *next;
    ULONG  fhlen;
    UBYTE  fh[FHSIZE_MAX];
    ULONG  ftype;                      /* NF3REG / NF3DIR */
    struct DirChunk *dc;               /* EXAMINE_NEXT snapshot */
    LONG   dctotal;
    char   name[NAME_MAX_AMIGA + 1];   /* leaf name, for EXAMINE */
};

struct CFile {
    struct CFile *next;
    ULONG  fhlen;
    UBYTE  fh[FHSIZE_MAX];
    ULONG  pos;
    ULONG  size;
    LONG   dirty;                      /* UNSTABLE data awaiting COMMIT */
    LONG   verf_valid;
    LONG   lost;                       /* verifier changed mid-file */
    UBYTE  wverf[8];
    char   name[NAME_MAX_AMIGA + 1];
};

struct Attr {                          /* decoded fattr3, 32-bit view */
    ULONG ftype, mode, size, fileid, mtime;
};

static struct MsgPort    *g_port;
static struct DeviceNode *g_devnode;
static struct DosList    *g_volnode;
static struct CLock      *g_locks;
static struct CFile      *g_files;
static LONG   g_nlocks, g_nfiles;
static LONG   g_dying;

static char   g_host[64];              /* dotted quad from Startup */
static char   g_export[192];
static char   g_volname[32];
static ULONG  g_uid, g_gid;            /* AUTH_UNIX identity (UID=/GID=) */
static LONG   g_tzoff;                 /* seconds east of UTC (TZ=) */
static LONG   g_volset;                /* VOLUME= given */

static LONG   g_sock;                  /* persistent nfsd connection */
static LONG   g_have_root;
static ULONG  g_rootfhlen;
static UBYTE  g_rootfh[FHSIZE_MAX];
static ULONG  g_xid;

static UBYTE *g_req;                   /* request build buffer */
static UBYTE *g_rep;                   /* reply buffer */
static ULONG  g_reqlen;
static ULONG  g_rsize, g_wsize;        /* RSIZE=/WSIZE= transfer chunks */
static ULONG  g_depth;                 /* DEPTH= write pipeline (1=sync) */
static ULONG  g_testshort;             /* fault injection: every Nth */
static ULONG  g_testdrop;              /*   write reply halved / dropped */
static ULONG  g_reqbufsz, g_repbufsz;

/* ------------------------------------------------------------------ */
/* XDR pack into g_req / unpack out of g_rep. m68k is big-endian =    */
/* XDR byte order, but the helpers keep bounds honest.                */

static void pk_u32(ULONG v)
{
    if (g_reqlen + 4 <= g_reqbufsz) {
        UBYTE *p = g_req + g_reqlen;
        p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v;
        g_reqlen += 4;
    }
}

static void pk_u64(ULONG hi, ULONG lo) { pk_u32(hi); pk_u32(lo); }

static void pk_opaque(const UBYTE *d, ULONG n)
{
    ULONG pad = (4 - (n & 3)) & 3;
    pk_u32(n);
    if (g_reqlen + n + pad <= g_reqbufsz) {
        memcpy(g_req + g_reqlen, d, n);
        memset(g_req + g_reqlen + n, 0, pad);
        g_reqlen += n + pad;
    }
}

static void pk_str(const char *s) { pk_opaque((const UBYTE *)s, c_strlen(s)); }

struct UB { UBYTE *p, *end; LONG err; };

static ULONG ub_u32(struct UB *u)
{
    ULONG v;
    if (u->p + 4 > u->end) { u->err = 1; return 0; }
    v = ((ULONG)u->p[0] << 24) | ((ULONG)u->p[1] << 16)
      | ((ULONG)u->p[2] << 8) | u->p[3];
    u->p += 4;
    return v;
}

/* 64-bit XDR field, folded to the 32 bits AmigaDOS can express */
static ULONG ub_u64lo(struct UB *u)
{
    ULONG hi = ub_u32(u), lo = ub_u32(u);
    return hi ? 0xFFFFFFFF : lo;       /* >4GB clamps, never lies small */
}

static UBYTE *ub_opaque(struct UB *u, ULONG *lenp)
{
    ULONG n = ub_u32(u);
    ULONG pad = (4 - (n & 3)) & 3;
    UBYTE *d = u->p;
    if (u->p + n + pad > u->end) { u->err = 1; *lenp = 0; return NULL; }
    u->p += n + pad;
    *lenp = n;
    return d;
}

static void ub_skip(struct UB *u, ULONG n)
{
    if (u->p + n > u->end) u->err = 1; else u->p += n;
}

/* fattr3 is 84 bytes; pull the fields we keep, skip the rest in place */
static void ub_fattr(struct UB *u, struct Attr *a)
{
    a->ftype = ub_u32(u);
    a->mode  = ub_u32(u);
    ub_skip(u, 12);                    /* nlink uid gid */
    a->size  = ub_u64lo(u);
    ub_skip(u, 8 + 8);                 /* used, rdev */
    ub_skip(u, 8);                     /* fsid */
    ub_skip(u, 4); a->fileid = ub_u32(u);
    ub_skip(u, 8);                     /* atime */
    a->mtime = ub_u32(u); ub_skip(u, 4);
    ub_skip(u, 8);                     /* ctime */
}

static LONG ub_postop_attr(struct UB *u, struct Attr *a)
{
    if (ub_u32(u)) { ub_fattr(u, a); return 1; }
    return 0;
}

/* ------------------------------------------------------------------ */
/* sockets: connect, record-marked send/recv                          */

static LONG tcp_connect(ULONG ip, UWORD dstport)
{
    struct sockaddr_in sa;
    LONG rc, s, nb = 1;

    s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return -1;
    memset(&sa, 0, sizeof(sa));
    sa.sin_len = sizeof(sa);
    sa.sin_family = AF_INET;
    sa.sin_port = dstport;             /* big-endian host: already net order */
    sa.sin_addr.s_addr = ip;

    /* Non-blocking connect + WaitSelect = a real timeout; a dead server
     * must never wedge the handler. If FIONBIO is unsupported we accept
     * a plain blocking connect rather than fail. */
    if (IoctlSocket(s, FIONBIO, (char *)&nb) == 0) {
        rc = connect(s, (struct sockaddr *)&sa, sizeof(sa));
        if (rc < 0) {
            LONG e = Errno();
            if (e == 35 || e == 36) {  /* EWOULDBLOCK / EINPROGRESS */
                fd_set wf;
                struct timeval tv;
                FD_ZERO(&wf); FD_SET(s, &wf);
                tv.tv_sec = CONN_TIMEOUT; tv.tv_usec = 0;
                if (WaitSelect(s + 1, NULL, &wf, NULL, &tv, NULL) == 1) {
                    LONG soerr = 0;
                    socklen_t slen = sizeof(soerr);
                    rc = (getsockopt(s, SOL_SOCKET, SO_ERROR, &soerr, &slen) == 0
                          && soerr == 0) ? 0 : -1;
                } else rc = -1;        /* timeout or select error */
            }
        }
        nb = 0;
        IoctlSocket(s, FIONBIO, (char *)&nb);
    } else {
        rc = connect(s, (struct sockaddr *)&sa, sizeof(sa));
    }
    if (rc != 0) {
        DBG2("connect failed, port ", dstport);
        CloseSocket(s);
        return -1;
    }
    {
        LONG one = 1, buf = (g_rsize > g_wsize ? g_rsize : g_wsize);
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        /* a full write chunk must queue in one go, or every WRITE RPC
         * stalls against the peer's delayed ACKs (measured: ~90ms/16KB) */
        setsockopt(s, SOL_SOCKET, SO_SNDBUF, &buf, sizeof(buf));
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &buf, sizeof(buf));
    }
    return s;
}

static LONG sendall(LONG s, const UBYTE *d, ULONG n)
{
    while (n) {
        LONG r = send(s, (UBYTE *)d, n, 0);
        if (r <= 0) return -1;
        d += r; n -= r;
    }
    return 0;
}

static LONG recvn(LONG s, UBYTE *d, ULONG n)
{
    while (n) {
        fd_set rf;
        struct timeval tv;
        LONG r;
        FD_ZERO(&rf); FD_SET(s, &rf);
        tv.tv_sec = RECV_TIMEOUT; tv.tv_usec = 0;
        r = WaitSelect(s + 1, &rf, NULL, NULL, &tv, NULL);
        if (r != 1) { DBG("recv timeout"); return -1; }
        r = recv(s, d, n, 0);
        if (r <= 0) return -1;
        d += r; n -= r;
    }
    return 0;
}

/* ------------------------------------------------------------------ */
/* SunRPC: build call header, transact one record-marked round trip.  */
/* On success returns 1 and points *u at the proc results in g_rep.   */

static void rpc_begin(ULONG prog, ULONG vers, ULONG proc)
{
    g_reqlen = 4;                      /* room for the record mark */
    g_xid++;
    pk_u32(g_xid); pk_u32(RPC_CALL); pk_u32(RPC_VERS);
    pk_u32(prog); pk_u32(vers); pk_u32(proc);
    /* AUTH_UNIX cred: stamp, machinename, uid, gid, gids<0> */
    pk_u32(AUTH_UNIX);
    /* body: stamp(4) + name "aminfsv3" (4 len + 8 + 0 pad = 12) + uid(4)
     * + gid(4) + gids count(4) = 28. Length must track the name. */
    pk_u32(28);
    pk_u32(0); pk_str("aminfsv3"); pk_u32(g_uid); pk_u32(g_gid); pk_u32(0);
    pk_u32(AUTH_NULL); pk_u32(0);      /* verf */
}

static LONG rpc_send(LONG s)
{
    ULONG msglen = g_reqlen - 4;
    UBYTE *p = g_req;

    p[0] = 0x80 | (msglen >> 24); p[1] = msglen >> 16;
    p[2] = msglen >> 8; p[3] = msglen;
    return sendall(s, g_req, g_reqlen);
}

/* One reply record into g_rep, RPC header parsed and checked. The xid
 * comes back via *rxid so pipelined callers can match it to a slot. */
static LONG rpc_recv(LONG s, struct UB *u, ULONG *rxid)
{
    ULONG total = 0, last = 0;

    while (!last) {
        UBYTE mark[4]; ULONG n;
        if (recvn(s, mark, 4)) return 0;
        last = mark[0] & 0x80;
        n = ((ULONG)(mark[0] & 0x7F) << 24) | ((ULONG)mark[1] << 16)
          | ((ULONG)mark[2] << 8) | mark[3];
        if (total + n > g_repbufsz) return 0;
        if (recvn(s, g_rep + total, n)) return 0;
        total += n;
    }

    u->p = g_rep; u->end = g_rep + total; u->err = 0;
    {
        ULONG xid = ub_u32(u), mtype = ub_u32(u), stat = ub_u32(u);
        ULONG vlen;
        if (u->err || mtype != 1 || stat != 0) return 0;
        ub_u32(u); ub_opaque(u, &vlen);        /* verifier */
        if (ub_u32(u) != 0) return 0;          /* accept_stat */
        *rxid = xid;
    }
    return !u->err;
}

static LONG rpc_finish(LONG s, struct UB *u)
{
    ULONG rxid;
    if (rpc_send(s)) return 0;
    if (!rpc_recv(s, u, &rxid)) return 0;
    return rxid == g_xid;
}

/* ------------------------------------------------------------------ */
/* connection management: lazy open of bsdsocket, lazy MNT            */

static LONG parse_ip(const char *s, ULONG *out)
{
    ULONG ip = 0, part = 0, seen = 0, dots = 0;
    for (;; s++) {
        if (*s >= '0' && *s <= '9') { part = part * 10 + (*s - '0'); seen = 1; }
        else if (*s == '.' || *s == 0) {
            if (!seen || part > 255) return 0;
            ip = (ip << 8) | part; part = 0; seen = 0;
            if (*s == 0) break;
            dots++;
        } else return 0;
    }
    if (dots != 3) return 0;
    *out = ip;
    return 1;
}

static void drop_conn(void)
{
    if (g_sock >= 0 && SocketBase) CloseSocket(g_sock);
    g_sock = -1;
}

/* 0 = ok, else an AmigaDOS error code */
static LONG net_up(void)
{
    ULONG ip;

    if (!SocketBase) {
        SocketBase = OpenLibrary("bsdsocket.library", 4);
        if (!SocketBase) {
            DBG("no bsdsocket.library (TCP stack not up?)");
            return ERROR_DEVICE_NOT_MOUNTED;
        }
        DBG("bsdsocket open");
    }
    if (!parse_ip(g_host, &ip)) {
        DBG("bad host in Startup (need dotted quad)");
        return ERROR_BAD_STREAM_NAME;
    }

    if (!g_have_root) {
        struct UB u;
        LONG s;
        ULONG port;

        s = tcp_connect(ip, PMAP_PORT);
        if (s < 0) return ERROR_DEVICE_NOT_MOUNTED;
        rpc_begin(PMAP_PROG, PMAP_VERS, PMAP_GETPORT);
        pk_u32(MOUNT_PROG); pk_u32(MOUNT_VERS); pk_u32(6 /*tcp*/); pk_u32(0);
        if (!rpc_finish(s, &u)) {
            DBG("GETPORT rpc failed");
            CloseSocket(s); return ERROR_DEVICE_NOT_MOUNTED;
        }
        port = ub_u32(&u);
        CloseSocket(s);
        if (!port || port > 0xFFFF) return ERROR_DEVICE_NOT_MOUNTED;
        DBG2("mountd at port ", port);

        s = tcp_connect(ip, (UWORD)port);
        if (s < 0) return ERROR_DEVICE_NOT_MOUNTED;
        rpc_begin(MOUNT_PROG, MOUNT_VERS, MOUNTPROC_MNT);
        pk_str(g_export);
        if (!rpc_finish(s, &u)) { CloseSocket(s); return ERROR_DEVICE_NOT_MOUNTED; }
        {
            ULONG st = ub_u32(&u), n;
            UBYTE *fh = ub_opaque(&u, &n);
            CloseSocket(s);
            if (st != 0 || !fh || n > FHSIZE_MAX) {
                DBG2("MNT refused, status ", st);
                return st == 13 ? ERROR_READ_PROTECTED : ERROR_DEVICE_NOT_MOUNTED;
            }
            memcpy(g_rootfh, fh, n);
            g_rootfhlen = n;
            g_have_root = 1;
            DBG2("root fh bytes: ", n);
        }
    }

    if (g_sock < 0) {
        g_sock = tcp_connect(ip, NFS_PORT);
        if (g_sock < 0) return ERROR_DEVICE_NOT_MOUNTED;
        DBG("nfsd connected");
    }
    return 0;
}

/* One NFS transaction with a single silent reconnect on transport death.
 * The args are re-packed on retry, so a half-sent request never lingers. */
struct NfsArgs {
    const UBYTE *fh;  ULONG fhlen;
    const char *name;
    const UBYTE *fh2; ULONG fh2len;    /* RENAME destination dir */
    const char *name2;
    const UBYTE *data; ULONG dlen;     /* WRITE payload */
    ULONG a, b, c;                     /* offset/count/cookie */
    LONG set_mode;  ULONG mode;        /* sattr3 pieces */
    LONG set_size;  ULONG size;
    LONG set_mtime; ULONG mtime;
};

static void pk_sattr(const struct NfsArgs *na)
{
    if (na->set_mode) { pk_u32(1); pk_u32(na->mode); } else pk_u32(0);
    pk_u32(0); pk_u32(0);              /* uid, gid: never set */
    if (na->set_size) { pk_u32(1); pk_u64(0, na->size); } else pk_u32(0);
    pk_u32(0);                         /* atime: DONT_CHANGE */
    if (na->set_mtime) { pk_u32(2); pk_u32(na->mtime); pk_u32(0); }
    else pk_u32(0);                    /* 2 = SET_TO_CLIENT_TIME */
}

/* returns 0 ok (u at status word), else DOS error */
static LONG nfs_call(ULONG proc, const struct NfsArgs *na, struct UB *u,
                     const UBYTE *verf /* 8 bytes for READDIRPLUS, else NULL */)
{
    LONG try, err;

    for (try = 0; try < 2; try++) {
        err = net_up();
        if (err) return err;

        rpc_begin(NFS_PROG, NFS_VERS, proc);
        pk_opaque(na->fh, na->fhlen);
        if (proc == NFS3_LOOKUP) {
            pk_str(na->name);
        } else if (proc == NFS3_READ) {
            pk_u64(0, na->a); pk_u32(na->b);
        } else if (proc == NFS3_READDIRPLUS) {
            pk_u64(na->a, na->b);
            if (g_reqlen + 8 <= g_reqbufsz) {   /* cookieverf: raw 8 bytes */
                memcpy(g_req + g_reqlen, verf, 8);
                g_reqlen += 8;
            }
            pk_u32(4096);              /* dircount */
            pk_u32(g_repbufsz - 512); /* maxcount */
        } else if (proc == NFS3_SETATTR) {
            pk_sattr(na);
            pk_u32(0);                 /* guard: no ctime check */
        } else if (proc == NFS3_WRITE) {
            pk_u64(0, na->a);
            pk_u32(na->dlen);
            pk_u32(0);                 /* UNSTABLE: COMMIT happens at close */
            pk_opaque(na->data, na->dlen);
        } else if (proc == NFS3_COMMIT) {
            pk_u64(0, 0);              /* offset 0, count 0 = whole file */
            pk_u32(0);
        } else if (proc == NFS3_CREATE) {
            pk_str(na->name);
            pk_u32(0);                 /* UNCHECKED */
            pk_sattr(na);
        } else if (proc == NFS3_MKDIR) {
            pk_str(na->name);
            pk_sattr(na);
        } else if (proc == NFS3_REMOVE || proc == NFS3_RMDIR) {
            pk_str(na->name);
        } else if (proc == NFS3_RENAME) {
            pk_str(na->name);
            pk_opaque(na->fh2, na->fh2len);
            pk_str(na->name2);
        }
        if (rpc_finish(g_sock, u)) return 0;
        DBG("transport error, reconnecting");
        drop_conn();
    }
    return ERROR_DEVICE_NOT_MOUNTED;
}

static LONG nfs3_to_dos(ULONG st)
{
    switch (st) {
    case 2:  return ERROR_OBJECT_NOT_FOUND;      /* NOENT */
    case 13: return ERROR_READ_PROTECTED;        /* ACCES */
    case 17: return ERROR_OBJECT_EXISTS;
    case 20: return ERROR_OBJECT_WRONG_TYPE;     /* NOTDIR */
    case 21: return ERROR_OBJECT_WRONG_TYPE;     /* ISDIR */
    case 28: return ERROR_DISK_FULL;
    case 30: return ERROR_DISK_WRITE_PROTECTED;
    case 63: return ERROR_INVALID_COMPONENT_NAME;
    case 66: return ERROR_DIRECTORY_NOT_EMPTY;
    case 70: return ERROR_OBJECT_NOT_FOUND;      /* STALE */
    default: return ERROR_ACTION_NOT_KNOWN;
    }
}

/* ------------------------------------------------------------------ */
/* NFS operations at the level the packet code wants                  */

static LONG nfs_lookup(const UBYTE *dirfh, ULONG dirfhlen, const char *name,
                       UBYTE *outfh, ULONG *outfhlen, struct Attr *a,
                       char *actual /* server-case name out, may be NULL */);

static LONG nfs_getattr(const UBYTE *fh, ULONG fhlen, struct Attr *a)
{
    struct UB u;
    struct NfsArgs na;
    LONG err;
    ULONG st;

    na.fh = fh; na.fhlen = fhlen;
    err = nfs_call(NFS3_GETATTR, &na, &u, NULL);
    if (err) return err;
    st = ub_u32(&u);
    if (st != 0) return nfs3_to_dos(st);
    ub_fattr(&u, a);
    return u.err ? ERROR_ACTION_NOT_KNOWN : 0;
}

/* whole-directory snapshot via READDIRPLUS; chunk list out */
static LONG nfs_readdir(const UBYTE *dirfh, ULONG dirfhlen,
                        struct DirChunk **out, LONG *total)
{
    struct DirChunk *head = NULL, *tail = NULL;
    ULONG chi = 0, clo = 0;
    UBYTE verf[8];
    LONG count = 0;

    memset(verf, 0, 8);
    *out = NULL; *total = 0;

    for (;;) {
        struct UB u;
        struct NfsArgs na;
        LONG err;
        ULONG st;
        struct Attr da;
        LONG eof;

        na.fh = dirfh; na.fhlen = dirfhlen; na.a = chi; na.b = clo;
        err = nfs_call(NFS3_READDIRPLUS, &na, &u, verf);
        if (err) goto fail_err;
        st = ub_u32(&u);
        if (st != 0) { err = nfs3_to_dos(st); goto fail_err; }
        ub_postop_attr(&u, &da);
        if (u.p + 8 > u.end) { u.err = 1; goto fail_proto; }
        memcpy(verf, u.p, 8); u.p += 8;

        while (ub_u32(&u)) {           /* another entry */
            ULONG namelen;
            UBYTE *nm;
            struct Attr ea;
            LONG have_attr, have_fh;
            ULONG efhlen = 0;
            UBYTE *efh = NULL;

            ub_skip(&u, 8);            /* fileid (also in attrs) */
            nm = ub_opaque(&u, &namelen);
            chi = ub_u32(&u); clo = ub_u32(&u);   /* cookie */
            have_attr = ub_postop_attr(&u, &ea);
            have_fh = ub_u32(&u);
            if (have_fh) efh = ub_opaque(&u, &efhlen);
            if (u.err) goto fail_proto;

            if (!nm) continue;
            if (namelen == 1 && nm[0] == '.') continue;
            if (namelen == 2 && nm[0] == '.' && nm[1] == '.') continue;
            if (namelen > NAME_MAX_AMIGA) continue;   /* unreachable name; skip */
            if (efhlen > FHSIZE_MAX) { efh = NULL; efhlen = 0; }

            if (!tail || tail->used == DIRCHUNK_N) {
                struct DirChunk *nc = AllocVec(sizeof(*nc), MEMF_PUBLIC | MEMF_CLEAR);
                if (!nc) goto fail_mem;
                if (tail) tail->next = nc; else head = nc;
                tail = nc;
            }
            {
                struct DirEnt *e = &tail->e[tail->used++];
                memcpy(e->name, nm, namelen);
                e->name[namelen] = 0;
                e->namelen = namelen;
                if (have_attr) {
                    e->fileid = ea.fileid; e->size = ea.size;
                    e->mode = ea.mode; e->ftype = ea.ftype; e->mtime = ea.mtime;
                }
                if (efh) { memcpy(e->fh, efh, efhlen); e->fhlen = efhlen; }
                count++;
            }
        }
        eof = ub_u32(&u);
        if (u.err) goto fail_proto;
        if (eof) break;
    }
    *out = head; *total = count;
    return 0;

fail_proto:
    DBG("READDIRPLUS: malformed reply");
fail_mem:
fail_err:
    while (head) { struct DirChunk *n = head->next; FreeVec(head); head = n; }
    return ERROR_NO_FREE_STORE;
}

static void free_dircache(struct CLock *cl)
{
    struct DirChunk *c = cl->dc;
    while (c) { struct DirChunk *n = c->next; FreeVec(c); c = n; }
    cl->dc = NULL; cl->dctotal = 0;
}

static LONG nfs_lookup(const UBYTE *dirfh, ULONG dirfhlen, const char *name,
                       UBYTE *outfh, ULONG *outfhlen, struct Attr *a,
                       char *actual)
{
    struct UB u;
    struct NfsArgs na;
    LONG err;
    ULONG st, n;
    UBYTE *fh;

    na.fh = dirfh; na.fhlen = dirfhlen; na.name = name;
    err = nfs_call(NFS3_LOOKUP, &na, &u, NULL);
    if (err) return err;
    st = ub_u32(&u);

    if (st == 2 /*NOENT*/) {
        /* Amiga eyes are case-blind; Linux's aren't. Scan the directory
         * for a unique case-insensitive match before giving up. */
        struct DirChunk *dc, *c;
        LONG total, wanted = c_strlen(name);
        struct DirEnt *hit = NULL;
        if (nfs_readdir(dirfh, dirfhlen, &dc, &total) == 0) {
            for (c = dc; c; c = c->next) {
                LONG i;
                for (i = 0; i < c->used; i++)
                    if (names_equal_nocase(c->e[i].name, c->e[i].namelen,
                                           name, wanted)) {
                        if (hit) { hit = NULL; c = NULL; break; }  /* ambiguous */
                        hit = &c->e[i];
                    }
                if (!c) break;
            }
            if (hit && hit->fhlen) {
                memcpy(outfh, hit->fh, hit->fhlen);
                *outfhlen = hit->fhlen;
                a->ftype = hit->ftype; a->mode = hit->mode; a->size = hit->size;
                a->fileid = hit->fileid; a->mtime = hit->mtime;
                if (actual) memcpy(actual, hit->name, hit->namelen + 1);
                while (dc) { struct DirChunk *nx = dc->next; FreeVec(dc); dc = nx; }
                return 0;
            }
            while (dc) { struct DirChunk *nx = dc->next; FreeVec(dc); dc = nx; }
        }
        return ERROR_OBJECT_NOT_FOUND;
    }
    if (st != 0) return nfs3_to_dos(st);

    fh = ub_opaque(&u, &n);
    if (!fh || n > FHSIZE_MAX || u.err) return ERROR_ACTION_NOT_KNOWN;
    memcpy(outfh, fh, n);
    *outfhlen = n;
    if (actual) memcpy(actual, name, c_strlen(name) + 1);
    if (!ub_postop_attr(&u, a)) {
        /* server may omit attrs; treat as plain file of unknown size */
        a->ftype = NF3REG; a->mode = 0644; a->size = 0;
        a->fileid = 0; a->mtime = 0;
    }
    return 0;
}

static LONG nfs_read(struct CFile *cf, UBYTE *dst, ULONG want, ULONG *got)
{
    ULONG done = 0;

    while (done < want) {
        struct UB u;
        struct NfsArgs na;
        LONG err;
        ULONG st, chunk = want - done;
        ULONG count, eof, dlen;
        UBYTE *data;

        if (chunk > g_rsize) chunk = g_rsize;
        na.fh = cf->fh; na.fhlen = cf->fhlen;
        na.a = cf->pos + done; na.b = chunk;
        err = nfs_call(NFS3_READ, &na, &u, NULL);
        if (err) { *got = done; return err; }
        st = ub_u32(&u);
        if (st != 0) { *got = done; return nfs3_to_dos(st); }
        {
            struct Attr a;
            ub_postop_attr(&u, &a);
        }
        count = ub_u32(&u);
        eof = ub_u32(&u);
        data = ub_opaque(&u, &dlen);
        if (!data || u.err || dlen < count) { *got = done; return ERROR_SEEK_ERROR; }
        memcpy(dst + done, data, count);
        done += count;
        if (eof || count == 0) break;
    }
    *got = done;
    return 0;
}

/* wcc_data: pre_op (bool + size/times) then post_op_attr; skip both */
static void wcc_data(struct UB *u)
{
    struct Attr a;
    if (ub_u32(u)) ub_skip(u, 8 + 8 + 8);   /* size u64, mtime, ctime */
    ub_postop_attr(u, &a);
}

static LONG nfs_status_op(ULONG proc, struct NfsArgs *na)
{
    struct UB u;
    LONG err = nfs_call(proc, na, &u, NULL);
    ULONG st;
    if (err) return err;
    st = ub_u32(&u);
    return st ? nfs3_to_dos(st) : 0;
}

/* CREATE or MKDIR: both reply post_op_fh3 + attrs; fall back to LOOKUP */
static LONG nfs_make(ULONG proc, const UBYTE *dirfh, ULONG dirfhlen,
                     const char *name, ULONG mode, LONG trunc,
                     UBYTE *outfh, ULONG *outfhlen, struct Attr *a)
{
    struct UB u;
    struct NfsArgs na;
    LONG err;
    ULONG st;

    memset(&na, 0, sizeof(na));
    na.fh = dirfh; na.fhlen = dirfhlen; na.name = name;
    na.set_mode = 1; na.mode = mode;
    if (trunc) { na.set_size = 1; na.size = 0; }
    err = nfs_call(proc, &na, &u, NULL);
    if (err) return err;
    st = ub_u32(&u);
    if (st != 0) return nfs3_to_dos(st);
    {
        UBYTE *fh = NULL;
        ULONG n = 0;
        LONG have_attr;
        if (ub_u32(&u)) fh = ub_opaque(&u, &n);
        have_attr = ub_postop_attr(&u, a);
        if (fh && n && n <= FHSIZE_MAX && !u.err) {
            memcpy(outfh, fh, n);
            *outfhlen = n;
            if (!have_attr) {
                a->ftype = (proc == NFS3_MKDIR) ? NF3DIR : NF3REG;
                a->mode = mode; a->size = 0; a->fileid = 0; a->mtime = 0;
            }
            return 0;
        }
    }
    return nfs_lookup(dirfh, dirfhlen, name, outfh, outfhlen, a, NULL);
}

static LONG nfs_write(struct CFile *cf, ULONG offset,
                      const UBYTE *data, ULONG len, ULONG *written)
{
    ULONG done = 0;

    while (done < len) {
        struct UB u;
        struct NfsArgs na;
        LONG err;
        ULONG st, chunk = len - done, count;

        if (chunk > g_wsize) chunk = g_wsize;
        memset(&na, 0, sizeof(na));
        na.fh = cf->fh; na.fhlen = cf->fhlen;
        na.a = offset + done;
        na.data = data + done; na.dlen = chunk;
        err = nfs_call(NFS3_WRITE, &na, &u, NULL);
        if (err) { *written = done; return err; }
        st = ub_u32(&u);
        if (st != 0) { *written = done; return nfs3_to_dos(st); }
        wcc_data(&u);
        count = ub_u32(&u);
        ub_u32(&u);                    /* committed level */
        if (u.p + 8 <= u.end) {
            if (!cf->verf_valid) {
                memcpy(cf->wverf, u.p, 8);
                cf->verf_valid = 1;
            } else if (c_memcmp(cf->wverf, u.p, 8)) {
                DBG("write verifier changed - server restarted mid-file");
                cf->lost = 1;
            }
        }
        if (u.err || count == 0) { *written = done; return ERROR_SEEK_ERROR; }
        cf->dirty = 1;
        done += count;
    }
    *written = done;
    return 0;
}

/* COMMIT the whole file; verify against the write verifier */
static LONG nfs_commit(struct CFile *cf)
{
    struct UB u;
    struct NfsArgs na;
    LONG err;
    ULONG st;

    if (!cf->dirty) return cf->lost ? ERROR_SEEK_ERROR : 0;
    memset(&na, 0, sizeof(na));
    na.fh = cf->fh; na.fhlen = cf->fhlen;
    err = nfs_call(NFS3_COMMIT, &na, &u, NULL);
    if (err) return err;
    st = ub_u32(&u);
    if (st != 0) return nfs3_to_dos(st);
    wcc_data(&u);
    if (u.p + 8 <= u.end && cf->verf_valid && c_memcmp(u.p, cf->wverf, 8)) {
        DBG("COMMIT verifier mismatch - unstable data lost");
        cf->lost = 1;
    }
    cf->dirty = 0;
    return cf->lost ? ERROR_SEEK_ERROR : 0;
}

static LONG resolve(struct CLock *base, UBYTE *bstr,
                    UBYTE *outfh, ULONG *outfhlen, struct Attr *a,
                    LONG wantparent, char *leaf);

#define PIPE_MAX 8

/* Pipelined UNSTABLE writes: up to DEPTH= WRITE RPCs in flight.
 * Safe by construction: disjoint absolute-offset chunks; replies
 * matched by xid; only the contiguous watermark is ever reported;
 * short writes re-issue their tail in place; a dead transport falls
 * back to the synchronous path from the watermark (NFS writes are
 * idempotent, so replaying a maybe-landed chunk is harmless).
 * DEPTH=1 never enters this function. */
static LONG nfs_write_pipe(struct CFile *cf, ULONG offset,
                           const UBYTE *data, ULONG len, ULONG *written)
{
    struct { ULONG xid, off, len; LONG busy; } sl[PIPE_MAX];
    LONG nbusy = 0, err = 0, dead = 0;
    ULONG next = 0, wm, i, replies = 0;

    err = net_up();
    if (err) { *written = 0; return err; }
    for (i = 0; i < PIPE_MAX; i++) sl[i].busy = 0;

    for (;;) {
        while (!err && !dead && next < len && nbusy < (LONG)g_depth) {
            ULONG chunk = len - next;
            if (chunk > g_wsize) chunk = g_wsize;
            rpc_begin(NFS_PROG, NFS_VERS, NFS3_WRITE);
            pk_opaque(cf->fh, cf->fhlen);
            pk_u64(0, offset + next); pk_u32(chunk); pk_u32(0);
            pk_opaque(data + next, chunk);
            for (i = 0; i < PIPE_MAX && sl[i].busy; i++) ;
            sl[i].xid = g_xid; sl[i].off = next; sl[i].len = chunk;
            sl[i].busy = 1;
            if (rpc_send(g_sock)) { sl[i].busy = 0; dead = 1; break; }
            nbusy++;
            next += chunk;
        }
        if (nbusy == 0) break;

        {
            struct UB u;
            ULONG rxid, st, count;

            if (dead || !rpc_recv(g_sock, &u, &rxid)) { dead = 1; break; }
            replies++;
            if (g_testdrop && replies == g_testdrop) {
                DBG("TESTDROP: simulating transport death");
                g_testdrop = 0;
                dead = 1;
                break;
            }
            for (i = 0; i < PIPE_MAX; i++)
                if (sl[i].busy && sl[i].xid == rxid) break;
            if (i == PIPE_MAX) { dead = 1; break; }   /* unknown xid */

            st = ub_u32(&u);
            if (st != 0) {
                if (!err) err = nfs3_to_dos(st);
                sl[i].busy = 0; nbusy--;
                continue;              /* stop issuing, drain the rest */
            }
            wcc_data(&u);
            count = ub_u32(&u);
            ub_u32(&u);                /* committed level */
            if (u.p + 8 <= u.end) {
                if (!cf->verf_valid) {
                    memcpy(cf->wverf, u.p, 8);
                    cf->verf_valid = 1;
                } else if (c_memcmp(cf->wverf, u.p, 8)) {
                    DBG("write verifier changed - server restarted mid-file");
                    cf->lost = 1;
                }
            }
            if (u.err || count == 0) { dead = 1; break; }
            cf->dirty = 1;
            if (g_testshort && udivmod(replies, g_testshort, NULL) * g_testshort == replies
                && count > 1) {
                count >>= 1;
                DBG2("TESTSHORT: pretending short write of ", count);
            }
            if (count < sl[i].len) {
                ULONG ro = sl[i].off + count, rl = sl[i].len - count;
                rpc_begin(NFS_PROG, NFS_VERS, NFS3_WRITE);
                pk_opaque(cf->fh, cf->fhlen);
                pk_u64(0, offset + ro); pk_u32(rl); pk_u32(0);
                pk_opaque(data + ro, rl);
                sl[i].xid = g_xid; sl[i].off = ro; sl[i].len = rl;
                if (rpc_send(g_sock)) { sl[i].busy = 0; nbusy--; dead = 1; break; }
            } else {
                sl[i].busy = 0; nbusy--;
            }
        }
    }

    /* contiguous watermark: everything below the lowest outstanding */
    wm = next;
    for (i = 0; i < PIPE_MAX; i++)
        if (sl[i].busy && sl[i].off < wm) wm = sl[i].off;

    if (dead) {
        ULONG more = 0;
        LONG e2;
        drop_conn();
        e2 = nfs_write(cf, offset + wm, data + wm, len - wm, &more);
        *written = e2 ? wm + more : len;
        return e2;
    }
    if (err) {
        /* an append-style write may leave acked bytes past the failed
         * chunk; trim so the file ends exactly where we say it does.
         * Never shrink below the pre-write size. */
        if (offset + wm >= cf->size) {
            struct NfsArgs na;
            memset(&na, 0, sizeof(na));
            na.fh = cf->fh; na.fhlen = cf->fhlen;
            na.set_size = 1; na.size = offset + wm;
            nfs_status_op(NFS3_SETATTR, &na);
        }
        *written = wm;
        return err;
    }
    *written = len;
    return 0;
}

/* Pipelined READs: mirror of nfs_write_pipe. Requests are tiny, so
 * depth never trips the lwIP blocked-send hazard; replies stream in
 * and land at their slot's offset in dst. Same guarantees: xid
 * matching, contiguous watermark, short-read tail re-issue, sync
 * fallback from the watermark on transport death. */
static LONG nfs_read_pipe(struct CFile *cf, ULONG offset,
                          UBYTE *dst, ULONG want, ULONG *got)
{
    struct { ULONG xid, off, len; LONG busy; } sl[PIPE_MAX];
    LONG nbusy = 0, err = 0, dead = 0, at_eof = 0;
    ULONG next = 0, wm, i, replies = 0;

    err = net_up();
    if (err) { *got = 0; return err; }
    for (i = 0; i < PIPE_MAX; i++) sl[i].busy = 0;

    /* subdivide the client's request across the pipeline: a 64K Read
     * from an app becomes depth-many smaller chunks in flight instead
     * of one synchronous RPC */
    {
        ULONG csz = udivmod(want, g_depth, NULL);
        if (csz > g_rsize) csz = g_rsize;
        if (csz < 8192) csz = 8192;

    for (;;) {
        while (!err && !dead && !at_eof && next < want && nbusy < (LONG)g_depth) {
            ULONG chunk = want - next;
            if (chunk > csz) chunk = csz;
            rpc_begin(NFS_PROG, NFS_VERS, NFS3_READ);
            pk_opaque(cf->fh, cf->fhlen);
            pk_u64(0, offset + next); pk_u32(chunk);
            for (i = 0; i < PIPE_MAX && sl[i].busy; i++) ;
            sl[i].xid = g_xid; sl[i].off = next; sl[i].len = chunk;
            sl[i].busy = 1;
            if (rpc_send(g_sock)) { sl[i].busy = 0; dead = 1; break; }
            nbusy++;
            next += chunk;
        }
        if (nbusy == 0) break;

        {
            struct UB u;
            struct Attr a;
            ULONG rxid, st, count, eof, dlen;
            UBYTE *data;

            if (dead || !rpc_recv(g_sock, &u, &rxid)) { dead = 1; break; }
            replies++;
            for (i = 0; i < PIPE_MAX; i++)
                if (sl[i].busy && sl[i].xid == rxid) break;
            if (i == PIPE_MAX) { dead = 1; break; }

            st = ub_u32(&u);
            if (st != 0) {
                if (!err) err = nfs3_to_dos(st);
                sl[i].busy = 0; nbusy--;
                continue;
            }
            ub_postop_attr(&u, &a);
            count = ub_u32(&u);
            eof = ub_u32(&u);
            data = ub_opaque(&u, &dlen);
            if (!data || u.err || dlen < count || count > sl[i].len) {
                dead = 1; break;
            }
            if (g_testshort && udivmod(replies, g_testshort, NULL) * g_testshort == replies
                && count > 1 && !eof) {
                count >>= 1;
                DBG2("TESTSHORT: pretending short read of ", count);
            }
            memcpy(dst + sl[i].off, data, count);
            if (count < sl[i].len && !eof) {
                ULONG ro = sl[i].off + count, rl = sl[i].len - count;
                rpc_begin(NFS_PROG, NFS_VERS, NFS3_READ);
                pk_opaque(cf->fh, cf->fhlen);
                pk_u64(0, offset + ro); pk_u32(rl);
                sl[i].xid = g_xid; sl[i].off = ro; sl[i].len = rl;
                if (rpc_send(g_sock)) { sl[i].busy = 0; nbusy--; dead = 1; break; }
            } else {
                if (eof && sl[i].off + count < want) at_eof = 1;
                sl[i].busy = 0; nbusy--;
            }
        }
    }

    wm = next;
    for (i = 0; i < PIPE_MAX; i++)
        if (sl[i].busy && sl[i].off < wm) wm = sl[i].off;

    if (dead) {
        /* transport died: reconnect and finish from the watermark with
         * the synchronous path (absolute offsets, idempotent). nfs_read
         * works relative to cf->pos, so borrow it briefly. */
        ULONG more = 0, save = cf->pos;
        LONG e2;
        drop_conn();
        cf->pos = offset + wm;
        e2 = nfs_read(cf, dst + wm, want - wm, &more);
        cf->pos = save;
        *got = wm + more;
        return e2;
    }
    if (err) { *got = wm; return err; }
    if (at_eof) { *got = wm; return 0; }   /* eof mid-span: contiguous only */
    *got = want;
    return 0;
    }
}

/* resolve to the parent + typed leaf, then find the server-case entry */
static LONG resolve_entry(struct CLock *base, UBYTE *bstr,
                          UBYTE *pfh, ULONG *plen,
                          char *actual, struct Attr *a,
                          UBYTE *ofh, ULONG *olen)
{
    struct Attr pa;
    char leaf[NAME_MAX_AMIGA + 1];
    LONG err;

    err = resolve(base, bstr, pfh, plen, &pa, 1, leaf);
    if (err) return err;
    return nfs_lookup(pfh, *plen, leaf, ofh, olen, a, actual);
}

/* ------------------------------------------------------------------ */
/* AmigaDOS glue                                                      */

#define FIBF_DELETE_BIT 1
#define FIBF_EXECUTE_BIT 4
#define FIBF_WRITE_BIT  2
#define FIBF_READ_BIT   8

static ULONG prot_from_mode(ULONG mode)
{
    ULONG p = 0;                       /* low nibble active-low: 0 = all allowed */
    if (!(mode & 0400)) p |= FIBF_READ_BIT;
    if (!(mode & 0200)) p |= FIBF_WRITE_BIT | FIBF_DELETE_BIT;
    /* x-bit deliberately not mapped: Linux 644 must stay runnable */
    return p;
}

#define AMIGA_EPOCH 252460800UL        /* 1978-01-01 as unix seconds */

static void ds_from_unix(struct DateStamp *ds, ULONG t)
{
    ULONG insec, inday, sec;
    t += g_tzoff;                      /* server time is UTC; show local */
    if (t < AMIGA_EPOCH) t = AMIGA_EPOCH;
    t -= AMIGA_EPOCH;
    ds->ds_Days   = udivmod(t, 86400, &insec);
    ds->ds_Minute = udivmod(insec, 60, &sec);
    (void)inday;
    ds->ds_Tick   = sec * TICKS_PER_SECOND;
}

static void fib_fill(struct FileInfoBlock *fib, const char *name,
                     const struct Attr *a, LONG is_root)
{
    LONG n = c_strlen(name);

    if (n > NAME_MAX_AMIGA) n = NAME_MAX_AMIGA;
    memset(fib, 0, sizeof(*fib));
    fib->fib_DiskKey = a->fileid;
    fib->fib_DirEntryType = is_root ? ST_ROOT
                          : (a->ftype == NF3DIR ? ST_USERDIR : ST_FILE);
    fib->fib_EntryType = fib->fib_DirEntryType;
    fib->fib_FileName[0] = n;
    memcpy(fib->fib_FileName + 1, name, n);
    fib->fib_Protection = prot_from_mode(a->mode);
    fib->fib_Size = a->size;
    fib->fib_NumBlocks = (a->size >> 9) + 1;
    ds_from_unix(&fib->fib_Date, a->mtime);
    fib->fib_Comment[0] = 0;
}

static struct CLock *lock_new(const UBYTE *fh, ULONG fhlen, ULONG ftype, ULONG key)
{
    struct CLock *cl = AllocVec(sizeof(*cl), MEMF_PUBLIC | MEMF_CLEAR);
    if (!cl) return NULL;
    cl->fl.fl_Key = key;
    cl->fl.fl_Access = SHARED_LOCK;
    cl->fl.fl_Task = g_port;
    cl->fl.fl_Volume = MKBADDR(g_volnode);
    memcpy(cl->fh, fh, fhlen);
    cl->fhlen = fhlen;
    cl->ftype = ftype;
    cl->next = g_locks;
    g_locks = cl;
    g_nlocks++;
    return cl;
}

static void lock_free(struct CLock *cl)
{
    struct CLock **pp;
    for (pp = &g_locks; *pp; pp = &(*pp)->next)
        if (*pp == cl) { *pp = cl->next; break; }
    free_dircache(cl);
    FreeVec(cl);
    g_nlocks--;
}

/* lock BPTR from a packet arg; NULL/0 means the root */
static struct CLock *lock_of(BPTR b) { return b ? (struct CLock *)BADDR(b) : NULL; }

static void lock_fh(struct CLock *cl, const UBYTE **fh, ULONG *fhlen, ULONG *ftype)
{
    if (cl) { *fh = cl->fh; *fhlen = cl->fhlen; *ftype = cl->ftype; }
    else    { *fh = g_rootfh; *fhlen = g_rootfhlen; *ftype = NF3DIR; }
}

/*
 * Resolve an AmigaDOS path (BSTR) relative to a lock. Handles the
 * "DEVICE:" prefix (absolute -> root), '/' separators, and leading or
 * doubled '/' as parent (via NFS LOOKUP of ".."). Fills fh/attr of the
 * final object; if wantparent, stops one short and returns the last
 * component in leaf[] instead (for LOOKUP of things we may later create).
 */
static LONG resolve(struct CLock *base, UBYTE *bstr,
                    UBYTE *outfh, ULONG *outfhlen, struct Attr *a,
                    LONG wantparent, char *leaf /* may be NULL */)
{
    char path[256];
    LONG len = bstr[0], i, o = 0;
    const UBYTE *fh; ULONG fhlen, ftype;
    char comp[NAME_MAX_AMIGA + 1];
    LONG cl2, err, from_root = 0;
    UBYTE curfh[FHSIZE_MAX]; ULONG curlen;
    struct Attr cura;

    for (i = 0; i < len && o < 255; i++) path[o++] = bstr[1 + i];
    path[o] = 0;

    /* device prefix: everything before ':' names us; discard */
    for (i = 0; path[i]; i++)
        if (path[i] == ':') { from_root = 1; o = i + 1; break; }
    if (!from_root) o = 0;

    if (from_root || !base) { fh = g_rootfh; fhlen = g_rootfhlen; ftype = NF3DIR; }
    else lock_fh(base, &fh, &fhlen, &ftype);

    memcpy(curfh, fh, fhlen); curlen = fhlen;
    cura.ftype = ftype; cura.mode = 0755; cura.size = 0;
    cura.fileid = 0; cura.mtime = 0;

    i = o; cl2 = 0;
    for (;;) {
        if (path[i] == '/' || path[i] == 0) {
            comp[cl2] = 0;
            if (cl2 == 0 && path[i] == '/') {
                /* empty component = go to parent */
                if (curlen == g_rootfhlen &&
                    !c_memcmp(curfh, g_rootfh, curlen)) {
                    /* parent of root: stay (matches RAM: behaviour) */
                } else {
                    UBYTE nfh[FHSIZE_MAX]; ULONG nlen; struct Attr na2;
                    err = nfs_lookup(curfh, curlen, "..", nfh, &nlen, &na2, NULL);
                    if (err) return err;
                    memcpy(curfh, nfh, nlen); curlen = nlen; cura = na2;
                }
            } else if (cl2 > 0) {
                LONG is_last = (path[i] == 0);
                UBYTE nfh[FHSIZE_MAX]; ULONG nlen; struct Attr na2;
                if (is_last && wantparent) {
                    LONG k;
                    for (k = 0; k <= cl2; k++) leaf[k] = comp[k];
                    memcpy(outfh, curfh, curlen); *outfhlen = curlen; *a = cura;
                    return 0;
                }
                if (cura.ftype != NF3DIR) return ERROR_DIR_NOT_FOUND;
                err = nfs_lookup(curfh, curlen, comp, nfh, &nlen, &na2, NULL);
                if (err) return err;
                memcpy(curfh, nfh, nlen); curlen = nlen; cura = na2;
            }
            cl2 = 0;
            if (path[i] == 0) break;
        } else {
            if (cl2 >= NAME_MAX_AMIGA) return ERROR_INVALID_COMPONENT_NAME;
            comp[cl2++] = path[i];
        }
        i++;
    }

    if (wantparent) {
        /* path had no leaf ("" or "dev:"): no component to name */
        return ERROR_INVALID_COMPONENT_NAME;
    }
    memcpy(outfh, curfh, curlen); *outfhlen = curlen; *a = cura;
    return 0;
}

/* the leaf name of a BSTR path, for EXAMINE's fib_FileName */
static void leafname(UBYTE *bstr, char *out)
{
    LONG len = bstr[0], i, start = 0, o = 0;
    for (i = 0; i < len; i++)
        if (bstr[1 + i] == ':' || bstr[1 + i] == '/') start = i + 1;
    for (i = start; i < len && o < NAME_MAX_AMIGA; i++) out[o++] = bstr[1 + i];
    out[o] = 0;
}

/* ------------------------------------------------------------------ */
/* packet actions                                                     */

static void act_locate(struct DosPacket *pkt)
{
    struct CLock *base = lock_of(pkt->dp_Arg1);
    UBYTE fh[FHSIZE_MAX]; ULONG fhlen; struct Attr a;
    LONG err = net_up();

    if (!err)
        err = resolve(base, BADDR(pkt->dp_Arg2), fh, &fhlen, &a, 0, NULL);
    if (err) { pkt->dp_Res1 = 0; pkt->dp_Res2 = err; return; }
    {
        struct CLock *cl = lock_new(fh, fhlen, a.ftype, a.fileid);
        if (!cl) { pkt->dp_Res1 = 0; pkt->dp_Res2 = ERROR_NO_FREE_STORE; return; }
        leafname(BADDR(pkt->dp_Arg2), cl->name);
        pkt->dp_Res1 = MKBADDR(&cl->fl);
        pkt->dp_Res2 = 0;
    }
}

static void act_free_lock(struct DosPacket *pkt)
{
    struct CLock *cl = lock_of(pkt->dp_Arg1);
    if (cl) lock_free(cl);
    pkt->dp_Res1 = DOSTRUE;
}

static void act_copy_dir(struct DosPacket *pkt)
{
    struct CLock *cl = lock_of(pkt->dp_Arg1);
    const UBYTE *fh; ULONG fhlen, ftype;
    struct CLock *nc;

    lock_fh(cl, &fh, &fhlen, &ftype);
    nc = lock_new(fh, fhlen, ftype, cl ? cl->fl.fl_Key : 0);
    if (!nc) { pkt->dp_Res1 = 0; pkt->dp_Res2 = ERROR_NO_FREE_STORE; return; }
    if (cl) memcpy(nc->name, cl->name, sizeof(nc->name));
    pkt->dp_Res1 = MKBADDR(&nc->fl);
    pkt->dp_Res2 = 0;
}

static void act_parent(struct DosPacket *pkt)
{
    struct CLock *cl = lock_of(pkt->dp_Arg1);
    UBYTE nfh[FHSIZE_MAX]; ULONG nlen; struct Attr a;
    LONG err;

    if (!cl || (cl->fhlen == g_rootfhlen &&
                !c_memcmp(cl->fh, g_rootfh, cl->fhlen))) {
        pkt->dp_Res1 = 0; pkt->dp_Res2 = 0;   /* root has no parent */
        return;
    }
    err = net_up();
    if (!err) {
        const UBYTE *fh; ULONG fhlen, ftype;
        lock_fh(cl, &fh, &fhlen, &ftype);
        if (ftype == NF3DIR) {
            err = nfs_lookup(fh, fhlen, "..", nfh, &nlen, &a, NULL);
        } else {
            /* parent of a file lock: we can't LOOKUP ".." on a file.
             * b1 punts to the root; fine for List/Type usage patterns. */
            memcpy(nfh, g_rootfh, g_rootfhlen); nlen = g_rootfhlen;
            a.ftype = NF3DIR; a.fileid = 0;
            err = 0;
        }
    }
    if (err) { pkt->dp_Res1 = 0; pkt->dp_Res2 = err; return; }
    {
        struct CLock *nc = lock_new(nfh, nlen, NF3DIR, a.fileid);
        if (!nc) { pkt->dp_Res1 = 0; pkt->dp_Res2 = ERROR_NO_FREE_STORE; return; }
        pkt->dp_Res1 = MKBADDR(&nc->fl);
        pkt->dp_Res2 = 0;
    }
}

static void act_examine(struct DosPacket *pkt)
{
    struct CLock *cl = lock_of(pkt->dp_Arg1);
    struct FileInfoBlock *fib = BADDR(pkt->dp_Arg2);
    struct Attr a;
    const UBYTE *fh;
    ULONG fhlen, ftype;
    LONG err, is_root;

    err = net_up();
    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
    lock_fh(cl, &fh, &fhlen, &ftype);
    is_root = (fhlen == g_rootfhlen && !c_memcmp(fh, g_rootfh, fhlen));
    err = nfs_getattr(fh, fhlen, &a);
    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
    fib_fill(fib, is_root ? g_volname
                          : (cl && cl->name[0] ? cl->name : "?"), &a, is_root);
    fib->fib_DiskKey = 0;              /* EXAMINE_NEXT starts at index 0 */
    pkt->dp_Res1 = DOSTRUE;
    pkt->dp_Res2 = 0;
}

static void act_examine_next(struct DosPacket *pkt)
{
    struct CLock *cl = lock_of(pkt->dp_Arg1);
    struct FileInfoBlock *fib = BADDR(pkt->dp_Arg2);
    LONG idx = fib->fib_DiskKey;
    LONG err;

    err = net_up();
    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }

    if (!cl) {
        /* EXNEXT with a zero lock: treat as root; give it a real lock-
         * less snapshot via a temporary walk. DOS always passes a lock
         * in practice; keep it simple. */
        pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = ERROR_NO_MORE_ENTRIES;
        return;
    }

    if (!cl->dc) {
        const UBYTE *fh; ULONG fhlen, ftype;
        lock_fh(cl, &fh, &fhlen, &ftype);
        if (ftype != NF3DIR) {
            pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = ERROR_OBJECT_WRONG_TYPE;
            return;
        }
        err = nfs_readdir(fh, fhlen, &cl->dc, &cl->dctotal);
        if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
        DBG2("dir snapshot entries: ", cl->dctotal);
    }

    if (idx >= cl->dctotal) {
        free_dircache(cl);
        pkt->dp_Res1 = DOSFALSE;
        pkt->dp_Res2 = ERROR_NO_MORE_ENTRIES;
        return;
    }
    {
        struct DirChunk *c = cl->dc;
        LONG skip = idx;
        struct Attr a;
        while (skip >= c->used) { skip -= c->used; c = c->next; }
        {
            struct DirEnt *e = &c->e[skip];
            a.ftype = e->ftype; a.mode = e->mode; a.size = e->size;
            a.fileid = e->fileid; a.mtime = e->mtime;
            fib_fill(fib, e->name, &a, 0);
        }
        fib->fib_DiskKey = idx + 1;
        pkt->dp_Res1 = DOSTRUE;
        pkt->dp_Res2 = 0;
    }
}

static void open_tail(struct DosPacket *pkt, struct FileHandle *fhandle,
                      const UBYTE *fh, ULONG fhlen, ULONG size, UBYTE *namebstr)
{
    struct CFile *cf = AllocVec(sizeof(*cf), MEMF_PUBLIC | MEMF_CLEAR);
    if (!cf) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = ERROR_NO_FREE_STORE; return; }
    memcpy(cf->fh, fh, fhlen);
    cf->fhlen = fhlen;
    cf->size = size;
    leafname(namebstr, cf->name);
    cf->next = g_files;
    g_files = cf;
    g_nfiles++;
    fhandle->fh_Arg1 = (LONG)cf;
    fhandle->fh_Type = g_port;
    pkt->dp_Res1 = DOSTRUE;
    pkt->dp_Res2 = 0;
}

static void act_findinput(struct DosPacket *pkt)
{
    struct FileHandle *fhandle = BADDR(pkt->dp_Arg1);
    struct CLock *base = lock_of(pkt->dp_Arg2);
    UBYTE fh[FHSIZE_MAX]; ULONG fhlen; struct Attr a;
    LONG err = net_up();

    if (!err)
        err = resolve(base, BADDR(pkt->dp_Arg3), fh, &fhlen, &a, 0, NULL);
    if (!err && a.ftype == NF3DIR) err = ERROR_OBJECT_WRONG_TYPE;
    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
    open_tail(pkt, fhandle, fh, fhlen, a.size, BADDR(pkt->dp_Arg3));
}

/* FINDOUTPUT = MODE_NEWFILE: create-or-truncate */
static void act_findoutput(struct DosPacket *pkt)
{
    struct FileHandle *fhandle = BADDR(pkt->dp_Arg1);
    struct CLock *base = lock_of(pkt->dp_Arg2);
    UBYTE pfh[FHSIZE_MAX]; ULONG plen; struct Attr pa, a;
    UBYTE fh[FHSIZE_MAX]; ULONG fhlen;
    char leaf[NAME_MAX_AMIGA + 1];
    LONG err = net_up();

    if (!err)
        err = resolve(base, BADDR(pkt->dp_Arg3), pfh, &plen, &pa, 1, leaf);
    if (!err)
        err = nfs_make(NFS3_CREATE, pfh, plen, leaf, 0644, 1, fh, &fhlen, &a);
    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
    open_tail(pkt, fhandle, fh, fhlen, 0, BADDR(pkt->dp_Arg3));
}

/* FINDUPDATE = MODE_READWRITE: open existing, create if absent */
static void act_findupdate(struct DosPacket *pkt)
{
    struct FileHandle *fhandle = BADDR(pkt->dp_Arg1);
    struct CLock *base = lock_of(pkt->dp_Arg2);
    UBYTE pfh[FHSIZE_MAX]; ULONG plen; struct Attr pa, a;
    UBYTE fh[FHSIZE_MAX]; ULONG fhlen;
    char leaf[NAME_MAX_AMIGA + 1];
    LONG err = net_up();

    if (!err)
        err = resolve(base, BADDR(pkt->dp_Arg3), pfh, &plen, &pa, 1, leaf);
    if (!err) {
        err = nfs_lookup(pfh, plen, leaf, fh, &fhlen, &a, NULL);
        if (err == ERROR_OBJECT_NOT_FOUND)
            err = nfs_make(NFS3_CREATE, pfh, plen, leaf, 0644, 0, fh, &fhlen, &a);
        else if (!err && a.ftype == NF3DIR)
            err = ERROR_OBJECT_WRONG_TYPE;
    }
    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
    open_tail(pkt, fhandle, fh, fhlen, a.size, BADDR(pkt->dp_Arg3));
}

static void act_end(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    struct CFile **pp;
    LONG err = nfs_commit(cf);
    for (pp = &g_files; *pp; pp = &(*pp)->next)
        if (*pp == cf) { *pp = cf->next; FreeVec(cf); g_nfiles--; break; }
    pkt->dp_Res1 = err ? DOSFALSE : DOSTRUE;
    pkt->dp_Res2 = err;
}

static void act_read(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    UBYTE *dst = (UBYTE *)pkt->dp_Arg2;
    ULONG want = pkt->dp_Arg3;
    ULONG got = 0;
    LONG err;

    if (cf->pos >= cf->size) { pkt->dp_Res1 = 0; pkt->dp_Res2 = 0; return; }
    if (want > cf->size - cf->pos) want = cf->size - cf->pos;
    err = (g_depth > 1 && want >= 32768)
        ? nfs_read_pipe(cf, cf->pos, dst, want, &got)
        : nfs_read(cf, dst, want, &got);
    if (err && got == 0) { pkt->dp_Res1 = -1; pkt->dp_Res2 = err; return; }
    cf->pos += got;
    pkt->dp_Res1 = got;
    pkt->dp_Res2 = 0;
}

static void act_seek(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    LONG off = pkt->dp_Arg2, mode = pkt->dp_Arg3;
    LONG base = (mode == OFFSET_BEGINNING) ? 0
              : (mode == OFFSET_END) ? (LONG)cf->size : (LONG)cf->pos;
    LONG npos = base + off;

    if (npos < 0 || (ULONG)npos > cf->size) {
        pkt->dp_Res1 = -1; pkt->dp_Res2 = ERROR_SEEK_ERROR; return;
    }
    pkt->dp_Res1 = cf->pos;
    cf->pos = npos;
    pkt->dp_Res2 = 0;
}

static void act_info(struct DosPacket *pkt, BPTR infobptr)
{
    struct InfoData *id = BADDR(infobptr);
    ULONG tblocks = 1000000, ublocks = 0;

    memset(id, 0, sizeof(*id));
    if (net_up() == 0) {
        struct UB u;
        struct NfsArgs na;
        na.fh = g_rootfh; na.fhlen = g_rootfhlen;
        if (nfs_call(NFS3_FSSTAT, &na, &u, NULL) == 0 && ub_u32(&u) == 0) {
            struct Attr a;
            ULONG thi, tlo, fhi, flo;
            ub_postop_attr(&u, &a);
            thi = ub_u32(&u); tlo = ub_u32(&u);   /* tbytes */
            fhi = ub_u32(&u); flo = ub_u32(&u);   /* fbytes */
            /* bytes -> 512-byte blocks, shifted across the word split;
             * a >=1TB export overflows LONG id_NumBlocks, so clamp */
            if (thi & 0xFFFFFF80) tblocks = 0x7FFFFFFF;
            else tblocks = (thi << 23) | (tlo >> 9);
            if ((thi | fhi) & 0xFFFFFF80) ublocks = 0;
            else ublocks = tblocks - ((fhi << 23) | (flo >> 9));
            if ((LONG)ublocks < 0) ublocks = 0;
        }
    }
    id->id_DiskState = ID_VALIDATED;
    id->id_NumBlocks = tblocks;
    id->id_NumBlocksUsed = ublocks;
    id->id_BytesPerBlock = 512;
    id->id_DiskType = ID_DOS_DISK;
    id->id_VolumeNode = MKBADDR(g_volnode);
    id->id_InUse = g_nfiles ? DOSTRUE : DOSFALSE;
    pkt->dp_Res1 = DOSTRUE;
    pkt->dp_Res2 = 0;
}

static void act_same_lock(struct DosPacket *pkt)
{
    struct CLock *a = lock_of(pkt->dp_Arg1);
    struct CLock *b = lock_of(pkt->dp_Arg2);
    const UBYTE *fa, *fb; ULONG la, lb, t;

    lock_fh(a, &fa, &la, &t);
    lock_fh(b, &fb, &lb, &t);
    pkt->dp_Res1 = (la == lb && !c_memcmp(fa, fb, la))
                 ? DOSTRUE : DOSFALSE;
    pkt->dp_Res2 = 0;
}

static void act_write(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    const UBYTE *src = (const UBYTE *)pkt->dp_Arg2;
    ULONG want = pkt->dp_Arg3, done = 0;
    LONG err;

    err = (g_depth > 1 && want > g_wsize)
        ? nfs_write_pipe(cf, cf->pos, src, want, &done)
        : nfs_write(cf, cf->pos, src, want, &done);
    cf->pos += done;
    if (cf->pos > cf->size) cf->size = cf->pos;
    if (err && done == 0) { pkt->dp_Res1 = -1; pkt->dp_Res2 = err; return; }
    pkt->dp_Res1 = done;
    pkt->dp_Res2 = 0;
}

static void act_delete(struct DosPacket *pkt)
{
    struct CLock *base = lock_of(pkt->dp_Arg1);
    UBYTE pfh[FHSIZE_MAX]; ULONG plen;
    UBYTE ofh[FHSIZE_MAX]; ULONG olen;
    char actual[NAME_MAX_AMIGA + 1];
    struct Attr a;
    struct NfsArgs na;
    LONG err = net_up();

    if (!err)
        err = resolve_entry(base, BADDR(pkt->dp_Arg2), pfh, &plen,
                            actual, &a, ofh, &olen);
    if (!err) {
        memset(&na, 0, sizeof(na));
        na.fh = pfh; na.fhlen = plen; na.name = actual;
        err = nfs_status_op(a.ftype == NF3DIR ? NFS3_RMDIR : NFS3_REMOVE, &na);
    }
    pkt->dp_Res1 = err ? DOSFALSE : DOSTRUE;
    pkt->dp_Res2 = err;
}

static void act_rename(struct DosPacket *pkt)
{
    struct CLock *sbase = lock_of(pkt->dp_Arg1);
    struct CLock *dbase = lock_of(pkt->dp_Arg3);
    UBYTE spfh[FHSIZE_MAX], dpfh[FHSIZE_MAX], ofh[FHSIZE_MAX];
    ULONG splen, dplen, olen;
    char actual[NAME_MAX_AMIGA + 1], dleaf[NAME_MAX_AMIGA + 1];
    struct Attr a, dpa;
    struct NfsArgs na;
    LONG err = net_up();

    if (!err)
        err = resolve_entry(sbase, BADDR(pkt->dp_Arg2), spfh, &splen,
                            actual, &a, ofh, &olen);
    if (!err)
        err = resolve(dbase, BADDR(pkt->dp_Arg4), dpfh, &dplen, &dpa, 1, dleaf);
    if (!err) {
        memset(&na, 0, sizeof(na));
        na.fh = spfh; na.fhlen = splen; na.name = actual;
        na.fh2 = dpfh; na.fh2len = dplen; na.name2 = dleaf;
        err = nfs_status_op(NFS3_RENAME, &na);
    }
    pkt->dp_Res1 = err ? DOSFALSE : DOSTRUE;
    pkt->dp_Res2 = err;
}

static void act_create_dir(struct DosPacket *pkt)
{
    struct CLock *base = lock_of(pkt->dp_Arg1);
    UBYTE pfh[FHSIZE_MAX], fh[FHSIZE_MAX];
    ULONG plen, fhlen;
    char leaf[NAME_MAX_AMIGA + 1];
    struct Attr pa, a;
    LONG err = net_up();

    if (!err)
        err = resolve(base, BADDR(pkt->dp_Arg2), pfh, &plen, &pa, 1, leaf);
    if (!err)
        err = nfs_make(NFS3_MKDIR, pfh, plen, leaf, 0755, 0, fh, &fhlen, &a);
    if (err) { pkt->dp_Res1 = 0; pkt->dp_Res2 = err; return; }
    {
        struct CLock *cl = lock_new(fh, fhlen, NF3DIR, a.fileid);
        if (!cl) { pkt->dp_Res1 = 0; pkt->dp_Res2 = ERROR_NO_FREE_STORE; return; }
        leafname(BADDR(pkt->dp_Arg2), cl->name);
        pkt->dp_Res1 = MKBADDR(&cl->fl);
        pkt->dp_Res2 = 0;
    }
}

/* SET_PROTECT / SET_DATE share the resolve-then-SETATTR shape */
static void act_setattr_path(struct DosPacket *pkt, struct NfsArgs *na)
{
    struct CLock *base = lock_of(pkt->dp_Arg2);
    UBYTE fh[FHSIZE_MAX]; ULONG fhlen;
    struct Attr a;
    LONG err = net_up();

    if (!err)
        err = resolve(base, BADDR(pkt->dp_Arg3), fh, &fhlen, &a, 0, NULL);
    if (!err) {
        /* a directory without x is untraversable on the Linux side -
         * mirror r into x for dirs (files stay x-less by design) */
        if (na->set_mode && a.ftype == NF3DIR)
            na->mode |= (na->mode & 0444) >> 2;
        na->fh = fh; na->fhlen = fhlen;
        err = nfs_status_op(NFS3_SETATTR, na);
    }
    pkt->dp_Res1 = err ? DOSFALSE : DOSTRUE;
    pkt->dp_Res2 = err;
}

static void act_set_protect(struct DosPacket *pkt)
{
    ULONG mask = pkt->dp_Arg4, mode = 0;
    struct NfsArgs na;

    if (!(mask & FIBF_READ_BIT)) mode |= 0444;
    if (!(mask & (FIBF_WRITE_BIT | FIBF_DELETE_BIT))) mode |= 0200;
    memset(&na, 0, sizeof(na));
    na.set_mode = 1; na.mode = mode;
    act_setattr_path(pkt, &na);
}

static void act_set_date(struct DosPacket *pkt)
{
    struct DateStamp *ds = (struct DateStamp *)pkt->dp_Arg4;
    struct NfsArgs na;

    memset(&na, 0, sizeof(na));
    na.set_mtime = 1;
    na.mtime = AMIGA_EPOCH + ds->ds_Days * 86400
             + ds->ds_Minute * 60 + udivmod(ds->ds_Tick, TICKS_PER_SECOND, NULL)
             - g_tzoff;                /* DateStamps are local; NFS is UTC */
    act_setattr_path(pkt, &na);
}

static void act_set_file_size(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    LONG off = pkt->dp_Arg2, mode = pkt->dp_Arg3;
    LONG base = (mode == OFFSET_BEGINNING) ? 0
              : (mode == OFFSET_END) ? (LONG)cf->size : (LONG)cf->pos;
    LONG nsize = base + off;
    struct NfsArgs na;
    LONG err;

    if (nsize < 0) { pkt->dp_Res1 = -1; pkt->dp_Res2 = ERROR_SEEK_ERROR; return; }
    memset(&na, 0, sizeof(na));
    na.fh = cf->fh; na.fhlen = cf->fhlen;
    na.set_size = 1; na.size = nsize;
    err = nfs_status_op(NFS3_SETATTR, &na);
    if (err) { pkt->dp_Res1 = -1; pkt->dp_Res2 = err; return; }
    cf->size = nsize;
    if (cf->pos > cf->size) cf->pos = cf->size;
    pkt->dp_Res1 = nsize;
    pkt->dp_Res2 = 0;
}

static void act_examine_fh(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    struct FileInfoBlock *fib = BADDR(pkt->dp_Arg2);
    struct Attr a;
    LONG err = nfs_getattr(cf->fh, cf->fhlen, &a);

    if (err) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = err; return; }
    fib_fill(fib, cf->name[0] ? cf->name : "?", &a, 0);
    pkt->dp_Res1 = DOSTRUE;
    pkt->dp_Res2 = 0;
}

static void act_die(struct DosPacket *pkt)
{
    if (g_nlocks || g_nfiles) {
        pkt->dp_Res1 = DOSFALSE;
        pkt->dp_Res2 = ERROR_OBJECT_IN_USE;
        return;
    }
    DBG("ACTION_DIE: shutting down");
    g_devnode->dn_Task = NULL;         /* next open gets a fresh mount */
    /* Drop the cached seglist too: DOS would happily re-run THIS code
     * forever, making handler upgrades need a reboot. Cleared, the next
     * access reloads L:nfs-handler from disk. The running seglist leaks
     * (~25KB, we are executing it and cannot UnLoadSeg ourselves) -
     * the price of a reboot-free upgrade path, reclaimed at reboot. */
    g_devnode->dn_SegList = 0;
    g_dying = 1;
    pkt->dp_Res1 = DOSTRUE;
    pkt->dp_Res2 = 0;
}

/* ------------------------------------------------------------------ */
/* startup + main loop                                                */

static void parse_startup(void)
{
    UBYTE *b = BADDR(g_devnode->dn_Startup);
    LONG len, i, o = 0, colon = -1;

    g_host[0] = 0; g_export[0] = 0;
    /* volume name default; overwritten below from the export's leaf */
    g_volname[0] = 'N'; g_volname[1] = 'F'; g_volname[2] = 'S';
    g_volname[3] = 0;

    if (!b || (LONG)g_devnode->dn_Startup < 1024) {
        DBG2("startup: small-int or null, raw ", (ULONG)g_devnode->dn_Startup);
        return;
    }
    len = b[0];
    kput("AmiNFSv3: startup len "); kputu(len); kput(" ");
    for (i = 0; i < len && i < 80; i++) kputc(b[1 + i] >= 32 ? b[1 + i] : '?');
    kputc('\n');

    {   /* Mount delivers the Startup value quotes and all; shed them */
        LONG s = 1, e = len;               /* b[s..e) are the chars */
        while (s < e && (b[s] == '"' || b[s] == ' ')) s++;
        while (e > s && (b[e - 1] == '"' || b[e - 1] == ' ')) e--;

        for (i = s; i < e; i++)
            if (b[i] == ':') { colon = i; break; }
        if (colon <= s) return;

        for (i = s; i < colon && o < 63; i++) g_host[o++] = b[i];
        g_host[o] = 0;
        o = 0;
        for (i = colon + 1; i < e && o < 191 && b[i] != ' '; i++)
            g_export[o++] = b[i];
        g_export[o] = 0;

        /* remaining space-separated tokens are options */
        while (i < e) {
            char tok[64];
            LONG t = 0;
            while (i < e && b[i] == ' ') i++;
            while (i < e && b[i] != ' ' && t < 63) tok[t++] = b[i++];
            tok[t] = 0;
            if (t > 7 && !c_memcmp(tok, "VOLUME=", 7)) {
                LONG k;
                for (k = 0; tok[7 + k] && k < 31; k++) g_volname[k] = tok[7 + k];
                g_volname[k] = 0;
                g_volset = 1;
            } else if (t > 4 && !c_memcmp(tok, "UID=", 4)) {
                ULONG v = 0; LONG k;
                for (k = 4; tok[k] >= '0' && tok[k] <= '9'; k++)
                    v = v * 10 + (tok[k] - '0');
                g_uid = v;
            } else if (t > 4 && !c_memcmp(tok, "GID=", 4)) {
                ULONG v = 0; LONG k;
                for (k = 4; tok[k] >= '0' && tok[k] <= '9'; k++)
                    v = v * 10 + (tok[k] - '0');
                g_gid = v;
            } else if (t > 6 && !c_memcmp(tok, "RSIZE=", 6)) {
                ULONG v = 0; LONG k;
                for (k = 6; tok[k] >= '0' && tok[k] <= '9'; k++)
                    v = v * 10 + (tok[k] - '0');
                if (v < XFER_MIN) v = XFER_MIN;
                if (v > XFER_MAX) v = XFER_MAX;
                g_rsize = v;
            } else if (t > 6 && !c_memcmp(tok, "WSIZE=", 6)) {
                ULONG v = 0; LONG k;
                for (k = 6; tok[k] >= '0' && tok[k] <= '9'; k++)
                    v = v * 10 + (tok[k] - '0');
                if (v < XFER_MIN) v = XFER_MIN;
                if (v > XFER_MAX) v = XFER_MAX;
                g_wsize = v;
            } else if (t > 6 && !c_memcmp(tok, "DEPTH=", 6)) {
                ULONG v = tok[6] - '0';
                if (v >= 1 && v <= 8) g_depth = v;
            } else if (t > 10 && !c_memcmp(tok, "TESTSHORT=", 10)) {
                g_testshort = tok[10] - '0';
            } else if (t > 9 && !c_memcmp(tok, "TESTDROP=", 9)) {
                g_testdrop = tok[9] - '0';
            } else if (t > 3 && !c_memcmp(tok, "TZ=", 3)) {
                LONG k = 3, neg = 0, h = 0, m = 0;
                if (tok[k] == '-') { neg = 1; k++; }
                else if (tok[k] == '+') k++;
                for (; tok[k] >= '0' && tok[k] <= '9'; k++)
                    h = h * 10 + (tok[k] - '0');
                if (tok[k] == ':')
                    for (k++; tok[k] >= '0' && tok[k] <= '9'; k++)
                        m = m * 10 + (tok[k] - '0');
                g_tzoff = (h * 3600 + m * 60) * (neg ? -1 : 1);
            } else if (t) {
                kput("AmiNFSv3: unknown option "); kput(tok); kputc('\n');
            }
        }
    }

    kput("AmiNFSv3: host '"); kput(g_host); kput("' export '"); kput(g_export);
    kput("'\n");

    /* volume name = last path component of the export, unless VOLUME= */
    if (!g_volset) {
        LONG start = 0;
        for (i = 0; g_export[i]; i++)
            if (g_export[i] == '/' && g_export[i + 1]) start = i + 1;
        o = 0;
        for (i = start; g_export[i] && g_export[i] != '/' && o < 31; i++)
            g_volname[o++] = g_export[i];
        if (o) g_volname[o] = 0;
    }
}

LONG handler_main(void)
{
    struct Process *me;
    struct DosPacket *pkt;
    struct Message *msg;

    SysBase = *(struct ExecBase **)4;
    DOSBase = (struct DosLibrary *)OpenLibrary("dos.library", 37);
    if (!DOSBase) return RETURN_FAIL;

    /* dn_SegList is reused on re-mount: every global must be set here */
    SocketBase = NULL;
    g_volnode = NULL; g_locks = NULL; g_files = NULL;
    g_nlocks = g_nfiles = 0; g_dying = 0;
    g_sock = -1; g_have_root = 0; g_rootfhlen = 0; g_xid = 100;
    g_uid = 1000; g_gid = 1000; g_volset = 0; g_tzoff = 0;
    g_rsize = RSIZE_DEFAULT; g_wsize = WSIZE_DEFAULT;
    g_depth = 1; g_testshort = 0; g_testdrop = 0;
    g_req = g_rep = NULL;

    me = (struct Process *)FindTask(NULL);
    g_port = &me->pr_MsgPort;
    me->pr_WindowPtr = (APTR)-1;       /* no requesters from this process */

    WaitPort(g_port);
    msg = GetMsg(g_port);
    pkt = (struct DosPacket *)msg->mn_Node.ln_Name;
    g_devnode = BADDR(pkt->dp_Arg3);

    parse_startup();

    g_reqbufsz = g_wsize + REQBUF_EXTRA;
    g_repbufsz = g_rsize + REPBUF_EXTRA;
    g_req = AllocVec(g_reqbufsz, MEMF_PUBLIC);
    g_rep = AllocVec(g_repbufsz, MEMF_PUBLIC);
    if (!g_req || !g_rep) {
        if (g_req) FreeVec(g_req);
        if (g_rep) FreeVec(g_rep);
        ReplyPkt(pkt, DOSFALSE, ERROR_NO_FREE_STORE);
        CloseLibrary((struct Library *)DOSBase);
        return RETURN_FAIL;
    }

    /* volume node: makes locks legit and puts a disk on the Workbench */
    g_volnode = MakeDosEntry(g_volname, DLT_VOLUME);
    if (g_volnode) {
        g_volnode->dol_Task = g_port;
        g_volnode->dol_misc.dol_volume.dol_DiskType = ID_DOS_DISK;
        DateStamp(&g_volnode->dol_misc.dol_volume.dol_VolumeDate);
        AddDosEntry(g_volnode);
    }

    g_devnode->dn_Task = g_port;
    ReplyPkt(pkt, DOSTRUE, 0);
    DBG("mounted, waiting for packets");

    while (!g_dying) {
        WaitPort(g_port);
        while ((msg = GetMsg(g_port))) {
            pkt = (struct DosPacket *)msg->mn_Node.ln_Name;
            pkt->dp_Res2 = 0;

            switch (pkt->dp_Type) {
            case ACTION_LOCATE_OBJECT:  act_locate(pkt); break;
            case ACTION_FREE_LOCK:      act_free_lock(pkt); break;
            case ACTION_COPY_DIR:       act_copy_dir(pkt); break;
            case ACTION_PARENT:         act_parent(pkt); break;
            case ACTION_EXAMINE_OBJECT: act_examine(pkt); break;
            case ACTION_EXAMINE_NEXT:   act_examine_next(pkt); break;
            case ACTION_FINDINPUT:      act_findinput(pkt); break;
            case ACTION_FINDOUTPUT:     act_findoutput(pkt); break;
            case ACTION_FINDUPDATE:     act_findupdate(pkt); break;
            case ACTION_WRITE:          act_write(pkt); break;
            case ACTION_DELETE_OBJECT:  act_delete(pkt); break;
            case ACTION_RENAME_OBJECT:  act_rename(pkt); break;
            case ACTION_CREATE_DIR:     act_create_dir(pkt); break;
            case ACTION_SET_PROTECT:    act_set_protect(pkt); break;
            case ACTION_SET_DATE:       act_set_date(pkt); break;
            case ACTION_SET_FILE_SIZE:  act_set_file_size(pkt); break;
            case ACTION_EXAMINE_FH:     act_examine_fh(pkt); break;
            case ACTION_END:            act_end(pkt); break;
            case ACTION_READ:           act_read(pkt); break;
            case ACTION_SEEK:           act_seek(pkt); break;
            case ACTION_DISK_INFO:      act_info(pkt, pkt->dp_Arg1); break;
            case ACTION_INFO:           act_info(pkt, pkt->dp_Arg2); break;
            case ACTION_SAME_LOCK:      act_same_lock(pkt); break;
            case ACTION_IS_FILESYSTEM:  pkt->dp_Res1 = DOSTRUE; break;
            case ACTION_FLUSH: {
                struct CFile *cf;
                pkt->dp_Res1 = DOSTRUE;
                for (cf = g_files; cf; cf = cf->next)
                    if (nfs_commit(cf)) {
                        pkt->dp_Res1 = DOSFALSE;
                        pkt->dp_Res2 = ERROR_SEEK_ERROR;
                    }
                break;
            }
            case ACTION_CURRENT_VOLUME: pkt->dp_Res1 = MKBADDR(g_volnode); break;
            case ACTION_DIE:            act_die(pkt); break;

            /* comments have no NFS home; refuse so nobody thinks they stick */
            case ACTION_SET_COMMENT:
                pkt->dp_Res1 = DOSFALSE;
                pkt->dp_Res2 = ERROR_ACTION_NOT_KNOWN;
                break;

            default:
                DBG2("unknown action ", pkt->dp_Type);
                pkt->dp_Res1 = DOSFALSE;
                pkt->dp_Res2 = ERROR_ACTION_NOT_KNOWN;
                break;
            }
            ReplyPkt(pkt, pkt->dp_Res1, pkt->dp_Res2);
        }
    }

    /* teardown: sockets and library bases; locks/files were zero (DIE
     * refuses otherwise), buffers are ours */
    drop_conn();
    if (SocketBase) CloseLibrary(SocketBase);
    if (g_volnode) {
        LockDosList(LDF_VOLUMES | LDF_WRITE);
        RemDosEntry(g_volnode);
        UnLockDosList(LDF_VOLUMES | LDF_WRITE);
        FreeDosEntry(g_volnode);
    }
    FreeVec(g_req);
    FreeVec(g_rep);
    DBG("gone");
    CloseLibrary((struct Library *)DOSBase);
    return RETURN_OK;
}
