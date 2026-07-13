/* dupfind.e -- find duplicate files
   Usage: dupfind DIR [PATTERN pat] [FULL] [CHECKSUM] [VERBOSE]
   e.g.   dupfind work:
          dupfind work:downloads
          dupfind work:downloads PATTERN #?.iff
          dupfind work: CHECKSUM
          dupfind work: FULL

   Default comparison mode only checks the first HDRSIZE bytes of files
   that share the same size -- fast, but can in rare cases report a
   "duplicate" that actually differs later in the file. CHECKSUM and
   FULL are both always exact: CHECKSUM hashes whole files first as a
   fast pre-filter (cheap for groups of many same-size-but-different
   files) then confirms any hash match with a full byte compare; FULL
   always does the byte compare directly, no hashing.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/rdargs'

CONST HDRSIZE=512, CHUNKSIZE=4096

OBJECT fentry
  next:PTR TO fentry
  path[256]:ARRAY OF CHAR
  size:LONG
  sig:LONG
  sigValid:LONG
  matched:LONG
ENDOBJECT

DEF fileListHead:PTR TO fentry, fileListTail:PTR TO fentry
DEF fileCount

PROC main() HANDLE
  DEF rdargs=NIL:PTR TO rdargs
  DEF argarray[5]:ARRAY OF LONG
  DEF dirName:PTR TO CHAR
  DEF pattern:PTR TO CHAR
  DEF fullFlag, checksumFlag, verboseFlag
  DEF patBuf[256]:ARRAY OF CHAR
  DEF patLen, mode

  rdargs := ReadArgs('DIR/A,PATTERN/K,FULL/S,CHECKSUM/S,VERBOSE/S', argarray, NIL)
  IF rdargs=NIL THEN Throw("ARG", 'Bad arguments - usage: dupfind DIR [PATTERN pat] [FULL] [CHECKSUM] [VERBOSE]')

  dirName      := argarray[0]
  pattern      := argarray[1]
  fullFlag     := argarray[2]
  checksumFlag := argarray[3]
  verboseFlag  := argarray[4]

  IF pattern=NIL THEN pattern := '#?'

  patLen := ParsePatternNoCase(pattern, patBuf, 256)
  IF patLen=-1 THEN Throw("ARG", 'Pattern too complex')

  mode := 0
  IF checksumFlag THEN mode := 1
  IF fullFlag THEN mode := 2

  WriteF('Scanning \s (pattern \s)\n', dirName, pattern)

  fileCount := 0
  scanDir(dirName, patBuf, patLen, verboseFlag)

  WriteF('\nTotal matching files: \d\n', fileCount)

  findDuplicates(mode)

  FreeArgs(rdargs)

EXCEPT DO
  IF rdargs THEN FreeArgs(rdargs)
  IF exception THEN WriteF('Error: \s\n', exceptioninfo)
ENDPROC

PROC scanDir(dirName:PTR TO CHAR, patBuf:PTR TO CHAR, patLen, verboseFlag)
  DEF lock, fib:PTR TO fileinfoblock
  DEF pathBuf[256]:STRING

  lock := Lock(dirName, ACCESS_READ)
  IF lock=0
    WriteF('Cannot open: \s\n', dirName)
    RETURN
  ENDIF

  NEW fib
  IF Examine(lock, fib)=FALSE
    WriteF('Examine failed: \s\n', dirName)
    UnLock(lock)
    RETURN
  ENDIF

  WHILE ExNext(lock, fib)
    IF fib.direntrytype > 0
      -> it's a subdirectory, recurse
      StrCopy(pathBuf, dirName, ALL)
      IF pathBuf[EstrLen(pathBuf)-1] <> ":" AND pathBuf[EstrLen(pathBuf)-1] <> "/"
        StrAdd(pathBuf, '/', ALL)
      ENDIF
      StrAdd(pathBuf, fib.filename, ALL)
      scanDir(pathBuf, patBuf, patLen, verboseFlag)
    ELSE
      -> it's a file, check pattern
      IF MatchPatternNoCase(patBuf, fib.filename)
        StrCopy(pathBuf, dirName, ALL)
        IF pathBuf[EstrLen(pathBuf)-1] <> ":" AND pathBuf[EstrLen(pathBuf)-1] <> "/"
          StrAdd(pathBuf, '/', ALL)
        ENDIF
        StrAdd(pathBuf, fib.filename, ALL)
        addFile(pathBuf, fib.size)
        IF verboseFlag THEN WriteF('  \s\n', pathBuf)
      ENDIF
    ENDIF
  ENDWHILE

  END fib
  UnLock(lock)
ENDPROC

PROC addFile(fullPath:PTR TO CHAR, size)
  DEF e:PTR TO fentry
  NEW e
  AstrCopy(e.path, fullPath, ALL)
  e.size := size
  e.next := NIL
  e.sigValid := FALSE
  e.matched := FALSE
  IF fileListHead=NIL
    fileListHead := e
    fileListTail := e
  ELSE
    fileListTail.next := e
    fileListTail := e
  ENDIF
  fileCount := fileCount + 1
ENDPROC

PROC findDuplicates(mode)
  DEF p:PTR TO fentry, q:PTR TO fentry
  DEF setCount, dupSets

  dupSets := 0
  p := fileListHead
  WHILE p<>NIL
    IF p.matched=FALSE
      setCount := 0
      q := p.next
      WHILE q<>NIL
        IF (q.matched=FALSE) AND (q.size=p.size)
          IF entriesMatch(p, q, mode)
            IF setCount=0
              WriteF('\nDuplicate set (\d bytes):\n', p.size)
              WriteF('  \s\n', p.path)
              p.matched := TRUE
              dupSets := dupSets + 1
            ENDIF
            WriteF('  \s\n', q.path)
            q.matched := TRUE
            setCount := setCount + 1
          ENDIF
        ENDIF
        q := q.next
      ENDWHILE
    ENDIF
    p := p.next
  ENDWHILE

  IF dupSets=0
    WriteF('\nNo duplicates found.\n')
  ELSE
    WriteF('\n\d duplicate set(s) found.\n', dupSets)
  ENDIF
ENDPROC

PROC entriesMatch(a:PTR TO fentry, b:PTR TO fentry, mode)
  DEF result
  IF mode=2
    result := filesEqualFull(a.path, b.path)
  ELSEIF mode=1
    IF getChecksum(a) = getChecksum(b)
      result := filesEqualFull(a.path, b.path)
    ELSE
      result := FALSE
    ENDIF
  ELSE
    result := headerSignatureMatch(a.path, b.path)
  ENDIF
ENDPROC result

PROC getChecksum(e:PTR TO fentry)
  DEF fh, buf[CHUNKSIZE]:ARRAY OF CHAR, n, sum, i
  IF e.sigValid THEN RETURN e.sig
  fh := Open(e.path, MODE_OLDFILE)
  sum := 0
  IF fh<>0
    REPEAT
      n := Read(fh, buf, CHUNKSIZE)
      IF n>0
        FOR i:=0 TO n-1
          sum := ((sum << 1) OR (sum >> 31)) + buf[i]
        ENDFOR
      ENDIF
    UNTIL n<=0
    Close(fh)
  ENDIF
  e.sig := sum
  e.sigValid := TRUE
ENDPROC sum

PROC headerSignatureMatch(pathA:PTR TO CHAR, pathB:PTR TO CHAR)
  DEF fhA, fhB, bufA[HDRSIZE]:ARRAY OF CHAR, bufB[HDRSIZE]:ARRAY OF CHAR, nA, nB, result
  fhA := Open(pathA, MODE_OLDFILE)
  fhB := Open(pathB, MODE_OLDFILE)
  result := FALSE
  IF fhA<>0 AND fhB<>0
    nA := Read(fhA, bufA, HDRSIZE)
    nB := Read(fhB, bufB, HDRSIZE)
    IF nA=nB THEN result := memEq(bufA, bufB, nA)
  ENDIF
  IF fhA THEN Close(fhA)
  IF fhB THEN Close(fhB)
ENDPROC result

PROC filesEqualFull(pathA:PTR TO CHAR, pathB:PTR TO CHAR)
  DEF fhA, fhB, bufA[CHUNKSIZE]:ARRAY OF CHAR, bufB[CHUNKSIZE]:ARRAY OF CHAR
  DEF nA, nB, result

  fhA := Open(pathA, MODE_OLDFILE)
  fhB := Open(pathB, MODE_OLDFILE)
  result := TRUE
  IF fhA=0 OR fhB=0
    result := FALSE
  ELSE
    REPEAT
      nA := Read(fhA, bufA, CHUNKSIZE)
      nB := Read(fhB, bufB, CHUNKSIZE)
      IF nA<>nB
        result := FALSE
      ELSEIF nA>0
        IF memEq(bufA, bufB, nA)=FALSE THEN result := FALSE
      ENDIF
    UNTIL (nA<=0) OR (result=FALSE)
  ENDIF
  IF fhA THEN Close(fhA)
  IF fhB THEN Close(fhB)
ENDPROC result

PROC memEq(a:PTR TO CHAR, b:PTR TO CHAR, len)
  DEF i
  FOR i:=0 TO len-1
    IF a[i]<>b[i] THEN RETURN FALSE
  ENDFOR
ENDPROC TRUE

version: CHAR '$VER: dupfind 0.1 (14.7.26)',0
