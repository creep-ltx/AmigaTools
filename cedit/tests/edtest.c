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

/* type a string one character at a time, the way a user does */
static void typerun(Buffer *b, int y, int x, const char *t)
{
    int i;
    for (i = 0; t[i]; i++) edinsch(b, y, x + i, t[i]);
}

static void undoing(void)
{
    Buffer b;
    int st, line;

    /* a typing RUN is one undo, not one per letter */
    bufinit(&b);
    bufsplit(&b, "hello\n", 6);
    ck(!ed_canundo(&b), "a fresh buffer has nothing to undo");
    ck(!b.dirty, "a fresh buffer is clean");
    typerun(&b, 0, 5, " world");
    ck(!strcmp(b.ln[0], "hello world"), "typed");
    ck(b.dirty, "typing dirties");
    ck(ed_canundo(&b), "and can be undone");
    line = ed_undo(&b, &st);
    ck(line == 0 && !st, "undo reports its line, not structural");
    ck(!strcmp(b.ln[0], "hello"), "ONE undo took back the whole run");
    ck(!b.dirty, "undone back to the saved state is clean again");
    ck(!ed_canundo(&b), "and there is nothing left to undo");

    /* and redo puts it back, character for character */
    ck(ed_canredo(&b), "redo is available");
    ed_redo(&b, &st);
    ck(!strcmp(b.ln[0], "hello world"), "redo restored the run");
    ck(b.dirty, "redone away from the saved state is dirty");
    buffree(&b);

    /* ed_break splits a run in two */
    bufinit(&b);
    bufsplit(&b, "", 0);
    typerun(&b, 0, 0, "abc");
    ed_break(&b);
    typerun(&b, 0, 3, "def");
    ed_undo(&b, &st);
    ck(!strcmp(b.ln[0], "abc"), "break ends a run");
    ed_undo(&b, &st);
    ck(!strcmp(b.ln[0], ""), "and the first run undoes separately");
    buffree(&b);

    /* a run only continues where the last character ENDED */
    bufinit(&b);
    bufsplit(&b, "", 0);
    typerun(&b, 0, 0, "ab");
    edinsch(&b, 0, 0, 'X');     /* back at the head: a new run */
    ck(!strcmp(b.ln[0], "Xab"), "inserted at the head");
    ed_undo(&b, &st);
    ck(!strcmp(b.ln[0], "ab"), "only the head insert came back out");
    buffree(&b);

    /* Backspace walks left; Del stays put. Both coalesce, and both
     * must restore the text in the RIGHT ORDER. */
    bufinit(&b);
    bufsplit(&b, "abcdef\n", 7);
    eddelch(&b, 0, 5);
    eddelch(&b, 0, 4);
    eddelch(&b, 0, 3);          /* backspacing f, e, d */
    ck(!strcmp(b.ln[0], "abc"), "backspaced to abc");
    ed_undo(&b, &st);
    ck(!strcmp(b.ln[0], "abcdef"), "one undo restored def in order");
    buffree(&b);

    bufinit(&b);
    bufsplit(&b, "abcdef\n", 7);
    eddelch(&b, 0, 0);
    eddelch(&b, 0, 0);
    eddelch(&b, 0, 0);          /* Del at the head, three times */
    ck(!strcmp(b.ln[0], "def"), "deleted to def");
    ed_undo(&b, &st);
    ck(!strcmp(b.ln[0], "abcdef"), "one undo restored abc in order");
    buffree(&b);

    /* structural edits report themselves as such */
    bufinit(&b);
    bufsplit(&b, "onetwo\n", 7);
    edsplitline(&b, 0, 3);
    ck(b.n == 2, "split happened");
    line = ed_undo(&b, &st);
    ck(st, "undoing a split is structural");
    ck(b.n == 1 && !strcmp(b.ln[0], "onetwo"), "split undone");
    ed_redo(&b, &st);
    ck(st && b.n == 2, "and redone");
    ck(!strcmp(b.ln[0], "one") && !strcmp(b.ln[1], "two"),
       "redone split is the same split");
    buffree(&b);

    /* a join of two REAL lines, undone - the seam has to come back
     * exactly where it was, not at the end of the joined text */
    bufinit(&b);
    bufsplit(&b, "one\ntwo\n", 8);
    edjoinline(&b, 0);
    ck(b.n == 1 && !strcmp(b.ln[0], "onetwo"), "joined");
    ed_undo(&b, &st);
    ck(st && b.n == 2 && !strcmp(b.ln[0], "one") &&
       !strcmp(b.ln[1], "two"), "join undone at the right seam");
    ed_redo(&b, &st);
    ck(st && b.n == 1 && !strcmp(b.ln[0], "onetwo"), "join redone");
    buffree(&b);
    (void)line;

    /* a new edit throws the redo future away */
    bufinit(&b);
    bufsplit(&b, "", 0);
    typerun(&b, 0, 0, "abc");
    ed_undo(&b, &st);
    ck(ed_canredo(&b), "redo available before the new edit");
    typerun(&b, 0, 0, "z");
    ck(!ed_canredo(&b), "a new edit discards the redo future");
    ck(!strcmp(b.ln[0], "z"), "and the new edit stands");
    buffree(&b);

    /* the save point moves, and dirty follows it in both directions */
    bufinit(&b);
    bufsplit(&b, "a\n", 2);
    typerun(&b, 0, 1, "bc");
    ck(b.dirty, "dirty after typing");
    ed_marksaved(&b);
    ck(!b.dirty, "clean at the new save point");
    ed_undo(&b, &st);
    ck(b.dirty, "undoing AWAY from the save point dirties again");
    ed_redo(&b, &st);
    ck(!b.dirty, "and redoing back to it is clean");
    buffree(&b);

    /* undo past the beginning, redo past the end: no-ops, not
     * crashes, and they say so */
    bufinit(&b);
    bufsplit(&b, "x\n", 2);
    ck(ed_undo(&b, &st) == -1, "undo with nothing to undo");
    ck(ed_redo(&b, &st) == -1, "redo with nothing to redo");
    ck(!strcmp(b.ln[0], "x"), "and the buffer is untouched");
    buffree(&b);

    /* loading a file is not an edit */
    bufinit(&b);
    bufsplit(&b, "one\ntwo\n", 8);
    ck(!ed_canundo(&b), "a load leaves nothing on the undo stack");
    ck(!b.dirty, "and leaves the buffer clean");
    buffree(&b);

    /* the stack is bounded, and the oldest records fall off rather
     * than the newest being refused */
    bufinit(&b);
    bufsplit(&b, "", 0);
    {
        int i;
        for (i = 0; i < UNDO_MAX + 50; i++) {
            edinsch(&b, 0, 0, 'x');
            ed_break(&b);       /* one record each, no coalescing */
        }
        ck(b.nur <= UNDO_MAX, "the undo stack is bounded");
        ck(ed_canundo(&b), "and the newest edits are still undoable");
        ed_undo(&b, &st);
        ck(b.len[0] == UNDO_MAX + 49, "the last edit undid");
    }
    buffree(&b);
}

