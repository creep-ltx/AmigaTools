/* amifetch.e -- neofetch-style Amiga system info dump
   Usage: amifetch [MEM unit] [CHIP unit] [FAST unit]  (unit = B, KB, MB)

   MEM sets the default unit for both Chip and Fast RAM; CHIP/FAST
   override it individually. With nothing given, both default to KB.

   e.g.  amifetch
         amifetch MEM=MB
         amifetch MEM=MB CHIP=B
         amifetch CHIP=B FAST=MB
         amifetch CHIP KB FAST B

   Reports CPU/FPU (from exec.library's cumulative AttnFlags bits),
   chip/fast RAM free vs. installed (AvailMem), video timing (from the
   vertical blank frequency), Kickstart/exec.library version, E-Clock
   frequency, and this process's stack size, inside a border box sized
   to fit whatever the longest line turns out to be.

   RAM sizes are converted with Shr(x,shift)/Shl(x,n) rather than
   x/divisor or x*factor: E-VO's `/` operator compiles straight to the
   68000's hardware DIVU/DIVS instruction (32-bit dividend, 16-bit
   divisor, 16-bit quotient) for speed, and if the quotient overflows
   that 16-bit result it silently returns garbage instead of a proper
   32-bit-safe division -- confirmed by Darren Coles (E-VO's author)
   after this was reported upstream. Fast RAM's raw byte count is big
   enough that its /1024 quotient overflows a signed 16-bit result;
   Chip RAM's never got that big, which is why it looked fine while
   Fast RAM didn't. E provides Div() for the general case, but it's
   markedly slower per Darren -- since every divisor here is a power
   of two, Shr()/Shl() are both correct AND the faster choice, not
   just a workaround. MB's one decimal place is derived from those
   plus the small-value-only Mod() builtin instead of plain `/` or `*`.

   Every line is built into a buffer with StringF() first (never
   printed straight to the screen), so the true width of the longest
   line is known before anything is drawn -- avoids the runtime
   \s[N] field-width format code entirely (untested in this compiler,
   and after the division bug, not something to trust blind) in favour
   of manually padding with StrAddChar(), which dupfind.e already
   proved safe.
*/

MODULE 'exec/execbase', 'exec/libraries', 'exec/memory', 'dos/dos', 'dos/dosextens', 'dos/rdargs'

PROC main() HANDLE
  DEF rdargs=NIL:PTR TO rdargs
  DEF argarray[3]:ARRAY OF LONG
  DEF eb:PTR TO execbase
  DEF lb:PTR TO lib
  DEF attn
  DEF cpu[8]:STRING, fpu[24]:STRING, video[16]:STRING
  DEF free, total
  DEF memShift, chipShift, fastShift
  DEF memUnit:PTR TO CHAR, chipUnit:PTR TO CHAR, fastUnit:PTR TO CHAR
  DEF lCpu[64]:STRING, lFpu[64]:STRING, lVideo[64]:STRING
  DEF lChip[64]:STRING, lFast[64]:STRING, lExec[64]:STRING
  DEF lClock[64]:STRING, lStack[64]:STRING
  DEF width, border[80]:STRING

  rdargs := ReadArgs('MEM/K,CHIP/K,FAST/K', argarray, NIL)
  IF rdargs=NIL THEN Throw("ARG",'Bad arguments - usage: amifetch [MEM unit] [CHIP unit] [FAST unit] (unit = B/KB/MB)')

  memShift, memUnit := parseunit(argarray[0], 10, 'KB')
  chipShift, chipUnit := parseunit(argarray[1], memShift, memUnit)
  fastShift, fastUnit := parseunit(argarray[2], memShift, memUnit)

  eb := execbase
  attn := eb.attnflags

  IF attn AND AFF_68060
    StrCopy(cpu,'68060',ALL)
  ELSEIF attn AND AFF_68040
    StrCopy(cpu,'68040',ALL)
  ELSEIF attn AND AFF_68030
    StrCopy(cpu,'68030',ALL)
  ELSEIF attn AND AFF_68020
    StrCopy(cpu,'68020',ALL)
  ELSEIF attn AND AFF_68010
    StrCopy(cpu,'68010',ALL)
  ELSE
    StrCopy(cpu,'68000',ALL)
  ENDIF
  StringF(lCpu,'CPU:        \s', cpu)

  IF attn AND AFF_68882
    StrCopy(fpu,'68882',ALL)
  ELSEIF attn AND AFF_68881
    StrCopy(fpu,'68881',ALL)
  ELSEIF attn AND AFF_FPU40
    StrCopy(fpu,'68040/68060 FPU',ALL)
  ELSE
    StrCopy(fpu,'none',ALL)
  ENDIF
  StringF(lFpu,'FPU:        \s', fpu)

  IF eb.vblankfrequency=60
    StrCopy(video,'NTSC (60Hz)',ALL)
  ELSE
    StrCopy(video,'PAL (50Hz)',ALL)
  ENDIF
  StringF(lVideo,'Video:      \s', video)

  free  := AvailMem(MEMF_CHIP)
  total := AvailMem(MEMF_CHIP OR MEMF_TOTAL)
  buildram(lChip, 'Chip RAM', free, total, chipShift, chipUnit)

  free  := AvailMem(MEMF_FAST)
  total := AvailMem(MEMF_FAST OR MEMF_TOTAL)
  buildram(lFast, 'Fast RAM', free, total, fastShift, fastUnit)

  lb := {eb.lib}
  StringF(lExec,'Exec:       \d.\d (Kickstart)', lb.version, lb.revision)
  StringF(lClock,'E-Clock:    \d Hz', eb.eclockfrequency)
  StringF(lStack,'Stack:      \d bytes', thistask::process.stacksize)

  width := EstrLen(lCpu)
  width := widermax(width, EstrLen(lFpu))
  width := widermax(width, EstrLen(lVideo))
  width := widermax(width, EstrLen(lChip))
  width := widermax(width, EstrLen(lFast))
  width := widermax(width, EstrLen(lExec))
  width := widermax(width, EstrLen(lClock))
  width := widermax(width, EstrLen(lStack))

  padto(lCpu,width)
  padto(lFpu,width)
  padto(lVideo,width)
  padto(lChip,width)
  padto(lFast,width)
  padto(lExec,width)
  padto(lClock,width)
  padto(lStack,width)

  makeborder(border,width,'.','.')
  WriteF('\s\n', border)
  WriteF('| \s |\n', lCpu)
  WriteF('| \s |\n', lFpu)
  WriteF('| \s |\n', lVideo)
  WriteF('| \s |\n', lChip)
  WriteF('| \s |\n', lFast)
  WriteF('| \s |\n', lExec)
  WriteF('| \s |\n', lClock)
  WriteF('| \s |\n', lStack)
  makeborder(border,width,'`','\a')
  WriteF('\s\n', border)

  FreeArgs(rdargs)

