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
#include <workbench/startup.h>
#include <workbench/workbench.h>
#include <dos/dostags.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/gadtools.h>
#include <proto/asl.h>
#include <proto/wb.h>
#include <proto/icon.h>
#include <proto/diskfont.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "diff.h"
#include "ltxwin.h"             /* cedit b0: the shared GUI chassis */

/* 'used' or -O2 strips it - and c:Version must find it */
static const char verstag[] __attribute__((used)) =
    "$VER: cdiff 0.1b109 (2.8.26)";

/* NO __stack here: his guru proved this libnix never reads it (nm
 * shows nothing referencing ___stack) - main swaps to a real 64K
 * stack itself via exec StackSwap, see the bottom of the file */

/* cedit b0: the library bases now live in ltxgui/ltxwin.c - still
 * strong definitions, still keeping libnix's auto-open modules out
 * of the link, and still opened ONLY by guimode so TEXT mode runs
 * where they don't exist (vamos). guimode opens them and closemain
 * closes them exactly as before. */

/* ---- b73: tooltype settings (his ask; a config FILE is explicitly
 * not wanted - the icon carries them). All optional, all inert when
 * absent, so a CLI launch behaves exactly as before. */
static char ttfont[64];         /* FONT=topaz.font/8 */
static int  ttfsize = 8;
static char tteditor[80];       /* EDITOR= - beats ENV:EDITOR */
static char ttdrawer[310];      /* DRAWER= - where the requester starts */
/* b79, his design and his keyword. OPENSCREEN= opens a screen of
 * OUR own: its presence decides that cdiff gets one, its value names
 * it. Deliberately NOT called PUBSCREEN - that keyword already means
 * "open my window on somebody else's public screen" throughout
 * Amiga software, which is the opposite of this and is exactly the
 * inert behaviour b77 removed. Reusing it would have misled anyone
 * who knows the convention. SCREENDEPTH= is a modifier and does
 * nothing on its own - without OPENSCREEN there is no screen of
 * ours to set the depth of, and without SCREENDEPTH the screen is
 * cloned from Workbench exactly. */
static char ttscrname[64];      /* OPENSCREEN= - name of OUR screen */
/* b80, his ask: PUBSCREEN= comes back, but now meaning exactly what
 * it means everywhere else in Amiga software - ATTACH to a public
 * screen somebody else already opened. It was removed at b77 only
 * because it was the sole screen option and could not create one;
 * beside OPENSCREEN= the pair is unambiguous, each doing precisely
 * what its name says. It is also more useful now than it was then:
 * the screen OPENSCREEN= makes IS public, so a second cdiff can
 * attach to the first one's screen. */
static char ttpubscr[64];       /* PUBSCREEN= - somebody else's */
static int  ttdepth;            /* SCREENDEPTH= - 0 = clone WB */
/* cedit b0b: ttstatus lives in ltxwin.c - it decides the grid */
static int  ttcontext = 3;      /* CONTEXT=n around each change */
/* cedit b6: FASTSCROLL is gone entirely (his call). It was a
 * bisection tool from b92 that outlived its question, and its
 * default was left on the slow side - so every one-line scroll
 * repainted every row. The blit is now simply what scrolling is. */
/* cedit b0b: tttab/ttmask live in ltxwin.c - the row painter owns
 * the tab grid. readtooltypes still sets them from TABSIZE=. */
static int  ttleft = -1, tttop = -1, ttwidth = -1, ttheight = -1;
/* b75: VIEW= removed (his call). It earned nothing: TREE re-set a
 * view gdirmode had already set, BOTH re-set the zero default, and
 * LEFT/RIGHT only bit when a pair was already loaded - i.e. only
 * when project icons had been dropped on the cdiff icon. Two live
 * values in one narrow case, against a tooltype to learn and to
 * document, while 1/2/3 and Tab switch views instantly anyway. */
/* cedit b0: ttoollock/ttoolname moved to ltxwin.c - iconset() needs
 * them and so does the AppIcon, both of which are chassis business */
/* cedit b0b: the font we opened is the chassis's - ltx_closefont */

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

/* b82: the status row's numbers. Hunk starts are per-VIEW (the row
 * numbering differs), the diffstat is per-PAIR. Both cached and
 * rebuilt lazily - a status row that rescanned 12000 rows on every
 * scroll would undo b12 and b62 in one go. */
static int *ghs;                /* hunk start rows, ascending */
static int ghn, ghcap, ghdirty = 1;
static int gadds, gdels;        /* +a -d, counted from grows */

/* b104, his ask: "differences only". A DISPLAY MAP over the active
 * view - each entry is either a real row index, or a NEGATIVE number
 * carrying how many rows were collapsed there, drawn as a marker.
 * Everything else in the program keeps working in display indices,
 * so scrolling, the scrollbars, find and the hunk counter need no
 * idea the filter exists; only the three places that turn a display
 * index into content have to translate. Rebuilt lazily like the
 * width scan and the hunk index, and invalidated at the same points. */
static int ttdiffs;             /* the mode, session only */
static int *dmap;
static int dmapn, dmapcap, dmapdirty = 1;

/* b67: find state (his ask, modelled on a Navigation menu with
 * Find.../Find Next/Find Previous). findrow is the matched row in
 * the ACTIVE view's row numbering, -1 when nothing is current.
 * Declared up here with gmaxw for the same reason: freedirs and
 * scandirs need to clear it. */
static char findstr[80];
static int findrow = -1, findn, findof;

/* b102, his ask: a busy pointer while we are working, so loading a
 * pair or walking two directory trees does not look like a hang.
 * cedit b0: declared by ltxwin.h now. */
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
    ghdirty = 1;            /* b82: and the hunk index */
    dmapdirty = 1;          /* b104: and the diffs-only map */
    findrow = -1; findn = findof = 0;   /* b67: row numbering changed */
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
static void scandirs_(void);

static void scandirs(void)
{
    busy(1);
    scandirs_();
    busy(0);
}

static void scandirs_(void)
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
    ghdirty = 1;            /* b82: and the hunk index */
    dmapdirty = 1;          /* b104: and the diffs-only map */
    findrow = -1; findn = findof = 0;   /* b67: row numbering changed */
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

/* cedit b0: win, goodfont/tryfont and busy moved to ltxwin.c. The
 * window handle keeps its name there, so every use below is
 * unchanged. */

/* cedit b0b: rp, font and the cell metrics live in ltxwin.c now */
static int halfw;                      /* columns per side */
/* b67: the leftmost content column is reserved for the find caret,
 * so cx0/cvis are the grid the file views actually lay out in. The
 * Tree keeps its own 4-column prefix and ignores these - a find
 * there moves the selection cursor, which is marker enough. */
static int cx0, cvis, markcol;

static const DLine *ga, *gb;
static Row *grows;
static int gnrows, gtop;
static int gna, gnb;            /* line counts, for the gutter width */
/* cedit b0b: gutw lives in ltxwin.c, beside the drawnum that uses it */

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
/* cedit b0b: hoff lives in ltxwin.c - the painter windows by it */
static char *gatag, *gbtag;     /* per-line diff tag, ' ' = equal */

/* cedit b0b: the hit ranges are ltx_tabx/ltx_tabe now */
static int tabsok;              /* tab bar live (files loaded) */

/* cedit b0b: the grid, the pens and the scroll engine live in
 * ltxwin.c now - see the LtxApp vtable further down for how the
 * chassis asks this program what it is scrolling. */

static int gntabs, gtabvid[4];  /* live tabs -> view ids */

/* cedit b0b: the scroller gadgets and the deferred-paint flags
 * live in ltxwin.c */

static int selold, seloldset;   /* Tree cursor's painted row - the
                                 * app half of the paint debt; the
                                 * chassis knows it only as
                                 * ltx_appowed */

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
/* b97: expand a line into columns exactly as drawtext renders it -
 * same tab rule, same control-char substitution - so an intra-line
 * comparison can never disagree with what is on screen */
static int expandcols(const DLine *l, char *out, int max)
{
    int i, o = 0;
    for (i = 0; i < l->len && o < max; i++) {
        char ch = l->ptr[i];
        if (ch == '\t') {
            do {
                out[o++] = ' ';
            } while ((ttmask ? (o & ttmask) : (o % tttab)) && o < max);
        } else
            out[o++] = (ch >= 32 || ch < 0) ? ch : '.';
    }
    return o;
}

/* b97, the intra-line span: trim the longest common PREFIX and the
 * longest common SUFFIX, and whatever is left in the middle is what
 * actually changed. Two cheap scans instead of a character-level
 * LCS, and it catches what real edits look like - an identifier
 * renamed, a number changed, a word inserted. When a line was
 * rewritten wholesale the span is the whole line, which is the
 * truth. Columns, not bytes, so tabs cannot shift it. */
/* b103, his find: character-exact trimming cuts INSIDE words. On
 *   left  "       'dos/datetime','dos/dostags','devices/inputevent',"
 *   right "       'devices/inputevent',"
 * both lines happen to share "'d", so the prefix ate it and the span
 * came out shifted one character right - starting mid-token and
 * ending on a stray "d". Correct to the letter, and it reads as a
 * mistake.
 *
 * So: back each boundary off a split word. Moving the FRONT left is
 * always safe (the prefix was common, marking more of it can only be
 * honest). Moving the BACK left extends the common suffix, so it is
 * allowed only while the characters being moved into it actually
 * match on both sides.
 *
 * Deliberately only ever shrinks the marked span or grows it at the
 * front - never grows it at the back. Growing outward to whole words
 * would tidy "1000" vs "600" (marked "10"/"6" today) but it would
 * also mark text that DID NOT CHANGE, and marking unchanged text is
 * the one thing this must not do. */
