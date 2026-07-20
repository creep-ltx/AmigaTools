/* mv.e -- Unix-style move for AmigaDOS
   usage: mv [-fb] FROM ... TO
   e.g.   mv oldname newname
          mv work:file work:archive/file
          mv work:file work:archive         (into the directory)
          mv work:file ram:                 (cross-volume: copy+delete)
          mv #?.mod mods:                   (pattern move)
          mv a.txt b.txt c.txt work:stuff   (multiple sources)
          mv -f #?.iff pics:                (replace existing targets)

   Flags are bundled Unix-style (-f, -b, or -fb), matching ls/cp in
   this set; the last path is TO, everything before it is a source.
   `mv ?` still prints usage, as an AmigaDOS command should.

   AmigaDOS Rename() is already a full move within one volume -- a
   rename is just a directory-entry relink, so relocating a file (or
   a whole directory) anywhere on the same volume is a single cheap
   call. That's always tried first, per file. When the target is on a
   different volume, Rename() fails with ERROR_RENAME_ACROSS_DEVICES
   and mv falls back to copy + delete, preserving the protection bits
   and datestamp. Moving a directory across volumes would need a
   recursive copy and is refused (reported, then the batch carries on).

   With more than one source -- multiple FROM arguments or a pattern
   -- TO must be an existing directory. A single plain FROM keeps the
   simple rename/move-into-directory behaviour.

   mv is non-destructive by default: an existing target is skipped,
   and every file that wasn't moved is listed at the end (return code
   5). This is deliberately safer than Unix mv's silent clobber -- it
   is effectively `mv -n`. With -f the target is deleted and replaced.
   With -b the target is renamed to <name>.mvbak first and the move
   proceeds -- but if that backup name is already taken, the file is
   refused: nothing is touched, the reason is printed, and it joins
   the not-moved list (rc 10). The .mvbak suffix belongs to this tool
   (unlike .old, which people hand-craft), so -bf is allowed to mean
   "replace a stale .mvbak" -- -f consistently sanctions destroying
   one thing: alone it's the target, with -b it's the old backup.
   Neither flag touches anything when source and target are the same
   object (checked with SameLock(), otherwise `mv -f file file`
   would delete the only copy) or when the target is a directory.

   Ctrl-C is honoured between files and between copy chunks; a break
   mid-copy removes the partial target file, like any failed copy.

   Errors on one file (source vanished, directory across volumes...)
   are reported and the rest of the batch still runs. Return code is
   the worst that happened: 0 clean, 5 something was skipped, 10 some
   file failed, 20 break.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/dosasl'

CONST BUFSIZE=32768, PATHLEN=512, MAXARGS=32

OBJECT snode
  next:PTR TO snode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

DEF rc, overwrite, backup, toisdir
DEF gto:PTR TO CHAR
DEF gtarget[PATHLEN+4]:ARRAY OF CHAR
DEF gbak[PATHLEN+8]:ARRAY OF CHAR
DEF gpatbuf[1030]:ARRAY OF CHAR
DEF gfib:PTR TO fileinfoblock
DEF gbuf=NIL                       -> copy buffer, allocated on first use
DEF skiphead=NIL:PTR TO snode, skiptail=NIL:PTR TO snode, skipcount

PROC main() HANDLE
  DEF paths[MAXARGS]:ARRAY OF LONG
  DEF npaths, n, i, wild, multi, lock
  DEF node:PTR TO snode

  rc := RETURN_OK

  npaths := parseargs(paths)
  IF npaths < 2 THEN Throw("MV", 'usage: mv [-fb] FROM ... TO')

  gto := paths[npaths-1]
  n   := npaths-1                    -> everything before TO is a source

  wild := FALSE
  FOR i := 0 TO n-1
    IF ParsePatternNoCase(paths[i], gpatbuf, 1024)=1 THEN wild := TRUE
  ENDFOR
  multi := wild OR (n>1)

  NEW gfib
  toisdir := FALSE
  lock := Lock(gto, ACCESS_READ)
  IF lock
    IF Examine(lock, gfib)
      IF gfib.direntrytype > 0 THEN toisdir := TRUE
    ENDIF
    UnLock(lock)
  ENDIF

  IF multi AND (toisdir=FALSE) THEN Throw("MV", 'mv: with several files or a pattern, TO must be an existing directory')

  FOR i:=0 TO n-1 DO dosource(paths[i])

  IF skipcount>0
    WriteF('not moved:\n')
    node := skiphead
    WHILE node
      WriteF('  \s\n', node.path)
      node := node.next
    ENDWHILE
    setrc(RETURN_WARN)
  ENDIF

EXCEPT DO
  IF exception="DOS"
    PrintFault(exceptioninfo, 'mv')
    setrc(RETURN_ERROR)
  ELSEIF exception="BRK"
    WriteF('***Break: mv\n')
    setrc(RETURN_FAIL)
  ELSEIF exception="USG"
    usage()
  ELSEIF exception="ARG"
    WriteF('mv: unknown option (mv ? for usage)\n')
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC usage()
  WriteF('mv 0.4 -- Unix-style move\n')
  WriteF('usage: mv [-fb] FROM ... TO\n')
  WriteF('  -f  force: replace an existing target\n')
  WriteF('  -b  back up an existing target as <name>.mvbak first\n')
ENDPROC

/* Tokenizes E's raw command line, ls-style: whitespace-separated,
   double quotes group, `*` escapes inside quotes (AmigaDOS rules, *n
   and *e get their control meanings). -x bundles set flags; a lone ?
   prints usage; everything else is a path. The last path collected
   is TO, the rest are sources (main sorts that out). */
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
    CASE "f" ; overwrite := TRUE
    CASE "b" ; backup := TRUE
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

