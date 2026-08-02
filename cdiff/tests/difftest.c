/* difftest - the engine harness. Compiles with the HOST cc and with
 * m68k-amigaos-gcc (run under vamos): same code, same verdicts.
 * The invariant: diff_verify proves the op stream transforms A into
 * B exactly. Fixed-seed randoms (every run is the same run), plus a
 * control that tampers an op and REQUIRES the checker to catch it -
 * a harness that cannot fail proves nothing. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../diff.h"

static int failures = 0;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

/* build DLines straight from an array of C strings */
static DLine *mklines(const char **s, int n)
{
    /* route through diff_split so the split path is exercised too:
     * join with LFs into one buffer */
    static char buf[65536];
    DLine *l;
    int i, nl;
    long p = 0;
    for (i = 0; i < n; i++) {
        int len = strlen(s[i]);
        memcpy(buf + p, s[i], len);
        p += len;
        buf[p++] = '\n';
    }
    if (diff_split(buf, p, &l, &nl) != 0) return NULL;
    if (nl != n) return NULL;
    return l;
}

static void run(const char **as, int na, const char **bs, int nb,
                const char *name)
{
    DLine *a = mklines(as, na), *b;
    DOp *ops;
    int nops;
    static char msg[128];
    /* mklines shares one static buffer - split b from its own copy */
    static char bbuf[65536];
    long p = 0;
    int i, nlb;
    for (i = 0; i < nb; i++) {
        int len = strlen(bs[i]);
        memcpy(bbuf + p, bs[i], len);
        p += len;
        bbuf[p++] = '\n';
    }
    if (diff_split(bbuf, p, &b, &nlb) != 0 || nlb != nb) {
        check(0, name);
        free(a);
        return;
    }
    if (diff_run(a, na, b, nb, &ops, &nops) != 0) {
        sprintf(msg, "%s (diff_run oom)", name);
        check(0, msg);
    } else {
        sprintf(msg, "%s (verify)", name);
        check(diff_verify(a, na, b, nb, ops, nops), msg);
        free(ops);
    }
    free(a);
    free(b);
}

/* b99: correctness is not enough for the Myers work - a wholesale
 * replace VERIFIES perfectly, it is just a bad answer. This probe
 * asserts the op stream actually contains equal runs, which is the
 * whole point of running Myers inside an anchorless block. If anyone
 * removes it, these fail. */
static void runeq(const char **as, int na, const char **bs, int nb,
                  int mineq, const char *name)
{
    static char abuf[65536], bbuf[65536], msg[128];
    DLine *a, *b;
    DOp *ops;
    int nops, i, nlA, nlB, eq = 0;
    long p = 0, q = 0;
    for (i = 0; i < na; i++) {
        int len = strlen(as[i]);
        memcpy(abuf + p, as[i], len); p += len; abuf[p++] = '\n';
    }
    for (i = 0; i < nb; i++) {
        int len = strlen(bs[i]);
        memcpy(bbuf + q, bs[i], len); q += len; bbuf[q++] = '\n';
    }
    if (diff_split(abuf, p, &a, &nlA) != 0 ||
        diff_split(bbuf, q, &b, &nlB) != 0) { check(0, name); return; }
    if (diff_run(a, nlA, b, nlB, &ops, &nops) != 0) {
        check(0, name);
        free(a); free(b);
        return;
    }
    sprintf(msg, "%s (verify)", name);
    check(diff_verify(a, nlA, b, nlB, ops, nops), msg);
    for (i = 0; i < nops; i++)
        if (ops[i].t == DOP_EQ) eq += ops[i].n;
    sprintf(msg, "%s (aligned: %d equal lines, want >= %d)", name, eq, mineq);
    check(eq >= mineq, msg);
    free(ops); free(a); free(b);
}

/* fixed-seed PRNG - the Mod-is-DIVS lesson says never trust rand() */
static unsigned long seed = 12345;
static int rnd(int n)
{
    seed = seed * 1103515245UL + 12345UL;
    return (int)((seed >> 16) % (unsigned long)n);
}

