/* cdiff - a visual diff for AmigaOS. Two files side by side, patience
 * diff engine (diff.c), custom-drawn rows the CFile way.
 *
 * Usage: cdiff FILE1/A,FILE2/A,TEXT/S
 *   GUI (default): window on the Workbench screen.
 *     cursor up/down scroll, shift = page, space/b page, t/e top/end,
 *     n/p next/previous hunk, Esc or q quits.
 *   TEXT: unified-style listing to stdout (and the vamos test road).
 */
#include <exec/types.h>
#include <exec/tasks.h>
#include <intuition/intuition.h>
#include <intuition/imageclass.h>
#include <intuition/gadgetclass.h>
#include <intuition/icclass.h>
#include <proto/utility.h>   /* sysiclass: the arrow images */
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
    "$VER: cdiff 0.1b41 (1.8.26)";

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
static int gndiff, gnleft, gnright;

/* widest EXPANDED (tab-stops honoured) line in the active view, in
 * columns - the honest replacement for a fixed pan-range guess
 * (his find: a constant showed a partly-empty knob even when
 * nothing on screen overflowed the window). Recomputed lazily
 * (maxwdirty) so a scroll step never rescans a 12000-line file.
 * Declared here (not with the rest of the view state further
 * down) so freedirs/scandirs can mark it dirty too. */
static int gmaxw, maxwdirty = 1;

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
    gndiff = gnleft = gnright = 0;
    gdirmode = 0;
    maxwdirty = 1;
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
    maxwdirty = 1;
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

/* BORDER SCROLLERS - raw Intuition prop gadgets + sysiclass arrow
 * images. This is the MultiView anatomy and the ONLY road that
 * works here: GadTools gadgets are client-area widgets, they are
 * not designed to live in a window's border, which is why the
 * b27/b28 SCROLLER_KIND rewrite rendered nothing at all on his
 * machine (twice). Raw prop gadgets in the border DID render from
 * b25 on - his own screenshot proves it - so this restores that
 * proven half and fixes the one real defect the arrows had:
 *
 *   GFLG_GADGIMAGE (intuition.h 0x0004) - "set if GadgetRender
 *   and SelectRender point to an Image structure, clear if they
 *   point to Border structures"
 *
 * b26 built the arrow gadgets with GadgetRender = a sysiclass
 * Image but never set that flag, so Intuition walked the Image as
 * a struct Border and drew nothing. One bit. */
/* BORDER SCROLLERS - propgclass BOOPSI objects, exactly the shape
 * DiskMaster2 uses (his pointer, and the first REAL working code I
 * have had all night). Everything here mirrors DMRead.c:
 *
 *   NewObject(NULL, "propgclass", ... GA_RightBorder, TRUE,
 *             PGA_Freedom, FREEVERT, PGA_NewLook, TRUE,
 *             PGA_Borderless, TRUE, ICA_TARGET, ICTARGET_IDCMP)
 *   ... handed to OpenWindow via WA_Gadgets
 *
 * Three things I had wrong, all visible in that one call:
 *   - it is propgclass, a BOOPSI object, NOT a raw struct Gadget
 *     with GTYP_PROPGADGET filled in by hand;
 *   - PGA_Borderless is TRUE. I removed PROPBORDERLESS in b33
 *     believing it caused the flat look. DiskMaster2 sets it;
 *   - notification is ICA_TARGET/ICTARGET_IDCMP arriving as
 *     IDCMP_IDCMPUPDATE, not GADGETUP/MOUSEMOVE, so my handler was
 *     listening on a channel the gadget never used.
 *
 * PGA_Total/Visible/Top take real unit counts, so no pot/body
 * arithmetic. The arrow buttons stay raw sysiclass booleans - those
 * always did render. */
static Object *vgad, *hgad;
static struct Gadget agup, agdn, aglt, agrt;
static APTR iup, idn, ilt, irt;     /* sysiclass arrow images */
static int gadsok, arrowsok;
static int arrheld;                 /* 1 up 2 down 3 left 4 right */

static int noscrollset;
static int arrheld;                 /* 1 up 2 down 3 left 4 right */

/* draw one text cell run, tab-expanded, clipped to width cells,
 * starting hoff source columns in (tab stops stay absolute) */
