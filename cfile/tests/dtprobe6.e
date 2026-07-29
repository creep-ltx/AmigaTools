-> dtprobe6 - datatypes probe round 6 (30.7.26): THE ANSWER WAS IN
-> THE GUIDE. WarpJPEG's default OUTPUT_MODE=FULL emits 24-bit
-> truecolour - there IS no palette bitmap for extraction to fetch
-> (that is why the 224-colour PNG/WebP worked and the photo never
-> did). Since Warp 45.9 a LOCAL env variable overrides the global
-> prefs, and our extraction road decodes via DTM_PROCLAYOUT in OUR
-> process - so a local var set here reaches the class and nobody
-> else. This round proves it on the proven round-1 road:
->   [1] me.jpg with local OUTPUT_MODE=REDUCED  -> expect a bitmap,
->       shown center-cropped on 640x512
->   [2] me.jpg with REDUCED + SCALING=SMALLER WIDTH=640 HEIGHT=512
->       -> Warp shrinks ON DECODE: expect the WHOLE photo to fit
-> Output: Amiga:dtprobe6.out

MODULE 'datatypes', 'datatypes/datatypes', 'datatypes/datatypesclass',
       'datatypes/pictureclass', 'intuition/screens', 'graphics/gfx',
       'graphics/rastport', 'exec/libraries',
       'dos/dos', 'dos/var', 'utility/tagitem'

DEF datatypesbase=NIL:PTR TO lib, fo=NIL, line[340]:STRING, jpegf

PROC out(s)
  Write(fo, s, StrLen(s))
ENDPROC

PROC jpegrun(label, prefs)
  DEF o=NIL, res, bmh=NIL:PTR TO bitmapheader, bm=NIL:PTR TO bitmap,
      mid=0, cregs=NIL:PTR TO LONG, ncol=0,
      scr=NIL:PTR TO screen, tab=NIL:PTR TO LONG, k, w, h, sx, sy
  StringF(line, '\n[\s]\n  local prefs: \s\n', label, prefs)
  out(line)
  -> the local override: visible to OUR process only, and only until
  -> the DeleteVar below
  SetVar('Datatypes/WarpJPEG.prefs', prefs, StrLen(prefs),
         GVF_LOCAL_ONLY)
  o := NewDTObjectA(jpegf,
    [DTA_SOURCETYPE, DTST_FILE,
     DTA_GROUPID,    GID_PICTURE,
     PDTA_REMAP,     FALSE,
     TAG_DONE,       NIL])
  IF o = NIL
    StringF(line, '  NewDTObject FAILED (ioerr \d)\n', IoErr())
    out(line)
    DeleteVar('Datatypes/WarpJPEG.prefs', GVF_LOCAL_ONLY)
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
  IF bmh
    StringF(line, '  layout: \d  bmh: \dx\d depth \d  colours: \d\n',
            res, bmh.width, bmh.height, bmh.depth, ncol)
  ELSE
    StringF(line, '  layout: \d  bmh: NIL  colours: \d\n', res, ncol)
  ENDIF
  out(line)
  IF bm
    StringF(line, '  bitmap: yes, real depth \d\n', bm.depth)
    out(line)
  ELSE
    out('  bitmap: NIL\n')
  ENDIF
  IF bm
    IF bmh
      IF bm.depth <= 8
        scr := OpenScreenTagList(NIL,
          [SA_WIDTH, 640, SA_HEIGHT, 512, SA_DEPTH, 8,
           SA_DISPLAYID, $29000, SA_QUIET, TRUE, SA_SHOWTITLE, FALSE,
           TAG_DONE, NIL])
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
          w := bmh.width
          IF w > 640 THEN w := 640
          h := bmh.height
          IF h > 512 THEN h := 512
          sx := Shr(bmh.width - w, 1)
          sy := Shr(bmh.height - h, 1)
          BltBitMap(bm, sx, sy, scr.rastport.bitmap,
                    Shr(640 - w, 1), Shr(512 - h, 1), w, h,
                    $C0, $FF, NIL)
          Delay(400)
          CloseScreen(scr)
          out('  display: shown\n')
        ELSE
          out('  display: screen would not open\n')
        ENDIF
      ELSE
        out('  display: skipped (deeper than 8)\n')
      ENDIF
    ENDIF
  ENDIF
  DisposeDTObject(o)
  DeleteVar('Datatypes/WarpJPEG.prefs', GVF_LOCAL_ONLY)
ENDPROC

PROC main()
  IF (fo := Open('Amiga:dtprobe6.out', NEWFILE)) = NIL THEN RETURN
  IF (datatypesbase := OpenLibrary('datatypes.library', 39)) = NIL
    out('no datatypes.library\n')
    Close(fo)
    RETURN
  ENDIF
  jpegf := 'Amiga:DTTest/me.jpg'
  out('dtprobe round 6 - the OUTPUT_MODE answer from the guide\n')
  jpegrun('1: REDUCED, full size, center crop',
          'OUTPUT_MODE=REDUCED DITHER=FS')
  jpegrun('2: REDUCED + decode-time scaling to the screen',
          'OUTPUT_MODE=REDUCED DITHER=FS SCALING=SMALLER WIDTH=640 HEIGHT=512')
  CloseLibrary(datatypesbase)
  out('\ndtprobe6 done\n')
  Close(fo)
  WriteF('dtprobe6 done - output in Amiga:dtprobe6.out\n')
ENDPROC
