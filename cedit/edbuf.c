/* edbuf - cedit's text buffer. Pure logic; see edbuf.h. */
#include <stdlib.h>
#include <string.h>
#include "edbuf.h"

void bufinit(Buffer *b)
{
    memset(b, 0, sizeof(*b));
    b->maxwdirty = 1;
    b->usaved = 0;      /* a freshly loaded buffer IS its saved state */
}

void buffree(Buffer *b)
{
    int i;
    for (i = 0; i < b->n; i++) free(b->ln[i]);
    for (i = 0; i < b->nur; i++) free(b->ur[i].text);
    free(b->ur);
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
    /* the load is not an edit: every addline above ran through the
     * primitives, so clear what they recorded and call THIS the
     * saved state. Otherwise undo would walk a fresh file apart. */
    for (i = 0; i < b->nur; i++) free(b->ur[i].text);
    b->nur = b->utop = 0;
    b->usaved = 0;
    b->dirty = 0;
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

/* ---- undo -------------------------------------------------------- */

static void urfree(UndoRec *r)
{
    free(r->text);
    r->text = NULL;
}

/* throw away everything above the split point - a fresh edit means
 * the redo future never happened */
static void urclip(Buffer *b)
{
    while (b->nur > b->utop) urfree(&b->ur[--b->nur]);
    /* and a save point above the new top can never be reached again */
    if (b->usaved > b->nur) b->usaved = -1;
}

static UndoRec *urpush(Buffer *b)
{
    UndoRec *r;
    urclip(b);
    if (b->nur >= b->urcap) {
        int nc = b->urcap ? b->urcap * 2 : 64;
        UndoRec *nr;
        if (nc > UNDO_MAX) nc = UNDO_MAX;
        if (b->nur >= nc) {
            /* full: the oldest record falls off the end. The save
             * point goes with it - once the record that would undo
             * back to the saved state is gone, "unmodified" is a
             * claim we can no longer make honestly. */
            urfree(&b->ur[0]);
            memmove(b->ur, b->ur + 1, (b->nur - 1) * sizeof(UndoRec));
            b->nur--;
            b->utop--;
            if (b->usaved >= 0) b->usaved--;
        } else {
            nr = realloc(b->ur, nc * sizeof(UndoRec));
            if (nr == NULL) return NULL;
            b->ur = nr;
            b->urcap = nc;
        }
    }
    r = &b->ur[b->nur++];
    b->utop = b->nur;
    memset(r, 0, sizeof(*r));
    r->cy = b->cy;
    r->cx = b->cx;
    return r;
}

void ed_break(Buffer *b)
{
    b->ubreak = 1;
}

void ed_marksaved(Buffer *b)
{
    b->usaved = b->utop;
    b->dirty = 0;               /* THIS is now the unmodified state */
}

int ed_canundo(const Buffer *b) { return b->utop > 0; }
int ed_canredo(const Buffer *b) { return b->utop < b->nur; }

static void udirty(Buffer *b)
{
    b->dirty = (b->utop != b->usaved);
}

/* ---- editing ----------------------------------------------------- */

int edinsch(Buffer *b, int y, int x, char c)
{
    int n = b->len[y];
    if (!edgrow(b, y, n + 1)) return 0;
    memmove(b->ln[y] + x + 1, b->ln[y] + x, n - x + 1);   /* with NUL */
    b->ln[y][x] = c;
    b->len[y] = n + 1;
    b->maxwdirty = 1;
    if (!b->uapply) {
        /* coalesce a typing RUN into one record - the same instinct
         * as coalescing a held-key input burst: one undo should take
         * back a word, not a letter. The run continues only while
         * the next character lands exactly where the last one ended
         * on the same line, and the app has not broken it. */
        UndoRec *t = b->utop > 0 ? &b->ur[b->utop - 1] : NULL;
        int done = 0;
        if (t && !b->ubreak && t->op == UNDO_INS && t->y == y &&
            t->x + t->n == x && b->utop == b->nur) {
            char *nt = realloc(t->text, t->n + 2);
            if (nt) {
                t->text = nt;
                t->text[t->n++] = c;
                t->text[t->n] = 0;
                done = 1;
            }
        }
        if (!done) {
            UndoRec *r = urpush(b);
            if (r == NULL) return 0;
            r->op = UNDO_INS;
            r->y = y; r->x = x; r->n = 1;
            r->text = malloc(2);
            if (r->text == NULL) { r->n = 0; }
            else { r->text[0] = c; r->text[1] = 0; }
        }
        b->ubreak = 0;
        udirty(b);
    }
    return 1;
}

void eddelch(Buffer *b, int y, int x)
{
    int n = b->len[y];
    char gone;
    if (x >= n) return;
    gone = b->ln[y][x];
    memmove(b->ln[y] + x, b->ln[y] + x + 1, n - x);       /* with NUL */
    b->len[y] = n - 1;
    b->maxwdirty = 1;
    if (!b->uapply) {
        UndoRec *t = b->utop > 0 ? &b->ur[b->utop - 1] : NULL;
        /* two runs coalesce, and they grow the stored text at
         * opposite ends: Backspace walks LEFT (each removal is one
         * before the last), Del stays PUT (each removal is at the
         * same column). Anything else starts a new record. */
        if (t && !b->ubreak && t->op == UNDO_DEL && t->y == y &&
            b->utop == b->nur &&
            (t->x == x + 1 || t->x == x)) {
            char *nt = realloc(t->text, t->n + 2);
            if (nt) {
                t->text = nt;
                if (t->x == x + 1) {            /* Backspace */
                    memmove(t->text + 1, t->text, t->n);
                    t->text[0] = gone;
                    t->x = x;
                } else                          /* Del */
                    t->text[t->n] = gone;
                t->n++;
                t->text[t->n] = 0;
                b->ubreak = 0;
                udirty(b);
                return;
            }
        }
        {
            UndoRec *r = urpush(b);
            if (r) {
                r->op = UNDO_DEL;
                r->y = y; r->x = x; r->n = 1;
                r->text = malloc(2);
                if (r->text) { r->text[0] = gone; r->text[1] = 0; }
                else { r->n = 0; }
            }
        }
        b->ubreak = 0;
        udirty(b);
    }
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
    b->maxwdirty = 1;
    if (!b->uapply) {
        UndoRec *r = urpush(b);
        if (r == NULL) return 0;
        r->op = UNDO_SPLIT;
        r->y = y; r->x = x;
        b->ubreak = 0;
        udirty(b);
    }
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
    b->maxwdirty = 1;
    if (!b->uapply) {
        UndoRec *r = urpush(b);
        if (r == NULL) return 0;
        r->op = UNDO_JOIN;
        r->y = y; r->x = a;     /* where the seam was */
        b->ubreak = 0;
        udirty(b);
    }
    return 1;
}

/* ---- undo/redo, applied -------------------------------------------
 * Every record's inverse is one of the other three operations, run
 * through the ordinary primitives with `uapply` set so they do not
 * record what they are undoing. Nothing here reaches into the line
 * table directly, so undo can never drift from what an edit does. */

/* the four operations and their inverses, run through the ordinary
 * primitives with `uapply` set so they do not record what they are
 * undoing. Nothing here touches the line table directly, so undo can
 * never drift from what an edit actually does.
 *
 * INS and DEL are exact mirrors and both carry their text: an INS
 * record with only a count could be undone but never redone, which
 * is the flaw this shape exists to avoid. */
static int insert_text(Buffer *b, int y, int x, const char *t, int n)
{
    int i;
    for (i = 0; i < n; i++)
        if (!edinsch(b, y, x + i, t[i])) return 0;
    return 1;
}

static void delete_n(Buffer *b, int y, int x, int n)
{
    int i;
    for (i = 0; i < n; i++) eddelch(b, y, x);
}

static int applyrec(Buffer *b, UndoRec *r, int inverse, int *structural)
{
    int ok = 1;
    *structural = 0;
    b->uapply = 1;
    switch (r->op) {
    case UNDO_INS:
        if (inverse) {
            delete_n(b, r->y, r->x, r->n);
            b->cy = r->y; b->cx = r->x;
        } else {
            ok = r->text && insert_text(b, r->y, r->x, r->text, r->n);
            b->cy = r->y; b->cx = r->x + r->n;
        }
        break;
    case UNDO_DEL:
        if (inverse) {
            ok = r->text && insert_text(b, r->y, r->x, r->text, r->n);
            b->cy = r->y; b->cx = r->x + r->n;
        } else {
            delete_n(b, r->y, r->x, r->n);
            b->cy = r->y; b->cx = r->x;
        }
        break;
    case UNDO_SPLIT:
        ok = inverse ? edjoinline(b, r->y)
                     : edsplitline(b, r->y, r->x);
        b->cy = inverse ? r->y : r->y + 1;
        b->cx = inverse ? r->x : 0;
        *structural = 1;
        break;
    case UNDO_JOIN:
        ok = inverse ? edsplitline(b, r->y, r->x)
                     : edjoinline(b, r->y);
        b->cy = r->y;
        b->cx = inverse ? r->x : r->x;
        if (inverse) { b->cy = r->y + 1; b->cx = 0; }
        *structural = 1;
        break;
    }
    b->uapply = 0;
    return ok;
}

int ed_undo(Buffer *b, int *structural)
{
    UndoRec *r;
    int line;
    if (b->utop <= 0) return -1;
    r = &b->ur[b->utop - 1];
    line = r->y;
    if (!applyrec(b, r, 1, structural)) return -1;
    b->utop--;
    b->ubreak = 1;
    b->maxwdirty = 1;
    udirty(b);
    return line;
}

int ed_redo(Buffer *b, int *structural)
{
    UndoRec *r;
    int line;
    if (b->utop >= b->nur) return -1;
    r = &b->ur[b->utop];
    line = r->y;
    if (!applyrec(b, r, 0, structural)) return -1;
    b->utop++;
    b->ubreak = 1;
    b->maxwdirty = 1;
    udirty(b);
    return line;
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