static void drawtext(int x, int y, const DLine *l, int width,
                     int pen, int bg)
{
    static char ex[512];
    int i, o = 0, end = hoff + width;
    if (end > 512) end = 512;
    for (i = 0; i < l->len && o < end; i++) {
        char ch = l->ptr[i];
        if (ch == '\t') {
            do { ex[o++] = ' '; } while ((o & 7) && o < end);
        } else
            ex[o++] = (ch >= 32 || ch < 0) ? ch : '.';
    }
    SetAPen(rp, pen);
    SetBPen(rp, bg);
    Move(rp, x, y + fbase);
    if (o > hoff) Text(rp, (STRPTR)ex + hoff, o - hoff);
}

/* right-aligned 1-based line number in the gutter cells */
static void drawnum(int x, int y, long line, int pen, int bg)
{
    static char nb[16];
    sprintf(nb, "%*ld", gutw, line + 1);
    SetAPen(rp, pen);
    SetBPen(rp, bg);
    Move(rp, x, y + fbase);
    Text(rp, (STRPTR)nb, gutw);
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
    if (bar) {
        SetAPen(rp, 3);
        RectFill(rp, x, y, x + w * fw - 1, y + fh - 1);
    }
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
    int y = conty + vr * fh;
    int bar, x1;
    Row *r;
    SetAPen(rp, 0);
    RectFill(rp, x0, y, x0 + viscols * fw - 1, y + fh - 1);
    if (idx >= gnrows) return;
    r = &grows[idx];
    bar = r->tag != ' ';
    x1 = x0 + (halfw + 3) * fw;         /* right pane's left edge */
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

static void drawrows(void);

/* tab-expanded column width of one line (matches drawtext's own
 * expansion exactly, so the scroll range agrees with what actually
 * renders) */
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
 * side is wider), Tree takes the rel-path length. Called lazily
 * (maxwdirty) from updscrollers/sethoff - never on a hot scroll
 * step, so a 12000-line file costs nothing per keystroke. */
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
 * or the window width when everything already fits */
static int htotal(void)
{
    if (maxwdirty) calcmaxw();
    return gmaxw > viscols ? gmaxw : viscols;
}

/* push view/scroll state onto both knobs. NewModifyProp wants a
 * normalized 0..MAXPOT pot and a MAXBODY-scaled body (the visible
 * share) - a view that fits gives body = MAXBODY, i.e. a full-length
 * knob, the honest "nothing to scroll here" (his find: the Tree
 * showed a part-length horizontal knob when nothing overflowed). */
static void updscrollers(void)
{
    long total = vcount(), vis = crows, ht = htotal();
    long hvis = viscols;
    if (!gadsok || noscrollset) return;
    if (total < 1) total = 1;
    if (vis < 1) vis = 1;
    if (vis > total) vis = total;
    if (ht < 1) ht = 1;
    if (hvis < 1) hvis = 1;
    if (hvis > ht) hvis = ht;
    if (hoff > ht - hvis) hoff = ht - hvis;
    if (hoff < 0) hoff = 0;
    /* real unit counts, DiskMaster2's fd_setvscroller shape */
    if (vgad)
        SetGadgetAttrs((struct Gadget *)vgad, win, NULL,
                       PGA_Total, total, PGA_Visible, vis,
                       PGA_Top, *vtop(), TAG_END);
    if (hgad)
        SetGadgetAttrs((struct Gadget *)hgad, win, NULL,
                       PGA_Total, ht, PGA_Visible, hvis,
                       PGA_Top, hoff, TAG_END);
}

/* the one place hoff ever changes - keyboard, arrows, the knob -
 * so the clamp and the redraw can never drift apart */
static void sethoff(int nh)
{
    int ht = htotal();
    if (nh > ht - viscols) nh = ht - viscols;
    if (nh < 0) nh = 0;
    if (nh == hoff) return;
    hoff = nh;
    drawrows();
    updscrollers();
}

static void scrollto(int target);
static void movesel(int target);

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

/* THE fix (his boot, twice): a plain struct Gadget renders a
 * class-based image ONLY with GFLG_GADGIMAGE set - without it
 * Intuition reads GadgetRender as a struct Border and draws
 * nothing at all. b26 had everything else right and omitted this
 * one bit, which is what sent b27/b28 chasing GadTools instead. */
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

/* The MultiView border anatomy, on raw Intuition prop gadgets -
 * NOT GadTools. GadTools gadgets are client-area widgets and do
 * not belong in a window border; putting SCROLLER_KIND there is
 * what made b27/b28 render nothing. Raw props in the border have
 * rendered correctly since b25 (his screenshot), so that stays;
 * only the arrows needed fixing.
 *
 * Layout, all derived from the real border sizes: the vertical
 * prop runs from below the title to just above its two arrows,
 * which stack directly above the size gadget; the horizontal prop
 * runs from the left border to just before its two arrows, which
 * sit immediately left of the size gadget's corner. */
