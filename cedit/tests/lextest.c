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
    ck(lx_language("readme") == LX_NONE, "no extension, no language");
    ck(lx_language("e") == LX_NONE, "a bare 'e' is not an extension");
    /* b9 */
    ck(lx_language("cedit.c") == LX_C,   ".c is C");
    ck(lx_language("elex.h") == LX_C,    ".h is C");
    ck(lx_language("MAIN.C") == LX_C,    "and case does not matter");
    ck(lx_language("boot.s") == LX_ASM,  ".s is assembly");
    ck(lx_language("boot.asm") == LX_ASM, ".asm too");
    ck(lx_language("exec.i") == LX_ASM,  ".i is an Amiga asm include");
    ck(lx_language("notes.txt") == LX_NONE, ".txt is plain text");
}

/* ---- b9: the tables themselves -----------------------------------
 * A binary search over an unsorted table does not fail loudly, it
 * just misses keywords - so the sortedness is asserted rather than
 * intended. 150 hand-written mnemonics will not stay in order on
 * their own. */
static int foldcmp(const char *a, const char *b, int fold)
{
    int i = 0;
    for (;;) {
        int ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (fold) {
            if (ca >= 'A' && ca <= 'Z') ca += 32;
            if (cb >= 'A' && cb <= 'Z') cb += 32;
        }
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
        i++;
    }
}

static void tables(void)
{
    int lang;
    for (lang = LX_E; lang < LX_NLANG; lang++) {
        const LxLang *L = lx_table(lang);
        int i, ok = 1, dup = 0;
        int fold = (L->kwcase == LXK_FOLD);
        ck(L != 0 && L->nkw > 0, "the table has keywords");
        for (i = 1; i < L->nkw; i++) {
            int c = foldcmp(L->kw[i - 1], L->kw[i], fold);
            if (c > 0) ok = 0;
            if (c == 0) dup = 1;
        }
        if (!ok) printf("  (%s keyword table is NOT sorted)\n", L->name);
        if (dup) printf("  (%s keyword table has a duplicate)\n", L->name);
        ck(ok, "keyword table is sorted");
        ck(!dup, "keyword table has no duplicates");
        /* and every word in it is actually found by the search that
         * will look for it - the sortedness check above is necessary
         * but this is the one that matters */
        for (i = 0; i < L->nkw; i++) {
            LxRun r[8];
            int n2;
            char buf[64];
            int kl = (int)strlen(L->kw[i]);
            if (kl > 60) continue;
            memcpy(buf, L->kw[i], kl);
            buf[kl] = 0;
            lx_line(lang, 0, buf, kl, r, 8, &n2);
            if (!(n2 >= 1 && r[0].cls == LX_KEYWORD)) {
                printf("  (%s: keyword \"%s\" is not found)\n",
                       L->name, buf);
                ck(0, "every keyword in the table is reachable");
                break;
            }
        }
    }
}

/* lex one line in a given language */
static unsigned char lexl(int lang, unsigned char st, const char *s)
{
    return lx_line(lang, st, s, (int)strlen(s), runs, MAXR, &nr);
}

static void clang(void)
{
    lexl(LX_C, 0, "int x = 1; // trailing");
    ck(clsat(0) == LX_KEYWORD, "int is a C keyword");
    ck(clsat(4) == LX_TEXT, "the name is not");
    ck(clsat(8) == LX_NUMBER, "the literal is a number");
    ck(clsat(12) == LX_COMMENT, "// starts a comment");
    ck(clsat(20) == LX_COMMENT, "running to end of line");

    /* C block comments do NOT nest - the inner opener is just text
     * inside the comment, and ONE close ends the whole thing */
    ck(lexl(LX_C, 0, "/* outer /* inner") == 1, "C blocks do not nest");
    ck(lexl(LX_C, 1, "*/ code") == 0, "and one close ends it");
    ck(clsat(3) == LX_TEXT, "code after the close is code");

    /* case matters, and whole words only */
    lexl(LX_C, 0, "INT x;");
    ck(clsat(0) == LX_TEXT, "INT is not int - C is case sensitive");
    lexl(LX_C, 0, "integer = 1;");
    ck(clsat(0) == LX_TEXT, "integer is not int");
    lexl(LX_C, 0, "myint = 1;");
    ck(clsat(0) == LX_TEXT, "myint is not int");

    /* the preprocessor, but only where it starts the line */
    lexl(LX_C, 0, "#include <stdio.h>");
    ck(clsat(0) == LX_KEYWORD, "a leading # is a directive");
    ck(clsat(9) == LX_TEXT, "what follows it is not");
    lexl(LX_C, 0, "  #define X 1");
    ck(clsat(2) == LX_KEYWORD, "indented directives count too");
    lexl(LX_C, 0, "x = a #b;");
    ck(clsat(6) == LX_TEXT, "a # in mid-line is not a directive");

    /* $ and % are NOT number prefixes in C */
    lexl(LX_C, 0, "x = a % b;");
    ck(clsat(6) == LX_TEXT, "% is modulo in C, not a binary literal");

    /* strings and char literals, and a // inside one */
    lexl(LX_C, 0, "s = \"a // b\"; c = 'x';");
    ck(clsat(5) == LX_STRING, "a C string");
    ck(clsat(7) == LX_STRING, "a // inside it is not a comment");
    ck(clsat(18) == LX_STRING, "a char literal is a string too");
    ck(lexl(LX_C, 0, "s = \"unterminated") == 0,
       "an unterminated C string still ends at EOL");
}

