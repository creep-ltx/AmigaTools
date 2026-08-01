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
#include <intuition/intuition.h>
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
    "$VER: cdiff 0.1b14 (1.8.26)";

unsigned long __stack = 65536;  /* libnix: engine recursion headroom */

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
static int tabx[3], tabe[3];    /* tab bar hit ranges (pixels) */
static int tabsok;              /* tab bar live (files loaded) */
static int tabh;                /* tab bar height in pixels */

/* the screen's own GUI pens (DrawInfo), with 4-colour WB fallbacks -
 * the tabs are drawn in Intuition's bevel language (his ask: GUI
 * tabs, not text cells), so they follow the user's WB palette */
static int pshine = 2, pshadow = 1, pfill = 3, pfilltext = 2,
           ptext = 1, pback = 0;

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

/* the active view's scroll top and extent */
static int *vtop(void)
{
    return view == 0 ? &gtop : view == 1 ? &ltop : &rtop;
}

static int vcount(void)
{
    return view == 0 ? gnrows : view == 1 ? gna : gnb;
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
 * the content through a gap in the base rule */
static void drawtabs(void)
{
    static char lab[3][40];
    int i, x, w, yr = y0 + tabh, winr = x0 + viscols * fw - 1;
    SetAPen(rp, pback);
    RectFill(rp, x0, y0, winr, yr + 1);
    tabsok = ga != NULL;
    if (!tabsok) return;
    strcpy(lab[0], "Both");
    sprintf(lab[1], "%.30s", (char *)FilePart((STRPTR)gf1));
    sprintf(lab[2], "%.30s", (char *)FilePart((STRPTR)gf2));
    x = x0 + 2;
    for (i = 0; i < 3; i++) {
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
        /* body */
        SetAPen(rp, i == view ? pfill : pback);
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
        SetAPen(rp, i == view ? pfilltext : ptext);
        SetBPen(rp, i == view ? pfill : pback);
        Move(rp, x + 6, y0 + 2 + fbase);
        Text(rp, (STRPTR)lab[i], lw);
        x += w + 3;
    }
    /* base rule in shine, broken open under the active tab - the
     * classic "this tab is the page you are on" statement */
    SetAPen(rp, pshine);
    if (tabx[view] > x0) {
        Move(rp, x0, yr);
        Draw(rp, tabx[view], yr);
    }
    Move(rp, tabe[view] - 1, yr);
    Draw(rp, winr, yr);
    /* the active tab's floor is its fill colour: erase the rule
     * span so page and tab read as one surface */
    SetAPen(rp, pfill);
    Move(rp, tabx[view] + 1, yr);
    Draw(rp, tabe[view] - 2, yr);
}

static void drawpage(void)
{
    int vr, s, e;
    drawtabs();
    for (vr = 0; vr < crows; vr++) {
        if (view == 0)
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
    if (ga == NULL) {           /* WB start, nothing loaded yet */
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
    static char t[220];
    if (ga)
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
    if (view == 0)
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
    } else
        drawrows();
}

/* next/previous hunk in the active view: rows in the overview,
 * tagged lines in a single-file tab */
static int nexthunk(int from, int dir)
{
    const char *tg = view == 1 ? gatag : gbtag;
    int n = vcount(), i = from + dir;
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

/* switch tabs, keeping the position: the top row/line carries over
 * through the row list so all three views stay anchored */
static void setview(int v)
{
    int i, row = 0;
    if (v == view || ga == NULL) return;
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
    return 0;
}

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

static void aboutreq(void)
{
    static char t[300];
    /* verstag + 6 skips "$VER: " - the About can never drift from
     * the real version string */
    sprintf(t, "%s\n\na visual diff for AmigaOS\n"
               "patience engine, side-by-side view\n\n"
               "by Tobias Karlsson & Claude, 2026",
            verstag + 6);
    erq(t);
}

static void keysreq(void)
{
    erq("1 / 2 / 3 - view: Both / Left / Right\n"
        "Tab / Shift+Tab - cycle views (bar is clickable)\n"
        "cursor up/down - scroll (shift = page), wheel works\n"
        "cursor left/right - scroll long lines (shift = more)\n"
        "space / b - page down / up\n"
        "t / e - top / end\n"
        "n / p - next / previous hunk\n"
        "F5 - reload both files, keep position\n"
        "Edit menu - edit a side (ENV:EDITOR), rediff on return\n"
        "Esc or q - quit");
}

static int domenu(UWORD code)   /* returns 1 = quit */
{
    UWORD c = code;
    while (c != MENUNULL) {
        struct MenuItem *item = ItemAddress(gmenu, c);
        if (MENUNUM(c) == 0) {
            switch (ITEMNUM(c)) {
            case 0:             /* Open Files... - one by one, his ask */
                if (askfile("cdiff: select the LEFT file", gf1)) {
                    settitle();
                    askfile("cdiff: select the RIGHT file", gf2);
                }
                reload();
                break;
            case 1:             /* Open Left... */
                if (askfile("cdiff: select the LEFT file", gf1))
                    reload();
                break;
            case 2:             /* Open Right... */
                if (askfile("cdiff: select the RIGHT file", gf2))
                    reload();
                break;
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
                  IDCMP_NEWSIZE,
        WA_Flags, WFLG_DRAGBAR | WFLG_DEPTHGADGET |
                  WFLG_CLOSEGADGET | WFLG_SIMPLE_REFRESH |
                  WFLG_ACTIVATE | WFLG_SIZEGADGET | WFLG_SIZEBBOTTOM,
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
    {
        /* the screen's GUI pens for the tab bevels; fall back to
         * the 4-colour defaults if DrawInfo is unavailable */
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

    if (gf1[0] && gf2[0]) {         /* CLI gave the pair up front */
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
            ReplyMsg((struct Message *)msg);
            if (class == IDCMP_CLOSEWINDOW) done = 1;
            if (class == IDCMP_MENUPICK) {
                if (gmenu && domenu(code)) done = 1;
            }
            if (class == IDCMP_REFRESHWINDOW) {
                BeginRefresh(win);
                drawpage();
                EndRefresh(win, TRUE);
            }
            if (class == IDCMP_NEWSIZE) {
                calcgrid();
                clamptops();
                drawpage();
            }
            if (class == IDCMP_MOUSEBUTTONS && code == SELECTDOWN) {
                if (tabsok && my >= y0 && my <= y0 + tabh) {
                    int i;
                    for (i = 0; i < 3; i++)
                        if (mx >= tabx[i] && mx < tabe[i])
                            setview(i);
                }
            }
            if (class == IDCMP_VANILLAKEY) {
                switch (code) {
                case 27: case 'q': case 'Q': done = 1; break;
                case 9:             /* Tab cycles; Shift+Tab back */
                    if (qual & (IEQUALIFIER_LSHIFT | IEQUALIFIER_RSHIFT))
                        setview((view + 2) % 3);
                    else
                        setview((view + 1) % 3);
                    break;
                case '1': setview(0); break;
                case '2': setview(1); break;
                case '3': setview(2); break;
                case ' ': scrollto(*vtop() + crows); break;
                case 'b': case 'B': scrollto(*vtop() - crows); break;
                case 't': case 'T': scrollto(0); break;
                case 'e': case 'E': scrollto(vcount()); break;
                case 'n': case 'N':
                    scrollto(nexthunk(*vtop(), 1)); break;
                case 'p': case 'P':
                    scrollto(nexthunk(*vtop(), -1)); break;
                }
            }
            if (class == IDCMP_RAWKEY) {
                int page = (qual & (IEQUALIFIER_LSHIFT |
                                    IEQUALIFIER_RSHIFT)) != 0;
                if (code == 0x4C)      /* cursor up */
                    scrollto(*vtop() - (page ? crows : 1));
                else if (code == 0x4D) /* cursor down */
                    scrollto(*vtop() + (page ? crows : 1));
                else if (code == 0x54) /* F5: reload, the CFile reflex */
                    refreshdiff();
                else if (code == 0x42 && page)
                    /* Shift+Tab has NO vanilla translation - it
                     * falls through as RAWKEY (plain Tab arrives
                     * as VANILLAKEY 9 and never gets here) */
                    setview((view + 2) % 3);
                else if (code == 0x7A) /* NewMouse: wheel up */
                    scrollto(*vtop() - (page ? crows : 3));
                else if (code == 0x7B) /* NewMouse: wheel down */
                    scrollto(*vtop() + (page ? crows : 3));
                else if (code == 0x4F || code == 0x4E) {
                    /* horizontal: every row's text moves, so this
                     * stays a content repaint (the CFile editor's
                     * edxoff precedent) - the gutter is pinned */
                    int step = page ? 40 : 8;
                    int nh = hoff + (code == 0x4E ? step : -step);
                    if (nh < 0) nh = 0;
                    if (nh > 440) nh = 440;
                    if (nh != hoff) {
                        hoff = nh;
                        drawrows();
                    }
                }
            }
        }
    }
    if (gmenu) ClearMenuStrip(win);
    CloseWindow(win);
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

int main(int argc, char **argv)
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
        strncpy(gf1, (char *)argarr[0], sizeof(gf1) - 1);
        strncpy(gf2, (char *)argarr[1], sizeof(gf2) - 1);
        guimode();
        freediff();
    }
    FreeArgs(rda);
    return 0;
}
