/* engine.c - CCON's output fast path, in C (1.2.8b9).

   Why C inside an E handler: on a stock A1200 (14MHz 68020, chip RAM
   only) every instruction is fetched over the chip bus the display is
   already holding, and E's code for render() cost ~30us per printable
   byte and ~100us per escape byte (measured, CCON.prof). gcc -O2 code
   for the same work is a fraction of that.

   This file mirrors render()'s DEFERRED path (dfon) for the byte
   classes that make up nearly all output - printables, LF, CR, BS, TAB,
   FF and CSI m/H/f/A/B/C/D/K/J/L/M/S/T/@/P - statement for statement against the E
   procs named in each comment. Anything else (other escapes, OSC, the
   8-bit introducers, private CSI, a sequence split across writes) is
   handed back: frun returns the index of the byte E must take next, and
   E is only ever called at cesc = 0, so its state machine starts that
   byte fresh. E's procs stay the reference; change one, change both.

   Built position independent (no data, no absolute addresses): see
   build.sh, which links it at two addresses and refuses to ship if the
   two images differ. */

#include "con.h"

#ifndef EXEC_TYPES_H
typedef unsigned long ULONG;
#endif

/* the E globals render() keeps its engine state in, by address -
   filled once by the handler (fxinit), see FX_* in ccon-handler.e */
struct fx {
    struct con **curcon;
    LONG *dfon, *dfpend, *dffull, *dflo, *dfhi, *dflost, *dfgen;
    LONG *alteat, *dfnarrow, *maskon;
    UBYTE **dfd, **dfx0, **dfx1;
    LONG *dfo;
    UBYTE *dfdb, *dfx0b, *dfx1b;
    LONG *conlist;          /* 18: the console list head */
    LONG *flusharmed;       /* 19 */
    LONG *port;             /* 20: our packet port (pr_MsgPort) */
    void *sysbase;          /* 21: exec */
    LONG *dfvb;             /* 22 */
    void *gfxbase;          /* 23 */
    LONG *dgtf, *gsh;       /* 24, 25: what ppsetup's pctx was built for - */
    LONG *pkey;             /* 26: pkey[0..5] (bm, ax, ay, ch, dgtf, gsh) */
    LONG *fxret, *fxold;    /* 27, 28: cfout's hand-over to cfresume */
    UBYTE *ftreq;           /* 29: the flush timer request (non-NIL) */
    LONG *fdelay;           /* 30: its wait (us) */
};

#define DFROWS 256
#define TRUE (-1)
#define FALSE 0

static inline LONG ringidx(struct con *k, LONG r)
{
    LONG i = k->sbtop + r;
    if (i >= k->sbmax) i -= k->sbmax;
    return i;
}

/* byte fill / copy a long at a time: on a stock 020 every chip access
   is the cost, and a long store moves four cells' bytes for one (the
   020 takes the misaligned source reads in its stride) */
extern void abfill(UBYTE *p, ULONG v, LONG n);           /* pgroups.s */
extern void abcopy(UBYTE *d, const UBYTE *s, LONG n);
#define bfill abfill
#define bcopy abcopy
#define zfill(p, n) bfill(p, 0, n)

/* clearrow */
static void clearrow(struct con *k, LONG r)
{
    LONG i = ringidx(k, r);
    LONG off = i * k->cols;
    zfill((UBYTE *)k->sb + off, k->cols);
    zfill((UBYTE *)k->sa + off, k->cols);
    zfill((UBYTE *)k->ss + off, k->cols);
    if (k->sw && r >= 0 && r < k->rows) ((UBYTE *)k->sw)[i] = 0;
}

/* setwrapf */
static void setwrapf(struct con *k, LONG r, LONG v)
{
    if (!k->sw) return;
    if (r < 0 || r > k->rows - 1) return;
    ((UBYTE *)k->sw)[ringidx(k, r)] = v;
}

/* dfmark */
static void dfmark(struct fx *x, struct con *k, LONG r, LONG x0, LONG x1)
{
    UBYTE *d = *x->dfd, *a = *x->dfx0, *b = *x->dfx1;
    if (*x->dffull) return;
    if (r < 0 || r > k->rows - 1) return;
    if (d[r] == (UBYTE)*x->dfgen) {
        if (x0 < a[r]) a[r] = x0;
        if (x1 > b[r]) b[r] = x1;
    } else {
        d[r] = *x->dfgen;
        a[r] = x0;
        b[r] = x1;
    }
    if (r < *x->dflo) *x->dflo = r;
    if (r > *x->dfhi) *x->dfhi = r;
}

/* dfscroll (1.2.8b9 sliding window) */
static void dfscroll(struct fx *x, struct con *k)
{
    LONG o;
    if (k->ancy > 0) k->ancy--;
    k->sbtop++;
    if (k->sbtop >= k->sbmax) k->sbtop = 0;
    if (k->sbcnt < k->sbmax - k->rows) k->sbcnt++;
    if (k->rawmode | k->altvalid) k->rawscr++;
    clearrow(k, k->rows - 1);
    if (*x->dffull) return;
    (*x->dfpend)++;
    if (*x->dfpend >= k->rows) {
        *x->dffull = TRUE;
        *x->dfpend = 0;
        return;
    }
    if (*x->dflo == 0 && *x->dfhi >= 0) {
        if ((*x->dfd)[0] == (UBYTE)*x->dfgen) {
            LONG w = (*x->dfx1)[0] + 1;
            if (w > *x->dflost) *x->dflost = w;
        }
    }
    o = *x->dfo + 1;
    if (o >= DFROWS) {
        LONG j;
        for (j = 0; j < DFROWS; j++) {
            x->dfdb[j] = x->dfdb[j + o];
            x->dfx0b[j] = x->dfx0b[j + o];
            x->dfx1b[j] = x->dfx1b[j + o];
        }
        o = 0;
    }
    *x->dfo = o;
    *x->dfd = x->dfdb + o;
    *x->dfx0 = x->dfx0b + o;
    *x->dfx1 = x->dfx1b + o;
    (*x->dfd)[k->rows - 1] = 0;
    if (*x->dfhi >= 0) {
        if (*x->dflo - 1 > 0) (*x->dflo)--; else *x->dflo = 0;
        (*x->dfhi)--;
    }
}

/* jumpok */
static LONG jumpok(struct con *k)
{
    k->jburst++;
    if (k->jeff <= 1) return FALSE;
    if (k->rawmode) return FALSE;
    if (k->altvalid) return FALSE;
    if (k->jauto) {
        if (k->jburst < (k->rows >> 1) && k->jsync < 4) return FALSE;
    }
    k->jslk = TRUE;
    return TRUE;
}

