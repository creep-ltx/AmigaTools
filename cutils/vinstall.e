/* vinstall.e -- version-aware pack installer for AmigaDOS
   usage: vinstall [-nyf] [FROM [TO]]
   e.g.   vinstall                        (install/update C -> C:)
          vinstall -n                     (report only, change nothing)
          vinstall -y                     (no confirmation question)
          vinstall C SYS:Tools/bin       (explicit directories)

   The point of this one: AmigaDOS version tools stop reading at the
   second dot -- VERSION and Installer's getversion both see "0.3" of
   "0.3.4", so a stale 0.3.3 looks current to them. vinstall parses
   the FULL version out of a $VER string (up to four numeric
   components) and settles ties with a byte compare, so "same
   reported version, different build" is detected instead of trusted.

   For every file in FROM it finds the same name in TO and reports
   one of: not present (install), identical (ok), older (update),
   same version but different build (update -- the archive is the
   canonical build for its version), newer in TO (keep), or archive
   copy unversioned while TO's has a version (keep). Nothing is
   copied until the whole report is printed and one question is
   answered; -y skips the question, -n never copies at all, -f
   includes the kept files in the copy set (downgrades, on your
   head). Protection bits, datestamp and filenote travel with every
   copy, cp-style, and a failed or broken copy removes the partial
   target.

   Ctrl-C is honoured between files and inside copies. Errors on one
   file are reported and the rest still runs. Return code is the
   worst that happened: 0 clean, 5 something was kept back (and
   listed), 10 something failed, 20 break.
*/

MODULE 'dos/dos', 'dos/dosextens'

CONST PATHLEN=512, MAXF=64, BUFSIZE=8192, VERLEN=24

CONST ST_INSTALL=1                       -> not in TO
CONST ST_SAME=2                          -> byte-identical
CONST ST_UPDATE=3                        -> TO's is older (or unversioned)
CONST ST_DIFFER=4                        -> same version, different build
CONST ST_NEWER=5                         -> TO's is newer: keep
CONST ST_SRCNOVER=6                      -> archive unversioned, TO's versioned: keep
CONST ST_ERROR=7

OBJECT ent
  name[108]:ARRAY OF CHAR
  size:LONG
  prot:LONG
  ds[3]:ARRAY OF LONG                    -> source datestamp (days,minute,tick)
  comm[80]:ARRAY OF CHAR
  sver[VERLEN]:ARRAY OF CHAR             -> version texts for the report
  dver[VERLEN]:ARRAY OF CHAR             -> (doubles as the note on ST_ERROR)
  st:LONG
ENDOBJECT

DEF rc, dryrun, yes, force
DEF fromdir[PATHLEN]:ARRAY OF CHAR
DEF todir[PATHLEN]:ARRAY OF CHAR
DEF ents[MAXF]:ARRAY OF ent
DEF eptr[MAXF]:ARRAY OF LONG             -> report order (sorted by name)
DEF nents
DEF gfib:PTR TO fileinfoblock
DEF gb1:PTR TO CHAR                      -> compare/copy chunk buffer

PROC main() HANDLE
  DEF i, e:PTR TO ent, ncopy, nkeep, nerr

  rc := RETURN_OK
  AstrCopy(fromdir, 'C', PATHLEN)
  AstrCopy(todir, 'C:', PATHLEN)

  parseargs()

  NEW gfib
  gb1 := New(BUFSIZE)
  IF gb1 = NIL THEN Throw("ERR", 'vinstall: no memory')

  scandir()
  IF nents = 0 THEN Throw("ERR", 'vinstall: nothing in FROM directory')

  FOR i := 0 TO nents-1
    checkbreak()
    analyze(ents[i])
  ENDFOR

  sortents()
  report()

  ncopy := 0
  nkeep := 0
  nerr := 0
  FOR i := 0 TO nents-1
    e := eptr[i]
    IF incopyset(e) THEN ncopy := ncopy+1
    IF kept(e) THEN nkeep := nkeep+1
    IF e.st = ST_ERROR THEN nerr := nerr+1
  ENDFOR
  IF nkeep > 0 THEN setrc(RETURN_WARN)
  IF nerr > 0 THEN setrc(RETURN_ERROR)

  IF ncopy = 0
    WriteF('vinstall: nothing to do\n')
  ELSEIF dryrun
    WriteF('vinstall: -n, nothing changed (\d file(s) would be copied)\n', ncopy)
  ELSEIF confirm(ncopy)
    FOR i := 0 TO nents-1
      e := eptr[i]
      IF incopyset(e)
        checkbreak()
        install(e)
      ENDIF
    ENDFOR
  ELSE
    WriteF('vinstall: nothing changed\n')
  ENDIF

