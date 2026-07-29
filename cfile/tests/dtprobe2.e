-> dtprobe2 - datatypes probe round 2 (30.7.26): ONLY the corner
-> round 1 exposed. The 1440x1440 JPEG decoded its header but gave
-> bitmap NIL on the native road (layout returned 1, not 2). Round 2
-> asks why, and proves the two roads a viewer needs for it:
->   [1] native road, instrumented: error attrs, classbitmap,
->       chip/fast memory before and after
->   [2] the REMAP road: decode remapped+dithered onto OUR screen
->       (PDTA_REMAP TRUE + PDTA_SCREEN), then center-crop blit -
->       the recipe for images bigger than any displayable mode
->   [3] the crop policy itself, proven on a known-good image: the
->       640x480 PNG shown center-cropped on a deliberately small
->       320x256 screen
-> Output: Amiga:dtprobe2.out    Run:  Amiga:dtprobe2

MODULE 'datatypes', 'datatypes/datatypes', 'datatypes/datatypesclass',
       'datatypes/pictureclass', 'intuition/screens', 'graphics/gfx',
       'graphics/rastport', 'exec/libraries', 'exec/memory',
       'dos/dos', 'utility/tagitem'

DEF datatypesbase=NIL:PTR TO lib, fo=NIL, line[340]:STRING, jpegf

PROC out(s)
  Write(fo, s, StrLen(s))
ENDPROC

PROC mems(label)
  StringF(line, '  mem \s: chip \d KB, fast \d KB\n', label,
          Shr(AvailMem(MEMF_CHIP), 10), Shr(AvailMem(MEMF_FAST), 10))
  out(line)
ENDPROC

-> blit the CENTER of a (possibly bigger) bitmap onto a screen
PROC cropblit(bm:PTR TO bitmap, iw, ih, scr:PTR TO screen, sw, sh)
  DEF w, h, sx, sy
  w := iw
  IF w > sw THEN w := sw
  h := ih
  IF h > sh THEN h := sh
  sx := Shr(iw - w, 1)    -> source offset: the image's center
  sy := Shr(ih - h, 1)
  BltBitMap(bm, sx, sy, scr.rastport.bitmap,
            Shr(sw - w, 1), Shr(sh - h, 1), w, h, $C0, $FF, NIL)
ENDPROC

-> [1] the native road again, instrumented
PROC natjpeg()
  DEF o=NIL, res, bmh=NIL:PTR TO bitmapheader, bm=NIL, cbm=NIL,
      errl=0, errn=0
  out('\n[1] JPEG, native road, instrumented\n')
  mems('before')
  o := NewDTObjectA(jpegf,
    [DTA_SOURCETYPE, DTST_FILE,
     DTA_GROUPID,    GID_PICTURE,
     PDTA_REMAP,     FALSE,
     TAG_DONE,       NIL])
  IF o = NIL
    StringF(line, '  NewDTObject FAILED (ioerr \d)\n', IoErr())
    out(line)
    RETURN
  ENDIF
  res := DoDTMethodA(o, NIL, NIL, [DTM_PROCLAYOUT, NIL, 1])
  GetDTAttrsA(o,
    [PDTA_BITMAPHEADER, {bmh},
     PDTA_BITMAP,       {bm},
     PDTA_CLASSBITMAP,  {cbm},
     DTA_ERRORLEVEL,    {errl},
     DTA_ERRORNUMBER,   {errn},
     TAG_DONE,          NIL])
  StringF(line, '  layout: \d  errorlevel: \d  errornumber: \d\n',
          res, errl, errn)
  out(line)
  StringF(line, '  bitmap: \s  classbitmap: \s\n',
          IF bm THEN 'yes' ELSE 'NIL', IF cbm THEN 'yes' ELSE 'NIL')
  out(line)
  mems('after decode')
  DisposeDTObject(o)
  mems('after dispose')
ENDPROC

