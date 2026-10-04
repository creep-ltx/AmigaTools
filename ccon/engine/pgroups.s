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