/* dfnl */
static void dfnl(struct fx *x, struct con *k)
{
    LONG j;
    k->cx = 0;
    k->cy++;
    if (k->cy >= k->rows) {
        if (jumpok(k)) {
            for (j = 1; j <= k->jeff; j++) dfscroll(x, k);
            k->cy = k->rows - k->jeff;
        } else {
            dfscroll(x, k);
            k->cy = k->rows - 1;
        }
    }
    setwrapf(k, k->cy, 0);
}

/* a run of m newlines (dfnl m times). Once dffull is set a scroll
   touches no dirt - it is ring bookkeeping and one cleared row - so
   that case runs here with every field in a register: scroll-nl's
   bare newlines cost ~230us each through the dfnl/dfscroll chain */
static void lfrun(struct fx *x, struct con *k, LONG m)
{
    LONG cy, rows, cols, jb, sbtop, sbmax, sbcnt, lim, ancy, rawscr, raw, jok, jauto, jeff, jslk;
    UBYTE *sb, *sa, *ss, *sw;
    while (m > 0 && !*x->dffull) { dfnl(x, k); m--; }
    if (m <= 0) return;
    cy = k->cy; rows = k->rows; cols = k->cols; jb = k->jburst;
    sbtop = k->sbtop; sbmax = k->sbmax; sbcnt = k->sbcnt; lim = sbmax - rows;
    ancy = k->ancy; rawscr = k->rawscr; raw = k->rawmode | k->altvalid;
    jok = k->jeff > 1 && !k->rawmode && !k->altvalid;
    jauto = k->jauto; jeff = k->jeff; jslk = k->jslk;
    sb = (UBYTE *)k->sb; sa = (UBYTE *)k->sa; ss = (UBYTE *)k->ss; sw = (UBYTE *)k->sw;
    while (m-- > 0) {
        LONG i;
        cy++;
        if (cy >= rows) {
            LONG ns = 1;
            jb++;
            if (jok && (!jauto || jb >= (rows >> 1) || k->jsync >= 4)) { jslk = TRUE; ns = jeff; }
            cy = rows - ns;
            while (ns-- > 0) {
                LONG off;
                if (ancy > 0) ancy--;
                sbtop++;
                if (sbtop >= sbmax) sbtop = 0;
                if (sbcnt < lim) sbcnt++;
                if (raw) rawscr++;
                i = sbtop + rows - 1;
                if (i >= sbmax) i -= sbmax;
                off = i * cols;
                zfill(sb + off, cols);
                zfill(sa + off, cols);
                zfill(ss + off, cols);
                if (sw) sw[i] = 0;
            }
        }
        if (sw) {
            i = sbtop + cy;
            if (i >= sbmax) i -= sbmax;
            sw[i] = 0;
        }
    }
    k->cx = 0; k->cy = cy; k->jburst = jb; k->sbtop = sbtop; k->sbcnt = sbcnt;
    k->ancy = ancy; k->rawscr = rawscr; k->jslk = jslk;
}

/* dfwrapnl */
static void dfwrapnl(struct fx *x, struct con *k)
{
    dfnl(x, k);
    setwrapf(k, k->cy, 1);
}

/* maskcalc (1.2.8b9: the exact plane set, see the E proc) */
static void maskcalc(struct fx *x, struct con *k)
{
    k->mmask = (k->mpens & 0xFF) | k->mfloor;
    if (*x->maskon) {
        UBYTE *rp = (UBYTE *)k->rp;
        rp[24] = k->mmask;               /* rp_Mask */
    }
}

/* penuse */
static void penuse(struct fx *x, struct con *k, LONG f, LONG b)
{
    LONG u = k->mpens | f | b;
    if (u != k->mpens) {
        k->mpens = u;
        maskcalc(x, k);
    }
}

/* fgpen */
static LONG fgpen(struct con *k)
{
    if (k->bold && k->curfg < 8) {
        if (k->wbpens) {
            if (k->can16) return k->curfg + 8;
        } else if (k->cursgr) {
            if (k->anstab[k->curfg] >= 0) return k->anstab[k->curfg];
        }
    }
    return k->curfg;
}

/* curattr */
static LONG curattr(struct fx *x, struct con *k)
{
    LONG f = fgpen(k);
    penuse(x, k, f, k->curbg);
    return f | (k->curbg << 4);
}

/* render()'s deferred printable run */
static void putrun(struct fx *x, struct con *k, const UBYTE *s, LONG run)
{
    LONG at, sty, fit, off;
    UBYTE *m, *a, *t;
    k->vblank = FALSE;
    *x->alteat = FALSE;
    at = curattr(x, k);
    sty = k->cursty;
    while (run > 0) {
        if (k->cx >= k->cols) dfwrapnl(x, k);
        fit = k->cols - k->cx;
        if (fit > run) fit = run;
        off = ringidx(k, k->cy) * k->cols + k->cx;
        m = (UBYTE *)k->sb + off;
        a = (UBYTE *)k->sa + off;
        t = (UBYTE *)k->ss + off;
        bcopy(m, s, fit);
        bfill(a, at, fit);
        bfill(t, sty, fit);
        dfmark(x, k, k->cy, k->cx, k->cx + fit - 1);
        k->cx += fit;
        s += fit;
        run -= fit;
    }
}

/* dfputc */
static void dfputc(struct fx *x, struct con *k, LONG c)
{
    LONG off;
    if (k->cx >= k->cols) dfwrapnl(x, k);
    k->vblank = FALSE;
    off = ringidx(k, k->cy) * k->cols + k->cx;
    ((UBYTE *)k->sb)[off] = c;
    ((UBYTE *)k->sa)[off] = curattr(x, k);
    ((UBYTE *)k->ss)[off] = k->cursty;
    dfmark(x, k, k->cy, k->cx, k->cx);
    k->cx++;
}

/* eraseeol, deferred */
static void eraseeol(struct fx *x, struct con *k)
{
    LONG j, off;
    UBYTE *m, *a, *t;
    if (k->cx >= k->cols) return;
    if (k->sb) {
        off = ringidx(k, k->cy) * k->cols;
        m = (UBYTE *)k->sb + off;
        a = (UBYTE *)k->sa + off;
        t = (UBYTE *)k->ss + off;
        j = k->cols - k->cx;
        zfill(m + k->cx, j);
        zfill(a + k->cx, j);
        zfill(t + k->cx, j);
        setwrapf(k, k->cy + 1, 0);
        dfmark(x, k, k->cy, k->cx, k->cols - 1);
    }
}

/* erasebelow, deferred */
static void erasebelow(struct fx *x, struct con *k)
{
    LONG r;
    eraseeol(x, k);
    if (k->cy < k->rows - 1) {
        if (k->sb) {
            for (r = k->cy + 1; r <= k->rows - 1; r++) clearrow(k, r);
            for (r = k->cy + 1; r <= k->rows - 1; r++) dfmark(x, k, r, 0, k->cols - 1);
        }
    }
}

/* ---- the region ops, deferred (E1): model moves + full-width marks ---- */

