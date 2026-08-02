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
    for (i = 0; i < got; i++) {
        if (raw[i] == '\n' || raw[i] == '\r') {
            if (!addline(b, raw + start, (int)(i - start))) {
                buffree(b);
                return 0;
            }
            if (raw[i] == '\r' && i + 1 < got && raw[i + 1] == '\n') i++;
            start = i + 1;
        }
    }
    if (start < got && !addline(b, raw + start, (int)(got - start))) {
        buffree(b);
        return 0;
    }
    if (b->n == 0 && !addline(b, "", 0)) {
        buffree(b);
        return 0;
    }
    return 1;
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
