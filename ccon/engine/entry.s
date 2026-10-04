| engine.bin's entry table: the handler calls offset 0 (frun), 4 (fcheck),
| 8 (ppaint), 12 (gshift), 16 (wacc), 20 (cflush), 24 (cfout_e), 28 (wchar), 32 (drain)
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
	bra.w	drain