static void rowcopy(struct con *k, LONG from, LONG to)
{
    LONG c = k->cols, f = ringidx(k, from) * c, t = ringidx(k, to) * c;
    bcopy((UBYTE *)k->sb + t, (UBYTE *)k->sb + f, c);
    bcopy((UBYTE *)k->sa + t, (UBYTE *)k->sa + f, c);
    bcopy((UBYTE *)k->ss + t, (UBYTE *)k->ss + f, c);
}

static void dropwrapf(struct con *k, LONG r0, LONG r1)
{
    LONG r;
    if (!k->sw) return;
    for (r = r0; r <= r1; r++) setwrapf(k, r, 0);
}

static void markrows(struct fx *x, struct con *k, LONG r0, LONG r1)
{
    LONG r;
    for (r = r0; r <= r1; r++) dfmark(x, k, r, 0, k->cols - 1);
}

/* inslines */
static void inslines(struct fx *x, struct con *k, LONG n)
{
    LONG r;
    if (n < 1) n = 1;
    if (n > k->rows - k->cy) n = k->rows - k->cy;
    if (k->sb) {
        for (r = k->rows - 1; r >= k->cy + n; r--) rowcopy(k, r - n, r);
        for (r = k->cy; r <= k->cy + n - 1; r++) clearrow(k, r);
        dropwrapf(k, k->cy, k->rows - 1);
        markrows(x, k, k->cy, k->rows - 1);
    }
}

/* dellines */
static void dellines(struct fx *x, struct con *k, LONG n)
{
    LONG r;
    if (n < 1) n = 1;
    if (n > k->rows - k->cy) n = k->rows - k->cy;
    if (k->sb) {
        for (r = k->cy; r <= k->rows - 1 - n; r++) rowcopy(k, r + n, r);
        for (r = k->rows - n; r <= k->rows - 1; r++) clearrow(k, r);
        dropwrapf(k, k->cy, k->rows - 1);
        markrows(x, k, k->cy, k->rows - 1);
    }
}

/* scrollup */
static void scrollup(struct fx *x, struct con *k, LONG n)
{
    LONG r;
    if (n < 1) n = 1;
    if (n > k->rows) n = k->rows;
    if (k->sb) {
        for (r = 0; r <= k->rows - 1 - n; r++) rowcopy(k, r + n, r);
        for (r = k->rows - n; r <= k->rows - 1; r++) clearrow(k, r);
        dropwrapf(k, 0, k->rows - 1);
        markrows(x, k, 0, k->rows - 1);
    }
}

/* scrolldown */
static void scrolldown(struct fx *x, struct con *k, LONG n)
{
    LONG r;
    if (n < 1) n = 1;
    if (n > k->rows) n = k->rows;
    if (k->sb) {
        for (r = k->rows - 1; r >= n; r--) rowcopy(k, r - n, r);
        for (r = 0; r <= n - 1; r++) clearrow(k, r);
        dropwrapf(k, 0, k->rows - 1);
        markrows(x, k, 0, k->rows - 1);
    }
}

/* inschars */
static void inschars(struct fx *x, struct con *k, LONG n)
{
    LONG j, off;
    UBYTE *m, *a, *st;
    if (k->cx >= k->cols) return;
    if (n < 1) n = 1;
    if (n > k->cols - k->cx) n = k->cols - k->cx;
    if (k->sb) {
        off = ringidx(k, k->cy) * k->cols;
        m = (UBYTE *)k->sb + off; a = (UBYTE *)k->sa + off; st = (UBYTE *)k->ss + off;
        for (j = k->cols - 1; j >= k->cx + n; j--) {
            m[j] = m[j - n]; a[j] = a[j - n]; st[j] = st[j - n];
        }
        for (j = k->cx; j <= k->cx + n - 1; j++) { m[j] = 0; a[j] = 0; st[j] = 0; }
        setwrapf(k, k->cy + 1, 0);
        dfmark(x, k, k->cy, k->cx, k->cols - 1);
    }
}

/* delchars */
static void delchars(struct fx *x, struct con *k, LONG n)
{
    LONG j, off;
    UBYTE *m, *a, *st;
    if (k->cx >= k->cols) return;
    if (n < 1) n = 1;
    if (n > k->cols - k->cx) n = k->cols - k->cx;
    if (k->sb) {
        off = ringidx(k, k->cy) * k->cols;
        m = (UBYTE *)k->sb + off; a = (UBYTE *)k->sa + off; st = (UBYTE *)k->ss + off;
        for (j = k->cx; j <= k->cols - 1 - n; j++) {
            m[j] = m[j + n]; a[j] = a[j + n]; st[j] = st[j + n];
        }
        for (j = k->cols - n; j <= k->cols - 1; j++) { m[j] = 0; a[j] = 0; st[j] = 0; }
        setwrapf(k, k->cy + 1, 0);
        dfmark(x, k, k->cy, k->cx, k->cols - 1);
    }
}

/* csidispatch's 'm' */
static void sgr(struct con *k, LONG *par, LONG np)
{
    LONG i, v;
    for (i = 0; i <= np; i++) {
        v = par[i];
        if (v == 0) {
            k->curfg = k->deffg; k->curbg = 0; k->bold = FALSE;
            k->cursgr = FALSE; k->cursty = 0;
        } else if (v == 1) { k->bold = TRUE; k->cursty |= 8; }
        else if (v == 22) { k->bold = FALSE; k->cursty &= 7; }
        else if (v == 3) k->cursty |= 1;
        else if (v == 23) k->cursty &= 14;
        else if (v == 4) k->cursty |= 2;
        else if (v == 24) k->cursty &= 13;
        else if (v == 7) k->cursty |= 4;
        else if (v == 27) k->cursty &= 11;
        else if (v >= 30 && v <= 37) {
            k->curfg = v - 30;
            k->cursgr = TRUE;
            if (k->wbpens && k->can16 && !k->bold && v <= 33) {
                if (v == 30) k->curfg = 0;
                else if (v == 31) k->curfg = k->deffg;
                else if (v == 32) k->curfg = 15;
                else k->curfg = 12;
            }
        } else if (v == 39) { k->curfg = k->deffg; k->cursgr = FALSE; }
        else if (v >= 40 && v <= 47) k->curbg = v - 40;
        else if (v == 49) k->curbg = 0;
    }
}

/* the end of the printable run starting at j (render()'s prtbl class:
   32..126 and 160..255). Four plain ASCII bytes per long read first -
   no high bit, none below $20 (hasless), none $7F (haszero of v^$7F) -
   then byte by byte: the byte loop alone was ~13 instructions a
   character, 1024 of the 1705 a 78-character line took (vamos -I) */
