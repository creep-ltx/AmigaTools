/* diff.c - patience line diff (the git-patience shape):
 * lines unique in BOTH files are anchors, the longest increasing
 * chain of anchors splits the problem, recursion fills the gaps.
 * Non-unique leftovers become plain replace blocks - honest, cheap
 * in memory, and good-looking on source code, which is the job.
 * Heap-only work arrays, tiny stack frames, depth-capped recursion:
 * a shell-default Amiga stack must survive any input. */
#include <stdlib.h>
#include <string.h>
#include "diff.h"

#define MAXDEPTH 64

typedef struct {
    const DLine *a, *b;
    DOp *ops;
    int nops, cap;
    int oom;
} Ctx;

static unsigned long hashline(const char *p, int len)
{
    unsigned long h = 5381;
    int i;
    for (i = 0; i < len; i++)
        h = ((h << 5) + h) ^ (unsigned char)p[i];
    return h;
}

int diff_split(const char *buf, long size, DLine **lines, int *nlines)
{
    long i, start;
    int n = 0, li = 0, len;
    DLine *l;
    for (i = 0; i < size; i++)
        if (buf[i] == '\n') n++;
    if (size > 0 && (n == 0 || buf[size - 1] != '\n'))
        n++;                    /* unterminated last line */
    *nlines = n;
    if (n == 0) { *lines = NULL; return 0; }
    l = malloc(n * sizeof(DLine));
    if (l == NULL) return -1;
    start = 0;
    for (i = 0; i <= size; i++) {
        if (i == size || buf[i] == '\n') {
            if (i == size && start == i) break;
            len = (int)(i - start);
            if (len > 0 && buf[start + len - 1] == '\r')
                len--;          /* CRLF tolerance */
            l[li].ptr = buf + start;
            l[li].len = len;
            l[li].hash = hashline(buf + start, len);
            li++;
            start = i + 1;
        }
    }
    *lines = l;
    return 0;
}

static int lineeq(const DLine *x, const DLine *y)
{
    if (x->hash != y->hash || x->len != y->len) return 0;
    return memcmp(x->ptr, y->ptr, x->len) == 0;
}

static void emit(Ctx *c, int t, int n)
{
    if (n <= 0 || c->oom) return;
    if (c->nops > 0 && c->ops[c->nops - 1].t == t) {
        c->ops[c->nops - 1].n += n;    /* merge adjacent runs */
        return;
    }
    if (c->nops >= c->cap) {
        int ncap = c->cap ? c->cap * 2 : 64;
        DOp *no = realloc(c->ops, ncap * sizeof(DOp));
        if (no == NULL) { c->oom = 1; return; }
        c->ops = no;
        c->cap = ncap;
    }
    c->ops[c->nops].t = (unsigned char)t;
    c->ops[c->nops].n = n;
    c->nops++;
}

/* index-sort helper: order a range's lines by hash so uniqueness is
 * a run-length question. Collision safety is conservative: an equal-
 * hash run longer than 1 is simply never an anchor. */
typedef struct { unsigned long hash; int idx; } HKey;

static int hkeycmp(const void *pa, const void *pb)
{
    const HKey *x = pa, *y = pb;
    if (x->hash < y->hash) return -1;
    if (x->hash > y->hash) return 1;
    return x->idx - y->idx;
}

static HKey *rangekeys(const DLine *l, int lo, int hi)
{
    int n = hi - lo, i;
    HKey *k = malloc(n * sizeof(HKey));
    if (k == NULL) return NULL;
    for (i = 0; i < n; i++) {
        k[i].hash = l[lo + i].hash;
        k[i].idx = lo + i;
    }
    qsort(k, n, sizeof(HKey), hkeycmp);
    return k;
}

/* is k[i] a hash-unique entry in its sorted array? */
static int isuniq(const HKey *k, int n, int i)
{
    if (i > 0 && k[i - 1].hash == k[i].hash) return 0;
    if (i < n - 1 && k[i + 1].hash == k[i].hash) return 0;
    return 1;
}

static int findkey(const HKey *k, int n, unsigned long hash)
{
    int lo = 0, hi = n - 1, mid;
    while (lo <= hi) {
        mid = (lo + hi) / 2;
        if (k[mid].hash < hash) lo = mid + 1;
        else if (k[mid].hash > hash) hi = mid - 1;
        else return mid;
    }
    return -1;
}

static void rec(Ctx *c, int alo, int ahi, int blo, int bhi, int depth);

/* the middle of a trimmed range: anchor on unique pairs, LIS-chain
 * them, recurse the gaps. Falls back to a replace block when there
 * are no anchors (or on OOM of the work arrays - degrade, not die). */
