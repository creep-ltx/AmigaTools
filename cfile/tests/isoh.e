-> isoh.e - ISO9660 parser harness for CFile's disk-image stage.
-> The iso* procs below are written EXACTLY as they will land in
-> cfile.e (eascan-style caller-frame iterator, heap sector buffer,
-> big-endian halves of the both-endian fields - no byte swapping on
-> a 68k). The harness wraps them in a CLI:
->   isoh <image> LIST                recursive listing to stdout
->   isoh <image> CAT <path> <out>    extract one member to a file
-> Build: ecompile isoh.e   Run: vamos isoh <args>

OPT LARGE

MODULE 'dos/dos'

CONST ISOSEC=2048, ISONAME=110, ISOPATH=300

DEF con, image[300]:STRING, isoroot, isorootsz

-> ---- the cfile-bound core ------------------------------------------

-> big-endian u32 at b (the 68k half of a both-endian field). CD
-> extents/sizes stay far below 2^31, so LONG is safe.
PROC isob32(b:PTR TO CHAR)
ENDPROC Shl(b[0], 24) OR Shl(b[1], 16) OR Shl(b[2], 8) OR b[3]

-> read the Primary Volume Descriptor: root dir extent + byte size.
-> Descriptors start at sector 16; type 1 + "CD001" is the PVD, type
-> 255 ends the set. Returns TRUE with {rootp}/{rszp} filled.
PROC isopvd(fh, rootp:PTR TO LONG, rszp:PTR TO LONG)
  DEF buf:PTR TO CHAR, sec, ok=FALSE, t, r:PTR TO CHAR
  IF (buf := New(ISOSEC)) = NIL THEN RETURN FALSE
  FOR sec := 16 TO 31    -> descriptor set: bounded scan is plenty
    IF ok = FALSE
      IF Seek(fh, Shl(sec, 11), OFFSET_BEGINNING) >= 0
        IF Read(fh, buf, ISOSEC) = ISOSEC
          t := buf[0]
          IF (buf[1] = "C") AND (buf[2] = "D") AND (buf[3] = "0") AND
             (buf[4] = "0") AND (buf[5] = "1")
            IF t = 1
              r := buf + 156          -> the root directory record
              rootp[] := isob32(r + 6)
              rszp[]  := isob32(r + 14)
              ok := TRUE
            ELSEIF t = 255
              sec := 31               -> terminator: stop scanning
            ENDIF
          ELSE
            sec := 31                 -> not a descriptor: stop
          ENDIF
        ENDIF
      ENDIF
    ENDIF
  ENDFOR
  Dispose(buf)
ENDPROC ok

-> caller-frame directory-record iterator (the eascan shape). One
-> heap sector buffer; records never straddle sectors (len byte 0 =
-> the rest of this sector is padding - hop to the next one).
OBJECT isoscan
  fh                          -> image file handle (caller owns)
  ext                         -> dir extent LBA
  secs                        -> sectors in the extent
  cur                         -> sectors consumed so far
  pos                         -> parse offset in buf
  avail                       -> valid bytes in buf
  buf:PTR TO CHAR             -> New(ISOSEC), NIL on alloc fail
  err
  rsize                       -> current record: file byte size
  rext                        ->   extent LBA
  rdir                        ->   nonzero = directory
  rname[ISONAME]:ARRAY OF CHAR  -> display name, NUL-terminated
                              -> (";version" and one trailing "." off)
ENDOBJECT

PROC isodbegin(s:PTR TO isoscan, fh, ext, size)
  s.fh := fh
  s.ext := ext
  s.secs := Shr(size + (ISOSEC - 1), 11)
  s.cur := 0
  s.pos := 0
  s.avail := 0
  s.err := FALSE
  s.buf := New(ISOSEC)
  IF s.buf = NIL THEN s.err := TRUE
ENDPROC

PROC isodsec(s:PTR TO isoscan)    -> pull the next sector into buf
  IF s.cur >= s.secs THEN RETURN FALSE
  IF Seek(s.fh, Shl(s.ext + s.cur, 11), OFFSET_BEGINNING) < 0
    s.err := TRUE
    RETURN FALSE
  ENDIF
  IF Read(s.fh, s.buf, ISOSEC) <> ISOSEC
    s.err := TRUE
    RETURN FALSE
  ENDIF
  s.cur := s.cur + 1
  s.pos := 0
  s.avail := ISOSEC
