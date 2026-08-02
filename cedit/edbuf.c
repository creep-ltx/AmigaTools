/* edbuf - cedit's text buffer. Pure logic; see edbuf.h. */
#include <stdlib.h>
#include <string.h>
#include "edbuf.h"

void bufinit(Buffer *b)
{
    memset(b, 0, sizeof(*b));
    b->maxwdirty = 1;
}

void buffree(Buffer *b)
{
    int i;
    for (i = 0; i < b->n; i++) free(b->ln[i]);
    free(b->ln);
    free(b->len);
    free(b->cap);
    free(b->lex);
    bufinit(b);
}

/* Each array is grown into a TEMPORARY first and only committed once
 * it succeeded, so a failure partway leaves the buffer usable rather
 * than with three arrays of one size and one of another. */
int edensure(Buffer *b, int need)
{
    int nt;
    char **nl;
    int *nlen, *ncap;
    unsigned char *nlex;
    if (need <= b->tab) return 1;
    nt = b->tab ? b->tab : 256;
    while (nt < need) nt *= 2;
    nl = realloc(b->ln, nt * sizeof(char *));
    if (nl == NULL) return 0;
    b->ln = nl;
    nlen = realloc(b->len, nt * sizeof(int));
    if (nlen == NULL) return 0;
    b->len = nlen;
    ncap = realloc(b->cap, nt * sizeof(int));
    if (ncap == NULL) return 0;
    b->cap = ncap;
    nlex = realloc(b->lex, nt * sizeof(unsigned char));
    if (nlex == NULL) return 0;
    b->lex = nlex;
    b->tab = nt;
    return 1;
}

int edgrow(Buffer *b, int i, int need)
{
    int nc = b->cap[i] ? b->cap[i] : 32;
    char *p;
    need++;                             /* the NUL */
    if (need <= b->cap[i]) return 1;
    while (nc < need) nc *= 2;
    p = realloc(b->ln[i], nc);
    if (p == NULL) return 0;
    b->ln[i] = p;
    b->cap[i] = nc;
    return 1;
}

int addline(Buffer *b, const char *s, int len)
{
    if (!edensure(b, b->n + 1)) return 0;
    b->ln[b->n] = NULL;
    b->cap[b->n] = 0;
    if (!edgrow(b, b->n, len)) return 0;
    if (len) memcpy(b->ln[b->n], s, len);
    b->ln[b->n][len] = 0;
    b->len[b->n] = len;
    b->lex[b->n] = 0;
    b->n++;
    b->maxwdirty = 1;
    return 1;
}

int bufsplit(Buffer *b, const char *raw, long got)
{
    long i, start = 0;
    int seen = 0;
    b->eol = EOL_LF;
    b->noeol = 0;
    for (i = 0; i < got; i++) {
        if (raw[i] == '\n' || raw[i] == '\r') {
            if (!addline(b, raw + start, (int)(i - start))) {
                buffree(b);
                return 0;
            }
            /* the FIRST ending decides the file's style. A mixed file
             * has no honest answer, and picking the first one at
             * least keeps whatever the file mostly is. */
            if (!seen) {
                seen = 1;
                if (raw[i] == '\r')
                    b->eol = (i + 1 < got && raw[i + 1] == '\n')
                                 ? EOL_CRLF : EOL_CR;
            }
            if (raw[i] == '\r' && i + 1 < got && raw[i + 1] == '\n') i++;
            start = i + 1;
        }
    }
    if (start < got) {
        if (!addline(b, raw + start, (int)(got - start))) {
            buffree(b);
            return 0;
        }
        b->noeol = 1;           /* and saving must not add one */
    }
    if (b->n == 0) {
        /* an empty file still gets one empty line - a buffer with no
         * lines has no cursor position to be in - but that line is
         * synthetic, so it carries no terminator either. Saving an
         * untouched empty file must leave it empty, not one byte. */
        if (!addline(b, "", 0)) {
            buffree(b);
            return 0;
        }
        b->noeol = 1;
    }
    return 1;
}

/* ---- editing ----------------------------------------------------- */

int edinsch(Buffer *b, int y, int x, char c)
{
    int n = b->len[y];
    if (!edgrow(b, y, n + 1)) return 0;
    memmove(b->ln[y] + x + 1, b->ln[y] + x, n - x + 1);   /* with NUL */
    b->ln[y][x] = c;
    b->len[y] = n + 1;
    b->dirty = 1;
    b->maxwdirty = 1;
    return 1;
}