static void addscrollers(struct DrawInfo *dri, struct Screen *scr)
{
    int bt = scr->WBorTop + (scr->Font ? scr->Font->ta_YSize : 8) + 1;
    int bl = scr->WBorLeft;
    int aw = 0, ah = 0, lw = 0, lh = 0;
    struct Gadget *tail = NULL;

    if (dri) {
        iup = NewObject(NULL, (STRPTR)"sysiclass",
                        SYSIA_DrawInfo, (ULONG)dri,
                        SYSIA_Which, UPIMAGE, TAG_DONE);
        idn = NewObject(NULL, (STRPTR)"sysiclass",
                        SYSIA_DrawInfo, (ULONG)dri,
                        SYSIA_Which, DOWNIMAGE, TAG_DONE);
        ilt = NewObject(NULL, (STRPTR)"sysiclass",
                        SYSIA_DrawInfo, (ULONG)dri,
                        SYSIA_Which, LEFTIMAGE, TAG_DONE);
        irt = NewObject(NULL, (STRPTR)"sysiclass",
                        SYSIA_DrawInfo, (ULONG)dri,
                        SYSIA_Which, RIGHTIMAGE, TAG_DONE);
    }
    arrowsok = iup && idn && ilt && irt;
    if (arrowsok) {
        aw = ((struct Image *)iup)->Width;
        ah = ((struct Image *)iup)->Height;
        lw = ((struct Image *)ilt)->Width;
        lh = ((struct Image *)ilt)->Height;
    }

    /* DiskMaster2's own geometry: a 10-wide bar sitting 13 in from
     * the right edge, top just under the title, height relative.
     * Its arrows are absent, so the two here take their space off
     * the bottom of the bar. */
    vgad = NewObject(NULL, (STRPTR)"propgclass",
                     GA_ID, 1,
                     GA_RelRight, -13,
                     GA_Top, bt + 2,
                     GA_Width, 10,
                     GA_RelHeight, -(bt + 14 + ah + ah),
                     GA_RightBorder, TRUE,
                     PGA_Freedom, FREEVERT,
                     PGA_NewLook, TRUE,
                     PGA_Borderless, TRUE,
                     PGA_Total, 1,
                     PGA_Visible, 1,
                     PGA_Top, 0,
                     ICA_TARGET, ICTARGET_IDCMP,
                     TAG_END);
    if (vgad == NULL) return;

    hgad = NewObject(NULL, (STRPTR)"propgclass",
                     GA_ID, 2,
                     GA_Left, bl,
                     GA_RelBottom, -8,     /* 3px lower (his eye) */
                     GA_RelWidth, -(bl + 15 + lw + lw),
                     GA_Height, 10,
                     GA_BottomBorder, TRUE,
                     PGA_Freedom, FREEHORIZ,
                     PGA_NewLook, TRUE,
                     PGA_Borderless, TRUE,
                     PGA_Total, 1,
                     PGA_Visible, 1,
                     PGA_Top, 0,
                     ICA_TARGET, ICTARGET_IDCMP,
                     TAG_END);
    if (hgad)
        ((struct Gadget *)vgad)->NextGadget = (struct Gadget *)hgad;
    tail = (struct Gadget *)(hgad ? hgad : vgad);

    if (arrowsok) {
        /* up/down stacked above the size gadget's corner, left/right
         * immediately left of it - the bar lengths above reserve
         * exactly this much */
        mkarrow(&agup, iup, -(aw + 2), -(ah + ah + 12),
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_RIGHTBORDER, 3);
        mkarrow(&agdn, idn, -(aw + 2), -(ah + 12),
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_RIGHTBORDER, 4);
        mkarrow(&aglt, ilt, -(15 + lw + lw), 2 - lh,
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_BOTTOMBORDER, 5);
        mkarrow(&agrt, irt, -(15 + lw), 2 - lh,
                GFLG_RELRIGHT | GFLG_RELBOTTOM, GACT_BOTTOMBORDER, 6);
        tail->NextGadget = &agup;
        agup.NextGadget = &agdn;
        agdn.NextGadget = &aglt;
        aglt.NextGadget = &agrt;
    }
    gadsok = 1;     /* handed to OpenWindow, not added */
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
    SetAPen(rp, 0);
    RectFill(rp, x0, y, x0 + viscols * fw - 1, y + fh - 1);
    if (idx >= ndents) return;
    d = &dents[idx];
    bar = d->st != 'S';
    st = d->st == 'S' ? ' ' : d->st == 'D' ? '|' :
         d->st == 'L' ? '<' : '>';
    if (bar) {
        SetAPen(rp, 3);
        RectFill(rp, x0 + 2 * fw, y,
                 x0 + viscols * fw - 1, y + fh - 1);
    }
    SetAPen(rp, bar ? 2 : 1);
    SetBPen(rp, bar ? 3 : 0);
    Move(rp, x0 + 2 * fw, y + fbase);
    Text(rp, (STRPTR)&st, 1);
    sprintf(pbuf, "%.400s%s", d->rel, d->isdir ? "/" : "");
    tl.ptr = pbuf;
    tl.len = strlen(pbuf);
    tl.hash = 0;
    drawtext(x0 + 4 * fw, y, &tl, viscols - 4,
             bar ? 2 : 1, bar ? 3 : 0);
    if (idx == dsel) {          /* the cursor, always on the gray */
        static const char arrow = 0xBB;    /* Latin-1 >> */
        SetAPen(rp, 1);
        SetBPen(rp, 0);
        Move(rp, x0, y + fbase);
        Text(rp, (STRPTR)&arrow, 1);
    }
}

