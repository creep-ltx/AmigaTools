/* cdiff - a visual diff for AmigaOS. Two files side by side, patience
 * diff engine (diff.c), custom-drawn rows the CFile way.
 *
 * Usage: cdiff FILE1/A,FILE2/A,TEXT/S
 *   GUI (default): window on the Workbench screen.
 *     cursor up/down scroll, shift = page, space/b page, t/e top/end,
 *     n/p next/previous hunk, Esc backs out to the Tree,
 *     Amiga+Q quits.
 *   TEXT: unified-style listing to stdout (and the vamos test road).
 */
#include <exec/types.h>
#include <exec/tasks.h>
#include <intuition/intuition.h>
#include <intuition/imageclass.h>   /* sysiclass: the arrow images */
#include <devices/inputevent.h>
#include <libraries/gadtools.h>
#include <libraries/asl.h>
#include <dos/dostags.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/gadtools.h>
#include <proto/asl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "diff.h"

/* 'used' or -O2 strips it - and c:Version must find it */
static const char verstag[] __attribute__((used)) =
    "$VER: cdiff 0.1b66 (2.8.26)";

/* NO __stack here: his guru proved this libnix never reads it (nm
 * shows nothing referencing ___stack) - main swaps to a real 64K
 * stack itself via exec StackSwap, see the bottom of the file */

/* initialized on purpose: a strong definition keeps libnix's
 * auto-open modules out of the link - TEXT mode must run where
 * these libraries don't exist (vamos), so ONLY guimode opens them */
struct IntuitionBase *IntuitionBase = NULL;
struct GfxBase *GfxBase = NULL;
struct Library *GadToolsBase = NULL;
struct Library *AslBase = NULL;

/* one display row of the side-by-side view */
typedef struct {
    long al, bl;                /* line index per side, -1 = blank */
    char tag;                   /* ' ' equal, '|' change, '<' del, '>' ins */
} Row;

static char *loadfile(const char *name, long *size)
{
    FILE *f = fopen(name, "rb");
    char *buf;
    long sz;
    if (f == NULL) return NULL;
    fseek(f, 0, SEEK_END);
    sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc(sz > 0 ? sz : 1);
    if (buf == NULL) { fclose(f); return NULL; }
    if (sz > 0 && fread(buf, 1, sz, f) != (size_t)sz) {
        fclose(f);
        free(buf);
        return NULL;
    }
    fclose(f);
    *size = sz;
    return buf;
}

/* ops -> rows. A DEL run followed by an INS run is a replace block:
 * pair min(n,m) rows as changes, the tail stays one-sided. */
static Row *buildrows(const DOp *ops, int nops, int *nrows)
{
    long total = 0;
    int i, n = 0;
    long ac = 0, bc = 0;
    Row *r;
    for (i = 0; i < nops; i++) total += ops[i].n;
    r = malloc((total > 0 ? total : 1) * sizeof(Row));
    if (r == NULL) return NULL;
    for (i = 0; i < nops; i++) {
        int k, cnt = ops[i].n;
        if (ops[i].t == DOP_EQ) {
            for (k = 0; k < cnt; k++) {
                r[n].al = ac++; r[n].bl = bc++; r[n].tag = ' '; n++;
            }
        } else if (ops[i].t == DOP_DEL) {
            int ins = 0, pair, k2;
            if (i + 1 < nops && ops[i + 1].t == DOP_INS)
                ins = ops[i + 1].n;
            pair = cnt < ins ? cnt : ins;
            for (k = 0; k < pair; k++) {
                r[n].al = ac++; r[n].bl = bc++; r[n].tag = '|'; n++;
            }
            for (k = pair; k < cnt; k++) {
                r[n].al = ac++; r[n].bl = -1; r[n].tag = '<'; n++;
            }
            for (k2 = pair; k2 < ins; k2++) {
                r[n].al = -1; r[n].bl = bc++; r[n].tag = '>'; n++;
            }
            if (ins) i++;       /* the INS op is consumed */
        } else {                /* lone INS */
            for (k = 0; k < cnt; k++) {
                r[n].al = -1; r[n].bl = bc++; r[n].tag = '>'; n++;
            }
        }
    }
    *nrows = n;
    return r;
}

/* ---- TEXT mode -------------------------------------------------- */

static void putline(char pre, const DLine *l)
{
    printf("%c", pre);
    fwrite(l->ptr, 1, l->len, stdout);
    printf("\n");
}

static void textmode(const DLine *a, const DLine *b,
                     const DOp *ops, int nops)
{
    long ac = 0, bc = 0;
    int i, k, hunks = 0, adds = 0, dels = 0;
    for (i = 0; i < nops; i++) {
        int n = ops[i].n;
        if (ops[i].t == DOP_EQ) { ac += n; bc += n; continue; }
        if (ops[i].t == DOP_DEL) {
            printf("@@ -%ld @@\n", ac + 1);
            for (k = 0; k < n; k++) putline('-', &a[ac++]);
            dels += n;
        } else {
            printf("@@ +%ld @@\n", bc + 1);
            for (k = 0; k < n; k++) putline('+', &b[bc++]);
            adds += n;
        }
        hunks++;
    }
    printf("cdiff: %d hunk%s, +%d -%d\n", hunks,
           hunks == 1 ? "" : "s", adds, dels);
}

/* ---- directory mode --------------------------------------------- */
/* view 3 = the Tree tab: both trees walked and merged into one
 * list, status per entry from presence + size (S same-size, D
 * differ, L/R one-sided; Enter runs the real diff - content truth
 * on demand, the roadmap rule). Selection cursor, CFile-style. */
typedef struct {
    char *rel;                  /* path relative to both roots */
    char st;                    /* 'S' 'D' 'L' 'R' */
    char isdir;
} DEnt;

static int gdirmode;
static char gdir1[310], gdir2[310];
static DEnt *dents;
static int ndents, dtop, dsel;

/* b58, his find: the horizontal knob sat shrunken and draggable
 * even with NOTHING loaded, because the pan range was the fixed
 * HTOT=512 guess rather than anything the content had to say. This
 * is the widest EXPANDED (tab stops honoured) line in the ACTIVE
 * view, in columns - recomputed lazily via maxwdirty so a scroll
 * step never rescans a 12000-line file. Declared up here, not with
 * the rest of the view state, so freedirs/scandirs can mark it
 * dirty too. (The scan is b27's one keeper, which b30 also kept
 * when it threw the rest of that detour away.) */
static int gmaxw, maxwdirty = 1;
static int gndiff, gnleft, gnright;

typedef struct {
    char *rel;
    long sz;
    char isdir;
} SEnt;

typedef struct {
    SEnt *e;
    int n, cap, oom;
} SList;

static void sladd(SList *l, const char *rel, long sz, int isdir)
{
    char *r;
    if (l->oom) return;
    if (l->n >= l->cap) {
        int nc = l->cap ? l->cap * 2 : 64;
        SEnt *ne = realloc(l->e, nc * sizeof(SEnt));
        if (ne == NULL) { l->oom = 1; return; }
        l->e = ne;
        l->cap = nc;
    }
    r = malloc(strlen(rel) + 1);
    if (r == NULL) { l->oom = 1; return; }
    strcpy(r, rel);
    l->e[l->n].rel = r;
    l->e[l->n].sz = sz;
    l->e[l->n].isdir = isdir;
    l->n++;
}

static void slfree(SList *l)
{
    int i;
    for (i = 0; i < l->n; i++) free(l->e[i].rel);
    free(l->e);
}

/* AmigaDOS names are case-insensitive; '/' sorts children under
 * their parent naturally */
static int relcmp(const char *a, const char *b)
{
    int ca, cb;
    for (;;) {
        ca = (unsigned char)*a++;
        cb = (unsigned char)*b++;
        if (ca >= 'a' && ca <= 'z') ca -= 32;
        if (cb >= 'a' && cb <= 'z') cb -= 32;
        if (ca != cb || ca == 0) return ca - cb;
    }
}

static int sentcmp(const void *pa, const void *pb)
{
    return relcmp(((const SEnt *)pa)->rel, ((const SEnt *)pb)->rel);
}

/* recursive collector: every file and dir under base as rel paths.
 * Each level owns its lock and DOS-aligned fib (AllocDosObject);
 * the shared rel buffer rolls back after each child. ExNext for
 * now - the CFile I3 ExAll lesson applies on real media, noted in
 * the roadmap. */
static void walkdir(const char *base, char *rel, SList *out, int depth)
{
    char *full;                 /* heap, NOT the frame - a deep tree
                                 * with 730B frames ate the stack:
                                 * his guru 8000 0009 on Unpacked/ */
    BPTR lock;
    struct FileInfoBlock *fib;
    if (depth > 12 || out->oom) return;
    full = malloc(730);
    if (full == NULL) { out->oom = 1; return; }
    strcpy(full, base);
    if (rel[0]) AddPart((STRPTR)full, (STRPTR)rel, 730);
    lock = Lock((STRPTR)full, SHARED_LOCK);
    free(full);
    if (lock == 0) return;
    fib = AllocDosObject(DOS_FIB, NULL);
    if (fib && Examine(lock, fib)) {
        while (ExNext(lock, fib)) {
            int ol = strlen(rel);
            if (ol + strlen((char *)fib->fib_FileName) + 2 > 400)
                continue;
            if (ol) {
                rel[ol] = '/';
                strcpy(rel + ol + 1, (char *)fib->fib_FileName);
            } else
                strcpy(rel, (char *)fib->fib_FileName);
            if (fib->fib_DirEntryType > 0) {
                sladd(out, rel, 0, 1);
                walkdir(base, rel, out, depth + 1);
            } else
                sladd(out, rel, fib->fib_Size, 0);
            rel[ol] = 0;
        }
    }
    if (fib) FreeDosObject(DOS_FIB, fib);
    UnLock(lock);
}

static void freedirs(void)
{
    int i;
    for (i = 0; i < ndents; i++) free(dents[i].rel);
    free(dents);
    dents = NULL;
    ndents = 0; dtop = 0; dsel = 0;
    maxwdirty = 1;          /* b58: the Tree's widest path is gone */
    gndiff = gnleft = gnright = 0;
    gdirmode = 0;
}

/* takes ownership of rel */
static void dadd(char *rel, int isdir, int st)
{
    static int dcap;
    if (rel == NULL) return;
    if (dents == NULL) dcap = 0;
    if (ndents >= dcap) {
        int nc = dcap ? dcap * 2 : 128;
        DEnt *nd = realloc(dents, nc * sizeof(DEnt));
        if (nd == NULL) { free(rel); return; }
        dents = nd;
        dcap = nc;
    }
    dents[ndents].rel = rel;
    dents[ndents].st = st;
    dents[ndents].isdir = isdir;
    ndents++;
    if (st == 'D') gndiff++;
    if (st == 'L') gnleft++;
    if (st == 'R') gnright++;
}

static int filesdiffer(const char *rel, long sz);

/* walk both roots, sort, merge: presence decides L/R, then the
 * BYTES decide S/D (size shortcut first); both-sided dirs get no
 * row (their children speak) */
static void scandirs(void)
{
    SList la, lb;
    static char rel[420];
    int i = 0, j = 0;
    memset(&la, 0, sizeof(la));
    memset(&lb, 0, sizeof(lb));
    rel[0] = 0;
    walkdir(gdir1, rel, &la, 0);
    rel[0] = 0;
    walkdir(gdir2, rel, &lb, 0);
    qsort(la.e, la.n, sizeof(SEnt), sentcmp);
    qsort(lb.e, lb.n, sizeof(SEnt), sentcmp);
    while (i < la.n || j < lb.n) {
        int c = i >= la.n ? 1 : j >= lb.n ? -1 :
                relcmp(la.e[i].rel, lb.e[j].rel);
        if (c < 0) {
            dadd(la.e[i].rel, la.e[i].isdir, 'L');
            la.e[i].rel = NULL;
            i++;
        } else if (c > 0) {
            dadd(lb.e[j].rel, lb.e[j].isdir, 'R');
            lb.e[j].rel = NULL;
            j++;
        } else {
            if (la.e[i].isdir && lb.e[j].isdir) {
                ;               /* both dirs: children carry it */
            } else if (la.e[i].isdir != lb.e[j].isdir) {
                /* dir vs file clash: 2 = drawer on the left side,
                 * 3 = drawer on the right (the message names them) */
                dadd(la.e[i].rel, la.e[i].isdir ? 2 : 3, 'D');
                la.e[i].rel = NULL;
            } else {
                int st;
                if (la.e[i].sz != lb.e[j].sz)
                    st = 'D';
                else
                    st = filesdiffer(la.e[i].rel, la.e[i].sz)
                         ? 'D' : 'S';
                dadd(la.e[i].rel, 0, st);
                la.e[i].rel = NULL;
            }
            i++;
            j++;
        }
    }
    slfree(&la);
    slfree(&lb);
    maxwdirty = 1;              /* b58: the Tree just gained rows */
}

