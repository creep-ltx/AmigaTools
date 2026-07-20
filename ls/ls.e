/* ls.e -- Unix-style directory lister for AmigaDOS
   usage: ls [-1ahlrRSt] [path | pattern ...]

   The point is muscle memory: `ls -la` should do on an Amiga what
   fingers expect from Linux. So this deliberately breaks house
   ReadArgs style and hand-parses bundled -flags; `ls ?` still
   answers with usage, as an AmigaDOS command should.

   Mapping decisions:
   - `-a` maps to .info files (the Amiga's dotfile class) plus
     entries with the h protection bit; both hidden by default.
   - `-l` prints hsparwed instead of rwxrwxrwx, byte size, the
     DOS datestamp, and the filenote on a continuation line.
   - `-h` shows sizes tiered as bytes / K / M / G. The arithmetic
     uses Shr()/Mod() throughout: E's `/` compiles to hardware
     DIVU with a 16-bit quotient and silently garbles anything
     bigger (the amifetch lesson).
   - Multi-column output sized from the console: write the CSI
     `0 q` window-bounds request, read the `CSI 1;1;rows;cols r`
     report back in raw mode -- the same exchange C:Dir uses.
     Non-interactive output falls back to one entry per line, so
     redirected/piped output stays parseable.
   - Colors on interactive output: directories blue (1;34),
     hidden-class entries - h-bit or .info - grey (1;30).
   - A pattern argument lists the matches themselves (like ls -d):
     `ls #?.e` does what it says; a plain directory argument lists
     the directory's contents.

   Sort is name (case-insensitive, mixed dirs and files like ls),
   -t newest first, -S largest first, -r reverses. -R recurses
   depth-first with `path:` group headers.

   Ctrl-C is honoured between entries and rows. Return code:
   0 clean, 5 a path could not be accessed, 10 bad arguments,
   20 break.
*/

MODULE 'dos/dos', 'dos/dosextens', 'dos/dosasl', 'dos/datetime'

CONST PATHLEN=512, MAXARGS=32, NAMELEN=110
CONST SORT_NAME=0, SORT_TIME=1, SORT_SIZE=2

OBJECT dent
  next:PTR TO dent
  size:LONG
  blocks:LONG
  prot:LONG
  days:LONG
  minute:LONG
  tick:LONG
  isdir:LONG
  name[NAMELEN]:ARRAY OF CHAR
  comm[80]:ARRAY OF CHAR
ENDOBJECT

OBJECT pnode
  next:PTR TO pnode
  path[PATHLEN]:ARRAY OF CHAR
ENDOBJECT

DEF rc
DEF flong=FALSE, fall=FALSE, fone=FALSE, fhum=FALSE, frev=FALSE, frec=FALSE
DEF sortby=SORT_NAME
DEF twidth=77, tinter=FALSE, headers=FALSE, firstgrp=TRUE
DEF gfib=NIL:PTR TO fileinfoblock
DEF gdt=NIL:PTR TO datetime
DEF gline=NIL:PTR TO CHAR                   -> estring, line assembly
DEF gtmp=NIL:PTR TO CHAR                    -> estring, size field
DEF gdate=NIL:PTR TO CHAR, gtime=NIL:PTR TO CHAR
DEF gpatbuf[1030]:ARRAY OF CHAR
DEF pendhead=NIL:PTR TO pnode               -> -R work list, depth-first
DEF seqdir[8]:ARRAY OF CHAR                 -> CSI 1;34m, dirs: blue
DEF seqhid[8]:ARRAY OF CHAR                 -> CSI 1;30m, hidden: grey
DEF seqoff[8]:ARRAY OF CHAR                 -> CSI 0m

PROC main() HANDLE
  DEF paths[MAXARGS]:ARRAY OF LONG
  DEF npaths, i
  DEF node:PTR TO pnode

  rc := RETURN_OK
  NEW gfib
  NEW gdt
  gline := String(700)
  gtmp  := String(64)
  gdate := String(LEN_DATSTRING)
  gtime := String(LEN_DATSTRING)
  seqdir[0] := $9B; seqdir[1] := "1"; seqdir[2] := ";"; seqdir[3] := "3"
  seqdir[4] := "4"; seqdir[5] := "m"; seqdir[6] := 0
  seqhid[0] := $9B; seqhid[1] := "1"; seqhid[2] := ";"; seqhid[3] := "3"
  seqhid[4] := "0"; seqhid[5] := "m"; seqhid[6] := 0
  seqoff[0] := $9B; seqoff[1] := "0"; seqoff[2] := "m"; seqoff[3] := 0

  npaths := parseargs(paths)

  tinter := checkinter()
  IF tinter = FALSE THEN fone := TRUE
  IF tinter
    IF (flong = FALSE) AND (fone = FALSE) THEN twidth := termwidth()
  ENDIF

  headers := frec OR (npaths > 1)

  IF npaths = 0
    listpath('')
  ELSE
    FOR i := 0 TO npaths-1 DO listpath(paths[i])
  ENDIF

  WHILE pendhead
    checkbreak()
    node := pendhead
    pendhead := node.next
    listdir(node.path)
    Dispose(node)
  ENDWHILE

