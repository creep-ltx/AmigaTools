/* elex - the syntax lexer. Pure logic, no Amiga headers, so the
 * harness builds it on the host AND under vamos exactly as it does
 * edbuf. Nothing here knows about pens, screens or columns: it hands
 * back spans in SOURCE character positions and the renderer decides
 * what they look like.
 *
 * Amiga E first, and deliberately - CygnusEd and GoldED both do C and
 * asm, neither properly knows E, and E is what most of this
 * collection is written in.
 *
 * The state model is one byte per line: lex a line, get the state the
 * NEXT line starts in. After an edit the app re-lexes from the edited
 * line until that byte matches what it was before, which is almost
 * always one line. A scroll lexes only the rows that entered.
 */
#ifndef ELEX_H
#define ELEX_H

/* what a span is */
#define LX_TEXT    0
#define LX_COMMENT 1
#define LX_STRING  2
#define LX_KEYWORD 3
#define LX_NUMBER  4
#define LX_NCLASS  5

/* languages. LX_NONE lexes nothing and every line comes back as one
 * LX_TEXT span - which is exactly what a plain text file wants. */
#define LX_NONE 0
#define LX_E    1

/* `cls` is an int and not the unsigned char it obviously wants to
 * be, and the reason is measured rather than stylistic: at -O2 on
 * m68k, bebbo's gcc reads a struct's unsigned char field WRONGLY in a
 * tight loop - `runs[i].cls != runs[i-1].cls` reports a false match
 * on data that prints correctly one line earlier, and the same loop
 * over the int field beside it is fine. -O0 and -O1 are fine; the
 * host at -O2 is fine. It is the second instance of the -O2 m68k
 * class cdiff's b100 found, and again silent at -Wall.
 *
 * These arrays are per-line and never more than a few dozen entries,
 * so two bytes each buys nothing worth the risk. See
 * AmigaReferences/toolchain-and-testing.md. */
typedef struct {
    int start;                  /* first character of the span */
    int cls;
} LxRun;

/* the state a line ends in, carried to the next. 0 is "nothing open";
 * anything else is how many block comments are still unclosed,
 * because E nests them. Capped so it always fits a byte. */
#define LX_STATE_MAX 15

/* the most spans one row is worth splitting into. Past this the tail
 * keeps the last colour - a cosmetic limit on a pathological line,
 * never a wrong character. */
#define LX_MAXSPAN 24

/* pick a language from a file name; LX_NONE when nothing matches */
int lx_language(const char *name);

/* lex one line. `state` is what the previous line ended in; the
 * return value is what THIS line ends in. Spans are written to
 * runs[] in order, the first always starting at 0, and *nruns is set
 * to how many. A line that needs more than maxruns spans stops
 * splitting and the tail stays in the last one - a cosmetic limit,
 * never a wrong character. */
unsigned char lx_line(int lang, unsigned char state,
                      const char *s, int n,
                      LxRun *runs, int maxruns, int *nruns);

#endif /* ELEX_H */