/* same-size pair: do the BYTES differ? Chunked compare with an
 * early-out - a differing pair usually betrays itself in the first
 * chunk, an identical pair costs one full read at scan time (his
 * find: samesize.txt hid behind the size verdict; the dupcheck
 * road). Unreadable = differ, so Enter surfaces the fault. */
static int filesdiffer(const char *rel, long sz)
{
    static char q1[730], q2[730], cb1[8192], cb2[8192];
    FILE *f1, *f2;
    size_t n1, n2;
    int differ = 0;
    if (sz == 0) return 0;
    strcpy(q1, gdir1);
    AddPart((STRPTR)q1, (STRPTR)rel, 730);
    strcpy(q2, gdir2);
    AddPart((STRPTR)q2, (STRPTR)rel, 730);
    f1 = fopen(q1, "rb");
    if (f1 == NULL) return 1;
    f2 = fopen(q2, "rb");
    if (f2 == NULL) { fclose(f1); return 1; }
    for (;;) {
        n1 = fread(cb1, 1, sizeof(cb1), f1);
        n2 = fread(cb2, 1, sizeof(cb2), f2);
        if (n1 != n2) { differ = 1; break; }
        if (n1 == 0) break;
        if (memcmp(cb1, cb2, n1) != 0) { differ = 1; break; }
    }
    fclose(f1);
    fclose(f2);
    return differ;
}

/* is the path a directory? (drives both the CLI arm and Enter) */
static int ispathdir(const char *p)
{
    BPTR l;
    struct FileInfoBlock *fib;
    int r = 0;
    l = Lock((STRPTR)p, SHARED_LOCK);
    if (l == 0) return 0;
    fib = AllocDosObject(DOS_FIB, NULL);
    if (fib) {
        if (Examine(l, fib) && fib->fib_DirEntryType > 0) r = 1;
        FreeDosObject(DOS_FIB, fib);
    }
    UnLock(l);
    return r;
}

/* ---- the window ------------------------------------------------- */

static struct Window *win;
static struct RastPort *rp;
static struct TextFont *font;
static int fw, fh, fbase;              /* cell metrics */
static int x0, y0, viscols, visrows;   /* drawable grid */
static int halfw;                      /* columns per side */

static const DLine *ga, *gb;
static Row *grows;
static int gnrows, gtop;
static int gna, gnb;            /* line counts, for the gutter width */
static int gutw;                /* gutter digits; 0 = no gutter */

/* the loaded pair, owned here so the menu can swap files in place */
static char gf1[310], gf2[310];
static char *gbuf1, *gbuf2;
static DLine *gla, *glb;
static DOp *gops;

/* tabs (his ask): 0 = Both side-by-side, 1 = Left full-width,
 * 2 = Right full-width. Per-line change tags let the single views
 * bar their changed lines without walking the row list. */
static int view;
static int ltop, rtop;          /* single-view scroll tops (lines) */
static int hoff;                /* horizontal column offset - text
                                 * only, the gutter stays pinned */
static char *gatag, *gbtag;     /* per-line diff tag, ' ' = equal */
static int conty, crows;        /* content grid below the tab bar */
static int tabx[4], tabe[4];    /* tab bar hit ranges (pixels) */
static int tabsok;              /* tab bar live (files loaded) */
static int tabh;                /* tab bar height in pixels */

/* the screen's own GUI pens (DrawInfo), with 4-colour WB fallbacks -
 * the tabs are drawn in Intuition's bevel language (his ask: GUI
 * tabs, not text cells), so they follow the user's WB palette */
static int pshine = 2, pshadow = 1, pfill = 3, pfilltext = 2,
           ptext = 1, pback = 0;

static int gntabs, gtabvid[4];  /* live tabs -> view ids */

/* border scrollers (his verdict: "a CLI program in a GUI") - raw
 * prop gadgets, border-relative so resize repositions them free */
static struct Gadget vgad, hgad;
static struct PropInfo vpi, hpi;
static struct Image vim, him;
static int gadsok;

/* b48: the arrows, from b30's post-mortem rather than a new guess.
 * Boolean gadgets rendering sysiclass images, held in the same two
 * borders as the props. arrheld is the button under the mouse for
 * the INTUITICKS repeat; 0 when none. */
static struct Gadget agup, agdn, aglt, agrt;
static APTR iup, idn, ilt, irt;
static int arrowsok, arrheld;

/* b62, his find (stutter and torn rows on held up/down, Shift+
 * up/down and Tab, while the wheel stayed clean): the event loop
 * drains the whole port and PAINTS on every message. A held key
 * repeats faster than a scroll can be blitted, so one burst of N
 * repeats did N scroll blits and N knob refreshes to reach a state
 * that one paint could have drawn - and the intermediate frames
 * are what the eye catches as stutter. The wheel escaped it only
 * because a notch is one message, not a repeat stream.
 *
 * So: while `defer` is set the state still updates exactly as
 * before - every clamp, anchor mapping and view switch runs
 * untouched - but the painting is skipped and merely OWED, and
 * flushpaint() settles it once the port is empty. Same rule as
 * b12, moved up a level: the metric is blits per burst, not blits
 * per step.
 *
 * b63 fixed two things b62 got wrong. The debt is TYPED, so paying
 * it picks the cheapest sufficient repaint - b62 always ran a full
 * drawpage, which made a single keypress dearer than the
 * incremental scroll it replaced and stuttered worse than before.
 * And the flush runs inside the drain loop the moment the port is
 * empty, not after the loop exits - during a knob drag the stream
 * of MOUSEMOVE kept that loop alive, so b62 painted nothing at all
 * until the button came up. */
static int propheld;            /* 1 = vgad knob held, 2 = hgad */
static int defer;               /* inside message handling */
static int dirtyall;            /* a whole drawpage is owed */
static int dirtyrows;           /* every content row is owed */
static int dirtyknob;           /* the props need re-syncing */
static int scrollfrom, scrollfromset;   /* top the SCREEN still shows */
static int selold, seloldset;           /* Tree cursor's painted row */

/* draw one text cell run, tab-expanded, clipped to width cells,
 * starting hoff source columns in (tab stops stay absolute) */
/* b66: render exactly `width` columns, padded with blanks, and let
 * Text() lay down its own background through BPen. One blit puts
 * both the glyphs and the surface under them on screen, so the
 * caller needs no RectFill here at all - and a row can no longer
 * be caught half-painted, which is what a full-screen repaint
 * (Shift+scroll, Tab) was showing.
 *
 * The buffer now holds only the VISIBLE window rather than the
 * line from column 0, so a large hoff can never run past it - the
 * old ex[512] silently stopped padding once hoff+width passed 512. */
static void drawtext(int x, int y, const DLine *l, int width,
                     int pen, int bg)
{
    static char vis[256];
    int i, o = 0, n, end;
    if (width <= 0) return;
    if (width > (int)sizeof(vis)) width = sizeof(vis);
    end = hoff + width;
    for (i = 0; i < l->len && o < end; i++) {
        char ch = l->ptr[i];
        if (ch == '\t') {
            do {
                if (o >= hoff) vis[o - hoff] = ' ';
                o++;
            } while ((o & 7) && o < end);
        } else {
            if (o >= hoff) vis[o - hoff] = (ch >= 32 || ch < 0) ? ch : '.';
            o++;
        }
    }
    n = o - hoff;
    if (n < 0) n = 0;
    while (n < width) vis[n++] = ' ';
    SetAPen(rp, pen);
    SetBPen(rp, bg);
    Move(rp, x, y + fbase);
    Text(rp, (STRPTR)vis, width);
}

/* right-aligned 1-based line number in the gutter cells */
/* b66: gutw digits PLUS the separator column, so this Text covers
 * the whole gutw+1 span drawside skips over - no fill needed */
static void drawnum(int x, int y, long line, int pen, int bg)
{
    static char nb[24];
    sprintf(nb, "%*ld ", gutw, line + 1);
    SetAPen(rp, pen);
    SetBPen(rp, bg);
    Move(rp, x, y + fbase);
    Text(rp, (STRPTR)nb, gutw + 1);
}

/* one side of a row: optional bar fill, gutter number, the text,
 * within a `w`-column budget (halfw in the overview, viscols in a
 * single-file tab). The gutter recedes by palette hierarchy (his
 * ask - there is no dark grey on a 4-colour WB): blue-on-gray for
 * plain rows, black-on-blue under the bar - always a step quieter
 * than the content beside it. */
static void drawside(int x, int y, const DLine *l, long line,
                     int bar, int w)
{
    int tx = x, tw = w;
    /* b65: no fill here any more. The caller lays the row down ONCE
     * in its final colour, so this pane is already the right shade
     * and painting it again is pure flicker. */
    if (gutw > 0) {
        drawnum(x, y, line, bar ? 1 : 3, bar ? 3 : 0);
        tx += (gutw + 1) * fw;
        tw -= gutw + 1;
    }
    drawtext(tx, y, l, tw, bar ? 2 : 1, bar ? 3 : 0);
}

/* changed rows are BAR rows - pen-3 fill, white text, the CFile
 * selection-bar look - because pen-3 text on WB gray barely reads
 * (first-run screenshot lesson, 1.8.26). An inserted EMPTY line
 * shows as a solid bar instead of a naked marker. The untouched
 * side of a one-sided row stays gray: nothing lives there. */
static void drawrow(int vr)
{
    int idx = gtop + vr;
    int y = conty + vr * fh, ye = y + fh - 1;
    int rend = x0 + viscols * fw - 1;
    int bar, x1, se;
    Row *r;
    if (idx >= gnrows) {                /* past the end: blank */
        SetAPen(rp, 0);
        RectFill(rp, x0, y, rend, ye);
        return;
    }
    r = &grows[idx];
    bar = r->tag != ' ';
    x1 = x0 + (halfw + 3) * fw;         /* right pane's left edge */
    /* b65, his find (up/down clean, Shift+up/down and left/right
     * glitchy): those two land in drawrows(), which repaints every
     * row IN PLACE - and each row was being filled grey, then
     * filled blue over the top, then written into. Two full-width
     * fills per changed row, forty rows at key-repeat speed, is the
     * flicker. The blit path escaped it by only ever redrawing the
     * one or two entering rows.
     * ONE fill now, in the colour the row actually ends up, then
     * only the narrow strips that differ from it. */
    /* b66: each pane is painted end to end by drawnum + drawtext,
     * both of which carry their own background now. So fill ONLY
     * what no Text will cover: the marker gap, a missing pane on a
     * one-sided row, and the sub-cell slack at the right edge. No
     * pixel is written twice, and no row is ever briefly blank. */
    SetAPen(rp, 0);
    RectFill(rp, x0 + halfw * fw, y, x1 - 1, ye);       /* marker gap */
    if (r->al < 0)                      /* one-sided: no left pane */
        RectFill(rp, x0, y, x0 + halfw * fw - 1, ye);
    if (r->bl < 0)
        RectFill(rp, x1, y, x1 + halfw * fw - 1, ye);
    se = x1 + halfw * fw;               /* sub-cell slack on the right */
    if (se <= rend) RectFill(rp, se, y, rend, ye);
    if (r->al >= 0)
        drawside(x0, y, &ga[r->al], r->al, bar, halfw);
    if (bar) {
        SetAPen(rp, 3);
        SetBPen(rp, 0);
        Move(rp, x0 + (halfw + 1) * fw, y + fbase);
        Text(rp, (STRPTR)&r->tag, 1);
    }
    if (r->bl >= 0)
        drawside(x1, y, &gb[r->bl], r->bl, bar, halfw);
}