ENDPROC TRUE

PROC isodnext(s:PTR TO isoscan)
  DEF b:PTR TO CHAR, len, il, i, c, n, going=TRUE
  IF s.err THEN RETURN FALSE
  WHILE going
    IF (s.avail = 0) OR (s.pos >= s.avail)
      IF isodsec(s) = FALSE THEN RETURN FALSE
    ENDIF
    b := s.buf + s.pos
    len := b[0]
    IF len = 0
      s.pos := s.avail    -> padding: the rest of this sector is dead
    ELSEIF (s.pos + len) > s.avail
      s.err := TRUE       -> record claims to straddle: broken image
      RETURN FALSE
    ELSE
      s.pos := s.pos + len
      il := b[32]
      IF (il = 1) AND (b[33] <= 1)
        -> "." / "..": skip
      ELSE
        s.rext := isob32(b + 6)
        s.rsize := isob32(b + 14)
        s.rdir := b[25] AND 2
        n := 0
        IF il > (ISONAME - 2) THEN il := ISONAME - 2
        FOR i := 0 TO il - 1
          c := b[33 + i]
          IF (c = ";") AND (s.rdir = 0)
            i := il             -> ";version": name ends here
          ELSE
            s.rname[n] := c
            n++
          ENDIF
        ENDFOR
        IF n > 1
          IF s.rname[n - 1] = "." THEN n--    -> "TRAIL." stores a dot
        ENDIF
        s.rname[n] := 0
        IF n > 0 THEN going := FALSE          -> a real entry: yield
      ENDIF
    ENDIF
  ENDWHILE
ENDPROC TRUE

PROC isodend(s:PTR TO isoscan)
  IF s.buf THEN Dispose(s.buf)
  s.buf := NIL
ENDPROC

-> case-insensitive compare (cfile has nccmp; harness copy)
PROC hnccmp(a:PTR TO CHAR, b:PTR TO CHAR)
  DEF i=0, ca, cb
  REPEAT
    ca := a[i]
    cb := b[i]
    IF (ca >= "a") AND (ca <= "z") THEN ca := ca - 32
    IF (cb >= "a") AND (cb <= "z") THEN cb := cb - 32
    IF ca <> cb THEN RETURN 1
    i++
  UNTIL ca = 0
ENDPROC 0

-> resolve a "/"-separated path inside the image to (extent, size,
-> isdir), walking from the root. Empty path = the root itself.
PROC isofind(fh, root, rootsz, path:PTR TO CHAR,
             extp:PTR TO LONG, szp:PTR TO LONG, dirp:PTR TO LONG)
  DEF comp[ISONAME]:STRING, i=0, j, ext, sz, isdir=2, found, done=FALSE,
      s[1]:ARRAY OF isoscan, sc:PTR TO isoscan
  ext := root
  sz := rootsz
  sc := s
  WHILE done = FALSE
    -> next path component into comp
    j := 0
    WHILE (path[i] <> 0) AND (path[i] <> "/")
      IF j < (ISONAME - 2)
        comp[j] := path[i]
        j++
      ENDIF
      i++
    ENDWHILE
    IF path[i] = "/" THEN i++
    comp[j] := 0
    SetStr(comp, j)
    IF j = 0
      IF path[i] = 0 THEN done := TRUE    -> ran out of components
    ELSE
      IF isdir = 0 THEN RETURN FALSE      -> component under a FILE
      found := FALSE
      isodbegin(sc, fh, ext, sz)
      WHILE (found = FALSE) AND isodnext(sc)
        IF hnccmp(sc.rname, comp) = 0
          ext := sc.rext
          sz := sc.rsize
          isdir := sc.rdir
          found := TRUE
        ENDIF
      ENDWHILE
      isodend(sc)
      IF found = FALSE THEN RETURN FALSE
      IF path[i] = 0 THEN done := TRUE
    ENDIF
  ENDWHILE
  extp[] := ext
  szp[] := sz
  dirp[] := isdir
ENDPROC TRUE

-> ---- harness-only below this line ----------------------------------

PROC out(s)
  Write(con, s, StrLen(s))
ENDPROC

