/* cedit - a GUI text editor for AmigaOS, on the LTX chassis.
 *
 * b1 is READ-ONLY on purpose. The gate for this build is that a file
 * opens and scrolls exactly the way cdiff does - same gutter, same
 * border scrollbars, same status row, same deferred-paint discipline
 * - because all of that is ltxgui/ltxwin.c, lifted out of cdiff at
 * b0 and boot-proven there. If this build scrolls right, the lift
 * was clean and everything after it is editing, not plumbing.
 *
 * The Buffer struct below already carries what b2-b5 need (cursor,
 * dirty flag, per-line lexer state) with exactly one buffer in it,
 * so multi-file tabs at b4 are a data change and not a rewrite.
 *
 * Usage: cedit [FILE]
 */
#include <exec/types.h>
#include <exec/tasks.h>
#include <intuition/intuition.h>
#include <libraries/gadtools.h>
#include <workbench/startup.h>
#include <workbench/workbench.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/gadtools.h>
#include <proto/wb.h>
#include <proto/icon.h>
#include <proto/diskfont.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ltxwin.h"
#include "edbuf.h"

/* 'used' or -O2 strips it - and c:Version must find it */
static const char verstag[] __attribute__((used)) =
    "$VER: cedit 0.1b1 (2.8.26)";

/* ---- the buffer -------------------------------------------------
 * The line table, the splitter and the width arithmetic live in
 * edbuf.c: pure logic, harness-proven on the host AND under vamos
 * before this ever boots. What stays here is the file I/O, which
 * needs dos.library and so cannot be tested that way. */

static Buffer buf;              /* b4: an array, and a current index */
static Buffer *cur = &buf;

/* whole-file read, then split. A file this size fits: cedit is for
 * source, and CFile's streaming viewer exists for the other case. */
static int loadbuf(Buffer *b, const char *path)
{
    BPTR fh;
    long size, got;
    char *raw;

    buffree(b);
    fh = Open((STRPTR)path, MODE_OLDFILE);
    if (fh == 0) return 0;
    Seek(fh, 0, OFFSET_END);
    size = Seek(fh, 0, OFFSET_BEGINNING);
    if (size < 0) { Close(fh); return 0; }
    raw = malloc(size + 1);
    if (raw == NULL) { Close(fh); return 0; }
    got = size ? Read(fh, raw, size) : 0;
    Close(fh);
    if (got < 0) { free(raw); return 0; }
    raw[got] = 0;
    if (!bufsplit(b, raw, got)) { free(raw); return 0; }
    free(raw);
    strncpy(b->path, path, sizeof(b->path) - 1);
    strncpy(b->name, (char *)FilePart((STRPTR)path), sizeof(b->name) - 1);
    return 1;
}

/* ---- tooltype settings ------------------------------------------
 * The cdiff set, minus what has no meaning here yet. All optional,
 * all inert when absent, so a shell launch is unchanged. The typed
 * readers are the chassis's; WHICH keywords exist is cedit's. */
static char ttfont[64];
static int  ttfsize = 8;
static char ttscrname[64];      /* OPENSCREEN= - a screen of ours */
static char ttpubscr[64];       /* PUBSCREEN= - somebody else's */
static int  ttdepth;            /* SCREENDEPTH= */
static int  ttleft = -1, tttop = -1, ttwidth = -1, ttheight = -1;
static int  ttgutter = 1;       /* GUTTER=YES/NO - line numbers */

static struct MsgPort *appport;
static APTR   appwin;
static APTR   gvi;
static struct Menu *gmenu;

