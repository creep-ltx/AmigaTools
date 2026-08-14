/*
 * AmiNFS nfs-handler - an NFSv3-over-TCP client filesystem for AmigaOS 3.x.
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
 * b1 is read-only: every mutating action answers ERROR_DISK_WRITE_PROTECTED.
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
#include <proto/bsdsocket.h>

struct ExecBase *SysBase;
struct DosLibrary *DOSBase;
struct Library *SocketBase;

/* entry.c jumps here; it is linked first so the seglist starts with code */
LONG handler_main(void);

static const char verstag[] __attribute__((used)) =
    "$VER: nfs-handler 0.1b7 (14.8.2026)";

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

#define DBG(x)      do { kput("aminfs: "); kput(x); kputc('\n'); } while (0)
#define DBG2(x, n)  do { kput("aminfs: "); kput(x); kputu(n); kputc('\n'); } while (0)

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

#define NFS3_LOOKUP     3
#define NFS3_READ       6
#define NFS3_READDIRPLUS 17
#define NFS3_FSSTAT     18

#define NF3REG          1
#define NF3DIR          2

#define FHSIZE_MAX      64
#define RDCHUNK         16384          /* per NFS READ; tune in M4 */
#define REPBUF_SIZE     (RDCHUNK + 4096)
#define REQBUF_SIZE     2048
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
};

