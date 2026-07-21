;----------------------------------------------------------------------
; mkdir.asm -- Unix-style make directory for AmigaDOS, 68000 assembly.
; Usage: mkdir [-p] DIR ...
;
; Same behaviour as mkdir.e (see that file for the full design notes):
;   - hand-parsed Unix flag bundles (`mkdir -p a/b/c`); `mkdir ?`
;     answers with usage.
;   - without -p: CreateDir directly; the parent must exist and an
;     existing target is an error.
;   - with -p: create every missing directory along the path -- split
;     on '/', skipping the device: head and parent-hop pieces. An
;     existing directory is not an error; a path component that exists
;     as a file is.
;   - DIR names are literal, no pattern expansion.
;   - IoErr() is read BEFORE the message is written: a successful
;     Write() zeroes it on real AmigaDOS, so reading it afterwards would
;     feed PrintFault a 0, which prints nothing at all -- not even the
;     newline. Captured in d5 first, the fault text and its single
;     trailing newline always print.
;   - Ctrl-C honoured between directories. Return code: 0 clean,
;     10 some directory failed, 20 break.
;
; Assemble:  vasmm68k_mot -Fhunkexe -nosym -o mkdir-asm mkdir.asm
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
_LVOLock          = -84
_LVOUnLock        = -90
_LVOExamine       = -102
_LVOCreateDir     = -120
_LVOIoErr         = -132
_LVOPrintFault    = -474
_LVOPutStr        = -948

; dos constants
ACCESS_READ         = -2
ERROR_OBJECT_EXISTS = 203
SIGBREAKF_CTRL_C    = $1000
MEMF_CLEAR          = $10000
RETURN_OK    = 0
RETURN_WARN  = 5
RETURN_ERROR = 10
RETURN_FAIL  = 20

