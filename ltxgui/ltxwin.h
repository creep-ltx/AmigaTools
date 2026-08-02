/* ltxwin - the shared GUI chassis of the LTX AmigaTools family.
 *
 * Everything here was written, boot-tested and eye-tuned inside cdiff
 * 0.1b1-b109 and lifted out when cedit became the second tool that
 * wanted it. The rule this module exists to serve is CFile's own
 * (cfile/todo.md): the machinery moves to a module when a second tool
 * wants it, not before.
 *
 * The state below is DEFINED here and declared extern for the app, so
 * a lifted function and its caller keep the names they were written
 * with. That is deliberate: a rename would have turned a code move
 * into a 160-site edit of a program that renders correctly.
 *
 * Nothing in this file may know what the app's content IS. Rows,
 * lines, buffers, diffs - all of that stays on the app's side.
 */
#ifndef LTXWIN_H
#define LTXWIN_H

#include <exec/types.h>
#include <dos/dos.h>
#include <intuition/intuition.h>
#include <graphics/text.h>

/* ---- the window, and who we were launched as ------------------- */

extern struct Window *win;      /* NULL while iconified */

/* our own drawer and file name, kept from the WBStartup message so
 * the AppIcon can wear the user's icon and iconset() can write back
 * to it. Zero after a shell launch, and every user of them checks. */
extern BPTR ttoollock;
extern char ttoolname[110];

/* ---- fonts ----------------------------------------------------- */

/* open the font actually asked for: the ROM/memory list first, disk
 * second, and validated on BOTH roads (fixed, designed, right size).
 * A scaled topaz is not topaz. NULL if nothing qualifies. */
struct TextFont *tryfont(const char *name, int size);

/* ---- pointer --------------------------------------------------- */

/* the busy pointer, with WA_PointerDelay so a fast job never flashes
 * it. V39+; older Kickstarts keep the normal pointer. No-op with no
 * window. */
void busy(int on);

/* ---- tooltypes ------------------------------------------------- */

/* case-insensitive equality, so VIEW=tree and VIEW=TREE both work */
int tteq(const char *a, const char *b);

/* a positive dimension, or -1 for "absent, or unparseable, or
 * explicitly -1" - all of which mean "out to the screen edge" */
int ttdim(char **tt, const char *name);

/* a number clamped to [lo,hi], or def when absent or out of range */
int ttnum(char **tt, const char *name, int lo, int hi, int def);

/* a string, copied to dest (max includes the terminator). dest is
 * left untouched when the tooltype is absent or empty. */
void ttstr(char **tt, const char *name, char *dest, int max);

/* set NAME=value on OUR OWN icon, preserving every other byte - the
 * splice rule, not a GetDiskObject/PutDiskObject round trip (which
 * is destructive; see AmigaReferences/icon-info-files.md). Returns 0
 * when there is no icon to write, when the icon's layout is not one
 * we understand, or when the write fails - and in every one of those
 * cases the file on disk is left exactly as it was. */
int iconset(const char *name, const char *value);

#endif /* LTXWIN_H */