/* one full-width line of a single-file tab */
static void drawline(int vr)
{
    int line = *vtop() + vr;
    int y = conty + vr * fh;
    const DLine *l;
    char tag;
    SetAPen(rp, 0);
    RectFill(rp, x0, y, x0 + viscols * fw - 1, y + fh - 1);
    if (view == 1) {
        if (line >= gna) return;
        l = &ga[line];
        tag = gatag[line];
    } else {
        if (line >= gnb) return;
        l = &gb[line];
        tag = gbtag[line];
    }
    drawside(x0, y, l, line, tag != ' ', viscols);
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
        /* body */
        SetAPen(rp, gtabvid[i] == view ? pfill : pback);
        RectFill(rp, x + 1, y0 + 1, x + w - 2, yr - 1);
        /* bevel: shine top+left, shadow right */
        SetAPen(rp, pshine);
        Move(rp, x, yr - 1);
        Draw(rp, x, y0);
        Draw(rp, x + w - 2, y0);
        SetAPen(rp, pshadow);
        Move(rp, x + w - 1, y0 + 1);
        Draw(rp, x + w - 1, yr - 1);
        /* label, centred in the tab */
        SetAPen(rp, gtabvid[i] == view ? pfilltext : ptext);
        SetBPen(rp, gtabvid[i] == view ? pfill : pback);
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
    /* the active tab's floor is its fill colour: erase the rule
     * span so page and tab read as one surface */
    SetAPen(rp, pfill);
    Move(rp, tabx[act] + 1, yr);
    Draw(rp, tabe[act] - 2, yr);
}

static void drawpage(void)
{
    int vr, s, e;
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
static void scrollto(int target)
{
    int *t = vtop(), d, vr;
    int max = vcount() - crows;
    if (max < 0) max = 0;
    if (target > max) target = max;
    if (target < 0) target = 0;
    d = target - *t;
    if (d == 0) return;
    *t = target;
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
        updscrollers();
    } else
        drawrows();             /* full path: no tabs, but the
                                 * knob still needs the new top */
    if (d <= -crows || d >= crows)
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
    if (dsel < dtop)
        scrollto(dsel);
    else if (dsel >= dtop + crows)
        scrollto(dsel - crows + 1);
    if (old >= dtop && old < dtop + crows)
        drawone(old - dtop);
    if (dsel >= dtop && dsel < dtop + crows)
        drawone(dsel - dtop);
}

/* switch tabs, keeping the position: the top row/line carries over
 * through the row list so all three views stay anchored. The Tree
 * (3) keeps its own cursor - no anchor mapping to or from it. */
