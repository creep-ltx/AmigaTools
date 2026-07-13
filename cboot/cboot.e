MODULE 'Dos','dos/dos','Asl','libraries/Asl','exec/io','exec/ports','amigalib/ports','amigalib/io','exec/types','exec/memory','devices/keyboard'

CONST MATRIX_SIZE=16

PROC checkctrl()
  DEF keyIO: PTR TO iostd
  DEF keyMP: PTR TO mp
  DEF keyMatrix:PTR TO CHAR
  DEF ctrl=FALSE

  IF (keyMP:=createPort(0,0))
    IF (keyIO:=createExtIO(keyMP,SIZEOF iostd))
      IF (OpenDevice('keyboard.device',0,keyIO,0)=FALSE)
        IF (keyMatrix:=AllocMem(MATRIX_SIZE,MEMF_PUBLIC OR MEMF_CLEAR))
          keyIO.command:=KBD_READMATRIX
          keyIO.data:=keyMatrix
          keyIO.length:=IF KickVersion(36) THEN MATRIX_SIZE ELSE 13
          DoIO(keyIO)

          IF (keyMatrix[12] AND 8) THEN ctrl:=TRUE
          FreeMem(keyMatrix,MATRIX_SIZE)
        ELSE
          WriteF('Error: Could not allocate keymatrix memory\n')
        ENDIF
        CloseDevice(keyIO)
      ELSE
        WriteF('Error: Could not open keyboard.device\n')
      ENDIF
      deleteExtIO(keyIO)
    ELSE
      WriteF('Error: Could not create I/O request\n')
    ENDIF
    deletePort(keyMP)
  ELSE
    WriteF('Error: Could not create message port\n')
  ENDIF
ENDPROC ctrl

PROC checkmouse(file)
  DEF m
  m:=Mouse()
  SELECT m
    CASE 0
      StrCopy(file,'S:CBoot/Default')
    CASE 1
      StrCopy(file,'S:CBoot/LMB')
    CASE 2
      StrCopy(file,'S:CBoot/RMB')
  ENDSELECT
ENDPROC

PROC configmenu(file)
  DEF ask, executeStr[255]:STRING
  ask:=request('CBoot control.\n\nEdit or replace \s?\nOr test a new script without installing?','Edit|Replace|Test',[file])
  SELECT ask
    CASE 1
      StringF(executeStr,'ed \s',file)
      Execute(executeStr,0,0)
    CASE 2
      install(file)
    CASE 0
      test(file)
  ENDSELECT
ENDPROC

PROC selectfile(file)
  DEF ask
  IF FileLength('S:CBoot/Default') > 0
    ask:=request('Select the bootscript that you\nwant to install as: \s. \n\nOr use S:CBoot/Default to boot normally?','Boot normally|Select file',[file])
  ELSE
    ask:=request('Select the bootscript that you\nwant to install as: \s. ','Select file',[file])
  ENDIF
  IF ask = 1
    StrCopy(file,'S:CBoot/Default')
  ELSE
    install(file)
  ENDIF
ENDPROC

PROC install(file)
  DEF req:PTR TO filerequester, executeStr[255]:STRING
    IF aslbase:=OpenLibrary('asl.library',37)
      IF req:=AllocFileRequest()
        IF RequestFile(req)
          StringF(executeStr,'copy \s/\s \s', req.drawer, req.file, file)
          Execute(executeStr,0,0)
        ENDIF
        FreeFileRequest(req)
      ELSE
        WriteF('Could not open filerequester!\n')
      ENDIF
      CloseLibrary(aslbase)
    ELSE
      WriteF('Could not open asl.library!\n')
    ENDIF
ENDPROC

PROC test(file)
  DEF req:PTR TO filerequester
    IF aslbase:=OpenLibrary('asl.library',37)
      IF req:=AllocFileRequest()
        IF RequestFile(req)
          StringF(file,'\s/\s', req.drawer, req.file)
        ENDIF
        FreeFileRequest(req)
      ELSE
        WriteF('Could not open filerequester!\n')
      ENDIF
      CloseLibrary(aslbase)
    ELSE
      WriteF('Could not open asl.library!\n')
    ENDIF
ENDPROC

PROC request(body,gadgets,args) IS EasyRequestArgs(0,[20,0,0,body,gadgets],0,args)

PROC envremove()
  DEF lock
  IF lock:=Lock('Ram:ENV',-2)
    UnLock(lock)
    Execute('assign env: remove',0,0)
    Execute('run >nil: delete ram:env all',0,0)
  ENDIF
ENDPROC

PROC setupenv()
  DEF lock
  IF lock:=Lock('Ram:ENV',-2)
    UnLock(lock)
  ELSE
    Execute('makedir ram:env',0,0)
    Execute('assign env: ram:env',0,0)
  ENDIF
  IF lock:=Lock('S:CBoot',-2)
    UnLock(lock)
  ELSE
    Execute('makedir S:CBoot',0,0)
  ENDIF
ENDPROC

PROC setflags(file)
  DEF flags[255]:STRING
  StringF(flags,'protect \s +srwed',file)
  Execute(flags,0,0)
ENDPROC

PROC main()
  DEF file[255]:STRING, ctrl

  '$VER:CBoot version 1.3 (13.9.25) tobias.karlsson@piratkopia.se'

  ctrl:=checkctrl()
  checkmouse(file)
  setupenv()

  IF ctrl=TRUE THEN configmenu(file)

  WHILE FileLength(file) < 0
    selectfile(file)
  ENDWHILE

    envremove()
    setflags(file)
    Execute(file,0,0)
ENDPROC
