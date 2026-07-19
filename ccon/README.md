# CCON

An LTX console handler for AmigaOS — the `CON:` family (CON:,
KingCON, ViNCEd) grown at home. A mounted DOS handler speaking the
packet protocol, built around the one feature the stock 3.2 console
cannot be given from outside: **output scrollback** (verified
against the ROM con-handler's option table — no such option
exists, and commands talk to the handler, so no terminal program
can bolt it on). Around that core: a window per open, a modern
line editor, and a shell feel that fingers trained on
fish/bash/zsh recognize at once.

**Status: 1.1.** Every milestone boot-verified on an AmigaOS 3.2
install (FS-UAE, 68030). The release archive is `ltx-cc11.lha`. Since
1.0: per-window FONT and soft styles, an alternate-screen contract
for Ed/More (no console had that before), shared persistent
history, safe multi-line paste, scrollback content search, and —
new this release — CCON: can stand in for the system's own CON:/
RAW: entirely, KingCON style.

## Screenshots

Tab completion's cycling menu — directories blue, hidden grey:

![zsh-style Tab completion](screenshots/completion.png)

One typed letter, and history's continuation waits in grey —
Right takes it all, Ctrl+Right/Tab word by word:

![fish-style autosuggestions](screenshots/ghost.png)

Ctrl+R replaces the prompt with the search banner, bash style —
the real prompt comes back from the scrollback model:

![Ctrl+R incremental history search](screenshots/search.png)

## Highlights

- **Scrollback**: 512 lines per window by default (`LINES=n` up to
  5000), attribute AND style planes included — Shift/Ctrl+arrows
  and the mouse wheel, working over raw-mode programs too, except
  on a client's own alternate screen (More/Ed mid-page — xterm
  manners, nothing to scroll into there).
- **Scrollback content search**: once you're scrolled back, Ctrl+R
  retargets from command history to searching what's ON SCREEN —
  same incremental feel, matches shown inverted and grabbed onto
  your prompt live, n/N to keep stepping through matches.
- **Shared, persistent command history** across every window, not
  lost when one closes.
- **A window per open**, stock CON: semantics, with the full stock
  option set (`AUTO`, `WAIT`, `SCREENname`, `WINDOW0xADDR`,
  `NOBORDER`, …) parsed per open, `WIDTH`/`HEIGHT` of `-1` filling
  whatever's left of the screen from `X`/`Y`; `*`/`CONSOLE:` opens
  attach to the caller's console.
- **FONT and LINES per window**: your own face/size (loaded from
  disk if needed) or scrollback depth; unset FONT follows your
  Font Prefs default instead of a hardcoded topaz 8.
- **fish-style autosuggestions**: history's continuation as grey
  ghost text; Right accepts all, Ctrl+Right/Tab word by word.
- **bash-style Ctrl+R**: incremental history search; the prompt
  becomes an inverse `(search: …)` banner and is restored
  pixel-perfect from the scrollback model afterwards.
- **zsh-style Tab completion** with a cycling menu, on hand-rolled
  filesystem packets (a handler must not call packet-sending
  dos.library functions — the no-DOS rule).
- **readline surgery**: Ctrl+W/U/K, and Ctrl+L clearing the screen
  *into history* — Shift+Up undoes the clear.
- **Copy & paste** both ways with the stock console family
  (IFF FTXT): drag with output frozen mid-drag like stock,
  double-click word, triple-click line. RAMIGA-V pastes safely —
  one ordinary-looking line at a time with a grey "N more queued"
  hint, never blindly running a whole clipboard's worth of
  commands (RAMIGA+SHIFT+V or the PASTEEXEC option for the old
  instant-run way).
- **Two colour worlds kept apart**: `WBPENS` declares a truly-ANSI
  palette; on any other screen plain SGR 3x stays raw pens (what
  WB-pen programs like Ed mean) while bold+3x — ANSI colour intent,
  the `ls` scheme — is translated by colour through ObtainBestPen.
  `ls` is genuinely blue everywhere; Ed is never red — plus real
  italic/underline/inverse soft styles.
