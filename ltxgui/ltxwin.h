/* ltxwin - the shared GUI chassis of the LTX AmigaTools family.
 *
 * Everything here was written, boot-tested and eye-tuned inside cdiff
 * 0.1b1-b109 and lifted out when cedit became the second tool that
 * wanted it. The rule this module exists to serve is CFile's own
 * (cfile/todo.md): the machinery moves to a module when a second tool
 * wants it, not before.
 *
 * The state below is DEFINED here and declared extern for the app, so
 * a lifted function and its caller keep the names they were written
 * with. That is deliberate: a rename would have turned a code move
 * into a 160-site edit of a program that renders correctly.
 *
 * Nothing in this file may know what the app's content IS. Rows,
 * lines, buffers, diffs - all of that stays on the app's side.
 */
#ifndef LTXWIN_H
#define LTXWIN_H

#include <exec/types.h>
#include <dos/dos.h>
#include <intuition/intuition.h>
#include <graphics/text.h>

/* ---- the window, and who we were launched as ------------------- */

extern struct Window *win;      /* NULL while iconified */

/* our own drawer and file name, kept from the WBStartup message so
 * the AppIcon can wear the user's icon and iconset() can write back
 * to it. Zero after a shell launch, and every user of them checks. */
extern BPTR ttoollock;
extern char ttoolname[110];

/* ---- the cell grid --------------------------------------------- */

extern struct RastPort *rp;
extern struct TextFont *font;
extern int fw, fh, fbase;       /* cell metrics */
extern int hoff;                /* horizontal column offset - TEXT
                                 * only; the gutter stays pinned */
extern int gutw;                /* gutter digits; 0 = no gutter */
extern int tttab, ttmask;       /* tab stop, and its mask when the
                                 * stop is a power of two (0 = pay
                                 * for a modulo per expanded column) */

/* ---- the row painter -------------------------------------------- */

/* the widest row the painter will render in one call. The buffer
 * holds only the VISIBLE window rather than the line from column 0,
 * so a large hoff can never run past it. */
#define LTX_MAXCOLS 256
extern char ltx_vis[LTX_MAXCOLS];

/* a run of cells sharing one pen pair, in VISIBLE columns. Runs are
 * adjacent, never overlapping: each one ends where the next begins,
 * and the last ends at `width`. */
typedef struct {
    int start;                  /* first visible column */
    int pen, bg;
} LtxRun;

/* expand src into ltx_vis as `width` visible columns starting at the
 * current hoff: tabs to the tab grid (stops stay absolute), control
 * characters to '.', and blanks out to the right edge. Returns the
 * width actually prepared, clamped to LTX_MAXCOLS - use THAT for the
 * run list, not the width you asked for. */
int ltx_expandvis(const char *src, int len, int width);

/* b66: render exactly `width` columns and let Text() lay down its
 * own background through BPen. One blit puts both the glyphs and the
 * surface under them on screen, so the caller needs no RectFill at
 * all - and a row can no longer be caught half-painted, which is
 * what a full-screen repaint was showing.
 *
 * b97 generalised at cedit b0b: up to three runs became N. Every
 * pixel is still written exactly once (the b66 rule), which is the
 * property a syntax highlighter has to inherit rather than rebuild.
 * runs[0].start must be 0 and nruns >= 1. */
void ltx_drawruns(int x, int y, const char *vis, int width,
                  const LtxRun *runs, int nruns);

/* right-aligned 1-based line number in the gutter cells */
/* b66: gutw digits PLUS the separator column, so this Text covers
 * the whole gutw+1 span the caller skips over - no fill needed */
void drawnum(int x, int y, long line, int pen, int bg);

/* ---- opening the window ----------------------------------------- */

/* what the app wants; the chassis owns HOW. Every field is a
 * tooltype's worth of user intent, and every one of them is inert
 * when empty or negative, so a bare launch behaves as it always
 * did. */
typedef struct {
    const char *title;
    const char *scrname;    /* OPENSCREEN= - a screen of OUR own */
    const char *pubscr;     /* PUBSCREEN= - somebody else's */
    int   depth;            /* SCREENDEPTH=, 0 = clone Workbench */
    int   left, top;        /* -1 = the chassis decides */
    int   width, height;    /* <= 0 = out to the screen edge */
    const char *fontname;   /* FONT= family, "" = system default */
    int   fontsize;
    int   minwidth, minheight;
    ULONG idcmp;
} LtxWinSpec;

extern struct Screen *ltx_myscr;    /* our own screen, or NULL */

/* open the screen (or attach to one), open the window on it, read
 * the screen's GUI pens and open the font. Returns 0 having cleaned
 * up after itself if any of that fails.
 *
 * On success `*scrp` is the screen and `*drip` is its DrawInfo -
 * STILL HELD, and the pubscreen still locked with it (b48:
 * sysiclass reads both while it builds the arrow images). The
 * caller releases them with ltx_screendone() once addscrollers has
 * run. */
