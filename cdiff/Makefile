# cdiff - cross-built with Bebbo's gcc (/opt/amiga, not on PATH).
# `make test` proves the engine on the host AND under vamos before
# anything boots - the harness-first rule.

CC      = /opt/amiga/bin/m68k-amigaos-gcc
CFLAGS  = -O2 -noixemul -fomit-frame-pointer -Wall -I$(GUI)
HOSTCC  = cc
DEPLOY  = /home/creep/Documents/FS-UAE/Hard Drives/Dump/Code
# cedit b0: the shared GUI chassis, built from here rather than
# copied - one fix, both tools
GUI     = ../ltxgui

all: cdiff

cdiff: cdiff.c diff.c diff.h $(GUI)/ltxwin.c $(GUI)/ltxwin.h
	$(CC) $(CFLAGS) cdiff.c diff.c $(GUI)/ltxwin.c -o cdiff

test: test-host test-vamos

test-host: tests/difftest.c diff.c diff.h
	$(HOSTCC) -O2 -Wall -I. -o tests/difftest-host tests/difftest.c diff.c
	tests/difftest-host

# -s 64: a 64K vamos stack so cdiff's StackSwap trampoline never
# engages there (vamos's StackSwap is broken; real shells need it)
test-vamos: tests/difftest.c diff.c diff.h
	$(CC) $(CFLAGS) -I. tests/difftest.c diff.c -o tests/difftest
	vamos -q -s 64 tests/difftest

deploy: cdiff
	cp cdiff "$(DEPLOY)/cdiff"

clean:
	rm -f cdiff tests/difftest tests/difftest-host

.PHONY: all test test-host test-vamos deploy clean