- **Fullscreen programs work**: Ed with working menus (picks travel
  the same IECLASS_MENULIST route as on stock CON: — read out of
  Ed's disassembled parser), block cursor, class-12 resize
  re-measure, and proper whole-view scrolling (ANSI Scroll Up/Down
  honoured, not just the one changed row); More with real
  timer.device WAIT_CHARs, and it restores your scrollback
  transcript on exit exactly as xterm's alternate screen does —
  paged content never enters your history.
- **xterm-style window titles** (OSC) that survive scrollback.
- **CRAW:** — the same binary mounted raw-from-byte-one, the
  `RAW:` counterpart.
- **Can replace CON:/RAW: system-wide**, KingCON style — dismount
  the stock devices, mount CCON: under their names instead, and
  every console the OS opens becomes a CCON: window. Experimental;
  see `ccon.doc` section 14.
- Swedish (and other) dead-key composition survives raw mode.

## Try it

```
copy ccon-handler L:
copy CCON-mountlist DEVS:
Mount CCON: FROM DEVS:CCON-mountlist
Mount CRAW: FROM DEVS:CCON-mountlist
NewShell CCON:
```

More in the docs: `ccon.readme` is the quick overview,
**`ccon.doc` is the handbook** — every option, every key, the
design notes. A running handler keeps its seglist: after updating
`L:ccon-handler`, reboot — a re-Mount alone does nothing.

## Files

- `ccon-handler.e` — the source, Amiga E, one file.
- `ccon-handler` — prebuilt AmigaOS binary.
- `CCON-mountlist` — one mountlist, four device stanzas (`CCON:`,
  `CRAW:`, and the experimental `CON:`/`RAW:` takeover pair) for
  `DEVS:`, same shape KingCON's own mountlist uses.
- `ccon.readme` — short-form readme for the release archive.
- `ccon.doc` — the full plain-text manual (Amiga-width lines).
- `ltx-cc11.lha` — the release archive (`L/`, `DEVS/`, docs).
- `todo.md` — the complete build history: every milestone, every
  verified protocol fact, every disassembly finding, every latent
  bug the boots flushed out. The project's lab notebook.

## Building

```
evo ccon-handler.e LARGE
```

`LARGE` became necessary with the M10 console object: member
indirection pushed references past the small model's 32k range.
The generated startup was disassembled against the previous build
to confirm the E handler trick below survives the model change —
it does, byte-identically.

## The E handler trick

An E binary started as a handler has no CLI, so the E runtime's
startup code waits on the process message port and captures the
first message — which is DOS's mount startup packet — into the
`wbmessage` global, believing it a Workbench startup message. The
handler takes the packet from there, replies it itself, and sets
`wbmessage := NIL` so the runtime's exit code (which would reply
the same message again) stays quiet. Verified by disassembling the
generated startup code, not assumed.

## The road there

Ten milestones in three days, each boot-verified before the next
began: proof of life, the transplanted line editor, a real shell,
raw mode, scrollback, completion, colours, the input.device chain
(and the four system freezes it ended), copy & paste, window
resize, the stock option set, a window per open — then the
readline tier on release night. When documentation ran out, the
ROM was disassembled: the V47 shell's undocumented console probe,
console.device's raw event report format, con-handler's window
tag list, and Ed's menu parser were all read out of the bytes.
The whole story, including the lessons paid for in gurus, lives
in `todo.md`.

## Since 1.0

Two themes, same discipline — nothing shipped that wasn't
boot-verified, and every protocol question got settled by reading
the real bytes, not guessed. Theme A: per-window FONT (loaded from
disk through a helper process, the no-DOS rule intact) and real
soft styles, then the alternate screen — More's own V47 binary
turned out to already speak the xterm `?47h`/`?47l` protocol,
found by disassembling it rather than inventing a synthetic
signal. Theme B: shared persistent history, safe multi-line paste
after three design iterations, and scrollback content search,
which took its own six-beta detour through a two-pass keyboard-
dispatch trap before it actually worked.

The last stretch — Ed's scrolling and More's arrow-key paging — is
the clearest case for the house rule: when a client "misbehaves"
under CCON:, compare it against stock CON: before concluding
anything is unfixable. A full `machine68k` disassembly of both
binaries found real, separate bugs each time (Ed was never
receiving the ANSI Scroll Up/Down it actually sends; More's arrow
keys were encoded with the wrong CSI introducer byte) — and a
five-minute side-by-side test against stock CON: is what actually
proved the second one was CCON's bug to fix, after disassembly
alone had twice pointed the wrong way. That same session, CON:/
RAW: replacement went from a parked idea to something running in
a real `S:User-Startup`, once it turned out to need no handler
code at all — just the same mountlist trick KingCON already uses.
The full account, including what didn't work first, is in
`todo.md`.
