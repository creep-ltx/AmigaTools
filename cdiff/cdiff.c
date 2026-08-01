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
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "diff.h"

/* 'used' or -O2 strips it - and c:Version must find it */
static const char verstag[] __attribute__((used)) =
    "$VER: cdiff 0.1b1 (1.8.26)";

unsigned long __stack = 65536;  /* libnix: engine recursion headroom */

struct IntuitionBase *IntuitionBase;
struct GfxBase *GfxBase;

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

/* draw one text cell run, tab-expanded, clipped to width cells */
static void drawtext(int x, int y, const DLine *l, int width, int pen)
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
    SetBPen(rp, 0);
    Move(rp, x, y + fbase);
    if (o > 0) Text(rp, (STRPTR)ex, o);
}

static void drawrow(int vr)
{
    int idx = gtop + vr;
    int y = y0 + vr * fh;
    int pen;
    Row *r;
    SetAPen(rp, 0);
    RectFill(rp, x0, y, x0 + viscols * fw - 1, y + fh - 1);
    if (idx >= gnrows) return;
    r = &grows[idx];
    pen = r->tag == ' ' ? 1 : 3;
    if (r->al >= 0)
        drawtext(x0, y, &ga[r->al], halfw, pen);
    if (r->tag != ' ') {
        SetAPen(rp, 3);
        Move(rp, x0 + (halfw + 1) * fw, y + fbase);
        Text(rp, (STRPTR)&r->tag, 1);
    }
    if (r->bl >= 0)
        drawtext(x0 + (halfw + 3) * fw, y, &gb[r->bl], halfw, pen);
}

static void drawpage(void)
{
    int vr;
    for (vr = 0; vr < visrows; vr++)
        drawrow(vr);
}

static void settitle(const char *f1, const char *f2)
{
    static char t[200];
    sprintf(t, "cdiff: %.70s | %.70s  (%d rows)", f1, f2, gnrows);
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

static void guimode(const char *f1, const char *f2)
{
    struct Screen *scr;
    struct IntuiMessage *msg;
    int done = 0;

    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
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
                  IDCMP_RAWKEY | IDCMP_REFRESHWINDOW,
        WA_Flags, WFLG_DRAGBAR | WFLG_DEPTHGADGET |
                  WFLG_CLOSEGADGET | WFLG_SIMPLE_REFRESH |
                  WFLG_ACTIVATE,
        TAG_DONE);
    UnlockPubScreen(NULL, scr);
    if (win == NULL) goto out;

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

    settitle(f1, f2);
    drawpage();

    while (!done) {
        WaitPort(win->UserPort);
        while ((msg = (struct IntuiMessage *)GetMsg(win->UserPort))) {
            ULONG class = msg->Class;
            UWORD code = msg->Code;
            UWORD qual = msg->Qualifier;
            ReplyMsg((struct Message *)msg);
            if (class == IDCMP_CLOSEWINDOW) done = 1;
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
    CloseWindow(win);
out:
    if (GfxBase) CloseLibrary((struct Library *)GfxBase);
    if (IntuitionBase) CloseLibrary((struct Library *)IntuitionBase);
}

/* ---- main ------------------------------------------------------- */

int main(void)
{
    static const char tmpl[] = "FILE1/A,FILE2/A,TEXT/S";
    LONG argarr[3] = { 0, 0, 0 };
    struct RDArgs *rda;
    char *buf1, *buf2;
    long sz1, sz2;
    DLine *la, *lb;
    int na, nb, nops, nrows;
    DOp *ops;

    rda = ReadArgs((STRPTR)tmpl, argarr, NULL);
    if (rda == NULL) {
        PrintFault(IoErr(), (STRPTR)"cdiff");
        return 20;
    }
    buf1 = loadfile((char *)argarr[0], &sz1);
    buf2 = loadfile((char *)argarr[1], &sz2);
    if (buf1 == NULL || buf2 == NULL) {
        printf("cdiff: cannot read %s\n",
               buf1 == NULL ? (char *)argarr[0] : (char *)argarr[1]);
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

    if (argarr[2]) {
        textmode(la, lb, ops, nops);
    } else {
        ga = la; gb = lb;
        grows = buildrows(ops, nops, &nrows);
        if (grows == NULL) {
            printf("cdiff: out of memory\n");
            FreeArgs(rda);
            return 20;
        }
        gnrows = nrows;
        gtop = 0;
        guimode((char *)argarr[0], (char *)argarr[1]);
        free(grows);
    }
    free(ops);
    free(la);
    free(lb);
    free(buf1);
    free(buf2);
    FreeArgs(rda);
    return 0;
}
