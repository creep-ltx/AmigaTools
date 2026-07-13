/* mv.e -- Unix-style move for AmigaDOS
   Usage: mv FROM/A/M TO/A [OVERWRITE]
   e.g.   mv oldname newname
          mv work:file work:archive/file
          mv work:file work:archive         (into the directory)
          mv work:file ram:                 (cross-volume: copy+delete)
          mv #?.mod mods:                   (pattern move)
          mv a.txt b.txt c.txt work:stuff   (multiple sources)
          mv #?.iff pics: OVERWRITE         (replace existing targets)

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

   An existing target is skipped by default (skipped files are listed
   at the end, return code 5). With OVERWRITE the target is deleted
   and replaced instead -- unless source and target are the same
   object (checked with SameLock(), otherwise `mv file file OVERWRITE`
   would delete the only copy), or the target is a directory.

   Ctrl-C is honoured between files and between copy chunks; a break
   mid-copy removes the partial target file, like any failed copy.

   Errors on one file (source vanished, directory across volumes...)
   are reported and the rest of the batch still runs. Return code is
   the worst that happened: 0 clean, 5 something was skipped, 10 some
   file failed, 20 break.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/rdargs', 'dos/dosasl'

CONST BUFSIZE=32768, PATHLEN=512

OBJECT snode
  next:PTR TO snode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

DEF rc, overwrite, toisdir
DEF gto:PTR TO CHAR
DEF gtarget[PATHLEN+4]:ARRAY OF CHAR
DEF gpatbuf[1030]:ARRAY OF CHAR
DEF gfib:PTR TO fileinfoblock
DEF gbuf=NIL                       -> copy buffer, allocated on first use
DEF skiphead=NIL:PTR TO snode, skiptail=NIL:PTR TO snode, skipcount

PROC main() HANDLE
  DEF rdargs=NIL:PTR TO rdargs
  DEF argarray[3]:ARRAY OF LONG
  DEF fromlist:PTR TO LONG
  DEF n, i, wild, multi, lock
  DEF node:PTR TO snode

  rc := RETURN_OK

  rdargs := ReadArgs('FROM/A/M,TO/A,OVERWRITE/S', argarray, NIL)
  IF rdargs=NIL THEN Throw("DOS", IoErr())

  fromlist  := argarray[0]
  gto       := argarray[1]
  overwrite := argarray[2]

  n := 0
  wild := FALSE
  WHILE fromlist[n]
    IF ParsePatternNoCase(fromlist[n], gpatbuf, 1024)=1 THEN wild := TRUE
    n := n+1
  ENDWHILE
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

  FOR i:=0 TO n-1 DO dosource(fromlist[i])

  IF skipcount>0
    WriteF('skipped (already exists):\n')
    node := skiphead
    WHILE node
      WriteF('  \s\n', node.path)
      node := node.next
    ENDWHILE
    setrc(RETURN_WARN)
  ENDIF

EXCEPT DO
  IF rdargs THEN FreeArgs(rdargs)
  IF exception="DOS"
    PrintFault(exceptioninfo, 'mv')
    setrc(RETURN_ERROR)
  ELSEIF exception="BRK"
    WriteF('***Break: mv\n')
    setrc(RETURN_FAIL)
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
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
  DEF tlock, slock, same, tisdir, err

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
    IF overwrite=FALSE
      addskip(srcpath)
      RETURN
    ENDIF
    IF DeleteFile(gtarget)=FALSE
      WriteF('mv: cannot replace \s: ', gtarget)
      PrintFault(IoErr(), NIL)
      setrc(RETURN_ERROR)
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
  DEF fhin=NIL, fhout=NIL, n, partial

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
    WriteF('mv: copied to \s but could not delete \s: ', gtarget, srcpath)
    PrintFault(IoErr(), NIL)
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

version: CHAR '$VER: mv 0.2 (13.7.26) E build',0
