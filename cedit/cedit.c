/* cedit - a GUI text editor for AmigaOS, on the LTX chassis.
 *
 * b1 was read-only and proved the lifted chassis; b2 makes it an
 * editor - a caret, the edits, and save. The GUI is still almost
 * entirely ltxgui/ltxwin.c (window, screen, font, border scrollbars,
 * tab bar, status row, row painter, scroll engine); cedit's own GUI
 * code is the LtxApp adapters, a page composer and this event loop.
 *
 * The editing PRIMITIVES are not here either - they are edbuf.c,
 * pure logic, harness-proven on the host and under vamos before any
 * of this boots. What lives in this file is the cursor: where it is
 * allowed to be, what follows it, and which rows that dirties.
 *
 * The Buffer struct still carries what b3-b5 need (per-line lexer
 * state, per-buffer top/hoff) with exactly one buffer in it, so
 * multi-file tabs at b4 are a data change and not a rewrite.
 *
 * Usage: cedit [FILE]
 */
#include <exec/types.h>
#include <exec/tasks.h>
#include <intuition/intuition.h>
#include <libraries/gadtools.h>
#include <devices/clipboard.h>
#include <workbench/startup.h>
#include <workbench/workbench.h>
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
#include "ltxwin.h"
#include "edbuf.h"

/* 'used' or -O2 strips it - and c:Version must find it */
static const char verstag[] __attribute__((used)) =
    "$VER: cedit 0.1b5 (2.8.26)";

/* ---- the buffer -------------------------------------------------
 * The line table, the splitter and the width arithmetic live in
 * edbuf.c: pure logic, harness-proven on the host AND under vamos
 * before this ever boots. What stays here is the file I/O, which
 * needs dos.library and so cannot be tested that way. */

/* b2/b4: the open documents. The Buffer struct was built at b1 to
 * carry its own top, hoff, cursor and dirty flag precisely so that
 * this could become an array without touching anything else - and it
 * did: switching tabs is `cur = &docs[i]` plus one save/restore of
 * the chassis's single hoff.
 *
 * There is ALWAYS at least one document. Closing the last tab leaves
 * a blank untitled page rather than an empty window, which is also
 * exactly what Close All does - one end state, not two. */
#define MAXDOCS 16
static Buffer docs[MAXDOCS];
static int ndocs = 1;
static int curdoc;
static Buffer *cur = &docs[0];

/* the column an up/down move TRIES to reach. Without it, walking
 * down past a short line drags the cursor to its end and leaves it
 * there - the single most-noticed absence in a young editor. Held in
 * characters, clamped per line, and reset by every horizontal move
 * or edit, which is exactly when the user has chosen a new column. */
static int goalx;

/* SetWindowTitles repaints the whole title bar, so calling it per
 * keystroke would undo the point of repainting one row. The marker
 * only ever changes when `dirty` does. */
static int shown_dirty;

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

#define msg(t) ltx_msg(t)

/* ---- the clipboard ----------------------------------------------
 * clipboard.device unit 0, IFF FORM FTXT with a CHRS chunk - the
 * format the whole console family shares, so a cedit copy pastes
 * into a stock CON:, into Ed, into MultiView, and back again. The
 * shape is CCON's (ccon-handler.e, M7), which is boot-proven on this
 * hardware; what is written here is that design in C.
 *
 * It is IO-request only - no DOS packets anywhere - and opened
 * lazily on the first copy or paste, then kept. */
#define CLIPMAX 65536L

static struct MsgPort *clipport;
static struct IOClipReq *clipreq;

static int clipopen(void)
{
    if (clipreq) return 1;
    if (clipport == NULL) clipport = CreateMsgPort();
    if (clipport == NULL) return 0;
    clipreq = (struct IOClipReq *)
        CreateIORequest(clipport, sizeof(struct IOClipReq));
    if (clipreq == NULL) return 0;
    if (OpenDevice((STRPTR)"clipboard.device", PRIMARY_CLIP,
                   (struct IORequest *)clipreq, 0) != 0) {
        DeleteIORequest((struct IORequest *)clipreq);
        clipreq = NULL;
        return 0;
    }
    return 1;
}

static void clipclose(void)
{
    if (clipreq) {
        CloseDevice((struct IORequest *)clipreq);
        DeleteIORequest((struct IORequest *)clipreq);
        clipreq = NULL;
    }
    if (clipport) { DeleteMsgPort(clipport); clipport = NULL; }
}

static void wrbe(UBYTE *p, ULONG v)
{
    p[0] = (UBYTE)(v >> 24); p[1] = (UBYTE)(v >> 16);
    p[2] = (UBYTE)(v >> 8);  p[3] = (UBYTE)v;
}

static ULONG rdbe(const UBYTE *p)
{
    return ((ULONG)p[0] << 24) | ((ULONG)p[1] << 16) |
           ((ULONG)p[2] << 8) | (ULONG)p[3];
}

/* the whole form in one write, then CMD_UPDATE to commit it - a
 * write without the update leaves the clip unpublished */
static int clipput(const char *text, long n)
{
    UBYTE *buf;
    long pad, total;
    int ok;
    if (n <= 0 || !clipopen()) return 0;
    pad = n & 1;                        /* IFF chunks are even */
    total = 20 + n + pad;
    buf = malloc(total);
    if (buf == NULL) return 0;
    wrbe(buf,      0x464F524DUL);       /* 'FORM' */
    wrbe(buf + 4,  (ULONG)(12 + n + pad));
    wrbe(buf + 8,  0x46545854UL);       /* 'FTXT' */
    wrbe(buf + 12, 0x43485253UL);       /* 'CHRS' */
    wrbe(buf + 16, (ULONG)n);
    memcpy(buf + 20, text, n);
    if (pad) buf[20 + n] = 0;
    clipreq->io_Command = CMD_WRITE;
    clipreq->io_Data = (STRPTR)buf;
    clipreq->io_Length = total;
    clipreq->io_Offset = 0;
    clipreq->io_ClipID = 0;
    DoIO((struct IORequest *)clipreq);
    ok = (clipreq->io_Error == 0);
    if (ok) {
        clipreq->io_Command = CMD_UPDATE;
        DoIO((struct IORequest *)clipreq);
    }
    free(buf);
    return ok;
}

