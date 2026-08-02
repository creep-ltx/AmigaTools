/* ltxwin - the shared GUI chassis of the LTX AmigaTools family.
 * See ltxwin.h for what belongs here and what does not.
 *
 * Lifted from cdiff 0.1b109 at cedit b0. Build-tag comments (b73,
 * b87, b102, b109...) are cdiff's and are kept: they are the reason
 * each line reads the way it does, and losing them would lose the
 * post-mortems that produced them.
 */
#include <exec/types.h>
#include <intuition/intuition.h>
#include <workbench/startup.h>
#include <workbench/workbench.h>
#include <proto/exec.h>
#include <proto/dos.h>
#include <proto/intuition.h>
#include <proto/graphics.h>
#include <proto/icon.h>
#include <proto/diskfont.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ltxwin.h"

/* initialized on purpose: a strong definition keeps libnix's
 * auto-open modules out of the link - a TEXT/CLI mode must run where
 * these libraries don't exist (vamos), so ONLY the app's guimode
 * opens them. They live here rather than in the app because the
 * chassis is what needs them; the app closes them as it always did. */
struct IntuitionBase *IntuitionBase = NULL;
struct GfxBase *GfxBase = NULL;
struct Library *GadToolsBase = NULL;
struct Library *AslBase = NULL;
struct Library *WorkbenchBase = NULL;   /* b69: AppWindow drops */
struct Library *IconBase = NULL;        /* b72: the AppIcon's image */
struct Library *DiskfontBase = NULL;    /* b73: FONT= tooltype */

struct Window *win;

BPTR ttoollock;                 /* our own drawer, for the AppIcon */
char ttoolname[110];

/* ---- fonts ------------------------------------------------------ */

/* b109: is this the font we actually asked for? Every measurement in
 * cdiff is columns x fw, so a proportional face would render
 * nonsense; an algorithmically SCALED one is not what he named; and
 * a different height means diskfont substituted something. */
static int goodfont(struct TextFont *tf, int size)
{
    return !(tf->tf_Flags & FPF_PROPORTIONAL) &&
            (tf->tf_Flags & FPF_DESIGNED) &&
            tf->tf_YSize == size;
}

/* b109, and his findings are the whole design of this:
 *
 *   FONTS:topaz.font on disk offers only size 11. Ask diskfont for
 *   topaz 8 and it SCALES 11 down - a thin ~6px face that still
 *   lays out correctly on a character grid, so nothing looks broken,
 *   only wrong. The real topaz 8 and 9 live in ROM.
 *
 * So try the ROM/memory list FIRST via OpenFont, and only then go to
 * disk. Validation happens on BOTH roads, and a rejected font falls
 * through to the next one rather than ending the search - b108 gated
 * its retry on a NULL return, which never happens when diskfont
 * hands back something scaled. */
struct TextFont *tryfont(const char *name, int size)
{
    struct TextAttr ta;
    struct TextFont *tf;
    ta.ta_Name  = (STRPTR)name;
    ta.ta_YSize = size;
    ta.ta_Style = FS_NORMAL;
    ta.ta_Flags = 0;            /* ask permissively, verify strictly */
    tf = OpenFont(&ta);
    if (tf && !goodfont(tf, size)) { CloseFont(tf); tf = NULL; }
    if (tf == NULL && DiskfontBase) {
        tf = OpenDiskFont(&ta);
        if (tf && !goodfont(tf, size)) { CloseFont(tf); tf = NULL; }
    }
    return tf;
}

/* ---- pointer ---------------------------------------------------- */

/* b102: WA_PointerDelay means the busy pointer only appears if the
 * job actually takes a moment - a fast load never flashes it. V39+;
 * older Kickstarts keep the normal pointer, as they always did. */
void busy(int on)
{
    if (win == NULL) return;
    if (IntuitionBase->LibNode.lib_Version < 39) return;
    if (on)
        SetWindowPointer(win, WA_BusyPointer, TRUE,
                              WA_PointerDelay, TRUE, TAG_DONE);
    else
        SetWindowPointer(win, TAG_DONE);
}