/* the active view's scroll top and extent (3 = the Tree tab) */
static int *vtop(void)
{
    return view == 0 ? &gtop : view == 1 ? &ltop :
           view == 2 ? &rtop : &dtop;
}

static int vcount(void)
{
    return view == 0 ? gnrows : view == 1 ? gna :
           view == 2 ? gnb : ndents;
}

/* length of a line once tab stops are expanded, in columns - the
 * same 8-column rule drawtext renders with, so the measurement and
 * the rendering can never disagree */
static int explen(const char *p, int n)
{
    int i, o = 0;
    for (i = 0; i < n; i++) {
        if (p[i] == '\t') { do { o++; } while (o & 7); }
        else o++;
    }
    return o;
}

/* recompute gmaxw for the ACTIVE view: Both/Left take ga, Both/
 * Right take gb (Both scrolls them together, so it needs whichever
 * side is wider), Tree takes the rel-path length. Called lazily -
 * never on a hot scroll step, so a big file costs nothing per
 * keystroke. With nothing loaded every loop is skipped and gmaxw
 * lands on 0, which is exactly the "nothing to scroll" answer. */
static void calcmaxw(void)
{
    int i, m = 0, w;
    if (view == 3) {
        for (i = 0; i < ndents; i++) {
            w = strlen(dents[i].rel) + (dents[i].isdir ? 1 : 0);
            if (w > m) m = w;
        }
    } else {
        if (view != 2 && ga)
            for (i = 0; i < gna; i++) {
                w = explen(ga[i].ptr, ga[i].len);
                if (w > m) m = w;
            }
        if (view != 1 && gb)
            for (i = 0; i < gnb; i++) {
                w = explen(gb[i].ptr, gb[i].len);
                if (w > m) m = w;
            }
    }
    gmaxw = m;
    maxwdirty = 0;
}

/* the horizontal scroll range in columns: the widest line there is,
 * or the window width when everything already fits. Equal to
 * viscols means body == full and pot == 0 - a knob that fills its
 * track, which Intuition will not let the mouse drag. That is the
 * "expanded and not movable" state he asked for, and it falls out
 * of telling the truth about the content rather than from a special
 * case for empty. */
static int htotal(void)
{
    if (maxwdirty) calcmaxw();
    return gmaxw > viscols ? gmaxw : viscols;
}

/* keep both knobs honest: body = visible share, pot = position */
static void updscrollers(void)
{
    ULONG vbody, vpot, hbody, hpot;
    long total = vcount(), vis = crows, top = *vtop();
    int ht;
    if (!gadsok) return;
    if (defer) { dirtyknob = 1; return; }
    /* after the guard, and floored at 1: htotal() is max(gmaxw,
     * viscols) and both are 0 before the first calcgrid, which
     * would divide by zero below */
    ht = htotal();
    if (ht < 1) ht = 1;
    if (total < 1) total = 1;
    if (vis > total) vis = total;
    vbody = (0xFFFFUL * vis) / total;
    vpot = total > vis ? (0xFFFFUL * top) / (total - vis) : 0;
    hbody = (0xFFFFUL * (viscols < ht ? viscols : ht)) / ht;
    hpot = ht > viscols ? (0xFFFFUL * hoff) / (ht - viscols) : 0;
    NewModifyProp(&vgad, win, NULL, vpi.Flags, 0, vpot, 0, vbody, 1);
    NewModifyProp(&hgad, win, NULL, hpi.Flags, hpot, 0, hbody, 0, 1);
}

/* one sysiclass arrow image. w > 0 asks the class for an explicit
 * size; w == 0 takes whatever it considers natural for SYSIA_Size.
 * The caller ALWAYS re-reads Width/Height from the object it gets
 * back rather than assuming the request was honoured - if this
 * Intuition ignores IA_Width/IA_Height the geometry simply falls
 * back to the natural size instead of drifting out of the border. */
static APTR mksysi(struct DrawInfo *dri, ULONG which, int sysz,
                   int w, int h)
{
    if (w > 0)
        return NewObject(NULL, (STRPTR)"sysiclass",
                         SYSIA_DrawInfo, (ULONG)dri,
                         SYSIA_Which, which,
                         SYSIA_Size, sysz,
                         IA_Width, w, IA_Height, h, TAG_DONE);
    return NewObject(NULL, (STRPTR)"sysiclass",
                     SYSIA_DrawInfo, (ULONG)dri,
                     SYSIA_Which, which,
                     SYSIA_Size, sysz, TAG_DONE);
}

/* THE arrow fix, and the only reason b26-b28 failed: a plain struct
 * Gadget renders a class-based image ONLY with GFLG_GADGIMAGE set
 * (intuition.h 0x0004 - "set if GadgetRender and SelectRender point
 * to an Image structure, clear if they point to Border structures").
 * Without it Intuition walks the sysiclass Image as a struct Border
 * and draws nothing at all. b26 had every other detail right and
 * omitted this one bit, which is what sent b27/b28 chasing GadTools
 * SCROLLER_KIND - a client-area widget kind that cannot live in a
 * window border, hence "nothing rendered" twice over. */
static void mkarrow(struct Gadget *g, APTR im, int le, int te,
                    int rel, int act, int id)
{
    struct Image *i = (struct Image *)im;
    g->LeftEdge = le;
    g->TopEdge = te;
    g->Width = i->Width;
    g->Height = i->Height;
    g->Flags = rel | GFLG_GADGIMAGE | GFLG_GADGHCOMP;
    g->Activation = act | GACT_RELVERIFY | GACT_IMMEDIATE;
    g->GadgetType = GTYP_BOOLGADGET;
    g->GadgetRender = im;
    g->GadgetID = id;
    g->NextGadget = NULL;
}

/* the border scrollers: vertical right, horizontal bottom (beside
 * the size gadget), AUTOKNOB props in the new look.
 *
 * b48 adds the arrows WITHOUT disturbing the track geometry he
 * signed off at b47: every b47 constant below is untouched except
 * the two extents, which give up exactly the room the arrows need
 * (2*ah off the vertical's height, 2*aw off the horizontal's
 * width). The arrows are centred on the track they drive rather
 * than in the raw border, so they stay aligned with the insets he
 * tuned by eye whatever size sysiclass hands back. */
static void addscrollers(struct DrawInfo *dri, struct Screen *scr)
{
    int brw = win->BorderRight, bbh = win->BorderBottom;
    int vaw = 0, vah = 0, haw = 0, hah = 0, hahnat = 0, sysz;
    int vawnat = 0;                 /* natural width at sysz */
    struct Gadget *tail;
    int n = 2;

    /* medium-res arrows on a tall screen, low-res on a short one -
     * sysiclass sizes its own imagery from this.
     *
     * b49, his eye on b48: the up/down pair wants a pixel on EACH
     * side, the left/right pair wants a pixel off the BOTTOM with
     * its top staying put. Neither is a placement constant - the
     * drawn size comes from the image, so the size has to be asked
     * of the class. Two passes: build one of each pair at its
     * natural size to measure it, then rebuild all four at the
     * measured size plus his deltas. b48 measured BOTH pairs off
     * the up arrow, which was only correct while the two pairs
     * happened to share dimensions - each pair is measured on its
     * own here. */
    sysz = scr->Height >= 400 ? SYSISIZE_MEDRES : SYSISIZE_LOWRES;
    if (dri) {
        static const int cand[3] = { SYSISIZE_LOWRES, SYSISIZE_MEDRES,
                                     SYSISIZE_HIRES };
        int cw[3], ch[3], i, pick = -1, want;
        APTR ph = mksysi(dri, LEFTIMAGE, sysz, 0, 0);

        /* b52, settled by b51's telemetry ("nat 13 req 17 got 13"):
         * this sysiclass IGNORES IA_Width/IA_Height. b49's +2 and
         * b51's +4 were both silently discarded - the arrows have
         * been at natural size since b48, and no further nudging of
         * that number can ever do anything. SYSIA_Size is the only
         * real lever, so measure every size the class offers and
         * choose, instead of guessing which one to hardcode. */
        for (i = 0; i < 3; i++) {
            APTR p = mksysi(dri, UPIMAGE, cand[i], 0, 0);
            cw[i] = ch[i] = 0;
            if (p) {
                cw[i] = ((struct Image *)p)->Width;
                ch[i] = ((struct Image *)p)->Height;
                DisposeObject(p);
            }
            if (cand[i] == sysz) vawnat = cw[i];
        }
        /* his ask, in his units: the width he saw, plus a pixel per
         * side. Take the SMALLEST size that reaches it - overshoot
         * is as wrong as undershoot - and the widest available if
         * nothing does. */
        want = vawnat > 0 ? vawnat + 2 : 0;
        for (i = 0; i < 3; i++)
            if (cw[i] >= want && cw[i] > 0 &&
                (pick < 0 || cw[i] < cw[pick])) pick = i;
        if (pick < 0)
            for (i = 0; i < 3; i++)
                if (cw[i] > 0 && (pick < 0 || cw[i] > cw[pick])) pick = i;

        if (ph) {
            haw = ((struct Image *)ph)->Width;
            hah = ((struct Image *)ph)->Height;
            DisposeObject(ph);
        }
        if (pick >= 0 && haw > 0) {
            vaw = cw[pick];
            vah = ch[pick];
            hahnat = hah;       /* the top is pinned to THIS */
            /* the vertical pair takes the chosen SIZE; the
             * horizontal pair is left exactly as b50 built it -
             * his eye signed that pair off and nothing here
             * touches it */
            iup = mksysi(dri, UPIMAGE, cand[pick], 0, 0);
            idn = mksysi(dri, DOWNIMAGE, cand[pick], 0, 0);
            ilt = mksysi(dri, LEFTIMAGE, sysz, haw, hah - 1);
            irt = mksysi(dri, RIGHTIMAGE, sysz, haw, hah - 1);
        }
    }
    arrowsok = iup && idn && ilt && irt;
    if (arrowsok) {
        /* what the class actually built, not what was asked for */
        vaw = ((struct Image *)iup)->Width;
        vah = ((struct Image *)iup)->Height;
        haw = ((struct Image *)ilt)->Width;
        hah = ((struct Image *)ilt)->Height;
    } else
        vaw = vah = haw = hah = 0;

    vpi.Flags = AUTOKNOB | FREEVERT | PROPNEWLOOK | PROPBORDERLESS;
    /* b47: left edge in 1px, right edge pinned (his eye: "perfectly
     * positioned to the right, 1 pixel too wide to the left"). Both
     * constants move together - LeftEdge is RELRIGHT-anchored, so
     * +1 on it and -1 on Width shifts the left side alone */
    vgad.LeftEdge = -(brw - 5);
    vgad.TopEdge = win->BorderTop + 1;
    vgad.Width = brw - 8;
    /* b54: 1px taller at the BOTTOM (his eye) - TopEdge is absolute
     * and untouched, so the whole pixel goes to the bottom end */
    vgad.Height = -(win->BorderTop + bbh + 2 + 2 * vah);
    vgad.Flags = GFLG_RELRIGHT | GFLG_RELHEIGHT;
    vgad.Activation = GACT_RELVERIFY | GACT_IMMEDIATE |
                      GACT_RIGHTBORDER | GACT_FOLLOWMOUSE;
    vgad.GadgetType = GTYP_PROPGADGET;
    vgad.GadgetRender = (APTR)&vim;
    vgad.SpecialInfo = (APTR)&vpi;
    vgad.GadgetID = 1;
    hpi.Flags = AUTOKNOB | FREEHORIZ | PROPNEWLOOK | PROPBORDERLESS;
    hgad.LeftEdge = win->BorderLeft;
    /* b47: grow 1px upward, bottom edge pinned (his eye: "perfectly
     * positioned to the bottom but 1 pixel too thin"). TopEdge back
     * to b45's value while Height gains the pixel, so the bar gets
     * taller instead of moving - the b46 bottom he approved holds */
    hgad.TopEdge = -(bbh - 3);
    /* b57: another 2px to the RIGHT (his eye), 17 in total since
     * b54. LeftEdge is absolute and untouched, so every pixel goes
     * to the right end. The trailing constant IS the gap in pixels
     * before the left/right arrows: 20 originally, 3 now. The
     * arrows are anchored to the right border and do not move, so
     * that 3 is all the room left - past it the track and the left
     * arrow overlap, and the arrows have to move instead. */
    hgad.Width = -(win->BorderLeft + brw + 3 + 2 * haw);
    hgad.Height = bbh - 4;
    hgad.Flags = GFLG_RELBOTTOM | GFLG_RELWIDTH;
    hgad.Activation = GACT_RELVERIFY | GACT_IMMEDIATE |
                      GACT_BOTTOMBORDER | GACT_FOLLOWMOUSE;
    hgad.GadgetType = GTYP_PROPGADGET;
    hgad.GadgetRender = (APTR)&him;
    hgad.SpecialInfo = (APTR)&hpi;
    hgad.GadgetID = 2;
    vgad.NextGadget = &hgad;
    hgad.NextGadget = NULL;
    tail = &hgad;

    if (arrowsok) {
        /* Up/down stack in the right border directly above the size
         * gadget; left/right sit in the bottom border directly left
         * of it. The offsets are exact: with RELRIGHT the real x is
         * win->Width + LeftEdge, with RELBOTTOM the real y is
         * win->Height + TopEdge - so -(bbh + vah) puts a button's
         * last row exactly one pixel above the bottom border, and
         * -(brw + haw) its last column one pixel left of the right
         * border. The cross-axis inset centres each arrow on its
         * own track, so a sysiclass image wider or narrower than
         * the track still lines up with it.
         *
         * b49: the vertical pair re-centres on its NEW width, so
         * the two extra pixels land one per side exactly as he
         * asked. The horizontal pair does NOT re-centre - hy is
         * computed from the natural height it had at b48, which he
         * called correct, so losing a pixel takes it off the
         * bottom and leaves the top where it is. */
        int vx = vgad.LeftEdge + (vgad.Width - vaw) / 2;
        int hy = hgad.TopEdge + (hgad.Height - hahnat) / 2;
        /* b53: both down 1px (his eye) - the pair moves together,
         * the track above them is left where he tuned it */
        mkarrow(&agup, iup, vx, -(bbh + 2 * vah - 1),
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_RIGHTBORDER, 3);
        mkarrow(&agdn, idn, vx, -(bbh + vah - 1),
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_RIGHTBORDER, 4);
        mkarrow(&aglt, ilt, -(brw + 2 * haw), hy,
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_BOTTOMBORDER, 5);
        mkarrow(&agrt, irt, -(brw + haw), hy,
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_BOTTOMBORDER, 6);
        tail->NextGadget = &agup;
        agup.NextGadget = &agdn;
        agdn.NextGadget = &aglt;
        aglt.NextGadget = &agrt;
        n += 4;
    }

    AddGList(win, &vgad, -1, n, NULL);
    /* b50, his find: the arrows drew wrong on open and on every
     * resize, then corrected themselves the moment the window was
     * deactivated and reactivated - and stayed correct until the
     * next resize. That is the whole diagnosis. Deactivating makes
     * Intuition redraw the window FRAME: border background first,
     * then the border gadgets on top of it. RefreshGList only ever
     * paints the gadget imagery - it does not repaint the border
     * underneath - so every one of our own refreshes stamped the
     * arrows onto stale border pixels. Every gadget here lives in
     * a border, so the frame refresh is the correct call for all
     * six and RefreshGList has no business in this window. */
    RefreshWindowFrame(win);
    gadsok = 1;
}