-> [2] the REMAP road: our screen first, the datatype remaps into it
PROC remapjpeg()
  DEF o=NIL, res, bmh=NIL:PTR TO bitmapheader, bm=NIL:PTR TO bitmap,
      dbm=NIL:PTR TO bitmap, errl=0, errn=0,
      scr=NIL:PTR TO screen, use:PTR TO bitmap
  out('\n[2] JPEG, remap road (PDTA_REMAP TRUE onto our screen)\n')
  mems('before')
  scr := OpenScreenTagList(NIL,
    [SA_WIDTH,     640,
     SA_HEIGHT,    512,
     SA_DEPTH,     8,
     SA_DISPLAYID, $29000,    -> hires-laced, 256 colours (AGA)
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     TAG_DONE,     NIL])
  IF scr = NIL
    out('  could not open the 640x512x8 screen\n')
    RETURN
  ENDIF
  o := NewDTObjectA(jpegf,
    [DTA_SOURCETYPE,      DTST_FILE,
     DTA_GROUPID,         GID_PICTURE,
     PDTA_REMAP,          TRUE,
     PDTA_SCREEN,         scr,
     PDTA_DITHERQUALITY,  2,
     TAG_DONE,            NIL])
  IF o = NIL
    StringF(line, '  NewDTObject FAILED (ioerr \d)\n', IoErr())
    out(line)
    CloseScreen(scr)
    RETURN
  ENDIF
  res := DoDTMethodA(o, NIL, NIL, [DTM_PROCLAYOUT, NIL, 1])
  GetDTAttrsA(o,
    [PDTA_BITMAPHEADER, {bmh},
     PDTA_BITMAP,       {bm},
     PDTA_DESTBITMAP,   {dbm},
     DTA_ERRORLEVEL,    {errl},
     DTA_ERRORNUMBER,   {errn},
     TAG_DONE,          NIL])
  StringF(line, '  layout: \d  errorlevel: \d  errornumber: \d\n',
          res, errl, errn)
  out(line)
  StringF(line, '  bitmap: \s  destbitmap: \s\n',
          IF bm THEN 'yes' ELSE 'NIL', IF dbm THEN 'yes' ELSE 'NIL')
  out(line)
  mems('after decode')
  use := IF dbm THEN dbm ELSE bm
  IF use
    IF bmh
      cropblit(use, bmh.width, bmh.height, scr, 640, 512)
      Delay(250)
      out('  display: shown (center crop)\n')
    ENDIF
  ELSE
    out('  display: nothing to show\n')
  ENDIF
  DisposeDTObject(o)
  CloseScreen(scr)
  mems('after cleanup')
ENDPROC

-> [3] crop policy on a known-good image: PNG on a small screen
PROC croppng()
  DEF o=NIL, res, bmh=NIL:PTR TO bitmapheader, bm=NIL:PTR TO bitmap,
      mid=0, cregs=NIL:PTR TO LONG, ncol=0, scr=NIL:PTR TO screen,
      tab=NIL:PTR TO LONG, k
  out('\n[3] PNG 640x480 center-cropped on a 320x256 screen\n')
  o := NewDTObjectA('Amiga:DTTest/background_640_480.png',
    [DTA_SOURCETYPE, DTST_FILE,
     DTA_GROUPID,    GID_PICTURE,
     PDTA_REMAP,     FALSE,
     TAG_DONE,       NIL])
  IF o = NIL
    out('  NewDTObject FAILED\n')
    RETURN
  ENDIF
  res := DoDTMethodA(o, NIL, NIL, [DTM_PROCLAYOUT, NIL, 1])
  GetDTAttrsA(o,
    [PDTA_BITMAPHEADER, {bmh},
     PDTA_BITMAP,       {bm},
     PDTA_MODEID,       {mid},
     PDTA_CREGS,        {cregs},
     PDTA_NUMCOLORS,    {ncol},
     TAG_DONE,          NIL])
  IF bm
    scr := OpenScreenTagList(NIL,
      [SA_WIDTH, 320, SA_HEIGHT, 256, SA_DEPTH, 8,
       SA_DISPLAYID, $21000,    -> lores AGA, 256 colours
       SA_QUIET, TRUE, SA_SHOWTITLE, FALSE, TAG_DONE, NIL])
    IF scr
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
      cropblit(bm, bmh.width, bmh.height, scr, 320, 256)
      Delay(250)
      CloseScreen(scr)
      out('  display: shown (center crop)\n')
    ELSE
      out('  could not open the 320x256 screen\n')
    ENDIF
  ELSE
    out('  no bitmap\n')
  ENDIF
  DisposeDTObject(o)
ENDPROC

PROC main()
  IF (fo := Open('Amiga:dtprobe2.out', NEWFILE)) = NIL THEN RETURN
  IF (datatypesbase := OpenLibrary('datatypes.library', 39)) = NIL
    out('no datatypes.library\n')
    Close(fo)
    RETURN
  ENDIF
  StringF(line, 'dtprobe round 2 - datatypes.library v\d.\d\n',
          datatypesbase.version, datatypesbase.revision)
  out(line)
  jpegf := 'Amiga:DTTest/me.jpg'
  natjpeg()
  remapjpeg()
  croppng()
  CloseLibrary(datatypesbase)
  out('\ndtprobe2 done\n')
  Close(fo)
  WriteF('dtprobe2 done - output in Amiga:dtprobe2.out\n')
ENDPROC
