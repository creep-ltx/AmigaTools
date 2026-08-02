/* edtest - edbuf's harness. Runs on the HOST and under vamos, and
 * both are run before anything is deployed, because cdiff's b100
 * found a gcc -O2 miscompilation on m68k that was invisible to a
 * host-only test and silent at -Wall.
 *
 * A test that passes with the feature disabled tests nothing, so the
 * tamper control at the bottom deliberately breaks a rule and
 * asserts the suite NOTICES.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "edbuf.h"

static int fails;
static int quiet;

static void ck(int cond, const char *what)
{
    if (!cond) {
        fails++;
        if (!quiet) printf("  FAIL: %s\n", what);
    }
}

/* split `src` and check the lines come out exactly as `want[]` */
static void cksplit(const char *name, const char *src, long len,
                    const char *const *want, int nwant)
{
    Buffer b;
    int i, ok;
    bufinit(&b);
    ok = bufsplit(&b, src, len);
    ck(ok, name);
    ck(b.n == nwant, name);
    if (b.n == nwant) {
        for (i = 0; i < nwant; i++) {
            ck((int)strlen(want[i]) == b.len[i], name);
            ck(b.len[i] == (int)strlen(b.ln[i]), name);  /* NUL right */
            ck(!strcmp(b.ln[i], want[i]), name);
        }
    } else if (!quiet)
        printf("  (%s: got %d lines, wanted %d)\n", name, b.n, nwant);
    buffree(&b);
}

static void lineends(void)
{
    static const char *w3[] = { "a", "b", "c" };
    static const char *w1[] = { "only" };
    static const char *w0[] = { "" };
    static const char *wblank[] = { "a", "", "b" };

    cksplit("lf",      "a\nb\nc\n", 6, w3, 3);
    cksplit("lf-noeol","a\nb\nc",   5, w3, 3);
    cksplit("cr",      "a\rb\rc\r", 6, w3, 3);
    cksplit("crlf",    "a\r\nb\r\nc\r\n", 9, w3, 3);
    cksplit("crlf-noeol", "a\r\nb\r\nc", 7, w3, 3);
    cksplit("noeol-single", "only", 4, w1, 1);
    /* an EMPTY file must still give one empty line - a buffer with no
     * lines has no cursor position to be in */
    cksplit("empty", "", 0, w0, 1);
    /* a lone newline is one empty line, not zero and not two */
    cksplit("just-newline", "\n", 1, w0, 1);
    cksplit("blank-in-middle", "a\n\nb\n", 5, wblank, 3);
}

/* the table has to survive well past its first doubling, and the
 * per-line buffers well past theirs - CFile's editor carried an
 * 8192-line cap and a 200-char line cap until both were grown away,
 * and this is the test that says they are really gone */
static void growth(void)
{
    Buffer b;
    char big[5000];
    int i, ok = 1;
    bufinit(&b);
    for (i = 0; i < 5000; i++) {
        char s[32];
        sprintf(s, "line %d", i);
        if (!addline(&b, s, strlen(s))) { ok = 0; break; }
    }
    ck(ok, "5000 lines added");
    ck(b.n == 5000, "5000 lines counted");
    if (b.n == 5000) {
        ck(!strcmp(b.ln[0], "line 0"), "first line intact after growth");
        ck(!strcmp(b.ln[4999], "line 4999"), "last line intact");
        ck(!strcmp(b.ln[2500], "line 2500"), "middle line intact");
    }
    buffree(&b);

    memset(big, 'x', sizeof(big));
    bufinit(&b);
    ck(addline(&b, big, sizeof(big)), "4999-char line added");
    ck(b.n == 1, "one long line");
    ck(b.len[0] == (int)sizeof(big), "long line length");
    ck(b.ln[0][sizeof(big)] == 0, "long line terminated");
    ck((int)strlen(b.ln[0]) == (int)sizeof(big), "long line NUL right");
    buffree(&b);
}

/* freeing must leave a buffer that can be used again immediately -
 * loadbuf calls buffree on every open */
static void reuse(void)
{
    Buffer b;
    static const char *w[] = { "second" };
    bufinit(&b);
    ck(bufsplit(&b, "first\n", 6), "first load");
    buffree(&b);
    ck(b.n == 0 && b.tab == 0 && b.ln == NULL, "freed clean");
    ck(bufsplit(&b, "second\n", 7), "reload after free");
    ck(b.n == 1 && !strcmp(b.ln[0], "second"), "reloaded content");
    (void)w;
    buffree(&b);
}

