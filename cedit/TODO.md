# cedit — what is left

`roadmap.md` is the build log: what was made, why, and what it cost.
This is the forward list. Items move out of here and into a beta
section there when they get built.

Legend: `[ ]` open · `[~]` in progress · `[x]` done

---

## 1. The compiler bench — his design, 4.8.26

The biggest item on the list and the one that changes what cedit is
for. Written up in full below rather than as a line, because the
shape needs settling before any of it is built.

### What he asked for

> a feature to "add compiler", and the user can point to their C/E/Asm
> compiler. For each compiler it should be possible to enter arguments
> and have them populate a `Compile > E >` items menu list so the user
> can check/mark which arguments should be sent to the compiler, and
> also uncheck but no need to write them in every time … saved between
> runs, survive program end. And maybe CEdit can send the file to the
> correct compiler based on the .fileending or maybe it's better to
> have a `Compile > E > EVO`, `Compile > E > EC` menu … maybe the user
> has several compilers for each language.

### The constraint that settles the menu shape

**Intuition menus are exactly two levels deep**: `NM_TITLE` → `NM_ITEM`
→ `NM_SUB`, and there is no third. So `Compile > E > EVO > -quiet` is
not available, and the choice between "by file extension" and "pick
the compiler from a menu" is not a choice at all — the two-level limit
puts the COMPILER at item level and its ARGUMENTS in its submenu,
which is exactly the explicit form. The extension road is then one
extra item at the top:

```
Compile
  ├ Compile              Amiga+E   <- the DEFAULT compiler for this
  │                                   file's language, by extension
  ├ ─────────────
  ├ EC (E)          ▸  ├ Compile with this
  │                    ├ Default for .e        [x]
  │                    ├ ─────────────
  │                    ├ QUIET                 [x]
  │                    ├ NOWARN                [ ]
  │                    └ LARGE                 [x]
  ├ E-VO (E)        ▸  …
  ├ gcc (C)         ▸  …
  ├ vasm (Asm)      ▸  …
  ├ ─────────────
  ├ Add compiler...
  └ Edit compilers...
```

- An item that has subitems cannot itself be selected, so each
  compiler's submenu opens with **Compile with this**.
- **Default for .e** is a radio across the compilers of one language:
  it decides who the top-level **Compile** hands the file to. Several
  compilers per language, one of them the one Amiga+E means.
- Arguments are `CHECKIT | MENUTOGGLE` subitems. Ticked ones are sent,
  unticked ones stay in the list — which is the whole point: write
  every argument you know once, tick the ones this job needs.

### The configuration is a text file, and cedit edits text

- [ ] **`Edit compilers...` opens the config in a tab.** cedit is a
      text editor; the configuration is text; there is no reason to
      build a list-editing requester for something the program in
      front of you already does better. Saving it re-reads it and
      rebuilds the menu.
- [ ] `Add compiler...` stays as a convenience — four fields through
      `ltx_askfields` (name, language, path, template) — and appends
      to the same file. Same for `Add argument...` on a compiler's
      submenu, through the b7b status-row prompt.
- [ ] Removing and reordering is done by editing the file. No UI for
      it, and no apology for that.

**Format** — line based, hand-editable, order preserved:

```
# cedit compilers
compiler E   EC     Dump:Code/ec
  default
  template %c %a %f
  arg on   QUIET
  arg off  NOWARN
  arg on   LARGE
compiler E   E-VO   Dump:Code/evo
  arg on   -q
compiler C   gcc    gcc
  template %c %a %f -o %b
  arg on   -O2
  arg on   -Wall
  arg off  -g
```

**Template placeholders**, so the file does not have to be last on
every command line and output names are expressible:

| | |
|---|---|
| `%c` | the compiler's path |
| `%a` | the ticked arguments, space separated |
| `%f` | the file being compiled, full path |
| `%b` | that file without its extension |
| `%d` | the drawer it lives in |

Default template is `%c %a %f`, which is right for EC and gcc alike.

### Where it is kept

- [ ] **`ENVARC:cedit/compilers`**, read from `ENV:cedit/compilers`
      first if it exists — the standard Amiga preferences road, and
      the one that survives a reboot and a new binary.
- [ ] **A `COMPILERS=` tooltype overrides the path entirely.** Same
      instinct as every other setting here, and it means the file can
      sit on `Dump:` during development where the host can edit it.

### Running it

- [ ] **Save first.** Compiling the buffer you can see and not the
      file on disk is the oldest trap there is. Untitled documents get
      Save As, and a cancel cancels the compile.
