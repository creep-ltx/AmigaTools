; pgroups.s - the planar painter's two inner loops (1.2.8b9), vasm syntax.
;
; Written for the stock A1200, where every chip access - data, and every
; instruction fetched outside the 020's 256-byte cache - costs ~1.4us
; against the 16-colour Hires display. So: two passes per row, each a
; loop small enough to run from the cache, and no loop state in memory.
;
; ptrans - glyph bits for the row, colour-free. Per output long (four
;   output bytes = four cells, a "group"), per four glyph lines: four
;   longs hi(cell c) | lo(cell c-1) from the pre-shifted cache (a long is
;   four glyph lines of one cell), 4x4 byte-transposed into one long per
;   line, stored line-major into comb (line y of group g at
;   comb[y * ng + g]).
;
; pplane - one plane: per line, per segment of groups sharing a colour
;   mask pair, v = (comb AND A) XOR X straight into the plane. A segment
;   with E <> -1 is an edge group: the pixels outside the span are kept.

	section	.text,code
	xdef	ptrans
	xdef	pplane

;; void ptrans(UBYTE *c0m1, LONG ng, ULONG *comb, LONG ch, LONG cs,
;;              UBYTE *gl, LONG shift)
;   c0m1 = the char of cell c0-1 of group 0 (a padded copy of the row);
;   a char's cache block is at gl + (char << shift) - codes below 32
;   already point at the space glyph (gshift), so no clamp here
ptrans:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	52(sp),-(sp)		; groups left, a local
	move.l	52(sp),a0		; chars (args now from 52)
	move.l	60(sp),a5		; comb
	move.l	72(sp),a4		; gl
	move.l	56(sp),d6
	lsl.l	#2,d6			; line stride in comb
	move.l	76(sp),d7		; shift
.grp:	sub.l	a3,a3			; yy = 0
	move.l	a5,a2			; this group's column, line 0
.slab:	move.l	68(sp),a6		; cs
	add.l	a3,a6			; cs + yy
	moveq	#0,d4
	move.b	(a0),d4
	lsl.l	d7,d4
	lea	0(a4,d4.l),a1
	move.l	0(a1,a6.l),d0		; lo(c0-1)
	moveq	#0,d4
	move.b	1(a0),d4
	lsl.l	d7,d4
	lea	0(a4,d4.l),a1
	or.l	0(a1,a3.l),d0		; hi(c0)
	move.l	0(a1,a6.l),d1
	moveq	#0,d4
	move.b	2(a0),d4
	lsl.l	d7,d4
	lea	0(a4,d4.l),a1
	or.l	0(a1,a3.l),d1
	move.l	0(a1,a6.l),d2
	moveq	#0,d4
	move.b	3(a0),d4
	lsl.l	d7,d4
	lea	0(a4,d4.l),a1
	or.l	0(a1,a3.l),d2
	move.l	0(a1,a6.l),d3
	moveq	#0,d4
	move.b	4(a0),d4
	lsl.l	d7,d4
	lea	0(a4,d4.l),a1
	or.l	0(a1,a3.l),d3
	move.l	d0,d4			; transpose a,b,c,d -> lines 0..3
	and.l	#$FF00FF00,d0
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d1,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d0
	and.l	#$00FF00FF,d1
	or.l	d4,d1
	move.l	d2,d4
	and.l	#$FF00FF00,d2
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d3,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d2
	and.l	#$00FF00FF,d3
	or.l	d4,d3
	move.l	d0,d5
	swap	d5
	move.w	d2,d5
	swap	d2
	move.w	d2,d0
	move.l	d5,d2
	move.l	d1,d5
	swap	d5
	move.w	d3,d5
	swap	d3
	move.w	d3,d1
	move.l	d5,d3
	move.l	d0,(a2)
	move.l	d1,0(a2,d6.l)
	lea	0(a2,d6.l*2),a2
	move.l	d2,(a2)
	move.l	d3,0(a2,d6.l)
	lea	0(a2,d6.l*2),a2		; four lines down
	addq.l	#4,a3
	cmp.l	64(sp),a3		; yy < ch ?
	blt	.slab
	addq.l	#4,a0			; next four cells
	addq.l	#4,a5			; next column
	subq.l	#1,(sp)
	bne	.grp
	addq.l	#4,sp
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; void pplane(ULONG *comb, LONG ng, LONG ch, seg *sg, UBYTE *dst, LONG bpr)
;   seg: n.l (groups), A.l, X.l, E.l (-1 = whole longs); n = 0 ends
pplane:
	movem.l	d2-d7/a2-a6,-(sp)
	movem.l	48(sp),a3/a4		; comb (line base), ng
	move.l	56(sp),d2		; ch: lines left
	move.l	64(sp),a4		; dst line base
	move.l	a4,d3			; (a4 reused: ng is only a stride)
	move.l	52(sp),d4
	lsl.l	#2,d4			; comb line stride
	move.l	68(sp),a5		; bpr
.line:	move.l	a3,a0
	move.l	d3,a1
	move.l	60(sp),a2		; segments
.seg:	move.l	(a2)+,d0
	beq.s	.next
	movem.l	(a2)+,d5-d7		; A, X, E
	cmp.l	#-1,d7
	bne.s	.edge
	subq.l	#1,d0
.run:	move.l	(a0)+,d1
	and.l	d5,d1
	eor.l	d6,d1
	move.l	d1,(a1)+
	dbra	d0,.run
	bra.s	.seg
.edge:	move.l	(a0)+,d1		; one group: (v ^ dst) & E ^ dst
	and.l	d5,d1
	eor.l	d6,d1
	move.l	(a1),d0
	eor.l	d0,d1
	and.l	d7,d1
	eor.l	d0,d1
	move.l	d1,(a1)+
	bra.s	.seg
.next:	add.l	d4,a3
	add.l	a5,d3
	subq.l	#1,d2
	bne.s	.line
	movem.l	(sp)+,d2-d7/a2-a6
	rts