static int wordch(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

/* is position i a clean break - i.e. NOT in the middle of a word? */
static int cleanat(const char *s, int len, int i)
{
    return i <= 0 || i >= len || !wordch(s[i - 1]) || !wordch(s[i]);
}

static void snapspan(const char *ca, int la, const char *cb, int lb,
                     int *pre, int *enda, int *endb)
{
    int p = *pre, ea = *enda, eb = *endb;
    while (p > 0 && (!cleanat(ca, la, p) || !cleanat(cb, lb, p)))
        p--;
    while (ea > p && eb > p &&
           (!cleanat(ca, la, ea) || !cleanat(cb, lb, eb)) &&
           ca[ea - 1] == cb[eb - 1]) {
        ea--; eb--;
    }
    *pre = p;
    *enda = ea < p ? p : ea;
    *endb = eb < p ? p : eb;
}

static void intraspan(const DLine *a, const DLine *b,
                      int *pre, int *enda, int *endb)
{
    static char ca[512], cb[512];
    int la = expandcols(a, ca, sizeof(ca));
    int lb = expandcols(b, cb, sizeof(cb));
    int p = 0, sfx = 0, maxs;
    /* b100, and this cost a screenshot's worth of pixel forensics:
     * written as a THREE-term condition
     *
     *     while (p < la && p < lb && ca[p] == cb[p]) p++;
     *
     * bebbo's gcc MISCOMPILES this at -O2 on m68k. It stopped at
     * p=1 where the answer is 11, so the marked span started at the
     * second character of every changed line. -O1 and -O0 are
     * correct, and so is the two-term suffix loop below - the bound
     * has to come out of the condition. Verified on target under
     * vamos, not guessed: -O2 gave 1, -O1 and -O0 gave 11, and
     * hoisting the min fixed it at -O2.
     * Hoisting is better code regardless: one compare per iteration
     * instead of two. */
    {
        int lim = la < lb ? la : lb;
        while (p < lim && ca[p] == cb[p]) p++;
    }
    maxs = (la < lb ? la : lb) - p;     /* never overlap the prefix */
    while (sfx < maxs && ca[la - 1 - sfx] == cb[lb - 1 - sfx]) sfx++;
    *pre = p;
    *enda = la - sfx;
    *endb = lb - sfx;
    snapspan(ca, la, cb, lb, pre, enda, endb);
}

/* cedit b0b: the painter itself is ltx_drawruns() now, and takes N
 * runs instead of exactly three. This is the same b97 arithmetic,
 * only it builds a run list rather than laying the three Texts down
 * itself: hs/he are SOURCE columns, mapped into visible ones and
 * clamped exactly as before, and an empty span still collapses to
 * one full-width run. What cdiff hands over is a diff span; what
 * cedit will hand over is a lexer's output. */
static void drawtext(int x, int y, const DLine *l, int width,
                     int pen, int bg, int hs, int he, int hpen, int hbg)
{
    LtxRun runs[3];
    int nr = 0;
    width = ltx_expandvis(l->ptr, l->len, width);
    if (width <= 0) return;
    hs -= hoff; he -= hoff;             /* into visible columns */
    if (hs < 0) hs = 0;
    if (he > width) he = width;
    runs[nr].start = 0; runs[nr].pen = pen; runs[nr].bg = bg; nr++;
    if (hs < he) {                      /* something to mark */
        if (hs > 0) {
            runs[nr].start = hs; runs[nr].pen = hpen; runs[nr].bg = hbg;
            nr++;
        } else {                        /* the span starts at column 0 */
            runs[0].pen = hpen; runs[0].bg = hbg;
        }
        if (he < width) {
            runs[nr].start = he; runs[nr].pen = pen; runs[nr].bg = bg;
            nr++;
        }
    }
    ltx_drawruns(x, y, ltx_vis, width, runs, nr);
}

/* cedit b0b: drawnum moved to ltxwin.c - a gutter is a gutter */

/* one side of a row: optional bar fill, gutter number, the text,
 * within a `w`-column budget (halfw in the overview, viscols in a
 * single-file tab). The gutter recedes by palette hierarchy (his
 * ask - there is no dark grey on a 4-colour WB): blue-on-gray for
 * plain rows, black-on-blue under the bar - always a step quieter
 * than the content beside it. */
static int vcount(void);        /* b104: all defined further down */
static int drow(int i);
static void builddmap(void);

/* b104: a collapsed run, drawn as a centred rule with the count -
 * "-- 47 lines --". Keeps the reader oriented across a gap, which
 * is the whole reason gaps get a row at all instead of just closing
 * up. One padded Text, like every other row (the b66 rule). */
static void drawgap(int y, int hidden)
{
    static char gb[160];
    int i, w = viscols, len, pad;
    if (w > (int)sizeof(gb) - 1) w = sizeof(gb) - 1;
    if (w < 1) return;
    sprintf(gb, "-- %d line%s --", hidden, hidden == 1 ? "" : "s");
    len = strlen(gb);
    if (len > w) len = w;
    pad = (w - len) / 2;
    memmove(gb + pad, gb, len);
    for (i = 0; i < pad; i++) gb[i] = ' ';
    for (i = pad + len; i < w; i++) gb[i] = ' ';
    /* b105 (his eye): white, not black. A gap marker should RECEDE -
     * it says "nothing here", and white on the grey reads as quieter
     * than the black the real content is drawn in. The same palette
     * hierarchy b4 used to push the gutter back. */
    SetAPen(rp, 2);
    SetBPen(rp, 0);
    Move(rp, gx0, y + fbase);
    Text(rp, (STRPTR)gb, w);
}

/* b67: the find caret in the reserved column - always on the plain
 * background so it stays legible whether or not the row is a bar */
static void drawmark(int y, int hit)
{
    static const char m[1] = { '>' };
    static const char b[1] = { ' ' };
    if (!markcol) return;
    SetAPen(rp, 1);
    SetBPen(rp, 0);
    Move(rp, gx0, y + fbase);
    Text(rp, (STRPTR)(hit ? m : b), 1);
}

static void drawside(int x, int y, const DLine *l, long line,
                     int bar, int w, int hs, int he)
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
    /* b98 (his call): the changed span goes BLACK on the bar's own
     * blue, rather than b97's inversion to blue-on-white. Keeps the
     * row reading as one surface - only the text darkens. */
    drawtext(tx, y, l, tw, bar ? 2 : 1, bar ? 3 : 0, hs, he, 1, 3);
}

/* changed rows are BAR rows - pen-3 fill, white text, the CFile
 * selection-bar look - because pen-3 text on WB gray barely reads
 * (first-run screenshot lesson, 1.8.26). An inserted EMPTY line
 * shows as a solid bar instead of a naked marker. The untouched
 * side of a one-sided row stays gray: nothing lives there. */
static void drawrow(int vr)
{
    int di = gtop + vr, idx;
    int y = conty + vr * fh, ye = y + fh - 1;
    int rend = gx0 + viscols * fw - 1;
    int bar, x1, se;
    int hpre = 0, hea = 0, heb = 0;     /* b97: intra-line span */
    Row *r;
    if (di >= vcount()) {               /* past the end: blank */
        SetAPen(rp, 0);
        RectFill(rp, gx0, y, rend, ye);
        return;
    }
    idx = drow(di);                     /* b104 */
    if (idx < 0) {                      /* a collapsed run */
        SetAPen(rp, 0);
        RectFill(rp, gx0, y, rend, ye);
        drawgap(y, -idx);
        return;
    }
    if (idx >= gnrows) {
        SetAPen(rp, 0);
        RectFill(rp, gx0, y, rend, ye);
        return;
    }
    r = &grows[idx];
    bar = r->tag != ' ';
    x1 = cx0 + (halfw + 3) * fw;        /* right pane's left edge */
    drawmark(y, findrow >= 0 && idx == findrow);
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
    RectFill(rp, cx0 + halfw * fw, y, x1 - 1, ye);      /* marker gap */
    if (r->al < 0)                      /* one-sided: no left pane */
        RectFill(rp, cx0, y, cx0 + halfw * fw - 1, ye);
    if (r->bl < 0)
        RectFill(rp, x1, y, x1 + halfw * fw - 1, ye);
    se = x1 + halfw * fw;               /* sub-cell slack on the right */
    if (se <= rend) RectFill(rp, se, y, rend, ye);
    /* b97: only a '|' row has two lines to compare. A '<' or '>'
     * row has nothing on the other side, and an equal row nothing
     * to mark. */
    if (r->tag == '|' && r->al >= 0 && r->bl >= 0)
        intraspan(&ga[r->al], &gb[r->bl], &hpre, &hea, &heb);
    if (r->al >= 0)
        drawside(cx0, y, &ga[r->al], r->al, bar, halfw, hpre, hea);
    if (bar) {
        SetAPen(rp, 3);
        SetBPen(rp, 0);
        Move(rp, cx0 + (halfw + 1) * fw, y + fbase);
        Text(rp, (STRPTR)&r->tag, 1);
    }
    if (r->bl >= 0)
        drawside(x1, y, &gb[r->bl], r->bl, bar, halfw, hpre, heb);
}

/* the active view's scroll top and extent (3 = the Tree tab) */
static int *vtop(void)
{
    return view == 0 ? &gtop : view == 1 ? &ltop :
           view == 2 ? &rtop : &dtop;
}