struct CFile {
    struct CFile *next;
    ULONG  fhlen;
    UBYTE  fh[FHSIZE_MAX];
    ULONG  pos;
    ULONG  size;
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

static LONG   g_sock;                  /* persistent nfsd connection */
static LONG   g_have_root;
static ULONG  g_rootfhlen;
static UBYTE  g_rootfh[FHSIZE_MAX];
static ULONG  g_xid;

static UBYTE *g_req;                   /* request build buffer */
static UBYTE *g_rep;                   /* reply buffer */
static ULONG  g_reqlen;

/* ------------------------------------------------------------------ */
/* XDR pack into g_req / unpack out of g_rep. m68k is big-endian =    */
/* XDR byte order, but the helpers keep bounds honest.                */

static void pk_u32(ULONG v)
{
    if (g_reqlen + 4 <= REQBUF_SIZE) {
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
    if (g_reqlen + n + pad <= REQBUF_SIZE) {
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
    LONG rc;
    LONG s = socket(AF_INET, SOCK_STREAM, 0);
    DBG2("socket fd ", s);
    if (s < 0) return -1;
    memset(&sa, 0, sizeof(sa));
    sa.sin_len = sizeof(sa);
    sa.sin_family = AF_INET;
    sa.sin_port = dstport;             /* big-endian host: already net order */
    sa.sin_addr.s_addr = ip;
    rc = connect(s, (struct sockaddr *)&sa, sizeof(sa));
    kput("aminfs: connect port "); kputu(dstport); kput(" rc ");
    if (rc < 0) { kput("-"); kputu(-rc); } else kputu(rc);
    if (rc < 0) { kput(" errno "); kputu(Errno()); }
    kputc('\n');
    if (rc < 0) {
        CloseSocket(s);
        return -1;
    }
    {
        LONG one = 1;
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
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
        LONG r = recv(s, d, n, 0);
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
    /* body: stamp(4) + name "aminfs" (4 len + 6 + 2 pad = 12) + uid(4)
     * + gid(4) + gids count(4) = 28. Length must track the name. */
    pk_u32(28);
    pk_u32(0); pk_str("aminfs"); pk_u32(1000); pk_u32(1000); pk_u32(0);
    pk_u32(AUTH_NULL); pk_u32(0);      /* verf */
}

static LONG rpc_finish(LONG s, struct UB *u)
{
    ULONG msglen = g_reqlen - 4;
    ULONG total = 0, last = 0;
    UBYTE *p = g_req;

    p[0] = 0x80 | (msglen >> 24); p[1] = msglen >> 16;
    p[2] = msglen >> 8; p[3] = msglen;
    if (sendall(s, g_req, g_reqlen)) return 0;

    while (!last) {
        UBYTE mark[4]; ULONG n;
        if (recvn(s, mark, 4)) return 0;
        last = mark[0] & 0x80;
        n = ((ULONG)(mark[0] & 0x7F) << 24) | ((ULONG)mark[1] << 16)
          | ((ULONG)mark[2] << 8) | mark[3];
        if (total + n > REPBUF_SIZE) return 0;
        if (recvn(s, g_rep + total, n)) return 0;
        total += n;
    }

    u->p = g_rep; u->end = g_rep + total; u->err = 0;
    {
        ULONG xid = ub_u32(u), mtype = ub_u32(u), stat = ub_u32(u);
        ULONG vlen;
        if (u->err || xid != g_xid || mtype != 1 || stat != 0) return 0;
        ub_u32(u); ub_opaque(u, &vlen);        /* verifier */
        if (ub_u32(u) != 0) return 0;          /* accept_stat */
    }
    return !u->err;
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

/* one-shot diagnostic: where does outbound TCP actually reach? */
static LONG g_probed;
static void probe_net(ULONG ip)
{
    static const UWORD ports[3] = { 111, 2049, 22 };
    ULONG rtr = (ip & 0xFFFFFF00) | 1;   /* .1 = the router */
    LONG i, s;
    if (g_probed) return;
    g_probed = 1;
    for (i = 0; i < 3; i++) {
        s = tcp_connect(ip, ports[i]);
        if (s >= 0) CloseSocket(s);
    }
    s = tcp_connect(rtr, 80);
    if (s >= 0) CloseSocket(s);
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
    probe_net(ip);

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
struct NfsArgs { const UBYTE *fh; ULONG fhlen; const char *name;
                 ULONG a, b, c; };

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
            if (g_reqlen + 8 <= REQBUF_SIZE) {   /* cookieverf: raw 8 bytes */
                memcpy(g_req + g_reqlen, verf, 8);
                g_reqlen += 8;
            }
            pk_u32(4096);              /* dircount */
            pk_u32(REPBUF_SIZE - 512); /* maxcount */
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
                       UBYTE *outfh, ULONG *outfhlen, struct Attr *a);

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
                       UBYTE *outfh, ULONG *outfhlen, struct Attr *a)
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

        if (chunk > RDCHUNK) chunk = RDCHUNK;
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
                    err = nfs_lookup(curfh, curlen, "..", nfh, &nlen, &na2);
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
                err = nfs_lookup(curfh, curlen, comp, nfh, &nlen, &na2);
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
static void __attribute__((unused)) leafname(UBYTE *bstr, char *out)
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
            err = nfs_lookup(fh, fhlen, "..", nfh, &nlen, &a);
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
    LONG is_root = (!cl || (cl->fhlen == g_rootfhlen &&
                            !c_memcmp(cl->fh, g_rootfh, cl->fhlen)));

    /* We stored type/key at lock time; size/date need a fresh LOOKUP of
     * ourselves - NFS has GETATTR but b1 leans on the lock's snapshot
     * plus the dircache for EXNEXT. For EXAMINE on a dir (the common
     * List entry) static data suffices; for a file, re-resolve is
     * skipped in b1 (size shows 0 on direct Examine of a file lock).
     * TODO b2: real GETATTR here. */
    a.ftype = cl ? cl->ftype : NF3DIR;
    a.mode = 0755; a.size = 0; a.mtime = 0;
    a.fileid = cl ? (ULONG)cl->fl.fl_Key : 0;

    fib_fill(fib, is_root ? g_volname : "", &a, is_root);
    if (!is_root) {
        /* no name stored in the lock in b1; EXAMINE_NEXT fills real names */
        fib->fib_FileName[0] = 1;
        fib->fib_FileName[1] = '?';
    }
    fib->fib_DiskKey = 0;              /* EXNEXT starts at index 0 */
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
    {
        struct CFile *cf = AllocVec(sizeof(*cf), MEMF_PUBLIC | MEMF_CLEAR);
        if (!cf) { pkt->dp_Res1 = DOSFALSE; pkt->dp_Res2 = ERROR_NO_FREE_STORE; return; }
        memcpy(cf->fh, fh, fhlen);
        cf->fhlen = fhlen;
        cf->size = a.size;
        cf->next = g_files;
        g_files = cf;
        g_nfiles++;
        fhandle->fh_Arg1 = (LONG)cf;
        fhandle->fh_Type = g_port;
        pkt->dp_Res1 = DOSTRUE;
        pkt->dp_Res2 = 0;
    }
}

static void act_end(struct DosPacket *pkt)
{
    struct CFile *cf = (struct CFile *)pkt->dp_Arg1;
    struct CFile **pp;
    for (pp = &g_files; *pp; pp = &(*pp)->next)
        if (*pp == cf) { *pp = cf->next; FreeVec(cf); g_nfiles--; break; }
    pkt->dp_Res1 = DOSTRUE;
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
    err = nfs_read(cf, dst, want, &got);
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
            if (thi & 0xFFFFFF00) tblocks = 0x7FFFFFFF;
            else tblocks = (thi << 23) | (tlo >> 9);
            if (fhi & 0xFFFFFF00) ublocks = 0;
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

static void act_die(struct DosPacket *pkt)
{
    if (g_nlocks || g_nfiles) {
        pkt->dp_Res1 = DOSFALSE;
        pkt->dp_Res2 = ERROR_OBJECT_IN_USE;
        return;
    }
    DBG("ACTION_DIE: shutting down");
    g_devnode->dn_Task = NULL;         /* next open gets a fresh mount */
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
    kput("aminfs: startup len "); kputu(len); kput(" ");
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
        for (i = colon + 1; i < e && o < 191; i++) g_export[o++] = b[i];
        g_export[o] = 0;
    }

    kput("aminfs: host '"); kput(g_host); kput("' export '"); kput(g_export);
    kput("'\n");

    /* volume name = last path component of the export */
    {
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
    g_req = g_rep = NULL;

    me = (struct Process *)FindTask(NULL);
    g_port = &me->pr_MsgPort;
    me->pr_WindowPtr = (APTR)-1;       /* no requesters from this process */

    WaitPort(g_port);
    msg = GetMsg(g_port);
    pkt = (struct DosPacket *)msg->mn_Node.ln_Name;
    g_devnode = BADDR(pkt->dp_Arg3);

    parse_startup();

    g_req = AllocVec(REQBUF_SIZE, MEMF_PUBLIC);
    g_rep = AllocVec(REPBUF_SIZE, MEMF_PUBLIC);
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
            DBG2("pkt ", pkt->dp_Type);

            switch (pkt->dp_Type) {
            case ACTION_LOCATE_OBJECT:  act_locate(pkt); break;
            case ACTION_FREE_LOCK:      act_free_lock(pkt); break;
            case ACTION_COPY_DIR:       act_copy_dir(pkt); break;
            case ACTION_PARENT:         act_parent(pkt); break;
            case ACTION_EXAMINE_OBJECT: act_examine(pkt); break;
            case ACTION_EXAMINE_NEXT:   act_examine_next(pkt); break;
            case ACTION_FINDINPUT:      act_findinput(pkt); break;
            case ACTION_END:            act_end(pkt); break;
            case ACTION_READ:           act_read(pkt); break;
            case ACTION_SEEK:           act_seek(pkt); break;
            case ACTION_DISK_INFO:      act_info(pkt, pkt->dp_Arg1); break;
            case ACTION_INFO:           act_info(pkt, pkt->dp_Arg2); break;
            case ACTION_SAME_LOCK:      act_same_lock(pkt); break;
            case ACTION_IS_FILESYSTEM:  pkt->dp_Res1 = DOSTRUE; break;
            case ACTION_FLUSH:          pkt->dp_Res1 = DOSTRUE; break;
            case ACTION_CURRENT_VOLUME: pkt->dp_Res1 = MKBADDR(g_volnode); break;
            case ACTION_DIE:            act_die(pkt); break;

            /* the write side arrives in b2+; refuse honestly for now */
            case ACTION_FINDOUTPUT:
            case ACTION_FINDUPDATE:
            case ACTION_WRITE:
            case ACTION_DELETE_OBJECT:
            case ACTION_RENAME_OBJECT:
            case ACTION_CREATE_DIR:
            case ACTION_SET_PROTECT:
            case ACTION_SET_COMMENT:
            case ACTION_SET_DATE:
            case ACTION_SET_FILE_SIZE:
                pkt->dp_Res1 = DOSFALSE;
                pkt->dp_Res2 = ERROR_DISK_WRITE_PROTECTED;
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
