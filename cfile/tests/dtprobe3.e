-> dtprobe3 - datatypes probe round 3 (30.7.26): the JPEG renders,
-> but WarpJPEG exposes NO bitmap to extraction (round 2: 5.6MB of
-> decode traffic, clean error attrs, every bitmap attr NIL). Three
-> roads that might make a truecolour class actually SHOW something:
->   [1] extraction with PDTA_DESTMODE=PMODE_V44 (V44 negotiation)
->   [2] extraction remapped onto a HAM8 screen (Warp's famous mode)
->   [3] THE MULTIVIEW WAY: embed the object in a window with
->       AddDTObject/RefreshDTObject and let the class render
->       itself (async, in its own layout process) - first on the
->       known-good PNG as a control, then on the JPEG
-> Each visual step holds ~8 seconds. Output: Amiga:dtprobe3.out

MODULE 'datatypes', 'datatypes/datatypes', 'datatypes/datatypesclass',
       'datatypes/pictureclass', 'intuition/intuition',
       'intuition/screens', 'intuition/gadgetclass', 'graphics/gfx',
       'graphics/rastport', 'exec/libraries', 'exec/memory',
       'dos/dos', 'utility/tagitem'

DEF datatypesbase=NIL:PTR TO lib, fo=NIL, line[340]:STRING, jpegf, pngf

PROC out(s)
  Write(fo, s, StrLen(s))
ENDPROC

-> [1]+[2]: one extraction attempt, parameterised
PROC extract(label, mid, destmode)
  DEF o=NIL, res, bmh=NIL:PTR TO bitmapheader, bm=NIL, dbm=NIL,
      scr=NIL:PTR TO screen, t[16]:ARRAY OF LONG, n
  StringF(line, '\n[\s]\n', label)
  out(line)
  scr := OpenScreenTagList(NIL,
    [SA_WIDTH, 640, SA_HEIGHT, 512, SA_DEPTH, 8,
     SA_DISPLAYID, mid, SA_QUIET, TRUE, SA_SHOWTITLE, FALSE,
     TAG_DONE, NIL])
  IF scr = NIL
    StringF(line, '  screen $\h would not open\n', mid)
    out(line)
    RETURN
  ENDIF
  -> build the taglist by hand so DESTMODE can be optional
  n := 0
  t[n] := DTA_SOURCETYPE ; t[n+1] := DTST_FILE   ; n := n + 2
  t[n] := DTA_GROUPID    ; t[n+1] := GID_PICTURE ; n := n + 2
  t[n] := PDTA_REMAP     ; t[n+1] := TRUE        ; n := n + 2
  t[n] := PDTA_SCREEN    ; t[n+1] := scr         ; n := n + 2
  IF destmode >= 0
    t[n] := PDTA_DESTMODE ; t[n+1] := destmode   ; n := n + 2
  ENDIF
  t[n] := TAG_DONE ; t[n+1] := NIL
  o := NewDTObjectA(jpegf, t)
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
     TAG_DONE,          NIL])
  StringF(line, '  layout: \d  bitmap: \s  destbitmap: \s\n', res,
          IF bm THEN 'yes' ELSE 'NIL', IF dbm THEN 'yes' ELSE 'NIL')
  out(line)
  IF dbm = NIL THEN dbm := bm
  IF dbm
    IF bmh
      BltBitMap(dbm, 0, 0, scr.rastport.bitmap, 0, 0,
                IF bmh.width > 640 THEN 640 ELSE bmh.width,
                IF bmh.height > 512 THEN 512 ELSE bmh.height,
                $C0, $FF, NIL)
      Delay(400)
      out('  display: shown\n')
    ENDIF
  ENDIF
  DisposeDTObject(o)
  CloseScreen(scr)
ENDPROC

-> [3]: the MultiView way - the object is a gadget in our window and
-> renders ITSELF (the class runs its own async layout). We give it
-> ~8 seconds on screen; the verdict is his eyes + the attrs after.
PROC windowroad(label, file)
  DEF o=NIL, scr=NIL:PTR TO screen, win=NIL:PTR TO window,
      totv=0, toth=0, res
  StringF(line, '\n[\s]\n', label)
  out(line)
  scr := OpenScreenTagList(NIL,
    [SA_WIDTH, 640, SA_HEIGHT, 512, SA_DEPTH, 8,
     SA_DISPLAYID, $29000, SA_QUIET, TRUE, SA_SHOWTITLE, FALSE,
     TAG_DONE, NIL])
  IF scr = NIL
    out('  screen would not open\n')
    RETURN
  ENDIF
  win := OpenWindowTagList(NIL,
    [WA_CUSTOMSCREEN, scr,
     WA_LEFT, 0, WA_TOP, 0, WA_WIDTH, 640, WA_HEIGHT, 512,
     WA_BORDERLESS, TRUE, WA_BACKDROP, TRUE, WA_ACTIVATE, TRUE,
     WA_RMBTRAP, TRUE,
     TAG_DONE, NIL])
  IF win = NIL
    out('  window would not open\n')
    CloseScreen(scr)
    RETURN
  ENDIF
  o := NewDTObjectA(file,
    [DTA_SOURCETYPE, DTST_FILE,
     DTA_GROUPID,    GID_PICTURE,
     GA_LEFT,        0,
     GA_TOP,         0,
     GA_WIDTH,       640,
     GA_HEIGHT,      512,
     PDTA_REMAP,     TRUE,
     PDTA_SCREEN,    scr,
     TAG_DONE,       NIL])
  IF o = NIL
    StringF(line, '  NewDTObject FAILED (ioerr \d)\n', IoErr())
    out(line)
    CloseWindow(win)
    CloseScreen(scr)
    RETURN
  ENDIF
  res := AddDTObject(win, NIL, o, -1)
  StringF(line, '  AddDTObject: \d\n', res)
  out(line)
  RefreshDTObjectA(o, win, NIL, [TAG_DONE, NIL])
  Delay(400)    -> the class lays out + renders asynchronously
  GetDTAttrsA(o,
    [DTA_TOTALVERT,  {totv},
     DTA_TOTALHORIZ, {toth},
     TAG_DONE,       NIL])
  StringF(line, '  after 8s: totalhoriz \d, totalvert \d\n', toth, totv)
  out(line)
  RemoveDTObject(win, o)
  DisposeDTObject(o)
  CloseWindow(win)
  CloseScreen(scr)
ENDPROC

PROC main()
  IF (fo := Open('Amiga:dtprobe3.out', NEWFILE)) = NIL THEN RETURN
  IF (datatypesbase := OpenLibrary('datatypes.library', 39)) = NIL
    out('no datatypes.library\n')
    Close(fo)
    RETURN
  ENDIF
  jpegf := 'Amiga:DTTest/me.jpg'
  pngf := 'Amiga:DTTest/background_640_480.png'
  out('dtprobe round 3\n')
  extract('1: jpeg, DESTMODE=PMODE_V44, 640x512x8', $29000, PMODE_V44)
  extract('2: jpeg, HAM8 hires-laced screen', $29800, -1)
  windowroad('3a: PNG control, window road', pngf)
  windowroad('3b: JPEG, window road', jpegf)
  CloseLibrary(datatypesbase)
  out('\ndtprobe3 done\n')
  Close(fo)
  WriteF('dtprobe3 done - output in Amiga:dtprobe3.out\n')
ENDPROC