/* select from (ay,ax) to (cy,cx) the way a drag does */
static void sel(Buffer *b, int ay, int ax, int cy, int cx)
{
    b->cy = ay; b->cx = ax;
    ed_selstart(b);
    b->cy = cy; b->cx = cx;
}

/* ---- b7: search, replace, auto-indent ---------------------------- */

/* one find, spelled out, so a failure names the case */
static void ckfind(const char *what, Buffer *b, const char *pat,
                   int fy0, int fx0, int dir, int fold, int wrap,
                   int wanty, int wantx)
{
    int fy = -1, fx = -1;
    int got = ed_search(b, pat, fy0, fx0, dir, fold, wrap, 0, &fy, &fx);
    if (wanty < 0) {
        ck(!got, what);                 /* expected NOT to be found */
        return;
    }
    ck(got && fy == wanty && fx == wantx, what);
    if (!quiet && got && (fy != wanty || fx != wantx))
        printf("  (%s: got %d,%d wanted %d,%d)\n", what, fy, fx,
               wanty, wantx);
}

static void searching(void)
{
    Buffer b;

    bufinit(&b);
    /*        0123456789 */
    bufsplit(&b, "alpha beta\nbeta gamma\nBETA delta\n", 33);

    /* forward starts AT the position given, so a match already under
     * the cursor is found again - that is what makes a fresh Find
     * from a click work */
    ckfind("forward from the top", &b, "beta", 0,0, 1,0,0,  0,6);
    ckfind("forward from the match itself", &b, "beta", 0,6, 1,0,0, 0,6);
    /* ...and one past it walks on, which is Find Next */
    ckfind("find next steps off the match", &b, "beta", 0,7, 1,0,0, 1,0);

    /* backward starts strictly BEFORE, so Find Previous never
     * re-finds what it is standing on */
    ckfind("backward from the match itself", &b, "beta", 1,0, -1,0,0,
           0,6);
    ckfind("backward finds the nearest before", &b, "beta", 1,4, -1,0,0,
           1,0);

    /* case */
    ckfind("case sensitive misses BETA", &b, "BETA", 0,0, 1,0,0, 2,0);
    ckfind("folded finds the first regardless", &b, "BETA", 0,0, 1,1,0,
           0,6);
    ckfind("folded backward", &b, "beta", 2,4, -1,1,0, 2,0);

    /* no wrap stops at the end; wrap comes round */
    ckfind("no wrap past the last match", &b, "alpha", 1,0, 1,0,0,
           -1,0);
    ckfind("wrap comes round to the top", &b, "alpha", 1,0, 1,0,1, 0,0);
    ckfind("wrap backward comes round to the end", &b, "delta", 0,0,
           -1,0,1, 2,5);

    /* the case the wrapped revisit exists for: the only other match
     * is EARLIER ON THE SAME LINE as the start. A wrap that visits
     * each line once misses this one entirely. */
    ckfind("wrap re-searches the start line", &b, "alpha", 0,6, 1,0,1,
           0,0);
    ckfind("wrap re-searches the start line backward", &b, "gamma",
           1,0, -1,0,1, 1,5);

    /* absent, empty, and a pattern longer than the line */
    ckfind("absent pattern", &b, "zeta", 0,0, 1,0,1, -1,0);
    ckfind("empty pattern finds nothing", &b, "", 0,0, 1,0,1, -1,0);
    ckfind("pattern longer than any line", &b,
           "alpha beta gamma delta epsilon", 0,0, 1,0,1, -1,0);

    /* a match at the very end of a line, and at the very start */
    ckfind("match at end of line", &b, "gamma", 0,0, 1,0,0, 1,5);
    ckfind("match at start of line", &b, "beta", 0,10, 1,0,0, 1,0);
    buffree(&b);

    /* overlapping occurrences: "aa" in "aaaa" starts at 0 and 2 when
     * walked the way Find Next walks it */
    bufinit(&b);
    bufsplit(&b, "aaaa\n", 5);
    ckfind("overlap: first", &b, "aa", 0,0, 1,0,0, 0,0);
    ckfind("overlap: next from one past", &b, "aa", 0,1, 1,0,0, 0,1);
    ckfind("overlap: last possible start", &b, "aa", 0,2, 1,0,0, 0,2);
    ckfind("overlap: none past the end", &b, "aa", 0,3, 1,0,0, -1,0);
    buffree(&b);

    /* a one-line buffer wrapping onto itself must still terminate */
    bufinit(&b);
    bufsplit(&b, "solo\n", 5);
    ckfind("single line, wrap forward", &b, "solo", 0,2, 1,0,1, 0,0);
    ckfind("single line, wrap backward", &b, "solo", 0,0, -1,0,1, 0,0);
    ckfind("single line, absent, wrap", &b, "nope", 0,0, 1,0,1, -1,0);
    buffree(&b);

    /* an empty document has one empty line and must not read off it */
    bufinit(&b);
    bufsplit(&b, "", 0);
    ckfind("empty document", &b, "x", 0,0, 1,0,1, -1,0);
    buffree(&b);
}