EXCEPT DO
  IF rdargs THEN FreeArgs(rdargs)
  IF exception THEN WriteF('Error: \s\n', exceptioninfo)
ENDPROC

/* Turns a MEM/CHIP/FAST keyword value ('B', 'KB' or 'MB',
   case-insensitive) into a shift amount and a display label. NIL
   (argument not given) falls back to the supplied default. */
PROC parseunit(raw:PTR TO CHAR, defShift, defUnit:PTR TO CHAR)
  DEF buf[8]:STRING
  DEF shift, unit:PTR TO CHAR

  IF raw=NIL
    shift := defShift
    unit := defUnit
  ELSE
    StrCopy(buf,raw,ALL)
    UpperStr(buf)
    IF StrCmp(buf,'B',ALL)
      shift := 0
      unit := 'B'
    ELSEIF StrCmp(buf,'KB',ALL)
      shift := 10
      unit := 'KB'
    ELSEIF StrCmp(buf,'MB',ALL)
      shift := 20
      unit := 'MB'
    ELSE
      Throw("ARG",'Unit must be B, KB or MB')
    ENDIF
  ENDIF
ENDPROC shift, unit

/* Builds one "<label>:   <free> <unit> free / <total> <unit> total"
   line into buf. MB gets one decimal place (xx.x MB); B and KB stay
   whole numbers. */
PROC buildram(buf:PTR TO CHAR, label:PTR TO CHAR, freeBytes, totalBytes, shift, unit:PTR TO CHAR)
  DEF freeW, freeD, totalW, totalD

  IF StrCmp(unit,'MB',ALL)
    freeW, freeD := splittenths(freeBytes)
    totalW, totalD := splittenths(totalBytes)
    StringF(buf,'\s:   \d.\d MB free / \d.\d MB total', label, freeW, freeD, totalW, totalD)
  ELSE
    StringF(buf,'\s:   \d \s free / \d \s total', label, Shr(freeBytes,shift), unit, Shr(totalBytes,shift), unit)
  ENDIF
ENDPROC buf

/* bytes -> whole MB, tenths-of-MB digit. Built from Shl/Shr (proven
   correct) and Mod() (documented correct for small values) instead
   of `/` or `*`, since bytes here can be tens of millions. */
PROC splittenths(bytes)
  DEF tenths, whole, dec
  tenths := Shr(Shl(bytes,3) + Shl(bytes,1), 20)
  dec, whole := Mod(tenths, 10)
ENDPROC whole, dec

PROC widermax(a,b)
  IF b>a THEN a:=b
ENDPROC a

/* Right-pads line with spaces (in place) until it's target chars
   long. Never shortens -- if line is already >= target this is a
   no-op. */
PROC padto(line:PTR TO CHAR, target)
  WHILE EstrLen(line)<target
    StrAddChar(line," ")
  ENDWHILE
ENDPROC line

/* Builds a border line into out: left, then (width+2) dashes, then
   right. The +2 accounts for the single space of padding on each
   side of a content line ("| " and " |"). */
PROC makeborder(out:PTR TO CHAR, width, left:PTR TO CHAR, right:PTR TO CHAR)
  DEF i
  StrCopy(out,left,ALL)
  FOR i:=1 TO width+2 DO StrAddChar(out,"-")
  StrAdd(out,right,ALL)
ENDPROC out

version: CHAR '$VER: amifetch 0.1 (14.7.26)',0
