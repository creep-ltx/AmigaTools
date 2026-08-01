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
#include <classes/window.h>
#include <gadgets/layout.h>
#include <gadgets/listbrowser.h>
#include <gadgets/clicktab.h>
#include <reaction/reaction_macros.h>
#include <proto/utility.h>   /* sysiclass: the arrow images */
#include <devices/inputevent.h>
#include <libraries/gadtools.h>
#include <libraries/asl.h>
#include <dos/dostags.h>
#include <proto/exec.h>
#include <clib/alib_protos.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/gadtools.h>
#include <proto/asl.h>
#include <proto/window.h>
#include <proto/layout.h>
#include <proto/listbrowser.h>
#include <proto/clicktab.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "diff.h"

/* 'used' or -O2 strips it - and c:Version must find it */
static const char verstag[] __attribute__((used)) =
    "$VER: cdiff 0.2b1 (2.8.26)";

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
/* the ReAction classes - V40 (3.1) onwards */
struct Library *WindowBase = NULL;
struct Library *LayoutBase = NULL;
struct Library *ListBrowserBase = NULL;
struct Library *ClickTabBase = NULL;
#define REACTVER 40

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

/* ---- the ReAction GUI ------------------------------------------- */
/* His instruction from the start, finally followed: build this out
 * of the OS's own GUI classes instead of hand-drawing it. The window
 * is window.class, the view switcher is clicktab.gadget, and the
 * content is listbrowser.gadget - which is a COMPLETE scrolling list
 * widget: it draws the rows, both scrollbars and their arrows, in
 * the system style, because it is the same class Workbench-era apps
 * like DiskMaster2 use for exactly this. Per-column LBNCA_FGPen /
 * LBNCA_BGPen carry the diff colouring, so nothing is lost by not
 * rendering the rows myself. */
static struct Window *win;
static Object *winobj, *tabobj, *listobj, *layoutobj;
static struct List rowlist, tablist;
static struct MsgPort *appport;

static const DLine *ga, *gb;
static Row *grows;
static int gnrows;
static int gna, gnb;

/* the loaded pair, owned here so the menu can swap files in place */
static char gf1[310], gf2[310];
static char *gbuf1, *gbuf2;
static DLine *gla, *glb;
static DOp *gops;

/* 0 = Both side-by-side, 1 = Left, 2 = Right, 3 = Tree */
static int view;
static char *gatag, *gbtag;     /* per-line diff tag, ' ' = equal */

/* one arena holding every NUL-terminated string the listbrowser
 * nodes point at - DLine is pointer+length with no terminator, and
 * the class needs real C strings that outlive the call */
static char *arena;
static long arenasz, arenaused;

/* the screen's own GUI pens (DrawInfo), 4-colour fallbacks */
static int pshine = 2, pshadow = 1, pfill = 3, pfilltext = 2,
           ptext = 1, pback = 0;

static int gntabs, gtabvid[4];  /* live tabs -> view ids */

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
/* ---- the listbrowser model -------------------------------------- */

/* column layouts, one per view. CIF_WEIGHTED shares the width out
 * proportionally, so the two text columns of the side-by-side view
 * get the space and the number/marker columns stay narrow. */
static struct ColumnInfo ci_both[] = {
    {  6, NULL, CIF_WEIGHTED }, { 44, NULL, CIF_WEIGHTED },
    {  4, NULL, CIF_WEIGHTED },
    {  6, NULL, CIF_WEIGHTED }, { 44, NULL, CIF_WEIGHTED },
    { -1, NULL, 0 }
};
static struct ColumnInfo ci_one[] = {
    {  8, NULL, CIF_WEIGHTED }, { 92, NULL, CIF_WEIGHTED },
    { -1, NULL, 0 }
};
static struct ColumnInfo ci_tree[] = {
    {  4, NULL, CIF_WEIGHTED }, { 96, NULL, CIF_WEIGHTED },
    { -1, NULL, 0 }
};

static void arenareset(void)
{
    arenaused = 0;
}

/* copy a DLine into the arena as a real C string, tabs expanded to
 * 8-stops so listbrowser sees the same alignment the file has */
