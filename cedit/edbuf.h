/* edbuf - cedit's text buffer: pure logic, no Amiga headers.
 *
 * Kept in its own file for the reason diff.c is: a harness builds it
 * on the HOST and under vamos, and runs both, because cdiff found an
 * -O2 miscompilation on m68k that a host-only test could never have
 * seen (AmigaReferences/toolchain-and-testing.md). Everything that
 * can be decided without a window belongs here - at b2 and b3 that
 * means the edits and the undo stack too.
 */
#ifndef EDBUF_H
#define EDBUF_H

/* The CFile editor's model (cfile.e edensure/edgrow, 0.5b44): a
 * doubling line TABLE of independently grown per-line buffers. Not a
 * gap buffer, and the reason is what the rest of cedit needs:
 * rendering row N is an O(1) lookup, the gutter number IS the index,
 * and b5's per-line lexer state is one byte alongside. Its other
 * virtue is proven rather than argued - CFile's editor lost its
 * 8192-line cap and its 200-char line cap by growing these arrays,
 * and real memory is the only wall left. */
/* ---- undo -------------------------------------------------------
 * Command records, not snapshots: a 5,000-line file cannot afford a
 * copy per keystroke on a machine with 8MB, and the inverse of every
 * edit here is exactly one other edit.
 *
 * The records are pushed by the ed* primitives THEMSELVES, so no
 * path can change a buffer without becoming undoable - a rule worth
 * more than any amount of care at the call sites.
 *
 * One array, one cursor: records below `utop` are undoable, records
 * at or above it are redoable, and a fresh edit throws the latter
 * away. That is the whole model. */
#define UNDO_INS   0            /* n characters went in at (y,x) */
#define UNDO_DEL   1            /* `text` came out at (y,x) */
#define UNDO_SPLIT 2            /* line y split at x */
#define UNDO_JOIN  3            /* line y+1 joined onto y, which was
                                 * x characters long at the time */
#define UNDO_MAX   500          /* oldest records fall off the end */

typedef struct {
    unsigned char op;
    int  grp;                   /* 0 = on its own; otherwise every
                                 * record sharing this id undoes as
                                 * ONE step. A paste is one undo, not
                                 * thirty. */
    int  y, x;
    int  n;                     /* INS: how many; DEL: strlen(text) */
    char *text;                 /* DEL only, else NULL */
    int  cy, cx;                /* where the cursor was before it */
} UndoRec;

typedef struct {
    char **ln;                  /* per-line text, NUL-terminated */
    int   *len;                 /* used length, excluding the NUL */
    int   *cap;                 /* allocated per line */
    unsigned char *lex;         /* the state each line STARTS in.
                                 * lex[0] is always 0. Kept narrow on
                                 * purpose - one byte per line across
                                 * a 12,000-line file is worth it -
                                 * and always read through an int
                                 * local before comparing, because of
                                 * the -O2 m68k narrow-load bug that
                                 * widened LxRun.cls. */
    int    n;                   /* lines in use */
    int    tab;                 /* table capacity */
    int    top;                 /* scroll top, in rows */
    int    hoff;                /* this buffer's pan (b4: the chassis
                                 * has ONE hoff, so switching tabs
                                 * saves and restores it here) */
    int    cy, cx;              /* b2: the cursor */
    int    dirty;               /* b2: unsaved changes */
    int    maxw, maxwdirty;     /* widest expanded line, lazily */
    /* what the FILE used, so saving writes back what was read. An
     * editor that silently converts line endings is telling the same
     * kind of lie cdiff refuses elsewhere - the diff of a file it
     * saved would show every line changed. */
    int    eol;                 /* EOL_LF / EOL_CRLF / EOL_CR */
    int    noeol;               /* the last line had no terminator */
    /* undo */
    UndoRec *ur;
    int    nur;                 /* records held */
    int    utop;                /* the undo/redo split point */
    int    urcap;
    int    ubreak;              /* 1 = do not merge with the top
                                 * record; set by the app whenever
                                 * the cursor moves on its own */
    int    usaved;              /* utop as of the last save, so undo
                                 * back to it clears `dirty` */
    int    uapply;              /* inside an undo: do not record */
    int    ugrp;                /* the group being recorded, or 0 */
    int    ugrpnext;            /* the next group id to hand out */
    /* selection: an anchor plus the cursor. Inactive when selon is
     * 0; the two ends may be in either order and ed_selrange sorts
     * them, because a drag can go backwards. */
    int    selon, say, sax;
    int    lang;                /* LX_E, or LX_NONE for plain text */
    int    lexdone;             /* lines whose lex[] state is known */
    char   path[310];
    char   name[110];
} Buffer;

#define EOL_LF   0
#define EOL_CRLF 1
#define EOL_CR   2

void bufinit(Buffer *b);
void buffree(Buffer *b);

/* room for at least `need` lines; the table doubles. 0 = out of
 * memory, and the buffer is left exactly as it was. */
