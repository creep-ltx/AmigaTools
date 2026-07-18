# CTerm

A terminal for AmigaOS: a real AmigaDOS shell inside a
full-screen LTX frame. (Named CShell until 0.3 — but it hosts
shells, it isn't one, so it took the terminal's name.)

## How it works

CTerm opens its own screen (like Workbench, made public as
`CTERM`), draws header and footer art bands loaded from a mockup
file, opens a *borderless* window covering exactly the space
between them — and hands that window to a console handler using
`CON:`'s documented `WINDOW 0xaddr` option. The handler never
opens a window of its own, so there is no chrome to fight.
`Execute` then starts a real, interactive UserShell in it.

Because the console is the OS's own, everything simply works:
stdin and interactive prompts, raw mode, `More`, `Ed`, keymaps,
shell history and line editing, scripts, `S:Shell-Startup`. There
is no emulation layer — CTerm is to this console what the boot
Shell is to a CON: window, plus the frame.

`EndShell` (or `EndCLI`) ends the shell and CTerm closes behind
it.

## Arguments

```
CTerm [CONSOLE <device:>] [HEADER <file>] [FOOTER <file>]
      [FULL] [ANSI] [FROM <script>]
```

`CONSOLE` picks the console handler the frame window is handed
to — `CON:` (the default), `CCON:` (this repo's own handler, with
output scrollback and tab completion in the frame), `KCON:`,
`VNC:`, any mounted console device. It is only a prefix on the
open spec, so there is no list to maintain. `FROM` names a script
the shell executes before its first prompt — aliases and assigns
set there stick, since it runs in the same CLI process (the
NewShell `FROM` mechanism):

```
CTerm CCON: FROM S:Shell-Startup
```

`HEADER` and `FOOTER` name band art files of your own — the whole
file is the band; a header claims up to 6 lines, a footer up to 3. Naming one band shows only
that band; naming neither shows the built-in mockup; `FULL` shows
none, giving the console the whole screen (`FULL` with a named
band is refused as a contradiction). A band file containing ANSI
escapes is detected and rendered in colour — SGR foreground and
background, bold, underline, and the cursor-forward gaps ANSI art
positions itself with — and automatically engages the palette:

```
CTerm CCON: HEADER S:CMenu/Headers/top3.ANS
CTerm FULL
```

The screen always opens with 16 pens and the ANSI colours in
place — so blue directories and grey hidden files work in both
themes, with the same SGR codes. `ANSI` picks the dark terminal
theme (black background, light-grey text); without it the
classic light theme stands (grey background, black text — with
black where ANSI red would sit, the CMenu LIGHT trade). Bright
colours (bold-as-bright, where ANSI art lives) and pen-8 grey
exist in both. Plain (non-ANSI) band art follows the theme's
text colour: light grey on dark, black on light. The palette is *true* ANSI,
so pen 1 (the pen consoles draw text with by default) is red;
CCON accepts a `PEN` option in its open name for exactly this,
and CTerm passes `PEN7/WBPENS` automatically when the console
device is CCON-family: `PEN7` gives light-grey terminal text,
and `WBPENS` retargets plain SGR 30–33 — Workbench pen numbers
to OS programs (C:Ed hardcodes `ESC[31m`, "WB black", for its
body text) — so Ed reads grey-on-dark instead of red while bold
ANSI colours stay put. (Stock CON: rejects opens carrying
options it does not know, so the options are only sent to
CCON-family names — CON: under `ANSI` keeps red text.)

## Configuration

`PROGDIR:cterm.cfg` (plain text, `;` comments, `KEY VALUE`
lines, keys case-insensitive) provides defaults for everything;
the command line overrides it:

```
; CTerm configuration
CONSOLE CCON:
HEADER S:CMenu/Headers/top1.ANS
FOOTER DH0:Art/ltx-footer.txt
ANSI ON
FROM S:Shell-Startup
```

`FULL ON` is also accepted; a `HEADER`/`FOOTER` given on the
command line overrides a config `FULL`.

KingCON as a hardwired handler was tried and dropped during 0.2:
on the AmigaOS 3.2 test install, KingCON 1.3 crashes
(`AN_ASYNCPKT`) even on a plain `NewShell KCON:` with nothing of
CTerm's involved — hence the default remains the standard CON:
handler, and anything else is opt-in by argument.

An earlier build was an application rendering its own console fed
through `PIPE:` — it could run commands but never feed them input,
which is an architectural ceiling for a shell host. It lives in
the git history as the proving ground; the `contest.e` test in
this directory is the experiment that proved the embedded-console
architecture on an AmigaOS 3.2 install and retired it.

## Font and art

CTerm opens in MicroKnight7/7 when `FONTS:` has it (proportional
fonts are refused) and falls back to Topaz/8. The screen carries
the font (`SA_FONT`), so the console inherits it. The art follows
the font: `cterm-mockup-microknight7` is 91 columns wide for the
grid a 7×7 font gives on PAL, `cterm-mockup` is the 80-column
Topaz version. Bands are drawn as blocks — every line at the same
left edge — so the art's alignment survives lines of differing
length.

## Without a Startup-Sequence

If `ENV:` or `T:` is missing at start, CTerm creates them the
standard way (`RAM:Env`, `RAM:T`) and removes only what it made,
on exit — so it works as a bootless emergency shell.

## Files

- `cterm` — prebuilt AmigaOS binary.
- `cterm.e` — the source, Amiga E (~350 lines).
- `cterm-mockup` — 80-column header/footer art (raw high-bit
  bytes, loaded at runtime, not compiled in).
- `cterm-mockup-microknight7` — the 91-column version.
- `contest.e` / `contest` — the architecture proof: bands +
  borderless window + `WINDOW` option + `Execute`.
- `cterm.cfg` — a commented example config; uncomment what you
  want and drop it next to the binary.
- `todo.md` — what's next.

## Building

A prebuilt binary is committed. To build it yourself, compile
`cterm.e` with the E-VO E compiler:

```
evo cterm.e
```

## Verified behaviour

On an AmigaOS 3.2 install (FS-UAE): 0.2 boot-verified end to end
as a bootless startup (screen and art up, MicroKnight7 inherited
by the console, real shell interactive, `Ed` fullscreen in the
frame, `EndShell` tears it down). 0.3 boot-verified with
`CCON:` as the console — scrollback and tab completion inside
the frame, the handler keeping the frame's font and exact grid —
launched from a boot script as
`cterm ccon: >nil: <nil:` after `mount ccon: from
devs:ccon-mountlist`. The `FROM` argument parses (bad-argument
usage verified under vamos) but has not been exercised at boot
yet. 0.4 (user bands, FULL, ANSI palette, the config file) is
built — the config parser is verified under vamos (extracted and
run verbatim), the rest awaits its boot test.
