# cdiff - cross-built with Bebbo's gcc (/opt/amiga, not on PATH).
# `make test` proves the engine on the host AND under vamos before
# anything boots - the harness-first rule.

CC      = /opt/amiga/bin/m68k-amigaos-gcc
CFLAGS  = -O2 -noixemul -fomit-frame-pointer -Wall
HOSTCC  = cc
DEPLOY  = /home/creep/Documents/FS-UAE/Hard Drives/Dump/Code

all: cdiff

cdiff: cdiff.c diff.c diff.h
	$(CC) $(CFLAGS) cdiff.c diff.c -o cdiff

test: test-host test-vamos

test-host: tests/difftest.c diff.c diff.h
	$(HOSTCC) -O2 -Wall -I. -o tests/difftest-host tests/difftest.c diff.c
	tests/difftest-host

test-vamos: tests/difftest.c diff.c diff.h
	$(CC) $(CFLAGS) -I. tests/difftest.c diff.c -o tests/difftest
	vamos -q tests/difftest

deploy: cdiff
	cp cdiff "$(DEPLOY)/cdiff"

clean:
	rm -f cdiff tests/difftest tests/difftest-host

.PHONY: all test test-host test-vamos deploy clean