EXCEPT DO
  IF exception = "BRK"
    WriteF('***Break: ls\n')
    setrc(RETURN_FAIL)
  ELSEIF exception = "ARG"
    WriteF('ls: unknown option (ls ? for usage)\n')
    setrc(RETURN_ERROR)
  ELSEIF exception = "USG"
    usage()
  ELSEIF exception = "DOS"
    PrintFault(exceptioninfo, 'ls')
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('ls: error\n')
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC setrc(v)
  IF v > rc THEN rc := v
ENDPROC

PROC checkbreak()
  IF SetSignal(0, SIGBREAKF_CTRL_C) AND SIGBREAKF_CTRL_C THEN Throw("BRK", 0)
ENDPROC

PROC usage()
  WriteF('ls 0.2 -- Unix-style directory lister\n')
  WriteF('usage: ls [-1ahlrRSt] [path | pattern ...]\n')
  WriteF('  -l  long listing (protection, size, date, filenote)\n')
  WriteF('  -a  show .info files and hidden (h-bit) entries\n')
  WriteF('  -h  human-readable sizes (K, M, G)\n')
  WriteF('  -t  sort by date, newest first\n')
  WriteF('  -S  sort by size, largest first\n')
  WriteF('  -r  reverse sort order\n')
  WriteF('  -R  recurse into directories\n')
  WriteF('  -1  one entry per line\n')
ENDPROC

/* Tokenizes E's raw command line: whitespace-separated, double
   quotes group, `*` escapes inside quotes (AmigaDOS rules, *n and
   *e get their control meanings). -x bundles set flags; a lone ?
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
    CASE "l" ; flong := TRUE
    CASE "a" ; fall := TRUE
    CASE "h" ; fhum := TRUE
    CASE "t" ; sortby := SORT_TIME
    CASE "S" ; sortby := SORT_SIZE
    CASE "r" ; frev := TRUE
    CASE "R" ; frec := TRUE
    CASE "1" ; fone := TRUE
    DEFAULT  ; Throw("ARG", c)
    ENDSELECT
    i++
  ENDWHILE
ENDPROC

PROC checkinter()
  DEF a, b
  a := IsInteractive(Output())
  b := IsInteractive(Input())
  IF a AND b THEN RETURN TRUE
ENDPROC FALSE

/* Asks the console for its size: raw mode, CSI `0 q`, parse the
   `CSI 1;1;rows;cols r` report (params until the first byte >=
   $40 -- the CSI rule). The report introducer may be the 8-bit CSI
   ($9B) stock CON: sends or the 7-bit ESC[ two-byte form; both are
   accepted, so the whole report is consumed and nothing leaks into
   the next command line. Every read is guarded by WaitForChar so a
   console that never answers costs 0.5s, not a hang. */
