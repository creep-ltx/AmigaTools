;----------------------------------------------------------------------
; cp.asm -- Unix-style copy for AmigaDOS, 68000 assembly.
; usage: cp [-fr] FROM ... TO
;
; Same behaviour as cp.e (see that file for the full design notes):
;   - bundled Unix flag bundles (-f, -r, -fr); the last path is TO,
;     everything before it a source. `cp ?` prints usage.
;   - non-destructive: an existing target file is skipped and listed at
;     the end (rc 5); -f deletes and replaces it, after proving the
;     source exists and differs from the target (SameLock). A directory
;     is never replaced with a file.
;   - protection bits, datestamp and filenote are carried to the copy.
;   - -r copies directories with an explicit FIFO work list (not native
;     recursion, so a deep tree can't blow the stack): each dir is
;     recreated, its files copied, its subdirs queued. Without -r a
;     directory source is refused.
;   - Ctrl-C between files and copy chunks; a broken/failed copy removes
;     the partial target.
;   - Per-file errors are reported and the batch continues. Return code:
;     0 clean, 5 skips, 10 errors, 20 break.
;
; Assemble:  vasmm68k_mot -Fhunkexe -nosym -o cp-asm cp.asm
;
; Register conventions: a6 = dos.library base throughout, d7 = worst
; return code so far (setrc keeps the max). Library calls only trash
; d0/d1/a0/a1. State that must survive across calls lives in BSS, and
; every routine movem-saves the registers it uses.
;----------------------------------------------------------------------

; exec.library
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

; dos.library
_LVOOpen          = -30
_LVOClose         = -36
_LVORead          = -42
_LVOWrite         = -48
_LVODeleteFile    = -72
_LVOLock          = -84
_LVOUnLock        = -90
_LVOExamine       = -102
_LVOExNext        = -108
_LVOCreateDir     = -120
_LVOIoErr         = -132
_LVOSetComment    = -180
_LVOSetProtection = -186
_LVOSetFileDate   = -396
_LVOSameLock      = -420
_LVOPrintFault    = -474
_LVOMatchFirst    = -822
_LVOMatchNext     = -828
_LVOMatchEnd      = -834
_LVOFilePart      = -870
_LVOAddPart       = -882
_LVOPutStr        = -948
_LVOParsePatternNoCase = -966

; dos constants
MODE_OLDFILE = 1005
MODE_NEWFILE = 1006
ACCESS_READ  = -2
ERROR_OBJECT_EXISTS   = 203
ERROR_NO_MORE_ENTRIES = 232
LOCK_SAME    = 0
SIGBREAKF_CTRL_C = $1000
MEMF_CLEAR   = $10000
RETURN_OK    = 0
RETURN_WARN  = 5
RETURN_ERROR = 10
RETURN_FAIL  = 20

; struct offsets
pr_MsgPort       = 92
pr_CLI           = 172
fib_DirEntryType = 4
fib_FileName     = 8
fib_Protection   = 116
fib_Date         = 132
fib_Comment      = 144
fib_SIZEOF       = 260
ap_Strlen        = 18
ap_Info          = 20
ap_Buf           = 280

BUFSIZE = 32768
PATHLEN = 512
MAXARGS = 32
NAMELEN = 110

; collected directory entry (AllocMem'd, MEMF_CLEAR)
cent_next  = 0
cent_isdir = 4
cent_prot  = 8
cent_days  = 12
cent_min   = 16
cent_tick  = 20
cent_name  = 24                         ; 110 bytes
cent_comm  = 134                        ; 80 bytes
CENT_SIZEOF = 216

; -r work-list node (src+dst path pair)
dn_next = 0
dn_src  = 4                             ; PATHLEN
dn_dst  = 516                           ; PATHLEN
DN_SIZEOF = 1028

; skip-list node
sn_next = 0
sn_path = 4                             ; PATHLEN
SN_SIZEOF = 516

; the matched path and its FileInfoBlock live inside the anchor
srcpath = anchor+ap_Buf
srcfib  = anchor+ap_Info

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
        bra     exit_wb

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
        tst.b   usagefl                 ; `cp ?`: usage printed, rc 0
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
        move.l  npaths,d0
        cmp.l   #2,d0
        bge.s   .haveargs
        lea     msg_usage(pc),a0        ; need at least FROM and TO
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra     finish
.haveargs:
        move.l  npaths,d0               ; gto = pathtab[npaths-1]
        subq.l  #1,d0
        move.l  d0,nsrc                 ; nsrc sources precede TO
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),gto

; --- detect wildcards among the sources
        moveq   #0,d6                   ; wild
        moveq   #0,d4                   ; source index
.cnt:   cmp.l   nsrc,d4
        bge.s   .cdone
        move.l  d4,d0
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),d1
        move.l  #gpatbuf,d2
        move.l  #1024,d3
        jsr     _LVOParsePatternNoCase(a6)
        tst.l   d0                      ; jsr leaves stale flags!
        ble.s   .cnext
        moveq   #1,d6