static LONG prscan(const UBYTE *s, LONG j, LONG len)
{
    while (j < len && ((ULONG)(s + j) & 3)) {        /* to a long boundary */
        UBYTE c = s[j];
        if ((UBYTE)(c - 32) >= 95 && c < 160) return j;
        j++;
    }
    while (j + 4 <= len) {
        ULONG v = *(const ULONG *)(s + j);
        /* a high bit in any byte of v, of v+$01.. ($7F turns $80) or of
           v-$20.. (a byte below $20 borrows) = not four plain printables.
           Carries and borrows can only flag more, never less - and a
           false flag just falls to the exact loop below */
        if ((v | (v + 0x01010101) | (v - 0x20202020)) & 0x80808080) break;
        j += 4;
    }
    while (j < len) {
        UBYTE c = s[j];
        if ((UBYTE)(c - 32) >= 95 && c < 160) break;
        j++;
    }
    return j;
}

/* returns the index of the first byte E must handle (len = all done) */
LONG frun(struct fx *x, const UBYTE *s, LONG i, LONG len)
{
    struct con *k = *x->curcon;
    LONG c, j;
    while (i < len) {
        c = s[i];
        if ((c >= 32 && c <= 126) || c >= 160) {
            j = prscan(s, i + 1, len);
            putrun(x, k, s + i, j - i);
            i = j;
        } else if (c == 10) {
            if (*x->alteat) { *x->alteat = FALSE; i++; }
            j = i;
            while (j < len && s[j] == 10) j++;
            if (j > i) lfrun(x, k, j - i);
            i = j;
        } else if (c == 13) {
            k->cx = 0;
            i++;
        } else if (c == 27) {
            LONG par[4], np = 0, fin;
            j = i + 1;
            if (j >= len || s[j] != '[') return i;
            j++;
            par[0] = par[1] = par[2] = par[3] = 0;
            for (;;) {
                if (j >= len) return i;          /* split: E keeps state */
                c = s[j];
                if (c >= '0' && c <= '9') {
                    par[np] = par[np] * 10 + (c - 48);
                    if (par[np] > 999) par[np] = 999;
                } else if (c == ';') {
                    np++;
                    if (np > 3) np = 3;
                    par[np] = 0;
                } else if (c >= 0x40) break;
                else return i;                   /* private / odd: E */
                j++;
            }
            fin = c;
            k->cpar[0] = par[0]; k->cpar[1] = par[1];  /* csistart + the */
            k->cpar[2] = par[2]; k->cpar[3] = par[3];  /* parse, as E    */
            k->cnp = np;                               /* leaves them    */
            k->cpriv = FALSE;
            if (fin == 'm') {
                sgr(k, par, np);
            } else if (fin == 'H' || fin == 'f') {
                k->jslk = FALSE;
                k->cy = par[0] - 1;
                if (k->cy < 0) k->cy = 0;
                if (k->cy >= k->rows) k->cy = k->rows - 1;
                k->cx = par[1] - 1;
                if (k->cx < 0) k->cx = 0;
                if (k->cx > k->cols) k->cx = k->cols;
            } else if (fin == 'K') {
                k->jslk = FALSE;
                eraseeol(x, k);
            } else if (fin == 'J') {
                k->jslk = FALSE;
                erasebelow(x, k);
            } else if (fin == 'L' || fin == 'M' || fin == 'S' || fin == 'T'
                    || fin == '@' || fin == 'P') {
                LONG n = par[0];
                k->jslk = FALSE;
                if (fin == 'L') inslines(x, k, n);
                else if (fin == 'M') dellines(x, k, n);
                else if (fin == 'S') scrollup(x, k, n);
                else if (fin == 'T') scrolldown(x, k, n);
                else if (fin == '@') inschars(x, k, n);
                else delchars(x, k, n);
            } else if (fin >= 'A' && fin <= 'D') {
                LONG n = par[0];
                k->jslk = FALSE;
                if (n < 1) n = 1;
                if (fin == 'A') { k->cy -= n; if (k->cy < 0) k->cy = 0; }
                else if (fin == 'B') { k->cy += n; if (k->cy >= k->rows) k->cy = k->rows - 1; }
                else if (fin == 'C') { k->cx += n; if (k->cx > k->cols) k->cx = k->cols; }
                else { k->cx -= n; if (k->cx < 0) k->cx = 0; }
            } else return i;
            i = j + 1;
        } else if (c == 8) {
            if (k->cx > 0) k->cx--;
            i++;
        } else if (c == 9) {
            *x->alteat = FALSE;
            do dfputc(x, k, 32); while ((k->cx & 7) != 0 && k->cx < k->cols);
            i++;
        } else if (c == 12) {
            LONG r;
            k->vblank = TRUE;
            k->jslk = FALSE;
            k->jburst = 0;
            *x->alteat = FALSE;
            for (r = 0; r <= k->rows - 1; r++) clearrow(k, r);
            k->cx = 0;
            k->cy = 0;
            *x->dffull = TRUE;
            *x->dfpend = 0;
            *x->dfnarrow = TRUE;
            i++;
        } else if (c == 0x9B || c == 0x9D) {
            return i;
        } else {
            i++;                                 /* other controls: dropped */
        }
    }
    return i;
}

/* ---------- the planar painter (1.2.8b9) ----------
   Model rows straight into the bitplanes of a standard planar bitmap,
   for 8-pixel-wide fonts. On a stock A1200 every chip access costs about
   1.4us against the 16-colour Hires display, so this is written for
   access count: glyph lines are read four at a time as longs and
   transposed in registers, each output long is written once per plane,
   and a uniform-colour group costs no colour reads at all. Text() at the
   same job: a call per colour run, a template build and a blit per plane.

   The glyph cache (gshift) is pre-shifted for the window's bit phase s:
   per char a "hi" block (glyph >> s) and a "lo" block (glyph << 8-s), so
   output byte J = hi(cell J) | lo(cell J-1) and no carry runs between
   output longs. Pens: cell bit -> plane bit p of fg (1) or bg (0):
   v = (bits AND (fg^bg)) XOR bg, per plane, as 0/-1 masks.
   dpcells' rules for the pens (attr 0 + no style = 0 on 0; inverse
   swaps, fg = bg inverse takes deffg). */

struct pctx {
    const UBYTE *gl;        /* shifted cache, 256 chars x (2 * cs) bytes */
    LONG cs;                /* lines per block, a multiple of 4 */
    LONG ch;                /* cell height */
    LONG s;                 /* bit phase of grid column 0, 0..7 */
    LONG xb;                /* byte of grid column 0 within a line */
    UBYTE *pl[8];           /* each plane at grid row 0, line 0, byte 0 */
    LONG bpr;               /* bytes per line */
    LONG depth;
    UBYTE *sty;             /* per row: 1 = italic/underline cells (Text redraws) */
    ULONG *tmp;             /* scratch: 16K, see TMP_* */
};