static void asmlang(void)
{
    lexl(LX_ASM, 0, "        move.l  d0,d1   ; comment");
    ck(clsat(8) == LX_KEYWORD, "move is a mnemonic");
    ck(clsat(24) == LX_COMMENT, "; starts a comment");

    /* case does not matter in assembly */
    lexl(LX_ASM, 0, "        MOVE.L  d0,d1");
    ck(clsat(8) == LX_KEYWORD, "MOVE is the same mnemonic");
    lexl(LX_ASM, 0, "        Move.l  d0,d1");
    ck(clsat(8) == LX_KEYWORD, "and so is Move");

    /* the size suffix is not part of the word - the identifier scan
     * stops at the dot, so move.l still matches move */
    lexl(LX_ASM, 0, "  moveq #1,d0");
    ck(clsat(2) == LX_KEYWORD, "moveq without a suffix");

    /* a star in COLUMN 0 is the old comment convention; anywhere
     * else it is a multiply */
    lexl(LX_ASM, 0, "* a whole-line comment");
    ck(clsat(0) == LX_COMMENT, "a star in column 0 comments the line");
    ck(clsat(15) == LX_COMMENT, "all of it");
    lexl(LX_ASM, 0, "        move.l  #2*4,d0");
    ck(clsat(18) == LX_TEXT, "a star mid-line is not a comment");

    /* numbers in every base an assembler uses */
    lexl(LX_ASM, 0, "        move.l  #$DFF000,a0");
    ck(clsat(17) == LX_NUMBER, "$hex");
    lexl(LX_ASM, 0, "        move.b  #%1010,d0");
    ck(clsat(17) == LX_NUMBER, "%binary");
    lexl(LX_ASM, 0, "        move.b  #@777,d0");
    ck(clsat(17) == LX_NUMBER, "@octal");

    /* labels are not mnemonics */
    lexl(LX_ASM, 0, "loop:   dbra    d0,loop");
    ck(clsat(0) == LX_TEXT, "a label is not a keyword");
    ck(clsat(8) == LX_KEYWORD, "but dbra is");

    /* no block comments in assembly: a slash-star is just text */
    ck(lexl(LX_ASM, 0, "        move.l  d0,d1  /* not a comment") == 0,
       "assembly has no block comments to leave open");
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

/* b9: the same invariants over real C - this editor's own source,
 * which nobody wrote with a lexer in mind either. Every one of these
 * files compiles, so the block-comment state must close at 0. */
static int ccorpus(const char *path)
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
        st = lx_line(LX_C, st, line, n, runs, MAXR, &nr);
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
    printf("  %s: %ld lines, end state %d (C)\n", path, nlines, st);
    ck(bad == 0, "C corpus spans are well formed");
    ck(st == 0, "C corpus ends with no comment left open");
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
    tables();
    clang();
    asmlang();

    ran += corpus("../cfile/cfile.e");
    ran += corpus("../ccon/ccon-handler.e");
    ran += corpus("../cfile13/cfile13.e");
    ran += corpus("../cmenu/cmenu.e");
    /* and the C the editor itself is written in */
    ran += ccorpus("cedit.c");
    ran += ccorpus("edbuf.c");
    ran += ccorpus("elex.c");
    ran += ccorpus("../cdiff/cdiff.c");
    ran += ccorpus("../cdiff/diff.c");
    ran += ccorpus("../ltxgui/ltxwin.c");
    if (!ran) printf("  (no corpus files found - skipped)\n");

    if (fails) {
        printf("lextest: %d FAILURES\n", fails);
        return 1;
    }
    printf("lextest: ALL GREEN\n");
    return 0;
}