static void widths(void)
{
    Buffer b;
    /* tab stops are ABSOLUTE, so a tab's width depends on where it
     * starts - the thing every naive implementation gets wrong */
    ck(explen("\t", 1, 8, 7) == 8, "tab at column 0 -> 8");
    ck(explen("a\t", 2, 8, 7) == 8, "one char then tab -> 8");
    ck(explen("1234567\t", 8, 8, 7) == 8, "seven then tab -> 8");
    ck(explen("12345678\t", 9, 8, 7) == 16, "eight then tab -> 16");
    ck(explen("ab", 2, 8, 7) == 2, "plain text");
    /* a non-power-of-two size takes the modulo road; same answers */
    ck(explen("\t", 1, 5, 0) == 5, "tab 5 at column 0");
    ck(explen("abc\t", 4, 5, 0) == 5, "tab 5 from column 3");
    ck(explen("abcde\t", 6, 5, 0) == 10, "tab 5 from column 5");

    bufinit(&b);
    addline(&b, "ab", 2);
    addline(&b, "abcdefgh", 8);
    addline(&b, "abc", 3);
    ck(bufmaxw(&b, 8, 7) == 8, "maxw picks the widest");
    ck(bufmaxw(&b, 8, 7) == 8, "maxw cached answer agrees");
    addline(&b, "abcdefghijkl", 12);
    ck(bufmaxw(&b, 8, 7) == 12, "maxw re-measures after a new line");
    buffree(&b);
}

/* the file's line-ending style has to survive a round trip, or the
 * first save of a CRLF file makes every line look changed to cdiff */
static void eolstyle(void)
{
    Buffer b;
    bufinit(&b);
    bufsplit(&b, "a\nb\n", 4);
    ck(b.eol == EOL_LF && !b.noeol, "LF detected, terminated");
    buffree(&b);
    bufinit(&b);
    bufsplit(&b, "a\r\nb\r\n", 6);
    ck(b.eol == EOL_CRLF && !b.noeol, "CRLF detected");
    buffree(&b);
    bufinit(&b);
    bufsplit(&b, "a\rb\r", 4);
    ck(b.eol == EOL_CR && !b.noeol, "CR detected");
    buffree(&b);
    bufinit(&b);
    bufsplit(&b, "a\nb", 3);
    ck(b.eol == EOL_LF && b.noeol, "missing final newline noticed");
    buffree(&b);
    bufinit(&b);
    bufsplit(&b, "", 0);
    ck(b.noeol, "an empty file's synthetic line carries no terminator");
    buffree(&b);
}

/* every edit is checked on the LENGTH, the NUL and the text, because
 * a memmove that forgets the terminator leaves a buffer that renders
 * fine and saves garbage */
static void edits(void)
{
    Buffer b;
    int i;
    bufinit(&b);
    bufsplit(&b, "hello\n", 6);

    ck(edinsch(&b, 0, 5, '!'), "append a char");
    ck(!strcmp(b.ln[0], "hello!"), "appended text");
    ck(b.len[0] == 6 && strlen(b.ln[0]) == 6, "appended length+NUL");
    ck(b.dirty, "an edit sets dirty");

    ck(edinsch(&b, 0, 0, '>'), "insert at column 0");
    ck(!strcmp(b.ln[0], ">hello!"), "inserted at head");
    ck(b.len[0] == 7 && strlen(b.ln[0]) == 7, "head length+NUL");

    ck(edinsch(&b, 0, 3, '-'), "insert in the middle");
    ck(!strcmp(b.ln[0], ">he-llo!"), "inserted mid");

    eddelch(&b, 0, 3);
    ck(!strcmp(b.ln[0], ">hello!"), "delete mid");
    eddelch(&b, 0, 0);
    ck(!strcmp(b.ln[0], "hello!"), "delete at head");
    eddelch(&b, 0, 5);
    ck(!strcmp(b.ln[0], "hello"), "delete last char");
    ck(b.len[0] == 5 && strlen(b.ln[0]) == 5, "delete length+NUL");
    eddelch(&b, 0, 5);                  /* past the end: a no-op */
    ck(b.len[0] == 5, "delete past end does nothing");

    /* growth across the per-line doubling boundary, one char at a
     * time - the path a real typing session takes */
    for (i = 0; i < 400; i++)
        if (!edinsch(&b, 0, b.len[0], 'x')) { ck(0, "typing 400"); break; }
    ck(b.len[0] == 405, "405 chars after typing");
    ck((int)strlen(b.ln[0]) == 405, "typed line NUL right");
    buffree(&b);
}

static void splitjoin(void)
{
    Buffer b;
    bufinit(&b);
    bufsplit(&b, "onetwo\nlast\n", 12);
    ck(b.n == 2, "two lines to start");

    ck(edsplitline(&b, 0, 3), "split mid-line");
    ck(b.n == 3, "split makes three lines");
    ck(!strcmp(b.ln[0], "one"), "head after split");
    ck(!strcmp(b.ln[1], "two"), "tail after split");
    ck(!strcmp(b.ln[2], "last"), "line below survived the shift");
    ck(b.len[0] == 3 && b.len[1] == 3, "split lengths");
    ck((int)strlen(b.ln[0]) == 3 && (int)strlen(b.ln[1]) == 3,
       "split NULs");

    ck(edjoinline(&b, 0), "join them back");
    ck(b.n == 2, "join removes a line");
    ck(!strcmp(b.ln[0], "onetwo"), "joined text");
    ck(b.len[0] == 6 && (int)strlen(b.ln[0]) == 6, "joined length+NUL");
    ck(!strcmp(b.ln[1], "last"), "line below survived the join");

    /* Return at the very end of a line, and at the very start */
    ck(edsplitline(&b, 0, 6), "split at end of line");
    ck(b.n == 3 && b.len[1] == 0, "empty line created below");
    ck(edjoinline(&b, 0), "undo it by joining");
    ck(edsplitline(&b, 0, 0), "split at column 0");
    ck(b.n == 3 && b.len[0] == 0, "empty line created above");
    ck(!strcmp(b.ln[1], "onetwo"), "text pushed down intact");

    /* joining the LAST line is a no-op, not a crash or a failure */
    ck(edjoinline(&b, b.n - 1), "join at last line is a no-op");
    ck(b.n == 3, "no-op join changed nothing");
    buffree(&b);
}

