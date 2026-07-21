-> sbresizetest.e - harness for audit finding B2
->
-> B2: the scrollback ring's invariant is
->        sbcnt <= sbmax - rows
-> ("history lines above the screen" plus "the visible screen" cannot
-> exceed the ring). screenscroll() enforces it on the way up, with
->        IF sbcnt < (sbmax - rows) THEN sbcnt := sbcnt + 1
-> but NOTHING re-establishes it when doresize() makes `rows` BIGGER
-> underneath an already-large sbcnt. scrollview() then clamps viewoff
-> to a too-large sbcnt, and redraw()'s idx = sbtop - viewoff + r walks
-> back past the oldest retained line into ring rows the enlarged
-> screen has already recycled.
->
-> What this proves: the model arithmetic only. Every pixel call is
-> dropped. Whether the glass matches still needs the boot test.
->
-> Transcribed from ccon-handler.e 1.2b3: screenscroll, scrollview,
-> and the ring indexing redraw() uses. Each ring row carries a line
-> NUMBER instead of text, so a corrupt view is visible as a sequence
-> that jumps or repeats rather than counting by one.
->
-> Build: ecompile sbresizetest.e sbresizetest
-> Run:   vamos sbresizetest

MODULE 'dos/dos'

CONST COLS=10, SBMAX=10

DEF rowid[10]:ARRAY OF LONG,    -> the line number living in each ring row
    sbtop, sbcnt, rows, viewoff,
    fixb2,
    cy,
    nextline

-> ring index of visible row r
PROC ridx(r)
  DEF i
  i := sbtop + r
  WHILE i >= SBMAX
    i := i - SBMAX
  ENDWHILE
ENDPROC i

PROC clearrow(r)
  rowid[ridx(r)] := 0
ENDPROC

-> ccon-handler.e screenscroll(), model half
PROC screenscroll()
  sbtop := sbtop + 1
  IF sbtop >= SBMAX THEN sbtop := 0
  IF sbcnt < (SBMAX - rows) THEN sbcnt := sbcnt + 1
  clearrow(rows - 1)
ENDPROC

-> one line of client output, the way outnl() actually does it: write
-> at the cursor row, then advance, and only scroll once the cursor
-> would leave the screen. (An earlier draft scrolled FIRST and so
-> filled a fresh screen bottom-up, which made the low-history case
-> look broken in every mode - a harness artefact, not a console one.)
PROC emit()
  rowid[ridx(cy)] := nextline
  nextline := nextline + 1
  cy := cy + 1
  IF cy >= rows
    screenscroll()
    cy := rows - 1
  ENDIF
ENDPROC

-> ccon-handler.e scrollview(), clamping half
PROC scrollview(delta)
  viewoff := viewoff + delta
  IF viewoff > sbcnt THEN viewoff := sbcnt
  IF viewoff < 0 THEN viewoff := 0
ENDPROC

-> ccon-handler.e doresize(), the part under test.
->
-> fixb2 = 0  CURRENT. On SHRINK the real proc advances sbtop and
->            pushes the rows above the cursor into history. On GROW
->            it does nothing at all - so the visible window simply
->            extends DOWNWARD over ring rows that have already been
->            recycled, and sbcnt is left above its ceiling.
->
-> fixb2 = 1  the clamp the audit proposed: sbcnt := sbmax - rows.
->            Rejected - see the run. It only changes how far back you
->            may scroll; the newly exposed rows are still recycled
->            content, and it actually makes the far end of the
->            scrollback WORSE by cutting off rows that were readable.
->
-> fixb2 = 2  the symmetric grow: for each row gained, step sbtop BACK
->            one and drop sbcnt by one, pulling history down into the
->            new space - the exact mirror of the shrink loop already
->            in doresize, and it keeps sbcnt <= sbmax - rows for free.
->            Rows that history cannot fill are genuinely new and get
->            cleared, so they show blank rather than recycled text.
PROC doresize(newrows)
  DEF k, oldrows, r
  viewoff := 0
  oldrows := rows
  rows := newrows
  IF fixb2 = 1
    IF sbcnt > (SBMAX - rows) THEN sbcnt := SBMAX - rows
    IF sbcnt < 0 THEN sbcnt := 0
  ELSEIF fixb2 = 2
    k := rows - oldrows
    IF k > 0
      WHILE (k > 0) AND (sbcnt > 0)
        sbtop := sbtop - 1
        IF sbtop < 0 THEN sbtop := SBMAX - 1
        sbcnt := sbcnt - 1
        cy := cy + 1
        k := k - 1
      ENDWHILE
      -> k rows left over: no history to pull, so they are new blank
      -> rows at the BOTTOM and must not show recycled content
      FOR r := rows - k TO rows - 1
        clearrow(r)
      ENDFOR
    ENDIF
  ENDIF