/* Runs one FROM argument through MatchFirst()/MatchNext(), which
   handles plain names and patterns uniformly, and moves every match.
   Match errors are reported here; the batch continues. */
PROC dosource(spec:PTR TO CHAR) HANDLE
  DEF ap=NIL:PTR TO anchorpath
  DEF res, path:PTR TO CHAR, ifib:PTR TO fileinfoblock

  ap := New(SIZEOF anchorpath + PATHLEN)
  ap.strlen := PATHLEN-1
  path := ap + SIZEOF anchorpath
  ifib := {ap.info}

  res := MatchFirst(spec, ap)
  WHILE res=0
    checkbreak()
    moveone(path, ifib)
    res := MatchNext(ap)
  ENDWHILE
  IF res<>ERROR_NO_MORE_ENTRIES
    WriteF('mv: \s: ', spec)
    PrintFault(res, NIL)
    setrc(RETURN_ERROR)
  ENDIF

  MatchEnd(ap)
  Dispose(ap)
EXCEPT
  IF ap
    MatchEnd(ap)
    Dispose(ap)
  ENDIF
  ReThrow()
ENDPROC

/* Moves a single already-matched source. Reports its own errors and
   returns, so one bad file never kills the batch; the only exception
   that can escape is "BRK" (Ctrl-C during a copy). */
PROC moveone(srcpath:PTR TO CHAR, ifib:PTR TO fileinfoblock)
  DEF tlock, slock, blk, same, tisdir, err

  AstrCopy(gtarget, gto, PATHLEN)
  IF toisdir THEN AddPart(gtarget, FilePart(srcpath), PATHLEN)

  tlock := Lock(gtarget, ACCESS_READ)
  IF tlock
    -> the source must provably exist, and be a different object,
    -> BEFORE the target's fate is decided -- otherwise OVERWRITE
    -> could delete the target and then have nothing to move in
    slock := Lock(srcpath, ACCESS_READ)
    IF slock=NIL
      err := IoErr()
      UnLock(tlock)
      WriteF('mv: \s: ', srcpath)
      PrintFault(err, NIL)
      setrc(RETURN_ERROR)
      RETURN
    ENDIF
    same := SameLock(slock, tlock)=LOCK_SAME
    UnLock(slock)
    tisdir := FALSE
    IF Examine(tlock, gfib)
      IF gfib.direntrytype > 0 THEN tisdir := TRUE
    ENDIF
    UnLock(tlock)

    IF same
      WriteF('mv: \s: source and target are the same file\n', srcpath)
      setrc(RETURN_ERROR)
      RETURN
    ENDIF
    IF tisdir
      WriteF('mv: cannot overwrite directory \s\n', gtarget)
      setrc(RETURN_ERROR)
      RETURN
    ENDIF
    IF backup
      -> move the target out of the way as <name>.mvbak
      AstrCopy(gbak, gtarget, PATHLEN)
      catbak(gbak)
      blk := Lock(gbak, ACCESS_READ)
      IF blk
        UnLock(blk)
        IF overwrite
          -> BACKUP OVERWRITE: sanctioned to replace a stale .mvbak
          IF DeleteFile(gbak)=FALSE
            err := IoErr()
            WriteF('mv: cannot replace \s: ', gbak)
            PrintFault(err, NIL)
            setrc(RETURN_ERROR)
            RETURN
          ENDIF
        ELSE
          -> refuse: nothing touched, reported now, listed at the end
          WriteF('mv: \s: not moved, \s already exists\n', srcpath, gbak)
          addskip(srcpath)
          setrc(RETURN_ERROR)
          RETURN
        ENDIF
      ENDIF
      IF Rename(gtarget, gbak)=FALSE
        err := IoErr()
        WriteF('mv: cannot back up \s: ', gtarget)
        PrintFault(err, NIL)
        setrc(RETURN_ERROR)
        RETURN
      ENDIF
    ELSEIF overwrite
      IF DeleteFile(gtarget)=FALSE
        err := IoErr()
        WriteF('mv: cannot replace \s: ', gtarget)
        PrintFault(err, NIL)
        setrc(RETURN_ERROR)
        RETURN
      ENDIF
    ELSE
      addskip(srcpath)
      RETURN
    ENDIF
  ENDIF

  IF Rename(srcpath, gtarget) THEN RETURN
  err := IoErr()
  IF err=ERROR_RENAME_ACROSS_DEVICES
    IF ifib.direntrytype > 0
      WriteF('mv: \s: moving a directory across volumes is not supported\n', srcpath)
      setrc(RETURN_ERROR)
    ELSE
      copymove(srcpath, ifib)
    ENDIF
  ELSE
    WriteF('mv: \s: ', srcpath)
    PrintFault(err, NIL)
    setrc(RETURN_ERROR)
  ENDIF