/* ---- b87: writing a tooltype back to the icon ------------------
 * NOT via PutDiskObject: that rewrites the whole file from
 * icon.library's in-memory parse, so anything the running library
 * version did not understand is silently dropped - an OS3.5+ colour
 * icon appendix under an older icon.library, for instance. The
 * surgical route instead, ported from CFile 0.5b51's editor (proven
 * against 400 real .info files, all 107 with tooltypes rebuilt
 * byte-identical by a no-change save) and documented in
 * AmigaReferences/icon-info-files.md:
 *
 *   new file = bytes[0..block) + rebuilt block + bytes[block end..EOF)
 *
 * Everything before and after the tooltype block is copied untouched.
 * Any bounds check that fails means we do not understand the file,
 * and an icon we do not understand is one we leave alone. */

static UWORD rdw(const UBYTE *b, long o)
{
    return (UWORD)((b[o] << 8) | b[o + 1]);
}

static ULONG rdl(const UBYTE *b, long o)
{
    return ((ULONG)b[o] << 24) | ((ULONG)b[o + 1] << 16) |
           ((ULONG)b[o + 2] << 8) | (ULONG)b[o + 3];
}

static void wrl(UBYTE *b, long o, ULONG v)
{
    b[o] = (UBYTE)(v >> 24); b[o + 1] = (UBYTE)(v >> 16);
    b[o + 2] = (UBYTE)(v >> 8); b[o + 3] = (UBYTE)v;
}

/* an Image: 20-byte header, then ((W+15)/16)*2 * H * D of planes */
static long skipimage(const UBYTE *b, long size, long off)
{
    long w, h, d;
    if (off + 20 > size) return -1;
    w = rdw(b, off + 4);
    h = rdw(b, off + 6);
    d = rdw(b, off + 8);
    if (w < 1 || h < 1 || d < 1) return -1;
    if (w > 4096 || h > 4096 || d > 8) return -1;
    off += 20 + (long)(((w + 15) >> 4) * 2) * (h * d);
    if (off > size) return -1;
    return off;
}

/* where the tooltype block starts, and where the suffix after it
 * begins (equal when the icon has none) */
static int ttlocate(const UBYTE *b, long size, long *start, long *end)
{
    long off, nent, j, l;
    if (size < 78) return 0;
    if (rdw(b, 0) != 0xE310) return 0;          /* do_Magic */
    off = 78;
    if (rdl(b, 66)) off += 56;                  /* DrawerData */
    if (off > size) return 0;
    if (rdl(b, 22) && (off = skipimage(b, size, off)) < 0) return 0;
    if (rdl(b, 26) && (off = skipimage(b, size, off)) < 0) return 0;
    if (rdl(b, 50)) {                           /* DefaultTool string */
        if (off + 4 > size) return 0;
        l = (long)rdl(b, off);
        if (l < 0 || off + 4 + l > size) return 0;
        off += 4 + l;
    }
    *start = off;
    if (rdl(b, 54)) {                           /* the block */
        if (off + 4 > size) return 0;
        nent = (long)(rdl(b, off) >> 2) - 1;    /* count = n/4 - 1 */
        if (nent < 0 || nent > 4096) return 0;
        off += 4;
        for (j = 0; j < nent; j++) {
            if (off + 4 > size) return 0;
            l = (long)rdl(b, off);
            if (l < 0 || off + 4 + l > size) return 0;
            off += 4 + l;
        }
    }
    *end = off;
    return 1;
}

/* does this entry carry the tooltype called `name`? Compares the
 * text before the '=', so a parenthesised (NAME=...) does not match
 * and a disabled line is left exactly where he put it. */
static int ttnamed(const char *e, const char *name)
{
    int i = 0;
    while (name[i] && e[i] && e[i] != '=') {
        char a = e[i], b = name[i];
        if (a >= 'A' && a <= 'Z') a += 32;
        if (b >= 'A' && b <= 'Z') b += 32;
        if (a != b) return 0;
        i++;
    }
    return name[i] == 0 && e[i] == '=';
}

