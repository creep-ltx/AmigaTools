/* cp.e -- Unix-style copy for AmigaDOS
   usage: cp [-fr] FROM ... TO
   e.g.   cp file newname
          cp file work:archive/          (into a directory)
          cp -r dir  work:backup         (recursive)
          cp #?.txt  ram:                (pattern)
          cp a b c   work:stuff          (multiple sources -> dir)
          cp -f old.iff pics:            (replace existing target)

   Flags are bundled Unix-style (-f, -r, or -fr), matching ls/mv in
   this set; the last path is TO, everything before it is a source.
   `cp ?` prints usage, as an AmigaDOS command should.

   cp is non-destructive by default, like mv: an existing target file
   is skipped and listed at the end (return code 5). -f deletes and
   replaces it. This is deliberately safer than Unix cp's silent
   overwrite. cp never copies a file onto itself (checked with
   SameLock(), so `cp -f file file` can't destroy the only copy) and
   never replaces a directory with a file.

   Metadata is preserved by default -- protection bits, datestamp and
   filenote are carried to the copy, the way `Copy CLONE` does. There
   is no -p flag: preserving is the sensible Amiga default.

   With more than one source -- several names or a pattern -- TO must
   be an existing directory; sources are copied into it under their
   own names. A single plain source may name its copy directly.

   -r copies directories. The tree is walked with an explicit work
   list, not native recursion, so a deep tree can't blow the stack
   (the ls -R lesson): each directory is recreated at the target, its
   files copied, its subdirectories queued. An existing target
   directory is merged into. Files inside the tree follow the same
   skip/-f rule as a top-level target. Without -r a directory source
   is refused (reported; the batch carries on). Copying a directory
   into its own subtree is NOT guarded against -- don't.

   Ctrl-C is honoured between files and between copy chunks; a broken
   or failed copy removes the partial target file.

   Errors on one file are reported and the rest of the batch still
   runs. Return code is the worst that happened: 0 clean, 5 something
   was skipped, 10 some file failed, 20 break.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/dosasl'

CONST BUFSIZE=32768, PATHLEN=512, MAXARGS=32, NAMELEN=110

OBJECT snode                       -> skipped-file list
  next:PTR TO snode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT dnode                       -> -r directory work list (src+dst pair)
  next:PTR TO dnode
  src[PATHLEN]:ARRAY OF CHAR
  dst[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT cent                        -> one collected directory entry
  next:PTR TO cent
  isdir:LONG
  prot:LONG
  days:LONG
  minute:LONG
  tick:LONG
  name[NAMELEN]:ARRAY OF CHAR
  comm[80]:ARRAY OF CHAR
ENDOBJECT

DEF rc, force, recursive, toisdir
DEF gto:PTR TO CHAR
DEF gtarget[PATHLEN+4]:ARRAY OF CHAR
DEF gpatbuf[1030]:ARRAY OF CHAR
DEF gfib:PTR TO fileinfoblock
DEF gds[3]:ARRAY OF LONG           -> reusable datestamp (days,minute,tick)
DEF gbuf=NIL                       -> copy buffer, allocated on first use
DEF skiphead=NIL:PTR TO snode, skiptail=NIL:PTR TO snode, skipcount
DEF pendhead=NIL:PTR TO dnode, pendtail=NIL:PTR TO dnode

PROC main() HANDLE
  DEF paths[MAXARGS]:ARRAY OF LONG
  DEF npaths, n, i, wild, multi, lock
  DEF node:PTR TO snode

  rc := RETURN_OK

  npaths := parseargs(paths)
  IF npaths < 2 THEN Throw("CP", 'usage: cp [-fr] FROM ... TO')

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

  IF multi AND (toisdir=FALSE) THEN Throw("CP", 'cp: with several files or a pattern, TO must be an existing directory')

  FOR i:=0 TO n-1 DO dosource(paths[i])

  IF skipcount>0
    WriteF('not copied:\n')
    node := skiphead
    WHILE node
      WriteF('  \s\n', node.path)
      node := node.next
    ENDWHILE
    setrc(RETURN_WARN)
  ENDIF

EXCEPT DO
  IF exception="DOS"
    PrintFault(exceptioninfo, 'cp')
    setrc(RETURN_ERROR)
  ELSEIF exception="BRK"
    WriteF('***Break: cp\n')
    setrc(RETURN_FAIL)
  ELSEIF exception="USG"
    usage()
  ELSEIF exception="ARG"
    WriteF('cp: unknown option (cp ? for usage)\n')
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC usage()
  WriteF('cp 0.1.1 -- Unix-style copy\n')
  WriteF('usage: cp [-fr] FROM ... TO\n')
  WriteF('  -f  force: replace an existing target file\n')
  WriteF('  -r  copy directories recursively\n')
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
    CASE "f" ; force := TRUE
    CASE "r" ; recursive := TRUE
    CASE "R" ; recursive := TRUE
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
   handles plain names and patterns uniformly, and copies every
   match. Match errors are reported here; the batch continues. */
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
    copyone(path, ifib)
    res := MatchNext(ap)
  ENDWHILE
  IF res<>ERROR_NO_MORE_ENTRIES
    WriteF('cp: \s: ', spec)
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