static struct NewMenu newmenu[] = {
    { NM_TITLE, (STRPTR)"Project",    NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Quit",       (STRPTR)"Q", 0, 0, NULL },
    { NM_TITLE, (STRPTR)"Settings",   NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Line numbers", NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    { NM_ITEM,  (STRPTR)"Status bar", NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    { NM_ITEM,  (STRPTR)"Fast scroll", NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    { NM_END,   NULL,                 NULL,        0, 0, NULL },
};

/* ---- what the chassis asks --------------------------------------- */

/* the gutter is as wide as the last line number, and goes entirely
 * when the window cannot spare it - the b4 rule, and the reason it
 * is computed here rather than in the chassis: how many lines there
 * are is the app's business.
 *
 * OPEN QUESTION carried from the roadmap: this sizes to the CURRENT
 * line count, so at b2 the gutter will widen the moment typing takes
 * the file from 999 lines to 1000, shoving the text right under the
 * cursor. The intended fix is to size it at load with a floor of 4
 * and regrow only on save or reload. Left honest for now. */
static void calcgut(void)
{
    int m = cur->n;
    if (!ttgutter) { gutw = 0; return; }
    gutw = 1;
    while (m >= 10) { m /= 10; gutw++; }
    if (viscols < gutw + 12) gutw = 0;  /* too narrow: no gutter */
}

static int textx(void)
{
    return gx0 + (gutw > 0 ? (gutw + 1) * fw : 0);
}

static int textw(void)
{
    int w = viscols - (gutw > 0 ? gutw + 1 : 0);
    return w > 0 ? w : 0;
}

/* the widest expanded line is what the horizontal scroller measures
 * against; bufmaxw caches it until the text changes. */
static int ecols(void)
{
    int w = textw();
    int m = bufmaxw(cur, tttab, ttmask);
    return m > w ? m : w;
}

static int ecount(void)
{
    return cur->n;
}

static int *etop(void)
{
    return &cur->top;
}

/* one visible row. b1 paints a single run; b5 hands ltx_drawruns()
 * the lexer's list instead, and nothing else on this path changes -
 * which is the whole reason the painter was widened at b0b. */
static void erow(int vr)
{
    int i = cur->top + vr;
    int y = conty + vr * fh;
    int w;
    LtxRun run;
    if (i >= cur->n) {                  /* past the end: blank */
        SetAPen(rp, 0);
        RectFill(rp, gx0, y, gx0 + viscols * fw - 1, y + fh - 1);
        return;
    }
    if (gutw > 0) drawnum(gx0, y, (long)i, 3, 0);
    w = ltx_expandvis(cur->ln[i], cur->len[i], textw());
    run.start = 0; run.pen = 1; run.bg = 0;
    ltx_drawruns(textx(), y, ltx_vis, w, &run, 1);
}

static void erows(void)
{
    int vr;
    if (defer) { dirtyrows = 1; return; }
    for (vr = 0; vr < crows; vr++)
        erow(vr);
}

static void erowone(int vr)
{
    if (defer) { dirtyrows = 1; return; }
    erow(vr);
}

static void drawtabbar(void)
{
    const char *labs[1];
    if (cur->name[0] == 0) { ltx_drawtabs(NULL, 0, 0); return; }
    labs[0] = cur->name;
    ltx_drawtabs(labs, 1, 0);
}

static void epage(void)
{
    int s, e;
    if (win == NULL) return;
    if (defer) { dirtyall = 1; return; }
    drawtabbar();
    erows();
    /* the slack margins: the window size is rarely an exact multiple
     * of the cell, and the sub-cell strips below the last row and
     * right of the last column keep STALE pixels across a resize */
    SetAPen(rp, 0);
    s = gx0 + viscols * fw;
    e = win->Width - win->BorderRight - 1;
    if (s <= e)
        RectFill(rp, s, gy0, e, win->Height - win->BorderBottom - 1);
    s = conty + crows * fh;
    e = win->Height - win->BorderBottom - 1;
    if (s <= e)
        RectFill(rp, gx0, s, xend, e);
    if (slx <= xend)
        RectFill(rp, slx, conty, xend, e);
    drawstatus();
    updscrollers();
    if (cur->n == 0 || cur->name[0] == 0) {
        static const char hint[] = "no file loaded - cedit FILE";
        int hl = sizeof(hint) - 1;
        if (hl > viscols - 4) hl = viscols - 4;
        if (hl > 0) {
            SetAPen(rp, 1);
            SetBPen(rp, 0);
            Move(rp, gx0 + 2 * fw, conty + fh + fbase);
            Text(rp, (STRPTR)hint, hl);
        }
    }
}

/* b82's rule: whatever fills this has to be cheap, because it runs
 * on every position change. Both numbers here are O(1). */
static void estatus(char *dst, int max)
{
    if (cur->name[0] == 0)
        strcpy(dst, " nothing loaded");
    else
        sprintf(dst, " %.60s  line %d/%d", cur->name,
                cur->top + 1, cur->n);
    (void)max;
}

static void eflush(void)
{
    /* b2: the cursor's old and new rows land here, the way cdiff
     * settles its Tree cursor. Nothing owes paint at b1. */
}

static const LtxApp ceditapp = {
    ecount, etop, ecols, erowone, erows, epage, estatus, eflush
};

/* ---- window ------------------------------------------------------ */

static void calcgrid(void)
{
    ltx_calcgrid();
    calcgut();
}

static void settitle(void)
{
    static char t[400];
    if (win == NULL) return;
    if (cur->path[0])
        sprintf(t, "cedit: %.300s%s", cur->path, cur->dirty ? " *" : "");
    else
        strcpy(t, "cedit");
    SetWindowTitles(win, (STRPTR)t, (STRPTR)~0);
}

static void clamptop(void)
{
    int m = cur->n - crows;
    if (m < 0) m = 0;
    if (cur->top > m) cur->top = m;
    if (cur->top < 0) cur->top = 0;
}

static int openmain(void)
{
    struct Screen *scr;
    struct DrawInfo *dri;
    static LtxWinSpec spec;
    spec.title     = "cedit";
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
                     IDCMP_GADGETUP | IDCMP_MOUSEMOVE |
                     IDCMP_INTUITICKS;
    if (!ltx_openwin(&spec, &scr, &dri)) return 0;
    if (ttfont[0] && font == GfxBase->DefaultFont) ttfont[0] = 0;
    if (GadToolsBase) {
        gvi = GetVisualInfo(scr, TAG_DONE);
        if (gvi) {
            int mi;
            for (mi = 0; newmenu[mi].nm_Type != NM_END; mi++) {
                const char *lb = (const char *)newmenu[mi].nm_Label;
                int on;
                if (lb == NULL || lb == (const char *)NM_BARLABEL)
                    continue;
                if      (!strcmp(lb, "Line numbers")) on = ttgutter;
                else if (!strcmp(lb, "Status bar"))   on = ttstatus;
                else if (!strcmp(lb, "Fast scroll"))  on = ttfast;
                else continue;
                if (on) newmenu[mi].nm_Flags |= CHECKED;
                else    newmenu[mi].nm_Flags &= ~CHECKED;
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
    if (appport) appwin = AddAppWindowA(0, 0, win, appport, NULL);
    addscrollers(dri, scr);
    ltx_screendone(scr, dri);
    calcgrid();
    return 1;
}

static void closemain(void)
{
    if (appwin) { RemoveAppWindow(appwin); appwin = NULL; }
    if (gmenu) ClearMenuStrip(win);
    if (gadsok) { RemoveGList(win, &vgad, -1); gadsok = 0; }
    ltx_closewindow();
    if (gmenu) { FreeMenus(gmenu); gmenu = NULL; }
    if (gvi) { FreeVisualInfo(gvi); gvi = NULL; }
    freearrows();
    /* the VisualInfo came FROM the screen, so it goes first */
    ltx_closescreen();
}

/* ---- tooltypes --------------------------------------------------- */

static void readtooltypes(struct WBStartup *wbs, char *fpath, int fmax)
{
    struct DiskObject *dob;
    struct WBArg *wa;
    BPTR old;
    char **tt;
    UBYTE *v;

    if (IconBase == NULL || wbs == NULL || wbs->sm_ArgList == NULL) return;
    wa = wbs->sm_ArgList;
    if (wa[0].wa_Lock) ttoollock = DupLock(wa[0].wa_Lock);
    if (wa[0].wa_Name)
        strncpy(ttoolname, (char *)wa[0].wa_Name, sizeof(ttoolname) - 1);

    old = CurrentDir(wa[0].wa_Lock);
    dob = GetDiskObject((STRPTR)wa[0].wa_Name);
    if (dob) {
        tt = (char **)dob->do_ToolTypes;
        ttstr(tt, "OPENSCREEN", ttscrname, sizeof(ttscrname));
        ttstr(tt, "PUBSCREEN", ttpubscr, sizeof(ttpubscr));
        /* floor of 2 planes: cedit draws in pens 0-3 */
        ttdepth = ttnum(tt, "SCREENDEPTH", 2, 8, 0);
        v = FindToolType((CONST_STRPTR *)tt, (STRPTR)"FASTSCROLL");
        if (v) ttfast = !(tteq((char *)v, "NO") ||
                          tteq((char *)v, "OFF") ||
                          tteq((char *)v, "FALSE"));
        v = FindToolType((CONST_STRPTR *)tt, (STRPTR)"STATUSBAR");
        if (v) ttstatus = !(tteq((char *)v, "NO") ||
                            tteq((char *)v, "OFF") ||
                            tteq((char *)v, "FALSE"));
        v = FindToolType((CONST_STRPTR *)tt, (STRPTR)"GUTTER");
        if (v) ttgutter = !(tteq((char *)v, "NO") ||
                            tteq((char *)v, "OFF") ||
                            tteq((char *)v, "FALSE"));
        ttleft   = ttnum(tt, "LEFT",   0, 20000, -1);
        tttop    = ttnum(tt, "TOP",    0, 20000, -1);
        ttwidth  = ttdim(tt, "WIDTH");
        ttheight = ttdim(tt, "HEIGHT");
        tttab    = ttnum(tt, "TABSIZE", 1, 16, 8);
        /* a power of two can use a mask; anything else pays for a
         * modulo per expanded column (a DIVU per cell at 14MHz) */
        ttmask = (tttab & (tttab - 1)) ? 0 : tttab - 1;
        v = FindToolType((CONST_STRPTR *)tt, (STRPTR)"FONT");
        if (v) {
            char *sl;
            int n;
            strncpy(ttfont, (char *)v, sizeof(ttfont) - 6);
            ttfont[sizeof(ttfont) - 6] = 0;
            sl = strchr(ttfont, '/');
            if (sl) { *sl = 0; ttfsize = atoi(sl + 1); }
            if (ttfsize < 5 || ttfsize > 48) ttfsize = 8;
            /* he types the family name, not the file name */
            n = strlen(ttfont);
            if (n == 0)
                ttfont[0] = 0;
            else if (n < 5 || !tteq(ttfont + n - 5, ".font"))
                strcat(ttfont, ".font");
        }
        FreeDiskObject(dob);
    }
    CurrentDir(old);

    /* a project icon dropped on ours, or double-clicked with cedit
     * as its default tool */
    if (wbs->sm_NumArgs >= 2 && wa[1].wa_Name) {
        BPTR o2 = CurrentDir(wa[1].wa_Lock);
        BPTR l = Lock((STRPTR)wa[1].wa_Name, ACCESS_READ);
        if (l) {
            if (NameFromLock(l, (STRPTR)fpath, fmax) == 0) fpath[0] = 0;
            UnLock(l);
        }
        CurrentDir(o2);
    }
}

/* ---- the menu ---------------------------------------------------- */

static int domenu(UWORD code)   /* 1 = quit */
{
    while (code != MENUNULL) {
        struct MenuItem *it = ItemAddress(gmenu, code);
        UWORD m = MENUNUM(code), i = ITEMNUM(code);
        if (it == NULL) break;
        if (m == 0 && i == 0) return 1;                 /* Project/Quit */
        if (m == 1) {
            int on = (it->Flags & CHECKED) ? 1 : 0;
            if (i == 0) {                               /* Line numbers */
                ttgutter = on;
                (void)iconset("GUTTER", on ? "YES" : "NO");
                calcgrid();
                epage();
            } else if (i == 1) {                        /* Status bar */
                ttstatus = on;
                (void)iconset("STATUSBAR", on ? "YES" : "NO");
                calcgrid();
                clamptop();
                epage();
            } else if (i == 2) {                        /* Fast scroll */
                ttfast = on;
                (void)iconset("FASTSCROLL", on ? "YES" : "NO");
            }
        }
        code = it->NextSelect;
    }
    return 0;
}

/* ---- the event loop ---------------------------------------------- */

/* one arrow-gadget step: 1 up, 2 down, 3 left, 4 right */
static void arrowstep(int which)
{
    if (which == 1)      scrollto(cur->top - 1);
    else if (which == 2) scrollto(cur->top + 1);
    else                 sethoff(hoff + (which == 4 ? 8 : -8));
}

static void guimode(void)
{
    struct IntuiMessage *msg;
    int done = 0, burst = 0;

    ltx_setapp(&ceditapp);      /* before anything can paint */

    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
    GadToolsBase = OpenLibrary((STRPTR)"gadtools.library", 37);
    WorkbenchBase = OpenLibrary((STRPTR)"workbench.library", 37);
    if (ttfont[0]) DiskfontBase = OpenLibrary((STRPTR)"diskfont.library", 37);
    if (IntuitionBase == NULL || GfxBase == NULL) goto out;
    if (IconBase == NULL)
        IconBase = OpenLibrary((STRPTR)"icon.library", 37);
    if (WorkbenchBase) appport = CreateMsgPort();

    if (!openmain()) goto out;
    settitle();
    epage();

    while (!done) {
        ULONG wsig, asig, got;

        wsig = 1UL << win->UserPort->mp_SigBit;
        asig = appport ? 1UL << appport->mp_SigBit : 0;
        got = Wait(wsig | asig);

        if (asig && (got & asig)) {
            struct AppMessage *am;
            while ((am = (struct AppMessage *)GetMsg(appport)))
                ReplyMsg((struct Message *)am);
            flushpaint();
        }
        if (!(got & wsig)) continue;
        while ((msg = (struct IntuiMessage *)GetMsg(win->UserPort))) {
            ULONG class = msg->Class;
            UWORD code = msg->Code;
            UWORD qual = msg->Qualifier;
            APTR iaddr = msg->IAddress;
            /* b63's rule, inherited: every message defers its paint
             * and flushpaint below settles it as soon as the port is
             * empty, so a lone message still paints in its own
             * iteration and a burst paints once. */
            defer = 1;
            ReplyMsg((struct Message *)msg);

            if (class == IDCMP_CLOSEWINDOW)
                done = 1;
            if (class == IDCMP_GADGETDOWN ||
                class == IDCMP_GADGETUP ||
                class == IDCMP_MOUSEMOVE) {
                if (class == IDCMP_GADGETDOWN)
                    propheld = iaddr == (APTR)&vgad ? 1 :
                               iaddr == (APTR)&hgad ? 2 : 0;
                else if (class == IDCMP_GADGETUP)
                    propheld = 0;
                if (iaddr == (APTR)&vgad) {
                    ltx_trackvert();
                } else if (iaddr == (APTR)&hgad) {
                    ltx_trackhoriz();
                } else if (class == IDCMP_GADGETDOWN) {
                    arrheld = iaddr == (APTR)&agup ? 1 :
                              iaddr == (APTR)&agdn ? 2 :
                              iaddr == (APTR)&aglt ? 3 :
                              iaddr == (APTR)&agrt ? 4 : 0;
                    if (arrheld) arrowstep(arrheld);
                } else if (class == IDCMP_GADGETUP)
                    arrheld = 0;
            }
            if (class == IDCMP_INTUITICKS && arrheld) arrowstep(arrheld);
            if (class == IDCMP_INTUITICKS && propheld) proptrack();
            if (class == IDCMP_MENUPICK) {
                if (gmenu && domenu(code)) done = 1;
            }
            if (class == IDCMP_REFRESHWINDOW) {
                /* b64: a refresh is not a repeat stream - it must
                 * paint inside Begin/EndRefresh, now, or the damage
                 * is cleared with nothing drawn into it. */
                int od = defer;
                defer = 0;
                BeginRefresh(win);
                epage();
                EndRefresh(win, TRUE);
                defer = od;
                dirtyall = dirtyrows = 0;
                scrollfromset = ltx_appowed = 0;
            }
            if (class == IDCMP_NEWSIZE) {
                /* b50: the frame refresh, not RefreshGList - the
                 * latter skips the border background and leaves the
                 * arrows on stale pixels after every resize */
                if (gadsok) RefreshWindowFrame(win);
                calcgrid();
                clamptop();
                /* b83: a shrink produces no REFRESHWINDOW, so
                 * painting cannot wait for one - and rendering into
                 * a damaged region is suppressed until
                 * Begin/EndRefresh, so go through it when one is
                 * pending. */
                {
                    int od = defer;
                    defer = 0;
                    if (win->Flags & WFLG_WINDOWREFRESH) {
                        BeginRefresh(win);
                        epage();
                        EndRefresh(win, TRUE);
                    } else
                        epage();
                    defer = od;
                    dirtyall = dirtyrows = 0;
                    scrollfromset = ltx_appowed = 0;
                }
            }
            if (class == IDCMP_VANILLAKEY) {
                switch (code) {
                case ' ': scrollto(cur->top + crows); break;
                case 'b': case 'B': scrollto(cur->top - crows); break;
                case 't': case 'T': scrollto(0); break;
                case 'e': case 'E': scrollto(cur->n); break;
                }
            }
            if (class == IDCMP_RAWKEY) {
                int page = (qual & (IEQUALIFIER_LSHIFT |
                                    IEQUALIFIER_RSHIFT)) != 0;
                if (code == 0x4C)                       /* cursor up */
                    scrollto(cur->top - (page ? crows : 1));
                else if (code == 0x4D)                  /* cursor down */
                    scrollto(cur->top + (page ? crows : 1));
                else if (code == 0x7A)                  /* wheel up */
                    scrollto(cur->top - (page ? crows : 3));
                else if (code == 0x7B)                  /* wheel down */
                    scrollto(cur->top + (page ? crows : 3));
                else if (code == 0x4F || code == 0x4E) {
                    /* horizontal: every row's text moves, so this is
                     * a content repaint - the gutter stays pinned */
                    int step = page ? 40 : 8;
                    sethoff(hoff + (code == 0x4E ? step : -step));
                }
            }
            /* b63/b64: pay the debt as soon as nothing else is
             * queued, and at least every 4 messages regardless, so a
             * stream that never leaves a gap still animates. */
            if (!inputwaiting() || ++burst >= 4) {
                flushpaint();
                burst = 0;
            }
        }
        flushpaint();
    }

    closemain();
out:
    if (appport) {
        struct Message *m;
        while ((m = GetMsg(appport))) ReplyMsg(m);
        DeleteMsgPort(appport);
        appport = NULL;
    }
    ltx_closefont();
    if (ttoollock) { UnLock(ttoollock); ttoollock = 0; }
    if (DiskfontBase) CloseLibrary(DiskfontBase);
    if (IconBase) CloseLibrary(IconBase);
    if (WorkbenchBase) CloseLibrary(WorkbenchBase);
    if (GadToolsBase) CloseLibrary(GadToolsBase);
    if (GfxBase) CloseLibrary((struct Library *)GfxBase);
    if (IntuitionBase) CloseLibrary((struct Library *)IntuitionBase);
}

/* ---- main -------------------------------------------------------- */

static int smain(int argc, char **argv)
{
    static char fpath[310];
    struct RDArgs *rda;
    LONG args[1] = { 0 };

    if (argc == 0) {                    /* Workbench */
        IconBase = OpenLibrary((STRPTR)"icon.library", 37);
        readtooltypes((struct WBStartup *)argv, fpath, sizeof(fpath));
    } else {
        rda = ReadArgs((STRPTR)"FILE", args, NULL);
        if (rda) {
            if (args[0])
                strncpy(fpath, (char *)args[0], sizeof(fpath) - 1);
            FreeArgs(rda);
        }
    }
    bufinit(&buf);
    if (fpath[0] && !loadbuf(&buf, fpath)) {
        if (argc) PutStr((STRPTR)"cedit: cannot read that file\n");
        fpath[0] = 0;
    }
    guimode();
    buffree(&buf);
    return 0;
}

#define STACKSZ 65536
static struct StackSwapStruct sss;
static char *bigstk;
static int sargc, sret;
static char **sargv;

static void __attribute__((noinline)) runswapped(void)
{
    sret = smain(sargc, sargv);
}

int main(int argc, char **argv)
{
    struct Task *me = FindTask(NULL);
    long have = (char *)me->tc_SPUpper - (char *)me->tc_SPLower;
    /* swap only when the stack is measurably small. Zero bounds = an
     * environment that does not fill them in (vamos leaves both NULL,
     * and its StackSwap wrecks the exit path) - there, run as given. */
    if (me->tc_SPLower == NULL || me->tc_SPUpper == NULL ||
        have >= 32768)
        return smain(argc, argv);
    sargc = argc;
    sargv = argv;
    bigstk = malloc(STACKSZ);
    if (bigstk == NULL)
        return smain(argc, argv);
    sss.stk_Lower = bigstk;
    sss.stk_Upper = (ULONG)(bigstk + STACKSZ);
    sss.stk_Pointer = (APTR)(bigstk + STACKSZ);
    StackSwap(&sss);
    runswapped();
    StackSwap(&sss);
    free(bigstk);
    return sret;
}