EXCEPT DO
  IF exception = "BRK"
    WriteF('***Break: vinstall\n')
    setrc(RETURN_FAIL)
  ELSEIF exception = "USG"
    usage()
  ELSEIF exception = "ARG"
    WriteF('vinstall: unknown option (vinstall ? for usage)\n')
    setrc(RETURN_ERROR)
  ELSEIF exception = "MAX"
    WriteF('vinstall: more than \d files in FROM\n', MAXF)
    setrc(RETURN_ERROR)
  ELSEIF exception = "ERR"
    WriteF('\s\n', exceptioninfo)
    setrc(RETURN_ERROR)
  ELSEIF exception = "DOS"
    WriteF('vinstall: ')
    PrintFault(exceptioninfo, NIL)
    setrc(RETURN_ERROR)
  ELSEIF exception
    WriteF('vinstall: error\n')
    setrc(RETURN_ERROR)
  ENDIF
  CleanUp(rc)
ENDPROC

PROC usage()
  WriteF('vinstall 0.1 -- version-aware pack installer\n')
  WriteF('usage: vinstall [-nyf] [FROM [TO]]     (default: C -> C:)\n')
  WriteF('  Compares every file in FROM against the same name in TO, using\n')
  WriteF('  the full version from the $VER string (all components, so 0.3.4\n')
  WriteF('  beats 0.3.3) plus a byte compare. Reports everything first, then\n')
  WriteF('  copies what is missing or out of date after one question.\n')
  WriteF('  Protection bits, datestamp and filenote travel with each copy.\n')
  WriteF('  -n  report only, change nothing\n')
  WriteF('  -y  ask no questions\n')
  WriteF('  -f  also copy kept-back files (TO newer, or archive unversioned)\n')
ENDPROC

/* Tokenizes E's raw command line, ls-style: whitespace-separated,
   double quotes group, `*` escapes inside quotes (AmigaDOS rules, *n
   and *e get their control meanings). -x bundles set flags; a lone ?
   prints usage; the first bare word is FROM, the second TO. */
PROC parseargs()
  DEF p:PTR TO CHAR, tl, c, inq, done, npos
  DEF t[PATHLEN]:ARRAY OF CHAR

  npos := 0
  p := arg
  WHILE p[]
    WHILE (p[] > 0) AND (p[] <= 32) DO p++
    IF p[] = 0 THEN RETURN

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
      ELSEIF npos = 0
        AstrCopy(fromdir, t, PATHLEN)
        npos++
      ELSEIF npos = 1
        AstrCopy(todir, t, PATHLEN)
        npos++
      ELSE
        Throw("ERR", 'vinstall: at most two directories (FROM TO)')
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC

PROC setflags(t:PTR TO CHAR)
  DEF i, c
  i := 1
  WHILE (c := t[i]) <> 0
    SELECT c
    CASE "n" ; dryrun := TRUE
    CASE "y" ; yes := TRUE
    CASE "f" ; force := TRUE
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

/* Collects every FILE directly in FROM (subdirectories are not
   descended -- a pack's binary drawer is flat) with the metadata a
   later copy must carry. More than MAXF files is a hard error, never
   a silent truncation (family rule). */
PROC scandir()
  DEF lock, err, e:PTR TO ent, dsp:PTR TO LONG
  lock := Lock(fromdir, ACCESS_READ)
  IF lock = NIL THEN Throw("ERR", 'vinstall: FROM directory not found')
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    Throw("DOS", IoErr())
  ENDIF
  IF gfib.direntrytype < 0
    UnLock(lock)
    Throw("ERR", 'vinstall: FROM is a file, not a directory')
  ENDIF
  WHILE ExNext(lock, gfib)
    IF gfib.direntrytype < 0
      IF nents >= MAXF
        UnLock(lock)
        Throw("MAX", 0)
      ENDIF
      e := ents[nents]
      AstrCopy(e.name, gfib.filename, 108)
      e.size := gfib.size
      e.prot := gfib.protection
      dsp := gfib.datestamp
      e.ds[0] := dsp[0]
      e.ds[1] := dsp[1]
      e.ds[2] := dsp[2]
      AstrCopy(e.comm, gfib.comment, 80)
      nents++
    ENDIF
  ENDWHILE
  err := IoErr()
  UnLock(lock)
  IF err <> ERROR_NO_MORE_ENTRIES THEN Throw("DOS", err)
ENDPROC

