# CFile — missing features

What a file manager should have that CFile does not, roughly in the
order the friction hits a daily driver. Keys marked (?) are
suggestions, not decided.

## 0.3b1 — inside archives (done)

`Right`/`Enter` on an lha archive goes inside it and the pane works
like a directory; `v e c m r n Del` all work on members. `lha v` is
parsed once on entry into a per-pane member cache and each level is
filtered out of that, so navigating costs no lha runs. Writes go
through LhA and rewrite the archive; the bar steps per file, driven
by counting lha's own per-file output over an async `PIPE:`.

Four LhA 2.15 behaviours cost boot tests and are worth remembering:

- `lha l` is the **terse** flag layout that hides paths — the listing
  to parse is `lha v`, whose Name column is the full stored path.
- Its Ratio field is variable width (`40.5%` vs `100.0%`), so the
  columns shift row to row: parse by **field count**, never by column.
- Fed `NIL:` for input, lha cannot create a missing output directory
  (it wants to prompt), so extraction into a subdirectory failed until
  CFile pre-built the path itself. `-M` is also needed or lha tries to
  autoshow readme/`.doc` members into a `con:` window that never opens.
- `lha a` flattens an explicit `sub/file` argument to `file`, and
  skips a member that already exists. Paths survive only through `-r`
  recursion of a directory, and replacing means delete-then-add.

Follow-ups:

- [ ] **lzx / zip inside** — the architecture is format-agnostic apart
      from the listing parser and four command shapes; each tool's
      list format and per-member add/delete want the same dump-driven
      verification lha got. lzx's member delete is the doubtful one.
- [ ] **Batch the repacking** — every single change re-streams the
      whole archive through lha. Fine at Amiga sizes, but editing
      three members repacks three times; a "commit on exit" would
      collapse that into one.
- [ ] **Per-byte progress inside a file** — the bar ticks once per
      file, so one big member is a single jump. lha prints a
      `(done/total)` byte counter that could drive it finer.

## 0.3 candidates — "fast in the hand"

- [ ] **`/` filter with live narrowing** — `/` enters a prompt mode
      (like `:`), so every key is text there and no hotkey is lost;
      the pane narrows live while typing, Esc restores the full
      listing, Enter keeps the selection on the match. Plain
      type-ahead cannot work in a hotkey FM — `/` is the type-ahead.
- [ ] **Manual rescan** — panes go stale when a shell or Workbench
      changes a directory behind CFile's back; one key (?) re-reads
      both panes.
- [ ] **Mark all / none / invert / by pattern** — Space-only marking
      makes big bulk ops tedious. Pattern marking (`#?.mod`) is
      MatchPattern over the pane; the marks machinery already
      exists. Keys (?): maybe a/A for all/none, * for pattern.
- [ ] **.info sidecars** — copy/move/delete/rename `foo` should
      offer to take `foo.info` along (a config toggle, DOpus-style
      "Icons"). Without it, moved drawers and tools silently lose
      their icons. The most Amiga-specific gap.
- [ ] **`s` sort options** — by name/size/date, reversed; dirs stay
      first. (Long deferred.)
- [ ] **Free space + marked totals** — bytes free on the volume and
      the byte total of the marked set, in the border row. Info()
      is cheap.
- [ ] **`KEYMAP` config key** — e.g. `KEYMAP s` for a Swedish
      keymap when started without a Startup-Sequence. `C:` is a
      standard boot assign (present even bootless, unlike ENV:/T:),
      so running C:SetKeyboard at startup — before the window
      opens, so key translation uses it from the first keystroke —
      should do it. Verify the mechanism (SetKeyboard vs
      keymap.library directly) against the autodocs; vamos cannot
      test this, needs a bootless FS-UAE boot test.

## Nice, cheap, no hurry

- [ ] **Comment editing** — the `i` window shows the FileNote but
      cannot edit it, though it already edits protection bits live.
      A natural extension of that window.
- [ ] **Directory size on demand** — `i` on a directory byte-counts
      it; treestat() already does exactly this walk for the
      progress bar.
- [ ] **Size/date columns** — the panes show names only; a toggle
      for a size or date column could ride along with `s` sorting.

## Bigger, later

- [ ] **Find file** — recursive name search from the current
      directory, results as a pane or a jump.
- [ ] **Text search inside files** — grep-style, results in the
      console frame.
- [ ] **Mouse support** — select/mark/double-click-open; the tool
      is keyboard-driven by design, so this is comfort, not core.
- [ ] **DOpus-style icon info** — icon type, default tool, tooltypes
      in the `i` window. (Deferred since 0.1.)
- [ ] **Configurable user commands** — DOpus-buttons territory:
      user-defined keys running user-defined commands on the
      selection. Wants the config file to grow a section.

## Code notes, when a reason appears

- [ ] **ltxui.m split** — the frame composer / grid / console
      machinery moves to a module when a second tool wants it, not
      before.
- [ ] **StartNotify on cfile.config** — external edits (from a
      shell editor) could trigger the live reload the in-CFile
      editor already does. FS-UAE directory-drive support for
      notification is unverified.