.cnext: addq.l  #1,d4
        bra.s   .cnt
.cdone:

; --- is TO an existing directory?
        move.l  gto,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d5
        beq.s   .nodir
        move.l  d5,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .undir
        tst.l   gfib+fib_DirEntryType
        ble.s   .undir
        st      toisdir
.undir: move.l  d5,d1
        jsr     _LVOUnLock(a6)
.nodir:

; --- with several files or a pattern, TO must be that directory
        tst.l   d6
        bne.s   .ismulti
        cmp.l   #1,nsrc
        bls.s   .runsrc
.ismulti:
        tst.b   toisdir
        bne.s   .runsrc
        lea     msg_needdir(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra     finish

; --- run every source (pathtab[0..nsrc-1]); srcidx lives in memory
; --- so it survives dosource
.runsrc:
        clr.l   srcidx
.sloop: move.l  srcidx,d0
        cmp.l   nsrc,d0
        bge.s   .sdone
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),a0
        addq.l  #1,srcidx
        bsr     dosource
        tst.b   brkflag
        beq.s   .sloop
        lea     msg_break(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_FAIL,d0
        bsr     setrc
        bra.s   finish
.sdone:
        bsr     printskips

finish: bra     exit

;----------------------------------------------------------------------
; dosource (a0 = spec): run spec through MatchFirst/MatchNext (handles
; plain names and patterns uniformly) and copy every match.
;----------------------------------------------------------------------
dosource:
        move.l  a0,curspec
        lea     anchor,a0               ; clean anchor (280-byte struct)
        moveq   #69,d0
.cl:    clr.l   (a0)+
        dbra    d0,.cl
        move.w  #PATHLEN-1,anchor+ap_Strlen
        move.l  curspec,d1
        move.l  #anchor,d2
        jsr     _LVOMatchFirst(a6)
.ml:    tst.l   d0
        bne.s   .mend
        bsr     checkbreak
        tst.b   brkflag
        bne.s   .fin
        lea     srcpath,a2
        lea     srcfib,a3
        bsr     copyone
        tst.b   brkflag
        bne.s   .fin
        move.l  #anchor,d1
        jsr     _LVOMatchNext(a6)
        bra.s   .ml
.mend:  cmp.l   #ERROR_NO_MORE_ENTRIES,d0
        beq.s   .fin
        lea     pfx(pc),a0              ; report a bad spec, batch continues
        move.l  curspec,a1
        bsr     faultmsg                ; d0 still = match error code
        moveq   #RETURN_ERROR,d0
        bsr     setrc
.fin:   move.l  #anchor,d1
        jsr     _LVOMatchEnd(a6)
        rts

;----------------------------------------------------------------------
; copyone (a2 = srcpath, a3 = ifib): one matched top-level source. A
; file is copied to gtarget (gto, or gto/name when TO is a directory);
; a directory is walked with the work list when -r is set.
;----------------------------------------------------------------------
copyone:
        movem.l d2/a2-a5,-(sp)
        move.l  gto,a0                  ; gtarget := gto
        lea     gtarget,a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        tst.b   toisdir
        beq.s   .nott
        move.l  a2,d1                   ; AddPart(gtarget, FilePart(src))
        jsr     _LVOFilePart(a6)
        move.l  #gtarget,d1
        move.l  d0,d2
        move.l  #PATHLEN,d3
        jsr     _LVOAddPart(a6)
.nott:
        tst.l   fib_DirEntryType(a3)
        ble.s   .isfile
        tst.b   recursive               ; a directory
        bne.s   .dorec
        lea     msg_omit1(pc),a0        ; "cp: omitting directory "
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a2,d1
        jsr     _LVOPutStr(a6)
        lea     msg_omit2(pc),a0        ; " (use -r)\n"
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        bra.s   .done
.dorec: move.l  a2,a0                   ; copytree(src, gtarget)
        lea     gtarget,a1
        bsr     copytree
        bra.s   .done
.isfile:
        move.l  a2,a0                   ; prepfile(src, gtarget)
        lea     gtarget,a1
        bsr     prepfile
        tst.l   d0
        beq.s   .done
        move.l  fib_Protection(a3),d2   ; copyfile(src,dst,prot,ds,comm)
        lea     fib_Date(a3),a4
        lea     fib_Comment(a3),a5
        move.l  a2,a0
        lea     gtarget,a1
        move.l  a4,a2                   ; ds -> a2
        move.l  a5,a3                   ; comm -> a3
        bsr     copyfile
.done:  movem.l (sp)+,d2/a2-a5
        rts

;----------------------------------------------------------------------
; prepfile (a0 = srcpath, a1 = tpath) -> d0 = TRUE if the copy should
; proceed. The source must provably exist and differ from the target
; BEFORE -f deletes it, so a self-copy can't wipe the only copy.
;----------------------------------------------------------------------
prepfile:
        movem.l d2-d5/a2-a3,-(sp)
        move.l  a0,a2                   ; srcpath
        move.l  a1,a3                   ; tpath
        move.l  a3,d1                   ; Lock(tpath)
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d4                   ; tlock
        bne.s   .haveT
        moveq   #1,d0                   ; no target: proceed
        bra     .ret
.haveT:
        move.l  a2,d1                   ; Lock(src)
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d5                   ; slock
        bne.s   .haveS
        jsr     _LVOIoErr(a6)           ; src vanished
        move.l  d0,d3
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
        lea     pfx(pc),a0
        move.l  a2,a1
        move.l  d3,d0
        bsr     faultmsg
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        moveq   #0,d0
        bra     .ret
.haveS:
        move.l  d5,d1                   ; SameLock(slock, tlock)
        move.l  d4,d2
        jsr     _LVOSameLock(a6)
        move.l  d0,d3                   ; 0 = LOCK_SAME
        move.l  d5,d1
        jsr     _LVOUnLock(a6)          ; unlock slock
        moveq   #0,d5                   ; d5 := tisdir
        move.l  d4,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .exd
        tst.l   gfib+fib_DirEntryType
        ble.s   .exd
        moveq   #1,d5
.exd:   move.l  d4,d1
        jsr     _LVOUnLock(a6)          ; unlock tlock
        tst.l   d3                      ; same object?
        bne.s   .notsame
        lea     pfx(pc),a0
        move.l  a2,d1
        jsr     _LVOPutStr(a6)
        lea     msg_same(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        moveq   #0,d0
        bra.s   .ret
.notsame:
        tst.l   d5                      ; target a directory?
        beq.s   .notdir
        lea     msg_ovdir(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a3,d1
        jsr     _LVOPutStr(a6)
        lea     nl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        moveq   #0,d0
        bra.s   .ret
.notdir:
        tst.b   force
        beq.s   .skip
        move.l  a3,d1                   ; -f: DeleteFile(tpath)
        jsr     _LVODeleteFile(a6)
        tst.l   d0
        bne.s   .delok
        jsr     _LVOIoErr(a6)
        move.l  d0,d3
        lea     msg_repl(pc),a0
        move.l  a3,a1
        move.l  d3,d0
        bsr     faultmsg
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        moveq   #0,d0
        bra.s   .ret
.delok: moveq   #1,d0
        bra.s   .ret
.skip:  move.l  a2,a0                   ; skipped by default
        bsr     addskip
        moveq   #0,d0
.ret:   movem.l (sp)+,d2-d5/a2-a3
        rts

;----------------------------------------------------------------------
; copyfile (a0=src, a1=dst, d2=prot, a2=ds, a3=comm): copy the data,
; then carry over protection, datestamp and filenote. A failed or
; broken copy removes the partial target.
;----------------------------------------------------------------------
copyfile:
        movem.l d5-d6/a4-a5,-(sp)
        move.l  a0,cpsrc
        move.l  a1,cpdst
        move.l  d2,d5                   ; prot
        move.l  a2,a4                   ; ds
        move.l  a3,a5                   ; comm
        clr.l   fhin
        clr.l   fhout
        clr.b   cppartial
        tst.l   gbuf
        bne.s   .havebuf
        move.l  #BUFSIZE,d0
        bsr     xalloc
        tst.l   d0
        beq     .oom
        move.l  d0,gbuf
.havebuf:
        move.l  cpsrc,d1                ; Open(src, MODE_OLDFILE)
        move.l  #MODE_OLDFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,fhin
        bne.s   .openout
        jsr     _LVOIoErr(a6)
        move.l  d0,d6
        bra     .cpyerr
.openout:
        move.l  cpdst,d1                ; Open(dst, MODE_NEWFILE)
        move.l  #MODE_NEWFILE,d2
        jsr     _LVOOpen(a6)
        move.l  d0,fhout
        bne.s   .cploop
        jsr     _LVOIoErr(a6)
        move.l  d0,d6
        bra     .cpyerr
.cploop:
        st      cppartial
.rd:    bsr     checkbreak
        tst.b   brkflag
        bne     .brk
        move.l  fhin,d1
        move.l  gbuf,d2
        move.l  #BUFSIZE,d3
        jsr     _LVORead(a6)
        tst.l   d0
        beq     .rddone                 ; n = 0: EOF
        bmi.s   .rderr                  ; n < 0: error
        move.l  d0,d3                   ; n
        move.l  fhout,d1
        move.l  gbuf,d2
        jsr     _LVOWrite(a6)
        cmp.l   d3,d0                   ; wrote all n?
        beq     .rd
        jsr     _LVOIoErr(a6)
        move.l  d0,d6
        bra     .cpyerr
.rderr: jsr     _LVOIoErr(a6)
        move.l  d0,d6
        bra     .cpyerr
.rddone:
        move.l  fhout,d1
        jsr     _LVOClose(a6)
        clr.l   fhout
        move.l  fhin,d1
        jsr     _LVOClose(a6)
        clr.l   fhin
        clr.b   cppartial
        move.l  cpdst,d1                ; SetProtection(dst, prot)
        move.l  d5,d2
        jsr     _LVOSetProtection(a6)
        move.l  cpdst,d1                ; SetFileDate(dst, ds)
        move.l  a4,d2
        jsr     _LVOSetFileDate(a6)
        move.l  a5,a0                   ; SetComment(dst, comm) if comm[0]
        tst.b   (a0)
        beq.s   .ret
        move.l  cpdst,d1
        move.l  a5,d2
        jsr     _LVOSetComment(a6)
        bra.s   .ret
.brk:   bsr     closepartial
        bra.s   .ret
.oom:   bsr     outofmem
        bra.s   .ret
.cpyerr:
        bsr     closepartial
        lea     pfx(pc),a0
        move.l  cpsrc,a1
        move.l  d6,d0
        bsr     faultmsg
        moveq   #RETURN_ERROR,d0
        bsr     setrc
.ret:   movem.l (sp)+,d5-d6/a4-a5
        rts

; closepartial: close any open handles and delete a half-written target
closepartial:
        move.l  fhout,d0
        beq.s   .a
        move.l  d0,d1
        jsr     _LVOClose(a6)
        clr.l   fhout
.a:     move.l  fhin,d0
        beq.s   .b
        move.l  d0,d1
        jsr     _LVOClose(a6)
        clr.l   fhin
.b:     tst.b   cppartial
        beq.s   .c
        clr.b   cppartial
        move.l  cpdst,d1
        jsr     _LVODeleteFile(a6)
.c:     rts

;----------------------------------------------------------------------
; copytree (a0 = srctop, a1 = dsttop): copy a whole directory tree
; with an explicit FIFO work list, so a parent is always created
; before its children and a deep tree can't blow the stack.
;----------------------------------------------------------------------
copytree:
        move.l  a2,-(sp)
        bsr     queuedir                ; queue the top pair
.loop:  move.l  pendhead,d0
        beq.s   .done
        bsr     checkbreak
        tst.b   brkflag
        bne.s   .done
        move.l  pendhead,a2             ; pop a node
        move.l  dn_next(a2),pendhead
        tst.l   pendhead
        bne.s   .nn
        clr.l   pendtail
.nn:    lea     dn_src(a2),a0           ; copydir(node.src, node.dst)
        lea     dn_dst(a2),a1
        bsr     copydir
        move.l  a2,a1                   ; free the node
        move.l  #DN_SIZEOF,d0
        bsr     xfree
        bra.s   .loop
.done:  move.l  (sp)+,a2
        rts

; queuedir (a0 = src, a1 = dst): append a src/dst pair to the work list
queuedir:
        movem.l a2-a4,-(sp)
        move.l  a0,a3
        move.l  a1,a4
        move.l  #DN_SIZEOF,d0
        bsr     xalloc
        tst.l   d0
        beq.s   .oom
        move.l  d0,a2
        move.l  a3,a0
        lea     dn_src(a2),a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        move.l  a4,a0
        lea     dn_dst(a2),a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        clr.l   dn_next(a2)
        move.l  pendhead,d0
        bne.s   .app
        move.l  a2,pendhead
        bra.s   .st
.app:   move.l  pendtail,a0
        move.l  a2,dn_next(a0)
.st:    move.l  a2,pendtail
        movem.l (sp)+,a2-a4
        rts
.oom:   bsr     outofmem
        movem.l (sp)+,a2-a4
        rts

;----------------------------------------------------------------------
; copydir (a0 = src, a1 = dst): recreate dst as a directory, scan src
; into a list (so gfib is free before any file is examined), then copy
; each file and queue each subdirectory.
;   a2 = src, a3 = dst, d5 = list head, a5 = walker
;----------------------------------------------------------------------
copydir:
        movem.l d2-d6/a2-a5,-(sp)
        move.l  a0,a2
        move.l  a1,a3
        move.l  a2,a0                   ; ensuredir(src, dst)
        move.l  a3,a1
        bsr     ensuredir
        tst.l   d0
        beq     .ret
        move.l  a2,d1                   ; Lock(src)
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d4                   ; srclock
        bne.s   .locked
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     pfx(pc),a0
        move.l  a2,a1
        move.l  d5,d0
        bsr     faultmsg
        moveq   #RETURN_WARN,d0
        bsr     setrc
        bra     .ret
.locked:
        move.l  d4,d1                   ; Examine(srclock, gfib)
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        bne.s   .exok
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
        lea     msg_exam(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a2,d1
        jsr     _LVOPutStr(a6)
        lea     nl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_WARN,d0
        bsr     setrc
        bra     .ret
.exok:
        moveq   #0,d5                   ; head := NIL
.scan:  bsr     checkbreak
        tst.b   brkflag
        bne.s   .brkscan
        move.l  d4,d1                   ; ExNext(srclock, gfib)
        move.l  #gfib,d2
        jsr     _LVOExNext(a6)
        tst.l   d0
        beq.s   .scandone
        lea     gfib,a0                 ; mkent(gfib)
        bsr     mkent
        tst.l   d0
        beq.s   .scan                   ; alloc failed (reported); skip
        move.l  d0,a0
        move.l  d5,cent_next(a0)        ; e.next := head
        move.l  a0,d5                   ; head := e
        bra.s   .scan
.brkscan:
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
        move.l  d5,a0
        bsr     freecents
        bra     .ret
.scandone:
        jsr     _LVOIoErr(a6)
        move.l  d0,d6                   ; err
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
        cmp.l   #ERROR_NO_MORE_ENTRIES,d6
        beq.s   .procit
        lea     pfx(pc),a0
        move.l  a2,a1
        move.l  d6,d0
        bsr     faultmsg
        moveq   #RETURN_WARN,d0
        bsr     setrc
.procit:
        move.l  d5,a5                   ; walk with a5; keep head in d5
.ploop: move.l  a5,d0
        beq     .pdone
        bsr     checkbreak
        tst.b   brkflag
        bne     .pbrk
        move.l  a2,a0                   ; cs := src + e.name
        lea     cs,a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        lea     cs,a0
        move.l  a0,d1
        lea     cent_name(a5),a0
        move.l  a0,d2
        move.l  #PATHLEN,d3
        jsr     _LVOAddPart(a6)
        move.l  a3,a0                   ; cd := dst + e.name
        lea     cd,a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        lea     cd,a0
        move.l  a0,d1
        lea     cent_name(a5),a0
        move.l  a0,d2
        move.l  #PATHLEN,d3
        jsr     _LVOAddPart(a6)
        tst.l   cent_isdir(a5)
        beq.s   .pfile
        lea     cs,a0                   ; a subdirectory: queue it
        lea     cd,a1
        bsr     queuedir
        bra.s   .pnext
.pfile: lea     cs,a0                   ; a file: skip/-f, then copy
        lea     cd,a1
        bsr     prepfile
        tst.l   d0
        beq.s   .pnext
        lea     cs,a0
        lea     cd,a1
        bsr     copyfileent
.pnext: move.l  cent_next(a5),a5
        bra     .ploop
.pbrk:  move.l  d5,a0
        bsr     freecents
        bra.s   .ret
.pdone: move.l  d5,a0
        bsr     freecents
.ret:   movem.l (sp)+,d2-d6/a2-a5
        rts

; copyfileent (a0=src, a1=dst, a5=e): copy a scanned file entry,
; carrying the datestamp captured in the entry through gds.
copyfileent:
        movem.l d2/a2-a3,-(sp)
        move.l  a0,a2
        move.l  a1,a3
        move.l  cent_days(a5),gds
        move.l  cent_min(a5),gds+4
        move.l  cent_tick(a5),gds+8
        move.l  a2,a0
        move.l  a3,a1
        move.l  cent_prot(a5),d2
        lea     gds,a2                  ; ds -> a2
        lea     cent_comm(a5),a3        ; comm -> a3
        bsr     copyfile
        movem.l (sp)+,d2/a2-a3
        rts

;----------------------------------------------------------------------
; ensuredir (a0 = src, a1 = dst) -> d0 = TRUE. Reuse an existing dst
; directory, refuse an existing file, else CreateDir it and stamp the
; source directory's protection and filenote onto it.
;----------------------------------------------------------------------
ensuredir:
        movem.l d2-d5/a2-a3,-(sp)
        move.l  a0,a2                   ; src
        move.l  a1,a3                   ; dst
        move.l  a3,d1                   ; Lock(dst)
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d4
        beq.s   .notexist
        moveq   #0,d5                   ; isdir
        move.l  d4,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .exd
        tst.l   gfib+fib_DirEntryType
        ble.s   .exd
        moveq   #1,d5
.exd:   move.l  d4,d1
        jsr     _LVOUnLock(a6)
        tst.l   d5
        beq.s   .isfile
        moveq   #1,d0                   ; existing directory: reuse
        bra     .ret
.isfile:
        lea     pfx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a3,d1
        jsr     _LVOPutStr(a6)
        lea     msg_notdir2(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        moveq   #0,d0
        bra     .ret
.notexist:
        clr.b   ehave
        move.l  a2,d1                   ; grab src dir metadata
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d4
        beq.s   .nometa
        move.l  d4,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        beq.s   .unmeta
        move.l  gfib+fib_Protection,d5  ; d5 = prot
        lea     gfib+fib_Comment,a0
        lea     ecomm,a1
        move.l  #80,d0
        bsr     strcpyc
        st      ehave
.unmeta:
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
.nometa:
        move.l  a3,d1                   ; CreateDir(dst)
        jsr     _LVOCreateDir(a6)
        move.l  d0,d4
        bne.s   .created
        jsr     _LVOIoErr(a6)
        move.l  d0,d3
        lea     msg_crea(pc),a0
        move.l  a3,a1
        move.l  d3,d0
        bsr     faultmsg
        moveq   #RETURN_ERROR,d0
        bsr     setrc
        moveq   #0,d0
        bra.s   .ret
.created:
        move.l  d4,d1
        jsr     _LVOUnLock(a6)
        tst.b   ehave
        beq.s   .oktrue
        move.l  a3,d1                   ; SetProtection(dst, prot)
        move.l  d5,d2
        jsr     _LVOSetProtection(a6)
        lea     ecomm,a0
        tst.b   (a0)
        beq.s   .oktrue
        move.l  a3,d1                   ; SetComment(dst, ecomm)
        move.l  #ecomm,d2
        jsr     _LVOSetComment(a6)
.oktrue:
        moveq   #1,d0
.ret:   movem.l (sp)+,d2-d5/a2-a3
        rts

;----------------------------------------------------------------------
; mkent (a0 = fib) -> d0 = a cent copy of the entry, or 0 on OOM
;----------------------------------------------------------------------
mkent:
        movem.l d2/a2-a3,-(sp)
        move.l  a0,a3                   ; fib
        move.l  #CENT_SIZEOF,d0
        bsr     xalloc
        tst.l   d0
        beq.s   .oom
        move.l  d0,a2                   ; e
        lea     fib_FileName(a3),a0
        lea     cent_name(a2),a1
        move.l  #NAMELEN,d0
        bsr     strcpyc
        lea     fib_Comment(a3),a0
        lea     cent_comm(a2),a1
        move.l  #80,d0
        bsr     strcpyc
        move.l  fib_Protection(a3),cent_prot(a2)
        move.l  fib_Date(a3),cent_days(a2)
        move.l  fib_Date+4(a3),cent_min(a2)
        move.l  fib_Date+8(a3),cent_tick(a2)
        moveq   #0,d0
        tst.l   fib_DirEntryType(a3)
        ble.s   .nd
        moveq   #1,d0
.nd:    move.l  d0,cent_isdir(a2)
        move.l  a2,d0
        movem.l (sp)+,d2/a2-a3
        rts
.oom:   bsr     outofmem
        moveq   #0,d0
        movem.l (sp)+,d2/a2-a3
        rts

; freecents (a0 = head): free a cent list
freecents:
        move.l  a2,-(sp)
.l:     move.l  a0,d0
        beq.s   .d
        move.l  a0,a2
        move.l  cent_next(a2),a0
        move.l  a0,-(sp)                ; xfree trashes a0
        move.l  a2,a1
        move.l  #CENT_SIZEOF,d0
        bsr     xfree
        move.l  (sp)+,a0
        bra.s   .l
.d:     move.l  (sp)+,a2
        rts

; addskip (a0 = srcpath): record a skipped source
addskip:
        movem.l d2/a2-a3,-(sp)
        move.l  a0,a3
        move.l  #SN_SIZEOF,d0
        bsr     xalloc
        tst.l   d0
        beq.s   .oom
        move.l  d0,a2
        move.l  a3,a0
        lea     sn_path(a2),a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        clr.l   sn_next(a2)
        move.l  skiphead,d0
        bne.s   .app
        move.l  a2,skiphead
        bra.s   .st
.app:   move.l  skiptail,a0
        move.l  a2,sn_next(a0)
.st:    move.l  a2,skiptail
        addq.l  #1,skipcount
        movem.l (sp)+,d2/a2-a3
        rts
.oom:   bsr     outofmem
        movem.l (sp)+,d2/a2-a3
        rts

; printskips: list everything that wasn't copied, rc = warn
printskips:
        move.l  skipcount,d0
        beq.s   .r
        move.l  a2,-(sp)
        lea     msg_skiphdr(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  skiphead,a2
.pl:    move.l  a2,d0
        beq.s   .pe
        lea     msg_skipind(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        lea     sn_path(a2),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        lea     nl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  sn_next(a2),a2
        bra.s   .pl
.pe:    moveq   #RETURN_WARN,d0
        bsr     setrc
        move.l  (sp)+,a2
.r:     rts

;----------------------------------------------------------------------
; parseargs: tokenize cmdbuf (whitespace-separated, double quotes
; group, `*` escapes inside quotes). `-x` bundles set flags, a lone
; `?` prints usage, the rest fill pathtab.
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
        moveq   #0,d3
        moveq   #0,d4
.tk:    move.b  (a2),d0
        beq.s   .tkend
        tst.b   d4
        beq.s   .plain
        cmp.b   #'"',d0
        bne.s   .q1
        moveq   #0,d4
        addq.l  #1,a2
        bra.s   .tknext
.q1:    cmp.b   #'*',d0
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
        cmp.b   #'"',d0
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

        lea     tokbuf,a0
        move.b  (a0),d0
        cmp.b   #'-',d0
        bne.s   .notflag
        cmp.l   #1,d3
        bls.s   .aspath
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

; setflags: apply a "-xy" bundle from tokbuf; unknown -> badflag
setflags:
        lea     tokbuf+1,a0
.fl:    move.b  (a0)+,d0
        beq.s   .fr
        cmp.b   #'f',d0
        bne.s   .f1
        st      force
        bra.s   .fl
.f1:    cmp.b   #'r',d0
        bne.s   .f2
        st      recursive
        bra.s   .fl
.f2:    cmp.b   #'R',d0
        bne.s   .f3
        st      recursive
        bra.s   .fl
.f3:    st      badflag
.fr:    rts

usage:  lea     usagestr(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        rts

outofmem:
        lea     msg_nomem(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_ERROR,d0
        bra     setrc

;----------------------------------------------------------------------
; faultmsg: a0 = prefix, a1 = path, d0 = fault code. Prints
; "<prefix><path>: <fault>\n". Preserves d3-d7/a2-a6.
;----------------------------------------------------------------------
faultmsg:
        movem.l d3/a2-a3,-(sp)
        move.l  d0,d3
        move.l  a1,a3
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a3,d1
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d3,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)
        movem.l (sp)+,d3/a2-a3
        rts

; checkbreak: latch brkflag if Ctrl-C was pressed
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

; setrc: d7 = max(d7, d0)
setrc:  cmp.l   d7,d0
        ble.s   .r
        move.l  d0,d7
.r:     rts

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

; xalloc: d0 = size -> d0 = cleared memory or 0. Saves a6 on the stack,
; NOT in a5 -- copydir keeps its entry-list walker in a5 across the
; queuedir/copyfileent calls that alloc, so a5 must survive.
xalloc: move.l  a6,-(sp)
        move.l  4.w,a6
        move.l  #MEMF_CLEAR,d1
        jsr     _LVOAllocMem(a6)
        move.l  (sp)+,a6
        rts

; xfree: a1 = ptr, d0 = size
xfree:  move.l  a6,-(sp)
        move.l  4.w,a6
        jsr     _LVOFreeMem(a6)
        move.l  (sp)+,a6
        rts

;----------------------------------------------------------------------
; centralised cleanup
;----------------------------------------------------------------------
exit:   move.l  gbuf,d0                 ; free the copy buffer
        beq.s   .nobuf
        move.l  d0,a1
        move.l  #BUFSIZE,d0
        bsr     xfree
.nobuf:                                 ; free any leftover work-list nodes
.qf:    move.l  pendhead,d0
        beq.s   .qd
        move.l  d0,a1
        move.l  dn_next(a1),pendhead
        move.l  #DN_SIZEOF,d0
        bsr     xfree
        bra.s   .qf
.qd:    move.l  npaths,d6              ; free the parsed path strings
        bra.s   .pin
.pf:    move.l  d6,d0
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),a1
        move.l  #PATHLEN,d0
        bsr     xfree
.pin:   dbra    d6,.pf

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
        jsr     _LVOForbid(a6)
        move.l  d0,a1
        jsr     _LVOReplyMsg(a6)
.nowb:  move.l  d7,d0
        movem.l (sp)+,d2-d7/a2-a6
        rts

;----------------------------------------------------------------------
; data
;----------------------------------------------------------------------
verstr:      dc.b '$VER: cp 0.1 (20.7.26) asm build',0
dosname:     dc.b 'dos.library',0
pfx:         dc.b 'cp: ',0
colsp:       dc.b ': ',0
nl:          dc.b 10,0
msg_needdir: dc.b 'cp: with several files or a pattern, TO must be an '
             dc.b 'existing directory',10,0
msg_omit1:   dc.b 'cp: omitting directory ',0
msg_omit2:   dc.b ' (use -r)',10,0
msg_same:    dc.b ': source and target are the same file',10,0
msg_ovdir:   dc.b 'cp: cannot overwrite directory ',0
msg_repl:    dc.b 'cp: cannot replace ',0
msg_crea:    dc.b 'cp: cannot create ',0
msg_exam:    dc.b 'cp: cannot examine ',0
msg_notdir2: dc.b ' exists and is not a directory',10,0
msg_skiphdr: dc.b 'not copied:',10,0
msg_skipind: dc.b '  ',0
msg_badflag: dc.b 'cp: unknown option (cp ? for usage)',10,0
msg_nomem:   dc.b 'cp: out of memory',10,0
msg_break:   dc.b '***Break: cp',10,0
msg_usage:   dc.b 'usage: cp [-fr] FROM ... TO',10,0
usagestr:    dc.b 'cp 0.1 -- Unix-style copy',10
             dc.b 'usage: cp [-fr] FROM ... TO',10
             dc.b '  -f  force: replace an existing target file',10
             dc.b '  -r  copy directories recursively',10,0
        even

        section mem,bss

dosbase:   ds.l 1
wbmsg:     ds.l 1
gto:       ds.l 1
npaths:    ds.l 1
nsrc:      ds.l 1
srcidx:    ds.l 1
curspec:   ds.l 1
gbuf:      ds.l 1
pendhead:  ds.l 1
pendtail:  ds.l 1
skiphead:  ds.l 1
skiptail:  ds.l 1
skipcount: ds.l 1
fhin:      ds.l 1
fhout:     ds.l 1
cpsrc:     ds.l 1
cpdst:     ds.l 1
gds:       ds.l 3
pathtab:   ds.l MAXARGS
gfib:      ds.b fib_SIZEOF               ; Examine target; long-aligned
anchor:    ds.b ap_Buf+PATHLEN
gtarget:   ds.b PATHLEN+4
gpatbuf:   ds.b 1032
cs:        ds.b PATHLEN
cd:        ds.b PATHLEN
ecomm:     ds.b 80
cmdbuf:    ds.b 512
tokbuf:    ds.b 512
force:     ds.b 1
recursive: ds.b 1
toisdir:   ds.b 1
brkflag:   ds.b 1
cppartial: ds.b 1
ehave:     ds.b 1
usagefl:   ds.b 1
badflag:   ds.b 1
