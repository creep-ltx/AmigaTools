/* mkdir.c -- Unix-style make directory for AmigaDOS
   usage: mkdir [-p] DIR ...
   e.g.   mkdir work:newdir
          mkdir a b c                    (several at once)
          mkdir -p work:a/b/c            (create missing parents)
          mkdir -p ram:deep/nested/dir

   C translation of mkdir.e, kept function-for-function parallel so
   the two languages can be compared side by side. Behaviour is
   identical; where the languages force a different shape, a comment
   marks the spot. The big ones:

     E                              C
     -----------------------------  --------------------------------
     HANDLE / EXCEPT / Throw()      no exceptions: fatal errors print
                                    and call quit(), soft errors set
                                    rc and return a status upward
     arg (raw command line)         GetArgStr() from dos.library
     String(tl) heap strings        one static pathstore[][] -- C has
                                    no garbage collector, so the
                                    easiest safe thing is no
                                    allocation at all
     NEW gfib / CleanUp()           AllocDosObject(DOS_FIB)/FreeDosObject
     WriteF('\s \d')                Printf((STRPTR)"%s %ld") from dos.library
     built-in StrCopy/StrLen        <string.h>

   Everything below the argument parser is a line-for-line port.
   See mkdir.e for the full commentary on WHY things are done; the
   comments here focus on the E-vs-C differences.

   Build:  m68k-amigaos-gcc -Os -Wall -o mkdir_c mkdir.c
*/

#include <exec/types.h>
#include <dos/dos.h>
#include <dos/dosextens.h>
#include <proto/exec.h>
#include <proto/dos.h>

#include <string.h>
#include <stdlib.h>

#define PATHLEN 512
#define MAXARGS 32

static const char version[] __attribute__((used)) =
    "$VER: mkdir 0.1.1 (1.8.26) C build";

static int rc = RETURN_OK;
static int parents = FALSE;
static struct FileInfoBlock *gfib;

/* E's String(tl) heap-allocates each path and CleanUp() frees the lot.
   C makes you do your own bookkeeping, so the paths live in one static
   block instead: MAXARGS * PATHLEN = 16K of BSS, freed by exit. */
static char pathstore[MAXARGS][PATHLEN];

static void quit(void);
static void usage(void);
static int  parseargs(char **paths);
static void setflags(const UBYTE *t);
static void setrc(int v);
static void checkbreak(void);
static void makeone(const char *path);
static void makeparents(const char *path);
static int  makestep(const char *path);
static void makefinal(const char *path);
static int  isdir(const char *path);

/* E's EXCEPT block funnels every failure into one place; in C the
   equivalent is this: everyone who wants out calls quit(), which frees
   what main allocated and exits with the worst rc seen. */
static void quit(void)
{
    if (gfib)
        FreeDosObject(DOS_FIB, gfib);
    exit(rc);
}

int main(void)
{
    char *paths[MAXARGS];
    int npaths, i;

    npaths = parseargs(paths);
    if (npaths < 1) {
        /* E: Throw("MK", 'usage: ...') caught by the generic branch */
        PutStr((STRPTR)"usage: mkdir [-p] DIR ...\n");
        setrc(RETURN_ERROR);
        quit();
    }

    gfib = AllocDosObject(DOS_FIB, NULL);   /* E: NEW gfib */
    if (!gfib) {
        PutStr((STRPTR)"mkdir: no memory\n");
        setrc(RETURN_FAIL);
        quit();
    }

    for (i = 0; i < npaths; i++) {
        checkbreak();
        if (parents)
            makeparents(paths[i]);
        else
            makeone(paths[i]);
    }

    quit();
    return rc;                              /* not reached */
}

static void usage(void)
{
    PutStr((STRPTR)"mkdir 0.1.1 -- Unix-style make directory\n");
    PutStr((STRPTR)"usage: mkdir [-p] DIR ...\n");
    PutStr((STRPTR)"  -p  create parent directories as needed; existing is not an error\n");
}

/* Tokenizes the raw command line, ls-style: whitespace-separated,
   double quotes group, `*` escapes inside quotes (AmigaDOS rules, *n
   and *e get their control meanings). -x bundles set flags; a lone ?
   prints usage; everything else is a directory name.

   E hands you the raw line as `arg`; in C the C startup code has
   already chopped it into argv -- with its own quoting rules, not
   these. So we ignore argv entirely and re-fetch the untouched line
   with GetArgStr(). Note UBYTE, not char: char is signed on m68k gcc,
   and a signed `c <= 32` would treat every Latin-1 byte (å, ö, ...)
   as whitespace. E's CHAR is unsigned, so E never had the problem. */
static int parseargs(char **paths)
{
    const UBYTE *p;
    char t[PATHLEN];
    int np, tl, c, inq, done;

    np = 0;
    p = GetArgStr();                        /* E: p := arg */
    while (*p) {
        while (*p > 0 && *p <= 32)
            p++;
        if (*p == 0)
            return np;

        tl = 0;
        inq = FALSE;
        done = FALSE;
        while (!done) {
            c = *p;
            if (c == 0) {
                done = TRUE;
            } else if (inq) {
                if (c == '"') {                  /* closing quote */
                    inq = FALSE;
                    p++;
                } else if (c == '*') {           /* * escape */
                    p++;
                    c = *p;
                    if (c == 0) {
                        done = TRUE;
                    } else {
                        if (c == 'n' || c == 'N') c = 10;
                        if (c == 'e' || c == 'E') c = 27;
                        t[tl++] = c;
                        p++;
                    }
                } else {
                    t[tl++] = c;
                    p++;
                }
            } else {
                if (c <= 32) {
                    done = TRUE;
                } else if (c == '"') {           /* opening quote */
                    inq = TRUE;
                    p++;
                } else {
                    t[tl++] = c;
                    p++;
                }
            }
            if (tl >= PATHLEN - 1)
                done = TRUE;
        }
        t[tl] = 0;

        if (tl > 0) {
            if (t[0] == '-' && tl > 1) {
                setflags((UBYTE *)t);
            } else if (t[0] == '?' && tl == 1) {
                usage();                    /* E: Throw("USG") */
                quit();
            } else {
                /* 0.1.1 A1: never silently drop an argument (family
                   rule) - a directory list that doesn't fit is an
                   error, not a silently shorter batch */
                if (np >= MAXARGS) {        /* E: Throw("MAX") */
                    Printf((STRPTR)"mkdir: too many arguments (max %ld)\n",
                           (LONG)MAXARGS);
                    setrc(RETURN_ERROR);
                    quit();
                }
                strcpy(pathstore[np], t);   /* E: String + StrCopy */
                paths[np] = pathstore[np];
                np++;
            }
        }
    }
    return np;
}