/* one row of the Tree tab: selection arrow, status marker, path.
 * One-sided and differing rows bar like changed lines do. */
static void drawdirrow(int vr)
{
    int idx = dtop + vr;
    int y = conty + vr * fh;
    int bar;
    char st;
    static char pbuf[440];
    DLine tl;
    DEnt *d;
    if (idx >= ndents) {
        SetAPen(rp, 0);
        RectFill(rp, x0, y, x0 + viscols * fw - 1, y + fh - 1);
        return;
    }
    d = &dents[idx];
    bar = d->st != 'S';
    st = d->st == 'S' ? ' ' : d->st == 'D' ? '|' :
         d->st == 'L' ? '<' : '>';
    /* b66: no fill. Columns 0-1 carry the cursor on grey, columns
     * 2-3 the status mark on the row's own colour, and the path
     * takes the rest - three Texts, each painting its background,
     * covering the row end to end in one pass. */
    {
        char pre[2];
        pre[0] = idx == dsel ? (char)0xBB : ' ';   /* Latin-1 >> */
        pre[1] = ' ';
        SetAPen(rp, 1);
        SetBPen(rp, 0);
        Move(rp, x0, y + fbase);
        Text(rp, (STRPTR)pre, 2);
        pre[0] = st;
        SetAPen(rp, bar ? 2 : 1);
        SetBPen(rp, bar ? 3 : 0);
        Move(rp, x0 + 2 * fw, y + fbase);
        Text(rp, (STRPTR)pre, 2);
    }
    sprintf(pbuf, "%.400s%s", d->rel, d->isdir ? "/" : "");
    tl.ptr = pbuf;
    tl.len = strlen(pbuf);
    tl.hash = 0;
    drawtext(x0 + 4 * fw, y, &tl, viscols - 4,
             bar ? 2 : 1, bar ? 3 : 0);
}

/* one full-width line of a single-file tab */
static void drawline(int vr)
{
    int line = *vtop() + vr;
    int y = conty + vr * fh, ye = y + fh - 1;
    int rend = x0 + viscols * fw - 1;
    const DLine *l;
    char tag;
    if (view == 1) {
        if (line >= gna) goto blank;
        l = &ga[line];
        tag = gatag[line];
    } else {
        if (line >= gnb) goto blank;
        l = &gb[line];
        tag = gbtag[line];
    }
    /* b66: drawside covers the full width via drawnum+drawtext,
     * each painting its own background - no fill at all here */
    drawside(x0, y, l, line, tag != ' ', viscols);
    return;
blank:
    SetAPen(rp, 0);
    RectFill(rp, x0, y, rend, ye);
}

/* the tab bar: real GUI tabs (his ask) - beveled boxes in the
 * screen's DrawInfo pens, the active one filled and opening into
 * the content through a gap in the base rule. Directory mode adds
 * a Tree tab ahead of the file three. */
static void drawtabs(void)
{
    static char lab[4][40];
    int i, x, w, yr = y0 + tabh, winr = x0 + viscols * fw - 1;
    int nt = 0, act = 0;
    SetAPen(rp, pback);
    RectFill(rp, x0, y0, winr, yr + 1);
    tabsok = (ga != NULL) || gdirmode;
    if (!tabsok) { gntabs = 0; return; }
    if (gdirmode) {
        strcpy(lab[nt], "Tree");
        gtabvid[nt++] = 3;
    }
    if (ga) {
        strcpy(lab[nt], "Both");
        gtabvid[nt++] = 0;
        sprintf(lab[nt], "%.30s", (char *)FilePart((STRPTR)gf1));
        gtabvid[nt++] = 1;
        sprintf(lab[nt], "%.30s", (char *)FilePart((STRPTR)gf2));
        gtabvid[nt++] = 2;
    }
    gntabs = nt;
    x = x0 + 2;
    for (i = 0; i < nt; i++) {
        int lw = strlen(lab[i]);
        w = lw * fw + 12;               /* label + side padding */
        /* clip into the window - narrow windows must not get
         * their border overpainted (his find, the hint lesson) */
        if (x + w > winr) {
            w = winr - x;
            lw = (w - 12) / fw;
            if (lw < 1) {               /* no room left at all */
                tabx[i] = winr;
                tabe[i] = winr;
                continue;
            }
        }
        tabx[i] = x;
        tabe[i] = x + w;
        if (gtabvid[i] == view) act = i;
        /* body - b59: every tab takes the page background, active
         * included (his ask: no blue). What marks the active one is
         * the base rule breaking open under it, not a fill. */
        SetAPen(rp, pback);
        RectFill(rp, x + 1, y0 + 1, x + w - 2, yr - 1);
        /* bevel: shine top+left, shadow right */
        SetAPen(rp, pshine);
        Move(rp, x, yr - 1);
        Draw(rp, x, y0);
        Draw(rp, x + w - 2, y0);
        SetAPen(rp, pshadow);
        Move(rp, x + w - 1, y0 + 1);
        Draw(rp, x + w - 1, yr - 1);
        /* label, centred in the tab - b59: one pen pair now that
         * the active tab is no longer filled */
        SetAPen(rp, ptext);
        SetBPen(rp, pback);
        Move(rp, x + 6, y0 + 2 + fbase);
        Text(rp, (STRPTR)lab[i], lw);
        x += w + 3;
    }
    /* base rule in shine, broken open under the active tab - the
     * classic "this tab is the page you are on" statement */
    SetAPen(rp, pshine);
    if (tabx[act] > x0) {
        Move(rp, x0, yr);
        Draw(rp, tabx[act], yr);
    }
    Move(rp, tabe[act] - 1, yr);
    Draw(rp, winr, yr);
    /* b59: the active tab's floor is the page background, so the
     * rule span under it is erased to pback - tab and page read as
     * one continuous surface and the separator does not cut across
     * it (his ask). This is the ONLY thing distinguishing the
     * active tab now, so the span must stay exactly as wide as the
     * tab's own body. */
    SetAPen(rp, pback);
    Move(rp, tabx[act] + 1, yr);
    Draw(rp, tabe[act] - 2, yr);
}

static void drawpage(void)
{
    int vr, s, e;
    if (defer) { dirtyall = 1; return; }
    drawtabs();
    for (vr = 0; vr < crows; vr++) {
        if (view == 3)
            drawdirrow(vr);
        else if (view == 0)
            drawrow(vr);
        else
            drawline(vr);
    }
    /* the slack margins: window size is rarely an exact multiple
     * of the cell, and the sub-cell strips below the last row and
     * right of the last column keep STALE pixels across a resize
     * (his find - "the blue": old bar rows surviving there) */
    SetAPen(rp, 0);
    s = x0 + viscols * fw;
    e = win->Width - win->BorderRight - 1;
    if (s <= e)
        RectFill(rp, s, y0, e, win->Height - win->BorderBottom - 1);
    s = conty + crows * fh;
    e = win->Height - win->BorderBottom - 1;
    if (s <= e)
        RectFill(rp, x0, s, x0 + viscols * fw - 1, e);
    updscrollers();
    if (ga == NULL && !gdirmode) {  /* WB start, nothing loaded -
                                     * in dirmode the Tree IS the
                                     * content (his find: the hint
                                     * stamped over the rows) */
        static const char hint[] =
            "no files loaded - Project / Open Files... "
            "(right mouse button)";
        int hl = sizeof(hint) - 1;
        /* a window RastPort includes the borders - clip by hand or
         * a narrow window gets its border overpainted (his find) */
        if (hl > viscols - 4) hl = viscols - 4;
        if (hl > 0) {
            SetAPen(rp, 1);
            SetBPen(rp, 0);
            Move(rp, x0 + 2 * fw, conty + fh + fbase);
            Text(rp, (STRPTR)hint, hl);
        }
    }
}

static void settitle(void)
{
    static char t[260];
    if (gdirmode && view == 3)
        sprintf(t, "cdiff: %.60s | %.60s"
                "  (%d entries: %d differ, %d left-only, %d right-only)",
                gdir1, gdir2, ndents, gndiff, gnleft, gnright);
    else if (ga)
        sprintf(t, "cdiff: %.70s | %.70s  (%d rows)", gf1, gf2, gnrows);
    else if (gf1[0])
        sprintf(t, "cdiff: %.70s | (now open the right file)", gf1);
    else if (gf2[0])
        sprintf(t, "cdiff: (now open the left file) | %.70s", gf2);
    else
        strcpy(t, "cdiff");
    SetWindowTitles(win, (STRPTR)t, (STRPTR)~0);
}