static char *arenaline(const DLine *l)
{
    char *out;
    int i, o = 0;
    long need = (long)l->len * 8 + 2;
    if (arena == NULL || arenaused + need > arenasz) return (char *)"";
    out = arena + arenaused;
    for (i = 0; i < l->len; i++) {
        char ch = l->ptr[i];
        if (ch == '\t') { do { out[o++] = ' '; } while (o & 7); }
        else out[o++] = (ch >= 32 || ch < 0) ? ch : '.';
    }
    out[o++] = 0;
    arenaused += o;
    return out;
}

static char *arenafmt(const char *fmt, long v)
{
    char *out;
    if (arena == NULL || arenaused + 24 > arenasz) return (char *)"";
    out = arena + arenaused;
    sprintf(out, fmt, v);
    arenaused += strlen(out) + 1;
    return out;
}

static void freerows(void)
{
    if (listobj)
        SetGadgetAttrs((struct Gadget *)listobj, win, NULL,
                       LISTBROWSER_Labels, (ULONG)~0, TAG_END);
    FreeListBrowserList(&rowlist);
    NewList(&rowlist);
}

/* build the listbrowser node list for the ACTIVE view. Changed rows
 * carry FILLPEN/FILLTEXTPEN so they read as bars, exactly the CFile
 * selection-bar look the custom renderer used to draw by hand. */
static void buildlist(void)
{
    struct Node *n;
    int i, fg, bg, bar;

    freerows();
    arenareset();
    if (view == 3) {
        for (i = 0; i < ndents; i++) {
            char st[4], *nm;
            DEnt *d = &dents[i];
            bar = d->st != 'S';
            st[0] = d->st == 'S' ? ' ' : d->st == 'D' ? '|' :
                    d->st == 'L' ? '<' : '>';
            st[1] = 0;
            if (arena && arenaused + 8 < arenasz) {
                nm = arena + arenaused;
                strcpy(nm, st);
                arenaused += 2;
            } else nm = (char *)"";
            fg = bar ? pfilltext : ptext;
            bg = bar ? pfill : pback;
            {
                static char pb[440];
                DLine tl;
                sprintf(pb, "%.400s%s", d->rel, d->isdir ? "/" : "");
                tl.ptr = pb; tl.len = strlen(pb); tl.hash = 0;
                n = AllocListBrowserNode(2,
                        LBNA_Column, 0,
                            LBNCA_Text, (ULONG)nm,
                            LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                        LBNA_Column, 1,
                            LBNCA_Text, (ULONG)arenaline(&tl),
                            LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                        TAG_END);
            }
            if (n) AddTail(&rowlist, n);
        }
    } else if (view == 0) {
        for (i = 0; i < gnrows; i++) {
            Row *r = &grows[i];
            char mk[2];
            bar = r->tag != ' ';
            fg = bar ? pfilltext : ptext;
            bg = bar ? pfill : pback;
            mk[0] = r->tag; mk[1] = 0;
            n = AllocListBrowserNode(5,
                    LBNA_Column, 0,
                        LBNCA_Text, (ULONG)(r->al >= 0 ?
                            arenafmt("%ld", r->al + 1) : ""),
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    LBNA_Column, 1,
                        LBNCA_Text, (ULONG)(r->al >= 0 ?
                            arenaline(&ga[r->al]) : ""),
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    LBNA_Column, 2,
                        LBNCA_Text, (ULONG)(bar ? mk : " "),
                        LBNCA_CopyText, TRUE,
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    LBNA_Column, 3,
                        LBNCA_Text, (ULONG)(r->bl >= 0 ?
                            arenafmt("%ld", r->bl + 1) : ""),
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    LBNA_Column, 4,
                        LBNCA_Text, (ULONG)(r->bl >= 0 ?
                            arenaline(&gb[r->bl]) : ""),
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    TAG_END);
            if (n) AddTail(&rowlist, n);
        }
    } else {
        const DLine *src = view == 1 ? ga : gb;
        const char *tg = view == 1 ? gatag : gbtag;
        int cnt = view == 1 ? gna : gnb;
        for (i = 0; i < cnt; i++) {
            bar = tg && tg[i] != ' ';
            fg = bar ? pfilltext : ptext;
            bg = bar ? pfill : pback;
            n = AllocListBrowserNode(2,
                    LBNA_Column, 0,
                        LBNCA_Text, (ULONG)arenafmt("%ld", (long)i + 1),
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    LBNA_Column, 1,
                        LBNCA_Text, (ULONG)arenaline(&src[i]),
                        LBNCA_FGPen, fg, LBNCA_BGPen, bg,
                    TAG_END);
            if (n) AddTail(&rowlist, n);
        }
    }
    if (listobj)
        SetGadgetAttrs((struct Gadget *)listobj, win, NULL,
                       LISTBROWSER_ColumnInfo, (ULONG)(view == 3 ? ci_tree :
                                        view == 0 ? ci_both : ci_one),
                       LISTBROWSER_Labels, (ULONG)&rowlist,
                       LISTBROWSER_Top, 0,
                       TAG_END);
}