/* set NAME=value on our own icon, preserving every other byte */
int iconset(const char *name, const char *value)
{
    char path[400], neu[160];
    UBYTE *buf = NULL, *out = NULL;
    long size, st, en, off, nent, j, l, need, o, nn;
    BPTR fh, old;
    int ok = 0, replaced = 0;

    if (!ttoollock || !ttoolname[0]) return 0;  /* not a WB launch */
    sprintf(neu, "%.60s=%.60s", name, value);
    old = CurrentDir(ttoollock);
    sprintf(path, "%.300s.info", ttoolname);

    fh = Open((STRPTR)path, MODE_OLDFILE);
    if (fh == 0) goto done;
    Seek(fh, 0, OFFSET_END);
    size = Seek(fh, 0, OFFSET_BEGINNING);
    if (size < 78 || size > 1000000L) { Close(fh); goto done; }
    buf = malloc(size);
    if (buf == NULL) { Close(fh); goto done; }
    if (Read(fh, buf, size) != size) { Close(fh); goto done; }
    Close(fh);

    if (!ttlocate(buf, size, &st, &en)) goto done;

    /* worst case: every old byte, plus our entry, plus the count */
    need = size + strlen(neu) + 16;
    out = malloc(need);
    if (out == NULL) goto done;

    memcpy(out, buf, st);
    o = st + 4;                         /* leave room for the count */
    nn = 0;
    if (rdl(buf, 54)) {                 /* copy the entries we keep */
        nent = (long)(rdl(buf, st) >> 2) - 1;
        off = st + 4;
        for (j = 0; j < nent; j++) {
            l = (long)rdl(buf, off);
            if (ttnamed((char *)buf + off + 4, name)) {
                wrl(out, o, (ULONG)(strlen(neu) + 1));
                memcpy(out + o + 4, neu, strlen(neu) + 1);
                o += 4 + strlen(neu) + 1;
                replaced = 1;
            } else {
                memcpy(out + o, buf + off, 4 + l);
                o += 4 + l;
            }
            nn++;
            off += 4 + l;
        }
    }
    if (!replaced) {                    /* new setting: append it */
        wrl(out, o, (ULONG)(strlen(neu) + 1));
        memcpy(out + o + 4, neu, strlen(neu) + 1);
        o += 4 + strlen(neu) + 1;
        nn++;
    }
    wrl(out, st, (ULONG)((nn + 1) * 4));        /* the format's rule */
    memcpy(out + o, buf + en, size - en);
    o += size - en;
    if (!rdl(buf, 54)) wrl(out, 54, 1);         /* present-flag on */

    fh = Open((STRPTR)path, MODE_NEWFILE);
    if (fh == 0) goto done;
    ok = (Write(fh, out, o) == o);
    Close(fh);
done:
    free(buf);
    free(out);
    CurrentDir(old);
    return ok;
}

/* ---- b73: reading tooltypes ------------------------------------
 * The app decides WHICH tooltypes exist and where they land; these
 * are just the typed readers. Every setting is optional and inert
 * when absent, so a shell launch is unchanged. */

/* case-insensitive equality, so VIEW=tree and VIEW=TREE both work.
 * Local rather than utility.library's Stricmp - one more library
 * open for four comparisons is not a trade worth making. */
int tteq(const char *a, const char *b)
{
    while (*a && *b) {
        char x = *a++, y = *b++;
        if (x >= 'A' && x <= 'Z') x += 32;
        if (y >= 'A' && y <= 'Z') y += 32;
        if (x != y) return 0;
    }
    return *a == 0 && *b == 0;
}

/* b81: WIDTH=/HEIGHT= take a positive size, or -1 meaning "out to
 * the screen edge from wherever LEFT=/TOP= put us". Absent means the
 * same as -1 - which also fixes a real bug in the old defaults: a
 * LEFT= with no WIDTH= used the FULL screen width, so the window ran
 * off the right edge by exactly the left inset. Anything unparseable
 * falls back to filling rather than to a silly size; the window's own
 * WA_MinWidth/MinHeight clamp values that are too small. */
int ttdim(char **tt, const char *name)
{
    UBYTE *v = FindToolType((CONST_STRPTR *)tt, (STRPTR)name);
    int n;
    if (v == NULL) return -1;
    n = atoi((char *)v);
    return n > 0 ? n : -1;
}

int ttnum(char **tt, const char *name, int lo, int hi, int def)
{
    UBYTE *v = FindToolType((CONST_STRPTR *)tt, (STRPTR)name);
    int n;
    if (v == NULL) return def;
    n = atoi((char *)v);
    if (n < lo || n > hi) return def;
    return n;
}

void ttstr(char **tt, const char *name, char *dest, int max)
{
    UBYTE *v = FindToolType((CONST_STRPTR *)tt, (STRPTR)name);
    if (v == NULL || v[0] == 0) return;
    strncpy(dest, (char *)v, max - 1);
    dest[max - 1] = 0;
}