/* build the shifted cache from the plain one (256 x ch bytes) */
void gshift(UBYTE *dst, const UBYTE *src, LONG ch, LONG cs, LONG s)
{
    LONG c, y;
    for (c = 0; c < 256; c++) {
        UBYTE *h = dst + c * 2 * cs, *l = h + cs;
        for (y = 0; y < cs; y++) {
            ULONG g = y < ch ? src[(c < 32 ? 32 : c) * ch + y] : 0;
            h[y] = g >> s;
            l[y] = s ? (g << (8 - s)) & 0xFF : 0;
        }
    }
}

/* the asm inner loops (pgroups.s) */
struct seg { LONG n; ULONG a, x, e; };
extern void ptrans(const UBYTE *c0m1, LONG ng, ULONG *comb, LONG ch, LONG cs,
                   const UBYTE *gl, LONG shift);
extern void pplane(ULONG *comb, LONG ng, LONG ch, struct seg *sg, UBYTE *dst, LONG bpr);

/* scratch layout in pctx->tmp (16K) */
#define TMP_CH   0          /* the row's chars, attrs, styles: 4 pad */
#define TMP_AT   272        /* bytes before cell 0, 8 after the last */
#define TMP_ST   544
#define TMP_CSEG 816        /* colour segments */
#define TMP_PSEG 2304       /* one plane's segments */
#define TMP_COMB 4096       /* the transposed glyph lines */
#define TMP_TN   12800      /* pfused's pens tables (256 words each), */
#define TMP_TI   13312      /* built for the deffg in TMP_TKEY */
#define TMP_TKEY 13824

struct pf {
    const UBYTE **gp; LONG ng, ch; const UBYTE *pa; LONG bpr; ULONG ef, el; LONG uni5;
    ULONG own[5]; const WORD *tn, *ti; LONG k; ULONG e; LONG key, yy;
    struct { UBYTE *dst; LONG pbit; ULONG a, x; } pt[8]; LONG end;
};
extern void pfused(struct pf *f);
extern void pfused1(struct pf *f);

/* a run of groups painted alike: uniform (one attr/style for every
   bit) or a single mixed group (owners c0-1..c0+3 listed) */
struct cseg { LONG n; ULONG e; UBYTE mixed, pad; UBYTE at[5], st[5]; };

/* the pens of one cell (dpcells' rules): fg^bg in fx, bg in fb */
static void cpen(struct con *k, LONG at, LONG st, LONG *fx, LONG *fb)
{
    LONG fg = at & 15, bg = (at >> 4) & 7;
    if (st & 4) {
        LONG t;
        if (fg == bg) fg = k->deffg;
        t = fg; fg = bg; bg = t;
    }
    *fx = fg ^ bg;
    *fb = bg;
}

static LONG prow(struct pctx *pc, struct con *k, LONG mask, LONG r, LONG x0, LONG x1)
{
    LONG n, i, styled = 0, cs = pc->cs, ch = pc->ch, s = pc->s, bpr = pc->bpr;
    LONG B0, B1, q0, q1, J0, ng, g, p, off, ncs, shift;
    UBYTE *tc = (UBYTE *)pc->tmp + TMP_CH, *ta = (UBYTE *)pc->tmp + TMP_AT,
          *ts = (UBYTE *)pc->tmp + TMP_ST;
    struct cseg *cg = (struct cseg *)((UBYTE *)pc->tmp + TMP_CSEG);
    struct seg *sg = (struct seg *)((UBYTE *)pc->tmp + TMP_PSEG);
    ULONG *comb = (ULONG *)((UBYTE *)pc->tmp + TMP_COMB);
    ULONG own[5], ef, el, mh, ml, sor = 0;
    if (x0 < 0) x0 = 0;
    if (x1 > k->cols - 1) x1 = k->cols - 1;
    if (x0 > x1) return 0;
    n = x1 - x0 + 1;
    off = ringidx(k, r) * k->cols + x0;
    /* padded copies: cells -4 .. n+7, zeros outside the span */
    *(ULONG *)tc = 0; *(ULONG *)ta = 0; *(ULONG *)ts = 0;
    bcopy(tc + 4, (const UBYTE *)k->sb + off, n);
    bcopy(ta + 4, (const UBYTE *)k->sa + off, n);
    bcopy(ts + 4, (const UBYTE *)k->ss + off, n);
    {   /* the 8 pad bytes after the span, as unaligned long stores */
        ULONG *z;
        z = (ULONG *)(tc + 4 + n); z[0] = 0; z[1] = 0;
        z = (ULONG *)(ta + 4 + n); z[0] = 0; z[1] = 0;
        z = (ULONG *)(ts + 4 + n); z[0] = 0; z[1] = 0;
    }
    for (i = 0; i < n + 4; i += 4) sor |= *(ULONG *)(ts + 4 + i);
    if (sor & 0x0B0B0B0B) styled = 1;      /* italic, underline, bold: Text */
    J0 = pc->xb + x0;
    B0 = J0 * 8 + s;
    B1 = B0 + n * 8;
    q0 = B0 >> 5;
    q1 = (B1 - 1) >> 5;
    ng = q1 - q0 + 1;
    ef = 0xFFFFFFFF >> (B0 - 32 * q0);
    el = (B1 - 32 * q1) >= 32 ? 0xFFFFFFFF : ~(0xFFFFFFFF >> (B1 - 32 * q1));
    mh = 0xFF >> s;
    ml = ~mh & 0xFF;
    for (i = 0; i < 5; i++) {
        ULONG o = 0;
        if (i >= 1) o |= mh << ((4 - i) * 8);    /* hi bits: byte i-1 */
        if (i <= 3) o |= ml << ((3 - i) * 8);    /* lo bits: byte i */
        own[i] = o;
    }
    if (cs == 8) {
        /* cells up to 8 lines: one fused pass (pgroups.s) */
        struct pf f;
        WORD *tn = (WORD *)((UBYTE *)pc->tmp + TMP_TN), *ti = (WORD *)((UBYTE *)pc->tmp + TMP_TI);
        LONG *tkey = (LONG *)((UBYTE *)pc->tmp + TMP_TKEY), np = 0;
        if (*tkey != k->deffg + 0x10000) {
            for (i = 0; i < 256; i++) {
                LONG fx, fb;
                cpen(k, i, 0, &fx, &fb);
                tn[i] = (fx << 8) | fb;
                cpen(k, i, 4, &fx, &fb);
                ti[i] = (fx << 8) | fb;
            }
            *tkey = k->deffg + 0x10000;
        }
        const UBYTE **gp = (const UBYTE **)((UBYTE *)pc->tmp + TMP_PSEG);  /* gp[i+4]: cell i */
        const UBYTE *gl = pc->gl, *mc = (const UBYTE *)k->sb + off;
        for (i = 0; i < 4; i++) { gp[i] = gl; gp[n + 4 + i] = gl; gp[n + 8 + i] = gl; }
        for (i = 0; i < n; i++) gp[i + 4] = gl + (mc[i] << 4);
        f.gp = gp + 4 + 4 * q0 - J0 - 1;
        f.pa = ta + 4 + 4 * q0 - J0 - 1;
        f.ng = ng; f.ch = ch; f.bpr = bpr; f.ef = ef; f.el = el;
        f.uni5 = s;
        for (i = 0; i < 5; i++) f.own[i] = own[i];
        f.tn = tn; f.ti = ti;
        for (p = 0; p < pc->depth; p++) {
            if (!((mask >> p) & 1)) continue;
            f.pt[np].dst = pc->pl[p] + r * ch * bpr + q0 * 4;
            f.pt[np].pbit = p;
            np++;
        }
        f.pt[np].dst = 0;
        if (np == 1) pfused1(&f);         /* one plane: everything in registers */
        else if (np) pfused(&f);
        return styled;
    }
    /* the colour segments, once for every plane */
    ncs = 0;
    for (g = 0; g < ng; g++) {
        LONG p0 = 4 * (q0 + g) - J0 + 3;         /* padded index of c0-1 */
        ULONG A4 = *(const ULONG *)(ta + p0 + 1), S4 = *(const ULONG *)(ts + p0 + 1);
        ULONG a1 = A4 >> 24, s1 = S4 >> 24, e = 0xFFFFFFFF;
        LONG uni = A4 == a1 * 0x01010101 && S4 == s1 * 0x01010101
                && (!s || (ta[p0] == a1 && ts[p0] == s1));
        if (g == 0) e &= ef;
        if (g == ng - 1) e &= el;
        if (uni && e == 0xFFFFFFFF && ncs > 0 && !cg[ncs - 1].mixed
            && cg[ncs - 1].e == 0xFFFFFFFF && cg[ncs - 1].at[0] == a1 && cg[ncs - 1].st[0] == s1) {
            cg[ncs - 1].n++;
            continue;
        }
        cg[ncs].n = 1;
        cg[ncs].e = e;
        cg[ncs].mixed = !uni;
        if (uni) { cg[ncs].at[0] = a1; cg[ncs].st[0] = s1; }
        else for (i = 0; i < 5; i++) { cg[ncs].at[i] = ta[p0 + i]; cg[ncs].st[i] = ts[p0 + i]; }
        ncs++;
    }
    shift = cs == 8 ? 4 : cs == 16 ? 5 : 6;
#ifndef SKIP_TRANS
    ptrans(tc + 4 + 4 * q0 - J0 - 1, ng, comb, ch, cs, pc->gl, shift);
#endif
    for (p = 0; p < pc->depth; p++) {
        LONG ns = 0, c;
        if (!((mask >> p) & 1)) continue;
        for (c = 0; c < ncs; c++) {
            ULONG a = 0, x = 0;
            LONG fx, fb;
            if (!cg[c].mixed) {
                cpen(k, cg[c].at[0], cg[c].st[0], &fx, &fb);
                a = ((fx >> p) & 1) ? 0xFFFFFFFF : 0;
                x = ((fb >> p) & 1) ? 0xFFFFFFFF : 0;
            } else {
                for (i = 0; i < 5; i++) {
                    cpen(k, cg[c].at[i], cg[c].st[i], &fx, &fb);
                    if ((fx >> p) & 1) a |= own[i];
                    if ((fb >> p) & 1) x |= own[i];
                }
            }
            if (ns > 0 && cg[c].e == 0xFFFFFFFF && sg[ns - 1].e == 0xFFFFFFFF
                && sg[ns - 1].a == a && sg[ns - 1].x == x) {
                sg[ns - 1].n += cg[c].n;
            } else {
                sg[ns].n = cg[c].n; sg[ns].a = a; sg[ns].x = x; sg[ns].e = cg[c].e;
                ns++;
            }
        }
        sg[ns].n = 0;
#ifndef SKIP_PLANE
        pplane(comb, ng, ch, sg, pc->pl[p] + r * ch * bpr + q0 * 4, bpr);
#endif
    }
    return styled;
}