int main(void)
{
    static const char *empty[1] = { "x" };  /* unused, size anchor */
    static const char *one[] = { "hello" };
    static const char *ab[] = { "alpha", "beta" };
    static const char *ab2[] = { "alpha", "BETA" };
    static const char *mid1[] = { "a", "b", "c", "d", "e" };
    static const char *mid2[] = { "a", "b", "X", "d", "e" };
    static const char *pre[] = { "new", "a", "b" };
    static const char *app[] = { "a", "b", "new" };
    static const char *dup1[] = { "x", "x", "x", "x" };
    static const char *dup2[] = { "x", "x", "y", "x", "x" };
    static const char *move1[] = { "one", "two", "three", "four" };
    static const char *move2[] = { "three", "four", "one", "two" };

    DLine *a, *b;
    DOp *ops;
    int nops, i, t;

    run(one, 1, one, 1, "identical");
    run(empty, 0, empty, 0, "empty vs empty");
    run(empty, 0, ab, 2, "empty vs two");
    run(ab, 2, empty, 0, "two vs empty");
    run(ab, 2, ab2, 2, "one line changed");
    run(mid1, 5, mid2, 5, "middle change");
    run(mid1, 5, pre, 3, "prepend+truncate");
    run(mid1, 5, app, 3, "append shape");
    run(dup1, 4, dup2, 5, "no unique lines (fallback)");
    run(move1, 4, move2, 4, "block move");

    /* randomized apply-check: 200 rounds of independent line soups
     * from a small pool - every op stream must verify */
    {
        static const char *pool[] =
            { "aa", "bb", "cc", "dd", "ee", "ff", "gg", "hh" };
        static const char *ra[64], *rb[64];
        for (t = 0; t < 200; t++) {
            int na = rnd(41), nb = rnd(41);
            for (i = 0; i < na; i++) ra[i] = pool[rnd(8)];
            for (i = 0; i < nb; i++) rb[i] = pool[rnd(8)];
            run(ra, na, rb, nb, "random round");
        }
    }

    /* the control: a tampered op stream MUST fail verification */
    a = mklines(mid1, 5);
    {
        static char bbuf[64];
        long p = 0;
        int nlb;
        for (i = 0; i < 5; i++) {
            int len = strlen(mid2[i]);
            memcpy(bbuf + p, mid2[i], len);
            p += len;
            bbuf[p++] = '\n';
        }
        diff_split(bbuf, p, &b, &nlb);
    }
    /* ---- b99: anchorless blocks, the case Myers exists for ----
     * Every line repeats, so NOTHING is unique in both files and
     * patience has nothing to anchor on. Before Myers these came
     * back as "delete all, insert all" - zero equal lines. */
    {   /* the shape from his own screenshots: a tag block where the
         * matching lines REPEAT, so they are unique in neither file
         * and patience cannot anchor on them */
        static const char *ra[] = {
            "WA_TOP, 0,", "WA_WIDTH, w,", "WA_TOP, 0,",
            "WA_WIDTH, w,", "WA_HEIGHT, h,"
        };
        static const char *rb[] = {
            "WA_LEFT, 1,", "WA_WIDTH, w,", "WA_LEFT, 1,",
            "WA_WIDTH, w,", "WA_DEPTH, d,"
        };
        runeq(ra, 5, rb, 5, 2, "myers: repeated tags, no anchor possible");
    }
    {   /* nothing trims at either end, and the only matches repeat */
        static const char *ra[] = { "A", "END", "B", "END", "C" };
        static const char *rb[] = { "X", "END", "Y", "END", "Z" };
        runeq(ra, 5, rb, 5, 2, "myers: repeated separators");
    }
    {   /* three matches, deep enough to exercise the recursion */
        static const char *ra[] = { "1","dup","2","dup","3","dup","4" };
        static const char *rb[] = { "a","dup","b","dup","c","dup","d" };
        runeq(ra, 7, rb, 7, 3, "myers: three non-unique matches");
    }

    diff_run(a, 5, b, 5, &ops, &nops);
    check(diff_verify(a, 5, b, 5, ops, nops), "control pre-tamper");
    ops[0].n++;                      /* break it on purpose */
    check(!diff_verify(a, 5, b, 5, ops, nops),
          "control: tampered stream caught");
    free(ops);
    free(a);
    free(b);

    if (failures) {
        printf("difftest: %d FAILURE(S)\n", failures);
        return 20;
    }
    printf("difftest: ALL GREEN\n");
    return 0;
}