/* one content row of whatever view is active */
static void drawone(int vr)
{
    if (defer) { dirtyrows = 1; return; }
    if (view == 3)
        drawdirrow(vr);
    else if (view == 0)
        drawrow(vr);
    else
        drawline(vr);
}

/* content rows only - scrolling must never repaint the tab bar */
static void drawrows(void)
{
    int vr;
    if (defer) { dirtyrows = 1; return; }
    for (vr = 0; vr < crows; vr++)
        drawone(vr);
}

/* scroll the ACTIVE view so `target` is on top, clamped. The CFile
 * R1 rule (graphics-and-performance.md): a scroll step is ONE blit
 * of the content rectangle plus repaints of only the entering rows
 * - not a page of Texts, and never the tab bar. Jumps of a page or
 * more repaint the content whole (one pass beats a huge blit plus
 * a full repaint). ScrollWindowRaster (V39) keeps the damage
 * regions honest under overlapping windows on the pubscreen. */
/* b63: the scroll PAINT, from wherever the screen currently is to
 * wherever the state now says it should be. Split out of scrollto
 * so a deferred burst can replay it ONCE over the whole distance
 * instead of the caller having to paint every step. Still b12's
 * rule: one ScrollWindowRaster plus only the entering rows, the
 * tab bar never touched. */
static void paintscroll(int from, int to)
{
    int d = to - from, vr;
    if (d == 0) return;
    if ((d > -crows) && (d < crows) &&
        (IntuitionBase->LibNode.lib_Version >= 39)) {
        SetBPen(rp, 0);         /* the blit fills exposed with BgPen */
        ScrollWindowRaster(win, 0, d * fh,
                           x0, conty,
                           x0 + viscols * fw - 1,
                           conty + crows * fh - 1);
        if (d > 0) {            /* moved up: new rows at the bottom */
            for (vr = crows - d; vr < crows; vr++)
                drawone(vr);
        } else {                /* moved down: new rows on top */
            for (vr = 0; vr < -d; vr++)
                drawone(vr);
        }
    } else
        drawrows();             /* too far to blit: full rows */
}

static void scrollto(int target)
{
    int *t = vtop(), from;
    int max = vcount() - crows;
    if (max < 0) max = 0;
    if (target > max) target = max;
    if (target < 0) target = 0;
    from = *t;
    if (target == from) return;
    *t = target;
    if (defer) {
        /* Only the FIRST deferred step of a burst knows what is
         * actually on screen - every later one would report a top
         * that was never painted. Hence "if not already set". */
        if (!scrollfromset) { scrollfrom = from; scrollfromset = 1; }
        return;
    }
    paintscroll(from, target);
    updscrollers();
}

/* next/previous hunk in the active view: rows in the overview,
 * tagged lines in a single-file tab, non-same entries in the Tree */
static int nexthunk(int from, int dir)
{
    const char *tg = view == 1 ? gatag : gbtag;
    int n = vcount(), i = from + dir;
    if (view == 3) {
        while (i >= 0 && i < n && dents[i].st == 'S') i += dir;
        if (i < 0 || i >= n) return from;
        return i;
    }
    if (view == 0) {
        while (i > 0 && i < n && grows[i].tag != ' ') i += dir;
        while (i >= 0 && i < n && grows[i].tag == ' ') i += dir;
        if (i < 0 || i >= n) return from;
        while (i > 0 && grows[i - 1].tag != ' ') i--;
    } else {
        while (i > 0 && i < n && tg[i] != ' ') i += dir;
        while (i >= 0 && i < n && tg[i] == ' ') i += dir;
        if (i < 0 || i >= n) return from;
        while (i > 0 && tg[i - 1] != ' ') i--;
    }
    return i;
}

/* move the Tree selection to `target`: keep it visible (the edge
 * cross rides scrollto's blit), repaint just the two cursor rows */
static void movesel(int target)
{
    int old = dsel;
    if (ndents <= 0) return;
    if (target < 0) target = 0;
    if (target >= ndents) target = ndents - 1;
    if (target == dsel) return;
    dsel = target;
    /* the scroll goes first even when deferring, so scrollto can
     * record where the screen is before we return */
    if (dsel < dtop)
        scrollto(dsel);
    else if (dsel >= dtop + crows)
        scrollto(dsel - crows + 1);
    if (defer) {
        if (!seloldset) { selold = old; seloldset = 1; }
        return;
    }
    if (old >= dtop && old < dtop + crows)
        drawone(old - dtop);
    if (dsel >= dtop && dsel < dtop + crows)
        drawone(dsel - dtop);
}

/* pan to column `nh`, clamped to the real content width - the one
 * path to hoff for arrows and keys alike, so a held-down arrow can
 * never walk it past what drawtext will show. b58: the clamp was a
 * flat 440, which is why panning worked over an empty window; with
 * nothing loaded htotal() == viscols and the ceiling is 0. */
static void sethoff(int nh)
{
    int ht = htotal();
    if (nh > ht - viscols) nh = ht - viscols;
    if (nh < 0) nh = 0;
    if (nh == hoff) return;
    hoff = nh;
    if (defer) { dirtyrows = 1; return; }
    drawrows();
    updscrollers();
}

/* b64: follow a knob that Intuition is dragging. The PropInfo pot
 * is the truth - Intuition updates it in place as the mouse moves,
 * so converting it to a row/column here tracks the drag no matter
 * which IDCMP class happened to wake us. Cheap and idempotent: if
 * the pot still agrees with where we are, both calls return
 * immediately having done nothing. */
static void proptrack(void)
{
    if (propheld == 1) {
        long total = vcount(), vis = crows;
        if (total > vis)
            scrollto((int)(((ULONG)vpi.VertPot * (total - vis)
                            + 0x7FFF) / 0xFFFF));
    } else if (propheld == 2) {
        int ht = htotal();
        if (ht > viscols)
            sethoff((int)(((ULONG)hpi.HorizPot * (ht - viscols)
                           + 0x7FFF) / 0xFFFF));
    }
}

/* b63: is another message ALREADY queued? A held key or a dragged
 * knob arrives as a stream, and painting every message of it is
 * what stutters. This answers "is more coming right now", so the
 * paint can be skipped for every message but the last of a burst.
 * Forbid/Permit because Intuition appends to this list from input
 * server context. */
static int inputwaiting(void)
{
    int more;
    Forbid();
    more = win->UserPort->mp_MsgList.lh_Head->ln_Succ != NULL;
    Permit();
    return more;
}

/* b63: settle whatever painting the burst ran up, ONCE, on the
 * final state. b62 got this wrong twice: it always paid the debt
 * with a full drawpage (making a SINGLE keypress more expensive
 * than the incremental scroll it replaced), and it only ran after
 * the message loop exited - which during a knob drag never
 * happened, so nothing moved until the button came up. Now the
 * debt is typed, the cheapest sufficient repaint is chosen, and
 * the caller runs this the moment the port is empty. */
static void flushpaint(void)
{
    int owed = dirtyall || dirtyrows || scrollfromset || seloldset;
    if (!owed && !dirtyknob) return;
    defer = 0;
    if (dirtyall)
        drawpage();                     /* tabs and every row */
    else if (dirtyrows)
        drawrows();                     /* every row's text moved */
    else {
        if (scrollfromset)
            paintscroll(scrollfrom, *vtop());
        if (seloldset) {                /* Tree cursor: two rows */
            if (selold >= dtop && selold < dtop + crows)
                drawone(selold - dtop);
            if (dsel >= dtop && dsel < dtop + crows)
                drawone(dsel - dtop);
        }
    }
    dirtyall = dirtyrows = dirtyknob = 0;
    scrollfromset = seloldset = 0;
    /* b64: NOT while a knob is held - Intuition is rendering that
     * knob as it tracks the mouse, and NewModifyProp would stamp
     * our own idea of the position back over the drag. */
    if (!propheld) updscrollers();
}

/* one arrow-gadget step: 1 up, 2 down, 3 left, 4 right. The Tree
 * moves its selection (matching click-to-select); every other view
 * scrolls the content or pans it. */
static void arrowstep(int which)
{
    if (which == 1) {
        if (view == 3) movesel(dsel - 1); else scrollto(*vtop() - 1);
    } else if (which == 2) {
        if (view == 3) movesel(dsel + 1); else scrollto(*vtop() + 1);
    } else
        sethoff(hoff + (which == 4 ? 8 : -8));
}

/* switch tabs, keeping the position: the top row/line carries over
 * through the row list so all three views stay anchored. The Tree
 * (3) keeps its own cursor - no anchor mapping to or from it. */
static void setview(int v)
{
    int i, row = 0;
    if (v == view) return;
    /* b58: gmaxw is per-view (Both needs the wider of the two
     * sides, Tree measures paths), so a view change invalidates it */
    maxwdirty = 1;
    if (v == 3) {
        if (!gdirmode) return;
        view = 3;
        settitle();             /* the title follows the view (his
                                 * find: stale file title over the
                                 * Tree) */
        drawpage();
        return;
    }
    if (ga == NULL) return;
    if (view == 3) {
        view = v;
        settitle();
        drawpage();
        return;
    }
    if (view == 0) {
        for (i = gtop; i < gnrows; i++) {
            if (v == 1 && grows[i].al >= 0) { ltop = grows[i].al; break; }
            if (v == 2 && grows[i].bl >= 0) { rtop = grows[i].bl; break; }
        }
    } else {
        int line = view == 1 ? ltop : rtop;
        for (i = 0; i < gnrows; i++) {
            long here = view == 1 ? grows[i].al : grows[i].bl;
            if (here >= line) { row = i; break; }
        }
        if (v == 0) {
            gtop = row;
        } else {
            for (i = row; i < gnrows; i++) {
                long other = v == 1 ? grows[i].al : grows[i].bl;
                if (other >= 0) {
                    if (v == 1) ltop = other; else rtop = other;
                    break;
                }
            }
        }
    }
    view = v;
    /* re-clamp the landing view */
    {
        int *t = vtop(), max = vcount() - crows;
        if (max < 0) max = 0;
        if (*t > max) *t = max;
        if (*t < 0) *t = 0;
    }
    drawpage();
}

/* ---- loading, requesters, menus --------------------------------- */

static struct Menu *gmenu;
static APTR gvi;
static struct FileRequester *freq;   /* one, so it remembers the drawer */

/* error requester - works with win = NULL too (before the window),
 * and a WB start has no shell to print into */
static void erq(const char *text)
{
    struct EasyStruct es;
    ULONG args[1];
    es.es_StructSize = sizeof(es);
    es.es_Flags = 0;
    es.es_Title = (UBYTE *)"cdiff";
    es.es_TextFormat = (UBYTE *)"%s";
    es.es_GadgetFormat = (UBYTE *)"OK";
    args[0] = (ULONG)text;
    EasyRequestArgs(win, &es, NULL, args);
}

static void freediff(void)
{
    free(grows); grows = NULL; gnrows = 0;
    free(gops); gops = NULL;
    free(gla); gla = NULL;
    free(glb); glb = NULL;
    free(gbuf1); gbuf1 = NULL;
    free(gbuf2); gbuf2 = NULL;
    free(gatag); gatag = NULL;
    free(gbtag); gbtag = NULL;
    ga = gb = NULL;
    gna = gnb = 0;
    gtop = 0; ltop = 0; rtop = 0;
    hoff = 0;
    view = 0;
    maxwdirty = 1;          /* b58: both sides freed */
}

static void calcgut(void)
{
    int m = gna > gnb ? gna : gnb;
    gutw = 1;
    while (m >= 10) { m /= 10; gutw++; }
    if (halfw < gutw + 12) gutw = 0;    /* too narrow: no gutter */
}

/* the whole text grid from the window's current size - run at
 * open and again on every IDCMP_NEWSIZE */