/* One already-matched top-level source. A file is copied to gtarget
   (gto, or gto/name when TO is a directory); a directory is walked
   with the work list when -r is set, refused otherwise. */
PROC copyone(srcpath:PTR TO CHAR, ifib:PTR TO fileinfoblock)
  AstrCopy(gtarget, gto, PATHLEN)
  IF toisdir THEN AddPart(gtarget, FilePart(srcpath), PATHLEN)

  IF ifib.direntrytype > 0
    IF recursive = FALSE
      WriteF('cp: omitting directory \s (use -r)\n', srcpath)
      setrc(RETURN_ERROR)
      RETURN
    ENDIF
    copytree(srcpath, gtarget)
  ELSE
    IF prepfile(srcpath, gtarget)
      copyfile(srcpath, gtarget, ifib.protection, {ifib.datestamp}, ifib.comment)
    ENDIF
  ENDIF
ENDPROC

/* Decides the fate of an existing FILE target: proceed (no target,
   or -f after deleting it), or don't (skipped by default, or refused
   because it's a directory or the same object as the source). The
   source must provably exist and differ from the target BEFORE the
   target is deleted, so -f can't wipe the target and then find
   nothing to copy in. Returns TRUE if the copy should proceed. */
PROC prepfile(srcpath:PTR TO CHAR, tpath:PTR TO CHAR)
  DEF tlock, slock, same, tisdir, err
  tlock := Lock(tpath, ACCESS_READ)
  IF tlock = NIL THEN RETURN TRUE
  slock := Lock(srcpath, ACCESS_READ)
  IF slock = NIL
    err := IoErr()
    UnLock(tlock)
    WriteF('cp: \s: ', srcpath)
    PrintFault(err, NIL)
    setrc(RETURN_ERROR)
    RETURN FALSE
  ENDIF
  same := SameLock(slock, tlock) = LOCK_SAME
  UnLock(slock)
  tisdir := FALSE
  IF Examine(tlock, gfib)
    IF gfib.direntrytype > 0 THEN tisdir := TRUE
  ENDIF
  UnLock(tlock)
  IF same
    WriteF('cp: \s: source and target are the same file\n', srcpath)
    setrc(RETURN_ERROR)
    RETURN FALSE
  ENDIF
  IF tisdir
    WriteF('cp: cannot overwrite directory \s\n', tpath)
    setrc(RETURN_ERROR)
    RETURN FALSE
  ENDIF
  IF force
    IF DeleteFile(tpath) = FALSE
      err := IoErr()
      WriteF('cp: cannot replace \s: ', tpath)
      PrintFault(err, NIL)
      setrc(RETURN_ERROR)
      RETURN FALSE
    ENDIF
    RETURN TRUE
  ENDIF
  addskip(srcpath)
  RETURN FALSE
ENDPROC

/* Copies one file's data, then carries over protection, datestamp
   and filenote (best-effort: a filesystem that can't store these
   shouldn't fail the copy). A failed or broken copy removes the
   partial target; a Ctrl-C break propagates out after that cleanup. */
PROC copyfile(src:PTR TO CHAR, dst:PTR TO CHAR, prot, ds:PTR TO datestamp, comm:PTR TO CHAR) HANDLE
  DEF fhin=NIL, fhout=NIL, n, partial

  partial := FALSE
  IF gbuf=NIL THEN gbuf := New(BUFSIZE)

  fhin := Open(src, MODE_OLDFILE)
  IF fhin=NIL THEN Throw("CPY", IoErr())
  fhout := Open(dst, MODE_NEWFILE)
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

  SetProtection(dst, prot)
  IF ds THEN SetFileDate(dst, ds)
  IF comm THEN IF comm[0] THEN SetComment(dst, comm)

EXCEPT
  IF fhout THEN Close(fhout)
  IF fhin THEN Close(fhin)
  IF partial THEN DeleteFile(dst)
  IF exception="CPY"
    WriteF('cp: \s: ', src)
    PrintFault(exceptioninfo, NIL)
    setrc(RETURN_ERROR)
  ELSE
    ReThrow()
  ENDIF
ENDPROC

/* Copies a whole directory tree src -> dst with an explicit FIFO
   work list. The top pair is queued, then drained: each pop
   recreates its destination directory, copies the files it holds,
   and queues its subdirectories. A parent is always processed (and
   thus created) before its children. */
PROC copytree(srctop:PTR TO CHAR, dsttop:PTR TO CHAR)
  DEF node:PTR TO dnode
  queuedir(srctop, dsttop)
  WHILE pendhead
    checkbreak()
    node := pendhead
    pendhead := node.next
    IF pendhead=NIL THEN pendtail := NIL
    copydir(node.src, node.dst)
    END node                                 -> NEW'd: END, never Dispose
  ENDWHILE
ENDPROC

PROC queuedir(src:PTR TO CHAR, dst:PTR TO CHAR)
  DEF node:PTR TO dnode
  NEW node
  AstrCopy(node.src, src, PATHLEN)
  AstrCopy(node.dst, dst, PATHLEN)
  node.next := NIL
  IF pendhead=NIL THEN pendhead := node ELSE pendtail.next := node
  pendtail := node
