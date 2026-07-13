;----------------------------------------------------------------------
; mv.asm -- Unix-style move for AmigaDOS, 68000 assembly.
; Usage: mv <from> <to>
;
; Same behaviour as mv.e (see that file for the full design notes):
;   - Rename() first: on AmigaDOS that's already a full move anywhere
;     on the same volume, files and directories alike.
;   - ERROR_RENAME_ACROSS_DEVICES -> copy + delete fallback, keeping
;     protection bits and datestamp. Directories are refused there.
;   - If TO is an existing directory, FROM moves into it (AddPart).
;   - Never overwrites an existing target; a failed copy deletes the
;     partial file so no half-copy is left behind.
;
; Assemble:  vasmm68k_mot -Fhunkexe -nosym -o mv mv.asm
;
; Register use: a6 = dos.library base throughout the main flow (the
; standard scratch registers d0/d1/a0/a1 are the only ones library
; calls may trash). d7 = return code. Cleanup is centralised at exit:
; every open handle lives in a BSS variable that starts zeroed, so
; error paths just set an error code and jump -- same shape as the
; E version's EXCEPT DO block.
;----------------------------------------------------------------------

; exec.library (offsets from amitools' exec_lib.fd)
_LVOForbid       = -132
_LVOAllocMem     = -198
_LVOFreeMem      = -210
_LVOFindTask     = -294
_LVOGetMsg       = -372
_LVOReplyMsg     = -378
_LVOWaitPort     = -384
_LVOCloseLibrary = -414
_LVOOpenLibrary  = -552

; dos.library (offsets from amitools' dos_lib.fd)
_LVOOpen          = -30
_LVOClose         = -36
_LVORead          = -42
_LVOWrite         = -48
_LVODeleteFile    = -72
_LVORename        = -78
_LVOLock          = -84
_LVOUnLock        = -90
_LVOExamine       = -102
_LVOIoErr         = -132
_LVOSetProtection = -186
_LVOSetFileDate   = -396
_LVOPrintFault    = -474
_LVOReadArgs      = -798
_LVOFreeArgs      = -858
_LVOFilePart      = -870
_LVOAddPart       = -882
_LVOPutStr        = -948

; dos constants
MODE_OLDFILE = 1005
MODE_NEWFILE = 1006
ACCESS_READ  = -2
ERROR_NO_FREE_STORE         = 103
ERROR_OBJECT_EXISTS         = 203
ERROR_RENAME_ACROSS_DEVICES = 215
RETURN_OK    = 0
RETURN_WARN  = 5
RETURN_ERROR = 10
RETURN_FAIL  = 20

; struct offsets (verified against amitools' struct definitions)
pr_MsgPort       = 92
pr_CLI           = 172
fib_DirEntryType = 4
fib_Protection   = 116
fib_Date         = 132
fib_SIZEOF       = 260

BUFSIZE = 32768
DESTLEN = 512

        section text,code

start:  movem.l d2-d7/a2-a6,-(sp)
        moveq   #RETURN_OK,d7

; --- CLI or Workbench? A WB-launched process has pr_CLI = 0 and must
; --- collect (and later reply) its startup message or WB hangs.
        move.l  4.w,a6
        sub.l   a1,a1
        jsr     _LVOFindTask(a6)
        move.l  d0,a2
        tst.l   pr_CLI(a2)
        bne.s   .fromcli
        lea     pr_MsgPort(a2),a0
        jsr     _LVOWaitPort(a6)
        lea     pr_MsgPort(a2),a0
        jsr     _LVOGetMsg(a6)
        move.l  d0,wbmsg
        bra     exit_wb                 ; CLI-only tool: just exit clean

.fromcli:
        lea     dosname(pc),a1
        moveq   #37,d0
        jsr     _LVOOpenLibrary(a6)
        move.l  d0,dosbase
        bne.s   .gotdos
        moveq   #RETURN_FAIL,d7
        bra     exit_nodos
.gotdos:
        move.l  d0,a6

; --- ReadArgs('FROM/A,TO/A', argarr, 0)
        lea     template(pc),a0
        move.l  a0,d1
        lea     argarr,a0
        move.l  a0,d2
        moveq   #0,d3
        jsr     _LVOReadArgs(a6)
        move.l  d0,rdargs
        beq     fault_ioerr

; --- copy TO into the writable dest buffer (bounded)
        move.l  argarr+4,a0
        lea     dest,a1
        move.w  #DESTLEN-2,d0
.cpto:  move.b  (a0)+,(a1)+
        dbeq    d0,.cpto
        clr.b   (a1)

; --- if TO is an existing directory, target is TO/<filename of FROM>
        lea     dest,a0
        move.l  a0,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d6
        beq.s   .nodir
        move.l  d6,d1
        lea     fib,a0
        move.l  a0,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .undir
        tst.l   fib+fib_DirEntryType
        ble.s   .undir
        move.l  argarr,d1
        jsr     _LVOFilePart(a6)
        move.l  d0,d2
        lea     dest,a0
        move.l  a0,d1
        move.l  #DESTLEN,d3
        jsr     _LVOAddPart(a6)
.undir: move.l  d6,d1
        jsr     _LVOUnLock(a6)
.nodir:

; --- fast path: Rename() covers rename + every same-volume move
        move.l  argarr,d1
        lea     dest,a0
        move.l  a0,d2
        jsr     _LVORename(a6)
        tst.l   d0
        bne     exit                    ; done, d7 already RETURN_OK
        jsr     _LVOIoErr(a6)
        cmp.l   #ERROR_RENAME_ACROSS_DEVICES,d0
        beq.s   crossmove
        move.l  d0,d1
        bra     fault

;----------------------------------------------------------------------
; cross-volume: copy + delete
;----------------------------------------------------------------------
crossmove:
        move.l  argarr,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d6
        beq     fault_ioerr
        move.l  d6,d1
        lea     fib,a0
        move.l  a0,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        bne.s   .exok
        jsr     _LVOIoErr(a6)           ; save error before UnLock
        move.l  d0,d5
        move.l  d6,d1
        jsr     _LVOUnLock(a6)
        move.l  d5,d1
        bra     fault
.exok:  move.l  d6,d1
        jsr     _LVOUnLock(a6)
        move.l  fib+fib_Protection,srcprot
        tst.l   fib+fib_DirEntryType
        ble.s   .isfile
        lea     msg_dir(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d7
        bra     exit
.isfile:

; MODE_NEWFILE would silently truncate an existing target, so refuse
; first, matching Rename()'s same-volume behaviour
        lea     dest,a0
        move.l  a0,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d1
        beq.s   .free
        jsr     _LVOUnLock(a6)
        move.l  #ERROR_OBJECT_EXISTS,d1
        bra     fault
.free:

        move.l  a6,a5                   ; buffer via exec
        move.l  4.w,a6
        move.l  #BUFSIZE,d0
        moveq   #0,d1                   ; MEMF_ANY
        jsr     _LVOAllocMem(a6)
        move.l  a5,a6
        move.l  d0,bufptr
        bne.s   .gotbuf
        move.l  #ERROR_NO_FREE_STORE,d1
        bra     fault
.gotbuf:

        move.l  argarr,d1
        move.l  #MODE_OLDFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,fhin
        beq     fault_ioerr
        lea     dest,a0
        move.l  a0,d1
        move.l  #MODE_NEWFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,fhout
        beq     fault_ioerr             ; fhin closed by exit cleanup

.loop:  move.l  fhin,d1
        move.l  bufptr,d2
        move.l  #BUFSIZE,d3
        jsr     _LVORead(a6)
        move.l  d0,d3
        beq.s   .done                   ; 0 = EOF
        bmi.s   .rwfail                 ; -1 = read error
        move.l  fhout,d1
        move.l  bufptr,d2
        jsr     _LVOWrite(a6)
        cmp.l   d3,d0
        beq.s   .loop
.rwfail:
        jsr     _LVOIoErr(a6)           ; save error, then remove the
        move.l  d0,d5                   ; partial target file
        move.l  fhout,d1
        jsr     _LVOClose(a6)
        clr.l   fhout
        move.l  fhin,d1
        jsr     _LVOClose(a6)
        clr.l   fhin
        lea     dest,a0
        move.l  a0,d1
        jsr     _LVODeleteFile(a6)
        move.l  d5,d1
        bra     fault
.done:
        move.l  fhout,d1
        jsr     _LVOClose(a6)
        clr.l   fhout
        move.l  fhin,d1
        jsr     _LVOClose(a6)
        clr.l   fhin

; best-effort: carry over protection bits and datestamp
        lea     dest,a0
        move.l  a0,d1
        move.l  srcprot,d2
        jsr     _LVOSetProtection(a6)
        lea     dest,a0
        move.l  a0,d1
        lea     fib+fib_Date,a0
        move.l  a0,d2
        jsr     _LVOSetFileDate(a6)

        move.l  argarr,d1
        jsr     _LVODeleteFile(a6)
        tst.l   d0
        bne.s   exit                    ; d7 already RETURN_OK
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     msg_nodel(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        lea     mvname(pc),a0
        move.l  a0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_WARN,d7
        bra.s   exit

;----------------------------------------------------------------------
; error reporting + centralised cleanup
;----------------------------------------------------------------------
fault_ioerr:
        jsr     _LVOIoErr(a6)
        move.l  d0,d1
fault:  lea     mvname(pc),a0
        move.l  a0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_ERROR,d7
        ; falls through to exit

exit:   move.l  fhout,d1
        beq.s   .nofo
        jsr     _LVOClose(a6)
.nofo:  move.l  fhin,d1
        beq.s   .nofi
        jsr     _LVOClose(a6)
.nofi:  move.l  bufptr,d0
        beq.s   .nobuf
        move.l  d0,a1
        move.l  a6,a5
        move.l  4.w,a6
        move.l  #BUFSIZE,d0
        jsr     _LVOFreeMem(a6)
        move.l  a5,a6
.nobuf: move.l  rdargs,d1
        beq.s   exit_nodos
        jsr     _LVOFreeArgs(a6)

exit_nodos:
        move.l  4.w,a6
        move.l  dosbase,d0
        beq.s   exit_wb
        move.l  d0,a1
        jsr     _LVOCloseLibrary(a6)

exit_wb:
        move.l  wbmsg,d0
        beq.s   .nowb
        move.l  4.w,a6
        jsr     _LVOForbid(a6)          ; keep our seglist valid until
        move.l  d0,a1                   ; WB sees the reply
        jsr     _LVOReplyMsg(a6)
.nowb:  move.l  d7,d0
        movem.l (sp)+,d2-d7/a2-a6
        rts

dosname:   dc.b 'dos.library',0
template:  dc.b 'FROM/A,TO/A',0
mvname:    dc.b 'mv',0
msg_dir:   dc.b 'mv: moving a directory across volumes is not supported',10,0
msg_nodel: dc.b 'mv: copied, but could not delete the source:',10,0

        section mem,bss

dosbase: ds.l 1
rdargs:  ds.l 1
argarr:  ds.l 2
wbmsg:   ds.l 1
bufptr:  ds.l 1
fhin:    ds.l 1
fhout:   ds.l 1
srcprot: ds.l 1
fib:     ds.b fib_SIZEOF                ; Examine() needs long alignment;
dest:    ds.b DESTLEN+4                 ; all-ds.l above guarantees it
