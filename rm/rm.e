/* rm.e -- Unix-style delete for AmigaDOS
   usage: rm [-rfv] FILE | PATTERN ...
   e.g.   rm old.txt
          rm #?.bak                     (pattern)
          rm -r work:tmpdir             (directory and contents)
          rm -f locked.dat              (strip delete protection first)
          rm -rv ram:t                  (say what goes as it goes)

   C:Delete exists; rm is the muscle memory, and this one carries the
   family manners (ls/cp/mv/mkdir): bundled -flags, `rm ?` for usage,
   patterns matched by the command itself, errors on one item never
   kill the batch, and a "not deleted:" summary at the end. Return
   code is the worst that happened: 0 clean, 5 something was skipped,
   10 some item failed, 20 break.

   rm is careful by default, in this family's way:
   - A directory is refused without -r, like Unix (and unlike
     Delete ALL's promptless enthusiasm).
   - A delete-protected file (the d-bit -- the Amiga's own safety
     catch) is SKIPPED by default and listed at the end. With -f the
     protection is stripped (SetProtection 0) and the delete retried:
     that is what force *means* on AmigaDOS. A file another task
     holds open (in use) always refuses -- -f cannot unlock it.
   - A VOLUME ROOT is refused unconditionally: `rm -rf dh0:` answers
     "refusing to remove a volume root" and nothing else. No flag
     overrides it in this version; Format and Delete ALL exist for
     the one day a decade that is really meant.
   - Soft links are deleted as LINKS, never followed -- with or
     without -r. A link to a directory never becomes a tree delete,
     and not descending links kills the cycle risk in the same line.
     Hard directory links are treated the same way (the link entry
     goes, the target stays).

   -r walks with an explicit work list, never native recursion (the
   ls -R lesson), and each directory is scanned to completion BEFORE
   anything inside it is deleted -- never delete under a live ExNext,
   the filesystem invalidates the walk (the cfile deltree lesson).
   Files go as they are met; every scanned directory is pushed on a
   LIFO and the LIFO unwound at the end, deepest first, so each
   directory delete meets an already-emptied directory. A child that
   refuses to go (protected without -f, in use) leaves its whole
   parent chain standing -- each parent then reports "not empty"
   once, and nothing is lost that wasn't meant to be.

   Without -f, an argument that matches nothing is an error ("no
   match"), Unix rm manners; with -f it is silence, also Unix rm
   manners. -v lists each object as it is deleted (default silent).

   Ctrl-C is honoured between entries. All entry nodes are NEW'd and
   END'd (the B1 rule: Dispose() is only for New()/String()/List()).
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/dosasl'

CONST PATHLEN=512, MAXARGS=32, NAMELEN=110

OBJECT snode                       -> not-deleted list
  next:PTR TO snode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT dnode                       -> -r scan work list (FIFO)
  next:PTR TO dnode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT rnode                       -> -r directory-delete list (LIFO)
  next:PTR TO rnode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

OBJECT cent                        -> one collected directory entry
  next:PTR TO cent
  etype:LONG                       -> raw fib_DirEntryType
  name[NAMELEN]:ARRAY OF CHAR
ENDOBJECT

DEF rc, recursive, force, verbose
DEF gfib:PTR TO fileinfoblock
DEF gpatbuf[1030]:ARRAY OF CHAR
DEF skiphead=NIL:PTR TO snode, skiptail=NIL:PTR TO snode, skipcount
DEF pendhead=NIL:PTR TO dnode, pendtail=NIL:PTR TO dnode
DEF rmhead=NIL:PTR TO rnode

PROC main() HANDLE
  DEF paths[MAXARGS]:ARRAY OF LONG
  DEF npaths, i
  DEF node:PTR TO snode

  rc := RETURN_OK

  npaths := parseargs(paths)
  IF npaths < 1 THEN Throw("RM", 'usage: rm [-rfv] FILE | PATTERN ...')

  NEW gfib

  FOR i := 0 TO npaths-1 DO dosource(paths[i])

  IF skipcount > 0
    WriteF('not deleted:\n')
    node := skiphead
    WHILE node
      WriteF('  \s\n', node.path)
      node := node.next
    ENDWHILE
    setrc(RETURN_WARN)
  ENDIF

EXCEPT DO
  IF exception="DOS"
    PrintFault(exceptioninfo, 'rm')
    setrc(RETURN_ERROR)
  ELSEIF exception="BRK"
    WriteF('***Break: rm\n')
    setrc(RETURN_FAIL)
  ELSEIF exception="USG"
    usage()
  ELSEIF exception="ARG"
    WriteF('rm: unknown option (rm ? for usage)\n')
    setrc(RETURN_ERROR)
  ELSEIF exception="MAX"
    WriteF('rm: too many arguments (max \d)\n', MAXARGS)
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC usage()
  WriteF('rm 0.1 -- Unix-style delete\n')
  WriteF('usage: rm [-rfv] FILE | PATTERN ...\n')
  WriteF('  -r  delete directories and their contents\n')
  WriteF('  -f  force: strip delete protection and retry; quiet when nothing matches\n')
  WriteF('  -v  list each object as it is deleted\n')
ENDPROC

/* Tokenizes E's raw command line, ls-style: whitespace-separated,
   double quotes group, `*` escapes inside quotes (AmigaDOS rules, *n
   and *e get their control meanings). -x bundles set flags; a lone ?
   prints usage; everything else is a path/pattern. */
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
        -> A1 from birth: never silently drop an argument
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
    CASE "r" ; recursive := TRUE
    CASE "R" ; recursive := TRUE
    CASE "f" ; force := TRUE
    CASE "v" ; verbose := TRUE
    DEFAULT  ; Throw("ARG", c)
    ENDSELECT
    i++
  ENDWHILE