int  edensure(Buffer *b, int need);
/* line `i` holds at least `need` bytes plus its terminator */
int  edgrow(Buffer *b, int i, int need);
/* append one line, copying `len` bytes */
int  addline(Buffer *b, const char *s, int len);

/* split `raw` into lines. CR, LF and CRLF all end one - Amiga source
 * arrives from everywhere. A file with no trailing newline still
 * gets its last line; an EMPTY file gets exactly one empty line,
 * because a buffer with no lines has no cursor position to be in.
 * 0 = out of memory partway, and the buffer is freed rather than
 * left half-populated. */
int  bufsplit(Buffer *b, const char *raw, long got);

/* ---- editing ----------------------------------------------------
 * Every one of these returns 0 ONLY on out of memory, and leaves the
 * buffer unchanged when it does. Coordinates are clamped by the
 * caller, not here: cedit's cursor is the single place that decides
 * what is a legal position, and duplicating that decision is how the
 * two drift apart. */

/* insert one character at (y,x); x may be len[y] (append) */
int  edinsch(Buffer *b, int y, int x, char c);
/* delete the character at (y,x); a no-op at end of line */
void eddelch(Buffer *b, int y, int x);
/* split line y at x - the tail becomes a new line y+1 */
int  edsplitline(Buffer *b, int y, int x);
/* join line y+1 onto the end of line y */
int  edjoinline(Buffer *b, int y);

/* undo/redo one step. Returns -1 when there was nothing to do,
 * otherwise the line the change starts at; *structural is set when
 * lines were added or removed, so every row below moved and the
 * caller must repaint rather than touch one row. The cursor is left
 * where the edit happened, in b->cy/b->cx. */
int  ed_undo(Buffer *b, int *structural);
int  ed_redo(Buffer *b, int *structural);

/* end the current coalescing run: the next typed character starts a
 * new undo record rather than extending the last. The app calls this
 * whenever the cursor moves for any reason other than typing. */
void ed_break(Buffer *b);

/* remember this point as the saved state, so undoing back to it
 * clears `dirty` and redoing away from it sets it again */
void ed_marksaved(Buffer *b);

int  ed_canundo(const Buffer *b);
int  ed_canredo(const Buffer *b);

/* everything recorded between these two undoes as one step */
void ed_group(Buffer *b);
void ed_ungroup(Buffer *b);

/* ---- selection ---------------------------------------------------
 * The anchor is set where a drag starts or where the mark key is
 * pressed; the other end is always the cursor. Nothing here draws -
 * the app renders the range with the row painter's runs. */

void ed_selstart(Buffer *b);    /* anchor at the cursor, select on */
void ed_selclear(Buffer *b);
/* the range in document order, 0 when nothing is selected or the two
 * ends are the same place */
int  ed_selrange(const Buffer *b, int *y0, int *x0, int *y1, int *x1);

/* how many bytes ed_seltext will write (no terminator), and the text
 * itself, lines joined with LF */
long ed_selbytes(const Buffer *b);
long ed_seltext(const Buffer *b, char *out);

/* delete the selection; the cursor lands at its start. One undo. */
int  ed_seldelete(Buffer *b);

/* insert text at (y,x), splitting on LF and CR. One undo. The cursor
 * is left after the last character inserted. */
int  ed_instext(Buffer *b, int y, int x, const char *t, long n);

/* a display column (what the screen counts, tabs expanded) to a
 * character index in line y, and back. A click lands on a column;
 * the buffer is indexed by character. */
int  ed_col2x(const Buffer *b, int y, int col, int tabsize, int mask);

/* ---- syntax state -------------------------------------------------
 * lex[i] is the state line i STARTS in, so line i can be coloured
 * knowing only that byte. ed_lexupto brings the array up to date as
 * far as `upto`, lexing forward from wherever it already was.
 *
 * After an edit, ed_lexdirty walks forward from the edited line and
 * stops the moment a recomputed state matches the one already
 * stored: a change inside a line almost never reaches the line after
 * it, so this is one line of work in the ordinary case and only runs
 * long when a block comment was opened or closed. */
void ed_lexupto(Buffer *b, int upto);
void ed_lexdirty(Buffer *b, int y);

/* ---- saving -----------------------------------------------------
 * The bytes a save produces are the one thing in an editor that must
 * never be guessed at, so they are built here where the harness can
 * check them, and cedit.c only does the writing. */

/* how many bytes bufserialize will produce */
long bufbytes(const Buffer *b);
/* fill `out` with exactly that many bytes; returns the count. Line
 * endings are the ones the file arrived with, and a file that had no
 * final terminator does not gain one. */
long bufserialize(const Buffer *b, char *out);

/* the width of a line once tab stops are expanded. `mask` is
 * tabsize-1 when the size is a power of two, else 0 - which costs a
 * modulo per column instead (a DIVU per cell at 14MHz). */
int  explen(const char *p, int n, int tabsize, int mask);
/* the widest expanded line in the buffer, cached until maxwdirty */
int  bufmaxw(Buffer *b, int tabsize, int mask);

#endif /* EDBUF_H */
