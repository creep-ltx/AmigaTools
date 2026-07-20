/* mkdir.e -- Unix-style make directory for AmigaDOS
   usage: mkdir [-p] DIR ...
   e.g.   mkdir work:newdir
          mkdir a b c                    (several at once)
          mkdir -p work:a/b/c            (create missing parents)
          mkdir -p ram:deep/nested/dir

   AmigaDOS MakeDir already creates a single directory; the point of
   this one is -p and Unix muscle memory. Flags are bundled -flags
   like ls/cp/mv; `mkdir ?` prints usage.

   Without -p each DIR is created directly: its parent must already
   exist, and an existing DIR is an error (like Unix mkdir).

   With -p every missing directory along the path is created -- so
   `mkdir -p work:a/b/c` makes a, then a/b, then a/b/c -- and an
   already-existing directory is NOT an error (the whole point of -p).
   A path component that already exists as a *file* is an error: you
   can't descend through it. Device/volume names (the part before ':')
   are never created, only descended into.

   DIR names are literal -- no pattern expansion: `mkdir "#?"` makes a
   directory called "#?", not one per match. The shell doesn't expand
   them either; on AmigaDOS each command matches its own patterns, and
   mkdir has nothing to match against.

   Ctrl-C is honoured between directories. Errors on one DIR are
   reported and the rest still run. Return code is the worst that
   happened: 0 clean, 10 some directory failed, 20 break.
*/

MODULE 'dos/dos', 'dos/dosextens'

CONST PATHLEN=512, MAXARGS=32

DEF rc, parents
DEF gfib:PTR TO fileinfoblock

PROC main() HANDLE
  DEF paths[MAXARGS]:ARRAY OF LONG
  DEF npaths, i

  rc := RETURN_OK

  npaths := parseargs(paths)
  IF npaths < 1 THEN Throw("MK", 'usage: mkdir [-p] DIR ...')

  NEW gfib

  FOR i := 0 TO npaths-1
    checkbreak()
    IF parents
      makeparents(paths[i])
    ELSE
      makeone(paths[i])
    ENDIF
  ENDFOR

EXCEPT DO
  IF exception="DOS"
    PrintFault(exceptioninfo, 'mkdir')
    setrc(RETURN_ERROR)
  ELSEIF exception="BRK"
    WriteF('***Break: mkdir\n')
    setrc(RETURN_FAIL)
  ELSEIF exception="USG"
    usage()
  ELSEIF exception="ARG"
    WriteF('mkdir: unknown option (mkdir ? for usage)\n')
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC usage()
  WriteF('mkdir 0.1 -- Unix-style make directory\n')
  WriteF('usage: mkdir [-p] DIR ...\n')
  WriteF('  -p  create parent directories as needed; existing is not an error\n')
ENDPROC

/* Tokenizes E's raw command line, ls-style: whitespace-separated,
   double quotes group, `*` escapes inside quotes (AmigaDOS rules, *n
   and *e get their control meanings). -x bundles set flags; a lone ?
   prints usage; everything else is a directory name. */
PROC parseargs(paths:PTR TO LONG)
  DEF p:PTR TO CHAR, np, tl, c, inq, done
  DEF t[PATHLEN]:ARRAY OF CHAR
  DEF s:PTR TO CHAR

  np := 0
  p := arg
  WHILE p[]
    WHILE (p[] > 0) AND (p[] <= 32) DO p++
    IF p[] = 0 THEN RETURN np

    tl := 0
    inq := FALSE
    done := FALSE
    WHILE done = FALSE
      c := p[]
      IF c = 0
        done := TRUE
      ELSEIF inq
        IF c = 34                            -> closing quote
          inq := FALSE
          p++
        ELSEIF c = 42                        -> * escape
          p++
          c := p[]
          IF c = 0
            done := TRUE
          ELSE
            IF (c = "n") OR (c = "N") THEN c := 10
            IF (c = "e") OR (c = "E") THEN c := 27
            t[tl] := c
            tl++
            p++
          ENDIF
        ELSE
          t[tl] := c
          tl++
          p++
        ENDIF
      ELSE
        IF c <= 32
          done := TRUE
        ELSEIF c = 34                        -> opening quote
          inq := TRUE
          p++
        ELSE
          t[tl] := c
          tl++
          p++
        ENDIF
      ENDIF
      IF tl >= (PATHLEN-1) THEN done := TRUE
    ENDWHILE
    t[tl] := 0

    IF tl > 0
      IF (t[0] = "-") AND (tl > 1)
        setflags(t)
      ELSEIF (t[0] = "?") AND (tl = 1)
        Throw("USG", 0)
      ELSE
        IF np < MAXARGS
          s := String(tl)
          StrCopy(s, t)
          paths[np] := s
          np++
        ENDIF
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC np