ENDPROC

-> what redraw() would paint, top row first
PROC viewline(r)
  DEF i
  i := sbtop - viewoff + r
  WHILE i < 0
    i := i + SBMAX
  ENDWHILE
  WHILE i >= SBMAX
    i := i - SBMAX
  ENDWHILE
ENDPROC rowid[i]

-> A view is sound when its written rows count by exactly one, top to
-> bottom, and any blank rows come only AFTER them (a window taller
-> than the session is legitimately blank at the bottom). A jump, a
-> repeat, or a blank with text under it all mean the window read a
-> ring row that had already been recycled beneath it.
PROC checkview()
  DEF r, prev, v, bad=0, seenblank=FALSE
  prev := -1
  FOR r := 0 TO rows - 1
    v := viewline(r)
    IF v = 0
      seenblank := TRUE
    ELSE
      IF seenblank
        bad := bad + 1        -> text below a blank: recycled row
      ELSEIF prev >= 0
        IF v <> (prev + 1) THEN bad := bad + 1
      ENDIF
      prev := v
    ENDIF
  ENDFOR
ENDPROC bad

PROC showview(tag)
  DEF r, s[128]:STRING, t[16]:STRING
  StrCopy(s, '')
  FOR r := 0 TO rows - 1
    StringF(t, ' \d', viewline(r))
    StrAdd(s, t)
  ENDFOR
  WriteF('    \s rows=\d sbcnt=\d viewoff=\d view:\s\n',
         tag, rows, sbcnt, viewoff, s)
ENDPROC

-> lines = how much output the session produced before the resize;
-> few lines means little or no history to pull down, which is the
-> case that exposes whether the new bottom rows get cleared
PROC scenario(fix, lines, tag)
  DEF r, badlive, badback
  fixb2 := fix
  FOR r := 0 TO SBMAX - 1
    rowid[r] := 0
  ENDFOR
  sbtop := 0
  sbcnt := 0
  viewoff := 0
  rows := 5
  cy := 0
  nextline := 1
  FOR r := 1 TO lines
    emit()
  ENDFOR
  doresize(8)                   -> the user drags the window bigger
  showview('live: ')
  badlive := checkview()
  scrollview(999)
  showview('back: ')
  badback := checkview()
  WriteF('    \s bad rows: live=\d scrolled=\d\n', tag, badlive, badback)
ENDPROC badlive + badback

PROC main()
  DEF cur, clamp, sym, cur2, clamp2, sym2
  WriteF('sbresizetest - audit B2 (window grown, ring not adjusted)\n')
  WriteF('ring holds \d rows; window 5 rows -> 8\n', SBMAX)

  WriteF('\n### full scrollback (30 lines through a \d-row ring)\n', SBMAX)
  WriteF('=== CURRENT: grow does nothing ===\n')
  cur := scenario(0, 30, 'current')
  WriteF('=== audit proposal: clamp sbcnt only ===\n')
  clamp := scenario(1, 30, 'clamp  ')
  WriteF('=== symmetric grow: pull history down ===\n')
  sym := scenario(2, 30, 'symgrow')

  WriteF('\n### barely any history (3 lines)\n')
  WriteF('=== CURRENT ===\n')
  cur2 := scenario(0, 3, 'current')
  WriteF('=== audit proposal ===\n')
  clamp2 := scenario(1, 3, 'clamp  ')
  WriteF('=== symmetric grow ===\n')
  sym2 := scenario(2, 3, 'symgrow')

  WriteF('\n---------------------------------------------\n')
  WriteF('totals  current=\d  clamp=\d  symgrow=\d\n',
         cur + cur2, clamp + clamp2, sym + sym2)
  IF (sym + sym2) = 0
    WriteF('symmetric grow is the only sound option.\n')
    IF (clamp + clamp2) >= (cur + cur2)
      WriteF('the audit proposal is NOT a fix - it is no better than\n')
      WriteF('doing nothing. B2 needs rewriting before it is applied.\n')
    ENDIF
  ELSE
    WriteF('symmetric grow still leaves \d bad rows - not solved yet\n',
           sym + sym2)
  ENDIF
ENDPROC
