;----------------------------------------------------------------------
; mv.asm -- Unix-style move for AmigaDOS, 68000 assembly.
; Usage: mv FROM/A/M TO/A [OVERWRITE]
;
; Same behaviour as mv.e (see that file for the full design notes):
;   - Rename() first, per file: on AmigaDOS that's already a full move
;     anywhere on the same volume, files and directories alike.
;   - ERROR_RENAME_ACROSS_DEVICES -> copy + delete fallback, keeping
;     protection bits and datestamp. Directories are refused there.
;   - FROM takes multiple names and/or AmigaDOS patterns (MatchFirst/
;     MatchNext); with several files or a pattern, TO must be an
;     existing directory.
;   - Existing targets are skipped by default and listed at the end
;     (return code 5); OVERWRITE deletes and replaces them instead --
;     after proving the source exists and is a different object
;     (SameLock), so a self-move can never delete the only copy.
;   - Ctrl-C is honoured between files and between copy chunks; a
;     break or failed copy removes the partial target file.
;   - Per-file errors are reported and the batch continues. Return
;     code: 0 clean, 5 skips, 10 errors, 20 break.
;
; Assemble:  vasmm68k_mot -Fhunkexe -nosym -o mv mv.asm
;
; Register conventions: a6 = dos.library base throughout, d7 = worst
; return code so far (setrc keeps the max). Library calls only trash
; d0/d1/a0/a1. State that must survive across calls lives in BSS.
;----------------------------------------------------------------------