void eddelch(Buffer *b, int y, int x)
{
    int n = b->len[y];
    if (x >= n) return;
    memmove(b->ln[y] + x, b->ln[y] + x + 1, n - x);       /* with NUL */
    b->len[y] = n - 1;
    b->dirty = 1;
    b->maxwdirty = 1;
}

/* make room for one more line at index y, shifting the rest down.
 * The four arrays move together or not at all. */
static int rowopen(Buffer *b, int y)
{
    int i;
    if (!edensure(b, b->n + 1)) return 0;
    for (i = b->n; i > y; i--) {
        b->ln[i]  = b->ln[i - 1];
        b->len[i] = b->len[i - 1];
        b->cap[i] = b->cap[i - 1];
        b->lex[i] = b->lex[i - 1];
    }
    b->ln[y] = NULL;
    b->len[y] = 0;
    b->cap[y] = 0;
    b->lex[y] = 0;
    b->n++;
    return 1;
}

/* drop line y, freeing it, and close the gap */
static void rowclose(Buffer *b, int y)
{
    int i;
    free(b->ln[y]);
    for (i = y; i < b->n - 1; i++) {
        b->ln[i]  = b->ln[i + 1];
        b->len[i] = b->len[i + 1];
        b->cap[i] = b->cap[i + 1];
        b->lex[i] = b->lex[i + 1];
    }
    b->n--;
}

int edsplitline(Buffer *b, int y, int x)
{
    int tail = b->len[y] - x;
    if (!rowopen(b, y + 1)) return 0;
    if (!edgrow(b, y + 1, tail)) {
        rowclose(b, y + 1);     /* nothing was moved into it yet */
        return 0;
    }
    memcpy(b->ln[y + 1], b->ln[y] + x, tail);
    b->ln[y + 1][tail] = 0;
    b->len[y + 1] = tail;
    b->ln[y][x] = 0;
    b->len[y] = x;
    b->dirty = 1;
    b->maxwdirty = 1;
    return 1;
}

int edjoinline(Buffer *b, int y)
{
    int a, t;
    if (y + 1 >= b->n) return 1;        /* nothing to join: not a
                                         * failure, just a no-op */
    a = b->len[y];
    t = b->len[y + 1];
    if (!edgrow(b, y, a + t)) return 0;
    memcpy(b->ln[y] + a, b->ln[y + 1], t + 1);          /* with NUL */
    b->len[y] = a + t;
    rowclose(b, y + 1);
    b->dirty = 1;
    b->maxwdirty = 1;
    return 1;
}

/* ---- saving ------------------------------------------------------ */

static int eollen(const Buffer *b)
{
    return b->eol == EOL_CRLF ? 2 : 1;
}

long bufbytes(const Buffer *b)
{
    long t = 0;
    int i, e = eollen(b);
    for (i = 0; i < b->n; i++) {
        t += b->len[i];
        if (!(i == b->n - 1 && b->noeol)) t += e;
    }
    return t;
}

long bufserialize(const Buffer *b, char *out)
{
    static const char *ends[3] = { "\n", "\r\n", "\r" };
    const char *eol = ends[b->eol];
    int i, e = eollen(b);
    long o = 0;
    for (i = 0; i < b->n; i++) {
        if (b->len[i]) {
            memcpy(out + o, b->ln[i], b->len[i]);
            o += b->len[i];
        }
        if (!(i == b->n - 1 && b->noeol)) {
            memcpy(out + o, eol, e);
            o += e;
        }
    }
    return o;
}

int explen(const char *p, int n, int tabsize, int mask)
{
    int i, o = 0;
    for (i = 0; i < n; i++) {
        if (p[i] == '\t') {
            do { o++; } while (mask ? (o & mask) : (o % tabsize));
        } else
            o++;
    }
    return o;
}

int bufmaxw(Buffer *b, int tabsize, int mask)
{
    int i, m = 0;
    if (!b->maxwdirty) return b->maxw;
    for (i = 0; i < b->n; i++) {
        int e = explen(b->ln[i], b->len[i], tabsize, mask);
        if (e > m) m = e;
    }
    b->maxw = m;
    b->maxwdirty = 0;
    return m;
}