/* the arena must hold every expanded line of whichever view is
 * widest - size it once per load from the real byte counts */
static void arenafit(void)
{
    long need = 4096;
    int i;
    if (ga) for (i = 0; i < gna; i++) need += ga[i].len * 2 + 24;
    if (gb) for (i = 0; i < gnb; i++) need += gb[i].len * 2 + 24;
    for (i = 0; i < ndents; i++) need += strlen(dents[i].rel) + 8;
    if (need <= arenasz) return;
    free(arena);
    arena = malloc(need);
    arenasz = arena ? need : 0;
    arenaused = 0;
}

static int nexthunk(int from, int dir)
{
    const char *tg = view == 1 ? gatag : gbtag;
    int n = view == 3 ? ndents : view == 0 ? gnrows :
            view == 1 ? gna : gnb;
    int i = from + dir;
    if (view == 3) {
        while (i >= 0 && i < n && dents[i].st == 'S') i += dir;
    } else if (view == 0) {
        while (i > 0 && i < n && grows[i].tag != ' ') i += dir;
        while (i >= 0 && i < n && grows[i].tag == ' ') i += dir;
        while (i > 0 && i < n && grows[i - 1].tag != ' ') i--;
    } else {
        if (tg == NULL) return from;
        while (i > 0 && i < n && tg[i] != ' ') i += dir;
        while (i >= 0 && i < n && tg[i] == ' ') i += dir;
        while (i > 0 && i < n && tg[i - 1] != ' ') i--;
    }
    if (i < 0 || i >= n) return from;
    return i;
}

static void settitle(void);
static void erq(const char *text);
static int loaddiff(void);
static void buildtabs(void);
static void buildlist(void);
static void arenafit(void);

/* Enter (or a double-click) on a Tree row: run the real diff on that
 * pair. The selected row now comes from the listbrowser itself. */