-> recursive listing: "<path> <size> <D|F>" per line, dirs first walked
PROC listdir(fh, ext, sz, prefix:PTR TO CHAR, depth)
  DEF s[1]:ARRAY OF isoscan, sc:PTR TO isoscan, line[500]:STRING,
      sub[ISOPATH]:STRING,
      dext[64]:ARRAY OF LONG, dsz[64]:ARRAY OF LONG, nd=0, k,
      dnames:PTR TO LONG
  IF depth > 20 THEN RETURN
  IF (dnames := New(64 * 4)) = NIL THEN RETURN
  sc := s
  isodbegin(sc, fh, ext, sz)
  WHILE isodnext(sc)
    StringF(line, '\s\s \d \s\n', prefix, sc.rname, sc.rsize,
            IF sc.rdir THEN 'D' ELSE 'F')
    out(line)
    IF sc.rdir AND (nd < 64)
      dext[nd] := sc.rext
      dsz[nd] := sc.rsize
      IF (dnames[nd] := String(StrLen(sc.rname) + 2))
        StrCopy(dnames[nd], sc.rname)
        nd++
      ENDIF
    ENDIF
  ENDWHILE
  IF sc.err THEN out('SCAN ERROR\n')
  isodend(sc)
  FOR k := 0 TO nd - 1
    StringF(sub, '\s\s/', prefix, dnames[k])
    listdir(fh, dext[k], dsz[k], sub, depth + 1)
    DisposeLink(dnames[k])
  ENDFOR
  Dispose(dnames)
ENDPROC

PROC docat(fh, path, outname)
  DEF ext, sz, isdir, fo, buf:PTR TO CHAR, left, n
  IF isofind(fh, isoroot, isorootsz, path, {ext}, {sz}, {isdir}) = FALSE
    out('NOT FOUND\n')
    RETURN
  ENDIF
  IF isdir
    out('IS A DIRECTORY\n')
    RETURN
  ENDIF
  IF (buf := New(ISOSEC)) = NIL THEN RETURN
  IF (fo := Open(outname, NEWFILE)) = NIL
    Dispose(buf)
    out('CANNOT OPEN OUT\n')
    RETURN
  ENDIF
  Seek(fh, Shl(ext, 11), OFFSET_BEGINNING)
  left := sz
  WHILE left > 0
    n := IF left > ISOSEC THEN ISOSEC ELSE left
    IF Read(fh, buf, n) <> n
      out('READ ERROR\n')
      left := 0
    ELSE
      Write(fo, buf, n)
      left := left - n
    ENDIF
  ENDWHILE
  Close(fo)
  Dispose(buf)
  out('OK\n')
ENDPROC

PROC main()
  DEF a:PTR TO CHAR, i=0, j, w[4]:ARRAY OF LONG, nw=0,
      word[300]:STRING, fh, cmd
  con := stdout
  a := arg
  -> split up to 4 space-separated words
  WHILE (a[i] <> 0) AND (nw < 4)
    WHILE a[i] = 32
      i++
    ENDWHILE
    j := 0
    WHILE (a[i] <> 32) AND (a[i] <> 0)
      IF j < 298
        word[j] := a[i]
        j++
      ENDIF
      i++
    ENDWHILE
    word[j] := 0
    IF j > 0
      IF (w[nw] := String(j + 2))
        StrCopy(w[nw], word)
        SetStr(w[nw], j)
        nw++
      ENDIF
    ENDIF
  ENDWHILE
  IF nw < 2
    out('usage: isoh <image> LIST | CAT <path> <out>\n')
    RETURN
  ENDIF
  StrCopy(image, w[0])
  IF (fh := Open(image, OLDFILE)) = NIL
    out('cannot open image\n')
    RETURN
  ENDIF
  IF isopvd(fh, {isoroot}, {isorootsz}) = FALSE
    out('no PVD - not an ISO9660 image\n')
    Close(fh)
    RETURN
  ENDIF
  cmd := w[1]
  IF hnccmp(cmd, 'LIST') = 0
    listdir(fh, isoroot, isorootsz, '', 0)
  ELSEIF (hnccmp(cmd, 'CAT') = 0) AND (nw >= 4)
    docat(fh, w[2], w[3])
  ELSE
    out('bad command\n')
  ENDIF
  Close(fh)
ENDPROC
