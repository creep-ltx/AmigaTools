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

**Status: 1.0 — released.** Every milestone boot-verified on an
AmigaOS 3.2 install (FS-UAE, 68030). The release archive is
`ccon.lha`; the endgame — CTerm handing its frame window to
`CCON:` — works and is the daily driver.

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

- **Scrollback**: 4000 lines per window, attribute plane included —
  Shift/Ctrl+arrows and the mouse wheel, working over raw-mode
  programs too (wheel back through More mid-page).
- **A window per open**, stock CON: semantics, with the full stock
  option set (`AUTO`, `WAIT`, `SCREENname`, `WINDOW0xADDR`,
  `NOBORDER`, …) parsed per open; `*`/`CONSOLE:` opens attach to
  the caller's console.
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
  double-click word, triple-click line, RAMIGA-V paste.
- **Two colour worlds kept apart**: `WBPENS` declares a truly-ANSI
  palette; on any other screen plain SGR 3x stays raw pens (what
  WB-pen programs like Ed mean) while bold+3x — ANSI colour intent,
  the `ls` scheme — is translated by colour through ObtainBestPen.
  `ls` is genuinely blue everywhere; Ed is never red.
- **Fullscreen programs work**: Ed with working menus (picks travel
  the same IECLASS_MENULIST route as on stock CON: — read out of
  Ed's disassembled parser), block cursor, class-12 resize
  re-measure; More with real timer.device WAIT_CHARs.
- **CRAW:** — the same binary mounted raw-from-byte-one, the
  `RAW:` counterpart.

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
- `CCON-mountlist` — one mountlist, two device stanzas (`CCON:`
  and `CRAW:`) for `DEVS:`, same shape KingCON's own uses.
- `ccon.readme` — short-form readme for the release archive.
- `ccon.doc` — the full plain-text manual (Amiga-width lines).
- `ccon.lha` — the release archive (`L/`, `DEVS/`, docs).
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