static int vcount(void)
{
    /* b104: with the filter on, the view is as long as the map */
    if (ttdiffs && view != 3) {
        if (dmapdirty) builddmap();
        if (dmapn > 0) return dmapn;
    }
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
        if (p[i] == '\t') {
            do { o++; } while (ttmask ? (o & ttmask) : (o % tttab));
        }
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

/* b104: build the display map for the active view. A row is KEPT if
 * it differs, or lies within CONTEXT rows of one that does; every
 * run of dropped rows collapses to a single marker entry carrying
 * its count. Context is what makes this readable rather than merely
 * shorter - a changed line with nothing around it is hard to place. */
static void builddmap(void)
{
    int n, i, run = 0;
    dmapdirty = 0;
    dmapn = 0;
    if (view == 3) return;              /* the Tree is already only
                                         * differing entries */
    n = view == 0 ? gnrows : view == 1 ? gna : gnb;
    for (i = 0; i < n; i++) {
        int keep = 0, j;
        for (j = i - ttcontext; j <= i + ttcontext && !keep; j++) {
            if (j < 0 || j >= n) continue;
            if (view == 0) keep = grows && grows[j].tag != ' ';
            else if (view == 1) keep = gatag && gatag[j] != ' ';
            else keep = gbtag && gbtag[j] != ' ';
        }
        if (!keep) { run++; continue; }
        if (dmapn + 2 > dmapcap) {      /* room for a marker AND a row */
            int nc = dmapcap ? dmapcap * 2 : 256;
            int *np = realloc(dmap, nc * sizeof(int));
            if (np == NULL) { dmapn = 0; return; }  /* degrade: no filter */
            dmap = np;
            dmapcap = nc;
        }
        if (run) { dmap[dmapn++] = -run; run = 0; }
        dmap[dmapn++] = i;
    }
    if (run && dmapn + 1 <= dmapcap) dmap[dmapn++] = -run;
}

/* display index -> row index, or NEGATIVE carrying the collapsed
 * count for a marker. Identity when the filter is off, which is why
 * nothing else in the program has to know about it. */
static int drow(int i)
{
    if (!ttdiffs || view == 3) return i;
    if (dmapdirty) builddmap();
    if (dmapn == 0) return i;           /* nothing built - fall back */
    if (i < 0 || i >= dmapn) return -1;
    return dmap[i];
}

/* b82: one pass collecting every hunk START in the active view, and
 * the pair's +a/-d. A hunk is a maximal run of non-equal rows, the
 * same definition nexthunk() walks. Lazy, like calcmaxw. */
static void calchunks(void)
{
    const char *tg = view == 1 ? gatag : view == 2 ? gbtag : NULL;
    int n = vcount(), i, prev = 0;

    ghn = 0;
    ghdirty = 0;
    gadds = gdels = 0;
    /* the diffstat describes the PAIR, not the tab he happens to be
     * on, so it always comes from the row model. A changed line is
     * one deletion and one insertion, as diffstat has it. */
    if (grows) {
        for (i = 0; i < gnrows; i++) {
            char t = grows[i].tag;
            if (t == '>') gadds++;
            else if (t == '<') gdels++;
            else if (t == '|') { gadds++; gdels++; }
        }
    }
    if (n <= 0) return;
    for (i = 0; i < n; i++) {
        int hit, ri = drow(i);          /* b104 */
        if (ri < 0) { prev = 0; continue; }     /* marker breaks a run */
        if (view == 3)      hit = dents[ri].st != 'S';
        else if (view == 0) hit = grows && grows[ri].tag != ' ';
        else                hit = tg && tg[ri] != ' ';
        if (hit && !prev) {
            if (ghn >= ghcap) {
                int nc = ghcap ? ghcap * 2 : 64;
                int *np = realloc(ghs, nc * sizeof(int));
                if (np == NULL) break;  /* keep what we have */
                ghs = np;
                ghcap = nc;
            }
            ghs[ghn++] = i;
        }
        prev = hit;
    }
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
        RectFill(rp, gx0, y, gx0 + viscols * fw - 1, y + fh - 1);
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
        Move(rp, gx0, y + fbase);
        Text(rp, (STRPTR)pre, 2);
        pre[0] = st;
        SetAPen(rp, bar ? 2 : 1);
        SetBPen(rp, bar ? 3 : 0);
        Move(rp, gx0 + 2 * fw, y + fbase);
        Text(rp, (STRPTR)pre, 2);
    }
    sprintf(pbuf, "%.400s%s", d->rel, d->isdir ? "/" : "");
    tl.ptr = pbuf;
    tl.len = strlen(pbuf);
    tl.hash = 0;
    drawtext(gx0 + 4 * fw, y, &tl, viscols - 4,
             bar ? 2 : 1, bar ? 3 : 0, 0, 0, 0, 0);
}

/* one full-width line of a single-file tab */
static void drawline(int vr)
{
    int di = *vtop() + vr, line;
    int y = conty + vr * fh, ye = y + fh - 1;
    int rend = gx0 + viscols * fw - 1;
    const DLine *l;
    char tag;
    if (di >= vcount()) goto blank;
    line = drow(di);                    /* b104 */
    if (line < 0) {                     /* a collapsed run */
        SetAPen(rp, 0);
        RectFill(rp, gx0, y, rend, ye);
        drawgap(y, -line);
        return;
    }
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
    drawmark(y, findrow >= 0 && line == findrow);
    /* b97: no intra-line marking here - the paired line is not in
     * this view, and finding it would need a reverse line->row map.
     * The Both tab is where you compare. */
    drawside(cx0, y, l, line, tag != ' ', cvis, 0, 0);
    return;
blank:
    SetAPen(rp, 0);
    RectFill(rp, gx0, y, rend, ye);
}

/* the tab bar: real GUI tabs (his ask) - beveled boxes in the
 * screen's DrawInfo pens, the active one filled and opening into
 * the content through a gap in the base rule. Directory mode adds
 * a Tree tab ahead of the file three. */
/* cedit b0b: the bevel drawing and the hit ranges are the chassis's
 * ltx_drawtabs() now. What stays here is what the tabs MEAN - which
 * views exist, what they are called, and which one is current. */
static void drawtabs(void)
{
    static char lab[4][40];
    const char *labs[4];
    int i, nt = 0, act = 0;
    tabsok = (ga != NULL) || gdirmode;
    if (!tabsok) {
        gntabs = 0;
        ltx_drawtabs(NULL, 0, 0, 0);    /* clears the bar */
        return;
    }
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
    for (i = 0; i < nt; i++) {
        labs[i] = lab[i];
        if (gtabvid[i] == view) act = i;
    }
    /* cdiff's tabs are views, not documents - nothing to close */
    ltx_drawtabs(labs, nt, act, 0);
}

static void calcgrid(void);     /* b68: the grid follows find state */

static void drawpage(void)
{
    int vr, s, e;
    if (win == NULL) return;    /* b72: iconified */
    if (defer) { dirtyall = 1; return; }
    /* the caret column comes and goes with the search, and a find
     * can be cleared from paths that never call calcgrid (reload,
     * view switch, rescan) - so reconcile here, cheaply, and only
     * when the two actually disagree */
    if (markcol != (findrow >= 0)) calcgrid();
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
    s = gx0 + viscols * fw;
    e = win->Width - win->BorderRight - 1;
    if (s <= e)
        /* from CONTY, not gy0 (cedit b2, his find): this strip is
         * the sub-cell remainder, 0 to fw-1 pixels wide, and
         * starting it at the top of the window painted it over the
         * right end of the tab bar - drawn moments earlier - in
         * background grey, cutting the base rule short. The bar
         * paints its own full width; this only ever needed to cover
         * the content. */
        RectFill(rp, s, conty, e, win->Height - win->BorderBottom - 1);
    s = conty + crows * fh;
    e = win->Height - win->BorderBottom - 1;
    if (s <= e)
        RectFill(rp, gx0, s, xend, e);
    /* b86: the right-hand sliver, once, for the full content height.
     * The scroll rect stops at the cell grid so ScrollWindowRaster
     * never disturbs it - it only needs painting when the whole page
     * does, which is one blit instead of one per row. */
    if (slx <= xend)
        RectFill(rp, slx, conty, xend, e);
    drawstatus();               /* b82: over the slack we just cleared */
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
            Move(rp, gx0 + 2 * fw, conty + fh + fbase);
            Text(rp, (STRPTR)hint, hl);
        }
    }
}