ENDPROC

PROC setrc(v)
  IF v > rc THEN rc := v
ENDPROC

PROC checkbreak()
  IF SetSignal(0, SIGBREAKF_CTRL_C) AND SIGBREAKF_CTRL_C THEN Throw("BRK", 0)
ENDPROC

/* A volume root, with or without one trailing '/', or an empty
   name. These are refused unconditionally -- see the header. */
PROC isroot(path:PTR TO CHAR)
  DEF l
  l := StrLen(path)
  IF l = 0 THEN RETURN TRUE
  IF path[l-1] = "/" THEN l := l-1
  IF l = 0 THEN RETURN TRUE
  IF path[l-1] = ":" THEN RETURN TRUE
ENDPROC FALSE

/* Runs one argument through MatchFirst()/MatchNext(), which handles
   plain names and patterns uniformly, and deletes every match.
   No match: an error without -f, silence with it (Unix rm manners).
   Match errors are reported here; the batch continues. */
PROC dosource(spec:PTR TO CHAR) HANDLE
  DEF ap=NIL:PTR TO anchorpath
  DEF res, path:PTR TO CHAR, ifib:PTR TO fileinfoblock, count

  ap := New(SIZEOF anchorpath + PATHLEN)
  ap.strlen := PATHLEN-1
  path := ap + SIZEOF anchorpath
  ifib := {ap.info}

  count := 0
  res := MatchFirst(spec, ap)
  WHILE res = 0
    checkbreak()
    delone(path, ifib)
    count++
    res := MatchNext(ap)
  ENDWHILE
  IF res <> ERROR_NO_MORE_ENTRIES
    IF (res = ERROR_OBJECT_NOT_FOUND) AND force
      -> -f: a name that isn't there is already the desired state
    ELSE
      WriteF('rm: \s: ', spec)
      PrintFault(res, NIL)
      setrc(RETURN_ERROR)
    ENDIF
  ELSEIF count = 0
    IF force = FALSE
      WriteF('rm: \s: no match\n', spec)
      setrc(RETURN_ERROR)
    ENDIF
  ENDIF

  MatchEnd(ap)
  Dispose(ap)
  ap := NIL          -> the ls 0.3.3 L1 lesson, kept even though
                     -> nothing throwable follows today
EXCEPT
  IF ap
    MatchEnd(ap)
    Dispose(ap)
  ENDIF
  ReThrow()
ENDPROC

/* One matched object. Links (soft, and hard directory links) are
   deleted as links; directories need -r; files just go. */
PROC delone(path:PTR TO CHAR, ifib:PTR TO fileinfoblock)
  IF isroot(path)
    WriteF('rm: \s: refusing to remove a volume root\n', path)
    setrc(RETURN_ERROR)
    RETURN
  ENDIF
  IF (ifib.direntrytype = ST_SOFTLINK) OR (ifib.direntrytype = ST_LINKDIR)
    delfile(path)                  -> the link entry, never the target
  ELSEIF ifib.direntrytype > 0
    IF recursive = FALSE
      WriteF('rm: \s is a directory (use -r)\n', path)
      setrc(RETURN_ERROR)
      RETURN
    ENDIF
    deltree(path)
  ELSE
    delfile(path)
  ENDIF
ENDPROC

/* Deletes one object (file, link, or an already-emptied directory).
   ERROR_DELETE_PROTECTED without -f: skipped and listed. With -f:
   protection stripped, delete retried, real failures reported. */