/* his question, and the reason whole-word exists: replacing `from`
 * with `new` in a line that also holds `from!`, `frommage` and
 * `Afrom`. Without the switch all four are hit; with it, only the
 * word itself. */
static void wholeword(void)
{
    Buffer b;
    int fy, fx, n;
    const char *src = "from from! from? frommage Afrom From\n";
    /*                 0    5     11    17       26    32       */

    bufinit(&b);
    bufsplit(&b, src, (long)strlen(src));

    /* plain substring: five hits, one of them inside a longer word on
     * the LEFT, which is the one nobody expects */
    n = 0; fx = 0;
    while (ed_search(&b, "from", 0, fx, 1, 0, 0, 0, &fy, &fx)) { fx++; n++; }
    ck(n == 5, "substring search finds all five");

    /* whole word: THREE, not two. `from!` and `from?` both count -
     * punctuation is a boundary, so the word ends at it. Only
     * `frommage` (letter after) and `Afrom` (letter before) are
     * excluded. Getting this wrong in the test first is what proves
     * the test is reading the real answer and not my assumption. */
    n = 0; fx = 0;
    while (ed_search(&b, "from", 0, fx, 1, 0, 0, 1, &fy, &fx)) { fx++; n++; }
    ck(n == 3, "whole-word search finds the three standalone words");

    ck(ed_search(&b, "from", 0, 0, 1, 0, 0, 1, &fy, &fx) &&
       fy == 0 && fx == 0, "whole word at the start of the line");
    ck(ed_search(&b, "from", 0, 1, 1, 0, 0, 1, &fy, &fx) &&
       fx == 5, "a bang after is still a word boundary");
    ck(ed_search(&b, "from", 0, 6, 1, 0, 0, 1, &fy, &fx) &&
       fx == 11, "a question mark after is a word boundary too");
    /* past those, only frommage (17) and Afrom (27) are left, and
     * neither is a word */
    ck(!ed_search(&b, "from", 0, 12, 1, 0, 0, 1, &fy, &fx),
       "no whole word inside frommage or Afrom");
    buffree(&b);

    /* and the replacement, which is what he actually asked about */
    bufinit(&b);
    bufsplit(&b, src, (long)strlen(src));
    ck(ed_replaceall(&b, "from", "new", 0, 0) == 5,
       "substring replace hits five");
    ck(!strcmp(b.ln[0], "new new! new? newmage Anew From"),
       "substring replace mangles the longer words");
    buffree(&b);

    bufinit(&b);
    bufsplit(&b, src, (long)strlen(src));
    ck(ed_replaceall(&b, "from", "new", 0, 1) == 3,
       "whole-word replace hits three");
    ck(!strcmp(b.ln[0], "new new! new? frommage Afrom From"),
       "whole-word replace leaves the longer words alone");
    buffree(&b);

    /* digits and underscore are word characters, so an identifier is
     * one word - this is the case that matters for renaming in code */
    bufinit(&b);
    bufsplit(&b, "x x_1 x1 _x x.y\n", 16);
    ck(ed_replaceall(&b, "x", "Q", 0, 1) == 2, "identifier boundaries");
    ck(!strcmp(b.ln[0], "Q x_1 x1 _x Q.y"),
       "underscore and digits bind, a dot does not");
    buffree(&b);

    /* a word alone on a line: both ends of the line are boundaries */
    bufinit(&b);
    bufsplit(&b, "from\n", 5);
    ck(ed_search(&b, "from", 0, 0, 1, 0, 0, 1, &fy, &fx),
       "a word alone on a line is a whole word");
    buffree(&b);

    /* whole word AND case folding together */
    bufinit(&b);
    bufsplit(&b, "From FROMMAGE from\n", 19);
    ck(ed_replaceall(&b, "from", "new", 1, 1) == 2,
       "folded whole-word replace");
    ck(!strcmp(b.ln[0], "new FROMMAGE new"),
       "folded whole-word leaves FROMMAGE alone");
    buffree(&b);
}