PROC setflags(t:PTR TO CHAR)
  DEF i, c
  i := 1
  WHILE (c := t[i]) <> 0
    SELECT c
    CASE "p" ; parents := TRUE
    DEFAULT  ; Throw("ARG", c)
    ENDSELECT
    i++
  ENDWHILE
ENDPROC

PROC setrc(v)
  IF v>rc THEN rc := v
ENDPROC

PROC checkbreak()
  IF SetSignal(0, SIGBREAKF_CTRL_C) AND SIGBREAKF_CTRL_C THEN Throw("BRK", 0)
ENDPROC

/* Plain mode: create the directory directly. Its parent must exist,
   and an already-existing target is an error -- both surface as the
   dos.library fault (Object already exists / Object not found). */
PROC makeone(path:PTR TO CHAR)
  DEF lock
  lock := CreateDir(path)
  IF lock
    UnLock(lock)
    RETURN
  ENDIF
  WriteF('mkdir: \s: ', path)
  PrintFault(IoErr(), NIL)
  setrc(RETURN_ERROR)
ENDPROC

/* -p mode: create every missing directory along the path. Splits on
   '/' (and skips the 'device:' head), creating each prefix in turn;
   an intermediate that already exists is fine, a hard failure aborts
   just this path. Parent-hop components (an empty piece from a
   leading or doubled '/') are stepped over, not created. */
PROC makeparents(path:PTR TO CHAR)
  DEF w[PATHLEN]:ARRAY OF CHAR
  DEF i, start, c, len

  AstrCopy(w, path, PATHLEN)
  len := StrLen(w)
  IF len = 0 THEN RETURN

  start := 0
  i := 0
  WHILE i < len
    c := w[i]
    IF c = ":"
      start := i+1                         -> device head: descend, don't create
    ELSEIF c = "/"
      IF i > start                         -> a real name ends here
        w[i] := 0
        IF makestep(w) = FALSE
          w[i] := "/"
          RETURN                           -> hard error, already reported
        ENDIF
        w[i] := "/"
      ENDIF
      start := i+1
    ENDIF
    i := i+1
  ENDWHILE

  IF len > start THEN makefinal(w)         -> the last component
ENDPROC

/* An intermediate directory under -p: already-exists is success.
   Returns FALSE (after reporting) only on a real failure. */
PROC makestep(path:PTR TO CHAR)
  DEF lock, err
  lock := CreateDir(path)
  IF lock
    UnLock(lock)
    RETURN TRUE
  ENDIF
  err := IoErr()
  IF err = ERROR_OBJECT_EXISTS THEN RETURN TRUE
  WriteF('mkdir: \s: ', path)
  PrintFault(err, NIL)
  setrc(RETURN_ERROR)
  RETURN FALSE
ENDPROC

/* The final component under -p: already-exists is success only if it
   really is a directory; an existing file of that name is an error. */
PROC makefinal(path:PTR TO CHAR)
  DEF lock, err
  lock := CreateDir(path)
  IF lock
    UnLock(lock)
    RETURN
  ENDIF
  err := IoErr()
  IF err = ERROR_OBJECT_EXISTS
    IF isdir(path) = FALSE
      WriteF('mkdir: \s: exists and is not a directory\n', path)
      setrc(RETURN_ERROR)
    ENDIF
    RETURN
  ENDIF
  WriteF('mkdir: \s: ', path)
  PrintFault(err, NIL)
  setrc(RETURN_ERROR)
ENDPROC

PROC isdir(path:PTR TO CHAR)
  DEF lock, r
  r := FALSE
  lock := Lock(path, ACCESS_READ)
  IF lock
    IF Examine(lock, gfib)
      IF gfib.direntrytype > 0 THEN r := TRUE
    ENDIF
    UnLock(lock)
  ENDIF
ENDPROC r

version: CHAR '$VER: mkdir 0.1 (20.7.26) E build',0
