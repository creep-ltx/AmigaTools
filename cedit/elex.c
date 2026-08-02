/* elex - the syntax lexer. See elex.h. */
#include <string.h>
#include "elex.h"

/* Amiga E's keywords. Uppercase only, which is not laziness: E is
 * case sensitive and every keyword is spelled in capitals, so
 * matching case-insensitively would paint a variable called `to` or
 * a field called `list` as a keyword. Checked against the 31,906
 * lines of E in this repo. */
static const char *const ekw[] = {
    "AND", "ARRAY", "BUT", "CASE", "CHAR", "CONST", "DEC", "DEF",
    "DEFAULT", "DO", "ELSE", "ELSEIF", "EMPTY", "END", "ENDFOR",
    "ENDIF", "ENDLOOP", "ENDOBJECT", "ENDPROC", "ENDSELECT",
    "ENDWHILE", "ENUM", "EXCEPT", "EXIT", "EXPORT", "FALSE", "FOR",
    "HANDLE", "IF", "INC", "INT", "IS", "JUMP", "LIST", "LONG",
    "LOOP", "MODULE", "NEW", "NIL", "NOT", "OBJECT", "OF", "OPT",
    "OR", "PROC", "PTR", "RAISE", "REPEAT", "RETURN", "SELECT",
    "SELF", "SET", "SIZEOF", "STEP", "STRING", "SUPER", "THEN", "TO",
    "TRUE", "UNTIL", "VOID", "WHILE"
};
#define NEKW ((int)(sizeof(ekw) / sizeof(ekw[0])))

int lx_language(const char *name)
{
    int n = (int)strlen(name);
    if (n >= 2 && name[n - 2] == '.' &&
        (name[n - 1] == 'e' || name[n - 1] == 'E'))
        return LX_E;
    return LX_NONE;
}

static int isuc(char c) { return c >= 'A' && c <= 'Z'; }
static int isdig(char c) { return c >= '0' && c <= '9'; }
static int isidc(char c)
{
    return isuc(c) || isdig(c) || c == '_' ||
           (c >= 'a' && c <= 'z');
}

/* a whole word of capitals, matched against the table. Binary search
 * because the table is sorted and this runs per word per row. */
static int iskw(const char *s, int len)
{
    int lo = 0, hi = NEKW - 1;
    while (lo <= hi) {
        int mid = (lo + hi) / 2, c;
        const char *k = ekw[mid];
        int kl = (int)strlen(k);
        c = strncmp(s, k, len < kl ? len : kl);
        if (c == 0) c = len - kl;
        if (c == 0) return 1;
        if (c < 0) hi = mid - 1; else lo = mid + 1;
    }
    return 0;
}

/* open a span, unless the one we are in already has this class -
 * adjacent runs of the same colour would be two Text() calls where
 * one will do, and the row painter's cost is measured in those. */
static void push(LxRun *runs, int maxruns, int *nr, int start, int cls)
{
    if (*nr > 0 && runs[*nr - 1].cls == cls) return;
    if (*nr >= maxruns) return;
    if (*nr > 0 && runs[*nr - 1].start == start) {
        runs[*nr - 1].cls = cls;    /* empty span: just retype it */
        return;
    }
    runs[*nr].start = start;
    runs[*nr].cls = cls;
    (*nr)++;
}

unsigned char lx_line(int lang, unsigned char state,
                      const char *s, int n,
                      LxRun *runs, int maxruns, int *nruns)
{
    int i = 0, nr = 0;
    int depth = state > LX_STATE_MAX ? LX_STATE_MAX : state;

    *nruns = 0;
    if (maxruns < 1) return state;
    if (lang == LX_NONE) {
        runs[0].start = 0;
        runs[0].cls = LX_TEXT;
        *nruns = 1;
        return 0;
    }

    push(runs, maxruns, &nr, 0, depth ? LX_COMMENT : LX_TEXT);

    while (i < n) {
        char c = s[i];

        if (depth) {                    /* inside a block comment */
            if (c == '*' && i + 1 < n && s[i + 1] == '/') {
                depth--;
                i += 2;
                if (!depth) push(runs, maxruns, &nr, i, LX_TEXT);
                continue;
            }
            if (c == '/' && i + 1 < n && s[i + 1] == '*') {
                if (depth < LX_STATE_MAX) depth++;   /* E nests them */
                i += 2;
                continue;
            }
            i++;
            continue;
        }

        /* the arrow comment runs to the end of the line, and is the
         * E comment that matters: it is on nearly every line of the
         * corpus */
        if (c == '-' && i + 1 < n && s[i + 1] == '>') {
            push(runs, maxruns, &nr, i, LX_COMMENT);
            break;                              /* nothing after it */
        }

        if (c == '/' && i + 1 < n && s[i + 1] == '*') {
            push(runs, maxruns, &nr, i, LX_COMMENT);
            depth = 1;
            i += 2;
            continue;
        }

        if (c == '\'') {                        /* E strings */
            int j = i + 1;
            while (j < n) {
                if (s[j] == '\\' && j + 1 < n) { j += 2; continue; }
                if (s[j] == '\'') { j++; break; }
                j++;
            }
            push(runs, maxruns, &nr, i, LX_STRING);
            i = j;
            push(runs, maxruns, &nr, i, LX_TEXT);
            continue;
        }

        if (c == '"') {                         /* E's char/quoted */
            int j = i + 1;
            while (j < n) {
                if (s[j] == '\\' && j + 1 < n) { j += 2; continue; }
                if (s[j] == '"') { j++; break; }
                j++;
            }
            push(runs, maxruns, &nr, i, LX_STRING);
            i = j;
            push(runs, maxruns, &nr, i, LX_TEXT);
            continue;
        }

        /* $hex, %binary and plain decimal */
        if (isdig(c) || ((c == '$' || c == '%') && i + 1 < n &&
                         isidc(s[i + 1]))) {
            int j = i + 1;
            while (j < n && (isidc(s[j]))) j++;
            push(runs, maxruns, &nr, i, LX_NUMBER);
            i = j;
            push(runs, maxruns, &nr, i, LX_TEXT);
            continue;
        }

        /* a word. Only an all-capitals one can be a keyword, and the
         * span has to cover the WHOLE word - so `PROCESS` is not
         * PROC followed by ESS. */
        if (isidc(c)) {
            int j = i;
            int allcaps = 1;
            while (j < n && isidc(s[j])) {
                if (!isuc(s[j]) && !isdig(s[j]) && s[j] != '_')
                    allcaps = 0;
                j++;
            }
            if (allcaps && iskw(s + i, j - i)) {
                push(runs, maxruns, &nr, i, LX_KEYWORD);
                i = j;
                push(runs, maxruns, &nr, i, LX_TEXT);
            } else
                i = j;
            continue;
        }

        i++;
    }

    *nruns = nr ? nr : 1;
    if (!nr) { runs[0].start = 0; runs[0].cls = LX_TEXT; }
    return (unsigned char)depth;
}