static void replacing(void)
{
    Buffer b;
    int st, n;

    /* the plain case, and the count */
    bufinit(&b);
    bufsplit(&b, "one two one\ntwo one two\n", 24);
    n = ed_replaceall(&b, "one", "1", 0, 0);
    ck(n == 3, "replace all counts every hit");
    ck(!strcmp(b.ln[0], "1 two 1"), "replace all, first line");
    ck(!strcmp(b.ln[1], "two 1 two"), "replace all, second line");
    ck(b.len[0] == (int)strlen(b.ln[0]), "length tracks the text");
    ck(b.len[1] == (int)strlen(b.ln[1]), "length tracks the text (2)");

    /* ONE undo takes all three back - the whole point of the group */
    ck(ed_undo(&b, &st) >= 0, "replace all is undoable");
    ck(!strcmp(b.ln[0], "one two one") && !strcmp(b.ln[1], "two one two"),
       "one undo takes back every replacement");
    ck(!ed_canundo(&b), "and there was only the one step");
    buffree(&b);

    /* growing: a replacement CONTAINING the pattern must terminate
     * and must not be rescanned into itself */
    bufinit(&b);
    bufsplit(&b, "a a a\n", 6);
    n = ed_replaceall(&b, "a", "aa", 0, 0);
    ck(n == 3, "growing replacement replaces each hit once");
    ck(!strcmp(b.ln[0], "aa aa aa"), "growing replacement text");
    buffree(&b);

    /* shrinking to nothing */
    bufinit(&b);
    bufsplit(&b, "xaxaxa\n", 7);
    n = ed_replaceall(&b, "a", "", 0, 0);
    ck(n == 3, "replacing with nothing still counts");
    ck(!strcmp(b.ln[0], "xxx"), "replacing with nothing deletes");
    ck(b.len[0] == 3, "length after deletion");
    buffree(&b);

    /* case folding, and that the REPLACEMENT is written literally
     * rather than echoing the case that was matched */
    bufinit(&b);
    bufsplit(&b, "Foo foo FOO\n", 12);
    n = ed_replaceall(&b, "foo", "bar", 1, 0);
    ck(n == 3, "folded replace hits every case");
    ck(!strcmp(b.ln[0], "bar bar bar"), "folded replace writes literally");
    buffree(&b);

    bufinit(&b);
    bufsplit(&b, "Foo foo FOO\n", 12);
    n = ed_replaceall(&b, "foo", "bar", 0, 0);
    ck(n == 1, "unfolded replace hits only the exact case");
    ck(!strcmp(b.ln[0], "Foo bar FOO"), "unfolded replace text");
    buffree(&b);

    /* his case: "from!" -> "from". The replacement is a PREFIX of
     * the pattern, so a scanner that resumed inside its own output
     * would either loop or eat the following text. */
    bufinit(&b);
    bufsplit(&b, "come from! and from! again\n", 27);
    n = ed_replaceall(&b, "from!", "from", 0, 0);
    ck(n == 2, "from! -> from replaces both");
    ck(!strcmp(b.ln[0], "come from and from again"),
       "from! -> from text");
    ck(b.len[0] == (int)strlen(b.ln[0]), "from! -> from length");
    buffree(&b);

    /* the same pattern found and replaced ONE at a time, which is
     * the road Replace Next walks */
    bufinit(&b);
    bufsplit(&b, "from! from!\n", 12);
    {
        int fy, fx;
        ck(ed_search(&b, "from!", 0, 0, 1, 0, 0, 0, &fy, &fx) &&
           fy == 0 && fx == 0, "find from! at the start");
        ck(ed_replaceat(&b, 0, 0, 5, "from"), "replace the first from!");
        ck(!strcmp(b.ln[0], "from from!"), "first from! replaced");
        /* and from just past it, the second is still findable */
        ck(ed_search(&b, "from!", 0, 4, 1, 0, 0, 0, &fy, &fx) &&
           fy == 0 && fx == 5, "second from! still found");
        ck(ed_replaceat(&b, 0, 5, 5, "from"), "replace the second");
        ck(!strcmp(b.ln[0], "from from"), "both from! replaced");
    }
    buffree(&b);

    /* punctuation generally, since a search that mishandled it would
     * show up here rather than in a word */
    bufinit(&b);
    bufsplit(&b, "a!b?c.d,e\n", 10);
    ck(ed_replaceall(&b, "!", "@", 0, 0) == 1, "replace a bang");
    ck(!strcmp(b.ln[0], "a@b?c.d,e"), "bang replaced");
    buffree(&b);

    /* nothing to do */
    bufinit(&b);
    bufsplit(&b, "hello\n", 6);
    ck(ed_replaceall(&b, "zzz", "x", 0, 0) == 0, "no match, no replacement");
    ck(!strcmp(b.ln[0], "hello"), "no match leaves the line alone");
    ck(!ed_canundo(&b), "no match leaves nothing on the undo stack");
    ck(ed_replaceall(&b, "", "x", 0, 0) == 0, "empty pattern replaces nothing");
    ck(!strcmp(b.ln[0], "hello"), "empty pattern leaves the line alone");
    buffree(&b);

    /* one replacement in the middle, by hand, with its own undo */
    bufinit(&b);
    bufsplit(&b, "abcdef\n", 7);
    ck(ed_replaceat(&b, 0, 2, 2, "XYZ"), "replace at a position");
    ck(!strcmp(b.ln[0], "abXYZef"), "replace at a position, text");
    ck(ed_undo(&b, &st) >= 0, "single replace undoes");
    ck(!strcmp(b.ln[0], "abcdef"), "single replace undoes fully");
    buffree(&b);
}