/* read unit 0 and dig the CHRS text out of the form. The read cycle
 * MUST be run dry afterwards or the clip is never released - the
 * clipboard.device rule CCON learned the same way. */
static long clipget(char **out)
{
    UBYTE *buf, scr[64];
    long got, o, n = 0;
    *out = NULL;
    if (!clipopen()) return 0;
    buf = malloc(CLIPMAX);
    if (buf == NULL) return 0;
    clipreq->io_Command = CMD_READ;
    clipreq->io_Data = (STRPTR)buf;
    clipreq->io_Length = CLIPMAX;
    clipreq->io_Offset = 0;
    clipreq->io_ClipID = 0;
    DoIO((struct IORequest *)clipreq);
    got = (clipreq->io_Error == 0) ? clipreq->io_Actual : 0;
    do {                                /* run it dry */
        clipreq->io_Command = CMD_READ;
        clipreq->io_Data = (STRPTR)scr;
        clipreq->io_Length = sizeof(scr);
        DoIO((struct IORequest *)clipreq);
    } while (clipreq->io_Error == 0 && clipreq->io_Actual > 0);

    if (got >= 20 && rdbe(buf) == 0x464F524DUL &&
        rdbe(buf + 8) == 0x46545854UL) {
        o = 12;                         /* first chunk inside FTXT */
        while (o + 8 <= got) {
            ULONG id = rdbe(buf + o), sz = rdbe(buf + o + 4);
            if (id == 0x43485253UL) {   /* 'CHRS' */
                if ((long)sz > got - (o + 8)) sz = got - (o + 8);
                *out = malloc(sz + 1);
                if (*out) {
                    memcpy(*out, buf + o + 8, sz);
                    (*out)[sz] = 0;
                    n = sz;
                }
                break;
            }
            o += 8 + sz + (sz & 1);
        }
    }
    free(buf);
    return n;
}

/* write the buffer back, in the line endings the file arrived with.
 *
 * Never straight over the original: the new text goes to a sibling
 * file first and only replaces the old one once it is completely
 * written. A save that fails halfway then costs nothing but a stray
 * .new file, where a direct write would have left a truncated
 * source. CFile's charter is non-destructive by default and this is
 * the same rule with the same reason. */
