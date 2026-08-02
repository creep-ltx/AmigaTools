/* lextest - the lexer's harness. Host AND vamos, like edtest.
 *
 * Two halves. The first is the ordinary unit tests. The second runs
 * the lexer over the REAL E SOURCE in this repo - tens of thousands
 * of lines that were never written with a lexer in mind - and checks
 * the properties that must hold for any input: spans in order,
 * starting at 0, never past the end of the line, and the block
 * comment state closing by end of file. A lexer that only ever sees
 * its author's examples is a lexer that has not been tested.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "elex.h"

static int fails;

static void ck(int cond, const char *what)
{
    if (!cond) { fails++; printf("  FAIL: %s\n", what); }
}

#define MAXR 64
static LxRun runs[MAXR];
static int nr;

/* lex one line from a C string and return the ending state */
static unsigned char lex(unsigned char st, const char *s)
{
    return lx_line(LX_E, st, s, (int)strlen(s), runs, MAXR, &nr);
}

/* the class covering character `at` */
static int clsat(int at)
{
    int i, c = LX_TEXT;
    for (i = 0; i < nr; i++)
        if (runs[i].start <= at) c = runs[i].cls;
    return c;
}

static void language(void)
{
    ck(lx_language("cfile.e") == LX_E, ".e is E");
    ck(lx_language("CFILE.E") == LX_E, "and so is .E");
    ck(lx_language("cedit.c") == LX_NONE, ".c is not E yet");
    ck(lx_language("readme") == LX_NONE, "no extension, no language");
    ck(lx_language("e") == LX_NONE, "a bare 'e' is not an extension");
}

static void comments(void)
{
    lex(0, "x := 1  -> and the rest is comment");
    ck(clsat(0) == LX_TEXT, "code before the arrow is code");
    ck(clsat(8) == LX_COMMENT, "the arrow starts a comment");
    ck(clsat(30) == LX_COMMENT, "and it runs to the end of the line");

    /* an arrow inside a STRING is not a comment - the single most
     * common way a naive line lexer gets E wrong */
    lex(0, "s := '-> not a comment'");
    ck(clsat(6) == LX_STRING, "the string is a string");
    ck(clsat(9) == LX_STRING, "an arrow inside it is still string");

    ck(lex(0, "/* opens") == 1, "an unclosed block comment carries");
    ck(clsat(0) == LX_COMMENT, "and colours from where it opened");
    ck(lex(1, "still inside") == 1, "a carried comment continues");
    ck(clsat(0) == LX_COMMENT, "and the whole line is comment");
    ck(lex(1, "closes */ code") == 0, "and closes");
    ck(clsat(0) == LX_COMMENT, "the closing part is still comment");
    ck(clsat(11) == LX_TEXT, "code after it is code again");

    /* E nests block comments - one level of closing is not enough */
    ck(lex(0, "/* outer /* inner") == 2, "nesting counts up");
    ck(lex(2, "*/ still inside") == 1, "one close leaves one open");
    ck(clsat(4) == LX_COMMENT, "and the text is still comment");
    ck(lex(1, "*/ out") == 0, "the second close ends it");

    ck(lex(0, "a /* b */ c /* d */ e") == 0,
       "two complete blocks on one line close");
    ck(clsat(0) == LX_TEXT, "code between them is code");
    ck(clsat(10) == LX_TEXT, "and after the first block too");
}

static void strings(void)
{
    lex(0, "x := 'hello'");
    ck(clsat(5) == LX_STRING, "a quoted string");
    ck(clsat(11) == LX_STRING, "including its closing quote");

    lex(0, "x := 'a\\'b' + y");
    ck(clsat(6) == LX_STRING, "an escaped quote stays inside");
    ck(clsat(12) == LX_TEXT, "and the string still ends");

    /* an unterminated string must NOT leak into the next line: E
     * strings do not span lines, and a lexer that lets one do so
     * paints the whole rest of the file */
    ck(lex(0, "x := 'oops") == 0, "an unterminated string ends at EOL");
}