static void autoindent(void)
{
    Buffer b;
    char ind[64];
    int st;

    bufinit(&b);
    bufsplit(&b, "    four\n\tone tab\nnone\n        \n", 33);

    ck(ed_indent(&b, 0, -1, ind, 63) == 4 && !strcmp(ind, "    "),
       "indent of spaces");
    ck(ed_indent(&b, 1, -1, ind, 63) == 1 && !strcmp(ind, "\t"),
       "indent of a tab");
    ck(ed_indent(&b, 2, -1, ind, 63) == 0 && !strcmp(ind, ""),
       "no indent");
    /* a line that is ALL whitespace is all indent */
    ck(ed_indent(&b, 3, -1, ind, 63) == 8, "an all-blank line is all indent");
    /* clamped to the cursor */
    ck(ed_indent(&b, 0, 2, ind, 63) == 2 && !strcmp(ind, "  "),
       "indent clamped to the cursor");
    ck(ed_indent(&b, 0, 0, ind, 63) == 0, "clamped to column 0 is nothing");
    buffree(&b);

    /* Return at the end of an indented line */
    bufinit(&b);
    bufsplit(&b, "    body\nnext\n", 14);
    ck(ed_newline(&b, 0, 8, 1), "newline with auto-indent");
    ck(b.n == 3, "newline added a line");
    ck(!strcmp(b.ln[0], "    body"), "the original line is untouched");
    ck(!strcmp(b.ln[1], "    "), "the new line carries the indent");
    ck(b.cy == 1 && b.cx == 4, "the cursor lands after the indent");
    /* ONE undo, not one per indent character */
    ck(ed_undo(&b, &st) >= 0, "auto-indent newline undoes");
    ck(b.n == 2 && !strcmp(b.ln[0], "    body"),
       "one undo takes back the split AND the indent");
    ck(!ed_canundo(&b), "and it was a single step");
    buffree(&b);

    /* Return in the MIDDLE of an indented line: the tail moves down
     * and gets the indent in front of it */
    bufinit(&b);
    bufsplit(&b, "\t\tab cd\n", 8);
    /* "\t\tab cd" split at 5 leaves the space on the head */
    ck(ed_newline(&b, 0, 5, 1), "newline mid-line");
    ck(!strcmp(b.ln[0], "\t\tab "), "the head keeps its indent");
    ck(!strcmp(b.ln[1], "\t\tcd"), "the tail is indented to match");
    ck(b.cy == 1 && b.cx == 2, "cursor after the copied indent");
    buffree(&b);

    /* Return INSIDE the leading whitespace copies only what was
     * before the cursor - not indent that was never typed */
    bufinit(&b);
    bufsplit(&b, "        deep\n", 13);
    ck(ed_newline(&b, 0, 3, 1), "newline inside the indent");
    ck(!strcmp(b.ln[0], "   "), "the head is what was before the cursor");
    ck(!strcmp(b.ln[1], "        deep"),
       "the tail keeps its own leading space, not doubled");
    ck(b.cy == 1 && b.cx == 3, "cursor after the three copied");
    buffree(&b);

    /* switched off, it is exactly the old behaviour */
    bufinit(&b);
    bufsplit(&b, "    body\n", 9);
    ck(ed_newline(&b, 0, 8, 0), "newline without auto-indent");
    ck(!strcmp(b.ln[1], "") && b.cx == 0,
       "no auto-indent means column 0");
    buffree(&b);

    /* Return at column 0 of an indented line indents NOTHING, because
     * nothing was before the cursor */
    bufinit(&b);
    bufsplit(&b, "    body\n", 9);
    ck(ed_newline(&b, 0, 0, 1), "newline at column 0");
    ck(!strcmp(b.ln[0], "") && !strcmp(b.ln[1], "    body"),
       "column 0 pushes the line down unchanged");
    ck(b.cy == 1 && b.cx == 0, "cursor at the start of the pushed line");
    buffree(&b);
}