/* The verdict for one file. Byte-identical is decided first (and
   cheapest, sizes gate it); only differing files get their versions
   compared, so the version text in the report is always the truth
   about the bytes, not the other way around. */
PROC analyze(e:PTR TO ent)
  DEF spath[PATHLEN]:ARRAY OF CHAR
  DEF dpath[PATHLEN]:ARRAY OF CHAR
  DEF sbuf:PTR TO CHAR, dbuf:PTR TO CHAR
  DEF lock, dsize, c
  DEF sv[4]:ARRAY OF LONG, dv[4]:ARRAY OF LONG
  DEF sfound, dfound

  makepath(spath, fromdir, e.name)
  makepath(dpath, todir, e.name)

  sbuf := loadfile(spath, e.size)
  IF sbuf = NIL
    e.st := ST_ERROR
    AstrCopy(e.dver, 'FROM copy unreadable', VERLEN)
    RETURN
  ENDIF
  sfound := findver(sbuf, e.size, e.sver, sv)

  lock := Lock(dpath, ACCESS_READ)
  IF lock = NIL
    e.st := ST_INSTALL
    Dispose(sbuf)
    RETURN
  ENDIF
  IF Examine(lock, gfib) = FALSE
    UnLock(lock)
    Dispose(sbuf)
    e.st := ST_ERROR
    AstrCopy(e.dver, 'TO copy unreadable', VERLEN)
    RETURN
  ENDIF
  IF gfib.direntrytype > 0
    UnLock(lock)
    Dispose(sbuf)
    e.st := ST_ERROR
    AstrCopy(e.dver, 'directory in the way', VERLEN)
    RETURN
  ENDIF
  dsize := gfib.size
  UnLock(lock)

  IF dsize = e.size
    IF samefile(sbuf, e.size, dpath)
      e.st := ST_SAME
      AstrCopy(e.dver, e.sver, VERLEN)
      Dispose(sbuf)
      RETURN
    ENDIF
  ENDIF

  dbuf := loadfile(dpath, dsize)
  IF dbuf = NIL
    Dispose(sbuf)
    e.st := ST_ERROR
    AstrCopy(e.dver, 'TO copy unreadable', VERLEN)
    RETURN
  ENDIF
  dfound := findver(dbuf, dsize, e.dver, dv)
  Dispose(dbuf)
  Dispose(sbuf)

  IF sfound AND dfound
    c := vercmp(sv, dv)
    IF c > 0
      e.st := ST_UPDATE
    ELSEIF c < 0
      e.st := ST_NEWER
    ELSE
      e.st := ST_DIFFER
    ENDIF
  ELSEIF sfound
    e.st := ST_UPDATE                    -> TO's unversioned, archive versioned
  ELSEIF dfound
    e.st := ST_SRCNOVER
  ELSE
    e.st := ST_DIFFER                    -> neither versioned; archive is canonical
  ENDIF
ENDPROC

/* Whole file into a New() buffer (E-VO: New handles sizes String()
   cannot; a NIL simply means too big or unreadable and the caller
   degrades honestly). */
PROC loadfile(path:PTR TO CHAR, size)
  DEF fh, buf:PTR TO CHAR, n
  IF size < 0 THEN RETURN NIL
  buf := New(size+1)
  IF buf = NIL THEN RETURN NIL
  fh := Open(path, MODE_OLDFILE)
  IF fh = NIL
    Dispose(buf)
    RETURN NIL
  ENDIF
  n := Read(fh, buf, size)
  Close(fh)
  IF n <> size
    Dispose(buf)
    RETURN NIL
  ENDIF
ENDPROC buf

/* TRUE if the file at path is byte-identical to buf (sizes already
   known equal). Chunked so only one side needs to be in memory. */
PROC samefile(buf:PTR TO CHAR, len, path:PTR TO CHAR)
  DEF fh, n, off, i, r
  r := TRUE
  fh := Open(path, MODE_OLDFILE)
  IF fh = NIL THEN RETURN FALSE
  off := 0
  WHILE r AND (off < len)
    n := Read(fh, gb1, BUFSIZE)
    IF n <= 0
      r := FALSE
    ELSE
      i := 0
      WHILE (i < n) AND r
        IF buf[off+i] <> gb1[i] THEN r := FALSE
        i++
      ENDWHILE
      off := off+n
    ENDIF
  ENDWHILE
  Close(fh)
ENDPROC r

PROC isdig(c)
ENDPROC (c >= "0") AND (c <= "9")