PROC termwidth()
  DEF req[4]:ARRAY OF CHAR, b[4]:ARRAY OF CHAR
  DEF params[8]:ARRAY OF LONG
  DEF w, np, i, c, done, infh, outfh, gotesc

  w := 77
  infh := Input()
  outfh := Output()
  FOR i := 0 TO 7 DO params[i] := 0

  SetMode(infh, 1)
  req[0] := $9B; req[1] := "0"; req[2] := $20; req[3] := "q"
  Write(outfh, req, 4)

  np := 0
  gotesc := FALSE
  done := FALSE
  IF WaitForChar(infh, 500000) = FALSE THEN done := TRUE
  WHILE done = FALSE
    IF Read(infh, b, 1) <> 1
      done := TRUE
    ELSE
      c := b[0]
      IF gotesc
        gotesc := FALSE
        IF c = "[" THEN np := 0              -> ESC [ : 7-bit CSI introducer
      ELSEIF c = 27
        gotesc := TRUE                       -> maybe a 7-bit CSI (ESC [)
      ELSEIF c = $9B
        np := 0                              -> 8-bit CSI introducer
      ELSEIF (c >= "0") AND (c <= "9")
        IF np < 8 THEN params[np] := (params[np] * 10) + (c - "0")
      ELSEIF c = ";"
        np++
      ELSEIF c >= $40                        -> final byte
        np++
        done := TRUE
      ENDIF
    ENDIF
    IF done = FALSE
      IF WaitForChar(infh, 250000) = FALSE THEN done := TRUE
    ENDIF
  ENDWHILE
  SetMode(infh, 0)

  IF np >= 4
    IF params[3] > 0 THEN w := params[3]
  ENDIF
ENDPROC w

/* One command-line argument: a pattern lists its matches, a plain
   directory lists its contents, a plain file lists itself. */
PROC listpath(path:PTR TO CHAR)
  DEF lock, isdir, wild, err

  wild := ParsePatternNoCase(path, gpatbuf, 1024) = 1
  IF wild
    listmatches(path)
    RETURN
  ENDIF

  lock := Lock(path, ACCESS_READ)
  IF lock = NIL
    err := IoErr()
    WriteF('ls: cannot access \s: ', path)
    PrintFault(err, NIL)
    setrc(RETURN_WARN)
    RETURN
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    WriteF('ls: cannot examine \s\n', path)
    setrc(RETURN_WARN)
    RETURN
  ENDIF
  isdir := gfib.direntrytype > 0
  UnLock(lock)

  IF isdir
    listdir(path)
  ELSE
    listsingle(path)
  ENDIF
ENDPROC

/* A single already-Examine'd file (gfib holds it): one entry,
   shown under the name it was typed as. */
PROC listsingle(path:PTR TO CHAR)
  DEF e:PTR TO dent, arr:PTR TO LONG
  e := mkent(gfib)
  AstrCopy(e.name, path, NAMELEN)
  arr := New(4)
  arr[0] := e
  output(arr, 1, FALSE)
  Dispose(arr)
  Dispose(e)
ENDPROC

/* Pattern argument: MatchFirst/MatchNext, matches listed as
   entries themselves (dirs included -- the ls -d simplification). */
PROC listmatches(spec:PTR TO CHAR) HANDLE
  DEF ap=NIL:PTR TO anchorpath
  DEF res, path:PTR TO CHAR, ifib:PTR TO fileinfoblock
  DEF head=NIL:PTR TO dent, e:PTR TO dent, count

  ap := New(SIZEOF anchorpath + PATHLEN)
  ap.strlen := PATHLEN-1
  path := ap + SIZEOF anchorpath
  ifib := {ap.info}

  count := 0
  res := MatchFirst(spec, ap)
  WHILE res = 0
    checkbreak()
    e := mkent(ifib)
    AstrCopy(e.name, path, NAMELEN)
    e.next := head
    head := e
    count++
    res := MatchNext(ap)
  ENDWHILE
  IF res <> ERROR_NO_MORE_ENTRIES
    WriteF('ls: \s: ', spec)
    PrintFault(res, NIL)
    setrc(RETURN_WARN)
  ENDIF
  MatchEnd(ap)
  Dispose(ap)

  IF count = 0
    IF res = ERROR_NO_MORE_ENTRIES
      WriteF('ls: \s: no match\n', spec)
      setrc(RETURN_WARN)
    ENDIF
  ELSE
    sortout(head, count, FALSE, NIL)
  ENDIF
  freelist(head)
EXCEPT
  IF ap
    MatchEnd(ap)
    Dispose(ap)
  ENDIF
  freelist(head)
  ReThrow()
ENDPROC

/* Scans one directory into a list, prints it, and with -R queues
   its subdirectories (depth-first: the group is prepended to the
   work list in display order). */
PROC listdir(path:PTR TO CHAR) HANDLE
  DEF lock=NIL, head=NIL:PTR TO dent, count, e:PTR TO dent
  DEF ok, err, disp:PTR TO CHAR
  DEF dbuf[NAMELEN]:ARRAY OF CHAR

  lock := Lock(path, ACCESS_READ)
  IF lock = NIL
    err := IoErr()
    WriteF('ls: cannot access \s: ', path)
    PrintFault(err, NIL)
    setrc(RETURN_WARN)
    RETURN
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    WriteF('ls: cannot examine \s\n', path)
    setrc(RETURN_WARN)
    RETURN
  ENDIF

  -> gfib is reused by every ExNext below -- the dir's own name
  -> must be copied out, not pointed at
  AstrCopy(dbuf, gfib.filename, NAMELEN)
  disp := IF path[0] THEN path ELSE dbuf

  count := 0
  ok := ExNext(lock, gfib)
  WHILE ok
    checkbreak()
    IF keepentry(gfib)
      e := mkent(gfib)
      e.next := head
      head := e
      count++
    ENDIF
    ok := ExNext(lock, gfib)
  ENDWHILE
  err := IoErr()
  UnLock(lock)
  lock := NIL
  IF err <> ERROR_NO_MORE_ENTRIES
    WriteF('ls: \s: ', disp)
    PrintFault(err, NIL)
    setrc(RETURN_WARN)
  ENDIF

  IF headers
    IF firstgrp = FALSE THEN WriteF('\n')
    WriteF('\s:\n', disp)
  ENDIF
  firstgrp := FALSE

  sortout(head, count, TRUE, path)
  freelist(head)
EXCEPT
  IF lock THEN UnLock(lock)
  freelist(head)
  ReThrow()
ENDPROC

/* Sorts a collected entry list into an array and prints it; for a
   directory listing (-R), also queues subdirectories. */
PROC sortout(head:PTR TO dent, count, isdirlist, path:PTR TO CHAR)
  DEF arr:PTR TO LONG, e:PTR TO dent, i
  DEF ghead=NIL:PTR TO pnode, gtail=NIL:PTR TO pnode, node:PTR TO pnode

  IF count = 0
    IF flong AND isdirlist THEN WriteF('total 0\n')
    RETURN
  ENDIF

  arr := New(Mul(count, 4))
  e := head
  i := 0
  WHILE e
    arr[i] := e
    i++
    e := e.next
  ENDWHILE
  sortarr(arr, count)

  output(arr, count, isdirlist)

  IF frec AND isdirlist
    FOR i := 0 TO count-1
      e := arr[IF frev THEN count-1-i ELSE i]
      IF e.isdir
        NEW node
        AstrCopy(node.path, path, PATHLEN)
        AddPart(node.path, e.name, PATHLEN)
        node.next := NIL
        IF ghead = NIL
          ghead := node
        ELSE
          gtail.next := node
        ENDIF
        gtail := node
      ENDIF
    ENDFOR
    IF ghead                                 -> prepend group: depth-first
      gtail.next := pendhead
      pendhead := ghead
    ENDIF
  ENDIF

  Dispose(arr)
ENDPROC

PROC freelist(head:PTR TO dent)
  DEF e:PTR TO dent
  WHILE head
    e := head
    head := head.next
    Dispose(e)
  ENDWHILE
ENDPROC

PROC keepentry(fib:PTR TO fileinfoblock)
  DEF l, n:PTR TO CHAR
  IF fall THEN RETURN TRUE
  IF (fib.protection AND $80) <> 0 THEN RETURN FALSE   -> FIBF_HIDDEN
  l := StrLen(fib.filename)
  IF l >= 6
    n := fib.filename
    n := n + l - 5
    IF suffinfo(n) THEN RETURN FALSE
  ENDIF
ENDPROC TRUE

PROC suffinfo(n:PTR TO CHAR)
  IF ucase(n[0]) <> "." THEN RETURN FALSE
  IF ucase(n[1]) <> "I" THEN RETURN FALSE
  IF ucase(n[2]) <> "N" THEN RETURN FALSE
  IF ucase(n[3]) <> "F" THEN RETURN FALSE
  IF ucase(n[4]) <> "O" THEN RETURN FALSE
ENDPROC TRUE

PROC ucase(c)
  IF (c >= "a") AND (c <= "z") THEN RETURN c - 32
ENDPROC c

PROC mkent(fib:PTR TO fileinfoblock)
  DEF e:PTR TO dent, ds:PTR TO datestamp
  NEW e
  AstrCopy(e.name, fib.filename, NAMELEN)
  AstrCopy(e.comm, fib.comment, 80)
  e.size := fib.size
  e.blocks := fib.numblocks
  e.prot := fib.protection
  ds := fib.datestamp
  e.days := ds.days
  e.minute := ds.minute
  e.tick := ds.tick
  e.isdir := IF fib.direntrytype > 0 THEN TRUE ELSE FALSE
ENDPROC e

/* ---- sorting ---- */

PROC cmpname(a:PTR TO CHAR, b:PTR TO CHAR)
  DEF i, ca, cb
  i := 0
  REPEAT
    ca := ucase(a[i])
    cb := ucase(b[i])
    i++
  UNTIL (ca <> cb) OR (ca = 0)
  IF ca > cb THEN RETURN 1
  IF ca < cb THEN RETURN -1
ENDPROC 0

PROC cmpent(a:PTR TO dent, b:PTR TO dent)
  IF sortby = SORT_TIME                      -> newest first
    IF b.days   > a.days   THEN RETURN 1
    IF b.days   < a.days   THEN RETURN -1
    IF b.minute > a.minute THEN RETURN 1
    IF b.minute < a.minute THEN RETURN -1
    IF b.tick   > a.tick   THEN RETURN 1
    IF b.tick   < a.tick   THEN RETURN -1
  ELSEIF sortby = SORT_SIZE                  -> largest first
    IF b.size > a.size THEN RETURN 1
    IF b.size < a.size THEN RETURN -1
  ENDIF
ENDPROC cmpname(a.name, b.name)

PROC sortarr(arr:PTR TO LONG, n)
  DEF gap, i, j, t, cont
  gap := 1
  WHILE gap < n DO gap := (gap * 3) + 1
  WHILE gap > 1
    gap := gap / 3                           -> gap stays small: 16-bit / is safe
    IF gap < 1 THEN gap := 1
    IF gap <= (n - 1)
      FOR i := gap TO n-1
        t := arr[i]
        j := i
        cont := TRUE
        WHILE cont
          IF j >= gap
            IF cmpent(arr[j - gap], t) > 0
              arr[j] := arr[j - gap]
              j := j - gap
            ELSE
              cont := FALSE
            ENDIF
          ELSE
            cont := FALSE
          ENDIF
        ENDWHILE
        arr[j] := t
      ENDFOR
    ENDIF
    IF gap = 1 THEN RETURN
  ENDWHILE
ENDPROC

/* ---- output ---- */

PROC output(arr:PTR TO LONG, count, isdirlist)
  DEF i, e:PTR TO dent, tot

  firstgrp := FALSE                          -> a later dir group gets its blank line

  IF flong
    IF isdirlist
      tot := 0
      FOR i := 0 TO count-1
        e := arr[i]
        tot := tot + e.blocks
      ENDFOR
      WriteF('total \d\n', tot)
    ENDIF
    FOR i := 0 TO count-1
      checkbreak()
      longline(arr[IF frev THEN count-1-i ELSE i])
    ENDFOR
  ELSE
    columns(arr, count)
  ENDIF
ENDPROC

PROC getent(arr:PTR TO LONG, count, i)
ENDPROC arr[IF frev THEN count-1-i ELSE i]

PROC columns(arr:PTR TO LONG, count)
  DEF i, r, c, idx, maxlen, l, colw, ncols, nrows
  DEF e:PTR TO dent, outfh

  outfh := Output()
  maxlen := 1
  FOR i := 0 TO count-1
    e := arr[i]
    l := StrLen(e.name)
    IF l > maxlen THEN maxlen := l
  ENDFOR
  colw := maxlen + 2
  ncols := IF fone THEN 1 ELSE twidth / colw
  IF ncols < 1 THEN ncols := 1
  nrows := ((count + ncols) - 1) / ncols

  FOR r := 0 TO nrows-1
    checkbreak()
    StrCopy(gline, '')
    FOR c := 0 TO ncols-1
      idx := Mul(c, nrows) + r
      IF idx < count
        e := getent(arr, count, idx)
        addname(e)
        IF (c < (ncols - 1)) AND ((Mul(c + 1, nrows) + r) < count)
          l := StrLen(e.name)
          WHILE l < colw
            StrAdd(gline, ' ')
            l++
          ENDWHILE
        ENDIF
      ENDIF
    ENDFOR
    StrAdd(gline, '\n')
    Write(outfh, gline, EstrLen(gline))
  ENDFOR
ENDPROC

-> the colour scheme: directories blue, hidden-class entries (h-bit
-> or .info) grey - grey wins, dimming is the point - plain files in
-> the terminal's default
PROC ishid(e:PTR TO dent)
  DEF l
  IF e.prot AND $80 THEN RETURN TRUE
  l := StrLen(e.name)
  IF l >= 6
    IF suffinfo(e.name + l - 5) THEN RETURN TRUE
  ENDIF
ENDPROC FALSE

PROC addname(e:PTR TO dent)
  IF tinter AND ishid(e)
    StrAdd(gline, seqhid)
    StrAdd(gline, e.name)
    StrAdd(gline, seqoff)
  ELSEIF tinter AND e.isdir
    StrAdd(gline, seqdir)
    StrAdd(gline, e.name)
    StrAdd(gline, seqoff)
  ELSE
    StrAdd(gline, e.name)
  ENDIF
ENDPROC

PROC longline(e:PTR TO dent)
  DEF l, wid, ds:PTR TO datestamp, outfh

  outfh := Output()
  StrCopy(gline, '')

  -> hsparwed: h/s/p/a lit when SET, r/w/e/d lit when CLEAR
  StrAdd(gline, IF e.prot AND $80 THEN 'h' ELSE '-')
  StrAdd(gline, IF e.prot AND $40 THEN 's' ELSE '-')
  StrAdd(gline, IF e.prot AND $20 THEN 'p' ELSE '-')
  StrAdd(gline, IF e.prot AND $10 THEN 'a' ELSE '-')
  StrAdd(gline, IF e.prot AND $08 THEN '-' ELSE 'r')
  StrAdd(gline, IF e.prot AND $04 THEN '-' ELSE 'w')
  StrAdd(gline, IF e.prot AND $02 THEN '-' ELSE 'e')
  StrAdd(gline, IF e.prot AND $01 THEN '-' ELSE 'd')
  StrAdd(gline, ' ')

  IF e.isdir
    StrCopy(gtmp, 'Dir')
  ELSE
    fmtsize(e.size)
  ENDIF
  wid := IF fhum THEN 6 ELSE 10
  l := EstrLen(gtmp)
  WHILE l < wid
    StrAdd(gline, ' ')
    l++
  ENDWHILE
  StrAdd(gline, gtmp)
  StrAdd(gline, ' ')

  ds := gdt.stamp
  ds.days := e.days
  ds.minute := e.minute
  ds.tick := e.tick
  gdt.format := FORMAT_DOS
  gdt.flags := 0
  gdt.strday := NIL
  gdt.strdate := gdate
  gdt.strtime := gtime
  IF DateToStr(gdt)
    StrAdd(gline, gdate)
    StrAdd(gline, ' ')
    StrAdd(gline, gtime)
  ELSE
    StrAdd(gline, '------------------')
  ENDIF
  StrAdd(gline, ' ')

  addname(e)
  StrAdd(gline, '\n')
  IF e.comm[0]
    StrAdd(gline, ': ')
    StrAdd(gline, e.comm)
    StrAdd(gline, '\n')
  ENDIF
  Write(outfh, gline, EstrLen(gline))
ENDPROC

/* Size into gtmp. Human tiers use shifts ONLY -- E's `/` is
   16-bit DIVU (quotient garbles past 32767), and Mod() with a
   divisor over 64K raised a CPU exception under vamos (found
   here: Mod(v,1048576) crashed; Mod is only proven for small
   divisors). Remainder = v - Shl(units,n), tenths via one small
   Mul plus a shift. */
PROC fmtsize(v)
  DEF units, rem, tenths
  IF fhum = FALSE
    StringF(gtmp, '\d', v)
  ELSEIF v < 1024
    StringF(gtmp, '\d', v)
  ELSEIF v < 10240
    units := Shr(v, 10)
    rem := v - Shl(units, 10)                -> 0..1023 bytes
    tenths := Shr(Mul(rem, 10), 10)
    StringF(gtmp, '\d.\dK', units, tenths)
  ELSEIF v < 1048576
    StringF(gtmp, '\dK', Shr(v, 10))
  ELSEIF v < 10485760
    units := Shr(v, 20)
    rem := Shr(v - Shl(units, 20), 10)       -> 0..1023 KB
    tenths := Shr(Mul(rem, 10), 10)
    StringF(gtmp, '\d.\dM', units, tenths)
  ELSEIF v < 1073741824
    StringF(gtmp, '\dM', Shr(v, 20))
  ELSE
    units := Shr(v, 30)
    rem := Shr(v - Shl(units, 30), 20)       -> 0..1023 MB
    tenths := Shr(Mul(rem, 10), 10)
    StringF(gtmp, '\d.\dG', units, tenths)
  ENDIF
ENDPROC

version: CHAR '$VER: ls 0.2 (20.7.26) E build',0