static void calcgrid(void)
{
    x0 = win->BorderLeft;
    y0 = win->BorderTop;
    viscols = (win->Width - win->BorderLeft - win->BorderRight) / fw;
    visrows = (win->Height - win->BorderTop - win->BorderBottom) / fh;
    halfw = (viscols - 3) / 2;
    /* b60: 2px shorter (his eye). The label baseline is fixed at
     * y0 + 2 + fbase, so the text does not move and the whole
     * saving comes off the bottom - which also lifts conty and
     * gains the content a couple of pixels. */
    tabh = fh + 2;
    conty = y0 + tabh + 2;
    crows = (win->Height - win->BorderBottom - conty) / fh;
    if (crows < 1) crows = 1;
    calcgut();
}

/* clamp every view's top against the current extents */
static void clamptops(void)
{
    int m;
    m = gnrows - crows; if (m < 0) m = 0;
    if (gtop > m) gtop = m;
    m = gna - crows; if (m < 0) m = 0;
    if (ltop > m) ltop = m;
    m = gnb - crows; if (m < 0) m = 0;
    if (rtop > m) rtop = m;
    m = ndents - crows; if (m < 0) m = 0;
    if (dtop > m) dtop = m;
}

/* load gf1/gf2 and diff them; replaces whatever was loaded */
static int loaddiff(void)
{
    long sz1, sz2;
    int na, nb, nops, nrows;
    static char eb[360];
    freediff();
    gbuf1 = loadfile(gf1, &sz1);
    if (gbuf1 == NULL) {
        sprintf(eb, "cannot read %.300s", gf1);
        erq(eb);
        return -1;
    }
    gbuf2 = loadfile(gf2, &sz2);
    if (gbuf2 == NULL) {
        sprintf(eb, "cannot read %.300s", gf2);
        erq(eb);
        freediff();
        return -1;
    }
    if (diff_split(gbuf1, sz1, &gla, &na) != 0 ||
        diff_split(gbuf2, sz2, &glb, &nb) != 0 ||
        diff_run(gla, na, glb, nb, &gops, &nops) != 0 ||
        (grows = buildrows(gops, nops, &nrows)) == NULL ||
        (gatag = malloc(na > 0 ? na : 1)) == NULL ||
        (gbtag = malloc(nb > 0 ? nb : 1)) == NULL) {
        erq("out of memory");
        freediff();
        return -1;
    }
    /* per-line tags for the single-file tabs */
    memset(gatag, ' ', na > 0 ? na : 1);
    memset(gbtag, ' ', nb > 0 ? nb : 1);
    {
        int i;
        for (i = 0; i < nrows; i++) {
            if (grows[i].al >= 0) gatag[grows[i].al] = grows[i].tag;
            if (grows[i].bl >= 0) gbtag[grows[i].bl] = grows[i].tag;
        }
    }
    ga = gla; gb = glb;
    gna = na; gnb = nb;
    maxwdirty = 1;          /* b58: new content, new widest line */
    gnrows = nrows;
    gtop = 0;
    return 0;
}

/* 0 = cancelled, 1 = a file, 2 = a drawer (empty File field - the
 * road into directory mode) */
static int askfile(const char *title, char *dest)
{
    if (AslBase == NULL) {
        erq("asl.library v37 not available");
        return 0;
    }
    if (freq == NULL)
        freq = AllocAslRequestTags(ASL_FileRequest, TAG_DONE);
    if (freq == NULL) return 0;
    if (!AslRequestTags(freq,
            ASLFR_Window, (ULONG)win,
            ASLFR_TitleText, (ULONG)title,
            TAG_DONE))
        return 0;
    strcpy(dest, (char *)freq->fr_Drawer);
    if (freq->fr_File == NULL || freq->fr_File[0] == 0)
        return 2;
    AddPart((STRPTR)dest, freq->fr_File, 310);
    return 1;
}

/* a menu open picked new file(s): rediff if the pair is complete */
static void reload(void)
{
    if (gf1[0] && gf2[0]) {
        if (loaddiff() == 0) calcgut();
    }
    settitle();
    drawpage();
}

/* rediff the SAME pair, keeping view and position - the road home
 * after an edit or an external change (F5, the CFile reflex) */
static void refreshdiff(void)
{
    int v = view, gt = gtop, lt = ltop, rt = rtop, m;
    if (gf1[0] && gf2[0]) {
        if (loaddiff() == 0) {
            calcgut();
            view = v;
            gtop = gt; ltop = lt; rtop = rt;
            m = gnrows - crows; if (m < 0) m = 0;
            if (gtop > m) gtop = m;
            m = gna - crows; if (m < 0) m = 0;
            if (ltop > m) ltop = m;
            m = gnb - crows; if (m < 0) m = 0;
            if (rtop > m) rtop = m;
        }
    }
    settitle();
    drawpage();
}

/* Enter on a Tree entry: run the real diff on that file pair */
static void opensel(void)
{
    DEnt *d;
    static char eb[220];
    if (!gdirmode || view != 3 || ndents <= 0) return;
    d = &dents[dsel];
    /* name the actual drawers (his point: we KNOW them - vague
     * "left/right" helps nobody) */
    if (d->isdir) {
        if (d->isdir == 2)
            sprintf(eb, "\"%.40s\" is a drawer in\n%.64s\n"
                    "but a plain file in\n%.64s",
                    d->rel, gdir1, gdir2);
        else if (d->isdir == 3)
            sprintf(eb, "\"%.40s\" is a drawer in\n%.64s\n"
                    "but a plain file in\n%.64s",
                    d->rel, gdir2, gdir1);
        else
            sprintf(eb, "the drawer \"%.40s\"\nexists only in\n%.64s",
                    d->rel, d->st == 'L' ? gdir1 : gdir2);
        erq(eb);
        return;
    }
    if (d->st == 'L' || d->st == 'R') {
        sprintf(eb, "\"%.40s\"\nexists only in\n%.64s",
                d->rel, d->st == 'L' ? gdir1 : gdir2);
        erq(eb);
        return;
    }
    strcpy(gf1, gdir1);
    AddPart((STRPTR)gf1, (STRPTR)d->rel, 310);
    strcpy(gf2, gdir2);
    AddPart((STRPTR)gf2, (STRPTR)d->rel, 310);
    if (loaddiff() == 0) {
        calcgut();
        view = 0;
    } else
        view = 3;               /* freediff reset it - stay in the Tree */
    settitle();
    drawpage();
}

/* Tab / Shift+Tab: cycle the LIVE views - the Tree only exists in
 * directory mode, the file three only once a pair is loaded */
static void cycleview(int dir)
{
    int v = view, i;
    for (i = 0; i < 4; i++) {
        v = (v + (dir > 0 ? 1 : 3)) & 3;
        if (v == 3) {
            if (gdirmode) break;
        } else if (ga)
            break;
    }
    setview(v);
}

/* hand a side to an editor, synchronously, then rediff in place.
 * ENV:EDITOR names it (Ed otherwise); the AUTO console only
 * appears if the editor actually wants a shell window - GUI
 * editors never show it. */
static void editfile(int side)
{
    static char ed[80], cmd[420];
    BPTR ch;
    LONG res;
    if (side == 1 ? !gf1[0] : !gf2[0]) return;
    if (GetVar((STRPTR)"EDITOR", (STRPTR)ed, sizeof(ed), 0) <= 0)
        strcpy(ed, "Ed");
    sprintf(cmd, "%s \"%s\"", ed, side == 1 ? gf1 : gf2);
    ch = Open((STRPTR)"CON:0/12/640/240/cdiff editor/AUTO/CLOSE",
              MODE_NEWFILE);
    res = SystemTags((STRPTR)cmd,
                     SYS_Input, (ULONG)ch,
                     SYS_Output, (ULONG)ch,
                     TAG_DONE);
    if (ch) Close(ch);
    if (res == -1)
        erq("could not launch the editor\n(set ENV:EDITOR to name one)");
    refreshdiff();
}