/* dpplanar's row loop: every row in full (all = 2) or the dirty spans */
LONG ppaint(struct pctx *pc, struct fx *x, LONG all)
{
    struct con *k = *x->curcon;
    LONG r, r0, r1, styled = 0, sty, mask;
    mask = k->mmask & ((1 << pc->depth) - 1);
    if (all == 2) { r0 = 0; r1 = k->rows - 1; }
    else {
        r0 = *x->dflo < 0 ? 0 : *x->dflo;
        r1 = *x->dfhi > k->rows - 1 ? k->rows - 1 : *x->dfhi;
    }
    for (r = r0; r <= r1; r++) {
        sty = 0;
        if (all == 2) sty = prow(pc, k, mask, r, 0, k->cols - 1);
        else if ((*x->dfd)[r] == (UBYTE)*x->dfgen)
            sty = prow(pc, k, mask, r, (*x->dfx0)[r], (*x->dfx1)[r]);
        pc->sty[r] = sty;
        if (sty) styled = 1;
    }
    return styled;
}

/* ---------- the write packet, accepted (1.2.8b9) ----------
   dopkt's ACTION_WRITE + dowrite's write-behind accept for the case
   nearly every packet is: a known console, window up, nothing to reset
   (no selection, search, scrolled view or completion menu - so
   acceptreset would do nothing), nobody reading, and room in the
   buffer. Copy, take the break owner, reply. Returns 0 = not that case
   (E does it all, unchanged), 1 = done, 2 = done and the flush timer
   still needs arming (armflush). On a stock 020 the E path was ~0.7ms a
   packet, ~6s of conbench. */

#define WOBSZ 16384

struct dpkt { void *link; void *port; LONG type, res1, res2, arg1, arg2, arg3; };

static void putmsg(void *sys, void *port, void *msg)
{
    register void *a0 __asm__("a0") = port;
    register void *a1 __asm__("a1") = msg;
    register void *a6 __asm__("a6") = sys;
    __asm__ volatile ("jsr -366(%%a6)" : "+r"(a0), "+r"(a1), "+r"(a6) : : "d0", "d1", "memory", "cc");
}

LONG wacc(struct fx *x, struct dpkt *pkt)
{
    struct con *k = (struct con *)pkt->arg1, *c;
    LONG len = pkt->arg3;
    void *rport;
    for (c = (struct con *)*x->conlist; c; c = (struct con *)c->next)
        if (c == k) break;
    if (!c) return 0;
    if (k->selon || k->appicon || !k->win || !k->wob || k->sbsrch || k->sello >= 0
        || k->viewoff != 0 || k->tcactive || k->rdn > 0 || k->wcn > 0) return 0;
    if (len < 0 || k->wolen + len > WOBSZ) return 0;
    *x->curcon = k;
    k->breaktask = ((LONG *)pkt->port)[4];          /* mp_SigTask */
    bcopy((UBYTE *)k->wob + k->wolen, (const UBYTE *)pkt->arg2, len);
    k->wolen += len;
    k->jwrote = TRUE;
    rport = pkt->port;                              /* ReplyPkt(pkt, len, 0) */
    pkt->res1 = len;
    pkt->res2 = 0;
    pkt->port = x->port;
    putmsg(x->sysbase, rport, pkt->link);
    return *x->flusharmed ? 1 : 2;
}