static void settitle(void)
{
    static char t[400];
    if (win == NULL) return;    /* b72: iconified */
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
    /* b71: a drawer dropped on one side, still waiting for the
     * other - say so, or the window just sits there looking idle */
    else if (gdir1[0] && !gdir2[0])
        sprintf(t, "cdiff: %.60s | (now drop the RIGHT drawer)", gdir1);
    else if (gdir2[0] && !gdir1[0])
        sprintf(t, "cdiff: (now drop the LEFT drawer) | %.60s", gdir2);
    else
        strcpy(t, "cdiff");
    if (findrow >= 0 && findn > 0) {    /* b67: which match, of how many */
        char fb[140];
        sprintf(fb, "  [Find \"%.40s\" %d/%d]", findstr, findof, findn);
        strcat(t, fb);
    }
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

/* ---- cedit b0b: what the chassis is allowed to ask this program --
 * The scroll engine in ltxwin.c knows how to blit a rectangle and
 * repaint the rows that entered; it does not know that cdiff's rows
 * are diff rows, or that view 3 is a directory tree. These eight
 * answers are the entire surface between the two, and they are the
 * reason cedit can hand the same engine a Buffer instead. */

/* b82: the status row's left-hand text - hunk position and the
 * diffstat. The hunk index is a binary search over a lazily-rebuilt
 * array, never a rescan of 12000 rows: this runs on every position
 * change, and b82's whole lesson was that it has to be cheap. */
static void cdiffstatus(char *dst, int max)
{
    int idx, lo, hi;
    if (ghdirty) calchunks();
    lo = 0; hi = ghn;
    while (lo < hi) {
        int mid = (lo + hi) / 2;
        if (ghs[mid] <= *vtop()) lo = mid + 1; else hi = mid;
    }
    idx = lo;
    if (view == 3 && gdirmode)
        sprintf(dst, " %d entries  %d differ %d left %d right",
                ndents, gndiff, gnleft, gnright);
    else if (ga)
        sprintf(dst, " hunk %d/%d  +%d -%d", idx, ghn, gadds, gdels);
    else
        strcpy(dst, " nothing loaded");
    (void)max;      /* every branch above is far inside sb[320] */
}

/* the Tree cursor's two rows - the app's own half of the paint debt */
static void cdiffflush(void)
{
    if (!seloldset) return;
    if (selold >= dtop && selold < dtop + crows)
        drawone(selold - dtop);
    if (dsel >= dtop && dsel < dtop + crows)
        drawone(dsel - dtop);
    seloldset = 0;
}

static const LtxApp cdiffapp = {
    vcount, vtop, htotal, drawone, drawrows, drawpage,
    cdiffstatus, cdiffflush
};


/* next/previous hunk in the active view: rows in the overview,
 * tagged lines in a single-file tab, non-same entries in the Tree */
static int nexthunk(int from, int dir)
{
    const char *tg = view == 1 ? gatag : gbtag;
    int n = vcount(), i = from + dir;
    if (ttdiffs && view != 3) {
        /* b104: with the filter on almost every row is interesting,
         * so walk the display rows and stop on the next real one
         * that differs - the markers are the boundaries */
        while (i > 0 && i < n && drow(i) < 0) i += dir;
        if (i < 0 || i >= n) return from;
        return i;
    }
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
        ltx_appowed = 1;        /* cedit b0b: tell the chassis */
        return;
    }
    if (old >= dtop && old < dtop + crows)
        drawone(old - dtop);
    if (dsel >= dtop && dsel < dtop + crows)
        drawone(dsel - dtop);
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
     * sides, Tree measures paths), so a view change invalidates it.
     * b67: and findrow is a row index in the OLD view's numbering -
     * the term survives a view switch, the hit cannot. */
    maxwdirty = 1;
    ghdirty = 1;            /* b82: and the hunk index */
    dmapdirty = 1;          /* b104: and the diffs-only map */
    findrow = -1; findn = findof = 0;
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

/* error requester - works with win = NULL too (before the window),
 * and a WB start has no shell to print into */
/* cedit b2: erq/askfile are the chassis's ltx_msg/ltx_askfile now
 * - cedit became the second caller, which is when they move. */

/* ---- b67: find ------------------------------------------------
 * Case-insensitive substring over the ACTIVE view's rows: Both
 * searches either side of a row, a single-file tab searches that
 * file, the Tree searches the paths. Searching what is on screen is
 * the whole contract - a hit you cannot see would be a lie. */

static int memfind(const char *hay, int hlen, const char *nee, int nlen)
{
    int i, j;
    if (nlen <= 0 || nlen > hlen) return 0;
    for (i = 0; i <= hlen - nlen; i++) {
        for (j = 0; j < nlen; j++) {
            char a = hay[i + j], b = nee[j];
            if (a >= 'A' && a <= 'Z') a += 32;
            if (b >= 'A' && b <= 'Z') b += 32;
            if (a != b) break;
        }
        if (j == nlen) return 1;
    }
    return 0;
}

static int rowhas(int row, const char *nee, int nlen)
{
    row = drow(row);            /* b104: display index -> real row */
    if (row < 0) return 0;      /* a collapsed-run marker */
    if (view == 3) {
        if (row < 0 || row >= ndents) return 0;
        return memfind(dents[row].rel, strlen(dents[row].rel), nee, nlen);
    }
    if (view == 0) {
        Row *r;
        if (row < 0 || row >= gnrows) return 0;
        r = &grows[row];
        if (r->al >= 0 && ga &&
            memfind(ga[r->al].ptr, ga[r->al].len, nee, nlen)) return 1;
        if (r->bl >= 0 && gb &&
            memfind(gb[r->bl].ptr, gb[r->bl].len, nee, nlen)) return 1;
        return 0;
    }
    if (view == 1) {
        if (!ga || row < 0 || row >= gna) return 0;
        return memfind(ga[row].ptr, ga[row].len, nee, nlen);
    }
    if (!gb || row < 0 || row >= gnb) return 0;
    return memfind(gb[row].ptr, gb[row].len, nee, nlen);
}

/* One pass over the view: count EVERY match (so the title can say
 * "3/17") and pick the hit in `dir`, wrapping at the ends. Counting
 * costs the same scan the search needs anyway, and being exact after
 * a reload or a view switch beats caching a number that can rot.
 * `fresh` starts from where he is looking rather than from the
 * previous hit. */
static void gofind(int dir, int fresh)
{
    int n = vcount(), nlen = strlen(findstr);
    int r, cnt = 0, ord = 0;
    int first = -1, last = -1, nxt = -1, prv = -1;
    int fo = 0, lo = 0, no = 0, po = 0, start, hit;

    if (nlen == 0) return;
    if (n <= 0) { ltx_msg("nothing loaded to search"); return; }
    start = fresh ? (view == 3 ? dsel : *vtop())
                  : (findrow >= 0 ? findrow + dir : 0);

    for (r = 0; r < n; r++) {
        if (!rowhas(r, findstr, nlen)) continue;
        ord = ++cnt;
        if (first < 0) { first = r; fo = ord; }
        last = r; lo = ord;
        if (dir > 0 && nxt < 0 && r >= start) { nxt = r; no = ord; }
        if (dir < 0 && r <= start)            { prv = r; po = ord; }
    }
    if (cnt == 0) {
        findrow = -1;
        findn = findof = 0;
        calcgrid();                     /* b68: and goes away again */
        settitle();
        drawpage();
        ltx_msg("not found");
        return;
    }
    if (dir > 0) { hit = nxt >= 0 ? nxt : first; findof = nxt >= 0 ? no : fo; }
    else         { hit = prv >= 0 ? prv : last;  findof = prv >= 0 ? po : lo; }

    findrow = hit;
    findn = cnt;
    calcgrid();                         /* b68: the caret column appears */
    if (view == 3)
        movesel(hit);                   /* the Tree's own cursor marks it */
    else
        scrollto(hit - crows / 2);      /* centred, per his pick */
    settitle();
    drawpage();                         /* the caret moved rows */
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
    ghdirty = 1;            /* b82: and the hunk index */
    dmapdirty = 1;          /* b104: and the diffs-only map */
    findrow = -1; findn = findof = 0;   /* b67: row numbering changed */
}

static void calcgut(void)
{
    int m = gna > gnb ? gna : gnb;
    gutw = 1;
    while (m >= 10) { m /= 10; gutw++; }
    if (halfw < gutw + 12) gutw = 0;    /* too narrow: no gutter */
}

/* the whole text grid from the window's current size - run at
 * open and again on every IDCMP_NEWSIZE.
 *
 * cedit b0b: the generic half is ltx_calcgrid() - the drawable
 * grid, the tab bar height, the status row and the content rows.
 * What stays here is what depends on WHAT CDIFF PUTS IN the grid:
 * the find caret's reserved column, the two panes, the gutter. None
 * of it feeds back into the chassis numbers, so the order is safe. */