PROC delfile(path:PTR TO CHAR)
  DEF err
  IF DeleteFile(path)
    IF verbose THEN WriteF('\s\n', path)
    RETURN TRUE
  ENDIF
  err := IoErr()
  IF err = ERROR_DELETE_PROTECTED
    IF force
      SetProtection(path, 0)
      IF DeleteFile(path)
        IF verbose THEN WriteF('\s\n', path)
        RETURN TRUE
      ENDIF
      err := IoErr()
    ELSE
      addskip(path)
      RETURN FALSE
    ENDIF
  ENDIF
  WriteF('rm: \s: ', path)
  PrintFault(err, NIL)
  setrc(RETURN_ERROR)
ENDPROC FALSE

/* -r: delete a whole tree. Phase one drains a FIFO scan list: each
   directory is ExNext-scanned TO COMPLETION into a collected list
   (never delete under a live walk), then its files and links are
   deleted and its subdirectories queued; the directory itself goes
   on the LIFO. Phase two unwinds the LIFO -- deepest first, every
   directory meets its contents already gone (unless something
   refused, in which case the parents report "not empty" honestly). */
PROC deltree(top:PTR TO CHAR)
  DEF node:PTR TO dnode, r:PTR TO rnode
  queuedir(top)
  WHILE pendhead
    checkbreak()
    node := pendhead
    pendhead := node.next
    IF pendhead = NIL THEN pendtail := NIL
    scandir(node.path)
    END node                                 -> NEW'd: END, never Dispose
  ENDWHILE
  WHILE rmhead
    checkbreak()
    r := rmhead
    rmhead := r.next
    delfile(r.path)                          -> empty (or honestly not)
    END r
  ENDWHILE
ENDPROC

PROC queuedir(path:PTR TO CHAR)
  DEF node:PTR TO dnode, r:PTR TO rnode
  NEW node
  AstrCopy(node.path, path, PATHLEN)
  node.next := NIL
  IF pendhead = NIL THEN pendhead := node ELSE pendtail.next := node
  pendtail := node
  NEW r                                      -> LIFO: children pushed
  AstrCopy(r.path, path, PATHLEN)            -> after their parent end
  r.next := rmhead                           -> up ABOVE it - deepest
  rmhead := r                                -> deletes first
ENDPROC

/* Scans one directory to completion, then deletes its files and
   links and queues its subdirectories. */
PROC scandir(path:PTR TO CHAR) HANDLE
  DEF lock=NIL, head=NIL:PTR TO cent, e:PTR TO cent, ok, err
  DEF w[PATHLEN]:ARRAY OF CHAR

  lock := Lock(path, ACCESS_READ)
  IF lock = NIL
    err := IoErr()
    WriteF('rm: \s: ', path)
    PrintFault(err, NIL)
    setrc(RETURN_ERROR)
    RETURN
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    lock := NIL
    WriteF('rm: cannot examine \s\n', path)
    setrc(RETURN_ERROR)
    RETURN
  ENDIF

  ok := ExNext(lock, gfib)
  WHILE ok
    checkbreak()
    NEW e
    AstrCopy(e.name, gfib.filename, NAMELEN)
    e.etype := gfib.direntrytype
    e.next := head
    head := e
    ok := ExNext(lock, gfib)
  ENDWHILE
  err := IoErr()
  UnLock(lock)
  lock := NIL
  IF err <> ERROR_NO_MORE_ENTRIES
    WriteF('rm: \s: ', path)
    PrintFault(err, NIL)
    setrc(RETURN_ERROR)
  ENDIF

  e := head
  WHILE e
    checkbreak()
    AstrCopy(w, path, PATHLEN)
    AddPart(w, e.name, PATHLEN)
    IF (e.etype = ST_SOFTLINK) OR (e.etype = ST_LINKDIR)
      delfile(w)                             -> the link, not through it
    ELSEIF e.etype > 0
      IF e.name[0] THEN queuedir(w)          -> the ls B1 blank-name rule
    ELSE
      delfile(w)
    ENDIF
    e := e.next
  ENDWHILE
  freecents(head)
EXCEPT
  IF lock THEN UnLock(lock)
  freecents(head)
  ReThrow()
ENDPROC

-> cents are NEW'd: free with END, never Dispose() (the B1 rule)
PROC freecents(head:PTR TO cent)
  DEF e:PTR TO cent
  WHILE head
    e := head
    head := head.next
    END e
  ENDWHILE
ENDPROC

PROC addskip(path:PTR TO CHAR)
  DEF node:PTR TO snode
  NEW node
  AstrCopy(node.path, path, PATHLEN)
  node.next := NIL
  IF skiphead = NIL
    skiphead := node
  ELSE
    skiptail.next := node
  ENDIF
  skiptail := node
  skipcount := skipcount+1
ENDPROC

version: CHAR '$VER: rm 0.1 (27.7.26) E build',0