; struct offsets (verified against amitools' struct definitions)
pr_MsgPort       = 92
pr_CLI           = 172
fib_DirEntryType = 4
fib_SIZEOF       = 260

PATHLEN = 512
MAXARGS = 32

        section text,code

start:  movem.l d2-d7/a2-a6,-(sp)
        moveq   #RETURN_OK,d7

; --- copy the command line FIRST: a0/d0 are only valid at entry
        move.l  d0,d1
        cmp.l   #511,d1
        bls.s   .lenok
        move.l  #511,d1
.lenok: lea     cmdbuf,a1
        bra.s   .cin
.ccp:   move.b  (a0)+,(a1)+
.cin:   dbra    d1,.ccp
        clr.b   (a1)

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

        bsr     parseargs
        tst.b   usagefl                 ; `mkdir ?`: usage printed, rc 0
        bne     finish
        tst.b   badflag
        beq.s   .argok
        lea     msg_badflag(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra     finish
.argok:
        move.l  npaths,d6
        bne.s   .haveargs
        lea     msg_usage(pc),a0        ; no DIR given: short usage, rc 10
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra     finish

; --- one operand per iteration; d4 = index, d6 = npaths
.haveargs:
        moveq   #0,d4
.mloop: bsr     checkbreak
        tst.b   brkflag
        bne.s   .brk
        move.l  d4,d0
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),a0          ; a0 = path
        tst.b   parents
        beq.s   .one
        bsr     makeparents
        bra.s   .next
.one:   bsr     makeone
.next:  addq.l  #1,d4
        cmp.l   d6,d4
        blt.s   .mloop
        bra.s   finish
.brk:   lea     msg_break(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_FAIL,d0
        bsr     setrc

finish: bra     exit

;----------------------------------------------------------------------
; parseargs: tokenize cmdbuf (whitespace-separated, double quotes
; group, `*` escapes inside quotes -- AmigaDOS rules). `-x` bundles
; set flags, a lone `?` prints usage, the rest fill pathtab. DIR names
; are stored literally; mkdir does no pattern matching.
;----------------------------------------------------------------------
parseargs:
        movem.l d2-d6/a2-a3,-(sp)
        lea     cmdbuf,a2
.skipws:
        move.b  (a2),d0
        beq     .done
        cmp.b   #32,d0
        bhi.s   .token
        addq.l  #1,a2
        bra.s   .skipws

.token: lea     tokbuf,a3
        moveq   #0,d3                   ; token length
        moveq   #0,d4                   ; in-quotes flag
.tk:    move.b  (a2),d0
        beq.s   .tkend
        tst.b   d4
        beq.s   .plain
        cmp.b   #'"',d0                 ; closing quote
        bne.s   .q1
        moveq   #0,d4
        addq.l  #1,a2
        bra.s   .tknext
.q1:    cmp.b   #'*',d0                 ; escape inside quotes
        bne.s   .store
        addq.l  #1,a2
        move.b  (a2),d0
        beq.s   .tkend
        cmp.b   #'n',d0
        beq.s   .esc10
        cmp.b   #'N',d0
        beq.s   .esc10
        cmp.b   #'e',d0
        beq.s   .esc27
        cmp.b   #'E',d0
        bne.s   .store
.esc27: moveq   #27,d0
        bra.s   .store
.esc10: moveq   #10,d0
        bra.s   .store
.plain: cmp.b   #32,d0
        bls.s   .tkend
        cmp.b   #'"',d0                 ; opening quote
        bne.s   .store
        moveq   #1,d4
        addq.l  #1,a2
        bra.s   .tknext
.store: move.b  d0,(a3)+
        addq.l  #1,a2
        addq.l  #1,d3
.tknext:
        cmp.l   #PATHLEN-1,d3
        blt.s   .tk
.tkend: clr.b   (a3)
        tst.l   d3
        beq     .skipws

; classify the token
        lea     tokbuf,a0
        move.b  (a0),d0
        cmp.b   #'-',d0
        bne.s   .notflag
        cmp.l   #1,d3
        bls.s   .aspath                 ; a lone "-" is a path
        bsr     setflags
        tst.b   badflag
        bne.s   .done
        bra     .skipws
.notflag:
        cmp.b   #'?',d0
        bne.s   .aspath
        cmp.l   #1,d3
        bne.s   .aspath
        bsr     usage
        st      usagefl
        bra.s   .done
.aspath:
        cmp.l   #MAXARGS,npaths
        bge     .skipws
        move.l  #PATHLEN,d0
        bsr     xalloc
        tst.l   d0
        beq.s   .nomem
        move.l  d0,a1
        move.l  npaths,d1
        lsl.l   #2,d1
        lea     pathtab,a0
        move.l  a1,0(a0,d1.l)
        addq.l  #1,npaths
        lea     tokbuf,a0
        move.l  #PATHLEN,d0
        bsr     strcpyc
        bra     .skipws
.nomem: bsr     outofmem
.done:  movem.l (sp)+,d2-d6/a2-a3
        rts

; setflags: apply a "-xyz" bundle from tokbuf; unknown -> badflag
setflags:
        lea     tokbuf+1,a0
.fl:    move.b  (a0)+,d0
        beq.s   .fr
        cmp.b   #'p',d0
        bne.s   .f1
        st      parents
        bra.s   .fl
.f1:    st      badflag
.fr:    rts

usage:  lea     usagestr(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        rts

;----------------------------------------------------------------------
; makeone (a0 = path): plain mode. CreateDir directly; the parent must
; exist and an existing target is an error, both surfaced as the
; dos.library fault (PrintFault supplies the single trailing newline).
;----------------------------------------------------------------------
makeone:
        movem.l d5/a2,-(sp)
        move.l  a0,a2                  ; a2 = path
        move.l  a2,d1
        jsr     _LVOCreateDir(a6)
        tst.l   d0
        beq.s   .fail
        move.l  d0,d1
        jsr     _LVOUnLock(a6)
        bra.s   .done
.fail:  jsr     _LVOIoErr(a6)          ; capture BEFORE any output
        move.l  d0,d5
        move.l  a2,a0
        bsr     faultmk
.done:  movem.l (sp)+,d5/a2
        rts

;----------------------------------------------------------------------
; makeparents (a0 = path): -p mode. Copy the path into wbuf and create
; every missing directory along it. Split on '/', NUL-terminating at
; each separator to CreateDir the prefix so far; the device: head and
; empty parent-hop pieces are stepped over, not created.
;   d3 = len, d4 = start, d6 = i   (all preserved across makestep)
;----------------------------------------------------------------------
makeparents:
        movem.l d2-d6/a2-a3,-(sp)
        lea     wbuf,a1
        move.l  #PATHLEN,d0
        bsr     strcpyc               ; a0 (path) -> wbuf
        lea     wbuf,a0
        bsr     strlen                ; d0 = len
        move.l  d0,d3
        beq     .done                 ; empty path: nothing to do
        moveq   #0,d4                  ; start
        moveq   #0,d6                  ; i
        lea     wbuf,a3
.wloop: cmp.l   d3,d6
        bge.s   .final
        move.b  0(a3,d6.l),d0
        cmp.b   #':',d0
        beq.s   .colon
        cmp.b   #'/',d0
        beq.s   .slash
        bra.s   .winc                 ; ordinary name char
.colon: move.l  d6,d4                 ; device head: descend, don't create
        addq.l  #1,d4                 ; start = i+1
        bra.s   .winc
.slash: cmp.l   d4,d6                 ; i > start ? (non-empty component)
        ble.s   .slstart
        clr.b   0(a3,d6.l)            ; w[i] := 0
        lea     wbuf,a0
        bsr     makestep
        lea     wbuf,a3
        move.b  #'/',0(a3,d6.l)       ; restore the separator
        tst.l   d0
        beq.s   .done                 ; hard error, already reported
.slstart:
        move.l  d6,d4                 ; start = i+1
        addq.l  #1,d4
.winc:  addq.l  #1,d6
        bra.s   .wloop
.final: cmp.l   d4,d3                 ; len > start ? (a last component)
        ble.s   .done
        lea     wbuf,a0
        bsr     makefinal
.done:  movem.l (sp)+,d2-d6/a2-a3
        rts

;----------------------------------------------------------------------
; makestep (a0 = path) -> d0 = TRUE (continue) / FALSE (hard error).
; Intermediate directory under -p: already-exists is success.
;----------------------------------------------------------------------
makestep:
        movem.l d5/a2,-(sp)
        move.l  a0,a2
        move.l  a2,d1
        jsr     _LVOCreateDir(a6)
        tst.l   d0
        beq.s   .fail
        move.l  d0,d1
        jsr     _LVOUnLock(a6)
        moveq   #1,d0                 ; TRUE
        bra.s   .done
.fail:  jsr     _LVOIoErr(a6)
        move.l  d0,d5
        cmp.l   #ERROR_OBJECT_EXISTS,d5
        bne.s   .real
        moveq   #1,d0                 ; already exists: fine, continue
        bra.s   .done
.real:  move.l  a2,a0
        bsr     faultmk
        moveq   #0,d0                 ; FALSE
.done:  movem.l (sp)+,d5/a2
        rts

;----------------------------------------------------------------------
; makefinal (a0 = path): the last component under -p. An existing
; directory is success; an existing file of that name is an error.
;----------------------------------------------------------------------
makefinal:
        movem.l d5/a2,-(sp)
        move.l  a0,a2
        move.l  a2,d1
        jsr     _LVOCreateDir(a6)
        tst.l   d0
        beq.s   .fail
        move.l  d0,d1
        jsr     _LVOUnLock(a6)
        bra.s   .done
.fail:  jsr     _LVOIoErr(a6)
        move.l  d0,d5
        cmp.l   #ERROR_OBJECT_EXISTS,d5
        bne.s   .real
        move.l  a2,a0
        bsr     isdir
        tst.l   d0
        bne.s   .done                 ; it is a directory: success
        lea     pfx(pc),a0            ; a file of that name: refuse
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a2,d1
        jsr     _LVOPutStr(a6)
        lea     msg_notdir(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra.s   .done
.real:  move.l  a2,a0
        bsr     faultmk
.done:  movem.l (sp)+,d5/a2
        rts

;----------------------------------------------------------------------
; isdir (a0 = path) -> d0 = TRUE if it exists and is a directory
;----------------------------------------------------------------------
isdir:
        movem.l d5/a2,-(sp)
        moveq   #0,d5                 ; result = FALSE
        move.l  a0,d1
        move.l  #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        tst.l   d0
        beq.s   .done
        move.l  d0,a2                 ; lock
        move.l  a2,d1
        lea     gfib,a0
        move.l  a0,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .unlock
        move.l  gfib+fib_DirEntryType,d0
        ble.s   .unlock              ; <= 0: a file, not a directory
        moveq   #1,d5
.unlock:
        move.l  a2,d1
        jsr     _LVOUnLock(a6)
.done:  move.l  d5,d0
        movem.l (sp)+,d5/a2
        rts

;----------------------------------------------------------------------
; faultmk: "mkdir: <a0>: <fault d5>", then rc = ERROR. d5 must already
; hold the IoErr() code (captured before any output clobbered it).
;----------------------------------------------------------------------
faultmk:
        move.l  a0,-(sp)
        lea     pfx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  (sp)+,d1              ; path
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)    ; supplies the trailing newline
        moveq   #RETURN_ERROR,d0
        ; falls through into setrc

setrc:  cmp.l   d7,d0
        ble.s   .r
        move.l  d0,d7
.r:     rts

;----------------------------------------------------------------------
; checkbreak: latch brkflag if Ctrl-C was pressed
;----------------------------------------------------------------------
checkbreak:
        movem.l d1/a0-a1/a6,-(sp)
        move.l  4.w,a6
        moveq   #0,d0
        move.l  #SIGBREAKF_CTRL_C,d1
        jsr     _LVOSetSignal(a6)
        movem.l (sp)+,d1/a0-a1/a6
        andi.l  #SIGBREAKF_CTRL_C,d0
        beq.s   .r
        st      brkflag
.r:     rts

;----------------------------------------------------------------------
; string + memory helpers (dos base juggled through a5, the mv pattern)
;----------------------------------------------------------------------
; strlen: a0 = str -> d0 = length (a0 preserved)
strlen: move.l  a0,-(sp)
        moveq   #-1,d0
.l:     addq.l  #1,d0
        tst.b   (a0)+
        bne.s   .l
        move.l  (sp)+,a0
        rts

; strcpyc: copy a0 -> a1, at most d0 bytes including the NUL
strcpyc:
        subq.l  #1,d0
.c:     beq.s   .term
        move.b  (a0)+,(a1)+
        beq.s   .r
        subq.l  #1,d0
        bra.s   .c
.term:  clr.b   (a1)
.r:     rts

; xalloc: d0 = size -> d0 = cleared memory or 0
xalloc: move.l  a6,a5
        move.l  4.w,a6
        move.l  #MEMF_CLEAR,d1
        jsr     _LVOAllocMem(a6)
        move.l  a5,a6
        rts

; xfree: a1 = ptr, d0 = size
xfree:  move.l  a6,a5
        move.l  4.w,a6
        jsr     _LVOFreeMem(a6)
        move.l  a5,a6
        rts

outofmem:
        lea     msg_nomem(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bra     setrc

;----------------------------------------------------------------------
; centralised cleanup
;----------------------------------------------------------------------
exit:   move.l  npaths,d6              ; free the path strings
        bra.s   .pin
.pfree: move.l  d6,d0
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),a1
        move.l  #PATHLEN,d0
        bsr     xfree
.pin:   dbra    d6,.pfree

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

;----------------------------------------------------------------------
; data
;----------------------------------------------------------------------
verstr:      dc.b '$VER: mkdir 0.1 (20.7.26) asm build',0
dosname:     dc.b 'dos.library',0
pfx:         dc.b 'mkdir: ',0
colsp:       dc.b ': ',0
msg_notdir:  dc.b ': exists and is not a directory',10,0
msg_badflag: dc.b 'mkdir: unknown option (mkdir ? for usage)',10,0
msg_nomem:   dc.b 'mkdir: out of memory',10,0
msg_break:   dc.b '***Break: mkdir',10,0
msg_usage:   dc.b 'usage: mkdir [-p] DIR ...',10,0
usagestr:    dc.b 'mkdir 0.1 -- Unix-style make directory',10
             dc.b 'usage: mkdir [-p] DIR ...',10
             dc.b '  -p  create parent directories as needed; existing is not an error',10,0
        even

        section mem,bss

dosbase:  ds.l 1
wbmsg:    ds.l 1
npaths:   ds.l 1
pathtab:  ds.l MAXARGS
gfib:     ds.b fib_SIZEOF               ; Examine() target; long-aligned
                                        ; (all ds.l above guarantee it)
cmdbuf:   ds.b 512
tokbuf:   ds.b 512
wbuf:     ds.b PATHLEN
parents:  ds.b 1
brkflag:  ds.b 1
usagefl:  ds.b 1
badflag:  ds.b 1