/* ---------- dfflush, for the planar painter (1.2.8b9) ----------
   The E proc's planar-painter case without the E around it: on a stock
   020 dfflush + dfspans + dpplanar + ppsetup cost ~2.5ms of E per flush,
   which a per-line barrier (conbench sync-line) pays per line.
   Returns -1 = not handled (the layer is covered or split: E runs its
   own dfflush, nothing was done), else flags for E: 1 = styled rows to
   Text (bookkeeping NOT done - E finishes it), 2 = narrow the mask
   (maskscan), 4 = it was the full rebuild. */

static void gcall_lock(void *gfx, void *ly, LONG unlock)
{
    /* the layer rides in A5 - gcc's fixed PIC register under -mpcrel,
       which it neither allocates nor saves: an "a5" register variable
       silently clobbered E's frame pointer (the first build hung the
       machine). So A5 is saved and set by hand, around the call only. */
    register void *a6 __asm__("a6") = gfx;
    if (unlock)
        __asm__ volatile ("move.l %%a5,-(%%sp)\n\tmove.l %1,%%a5\n\tjsr -438(%%a6)\n\tmove.l (%%sp)+,%%a5"
                          : "+r"(a6) : "d"(ly) : "d0", "d1", "a0", "a1", "memory", "cc");
    else
        __asm__ volatile ("move.l %%a5,-(%%sp)\n\tmove.l %1,%%a5\n\tjsr -432(%%a6)\n\tmove.l (%%sp)+,%%a5"
                          : "+r"(a6) : "d"(ly) : "d0", "d1", "a0", "a1", "memory", "cc");
}

static void gscroll(void *gfx, void *rp, LONG dy, LONG x0, LONG y0, LONG x1, LONG y1)
{
    register void *a1 __asm__("a1") = rp;
    register LONG d0 __asm__("d0") = 0;
    register LONG d1 __asm__("d1") = dy;
    register LONG d2 __asm__("d2") = x0;
    register LONG d3 __asm__("d3") = y0;
    register LONG d4 __asm__("d4") = x1;
    register LONG d5 __asm__("d5") = y1;
    register void *a6 __asm__("a6") = gfx;
    __asm__ volatile ("jsr -396(%%a6)" : "+r"(a1), "+r"(d0), "+r"(d1), "+r"(a6)
                      : "r"(d2), "r"(d3), "r"(d4), "r"(d5) : "a0", "memory", "cc");
}

static void gwaitblit(void *gfx)
{
    register void *a6 __asm__("a6") = gfx;
    __asm__ volatile ("jsr -228(%%a6)" : "+r"(a6) : : "d0", "d1", "a0", "a1", "memory", "cc");
}

/* vblankscan */
static void vblankscan(struct con *k)
{
    LONG r, i;
    if (!k->sb) return;
    if (k->viewoff > 0) { k->vblank = FALSE; return; }
    for (r = 0; r < k->rows; r++) {
        const UBYTE *m = (const UBYTE *)k->sb + ringidx(k, r) * k->cols;
        for (i = 0; i < k->cols; i++)
            if (m[i]) { k->vblank = FALSE; return; }
    }
    k->vblank = TRUE;
}

LONG cflush(struct fx *x, struct pctx *pc)
{
    struct con *k = *x->curcon;
    UBYTE *rp = (UBYTE *)k->rp, *win = (UBYTE *)k->win;
    UBYTE *ly = *(UBYTE **)rp, *cr;                      /* rp_Layer */
    LONG res = 0, sty, r;
    void *gfx = x->gfxbase;
    if (!*x->dfon) return 0;
    if (!ly) return -1;
    gwaitblit(gfx);                                     /* a queued scroll lands first */
    gcall_lock(gfx, ly, 0);
    cr = *(UBYTE **)(ly + 8);
    if (!cr || *(UBYTE **)cr || *(LONG *)(cr + 8)
        || *(LONG *)(cr + 16) != *(LONG *)(ly + 16) || *(LONG *)(cr + 20) != *(LONG *)(ly + 20)
        || *(LONG *)(ly + 32)) {
        gcall_lock(gfx, ly, 1);
        return -1;
    }
    if (*x->dffull && *x->dfvb && k->vblank) {
        *x->dffull = FALSE;
        if (*x->dfnarrow) { res |= 2; *x->dfnarrow = FALSE; }
    } else if (*x->dffull) {
        sty = ppaint(pc, x, 2);
        vblankscan(k);
        *x->dffull = FALSE;
        if (*x->dfnarrow) { res |= 2; *x->dfnarrow = FALSE; }
        if (sty) res |= 1 | 4;
    } else {
        if (*x->dfpend > 0 && !k->vblank) {
            WORD w = *(WORD *)(win + 8), h = *(WORD *)(win + 10);
            gscroll(gfx, rp, *x->dfpend * k->ch, win[54], win[55], w - win[56] - 1, h - win[57] - 1);
            gwaitblit(gfx);
        }
        *x->dfpend = 0;
        if (*x->dfhi >= *x->dflo && ppaint(pc, x, FALSE)) res |= 1;
    }
    gcall_lock(gfx, ly, 1);
    if (res & 1) return res;                            /* E Texts the styled rows */
    (*x->dfgen)++;
    if (*x->dfgen > 255) {
        for (r = 0; r < 512; r++) x->dfdb[r] = 0;
        *x->dfgen = 1;
    }
    *x->dflo = k->rows;
    *x->dfhi = -1;
    *x->dflost = 0;
    *x->dfvb = k->vblank;
    return res;
}

/* ---------- flushout, whole (1.2.8b9) ----------
   flushout -> dorender -> render -> dfflush for the case nearly every
   flush is: a cooked console at rest-but-for-output (no read parked,
   nothing typed, no search or paste hint, the blip deferred), window up,
   live view, the planar painter's pctx current for it (ppsetup's key).
   Every condition is checked before anything moves; then dfstart, the
   mask bracket, frun, cflush and the epilogue, statement for statement.
   0 = not that case (E does it all, nothing done here); 1 = done;
   2 = render stopped at *fxret (a byte frun hands back, or cflush could
   not paint): E's cfresume carries on from there; 4 = cflush painted and
   left flags *fxret for E (styled rows, narrowing): cfresume finishes. */

