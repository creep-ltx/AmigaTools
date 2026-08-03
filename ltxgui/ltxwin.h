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

/* ---- JAM1 over a surface that is already background --------------
 * The CFile R6 trick. JAM2 lays down a background pixel for every
 * cell as well as the glyph; JAM1 writes the glyph alone. A row the
 * scroll blit just vacated is background by construction, so the
 * entering rows after a scroll can be drawn glyph-only.
 *
 * ltx_clean is the chassis telling the app's row painter that THIS
 * row is one of those. It is set only around the entering rows of a
 * scroll, never for a repaint in place, where the old glyphs are
 * still on the surface and JAM1 would leave them behind.
 *
 * CCON's OTHER chip-level saving, rp_Mask - keep the OR of every pen
 * drawn and hand the blitter only those planes, measured there at
 * 34.8ms / 17.4ms / 8.8ms for four / two / one plane - was tried
 * here and REMOVED. ScrollRaster's fill of the vacated strip obeys
 * rp_Mask too, so the masked-out planes of those rows were never
 * cleared, and that is exactly the precondition JAM1 above depends
 * on. The two optimisations are mutually exclusive in one pass, and
 * JAM1 is the one that survived: his word for the masked build was
 * "It's worse", and the screen showed old glyphs under new ones. */
extern int ltx_clean;

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

/* ---- asking for pointer news only when it is wanted --------------
 * His question: does the window really need to know where the
 * pointer is? Only while something is being manipulated - a drag, a
 * held arrow, a dragged knob. The rest of the time MOUSEMOVE and
 * INTUITICKS are messages that cost a port round trip and a pass
 * through the event loop to be thrown away, and they arrive ten or
 * more times a second for as long as the pointer sits over the
 * window.
 *
 * So they are left OUT of the window's IDCMP set and switched on for
 * the duration. ltx_openwin remembers the app's base set; this ORs
 * the pointer classes onto it and takes them off again. */
void ltx_trackpointer(int on);

/* ---- requesters -------------------------------------------------- */

/* b7: a small form requester - N labelled fields and a row of
 * buttons. cdiff has had a one-field version since its b67 (the Find
 * box); cedit's Replace wants two fields and a toggle and Goto Line
 * wants one, which is the second caller that says LIFT rather than
 * copy. cdiff's askfind is now a call to this.
 *
 * A field is a string gadget when `buf` is set and a checkbox when
 * `flag` is - exactly one of the two. Real gadtools gadgets, not a
 * hand-rolled line editor: his standing instruction is to use the
 * OS's own, and a string gadget is where the OS keeps undo, the
 * clipboard shortcuts and the keymap. */
#define LTX_MAXFIELDS 6
#define LTX_MAXBUTTONS 3

typedef struct {
    const char *label;
    char       *buf;            /* string field: where the text goes */
    int         max;            /* and its capacity, minus the NUL */
    int        *flag;           /* checkbox field instead, 0/1 */
} LtxField;

/* Returns 0 when cancelled - the close gadget, Esc, or the Cancel
 * button this adds on the right for you - otherwise 1..nb saying
 * WHICH affirmative button was used. Return in a string gadget is
 * button 1, the leftmost, which is why that one should be the
 * ordinary answer. Field values are written back only on an accept,
 * so a cancel cannot half-edit the caller's strings. */
int ltx_askfields(const char *title, LtxField *f, int nf,
                  const char **buttons, int nb);

/* ---- b7b: the prompt row, Ed's way ------------------------------
 * His call, with Ed 47.2 on screen beside it: a whole window that
 * has to be opened, centred, dragged out of the way and closed, to
 * collect one short string, is a lot of furniture for a keystroke.
 * Ed asks on its bottom line and gets out of the way.
 *
 * So the prompt takes over the STATUS ROW rather than inserting a
 * line of its own. Nothing reflows, nothing scrolls, the page does
 * not repaint - one row is painted and painted back. And the status
 * text is precisely what is not wanted while typing a search: the
 * line number under the cursor is about to change anyway.
 *
 * `buf` arrives holding the previous answer and is left untouched
 * unless the prompt is accepted. Returns 1 on Return, 0 on Esc or
 * the close gadget.
 *
 * With STATUSBAR=NO there is no row to borrow, and rather than
 * relayout the page to manufacture one - which WOULD repaint
 * everything, the thing this design exists to avoid - the caller
 * falls back to ltx_askfields. Hence ltx_haveprompt. */
int  ltx_haveprompt(void);
int  ltx_askline(const char *label, char *buf, int max);

/* The prompt owns the window's message port while it is up, so a
 * resize during one never reaches the app's own loop. The chassis
 * re-measures its half; this says whether the app must settle the
 * rest (cedit's gutter width follows viscols). Reading it clears it. */
int  ltx_tookresize(void);

/* a transient message in the status row - "not found", "12 replaced"
 * - instead of a requester that has to be dismissed before the next
 * keystroke. Cleared by the next key the app sees. */
void ltx_flash(const char *text);
void ltx_flashclear(void);
int  ltx_flashing(void);

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