ENDPROC

/* Recreates dst as a directory (merging into an existing one),
   scans src into a list -- so gfib is free again before any file is
   examined -- then copies each file and queues each subdirectory. */
PROC copydir(src:PTR TO CHAR, dst:PTR TO CHAR) HANDLE
  DEF lock=NIL, head=NIL:PTR TO cent, e:PTR TO cent, ok, err
  DEF cs[PATHLEN]:ARRAY OF CHAR, cd[PATHLEN]:ARRAY OF CHAR

  IF ensuredir(src, dst) = FALSE THEN RETURN

  lock := Lock(src, ACCESS_READ)
  IF lock = NIL
    err := IoErr()
    WriteF('cp: \s: ', src)
    PrintFault(err, NIL)
    setrc(RETURN_WARN)
    RETURN
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    lock := NIL
    WriteF('cp: cannot examine \s\n', src)
    setrc(RETURN_WARN)
    RETURN
  ENDIF

  ok := ExNext(lock, gfib)
  WHILE ok
    checkbreak()
    e := mkent(gfib)
    e.next := head
    head := e
    ok := ExNext(lock, gfib)
  ENDWHILE
  err := IoErr()
  UnLock(lock)
  lock := NIL
  IF err <> ERROR_NO_MORE_ENTRIES
    WriteF('cp: \s: ', src)
    PrintFault(err, NIL)
    setrc(RETURN_WARN)
  ENDIF

  e := head
  WHILE e
    checkbreak()
    AstrCopy(cs, src, PATHLEN)
    AddPart(cs, e.name, PATHLEN)
    AstrCopy(cd, dst, PATHLEN)
    AddPart(cd, e.name, PATHLEN)
    IF e.isdir
      queuedir(cs, cd)
    ELSE
      IF prepfile(cs, cd) THEN copyfileent(cs, cd, e)
    ENDIF
    e := e.next
  ENDWHILE
  freecents(head)
EXCEPT
  IF lock THEN UnLock(lock)
  freecents(head)
  ReThrow()
ENDPROC

PROC copyfileent(src:PTR TO CHAR, dst:PTR TO CHAR, e:PTR TO cent)
  gds[0] := e.days
  gds[1] := e.minute
  gds[2] := e.tick
  copyfile(src, dst, e.prot, gds, e.comm)
ENDPROC

/* Makes sure dst is a directory: reuse it if it already is one,
   refuse if it exists as a file, otherwise CreateDir() it and stamp
   the source directory's protection and filenote onto it (best
   effort; the datestamp is left as creation time, since populating
   the directory would only touch it again). */
PROC ensuredir(src:PTR TO CHAR, dst:PTR TO CHAR)
  DEF dlock, slock, isdir, prot, comm[80]:ARRAY OF CHAR, have, err

  dlock := Lock(dst, ACCESS_READ)
  IF dlock
    isdir := FALSE
    IF Examine(dlock, gfib)
      IF gfib.direntrytype > 0 THEN isdir := TRUE
    ENDIF
    UnLock(dlock)
    IF isdir THEN RETURN TRUE
    WriteF('cp: \s exists and is not a directory\n', dst)
    setrc(RETURN_ERROR)
    RETURN FALSE
  ENDIF

  have := FALSE
  slock := Lock(src, ACCESS_READ)
  IF slock
    IF Examine(slock, gfib)
      prot := gfib.protection
      AstrCopy(comm, gfib.comment, 80)
      have := TRUE
    ENDIF
    UnLock(slock)
  ENDIF

  dlock := CreateDir(dst)
  IF dlock = NIL
    err := IoErr()
    WriteF('cp: cannot create \s: ', dst)
    PrintFault(err, NIL)
    setrc(RETURN_ERROR)
    RETURN FALSE
  ENDIF
  UnLock(dlock)

  IF have
    SetProtection(dst, prot)
    IF comm[0] THEN SetComment(dst, comm)
  ENDIF
ENDPROC TRUE

PROC mkent(fib:PTR TO fileinfoblock)
  DEF e:PTR TO cent, ds:PTR TO datestamp
  NEW e
  AstrCopy(e.name, fib.filename, NAMELEN)
  AstrCopy(e.comm, fib.comment, 80)
  e.prot := fib.protection
  ds := fib.datestamp
  e.days := ds.days
  e.minute := ds.minute
  e.tick := ds.tick
  e.isdir := IF fib.direntrytype > 0 THEN TRUE ELSE FALSE
ENDPROC e

-> cents are NEW'd: free with END, never Dispose(). A NEW under 257
-> bytes is FastNew - chunk-carved, headerless, off the New() memlist -
-> and Dispose() on the first cent of a chunk FreeMem()s the WHOLE
-> chunk under the live ones (ls BUGS.md B1, the -R freeze root cause).
PROC freecents(head:PTR TO cent)
  DEF e:PTR TO cent
  WHILE head
    e := head
    head := head.next
    END e
  ENDWHILE
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

version: CHAR '$VER: cp 0.1.1 (24.7.26) E build',0
