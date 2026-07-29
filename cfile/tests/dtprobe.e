-> dtprobe - datatypes probe round 1 (CFile picture-viewer recon,
-> 30.7.26). Scans Amiga:DTTest/, identifies every file through
-> datatypes.library, decodes every picture NATIVE (no remap) and
-> reports what the class really delivers (dimensions, depth, mode
-> id, colour count, bitmap), then displays each displayable one
-> full-screen for ~5 seconds. Output: Amiga:dtprobe.out
-> Run from a shell:  Amiga:dtprobe

MODULE 'datatypes', 'datatypes/datatypes', 'datatypes/datatypesclass',
       'datatypes/pictureclass', 'intuition/screens', 'graphics/gfx',
       'graphics/rastport', 'exec/libraries',
       'dos/dos', 'utility/tagitem'

DEF datatypesbase=NIL:PTR TO lib, fo=NIL, line[340]:STRING

PROC out(s)
  Write(fo, s, StrLen(s))
ENDPROC

-> show one decoded picture on its own screen: the image's own mode
-> id and depth, its own palette, centered, ~5 seconds
PROC showpic(bm:PTR TO bitmap, bmh:PTR TO bitmapheader, mid,
             cregs:PTR TO LONG, ncol)
  DEF scr=NIL:PTR TO screen, sw, sh, tab=NIL:PTR TO LONG, k, w, h
  sw := bmh.width
  IF sw < 320 THEN sw := 320
  sh := bmh.height
  IF sh < 200 THEN sh := 200
  scr := OpenScreenTagList(NIL,
    [SA_WIDTH,     sw,
     SA_HEIGHT,    sh,
     SA_DEPTH,     bm.depth,
     SA_DISPLAYID, mid,
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     TAG_DONE,     NIL])
  IF scr = NIL
    out('  display: OpenScreen FAILED for that mode\n')
    RETURN
  ENDIF
  IF cregs
    IF ncol > 0
      IF ncol > 256 THEN ncol := 256
      IF (tab := New((Mul(ncol, 3) + 2) * 4))
        tab[0] := Shl(ncol, 16)
        FOR k := 0 TO Mul(ncol, 3) - 1
          tab[k + 1] := cregs[k]
        ENDFOR
        tab[Mul(ncol, 3) + 1] := 0
        LoadRGB32(scr.viewport, tab)
        Dispose(tab)
      ENDIF
    ENDIF
  ENDIF
  w := bmh.width
  IF w > sw THEN w := sw
  h := bmh.height
  IF h > sh THEN h := sh
  BltBitMap(bm, 0, 0, scr.rastport.bitmap,
            Shr(sw - w, 1), Shr(sh - h, 1), w, h, $C0, $FF, NIL)
  Delay(250)
  CloseScreen(scr)
  out('  display: shown\n')
ENDPROC

PROC probepic(path)
  DEF o=NIL, res, n, bmh=NIL:PTR TO bitmapheader, bm=NIL:PTR TO bitmap,
      mid=0, cregs=NIL:PTR TO LONG, ncol=0
  o := NewDTObjectA(path,
    [DTA_SOURCETYPE, DTST_FILE,
     DTA_GROUPID,    GID_PICTURE,
     PDTA_REMAP,     FALSE,
     TAG_DONE,       NIL])
  IF o = NIL
    StringF(line, '  decode: NewDTObject FAILED (ioerr \d)\n', IoErr())
    out(line)
    RETURN
  ENDIF
  res := DoDTMethodA(o, NIL, NIL, [DTM_PROCLAYOUT, NIL, 1])
  n := GetDTAttrsA(o,
    [PDTA_BITMAPHEADER, {bmh},
     PDTA_BITMAP,       {bm},
     PDTA_MODEID,       {mid},
     PDTA_CREGS,        {cregs},
     PDTA_NUMCOLORS,    {ncol},
     TAG_DONE,          NIL])
  StringF(line, '  layout: \d  attrs: \d\n', res, n)
  out(line)
  IF bmh
    StringF(line, '  bmh: \dx\d depth \d\n', bmh.width, bmh.height,
            bmh.depth)
    out(line)
  ELSE
    out('  bmh: NIL\n')
  ENDIF
  StringF(line, '  modeid: $\h  colours: \d  cregs: \s\n', mid, ncol,
          IF cregs THEN 'yes' ELSE 'NIL')
  out(line)
  IF bm
    StringF(line, '  bitmap: yes, real depth \d\n', bm.depth)
    out(line)
    IF bmh
      IF bm.depth <= 8
        showpic(bm, bmh, mid, cregs, ncol)
      ELSE
        out('  display: skipped (deeper than 8 planes)\n')
      ENDIF
    ENDIF
  ELSE
    out('  bitmap: NIL - nothing to display\n')
  ENDIF
  DisposeDTObject(o)
ENDPROC

PROC probefile(path, name)
  DEF lock, dtn:PTR TO datatype, hdr:PTR TO datatypeheader, g
  StringF(line, '\nFILE \s\n', name)
  out(line)
  IF (lock := Lock(path, SHARED_LOCK)) = NIL
    out('  cannot lock\n')
    RETURN
  ENDIF
  dtn := ObtainDataTypeA(DTST_FILE, lock, NIL)
  IF dtn = NIL
    StringF(line, '  no datatype found (ioerr \d)\n', IoErr())
    out(line)
  ELSE
    hdr := dtn.header
    g := hdr.groupid
    StringF(line, '  datatype: \s (\s)  group: \c\c\c\c\n',
            hdr.name, hdr.basename,
            Shr(g, 24) AND 255, Shr(g, 16) AND 255,
            Shr(g, 8) AND 255, g AND 255)
    out(line)
    IF g = GID_PICTURE THEN probepic(path)
    ReleaseDataType(dtn)
  ENDIF
  UnLock(lock)
ENDPROC

PROC main()
  DEF lock=NIL, fib:PTR TO fileinfoblock, path[340]:STRING
  IF (fo := Open('Amiga:dtprobe.out', NEWFILE)) = NIL THEN RETURN
  IF (datatypesbase := OpenLibrary('datatypes.library', 39)) = NIL
    out('no datatypes.library v39+\n')
    Close(fo)
    RETURN
  ENDIF
  StringF(line, 'dtprobe round 1 - datatypes.library v\d.\d\n',
          datatypesbase.version, datatypesbase.revision)
  out(line)
  fib := AllocDosObject(DOS_FIB, NIL)
  lock := Lock('Amiga:DTTest', SHARED_LOCK)
  IF fib
    IF lock
      IF Examine(lock, fib)
        WHILE ExNext(lock, fib)
          IF fib.direntrytype < 0    -> a file
            StringF(path, 'Amiga:DTTest/\s', fib.filename)
            probefile(path, fib.filename)
          ENDIF
        ENDWHILE
      ENDIF
    ELSE
      out('cannot lock Amiga:DTTest\n')
    ENDIF
  ENDIF
  IF lock THEN UnLock(lock)
  IF fib THEN FreeDosObject(DOS_FIB, fib)
  CloseLibrary(datatypesbase)
  out('\ndtprobe done\n')
  Close(fo)
  WriteF('dtprobe done - output in Amiga:dtprobe.out\n')
ENDPROC
