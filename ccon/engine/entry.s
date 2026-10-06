| engine.bin's entry table: the handler calls offset 0 (frun), 4 (fcheck),
| 8 (ppaint), 12 (gshift), 16 (wacc), 20 (cflush), 24 (cfout_e), 28 (wchar), 32 (unused:
| returns 0 - drain was removed by Audit8 J31, the slot keeps mscan at 36), 36 (mscan)
	.text
	.globl _start
_start:
	bra.w	frun
	bra.w	fcheck
	bra.w	ppaint
	bra.w	gshift
	bra.w	wacc
	bra.w	cflush
	bra.w	cfout_e
	bra.w	wchar
	moveq	#0,%d0		| 32: was drain - 4 bytes, like a bra.w
	rts
	bra.w	mscan
