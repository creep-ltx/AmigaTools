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

int main(void)
{
    lineends();
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