static void setflags(const UBYTE *t)
{
    int i, c;
    for (i = 1; (c = t[i]) != 0; i++) {
        switch (c) {                        /* E: SELECT/CASE */
        case 'p':
            parents = TRUE;
            break;
        default:                            /* E: Throw("ARG") */
            PutStr((STRPTR)"mkdir: unknown option (mkdir ? for usage)\n");
            setrc(RETURN_ERROR);
            quit();
        }
    }
}

static void setrc(int v)
{
    if (v > rc)
        rc = v;
}

static void checkbreak(void)
{
    if (SetSignal(0, SIGBREAKF_CTRL_C) & SIGBREAKF_CTRL_C) {
        PutStr((STRPTR)"***Break: mkdir\n");        /* E: Throw("BRK") */
        setrc(RETURN_FAIL);
        quit();
    }
}

/* Plain mode: create the directory directly. Its parent must exist,
   and an already-existing target is an error -- both surface as the
   dos.library fault (Object already exists / Object not found), and
   PrintFault supplies the single trailing newline. Grab IoErr() BEFORE
   the Printf: a successful Write() zeroes IoErr on real AmigaDOS, so
   reading it afterwards feeds PrintFault a 0 -- which prints nothing at
   all, not even the newline (vamos doesn't clobber it, which is how
   this slipped through in the E version). */
static void makeone(const char *path)
{
    BPTR lock;
    LONG err;

    lock = CreateDir((STRPTR)path);
    if (lock) {
        UnLock(lock);
        return;
    }
    err = IoErr();
    Printf((STRPTR)"mkdir: %s: ", (ULONG)path);
    PrintFault(err, NULL);
    setrc(RETURN_ERROR);
}

/* -p mode: create every missing directory along the path. Splits on
   '/' (and skips the 'device:' head), creating each prefix in turn;
   an intermediate that already exists is fine, a hard failure aborts
   just this path. Parent-hop components (an empty piece from a
   leading or doubled '/') are stepped over, not created. */
static void makeparents(const char *path)
{
    char w[PATHLEN];
    int i, start, c, len;

    strncpy(w, path, PATHLEN - 1);          /* E: AstrCopy */
    w[PATHLEN - 1] = 0;
    len = strlen(w);
    if (len == 0)
        return;

    start = 0;
    for (i = 0; i < len; i++) {
        c = (UBYTE)w[i];
        if (c == ':') {
            start = i + 1;                  /* device head: descend, don't create */
        } else if (c == '/') {
            if (i > start) {                /* a real name ends here */
                w[i] = 0;
                if (!makestep(w))
                    return;                 /* hard error, already reported */
                w[i] = '/';
            }
            start = i + 1;
        }
    }

    if (len > start)                        /* the last component */
        makefinal(w);
}

/* An intermediate directory under -p: an already-existing DIRECTORY
   is success; an existing FILE is reported here, at the component
   that is actually in the way (0.1.1 K1 - it used to "succeed" and
   let the NEXT step fail with a generic fault naming the wrong
   component). Returns FALSE (after reporting) on a real failure. */
static int makestep(const char *path)
{
    BPTR lock;
    LONG err;

    lock = CreateDir((STRPTR)path);
    if (lock) {
        UnLock(lock);
        return TRUE;
    }
    err = IoErr();
    if (err == ERROR_OBJECT_EXISTS) {
        if (isdir(path))
            return TRUE;
        Printf((STRPTR)"mkdir: %s: exists and is not a directory\n",
               (ULONG)path);
        setrc(RETURN_ERROR);
        return FALSE;
    }
    Printf((STRPTR)"mkdir: %s: ", (ULONG)path);
    PrintFault(err, NULL);
    setrc(RETURN_ERROR);
    return FALSE;
}

/* The final component under -p: already-exists is success only if it
   really is a directory; an existing file of that name is an error. */
static void makefinal(const char *path)
{
    BPTR lock;
    LONG err;

    lock = CreateDir((STRPTR)path);
    if (lock) {
        UnLock(lock);
        return;
    }
    err = IoErr();
    if (err == ERROR_OBJECT_EXISTS) {
        if (!isdir(path)) {
            Printf((STRPTR)"mkdir: %s: exists and is not a directory\n",
                   (ULONG)path);
            setrc(RETURN_ERROR);
        }
        return;
    }
    Printf((STRPTR)"mkdir: %s: ", (ULONG)path);
    PrintFault(err, NULL);
    setrc(RETURN_ERROR);
}

static int isdir(const char *path)
{
    BPTR lock;
    int r = FALSE;

    lock = Lock((STRPTR)path, ACCESS_READ);
    if (lock) {
        if (Examine(lock, gfib))
            if (gfib->fib_DirEntryType > 0)
                r = TRUE;
        UnLock(lock);
    }
    return r;
}
