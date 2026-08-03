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
 *
 * ---- b9: one engine, several languages ---------------------------
 *
 * What a language needs turned out to be a short list - what starts a
 * line comment, what opens and closes a block comment and whether
 * those nest, which characters quote a string, which prefix a number,
 * and how keywords are cased - so this became a loop over an `LxLang`
 * table instead of three copies of itself.
 *
 * The tables are COMPILED IN rather than read from a drawer, and that
 * is a decision worth writing down. The corpus harness is what makes
 * the E lexer trustworthy: 33,735 lines of real code, asserted to
 * come back with ordered spans and a comment state that closes at
 * zero at end of file. A table loaded from disk at run time cannot be
 * checked that way, and a half-edited definition would break
 * highlighting on a machine nobody can debug from here.
 *
 * What this shape buys is that a loader becomes ADDITIVE: the engine
 * already takes a table it does not own, so reading one from
 * PROGDIR:Lexers/ later is a parser and nothing else - no change to
 * the lexing itself, and the built-in tables stay as the fallback
 * when a file is missing or malformed. That is the reason for doing
 * it in this order rather than designing a file format first.
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
#define LX_C    2
#define LX_ASM  3
#define LX_NLANG 4

/* how a language spells its keywords */
#define LXK_EXACT 0     /* case sensitive, as written in the table */
#define LXK_UPPER 1     /* must be ALL CAPS to be considered at all -
                         * E is case sensitive and every keyword is
                         * capitals, so matching any other way paints
                         * a variable called `to` as a keyword */
#define LXK_FOLD  2     /* case insensitive - 68k asm, where `move`,
                         * `Move` and `MOVE` are one mnemonic */

typedef struct {
    const char *name;           /* shown in the Highlight menu */
    const char *const *kw;      /* SORTED, or the binary search lies -
                                 * and the harness checks that it is,
                                 * because a hand-written table of 150
                                 * mnemonics will not stay sorted by
                                 * good intentions */
    int         nkw;
    int         kwcase;         /* LXK_* above */
    const char *lc1, *lc2;      /* line-comment starters, NULL if none */
    int         starcol0;       /* '*' in COLUMN 0 starts a comment -
                                 * the old assembler convention, and
                                 * column 0 only, because anywhere else
                                 * it is a multiply */
    const char *bo, *bc;        /* block comment open/close, or NULL */
    int         bnest;          /* and whether those nest */
    const char *quotes;         /* characters that quote a string */
    const char *numpfx;         /* extra number prefixes: "$%" and so
                                 * on. Empty for C, where '%' is
                                 * modulo and '$' is not a number. */
    int         hash;           /* a leading # is a preprocessor
                                 * directive, and reads as a keyword */
} LxLang;

/* the table for a language id, or NULL for LX_NONE and anything out
 * of range. Exposed so the harness can check the keyword tables are
 * sorted and the app can name them in a menu. */
const LxLang *lx_table(int lang);

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