int  ltx_openwin(const LtxWinSpec *sp, struct Screen **scrp,
                 struct DrawInfo **drip);
void ltx_screendone(struct Screen *scr, struct DrawInfo *dri);
/* kept separate, and in this order: VisualInfo obtained from the
 * screen must be freed BEFORE the screen it came from goes away, and
 * that free is the app's (it owns its menus). */
void ltx_closewindow(void);
void ltx_closescreen(void);
void ltx_closefont(void);       /* at exit only - see ltx_openwin */

/* ---- the window grid -------------------------------------------- */

extern int gx0, gy0, viscols, visrows;    /* drawable grid */
/* b86, his find: both rules reached the LEFT border but stopped
 * short of the right one "depending on the window width". viscols is
 * (width / fw), so viscols*fw falls short of the real edge by the
 * remainder - 0 to fw-1 pixels. Anything drawn to the CELL grid ends
 * there; anything that should meet the border needs the PIXEL edge.
 * xend is that edge, and slx is the first pixel of the leftover
 * sliver. */
extern int xend, slx;
extern int conty, crows;        /* content grid below the tab bar */
extern int tabh;                /* tab bar height in pixels; 0 when
                                 * the bar is off */
/* 1 = reserve room for a tab bar (the default, and what cdiff always
 * wants). 0 = no bar at all, and the content starts at the top
 * border instead - a single document has nothing to switch between,
 * so the row it would cost is better spent on text. Set it BEFORE
 * ltx_calcgrid(); ltx_drawtabs() draws nothing while it is 0. */
extern int ltx_tabbar;
extern int staty;               /* b82: status row y, -1 = no room */
extern int ttstatus;            /* STATUSBAR=YES/NO */

/* the screen's own GUI pens (DrawInfo), with 4-colour WB fallbacks -
 * the tabs are drawn in Intuition's bevel language (his ask: GUI
 * tabs, not text cells), so they follow the user's WB palette */
extern int pshine, pshadow, pfill, pfilltext, ptext, pback;

/* the generic text grid from the window's current size - run at open
 * and again on every IDCMP_NEWSIZE. The app runs its OWN layout
 * afterwards: anything that depends on what the app puts in the grid
 * (reserved columns, panes, gutter width) is the app's business and
 * none of it feeds back into the numbers computed here. */
void ltx_calcgrid(void);

/* ---- the tab bar ------------------------------------------------ */

/* cdiff needs four. cedit needs one per open file, and will need to
 * answer for what happens past the last one that fits. */
#define LTX_MAXTABS 32

/* pixel hit ranges, filled by ltx_drawtabs, indexed by the app's OWN
 * tab number - a tab scrolled out of view gets a zero-width range,
 * so a hit test can never land on something that is not on screen. */
extern int ltx_tabx[LTX_MAXTABS], ltx_tabe[LTX_MAXTABS];
extern int ltx_tabcx[LTX_MAXTABS];  /* close box left edge, or 0 */
extern int ltx_ntabs;
extern int ltx_tabfirst;            /* leftmost tab drawn */

/* the tab bar: real GUI tabs (his ask) - beveled boxes in the
 * screen's own pen set, so they follow the user's WB palette rather
 * than inventing colours. `active` is an INDEX into labels[], not
 * whatever the app calls that view. n == 0 clears the bar.
 *
 * `closable` puts a small close box on every tab. When the tabs do
 * not all fit, a left arrow appears at the left end and a right one
 * at the right, each drawn only when that direction is actually
 * available - and the bar scrolls itself so the ACTIVE tab is always
 * on screen, because a tab you cannot reach is a document you cannot
 * reach. Both arrow slots stay reserved while scrolling is in force,
 * so the tabs do not shuffle sideways as you page through them. */
void ltx_drawtabs(const char *const *labels, int n, int active,
                  int closable);

/* what a click in the bar means. LTXTAB_SCROLL means the chassis has
 * already moved the bar and the app need only redraw it. */
#define LTXTAB_NONE   0
#define LTXTAB_PICK   1         /* *idx = the tab clicked */
#define LTXTAB_CLOSE  2         /* *idx = that tab's close box */
#define LTXTAB_SCROLL 3
int ltx_tabclick(int mx, int my, int *idx);

/* ---- what the chassis asks the app ------------------------------ */

/* The chassis scrolls, but it does not know what it is scrolling.
 * cdiff's model is Rows and DLines, cedit's is a Buffer of lines;
 * these are the only questions the scroll engine ever needs to ask,
 * and the app answers them in its own terms. */
