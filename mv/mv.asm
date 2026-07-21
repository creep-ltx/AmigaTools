;----------------------------------------------------------------------
; mv.asm -- Unix-style move for AmigaDOS, 68000 assembly.
; usage: mv [-fb] FROM ... TO
;
; Same behaviour as mv.e (see that file for the full design notes):
;   - Rename() first, per file: on AmigaDOS that's already a full move
;     anywhere on the same volume, files and directories alike.
;   - ERROR_RENAME_ACROSS_DEVICES -> copy + delete fallback, keeping
;     protection bits and datestamp. Directories are refused there.
;   - FROM takes multiple names and/or AmigaDOS patterns (MatchFirst/
;     MatchNext); with several files or a pattern, TO must be an
;     existing directory.
;   - Flags are bundled Unix-style (-f, -b, -fb); the last path is TO,
;     everything before it a source. Existing targets are skipped by
;     default; everything not moved is listed at the end (return code
;     5). -f deletes and replaces the target; -b renames it to
;     <name>.mvbak first and refuses the file if that name is taken
;     (rc 10) -- unless -f is also given, which sanctions replacing the
;     stale .mvbak. All of it guarded by proving the source exists and
;     is a different object (SameLock), so a self-move can never delete
;     the only copy.
;   - Ctrl-C is honoured between files and between copy chunks; a
;     break or failed copy removes the partial target file.
;   - Per-file errors are reported and the batch continues. Return
;     code: 0 clean, 5 skips, 10 errors, 20 break.
;
; Assemble:  vasmm68k_mot -Fhunkexe -nosym -o mv-asm mv.asm
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
MAXARGS = 32
MEMF_CLEAR = $10000

; the matched source path and its FileInfoBlock live inside the anchor
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

; --- parse the command line: bundled -f/-b flags, the last path is
; --- TO, everything before it a source
        bsr     parseargs
        tst.b   usagefl                 ; `mv ?`: usage printed, rc 0
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

; --- is TO an existing directory?
        move.l  gto,d1
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

; --- detect wildcards among the sources; with several files or a
; --- pattern, TO must be that existing directory
        moveq   #0,d6                   ; wild
        moveq   #0,d4                   ; source index
.cnt:   cmp.l   nsrc,d4
        bge.s   .cdone
        move.l  d4,d0
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),d1
        move.l  #patbuf,d2
        move.l  #1024,d3
        jsr     _LVOParsePatternNoCase(a6)
        tst.l   d0                      ; jsr leaves stale flags!
        ble.s   .cnext
        moveq   #1,d6
.cnext: addq.l  #1,d4
        bra.s   .cnt
.cdone: tst.l   d6
        bne.s   .ismulti
        cmp.l   #1,nsrc
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

; --- run every source (pathtab[0..nsrc-1]); srcidx lives in memory
; --- so it survives dosource/moveone
.single:
        clr.l   srcidx
srcloop:
        move.l  srcidx,d0
        cmp.l   nsrc,d0
        bge.s   alldone
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),curspec
        addq.l  #1,srcidx
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
        move.l  gto,a0                  ; rebuild target: TO ...
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
        beq     .same
        tst.l   d5
        beq.s   .notdir                 ; Examine failed: treat as file
        tst.l   gfib+fib_DirEntryType
        bgt     .ovdir
.notdir:
        tst.b   backup                  ; -b given?
        bne.s   .dobak
        tst.b   force                   ; -f given?
        bne.s   .dodel
        lea     srcpath,a3              ; neither: record the skip
        bra     addskip
.dodel: move.l  #gtarget,d1
        jsr     _LVODeleteFile(a6)
        tst.l   d0
        bne     .rename
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     gtarget,a3
        bra     replfault

.dobak: lea     gtarget,a0              ; gbak = gtarget + '.mvbak'
        lea     gbak,a1