/* Finds the first well-formed $VER string in buf and parses the FULL
   version: up to four dot-separated numeric components into comps
   (missing ones stay 0, so 0.3 = 0.3.0 < 0.3.1), and the version
   text as written into disp for the report. The program name between
   the marker and the number is skipped; a marker with no number at
   all is ignored and the scan continues. FALSE = unversioned. */
PROC findver(buf:PTR TO CHAR, len, disp:PTR TO CHAR, comps:PTR TO LONG)
  DEF i, p, v, n, start, j, more
  FOR j := 0 TO 3 DO comps[j] := 0
  AstrCopy(disp, '-', VERLEN)
  IF buf = NIL THEN RETURN FALSE
  i := 0
  WHILE i <= (len-6)
    IF (buf[i] = "$") AND (buf[i+1] = "V") AND (buf[i+2] = "E") AND
       (buf[i+3] = "R") AND (buf[i+4] = ":")
      p := i+5
      WHILE (p < len) AND (buf[p] = " ") DO p++
      IF (p < len) AND (isdig(buf[p]) = FALSE)     -> program name token
        WHILE (p < len) AND (buf[p] > 32) DO p++
        WHILE (p < len) AND (buf[p] = " ") DO p++
      ENDIF
      IF (p < len) AND isdig(buf[p])
        start := p
        n := 0
        more := TRUE
        WHILE more
          v := 0
          WHILE (p < len) AND isdig(buf[p])
            v := (v*10) + (buf[p]-"0")
            p++
          ENDWHILE
          IF n < 4
            comps[n] := v
            n++
          ENDIF
          more := FALSE
          IF p < (len-1)
            IF (buf[p] = ".") AND isdig(buf[p+1])
              p++
              more := TRUE
            ENDIF
          ENDIF
        ENDWHILE
        j := 0
        WHILE (j < (VERLEN-1)) AND ((start+j) < p)
          disp[j] := buf[start+j]
          j++
        ENDWHILE
        disp[j] := 0
        RETURN TRUE
      ENDIF
      i := p                                       -> no number after marker: keep looking
    ELSE
      i++
    ENDIF
  ENDWHILE
ENDPROC FALSE

/* Component-wise version compare: 1, -1 or 0. */
PROC vercmp(a:PTR TO LONG, b:PTR TO LONG)
  DEF k
  FOR k := 0 TO 3
    IF a[k] > b[k] THEN RETURN 1
    IF a[k] < b[k] THEN RETURN -1
  ENDFOR
ENDPROC 0

/* dir + name -> out, honouring the AmigaDOS join rules: nothing is
   inserted after ':' or '/', a '/' otherwise. */
PROC makepath(out:PTR TO CHAR, dir:PTR TO CHAR, name:PTR TO CHAR)
  DEF l, c
  AstrCopy(out, dir, PATHLEN)
  l := StrLen(out)
  IF l > 0
    c := out[l-1]
    IF (c <> ":") AND (c <> "/")
      IF l < (PATHLEN-2)
        out[l] := "/"
        l++
        out[l] := 0
      ENDIF
    ENDIF
  ENDIF
  AstrCopy(out+l, name, PATHLEN-l)
ENDPROC

PROC lc(c)
  IF (c >= "A") AND (c <= "Z") THEN RETURN c+32
ENDPROC c

PROC namecmp(pa, pb)
  DEF a:PTR TO ent, b:PTR TO ent, i, ca, cb
  a := pa
  b := pb
  i := 0
  REPEAT
    ca := lc(a.name[i])
    cb := lc(b.name[i])
    IF ca <> cb THEN RETURN ca-cb
    i++
  UNTIL ca = 0
ENDPROC 0

/* Insertion sort of the report order -- the walk order of a
   filesystem is no order at all. */
PROC sortents()
  DEF i, j, t
  FOR i := 0 TO nents-1 DO eptr[i] := ents[i]
  IF nents > 1
    FOR i := 1 TO nents-1
      t := eptr[i]
      j := i-1
      WHILE (j >= 0) AND (namecmp(eptr[j], t) > 0)
        eptr[j+1] := eptr[j]
        j--
      ENDWHILE
      eptr[j+1] := t
    ENDFOR
  ENDIF
ENDPROC

PROC wpad(s:PTR TO CHAR, w)
  DEF l
  WriteF('\s', s)
  l := StrLen(s)
  WHILE l < w
    WriteF(' ')
    l++
  ENDWHILE
ENDPROC

/* The report prints "-" in the version column for an unversioned
   file, but says the word in the prose part. */
PROC vdisp(v:PTR TO CHAR)
  IF (v[0] = "-") AND (v[1] = 0) THEN RETURN 'unversioned'
ENDPROC v

