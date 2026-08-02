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

/* b99: the most work Myers is allowed to attempt on one replace
 * block, counted as n+m lines. Myers is O(ND) in time and needs two
 * vectors of 2(n+m)+3 ints; both have to stay affordable on a small
 * Amiga, and a block bigger than this is not a block anyone reads
 * line by line anyway. Past the cap we emit the plain replace that
 * was there before - degrade, never die. */
#define MYERSMAX 1024

typedef struct {
    const DLine *a, *b;
    DOp *ops;
    int nops, cap;
    int oom;
    int *mv1, *mv2, mvoff;      /* b99: Myers work vectors, or NULL */
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

/* ---- b99: Myers inside the replace blocks ----------------------
 * Patience anchors on lines unique in BOTH files. When a block has
 * no unique lines there is nothing to anchor on, and the whole thing
 * degraded to "delete all n, insert all m" - which is exactly what a
 * run of `WA_TOP,`/`WA_WIDTH,`/`WA_HEIGHT,` looks like, where most
 * of the lines actually match.
 *
 * Myers finds the genuinely shortest edit script. The MIDDLE SNAKE
 * is what makes it affordable: instead of building the whole edit
 * graph, find the midpoint of an optimal path by running the search
 * forward from the start and backward from the end until they meet,
 * then recurse on the two halves. Linear memory instead of
 * quadratic. Applied ONLY here, so patience keeps its good
 * anchoring everywhere else. */

/* the middle snake of a[alo..alo+n) vs b[blo..blo+m). Returns the
 * edit distance and, in forward-local coordinates, the snake start
 * (*px,*py) and end (*pu,*pv). -1 if the cap was hit. */
static int midsnake(Ctx *c, int alo, int n, int blo, int m,
                    int *v1, int *v2, int off,
                    int *px, int *py, int *pu, int *pv)
{
    int delta = n - m;
    int odd = (delta & 1) != 0;
    int dmax = (n + m + 1) / 2;
    int d, k;

    v1[off + 1] = 0;
    v2[off + 1] = 0;
    for (d = 0; d <= dmax; d++) {
        for (k = -d; k <= d; k += 2) {          /* forward */
            int x, y, x0;
            if (k == -d || (k != d && v1[off + k - 1] < v1[off + k + 1]))
                x = v1[off + k + 1];
            else
                x = v1[off + k - 1] + 1;
            y = x - k;
            x0 = x;
            while (x < n && y < m &&
                   lineeq(&c->a[alo + x], &c->b[blo + y])) { x++; y++; }
            v1[off + k] = x;
            if (odd) {
                int kk = delta - k;
                if (kk >= -(d - 1) && kk <= (d - 1) &&
                    v1[off + k] + v2[off + kk] >= n) {
                    *px = x0; *py = x0 - k;
                    *pu = x;  *pv = y;
                    return 2 * d - 1;
                }
            }
        }
        for (k = -d; k <= d; k += 2) {          /* backward */
            int x, y, x0;
            if (k == -d || (k != d && v2[off + k - 1] < v2[off + k + 1]))
                x = v2[off + k + 1];
            else
                x = v2[off + k - 1] + 1;
            y = x - k;
            x0 = x;
            while (x < n && y < m &&
                   lineeq(&c->a[alo + n - 1 - x],
                          &c->b[blo + m - 1 - y])) { x++; y++; }
            v2[off + k] = x;
            if (!odd) {
                int kk = delta - k;
                if (kk >= -d && kk <= d &&
                    v2[off + k] + v1[off + kk] >= n) {
                    /* backward coordinates count from the end */
                    *px = n - x;  *py = m - y;
                    *pu = n - x0; *pv = m - (x0 - k);
                    return 2 * d;
                }
            }
        }
    }
    return -1;
}

static void myers(Ctx *c, int alo, int ahi, int blo, int bhi, int depth)
{
    int n = ahi - alo, m = bhi - blo;
    int x, y, u, v;

    if (c->oom) return;
    if (n <= 0 && m <= 0) return;
    if (n <= 0) { emit(c, DOP_INS, m); return; }
    if (m <= 0) { emit(c, DOP_DEL, n); return; }
    /* the depth cap is the backstop for any pathological split: we
     * fall back to the honest replace rather than recurse forever */
    if (depth >= MAXDEPTH ||
        midsnake(c, alo, n, blo, m, c->mv1, c->mv2, c->mvoff,
                 &x, &y, &u, &v) < 0) {
        emit(c, DOP_DEL, n);
        emit(c, DOP_INS, m);
        return;
    }
    /* no split possible - same guard, reached when the snake spans
     * the whole range in one direction */
    if ((x == 0 && y == 0 && u == 0 && v == 0) ||
        (x == n && y == m && u == n && v == m)) {
        emit(c, DOP_DEL, n);
        emit(c, DOP_INS, m);
        return;
    }
    myers(c, alo, alo + x, blo, blo + y, depth + 1);
    if (u > x) emit(c, DOP_EQ, u - x);
    myers(c, alo + u, ahi, blo + v, bhi, depth + 1);
}

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
    /* b99: no anchors here - this is where the block used to become
     * a wholesale replace. Myers aligns it properly, within the cap
     * and only if the work vectors exist. */
    if (c->mv1 && c->mv2 && na + nb <= MYERSMAX) {
        myers(c, alo, ahi, blo, bhi, depth);
        return;
    }
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
    int vn = 2 * MYERSMAX + 3;
    c.a = a; c.b = b;
    c.ops = NULL; c.nops = 0; c.cap = 0; c.oom = 0;
    /* b99: one allocation for the whole run, reused by every replace
     * block - Myers is called from deep inside the recursion and must
     * not malloc there. If either fails we simply never use Myers and
     * the blocks stay as plain replaces: a missing optimisation, not
     * a failure. */
    c.mv1 = malloc(vn * sizeof(int));
    c.mv2 = c.mv1 ? malloc(vn * sizeof(int)) : NULL;
    c.mvoff = MYERSMAX + 1;
    if (c.mv2 == NULL) { free(c.mv1); c.mv1 = NULL; }
    rec(&c, 0, na, 0, nb, 0);
    free(c.mv1);
    free(c.mv2);
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
