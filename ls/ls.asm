;----------------------------------------------------------------------
; ls.asm -- Unix-style directory lister for AmigaDOS, 68000 assembly.
; Usage: ls [-1ahlrRSt] [path | pattern ...]
;
; Same behaviour as ls.e (see that file for the full design notes):
;   - hand-parsed Unix flag bundles (`ls -lah work:`), `ls ?` answers
;     with usage anyway.
;   - -a reveals .info files and h-bit entries, hidden by default.
;   - -l prints hsparwed, size, DOS datestamp, filenote on a
;     continuation line, and a leading `total <blocks>` for dirs.
;   - -h shows sizes tiered bytes/K/M/G. All the tier math is shifts:
;     the 68000's DIVU has a 16-bit quotient and divisor, so general
;     division is avoided everywhere except the two column counts,
;     whose operands are provably small.
;   - multi-column output sized by the console: CSI `0 q` bounds
;     request, `CSI 1;1;rows;cols r` report read back in raw mode
;     (the same exchange C:Dir uses). Non-interactive output falls
;     back to one entry per line; colors only when interactive.
;   - a pattern argument lists the matches themselves (MatchFirst/
;     MatchNext); a plain directory argument lists its contents.
;   - -t newest first, -S largest first, -r reverses, -R recurses
;     depth-first with `path:` group headers.
;   - Ctrl-C honoured between entries and rows. Return code:
;     0 clean, 5 a path could not be accessed, 10 bad args, 20 break.
;
; Assemble:  vasmm68k_mot -Fhunkexe -nosym -o ls-asm ls.asm
;
; Register conventions: a6 = dos.library base throughout, d7 = worst
; return code so far (setrc keeps the max), a3 = line-buffer append
; cursor inside the output builders. Library calls only trash
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
_LVORead          = -42
_LVOWrite         = -48
_LVOInput         = -54
_LVOOutput        = -60
_LVOLock          = -84
_LVOUnLock        = -90
_LVOExamine       = -102
_LVOExNext        = -108
_LVOIoErr         = -132
_LVOWaitForChar   = -204
_LVOIsInteractive = -216
_LVOSetMode       = -426
_LVOPrintFault    = -474
_LVODateToStr     = -744
_LVOMatchFirst    = -822
_LVOMatchNext     = -828
_LVOMatchEnd      = -834
_LVOAddPart       = -882
_LVOPutStr        = -948
_LVOParsePatternNoCase = -966

; dos constants
ACCESS_READ  = -2
ERROR_NO_MORE_ENTRIES = 232
SIGBREAKF_CTRL_C = $1000
RETURN_OK    = 0
RETURN_WARN  = 5
RETURN_ERROR = 10
RETURN_FAIL  = 20
FORMAT_DOS   = 0
MEMF_CLEAR   = $10000