- [ ] `Execute(cmd, NIL, out)` with the output redirected to a file,
      which is already the pattern CFile uses for exactly this.
      `busy(1)` around it — a compile is the slowest thing this
      program will ever do.
- [ ] The output goes somewhere he can read it. Simplest that is
      actually useful: **open it in a new tab**, which costs nothing
      because opening files in tabs already works.
- [ ] Bounded: 8 compilers, 20 arguments each. A menu longer than the
      screen is not a feature, and both numbers are far past what
      anyone will use.

### Then, and only then, the error jump

- [ ] **Parse the output and land the caret on the error line.** This
      is the feature nobody else has for E, and it is why the whole
      bench is worth building — but it is a SEPARATE beta, because
      parsing EC's, gcc's and vasm's error formats is its own job with
      its own tests, and the bench is useful without it.
- [ ] Each compiler gets an error-pattern name in the config
      (`errors ec`, `errors gcc`), not a regexp — three known formats
      matched by hand-written code that the harness can test beats a
      pattern language nobody will get right on the first try.

---

## 2. Save fidelity, and the `.bak` that fixes it

Found while reading `savebuf` back on 3.8.26. One change, three
problems:

- [ ] **The original is deleted BEFORE the rename.** The text is never
      at risk — it is already in the `.new` — but for that instant the
      file does not exist under its own name.
- [ ] **Protection bits are lost on every save.** The replacement is a
      brand-new file with defaults, so the archive bit and anything
      else set on the original quietly goes.
- [ ] **The file comment is lost the same way.** People do use
      `filenote` on this platform.
- [ ] The fix is one reordering plus two calls: rename the original to
      `.bak`, rename `.new` into place, then `SetProtection` and
      `SetComment` from what was read off the original before writing.
      Keeping or deleting the `.bak` becomes a `BACKUP=` tooltype.

---

## 3. File lifecycle

- [ ] **Revert to saved**, with a prompt when the buffer is dirty.
- [ ] **`+N` / start-at-line argument.** The `ENV:EDITOR` convention,
      and cedit is meant to be what `ENV:EDITOR` points at. It is also
      half the plumbing the error jump needs.
- [ ] **Iconify.** cdiff has it and cedit does not — and an editor is
      the tool most likely to be left open all session. See
      AmigaReferences/intuition-iconify.md.

---

## 4. ARexx

- [ ] **An ARexx port**, so CFile can hand cedit a file and cedit can
      tell cdiff to compare what was just saved. The thing that makes
      the three a family rather than three programs.
- [ ] Minimum useful command set: `OPEN`, `SAVE`, `LINE n`, `GETLINE`,
      `INSERT`, `QUIT` — enough for another program to drive it.

---

## 5. The menu pass — his, already asked for

- [ ] Shortcuts and grouping reviewed as a whole rather than assigned
      one beta at a time as they were.
- [ ] **Two ways to turn colouring off**, left over from b9:
      `Settings > Syntax colour` is a global master and
      `Highlight > Plain text` is per document. One of them should go,
      or they should be visibly different things.
- [ ] `Save As` has no shortcut since b8 gave Amiga+A to Select All.
      Worth confirming that is the right trade once the whole map is
      on one page.

---

## 6. Smaller, and honestly optional

- [ ] **Lexer definitions from `PROGDIR:Lexers/`** — stage two of b9.
      The engine already takes a table it does not own, so this is a
      parser and nothing else. Worth building the day a fourth
      language is actually wanted, and not before.
- [ ] **An assembly corpus for the harness.** E and C are covered by
      real source in this repo; assembly is not, because the cboot asm
      port was removed at 98093c3. It would have to come in as a test
      fixture under `tests/`.
- [ ] Bracket matching counts brackets inside strings and comments. A
      documented trade — teaching it otherwise means running a lexer
      that only knows E, so a C file would answer differently to the
      same key.
- [ ] Trailing-whitespace strip, and tab/space conversion.
- [ ] A recent-files list.

---

## Closed, so they stop being asked about

- **Gutter regrow.** Not an open question: `calcgut` already runs from
  `structural()`, so the gutter widens the moment a line is added. His
  A1200 shot of cfile.e shows five digits rendering correctly at
  12,211 lines.
- **`LTX_MAXCOLS` 256.** The real corpus does not approach it — the
  widest line in cfile.e is 136 columns. It stays a ceiling for a big
  RTG screen, not something to spend a build on.
- **The pointer-inside scrolling gap.** Closed on his call. Message
  traffic, the paint path and the coalescing cap were all ruled out;
  the remaining suspect is the pointer sprite over the blitted region,
  which is DMA we do not own.