; ---------------------------------------------------------------------
; pfused - one row, all planes, for cells up to 8 lines (cache blocks of
; 16 bytes: hi lines 0-7, lo lines 0-7). The two passes above in one,
; no line buffer: per group the colour masks (recomputed only when the
; group's attr/style key changes), then per four lines the glyph longs,
; the transpose, and every plane's four longs straight to the screen.
; Cells come as glyph POINTERS (one long each, from c0-1 of group 0), so
; the slab loop is short enough for the 020's 256-byte cache - keep the
; code from .fslab to .fnext that way (vasm -L shows the addresses).
PF_GP   = 0             ; glyph pointer of cell c0-1 of group 0
PF_NG   = 4
PF_CH   = 8
PF_PA   = 12            ; attr of cell c0-1 (styles at +SOFF), per group
PF_BPR  = 16
PF_EF   = 20
PF_EL   = 24
PF_UNI5 = 28
PF_OWN  = 32            ; 5 longs
PF_TN   = 52            ; pens table, plain: 256 words fx<<8|fb
PF_TI   = 56            ; ... inverse
PF_K    = 60            ; groups left
PF_E    = 64            ; this group's edge mask
PF_KEY  = 68            ; colour key of the masks in PF_PT (-1 = none)
PF_YY   = 72
PF_PT   = 76            ; planes: dst.l, pbit.l, A.l, X.l ... then 0
SOFF    = 272           ; styles = attrs + SOFF

	xdef	pfused
pfused:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	48(sp),a4
	move.l	PF_GP(a4),a0
	move.l	PF_BPR(a4),a5
	move.l	PF_NG(a4),PF_K(a4)
	moveq	#-1,d0
	move.l	d0,PF_KEY(a4)
	move.l	PF_EF(a4),d5		; first group: its edge
.fgrp:	cmp.l	#1,PF_K(a4)
	bne.s	.fnl
	and.l	PF_EL(a4),d5
.fnl:	move.l	d5,PF_E(a4)
	; ---- the group's colour masks ----
	move.l	PF_PA(a4),a6
	move.l	1(a6),d0		; attrs c0..c0+3
	move.l	SOFF+1(a6),d1		; styles
	move.l	d0,d2
	ror.l	#8,d2
	cmp.l	d0,d2
	bne	.fmix
	move.l	d1,d2
	ror.l	#8,d2
	cmp.l	d1,d2
	bne	.fmix
	tst.l	PF_UNI5(a4)
	beq.s	.funi
	cmp.b	(a6),d0
	bne	.fmix
	cmp.b	SOFF(a6),d1
	bne	.fmix
.funi:	moveq	#0,d2
	move.b	d0,d2
	lsl.w	#8,d2
	move.b	d1,d2			; key = attr<<8 | style
	cmp.l	PF_KEY(a4),d2
	beq	.fslabs
	move.l	d2,PF_KEY(a4)
	moveq	#0,d3
	move.b	d0,d3
	add.l	d3,d3			; word index
	move.l	PF_TN(a4),a1
	btst	#2,d1
	beq.s	.fn
	move.l	PF_TI(a4),a1
.fn:	move.w	0(a1,d3.l),d4		; fx<<8 | fb
	move.w	d4,d3
	lsr.w	#8,d3			; fx
	lea	PF_PT(a4),a2
.fu:	tst.l	(a2)
	beq	.fslabs
	move.l	4(a2),d6		; plane bit
	btst	d6,d3
	sne	d7
	extb.l	d7
	move.l	d7,8(a2)		; A
	btst	d6,d4
	sne	d7
	extb.l	d7
	move.l	d7,12(a2)		; X
	lea	16(a2),a2
	bra.s	.fu
.fmix:	moveq	#-1,d2
	move.l	d2,PF_KEY(a4)
	lea	PF_PT(a4),a2
.fm:	tst.l	(a2)
	beq	.fslabs
	move.l	4(a2),d6		; plane bit
	moveq	#0,d2			; A
	moveq	#0,d7			; X
	moveq	#0,d1			; owner i * 4
	move.l	a6,a3			; owner's attr
.fmo:	moveq	#0,d3
	move.b	(a3),d3
	add.l	d3,d3
	move.l	PF_TN(a4),a1
	btst	#2,SOFF(a3)
	beq.s	.fmn
	move.l	PF_TI(a4),a1
.fmn:	move.w	0(a1,d3.l),d4		; fx<<8 | fb
	btst	d6,d4
	beq.s	.fm1
	or.l	PF_OWN(a4,d1.l),d7
.fm1:	lsr.w	#8,d4
	btst	d6,d4
	beq.s	.fm2
	or.l	PF_OWN(a4,d1.l),d2
.fm2:	addq.l	#1,a3
	addq.l	#4,d1
	cmp.l	#20,d1
	bne.s	.fmo
	move.l	d2,8(a2)
	move.l	d7,12(a2)
	lea	16(a2),a2
	bra.s	.fm
	; ---- four lines at a time: the cached part ----
.fslabs:
	moveq	#0,d5
	move.l	d5,PF_YY(a4)
.fslab:	move.l	PF_YY(a4),d5
	move.l	(a0),a1
	move.l	8(a1,d5.l),d0		; lo(c0-1)
	move.l	4(a0),a1
	or.l	0(a1,d5.l),d0		; hi(c0)
	move.l	8(a1,d5.l),d1
	move.l	8(a0),a1
	or.l	0(a1,d5.l),d1
	move.l	8(a1,d5.l),d2
	move.l	12(a0),a1
	or.l	0(a1,d5.l),d2
	move.l	8(a1,d5.l),d3
	move.l	16(a0),a1
	or.l	0(a1,d5.l),d3
	move.l	#$FF00FF00,d6
	move.l	#$00FF00FF,d7
	move.l	d0,d4			; transpose a,b,c,d -> lines 0..3
	and.l	d6,d0
	lsl.l	#8,d4
	and.l	d6,d4
	move.l	d1,d5
	lsr.l	#8,d5
	and.l	d7,d5
	or.l	d5,d0
	and.l	d7,d1
	or.l	d4,d1
	move.l	d2,d4
	and.l	d6,d2
	lsl.l	#8,d4
	and.l	d6,d4
	move.l	d3,d5
	lsr.l	#8,d5
	and.l	d7,d5
	or.l	d5,d2
	and.l	d7,d3
	or.l	d4,d3
	move.l	d0,d5
	swap	d5
	move.w	d2,d5
	swap	d2
	move.w	d2,d0
	move.l	d5,d2
	move.l	d1,d5
	swap	d5
	move.w	d3,d5
	swap	d3
	move.w	d3,d1
	move.l	d5,d3
	lea	PF_PT(a4),a2
.fpl:	move.l	(a2),d4
	beq.s	.fpd
	move.l	d4,a3
	tst.l	PF_YY(a4)
	beq.s	.fp0
	lea	0(a3,a5.l*4),a3		; second slab: four lines down
.fp0:	movem.l	8(a2),d6/d7		; A, X
	lea	16(a2),a2
	move.l	PF_CH(a4),d5
	sub.l	PF_YY(a4),d5		; lines left in the row
	ifd	NOWRITE
	bra	.fpl
	endif
	cmp.l	#-1,PF_E(a4)
	bne	.fpe
	move.l	d0,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	subq.l	#1,d5
	beq.s	.fpl
	add.l	a5,a3
	move.l	d1,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	subq.l	#1,d5
	beq.s	.fpl
	add.l	a5,a3
	move.l	d2,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	subq.l	#1,d5
	beq.s	.fpl
	add.l	a5,a3
	move.l	d3,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	bra.s	.fpl
.fpd:	addq.l	#4,PF_YY(a4)
	move.l	PF_YY(a4),d5
	cmp.l	PF_CH(a4),d5
	blt	.fslab
.fnext:	; next group: four cells on, every plane's dst one long on
	lea	16(a0),a0
	addq.l	#4,PF_PA(a4)
	lea	PF_PT(a4),a2
.fadv:	tst.l	(a2)
	beq.s	.fadd
	addq.l	#4,(a2)
	lea	16(a2),a2
	bra.s	.fadv
.fadd:	moveq	#-1,d5
	subq.l	#1,PF_K(a4)
	bne	.fgrp
	movem.l	(sp)+,d2-d7/a2-a6
	rts
; an edge group's lines (outside the cached loop): (v ^ dst) & E ^ dst
.fpe:	move.l	d0,d4
	bsr.s	.fpr
	beq	.fpl
	move.l	d1,d4
	bsr.s	.fpr
	beq	.fpl
	move.l	d2,d4
	bsr.s	.fpr
	beq	.fpl
	move.l	d3,d4
	bsr.s	.fpr
	bra	.fpl
.fpr:	and.l	d6,d4
	eor.l	d7,d4
	move.l	(a3),a1
	exg	a1,d6			; d6 = dst, a1 = A (kept)
	eor.l	d6,d4
	and.l	PF_E(a4),d4
	eor.l	d6,d4
	exg	a1,d6
	move.l	d4,(a3)
	add.l	a5,a3
	subq.l	#1,d5
	rts

; ---------------------------------------------------------------------
; pfused1 - pfused for ONE plane: the plane's dst rides in a6 and its A/X
; in d6/d7, so an interior slab is its 5 pointer + 8 glyph reads and 4
; writes and nothing else. Edge groups (the span's first and last long)
; and a short last slab take the paths after .1gd, outside the cached
; loop. Plain text (pen 1 on 0) is one plane: the common row. Same
; struct pf; uses PF_PT's first entry (dst, pbit) only.
	xdef	pfused1
pfused1:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	48(sp),a4
	move.l	PF_GP(a4),a0
	move.l	PF_BPR(a4),a5
	move.l	PF_PT(a4),a6		; dst, line 0 of the first group
	move.l	PF_NG(a4),PF_K(a4)
	moveq	#-1,d0
	move.l	d0,PF_KEY(a4)
.1grp:	moveq	#-1,d5			; this group's edge mask
	move.l	PF_K(a4),d0
	cmp.l	PF_NG(a4),d0
	bne.s	.1nf
	and.l	PF_EF(a4),d5
.1nf:	cmp.l	#1,d0
	bne.s	.1nl
	and.l	PF_EL(a4),d5
.1nl:	move.l	d5,PF_E(a4)
	move.l	PF_PA(a4),a2
	move.l	1(a2),d0		; attrs c0..c0+3
	move.l	SOFF+1(a2),d1		; styles
	move.l	d0,d2
	ror.l	#8,d2
	cmp.l	d0,d2
	bne	.1mix
	move.l	d1,d2
	ror.l	#8,d2
	cmp.l	d1,d2
	bne	.1mix
	tst.l	PF_UNI5(a4)
	beq.s	.1uni
	cmp.b	(a2),d0
	bne	.1mix
	cmp.b	SOFF(a2),d1
	bne	.1mix
.1uni:	moveq	#0,d2
	move.b	d0,d2
	lsl.w	#8,d2
	move.b	d1,d2
	cmp.l	PF_KEY(a4),d2
	beq	.1run			; same pens as the last group
	move.l	d2,PF_KEY(a4)
	moveq	#0,d3
	move.b	d0,d3
	add.l	d3,d3
	move.l	PF_TN(a4),a1
	btst	#2,d1
	beq.s	.1n
	move.l	PF_TI(a4),a1
.1n:	move.w	0(a1,d3.l),d4		; fx<<8 | fb
	move.l	PF_PT+4(a4),d5		; plane bit
	btst	d5,d4
	sne	d7
	extb.l	d7			; X
	lsr.w	#8,d4
	btst	d5,d4
	sne	d6
	extb.l	d6			; A
.1run:	; an interior uniform group (A/X in d6/d7, attrs d0, styles d1):
	; count how many groups from here share its pens, then paint them
	; all in .1hot - nothing in that loop but the slabs
	cmp.l	#-1,PF_E(a4)
	bne	.1go
	cmp.l	#8,PF_CH(a4)
	bne	.1go
	move.l	PF_PA(a4),a2
	moveq	#1,d2			; groups in the run
	move.l	PF_K(a4),d3
	subq.l	#1,d3			; groups after this one
.1cnt:	cmp.l	#1,d3			; the last group is an edge: not in a run
	ble.s	.1hgo
	cmp.l	5(a2),d0		; next group's attrs
	bne.s	.1hgo
	cmp.l	SOFF+5(a2),d1
	bne.s	.1hgo
	addq.l	#4,a2
	addq.l	#1,d2
	subq.l	#1,d3
	bra.s	.1cnt
.1hgo:	sub.l	d2,PF_K(a4)		; the run's groups are spent here
	move.l	d2,d3
	lsl.l	#2,d3
	add.l	d3,PF_PA(a4)
	move.l	a4,-(sp)
	move.l	d2,a4			; a4 = groups left in the run
	cmp.l	#-1,d6
	bne	.1hc
	tst.l	d7
	bne	.1hc
	; ---- pen-1-on-0 style (A = -1, X = 0): bits straight out ----
.1hp:	sub.l	a3,a3
	move.l	a6,a2
.1hps:	move.l	(a0),a1
	move.l	8(a1,a3.l),d0
	move.l	4(a0),a1
	or.l	0(a1,a3.l),d0
	move.l	8(a1,a3.l),d1
	move.l	8(a0),a1
	or.l	0(a1,a3.l),d1
	move.l	8(a1,a3.l),d2
	move.l	12(a0),a1
	or.l	0(a1,a3.l),d2
	move.l	8(a1,a3.l),d3
	move.l	16(a0),a1
	or.l	0(a1,a3.l),d3
	move.l	#$FF00FF00,d6
	move.l	#$00FF00FF,d7
	move.l	d0,d4
	and.l	d6,d0
	lsl.l	#8,d4
	and.l	d6,d4
	move.l	d1,d5
	lsr.l	#8,d5
	and.l	d7,d5
	or.l	d5,d0
	and.l	d7,d1
	or.l	d4,d1
	move.l	d2,d4
	and.l	d6,d2
	lsl.l	#8,d4
	and.l	d6,d4
	move.l	d3,d5
	lsr.l	#8,d5
	and.l	d7,d5
	or.l	d5,d2
	and.l	d7,d3
	or.l	d4,d3
	move.l	d0,d5
	swap	d5
	move.w	d2,d5
	swap	d2
	move.w	d2,d0
	move.l	d5,d2
	move.l	d1,d5
	swap	d5
	move.w	d3,d5
	swap	d3
	move.w	d3,d1
	move.l	d5,d3
	move.l	d0,(a2)
	add.l	a5,a2
	move.l	d1,(a2)
	add.l	a5,a2
	move.l	d2,(a2)
	add.l	a5,a2
	move.l	d3,(a2)
	add.l	a5,a2
	addq.l	#4,a3
	cmp.w	#8,a3
	blt	.1hps
	lea	16(a0),a0
	addq.l	#4,a6
	subq.l	#1,a4
	cmp.w	#0,a4
	bne	.1hp
	moveq	#-1,d6			; A/X back (the masks used the regs)
	moveq	#0,d7
	bra	.1hend
	; ---- any pens: (bits AND A) XOR X ----
.1hc:	sub.l	a3,a3
	move.l	a6,a2
.1hcs:	move.l	(a0),a1
	move.l	8(a1,a3.l),d0
	move.l	4(a0),a1
	or.l	0(a1,a3.l),d0
	move.l	8(a1,a3.l),d1
	move.l	8(a0),a1
	or.l	0(a1,a3.l),d1
	move.l	8(a1,a3.l),d2
	move.l	12(a0),a1
	or.l	0(a1,a3.l),d2
	move.l	8(a1,a3.l),d3
	move.l	16(a0),a1
	or.l	0(a1,a3.l),d3
	move.l	d0,d4
	and.l	#$FF00FF00,d0
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d1,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d0
	and.l	#$00FF00FF,d1
	or.l	d4,d1
	move.l	d2,d4
	and.l	#$FF00FF00,d2
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d3,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d2
	and.l	#$00FF00FF,d3
	or.l	d4,d3
	move.l	d0,d5
	swap	d5
	move.w	d2,d5
	swap	d2
	move.w	d2,d0
	move.l	d5,d2
	move.l	d1,d5
	swap	d5
	move.w	d3,d5
	swap	d3
	move.w	d3,d1
	move.l	d5,d3
	and.l	d6,d0
	eor.l	d7,d0
	move.l	d0,(a2)
	add.l	a5,a2
	and.l	d6,d1
	eor.l	d7,d1
	move.l	d1,(a2)
	add.l	a5,a2
	and.l	d6,d2
	eor.l	d7,d2
	move.l	d2,(a2)
	add.l	a5,a2
	and.l	d6,d3
	eor.l	d7,d3
	move.l	d3,(a2)
	add.l	a5,a2
	addq.l	#4,a3
	cmp.w	#8,a3
	blt	.1hcs
	lea	16(a0),a0
	addq.l	#4,a6
	subq.l	#1,a4
	cmp.w	#0,a4
	bne	.1hc
.1hend:	move.l	(sp)+,a4
	tst.l	PF_K(a4)
	bne	.1grp
	movem.l	(sp)+,d2-d7/a2-a6
	rts
.1mix:	moveq	#-1,d2
	move.l	d2,PF_KEY(a4)
	move.l	PF_PT+4(a4),d5		; plane bit
	moveq	#0,d6			; A
	moveq	#0,d7			; X
	moveq	#0,d1
	move.l	a2,a3
.1mo:	moveq	#0,d3
	move.b	(a3),d3
	add.l	d3,d3
	move.l	PF_TN(a4),a1
	btst	#2,SOFF(a3)
	beq.s	.1mn
	move.l	PF_TI(a4),a1
.1mn:	move.w	0(a1,d3.l),d4
	btst	d5,d4
	beq.s	.1m1
	or.l	PF_OWN(a4,d1.l),d7
.1m1:	lsr.w	#8,d4
	btst	d5,d4
	beq.s	.1m2
	or.l	PF_OWN(a4,d1.l),d6
.1m2:	addq.l	#1,a3
	addq.l	#4,d1
	cmp.l	#20,d1
	bne.s	.1mo
.1go:	sub.l	a3,a3			; yy
	move.l	a6,a2			; line pointer
	; ---- the cached part: .1slab to .1gd ----
.1slab:	move.l	(a0),a1
	move.l	8(a1,a3.l),d0
	move.l	4(a0),a1
	or.l	0(a1,a3.l),d0
	move.l	8(a1,a3.l),d1
	move.l	8(a0),a1
	or.l	0(a1,a3.l),d1
	move.l	8(a1,a3.l),d2
	move.l	12(a0),a1
	or.l	0(a1,a3.l),d2
	move.l	8(a1,a3.l),d3
	move.l	16(a0),a1
	or.l	0(a1,a3.l),d3
	move.l	d0,d4
	and.l	#$FF00FF00,d0
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d1,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d0
	and.l	#$00FF00FF,d1
	or.l	d4,d1
	move.l	d2,d4
	and.l	#$FF00FF00,d2
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d3,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d2
	and.l	#$00FF00FF,d3
	or.l	d4,d3
	move.l	d0,d5
	swap	d5
	move.w	d2,d5
	swap	d2
	move.w	d2,d0
	move.l	d5,d2
	move.l	d1,d5
	swap	d5
	move.w	d3,d5
	swap	d3
	move.w	d3,d1
	move.l	d5,d3
	and.l	d6,d0
	eor.l	d7,d0
	and.l	d6,d1
	eor.l	d7,d1
	and.l	d6,d2
	eor.l	d7,d2
	and.l	d6,d3
	eor.l	d7,d3
	move.l	PF_CH(a4),d5
	sub.l	a3,d5			; lines left in the row
	cmp.l	#-1,PF_E(a4)
	bne.s	.1slow
	cmp.l	#4,d5
	blt.s	.1slow
	move.l	d0,(a2)
	add.l	a5,a2
	move.l	d1,(a2)
	add.l	a5,a2
	move.l	d2,(a2)
	add.l	a5,a2
	move.l	d3,(a2)
	add.l	a5,a2
.1next:	addq.l	#4,a3
	cmp.l	PF_CH(a4),a3
	blt	.1slab
.1gd:	lea	16(a0),a0
	addq.l	#4,PF_PA(a4)
	addq.l	#4,a6
	subq.l	#1,PF_K(a4)
	bne	.1grp
	movem.l	(sp)+,d2-d7/a2-a6
	rts
; an edge group or a short last slab: up to four lines, each kept to the
; edge mask - (v ^ dst) & E ^ dst (E = -1 for an interior short slab)
.1slow:	move.l	d6,-(sp)
	move.l	d0,d4
	bsr.s	.1w
	beq.s	.1sd
	move.l	d1,d4
	bsr.s	.1w
	beq.s	.1sd
	move.l	d2,d4
	bsr.s	.1w
	beq.s	.1sd
	move.l	d3,d4
	bsr.s	.1w
.1sd:	move.l	(sp)+,d6
	bra.s	.1next
.1w:	move.l	(a2),d6
	eor.l	d6,d4
	and.l	PF_E(a4),d4
	eor.l	d6,d4
	move.l	d4,(a2)
	add.l	a5,a2
	subq.l	#1,d5
	rts

; ---------------------------------------------------------------------
; pm1 / pm - pfused1 / pfused straight from the MODEL (1.2.8b11). The old
; pair painted from a padded copy of the span's three planes and read a
; glyph pointer per cell from an array the C side built: ~0.5ms a row
; on a stock 020 before a pixel moved, and 10 chip reads a group for the
; pointers. Here a group's characters are one long read from the model
; (the cell before it at -1), its attrs/styles are read in place (styles
; at attrs + PM_SOFF), and each glyph's block address is formed in
; registers: gl + 16c = (gl, 2c * 8). The span's edge groups reach a
; cell past each end - their pixels are outside the edge mask, so what
; they hold is never written. a1 = gl + the slab's line offset.
PM_CHP	= 0		; chars of group 0's c0 (c0-1 at -1)
PM_NG	= 4
PM_CH	= 8
PM_PA	= 12		; attr of cell c0-1 of the current group
PM_BPR	= 16
PM_EF	= 20
PM_EL	= 24
PM_UNI5	= 28
PM_OWN	= 32		; 5 longs
PM_TN	= 52
PM_TI	= 56
PM_K	= 60
PM_E	= 64
PM_KEY	= 68
PM_YY	= 72
PM_GL	= 76
PM_SOFF	= 80
PM_PREF	= 84		; 4 longs: own[0] | .. | own[j], j = 0..3
PM_PT	= 100		; planes: dst.l, pbit.l, A.l, X.l ... then 0

; a mixed group with TWO colours (b11): the cells before the first change
; one key, the rest another - nearly every mixed group (a colour run ends
; inside it). The five owner masks partition the long, so a plane's mask
; is PREF[j-1] where the left colour has the bit, NOT PREF[j-1] where the
; right one has it: two pens lookups for the group instead of five per
; plane (~80 chip reads -> ~8). In: a2 = owner 0's attr, d3 = soff, d0/d1
; = attrs/styles of owners 1-4. Out: d6/d7 = the two pens words (fx<<8 |
; fb), d5 = the left mask. Three or more colours (or none): branch \1,
; with a2/d3 intact. Uses d2/d4, a3.
TWOC	macro
	moveq	#0,d6
	move.b	(a2),d6
	lsl.w	#8,d6
	move.b	0(a2,d3.l),d6		; k0 = attr << 8 | style
	moveq	#0,d4			; j = the first owner that differs
	moveq	#0,d7			; i
.tc\@:	addq.w	#1,d7
	rol.l	#8,d0
	rol.l	#8,d1
	moveq	#0,d2
	move.b	d0,d2
	lsl.w	#8,d2
	move.b	d1,d2			; k(i)
	tst.w	d4
	bne.s	.tj\@
	cmp.w	d6,d2
	beq.s	.tn\@
	move.w	d7,d4
	move.w	d2,d5			; kJ
	bra.s	.tn\@
.tj\@:	cmp.w	d5,d2
	bne	\1			; a third colour
.tn\@:	cmp.w	#4,d7
	bne.s	.tc\@
	tst.w	d4
	beq	\1
	moveq	#0,d2			; wL
	move.w	d6,d2
	lsr.w	#8,d2
	add.l	d2,d2
	move.l	PM_TN(a4),a3
	btst	#2,d6
	beq.s	.tl\@
	move.l	PM_TI(a4),a3
.tl\@:	move.w	0(a3,d2.l),d6
	moveq	#0,d2			; wR
	move.w	d5,d2
	lsr.w	#8,d2
	add.l	d2,d2
	move.l	PM_TN(a4),a3
	btst	#2,d5
	beq.s	.tr\@
	move.l	PM_TI(a4),a3
.tr\@:	move.w	0(a3,d2.l),d7
	subq.w	#1,d4
	lsl.w	#2,d4
	move.l	PM_PREF(a4,d4.w),d5
	endm

; one slab: lines 0..3 of four cells into d0-d3, glyph base \1. In: d4 =
; 2 * the char before the group, d5 = the group's chars (c0 in the top
; byte). Both are used up (the transpose takes d4/d5).
SLAB2	macro
	move.l	8(\1,d4.l*8),d0		; lo(c-1)
	rol.l	#8,d5
	moveq	#0,d4
	move.b	d5,d4
	add.w	d4,d4
	or.l	0(\1,d4.l*8),d0		; hi(c0)
	move.l	8(\1,d4.l*8),d1		; lo(c0)
	rol.l	#8,d5
	moveq	#0,d4
	move.b	d5,d4
	add.w	d4,d4
	or.l	0(\1,d4.l*8),d1
	move.l	8(\1,d4.l*8),d2
	rol.l	#8,d5
	moveq	#0,d4
	move.b	d5,d4
	add.w	d4,d4
	or.l	0(\1,d4.l*8),d2
	move.l	8(\1,d4.l*8),d3
	rol.l	#8,d5
	moveq	#0,d4
	move.b	d5,d4
	add.w	d4,d4
	or.l	0(\1,d4.l*8),d3
	move.l	d0,d4			; transpose a,b,c,d -> lines 0..3
	and.l	#$FF00FF00,d0
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d1,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d0
	and.l	#$00FF00FF,d1
	or.l	d4,d1
	move.l	d2,d4
	and.l	#$FF00FF00,d2
	lsl.l	#8,d4
	and.l	#$FF00FF00,d4
	move.l	d3,d5
	lsr.l	#8,d5
	and.l	#$00FF00FF,d5
	or.l	d5,d2
	and.l	#$00FF00FF,d3
	or.l	d4,d3
	move.l	d0,d5
	swap	d5
	move.w	d2,d5
	swap	d2
	move.w	d2,d0
	move.l	d5,d2
	move.l	d1,d5
	swap	d5
	move.w	d3,d5
	swap	d3
	move.w	d3,d1
	move.l	d5,d3
	endm

; the group's chars for SLAB2, read again for each slab
GCHARS	macro
	moveq	#0,d4
	move.b	-1(a0),d4
	add.w	d4,d4
	move.l	(a0),d5
	endm

	xdef	pm1
pm1:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	48(sp),a4
	move.l	PM_CHP(a4),a0
	move.l	PM_GL(a4),a1
	move.l	PM_BPR(a4),a5
	move.l	PM_PT(a4),a6		; dst, line 0 of the first group
	move.l	PM_NG(a4),PM_K(a4)
	moveq	#-1,d0
	move.l	d0,PM_KEY(a4)
.m1grp:	moveq	#-1,d5			; this group's edge mask
	move.l	PM_K(a4),d0
	cmp.l	PM_NG(a4),d0
	bne.s	.m1nf
	and.l	PM_EF(a4),d5
.m1nf:	cmp.l	#1,d0
	bne.s	.m1nl
	and.l	PM_EL(a4),d5
.m1nl:	move.l	d5,PM_E(a4)
	move.l	PM_PA(a4),a2
	move.l	PM_SOFF(a4),d3
	move.l	1(a2),d0		; attrs c0..c0+3
	move.l	1(a2,d3.l),d1		; styles
	move.l	d0,d2
	ror.l	#8,d2
	cmp.l	d0,d2
	bne	.m1mix
	move.l	d1,d2
	ror.l	#8,d2
	cmp.l	d1,d2
	bne	.m1mix
	tst.l	PM_UNI5(a4)
	beq.s	.m1uni
	cmp.b	(a2),d0
	bne	.m1mix
	cmp.b	0(a2,d3.l),d1
	bne	.m1mix
.m1uni:	moveq	#0,d2
	move.b	d0,d2
	lsl.w	#8,d2
	move.b	d1,d2			; key = attr<<8 | style
	cmp.l	PM_KEY(a4),d2
	beq	.m1run			; same pens as the last group
	move.l	d2,PM_KEY(a4)
	moveq	#0,d3
	move.b	d0,d3
	add.l	d3,d3
	move.l	PM_TN(a4),a3
	btst	#2,d1
	beq.s	.m1n
	move.l	PM_TI(a4),a3
.m1n:	move.w	0(a3,d3.l),d4		; fx<<8 | fb
	move.l	PM_PT+4(a4),d5		; plane bit
	btst	d5,d4
	sne	d7
	extb.l	d7			; X
	lsr.w	#8,d4
	btst	d5,d4
	sne	d6
	extb.l	d6			; A
.m1run:	; an interior uniform group: count the groups after it with the
	; same pens and paint them in a loop with nothing else in it
	cmp.l	#-1,PM_E(a4)
	bne	.m1go
	cmp.l	#8,PM_CH(a4)
	bne	.m1go
	move.l	PM_PA(a4),a2
	move.l	PM_SOFF(a4),a3
	moveq	#1,d2			; groups in the run
	move.l	PM_K(a4),d3
	subq.l	#1,d3			; groups after this one
.m1cnt:	cmp.l	#1,d3			; the last group is an edge: not in a run
	ble.s	.m1hgo
	cmp.l	5(a2),d0		; next group's attrs
	bne.s	.m1hgo
	cmp.l	5(a2,a3.l),d1
	bne.s	.m1hgo
	addq.l	#4,a2
	addq.l	#1,d2
	subq.l	#1,d3
	bra.s	.m1cnt
.m1hgo:	sub.l	d2,PM_K(a4)		; the run's groups are spent here
	move.l	d2,d3
	lsl.l	#2,d3
	add.l	d3,PM_PA(a4)
	move.l	a4,-(sp)
	move.l	d2,a4			; a4 = groups left in the run
	cmp.l	#-1,d6
	bne	.m1hc
	tst.l	d7
	bne	.m1hc
	; ---- pen-1-on-0 style: the bits straight out. The cached loop is
	; .m1hp to .m1hpx (keep it under 256 bytes: vasm -L)
	moveq	#0,d7			; d7 = 2 * c-1, d6 = the chars,
	move.b	-1(a0),d7		; both kept across the two slabs
	add.w	d7,d7
.m1hp:	move.l	(a0)+,d6
	move.l	a6,a2
	sub.l	a3,a3
.m1hps:	move.l	d7,d4
	move.l	d6,d5
	SLAB2	a1
	move.l	d0,(a2)
	add.l	a5,a2
	move.l	d1,(a2)
	add.l	a5,a2
	move.l	d2,(a2)
	add.l	a5,a2
	move.l	d3,(a2)
	add.l	a5,a2
	addq.l	#4,a1
	addq.l	#4,a3
	cmp.w	#8,a3
	blt	.m1hps
	subq.l	#8,a1
	moveq	#0,d7			; c3 is the next group's c-1
	move.b	d6,d7
	add.w	d7,d7
	addq.l	#4,a6
	subq.l	#1,a4
	cmp.w	#0,a4
	bne	.m1hp
.m1hpx:	moveq	#-1,d6			; A/X back (the loop used the regs):
	moveq	#0,d7			; a cached key trusts them
	bra	.m1hend
	; ---- any pens: (bits AND A) XOR X ----
.m1hc:	move.l	a6,a2
	sub.l	a3,a3
.m1hcs:	GCHARS
	SLAB2	a1
	and.l	d6,d0
	eor.l	d7,d0
	move.l	d0,(a2)
	add.l	a5,a2
	and.l	d6,d1
	eor.l	d7,d1
	move.l	d1,(a2)
	add.l	a5,a2
	and.l	d6,d2
	eor.l	d7,d2
	move.l	d2,(a2)
	add.l	a5,a2
	and.l	d6,d3
	eor.l	d7,d3
	move.l	d3,(a2)
	add.l	a5,a2
	addq.l	#4,a1
	addq.l	#4,a3
	cmp.w	#8,a3
	blt	.m1hcs
	subq.l	#8,a1
	addq.l	#4,a0
	addq.l	#4,a6
	subq.l	#1,a4
	cmp.w	#0,a4
	bne	.m1hc
.m1hend: move.l	(sp)+,a4
	tst.l	PM_K(a4)
	bne	.m1grp
	movem.l	(sp)+,d2-d7/a2-a6
	rts
.m1mix:	moveq	#-1,d2
	move.l	d2,PM_KEY(a4)
	TWOC	.m1mg
	move.l	d5,d3
	not.l	d3			; the right colour's bits
	move.l	PM_PT+4(a4),d0		; plane bit
	moveq	#0,d1			; A
	moveq	#0,d2			; X
	move.l	d0,d4
	addq.l	#8,d4
	btst	d4,d6
	beq.s	.m1t1
	or.l	d5,d1
.m1t1:	btst	d4,d7
	beq.s	.m1t2
	or.l	d3,d1
.m1t2:	btst	d0,d6
	beq.s	.m1t3
	or.l	d5,d2
.m1t3:	btst	d0,d7
	beq.s	.m1t4
	or.l	d3,d2
.m1t4:	move.l	d1,d6
	move.l	d2,d7
	bra	.m1go
.m1mg:	move.l	PM_PT+4(a4),d5		; plane bit
	moveq	#0,d6			; A
	moveq	#0,d7			; X
	moveq	#0,d1			; owner * 4
	move.l	PM_SOFF(a4),d0
.m1mo:	moveq	#0,d3			; a2 walks the five owners' attrs
	move.b	(a2),d3
	add.l	d3,d3
	move.l	PM_TN(a4),a3
	btst	#2,0(a2,d0.l)
	beq.s	.m1mn
	move.l	PM_TI(a4),a3
.m1mn:	move.w	0(a3,d3.l),d4
	btst	d5,d4
	beq.s	.m1m1
	or.l	PM_OWN(a4,d1.l),d7
.m1m1:	lsr.w	#8,d4
	btst	d5,d4
	beq.s	.m1m2
	or.l	PM_OWN(a4,d1.l),d6
.m1m2:	addq.l	#1,a2
	addq.l	#4,d1
	cmp.l	#20,d1
	bne.s	.m1mo
.m1go:	sub.l	a3,a3			; yy
	move.l	a6,a2			; line pointer
.m1slab: GCHARS
	SLAB2	a1
	and.l	d6,d0
	eor.l	d7,d0
	and.l	d6,d1
	eor.l	d7,d1
	and.l	d6,d2
	eor.l	d7,d2
	and.l	d6,d3
	eor.l	d7,d3
	move.l	PM_CH(a4),d5
	sub.l	a3,d5			; lines left in the row
	cmp.l	#-1,PM_E(a4)
	bne.s	.m1slow
	cmp.l	#4,d5
	blt.s	.m1slow
	move.l	d0,(a2)
	add.l	a5,a2
	move.l	d1,(a2)
	add.l	a5,a2
	move.l	d2,(a2)
	add.l	a5,a2
	move.l	d3,(a2)
	add.l	a5,a2
.m1next: addq.l	#4,a1
	addq.l	#4,a3
	cmp.l	PM_CH(a4),a3
	blt	.m1slab
	sub.l	a3,a1			; back to the cache base
	addq.l	#4,a0
	addq.l	#4,PM_PA(a4)
	addq.l	#4,a6
	subq.l	#1,PM_K(a4)
	bne	.m1grp
	movem.l	(sp)+,d2-d7/a2-a6
	rts
; an edge group or a short last slab: up to four lines, each kept to the
; edge mask - (v ^ dst) & E ^ dst
.m1slow: move.l	d6,-(sp)
	move.l	d0,d4
	bsr.s	.m1w
	beq.s	.m1sd
	move.l	d1,d4
	bsr.s	.m1w
	beq.s	.m1sd
	move.l	d2,d4
	bsr.s	.m1w
	beq.s	.m1sd
	move.l	d3,d4
	bsr.s	.m1w
.m1sd:	move.l	(sp)+,d6
	bra	.m1next
.m1w:	move.l	(a2),d6
	eor.l	d6,d4
	and.l	PM_E(a4),d4
	eor.l	d6,d4
	move.l	d4,(a2)
	add.l	a5,a2
	subq.l	#1,d5
	rts

; two lines (\1, \2) of every plane, register path: plane p = line
; AND Ap (d6, d7, d5), dst a2/a3/a4, two lines down after
F3TWO	macro
	move.l	\1,d4
	and.l	d6,d4
	move.l	d4,(a2)
	move.l	\1,d4
	and.l	d7,d4
	move.l	d4,(a3)
	and.l	d5,\1
	move.l	\1,(a4)
	move.l	\2,d4
	and.l	d6,d4
	move.l	d4,0(a2,a5.l)
	move.l	\2,d4
	and.l	d7,d4
	move.l	d4,0(a3,a5.l)
	and.l	d5,\2
	move.l	\2,0(a4,a5.l)
	lea	0(a2,a5.l*2),a2
	lea	0(a3,a5.l*2),a3
	lea	0(a4,a5.l*2),a4
	endm
F2TWO	macro
	move.l	\1,d4
	and.l	d6,d4
	move.l	d4,(a2)
	and.l	d7,\1
	move.l	\1,(a3)
	move.l	\2,d4
	and.l	d6,d4
	move.l	d4,0(a2,a5.l)
	and.l	d7,\2
	move.l	\2,0(a3,a5.l)
	lea	0(a2,a5.l*2),a2
	lea	0(a3,a5.l*2),a3
	endm

	xdef	pm
pm:
	movem.l	d2-d7/a2-a6,-(sp)
	move.l	48(sp),a4
	move.l	PM_CHP(a4),a0
	move.l	PM_GL(a4),a1
	move.l	PM_BPR(a4),a5
	sub.l	a6,a6			; group byte offset (+ slab lines)
	move.l	PM_NG(a4),PM_K(a4)
	moveq	#-1,d0
	move.l	d0,PM_KEY(a4)
	move.l	PM_EF(a4),d5		; first group: its edge
.mgrp:	cmp.l	#1,PM_K(a4)
	bne.s	.mnl
	and.l	PM_EL(a4),d5
.mnl:	move.l	d5,PM_E(a4)
	; ---- the group's colour masks into PM_PT (only when they change) ----
	move.l	PM_PA(a4),a2
	move.l	PM_SOFF(a4),d3
	move.l	1(a2),d0		; attrs c0..c0+3
	move.l	1(a2,d3.l),d1		; styles
	move.l	d0,d2
	ror.l	#8,d2
	cmp.l	d0,d2
	bne	.mmix
	move.l	d1,d2
	ror.l	#8,d2
	cmp.l	d1,d2
	bne	.mmix
	tst.l	PM_UNI5(a4)
	beq.s	.muni
	cmp.b	(a2),d0
	bne	.mmix
	cmp.b	0(a2,d3.l),d1
	bne	.mmix
.muni:	moveq	#0,d2
	move.b	d0,d2
	lsl.w	#8,d2
	move.b	d1,d2			; key = attr<<8 | style
	cmp.l	PM_KEY(a4),d2
	beq	.mslabs
	move.l	d2,PM_KEY(a4)
	moveq	#0,d3
	move.b	d0,d3
	add.l	d3,d3
	move.l	PM_TN(a4),a3
	btst	#2,d1
	beq.s	.mn
	move.l	PM_TI(a4),a3
.mn:	move.w	0(a3,d3.l),d4		; fx<<8 | fb
	move.w	d4,d3
	lsr.w	#8,d3			; fx
	lea	PM_PT(a4),a2
.mu:	tst.l	(a2)
	beq	.mslabs
	move.l	4(a2),d6		; plane bit
	btst	d6,d3
	sne	d7
	extb.l	d7
	move.l	d7,8(a2)		; A
	btst	d6,d4
	sne	d7
	extb.l	d7
	move.l	d7,12(a2)		; X
	lea	16(a2),a2
	bra.s	.mu
.mmix:	moveq	#-1,d2
	move.l	d2,PM_KEY(a4)
	TWOC	.mmg
	move.l	d5,d3
	not.l	d3
	lea	PM_PT(a4),a3
.m2p:	tst.l	(a3)
	beq	.mslabs
	move.l	4(a3),d0		; plane bit
	moveq	#0,d1			; A
	moveq	#0,d2			; X
	move.l	d0,d4
	addq.l	#8,d4
	btst	d4,d6
	beq.s	.m2a
	or.l	d5,d1
.m2a:	btst	d4,d7
	beq.s	.m2b
	or.l	d3,d1
.m2b:	btst	d0,d6
	beq.s	.m2c
	or.l	d5,d2
.m2c:	btst	d0,d7
	beq.s	.m2d
	or.l	d3,d2
.m2d:	move.l	d1,8(a3)
	move.l	d2,12(a3)
	lea	16(a3),a3
	bra.s	.m2p
.mmg:	move.l	a1,-(sp)		; (a1 holds the tables here)
	move.l	PM_SOFF(a4),d0
	lea	PM_PT(a4),a3
.mm:	tst.l	(a3)
	beq.s	.mmd
	move.l	4(a3),d6		; plane bit
	moveq	#0,d2			; A
	moveq	#0,d7			; X
	moveq	#0,d1			; owner * 4
	move.l	PM_PA(a4),a2		; owner's attr
.mmo:	moveq	#0,d3
	move.b	(a2),d3
	add.l	d3,d3
	move.l	PM_TN(a4),a1
	btst	#2,0(a2,d0.l)
	beq.s	.mmn
	move.l	PM_TI(a4),a1
.mmn:	move.w	0(a1,d3.l),d4		; fx<<8 | fb
	btst	d6,d4
	beq.s	.mm1
	or.l	PM_OWN(a4,d1.l),d7
.mm1:	lsr.w	#8,d4
	btst	d6,d4
	beq.s	.mm2
	or.l	PM_OWN(a4,d1.l),d2
.mm2:	addq.l	#1,a2
	addq.l	#4,d1
	cmp.l	#20,d1
	bne.s	.mmo
	move.l	d2,8(a3)
	move.l	d7,12(a3)
	lea	16(a3),a3
	bra.s	.mm
.mmd:	move.l	(sp)+,a1
	; ---- the slabs: lines, then every plane's four longs ----
.mslabs:
	; b11: the register path - no edge, 8 lines, 2 or 3 planes, and no
	; X anywhere (pens on background 0, nothing inverse: the common
	; colour row). Every plane is then just (bits AND A), and the masks
	; and the three destinations fit in registers: none of the slow
	; path's four reads a plane a slab.
	cmp.l	#-1,PM_E(a4)
	bne	.mslow
	cmp.l	#8,PM_CH(a4)
	bne	.mslow
	tst.l	PM_PT+12(a4)		; X0
	bne	.mslow
	tst.l	PM_PT+28(a4)		; X1
	bne	.mslow
	move.l	PM_PT+32(a4),d4		; plane 2's dst
	beq	.f2
	tst.l	PM_PT+44(a4)		; X2
	bne	.mslow
	tst.l	PM_PT+48(a4)		; a fourth plane: the slow path
	bne	.mslow
	movem.l	a4/a6,-(sp)
	move.l	PM_PT+40(a4),-(sp)	; A2 - read once a slab, (sp)
	move.l	PM_PT+8(a4),d6		; A0
	move.l	PM_PT+24(a4),d7		; A1
	move.l	PM_PT(a4),a2
	add.l	a6,a2
	move.l	PM_PT+16(a4),a3
	add.l	a6,a3
	move.l	d4,a4
	add.l	a6,a4
	sub.l	a6,a6			; slab 0
.f3s:	GCHARS
	SLAB2	a1
	move.l	(sp),d5
	F3TWO	d0,d1
	F3TWO	d2,d3
	cmp.w	#0,a6
	bne.s	.f3e
	addq.l	#4,a1
	addq.w	#1,a6
	bra	.f3s
.f3e:	subq.l	#4,a1
	addq.l	#4,sp
	movem.l	(sp)+,a4/a6
	bra	.mnext
.f2:	move.l	PM_PT+8(a4),d6		; two planes
	move.l	PM_PT+24(a4),d7
	move.l	a6,-(sp)
	move.l	PM_PT(a4),a2
	add.l	a6,a2
	move.l	PM_PT+16(a4),a3
	add.l	a6,a3
	sub.l	a6,a6
.f2s:	GCHARS
	SLAB2	a1
	F2TWO	d0,d1
	F2TWO	d2,d3
	cmp.w	#0,a6
	bne.s	.f2e
	addq.l	#4,a1
	addq.w	#1,a6
	bra	.f2s
.f2e:	subq.l	#4,a1
	move.l	(sp)+,a6
	bra	.mnext
.mslow:	moveq	#0,d5
	move.l	d5,PM_YY(a4)
.mslab:	GCHARS
	SLAB2	a1
	move.l	PM_CH(a4),d5
	sub.l	PM_YY(a4),d5		; lines left in the row
	lea	PM_PT(a4),a2
.mpl:	move.l	(a2),d4
	beq.s	.mpd
	move.l	d4,a3
	add.l	a6,a3
	movem.l	8(a2),d6/d7		; A, X
	lea	16(a2),a2
	cmp.l	#-1,PM_E(a4)
	bne.s	.mpe
	cmp.l	#4,d5
	blt.s	.mpe
	move.l	d0,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	add.l	a5,a3
	move.l	d1,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	add.l	a5,a3
	move.l	d2,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	add.l	a5,a3
	move.l	d3,d4
	and.l	d6,d4
	eor.l	d7,d4
	move.l	d4,(a3)
	bra.s	.mpl
.mpd:	addq.l	#4,PM_YY(a4)
	addq.l	#4,a1
	lea	0(a6,a5.l*4),a6		; four lines down
	move.l	PM_YY(a4),d5
	cmp.l	PM_CH(a4),d5
	blt	.mslab
	sub.l	d5,a1			; group done: slab offsets off
	move.l	a5,d4
	mulu.l	d5,d4
	sub.l	d4,a6
.mnext:	addq.l	#4,a6
	addq.l	#4,a0
	addq.l	#4,PM_PA(a4)
	moveq	#-1,d5
	subq.l	#1,PM_K(a4)
	bne	.mgrp
	movem.l	(sp)+,d2-d7/a2-a6
	rts
; an edge group or a short slab: each line kept to the edge mask
.mpe:	movem.l	d5/a2,-(sp)		; (.mpr borrows a2)
	move.l	d0,d4
	bsr.s	.mpr
	beq.s	.mped
	move.l	d1,d4
	bsr.s	.mpr
	beq.s	.mped
	move.l	d2,d4
	bsr.s	.mpr
	beq.s	.mped
	move.l	d3,d4
	bsr.s	.mpr
.mped:	movem.l	(sp)+,d5/a2
	bra	.mpl
.mpr:	and.l	d6,d4
	eor.l	d7,d4
	move.l	(a3),a2
	exg	a2,d6			; d6 = dst, a2 = A (kept)
	eor.l	d6,d4
	and.l	PM_E(a4),d4
	eor.l	d6,d4
	exg	a2,d6
	move.l	d4,(a3)
	add.l	a5,a3
	subq.l	#1,d5
	rts

; ---------------------------------------------------------------------
; putseg - engine.c's putrun for one segment that fits the row (1.2.8b11):
; the model cells (chars copied, attr and style filled), the row length,
; the dirty mark - putrun's body, slgrow and dfmark in one pass. On a stock
; 020 that path ran ~200 instructions a segment through five calls (C +
; abcopy + two abfills), none of it cache-resident; sgr-colour has 2400
; segments of 8 chars. Mirrors engine.c exactly (the harness compares).
; void putseg(struct fx *x, struct con *k, const UBYTE *s, LONG fit,
;             LONG at, LONG sty)   - fit >= 1, cx + fit <= cols
	include	"conoffs.i"
FX_DFFULL = 12
FX_DFLO	= 16
FX_DFHI	= 20
FX_DFGEN = 28
FX_DFD	= 44
FX_DFX0	= 48
FX_DFX1	= 52

; fill d0 bytes at a0 with the byte in d1 (d1 = the byte in all four)
PFILL	macro
	cmp.l	#8,d0
	blt.s	.fb\@
.fa\@:	move.l	a0,d2
	and.w	#3,d2
	beq.s	.fl\@
	move.b	d1,(a0)+
	subq.l	#1,d0
	bra.s	.fa\@
.fl\@:	move.l	d0,d2
	lsr.l	#2,d2
	subq.l	#1,d2
.fll\@:	move.l	d1,(a0)+
	dbra	d2,.fll\@
	and.l	#3,d0
.fb\@:	subq.l	#1,d0
	bmi.s	.fx\@
.fbl\@:	move.b	d1,(a0)+
	dbra	d0,.fbl\@
.fx\@:
	endm

	xdef	putseg
putseg:
	movem.l	d2-d7/a2-a4,-(sp)	; 36 bytes
	move.l	40(sp),a2		; x
	move.l	44(sp),a3		; k
	move.l	48(sp),a4		; s
	move.l	52(sp),d4		; fit
	move.l	CON_sbtop(a3),d6	; i = the ring row
	add.l	CON_cy(a3),d6
	cmp.l	CON_sbmax(a3),d6
	blt.s	.p1
	sub.l	CON_sbmax(a3),d6
.p1:	move.l	d6,d7
	mulu.l	CON_cols(a3),d7
	add.l	CON_cx(a3),d7		; d7 = off
	move.l	CON_sw(a3),d0		; slgrow
	beq.s	.p2
	add.l	CON_sbmax(a3),d0
	addq.l	#1,d0
	and.l	#-2,d0
	move.l	d0,a0
	move.l	CON_cx(a3),d1
	add.l	d4,d1			; cx + fit
	moveq	#0,d0
	move.w	0(a0,d6.l*2),d0
	cmp.l	d1,d0
	bge.s	.p2
	move.w	d1,0(a0,d6.l*2)
.p2:	move.l	CON_sb(a3),a0		; chars
	add.l	d7,a0
	move.l	a4,a1
	move.l	d4,d0
	cmp.l	#8,d0
	blt.s	.cb
.ca:	move.l	a0,d2			; the target long-aligned, the
	and.w	#3,d2			; source as it comes (020 takes it)
	beq.s	.cl
	move.b	(a1)+,(a0)+
	subq.l	#1,d0
	bra.s	.ca
.cl:	move.l	d0,d2
	lsr.l	#2,d2
	subq.l	#1,d2
.cll:	move.l	(a1)+,(a0)+
	dbra	d2,.cll
	and.l	#3,d0
.cb:	subq.l	#1,d0
	bmi.s	.cx
.cbl:	move.b	(a1)+,(a0)+
	dbra	d0,.cbl
.cx:	move.l	56(sp),d1		; attrs
	move.b	d1,d2
	lsl.w	#8,d1
	move.b	d2,d1
	move.w	d1,d2
	swap	d1
	move.w	d2,d1
	move.l	CON_sa(a3),a0
	add.l	d7,a0
	move.l	d4,d0
	PFILL
	move.l	60(sp),d1		; styles
	move.b	d1,d2
	lsl.w	#8,d1
	move.b	d2,d1
	move.w	d1,d2
	swap	d1
	move.w	d2,d1
	move.l	CON_ss(a3),a0
	add.l	d7,a0
	move.l	d4,d0
	PFILL
	; dfmark(x, k, cy, cx, cx + fit - 1)
	move.l	FX_DFFULL(a2),a0
	tst.l	(a0)
	bne.s	.pd
	move.l	CON_cy(a3),d0		; r
	bmi.s	.pd
	cmp.l	CON_rows(a3),d0
	bge.s	.pd
	move.l	CON_cx(a3),d1		; x0
	move.l	d1,d2
	add.l	d4,d2
	subq.l	#1,d2			; x1
	move.l	FX_DFD(a2),a0
	move.l	(a0),a0			; d
	move.l	FX_DFGEN(a2),a1
	move.l	(a1),d3			; gen
	cmp.b	0(a0,d0.l),d3
	bne.s	.pn
	move.l	FX_DFX0(a2),a1
	move.l	(a1),a1
	moveq	#0,d5
	move.b	0(a1,d0.l),d5
	cmp.l	d5,d1
	bge.s	.pm1
	move.b	d1,0(a1,d0.l)
.pm1:	move.l	FX_DFX1(a2),a1
	move.l	(a1),a1
	moveq	#0,d5
	move.b	0(a1,d0.l),d5
	cmp.l	d5,d2
	ble.s	.plh
	move.b	d2,0(a1,d0.l)
	bra.s	.plh
.pn:	move.b	d3,0(a0,d0.l)
	move.l	FX_DFX0(a2),a1
	move.l	(a1),a1
	move.b	d1,0(a1,d0.l)
	move.l	FX_DFX1(a2),a1
	move.l	(a1),a1
	move.b	d2,0(a1,d0.l)
.plh:	move.l	FX_DFLO(a2),a0
	cmp.l	(a0),d0
	bge.s	.ph
	move.l	d0,(a0)
.ph:	move.l	FX_DFHI(a2),a0
	cmp.l	(a0),d0
	ble.s	.pd
	move.l	d0,(a0)
.pd:	movem.l	(sp)+,d2-d7/a2-a4
	rts

; ---------------------------------------------------------------------
; abfill / abcopy - engine.c's bfill/bcopy: a long a store, two
; instructions a long (gcc's loop was six - on a stock 020 every
; instruction is fetched over the chip bus, so the count is the time)
; void abfill(UBYTE *p, ULONG v, LONG n)   v = the byte
; void abcopy(UBYTE *d, const UBYTE *s, LONG n)
	xdef	abfill
	xdef	abcopy
abfill:
	move.l	d2,-(sp)
	move.l	8(sp),a0
	move.l	12(sp),d0
	move.l	16(sp),d1
	ble.s	.bx
	cmp.l	#8,d1
	blt.s	.bb
	move.b	d0,d2
	lsl.w	#8,d0
	move.b	d2,d0
	move.w	d0,d2
	swap	d0
	move.w	d2,d0			; the byte in all four
.ba:	move.l	a0,d2
	and.w	#3,d2
	beq.s	.bl
	move.b	d0,(a0)+
	subq.l	#1,d1
	bra.s	.ba
.bl:	move.l	d1,d2
	lsr.l	#2,d2
	subq.l	#1,d2
.bll:	move.l	d0,(a0)+
	dbra	d2,.bll
	and.l	#3,d1
	beq.s	.bx
.bb:	subq.l	#1,d1
.bbl:	move.b	d0,(a0)+
	dbra	d1,.bbl
.bx:	move.l	(sp)+,d2
	rts
abcopy:
	move.l	d2,-(sp)
	move.l	8(sp),a0
	move.l	12(sp),a1
	move.l	16(sp),d1
	ble.s	.cx
	cmp.l	#8,d1
	blt.s	.cb
.ca:	move.l	a0,d2
	and.w	#3,d2
	beq.s	.cl
	move.b	(a1)+,(a0)+
	subq.l	#1,d1
	bra.s	.ca
.cl:	move.l	d1,d2
	lsr.l	#2,d2
	subq.l	#1,d2
.cll:	move.l	(a1)+,(a0)+
	dbra	d2,.cll
	and.l	#3,d1
	beq.s	.cx
.cb:	subq.l	#1,d1
.cbl:	move.b	(a1)+,(a0)+
	dbra	d1,.cbl
.cx:	move.l	(sp)+,d2
	rts