PROC dvs(e:PTR TO ent) IS vdisp(e.dver)

PROC report()
  DEF i, e:PTR TO ent
  WriteF('vinstall: \s -> \s\n', fromdir, todir)
  FOR i := 0 TO nents-1
    e := eptr[i]
    WriteF('  ')
    wpad(e.name, 12)
    wpad(e.sver, 10)
    SELECT e.st
    CASE ST_INSTALL
      WriteF('not in \s -> install\n', todir)
    CASE ST_SAME
      WriteF('identical -> ok\n')
    CASE ST_UPDATE
      WriteF('\s there -> update\n', dvs(e))
    CASE ST_DIFFER
      WriteF('\s there, different build -> update\n', dvs(e))
    CASE ST_NEWER
      IF force
        WriteF('\s there is newer -> DOWNGRADE (-f)\n', e.dver)
      ELSE
        WriteF('\s there is newer -> keep (-f overrides)\n', e.dver)
      ENDIF
    CASE ST_SRCNOVER
      IF force
        WriteF('\s there, archive unversioned -> replace (-f)\n', e.dver)
      ELSE
        WriteF('\s there, archive unversioned -> keep (-f overrides)\n', e.dver)
      ENDIF
    CASE ST_ERROR
      WriteF('error: \s\n', e.dver)
    ENDSELECT
  ENDFOR
ENDPROC

PROC incopyset(e:PTR TO ent)
  IF (e.st = ST_INSTALL) OR (e.st = ST_UPDATE) OR (e.st = ST_DIFFER) THEN RETURN TRUE
  IF force AND ((e.st = ST_NEWER) OR (e.st = ST_SRCNOVER)) THEN RETURN TRUE
ENDPROC FALSE

PROC kept(e:PTR TO ent)
  IF force THEN RETURN FALSE
ENDPROC (e.st = ST_NEWER) OR (e.st = ST_SRCNOVER)

/* One question for the whole batch, after the full report. Default
   is No -- non-destructive by default, family rule. */
PROC confirm(n)
  DEF s
  IF yes THEN RETURN TRUE
  s := String(80)
  IF s = NIL THEN RETURN FALSE
  WriteF('vinstall: copy \d file(s) to \s? [y/N] ', n, todir)
  ReadStr(stdin, s)
  IF (s[0] = "y") OR (s[0] = "Y") THEN RETURN TRUE
ENDPROC FALSE

/* Copies one file's data, then carries over protection, datestamp
   and filenote (best-effort: a filesystem that can't store these
   shouldn't fail the copy). A failed or broken copy removes the
   partial target; a Ctrl-C break propagates out after that cleanup. */
PROC install(e:PTR TO ent) HANDLE
  DEF spath[PATHLEN]:ARRAY OF CHAR
  DEF dpath[PATHLEN]:ARRAY OF CHAR
  DEF fhin=NIL, fhout=NIL, n, partial

  makepath(spath, fromdir, e.name)
  makepath(dpath, todir, e.name)
  partial := FALSE

  fhin := Open(spath, MODE_OLDFILE)
  IF fhin = NIL THEN Throw("CPY", IoErr())
  fhout := Open(dpath, MODE_NEWFILE)
  IF fhout = NIL THEN Throw("CPY", IoErr())
  partial := TRUE

  REPEAT
    checkbreak()
    n := Read(fhin, gb1, BUFSIZE)
    IF n > 0
      IF Write(fhout, gb1, n) <> n THEN Throw("CPY", IoErr())
    ENDIF
  UNTIL n <= 0
  IF n < 0 THEN Throw("CPY", IoErr())

  Close(fhout)
  fhout := NIL
  Close(fhin)
  fhin := NIL
  partial := FALSE

  SetProtection(dpath, e.prot)
  SetFileDate(dpath, e.ds)
  IF e.comm[0] THEN SetComment(dpath, e.comm)

  IF e.st = ST_INSTALL
    WriteF('  installed \s \s\n', e.name, e.sver)
  ELSE
    WriteF('  updated \s (\s -> \s)\n', e.name, dvs(e), vdisp(e.sver))
  ENDIF

EXCEPT
  IF fhout THEN Close(fhout)
  IF fhin THEN Close(fhin)
  IF partial THEN DeleteFile(dpath)
  IF exception = "CPY"
    WriteF('  \s: ', e.name)
    PrintFault(exceptioninfo, NIL)
    setrc(RETURN_ERROR)
  ELSE
    ReThrow()
  ENDIF
ENDPROC

version: CHAR '$VER: vinstall 0.1 (28.7.26) E build',0
