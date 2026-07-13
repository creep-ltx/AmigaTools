/* mv.e -- Unix-style move for AmigaDOS
   Usage: mv <from> <to>
   e.g.   mv oldname newname
          mv work:file work:archive/file
          mv work:file work:archive        (into the directory)
          mv work:file ram:                 (cross-volume: copy+delete)

   AmigaDOS Rename() is already a full move within one volume -- a
   rename is just a directory-entry relink, so relocating a file (or
   a whole directory) anywhere on the same volume is a single cheap
   call. That's always tried first. When the target is on a different
   volume, Rename() fails with ERROR_RENAME_ACROSS_DEVICES and mv
   falls back to copy + delete, preserving the protection bits and
   datestamp. Moving a directory across volumes would need a
   recursive copy and is refused for now.

   If TO is an existing directory, FROM is moved into it under its
   own name (like Unix mv), via AddPart()/FilePart() so trailing
   '/' and ':' are handled properly.

   An existing file is never overwritten: the same-volume case fails
   naturally with ERROR_OBJECT_EXISTS (Rename() refuses), and the
   copy fallback checks explicitly first, since MODE_NEWFILE would
   otherwise truncate the target without asking.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/rdargs'

CONST BUFSIZE=32768

DEF rc

PROC main() HANDLE
  DEF rdargs=NIL:PTR TO rdargs
  DEF argarray[2]:ARRAY OF LONG
  DEF from:PTR TO CHAR
  DEF dest[516]:ARRAY OF CHAR
  DEF fib=NIL:PTR TO fileinfoblock
  DEF lock=NIL
  DEF err

  rc := RETURN_OK

  rdargs := ReadArgs('FROM/A,TO/A', argarray, NIL)
  IF rdargs=NIL THEN Throw("DOS", IoErr())

  from := argarray[0]
  AstrCopy(dest, argarray[1], 512)

  -> if TO is an existing directory, the real target is TO/<filename>
  NEW fib
  lock := Lock(dest, ACCESS_READ)
  IF lock
    IF Examine(lock, fib)
      IF fib.direntrytype > 0 THEN AddPart(dest, FilePart(from), 512)
    ENDIF
    UnLock(lock)
    lock := NIL
  ENDIF

  IF Rename(from, dest)=FALSE
    err := IoErr()
    IF err=ERROR_RENAME_ACROSS_DEVICES
      crossmove(from, dest)
    ELSE
      Throw("DOS", err)
    ENDIF
  ENDIF

EXCEPT DO
  IF lock THEN UnLock(lock)
  IF fib THEN END fib
  IF rdargs THEN FreeArgs(rdargs)
  IF exception="DOS"
    PrintFault(exceptioninfo, 'mv')
    rc := RETURN_ERROR
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    rc := RETURN_ERROR
  ENDIF
  CleanUp(rc)
ENDPROC

/* Cross-volume move: copy the data, carry over protection bits and
   datestamp, then delete the source. A failed copy deletes the
   partial target file so an error never leaves half a file behind.
   Cleans up its own locks/handles, then rethrows to main's handler. */
PROC crossmove(from:PTR TO CHAR, dest:PTR TO CHAR) HANDLE
  DEF sfib=NIL:PTR TO fileinfoblock
  DEF slock=NIL, dlock=NIL, fhin=NIL, fhout=NIL
  DEF buf=NIL, n, prot, partial

  partial := FALSE

  slock := Lock(from, ACCESS_READ)
  IF slock=NIL THEN Throw("DOS", IoErr())
  NEW sfib
  IF Examine(slock, sfib)=FALSE THEN Throw("DOS", IoErr())
  IF sfib.direntrytype > 0 THEN Throw("MV", 'mv: moving a directory across volumes is not supported')
  prot := sfib.protection
  UnLock(slock)
  slock := NIL

  -> MODE_NEWFILE would silently truncate an existing target, so
  -> refuse first, matching Rename()'s same-volume behaviour
  dlock := Lock(dest, ACCESS_READ)
  IF dlock THEN Throw("DOS", ERROR_OBJECT_EXISTS)

  fhin := Open(from, MODE_OLDFILE)
  IF fhin=NIL THEN Throw("DOS", IoErr())
  fhout := Open(dest, MODE_NEWFILE)
  IF fhout=NIL THEN Throw("DOS", IoErr())
  partial := TRUE

  buf := New(BUFSIZE)
  REPEAT
    n := Read(fhin, buf, BUFSIZE)
    IF n > 0
      IF Write(fhout, buf, n) <> n THEN Throw("DOS", IoErr())
    ENDIF
  UNTIL n <= 0
  IF n < 0 THEN Throw("DOS", IoErr())

  Close(fhout)
  fhout := NIL
  Close(fhin)
  fhin := NIL
  partial := FALSE

  -> best-effort: a filesystem that can't store these shouldn't fail the move
  SetProtection(dest, prot)
  SetFileDate(dest, {sfib.datestamp})

  IF DeleteFile(from)=FALSE
    WriteF('mv: copied to \s but could not delete the source:\n', dest)
    PrintFault(IoErr(), 'mv')
    rc := RETURN_WARN
  ENDIF

EXCEPT DO
  IF fhout THEN Close(fhout)
  IF fhin THEN Close(fhin)
  IF (exception<>0) AND partial THEN DeleteFile(dest)
  IF dlock THEN UnLock(dlock)
  IF slock THEN UnLock(slock)
  IF sfib THEN END sfib
  ReThrow()
ENDPROC
