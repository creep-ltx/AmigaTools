/* amifetch.e -- neofetch-style Amiga system info dump
   Usage: amifetch

   Reports CPU/FPU (from exec.library's cumulative AttnFlags bits),
   chip/fast RAM free vs. installed (AvailMem), video timing (from the
   vertical blank frequency), Kickstart/exec.library version, E-Clock
   frequency, and this process's stack size.
*/

MODULE 'exec/execbase', 'exec/libraries', 'exec/memory', 'dos/dosextens'

PROC main()
  DEF eb:PTR TO execbase
  DEF lb:PTR TO lib
  DEF attn
  DEF cpu[8]:STRING, fpu[24]:STRING, video[16]:STRING
  DEF chipFree, chipTotal, fastFree, fastTotal

  eb := execbase
  lb := {eb.lib}
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

  IF attn AND AFF_68882
    StrCopy(fpu,'68882',ALL)
  ELSEIF attn AND AFF_68881
    StrCopy(fpu,'68881',ALL)
  ELSEIF attn AND AFF_FPU40
    StrCopy(fpu,'68040/68060 FPU',ALL)
  ELSE
    StrCopy(fpu,'none',ALL)
  ENDIF

  IF eb.vblankfrequency=60
    StrCopy(video,'NTSC (60Hz)',ALL)
  ELSE
    StrCopy(video,'PAL (50Hz)',ALL)
  ENDIF

  chipFree  := AvailMem(MEMF_CHIP)
  chipTotal := AvailMem(MEMF_CHIP OR MEMF_TOTAL)
  fastFree  := AvailMem(MEMF_FAST)
  fastTotal := AvailMem(MEMF_FAST OR MEMF_TOTAL)

  WriteF('CPU:        \s\n', cpu)
  WriteF('FPU:        \s\n', fpu)
  WriteF('Video:      \s\n', video)
  WriteF('Chip RAM:   \d K free / \d K total\n', chipFree/1024, chipTotal/1024)
  WriteF('Fast RAM:   \d K free / \d K total\n', fastFree/1024, fastTotal/1024)
  WriteF('Exec:       \d.\d (Kickstart)\n', lb.version, lb.revision)
  WriteF('E-Clock:    \d Hz\n', eb.eclockfrequency)
  WriteF('Stack:      \d bytes\n', thistask::process.stacksize)

ENDPROC