ENDPROC

/* Cross-volume move of one file into gtarget: copy the data, carry
   over protection bits and datestamp, delete the source. A failed or
   broken copy deletes the partial target file. */
PROC copymove(srcpath:PTR TO CHAR, ifib:PTR TO fileinfoblock) HANDLE
  DEF fhin=NIL, fhout=NIL, n, partial, err

  partial := FALSE

  IF gbuf=NIL THEN gbuf := New(BUFSIZE)

  fhin := Open(srcpath, MODE_OLDFILE)
  IF fhin=NIL THEN Throw("CPY", IoErr())
  fhout := Open(gtarget, MODE_NEWFILE)
  IF fhout=NIL THEN Throw("CPY", IoErr())
  partial := TRUE

  REPEAT
    checkbreak()
    n := Read(fhin, gbuf, BUFSIZE)
    IF n > 0
      IF Write(fhout, gbuf, n) <> n THEN Throw("CPY", IoErr())
    ENDIF
  UNTIL n <= 0
  IF n < 0 THEN Throw("CPY", IoErr())

  Close(fhout)
  fhout := NIL
  Close(fhin)
  fhin := NIL
  partial := FALSE

  -> best-effort: a filesystem that can't store these shouldn't fail the move
  SetProtection(gtarget, ifib.protection)
  SetFileDate(gtarget, {ifib.datestamp})

  IF DeleteFile(srcpath)=FALSE
    err := IoErr()
    WriteF('mv: copied to \s but could not delete \s: ', gtarget, srcpath)
    PrintFault(err, NIL)
    setrc(RETURN_WARN)
  ENDIF

EXCEPT
  IF fhout THEN Close(fhout)
  IF fhin THEN Close(fhin)
  IF partial THEN DeleteFile(gtarget)
  IF exception="CPY"
    WriteF('mv: \s: ', srcpath)
    PrintFault(exceptioninfo, NIL)
    setrc(RETURN_ERROR)
  ELSE
    ReThrow()
  ENDIF
ENDPROC

/* Appends '.mvbak' to a null-terminated path in place; the buffer is
   sized PATHLEN+8 so this always fits. */
PROC catbak(s:PTR TO CHAR)
  DEF i
  i := 0
  WHILE s[i] DO i := i+1
  s[i]   := "."
  s[i+1] := "m"
  s[i+2] := "v"
  s[i+3] := "b"
  s[i+4] := "a"
  s[i+5] := "k"
  s[i+6] := 0
ENDPROC

PROC addskip(srcpath:PTR TO CHAR)
  DEF node:PTR TO snode
  NEW node
  AstrCopy(node.path, srcpath, PATHLEN)
  node.next := NIL
  IF skiphead=NIL
    skiphead := node
  ELSE
    skiptail.next := node
  ENDIF
  skiptail := node
  skipcount := skipcount+1
ENDPROC

version: CHAR '$VER: mv 0.4 (20.7.26) E build',0
