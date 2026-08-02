/* ltxwin - the shared GUI chassis of the LTX AmigaTools family.
 * See ltxwin.h for what belongs here and what does not.
 *
 * Lifted from cdiff 0.1b109 at cedit b0. Build-tag comments (b73,
 * b87, b102, b109...) are cdiff's and are kept: they are the reason
 * each line reads the way it does, and losing them would lose the
 * post-mortems that produced them.
 */
#include <exec/types.h>
#include <intuition/intuition.h>
#include <intuition/imageclass.h>   /* sysiclass: the arrow images */
#include <intuition/screens.h>
#include <workbench/startup.h>
#include <workbench/workbench.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/icon.h>
#include <proto/diskfont.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ltxwin.h"

/* initialized on purpose: a strong definition keeps libnix's
 * auto-open modules out of the link - a TEXT/CLI mode must run where
 * these libraries don't exist (vamos), so ONLY the app's guimode
 * opens them. They live here rather than in the app because the
 * chassis is what needs them; the app closes them as it always did. */
struct IntuitionBase *IntuitionBase = NULL;
struct GfxBase *GfxBase = NULL;
struct Library *GadToolsBase = NULL;
struct Library *AslBase = NULL;
struct Library *WorkbenchBase = NULL;   /* b69: AppWindow drops */
struct Library *IconBase = NULL;        /* b72: the AppIcon's image */
struct Library *DiskfontBase = NULL;    /* b73: FONT= tooltype */

struct Window *win;

BPTR ttoollock;                 /* our own drawer, for the AppIcon */
char ttoolname[110];

struct RastPort *rp;
struct TextFont *font;
int fw, fh, fbase;
int hoff;
int gutw;
int tttab = 8, ttmask = 7;

char ltx_vis[LTX_MAXCOLS];

/* ---- the row painter -------------------------------------------- */

/* b97: expand a line into columns exactly as the painter renders it
 * - same tab rule, same control-char substitution - so an intra-line
 * comparison can never disagree with what is on screen. */
int ltx_expandvis(const char *src, int len, int width)
{
    int i, o = 0, n, end;
    if (width <= 0) return 0;
    if (width > LTX_MAXCOLS) width = LTX_MAXCOLS;
    end = hoff + width;
    for (i = 0; i < len && o < end; i++) {
        char ch = src[i];
        if (ch == '\t') {
            do {
                if (o >= hoff) ltx_vis[o - hoff] = ' ';
                o++;
            } while ((ttmask ? (o & ttmask) : (o % tttab)) && o < end);
        } else {
            if (o >= hoff) ltx_vis[o - hoff] = (ch >= 32 || ch < 0) ? ch : '.';
            o++;
        }
    }
    n = o - hoff;
    if (n < 0) n = 0;
    while (n < width) ltx_vis[n++] = ' ';
    return width;
}

void ltx_drawruns(int x, int y, const char *vis, int width,
                  const LtxRun *runs, int nruns)
{
    int i;
    if (width <= 0 || nruns < 1) return;
    for (i = 0; i < nruns; i++) {
        int s = runs[i].start;
        int e = (i + 1 < nruns) ? runs[i + 1].start : width;
        if (s < 0) s = 0;
        if (e > width) e = width;
        if (s >= e) continue;           /* an empty run paints nothing */
        SetAPen(rp, runs[i].pen);
        SetBPen(rp, runs[i].bg);
        Move(rp, x + s * fw, y + fbase);
        Text(rp, (STRPTR)vis + s, e - s);
    }
}

void drawnum(int x, int y, long line, int pen, int bg)
{
    static char nb[24];
    sprintf(nb, "%*ld ", gutw, line + 1);
    SetAPen(rp, pen);
    SetBPen(rp, bg);
    Move(rp, x, y + fbase);
    Text(rp, (STRPTR)nb, gutw + 1);
}

/* ---- opening the window ----------------------------------------- */

struct Screen *ltx_myscr;
static struct TextFont *ourfont;    /* what we opened, to close */

/* b73: the font is opened once and kept for the life of the program
 * - the window can be reopened after an iconify, and re-opening per
 * window would leak.
 *
 * A PROPORTIONAL font is refused outright by tryfont: every
 * measurement in these programs is columns x fw, so a variable-width
 * face would not render badly, it would render nonsense. Falling
 * back to the system font is the honest answer. */
static void openfont(const char *name, int size)
{
    struct TextFont *tf;
    if (font || name == NULL || name[0] == 0) return;
    tf = tryfont(name, size);
    if (tf == NULL) {
        /* b109: retry lowercased. OpenFont's list is case-sensitive
         * but the filesystem is not, so "Topaz" misses the ROM topaz
         * while "microknight" still finds MicroKnight.font on disk. */
        char lc[64];
        int i;
        for (i = 0; name[i] && i < (int)sizeof(lc) - 1; i++)
            lc[i] = (name[i] >= 'A' && name[i] <= 'Z')
                        ? name[i] + 32 : name[i];
        lc[i] = 0;
        if (strcmp(lc, name)) tf = tryfont(lc, size);
    }
    if (tf) font = ourfont = tf;
}