static void opensel(void)
{
    DEnt *d;
    ULONG sel = 0;
    static char eb[220];
    if (!gdirmode || view != 3 || ndents <= 0 || listobj == NULL) return;
    GetAttr(LISTBROWSER_Selected, listobj, &sel);
    if ((int)sel < 0 || (int)sel >= ndents) return;
    d = &dents[sel];
    /* name the actual drawers - vague "left/right" helps nobody */
    if (d->isdir) {
        if (d->isdir == 2)
            sprintf(eb, "\"%.40s\" is a drawer in\n%.64s\n"
                    "but a plain file in\n%.64s", d->rel, gdir1, gdir2);
        else if (d->isdir == 3)
            sprintf(eb, "\"%.40s\" is a drawer in\n%.64s\n"
                    "but a plain file in\n%.64s", d->rel, gdir2, gdir1);
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
    view = (loaddiff() == 0) ? 0 : 3;
    arenafit();
    buildtabs();
    buildlist();
    settitle();
}

/* the clicktab labels: Tree first when in directory mode, then the
 * file three once a pair is loaded - same live-tab rule the hand
 * drawn bar had, now expressed as clicktab nodes */
/* there is no FreeClickTabList in the API - only per-node, which is
 * how DiskMaster2 does it too */
static void freetabs(void)
{
    struct Node *n;
    while ((n = RemHead(&tablist))) FreeClickTabNode(n);
}

static void buildtabs(void)
{
    struct Node *n;
    static char l1[40], l2[40];
    int nt = 0;
    if (tabobj)
        SetGadgetAttrs((struct Gadget *)tabobj, win, NULL,
                       CLICKTAB_Labels, (ULONG)~0, TAG_END);
    freetabs();
    if (gdirmode) {
        if ((n = AllocClickTabNode(TNA_Text, (ULONG)"Tree",
                                   TNA_Number, nt, TAG_END))) {
            AddTail(&tablist, n);
            gtabvid[nt++] = 3;
        }
    }
    if (ga) {
        if ((n = AllocClickTabNode(TNA_Text, (ULONG)"Both",
                                   TNA_Number, nt, TAG_END))) {
            AddTail(&tablist, n);
            gtabvid[nt++] = 0;
        }
        sprintf(l1, "%.30s", (char *)FilePart((STRPTR)gf1));
        if ((n = AllocClickTabNode(TNA_Text, (ULONG)l1,
                                   TNA_Number, nt, TAG_END))) {
            AddTail(&tablist, n);
            gtabvid[nt++] = 1;
        }
        sprintf(l2, "%.30s", (char *)FilePart((STRPTR)gf2));
        if ((n = AllocClickTabNode(TNA_Text, (ULONG)l2,
                                   TNA_Number, nt, TAG_END))) {
            AddTail(&tablist, n);
            gtabvid[nt++] = 2;
        }
    }
    gntabs = nt;
    if (tabobj)
        SetGadgetAttrs((struct Gadget *)tabobj, win, NULL,
                       CLICKTAB_Labels, (ULONG)&tablist, TAG_END);
}

static void setview(int v)
{
    if (v == view) return;
    if (v == 3 ? !gdirmode : (ga == NULL)) return;
    view = v;
    buildlist();
    if (tabobj)
        SetGadgetAttrs((struct Gadget *)tabobj, win, NULL,
                       CLICKTAB_Current, v, TAG_END);
    settitle();
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
    view = 0;
    maxwdirty = 1;
}


/* the whole text grid from the window's current size - run at
 * open and again on every IDCMP_NEWSIZE */

/* clamp every view's top against the current extents */

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
        if (loaddiff() == 0) view = 0;
    }
    arenafit();
    buildtabs();
    buildlist();
    settitle();
}

/* rediff the SAME pair, keeping the view and roughly the position -
 * the road home after an edit or an external change (F5) */
