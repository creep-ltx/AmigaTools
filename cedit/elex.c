/* elex - the syntax lexer. See elex.h. */
#include <string.h>
#include "elex.h"

/* Amiga E's keywords. Uppercase only, which is not laziness: E is
 * case sensitive and every keyword is spelled in capitals, so
 * matching case-insensitively would paint a variable called `to` or
 * a field called `list` as a keyword. Checked against the 31,906
 * lines of E in this repo. */
static const char *const ekw[] = {
    "AND", "ARRAY", "BUT", "CASE", "CHAR", "CONST", "DEC", "DEF",
    "DEFAULT", "DO", "ELSE", "ELSEIF", "EMPTY", "END", "ENDFOR",
    "ENDIF", "ENDLOOP", "ENDOBJECT", "ENDPROC", "ENDSELECT",
    "ENDWHILE", "ENUM", "EXCEPT", "EXIT", "EXPORT", "FALSE", "FOR",
    "HANDLE", "IF", "INC", "INT", "IS", "JUMP", "LIST", "LONG",
    "LOOP", "MODULE", "NEW", "NIL", "NOT", "OBJECT", "OF", "OPT",
    "OR", "PROC", "PTR", "RAISE", "REPEAT", "RETURN", "SELECT",
    "SELF", "SET", "SIZEOF", "STEP", "STRING", "SUPER", "THEN", "TO",
    "TRUE", "UNTIL", "VOID", "WHILE"
};

/* C. The language's own keywords and nothing else - no library
 * types, no Amiga typedefs. A list that tries to know every name in
 * every header is a list that is wrong about somebody's variable. */
static const char *const ckw[] = {
    "auto", "break", "case", "char", "const", "continue", "default",
    "do", "double", "else", "enum", "extern", "float", "for", "goto",
    "if", "inline", "int", "long", "register", "restrict", "return",
    "short", "signed", "sizeof", "static", "struct", "switch",
    "typedef", "union", "unsigned", "void", "volatile", "while"
};

/* 68000 mnemonics and the assembler directives everyone's assembler
 * agrees on, lower case and matched case-insensitively. Size suffixes
 * (.b/.w/.l) are not part of the word: the identifier scan stops at
 * the dot, so `move.l` matches `move` and colours correctly. */
static const char *const akw[] = {
    "abcd", "add", "adda", "addi", "addq", "addx", "align", "and",
    "andi", "asl", "asr", "bcc", "bchg", "bclr", "bcs", "beq", "bge",
    "bgt", "bhi", "bhs", "ble", "blo", "bls", "blt", "bmi", "bne",
    "bpl", "bra", "bset", "bsr", "bss", "btst", "bvc", "bvs", "chk",
    "clr", "cmp", "cmpa", "cmpi", "cmpm", "cnop", "code", "data",
    "dbcc", "dbcs", "dbeq", "dbf", "dbge", "dbgt", "dbhi", "dble",
    "dbls", "dblt", "dbmi", "dbne", "dbpl", "dbra", "dbt", "dbvc",
    "dbvs", "dc", "dcb", "divs", "divu", "ds", "else", "end", "endc",
    "endif", "endm", "endr", "eor", "eori", "equ", "equr", "even",
    "exg", "ext", "fail", "far", "ifd", "ifeq", "ifge", "ifgt",
    "ifle", "iflt", "ifnd", "ifne", "illegal", "incbin", "include",
    "jmp", "jsr", "lea", "link", "list", "lsl", "lsr", "macro",
    "move", "movea", "movem", "movep", "moveq", "muls", "mulu",
    "nbcd", "near", "neg", "negx", "nolist", "nop", "not", "or",
    "org", "ori", "pea", "rem", "rept", "reset", "rol", "ror",
    "roxl", "roxr", "rs", "rsreset", "rsset", "rte", "rtr", "rts",
    "sbcd", "scc", "scs", "section", "seq", "set", "sf", "sge",
    "sgt", "shi", "sle", "sls", "slt", "smi", "sne", "spl", "st",
    "stop", "sub", "suba", "subi", "subq", "subx", "svc", "svs",
    "swap", "tas", "trap", "trapv", "tst", "unlk", "xdef", "xref"
};

#define NELEM(a) ((int)(sizeof(a) / sizeof((a)[0])))

/* ---- the language tables -----------------------------------------
 * Read across: keywords, how they are cased, line comments, the
 * column-0 star, block comments and whether they nest, string
 * quotes, number prefixes, and whether a leading # is a directive. */