void ltx_closefont(void)
{
    if (ourfont) { CloseFont(ourfont); ourfont = NULL; }
    font = NULL;
}

int ltx_openwin(const LtxWinSpec *sp, struct Screen **scrp,
                struct DrawInfo **drip)
{
    struct Screen *scr;
    struct DrawInfo *dri = NULL;
    int wleft, wtop, wwide, whigh;

    *scrp = NULL;
    *drip = NULL;
    /* b78: a screen of our own when OPENSCREEN= names one. Cloned
     * from Workbench (mode, colours, and depth unless SCREENDEPTH=
     * says otherwise), published under that name so it behaves like
     * any other public screen. If it will not open we fall back to
     * Workbench rather than refusing to start. */
    if (sp->scrname && sp->scrname[0] && ltx_myscr == NULL) {
        ltx_myscr = OpenScreenTags(NULL,
            SA_LikeWorkbench, TRUE,
            sp->depth ? SA_Depth : TAG_IGNORE, (ULONG)sp->depth,
            SA_Type,      PUBLICSCREEN,
            SA_PubName,   (ULONG)sp->scrname,
            SA_Title,     (ULONG)sp->scrname,
            SA_SharePens, TRUE,
            TAG_DONE);
        if (ltx_myscr) PubScreenStatus(ltx_myscr, 0);   /* let others in */
    }
    /* precedence: our own screen, then a named one to attach to,
     * then Workbench. OPENSCREEN wins when both are set - asking for
     * a screen of your own is the more specific request, and
     * attaching is the fallback. A named screen that is not there
     * falls through to Workbench rather than refusing to start. */
    scr = ltx_myscr;
    if (scr == NULL && sp->pubscr && sp->pubscr[0])
        scr = LockPubScreen((STRPTR)sp->pubscr);
    if (scr == NULL) scr = LockPubScreen(NULL);
    if (scr == NULL) return 0;
    /* b73/b81: LEFT/TOP/WIDTH/HEIGHT, each independent. The size is
     * measured FROM the position, so -1 (or no size at all) reaches
     * the screen edge without ever overrunning it. */
    wleft = sp->left >= 0 ? sp->left : 0;
    wtop  = sp->top  >= 0 ? sp->top  : scr->BarHeight + 1;
    wwide = sp->width  > 0 ? sp->width  : scr->Width  - wleft;
    whigh = sp->height > 0 ? sp->height : scr->Height - wtop;
    win = OpenWindowTags(NULL,
        WA_Left,   wleft,
        WA_Top,    wtop,
        WA_Width,  wwide,
        WA_Height, whigh,
        WA_Title, (ULONG)sp->title,
        WA_IconifyGadget, TRUE,   /* b72: V47 - ignored below it */
        ltx_myscr ? WA_CustomScreen : WA_PubScreen, (ULONG)scr,
        WA_IDCMP, sp->idcmp,
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
        WA_MinWidth, sp->minwidth,
        WA_MinHeight, sp->minheight,
        WA_MaxWidth, ~0,
        WA_MaxHeight, ~0,
        WA_NewLookMenus, TRUE,
        TAG_DONE);
    if (win == NULL) {
        if (!ltx_myscr) UnlockPubScreen(NULL, scr);
        return 0;
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
    rp = win->RPort;
    openfont(sp->fontname, sp->fontsize);
    if (font == NULL) font = GfxBase->DefaultFont;  /* system monospace */
    SetFont(rp, font);
    fw = font->tf_XSize;
    fh = font->tf_YSize;
    fbase = font->tf_Baseline;
    *scrp = scr;
    *drip = dri;
    return 1;
}

void ltx_screendone(struct Screen *scr, struct DrawInfo *dri)
{
    if (dri) FreeScreenDrawInfo(scr, dri);
    if (!ltx_myscr) UnlockPubScreen(NULL, scr);     /* ours needs no lock */
}

void ltx_closewindow(void)
{
    CloseWindow(win);
    win = NULL;
}

/* b78: the screen goes with the window - iconifying must not leave
 * an empty screen of ours sitting on the display. */
void ltx_closescreen(void)
{
    if (ltx_myscr) { CloseScreen(ltx_myscr); ltx_myscr = NULL; }
}

/* ---- the window grid -------------------------------------------- */

int gx0, gy0, viscols, visrows;
int xend, slx;
int conty, crows;
int tabh;
int staty = -1;
int ttstatus = 1;               /* STATUSBAR=YES/NO, default on */

int pshine = 2, pshadow = 1, pfill = 3, pfilltext = 2,
    ptext = 1, pback = 0;

const LtxApp *ltxapp;

void ltx_setapp(const LtxApp *a)
{
    ltxapp = a;
}

void ltx_calcgrid(void)
{
    gx0 = win->BorderLeft;
    gy0 = win->BorderTop;
    viscols = (win->Width - win->BorderLeft - win->BorderRight) / fw;
    visrows = (win->Height - win->BorderTop - win->BorderBottom) / fh;
    xend = win->Width - win->BorderRight - 1;
    slx  = gx0 + viscols * fw;   /* first pixel past the last cell */
    /* b60: 2px shorter (his eye). The label baseline is fixed at
     * gy0 + 2 + fbase, so the text does not move and the whole
     * saving comes off the bottom - which also lifts conty and
     * gains the content a couple of pixels. */
    tabh = fh + 2;
    conty = gy0 + tabh + 2;
    /* b83, his ask: the status text sits exactly ONE pixel above the
     * window border at every window size. So it is PINNED to the
     * bottom rather than riding the text grid - the sub-cell slack
     * now lands between the last content row and the status row,
     * instead of below the status row where it varied with height.
     * Text occupies staty..staty+fh-1, and the border begins at
     * Height-BorderBottom, so this leaves precisely one blank row. */
    staty = ttstatus ? win->Height - win->BorderBottom - 1 - fh : -1;
    /* b84: and two more pixels above the text - one for the shine
     * rule at staty-2, one blank at staty-1 - so the content can
     * never run into the divider */
    crows = staty >= 0 ? (staty - 2 - conty) / fh
                       : (win->Height - win->BorderBottom - conty) / fh;
    if (crows < 1) {            /* too short for both - content wins */
        staty = -1;
        crows = (win->Height - win->BorderBottom - conty) / fh;
        if (crows < 1) crows = 1;
    }
}

/* ---- the tab bar ------------------------------------------------ */

int ltx_tabx[LTX_MAXTABS], ltx_tabe[LTX_MAXTABS];
int ltx_ntabs;

void ltx_drawtabs(const char *const *labels, int n, int active)
{
    int i, x, w, yr = gy0 + tabh, winr = xend;
    if (rp == NULL) return;
    SetAPen(rp, pback);
    RectFill(rp, gx0, gy0, winr, yr + 1);
    if (n > LTX_MAXTABS) n = LTX_MAXTABS;
    ltx_ntabs = n;
    if (n < 1) return;
    if (active < 0 || active >= n) active = 0;
    x = gx0 + 2;
    for (i = 0; i < n; i++) {
        int lw = strlen(labels[i]);
        w = lw * fw + 12;               /* label + side padding */
        /* clip into the window - narrow windows must not get
         * their border overpainted (his find, the hint lesson) */
        if (x + w > winr) {
            w = winr - x;
            lw = (w - 12) / fw;
            if (lw < 1) {               /* no room left at all */
                ltx_tabx[i] = winr;
                ltx_tabe[i] = winr;
                continue;
            }
        }
        ltx_tabx[i] = x;
        ltx_tabe[i] = x + w;
        /* body - b59: every tab takes the page background, active
         * included (his ask: no blue). What marks the active one is
         * the base rule breaking open under it, not a fill. */
        SetAPen(rp, pback);
        RectFill(rp, x + 1, gy0 + 1, x + w - 2, yr - 1);
        /* bevel: shine top+left, shadow right */
        SetAPen(rp, pshine);
        Move(rp, x, yr - 1);
        Draw(rp, x, gy0);
        Draw(rp, x + w - 2, gy0);
        SetAPen(rp, pshadow);
        Move(rp, x + w - 1, gy0 + 1);
        Draw(rp, x + w - 1, yr - 1);
        /* label, centred in the tab - b59: one pen pair now that
         * the active tab is no longer filled */
        SetAPen(rp, ptext);
        SetBPen(rp, pback);
        Move(rp, x + 6, gy0 + 2 + fbase);
        Text(rp, (STRPTR)labels[i], lw);
        x += w + 3;
    }
    /* base rule in shine, broken open under the active tab - the
     * classic "this tab is the page you are on" statement */
    SetAPen(rp, pshine);
    if (ltx_tabx[active] > gx0) {
        Move(rp, gx0, yr);
        Draw(rp, ltx_tabx[active], yr);
    }
    Move(rp, ltx_tabe[active] - 1, yr);
    Draw(rp, winr, yr);
    /* b59: the active tab's floor is the page background, so the
     * rule span under it is erased to pback - tab and page read as
     * one continuous surface and the separator does not cut across
     * it (his ask). This is the ONLY thing distinguishing the
     * active tab now, so the span must stay exactly as wide as the
     * tab's own body. */
    SetAPen(rp, pback);
    Move(rp, ltx_tabx[active] + 1, yr);
    Draw(rp, ltx_tabe[active] - 2, yr);
}

/* ---- the status row --------------------------------------------- */

/* b82: ONE padded Text, so it repaints in a single blit and can
 * never be caught half-drawn (the b66 rule). It sits OUTSIDE the
 * scroll rectangle, so the scroll blit never disturbs it; it just
 * needs redrawing whenever the position changes.
 *
 * cedit b0b: the app composes the left-hand text - a hunk count is
 * cdiff's idea, a line/column is cedit's - and the chassis owns the
 * padding, the right-aligned percentage and the rule above. b82's
 * other lesson travels with it: whatever fills that string must be
 * cheap or cached, because this runs on every position change. */
void drawstatus(void)
{
    static char sb[320];
    int max, pct, w, i, len;
    char pc[16];

    if (win == NULL || staty < 0 || rp == NULL || ltxapp == NULL) return;
    w = viscols;
    if (w > (int)sizeof(sb) - 1) w = sizeof(sb) - 1;
    if (w < 1) return;

    max = ltxapp->rowcount() - crows;
    if (max < 0) max = 0;
    pct = max > 0
        ? (int)(((long)*ltxapp->toprow() * 100 + max / 2) / max) : 100;

    sb[0] = 0;
    ltxapp->statustext(sb, (int)sizeof(sb) - 1);

    len = strlen(sb);
    if (len > w) len = w;
    for (i = len; i < w; i++) sb[i] = ' ';
    sb[w] = 0;
    /* the percentage right-aligned, written over the padding */
    sprintf(pc, "%d%% ", pct);
    len = strlen(pc);
    if (len < w) memcpy(sb + w - len, pc, len);

    /* b84, his ask: a rule above the row, with exactly one blank
     * pixel between it and the text. calcgrid reserved those two
     * pixels, so this can never land on a content row. b86: back to
     * SHINEPEN after seeing both (his eye). */
    if (staty - 2 >= conty) {
        SetAPen(rp, pshine);
        Move(rp, gx0, staty - 2);
        Draw(rp, xend, staty - 2);
    }
    SetAPen(rp, 1);
    SetBPen(rp, 0);
    Move(rp, gx0, staty + fbase);
    Text(rp, (STRPTR)sb, w);
}

/* ---- the border scrollers --------------------------------------- */

/* his verdict on the alternative: "a CLI program in a GUI" - raw
 * prop gadgets, border-relative so resize repositions them free */
struct Gadget vgad, hgad;
static struct PropInfo vpi, hpi;
static struct Image vim, him;
int gadsok;

/* b48: the arrows, from b30's post-mortem rather than a new guess.
 * Boolean gadgets rendering sysiclass images, held in the same two
 * borders as the props. arrheld is the button under the mouse for
 * the INTUITICKS repeat; 0 when none. */
struct Gadget agup, agdn, aglt, agrt;
static APTR iup, idn, ilt, irt;
int arrowsok, arrheld;

int propheld;
int defer;
int dirtyall, dirtyrows, dirtyknob;
int scrollfrom, scrollfromset;
int ltx_appowed;
int ttfast;

/* keep both knobs honest: body = visible share, pot = position */
void updscrollers(void)
{
    ULONG vbody, vpot, hbody, hpot;
    long total, vis = crows, top;
    int ht;
    if (!gadsok || ltxapp == NULL) return;
    if (defer) { dirtyknob = 1; return; }
    total = ltxapp->rowcount();
    top = *ltxapp->toprow();
    /* after the guard, and floored at 1: colcount() is max(content,
     * viscols) and both are 0 before the first calcgrid, which would
     * divide by zero below */
    ht = ltxapp->colcount();
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
void addscrollers(struct DrawInfo *dri, struct Screen *scr)
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

void freearrows(void)
{
    if (iup) { DisposeObject(iup); iup = NULL; }
    if (idn) { DisposeObject(idn); idn = NULL; }
    if (ilt) { DisposeObject(ilt); ilt = NULL; }
    if (irt) { DisposeObject(irt); irt = NULL; }
    arrowsok = 0;
}

/* ---- the scroll engine ------------------------------------------ */

/* scroll the ACTIVE view so `target` is on top, clamped. The CFile
 * R1 rule (graphics-and-performance.md): a scroll step is ONE blit
 * of the content rectangle plus repaints of only the entering rows
 * - not a page of Texts, and never the tab bar. Jumps of a page or
 * more repaint the content whole (one pass beats a huge blit plus
 * a full repaint). */
/* b63: the scroll PAINT, from wherever the screen currently is to
 * wherever the state now says it should be. Split out of scrollto
 * so a deferred burst can replay it ONCE over the whole distance
 * instead of the caller having to paint every step. */
void paintscroll(int from, int to)
{
    int d = to - from, vr;
    if (d == 0 || ltxapp == NULL) return;
    /* b92: with Fast scroll OFF every step is a full row repaint -
     * no blit, no retained pixels. His screenshots show the screen
     * holding TWO scroll states split at a seam, and since scrolling
     * only ever blits and redraws the entering rows, nothing ever
     * repairs that. Turning the blit off decides in one boot whether
     * the fault is in the blit or in the row drawing, and if it is
     * the blit this is also a working fallback - b65/b66 made a full
     * repaint far cheaper than it used to be. */
    if (ttfast && (d > -crows) && (d < crows)) {
        SetBPen(rp, 0);         /* the blit fills exposed with BgPen */
        /* b93: ScrollRaster, NOT ScrollWindowRaster. His bisection
         * settled it - Fast scroll OFF (full row repaint) is clean,
         * ON was not, so the fault was the blit and not the row
         * drawing. And cdiff was the only tool in this family using
         * the V39 Intuition call: CCON scrolls with graphics.library's
         * ScrollRaster, seventeen call sites, on this same PiStorm
         * A1200 at five times stock speed with no artifacts. Use the
         * primitive that is proven on the hardware in front of us.
         * Bonus: ScrollRaster is V33, so the fast path no longer
         * needs the >= V39 guard the old call did. */
        ScrollRaster(rp, 0, d * fh,
                     gx0, conty,
                     gx0 + viscols * fw - 1,
                     conty + crows * fh - 1);
        /* b91, and the whole diagnosis is his two screenshots plus
         * the telemetry: every number was RIGHT, so the arithmetic
         * was never the fault. The picture showed line numbers
         * running 458..472 then 476..484 - exactly d rows missing,
         * with a torn row at the seam. The LOWER part of the rect
         * had scrolled and the upper part had not: a partial blit.
         *
         * The blit queues blitter work; Text() renders with the CPU.
         * Without a barrier the glyphs can land in a region the
         * blitter has not finished moving - which is why scrolling
         * DOWN garbled and scrolling UP never did. The entering rows
         * for a downward scroll sit at the BOTTOM, the part the blit
         * reaches LAST; for an upward scroll they sit at the top,
         * already moved by the time we draw. */
        WaitBlit();
        if (d > 0) {            /* moved up: new rows at the bottom */
            for (vr = crows - d; vr < crows; vr++)
                ltxapp->paintrow(vr);
        } else {                /* moved down: new rows on top */
            for (vr = 0; vr < -d; vr++)
                ltxapp->paintrow(vr);
        }
    } else
        ltxapp->paintrows();    /* too far to blit: full rows */
}

void scrollto(int target)
{
    int *t, from;
    int max;
    if (ltxapp == NULL) return;
    t = ltxapp->toprow();
    max = ltxapp->rowcount() - crows;
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

/* pan to column `nh`, clamped to the real content width - the one
 * path to hoff for arrows and keys alike, so a held-down arrow can
 * never walk it past what the painter will show. b58: the clamp was
 * a flat 440, which is why panning worked over an empty window; with
 * nothing loaded colcount() == viscols and the ceiling is 0. */
void sethoff(int nh)
{
    int ht;
    if (ltxapp == NULL) return;
    ht = ltxapp->colcount();
    if (nh > ht - viscols) nh = ht - viscols;
    if (nh < 0) nh = 0;
    if (nh == hoff) return;
    hoff = nh;
    if (defer) { dirtyrows = 1; return; }
    ltxapp->paintrows();
    updscrollers();
}

/* b64: follow a knob that Intuition is dragging. The PropInfo pot
 * is the truth - Intuition updates it in place as the mouse moves,
 * so converting it to a row/column here tracks the drag no matter
 * which IDCMP class happened to wake us. Cheap and idempotent: if
 * the pot still agrees with where we are, both calls return
 * immediately having done nothing. */
void ltx_trackvert(void)
{
    long total, vis = crows;
    if (ltxapp == NULL) return;
    total = ltxapp->rowcount();
    if (total > vis)
        scrollto((int)(((ULONG)vpi.VertPot * (total - vis)
                        + 0x7FFF) / 0xFFFF));
}

void ltx_trackhoriz(void)
{
    int ht;
    if (ltxapp == NULL) return;
    ht = ltxapp->colcount();
    if (ht > viscols)
        sethoff((int)(((ULONG)hpi.HorizPot * (ht - viscols)
                       + 0x7FFF) / 0xFFFF));
}

void proptrack(void)
{
    if (propheld == 1) ltx_trackvert();
    else if (propheld == 2) ltx_trackhoriz();
}

/* b63: is another message ALREADY queued? A held key or a dragged
 * knob arrives as a stream, and painting every message of it is
 * what stutters. This answers "is more coming right now", so the
 * paint can be skipped for every message but the last of a burst.
 * Forbid/Permit because Intuition appends to this list from input
 * server context. */
int inputwaiting(void)
{
    int more;
    Forbid();
    more = win->UserPort->mp_MsgList.lh_Head->ln_Succ != NULL;
    Permit();
    return more;
}

/* b63: settle whatever painting the burst ran up, ONCE, on the
 * final state. b62 got this wrong twice: it always paid the debt
 * with a full page (making a SINGLE keypress more expensive than
 * the incremental scroll it replaced), and it only ran after the
 * message loop exited - which during a knob drag never happened, so
 * nothing moved until the button came up. Now the debt is typed, the
 * cheapest sufficient repaint is chosen, and the caller runs this
 * the moment the port is empty. */
void flushpaint(void)
{
    int owed = dirtyall || dirtyrows || scrollfromset || ltx_appowed;
    if (win == NULL || ltxapp == NULL) return;  /* b72: iconified */
    /* b70: clear defer BEFORE the early return. It used to sit
     * inside the "something is owed" path, so a message that owed
     * no painting left the flag armed - harmless while every
     * painter ran inside the IDCMP drain that re-arms it each
     * message, and a real bug the moment anything painted from
     * OUTSIDE that drain. His find: a dropped icon loaded the files
     * but the window did not change until it was activated again -
     * the drop had painted into a deferred debt nobody settled. */
    defer = 0;
    if (!owed && !dirtyknob) return;
    /* b95: start the repaint just after the beam has passed, so as
     * much of it as possible lands inside one frame. This does NOT
     * cure the tearing he chased for six builds - a 25-row repaint
     * outlasts a 20ms PAL frame, so the beam still catches it - but
     * it makes the seam land in a consistent place instead of
     * wandering, which the eye tolerates far better. Coalescing
     * already limits us to one repaint per input burst, so the wait
     * costs at most one frame per burst.
     *
     * The tearing is NOT a bug in this program: it is what a
     * single-buffered display does. His tests proved it - it clears
     * the instant scrolling stops, it is identical on a stock A1200
     * PAL Hires with no RTG, and it is indifferent to whether we use
     * ScrollWindowRaster, ScrollRaster, or no blit at all. */
    WaitTOF();
    if (dirtyall)
        ltxapp->pageall();              /* tabs and every row */
    else if (dirtyrows)
        ltxapp->paintrows();            /* every row's text moved */
    else {
        if (scrollfromset)
            paintscroll(scrollfrom, *ltxapp->toprow());
        if (ltx_appowed)
            ltxapp->flushapp();
    }
    dirtyall = dirtyrows = dirtyknob = 0;
    scrollfromset = 0;
    ltx_appowed = 0;
    drawstatus();       /* b82: position changed, so this did too */
    /* b64: NOT while a knob is held - Intuition is rendering that
     * knob as it tracks the mouse, and NewModifyProp would stamp
     * our own idea of the position back over the drag. */
    if (!propheld) updscrollers();
}

/* ---- fonts ------------------------------------------------------ */

/* b109: is this the font we actually asked for? Every measurement in
 * cdiff is columns x fw, so a proportional face would render
 * nonsense; an algorithmically SCALED one is not what he named; and
 * a different height means diskfont substituted something. */
static int goodfont(struct TextFont *tf, int size)
{
    return !(tf->tf_Flags & FPF_PROPORTIONAL) &&
            (tf->tf_Flags & FPF_DESIGNED) &&
            tf->tf_YSize == size;
}

/* b109, and his findings are the whole design of this:
 *
 *   FONTS:topaz.font on disk offers only size 11. Ask diskfont for
 *   topaz 8 and it SCALES 11 down - a thin ~6px face that still
 *   lays out correctly on a character grid, so nothing looks broken,
 *   only wrong. The real topaz 8 and 9 live in ROM.
 *
 * So try the ROM/memory list FIRST via OpenFont, and only then go to
 * disk. Validation happens on BOTH roads, and a rejected font falls
 * through to the next one rather than ending the search - b108 gated
 * its retry on a NULL return, which never happens when diskfont
 * hands back something scaled. */
struct TextFont *tryfont(const char *name, int size)
{
    struct TextAttr ta;
    struct TextFont *tf;
    ta.ta_Name  = (STRPTR)name;
    ta.ta_YSize = size;
    ta.ta_Style = FS_NORMAL;
    ta.ta_Flags = 0;            /* ask permissively, verify strictly */
    tf = OpenFont(&ta);
    if (tf && !goodfont(tf, size)) { CloseFont(tf); tf = NULL; }
    if (tf == NULL && DiskfontBase) {
        tf = OpenDiskFont(&ta);
        if (tf && !goodfont(tf, size)) { CloseFont(tf); tf = NULL; }
    }
    return tf;
}

/* ---- pointer ---------------------------------------------------- */

/* b102: WA_PointerDelay means the busy pointer only appears if the
 * job actually takes a moment - a fast load never flashes it. V39+;
 * older Kickstarts keep the normal pointer, as they always did. */
void busy(int on)
{
    if (win == NULL) return;
    if (IntuitionBase->LibNode.lib_Version < 39) return;
    if (on)
        SetWindowPointer(win, WA_BusyPointer, TRUE,
                              WA_PointerDelay, TRUE, TAG_DONE);
    else
        SetWindowPointer(win, TAG_DONE);
}

/* ---- b87: writing a tooltype back to the icon ------------------
 * NOT via PutDiskObject: that rewrites the whole file from
 * icon.library's in-memory parse, so anything the running library
 * version did not understand is silently dropped - an OS3.5+ colour
 * icon appendix under an older icon.library, for instance. The
 * surgical route instead, ported from CFile 0.5b51's editor (proven
 * against 400 real .info files, all 107 with tooltypes rebuilt
 * byte-identical by a no-change save) and documented in
 * AmigaReferences/icon-info-files.md:
 *
 *   new file = bytes[0..block) + rebuilt block + bytes[block end..EOF)
 *
 * Everything before and after the tooltype block is copied untouched.
 * Any bounds check that fails means we do not understand the file,
 * and an icon we do not understand is one we leave alone. */

static UWORD rdw(const UBYTE *b, long o)
{
    return (UWORD)((b[o] << 8) | b[o + 1]);
}

static ULONG rdl(const UBYTE *b, long o)
{
    return ((ULONG)b[o] << 24) | ((ULONG)b[o + 1] << 16) |
           ((ULONG)b[o + 2] << 8) | (ULONG)b[o + 3];
}

static void wrl(UBYTE *b, long o, ULONG v)
{
    b[o] = (UBYTE)(v >> 24); b[o + 1] = (UBYTE)(v >> 16);
    b[o + 2] = (UBYTE)(v >> 8); b[o + 3] = (UBYTE)v;
}

/* an Image: 20-byte header, then ((W+15)/16)*2 * H * D of planes */
static long skipimage(const UBYTE *b, long size, long off)
{
    long w, h, d;
    if (off + 20 > size) return -1;
    w = rdw(b, off + 4);
    h = rdw(b, off + 6);
    d = rdw(b, off + 8);
    if (w < 1 || h < 1 || d < 1) return -1;
    if (w > 4096 || h > 4096 || d > 8) return -1;
    off += 20 + (long)(((w + 15) >> 4) * 2) * (h * d);
    if (off > size) return -1;
    return off;
}

/* where the tooltype block starts, and where the suffix after it
 * begins (equal when the icon has none) */
static int ttlocate(const UBYTE *b, long size, long *start, long *end)
{
    long off, nent, j, l;
    if (size < 78) return 0;
    if (rdw(b, 0) != 0xE310) return 0;          /* do_Magic */
    off = 78;
    if (rdl(b, 66)) off += 56;                  /* DrawerData */
    if (off > size) return 0;
    if (rdl(b, 22) && (off = skipimage(b, size, off)) < 0) return 0;
    if (rdl(b, 26) && (off = skipimage(b, size, off)) < 0) return 0;
    if (rdl(b, 50)) {                           /* DefaultTool string */
        if (off + 4 > size) return 0;
        l = (long)rdl(b, off);
        if (l < 0 || off + 4 + l > size) return 0;
        off += 4 + l;
    }
    *start = off;
    if (rdl(b, 54)) {                           /* the block */
        if (off + 4 > size) return 0;
        nent = (long)(rdl(b, off) >> 2) - 1;    /* count = n/4 - 1 */
        if (nent < 0 || nent > 4096) return 0;
        off += 4;
        for (j = 0; j < nent; j++) {
            if (off + 4 > size) return 0;
            l = (long)rdl(b, off);
            if (l < 0 || off + 4 + l > size) return 0;
            off += 4 + l;
        }
    }
    *end = off;
    return 1;
}

/* does this entry carry the tooltype called `name`? Compares the
 * text before the '=', so a parenthesised (NAME=...) does not match
 * and a disabled line is left exactly where he put it. */
static int ttnamed(const char *e, const char *name)
{
    int i = 0;
    while (name[i] && e[i] && e[i] != '=') {
        char a = e[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return 0;
        i++;
    }
    return name[i] == 0 && e[i] == '=';
}

/* set NAME=value on our own icon, preserving every other byte */
int iconset(const char *name, const char *value)
{
    char path[400], neu[160];
    UBYTE *buf = NULL, *out = NULL;
    long size, st, en, off, nent, j, l, need, o, nn;
    BPTR fh, old;
    int ok = 0, replaced = 0;

    if (!ttoollock || !ttoolname[0]) return 0;  /* not a WB launch */
    sprintf(neu, "%.60s=%.60s", name, value);
    old = CurrentDir(ttoollock);
    sprintf(path, "%.300s.info", ttoolname);

    fh = Open((STRPTR)path, MODE_OLDFILE);
    if (fh == 0) goto done;
    Seek(fh, 0, OFFSET_END);
    size = Seek(fh, 0, OFFSET_BEGINNING);
    if (size < 78 || size > 1000000L) { Close(fh); goto done; }
    buf = malloc(size);
    if (buf == NULL) { Close(fh); goto done; }
    if (Read(fh, buf, size) != size) { Close(fh); goto done; }
    Close(fh);

    if (!ttlocate(buf, size, &st, &en)) goto done;

    /* worst case: every old byte, plus our entry, plus the count */
    need = size + strlen(neu) + 16;
    out = malloc(need);
    if (out == NULL) goto done;

    memcpy(out, buf, st);
    o = st + 4;                         /* leave room for the count */
    nn = 0;
    if (rdl(buf, 54)) {                 /* copy the entries we keep */
        nent = (long)(rdl(buf, st) >> 2) - 1;
        off = st + 4;
        for (j = 0; j < nent; j++) {
            l = (long)rdl(buf, off);
            if (ttnamed((char *)buf + off + 4, name)) {
                wrl(out, o, (ULONG)(strlen(neu) + 1));
                memcpy(out + o + 4, neu, strlen(neu) + 1);
                o += 4 + strlen(neu) + 1;
                replaced = 1;
            } else {
                memcpy(out + o, buf + off, 4 + l);
                o += 4 + l;
            }
            nn++;
            off += 4 + l;
        }
    }
    if (!replaced) {                    /* new setting: append it */
        wrl(out, o, (ULONG)(strlen(neu) + 1));
        memcpy(out + o + 4, neu, strlen(neu) + 1);
        o += 4 + strlen(neu) + 1;
        nn++;
    }
    wrl(out, st, (ULONG)((nn + 1) * 4));        /* the format's rule */
    memcpy(out + o, buf + en, size - en);
    o += size - en;
    if (!rdl(buf, 54)) wrl(out, 54, 1);         /* present-flag on */

    fh = Open((STRPTR)path, MODE_NEWFILE);
    if (fh == 0) goto done;
    ok = (Write(fh, out, o) == o);
    Close(fh);
done:
    free(buf);
    free(out);
    CurrentDir(old);
    return ok;
}

/* ---- b73: reading tooltypes ------------------------------------
 * The app decides WHICH tooltypes exist and where they land; these
 * are just the typed readers. Every setting is optional and inert
 * when absent, so a shell launch is unchanged. */

/* case-insensitive equality, so VIEW=tree and VIEW=TREE both work.
 * Local rather than utility.library's Stricmp - one more library
 * open for four comparisons is not a trade worth making. */
int tteq(const char *a, const char *b)
{
    while (*a && *b) {
        char x = *a++, y = *b++;
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return 0;
    }
    return *a == 0 && *b == 0;
}

/* b81: WIDTH=/HEIGHT= take a positive size, or -1 meaning "out to
 * the screen edge from wherever LEFT=/TOP= put us". Absent means the
 * same as -1 - which also fixes a real bug in the old defaults: a
 * LEFT= with no WIDTH= used the FULL screen width, so the window ran
 * off the right edge by exactly the left inset. Anything unparseable
 * falls back to filling rather than to a silly size; the window's own
 * WA_MinWidth/MinHeight clamp values that are too small. */
int ttdim(char **tt, const char *name)
{
    UBYTE *v = FindToolType((CONST_STRPTR *)tt, (STRPTR)name);
    int n;
    if (v == NULL) return -1;
    n = atoi((char *)v);
    return n > 0 ? n : -1;
}

int ttnum(char **tt, const char *name, int lo, int hi, int def)
{
    UBYTE *v = FindToolType((CONST_STRPTR *)tt, (STRPTR)name);
    int n;
    if (v == NULL) return def;
    n = atoi((char *)v);
    if (n < lo || n > hi) return def;
    return n;
}

void ttstr(char **tt, const char *name, char *dest, int max)
{
    UBYTE *v = FindToolType((CONST_STRPTR *)tt, (STRPTR)name);
    if (v == NULL || v[0] == 0) return;
    strncpy(dest, (char *)v, max - 1);
    dest[max - 1] = 0;
}
