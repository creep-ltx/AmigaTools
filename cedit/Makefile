# cedit - cross-built with Bebbo's gcc (/opt/amiga, not on PATH).
# Builds against the shared GUI chassis in ../ltxgui rather than a
# copy of it: one fix, both tools.

CC      = /opt/amiga/bin/m68k-amigaos-gcc
GUI     = ../ltxgui
CFLAGS  = -O2 -noixemul -fomit-frame-pointer -Wall -I$(GUI)
DEPLOY  = /home/creep/Documents/FS-UAE/Hard Drives/Dump/Code

HOSTCC  = cc

all: cedit

cedit: cedit.c edbuf.c edbuf.h $(GUI)/ltxwin.c $(GUI)/ltxwin.h
	$(CC) $(CFLAGS) cedit.c edbuf.c $(GUI)/ltxwin.c -o cedit

# the harness-first rule: edbuf is proven on the host AND under vamos
# before anything is deployed. cdiff's b100 found a gcc -O2
# miscompilation on m68k that a host-only test could not have seen.
test: test-host test-vamos

test-host: tests/edtest.c edbuf.c edbuf.h
	$(HOSTCC) -O2 -Wall -I. -o tests/edtest-host tests/edtest.c edbuf.c
	tests/edtest-host

# -s 64: a 64K vamos stack so the StackSwap trampoline never engages
# there (vamos's StackSwap is broken; real shells need it)
test-vamos: tests/edtest.c edbuf.c edbuf.h
	$(CC) $(CFLAGS) -I. tests/edtest.c edbuf.c -o tests/edtest
	vamos -q -s 64 tests/edtest

deploy: cedit
	cp cedit "$(DEPLOY)/cedit"

clean:
	rm -f cedit tests/edtest tests/edtest-host

.PHONY: all test test-host test-vamos deploy clean