static void calcgrid(void)
{
    ltx_calcgrid();
    /* b68 (his call): the caret column is reserved ONLY while a
     * find is current - no search, no shifted text. b67 reserved it
     * always, which moved a layout he had already signed off for a
     * feature that is idle most of the time. Dropped again when the
     * window is too narrow to spare the column. */
    markcol = findrow >= 0;
    cx0 = gx0;
    cvis = viscols;
    if (markcol) {
        if (viscols - 1 >= 8) { cx0 = gx0 + fw; cvis = viscols - 1; }
        else markcol = 0;
    }
    halfw = (cvis - 3) / 2;
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
/* b96, his question - "should I really be able to open binaries,
 * images, .info files, modules, samples, archives?" No.
 *
 * A line diff of a binary is not merely useless, it MISLEADS: lines
 * break at stray 0x0A bytes that mean nothing, every non-printable
 * renders as '.', so two rows that genuinely differ get flagged as
 * changed and drawn as a bar while looking identical on screen. The
 * tool would be saying "these differ" and then showing nothing. That
 * is the same lie b24 refused for the Tree's same-size pairs and the
 * find refuses by only searching what is on screen.
 *
 * A NUL byte is the standard test and is reliable for Amiga text -
 * source, scripts, guides and readmes do not contain one. Only the
 * head is scanned: enough to classify, cheap on a big file. */
#define BINSCAN 8192

static int isbinary(const char *buf, long size)
{
    long i, n = size < BINSCAN ? size : BINSCAN;
    for (i = 0; i < n; i++)
        if (buf[i] == 0) return 1;
    return 0;
}

/* where the two byte streams first disagree, or -1 when the shorter
 * is a prefix of the longer AND they are the same length */
static long firstdiff(const char *a, long na, const char *b, long nb)
{
    long i, n = na < nb ? na : nb;
    for (i = 0; i < n; i++)
        if (a[i] != b[i]) return i;
    return na == nb ? -1 : n;   /* identical prefix, one runs on */
}

/* the honest verdict, in place of a diff that would mean nothing */
static void binverdict(char *out, const char *n1, long s1, int b1,
                       const char *n2, long s2, int b2)
{
    const char *what = (b1 && b2) ? "both files are binary" :
                       b1 ? "the LEFT file is binary"
                          : "the RIGHT file is binary";
    sprintf(out, "%s - cdiff compares text\n\n"
                 "%.40s  %ld bytes\n%.40s  %ld bytes\n\n",
            what, (char *)FilePart((STRPTR)n1), s1,
            (char *)FilePart((STRPTR)n2), s2);
}

static int loaddiff_(void);

/* b102: wrapped rather than threaded through - loaddiff_ has four
 * exit paths and every one of them must clear the pointer */
static int loaddiff(void)
{
    int r;
    busy(1);
    r = loaddiff_();
    busy(0);
    return r;
}

static int loaddiff_(void)
{
    long sz1, sz2;
    int na, nb, nops, nrows;
    static char eb[360];
    freediff();
    gbuf1 = loadfile(gf1, &sz1);
    if (gbuf1 == NULL) {
        sprintf(eb, "cannot read %.300s", gf1);
        ltx_msg(eb);
        return -1;
    }
    gbuf2 = loadfile(gf2, &sz2);
    if (gbuf2 == NULL) {
        sprintf(eb, "cannot read %.300s", gf2);
        ltx_msg(eb);
        freediff();
        return -1;
    }
    {   /* b96: classify before splitting - a line diff of a binary
         * would be a lie, and building one costs a DLine per stray
         * newline in a file that has no lines at all */
        int b1 = isbinary(gbuf1, sz1), b2 = isbinary(gbuf2, sz2);
        if (b1 || b2) {
            long at = firstdiff(gbuf1, sz1, gbuf2, sz2);
            binverdict(eb, gf1, sz1, b1, gf2, sz2, b2);
            if (at < 0)
                strcat(eb, "the bytes are IDENTICAL");
            else
                sprintf(eb + strlen(eb),
                        "first difference at byte %ld", at);
            ltx_msg(eb);
            freediff();
            return -1;
        }
    }
    if (diff_split(gbuf1, sz1, &gla, &na) != 0 ||
        diff_split(gbuf2, sz2, &glb, &nb) != 0 ||
        diff_run(gla, na, glb, nb, &gops, &nops) != 0 ||
        (grows = buildrows(gops, nops, &nrows)) == NULL ||
        (gatag = malloc(na > 0 ? na : 1)) == NULL ||
        (gbtag = malloc(nb > 0 ? nb : 1)) == NULL) {
        ltx_msg("out of memory");
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
    ghdirty = 1;            /* b82: and the hunk index */
    dmapdirty = 1;          /* b104: and the diffs-only map */
    findrow = -1; findn = findof = 0;   /* b67: row numbering changed */
    gnrows = nrows;
    gtop = 0;
    return 0;
}

/* 0 = cancelled, 1 = a file, 2 = a drawer (empty File field - the
 * road into directory mode) */

/* ---- b69: AppWindow drops (his ask) --------------------------
 * A dropped icon picks its side by WHERE it lands: the content
 * width splits 40/20/40, left band sets the left file, right band
 * the right, and the narrow middle asks. Two icons dropped together
 * fill left and right in the order given - position cannot
 * disambiguate two, so it is not consulted.
 *
 * The thirds apply in EVERY view, including an empty window and the
 * Tree, so the gesture never changes meaning. That matters more than
 * matching the pane geometry, because there IS no drawn boundary to
 * aim at (the marker column only carries |/</> on differing rows,
 * his correction) and AppWindow reports only the drop - there are no
 * drag-over events, so nothing can highlight a target mid-drag. */

static struct MsgPort *appport;
static struct AppWindow *appwin;
/* cedit b0b: our own screen, if any, is ltx_myscr */
static struct AppIcon *appicon;         /* b72: only while iconified */
static struct DiskObject *appdob;
static int iconified;
static void reload(void);       /* defined below with the loaders */

/* WBArg -> a full path we can hand to the loader */
static int wbargpath(struct WBArg *wa, char *dest, int max)
{
    dest[0] = 0;
    if (wa->wa_Lock) {
        if (!NameFromLock(wa->wa_Lock, (STRPTR)dest, max)) return 0;
    } else if (wa->wa_Name == NULL)
        return 0;
    if (wa->wa_Name && wa->wa_Name[0]) {
        if (!AddPart((STRPTR)dest, wa->wa_Name, max)) return 0;
    }
    return dest[0] != 0;
}

/* which band did it land in?  -1 left, 1 right, 0 the middle "ask" */
static int dropband(WORD mx)
{
    int w = win->Width - win->BorderLeft - win->BorderRight;
    int lx = win->BorderLeft, rel = mx - lx;
    if (w <= 0) return 0;
    if (rel < (w * 2) / 5) return -1;           /* 40% */
    if (rel > (w * 3) / 5) return 1;            /* 40% */
    return 0;                                   /* the narrow 20% */
}

static void dropped(struct AppMessage *am)
{
    static char p1[310], p2[310];
    int side;

    if (am->am_NumArgs <= 0) return;
    if (am->am_NumArgs >= 2) {          /* a pair: order decides */
        if (!wbargpath(&am->am_ArgList[0], p1, sizeof(p1)) ||
            !wbargpath(&am->am_ArgList[1], p2, sizeof(p2)))
            return;
        if (ispathdir(p1) && ispathdir(p2)) {
            freediff();
            freedirs();
            strcpy(gdir1, p1);
            strcpy(gdir2, p2);
            gf1[0] = gf2[0] = 0;
            gdirmode = 1;
            scandirs();
            view = 3;
            settitle();
            drawpage();
            return;
        }
        freedirs();
        strcpy(gf1, p1);
        strcpy(gf2, p2);
        reload();
        return;
    }
    if (!wbargpath(&am->am_ArgList[0], p1, sizeof(p1))) return;
    side = dropband(am->am_MouseX);
    if (side == 0) {                    /* the middle band asks */
        static struct EasyStruct es;
        ULONG args[1];
        LONG r;
        es.es_StructSize   = sizeof(es);
        es.es_Flags        = 0;
        es.es_Title        = (UBYTE *)"cdiff";
        es.es_TextFormat   = (UBYTE *)"Put \"%s\" on which side?";
        es.es_GadgetFormat = (UBYTE *)"Left|Right|Cancel";
        args[0] = (ULONG)FilePart((STRPTR)p1);
        r = EasyRequestArgs(win, &es, NULL, args);
        if (r == 1) side = -1;
        else if (r == 2) side = 1;
        else return;                    /* Cancel, and the 0 case */
    }
    if (ispathdir(p1)) {
        /* b71, his find: the two drawers to compare are rarely in
         * the same place on the drive, so they often CANNOT be
         * dragged together. One at a time then - a side each - and
         * the tree compare runs when both sides hold a drawer. */
        if (side < 0) { strcpy(gdir1, p1); gf1[0] = 0; }
        else          { strcpy(gdir2, p1); gf2[0] = 0; }
        if (gdir1[0] && gdir2[0]) {
            freediff();
            freedirs();                 /* clears gdirmode, so set it after */
            gf1[0] = gf2[0] = 0;
            gdirmode = 1;
            scandirs();
            view = 3;
        } else if ((side < 0 && gf2[0]) || (side > 0 && gf1[0]))
            ltx_msg("that side holds a drawer now - drop a drawer on the\n"
                "other side too, or a file to go back to comparing files");
        settitle();
        drawpage();
        return;
    }
    if (side < 0) { strcpy(gf1, p1); gdir1[0] = 0; }
    else          { strcpy(gf2, p1); gdir2[0] = 0; }
    if (gf1[0] && gf2[0]) {
        freedirs();
        reload();
    } else {
        if ((side < 0 && gdir2[0]) || (side > 0 && gdir1[0]))
            ltx_msg("that side holds a file now - drop a file on the other\n"
                "side too, or a drawer to go back to comparing trees");
        settitle();
        drawpage();
    }
}

/* b67: the Find requester - a real gadtools STRING_KIND, not a
 * hand-rolled line editor (his standing instruction: use the OS's
 * own). Reuses the VisualInfo the menus already hold. Enter accepts,
 * Esc or the close gadget cancels. Returns 1 when findstr changed
 * into something searchable. */
static int askfind(void)
{
    struct Screen *scr;
    struct Window *w;
    struct Gadget *glist = NULL, *sg;
    struct NewGadget ng;
    struct IntuiMessage *m;
    int done = 0, ok = 0, ww, wh;

    if (!GadToolsBase || !gvi) {
        ltx_msg("gadtools.library is not available - no Find requester");
        return 0;
    }
    if (CreateContext(&glist) == NULL) return 0;
    /* b76: the screen the MAIN window is on, not the default one.
     * With PUBSCREEN= set those differ, and this requester would
     * have opened on Workbench while cdiff sat on another screen.
     * Worse than cosmetic here: gvi (VisualInfo) is built from the
     * main window's screen, and GadTools VisualInfo is
     * screen-specific - using it on a window opened elsewhere is
     * simply wrong. No lock needed: our own window holds the screen
     * open. */
    scr = win ? win->WScreen : LockPubScreen(NULL);
    if (scr == NULL) { FreeGadgets(glist); return 0; }

    ww = 44 * fw + 6 * fw + 40;
    wh = scr->WBorTop + scr->Font->ta_YSize + 1 + fh + 26;
    memset(&ng, 0, sizeof(ng));
    ng.ng_LeftEdge   = 6 * fw + 16;
    ng.ng_TopEdge    = scr->WBorTop + scr->Font->ta_YSize + 1 + 8;
    ng.ng_Width      = 44 * fw;
    ng.ng_Height     = fh + 6;
    ng.ng_GadgetText = (STRPTR)"Find:";
    ng.ng_TextAttr   = scr->Font;
    ng.ng_GadgetID   = 1;
    ng.ng_Flags      = PLACETEXT_LEFT;
    ng.ng_VisualInfo = gvi;
    sg = CreateGadget(STRING_KIND, glist, &ng,
                      GTST_String, (ULONG)findstr,
                      GTST_MaxChars, (ULONG)(sizeof(findstr) - 1),
                      TAG_DONE);
    if (sg == NULL) {
        if (!win) UnlockPubScreen(NULL, scr);
        FreeGadgets(glist);
        return 0;
    }
    w = OpenWindowTags(NULL,
        WA_Left, (scr->Width - ww) / 2,
        WA_Top, (scr->Height - wh) / 3,
        WA_Width, ww,
        WA_Height, wh,
        WA_Title, (ULONG)"cdiff: Find",
        WA_PubScreen, (ULONG)scr,
        WA_Gadgets, (ULONG)glist,
        WA_IDCMP, IDCMP_CLOSEWINDOW | IDCMP_VANILLAKEY |
                  IDCMP_REFRESHWINDOW | IDCMP_GADGETUP |
                  IDCMP_ACTIVEWINDOW,
        WA_Flags, WFLG_DRAGBAR | WFLG_DEPTHGADGET | WFLG_CLOSEGADGET |
                  WFLG_ACTIVATE | WFLG_SMART_REFRESH | WFLG_RMBTRAP,
        TAG_DONE);
    if (!win) UnlockPubScreen(NULL, scr);   /* only what we locked */
    if (w == NULL) { FreeGadgets(glist); return 0; }
    GT_RefreshWindow(w, NULL);
    ActivateGadget(sg, w, NULL);

    while (!done) {
        WaitPort(w->UserPort);
        /* GT_GetIMsg/GT_ReplyIMsg are REQUIRED once real gadtools
         * gadgets exist in a window - plain GetMsg is only safe for
         * its menus (the lesson b30 wrote down the hard way) */
        while ((m = GT_GetIMsg(w->UserPort))) {
            ULONG cls = m->Class;
            UWORD cod = m->Code;
            APTR  iad = m->IAddress;
            GT_ReplyIMsg(m);
            if (cls == IDCMP_CLOSEWINDOW) done = 1;
            else if (cls == IDCMP_GADGETUP && iad == (APTR)sg) {
                ok = 1;                 /* Enter in the string gadget */
                done = 1;
            } else if (cls == IDCMP_VANILLAKEY) {
                if (cod == 27) done = 1;            /* Esc cancels */
                else if (cod == 13) { ok = 1; done = 1; }
            } else if (cls == IDCMP_REFRESHWINDOW) {
                GT_BeginRefresh(w);
                GT_EndRefresh(w, TRUE);
            }
        }
    }
    if (ok) {
        struct StringInfo *si = (struct StringInfo *)sg->SpecialInfo;
        if (si && si->Buffer) {
            strncpy(findstr, (char *)si->Buffer, sizeof(findstr) - 1);
            findstr[sizeof(findstr) - 1] = 0;
        } else
            ok = 0;
    }
    CloseWindow(w);
    FreeGadgets(glist);
    return ok && findstr[0];
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
        ltx_msg(eb);
        return;
    }
    if (d->st == 'L' || d->st == 'R') {
        sprintf(eb, "\"%.40s\"\nexists only in\n%.64s",
                d->rel, d->st == 'L' ? gdir1 : gdir2);
        ltx_msg(eb);
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
    /* b73: the EDITOR tooltype wins, then ENV:EDITOR, then Ed */
    if (tteditor[0])
        strcpy(ed, tteditor);
    else if (GetVar((STRPTR)"EDITOR", (STRPTR)ed, sizeof(ed), 0) <= 0)
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
        ltx_msg("could not launch the editor\n(set ENV:EDITOR to name one)");
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
    { NM_TITLE, (STRPTR)"Navigation",    NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Find...",       (STRPTR)"F",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Find Next",     (STRPTR)"N",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Find Previous", NULL,         0, 0, NULL },
    { NM_TITLE, (STRPTR)"Settings",      NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Status bar",    NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    { NM_ITEM,  (STRPTR)"Differences only", (STRPTR)"D",
      CHECKIT | MENUTOGGLE, 0, NULL },
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
    /* b76: follow the main window's screen, so About/Keys do not
     * appear on Workbench while cdiff is on a PUBSCREEN= screen */
    scr = win ? win->WScreen : LockPubScreen(NULL);
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
    if (!win) UnlockPubScreen(NULL, scr);   /* only what we locked */
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
        "the iconify gadget hides cdiff to a Workbench icon;\n"
        "  double-click it to come back, nothing is lost\n"
        "Amiga+D - differences only (unchanged runs collapse to\n"
        "  a marker; CONTEXT= tooltype sets how much is kept)\n"
        "Amiga+F / Amiga+N - find, find next (Navigation menu;\n"
        "  Find Previous has no shortcut). Case-insensitive,\n"
        "  searches the view you are in, wraps at the ends\n"
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
                r1 = ltx_askfile("cdiff: select the LEFT file or drawer", t1, ttdrawer, 0);
                if (!r1) break;
                r2 = ltx_askfile("cdiff: select the RIGHT file or drawer", t2, ttdrawer, 0);
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
                    ltx_msg("pick two files - or two drawers for a "
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
                int r = ltx_askfile("cdiff: select the LEFT file", t1, ttdrawer, 0);
                if (r == 2)
                    ltx_msg("that is a drawer - Open Files... with two "
                        "drawers runs a tree compare");
                else if (r == 1) {
                    strcpy(gf1, t1);
                    reload();
                }
                break;
            }
            case 2: {           /* Open Right... */
                static char t2[310];
                int r = ltx_askfile("cdiff: select the RIGHT file", t2, ttdrawer, 0);
                if (r == 2)
                    ltx_msg("that is a drawer - Open Files... with two "
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
        } else if (MENUNUM(c) == 2) {           /* Navigation */
            switch (ITEMNUM(c)) {
            case 0:                             /* Find... */
                if (askfind()) gofind(1, 1);
                break;
            case 1: gofind(1, 0); break;        /* Find Next */
            case 2: gofind(-1, 0); break;       /* Find Previous */
            }
        } else if (MENUNUM(c) == 3) {           /* Settings */
            if (ITEMNUM(c) == 0 && item) {
                /* b87, his ask: the menu IS the setting - toggling
                 * it writes STATUSBAR= back to the icon, so the
                 * choice survives the next launch. A CLI start has
                 * no icon to write to; the toggle still applies for
                 * this session. */
                ttstatus = (item->Flags & CHECKED) ? 1 : 0;
                calcgrid();
                clamptops();
                drawpage();
                if (ttoollock && ttoolname[0] &&
                    !iconset("STATUSBAR", ttstatus ? "YES" : "NO"))
                    ltx_msg("could not write STATUSBAR to the icon\n"
                        "(the setting still applies this session)");
            } else if (ITEMNUM(c) == 1 && item) {
                /* b104: Differences only. Keep the reader where they
                 * were - map the current top row across instead of
                 * dumping them at a different place in the file. */
                int was = drow(*vtop());
                ttdiffs = (item->Flags & CHECKED) ? 1 : 0;
                dmapdirty = 1;
                ghdirty = 1;
                if (was >= 0 && view != 3) {
                    int n = vcount(), i, best = 0;
                    for (i = 0; i < n; i++) {
                        int r = drow(i);
                        if (r >= 0 && r <= was) best = i;
                        if (r > was) break;
                    }
                    *vtop() = best;
                }
                findrow = -1; findn = findof = 0;
                clamptops();
                drawpage();
            }
        } else if (MENUNUM(c) == 4) {           /* Help */
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

/* b72: window setup, split out of guimode so iconify can tear the
 * window down and build it back with every piece of state - the
 * loaded diff, the view, the scroll positions - untouched. Returns
 * 0 if the window could not be opened. */
static int openmain(void)
{
    struct Screen *scr;
    struct DrawInfo *dri;
    /* cedit b0b: the screen precedence, the window geometry rules and
     * the font road are the chassis's now. What is left here is what
     * is cdiff's: its title, its IDCMP set, its menus and its grid. */
    static LtxWinSpec spec;
    spec.title     = "cdiff";
    spec.scrname   = ttscrname;
    spec.pubscr    = ttpubscr;
    spec.depth     = ttdepth;
    spec.left      = ttleft;
    spec.top       = tttop;
    spec.width     = ttwidth;
    spec.height    = ttheight;
    spec.fontname  = ttfont;
    spec.fontsize  = ttfsize;
    spec.minwidth  = 240;
    spec.minheight = 120;
    spec.idcmp     = IDCMP_CLOSEWINDOW | IDCMP_VANILLAKEY |
                     IDCMP_RAWKEY | IDCMP_REFRESHWINDOW |
                     IDCMP_MENUPICK | IDCMP_MOUSEBUTTONS |
                     IDCMP_NEWSIZE | IDCMP_GADGETDOWN |
                     IDCMP_GADGETUP;
    /* MOUSEMOVE and INTUITICKS are NOT asked for here (his question:
     * does the window really need to know where the pointer is?).
     * They are switched on by ltx_trackpointer() for the duration of
     * a drag, a held arrow or a dragged knob, and off again. */  /* b48: arrow auto-repeat */
    if (!ltx_openwin(&spec, &scr, &dri)) return 0;
    /* b109: we asked for a font and got the system default, so it
     * was not there - do not retry it on every reopen */
    if (ttfont[0] && font == GfxBase->DefaultFont) ttfont[0] = 0;
    if (GadToolsBase) {
        gvi = GetVisualInfo(scr, TAG_DONE);
        if (gvi) {
            /* b87: the checkmark starts wherever the tooltype
             * left it, so menu and icon never disagree on entry */
            {
                int mi;
                for (mi = 0; newmenu[mi].nm_Type != NM_END; mi++) {
                    const char *lb = (const char *)newmenu[mi].nm_Label;
                    if (lb == NULL || lb == (const char *)NM_BARLABEL)
                        continue;
                    if (!strcmp(lb, "Status bar")) {
                        if (ttstatus) newmenu[mi].nm_Flags |= CHECKED;
                        else          newmenu[mi].nm_Flags &= ~CHECKED;
                    }
                    continue;
                }
            }
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
    /* b72: the AppWindow is per-window, but the PORT is not - it
     * has to outlive the window so the AppIcon can still reach us
     * while iconified. Created once in guimode. */
    if (appport) appwin = AddAppWindowA(0, 0, win, appport, NULL);
    addscrollers(dri, scr);
    ltx_screendone(scr, dri);
    calcgrid();
    return 1;
}

/* b72: everything openmain built, in reverse. The app PORT and the
 * loaded document survive; the window, its menus, its gadgets and
 * the arrow images do not. Each pointer is cleared so a reopen
 * rebuilds rather than double-freeing. */
static void closemain(void)
{
    if (appwin) { RemoveAppWindow(appwin); appwin = NULL; }
    if (gmenu) ClearMenuStrip(win);
    if (gadsok) { RemoveGList(win, &vgad, -1); gadsok = 0; }
    ltx_closewindow();
    if (gmenu) { FreeMenus(gmenu); gmenu = NULL; }
    if (gvi) { FreeVisualInfo(gvi); gvi = NULL; }
    freearrows();               /* cedit b0b: the four sysiclass images */
    /* the VisualInfo above came FROM the screen, so it has to be
     * freed before the screen is - hence two calls, in this order */
    ltx_closescreen();
}

/* b72: hide. The window goes away entirely and an AppIcon takes its
 * place on Workbench; the document, the view and every scroll
 * position stay exactly as they were. If the AppIcon cannot be made
 * (no icon.library, no port, Workbench refuses) the window comes
 * straight back rather than leaving the program unreachable. */
static void goiconify(void)
{
    if (iconified || appport == NULL || IconBase == NULL) return;
    /* b73: wear HIS icon when we know where we live (a Workbench
     * launch tells us), and only fall back to the generic tool
     * image otherwise - the couple of lines promised at b72 */
    appdob = NULL;
    if (ttoollock && ttoolname[0]) {
        BPTR old = CurrentDir(ttoollock);
        appdob = GetDiskObject((STRPTR)ttoolname);
        CurrentDir(old);
    }
    if (appdob == NULL) appdob = GetDefDiskObject(WBTOOL);
    if (appdob == NULL) return;
    closemain();
    appicon = AddAppIconA(0, 0, (STRPTR)"cdiff", appport, 0, appdob, NULL);
    if (appicon == NULL) {              /* refused - undo the hide */
        FreeDiskObject(appdob);
        appdob = NULL;
        if (!openmain()) return;        /* nothing left to try */
        settitle();
        drawpage();
        return;
    }
    iconified = 1;
}

/* b72: and back. */
static void unicon(void)
{
    if (!iconified) return;
    if (appicon) { RemoveAppIcon(appicon); appicon = NULL; }
    if (appdob) { FreeDiskObject(appdob); appdob = NULL; }
    iconified = 0;
    if (!openmain()) return;
    settitle();
    drawpage();
}

static void guimode(void)
{
    struct IntuiMessage *msg;
    int done = 0, burst = 0;

    /* cedit b0b: before anything can paint. The chassis refuses to
     * scroll, flush or draw a status row without it. */
    ltx_appname = "cdiff";
    ltx_setapp(&cdiffapp);

    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
    GadToolsBase = OpenLibrary((STRPTR)"gadtools.library", 37);
    AslBase = OpenLibrary((STRPTR)"asl.library", 37);
    WorkbenchBase = OpenLibrary((STRPTR)"workbench.library", 37);
    if (ttfont[0]) DiskfontBase = OpenLibrary((STRPTR)"diskfont.library", 37);
    if (IntuitionBase == NULL || GfxBase == NULL) goto out;
    /* b106: only if smain has not already opened it for the
      * tooltypes - a Workbench start came through there first, and
      * opening twice while closing once leaks a reference every run */
    if (IconBase == NULL)
        IconBase = OpenLibrary((STRPTR)"icon.library", 37);
    /* b72: one port for the lifetime of the program - the AppWindow
     * comes and goes with the window, the AppIcon exists only while
     * iconified, and both report here. */
    if (WorkbenchBase) appport = CreateMsgPort();

    if (!openmain()) goto out;

    if (gdirmode) {                 /* CLI gave two directories */
        scandirs();
        view = 3;
    } else if (gf1[0] && gf2[0]) {  /* CLI gave the pair up front */
        if (loaddiff() == 0) calcgut();
    }
    settitle();
    drawpage();

    while (!done) {
        ULONG wsig, asig, got;

        /* b72: hidden. There is no window to wait on or paint into -
         * only the AppIcon can reach us, and only to bring us back. */
        if (iconified) {
            struct AppMessage *am;
            int wake = 0;
            if (appport == NULL) break;         /* unreachable: bail */
            Wait(1UL << appport->mp_SigBit);
            while ((am = (struct AppMessage *)GetMsg(appport))) {
                if (am->am_Type == AMTYPE_APPICON) wake = 1;
                ReplyMsg((struct Message *)am);
            }
            if (wake) unicon();
            continue;
        }

        wsig = 1UL << win->UserPort->mp_SigBit;
        asig = appport ? 1UL << appport->mp_SigBit : 0;
        got = Wait(wsig | asig);

        if (asig && (got & asig)) {     /* b69: dropped icons */
            struct AppMessage *am;
            while ((am = (struct AppMessage *)GetMsg(appport))) {
                if (am->am_Type == AMTYPE_APPWINDOW) dropped(am);
                ReplyMsg((struct Message *)am);
            }
            flushpaint();       /* b70: settle it here and now - this
                                 * is outside the IDCMP drain, so
                                 * nothing else will */
        }
        if (!(got & wsig)) continue;
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
            ULONG csec = msg->Seconds, cmic = msg->Micros;
            ReplyMsg((struct Message *)msg);
            /* An INTUITICKS with nothing to drive is pure noise, and
             * it is NOT free: every message that reaches the bottom
             * of this loop takes part in the burst accounting, and a
             * flush that owes a repaint pays a WaitTOF - a whole
             * frame. Intuition sends these ten times a second while
             * the pointer is over the window, so they interleave with
             * a held key's repeats, break the coalescing that is
             * supposed to turn a burst into ONE paint, and buy a
             * frame wait per interruption.
             *
             * That is why he saw scrolling roughly double the moment
             * the pointer left the window. Skipped BEFORE `defer` is
             * set, so a skipped message can never leave the flag
             * armed - b70's bug, which cost a build. */
            if (class == IDCMP_INTUITICKS && !arrheld && !propheld)
                continue;
            defer = 1;
            /* b72, straight out of AmigaReferences/intuition-
             * iconify.md: with WA_IconifyGadget set, the iconify
             * click arrives as IDCMP_CLOSEWINDOW with Code == 1 (a
             * real close is 0). Branch on Code or the new gadget
             * quits the program. */
            if (class == IDCMP_CLOSEWINDOW) {
                if (code == 1) { goiconify(); break; }
                done = 1;
            }
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
                if (class == IDCMP_GADGETDOWN) {
                    propheld = iaddr == (APTR)&vgad ? 1 :
                               iaddr == (APTR)&hgad ? 2 : 0;
                    /* a knob drag needs MOUSEMOVE, an arrow needs
                     * INTUITICKS to repeat - ask for them now and
                     * hand them back on release */
                    ltx_trackpointer(1);
                } else if (class == IDCMP_GADGETUP) {
                    propheld = 0;
                    arrheld = 0;
                    ltx_trackpointer(0);
                }
                if (iaddr == (APTR)&vgad) {
                    ltx_trackvert();
                } else if (iaddr == (APTR)&hgad) {
                    ltx_trackhoriz();
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
                scrollfromset = seloldset = ltx_appowed = 0;
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
                /* b83, his find: EXPANDING the window redrew at
                 * once, SHRINKING left stale content until the next
                 * scroll. A resize leaves the window with damage
                 * pending (WFLG_WINDOWREFRESH), and ordinary
                 * rendering into a damaged region is suppressed
                 * until BeginRefresh/EndRefresh - so the deferred
                 * repaint was simply discarded. Expanding escaped it
                 * only because it ALSO produced a REFRESHWINDOW
                 * message, which b64 already paints properly; a
                 * shrink produces no newly-exposed area and so no
                 * such message. Paint here and now, through the
                 * refresh when one is pending, and a resize no
                 * longer depends on a second event arriving. */
                {
                    int od = defer;
                    defer = 0;
                    if (win->Flags & WFLG_WINDOWREFRESH) {
                        BeginRefresh(win);
                        drawpage();
                        EndRefresh(win, TRUE);
                    } else
                        drawpage();
                    defer = od;
                    dirtyall = dirtyrows = 0;
                    scrollfromset = seloldset = ltx_appowed = 0;
                }
            }
            if (class == IDCMP_MOUSEBUTTONS && code == SELECTDOWN) {
                if (tabsok && my >= gy0 && my <= gy0 + tabh) {
                    int ti;
                    int what = ltx_tabclick(mx, my, &ti);
                    if (what == LTXTAB_PICK && ti < gntabs)
                        setview(gtabvid[ti]);
                    else if (what == LTXTAB_SCROLL)
                        drawtabs();
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
    /* b48's ordering lives in closemain now: RemoveGList detaches
     * the gadgets before the images they point at are disposed, so
     * Intuition can never be left holding a freed Image. */
    if (win) closemain();
    if (appicon) { RemoveAppIcon(appicon); appicon = NULL; }
    if (appdob) { FreeDiskObject(appdob); appdob = NULL; }
    if (appport) {                      /* drain what is still queued */
        struct Message *m;
        while ((m = GetMsg(appport))) ReplyMsg(m);
        DeleteMsgPort(appport);
        appport = NULL;
    }
out:
    if (gmenu) FreeMenus(gmenu);
    if (gvi) FreeVisualInfo(gvi);
    ltx_freefilereq();
    if (AslBase) CloseLibrary(AslBase);
    free(ghs); ghs = NULL; ghcap = ghn = 0;
    ltx_closefont();
    if (ttoollock) { UnLock(ttoollock); ttoollock = 0; }
    if (DiskfontBase) CloseLibrary(DiskfontBase);
    if (IconBase) CloseLibrary(IconBase);
    if (WorkbenchBase) CloseLibrary(WorkbenchBase);
    if (GadToolsBase) CloseLibrary(GadToolsBase);
    if (GfxBase) CloseLibrary((struct Library *)GfxBase);
    if (IntuitionBase) CloseLibrary((struct Library *)IntuitionBase);
}

/* ---- main ------------------------------------------------------- */

/* ---- b73: tooltypes -------------------------------------------
 * Read from the WBStartup message, which smain used to throw away as
 * (void)argv. Every setting is optional and inert when absent, so a
 * shell launch is unchanged. */

static void readtooltypes(struct WBStartup *wbs)
{
    struct DiskObject *dob;
    struct WBArg *wa;
    BPTR old;
    char **tt;
    UBYTE *v;

    if (IconBase == NULL || wbs == NULL || wbs->sm_ArgList == NULL) return;
    wa = wbs->sm_ArgList;
    /* keep our own drawer+name: b72's AppIcon can then wear HIS icon
     * instead of the generic tool image, the moment he draws one */
    if (wa[0].wa_Lock) ttoollock = DupLock(wa[0].wa_Lock);
    if (wa[0].wa_Name)
        strncpy(ttoolname, (char *)wa[0].wa_Name, sizeof(ttoolname) - 1);

    old = CurrentDir(wa[0].wa_Lock);
    dob = GetDiskObject((STRPTR)wa[0].wa_Name);
    if (dob) {
        tt = (char **)dob->do_ToolTypes;
        ttstr(tt, "EDITOR", tteditor, sizeof(tteditor));
        ttstr(tt, "DRAWER", ttdrawer, sizeof(ttdrawer));
        ttstr(tt, "OPENSCREEN", ttscrname, sizeof(ttscrname));
        ttstr(tt, "PUBSCREEN", ttpubscr, sizeof(ttpubscr));
        /* floor of 2 planes, not 1: cdiff draws in pens 0-3, and on
         * a 2-colour screen pens 2 and 3 do not exist */
        ttdepth = ttnum(tt, "SCREENDEPTH", 2, 8, 0);
        ttcontext = ttnum(tt, "CONTEXT", 0, 50, 3);
        v = FindToolType((CONST_STRPTR *)tt, (STRPTR)"STATUSBAR");
        if (v) ttstatus = !(tteq((char *)v, "NO") ||
                            tteq((char *)v, "OFF") ||
                            tteq((char *)v, "FALSE"));
        ttleft   = ttnum(tt, "LEFT",   0, 20000, -1);
        tttop    = ttnum(tt, "TOP",    0, 20000, -1);
        ttwidth  = ttdim(tt, "WIDTH");
        ttheight = ttdim(tt, "HEIGHT");
        tttab    = ttnum(tt, "TABSIZE", 1, 16, 8);
        /* a power of two can use a mask; anything else pays for a
         * modulo per expanded column (the roadmap's own warning
         * about DIVU in a per-cell loop at 14MHz) */
        ttmask = (tttab & (tttab - 1)) ? 0 : tttab - 1;
        v = FindToolType((CONST_STRPTR *)tt, (STRPTR)"FONT");
        if (v) {                        /* b74, his call: name/size */
            char *sl;
            int n;
            /* leave room to append ".font" ourselves */
            strncpy(ttfont, (char *)v, sizeof(ttfont) - 6);
            ttfont[sizeof(ttfont) - 6] = 0;
            sl = strchr(ttfont, '/');
            if (sl) { *sl = 0; ttfsize = atoi(sl + 1); }
            if (ttfsize < 5 || ttfsize > 48) ttfsize = 8;
            /* he types the family name, not the file name: FONT=
             * topaz/8. ".font" is appended when missing, and the
             * fully-spelled form still works. */
            n = strlen(ttfont);
            if (n == 0)
                ttfont[0] = 0;
            else if (n < 5 || !tteq(ttfont + n - 5, ".font"))
                strcat(ttfont, ".font");
        }
        FreeDiskObject(dob);
    }
    CurrentDir(old);

    /* project icons dropped ON the cdiff icon: the Workbench half of
     * b69's drop gesture. Two of them are a pair to compare. */
    if (wbs->sm_NumArgs >= 3) {
        static char p1[310], p2[310];
        if (wbargpath(&wa[1], p1, sizeof(p1)) &&
            wbargpath(&wa[2], p2, sizeof(p2))) {
            if (ispathdir(p1) && ispathdir(p2)) {
                strcpy(gdir1, p1);
                strcpy(gdir2, p2);
                gdirmode = 1;
            } else {
                strcpy(gf1, p1);
                strcpy(gf2, p2);
            }
        }
    } else if (wbs->sm_NumArgs == 2) {  /* one icon: the left side */
        static char p1[310];
        if (wbargpath(&wa[1], p1, sizeof(p1))) {
            if (ispathdir(p1)) strcpy(gdir1, p1);
            else               strcpy(gf1, p1);
        }
    }
}

static int smain(int argc, char **argv)
{
    /* b106: FILE1/FILE2 are NOT /A any more. A Workbench start has
     * always opened the empty window and let the Project menu supply
     * the files; from a shell, bare `cdiff` used to fail with
     * "required argument missing" instead - so the one road that
     * could show the window without knowing both names was the one
     * you could not take from a shell. TEXT still requires both,
     * because a listing of nothing is not a listing. */
    static const char tmpl[] = "FILE1,FILE2,TEXT/S";
    LONG argarr[3] = { 0, 0, 0 };
    struct RDArgs *rda;

    if (argc == 0) {
        /* Workbench start (his ask): empty window, the Project menu
         * supplies the files one by one. b73: argv IS the WBStartup
         * message here - it used to be thrown away, and it carries
         * both the tooltypes and any project icons dropped on us. */
        IconBase = OpenLibrary((STRPTR)"icon.library", 37);
        readtooltypes((struct WBStartup *)argv);
        guimode();
        freediff();
        return 0;
    }

    rda = ReadArgs((STRPTR)tmpl, argarr, NULL);
    if (rda == NULL) {
        PrintFault(IoErr(), (STRPTR)"cdiff");
        return 20;
    }
    if (argarr[2] && (argarr[0] == 0 || argarr[1] == 0)) {
        printf("cdiff: TEXT needs both files\n");
        FreeArgs(rda);
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
        {   /* b96: same refusal as the GUI - the TEXT road is the
             * regression gate, so it must not disagree about what a
             * binary is. Exit 5 (WARN): not a failure, but not a
             * clean "no differences" either. */
            int b1 = isbinary(buf1, sz1), b2 = isbinary(buf2, sz2);
            if (b1 || b2) {
                long at = firstdiff(buf1, sz1, buf2, sz2);
                printf("cdiff: %s - cdiff compares text\n",
                       (b1 && b2) ? "both files are binary" :
                       b1 ? "the LEFT file is binary"
                          : "the RIGHT file is binary");
                printf("cdiff: %s %ld bytes, %s %ld bytes\n",
                       (char *)argarr[0], sz1,
                       (char *)argarr[1], sz2);
                if (at < 0)
                    printf("cdiff: the bytes are IDENTICAL\n");
                else
                    printf("cdiff: first difference at byte %ld\n", at);
                free(buf1);
                free(buf2);
                FreeArgs(rda);
                return 5;
            }
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
    } else if (argarr[0] && argarr[1]) {
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
    } else {
        /* b106: none or one. The window opens either empty or with
         * that side filled and the title asking for the other -
         * exactly what a single dropped icon does, and what a
         * Workbench start has always done. */
        if (argarr[0]) {
            if (ispathdir((char *)argarr[0]))
                strncpy(gdir1, (char *)argarr[0], sizeof(gdir1) - 1);
            else
                strncpy(gf1, (char *)argarr[0], sizeof(gf1) - 1);
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
