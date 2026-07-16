# CShell

A real AmigaDOS shell inside a full-screen LTX frame.

## How it works

CShell opens its own screen (like Workbench, made public as
`CSHELL`), draws header and footer art bands loaded from a mockup
file, opens a *borderless* window covering exactly the space
between them — and hands that window to the standard console
handler using `CON:`'s documented `WINDOW 0xaddr` option. The
handler never opens a window of its own, so there is no chrome to
fight. `Execute('', console, NIL)` then starts a real, interactive
UserShell in it.

Because the console is the OS's own, everything simply works:
stdin and interactive prompts, raw mode, `More`, `Ed` (menus and
all), keymaps, shell history and line editing, scripts,
`S:Shell-Startup`. There is no emulation layer — CShell is to this
console what the boot Shell is to a CON: window, plus the frame.

`EndShell` (or `EndCLI`) ends the shell and CShell closes behind
it.

KingCON as the handler was tried and dropped: on the AmigaOS 3.2
test install, KingCON 1.3 crashes (`AN_ASYNCPKT`) even on a plain
`NewShell KCON:` with nothing of CShell's involved, so CShell uses
the standard CON: handler, full stop.

An earlier CShell was an application rendering its own console fed
through `PIPE:` — it could run commands but never feed them input,
which is an architectural ceiling for a shell. It lives in the git
history as the proving ground; the `contest.e` test in this
directory is the experiment that proved the embedded-console
architecture on a real AmigaOS 3.2 install and retired it.

## Font and art

CShell opens in MicroKnight7/7 when `FONTS:` has it (proportional
fonts are refused) and falls back to Topaz/8. The screen carries
the font (`SA_FONT`), so the console inherits it. The art follows
the font: `cshell-mockup-microknight7` is 91 columns wide for the
grid a 7×7 font gives on PAL, `cshell-mockup` is the 80-column
Topaz version. Bands are drawn as blocks — every line at the same
left edge — so the art's alignment survives lines of differing
length.

## Without a Startup-Sequence

If `ENV:` or `T:` is missing at start, CShell creates them the
standard way (`RAM:Env`, `RAM:T`) and removes only what it made,
on exit — so it works as a bootless emergency shell.

## Files

- `cshell` — prebuilt AmigaOS binary.
- `cshell.e` — the source, Amiga E (~300 lines).
- `cshell-mockup` — 80-column header/footer art (raw high-bit
  bytes, loaded at runtime, not compiled in).
- `cshell-mockup-microknight7` — the 91-column version.
- `contest.e` / `contest` — the architecture proof: bands +
  borderless window + `WINDOW` option + `Execute`.
- `todo.md` — what's next.

## Building

A prebuilt binary is committed. To build it yourself, compile
`cshell.e` with the E-VO E compiler:

```
evo cshell.e
```

## Verified behaviour

On an AmigaOS 3.2 install (FS-UAE), via the `contest` proof: the
console handler accepted the handed window (borderless, on the
custom screen, art intact above and below), a real shell ran in it
(`dir`, prompt, history), and `Ed` ran fullscreen inside the frame
with working menus — raw mode confirmed. The `cshell` binary
itself (same architecture plus the real art, MicroKnight7 and the
screen font) is compiled but awaits its first boot test.
