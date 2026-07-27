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
   and mv falls back to copy + delete, preserving protection bits,
   datestamp and filenote.

   0.5: that fallback covers DIRECTORIES too -- the last Rename-vs-mv
   gap. The tree is copied with cp's machinery (explicit work list,
   each directory scanned to completion, full metadata carried) and
   the source then deleted with rm's engine (scan-complete-then-
   delete, LIFO unwind, deepest directory first). ALL-OR-NOTHING per
   tree: any copy failure abandons the move -- the partial
   destination is wiped and the source left untouched. The
   destination must not already exist (a clean landing; merging is
   cp's business), volume roots are refused, and a tree containing a
   soft link or a hard DIRECTORY link is refused whole (a link can't
   be recreated faithfully across volumes, and copying through one
   could loop; hard FILE links copy as files). The source is deleted
   ONLY after the entire tree copied clean; if a source file then
   refuses to die (d-bit), the move stands and the leftover source is
   reported honestly (rc 5), like the single-file "copied but could
   not delete". A Ctrl-C during the copy phase leaves the partial
   copy at TO -- the source is never touched before the copy is
   complete.

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

CONST BUFSIZE=32768, PATHLEN=512, MAXARGS=32, NAMELEN=110

OBJECT snode
  next:PTR TO snode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT tnode                       -> 0.5: tree-copy work list (src+dst)
  next:PTR TO tnode
  src[PATHLEN]:ARRAY OF CHAR
  dst[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT rnode                       -> 0.5: delete lists (FIFO scan + LIFO)
  next:PTR TO rnode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT cent                        -> 0.5: one collected directory entry
  next:PTR TO cent
  etype:LONG
  prot:LONG
  days:LONG
  minute:LONG
  tick:LONG
  name[NAMELEN]:ARRAY OF CHAR
  comm[80]:ARRAY OF CHAR
ENDOBJECT

DEF rc, overwrite, backup, toisdir
DEF gto:PTR TO CHAR
DEF gtarget[PATHLEN+4]:ARRAY OF CHAR
DEF gbak[PATHLEN+8]:ARRAY OF CHAR
DEF gpatbuf[1030]:ARRAY OF CHAR
DEF gfib:PTR TO fileinfoblock
DEF gbuf=NIL                       -> copy buffer, allocated on first use
DEF skiphead=NIL:PTR TO snode, skiptail=NIL:PTR TO snode, skipcount
DEF gds[3]:ARRAY OF LONG           -> 0.5: reusable datestamp triple
DEF tphead=NIL:PTR TO tnode, tptail=NIL:PTR TO tnode  -> 0.5: copy FIFO
DEF dthead=NIL:PTR TO rnode, dttail=NIL:PTR TO rnode  -> 0.5: delete FIFO
DEF dlhead=NIL:PTR TO rnode        -> 0.5: delete LIFO, deepest first
DEF treeok                         -> 0.5: this tree still all-clean?

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
  ELSEIF exception="MAX"
    WriteF('mv: too many arguments (max \d)\n', MAXARGS)
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC usage()
  WriteF('mv 0.5 -- Unix-style move\n')
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
        -> 0.4.1 A1: never silently drop an argument - with 33+ the
        -> dropped one was TO and the 32nd SOURCE was promoted to
        -> target, relocating the whole batch somewhere never named
        IF np >= MAXARGS THEN Throw("MAX", 0)
        s := String(tl)
        StrCopy(s, t)
        paths[np] := s
        np++
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

  -> 0.5: a volume root can never be a move source - say so up
  -> front (FilePart of a root is '' and the target checks below
  -> would otherwise answer with a misleading message)
  IF isroot(srcpath)
    WriteF('mv: \s: cannot move a volume root\n', srcpath)
    setrc(RETURN_ERROR)
    RETURN
  ENDIF

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
      treemove(srcpath)          -> 0.5: the recursive fallback
    ELSE
      copymove(srcpath, ifib)
    ENDIF
  ELSE
    WriteF('mv: \s: ', srcpath)
    PrintFault(err, NIL)
    setrc(RETURN_ERROR)
  ENDIF
ENDPROC

/* 0.5: a volume root, with or without one trailing '/', or an
   empty name (the rm 0.1 rule -- never tree-operate on a root). */
PROC isroot(path:PTR TO CHAR)
  DEF l
  l := StrLen(path)
  IF l = 0 THEN RETURN TRUE
  IF path[l-1] = "/" THEN l := l-1
  IF l = 0 THEN RETURN TRUE
  IF path[l-1] = ":" THEN RETURN TRUE
ENDPROC FALSE

/* 0.5: cross-volume DIRECTORY move into gtarget. Copy phase first
   (all of it), source delete strictly after -- see the header for
   the all-or-nothing contract. */
PROC treemove(srcpath:PTR TO CHAR)
  DEF lk, node:PTR TO tnode
  IF isroot(srcpath)
    WriteF('mv: \s: cannot move a volume root\n', srcpath)
    setrc(RETURN_ERROR)
    RETURN
  ENDIF
  lk := Lock(gtarget, ACCESS_READ)
  IF lk
    UnLock(lk)
    WriteF('mv: cannot move \s onto existing \s\n', srcpath, gtarget)
    setrc(RETURN_ERROR)
    RETURN
  ENDIF
  treeok := TRUE
  tqueue(srcpath, gtarget)
  WHILE tphead
    checkbreak()
    node := tphead
    tphead := node.next
    IF tphead = NIL THEN tptail := NIL
    IF treeok THEN tcopydir(node.src, node.dst)
    END node                     -> NEW'd: END, never Dispose (B1)
  ENDWHILE
  IF treeok
    IF deltree(srcpath) = FALSE
      WriteF('mv: \s: moved, but the source could not be fully deleted\n', srcpath)
      setrc(RETURN_WARN)
    ENDIF
  ELSE
    deltree(gtarget)             -> wipe the partial landing
    WriteF('mv: \s: move abandoned, source untouched\n', srcpath)
    setrc(RETURN_ERROR)
  ENDIF
ENDPROC

PROC tqueue(src:PTR TO CHAR, dst:PTR TO CHAR)
  DEF node:PTR TO tnode
  NEW node
  AstrCopy(node.src, src, PATHLEN)
  AstrCopy(node.dst, dst, PATHLEN)
  node.next := NIL
  IF tphead = NIL THEN tphead := node ELSE tptail.next := node
  tptail := node
ENDPROC

/* 0.5: one directory of the copy phase -- create dst, scan src to
   completion, copy files, queue subdirectories. Any failure drops
   treeok; treemove then abandons and wipes. */
PROC tcopydir(src:PTR TO CHAR, dst:PTR TO CHAR) HANDLE
  DEF lock=NIL, head=NIL:PTR TO cent, e:PTR TO cent, ok, err
  DEF cs[PATHLEN]:ARRAY OF CHAR, cd[PATHLEN]:ARRAY OF CHAR

  IF tensure(src, dst) = FALSE
    treeok := FALSE
    RETURN
  ENDIF
  lock := Lock(src, ACCESS_READ)
  IF lock = NIL
    err := IoErr()
    WriteF('mv: \s: ', src)
    PrintFault(err, NIL)
    treeok := FALSE
    RETURN
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    lock := NIL
    WriteF('mv: cannot examine \s\n', src)
    treeok := FALSE
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
    WriteF('mv: \s: ', src)
    PrintFault(err, NIL)
    treeok := FALSE
  ENDIF

  e := head
  WHILE e
    checkbreak()
    AstrCopy(cs, src, PATHLEN)
    AddPart(cs, e.name, PATHLEN)
    AstrCopy(cd, dst, PATHLEN)
    AddPart(cd, e.name, PATHLEN)
    IF (e.etype = ST_SOFTLINK) OR (e.etype = ST_LINKDIR)
      -> a link can't be recreated faithfully on another volume, and
      -> copying THROUGH one could loop (a link to an ancestor) -
      -> refuse the whole tree, nothing has been deleted yet
      WriteF('mv: \s: the tree contains a link - not movable across volumes\n', cs)
      treeok := FALSE
    ELSEIF e.etype > 0
      IF e.name[0] THEN tqueue(cs, cd)       -> the ls B1 blank-name rule
    ELSE
      IF treeok THEN tcopyfile(cs, cd, e)
    ENDIF
    e := e.next
  ENDWHILE
  freecents(head)
EXCEPT
  IF lock THEN UnLock(lock)
  freecents(head)
  ReThrow()
ENDPROC

/* 0.5: create one destination directory, stamping the source dir's
   protection and filenote onto it (best effort). */
PROC tensure(src:PTR TO CHAR, dst:PTR TO CHAR)
  DEF dlock, slock, prot, comm[80]:ARRAY OF CHAR, have, err
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
    WriteF('mv: cannot create \s: ', dst)
    PrintFault(err, NIL)
    RETURN FALSE
  ENDIF
  UnLock(dlock)
  IF have
    SetProtection(dst, prot)
    IF comm[0] THEN SetComment(dst, comm)
  ENDIF
ENDPROC TRUE

/* 0.5: one file of the copy phase - cp's copyfile shape, with the
   full metadata set (protection, datestamp, filenote) and treeok
   instead of a per-file return-code verdict. */
PROC tcopyfile(src:PTR TO CHAR, dst:PTR TO CHAR, ce:PTR TO cent) HANDLE
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

  SetProtection(dst, ce.prot)
  gds[0] := ce.days
  gds[1] := ce.minute
  gds[2] := ce.tick
  SetFileDate(dst, gds)
  IF ce.comm[0] THEN SetComment(dst, ce.comm)

EXCEPT
  IF fhout THEN Close(fhout)
  IF fhin THEN Close(fhin)
  IF partial THEN DeleteFile(dst)
  IF exception="CPY"
    WriteF('mv: \s: ', src)
    PrintFault(exceptioninfo, NIL)
    treeok := FALSE
  ELSE
    ReThrow()
  ENDIF
ENDPROC

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
  e.etype := fib.direntrytype
ENDPROC e

-> cents are NEW'd: free with END, never Dispose() (the B1 rule)
PROC freecents(head:PTR TO cent)
  DEF e:PTR TO cent
  WHILE head
    e := head
    head := head.next
    END e
  ENDWHILE
ENDPROC

/* 0.5: rm 0.1's delete engine - scan each directory TO COMPLETION
   before deleting inside it (never delete under a live ExNext),
   unwind a LIFO deepest-first. Plain deletes, no protection
   stripping (mv's -f sanctions replacing the TARGET, not forcing
   the source out). FALSE = something refused; parents then report
   "not empty" honestly and the caller says what that means. */
PROC deltree(top:PTR TO CHAR)
  DEF n:PTR TO rnode, ok
  ok := TRUE
  dtqueue(top)
  WHILE dthead
    checkbreak()
    n := dthead
    dthead := n.next
    IF dthead = NIL THEN dttail := NIL
    IF dtscan(n.path) = FALSE THEN ok := FALSE
    END n
  ENDWHILE
  WHILE dlhead
    checkbreak()
    n := dlhead
    dlhead := n.next
    IF DeleteFile(n.path) = FALSE
      WriteF('mv: \s: ', n.path)
      PrintFault(IoErr(), NIL)
      ok := FALSE
    ENDIF
    END n
  ENDWHILE
ENDPROC ok

PROC dtqueue(path:PTR TO CHAR)
  DEF n:PTR TO rnode, r:PTR TO rnode
  NEW n
  AstrCopy(n.path, path, PATHLEN)
  n.next := NIL
  IF dthead = NIL THEN dthead := n ELSE dttail.next := n
  dttail := n
  NEW r                          -> LIFO: children push in above
  AstrCopy(r.path, path, PATHLEN) -> their parent - deepest first
  r.next := dlhead
  dlhead := r
ENDPROC

PROC dtscan(path:PTR TO CHAR) HANDLE
  DEF lock=NIL, head=NIL:PTR TO cent, e:PTR TO cent, okk, err, ok
  DEF w[PATHLEN]:ARRAY OF CHAR
  ok := TRUE
  lock := Lock(path, ACCESS_READ)
  IF lock = NIL
    err := IoErr()
    WriteF('mv: \s: ', path)
    PrintFault(err, NIL)
    RETURN FALSE
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    lock := NIL
    WriteF('mv: cannot examine \s\n', path)
    RETURN FALSE
  ENDIF
  okk := ExNext(lock, gfib)
  WHILE okk
    checkbreak()
    e := mkent(gfib)
    e.next := head
    head := e
    okk := ExNext(lock, gfib)
  ENDWHILE
  err := IoErr()
  UnLock(lock)
  lock := NIL
  IF err <> ERROR_NO_MORE_ENTRIES
    WriteF('mv: \s: ', path)
    PrintFault(err, NIL)
    ok := FALSE
  ENDIF
  e := head
  WHILE e
    checkbreak()
    AstrCopy(w, path, PATHLEN)
    AddPart(w, e.name, PATHLEN)
    IF (e.etype > 0) AND (e.etype <> ST_SOFTLINK) AND (e.etype <> ST_LINKDIR)
      IF e.name[0] THEN dtqueue(w)
    ELSE
      IF DeleteFile(w) = FALSE   -> files and link entries alike
        WriteF('mv: \s: ', w)
        PrintFault(IoErr(), NIL)
        ok := FALSE
      ENDIF
    ENDIF
    e := e.next
  ENDWHILE
  freecents(head)
EXCEPT
  IF lock THEN UnLock(lock)
  freecents(head)
  ReThrow()
ENDPROC ok

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
  -> 0.4.1 M1: the filenote too - a same-volume mv (pure Rename)
  -> keeps it, so the cross-volume path silently stripping it was
  -> an inconsistency (cp has carried it all along)
  IF ifib.comment[0] THEN SetComment(gtarget, ifib.comment)

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

version: CHAR '$VER: mv 0.5 (27.7.26) E build',0
