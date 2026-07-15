# CFile — missing features

What a file manager should have that CFile does not, roughly in the
order the friction hits a daily driver. Keys marked (?) are
suggestions, not decided.

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