static void selection(void)
{
    Buffer b;
    char out[256];
    long n;
    int y0,x0,y1,x1,st;

    bufinit(&b);
    bufsplit(&b, "one\ntwo\nthree\n", 14);

    ck(!ed_selrange(&b, &y0,&x0,&y1,&x1), "no selection by default");
    sel(&b, 0,0, 0,0);
    ck(!ed_selrange(&b, &y0,&x0,&y1,&x1), "an empty range is not a selection");

    /* within one line */
    sel(&b, 0,1, 0,3);
    ck(ed_selrange(&b,&y0,&x0,&y1,&x1) && y0==0&&x0==1&&y1==0&&x1==3,
       "range within a line");
    ck(ed_selbytes(&b) == 2, "bytes within a line");
    n = ed_seltext(&b, out); out[n]=0;
    ck(n==2 && !strcmp(out,"ne"), "text within a line");

    /* dragged BACKWARDS - the range still comes out in order */
    sel(&b, 0,3, 0,1);
    ck(ed_selrange(&b,&y0,&x0,&y1,&x1) && x0==1 && x1==3,
       "a backwards drag still reads forwards");
    n = ed_seltext(&b, out); out[n]=0;
    ck(!strcmp(out,"ne"), "backwards drag copies the same text");

    /* across lines, LF between them */
    sel(&b, 0,1, 2,3);
    ck(ed_selbytes(&b) == 10, "bytes across lines");
    n = ed_seltext(&b, out); out[n]=0;
    ck(n==10 && !strcmp(out,"ne\ntwo\nthr"), "text across lines");
    ck(ed_selbytes(&b) == n, "selbytes agrees with seltext");

    /* whole middle line */
    sel(&b, 1,0, 1,3);
    n = ed_seltext(&b, out); out[n]=0;
    ck(!strcmp(out,"two"), "a whole line");
    buffree(&b);

    /* delete within a line */
    bufinit(&b);
    bufsplit(&b, "abcdef\n", 7);
    sel(&b, 0,2, 0,4);
    ck(ed_seldelete(&b), "delete within a line");
    ck(!strcmp(b.ln[0], "abef"), "text after the delete");
    ck(b.cy==0 && b.cx==2, "cursor at the start of what went");
    ck(!b.selon, "and the selection is gone");
    ck(ed_undo(&b, &st) >= 0, "one undo");
    ck(!strcmp(b.ln[0], "abcdef"), "ONE undo restored the whole range");
    ck(!ed_canundo(&b), "and it was a single step");
    buffree(&b);

    /* delete across lines - the seam must close */
    bufinit(&b);
    bufsplit(&b, "one\ntwo\nthree\n", 14);
    sel(&b, 0,1, 2,3);
    ck(ed_seldelete(&b), "delete across lines");
    ck(b.n == 1, "three lines became one");
    ck(!strcmp(b.ln[0], "oee"), "head joined to tail");
    ck(b.cy==0 && b.cx==1, "cursor where the range started");
    ck(ed_undo(&b, &st) >= 0, "one undo");
    ck(st, "and it was structural");
    ck(b.n == 3 && !strcmp(b.ln[0],"one") && !strcmp(b.ln[1],"two") &&
       !strcmp(b.ln[2],"three"), "ONE undo restored all three lines");
    ck(!ed_canundo(&b), "a multi-line delete is a single step");
    buffree(&b);

    /* insert multi-line text - one undo, and every ending accepted */
    bufinit(&b);
    bufsplit(&b, "ad\n", 3);
    ck(ed_instext(&b, 0, 1, "b\nc", 3), "insert with an LF");
    ck(b.n == 2 && !strcmp(b.ln[0],"ab") && !strcmp(b.ln[1],"cd"),
       "split where the LF was");
    ck(b.cy==1 && b.cx==1, "cursor after the inserted text");
    ck(ed_undo(&b, &st) >= 0, "one undo");
    ck(b.n == 1 && !strcmp(b.ln[0],"ad"), "ONE undo took the paste back");
    buffree(&b);

    bufinit(&b);
    bufsplit(&b, "", 0);
    ck(ed_instext(&b, 0, 0, "a\r\nb\rc", 6), "CRLF and CR accepted");
    ck(b.n == 3 && !strcmp(b.ln[0],"a") && !strcmp(b.ln[1],"b") &&
       !strcmp(b.ln[2],"c"), "all three endings split once each");
    buffree(&b);

    /* display column to character index, with tabs */
    bufinit(&b);
    bufsplit(&b, "\tab\n", 4);          /* tab, a, b */
    ck(ed_col2x(&b, 0, 0, 8, 7) == 0, "column 0 is index 0");
    ck(ed_col2x(&b, 0, 4, 8, 7) == 0, "inside the tab stays before it");
    ck(ed_col2x(&b, 0, 8, 8, 7) == 1, "past the tab is index 1");
    ck(ed_col2x(&b, 0, 9, 8, 7) == 2, "then one per character");
    ck(ed_col2x(&b, 0, 99, 8, 7) == 3, "past the end is the end");
    buffree(&b);
}

int main(void)
{
    lineends();
    searching();
    wholeword();
    replacing();
    autoindent();
    selection();
    undoing();
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