static const LxLang langs[LX_NLANG] = {
    /* LX_NONE - never consulted; lx_line short-circuits */
    { "None", 0, 0, LXK_EXACT, 0, 0, 0, 0, 0, 0, "", "", 0 },

    /* LX_E: arrow comment to end of line, slash-star block comments
     * that NEST (E really does nest them, which is why the state is a
     * depth), single and double quotes, $hex and %binary, and
     * keywords only where the word is all capitals.
     *
     * The block-comment tokens are written a character at a time
     * below rather than as literals: spelling them out in a comment
     * here would close this one. */
    { "Amiga E", ekw, NELEM(ekw), LXK_UPPER,
      "->", 0, 0, "/*", "*/", 1, "'\"", "$%", 0 },

    /* LX_C: double-slash to end of line, slash-star blocks that do
     * NOT nest, both quote characters, no $ or % number prefix (% is
     * modulo and $ is not a number), and # opens a directive */
    { "C", ckw, NELEM(ckw), LXK_EXACT,
      "//", 0, 0, "/*", "*/", 0, "\"'", "", 1 },

    /* LX_ASM: ; to end of line, * in column 0, no block comments,
     * $hex %binary @octal, mnemonics case-insensitive */
    { "Assembly", akw, NELEM(akw), LXK_FOLD,
      ";", 0, 1, 0, 0, 0, "'\"", "$%@", 0 }
};

const LxLang *lx_table(int lang)
{
    if (lang <= LX_NONE || lang >= LX_NLANG) return 0;
    return &langs[lang];
}

/* extension -> language. Case-insensitive, because a file called
 * MAIN.C is the same file as main.c. */
static int extis(const char *name, int n, const char *ext)
{
    int e = (int)strlen(ext);
    int i;
    if (n < e + 1) return 0;
    if (name[n - e - 1] != '.') return 0;
    for (i = 0; i < e; i++) {
        int c = (unsigned char)name[n - e + i];
        if (c >= 'A' && c <= 'Z') c += 32;
        if (c != (unsigned char)ext[i]) return 0;
    }
    return 1;
}

int lx_language(const char *name)
{
    int n = (int)strlen(name);
    if (extis(name, n, "e"))   return LX_E;
    if (extis(name, n, "c"))   return LX_C;
    if (extis(name, n, "h"))   return LX_C;
    if (extis(name, n, "s"))   return LX_ASM;
    if (extis(name, n, "asm")) return LX_ASM;
    if (extis(name, n, "i"))   return LX_ASM;   /* Amiga asm includes */
    return LX_NONE;
}

static int isuc(char c)  { return c >= 'A' && c <= 'Z'; }
static int isdig(char c) { return c >= '0' && c <= '9'; }
static int isidc(char c)
{
    return isuc(c) || isdig(c) || c == '_' ||
           (c >= 'a' && c <= 'z');
}

static int chin(const char *set, char c)
{
    if (set == 0) return 0;
    while (*set) if (*set++ == c) return 1;
    return 0;
}

/* does `s` start with `p`? p may be NULL, which never matches. */
static int starts(const char *s, int n, int i, const char *p)
{
    int j = 0;
    if (p == 0) return 0;
    while (p[j]) {
        if (i + j >= n || s[i + j] != p[j]) return 0;
        j++;
    }
    return j;
}

/* compare a word against a table entry, folding case when asked */
static int kwcmp(const char *a, int alen, const char *b, int fold)
{
    int i, bl = (int)strlen(b);
    int m = alen < bl ? alen : bl;
    for (i = 0; i < m; i++) {
        int ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (fold) {
            if (ca >= 'A' && ca <= 'Z') ca += 32;
            if (cb >= 'A' && cb <= 'Z') cb += 32;
        }
        if (ca != cb) return ca - cb;
    }
    return alen - bl;
}

/* a whole word matched against the table. Binary search because the
 * table is sorted and this runs per word per row. */
static int iskw(const LxLang *L, const char *s, int len)
{
    int lo = 0, hi = L->nkw - 1;
    int fold = (L->kwcase == LXK_FOLD);
    while (lo <= hi) {
        int mid = (lo + hi) / 2;
        int c = kwcmp(s, len, L->kw[mid], fold);
        if (c == 0) return 1;
        if (c < 0) hi = mid - 1; else lo = mid + 1;
    }
    return 0;
}

/* open a span, unless the one we are in already has this class -
 * adjacent runs of the same colour would be two Text() calls where
 * one will do, and the row painter's cost is measured in those. */
