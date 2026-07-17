-> contest - proof test for the CTerm embedded-console architecture
->
-> Opens a screen, paints stand-in header/footer bands, opens a
-> BORDERLESS window covering the band between them, and hands that
-> window to the standard console handler with CON:'s WINDOW option
-> (verified in the AmigaDOS docs: "Use window pointed to by addr").
-> Then Execute('', console, NIL) starts a real, interactive
-> UserShell reading from that console - the classic "shell in my
-> window" pattern.
->
-> What to try inside it:
->   - prompt editing and shell history (the 3.2 console's own)
->   - an interactive command: Delete something ASK, or Ask
->   - type/more/ed - raw mode fullscreen programs
->   - a Swedish keymap, if set: the console does the keymap work
-> EndShell (or EndCLI) exits and contest cleans up the screen.
->
-> Build: ecompile contest.e   (E-VO)

MODULE 'intuition/intuition','intuition/screens',
       'utility/tagitem','graphics/rastport','dos/dos'

DEF scr=NIL:PTR TO screen,
    artwin=NIL:PTR TO window,
    conwin=NIL:PTR TO window,
    rc=0

PROC main() HANDLE
  DEF rp:PTR TO rastport, fh, bandh, spec[100]:STRING
  scr := OpenScreenTagList(NIL,
    [SA_LIKEWORKBENCH, TRUE,
     SA_DEPTH,     3,
     SA_QUIET,     TRUE,
     SA_SHOWTITLE, FALSE,
     SA_TITLE,     'CTerm console test',
     SA_PUBNAME,   'CSHTEST',
     TAG_DONE,     NIL])
  IF scr = NIL THEN Throw("UI", 'screen')
  -> the art layer: a backdrop window over the whole screen with
  -> stand-in bands where the mockup art will live
  artwin := OpenWindowTagList(NIL,
    [WA_LEFT,     0,
     WA_TOP,      0,
     WA_WIDTH,    scr.width,
     WA_HEIGHT,   scr.height,
     WA_CUSTOMSCREEN, scr,
     WA_BACKDROP,   TRUE,
     WA_BORDERLESS, TRUE,
     WA_RMBTRAP,    TRUE,
     TAG_DONE,    NIL])
  IF artwin = NIL THEN Throw("UI", 'art window')
  bandh := 48    -> six 8px rows of header, two of footer
  rp := artwin.rport
  SetAPen(rp, 3)
  RectFill(rp, 0, 0, scr.width - 1, bandh - 1)
  RectFill(rp, 0, scr.height - 16, scr.width - 1, scr.height - 1)
  -> the console layer: a borderless window covering exactly the
  -> space between the bands - this is the window the handler gets
  conwin := OpenWindowTagList(NIL,
    [WA_LEFT,     0,
     WA_TOP,      bandh,
     WA_WIDTH,    scr.width,
     WA_HEIGHT,   scr.height - bandh - 16,
     WA_CUSTOMSCREEN, scr,
     WA_BORDERLESS, TRUE,
     WA_ACTIVATE,   TRUE,
     TAG_DONE,    NIL])
  IF conwin = NIL THEN Throw("UI", 'console window')
  -> the whole experiment is this one line:
  StringF(spec, 'CON:0/0/0/0/CTerm/WINDOW0x\h', conwin)
  IF fh := Open(spec, NEWFILE)
    -> a real interactive shell in that console; returns at EndShell
    Execute('', fh, NIL)
    Close(fh)
  ELSE
    rc := 10
  ENDIF
  closeall()
  IF rc = 10 THEN WriteF('contest: the console did not open - the WINDOW option failed\n')
EXCEPT DO
  closeall()
  IF exception = "UI"
    WriteF('contest: cannot open UI (\s)\n', exceptioninfo)
    rc := 20
  ENDIF
  CleanUp(rc)
ENDPROC

PROC closeall()
  IF conwin
    CloseWindow(conwin)
    conwin := NIL
  ENDIF
  IF artwin
    CloseWindow(artwin)
    artwin := NIL
  ENDIF
  IF scr
    CloseScreen(scr)
    scr := NIL
  ENDIF
ENDPROC

version: CHAR '$VER: contest 0.1 (16.7.26) CTerm architecture proof',0