static void refreshdiff(void)
{
    int v = view;
    ULONG top = 0;
    if (listobj) GetAttr(LISTBROWSER_Top, listobj, &top);
    if (gf1[0] && gf2[0]) {
        if (loaddiff() == 0) view = v;
    }
    arenafit();
    buildtabs();
    buildlist();
    if (listobj)
        SetGadgetAttrs((struct Gadget *)listobj, win, NULL,
                       LISTBROWSER_Top, top, TAG_END);
    settitle();
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
    /* metrics come from the screen's font now that the custom
     * renderer (and its cached cell size) is gone */
    int cfw = 8, cfh = 8, fbase = 6;
    struct TextFont *font = NULL;
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
    okw = 6 * cfw + 8;
    okh = cfh + 6;
    ww = maxc * cfw + 32;
    if (ww < okw + 32) ww = okw + 32;
    wh = nl * cfh + okh + 28;
    scr = LockPubScreen(NULL);
    if (scr == NULL) return;
    if (scr->RastPort.Font) {
        font = scr->RastPort.Font;
        cfw = font->tf_XSize;
        cfh = font->tf_YSize;
        fbase = font->tf_Baseline;
    }
    ww = maxc * cfw + 32;
    if (ww < okw + 32) ww = okw + 32;
    wh = nl * cfh + okh + 28;
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
    if (font) SetFont(r, font);
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
                    y += cfh;
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
            Move(r, okx + (okw - 2 * cfw) / 2, oky + 3 + fbase);
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
                    buildlist();
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
    ULONG sigmask, result;
    UWORD code;
    int done = 0;

    NewList(&rowlist);
    NewList(&tablist);

    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
    GadToolsBase = OpenLibrary((STRPTR)"gadtools.library", 37);
    AslBase = OpenLibrary((STRPTR)"asl.library", 37);
    /* the ReAction classes that make this a real GUI app */
    WindowBase = OpenLibrary((STRPTR)"window.class", REACTVER);
    LayoutBase = OpenLibrary((STRPTR)"gadgets/layout.gadget", REACTVER);
    ListBrowserBase =
        OpenLibrary((STRPTR)"gadgets/listbrowser.gadget", REACTVER);
    ClickTabBase =
        OpenLibrary((STRPTR)"gadgets/clicktab.gadget", REACTVER);
    if (IntuitionBase == NULL || GfxBase == NULL) goto out;
    if (WindowBase == NULL || LayoutBase == NULL ||
        ListBrowserBase == NULL || ClickTabBase == NULL) {
        erq("cdiff needs the ReAction classes:\n"
            "window.class, layout.gadget,\n"
            "listbrowser.gadget, clicktab.gadget");
        goto out;
    }

    scr = LockPubScreen(NULL);
    if (scr == NULL) goto out;
    {
        struct DrawInfo *dri = GetScreenDrawInfo(scr);
        if (dri) {
            pshine = dri->dri_Pens[SHINEPEN];
            pshadow = dri->dri_Pens[SHADOWPEN];
            pfill = dri->dri_Pens[FILLPEN];
            pfilltext = dri->dri_Pens[FILLTEXTPEN];
            ptext = dri->dri_Pens[TEXTPEN];
            pback = dri->dri_Pens[BACKGROUNDPEN];
            FreeScreenDrawInfo(scr, dri);
        }
    }
    if (GadToolsBase) {
        gvi = GetVisualInfo(scr, TAG_DONE);
        if (gvi) {
            gmenu = CreateMenus(newmenu, TAG_DONE);
            if (gmenu)
                if (!LayoutMenus(gmenu, gvi,
                                 GTMN_NewLookMenus, TRUE, TAG_DONE)) {
                    FreeMenus(gmenu);
                    gmenu = NULL;
                }
        }
    }

    /* load first, so the tabs and the list have content to describe */
    if (gdirmode) {
        scandirs();
        view = 3;
    } else if (gf1[0] && gf2[0]) {
        if (loaddiff() == 0) view = 0;
    }
    arenafit();
    buildtabs();

    /* Each object is built by its OWN complete NewObject call
     * rather than the nested WindowObject/End macro style. Those
     * macros deliberately leave NewObject( unterminated and rely on
     * End to close it - which cannot work here, because in this NDK
     * NewObject is itself a variadic MACRO, and the preprocessor
     * does not expand the inner macros while collecting its
     * arguments, so it never sees a closing paren. Building each
     * object separately is equivalent, balanced, and lets every
     * step be checked. */
    tabobj = NewObject(CLICKTAB_GetClass(), NULL,
                       GA_ID, 100,
                       GA_RelVerify, TRUE,
                       CLICKTAB_Labels, (ULONG)&tablist,
                       CLICKTAB_Current, view == 3 ? 0 : view,
                       TAG_END);
    listobj = NewObject(LISTBROWSER_GetClass(), NULL,
                        GA_ID, 101,
                        GA_RelVerify, TRUE,
                        LISTBROWSER_AutoFit, TRUE,
                        LISTBROWSER_HorizontalProp, TRUE,
                        LISTBROWSER_ShowSelected, TRUE,
                        LISTBROWSER_ColumnInfo,
                            (ULONG)(view == 3 ? ci_tree :
                                    view == 0 ? ci_both : ci_one),
                        LISTBROWSER_Labels, (ULONG)&rowlist,
                        TAG_END);
    layoutobj = NewObject(LAYOUT_GetClass(), NULL,
                          LAYOUT_Orientation, LAYOUT_ORIENT_VERT,
                          LAYOUT_DeferLayout, TRUE,
                          LAYOUT_SpaceOuter, FALSE,
                          LAYOUT_AddChild, (ULONG)tabobj,
                          CHILD_WeightedHeight, 0,
                          LAYOUT_AddChild, (ULONG)listobj,
                          TAG_END);
    winobj = NewObject(WINDOW_GetClass(), NULL,
                       WA_Title, (ULONG)"cdiff",
                       WA_Activate, TRUE,
                       WA_DragBar, TRUE,
                       WA_DepthGadget, TRUE,
                       WA_CloseGadget, TRUE,
                       WA_SizeGadget, TRUE,
                       WA_SizeBBottom, TRUE,
                       WA_PubScreen, (ULONG)scr,
                       WA_Width, scr->Width,
                       WA_Height, scr->Height - scr->BarHeight - 1,
                       WA_IDCMP, IDCMP_RAWKEY | IDCMP_VANILLAKEY |
                                 IDCMP_IDCMPUPDATE,
                       WINDOW_Position, WPOS_CENTERSCREEN,
                       WINDOW_MenuStrip, (ULONG)gmenu,
                       WINDOW_ParentGroup, (ULONG)layoutobj,
                       TAG_END);
    UnlockPubScreen(NULL, scr);
    if (winobj == NULL) goto out;

    win = (struct Window *)RA_OpenWindow(winobj);
    if (win == NULL) goto out;

    buildlist();
    settitle();

    GetAttr(WINDOW_SigMask, winobj, &sigmask);
    while (!done) {
        ULONG sigs = Wait(sigmask | SIGBREAKF_CTRL_C);
        if (sigs & SIGBREAKF_CTRL_C) break;
        while ((result = RA_HandleInput(winobj, &code)) != WMHI_LASTMSG) {
            switch (result & WMHI_CLASSMASK) {
            case WMHI_CLOSEWINDOW:
                done = 1;
                break;
            case WMHI_MENUPICK:
                if (gmenu && domenu(code)) done = 1;
                break;
            case WMHI_GADGETUP:
                if ((result & WMHI_GADGETMASK) == 100) {
                    ULONG cur = 0;
                    GetAttr(CLICKTAB_Current, tabobj, &cur);
                    if ((int)cur < gntabs) setview(gtabvid[cur]);
                } else if ((result & WMHI_GADGETMASK) == 101) {
                    if (view == 3) opensel();
                }
                break;
            case WMHI_VANILLAKEY:
                switch (result & WMHI_KEYMASK) {
                case 27:
                    if (gdirmode && view != 3) setview(3);
                    else done = 1;
                    break;
                case 13: if (view == 3) opensel(); break;
                case 8: if (gdirmode && view != 3) setview(3); break;
                case '1': setview(0); break;
                case '2': setview(1); break;
                case '3': setview(2); break;
                case '0': setview(3); break;
                case 'n': case 'N':
                case 'p': case 'P': {
                    ULONG top = 0;
                    int d = ((result & WMHI_KEYMASK) == 'n' ||
                             (result & WMHI_KEYMASK) == 'N') ? 1 : -1;
                    GetAttr(LISTBROWSER_Top, listobj, &top);
                    SetGadgetAttrs((struct Gadget *)listobj, win, NULL,
                        LISTBROWSER_Top, nexthunk((int)top, d), TAG_END);
                    break;
                }
                }
                break;
            case WMHI_RAWKEY:
                if ((result & WMHI_KEYMASK) == 0x54) refreshdiff();
                break;
            }
            if (done) break;
        }
    }

    freerows();
    RA_CloseWindow(winobj);
    win = NULL;
out:
    if (winobj) DisposeObject(winobj);
    freetabs();
    free(arena);
    arena = NULL;
    if (gmenu) FreeMenus(gmenu);
    if (gvi) FreeVisualInfo(gvi);
    if (freq) FreeAslRequest(freq);
    if (ClickTabBase) CloseLibrary(ClickTabBase);
    if (ListBrowserBase) CloseLibrary(ListBrowserBase);
    if (LayoutBase) CloseLibrary(LayoutBase);
    if (WindowBase) CloseLibrary(WindowBase);
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