static LONG cfout(struct fx *x, struct pctx *pc, struct con *c)
{
    struct con *old = *x->curcon;
    UBYTE *rp = (UBYTE *)c->rp, *ly, *eb = (UBYTE *)c->ebuf;
    LONG *pk = x->pkey, i, r;
    if (c->wolen <= 0 || !c->win || c->viewoff || c->rawmode || c->rdn > 0
        || c->srch || c->pasteq || c->edlast || (eb && eb[0]) || c->edext
        || !c->sb || c->rows > DFROWS || c->cursoft || !c->dpok
        || c->mfloor == 0xFF || c->cw != 8 || !rp) return 0;
    ly = *(UBYTE **)rp;
    if (!ly) return 0;
    if (pk[0] != *(LONG *)(rp + 4) || pk[1] != *(WORD *)(ly + 16) + c->left
        || pk[2] != *(WORD *)(ly + 18) + c->topy || pk[3] != c->ch
        || pk[4] != *x->dgtf || pk[5] != *x->gsh) return 0;
    *x->fxold = (LONG)old;
    *x->curcon = c;
    /* dfstart */
    *x->dfon = TRUE;
    *x->dfpend = 0;
    *x->dffull = FALSE;
    *x->dfnarrow = FALSE;
    (*x->dfgen)++;
    if (*x->dfgen > 255) {
        for (i = 0; i < 512; i++) x->dfdb[i] = 0;
        *x->dfgen = 1;
    }
    *x->dflo = c->rows;
    *x->dfhi = -1;
    *x->dflost = 0;
    *x->dfvb = c->vblank;
    *x->maskon = TRUE;
    rp[24] = c->mmask;
    i = frun(x, (const UBYTE *)c->wob, 0, c->wolen);
    if (i < c->wolen) { *x->fxret = i; return 2; }
    r = cflush(x, pc);
    if (r < 0) { *x->fxret = c->wolen; return 2; }
    if (r) { *x->fxret = r; return 4; }
    *x->dfon = FALSE;                                   /* render's epilogue */
    *x->alteat = FALSE;
    *x->maskon = FALSE;
    rp[24] = 0xFF;
    c->ancx = c->cx;                                    /* reanchor */
    c->ancy = c->cy;
    c->blipdefer = TRUE;
    c->wolen = 0;
    *x->curcon = old;
    return 1;
}

LONG cfout_e(struct fx *x, struct pctx *pc, struct con *c) { return cfout(x, pc, c); }

/* ACTION_WAIT_CHAR: conbysender's first two lookups, the flush, and the
   no-wait answers. 0 = E does it all; 1 = replied; 2/4 = flushed partly,
   E resumes (cfresume) then runs its own WAIT_CHAR from the top (its
   flushout is then a no-op); 3 = flushed, E runs its WAIT_CHAR (a timed
   wait to park, or a window to open) */
#define INQMAX 2048
LONG wchar(struct fx *x, struct pctx *pc, struct dpkt *pkt)
{
    struct con *c = 0, *p;
    UBYTE *t = 0;
    LONG r;
    if (pkt->port) t = ((UBYTE **)pkt->port)[4];          /* mp_SigTask */
    if (!t) return 0;
    if (t[8] == 13) {                                     /* NT_PROCESS */
        LONG cli = *(LONG *)(t + 172);                    /* pr_CLI */
        if (cli) {
            LONG si = *(LONG *)((cli << 2) + 28);         /* cli_StandardInput */
            if (si) {
                LONG a = *(LONG *)((si << 2) + 36);       /* fh_Args */
                for (p = (struct con *)*x->conlist; p; p = (struct con *)p->next)
                    if ((LONG)p == a) { c = p; break; }
            }
        }
    }
    if (!c)
        for (p = (struct con *)*x->conlist; p; p = (struct con *)p->next)
            if (p->breaktask == (LONG)t) { c = p; break; }
    if (!c) return 0;
    if (c->wolen > 0) {
        r = cfout(x, pc, c);
        if (!r) return 0;
        if (r >= 2) return r;
    }
    if (!c->win || pkt->arg1 > 0) return 3;
    *x->curcon = c;
    c->bliptick = TRUE;
    if (c->jauto && c->jburst > 0) {
        c->jsync++;
        if (c->jsync >= 4) c->jeff = c->rows - 1 > 1 ? c->rows - 1 : 1;
    }
    pkt->res1 = ((c->inqt - c->inqh + INQMAX) & (INQMAX - 1)) > 0 ? -1 : 0;
    pkt->res2 = 0;
    {
        void *rport = pkt->port;
        pkt->port = x->port;
        putmsg(x->sysbase, rport, pkt->link);
    }
    return 1;
}

/* ---------- the packet port, drained (1.2.8b9) ----------
   The main loop's GetMsg/dopkt pass for the packet the port holds most:
   ACTION_WRITE goes through wacc (and armflush's SendIO when the flush
   timer is idle) without coming back to E. Returns the first message it
   does not take - E's dopkt gets it - or 0 when the port is empty. */

static void *getmsg(void *sys, void *port)
{
    register void *a0 __asm__("a0") = port;
    register void *a6 __asm__("a6") = sys;
    register void *d0 __asm__("d0");
    __asm__ volatile ("jsr -372(%%a6)" : "=r"(d0), "+r"(a0), "+r"(a6) : : "d1", "a1", "memory", "cc");
    return d0;
}

static void sendio(void *sys, void *io)
{
    register void *a1 __asm__("a1") = io;
    register void *a6 __asm__("a6") = sys;
    __asm__ volatile ("jsr -462(%%a6)" : "+r"(a1), "+r"(a6) : : "d0", "d1", "a0", "memory", "cc");
}

void *drain(struct fx *x)
{
    for (;;) {
        UBYTE *msg = getmsg(x->sysbase, x->port);
        struct dpkt *pkt;
        LONG r;
        if (!msg) return 0;
        pkt = *(struct dpkt **)(msg + 10);              /* ln_Name */
        if (pkt->type != 8) return msg;                 /* ACTION_WRITE */
        r = wacc(x, pkt);
        if (!r) return msg;
        if (r == 2) {                                   /* armflush */
            UBYTE *io = x->ftreq;
            *(WORD *)(io + 28) = 9;                     /* TR_ADDREQUEST */
            *(LONG *)(io + 32) = 0;                     /* secs */
            *(LONG *)(io + 36) = *x->fdelay;            /* micro */
            sendio(x->sysbase, io);
            *x->flusharmed = TRUE;
        }
    }
}

/* the layout check: the handler fills a scratch console with known
   values and asks for this sum; a mismatch keeps the engine off */
LONG fcheck(struct con *k)
{
    return k->cx + k->sb * 3 + k->mmask * 5 + k->vblank * 7 + k->osct[83] * 11
         + k->cursty * 13 + k->anstab[7] * 17 + k->jslk * 19;
}