; exec.library (offsets from amitools' exec_lib.fd)
_LVOForbid       = -132
_LVOAllocMem     = -198
_LVOFreeMem      = -210
_LVOFindTask     = -294
_LVOSetSignal    = -306
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
_LVOSameLock      = -420
_LVOPrintFault    = -474
_LVOReadArgs      = -798
_LVOMatchFirst    = -822
_LVOMatchNext     = -828
_LVOMatchEnd      = -834
_LVOFreeArgs      = -858
_LVOFilePart      = -870
_LVOAddPart       = -882
_LVOPutStr        = -948
_LVOParsePatternNoCase = -966

; dos constants
MODE_OLDFILE = 1005
MODE_NEWFILE = 1006
ACCESS_READ  = -2
ERROR_NO_FREE_STORE         = 103
ERROR_RENAME_ACROSS_DEVICES = 215
ERROR_NO_MORE_ENTRIES       = 232
LOCK_SAME    = 0
SIGBREAKF_CTRL_C = $1000
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
ap_Strlen        = 18
ap_Info          = 20
ap_Buf           = 280

BUFSIZE = 32768
PATHLEN = 512

; the matched source path and its FileInfoBlock live inside the anchor
srcpath = anchor+ap_Buf
srcfib  = anchor+ap_Info

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

; --- ReadArgs('FROM/A/M,TO/A,OVERWRITE/S', argarr, 0)
        lea     template(pc),a0
        move.l  a0,d1
        lea     argarr,a0
        move.l  a0,d2
        moveq   #0,d3
        jsr     _LVOReadArgs(a6)
        move.l  d0,rdargs
        bne.s   .argsok
        jsr     _LVOIoErr(a6)
        move.l  d0,d1
        lea     mvname(pc),a0
        move.l  a0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_ERROR,d7
        bra     finish
.argsok:

; --- is TO an existing directory?
        move.l  argarr+4,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d6
        beq.s   .nodir
        move.l  d6,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .undir
        tst.l   gfib+fib_DirEntryType
        ble.s   .undir
        st      toisdir
.undir: move.l  d6,d1
        jsr     _LVOUnLock(a6)
.nodir:

; --- count sources (d5) and detect wildcards (d6); with several
; --- files or a pattern, TO must be that existing directory
        moveq   #0,d5
        moveq   #0,d6
        move.l  argarr,a2
.cnt:   move.l  (a2)+,d0
        beq.s   .cdone
        addq.l  #1,d5
        move.l  d0,d1
        move.l  #patbuf,d2
        move.l  #1024,d3
        jsr     _LVOParsePatternNoCase(a6)
        tst.l   d0                      ; jsr leaves stale flags!
        ble.s   .cnt                    ; 0 = plain, -1 = err (surfaces later)
        moveq   #1,d6
        bra.s   .cnt
.cdone: tst.l   d6
        bne.s   .ismulti
        cmp.l   #1,d5
        bls.s   .single
.ismulti:
        tst.b   toisdir
        bne.s   .single
        lea     msg_needdir(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra.s   finish

; --- run every FROM argument
.single:
        move.l  argarr,fromptr
srcloop:
        move.l  fromptr,a0
        move.l  (a0)+,d0
        move.l  a0,fromptr
        tst.l   d0
        beq.s   alldone
        move.l  d0,curspec
        bsr     dosource
        tst.b   brkflag
        beq.s   srcloop
        lea     msg_break(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_FAIL,d0
        bsr     setrc
        bra.s   finish                  ; broken: don't print the skip list

alldone:
        bsr     printskips

finish: bsr     freeskips
        bra     exit

;----------------------------------------------------------------------
; dosource: run curspec through MatchFirst/MatchNext (handles plain
; names and patterns uniformly) and move every match
;----------------------------------------------------------------------
dosource:
        lea     anchor,a0               ; MatchFirst needs a clean anchor
        moveq   #69,d0                  ; 280/4 longwords
.cl:    clr.l   (a0)+
        dbra    d0,.cl
        move.w  #PATHLEN-1,anchor+ap_Strlen
        move.l  curspec,d1
        move.l  #anchor,d2
        jsr     _LVOMatchFirst(a6)
.mloop: tst.l   d0
        bne.s   .mend
        bsr     checkbreak
        tst.l   d0
        bne.s   .fin
        bsr     moveone
        tst.b   brkflag
        bne.s   .fin
        move.l  #anchor,d1
        jsr     _LVOMatchNext(a6)
        bra.s   .mloop
.mend:  cmp.l   #ERROR_NO_MORE_ENTRIES,d0
        beq.s   .fin
        move.l  d0,d5                   ; report bad spec, batch continues
        move.l  curspec,a3
        bsr     faultfor
.fin:   move.l  #anchor,d1
        jsr     _LVOMatchEnd(a6)
        rts

;----------------------------------------------------------------------
; moveone: move the currently matched srcpath to TO
;----------------------------------------------------------------------
moveone:
        move.l  argarr+4,a0             ; rebuild target: TO ...
        lea     gtarget,a1
        move.w  #PATHLEN-2,d0
.cp:    move.b  (a0)+,(a1)+
        dbeq    d0,.cp
        clr.b   (a1)
        tst.b   toisdir                 ; ... plus /<filename> if a dir
        beq.s   .built
        move.l  #srcpath,d1
        jsr     _LVOFilePart(a6)
        move.l  d0,d2
        move.l  #gtarget,d1
        move.l  #PATHLEN,d3
        jsr     _LVOAddPart(a6)
.built:
        move.l  #gtarget,d1             ; does the target exist?
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d6                   ; tlock
        beq     .rename

; the source must provably exist, and be a different object, BEFORE
; the target's fate is decided -- otherwise OVERWRITE could delete
; the target and then have nothing to move in
        move.l  #srcpath,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d4                   ; slock
        bne.s   .srcok
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        move.l  d6,d1
        jsr     _LVOUnLock(a6)
        lea     srcpath,a3
        bra     faultfor
.srcok: move.l  d4,d1
        move.l  d6,d2
        jsr     _LVOSameLock(a6)
        move.l  d0,d3                   ; LOCK_SAME (0) = same object
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
        move.l  d6,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        move.l  d0,d5
        move.l  d6,d1
        jsr     _LVOUnLock(a6)
        tst.l   d3
        beq.s   .same
        tst.l   d5
        beq.s   .notdir                 ; Examine failed: treat as file
        tst.l   gfib+fib_DirEntryType
        bgt.s   .ovdir
.notdir:
        tst.l   argarr+8                ; OVERWRITE given?
        bne.s   .dodel
        lea     srcpath,a3              ; no: record the skip
        bra     addskip
.dodel: move.l  #gtarget,d1
        jsr     _LVODeleteFile(a6)
        tst.l   d0
        bne.s   .rename
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     msg_repl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #gtarget,d1
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_ERROR,d0
        bra     setrc

.same:  lea     pfx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #srcpath,d1
        jsr     _LVOPutStr(a6)
        lea     msg_same(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bra     setrc

.ovdir: lea     msg_ovdir(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #gtarget,d1
        jsr     _LVOPutStr(a6)
        lea     nl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bra     setrc

.rename:
        move.l  #srcpath,d1
        move.l  #gtarget,d2
        jsr     _LVORename(a6)
        tst.l   d0
        bne.s   .done
        jsr     _LVOIoErr(a6)
        cmp.l   #ERROR_RENAME_ACROSS_DEVICES,d0
        beq.s   .xdev
        move.l  d0,d5
        lea     srcpath,a3
        bra     faultfor
.xdev:  tst.l   srcfib+fib_DirEntryType
        ble.s   .docopy
        lea     pfx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #srcpath,d1
        jsr     _LVOPutStr(a6)
        lea     msg_dirx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bra     setrc
.docopy:
        bra     copymove
.done:  rts

;----------------------------------------------------------------------
; copymove: cross-volume move of srcpath into gtarget
;----------------------------------------------------------------------
copymove:
        tst.l   bufptr                  ; copy buffer, allocated once
        bne.s   .buf
        move.l  a6,a5
        move.l  4.w,a6
        move.l  #BUFSIZE,d0
        moveq   #0,d1
        jsr     _LVOAllocMem(a6)
        move.l  a5,a6
        move.l  d0,bufptr
        bne.s   .buf
        move.l  #ERROR_NO_FREE_STORE,d5
        lea     srcpath,a3
        bra     faultfor
.buf:   move.l  #srcpath,d1
        move.l  #MODE_OLDFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,fhin
        bne.s   .in
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     srcpath,a3
        bra     faultfor
.in:    move.l  #gtarget,d1
        move.l  #MODE_NEWFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,fhout
        bne.s   .loop
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        bsr     closeboth
        lea     srcpath,a3
        bra     faultfor

.loop:  bsr     checkbreak
        tst.l   d0
        bne.s   .brk
        move.l  fhin,d1
        move.l  bufptr,d2
        move.l  #BUFSIZE,d3
        jsr     _LVORead(a6)
        move.l  d0,d3
        beq.s   .done                   ; 0 = EOF
        bmi.s   .rwerr                  ; -1 = read error
        move.l  fhout,d1
        move.l  bufptr,d2
        jsr     _LVOWrite(a6)
        cmp.l   d3,d0
        beq.s   .loop
.rwerr: jsr     _LVOIoErr(a6)           ; save error, then remove the
        move.l  d0,d5                   ; partial target file
        bsr     closeboth
        bsr     delpartial
        lea     srcpath,a3
        bra     faultfor
.brk:   bsr     closeboth               ; brkflag is set: unwind, the
        bra     delpartial              ; main loop prints ***Break

.done:  bsr     closeboth
        move.l  #gtarget,d1             ; best-effort: carry over
        move.l  srcfib+fib_Protection,d2 ; protection bits + datestamp
        jsr     _LVOSetProtection(a6)
        move.l  #gtarget,d1
        move.l  #srcfib+fib_Date,d2
        jsr     _LVOSetFileDate(a6)
        move.l  #srcpath,d1
        jsr     _LVODeleteFile(a6)
        tst.l   d0
        bne.s   .r
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     msg_cpd1(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #gtarget,d1
        jsr     _LVOPutStr(a6)
        lea     msg_cpd2(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #srcpath,d1
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_WARN,d0
        bra     setrc
.r:     rts

closeboth:
        move.l  fhout,d1
        beq.s   .1
        jsr     _LVOClose(a6)
        clr.l   fhout
.1:     move.l  fhin,d1
        beq.s   .2
        jsr     _LVOClose(a6)
        clr.l   fhin
.2:     rts

delpartial:
        move.l  #gtarget,d1
        jsr     _LVODeleteFile(a6)
        rts

;----------------------------------------------------------------------
; checkbreak: d0 nonzero (and brkflag set) if Ctrl-C was pressed
;----------------------------------------------------------------------
checkbreak:
        move.l  a6,-(sp)
        move.l  4.w,a6
        moveq   #0,d0
        move.l  #SIGBREAKF_CTRL_C,d1
        jsr     _LVOSetSignal(a6)
        move.l  (sp)+,a6
        andi.l  #SIGBREAKF_CTRL_C,d0
        beq.s   .r
        st      brkflag
.r:     rts

;----------------------------------------------------------------------
; faultfor: print "mv: <a3>: <fault text for d5>", raise rc to ERROR.
; setrc: d7 = max(d7, d0)
;----------------------------------------------------------------------
faultfor:
        lea     pfx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a3,d1
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_ERROR,d0
        ; falls through into setrc
setrc:  cmp.l   d7,d0
        ble.s   .r
        move.l  d0,d7
.r:     rts

;----------------------------------------------------------------------
; skip list: nodes of [next.l, allocsize.l, "  <path>\n\0"], printed
; and freed at the end
;----------------------------------------------------------------------
addskip:                                ; a3 = source path to record
        movem.l d2-d4/a2,-(sp)
        move.l  a3,a0
        moveq   #-1,d0
.sl:    addq.l  #1,d0
        tst.b   (a0)+
        bne.s   .sl
        add.l   #12,d0                  ; hdr 8 + '  ' + path + \n + \0
        move.l  d0,d4
        move.l  a6,a5
        move.l  4.w,a6
        moveq   #0,d1
        jsr     _LVOAllocMem(a6)
        move.l  a5,a6
        tst.l   d0
        bne.s   .got
        lea     pfx(pc),a0              ; no memory for the list entry:
        move.l  a0,d1                   ; report the skip inline instead
        jsr     _LVOPutStr(a6)
        move.l  a3,d1
        jsr     _LVOPutStr(a6)
        lea     msg_skipf(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        bra.s   .rc
.got:   move.l  d0,a2
        clr.l   (a2)
        move.l  d4,4(a2)
        lea     8(a2),a1
        move.b  #32,(a1)+
        move.b  #32,(a1)+
        move.l  a3,a0
.cpy:   move.b  (a0)+,(a1)+
        bne.s   .cpy
        move.b  #10,-1(a1)
        clr.b   (a1)
        tst.l   skiphead
        bne.s   .app
        move.l  a2,skiphead
        bra.s   .tl
.app:   move.l  skiptail,a0
        move.l  a2,(a0)
.tl:    move.l  a2,skiptail
.rc:    moveq   #RETURN_WARN,d0
        bsr     setrc
        movem.l (sp)+,d2-d4/a2
        rts

printskips:
        tst.l   skiphead
        beq.s   .r
        lea     msg_skiphdr(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  skiphead,d6
.w:     tst.l   d6
        beq.s   .r
        move.l  d6,a0
        lea     8(a0),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d6,a0
        move.l  (a0),d6
        bra.s   .w
.r:     rts

freeskips:
        move.l  skiphead,d6
        move.l  a6,a5
        move.l  4.w,a6
.f:     tst.l   d6
        beq.s   .fd
        move.l  d6,a1
        move.l  (a1),d3
        move.l  4(a1),d0
        jsr     _LVOFreeMem(a6)
        move.l  d3,d6
        bra.s   .f
.fd:    move.l  a5,a6
        clr.l   skiphead
        rts

;----------------------------------------------------------------------
; centralised cleanup
;----------------------------------------------------------------------
exit:   move.l  fhout,d1                ; defensive: every path closes
        beq.s   .nofo                   ; these already
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

verstr:      dc.b '$VER: mv 0.2 (13.7.26) asm build',0
dosname:     dc.b 'dos.library',0
template:    dc.b 'FROM/A/M,TO/A,OVERWRITE/S',0
mvname:      dc.b 'mv',0
pfx:         dc.b 'mv: ',0
colsp:       dc.b ': ',0
nl:          dc.b 10,0
msg_needdir: dc.b 'mv: with several files or a pattern, TO must be an '
             dc.b 'existing directory',10,0
msg_same:    dc.b ': source and target are the same file',10,0
msg_ovdir:   dc.b 'mv: cannot overwrite directory ',0
msg_repl:    dc.b 'mv: cannot replace ',0
msg_dirx:    dc.b ': moving a directory across volumes is not supported',10,0
msg_cpd1:    dc.b 'mv: copied to ',0
msg_cpd2:    dc.b ' but could not delete ',0
msg_skiphdr: dc.b 'skipped (already exists):',10,0
msg_skipf:   dc.b ': skipped (already exists)',10,0
msg_break:   dc.b '***Break: mv',10,0

        section mem,bss

dosbase:  ds.l 1
rdargs:   ds.l 1
argarr:   ds.l 3
wbmsg:    ds.l 1
bufptr:   ds.l 1
fhin:     ds.l 1
fhout:    ds.l 1
fromptr:  ds.l 1
curspec:  ds.l 1
skiphead: ds.l 1
skiptail: ds.l 1
gfib:     ds.b fib_SIZEOF               ; Examine() needs long alignment;
anchor:   ds.b 280+PATHLEN              ; all-ds.l above guarantees it,
gtarget:  ds.b PATHLEN+4                ; and the ds.b sizes stay
patbuf:   ds.b 1024                     ; long-multiples down to here
toisdir:  ds.b 1
brkflag:  ds.b 1