static void middle(Ctx *c, int alo, int ahi, int blo, int bhi, int depth)
{
    HKey *ka = NULL, *kb = NULL;
    int *ca = NULL, *cb = NULL;      /* candidate pairs, ia-ascending */
    int *tails = NULL, *prev = NULL; /* LIS piles */
    int na = ahi - alo, nb = bhi - blo;
    int i, j, nc = 0, nt = 0, best, pa, pb;

    ka = rangekeys(c->a, alo, ahi);
    kb = rangekeys(c->b, blo, bhi);
    ca = ka && kb ? malloc(na * sizeof(int)) : NULL;
    cb = ca ? malloc(na * sizeof(int)) : NULL;
    if (cb == NULL) goto replace;

    /* walk a's lines in file order; a line unique here AND unique in
     * b AND verifying equal becomes a candidate anchor */
    for (i = 0; i < na; i++) {
        int ai = alo + i, ki, kj;
        ki = findkey(ka, na, c->a[ai].hash);
        /* findkey lands somewhere in the run; unique means run of 1 */
        if (!isuniq(ka, na, ki) || ka[ki].idx != ai) continue;
        kj = findkey(kb, nb, c->a[ai].hash);
        if (kj < 0 || !isuniq(kb, nb, kj)) continue;
        if (!lineeq(&c->a[ai], &c->b[kb[kj].idx])) continue;
        ca[nc] = ai;
        cb[nc] = kb[kj].idx;
        nc++;
    }
    free(ka); free(kb); ka = kb = NULL;
    if (nc == 0) goto replace;

    /* longest increasing subsequence over cb (ca already ascends) */
    tails = malloc(nc * sizeof(int));
    prev = tails ? malloc(nc * sizeof(int)) : NULL;
    if (prev == NULL) goto replace;
    for (i = 0; i < nc; i++) {
        int lo = 0, hi = nt;
        while (lo < hi) {
            int mid = (lo + hi) / 2;
            if (cb[tails[mid]] < cb[i]) lo = mid + 1; else hi = mid;
        }
        prev[i] = lo > 0 ? tails[lo - 1] : -1;
        tails[lo] = i;
        if (lo == nt) nt++;
    }
    /* chain into ca/cb order by rewriting through prev links; reuse
     * tails as the chain buffer (nt entries, built backwards) */
    best = tails[nt - 1];
    for (i = nt - 1; i >= 0; i--) {
        tails[i] = best;
        best = prev[best];
    }
    free(prev); prev = NULL;

    pa = alo; pb = blo;
    for (j = 0; j < nt; j++) {
        int ia = ca[tails[j]], ib = cb[tails[j]];
        rec(c, pa, ia, pb, ib, depth + 1);
        emit(c, DOP_EQ, 1);
        pa = ia + 1;
        pb = ib + 1;
    }
    free(ca); free(cb); free(tails);
    rec(c, pa, ahi, pb, bhi, depth + 1);
    return;

replace:
    free(ka); free(kb); free(ca); free(cb); free(tails); free(prev);
    emit(c, DOP_DEL, na);
    emit(c, DOP_INS, nb);
}

static void rec(Ctx *c, int alo, int ahi, int blo, int bhi, int depth)
{
    int s = 0;
    if (c->oom) return;
    while (alo < ahi && blo < bhi && lineeq(&c->a[alo], &c->b[blo])) {
        emit(c, DOP_EQ, 1);
        alo++; blo++;
    }
    while (ahi > alo && bhi > blo &&
           lineeq(&c->a[ahi - 1], &c->b[bhi - 1])) {
        ahi--; bhi--; s++;
    }
    if (alo < ahi || blo < bhi) {
        if (alo == ahi)
            emit(c, DOP_INS, bhi - blo);
        else if (blo == bhi)
            emit(c, DOP_DEL, ahi - alo);
        else if (depth >= MAXDEPTH) {
            emit(c, DOP_DEL, ahi - alo);
            emit(c, DOP_INS, bhi - blo);
        } else
            middle(c, alo, ahi, blo, bhi, depth);
    }
    emit(c, DOP_EQ, s);
}

int diff_run(const DLine *a, int na, const DLine *b, int nb,
             DOp **ops, int *nops)
{
    Ctx c;
    c.a = a; c.b = b;
    c.ops = NULL; c.nops = 0; c.cap = 0; c.oom = 0;
    rec(&c, 0, na, 0, nb, 0);
    if (c.oom) { free(c.ops); *ops = NULL; *nops = 0; return -1; }
    *ops = c.ops;
    *nops = c.nops;
    return 0;
}

int diff_verify(const DLine *a, int na, const DLine *b, int nb,
                const DOp *ops, int nops)
{
    int i, j, ac = 0, bc = 0;
    for (i = 0; i < nops; i++) {
        int n = ops[i].n;
        if (n <= 0) return 0;
        switch (ops[i].t) {
        case DOP_EQ:
            if (ac + n > na || bc + n > nb) return 0;
            for (j = 0; j < n; j++)
                if (!lineeq(&a[ac + j], &b[bc + j])) return 0;
            ac += n; bc += n;
            break;
        case DOP_DEL:
            if (ac + n > na) return 0;
            ac += n;
            break;
        case DOP_INS:
            if (bc + n > nb) return 0;
            bc += n;
            break;
        default:
            return 0;
        }
    }
    return ac == na && bc == nb;
}