static void setview(int v)
{
    int i, row = 0;
    if (v == view) return;
    if (v == 3) {
        if (!gdirmode) return;
        view = 3;
        maxwdirty = 1;
        settitle();             /* the title follows the view (his
                                 * find: stale file title over the
                                 * Tree) */
        drawpage();
        return;
    }
    if (ga == NULL) return;
    if (view == 3) {
        view = v;
        maxwdirty = 1;
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
    maxwdirty = 1;
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
    maxwdirty = 1;
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
    tabh = fh + 4;
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
    gnrows = nrows;
    gtop = 0;
    maxwdirty = 1;
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
        "Esc or Backspace - back to the Tree (Esc in the Tree quits)\n"
        "F5 - reload both files, keep position\n"
        "Edit menu - edit a side (ENV:EDITOR), rediff on return\n"
        "Open Files with two DRAWERS - tree compare\n"
        "mouse: scrollbars; in the Tree click selects,\n"
        "double-click opens\n"
        "Esc (at the top) or Amiga+Q - quit");
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
    struct IntuiMessage *msg;
    int done = 0;

    /* GadTools is used for the MENUS only now - the scrollers are
     * raw Intuition gadgets, so the plain GetMsg/ReplyMsg pair is
     * correct again (GT_GetIMsg is required only when GadTools
     * GADGETS are in the window; GadTools menus never needed it,
     * as b25/b26 already demonstrated) */
    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
    GadToolsBase = OpenLibrary((STRPTR)"gadtools.library", 37);
    AslBase = OpenLibrary((STRPTR)"asl.library", 37);
    if (IntuitionBase == NULL || GfxBase == NULL) goto out;

    scr = LockPubScreen(NULL);
    if (scr == NULL) goto out;
    {
        /* the screen's GUI pens for the tab bevels; fall back to
         * the 4-colour defaults if DrawInfo is unavailable. The
         * sysiclass arrow images need the same DrawInfo, and the
         * whole scroller list must exist BEFORE OpenWindow - see
         * below. */
        struct DrawInfo *dri = GetScreenDrawInfo(scr);
        if (dri) {
            pshine = dri->dri_Pens[SHINEPEN];
            pshadow = dri->dri_Pens[SHADOWPEN];
            pfill = dri->dri_Pens[FILLPEN];
            pfilltext = dri->dri_Pens[FILLTEXTPEN];
            ptext = dri->dri_Pens[TEXTPEN];
            pback = dri->dri_Pens[BACKGROUNDPEN];
        }
        addscrollers(dri, scr);
        if (dri) FreeScreenDrawInfo(scr, dri);
    }
    win = OpenWindowTags(NULL,
        WA_Left, 0, WA_Top, scr->BarHeight + 1,
        WA_Width, scr->Width,
        WA_Height, scr->Height - scr->BarHeight - 1,
        WA_Title, (ULONG)"cdiff",
        WA_PubScreen, (ULONG)scr,
        /* THE structural fix (Intuition Gadgets, amigaos.net):
         * "Borders are adjusted only when the window is opened."
         * Border gadgets handed to AddGList AFTERWARDS never cause
         * Intuition to size the borders around them - which is why
         * every previous build's scrollers sat in a border that
         * knew nothing about them. Passed here instead, the
         * GACT_RIGHTBORDER / GACT_BOTTOMBORDER flags make Intuition
         * grow each border to hold its scroller, and with a size
         * gadget in both borders (SIZEBRIGHT|SIZEBBOTTOM) it takes
         * exactly the corner where the two meet - which is the
         * style guide's own rule for a window scrolling in both
         * directions. */
        /* (ULONG)vgad, NOT &vgad - when the props became BOOPSI
         * objects, vgad went from a struct to a POINTER, and this
         * line kept taking its address. Intuition then walked a
         * pointer-to-a-pointer as a gadget list, OpenWindow failed,
         * and cdiff exited with no window and no error. */
        WA_Gadgets, gadsok ? (ULONG)vgad : (ULONG)NULL,
        WA_IDCMP, IDCMP_CLOSEWINDOW | IDCMP_VANILLAKEY |
                  IDCMP_RAWKEY | IDCMP_REFRESHWINDOW |
                  IDCMP_MENUPICK | IDCMP_MOUSEBUTTONS |
                  IDCMP_NEWSIZE | IDCMP_GADGETDOWN |
                  IDCMP_GADGETUP | IDCMP_MOUSEMOVE |
                  IDCMP_INTUITICKS | IDCMP_IDCMPUPDATE,
        WA_Flags, WFLG_DRAGBAR | WFLG_DEPTHGADGET |
                  /* SMART: Intuition itself restores regions a
                   * requester covered - the app is BLOCKED inside
                   * EasyRequest and cannot repaint (his find: move
                   * the requester, holes stay). Backing store is
                   * the price, correctness is the product. */
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
    UnlockPubScreen(NULL, scr);

    rp = win->RPort;
    font = GfxBase->DefaultFont;    /* system monospace */
    SetFont(rp, font);
    fw = font->tf_XSize;
    fh = font->tf_YSize;
    fbase = font->tf_Baseline;
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
        while ((msg = (struct IntuiMessage *)
                      GetMsg(win->UserPort))) {
            ULONG class = msg->Class;
            UWORD code = msg->Code;
            UWORD qual = msg->Qualifier;
            WORD mx = msg->MouseX, my = msg->MouseY;
            APTR iaddr = msg->IAddress;
            ULONG csec = msg->Seconds, cmic = msg->Micros;
            ReplyMsg((struct Message *)msg);
            if (class == IDCMP_CLOSEWINDOW) done = 1;
            /* The propgclass bars report through IDCMP_IDCMPUPDATE
             * (that is what ICA_TARGET/ICTARGET_IDCMP buys), which
             * is DiskMaster2's own read-back: identify by GA_ID from
             * the message's tag list, then GetAttr the new PGA_Top
             * in real units. My old handler watched GADGETUP and
             * MOUSEMOVE - channels a propgclass object never uses. */
            if (class == IDCMP_IDCMPUPDATE) {
                ULONG id = GetTagData(GA_ID, 0, (struct TagItem *)iaddr);
                ULONG newtop = 0;
                noscrollset = 1;        /* never write back mid-drag */
                if (id == 1 && vgad) {
                    GetAttr(PGA_Top, vgad, &newtop);
                    if ((int)newtop != *vtop()) scrollto((int)newtop);
                } else if (id == 2 && hgad) {
                    GetAttr(PGA_Top, hgad, &newtop);
                    sethoff((int)newtop);
                }
                noscrollset = 0;
            }
            /* the arrows ARE plain boolean gadgets, so they keep the
             * ordinary down/tick/up repeat */
            if (class == IDCMP_GADGETDOWN) {
                arrheld = iaddr == (APTR)&agup ? 1 :
                          iaddr == (APTR)&agdn ? 2 :
                          iaddr == (APTR)&aglt ? 3 :
                          iaddr == (APTR)&agrt ? 4 : 0;
                if (arrheld) arrowstep(arrheld);
            }
            if (class == IDCMP_GADGETUP) arrheld = 0;
            if (class == IDCMP_INTUITICKS && arrheld)
                arrowstep(arrheld);
            if (class == IDCMP_MENUPICK) {
                if (gmenu && domenu(code)) done = 1;
            }
            if (class == IDCMP_REFRESHWINDOW) {
                /* graphics rendering ONLY inside the lock; the
                 * scrollers are updated after it is released */
                noscrollset = 1;
                BeginRefresh(win);
                drawpage();
                EndRefresh(win, TRUE);
                noscrollset = 0;
                updscrollers();
            }
            if (class == IDCMP_NEWSIZE) {
                /* the RELxxx flags let Intuition reposition each
                 * gadget's box during its own resize handling;
                 * RefreshGList makes them actually repaint there */
                if (gadsok)
                    RefreshGList((struct Gadget *)vgad, win, NULL,
                                 arrowsok ? 6 : 2);
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
                case 27:            /* Esc pops: file view -> Tree,
                                     * Tree (or plain mode) -> quit
                                     * (his instinct, the CFile way).
                                     * Amiga+Q quits via the menu
                                     * shortcut - no bare q (his
                                     * call: GUI apps do not quit
                                     * on a plain letter) */
                    if (gdirmode && view != 3) setview(3);
                    else done = 1;
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
                     * edxoff precedent) - the gutter is pinned.
                     * sethoff clamps against the real content
                     * width, not a guess. */
                    int step = page ? 40 : 8;
                    sethoff(hoff + (code == 0x4E ? step : -step));
                }
            }
        }
    }
    if (gmenu) ClearMenuStrip(win);
    CloseWindow(win);
out:
    /* No RemoveGList: the gadgets went in through WA_Gadgets, so
     * they belong to the window and CloseWindow takes them with
     * it (RemoveGList pairs with AddGList, which is no longer
     * used). The arrow gadgets are static structs - nothing to
     * free there. The propgclass bars and the sysiclass images ARE
     * allocated, and are disposed after the close, when nothing can
     * still reference them. */
    if (vgad) DisposeObject(vgad);
    if (hgad) DisposeObject(hgad);
    if (iup) DisposeObject(iup);
    if (idn) DisposeObject(idn);
    if (ilt) DisposeObject(ilt);
    if (irt) DisposeObject(irt);
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