.bk1:   move.b  (a0)+,(a1)+
        bne.s   .bk1
        lea     -1(a1),a1
        move.b  #'.',(a1)+
        move.b  #'m',(a1)+
        move.b  #'v',(a1)+
        move.b  #'b',(a1)+
        move.b  #'a',(a1)+
        move.b  #'k',(a1)+
        clr.b   (a1)
        move.l  #gbak,d1                ; is the backup name taken?
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        tst.l   d0
        beq.s   .bakfree
        move.l  d0,d1
        jsr     _LVOUnLock(a6)
        tst.b   force                   ; -bf: sanctioned to replace
        beq.s   .bakclash               ; a stale .mvbak
        move.l  #gbak,d1
        jsr     _LVODeleteFile(a6)
        tst.l   d0
        bne.s   .bakfree
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     gbak,a3
        bra     replfault
.bakclash:                              ; refuse: nothing touched,
        lea     pfx(pc),a0              ; reported now + listed at end
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #srcpath,d1
        jsr     _LVOPutStr(a6)
        lea     msg_bak1(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  #gbak,d1
        jsr     _LVOPutStr(a6)
        lea     msg_bak2(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        lea     srcpath,a3
        bsr     addskip
        moveq   #RETURN_ERROR,d0
        bra     setrc
.bakfree:
        move.l  #gtarget,d1
        move.l  #gbak,d2
        jsr     _LVORename(a6)
        tst.l   d0
        bne     .rename                 ; backed up: proceed with move
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        lea     msg_cbak(pc),a0
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

; replfault: print "mv: cannot replace <a3>: <fault text for d5>",
; raise rc to ERROR
replfault:
        lea     msg_repl(pc),a0
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
        bra.s   setrc

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
; parseargs: tokenize cmdbuf (whitespace-separated, double quotes
; group, `*` escapes inside quotes -- AmigaDOS rules). `-x` bundles
; set flags, a lone `?` prints usage, the rest fill pathtab.
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

        lea     tokbuf,a0               ; classify the token
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

; setflags: apply a "-xy" bundle from tokbuf; unknown -> badflag
setflags:
        lea     tokbuf+1,a0
.fl:    move.b  (a0)+,d0
        beq.s   .fr
        cmp.b   #'f',d0
        bne.s   .f1
        st      force
        bra.s   .fl
.f1:    cmp.b   #'b',d0
        bne.s   .f2
        st      backup
        bra.s   .fl
.f2:    st      badflag
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
.nobuf:                                 ; free the parsed path strings
        move.l  npaths,d6
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

verstr:      dc.b '$VER: mv 0.4 (20.7.26) asm build',0
dosname:     dc.b 'dos.library',0
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
msg_skiphdr: dc.b 'not moved:',10,0
msg_skipf:   dc.b ': not moved',10,0
msg_bak1:    dc.b ': not moved, ',0
msg_bak2:    dc.b ' already exists',10,0
msg_cbak:    dc.b 'mv: cannot back up ',0
msg_break:   dc.b '***Break: mv',10,0
msg_badflag: dc.b 'mv: unknown option (mv ? for usage)',10,0
msg_nomem:   dc.b 'mv: out of memory',10,0
msg_usage:   dc.b 'usage: mv [-fb] FROM ... TO',10,0
usagestr:    dc.b 'mv 0.4 -- Unix-style move',10
             dc.b 'usage: mv [-fb] FROM ... TO',10
             dc.b '  -f  force: replace an existing target',10
             dc.b '  -b  back up an existing target as <name>.mvbak first',10,0
        even

        section mem,bss

dosbase:  ds.l 1
wbmsg:    ds.l 1
bufptr:   ds.l 1
fhin:     ds.l 1
fhout:    ds.l 1
curspec:  ds.l 1
skiphead: ds.l 1
skiptail: ds.l 1
npaths:   ds.l 1
nsrc:     ds.l 1
gto:      ds.l 1
srcidx:   ds.l 1
pathtab:  ds.l MAXARGS
gfib:     ds.b fib_SIZEOF               ; Examine() needs long alignment;
anchor:   ds.b 280+PATHLEN              ; all-ds.l above guarantees it,
gtarget:  ds.b PATHLEN+4                ; and every ds.b size is a
gbak:     ds.b PATHLEN+12               ; long multiple down to here
patbuf:   ds.b 1024
cmdbuf:   ds.b 512
tokbuf:   ds.b 512
toisdir:  ds.b 1
force:    ds.b 1
backup:   ds.b 1
brkflag:  ds.b 1
usagefl:  ds.b 1
badflag:  ds.b 1