static void keywords(void)
{
    lex(0, "PROC main()");
    ck(clsat(0) == LX_KEYWORD, "PROC is a keyword");
    ck(clsat(5) == LX_TEXT, "the name after it is not");

    lex(0, "IF x THEN y");
    ck(clsat(0) == LX_KEYWORD, "IF");
    ck(clsat(5) == LX_KEYWORD, "THEN");
    ck(clsat(3) == LX_TEXT, "and the variable between them is not");

    /* whole words only */
    lex(0, "PROCESS := 1");
    ck(clsat(0) == LX_TEXT, "PROCESS is not PROC");
    lex(0, "myIF := 1");
    ck(clsat(0) == LX_TEXT, "myIF is not IF");

    /* lowercase is not a keyword: E is case sensitive, and a field
     * called `list` or a variable called `to` is very common */
    lex(0, "to := list");
    ck(clsat(0) == LX_TEXT, "lowercase 'to' is not TO");
    ck(clsat(6) == LX_TEXT, "lowercase 'list' is not LIST");
}

static void numbers(void)
{
    lex(0, "x := 42");
    ck(clsat(5) == LX_NUMBER, "a decimal number");
    lex(0, "x := $E310");
    ck(clsat(5) == LX_NUMBER, "a hex number");
    lex(0, "x := %1010");
    ck(clsat(5) == LX_NUMBER, "a binary number");
    lex(0, "abc123 := 1");
    ck(clsat(0) == LX_TEXT, "digits inside a name are not a number");
}

static void shapes(void)
{
    int i;
    lex(0, "PROC f()  -> c");
    ck(nr >= 1, "at least one span");
    ck(runs[0].start == 0, "the first span starts at 0");
    for (i = 1; i < nr; i++)
        ck(runs[i].start > runs[i - 1].start, "spans strictly ascend");
    for (i = 1; i < nr; i++)
        ck(runs[i].cls != runs[i - 1].cls,
           "adjacent spans never share a class");

    /* an empty line is one span, not zero */
    lex(0, "");
    ck(nr == 1, "an empty line is one span");

    /* plain text mode never splits */
    lx_line(LX_NONE, 0, "PROC x -> y", 11, runs, MAXR, &nr);
    ck(nr == 1 && runs[0].cls == LX_TEXT, "LX_NONE is one plain span");
}

/* ---- the corpus ---------------------------------------------------
 * Run over real E source and assert the invariants. Any file that is
 * missing is skipped rather than failed - the harness has to run from
 * a release tarball too. */
static int corpus(const char *path)
{
    FILE *f = fopen(path, "rb");
    char line[4096];
    unsigned char st = 0;
    long nlines = 0;
    int i, bad = 0;
    if (f == NULL) return 0;
    while (fgets(line, sizeof(line), f)) {
        int n = (int)strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) n--;
        st = lx_line(LX_E, st, line, n, runs, MAXR, &nr);
        nlines++;
        if (nr < 1) { bad++; continue; }
        if (runs[0].start != 0) bad++;
        for (i = 0; i < nr; i++) {
            if (runs[i].start < 0 || runs[i].start > n) bad++;
            if (runs[i].cls >= LX_NCLASS) bad++;
            if (i && runs[i].start <= runs[i - 1].start) bad++;
        }
        if (st > LX_STATE_MAX) bad++;
    }
    fclose(f);
    printf("  %s: %ld lines, end state %d\n", path, nlines, st);
    ck(bad == 0, "corpus spans are well formed");
    /* every one of these files compiles, so every block comment in
     * it is closed - the state MUST come back to 0 */
    ck(st == 0, "corpus ends with no comment left open");
    return 1;
}

int main(void)
{
    int ran = 0;
    language();
    comments();
    strings();
    keywords();
    numbers();
    shapes();

    ran += corpus("../cfile/cfile.e");
    ran += corpus("../ccon/ccon-handler.e");
    ran += corpus("../cfile13/cfile13.e");
    ran += corpus("../cmenu/cmenu.e");
    if (!ran) printf("  (no corpus files found - skipped)\n");

    if (fails) {
        printf("lextest: %d FAILURES\n", fails);
        return 1;
    }
    printf("lextest: ALL GREEN\n");
    return 0;
}
