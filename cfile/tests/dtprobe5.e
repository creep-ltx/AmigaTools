-> dtprobe5 - datatypes probe round 5 (30.7.26): round 4 heard ZERO
-> updates - class notifications only reach a window's IDCMP when
-> the object is created with ICA_TARGET=ICTARGET_IDCMP (the tag
-> MultiView passes; round 4 lacked it). This round adds it, AND a
-> fallback: every ~2s, if the object reports totals but nothing
-> painted yet, refresh anyway - so we learn which mechanism to
-> trust (updates, polling, or both). Output: Amiga:dtprobe5.out

MODULE 'datatypes', 'datatypes/datatypes', 'datatypes/datatypesclass',
       'datatypes/pictureclass', 'intuition/intuition',
       'intuition/screens', 'intuition/gadgetclass', 'intuition/icclass',
       'graphics/gfx',
       'graphics/rastport', 'exec/libraries', 'exec/ports',
       'dos/dos', 'utility/tagitem'

DEF datatypesbase=NIL:PTR TO lib, fo=NIL, line[340]:STRING

PROC out(s)
  Write(fo, s, StrLen(s))
ENDPROC

PROC windowroad(label, file)
  DEF o=NIL, scr=NIL:PTR TO screen, win=NIL:PTR TO window,
      totv=0, toth=0, msg:PTR TO intuimessage, cls,
      nupd=0, npoll=0, ticks=0, shown=FALSE
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
     WA_IDCMP, IDCMP_IDCMPUPDATE OR IDCMP_INTUITICKS,
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
     ICA_TARGET,     ICTARGET_IDCMP,
     TAG_DONE,       NIL])
  IF o = NIL
    StringF(line, '  NewDTObject FAILED (ioerr \d)\n', IoErr())
    out(line)
    CloseWindow(win)
    CloseScreen(scr)
    RETURN
  ENDIF
  AddDTObject(win, NIL, o, -1)
  -> the listen loop: INTUITICKS pace time (10/s). An IDCMPUPDATE =
  -> the class has news: refresh so it draws itself. FALLBACK: every
  -> ~2s, if the object already reports its size but nothing painted
  -> yet, refresh anyway (poll road). Stop ~8s after first paint, or
  -> after ~40s of nothing.
  WHILE (IF shown THEN ticks < 80 ELSE ticks < 400)
    WaitPort(win.userport)
    WHILE (msg := GetMsg(win.userport))
      cls := msg.class
      ReplyMsg(msg)
      IF cls = IDCMP_IDCMPUPDATE
        nupd++
        RefreshDTObjectA(o, win, NIL, [TAG_DONE, NIL])
        shown := TRUE
        ticks := 0
      ELSEIF cls = IDCMP_INTUITICKS
        ticks++
        IF shown = FALSE
          IF Mod(ticks, 20) = 19    -> ~every 2s: the poll road
            totv := 0
            GetDTAttrsA(o, [DTA_TOTALVERT, {totv}, TAG_DONE, NIL])
            IF totv > 0
              npoll++
              RefreshDTObjectA(o, win, NIL, [TAG_DONE, NIL])
              shown := TRUE
              ticks := 0
            ENDIF
          ENDIF
        ENDIF
      ENDIF
    ENDWHILE
  ENDWHILE
  GetDTAttrsA(o,
    [DTA_TOTALVERT,  {totv},
     DTA_TOTALHORIZ, {toth},
     TAG_DONE,       NIL])
  StringF(line, '  updates: \d  poll-refreshes: \d  totalhoriz \d totalvert \d\n',
          nupd, npoll, toth, totv)
  out(line)
  RemoveDTObject(win, o)
  DisposeDTObject(o)
  CloseWindow(win)
  CloseScreen(scr)
ENDPROC

PROC main()
  IF (fo := Open('Amiga:dtprobe5.out', NEWFILE)) = NIL THEN RETURN
  IF (datatypesbase := OpenLibrary('datatypes.library', 39)) = NIL
    out('no datatypes.library\n')
    Close(fo)
    RETURN
  ENDIF
  out('dtprobe round 5 - ICA_TARGET + the poll fallback\n')
  windowroad('1: PNG control', 'Amiga:DTTest/background_640_480.png')
  windowroad('2: JPEG', 'Amiga:DTTest/me.jpg')
  windowroad('3: WebP', 'Amiga:DTTest/CBoot.webp')
  CloseLibrary(datatypesbase)
  out('\ndtprobe5 done\n')
  Close(fo)
  WriteF('dtprobe5 done - output in Amiga:dtprobe5.out\n')
ENDPROC
