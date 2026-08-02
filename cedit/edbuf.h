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
typedef struct {
    char **ln;                  /* per-line text, NUL-terminated */
    int   *len;                 /* used length, excluding the NUL */
    int   *cap;                 /* allocated per line */
    unsigned char *lex;         /* b5: per-line lexer state. Carried
                                 * now so growing the table later
                                 * touches one place, not four. */
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