typedef struct {
    int  (*rowcount)(void);     /* rows in the active view */
    int *(*toprow)(void);       /* the active view's scroll top */
    int  (*colcount)(void);     /* total columns, >= viscols */
    void (*paintrow)(int vr);   /* one visible row */
    void (*paintrows)(void);    /* every visible row */
    void (*pageall)(void);      /* the whole page, app-composed */
    void (*statustext)(char *dst, int max);  /* the status row's own
                                              * left-hand text */
    void (*flushapp)(void);     /* settle app-owed painting */
} LtxApp;

extern const LtxApp *ltxapp;
void ltx_setapp(const LtxApp *a);

/* ---- scrolling and the deferred paint --------------------------- */

/* b62/b63: while `defer` is set the state still updates exactly as
 * before, but painting is skipped and merely OWED, and flushpaint()
 * settles it once the port is empty. The debt is TYPED so paying it
 * picks the cheapest sufficient repaint. */
extern int defer, dirtyall, dirtyrows, dirtyknob;
extern int scrollfrom, scrollfromset;
extern int ltx_appowed;         /* the app has its own debt pending;
                                 * flushapp() is what settles it */
extern int propheld;            /* 1 = vertical knob held, 2 = horiz */

void paintscroll(int from, int to);
void scrollto(int target);
void sethoff(int nh);
int  inputwaiting(void);
void flushpaint(void);
void drawstatus(void);
void updscrollers(void);
void proptrack(void);
/* the two halves of proptrack, addressable on their own: a
 * GADGETDOWN on a knob names WHICH gadget, where an INTUITICKS only
 * knows that something is held. Same pot arithmetic either way -
 * the PropInfo is the single source of truth for both paths. */
void ltx_trackvert(void);
void ltx_trackhoriz(void);
void addscrollers(struct DrawInfo *dri, struct Screen *scr);
void freearrows(void);          /* the four sysiclass images */


extern struct Gadget vgad, hgad, agup, agdn, aglt, agrt;
extern int gadsok, arrowsok, arrheld;

/* ---- fonts ----------------------------------------------------- */

/* open the font actually asked for: the ROM/memory list first, disk
 * second, and validated on BOTH roads (fixed, designed, right size).
 * A scaled topaz is not topaz. NULL if nothing qualifies. */
struct TextFont *tryfont(const char *name, int size);

/* ---- pointer --------------------------------------------------- */

/* the busy pointer, with WA_PointerDelay so a fast job never flashes
 * it. V39+; older Kickstarts keep the normal pointer. No-op with no
 * window. */
void busy(int on);

/* ---- mouse reporting --------------------------------------------
 * Intuition sends IDCMP_MOUSEMOVE for a window's body only while it
 * asks to be told - so a drag that tracks the pointer has to turn
 * this on, and OFF again on release. Left on permanently it puts a
 * message on the port for every pixel the pointer crosses, which on
 * an 020 is real work for nothing. */
void ltx_reportmouse(int on);

/* ---- requesters -------------------------------------------------- */

/* the app's name, used as the title of every requester below. Set it
 * once at startup; "ltx" until then. */
extern const char *ltx_appname;

/* a plain OK requester */
void ltx_msg(const char *text);

/* the ASL file requester. ONE is kept for the life of the program,
 * so it remembers where the user last was; `initdrawer` only seeds
 * it the first time (a DRAWER= tooltype, or "").
 *
 * Returns 1 when a file was picked and `dest` holds its full path,
 * 2 when only a drawer was picked and `dest` holds the drawer, and 0
 * when the user cancelled or asl.library is not there. `dest` must
 * have room for 310 bytes. `save` non-zero puts the requester in
 * save mode, where a name that does not exist yet is the point. */
int  ltx_askfile(const char *title, char *dest, const char *initdrawer,
                 int save);
void ltx_freefilereq(void);     /* at exit */

/* ---- tooltypes ------------------------------------------------- */

/* case-insensitive equality, so VIEW=tree and VIEW=TREE both work */
int tteq(const char *a, const char *b);

/* a positive dimension, or -1 for "absent, or unparseable, or
 * explicitly -1" - all of which mean "out to the screen edge" */
int ttdim(char **tt, const char *name);

/* a number clamped to [lo,hi], or def when absent or out of range */
int ttnum(char **tt, const char *name, int lo, int hi, int def);

/* a string, copied to dest (max includes the terminator). dest is
 * left untouched when the tooltype is absent or empty. */
void ttstr(char **tt, const char *name, char *dest, int max);

/* set NAME=value on OUR OWN icon, preserving every other byte - the
 * splice rule, not a GetDiskObject/PutDiskObject round trip (which
 * is destructive; see AmigaReferences/icon-info-files.md). Returns 0
 * when there is no icon to write, when the icon's layout is not one
 * we understand, or when the write fails - and in every one of those
 * cases the file on disk is left exactly as it was. */
int iconset(const char *name, const char *value);

#endif /* LTXWIN_H */
