/* diff.h - cdiff's line-diff engine, pure logic.
 * No OS calls anywhere in the engine: it compiles on the host for the
 * harness and cross for the Amiga, and must behave identically. */
#ifndef CDIFF_DIFF_H
#define CDIFF_DIFF_H

typedef struct {
    const char *ptr;        /* into the file buffer, NOT terminated */
    int len;                /* without the LF (and without a CR tail) */
    unsigned long hash;
} DLine;

/* op stream: EQ/DEL/INS runs, adjacent same-type runs pre-merged.
 * A replace block always arrives as DEL then INS. */
#define DOP_EQ  0
#define DOP_DEL 1
#define DOP_INS 2

typedef struct {
    unsigned char t;
    int n;
} DOp;

/* split a loaded file into hashed lines; *lines is malloc'd (free()
 * it), buf must outlive it. Returns 0, or -1 on out-of-memory. */
int diff_split(const char *buf, long size, DLine **lines, int *nlines);

/* patience diff a vs b; *ops is malloc'd (free() it).
 * Returns 0, or -1 on out-of-memory. */
int diff_run(const DLine *a, int na, const DLine *b, int nb,
             DOp **ops, int *nops);

/* harness invariant: do the ops transform a exactly into b?
 * Returns 1 if sound, 0 if not (the harness's teeth). */
int diff_verify(const DLine *a, int na, const DLine *b, int nb,
                const DOp *ops, int nops);

#endif
