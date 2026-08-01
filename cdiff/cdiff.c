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
    "$VER: cdiff 0.1b6 (1.8.26)";

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

/* draw one text cell run, tab-expanded, clipped to width cells */
static void drawtext(int x, int y, const DLine *l, int width,
                     int pen, int bg)
{
    static char ex[512];
    int i, o = 0;
    if (width > 512) width = 512;
    for (i = 0; i < l->len && o < width; i++) {
        char ch = l->ptr[i];
        if (ch == '\t') {
            do { ex[o++] = ' '; } while ((o & 7) && o < width);
        } else
            ex[o++] = (ch >= 32 || ch < 0) ? ch : '.';
    }
    SetAPen(rp, pen);
    SetBPen(rp, bg);
    Move(rp, x, y + fbase);
    if (o > 0) Text(rp, (STRPTR)ex, o);
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

/* one side of a row: optional bar fill, gutter number, the text.
 * The gutter recedes by palette hierarchy (his ask - there is no
 * dark grey on a 4-colour WB): blue-on-gray for plain rows, and
 * black-on-blue under the bar - always a step quieter than the
 * content beside it. */
static void drawside(int x, int y, const DLine *l, long line, int bar)
{
    int tx = x, tw = halfw;
    if (bar) {
        SetAPen(rp, 3);
        RectFill(rp, x, y, x + halfw * fw - 1, y + fh - 1);
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
    int y = y0 + vr * fh;
    int bar, x1;
    Row *r;
    SetAPen(rp, 0);
    RectFill(rp, x0, y, x0 + viscols * fw - 1, y + fh - 1);
    if (idx >= gnrows) return;
    r = &grows[idx];
    bar = r->tag != ' ';
    x1 = x0 + (halfw + 3) * fw;         /* right pane's left edge */
    if (r->al >= 0)
        drawside(x0, y, &ga[r->al], r->al, bar);
    if (bar) {
        SetAPen(rp, 3);
        SetBPen(rp, 0);
        Move(rp, x0 + (halfw + 1) * fw, y + fbase);
        Text(rp, (STRPTR)&r->tag, 1);
    }
    if (r->bl >= 0)
        drawside(x1, y, &gb[r->bl], r->bl, bar);
}

static void drawpage(void)
{
    int vr;
    for (vr = 0; vr < visrows; vr++)
        drawrow(vr);
    if (ga == NULL) {           /* WB start, nothing loaded yet */
        static const char hint[] =
            "no files loaded - Project / Open Files... "
            "(right mouse button)";
        SetAPen(rp, 1);
        SetBPen(rp, 0);
        Move(rp, x0 + 2 * fw, y0 + fh + fbase);
        Text(rp, (STRPTR)hint, sizeof(hint) - 1);
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

/* scroll so row `target` is on top, clamped; full repaint (the
 * ScrollRaster road is roadmap b3, deliberately) */
static void scrollto(int target)
{
    int max = gnrows - visrows;
    if (max < 0) max = 0;
    if (target > max) target = max;
    if (target < 0) target = 0;
    if (target == gtop) return;
    gtop = target;
    drawpage();
}

static int nexthunk(int from, int dir)
{
    int i = from + dir;
    while (i > 0 && i < gnrows && grows[i].tag != ' ') i += dir;
    while (i >= 0 && i < gnrows && grows[i].tag == ' ') i += dir;
    if (i < 0 || i >= gnrows) return from;
    /* walk back to the hunk's first row */
    while (i > 0 && grows[i - 1].tag != ' ') i--;
    return i;
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
    ga = gb = NULL;
    gna = gnb = 0;
    gtop = 0;
}

static void calcgut(void)
{
    int m = gna > gnb ? gna : gnb;
    gutw = 1;
    while (m >= 10) { m /= 10; gutw++; }
    if (halfw < gutw + 12) gutw = 0;    /* too narrow: no gutter */
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
        (grows = buildrows(gops, nops, &nrows)) == NULL) {
        erq("out of memory");
        freediff();
        return -1;
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

static struct NewMenu newmenu[] = {
    { NM_TITLE, (STRPTR)"Project",       NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open Files...", (STRPTR)"O",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open Left...",  (STRPTR)"L",  0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open Right...", (STRPTR)"R",  0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,             NULL,         0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Quit",          (STRPTR)"Q",  0, 0, NULL },
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
    erq("cursor up/down - scroll (shift = page)\n"
        "space / b - page down / up\n"
        "t / e - top / end\n"
        "n / p - next / previous hunk\n"
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
                  IDCMP_MENUPICK,
        WA_Flags, WFLG_DRAGBAR | WFLG_DEPTHGADGET |
                  WFLG_CLOSEGADGET | WFLG_SIMPLE_REFRESH |
                  WFLG_ACTIVATE,
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
    x0 = win->BorderLeft;
    y0 = win->BorderTop;
    viscols = (win->Width - win->BorderLeft - win->BorderRight) / fw;
    visrows = (win->Height - win->BorderTop - win->BorderBottom) / fh;
    halfw = (viscols - 3) / 2;

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
            if (class == IDCMP_VANILLAKEY) {
                switch (code) {
                case 27: case 'q': case 'Q': done = 1; break;
                case ' ': scrollto(gtop + visrows); break;
                case 'b': case 'B': scrollto(gtop - visrows); break;
                case 't': case 'T': scrollto(0); break;
                case 'e': case 'E': scrollto(gnrows); break;
                case 'n': case 'N': scrollto(nexthunk(gtop, 1)); break;
                case 'p': case 'P': scrollto(nexthunk(gtop, -1)); break;
                }
            }
            if (class == IDCMP_RAWKEY) {
                int page = (qual & (IEQUALIFIER_LSHIFT |
                                    IEQUALIFIER_RSHIFT)) != 0;
                if (code == 0x4C)      /* cursor up */
                    scrollto(gtop - (page ? visrows : 1));
                else if (code == 0x4D) /* cursor down */
                    scrollto(gtop + (page ? visrows : 1));
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