; struct offsets (verified against amitools' struct definitions)
pr_MsgPort       = 92
pr_CLI           = 172
fib_DirEntryType = 4
fib_FileName     = 8
fib_Protection   = 116
fib_Size         = 124
fib_NumBlocks    = 128
fib_Date         = 132
fib_Comment      = 144
fib_SIZEOF       = 260
dat_Stamp        = 0
dat_Format       = 12
dat_Flags        = 13
dat_StrDay       = 14
dat_StrDate      = 18
dat_StrTime      = 22
ap_Strlen        = 18
ap_Info          = 20
ap_Buf           = 280

; sort orders
SORT_NAME = 0
SORT_TIME = 1
SORT_SIZE = 2

; entry record, one per listed file/dir (AllocMem'd, MEMF_CLEAR)
ent_next   = 0
ent_size   = 4
ent_blocks = 8
ent_prot   = 12
ent_days   = 16
ent_min    = 20
ent_tick   = 24
ent_isdir  = 28
ent_name   = 32                         ; 110 bytes
ent_comm   = 142                        ; 80 bytes
ENT_SIZEOF = 224

; -R pending-directory node
pn_next   = 0
pn_path   = 4
PN_SIZEOF = 516

PATHLEN = 512
NAMELEN = 110
MAXARGS = 32

; the matched path and its FileInfoBlock live inside the anchor
mpath = anchor+ap_Buf
mfib  = anchor+ap_Info

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
        jsr     _LVOOutput(a6)
        move.l  d0,outfh
        jsr     _LVOInput(a6)
        move.l  d0,infh
        move.l  #77,twidth              ; fallback console width

        bsr     parseargs
        tst.b   usagefl                 ; `ls ?`: usage printed, rc 0
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

; --- interactive? both ends must be a console for probe and colors
        move.l  outfh,d1
        jsr     _LVOIsInteractive(a6)
        move.l  d0,d2
        move.l  infh,d1
        jsr     _LVOIsInteractive(a6)
        and.l   d2,d0
        beq.s   .notint
        st      tinter
        bra.s   .intdone
.notint:
        st      f_one                   ; piped/redirected: one per line
.intdone:
        tst.b   tinter
        beq.s   .nowidth
        tst.b   f_long
        bne.s   .nowidth
        tst.b   f_one
        bne.s   .nowidth
        bsr     termwidth
.nowidth:

; --- headers when recursing or with several arguments
        tst.b   f_rec
        bne.s   .hdr
        cmp.l   #2,npaths
        blt.s   .nohdr
.hdr:   st      headers
.nohdr:

; --- run every path argument (none = current dir)
        tst.l   npaths
        bne.s   .haveargs
        lea     nullstr(pc),a0
        move.l  a0,a2
        bsr     listpath
        bra.s   .drain
.haveargs:
        moveq   #0,d6                   ; index
.argloop:
        cmp.l   npaths,d6
        bge.s   .drain
        lea     pathtab,a0
        move.l  d6,d0
        lsl.l   #2,d0
        move.l  0(a0,d0.l),a2
        move.l  d6,-(sp)                ; listpath's callees use d6
        bsr     listpath
        move.l  (sp)+,d6
        tst.b   brkflag
        bne.s   .brkout
        addq.l  #1,d6
        bra.s   .argloop

; --- drain the -R pending queue (depth-first: groups are prepended)
.drain: move.l  pendhead,d0
        beq.s   alldone
        bsr     checkbreak
        tst.b   brkflag
        bne.s   .brkout
        move.l  pendhead,a2
        move.l  pn_next(a2),pendhead
        move.l  a2,-(sp)
        lea     pn_path(a2),a2
        bsr     listdir
        move.l  (sp)+,a1
        move.l  #PN_SIZEOF,d0
        bsr     xfree
        tst.b   brkflag
        beq.s   .drain
.brkout:
        lea     msg_break(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_FAIL,d0
        bsr     setrc
alldone:
finish: bra     exit

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
        cmp.b   #'l',d0
        bne.s   .f1
        st      f_long
        bra.s   .fl
.f1:    cmp.b   #'a',d0
        bne.s   .f2
        st      f_all
        bra.s   .fl
.f2:    cmp.b   #'h',d0
        bne.s   .f3
        st      f_hum
        bra.s   .fl
.f3:    cmp.b   #'t',d0
        bne.s   .f4
        move.b  #SORT_TIME,sortby
        bra.s   .fl
.f4:    cmp.b   #'S',d0
        bne.s   .f5
        move.b  #SORT_SIZE,sortby
        bra.s   .fl
.f5:    cmp.b   #'r',d0
        bne.s   .f6
        st      f_rev
        bra.s   .fl
.f6:    cmp.b   #'R',d0
        bne.s   .f7
        st      f_rec
        bra.s   .fl
.f7:    cmp.b   #'1',d0
        bne.s   .f8
        st      f_one
        bra.s   .fl
.f8:    st      badflag
.fr:    rts

usage:  lea     usagestr(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        rts

;----------------------------------------------------------------------
; termwidth: ask the console for its size. Raw mode, write CSI `0 q`,
; parse the `CSI 1;1;rows;cols r` report back (params until the first
; byte >= $40 -- the CSI rule). Every read is guarded by WaitForChar
; so a console that never answers costs 0.5s, not a hang.
;----------------------------------------------------------------------
termwidth:
        movem.l d2-d4,-(sp)
        move.l  infh,d1
        moveq   #1,d2
        jsr     _LVOSetMode(a6)
        move.l  outfh,d1
        lea     csireq(pc),a0
        move.l  a0,d2
        moveq   #4,d3
        jsr     _LVOWrite(a6)
        lea     params,a0               ; clear the parameter slots
        moveq   #0,d0
        move.l  d0,(a0)+
        move.l  d0,(a0)+
        move.l  d0,(a0)+
        move.l  d0,(a0)
        moveq   #0,d4                   ; parameter index
        move.l  infh,d1
        move.l  #500000,d2
        jsr     _LVOWaitForChar(a6)
        tst.l   d0
        beq     .out
.rd:    move.l  infh,d1
        move.l  #bytebuf,d2
        moveq   #1,d3
        jsr     _LVORead(a6)
        cmp.l   #1,d0
        bne.s   .out
        moveq   #0,d3
        move.b  bytebuf,d3
        cmp.w   #$9b,d3                 ; report start: reset
        bne.s   .n1
        moveq   #0,d4
        bra.s   .more
.n1:    cmp.w   #'0',d3
        blo.s   .n2
        cmp.w   #'9',d3
        bhi.s   .n2
        cmp.w   #8,d4                   ; digit: param = param*10 + d
        bge.s   .more
        lea     params,a0
        move.w  d4,d0
        add.w   d0,d0
        move.w  0(a0,d0.w),d1
        mulu    #10,d1
        sub.w   #'0',d3
        add.w   d3,d1
        move.w  d1,0(a0,d0.w)
        bra.s   .more
.n2:    cmp.w   #';',d3
        bne.s   .n3
        addq.w  #1,d4
        bra.s   .more
.n3:    cmp.w   #$40,d3                 ; final byte ends the report
        blo.s   .more
        addq.w  #1,d4
        bra.s   .out
.more:  move.l  infh,d1
        move.l  #250000,d2
        jsr     _LVOWaitForChar(a6)
        tst.l   d0
        bne     .rd
.out:   move.l  infh,d1
        moveq   #0,d2
        jsr     _LVOSetMode(a6)
        cmp.w   #4,d4                   ; params[3] = columns
        blt.s   .r
        moveq   #0,d0
        move.w  params+6,d0
        beq.s   .r
        cmp.l   #600,d0                 ; sanity clamp: linebuf is finite
        ble.s   .set
        move.l  #600,d0
.set:   move.l  d0,twidth
.r:     movem.l (sp)+,d2-d4
        rts

;----------------------------------------------------------------------
; listpath: one command-line argument (a2). A pattern lists its
; matches, a plain directory lists its contents, a file lists itself.
;----------------------------------------------------------------------
listpath:
        move.l  a2,d1
        move.l  #patbuf,d2
        move.l  #1024,d3
        jsr     _LVOParsePatternNoCase(a6)
        tst.l   d0                      ; jsr leaves stale flags!
        bgt     listmatches             ; 1 = wildcards present
        move.l  a2,d1                   ; 0 plain, -1 err (Lock reports)
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d6
        bne.s   .locked
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        move.l  a2,a0
        bra     faultacc
.locked:
        move.l  d6,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        bne.s   .exok
        move.l  d6,d1
        jsr     _LVOUnLock(a6)
        move.l  a2,a0
        bra     faultexam
.exok:  move.l  d6,d1
        jsr     _LVOUnLock(a6)
        tst.l   gfib+fib_DirEntryType
        bgt     listdir
        ; fall through: a plain file, gfib still holds its Examine

;----------------------------------------------------------------------
; listsingle: one entry from gfib, shown under the name it was typed
; as (a2). No total line.
;----------------------------------------------------------------------
listsingle:
        clr.l   lhead
        clr.l   lcount
        lea     gfib,a0
        bsr     mkent
        tst.l   d0
        beq.s   .r
        move.l  d0,a1
        lea     ent_name(a1),a1
        move.l  a2,a0
        move.l  #NAMELEN,d0
        bsr     strcpyc
        moveq   #0,d4                   ; not a dir listing
        sub.l   a4,a4
        bsr     sortout
.r:     bra     freelist

;----------------------------------------------------------------------
; listdir: scan directory a2 into the entry list, print it, and with
; -R queue its subdirectories (prepended in display order).
;----------------------------------------------------------------------
listdir:
        movem.l d6/a4,-(sp)
        move.l  a2,a4                   ; the path, kept for AddPart
        clr.l   lhead
        clr.l   lcount
        move.l  a2,d1
        moveq   #ACCESS_READ,d2
        jsr     _LVOLock(a6)
        move.l  d0,d6
        bne.s   .locked
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        move.l  a2,a0
        bsr     faultacc
        bra     .out
.locked:
        move.l  d6,d1
        move.l  #gfib,d2
        jsr     _LVOExamine(a6)
        tst.l   d0
        bne.s   .exok
        move.l  d6,d1
        jsr     _LVOUnLock(a6)
        move.l  a2,a0
        bsr     faultexam
        bra     .out
.exok:
        lea     gfib+fib_FileName,a0    ; the dir's own name, copied out:
        lea     dnamebuf,a1             ; every ExNext reuses gfib
        move.l  #NAMELEN,d0
        bsr     strcpyc

.scan:  bsr     checkbreak
        tst.b   brkflag
        bne.s   .scandone
        move.l  d6,d1
        move.l  #gfib,d2
        jsr     _LVOExNext(a6)
        tst.l   d0
        beq.s   .scandone
        bsr     keepentry
        tst.l   d0
        beq.s   .scan
        lea     gfib,a0
        bsr     mkent
        tst.l   d0
        bne.s   .scan
        bra     .scandone               ; out of memory: stop scanning
.scandone:
        jsr     _LVOIoErr(a6)
        move.l  d0,d5
        move.l  d6,d1
        jsr     _LVOUnLock(a6)
        tst.b   brkflag
        bne.s   .nofault
        cmp.l   #ERROR_NO_MORE_ENTRIES,d5
        beq.s   .nofault
        bsr     dispname
        bsr     faultfor
.nofault:
        tst.b   brkflag
        bne.s   .cleanup

; header: blank line between groups, then "path:"
        tst.b   headers
        beq.s   .nohdr
        tst.b   notfirst
        beq.s   .h1
        lea     nl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
.h1:    bsr     dispname
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        lea     colnl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        st      notfirst
.nohdr:
        moveq   #1,d4                   ; a dir listing (total, -R)
        bsr     sortout
.cleanup:
        bsr     freelist
.out:   movem.l (sp)+,d6/a4
        rts

; dispname: a0 = name to show for the current dir (a4 or its label)
dispname:
        move.l  a4,a0
        tst.b   (a0)
        bne.s   .r
        lea     dnamebuf,a0
.r:     rts

;----------------------------------------------------------------------
; listmatches: pattern argument a2 through MatchFirst/MatchNext;
; matches listed as entries themselves (the ls -d simplification).
;----------------------------------------------------------------------
listmatches:
        movem.l d6/a4,-(sp)
        move.l  a2,a4
        clr.l   lhead
        clr.l   lcount
        lea     anchor,a0               ; MatchFirst needs a clean anchor
        move.w  #(ap_Buf+PATHLEN)/4-1,d0
.cl:    clr.l   (a0)+
        dbra    d0,.cl
        move.w  #PATHLEN-1,anchor+ap_Strlen
        move.l  a2,d1
        move.l  #anchor,d2
        jsr     _LVOMatchFirst(a6)
.mloop: tst.l   d0
        bne.s   .mend
        bsr     checkbreak
        tst.b   brkflag
        bne.s   .mfin
        lea     mfib,a0
        bsr     mkent
        beq.s   .mfin                   ; out of memory: stop
        move.l  d0,a1
        lea     ent_name(a1),a1
        lea     mpath,a0
        move.l  #NAMELEN,d0
        bsr     strcpyc
        move.l  #anchor,d1
        jsr     _LVOMatchNext(a6)
        bra.s   .mloop
.mend:  move.l  d0,d5
        cmp.l   #ERROR_NO_MORE_ENTRIES,d5
        beq.s   .mfin
        move.l  a4,a0                   ; report bad spec
        bsr     faultfor
.mfin:  move.l  #anchor,d1
        jsr     _LVOMatchEnd(a6)
        tst.b   brkflag
        bne.s   .done
        tst.l   lcount
        bne.s   .have
        cmp.l   #ERROR_NO_MORE_ENTRIES,d5
        bne.s   .done
        lea     pfx(pc),a0              ; "ls: <spec>: no match"
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  a4,d1
        jsr     _LVOPutStr(a6)
        lea     msg_nomatch(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_WARN,d0
        bsr     setrc
        bra.s   .done
.have:  moveq   #0,d4                   ; not a dir listing
        sub.l   a4,a4
        bsr     sortout
.done:  bsr     freelist
        movem.l (sp)+,d6/a4
        rts

;----------------------------------------------------------------------
; keepentry: d0 nonzero if gfib's entry should be listed.
; -a keeps everything; otherwise the h-bit and *.info are hidden.
;----------------------------------------------------------------------
keepentry:
        tst.b   f_all
        beq.s   .filter
        moveq   #1,d0
        rts
.filter:
        btst    #7,gfib+fib_Protection+3 ; FIBB_HIDDEN
        bne.s   .no
        lea     gfib+fib_FileName,a0
        bsr     strlen
        cmp.l   #6,d0                   ; ".info" needs a stem (E parity)
        blt.s   .yes
        lea     gfib+fib_FileName,a0
        add.l   d0,a0
        moveq   #0,d1                   ; case-blind ".info" suffix
        move.b  -(a0),d1
        bsr     ucase
        cmp.b   #'O',d1
        bne.s   .yes
        move.b  -(a0),d1
        bsr     ucase
        cmp.b   #'F',d1
        bne.s   .yes
        move.b  -(a0),d1
        bsr     ucase
        cmp.b   #'N',d1
        bne.s   .yes
        move.b  -(a0),d1
        bsr     ucase
        cmp.b   #'I',d1
        bne.s   .yes
        move.b  -(a0),d1
        cmp.b   #'.',d1
        beq.s   .no
.yes:   moveq   #1,d0
        rts
.no:    moveq   #0,d0
        rts

; ucase: d1 lowercase ASCII -> uppercase
ucase:  cmp.b   #'a',d1
        blo.s   .r
        cmp.b   #'z',d1
        bhi.s   .r
        sub.b   #32,d1
.r:     rts

;----------------------------------------------------------------------
; mkent: build an entry record from the FIB at a0 and prepend it to
; the list. d0 = the entry, 0 on allocation failure (reported).
;----------------------------------------------------------------------
mkent:  movem.l d2/a2-a3,-(sp)
        move.l  a0,a2
        move.l  #ENT_SIZEOF,d0
        bsr     xalloc
        tst.l   d0
        bne.s   .got
        bsr     outofmem
        bra.s   .r
.got:   move.l  d0,a3
        move.l  fib_Size(a2),ent_size(a3)
        move.l  fib_NumBlocks(a2),ent_blocks(a3)
        move.l  fib_Protection(a2),ent_prot(a3)
        move.l  fib_Date+0(a2),ent_days(a3)
        move.l  fib_Date+4(a2),ent_min(a3)
        move.l  fib_Date+8(a2),ent_tick(a3)
        clr.l   ent_isdir(a3)
        tst.l   fib_DirEntryType(a2)
        ble.s   .file
        move.l  #1,ent_isdir(a3)
.file:  lea     fib_FileName(a2),a0
        lea     ent_name(a3),a1
        move.l  #NAMELEN,d0
        bsr     strcpyc
        lea     fib_Comment(a2),a0
        lea     ent_comm(a3),a1
        moveq   #80,d0
        bsr     strcpyc
        move.l  lhead,ent_next(a3)
        move.l  a3,lhead
        addq.l  #1,lcount
        move.l  a3,d0
.r:     movem.l (sp)+,d2/a2-a3
        tst.l   d0
        rts

;----------------------------------------------------------------------
; sortout: entry list -> sorted array -> output. d4 = dir listing
; (total line, -R recursion), a4 = the dir's path for subdir names.
;----------------------------------------------------------------------
sortout:
        movem.l d2-d6/a2-a3,-(sp)
        move.l  a4,v_path
        move.l  d4,v_isdir
        move.l  lcount,d2
        bne.s   .some
        tst.b   f_long                  ; empty dir, -l: "total 0"
        beq     .r
        tst.l   d4
        beq     .r
        lea     linebuf,a3
        lea     msg_total(pc),a0
        bsr     appstr
        moveq   #0,d0
        bsr     utod
        move.b  #10,(a3)+
        bsr     writeline
        bra     .r
.some:
        move.l  d2,d0
        lsl.l   #2,d0
        bsr     xalloc
        tst.l   d0
        bne.s   .gotarr
        bsr     outofmem
        bra     .r
.gotarr:
        move.l  d0,arrptr
        move.l  d0,a0                   ; fill from the list
        move.l  lhead,d1
.fill:  beq.s   .filled
        move.l  d1,a1
        move.l  a1,(a0)+
        move.l  ent_next(a1),d1
        bra.s   .fill
.filled:
        bsr     sortarr
        bsr     output
        tst.b   brkflag
        bne     .freearr

; -R: queue subdirectories, prepended as a group = depth-first
        tst.b   f_rec
        beq     .freearr
        tst.l   v_isdir
        beq     .freearr
        clr.l   ghead
        clr.l   gtail
        moveq   #0,d3                   ; display order index
.rq:    cmp.l   lcount,d3
        bge.s   .rqdone
        move.l  d3,d0
        bsr     getent
        move.l  a0,a2
        tst.l   ent_isdir(a2)
        beq.s   .rqnext
        move.l  #PN_SIZEOF,d0
        bsr     xalloc
        tst.l   d0
        bne.s   .gotpn
        bsr     outofmem
        bra.s   .rqdone
.gotpn: move.l  d0,a3
        move.l  v_path,a0
        lea     pn_path(a3),a1
        move.l  #PATHLEN,d0
        bsr     strcpyc
        lea     pn_path(a3),a0          ; path + / + name
        move.l  a0,d1
        lea     ent_name(a2),a0
        move.l  a0,d2
        move.l  d3,-(sp)                ; d3 is the loop index
        move.l  #PATHLEN,d3
        jsr     _LVOAddPart(a6)
        move.l  (sp)+,d3
        clr.l   pn_next(a3)
        move.l  ghead,d0
        bne.s   .app
        move.l  a3,ghead
        bra.s   .tl
.app:   move.l  gtail,a0
        move.l  a3,pn_next(a0)
.tl:    move.l  a3,gtail
.rqnext:
        addq.l  #1,d3
        bra.s   .rq
.rqdone:
        move.l  ghead,d0
        beq     .freearr
        move.l  gtail,a0
        move.l  pendhead,pn_next(a0)
        move.l  ghead,pendhead

.freearr:
        move.l  arrptr,a1
        move.l  lcount,d0
        lsl.l   #2,d0
        bsr     xfree
        clr.l   arrptr
.r:     movem.l (sp)+,d2-d6/a2-a3
        rts

; getent: d0 = display index -> a0 = entry (honours -r)
getent: tst.b   f_rev
        beq.s   .fwd
        move.l  lcount,d1
        subq.l  #1,d1
        sub.l   d0,d1
        move.l  d1,d0
.fwd:   lsl.l   #2,d0
        move.l  arrptr,a0
        move.l  0(a0,d0.l),a0
        rts

; freelist: release every entry record
freelist:
        move.l  lhead,d6
.f:     tst.l   d6
        beq.s   .fd
        move.l  d6,a1
        move.l  ent_next(a1),d6
        move.l  #ENT_SIZEOF,d0
        bsr     xfree
        bra.s   .f
.fd:    clr.l   lhead
        clr.l   lcount
        rts

;----------------------------------------------------------------------
; sortarr: shellsort arrptr[lcount] with cmpent. Gap sequence 3x+1.
;----------------------------------------------------------------------
sortarr:
        movem.l d2-d6/a2,-(sp)
        move.l  lcount,d2
        cmp.l   #2,d2
        blt     .r
        move.l  arrptr,a2
        moveq   #1,d3                   ; grow the gap
.grow:  move.l  d3,d0
        add.l   d0,d0
        add.l   d0,d3                   ; gap = gap*3
        addq.l  #1,d3                   ; +1
        cmp.l   d2,d3
        blt.s   .grow
.outer: divu    #3,d3                   ; gap /= 3 (gap < 3n: fits DIVU)
        and.l   #$ffff,d3
        bne.s   .gapok
        moveq   #1,d3
.gapok: move.l  d3,d4                   ; i = gap
.iloop: cmp.l   d2,d4
        bge.s   .idone
        move.l  d4,d0
        lsl.l   #2,d0
        move.l  0(a2,d0.l),d6           ; t = arr[i]
        move.l  d4,d5                   ; j = i
.jloop: cmp.l   d3,d5
        blt.s   .place
        move.l  d5,d0
        sub.l   d3,d0
        lsl.l   #2,d0
        move.l  0(a2,d0.l),a0           ; arr[j-gap]
        move.l  d6,a1                   ; t
        bsr     cmpent
        tst.l   d0
        ble.s   .place
        move.l  d5,d0
        sub.l   d3,d0
        lsl.l   #2,d0
        move.l  0(a2,d0.l),d1
        move.l  d5,d0
        lsl.l   #2,d0
        move.l  d1,0(a2,d0.l)           ; arr[j] = arr[j-gap]
        sub.l   d3,d5
        bra.s   .jloop
.place: move.l  d5,d0
        lsl.l   #2,d0
        move.l  d6,0(a2,d0.l)           ; arr[j] = t
        addq.l  #1,d4
        bra.s   .iloop
.idone: cmp.l   #1,d3
        bne     .outer
.r:     movem.l (sp)+,d2-d6/a2
        rts

;----------------------------------------------------------------------
; cmpent: order entries a0, a1 -> d0 (>0: a0 sorts after a1).
; -t newest first, -S largest first, ties and names case-blind.
; Preserves everything but d0/d1/a0/a1.
;----------------------------------------------------------------------
cmpent: move.b  sortby,d0
        cmp.b   #SORT_TIME,d0
        bne.s   .nsize
        move.l  ent_days(a1),d0
        cmp.l   ent_days(a0),d0
        bhi     .after
        bne     .before
        move.l  ent_min(a1),d0
        cmp.l   ent_min(a0),d0
        bhi     .after
        bne     .before
        move.l  ent_tick(a1),d0
        cmp.l   ent_tick(a0),d0
        bhi     .after
        bne     .before
        bra.s   .names
.nsize: cmp.b   #SORT_SIZE,d0
        bne.s   .names
        move.l  ent_size(a1),d0
        cmp.l   ent_size(a0),d0
        bgt     .after
        blt     .before
.names: ; case-blind name compare decides
        movem.l a0/a1,-(sp)
        lea     ent_name(a0),a0
        lea     ent_name(a1),a1
.cl:    moveq   #0,d0
        move.b  (a0)+,d0
        cmp.b   #'a',d0
        blo.s   .u1
        cmp.b   #'z',d0
        bhi.s   .u1
        sub.b   #32,d0
.u1:    moveq   #0,d1
        move.b  (a1)+,d1
        cmp.b   #'a',d1
        blo.s   .u2
        cmp.b   #'z',d1
        bhi.s   .u2
        sub.b   #32,d1
.u2:    cmp.b   d1,d0
        bne.s   .diff
        tst.b   d0
        bne.s   .cl
        movem.l (sp)+,a0/a1
        moveq   #0,d0
        rts
.diff:  movem.l (sp)+,a0/a1
        bhi     .after2
        moveq   #-1,d0
        rts
.after2:
        moveq   #1,d0
        rts
.after: moveq   #1,d0
        rts
.before:
        moveq   #-1,d0
        rts

;----------------------------------------------------------------------
; output: the sorted array, long or columns. Clears the first-group
; flag: any output means the next header wants its blank line.
;----------------------------------------------------------------------
output: st      notfirst
        tst.b   f_long
        bne.s   .long
        bra     columns
.long:  movem.l d2-d4/a2-a3,-(sp)
        tst.l   v_isdir                 ; "total <blocks>" for dirs
        beq.s   .rows
        moveq   #0,d3
        moveq   #0,d2
.sum:   cmp.l   lcount,d2
        bge.s   .sumd
        move.l  d2,d0
        lsl.l   #2,d0
        move.l  arrptr,a0
        move.l  0(a0,d0.l),a0
        add.l   ent_blocks(a0),d3
        addq.l  #1,d2
        bra.s   .sum
.sumd:  lea     linebuf,a3
        lea     msg_total(pc),a0
        bsr     appstr
        move.l  d3,d0
        bsr     utod
        move.b  #10,(a3)+
        bsr     writeline
.rows:  moveq   #0,d2
.el:    cmp.l   lcount,d2
        bge.s   .done
        bsr     checkbreak
        tst.b   brkflag
        bne.s   .done
        move.l  d2,d0
        bsr     getent
        bsr     longline
        addq.l  #1,d2
        bra.s   .el
.done:  movem.l (sp)+,d2-d4/a2-a3
        rts

;----------------------------------------------------------------------
; columns: multi-column layout, column-major like ls. v_ncols from
; the console width; both divisions have provably 16-bit results.
;----------------------------------------------------------------------
columns:
        movem.l d2-d6/a2-a3,-(sp)
        moveq   #1,d3                   ; maxlen
        moveq   #0,d2
.ml:    cmp.l   lcount,d2
        bge.s   .mld
        move.l  d2,d0
        lsl.l   #2,d0
        move.l  arrptr,a0
        move.l  0(a0,d0.l),a0
        lea     ent_name(a0),a0
        bsr     strlen
        cmp.l   d3,d0
        ble.s   .mnx
        move.l  d0,d3
.mnx:   addq.l  #1,d2
        bra.s   .ml
.mld:   addq.l  #2,d3
        move.l  d3,v_colw
        moveq   #1,d4                   ; ncols
        tst.b   f_one
        bne.s   .onecol
        move.l  twidth,d0
        divu    d3,d0                   ; twidth<=600: quotient fits
        and.l   #$ffff,d0
        move.l  d0,d4
        bne.s   .clamp
        moveq   #1,d4
.clamp: cmp.l   #32,d4                  ; linebuf must hold ncols color
        ble.s   .onecol                 ; escapes too
        moveq   #32,d4
.onecol:
        move.l  d4,v_ncols
        move.l  lcount,d0
        add.l   d4,d0
        subq.l  #1,d0
        divu    d4,d0                   ; nrows = (count+ncols-1)/ncols
        and.l   #$ffff,d0
        move.l  d0,v_nrows

        moveq   #0,d5                   ; r
.rloop: cmp.l   v_nrows,d5
        bge     .done
        bsr     checkbreak
        tst.b   brkflag
        bne     .done
        lea     linebuf,a3
        moveq   #0,d6                   ; c
.cloop: cmp.l   v_ncols,d6
        bge.s   .rowout
        move.l  v_nrows,d0
        mulu    d6,d0                   ; idx = c*nrows + r
        add.l   d5,d0
        cmp.l   lcount,d0
        bge.s   .cnext
        bsr     getent
        move.l  a0,a2
        bsr     appname
        ; pad to the column edge if another entry follows in this row
        move.l  v_ncols,d0
        subq.l  #1,d0
        cmp.l   d0,d6
        bge.s   .cnext
        move.l  v_nrows,d0
        move.l  d6,d1
        addq.l  #1,d1
        mulu    d1,d0
        add.l   d5,d0
        cmp.l   lcount,d0
        bge.s   .cnext
        lea     ent_name(a2),a0
        bsr     strlen
.pad:   cmp.l   v_colw,d0
        bge.s   .cnext
        move.b  #' ',(a3)+
        addq.l  #1,d0
        bra.s   .pad
.cnext: addq.l  #1,d6
        bra.s   .cloop
.rowout:
        move.b  #10,(a3)+
        bsr     writeline
        addq.l  #1,d5
        bra     .rloop
.done:  movem.l (sp)+,d2-d6/a2-a3
        rts

; appname: entry a2's name at (a3)+, wrapped in color when it's a
; directory on an interactive console
appname:
        tst.b   tinter
        beq.s   .plain
        tst.l   ent_isdir(a2)
        beq.s   .plain
        lea     seqon(pc),a0
        bsr     appstr
        lea     ent_name(a2),a0
        bsr     appstr
        lea     seqoff(pc),a0
        bra     appstr
.plain: lea     ent_name(a2),a0
        bra     appstr

;----------------------------------------------------------------------
; longline: one -l row for entry a0: hsparwed, size (or Dir), date,
; time, name, and the filenote on a continuation line.
;----------------------------------------------------------------------
longline:
        movem.l d2-d4/a2-a3,-(sp)
        move.l  a0,a2
        lea     linebuf,a3

        move.l  ent_prot(a2),d2         ; hsparwed: h/s/p/a lit when
        lea     prottab(pc),a0          ; SET, r/w/e/d lit when CLEAR
        moveq   #7,d3
.pb:    move.b  (a0)+,d0                ; bit number
        move.b  (a0)+,d1                ; letter
        move.b  (a0)+,d4                ; 1 = set means lit
        btst    d0,d2
        beq.s   .clr
        tst.b   d4
        bne.s   .lit
        bra.s   .dash
.clr:   tst.b   d4
        bne.s   .dash
.lit:   move.b  d1,(a3)+
        bra.s   .pn
.dash:  move.b  #'-',(a3)+
.pn:    dbra    d3,.pb
        move.b  #' ',(a3)+

        ; size column, right-aligned: bytes(10) or human(6); Dir
        move.l  a3,-(sp)                ; build the field in numbuf
        lea     numbuf,a3
        tst.l   ent_isdir(a2)
        beq.s   .fsz
        lea     str_dir(pc),a0
        bsr     appstr
        bra.s   .szdone
.fsz:   move.l  ent_size(a2),d0
        bsr     fmtsize
.szdone:
        clr.b   (a3)
        move.l  (sp)+,a3
        lea     numbuf,a0
        bsr     strlen
        moveq   #10,d1
        tst.b   f_hum
        beq.s   .wd
        moveq   #6,d1
.wd:    sub.l   d0,d1
        ble.s   .nopad
.sp:    move.b  #' ',(a3)+
        subq.l  #1,d1
        bne.s   .sp
.nopad: lea     numbuf,a0
        bsr     appstr
        move.b  #' ',(a3)+

        ; datestamp via DateToStr
        lea     dtime,a0
        move.l  ent_days(a2),dat_Stamp+0(a0)
        move.l  ent_min(a2),dat_Stamp+4(a0)
        move.l  ent_tick(a2),dat_Stamp+8(a0)
        move.b  #FORMAT_DOS,dat_Format(a0)
        clr.b   dat_Flags(a0)
        clr.l   dat_StrDay(a0)
        move.l  #datebuf,dat_StrDate(a0)
        move.l  #timebuf,dat_StrTime(a0)
        move.l  a0,d1
        jsr     _LVODateToStr(a6)
        tst.l   d0
        beq.s   .baddate
        lea     datebuf,a0
        bsr     appstr
        move.b  #' ',(a3)+
        lea     timebuf,a0
        bsr     appstr
        bra.s   .dated
.baddate:
        lea     dashes(pc),a0
        bsr     appstr
.dated: move.b  #' ',(a3)+

        bsr     appname
        move.b  #10,(a3)+
        tst.b   ent_comm(a2)            ; filenote: ": <comment>"
        beq.s   .write
        move.b  #':',(a3)+
        move.b  #' ',(a3)+
        lea     ent_comm(a2),a0
        bsr     appstr
        move.b  #10,(a3)+
.write: bsr     writeline
        movem.l (sp)+,d2-d4/a2-a3
        rts

;----------------------------------------------------------------------
; fmtsize: d0 = byte size, appended at (a3)+. Human tiers use shifts
; only -- DIVU's quotient AND divisor are 16-bit, and E's Mod() with
; a >64K divisor took a CPU exception for the same reason. Remainder
; is v - (units << n); tenths one small mulu plus a shift.
;----------------------------------------------------------------------
fmtsize:
        movem.l d2-d4,-(sp)
        tst.b   f_hum
        beq     .bytes
        cmp.l   #1024,d0
        blo     .bytes
        move.l  d0,d2
        cmp.l   #10240,d0
        bhs.s   .kbig
        moveq   #10,d3                  ; x.yK
        moveq   #'K',d4
        bra.s   .frac
.kbig:  cmp.l   #1048576,d0
        bhs.s   .meg
        moveq   #10,d1                  ; whole K
        lsr.l   d1,d0
        bsr     utod
        move.b  #'K',(a3)+
        bra.s   .r
.meg:   cmp.l   #10485760,d0
        bhs.s   .mbig
        moveq   #20,d3                  ; x.yM
        moveq   #'M',d4
        bra.s   .frac
.mbig:  cmp.l   #$40000000,d0
        bhs.s   .gig
        moveq   #20,d1                  ; whole M
        lsr.l   d1,d0
        bsr     utod
        move.b  #'M',(a3)+
        bra.s   .r
.gig:   moveq   #30,d3                  ; x.yG
        moveq   #'G',d4
.frac:  ; units = v>>d3, tenths = ((v - units<<d3) >> (d3-10)) *10 >>10
        move.l  d2,d0
        move.l  d3,d1
        lsr.l   d1,d0                   ; units
        bsr     utod
        move.b  #'.',(a3)+
        move.l  d2,d0
        move.l  d2,d1
        move.l  d3,d2
        lsr.l   d2,d1
        lsl.l   d2,d1
        sub.l   d1,d0                   ; remainder below the unit
        sub.l   #10,d2
        beq.s   .noshift
        move.l  d2,d1
        lsr.l   d1,d0                   ; scale into 0..1023
.noshift:
        mulu    #10,d0
        moveq   #10,d1
        lsr.l   d1,d0                   ; tenths 0..9
        add.b   #'0',d0
        move.b  d0,(a3)+
        move.b  d4,(a3)+
        bra.s   .r
.bytes: bsr     utod
.r:     movem.l (sp)+,d2-d4
        rts

;----------------------------------------------------------------------
; utod: d0 unsigned 32-bit -> decimal ASCII at (a3)+ (no NUL).
; Powers-of-ten subtraction: no DIVU anywhere near a 32-bit value.
;----------------------------------------------------------------------
utod:   movem.l d2-d3/a0,-(sp)
        lea     pow10(pc),a0
        moveq   #0,d2                   ; started flag
.pl:    move.l  (a0)+,d1
        beq.s   .done
        cmp.l   #1,d1
        beq.s   .last
        moveq   #'0'-1,d3
.sub:   addq.w  #1,d3
        sub.l   d1,d0
        bcc.s   .sub
        add.l   d1,d0
        cmp.w   #'0',d3
        bne.s   .emit
        tst.w   d2
        beq.s   .pl                     ; skip leading zeros
.emit:  move.b  d3,(a3)+
        moveq   #1,d2
        bra.s   .pl
.last:  add.w   #'0',d0
        move.b  d0,(a3)+
.done:  movem.l (sp)+,d2-d3/a0
        rts

;----------------------------------------------------------------------
; small string helpers
;----------------------------------------------------------------------
; strlen: a0 -> d0 (a0 preserved)
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

; appstr: NUL-string a0 appended at (a3)+
appstr: move.b  (a0)+,(a3)+
        bne.s   appstr
        subq.l  #1,a3                   ; drop the NUL
        rts

; writeline: flush linebuf..a3 via PutStr -- ALL user-visible output
; goes through dos' buffered layer (PutStr/PrintFault), so rows and
; error messages can never interleave out of order
writeline:
        clr.b   (a3)
        move.l  #linebuf,d1
        jsr     _LVOPutStr(a6)
        rts

;----------------------------------------------------------------------
; memory via exec, dos base juggled through a5 (the mv pattern)
;----------------------------------------------------------------------
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
; faults: "ls: [cannot access ]<a0>: <fault d5>", rc = warn.
; setrc: d7 = max(d7, d0)
;----------------------------------------------------------------------
faultacc:
        move.l  a0,-(sp)
        lea     msg_acc(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  (sp)+,d1
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_WARN,d0
        bra.s   setrc

faultexam:
        move.l  a0,-(sp)
        lea     msg_exam(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  (sp)+,d1
        jsr     _LVOPutStr(a6)
        lea     nl(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        moveq   #RETURN_WARN,d0
        bra.s   setrc

faultfor:
        move.l  a0,-(sp)
        lea     pfx(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  (sp)+,d1
        jsr     _LVOPutStr(a6)
        lea     colsp(pc),a0
        move.l  a0,d1
        jsr     _LVOPutStr(a6)
        move.l  d5,d1
        moveq   #0,d2
        jsr     _LVOPrintFault(a6)
        moveq   #RETURN_WARN,d0
        ; falls through into setrc
setrc:  cmp.l   d7,d0
        ble.s   .r
        move.l  d0,d7
.r:     rts

;----------------------------------------------------------------------
; centralised cleanup
;----------------------------------------------------------------------
exit:   move.l  npaths,d6               ; path strings
        bra.s   .pin
.pfree: move.l  d6,d0
        lsl.l   #2,d0
        lea     pathtab,a0
        move.l  0(a0,d0.l),a1
        move.l  #PATHLEN,d0
        bsr     xfree
.pin:   dbra    d6,.pfree
        bsr     freelist                ; defensive: normally empty
.qfree: move.l  pendhead,d0             ; unvisited -R directories
        beq.s   .qdone
        move.l  d0,a1
        move.l  pn_next(a1),pendhead
        move.l  #PN_SIZEOF,d0
        bsr     xfree
        bra.s   .qfree
.qdone:

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
verstr:      dc.b '$VER: ls 0.1 (17.7.26) asm build',0
dosname:     dc.b 'dos.library',0
nullstr:     dc.b 0
pfx:         dc.b 'ls: ',0
colsp:       dc.b ': ',0
nl:          dc.b 10,0
colnl:       dc.b ':',10,0
msg_acc:     dc.b 'ls: cannot access ',0
msg_exam:    dc.b 'ls: cannot examine ',0
msg_nomatch: dc.b ': no match',10,0
msg_badflag: dc.b 'ls: unknown option (ls ? for usage)',10,0
msg_nomem:   dc.b 'ls: out of memory',10,0
msg_break:   dc.b '***Break: ls',10,0
msg_total:   dc.b 'total ',0
str_dir:     dc.b 'Dir',0
dashes:      dc.b '------------------',0
seqon:       dc.b $9b,'33m',0
seqoff:      dc.b $9b,'0m',0
csireq:      dc.b $9b,'0 q'
; prottab: bit, letter, 1 = set-means-lit (h/s/p/a), 0 = clear (rwed)
prottab:     dc.b 7,'h',1, 6,'s',1, 5,'p',1, 4,'a',1
             dc.b 3,'r',0, 2,'w',0, 1,'e',0, 0,'d',0
usagestr:    dc.b 'ls 0.1 -- Unix-style directory lister',10
             dc.b 'usage: ls [-1ahlrRSt] [path | pattern ...]',10
             dc.b '  -l  long listing (protection, size, date, filenote)',10
             dc.b '  -a  show .info files and hidden (h-bit) entries',10
             dc.b '  -h  human-readable sizes (K, M, G)',10
             dc.b '  -t  sort by date, newest first',10
             dc.b '  -S  sort by size, largest first',10
             dc.b '  -r  reverse sort order',10
             dc.b '  -R  recurse into directories',10
             dc.b '  -1  one entry per line',10,0
        even
pow10:       dc.l 1000000000,100000000,10000000,1000000
             dc.l 100000,10000,1000,100,10,1,0

        section mem,bss

dosbase:  ds.l 1
wbmsg:    ds.l 1
outfh:    ds.l 1
infh:     ds.l 1
npaths:   ds.l 1
pathtab:  ds.l MAXARGS
pendhead: ds.l 1
ghead:    ds.l 1
gtail:    ds.l 1
lhead:    ds.l 1
lcount:   ds.l 1
arrptr:   ds.l 1
v_path:   ds.l 1
v_isdir:  ds.l 1
v_colw:   ds.l 1
v_ncols:  ds.l 1
v_nrows:  ds.l 1
twidth:   ds.l 1
params:   ds.w 8
gfib:     ds.b fib_SIZEOF               ; Examine() needs long alignment;
dtime:    ds.b 28                       ; all-ds.l/ds.w above guarantees
anchor:   ds.b ap_Buf+PATHLEN           ; it, and the ds.b sizes stay
cmdbuf:   ds.b 512                      ; long-multiples down to here
tokbuf:   ds.b 512
patbuf:   ds.b 1024
linebuf:  ds.b 800
dnamebuf: ds.b 112
datebuf:  ds.b 16
timebuf:  ds.b 16
numbuf:   ds.b 20
bytebuf:  ds.b 2
f_long:   ds.b 1
f_all:    ds.b 1
f_one:    ds.b 1
f_hum:    ds.b 1
f_rev:    ds.b 1
f_rec:    ds.b 1
sortby:   ds.b 1
tinter:   ds.b 1
headers:  ds.b 1
notfirst: ds.b 1
brkflag:  ds.b 1
usagefl:  ds.b 1
badflag:  ds.b 1
