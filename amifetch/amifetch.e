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
   frequency, and this process's stack size.

   RAM sizes are converted with Shr(x,shift)/Shl(x,n) rather than
   x/divisor or x*factor: this compiler's `/` operator on a 32-bit
   dividend north of a few million (e.g. Fast RAM's raw byte count,
   tens of millions) silently returns garbage -- specifically the low
   16 bits of the dividend, sign-extended, as if no division happened
   at all. Chip RAM's raw byte count is small enough to never trip it,
   which is why it looked fine while Fast RAM didn't. Confirmed on
   real hardware/FS-UAE with hardcoded values, unrelated to AvailMem()
   or WriteF() itself. Shr()/Shl() don't have the bug, so MB's one
   decimal place is derived from those plus the small-value-only
   Mod() builtin instead of plain `/` or `*`.
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
  WriteF('CPU:        \s\n', cpu)

  IF attn AND AFF_68882
    StrCopy(fpu,'68882',ALL)
  ELSEIF attn AND AFF_68881
    StrCopy(fpu,'68881',ALL)
  ELSEIF attn AND AFF_FPU40
    StrCopy(fpu,'68040/68060 FPU',ALL)
  ELSE
    StrCopy(fpu,'none',ALL)
  ENDIF
  WriteF('FPU:        \s\n', fpu)

  IF eb.vblankfrequency=60
    StrCopy(video,'NTSC (60Hz)',ALL)
  ELSE
    StrCopy(video,'PAL (50Hz)',ALL)
  ENDIF
  WriteF('Video:      \s\n', video)

  free  := AvailMem(MEMF_CHIP)
  total := AvailMem(MEMF_CHIP OR MEMF_TOTAL)
  printram('Chip RAM', free, total, chipShift, chipUnit)

  free  := AvailMem(MEMF_FAST)
  total := AvailMem(MEMF_FAST OR MEMF_TOTAL)
  printram('Fast RAM', free, total, fastShift, fastUnit)

  lb := {eb.lib}
  WriteF('Exec:       \d.\d (Kickstart)\n', lb.version, lb.revision)

  WriteF('E-Clock:    \d Hz\n', eb.eclockfrequency)
  WriteF('Stack:      \d bytes\n', thistask::process.stacksize)

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

/* Prints one "<label>:   <free> <unit> free / <total> <unit> total"
   line. MB gets one decimal place (xx.x MB); B and KB stay whole
   numbers. */
PROC printram(label:PTR TO CHAR, freeBytes, totalBytes, shift, unit:PTR TO CHAR)
  DEF freeW, freeD, totalW, totalD

  IF StrCmp(unit,'MB',ALL)
    freeW, freeD := splittenths(freeBytes)
    totalW, totalD := splittenths(totalBytes)
    WriteF('\s:   \d.\d MB free / \d.\d MB total\n', label, freeW, freeD, totalW, totalD)
  ELSE
    WriteF('\s:   \d \s free / \d \s total\n', label, Shr(freeBytes,shift), unit, Shr(totalBytes,shift), unit)
  ENDIF
ENDPROC

/* bytes -> whole MB, tenths-of-MB digit. Built from Shl/Shr (proven
   correct) and Mod() (documented correct for small values) instead
   of `/` or `*`, since bytes here can be tens of millions. */
PROC splittenths(bytes)
  DEF tenths, whole, dec
  tenths := Shr(Shl(bytes,3) + Shl(bytes,1), 20)
  dec, whole := Mod(tenths, 10)
ENDPROC whole, dec
