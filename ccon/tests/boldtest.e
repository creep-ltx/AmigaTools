-> boldtest.e - Audit8 J27: does bold leave a pixel behind?
-> boldtest OPENSPEC (e.g. boldtest XC1:0/40/400/120/bold)
->
-> Row 1: four BOLD M's, then CR and the same four M's PLAIN over them.
-> Row 3: four plain M's, never bold - the reference.
-> Bold is drawn one pixel wider (the font's smear), so the bold M's
-> ink reaches the first pixel column of the cell after them; if only
-> the four cells are repainted plain, that column keeps its ink. Grab
-> the window while it waits (5 s) and compare row 1 with row 3 one
-> cell to the right of the M's: any ink there on row 1 is the leftover.
->
-> Build: ecompile boldtest.e boldtest

MODULE 'dos/dos'

PROC main()
  DEF fh, cr[2]:ARRAY OF CHAR
  IF arg[0] = 0
    WriteF('usage: boldtest OPENSPEC\n')
    RETURN 10
  ENDIF
  fh := Open(arg, MODE_NEWFILE)
  IF fh = NIL THEN RETURN 10
  cr[0] := 13
  Write(fh, '\n\e[1mMMMM\e[0m', 13)  -> row 1: bold
  Delay(25)                       -> painted bold first, for certain
  Write(fh, cr, 1)                -> back to column 0 of row 1
  Write(fh, 'MMMM', 4)            -> plain over the same four cells
  Write(fh, '\n\nMMMM', 6)        -> row 3: the plain reference
  Delay(250)                      -> five seconds to grab the window
  Close(fh)
ENDPROC
