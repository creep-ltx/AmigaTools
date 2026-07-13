MODULE 'Dos','dos/dos','Asl','libraries/Asl','exec/io','exec/ports','amigalib/ports','amigalib/io','exec/types','exec/memory','devices/keyboard'

CONST MATRIX_SIZE=16

CONST CTRL_BIT=8, LAMIGA_BIT=64, RAMIGA_BIT=128

CONST MODE_ALL=0, MODE_MOUSE=1, MODE_AMIGA=2

PROC getmode()
  DEF options:PTR TO LONG, rdargs, mode=MODE_ALL
  options:=[0]
  IF rdargs:=ReadArgs('MODE',options,NIL)
    IF options[0]
      IF StrCmp(options[0],'mouse',ALL) THEN mode:=MODE_MOUSE
      IF StrCmp(options[0],'amiga',ALL) THEN mode:=MODE_AMIGA
    ENDIF
    FreeArgs(rdargs)
  ENDIF
ENDPROC mode

PROC readkeyflags()
  DEF keyIO: PTR TO iostd
  DEF keyMP: PTR TO mp
  DEF keyMatrix:PTR TO CHAR
  DEF flags=0

  IF (keyMP:=createPort(0,0))
    IF (keyIO:=createExtIO(keyMP,SIZEOF iostd))
      IF (OpenDevice('keyboard.device',0,keyIO,0)=FALSE)
        IF (keyMatrix:=AllocMem(MATRIX_SIZE,MEMF_PUBLIC OR MEMF_CLEAR))
          keyIO.command:=KBD_READMATRIX
          keyIO.data:=keyMatrix
          keyIO.length:=IF KickVersion(36) THEN MATRIX_SIZE ELSE 13
          DoIO(keyIO)

          flags:=keyMatrix[12] AND (CTRL_BIT OR LAMIGA_BIT OR RAMIGA_BIT)
          FreeMem(keyMatrix,MATRIX_SIZE)
        ENDIF
        CloseDevice(keyIO)
      ENDIF
      deleteExtIO(keyIO)
    ENDIF
    deletePort(keyMP)
  ENDIF
ENDPROC flags

PROC selectboot(file, mode, lamiga, ramiga)
  DEF m, matched=FALSE

  IF mode<>MODE_AMIGA
    m:=Mouse()
    SELECT m
      CASE 1
        StrCopy(file,'S:CBoot/LMB')
        matched:=TRUE
      CASE 2
        StrCopy(file,'S:CBoot/RMB')
        matched:=TRUE
    ENDSELECT
  ENDIF

  IF (matched=FALSE) AND (mode<>MODE_MOUSE)
    IF lamiga
      StrCopy(file,'S:CBoot/LAmiga')
      matched:=TRUE
    ELSEIF ramiga
      StrCopy(file,'S:CBoot/RAmiga')
      matched:=TRUE
    ENDIF
  ENDIF

  IF matched=FALSE THEN StrCopy(file,'S:CBoot/Default')
ENDPROC

PROC configmenu(file)
  DEF ask, executeStr[255]:STRING
  ask:=request('CBoot control.\n\nEdit, replace or test \s?','Edit|Replace|Test',[file])
  SELECT ask
    CASE 1
      StringF(executeStr,'ed "\s"',file)
      Execute(executeStr,0,0)
    CASE 2
      install(file,TRUE)
    CASE 0
      install(file,FALSE)
  ENDSELECT
ENDPROC

PROC selectfile(file)
  DEF ask
  IF FileLength('S:CBoot/Default') > 0
    ask:=request('No script for \s.\nBoot normally or select one?','Normal|Select',[file])
  ELSE
    ask:=request('No script for \s.\nSelect one:','Select',[file])
  ENDIF
  IF ask = 1
    StrCopy(file,'S:CBoot/Default')
  ELSE
    install(file,TRUE)
  ENDIF
ENDPROC

PROC pickfile(result)
  DEF req:PTR TO filerequester, ok=FALSE
  IF aslbase:=OpenLibrary('asl.library',37)
    IF req:=AllocFileRequest()
      IF RequestFile(req)
        StringF(result,'\s/\s', req.drawer, req.file)
        ok:=TRUE
      ENDIF
      FreeFileRequest(req)
    ENDIF
    CloseLibrary(aslbase)
  ENDIF
ENDPROC ok

PROC install(file, doinstall)
  DEF picked[255]:STRING, executeStr[255]:STRING
  IF pickfile(picked)
    IF doinstall
      StringF(executeStr,'copy "\s" "\s"', picked, file)
      Execute(executeStr,0,0)
    ELSE
      StrCopy(file,picked)
    ENDIF
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
  StringF(flags,'protect "\s" +srwed',file)
  Execute(flags,0,0)
ENDPROC

PROC main()
  DEF file[255]:STRING, ctrl, lamiga, ramiga, keyflags, mode, execStr[255]:STRING

  '$VER:CBoot 1.4 tobias.karlsson@piratkopia.se'

  mode:=getmode()
  keyflags:=readkeyflags()
  ctrl:=IF (keyflags AND CTRL_BIT) THEN TRUE ELSE FALSE
  lamiga:=IF (keyflags AND LAMIGA_BIT) THEN TRUE ELSE FALSE
  ramiga:=IF (keyflags AND RAMIGA_BIT) THEN TRUE ELSE FALSE

  selectboot(file,mode,lamiga,ramiga)
  setupenv()

  IF ctrl=TRUE THEN configmenu(file)

  WHILE FileLength(file) < 0
    selectfile(file)
  ENDWHILE

    envremove()
    setflags(file)
    StringF(execStr,'"\s"',file)
    Execute(execStr,0,0)
ENDPROC
