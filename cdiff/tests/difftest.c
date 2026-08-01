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