static struct NewMenu newmenu[] = {
    { NM_TITLE, (STRPTR)"Project",       NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open Files...", (STRPTR)"O",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open Left...",  (STRPTR)"L",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open Right...", (STRPTR)"R",  0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,             NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Quit",          (STRPTR)"Q",  0, 0, NULL },
    { NM_TITLE, (STRPTR)"Edit",          NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Left File...",  (STRPTR)"E",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Right File...", NULL,         0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,             NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Reload",        NULL,         0, 0, NULL },
    { NM_TITLE, (STRPTR)"Help",          NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Keys...",       (STRPTR)"K",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"About...",      NULL,         0, 0, NULL },
    { NM_END,   NULL,                    NULL,         0, 0, NULL },
};

/* a centered, self-drawn requester: EasyRequest cannot be
 * positioned (top-left always - his screenshot), so About and
 * Keys get a bevel-framed window at the screen's true centre,
 * whatever the resolution. OK or any key leaves. */
static void centerreq(const char *text)
{
    struct Screen *scr;
    struct Window *w;
    struct IntuiMessage *m;
    struct RastPort *r;
    const char *p, *ls;
    int nl = 1, maxc = 0, c = 0;
    int ww, wh, okx, oky, okw, okh, y, done = 0, redraw = 1;

    for (p = text; *p; p++) {
        if (*p == '\n') { nl++; c = 0; }
        else if (++c > maxc) maxc = c;
    }
    okw = 6 * fw + 8;
    okh = fh + 6;
    ww = maxc * fw + 32;
    if (ww < okw + 32) ww = okw + 32;
    wh = nl * fh + okh + 28;
    scr = LockPubScreen(NULL);
    if (scr == NULL) return;
    w = OpenWindowTags(NULL,
        WA_Left, (scr->Width - ww) / 2,
        WA_Top, (scr->Height - wh) / 2,
        WA_Width, ww,
        WA_Height, wh,
        WA_PubScreen, (ULONG)scr,
        WA_IDCMP, IDCMP_MOUSEBUTTONS | IDCMP_VANILLAKEY |
                  IDCMP_REFRESHWINDOW,
        WA_Flags, WFLG_BORDERLESS | WFLG_ACTIVATE |
                  WFLG_SMART_REFRESH | WFLG_RMBTRAP,
        TAG_DONE);
    UnlockPubScreen(NULL, scr);
    if (w == NULL) return;
    r = w->RPort;
    SetFont(r, font);
    okx = (ww - okw) / 2;
    oky = wh - okh - 8;
    while (!done) {
        if (redraw) {
            redraw = 0;
            SetAPen(r, pback);
            RectFill(r, 0, 0, ww - 1, wh - 1);
            SetAPen(r, pshine);         /* raised requester frame */
            Move(r, 0, wh - 1); Draw(r, 0, 0); Draw(r, ww - 1, 0);
            SetAPen(r, pshadow);
            Move(r, ww - 1, 1); Draw(r, ww - 1, wh - 1);
            Draw(r, 1, wh - 1);
            SetAPen(r, ptext);
            SetBPen(r, pback);
            y = 12 + fbase;
            ls = text;
            for (p = text; ; p++) {
                if (*p == '\n' || *p == 0) {
                    if (p > ls) {
                        Move(r, 16, y);
                        Text(r, (STRPTR)ls, p - ls);
                    }
                    y += fh;
                    ls = p + 1;
                    if (*p == 0) break;
                }
            }
            SetAPen(r, pshine);         /* the OK button, raised */
            Move(r, okx, oky + okh - 1); Draw(r, okx, oky);
            Draw(r, okx + okw - 2, oky);
            SetAPen(r, pshadow);
            Move(r, okx + okw - 1, oky + 1);
            Draw(r, okx + okw - 1, oky + okh - 1);
            Draw(r, okx + 1, oky + okh - 1);
            SetAPen(r, ptext);
            SetBPen(r, pback);
            Move(r, okx + (okw - 2 * fw) / 2, oky + 3 + fbase);
            Text(r, (STRPTR)"OK", 2);
        }
        WaitPort(w->UserPort);
        while ((m = (struct IntuiMessage *)GetMsg(w->UserPort))) {
            ULONG cls = m->Class;
            UWORD cod = m->Code;
            WORD mx = m->MouseX, my = m->MouseY;
            ReplyMsg((struct Message *)m);
            if (cls == IDCMP_VANILLAKEY) done = 1;
            if (cls == IDCMP_REFRESHWINDOW) {
                BeginRefresh(w);
                EndRefresh(w, TRUE);
                redraw = 1;
            }
            if (cls == IDCMP_MOUSEBUTTONS && cod == SELECTDOWN &&
                mx >= okx && mx < okx + okw &&
                my >= oky && my < oky + okh)
                done = 1;
        }
    }
    CloseWindow(w);
}

static void aboutreq(void)
{
    static char t[300];
    /* verstag + 6 skips "$VER: " - the About can never drift from
     * the real version string */
    sprintf(t, "%s\n\na visual diff for AmigaOS\n"
               "patience engine, side-by-side view\n\n"
               "Tobias Karlsson, 2026",
            verstag + 6);
    centerreq(t);
}

static void keysreq(void)
{
    centerreq("1 / 2 / 3 / 0 - view: Both / Left / Right / Tree\n"
        "Tab / Shift+Tab - cycle views (bar is clickable)\n"
        "cursor up/down - scroll (shift = page), wheel works\n"
        "cursor left/right - scroll long lines (shift = more)\n"
        "space / b - page down / up\n"
        "t / e - top / end\n"
        "n / p - next / previous hunk (or tree entry)\n"
        "Enter - diff the selected tree entry\n"
        "Esc or Backspace - back to the Tree\n"
        "F5 - reload both files, keep position\n"
        "Edit menu - edit a side (ENV:EDITOR), rediff on return\n"
        "Open Files with two DRAWERS - tree compare\n"
        "mouse: scrollbars; in the Tree click selects,\n"
        "double-click opens\n"
        "Amiga+Q or the close gadget - quit");
}

static int domenu(UWORD code)   /* returns 1 = quit */
{
    UWORD c = code;
    while (c != MENUNULL) {
        struct MenuItem *item = ItemAddress(gmenu, c);
        if (MENUNUM(c) == 0) {
            switch (ITEMNUM(c)) {
            case 0: {           /* Open Files... - one by one, his ask;
                                 * two drawers = directory mode */
                static char t1[310], t2[310];
                int r1, r2;
                r1 = askfile("cdiff: select the LEFT file or drawer", t1);
                if (!r1) break;
                r2 = askfile("cdiff: select the RIGHT file or drawer", t2);
                if (!r2) break;
                if (r1 == 2 && r2 == 2) {
                    freediff();
                    freedirs();
                    strcpy(gdir1, t1);
                    strcpy(gdir2, t2);
                    gf1[0] = 0;
                    gf2[0] = 0;
                    gdirmode = 1;
                    scandirs();
                    view = 3;
                    settitle();
                    drawpage();
                } else if (r1 == 2 || r2 == 2) {
                    erq("pick two files - or two drawers for a "
                        "tree compare\n(a drawer = leave the File "
                        "field empty)");
                } else {
                    freedirs();
                    strcpy(gf1, t1);
                    strcpy(gf2, t2);
                    reload();
                }
                break;
            }
            case 1: {           /* Open Left... */
                static char t1[310];
                int r = askfile("cdiff: select the LEFT file", t1);
                if (r == 2)
                    erq("that is a drawer - Open Files... with two "
                        "drawers runs a tree compare");
                else if (r == 1) {
                    strcpy(gf1, t1);
                    reload();
                }
                break;
            }
            case 2: {           /* Open Right... */
                static char t2[310];
                int r = askfile("cdiff: select the RIGHT file", t2);
                if (r == 2)
                    erq("that is a drawer - Open Files... with two "
                        "drawers runs a tree compare");
                else if (r == 1) {
                    strcpy(gf2, t2);
                    reload();
                }
                break;
            }
            case 4:             /* Quit (3 is the bar) */
                return 1;
            }
        } else if (MENUNUM(c) == 1) {
            switch (ITEMNUM(c)) {
            case 0: editfile(1); break;
            case 1: editfile(2); break;
            case 3: refreshdiff(); break;   /* 2 is the bar */
            }
        } else if (MENUNUM(c) == 2) {
            switch (ITEMNUM(c)) {
            case 0: keysreq(); break;
            case 1: aboutreq(); break;
            }
        }
        if (item == NULL) break;
        c = item->NextSelect;
    }
    return 0;
}

static void guimode(void)
{
    struct Screen *scr;
    struct DrawInfo *dri = NULL;
    struct IntuiMessage *msg;
    int done = 0, burst = 0;

    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
    GadToolsBase = OpenLibrary((STRPTR)"gadtools.library", 37);
    AslBase = OpenLibrary((STRPTR)"asl.library", 37);
    if (IntuitionBase == NULL || GfxBase == NULL) goto out;

    scr = LockPubScreen(NULL);
    if (scr == NULL) goto out;
    win = OpenWindowTags(NULL,
        WA_Left, 0, WA_Top, scr->BarHeight + 1,
        WA_Width, scr->Width,
        WA_Height, scr->Height - scr->BarHeight - 1,
        WA_Title, (ULONG)"cdiff",
        WA_PubScreen, (ULONG)scr,
        WA_IDCMP, IDCMP_CLOSEWINDOW | IDCMP_VANILLAKEY |
                  IDCMP_RAWKEY | IDCMP_REFRESHWINDOW |
                  IDCMP_MENUPICK | IDCMP_MOUSEBUTTONS |
                  IDCMP_NEWSIZE | IDCMP_GADGETDOWN |
                  IDCMP_GADGETUP | IDCMP_MOUSEMOVE |
                  IDCMP_INTUITICKS,   /* b48: arrow auto-repeat */
        WA_Flags, WFLG_DRAGBAR | WFLG_DEPTHGADGET |
                  /* SMART: Intuition itself restores regions a
                   * requester covered - the app is BLOCKED inside
                   * EasyRequest and cannot repaint (his find: move
                   * the requester, holes stay). Backing store is
                   * the price, correctness is the product.
                   * SIZEBRIGHT widens the right border for the
                   * vertical scroller. */
                  WFLG_CLOSEGADGET | WFLG_SMART_REFRESH |
                  WFLG_ACTIVATE | WFLG_SIZEGADGET |
                  WFLG_SIZEBBOTTOM | WFLG_SIZEBRIGHT,
        WA_MinWidth, 240,
        WA_MinHeight, 120,
        WA_MaxWidth, ~0,
        WA_MaxHeight, ~0,
        WA_NewLookMenus, TRUE,
        TAG_DONE);
    if (win == NULL) {
        UnlockPubScreen(NULL, scr);
        goto out;
    }
    /* the screen's GUI pens for the tab bevels; fall back to the
     * 4-colour defaults if DrawInfo is unavailable. b48: the pens
     * are read here but the DrawInfo is NOT freed yet - sysiclass
     * needs it to build the arrow images, so it stays alive (and
     * the pubscreen stays locked) until addscrollers has run */
    dri = GetScreenDrawInfo(scr);
    if (dri) {
        pshine = dri->dri_Pens[SHINEPEN];
        pshadow = dri->dri_Pens[SHADOWPEN];
        pfill = dri->dri_Pens[FILLPEN];
        pfilltext = dri->dri_Pens[FILLTEXTPEN];
        ptext = dri->dri_Pens[TEXTPEN];
        pback = dri->dri_Pens[BACKGROUNDPEN];
    }
    if (GadToolsBase) {
        gvi = GetVisualInfo(scr, TAG_DONE);
        if (gvi) {
            gmenu = CreateMenus(newmenu, TAG_DONE);
            if (gmenu) {
                if (LayoutMenus(gmenu, gvi,
                                GTMN_NewLookMenus, TRUE, TAG_DONE))
                    SetMenuStrip(win, gmenu);
                else {
                    FreeMenus(gmenu);
                    gmenu = NULL;
                }
            }
        }
    }
    rp = win->RPort;
    font = GfxBase->DefaultFont;    /* system monospace */
    SetFont(rp, font);
    fw = font->tf_XSize;
    fh = font->tf_YSize;
    fbase = font->tf_Baseline;
    /* b48: both the DrawInfo and the pubscreen lock are still held
     * here on purpose - sysiclass reads them while it builds the
     * arrow images. Released the moment the gadgets exist. */
    addscrollers(dri, scr);
    if (dri) FreeScreenDrawInfo(scr, dri);
    UnlockPubScreen(NULL, scr);
    calcgrid();

    if (gdirmode) {                 /* CLI gave two directories */
        scandirs();
        view = 3;
    } else if (gf1[0] && gf2[0]) {  /* CLI gave the pair up front */
        if (loaddiff() == 0) calcgut();
    }
    settitle();
    drawpage();

    while (!done) {
        WaitPort(win->UserPort);
        while ((msg = (struct IntuiMessage *)GetMsg(win->UserPort))) {
            ULONG class = msg->Class;
            UWORD code = msg->Code;
            UWORD qual = msg->Qualifier;
            WORD mx = msg->MouseX, my = msg->MouseY;
            APTR iaddr = msg->IAddress;
            /* b63: every message defers its paint; flushpaint
             * below settles it as soon as the port is empty. A lone
             * message therefore still paints in its own iteration -
             * nothing waits on a later event. */
            defer = 1;
            ULONG csec = msg->Seconds, cmic = msg->Micros;
            ReplyMsg((struct Message *)msg);
            if (class == IDCMP_CLOSEWINDOW) done = 1;
            if (class == IDCMP_GADGETDOWN ||
                class == IDCMP_GADGETUP ||
                class == IDCMP_MOUSEMOVE) {
                /* b64: remember that a KNOB is being dragged. The
                 * content was not following the drag at all, only
                 * jumping on release, which means the MOUSEMOVE
                 * path alone is not reliably driving it. Rather
                 * than keep theorising about who delivers what,
                 * the drag is also pumped from INTUITICKS below -
                 * two independent paths, and the pot is the single
                 * source of truth for both. */
                if (class == IDCMP_GADGETDOWN)
                    propheld = iaddr == (APTR)&vgad ? 1 :
                               iaddr == (APTR)&hgad ? 2 : 0;
                else if (class == IDCMP_GADGETUP)
                    propheld = 0;
                if (iaddr == (APTR)&vgad) {
                    long total = vcount(), vis = crows;
                    if (total > vis)
                        scrollto(((ULONG)vpi.VertPot *
                                  (total - vis) + 0x7FFF) / 0xFFFF);
                } else if (iaddr == (APTR)&hgad) {
                    int ht = htotal();
                    if (ht > viscols)
                        sethoff(((ULONG)hpi.HorizPot *
                                 (ht - viscols) + 0x7FFF) / 0xFFFF);
                } else if (class == IDCMP_GADGETDOWN) {
                    /* b48: the arrows are plain boolean gadgets -
                     * GADGETDOWN starts the repeat and takes the
                     * first step, INTUITICKS continues it while the
                     * button is held, GADGETUP ends it */
                    arrheld = iaddr == (APTR)&agup ? 1 :
                              iaddr == (APTR)&agdn ? 2 :
                              iaddr == (APTR)&aglt ? 3 :
                              iaddr == (APTR)&agrt ? 4 : 0;
                    if (arrheld) arrowstep(arrheld);
                } else if (class == IDCMP_GADGETUP)
                    arrheld = 0;
            }
            if (class == IDCMP_INTUITICKS && arrheld)
                arrowstep(arrheld);
            if (class == IDCMP_INTUITICKS && propheld)
                proptrack();
            if (class == IDCMP_MENUPICK) {
                if (gmenu && domenu(code)) done = 1;
            }
            if (class == IDCMP_REFRESHWINDOW) {
                /* b64, a bug b62/b63 introduced: with the paint
                 * deferred, drawpage() drew NOTHING here while
                 * EndRefresh still cleared the damage - so the
                 * damaged region was left holding whatever was
                 * under it until some later flush, and during a
                 * held key that flush is skipped while input is
                 * queued. A refresh is not a repeat stream: it
                 * must paint inside Begin/EndRefresh, now. */
                int od = defer;
                defer = 0;
                BeginRefresh(win);
                drawpage();
                EndRefresh(win, TRUE);
                defer = od;
                /* the whole page was just painted - drop the debt
                 * so the flush does not redraw it a second time */
                dirtyall = dirtyrows = 0;
                scrollfromset = seloldset = 0;
            }
            if (class == IDCMP_NEWSIZE) {
                /* the RELxxx flags let Intuition reposition each
                 * gadget's box during its own resize handling; the
                 * frame refresh then repaints border background and
                 * border gadgets together at the new corner. b50:
                 * this was RefreshGList, which skipped the
                 * background and left the arrows sitting on stale
                 * border pixels after every resize (his find) */
                if (gadsok) RefreshWindowFrame(win);
                calcgrid();
                clamptops();
                drawpage();
            }
            if (class == IDCMP_MOUSEBUTTONS && code == SELECTDOWN) {
                if (tabsok && my >= y0 && my <= y0 + tabh) {
                    int i;
                    for (i = 0; i < gntabs; i++)
                        if (mx >= tabx[i] && mx < tabe[i])
                            setview(gtabvid[i]);
                } else if (view == 3 && my >= conty &&
                           my < conty + crows * fh) {
                    /* Tree rows: click selects, double-click
                     * opens (his verdict: a GUI must click) */
                    static ULONG lsec, lmic;
                    static int lrow = -1;
                    int row = dtop + (my - conty) / fh;
                    if (row < ndents) {
                        if (row == dsel && lrow == row &&
                            DoubleClick(lsec, lmic, csec, cmic)) {
                            lrow = -1;
                            opensel();
                        } else {
                            movesel(row);
                            lrow = row;
                            lsec = csec;
                            lmic = cmic;
                        }
                    }
                }
            }
            if (class == IDCMP_VANILLAKEY) {
                int tree = view == 3;
                switch (code) {
                case 27:            /* Esc POPS ONLY, it never quits
                                     * (b61, his call): file view ->
                                     * Tree, and nothing at all from
                                     * the Tree or from plain mode.
                                     * Quitting is Amiga+Q via the
                                     * menu shortcut, or the window's
                                     * close gadget - not Esc, not a
                                     * bare letter. */
                    if (gdirmode && view != 3) setview(3);
                    break;
                case 13: opensel(); break;             /* Enter */
                case 8:             /* Backspace: file -> Tree */
                    if (gdirmode && view != 3) setview(3);
                    break;
                case 9:             /* Tab cycles; Shift+Tab back */
                    cycleview((qual & (IEQUALIFIER_LSHIFT |
                                       IEQUALIFIER_RSHIFT)) ? -1 : 1);
                    break;
                case '1': setview(0); break;
                case '2': setview(1); break;
                case '3': setview(2); break;
                case '0': setview(3); break;
                case ' ':
                    if (tree) movesel(dsel + crows);
                    else scrollto(*vtop() + crows);
                    break;
                case 'b': case 'B':
                    if (tree) movesel(dsel - crows);
                    else scrollto(*vtop() - crows);
                    break;
                case 't': case 'T':
                    if (tree) movesel(0);
                    else scrollto(0);
                    break;
                case 'e': case 'E':
                    if (tree) movesel(ndents);
                    else scrollto(vcount());
                    break;
                case 'n': case 'N':
                    if (tree) movesel(nexthunk(dsel, 1));
                    else scrollto(nexthunk(*vtop(), 1));
                    break;
                case 'p': case 'P':
                    if (tree) movesel(nexthunk(dsel, -1));
                    else scrollto(nexthunk(*vtop(), -1));
                    break;
                }
            }
            if (class == IDCMP_RAWKEY) {
                int page = (qual & (IEQUALIFIER_LSHIFT |
                                    IEQUALIFIER_RSHIFT)) != 0;
                int tree = view == 3;
                if (code == 0x4C) {    /* cursor up */
                    if (tree) movesel(dsel - (page ? crows : 1));
                    else scrollto(*vtop() - (page ? crows : 1));
                } else if (code == 0x4D) { /* cursor down */
                    if (tree) movesel(dsel + (page ? crows : 1));
                    else scrollto(*vtop() + (page ? crows : 1));
                }
                else if (code == 0x54) /* F5: reload, the CFile reflex */
                    refreshdiff();
                else if (code == 0x42 && page)
                    /* Shift+Tab has NO vanilla translation - it
                     * falls through as RAWKEY (plain Tab arrives
                     * as VANILLAKEY 9 and never gets here) */
                    cycleview(-1);
                else if (code == 0x7A) { /* NewMouse: wheel up */
                    if (tree) movesel(dsel - (page ? crows : 3));
                    else scrollto(*vtop() - (page ? crows : 3));
                } else if (code == 0x7B) { /* NewMouse: wheel down */
                    if (tree) movesel(dsel + (page ? crows : 3));
                    else scrollto(*vtop() + (page ? crows : 3));
                }
                else if (code == 0x4F || code == 0x4E) {
                    /* horizontal: every row's text moves, so this
                     * stays a content repaint (the CFile editor's
                     * edxoff precedent) - the gutter is pinned */
                    int step = page ? 40 : 8;
                    sethoff(hoff + (code == 0x4E ? step : -step));
                }
            }
            /* b63: pay the debt as soon as nothing else is queued.
             * This sits INSIDE the drain loop on purpose - a knob
             * drag streams MOUSEMOVE hard enough that the loop can
             * keep finding messages and never exit, which is why
             * b62's after-the-loop flush left the content frozen
             * until the button came up.
             * b64: and pay it at least every 4 messages regardless,
             * so a stream that never leaves a gap still animates
             * instead of going dark until the user lets go. */
            if (!inputwaiting() || ++burst >= 4) {
                flushpaint();
                burst = 0;
            }
        }
        flushpaint();           /* burst ended by the port emptying */
    }
    if (gmenu) ClearMenuStrip(win);
    if (gadsok) RemoveGList(win, &vgad, -1);
    CloseWindow(win);
    /* b48: dispose the images only AFTER the gadgets that pointed
     * at them are gone - RemoveGList detached them above, so this
     * order can never leave Intuition holding a freed Image */
    if (iup) DisposeObject(iup);
    if (idn) DisposeObject(idn);
    if (ilt) DisposeObject(ilt);
    if (irt) DisposeObject(irt);
out:
    if (gmenu) FreeMenus(gmenu);
    if (gvi) FreeVisualInfo(gvi);
    if (freq) FreeAslRequest(freq);
    if (AslBase) CloseLibrary(AslBase);
    if (GadToolsBase) CloseLibrary(GadToolsBase);
    if (GfxBase) CloseLibrary((struct Library *)GfxBase);
    if (IntuitionBase) CloseLibrary((struct Library *)IntuitionBase);
}

/* ---- main ------------------------------------------------------- */

static int smain(int argc, char **argv)
{
    static const char tmpl[] = "FILE1/A,FILE2/A,TEXT/S";
    LONG argarr[3] = { 0, 0, 0 };
    struct RDArgs *rda;

    (void)argv;
    if (argc == 0) {
        /* Workbench start (his ask): empty window, the Project menu
         * supplies the files one by one */
        guimode();
        freediff();
        return 0;
    }

    rda = ReadArgs((STRPTR)tmpl, argarr, NULL);
    if (rda == NULL) {
        PrintFault(IoErr(), (STRPTR)"cdiff");
        return 20;
    }
    if (argarr[2]) {
        /* TEXT: the shell citizen and the vamos test road - loads
         * locally, prints, frees, no window state touched */
        char *buf1, *buf2;
        long sz1, sz2;
        DLine *la, *lb;
        DOp *ops;
        int na, nb, nops;
        if (ispathdir((char *)argarr[0]) &&
            ispathdir((char *)argarr[1])) {
            /* two dirs: print the tree compare - the scanner's
             * harness road under vamos, and a CLI tool for free */
            int i;
            strncpy(gdir1, (char *)argarr[0], sizeof(gdir1) - 1);
            strncpy(gdir2, (char *)argarr[1], sizeof(gdir2) - 1);
            scandirs();
            for (i = 0; i < ndents; i++) {
                char m = dents[i].st == 'S' ? '=' :
                         dents[i].st == 'D' ? '|' :
                         dents[i].st == 'L' ? '<' : '>';
                printf("%c %s%s\n", m, dents[i].rel,
                       dents[i].isdir ? "/" : "");
            }
            printf("cdiff: %d entries: %d differ, "
                   "%d left-only, %d right-only\n",
                   ndents, gndiff, gnleft, gnright);
            freedirs();
            FreeArgs(rda);
            return 0;
        }
        buf1 = loadfile((char *)argarr[0], &sz1);
        buf2 = loadfile((char *)argarr[1], &sz2);
        if (buf1 == NULL || buf2 == NULL) {
            printf("cdiff: cannot read %s\n",
                   buf1 == NULL ? (char *)argarr[0]
                                : (char *)argarr[1]);
            FreeArgs(rda);
            return 20;
        }
        if (diff_split(buf1, sz1, &la, &na) != 0 ||
            diff_split(buf2, sz2, &lb, &nb) != 0 ||
            diff_run(la, na, lb, nb, &ops, &nops) != 0) {
            printf("cdiff: out of memory\n");
            FreeArgs(rda);
            return 20;
        }
        textmode(la, lb, ops, nops);
        free(ops);
        free(la);
        free(lb);
        free(buf1);
        free(buf2);
    } else {
        int d1 = ispathdir((char *)argarr[0]);
        int d2 = ispathdir((char *)argarr[1]);
        if (d1 && d2) {         /* two directories: tree compare */
            strncpy(gdir1, (char *)argarr[0], sizeof(gdir1) - 1);
            strncpy(gdir2, (char *)argarr[1], sizeof(gdir2) - 1);
            gdirmode = 1;
        } else if (d1 || d2) {
            printf("cdiff: mixing a file and a directory - "
                   "give two of the same kind\n");
            FreeArgs(rda);
            return 20;
        } else {
            strncpy(gf1, (char *)argarr[0], sizeof(gf1) - 1);
            strncpy(gf2, (char *)argarr[1], sizeof(gf2) - 1);
        }
        guimode();
        freediff();
        freedirs();
    }
    FreeArgs(rda);
    return 0;
}

/* the stack trampoline: this libnix ignores __stack (proven by
 * the Unpacked/ guru - nothing in the archive references it), so
 * main itself swaps onto a 64K heap stack before any real work.
 * Everything that crosses the swap lives in statics: after
 * StackSwap the old frame's SP-relative locals are meaningless. */
#define STACKSZ 65536

static struct StackSwapStruct sss;
static char *bigstk;
static int sargc, sret;
static char **sargv;

/* the swapped work MUST be an argument-less noinline call: gcc
 * merges stack-pointer cleanups across calls, so argument bytes
 * pushed before the swap-back get double-popped after it (his
 * exit guru, read straight out of the disassembly - an addql #8
 * paying for two pushes that lived on DIFFERENT stacks). With no
 * arguments, no SP bookkeeping crosses the swap boundary. */
static void __attribute__((noinline)) runswapped(void)
{
    sret = smain(sargc, sargv);
}

int main(int argc, char **argv)
{
    struct Task *me = FindTask(NULL);
    long have = (char *)me->tc_SPUpper - (char *)me->tc_SPLower;
    /* swap only when the stack is measurably small. Zero bounds =
     * an environment that does not fill them in (vamos leaves both
     * NULL, measured 1.8.26 - and its StackSwap wrecks the exit
     * path) - there, run as given. Real exec always fills them, so
     * every real Amiga launch road gets the trampoline; his guru
     * proof: 4096-stack shell + Unpacked/ = guru, 40960 = fine. */
    if (me->tc_SPLower == NULL || me->tc_SPUpper == NULL ||
        have >= 32768)
        return smain(argc, argv);
    sargc = argc;
    sargv = argv;
    bigstk = malloc(STACKSZ);
    if (bigstk == NULL)
        return smain(argc, argv);   /* degrade: run on what we have */
    sss.stk_Lower = bigstk;
    sss.stk_Upper = (ULONG)(bigstk + STACKSZ);
    sss.stk_Pointer = (APTR)(bigstk + STACKSZ);
    StackSwap(&sss);
    runswapped();
    StackSwap(&sss);
    free(bigstk);
    return sret;
}