/* a split/join pair must leave maxw honest, or the horizontal
 * scroller measures against a width the text no longer has */
static void widthafteredit(void)
{
    Buffer b;
    bufinit(&b);
    bufsplit(&b, "short\nlongestlinehere\n", 22);
    ck(bufmaxw(&b, 8, 7) == 15, "maxw before");
    edsplitline(&b, 1, 7);
    ck(bufmaxw(&b, 8, 7) == 8, "maxw after a split shrinks");
    edjoinline(&b, 1);
    ck(bufmaxw(&b, 8, 7) == 15, "maxw after a join grows back");
    eddelch(&b, 1, 0);
    ck(bufmaxw(&b, 8, 7) == 14, "maxw after a delete");
    edinsch(&b, 1, 0, 'X');
    ck(bufmaxw(&b, 8, 7) == 15, "maxw after an insert");
    buffree(&b);
}

/* a save must reproduce the file it read, byte for byte, when
 * nothing was edited. Anything less and cdiff would show every line
 * of a CRLF file as changed the first time cedit touched it. */
static void roundtrip(const char *name, const char *src, long len)
{
    Buffer b;
    char *out;
    long n;
    bufinit(&b);
    ck(bufsplit(&b, src, len), name);
    n = bufbytes(&b);
    ck(n == len, name);
    out = malloc(n + 1);
    if (out) {
        long w = bufserialize(&b, out);
        ck(w == n, name);
        ck(w == len && !memcmp(out, src, len), name);
        if (!quiet && (w != len || memcmp(out, src, len)))
            printf("  (%s: wrote %ld of %ld)\n", name, w, len);
        free(out);
    }
    buffree(&b);
}

static void saving(void)
{
    Buffer b;
    char out[64];
    long n;

    roundtrip("save lf",        "a\nb\nc\n", 6);
    roundtrip("save crlf",      "a\r\nb\r\nc\r\n", 9);
    roundtrip("save cr",        "a\rb\rc\r", 6);
    roundtrip("save noeol",     "a\nb", 3);
    roundtrip("save crlf noeol","a\r\nb", 4);
    roundtrip("save blank line","a\n\nb\n", 5);
    roundtrip("save one line",  "only\n", 5);
    roundtrip("save no newline at all", "only", 4);

    /* an edited buffer serializes the NEW text in the OLD endings */
    bufinit(&b);
    bufsplit(&b, "a\r\nb\r\n", 6);
    edinsch(&b, 0, 1, 'X');
    n = bufserialize(&b, out);
    ck(n == 7 && !memcmp(out, "aX\r\nb\r\n", 7),
       "edited CRLF buffer keeps CRLF");
    buffree(&b);

    /* a split adds exactly one line ending, not two and not zero */
    bufinit(&b);
    bufsplit(&b, "ab\n", 3);
    edsplitline(&b, 0, 1);
    n = bufserialize(&b, out);
    ck(n == 4 && !memcmp(out, "a\nb\n", 4), "split adds one ending");
    buffree(&b);

    /* splitting a no-final-newline file keeps the last line bare */
    bufinit(&b);
    bufsplit(&b, "ab", 2);
    edsplitline(&b, 0, 1);
    n = bufserialize(&b, out);
    ck(n == 3 && !memcmp(out, "a\nb", 3), "noeol survives a split");
    buffree(&b);

    /* opening an empty file and saving it must leave it EMPTY */
    bufinit(&b);
    bufsplit(&b, "", 0);
    ck(bufbytes(&b) == 0, "empty document saves as zero bytes");
    ck(bufserialize(&b, out) == 0, "and writes nothing");
    buffree(&b);
    roundtrip("save empty", "", 0);
}

int main(void)
{
    lineends();
    saving();
    eolstyle();
    edits();
    splitjoin();
    widthafteredit();
    growth();
    reuse();
    widths();

    if (fails) {
        printf("edtest: %d FAILURES\n", fails);
        return 1;
    }
    /* tamper control: a suite that cannot fail proves nothing. Feed
     * it a deliberately wrong expectation and require a failure. */
    {
        static const char *wrong[] = { "a", "b" };
        int before;
        quiet = 1;
        before = fails;
        cksplit("tamper", "a\nb\nc\n", 6, wrong, 2);
        quiet = 0;
        if (fails == before) {
            printf("edtest: TAMPER CONTROL DID NOT FIRE\n");
            return 1;
        }
        fails = before;
    }
    printf("edtest: ALL GREEN\n");
    return 0;
}
