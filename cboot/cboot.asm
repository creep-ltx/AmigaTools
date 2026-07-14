; cboot14.asm - 68k port of cboot14.e, extended with LAmiga/RAmiga
; boot modes and "mouse"/"amiga" command-line mode selection.
;
; Based on cboot14_old.asm (verified: booted and run on an AmigaOS 3.2
; install under FS-UAE, assembled size 3704 bytes for
; the Ctrl/LMB/RMB-only version). This adds the same functionality that was
; added to cboot14.e: reading the Left/Right Amiga bits from the keyboard
; matrix, and an optional "MODE" command-line argument ("mouse" or "amiga")
; that restricts CBoot to only the mouse-button or only the Amiga-key boot
; modes. Ctrl still enters the control center the same way regardless of
; which modes are active, exactly as in the .e version.
;
; New LVOs (dos.library, called with A6=DosBase):
;   ReadArgs=-798 FreeArgs=-858
; Derived the same way as every other LVO in this file: counting entries in
; emodules/fd/dos_lib.fd from the nearest "##bias" checkpoint (bias 492 at
; Cli()()), not recalled from memory. Cross-checked by recounting from
; Cli()() to MaxCli()() (should be entry 11, offset -552) and confirming it
; lines up with the already-hardware-verified Lock=-84 counting method used
; for the original LVOs in this file.
;
; Keyboard matrix bits (byte 12 of the KBD_READMATRIX result, same table
; already verified working for Ctrl in the original checkctrl):
;   bit 3 (mask 8)   = Ctrl          (raw keycode $63)
;   bit 6 (mask 64)  = Left Amiga    (raw keycode $66)
;   bit 7 (mask 128) = Right Amiga   (raw keycode $67)
;
; Everything else (LVOs, struct offsets, the three real bugs found via
; execution) is unchanged from cboot14_old.asm - see that file's header for
; the full derivation history.
;
; Verified LVOs:
;   exec.library:  OpenLibrary=-552 CloseLibrary=-414 AllocMem=-198 FreeMem=-210
;                  CreateMsgPort=-666 DeleteMsgPort=-672
;                  CreateIORequest=-654 DeleteIORequest=-660
;                  OpenDevice=-444 CloseDevice=-450 DoIO=-456
;   dos.library:   Lock=-84 UnLock=-90 Examine=-102 Execute=-222
;                  ReadArgs=-798 FreeArgs=-858
;                  (all called with A6=DosBase, not SysBase)
;   intuition.library: EasyRequestArgs=-588
;   asl.library:   AllocFileRequest=-30 FreeFileRequest=-36 RequestFile=-42
; Verified struct offsets:
;   Library.lib_Version=20 (word)
;   IOStdReq: io_Command=28 io_Length=36 io_Data=40   (SIZEOF=48)
;   FileRequester: fr_File=4 fr_Drawer=8
;   EasyStruct: es_StructSize=0 es_Flags=4 es_Title=8 es_TextFormat=12 es_GadgetFormat=16 (SIZEOF=20)
;   FileInfoBlock.fl_Size=124 (from E-VO.S's own FileLength implementation)

        section text,code

start:
        movea.l 4.w,a6
        move.l  a6,sysbase.l

        lea     dosname(pc),a1
        moveq   #0,d0
        jsr     -552(a6)
        move.l  d0,dosbase.l
        beq     exit

        lea     intuitionname(pc),a1
        moveq   #37,d0
        movea.l sysbase.l,a6
        jsr     -552(a6)
        move.l  d0,intuitionbase.l
        beq     closedos

        bsr     getmode
        move.b  d0,mode.l

        bsr     checkkeys
        move.b  d0,keyflags.l
        moveq   #0,d0
        btst    #3,keyflags.l
        beq.s   .noctrlbit
        moveq   #1,d0
.noctrlbit:
        move.b  d0,ctrlflag.l

        bsr     selectboot
        bsr     setupenv

        tst.b   ctrlflag.l
        beq.s   .noctrl
        bsr     configmenu
.noctrl:

.retryloop:
        lea     file.l,a1
        bsr     filelength
        tst.l   d0
        bge.s   .havefile
        bsr     selectfile
        bra.s   .retryloop
.havefile:

        bsr     envremove
        bsr     setflags

        lea     cmdbuf.l,a0
        move.b  #'"',(a0)+
        lea     file.l,a1
        bsr     copystr
        move.b  #'"',(a0)+
        clr.b   (a0)
        bsr     doexecute

        movea.l intuitionbase.l,a1
        movea.l sysbase.l,a6
        jsr     -414(a6)

closedos:
        movea.l dosbase.l,a1
        movea.l sysbase.l,a6
        jsr     -414(a6)

exit:
        moveq   #0,d0
        rts

; ============================================================
; getmode: parses an optional "MODE" CLI argument ("mouse" or "amiga").
; Returns D0 = 0 (MODE_ALL, default), 1 (MODE_MOUSE) or 2 (MODE_AMIGA).
; ============================================================
getmode:
        lea     modetemplate(pc),a0
        move.l  a0,d1
        lea     modeoptions.l,a1
        move.l  a1,d2
        moveq   #0,d3
        movea.l dosbase.l,a6
        jsr     -798(a6)              ; ReadArgs
        moveq   #0,d7                 ; default: MODE_ALL
        tst.l   d0
        beq     .done                 ; ReadArgs failed - keep default
        movea.l d0,a3                 ; a3 = rdargs handle (for FreeArgs)
        move.l  modeoptions.l,d0
        beq.s   .freeargs             ; no MODE string given - keep default
        movea.l d0,a1
        lea     mousename(pc),a0
        bsr     strcmp
        tst.l   d0
        beq.s   .setmouse
        movea.l modeoptions.l,a1
        lea     amiganame(pc),a0
        bsr     strcmp
        tst.l   d0
        beq.s   .setamiga
        bra.s   .freeargs
.setmouse:
        moveq   #1,d7
        bra.s   .freeargs
.setamiga:
        moveq   #2,d7
.freeargs:
        move.l  a3,d1
        movea.l dosbase.l,a6
        jsr     -858(a6)              ; FreeArgs
.done:
        move.l  d7,d0
        rts

; ============================================================
; strcmp: A0,A1 = two NUL-terminated strings -> D0=0 if equal, 1 if not
; ============================================================
strcmp:
.loop:
        move.b  (a0)+,d0
        move.b  (a1)+,d1
        cmp.b   d0,d1
        bne.s   .diff
        tst.b   d0
        beq.s   .same
        bra.s   .loop
.diff:
        moveq   #1,d0
        rts
.same:
        moveq   #0,d0
        rts

; ============================================================
; checkkeys: reads the keyboard matrix, returns D0 = byte 12 masked to
; Ctrl|LAmiga|RAmiga bits (8|64|128 = 200), or 0 if the read failed.
; ============================================================
checkkeys:
        moveq   #0,d7
        movea.l sysbase.l,a6
        jsr     -666(a6)             ; CreateMsgPort
        tst.l   d0
        beq     .done
        movea.l d0,a3
        movea.l a3,a0
        moveq   #48,d0               ; SIZEOF iostd
        movea.l sysbase.l,a6
        jsr     -654(a6)             ; CreateIORequest(port,size)
        tst.l   d0
        beq     .freeport
        movea.l d0,a4
        lea     kbdname(pc),a0
        moveq   #0,d0
        movea.l a4,a1
        moveq   #0,d1
        movea.l sysbase.l,a6
        jsr     -444(a6)             ; OpenDevice('keyboard.device',0,ioreq,0)
        tst.l   d0
        bne     .freeioreq
        move.l  #16,d0
        move.l  #$10001,d1           ; MEMF_PUBLIC|MEMF_CLEAR
        movea.l sysbase.l,a6
        jsr     -198(a6)             ; AllocMem
        tst.l   d0
        beq     .closedev
        movea.l d0,a5
        movea.l a4,a1
        move.w  #10,28(a1)           ; io_Command = KBD_READMATRIX
        move.l  a5,40(a1)            ; io_Data
        movea.l sysbase.l,a6
        move.w  20(a6),d1            ; lib_Version
        cmp.w   #36,d1
        blo.s   .old
        move.l  #16,36(a1)           ; io_Length
        bra.s   .doio
.old:
        move.l  #13,36(a1)
.doio:
        movea.l a4,a1
        movea.l sysbase.l,a6
        jsr     -456(a6)             ; DoIO
        movea.l a5,a1
        move.b  12(a1),d1
        and.b   #200,d1              ; CTRL(8)|LAMIGA(64)|RAMIGA(128)
        move.l  d1,d7
        movea.l a5,a1
        move.l  #16,d0
        movea.l sysbase.l,a6
        jsr     -210(a6)             ; FreeMem
.closedev:
        movea.l a4,a1
        movea.l sysbase.l,a6
        jsr     -450(a6)             ; CloseDevice
.freeioreq:
        movea.l a4,a0
        movea.l sysbase.l,a6
        jsr     -660(a6)             ; DeleteIORequest
.freeport:
        movea.l a3,a0
        movea.l sysbase.l,a6
        jsr     -672(a6)             ; DeleteMsgPort
.done:
        move.l  d7,d0
        rts

; ============================================================
; selectboot: fills 'file.l' with S:CBoot/Default|LMB|RMB|LAmiga|RAmiga
; based on Mouse() and keyflags.l, restricted by mode.l:
;   mode=0 (MODE_ALL)   - checks mouse buttons, then Amiga keys
;   mode=1 (MODE_MOUSE) - checks mouse buttons only
;   mode=2 (MODE_AMIGA) - checks Amiga keys only
; Mouse buttons take priority over Amiga keys if both are mode=0.
; Mouse-read sequence lifted verbatim from E-VO.S (I_MOUSE/E_MOUSE)
; ============================================================
selectboot:
        cmp.b   #2,mode.l
        beq     .skipmouse
        moveq   #0,d0
        btst    #6,$bfe001.l
        bne.s   .lmbnot
        moveq   #1,d0
.lmbnot:
        lea     $dff016,a0
        move.w  (a0),d1
        btst    #10,d1
        bne.s   .rmbnot
        bset    #1,d0
.rmbnot:
        cmp.b   #1,d0
        beq     .lmb
        cmp.b   #2,d0
        beq     .rmb
.skipmouse:
        cmp.b   #1,mode.l
        beq     .default
        btst    #6,keyflags.l
        bne.s   .lamiga
        btst    #7,keyflags.l
        bne.s   .ramiga
        bra     .default
.lmb:
        lea     file.l,a0
        lea     lmbname(pc),a1
        bsr     copystr
        bra     .term
.rmb:
        lea     file.l,a0
        lea     rmbname(pc),a1
        bsr     copystr
        bra     .term
.lamiga:
        lea     file.l,a0
        lea     lamiganame(pc),a1
        bsr     copystr
        bra.s   .term
.ramiga:
        lea     file.l,a0
        lea     ramiganame(pc),a1
        bsr     copystr
        bra.s   .term
.default:
        lea     file.l,a0
        lea     defaultname(pc),a1
        bsr     copystr
.term:
        clr.b   (a0)
        rts

; ============================================================
; filelength: A1=name -> D0=length or -1
; sequence verified against E-VO.S's own I_FILELENGTH implementation
; ============================================================
filelength:
        move.l  a1,d1
        moveq   #-2,d2
        movea.l dosbase.l,a6
        jsr     -84(a6)              ; Lock
        move.l  d0,a3
        moveq   #-1,d7
        cmpa.l  #0,a3
        beq     .done
        move.l  a7,a4
        lea     -260(a7),a7
        move.l  a3,d1
        move.l  a7,d2
        movea.l dosbase.l,a6
        jsr     -102(a6)             ; Examine
        move.l  124(a7),d1           ; fl_Size
        movea.l a4,a7
        tst.l   d0
        beq.s   .unlock
        move.l  d1,d7
.unlock:
        move.l  a3,d1
        movea.l dosbase.l,a6
        jsr     -90(a6)              ; UnLock
.done:
        move.l  d7,d0
        rts

; ============================================================
; checkexists: A1=name -> D0=1 if Lock succeeds (then immediately unlocked)
; ============================================================
checkexists:
        move.l  a1,d1
        moveq   #-2,d2
        movea.l dosbase.l,a6
        jsr     -84(a6)
        move.l  d0,a3
        cmpa.l  #0,a3
        beq.s   .no
        move.l  a3,d1
        movea.l dosbase.l,a6
        jsr     -90(a6)
        moveq   #1,d0
        rts
.no:
        moveq   #0,d0
        rts

; ============================================================
; doexecute: runs the null-terminated command line in cmdbuf.l
; ============================================================
doexecute:
        lea     cmdbuf.l,a1
        move.l  a1,d1
        moveq   #0,d2
        moveq   #0,d3
        movea.l dosbase.l,a6
        jsr     -222(a6)
        rts

; ============================================================
; doeasyrequest: A0=body ptr, A1=gadgets ptr -> D0=gadget clicked
; ============================================================
doeasyrequest:
        move.l  a0,easystructdata+12.l
        move.l  a1,easystructdata+16.l
        movea.l #0,a0
        lea     easystructdata.l,a1
        movea.l #0,a2
        lea     argsfile.l,a3
        movea.l intuitionbase.l,a6
        jsr     -588(a6)
        rts

; ============================================================
; pickfile: fills 'picked.l' via ASL file.l requester -> D0=1/0
; ============================================================
pickfile:
        moveq   #0,d7
        lea     aslname(pc),a1
        moveq   #37,d0
        movea.l sysbase.l,a6
        jsr     -552(a6)             ; OpenLibrary('asl.library',37)
        move.l  d0,aslbase.l
        beq     .done
        movea.l aslbase.l,a6
        jsr     -30(a6)              ; AllocFileRequest
        tst.l   d0
        beq     .closeasl
        movea.l d0,a3
        movea.l a3,a0
        movea.l aslbase.l,a6
        jsr     -42(a6)              ; RequestFile
        tst.l   d0
        beq.s   .freereq
        movea.l a3,a1
        move.l  8(a1),a1             ; fr_Drawer
        lea     picked.l,a0
        bsr     copystr
        move.b  #'/',(a0)+
        movea.l a3,a1
        move.l  4(a1),a1             ; fr_File
        bsr     copystr
        clr.b   (a0)
        moveq   #1,d7
.freereq:
        movea.l a3,a0
        movea.l aslbase.l,a6
        jsr     -36(a6)              ; FreeFileRequest
.closeasl:
        movea.l aslbase.l,a1
        movea.l sysbase.l,a6
        jsr     -414(a6)             ; CloseLibrary
.done:
        move.l  d7,d0
        rts

; ============================================================
; install: D6=1 (copy 'picked.l' onto 'file.l') or D6=0 (test: file:=picked.l)
; ============================================================
install:
        bsr     pickfile
        tst.l   d0
        beq     .done
        tst.b   d6
        beq.s   .testpath
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'copy "',0
        even
        lea     picked.l,a1
        bsr     copystr
        bsr     copylit
        dc.b    '" "',0
        even
        lea     file.l,a1
        bsr     copystr
        move.b  #'"',(a0)+
        clr.b   (a0)
        bsr     doexecute
        bra.s   .done
.testpath:
        lea     file.l,a0
        lea     picked.l,a1
        bsr     copystr
        clr.b   (a0)
.done:
        rts

; ============================================================
; configmenu: Edit / Replace / Test dialog
; ============================================================
configmenu:
        lea     configbody(pc),a0
        lea     configgadgets(pc),a1
        bsr     doeasyrequest
        cmp.l   #1,d0
        beq.s   .edit
        cmp.l   #2,d0
        beq.s   .replace
        moveq   #0,d6
        bsr     install
        rts
.edit:
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'ed "',0
        even
        lea     file.l,a1
        bsr     copystr
        move.b  #'"',(a0)+
        clr.b   (a0)
        bsr     doexecute
        rts
.replace:
        moveq   #1,d6
        bsr     install
        rts

; ============================================================
; selectfile: prompts for a bootscript when 'file.l' doesn't exist yet
; ============================================================
selectfile:
        lea     defaultname(pc),a1
        bsr     filelength
        tst.l   d0
        ble.s   .nodefault
        lea     sfbody1(pc),a0
        lea     sfgad1(pc),a1
        bsr     doeasyrequest
        cmp.l   #1,d0
        beq.s   .bootnormal
        moveq   #1,d6
        bsr     install
        rts
.bootnormal:
        lea     file.l,a0
        lea     defaultname(pc),a1
        bsr     copystr
        clr.b   (a0)
        rts
.nodefault:
        lea     sfbody2(pc),a0
        lea     sfgad2(pc),a1
        bsr     doeasyrequest
        moveq   #1,d6
        bsr     install
        rts

; ============================================================
; envremove / setupenv / setflags
; ============================================================
envremove:
        lea     ramenv(pc),a1
        bsr     checkexists
        tst.l   d0
        beq.s   .done
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'assign env: remove',0
        even
        clr.b   (a0)
        bsr     doexecute
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'run >nil: delete ram:env all',0
        even
        clr.b   (a0)
        bsr     doexecute
.done:
        rts

setupenv:
        lea     ramenv(pc),a1
        bsr     checkexists
        tst.l   d0
        bne.s   .haveenv
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'makedir ram:env',0
        even
        clr.b   (a0)
        bsr     doexecute
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'assign env: ram:env',0
        even
        clr.b   (a0)
        bsr     doexecute
.haveenv:
        lea     scbootname(pc),a1
        bsr     checkexists
        tst.l   d0
        bne.s   .havecboot
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'makedir S:CBoot',0
        even
        clr.b   (a0)
        bsr     doexecute
.havecboot:
        rts

setflags:
        lea     cmdbuf.l,a0
        bsr     copylit
        dc.b    'protect "',0
        even
        lea     file.l,a1
        bsr     copystr
        bsr     copylit
        dc.b    '" +srwed',0
        even
        clr.b   (a0)
        bsr     doexecute
        rts

; ============================================================
; helpers
; ============================================================
copylit:
        move.l  (sp)+,a1
.loop:
        move.b  (a1)+,d1
        beq.s   .done
        move.b  d1,(a0)+
        bra.s   .loop
.done:
        move.l  a1,d1
        addq.l  #1,d1
        and.l   #-2,d1
        movea.l d1,a1
        jmp     (a1)

copystr:
.loop:
        move.b  (a1)+,d1
        beq.s   .done
        move.b  d1,(a0)+
        bra.s   .loop
.done:
        rts

; ============================================================
; string literals
; ============================================================
dosname:        dc.b 'dos.library',0
                even
intuitionname:  dc.b 'intuition.library',0
                even
aslname:        dc.b 'asl.library',0
                even
kbdname:        dc.b 'keyboard.device',0
                even
defaultname:    dc.b 'S:CBoot/Default',0
                even
lmbname:        dc.b 'S:CBoot/LMB',0
                even
rmbname:        dc.b 'S:CBoot/RMB',0
                even
lamiganame:     dc.b 'S:CBoot/LAmiga',0
                even
ramiganame:     dc.b 'S:CBoot/RAmiga',0
                even
ramenv:         dc.b 'Ram:ENV',0
                even
scbootname:     dc.b 'S:CBoot',0
                even
modetemplate:   dc.b 'MODE',0
                even
mousename:      dc.b 'mouse',0
                even
amiganame:      dc.b 'amiga',0
                even
configbody:     dc.b 'CBoot control.',10,10,'Edit, replace or test %s?',0
                even
configgadgets:  dc.b 'Edit|Replace|Test',0
                even
sfbody1:        dc.b 'No script for %s.',10,'Boot normally or select one?',0
                even
sfgad1:         dc.b 'Normal|Select',0
                even
sfbody2:        dc.b 'No script for %s.',10,'Select one:',0
                even
sfgad2:         dc.b 'Select',0
                even

; ============================================================
; storage
; ============================================================
sysbase:        dc.l 0
dosbase:        dc.l 0
intuitionbase:  dc.l 0
aslbase:        dc.l 0
modeoptions:    dc.l 0
ctrlflag:       dc.b 0
                even
mode:           dc.b 0
                even
keyflags:       dc.b 0
                even
argsfile:       dc.l file
easystructdata: dc.l 20,0,0,0,0
file:           ds.b 256
picked:         ds.b 256
cmdbuf:         ds.b 600