static void push(LxRun *runs, int maxruns, int *nr, int start, int cls)
{
    if (*nr > 0 && runs[*nr - 1].cls == cls) return;
    if (*nr >= maxruns) return;
    if (*nr > 0 && runs[*nr - 1].start == start) {
        runs[*nr - 1].cls = cls;    /* empty span: just retype it */
        return;
    }
    runs[*nr].start = start;
    runs[*nr].cls = cls;
    (*nr)++;
}

unsigned char lx_line(int lang, unsigned char state,
                      const char *s, int n,
                      LxRun *runs, int maxruns, int *nruns)
{
    const LxLang *L = lx_table(lang);
    int i = 0, nr = 0, k;
    int depth = state > LX_STATE_MAX ? LX_STATE_MAX : state;

    *nruns = 0;
    if (maxruns < 1) return state;
    if (L == 0) {                       /* plain text: one span */
        runs[0].start = 0;
        runs[0].cls = LX_TEXT;
        *nruns = 1;
        return 0;
    }

    push(runs, maxruns, &nr, 0, depth ? LX_COMMENT : LX_TEXT);

    /* the assembler's column-0 star: the whole line is a comment */
    if (!depth && L->starcol0 && n > 0 && s[0] == '*') {
        push(runs, maxruns, &nr, 0, LX_COMMENT);
        *nruns = nr;
        return 0;
    }

    while (i < n) {
        char c = s[i];

        if (depth) {                    /* inside a block comment */
            if ((k = starts(s, n, i, L->bc)) != 0) {
                depth--;
                i += k;
                if (!depth) push(runs, maxruns, &nr, i, LX_TEXT);
                continue;
            }
            if (L->bnest && (k = starts(s, n, i, L->bo)) != 0) {
                if (depth < LX_STATE_MAX) depth++;
                i += k;
                continue;
            }
            i++;
            continue;
        }

        /* a line comment runs to the end of the line and stops the
         * scan - there is nothing after it to colour */
        if (starts(s, n, i, L->lc1) || starts(s, n, i, L->lc2)) {
            push(runs, maxruns, &nr, i, LX_COMMENT);
            break;
        }

        if ((k = starts(s, n, i, L->bo)) != 0) {
            push(runs, maxruns, &nr, i, LX_COMMENT);
            depth = 1;
            i += k;
            continue;
        }

        if (chin(L->quotes, c)) {
            char q = c;
            int j = i + 1;
            while (j < n) {
                if (s[j] == '\\' && j + 1 < n) { j += 2; continue; }
                if (s[j] == q) { j++; break; }
                j++;
            }
            push(runs, maxruns, &nr, i, LX_STRING);
            i = j;
            push(runs, maxruns, &nr, i, LX_TEXT);
            continue;
        }

        /* a preprocessor directive, C's # - only where it is the
         * first thing on the line, so a stringify inside a macro body
         * is left alone */
        if (L->hash && c == '#') {
            int b = 0;
            while (b < i && (s[b] == ' ' || s[b] == '\t')) b++;
            if (b == i) {
                int j = i + 1;
                while (j < n && (s[j] == ' ' || s[j] == '\t')) j++;
                while (j < n && isidc(s[j])) j++;
                push(runs, maxruns, &nr, i, LX_KEYWORD);
                i = j;
                push(runs, maxruns, &nr, i, LX_TEXT);
                continue;
            }
        }

        /* plain decimal, and whatever this language prefixes a
         * number with */
        if (isdig(c) || (chin(L->numpfx, c) && i + 1 < n &&
                         isidc(s[i + 1]))) {
            int j = i + 1;
            while (j < n && isidc(s[j])) j++;
            push(runs, maxruns, &nr, i, LX_NUMBER);
            i = j;
            push(runs, maxruns, &nr, i, LX_TEXT);
            continue;
        }

        /* a word. The span has to cover the WHOLE word, so `PROCESS`
         * is not PROC followed by ESS. Under LXK_UPPER a word with
         * any lower case in it cannot be a keyword at all. */
        if (isidc(c)) {
            int j = i;
            int allcaps = 1;
            while (j < n && isidc(s[j])) {
                if (!isuc(s[j]) && !isdig(s[j]) && s[j] != '_')
                    allcaps = 0;
                j++;
            }
            if ((L->kwcase != LXK_UPPER || allcaps) &&
                iskw(L, s + i, j - i)) {
                push(runs, maxruns, &nr, i, LX_KEYWORD);
                i = j;
                push(runs, maxruns, &nr, i, LX_TEXT);
            } else
                i = j;
            continue;
        }

        i++;
    }

    *nruns = nr ? nr : 1;
    if (!nr) { runs[0].start = 0; runs[0].cls = LX_TEXT; }
    return (unsigned char)depth;
}