static int savebuf(Buffer *b, const char *path)
{
    char tmp[320];
    char *out;
    long n;
    BPTR fh;
    int ok;

    if (b->path[0] == 0) return 0;
    /* built by edbuf, where the harness checks the exact bytes, then
     * written in ONE call - fewer packets to the filesystem than a
     * line at a time, and nothing to get wrong here. */
    n = bufbytes(b);
    out = malloc(n ? n : 1);
    if (out == NULL) return 0;
    n = bufserialize(b, out);

    sprintf(tmp, "%.310s.new", path);
    fh = Open((STRPTR)tmp, MODE_NEWFILE);
    if (fh == 0) { free(out); return 0; }
    ok = (n == 0) || (Write(fh, out, n) == n);
    if (Close(fh) == 0) ok = 0;         /* the buffered tail matters */
    free(out);
    if (!ok) { DeleteFile((STRPTR)tmp); return 0; }

    DeleteFile((STRPTR)path);           /* may not exist yet */
    if (!Rename((STRPTR)tmp, (STRPTR)path)) {
        msg("Saved, but could not replace the original.\n"
            "Your text is in the .new file beside it.");
        return 0;
    }
    b->dirty = 0;
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
static char ttdrawer[310];      /* DRAWER= - where the requester starts */

static struct MsgPort *appport;
static APTR   appwin;
static APTR   gvi;
static struct Menu *gmenu;

static struct NewMenu newmenu[] = {
    { NM_TITLE, (STRPTR)"Project",      NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"New",          (STRPTR)"N", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open...",      (STRPTR)"O", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Open New...",  (STRPTR)"D", 0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,            NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Close",        (STRPTR)"K", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Close All",    NULL,        0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,            NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Save",         (STRPTR)"S", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Save As...",   (STRPTR)"A", 0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,            NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Quit",         (STRPTR)"Q", 0, 0, NULL },
    { NM_TITLE, (STRPTR)"Edit",         NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Undo",         (STRPTR)"Z", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Redo",         (STRPTR)"Y", 0, 0, NULL },
    { NM_ITEM,  NM_BARLABEL,            NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Mark",         (STRPTR)"B", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Cut",          (STRPTR)"X", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Copy",         (STRPTR)"C", 0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Paste",        (STRPTR)"V", 0, 0, NULL },
    { NM_TITLE, (STRPTR)"Settings",   NULL,        0, 0, NULL },
    { NM_ITEM,  (STRPTR)"Line numbers", NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    { NM_ITEM,  (STRPTR)"Status bar", NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    { NM_ITEM,  (STRPTR)"Fast scroll", NULL,
      CHECKIT | MENUTOGGLE, 0, NULL },
    /* his ask: tab size from the menu, 1-10. Radio rather than
     * toggle - exactly one is true - which in GadTools means CHECKIT
     * plus a mutual-exclude mask naming every OTHER item at this
     * level. TABSIZE= reads the same range, so menu and tooltype can
     * always express the same thing. */
    { NM_ITEM,  (STRPTR)"Tab size",   NULL,        0, 0, NULL },
    { NM_SUB,   (STRPTR)"1",  NULL, CHECKIT, ~0x001 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"2",  NULL, CHECKIT, ~0x002 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"3",  NULL, CHECKIT, ~0x004 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"4",  NULL, CHECKIT, ~0x008 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"5",  NULL, CHECKIT, ~0x010 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"6",  NULL, CHECKIT, ~0x020 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"7",  NULL, CHECKIT, ~0x040 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"8",  NULL, CHECKIT, ~0x080 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"9",  NULL, CHECKIT, ~0x100 & 0x3FF, NULL },
    { NM_SUB,   (STRPTR)"10", NULL, CHECKIT, ~0x200 & 0x3FF, NULL },
    { NM_END,   NULL,                 NULL,        0, 0, NULL },
};

/* the tab stop, and its mask when the stop is a power of two - the
 * mask road costs an AND per expanded column, the other a DIVU at
 * 14MHz. Both are correct; only one is cheap. */
static void settabsize(int n)
{
    tttab = n;
    ttmask = (n & (n - 1)) ? 0 : n - 1;
}

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

/* the cursor's DISPLAY column - cx counts characters, and a tab is
 * one character but several columns. Everything on screen is
 * measured in the second kind, so the two must never be confused. */
static int curcol(void)
{
    return explen(cur->ln[cur->cy], cur->cx, tttab, ttmask);
}

/* b2: the caret, complemented over the cell rather than drawn into
 * it - the ROM's own way, and what CCON does. It inverts whatever
 * glyph is underneath, so it reads on any pen pair without the row
 * painter knowing it exists, and erasing it is the same operation
 * again. This is the ONE place a pixel is written twice; the b66
 * rule holds for the row itself. */
static void drawcaret(int y)
{
    int col = curcol() - hoff;
    int tw = textw();
    if (col < 0 || col >= tw) return;   /* panned out of sight */
    SetDrMd(rp, COMPLEMENT);
    RectFill(rp, textx() + col * fw, y,
                 textx() + col * fw + fw - 1, y + fh - 1);
    SetDrMd(rp, JAM2);
}

/* one visible row. b1 painted a single run; b5 hands ltx_drawruns()
 * the lexer's list instead, and nothing else on this path changes -
 * which is the whole reason the painter was widened at b0b.
 *
 * The caret is painted here rather than by its own code path, so
 * that EVERY repaint of this row - a scroll's entering row, a
 * refresh, a resize - carries it automatically. */
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
    /* b5: the selection, and the first real use of the N-run painter
     * that b0b widened for the lexer. Up to three runs - before the
     * selection, the selection itself in the CFile bar colours, and
     * after it - each written exactly once, so a selected row is
     * still one pass of Text() calls and never half-painted. */
    {
        int y0, x0, y1, x1, nr = 0;
        int s0 = -1, s1 = -1;
        LtxRun runs[3];
        if (ed_selrange(cur, &y0, &x0, &y1, &x1) &&
            i >= y0 && i <= y1) {
            /* the selected span of THIS row, in display columns */
            int cs = (i == y0) ? explen(cur->ln[i], x0, tttab, ttmask) : 0;
            int ce = (i == y1) ? explen(cur->ln[i], x1, tttab, ttmask)
                               : explen(cur->ln[i], cur->len[i],
                                        tttab, ttmask) + 1;
            s0 = cs - hoff;
            s1 = ce - hoff;
            if (s0 < 0) s0 = 0;
            if (s1 > w) s1 = w;
        }
        runs[nr].start = 0; runs[nr].pen = 1; runs[nr].bg = 0; nr++;
        if (s0 >= 0 && s1 > s0) {
            if (s0 > 0) {
                runs[nr].start = s0; runs[nr].pen = 2; runs[nr].bg = 3;
                nr++;
            } else {
                runs[0].pen = 2; runs[0].bg = 3;
            }
            if (s1 < w) {
                runs[nr].start = s1; runs[nr].pen = 1; runs[nr].bg = 0;
                nr++;
            }
        }
        ltx_drawruns(textx(), y, ltx_vis, w, runs, nr);
    }
    (void)run;
    /* no caret inside a live selection - the range is the statement,
     * and a caret in the middle of it says something else */
    if (i == cur->cy && !cur->selon) drawcaret(y);
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

/* With one document ltx_tabbar is 0 and this draws nothing - the name
 * is in the title bar and the status row already, so a one-tab bar
 * would spend a whole row of text saying what is said twice over
 * (his call). With two or more the bar appears and the grid shrinks
 * by exactly that row. */
static void drawtabbar(void)
{
    const char *labs[MAXDOCS];
    int i;
    if (!ltx_tabbar) return;
    for (i = 0; i < ndocs; i++)
        labs[i] = docs[i].name[0] ? docs[i].name : "untitled";
    /* closable: a document tab carries its own close box */
    ltx_drawtabs(labs, ndocs, curdoc, 1);
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
     * right of the last column keep STALE pixels across a resize.
     *
     * From CONTY, not gy0 - his find, and the answer to why every
     * attempt to move the tab divider's right end changed nothing at
     * all. This strip is the sub-cell remainder, 0 to fw-1 pixels
     * wide, and starting it at the top of the window painted it
     * straight over the right end of the tab bar - drawn moments
     * earlier - in background grey. The bar paints its own full
     * width; this only ever needed to cover the content. */
    SetAPen(rp, 0);
    s = gx0 + viscols * fw;
    e = win->Width - win->BorderRight - 1;
    if (s <= e)
        RectFill(rp, s, conty, e, win->Height - win->BorderBottom - 1);
    s = conty + crows * fh;
    e = win->Height - win->BorderBottom - 1;
    if (s <= e)
        RectFill(rp, gx0, s, xend, e);
    if (slx <= xend)
        RectFill(rp, slx, conty, xend, e);
    drawstatus();
    updscrollers();
    /* no hint here, and deliberately none: cdiff needs two files
     * before it can do anything, so an empty cdiff window has to say
     * so. An empty EDITOR window is not waiting for anything - it is
     * a new document with the caret already in it. */
}

/* b82's rule: whatever fills this has to be cheap, because it runs
 * on every position change. Both numbers here are O(1). */
static void estatus(char *dst, int max)
{
    sprintf(dst, " %.40s%s  line %d/%d  col %d%s",
            cur->name[0] ? cur->name : "untitled",
            cur->dirty ? " *" : "",
            cur->cy + 1, cur->n, curcol() + 1,
            ed_canundo(cur) ? "" : "  [no undo]");
    (void)max;
}

/* b2, and the standing rule: only redraw what actually changed.
 * Typing repaints ONE row. Moving the cursor repaints two - the row
 * it left, to erase the caret, and the row it reached. Only a
 * structural change (a split or a join, which shifts every row
 * below) escalates to dirtyrows. dmgold is a BUFFER index, not a
 * screen row, so it survives a scroll happening in the same burst. */
static int dmgold = -1;

static void damage(int oldcy)
{
    if (dmgold < 0) dmgold = oldcy;
    ltx_appowed = 1;
}

static void eflush(void)
{
    int vr;
    if (dmgold >= 0 && dmgold != cur->cy) {
        vr = dmgold - cur->top;
        if (vr >= 0 && vr < crows) erow(vr);
    }
    dmgold = -1;
    vr = cur->cy - cur->top;
    if (vr >= 0 && vr < crows) erow(vr);
}

static const LtxApp ceditapp = {
    ecount, etop, ecols, erowone, erows, epage, estatus, eflush
};

/* ---- window ------------------------------------------------------ */

static void settitle(void);
static void clamptop(void);
static void epage(void);

static void calcgrid(void)
{
    /* decided before the grid is measured, because it is what the
     * grid measures around */
    ltx_tabbar = (ndocs > 1);
    ltx_calcgrid();
    calcgut();
}

/* make document `i` the current one. The chassis has ONE hoff, so
 * the outgoing document's pan is stashed in its own Buffer and the
 * incoming one's restored - the single reason Buffer carries an hoff
 * field of its own. */
static void setdoc(int i)
{
    if (i < 0 || i >= ndocs) return;
    cur->hoff = hoff;
    curdoc = i;
    cur = &docs[i];
    hoff = cur->hoff;
    goalx = cur->cx;
    calcgrid();                 /* the gutter follows THIS line count */
    clamptop();
    settitle();
    shown_dirty = cur->dirty;
    epage();
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
            /* b87's rule, carried over: the checkmarks start
             * wherever the tooltypes left them, so menu and icon
             * never disagree on entry. */
            int mi;
            for (mi = 0; newmenu[mi].nm_Type != NM_END; mi++) {
                const char *lb = (const char *)newmenu[mi].nm_Label;
                int on;
                if (lb == NULL || lb == (const char *)NM_BARLABEL)
                    continue;
                if (newmenu[mi].nm_Type == NM_SUB)
                    on = (atoi(lb) == tttab);
                else if (!strcmp(lb, "Line numbers")) on = ttgutter;
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

/* returns how many file names it collected into fpaths */
static int readtooltypes(struct WBStartup *wbs, char fpaths[][310])
{
    struct DiskObject *dob;
    struct WBArg *wa;
    BPTR old;
    char **tt;
    UBYTE *v;

    if (IconBase == NULL || wbs == NULL || wbs->sm_ArgList == NULL)
        return 0;
    wa = wbs->sm_ArgList;
    if (wa[0].wa_Lock) ttoollock = DupLock(wa[0].wa_Lock);
    if (wa[0].wa_Name)
        strncpy(ttoolname, (char *)wa[0].wa_Name, sizeof(ttoolname) - 1);

    old = CurrentDir(wa[0].wa_Lock);
    dob = GetDiskObject((STRPTR)wa[0].wa_Name);
    if (dob) {
        tt = (char **)dob->do_ToolTypes;
        ttstr(tt, "DRAWER", ttdrawer, sizeof(ttdrawer));
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
        /* 1-10, the same range the Tab size menu offers, so the two
         * can always express the same thing. Anything else falls
         * back to 8 rather than to a size the menu cannot show. */
        settabsize(ttnum(tt, "TABSIZE", 1, 10, 8));
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

    /* project icons dropped on ours, or one double-clicked with
     * cedit as its default tool. Each gets its own tab. */
    {
        int k, n = 0;
        for (k = 1; k < wbs->sm_NumArgs && n < MAXDOCS; k++) {
            BPTR o2, l;
            if (wa[k].wa_Name == NULL) continue;
            o2 = CurrentDir(wa[k].wa_Lock);
            l = Lock((STRPTR)wa[k].wa_Name, ACCESS_READ);
            if (l) {
                if (NameFromLock(l, (STRPTR)fpaths[n], 310)) n++;
                UnLock(l);
            }
            CurrentDir(o2);
        }
        return n;
    }
}

/* ---- the menu ---------------------------------------------------- */

/* the Project menu's actions, defined below with the edits */
static int  askdiscardall(const char *gadgets);
static void donew(void);
static void doopen(int newtab);
static void doclose(void);
static void docloseall(void);
static void dosave(void);
static void dosaveas(void);
static void doundo(int redo);
static void selpaint(void);
static void domark(void);
static void docopy(int cut);
static void dopaste(void);
static int  askquit(void);      /* and the unsaved-changes prompt */
static void follow(void);       /* keep the caret on screen */

static int domenu(UWORD code)   /* 1 = quit */
{
    while (code != MENUNULL) {
        struct MenuItem *it = ItemAddress(gmenu, code);
        UWORD m = MENUNUM(code), i = ITEMNUM(code);
        if (it == NULL) break;
        /* New(0) Open(1) OpenNew(2) -(3) Close(4) CloseAll(5) -(6)
         * Save(7) SaveAs(8) -(9) Quit(10). The separator bars ARE
         * items and do take an index - cdiff's menu code says so in
         * a comment, and this is why. */
        if (m == 0) {
            if (i == 0)  { donew();      return 0; }
            if (i == 1)  { doopen(0);    return 0; }
            if (i == 2)  { doopen(1);    return 0; }
            if (i == 4)  { doclose();    return 0; }
            if (i == 5)  { docloseall(); return 0; }
            if (i == 7)  { dosave();     return 0; }
            if (i == 8)  { dosaveas();   return 0; }
            if (i == 10) return askquit();
        }
        if (m == 1) {                                   /* Edit */
            if (i == 0) { doundo(0); return 0; }
            if (i == 1) { doundo(1); return 0; }
            if (i == 3) { domark();  return 0; }
            if (i == 4) { docopy(1); return 0; }
            if (i == 5) { docopy(0); return 0; }
            if (i == 6) { dopaste(); return 0; }
        }
        if (m == 2) {                                   /* Settings */
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
            } else if (i == 3) {                        /* Tab size */
                UWORD sub = SUBNUM(code);
                if (sub != NOSUB) {
                    char v[8];
                    settabsize(sub + 1);
                    sprintf(v, "%d", tttab);
                    (void)iconset("TABSIZE", v);
                    /* every line's expanded width just changed, and
                     * so did the caret's column - so this is the one
                     * settings change that repaints the page */
                    cur->maxwdirty = 1;
                    calcgrid();
                    follow();
                    epage();
                }
            }
        }
        code = it->NextSelect;
    }
    return 0;
}

/* ---- the cursor -------------------------------------------------- */

/* keep the cursor on screen. Vertical goes through the chassis's
 * scrollto so a one-line step is still one blit plus one entering
 * row; horizontal through sethoff for the same reason. */
static void follow(void)
{
    int col, tw;
    if (cur->cy < cur->top) scrollto(cur->cy);
    else if (cur->cy >= cur->top + crows) scrollto(cur->cy - crows + 1);
    col = curcol();
    tw = textw();
    if (tw < 1) return;
    if (col < hoff) sethoff(col);
    else if (col >= hoff + tw) sethoff(col - tw + 1);
}

/* the one road to the cursor: clamp, follow, and mark the two rows
 * that changed. Everything below calls this rather than assigning
 * cy/cx itself, so no path can move the cursor off screen or forget
 * to erase the caret it left behind. */
static void gotoyx(int ny, int nx)
{
    int oldcy = cur->cy;
    if (ny < 0) ny = 0;
    if (ny >= cur->n) ny = cur->n - 1;
    if (nx < 0) nx = 0;
    if (nx > cur->len[ny]) nx = cur->len[ny];
    if (ny == cur->cy && nx == cur->cx) return;
    cur->cy = ny;
    cur->cx = nx;
    ed_break(cur);              /* b3: a move ends the typing run, so
                                 * one undo takes back one word and
                                 * not everything since the file
                                 * opened */
    follow();
    /* with a mark down, moving the caret EXTENDS the selection - that
     * is what the anchor is for - so the rows between both ends have
     * changed, not just two */
    if (cur->selon) selpaint();
    else            damage(oldcy);
}

static void moveh(int nx)       /* a horizontal move chooses a goal */
{
    gotoyx(cur->cy, nx);
    goalx = cur->cx;
}

static void movev(int ny)       /* a vertical move keeps it */
{
    if (ny < 0) ny = 0;
    if (ny >= cur->n) ny = cur->n - 1;
    gotoyx(ny, goalx);
}

static int wordch(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

/* Ctrl+left/right, the CCON line editor's jumps: over the run of
 * separators, then over the word itself */
static void wordjump(int dir)
{
    const char *l = cur->ln[cur->cy];
    int n = cur->len[cur->cy], x = cur->cx;
    if (dir > 0) {
        while (x < n && wordch(l[x])) x++;
        while (x < n && !wordch(l[x])) x++;
    } else {
        while (x > 0 && !wordch(l[x - 1])) x--;
        while (x > 0 && wordch(l[x - 1])) x--;
    }
    moveh(x);
}

/* ---- editing ----------------------------------------------------- */

static void oom(void)
{
    msg("Out of memory - that edit did not happen.");
}

static void marktitle(void)
{
    if (cur->dirty == shown_dirty) return;
    shown_dirty = cur->dirty;
    settitle();
}

/* a live selection is what the next edit replaces - the standard
 * everywhere, and the reason Cut is rarely needed twice */
static int eatsel(void)
{
    if (!cur->selon) return 0;
    {
        int y0, x0, y1, x1;
        if (!ed_selrange(cur, &y0, &x0, &y1, &x1)) {
            ed_selclear(cur);   /* an empty range is not a selection */
            return 0;
        }
    }
    ed_seldelete(cur);
    goalx = cur->cx;
    calcgut();
    follow();
    selpaint();
    return 1;
}

static void typech(char c)
{
    int oldcy;
    int had = eatsel();
    oldcy = cur->cy;
    if (had) ed_group(cur);
    if (!edinsch(cur, cur->cy, cur->cx, c)) { oom(); return; }
    cur->cx++;
    if (had) ed_ungroup(cur);
    goalx = cur->cx;
    follow();
    damage(oldcy);              /* one row - the b2 minimal-redraw case */
    marktitle();
}

/* Return, Backspace over a line start and Delete at a line end all
 * shift every row below, so these are the cases that escalate to a
 * full content repaint. Nothing cheaper is correct: the rows below
 * really did all move. */
static void structural(void)
{
    dirtyrows = 1;
    dmgold = -1;                /* the whole page covers both rows */
    cur->maxwdirty = 1;
    calcgut();                  /* the line count changed */
    marktitle();
}

static void donewline(void)
{
    int had = eatsel();
    if (had) ed_group(cur);
    if (!edsplitline(cur, cur->cy, cur->cx)) { oom(); return; }
    if (had) ed_ungroup(cur);
    cur->cy++;
    cur->cx = 0;
    goalx = 0;
    follow();
    structural();
}

static void dobackspace(void)
{
    if (eatsel()) { marktitle(); return; }  /* the selection WAS the
                                             * thing being removed */
    if (cur->cx > 0) {
        int oldcy = cur->cy;
        eddelch(cur, cur->cy, cur->cx - 1);
        cur->cx--;
        goalx = cur->cx;
        follow();
        damage(oldcy);
        marktitle();
        return;
    }
    if (cur->cy == 0) return;           /* start of the file */
    {
        int prev = cur->cy - 1, at = cur->len[prev];
        if (!edjoinline(cur, prev)) { oom(); return; }
        cur->cy = prev;
        cur->cx = at;
        goalx = at;
        follow();
        structural();
    }
}

static void dodelete(void)
{
    if (eatsel()) { marktitle(); return; }
    if (cur->cx < cur->len[cur->cy]) {
        int oldcy = cur->cy;
        eddelch(cur, cur->cy, cur->cx);
        follow();
        damage(oldcy);
        marktitle();
        return;
    }
    if (cur->cy + 1 >= cur->n) return;  /* end of the file */
    if (!edjoinline(cur, cur->cy)) { oom(); return; }
    structural();
}

/* b2: losing unsaved work to a stray close gadget is not something
 * to leave until b4's multi-buffer prompt. Two gadgets, and the
 * SAFE one is the default (gadget 0 = the rightmost = Cancel). */
/* quitting asks about EVERY open document, not just the visible one
 * - the unsaved work in tab three is the work you forget about */
static int askquit(void)
{
    return askdiscardall("Quit anyway|Cancel");
}

/* the one question, asked wherever a document is about to be thrown
 * away: Close, Close All, Open (which replaces) and Quit. The SAFE
 * gadget is the default - EasyRequest's rightmost is 0. */
static int askdiscard(Buffer *b, const char *gadgets)
{
    struct EasyStruct es;
    ULONG arg;
    if (!b->dirty) return 1;
    es.es_StructSize = sizeof(es);
    es.es_Flags = 0;
    es.es_Title = (STRPTR)"cedit";
    es.es_TextFormat = (STRPTR)"%s has unsaved changes.";
    es.es_GadgetFormat = (STRPTR)gadgets;
    arg = (ULONG)(b->name[0] ? b->name : "This document");
    return EasyRequestArgs(win, &es, NULL, &arg) != 0;
}

static int anydirty(void)
{
    int i;
    for (i = 0; i < ndocs; i++) if (docs[i].dirty) return 1;
    return 0;
}

/* ONE question for the whole set rather than one per document -
 * being asked eight times in a row is how a user learns to click
 * through prompts without reading them */
static int askdiscardall(const char *gadgets)
{
    struct EasyStruct es;
    if (!anydirty()) return 1;
    es.es_StructSize = sizeof(es);
    es.es_Flags = 0;
    es.es_Title = (STRPTR)"cedit";
    es.es_TextFormat = (STRPTR)"Some documents have unsaved changes.";
    es.es_GadgetFormat = (STRPTR)gadgets;
    return EasyRequestArgs(win, &es, NULL, NULL) != 0;
}

/* a fresh empty document in slot i */
static int blankdoc(int i)
{
    bufinit(&docs[i]);
    return bufsplit(&docs[i], "", 0);
}

static int docsfull(void)
{
    if (ndocs < MAXDOCS) return 0;
    msg("That is as many documents as cedit will hold at once.");
    return 1;
}

/* New: a blank page in a NEW tab */
static void donew(void)
{
    if (docsfull()) return;
    if (!blankdoc(ndocs)) { oom(); return; }
    ndocs++;
    setdoc(ndocs - 1);
}

/* Open replaces the current tab; Open New puts the file in one of
 * its own. Same requester, same loader, one flag apart. */
static void doopen(int newtab)
{
    char path[320];
    int slot;

    if (newtab && docsfull()) return;
    /* replacing the current tab discards it, so ask first; opening
     * into a NEW tab discards nothing and must not ask */
    if (!newtab && !askdiscard(cur, "Replace it|Cancel")) return;
    if (ltx_askfile("cedit: open a file", path, ttdrawer, 0) != 1)
        return;                 /* cancelled, or only a drawer */

    slot = newtab ? ndocs : curdoc;
    if (newtab) bufinit(&docs[slot]);
    busy(1);
    if (!loadbuf(&docs[slot], path)) {
        busy(0);
        msg("Could not read that file.");
        /* loadbuf frees before it reads, so the old text is gone
         * either way - leave an empty document, never a dead table */
        if (!blankdoc(slot)) { oom(); return; }
        if (!newtab) { setdoc(curdoc); return; }
    } else
        busy(0);
    if (newtab) ndocs++;
    setdoc(slot);
}

/* Close: the active tab goes. There is ALWAYS at least one document,
 * so closing the last one leaves a blank page - the same end state
 * Close All produces, rather than a second kind of empty. */
static void doclose(void)
{
    int i;
    if (!askdiscard(cur, "Close it|Cancel")) return;
    buffree(&docs[curdoc]);
    for (i = curdoc; i < ndocs - 1; i++) docs[i] = docs[i + 1];
    ndocs--;
    if (ndocs == 0) {
        if (!blankdoc(0)) { oom(); return; }
        ndocs = 1;
        curdoc = 0;
    } else if (curdoc >= ndocs)
        curdoc = ndocs - 1;
    cur = &docs[curdoc];
    hoff = cur->hoff;
    setdoc(curdoc);
}

static void docloseall(void)
{
    int i;
    if (!askdiscardall("Close them|Cancel")) return;
    for (i = 0; i < ndocs; i++) buffree(&docs[i]);
    ndocs = 1;
    curdoc = 0;
    cur = &docs[0];
    hoff = 0;
    if (!blankdoc(0)) { oom(); return; }
    setdoc(0);
}

static void dosaveas(void)
{
    char path[320];
    if (ltx_askfile("cedit: save as", path, ttdrawer, 1) != 1) return;
    busy(1);
    strncpy(cur->path, path, sizeof(cur->path) - 1);
    cur->path[sizeof(cur->path) - 1] = 0;
    strncpy(cur->name, (char *)FilePart((STRPTR)path),
            sizeof(cur->name) - 1);
    cur->name[sizeof(cur->name) - 1] = 0;
    if (!savebuf(cur, cur->path))
        msg("Could not write that file.");
    else
        ed_marksaved(cur);      /* undoing back here is 'unmodified' */
    busy(0);
    settitle();
    shown_dirty = cur->dirty;
    epage();                    /* the tab and the status row renamed */
}

/* b3. The chassis's own rules decide the repaint: a structural undo
 * moved every row below it, so that is a content repaint; anything
 * else touched one line and gets one row, through the same damage
 * path typing uses. */
static void doundo(int redo)
{
    int structural = 0, oldcy = cur->cy;
    int line = redo ? ed_redo(cur, &structural)
                    : ed_undo(cur, &structural);
    if (line < 0) {
        DisplayBeep(NULL);      /* nothing to undo is not an error */
        return;
    }
    goalx = cur->cx;
    follow();
    if (structural) {
        dirtyrows = 1;
        dmgold = -1;
        calcgut();              /* the line count may have changed */
    } else
        damage(oldcy);
    marktitle();
}

/* the selection changes which rows are inverse, and a drag can move
 * many at once - so this is the one interaction that repaints the
 * content rather than a row or two. Coalescing means once per input
 * burst, not once per mouse move. */
static void selpaint(void)
{
    dirtyrows = 1;
    dmgold = -1;
}

static void domark(void)
{
    if (cur->selon) ed_selclear(cur);   /* pressed twice = drop it */
    else            ed_selstart(cur);
    selpaint();
}

static void docopy(int cut)
{
    long n = ed_selbytes(cur);
    char *t;
    if (n <= 0) { DisplayBeep(NULL); return; }
    t = malloc(n);
    if (t == NULL) { oom(); return; }
    ed_seltext(cur, t);
    busy(1);
    if (!clipput(t, n))
        msg("Could not reach clipboard.device.");
    else if (cut) {
        if (!ed_seldelete(cur)) oom();
        goalx = cur->cx;
        calcgut();              /* a cut can remove lines */
        follow();
        marktitle();
    }
    busy(0);
    free(t);
    ed_selclear(cur);
    selpaint();
}

static void dopaste(void)
{
    char *t = NULL;
    long n;
    busy(1);
    n = clipget(&t);
    busy(0);
    if (n <= 0 || t == NULL) { DisplayBeep(NULL); free(t); return; }
    ed_group(cur);
    if (cur->selon) ed_seldelete(cur);  /* paste replaces a selection */
    if (!ed_instext(cur, cur->cy, cur->cx, t, n)) oom();
    ed_ungroup(cur);
    free(t);
    goalx = cur->cx;
    ed_selclear(cur);
    calcgut();
    follow();
    selpaint();
    marktitle();
}

static void dosave(void)
{
    if (cur->path[0] == 0) { dosaveas(); return; }   /* untitled */
    busy(1);
    if (!savebuf(cur, cur->path))
        msg("Could not write that file.");
    else
        ed_marksaved(cur);      /* undoing back here is 'unmodified' */
    busy(0);
    marktitle();
}

/* ---- the mouse --------------------------------------------------- */

static int dragging;

/* a click lands on a PIXEL; the buffer is indexed by CHARACTER, and
 * a tab is one character across many columns. So: pixel -> row and
 * display column, then ed_col2x walks the line's tab stops exactly
 * as the painter does to find the character under it. */
static void mousepos(int mx, int my, int *py, int *px)
{
    int row, col, y;
    row = (my - conty) / fh;
    if (my < conty) row = 0;
    if (row < 0) row = 0;
    if (row >= crows) row = crows - 1;
    y = cur->top + row;
    if (y >= cur->n) y = cur->n - 1;
    if (y < 0) y = 0;
    col = hoff + (mx - textx()) / fw;
    if (mx < textx()) col = hoff;
    if (col < 0) col = 0;
    *py = y;
    *px = ed_col2x(cur, y, col, tttab, ttmask);
}

/* ---- the event loop ---------------------------------------------- */

/* one arrow-gadget step: 1 up, 2 down, 3 left, 4 right. The gadgets
 * SCROLL - they do not move the cursor. A scrollbar is for looking
 * around, and taking the caret with it would lose the user's place
 * the moment they let go. */
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

    ltx_appname = "cedit";      /* every requester's title */
    ltx_setapp(&ceditapp);      /* before anything can paint */

    IntuitionBase = (struct IntuitionBase *)
        OpenLibrary((STRPTR)"intuition.library", 37);
    GfxBase = (struct GfxBase *)
        OpenLibrary((STRPTR)"graphics.library", 37);
    GadToolsBase = OpenLibrary((STRPTR)"gadtools.library", 37);
    AslBase = OpenLibrary((STRPTR)"asl.library", 37);   /* Open/Save As */
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
            WORD mx = msg->MouseX, my = msg->MouseY;
            APTR iaddr = msg->IAddress;
            /* b63's rule, inherited: every message defers its paint
             * and flushpaint below settles it as soon as the port is
             * empty, so a lone message still paints in its own
             * iteration and a burst paints once. */
            defer = 1;
            ReplyMsg((struct Message *)msg);

            if (class == IDCMP_CLOSEWINDOW)
                done = askquit();
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
            /* b2: b1's letter shortcuts are gone - in an editor 'b'
             * types a b. Scrolling is the cursor, the wheel and the
             * scrollbars now. VANILLAKEY is the right channel for
             * text because it is keymap-translated: his Swedish
             * layout produces the characters he actually pressed. */
            /* a click on a tab switches to it. The hit ranges come
             * from the chassis, which filled them when it drew the
             * bar - so the boxes on screen and the boxes we test are
             * the same numbers by construction. */
            /* a drag in the text selects. The mouse did nothing here
             * before, so nothing had to be rebound for it - which is
             * why this was the road chosen over Shift+arrows, whose
             * paging matters on a keyboard with no PgUp/PgDn. */
            if (class == IDCMP_MOUSEBUTTONS && code == SELECTDOWN &&
                my >= conty && my < conty + crows * fh) {
                int py, px;
                mousepos(mx, my, &py, &px);
                cur->cy = py; cur->cx = px;
                goalx = px;
                ed_break(cur);
                ed_selstart(cur);       /* anchor here; empty so far */
                dragging = 1;
                /* Intuition reports pointer movement only while
                 * asked - without this the drag never moved, which
                 * is exactly what his first boot showed. Off again
                 * on release, so an idle pointer costs nothing. */
                ltx_reportmouse(1);
                selpaint();
            } else if (class == IDCMP_MOUSEMOVE && dragging) {
                int py, px;
                mousepos(mx, my, &py, &px);
                if (py != cur->cy || px != cur->cx) {
                    cur->cy = py; cur->cx = px;
                    goalx = px;
                    follow();           /* dragging past the edge
                                         * scrolls, as it should */
                    selpaint();
                }
            } else if (class == IDCMP_MOUSEBUTTONS && code == SELECTUP) {
                dragging = 0;
                ltx_reportmouse(0);
                /* a click that never moved is a caret placement, not
                 * an empty selection sitting there doing nothing */
                {
                    int y0, x0, y1, x1;
                    if (!ed_selrange(cur, &y0, &x0, &y1, &x1)) {
                        ed_selclear(cur);
                        selpaint();
                    }
                }
            }
            if (class == IDCMP_MOUSEBUTTONS && code == SELECTDOWN) {
                int t, what = ltx_tabclick(mx, my, &t);
                if (what == LTXTAB_PICK) {
                    if (t != curdoc) setdoc(t);
                } else if (what == LTXTAB_CLOSE) {
                    /* close the tab that was clicked, not the active
                     * one - so switch first, then use the one road
                     * to closing (which is where the prompt lives) */
                    if (t != curdoc) setdoc(t);
                    doclose();
                } else if (what == LTXTAB_SCROLL)
                    drawtabbar();
            }
            if (class == IDCMP_VANILLAKEY) {
                if (code == 27) {                       /* Esc drops
                                                         * a selection */
                    if (cur->selon) { ed_selclear(cur); selpaint(); }
                } else if (code == 13)                  /* Return */
                    donewline();
                else if (code == 8)                     /* Backspace */
                    dobackspace();
                else if (code == 127)                   /* Del */
                    dodelete();
                else if (code == 9)                     /* Tab: a real
                                                         * tab byte */
                    typech('\t');
                else if (code >= 32 && code != 127)
                    typech((char)code);
            }
            if (class == IDCMP_RAWKEY) {
                int page = (qual & (IEQUALIFIER_LSHIFT |
                                    IEQUALIFIER_RSHIFT)) != 0;
                int ctrl = (qual & IEQUALIFIER_CONTROL) != 0;
                /* Shift = page / line ends, Ctrl = word jumps - the
                 * CCON line editor's assignment, so the two programs
                 * do not disagree about the same keys. */
                if (code == 0x4C)                       /* cursor up */
                    movev(cur->cy - (page ? crows : 1));
                else if (code == 0x4D)                  /* cursor down */
                    movev(cur->cy + (page ? crows : 1));
                else if (code == 0x4F) {                /* cursor left */
                    if (ctrl) wordjump(-1);
                    else if (page) moveh(0);
                    else if (cur->cx > 0) moveh(cur->cx - 1);
                    else if (cur->cy > 0)               /* wrap up */
                        { gotoyx(cur->cy - 1, cur->len[cur->cy - 1]);
                          goalx = cur->cx; }
                } else if (code == 0x4E) {              /* cursor right */
                    if (ctrl) wordjump(1);
                    else if (page) moveh(cur->len[cur->cy]);
                    else if (cur->cx < cur->len[cur->cy])
                        moveh(cur->cx + 1);
                    else if (cur->cy + 1 < cur->n)      /* wrap down */
                        { gotoyx(cur->cy + 1, 0); goalx = 0; }
                }
                /* the wheel SCROLLS and leaves the cursor alone -
                 * same reason as the scrollbars */
                else if (code == 0x7A)                  /* wheel up */
                    scrollto(cur->top - (page ? crows : 3));
                else if (code == 0x7B)                  /* wheel down */
                    scrollto(cur->top + (page ? crows : 3));
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
    clipclose();
    ltx_freefilereq();
    ltx_closefont();
    if (ttoollock) { UnLock(ttoollock); ttoollock = 0; }
    if (AslBase) CloseLibrary(AslBase);
    if (DiskfontBase) CloseLibrary(DiskfontBase);
    if (IconBase) CloseLibrary(IconBase);
    if (WorkbenchBase) CloseLibrary(WorkbenchBase);
    if (GadToolsBase) CloseLibrary(GadToolsBase);
    if (GfxBase) CloseLibrary((struct Library *)GfxBase);
    if (IntuitionBase) CloseLibrary((struct Library *)IntuitionBase);
}

/* ---- main -------------------------------------------------------- */

/* open `path` into the next free slot; the FIRST one lands in the
 * document that already exists rather than beside it */
static int openinto(const char *path)
{
    int slot = ndocs;
    if (ndocs == 1 && docs[0].path[0] == 0 && !docs[0].dirty &&
        docs[0].n == 1 && docs[0].len[0] == 0)
        slot = 0;               /* the untouched blank we started with */
    if (slot >= MAXDOCS) return 0;
    if (slot != 0) bufinit(&docs[slot]);
    if (!loadbuf(&docs[slot], path)) {
        if (!blankdoc(slot)) return 0;
        return 0;
    }
    if (slot == ndocs) ndocs++;
    return 1;
}

static int smain(int argc, char **argv)
{
    static char fpaths[MAXDOCS][310];
    int nf = 0, i, bad = 0;

    /* one empty line, always. A buffer with no lines at all has no
     * legal cursor position, and every edit indexes ln[cy] - so "no
     * file" is an empty document, not an empty table. */
    if (!blankdoc(0)) return 20;

    if (argc == 0) {                    /* Workbench */
        IconBase = OpenLibrary((STRPTR)"icon.library", 37);
        nf = readtooltypes((struct WBStartup *)argv, fpaths);
    } else {
        /* FILE/M: tabs exist, so several names are a reasonable
         * thing to type and each one gets its own */
        struct RDArgs *rda;
        LONG args[1] = { 0 };
        rda = ReadArgs((STRPTR)"FILE/M", args, NULL);
        if (rda) {
            STRPTR *list = (STRPTR *)args[0];
            while (list && *list && nf < MAXDOCS) {
                strncpy(fpaths[nf], (char *)*list, 309);
                fpaths[nf][309] = 0;
                nf++;
                list++;
            }
            FreeArgs(rda);
        }
    }
    for (i = 0; i < nf; i++)
        if (!openinto(fpaths[i])) bad++;
    if (bad && argc)
        PutStr((STRPTR)"cedit: could not read every file named\n");
    guimode();
    for (i = 0; i < ndocs; i++) buffree(&docs[i]);
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
