# nfs-handler - cross-built with Bebbo's m68k-amigaos-gcc.
# No startup code, no libc: the handler is its own world (see the
# comment atop nfs-handler.c). -fno-toplevel-reorder keeps aminfs_entry
# first in the text hunk, which is what makes it the entry point.

CC      = $(HOME)/opt/amiga/bin/m68k-amigaos-gcc
CFLAGS  = -O2 -noixemul -fomit-frame-pointer \
          -Wall -Wno-pointer-sign -nostartfiles -nostdlib
LIBGCC  = $(shell $(CC) -noixemul -print-libgcc-file-name)

all: nfs-handler NFSDismount

# entry.o MUST stay first: it is the entry point (see entry.c).
nfs-handler: entry.c nfs-handler.c
	$(CC) $(CFLAGS) -c entry.c -o entry.o
	$(CC) $(CFLAGS) -c nfs-handler.c -o nfs-handler.o
	$(CC) $(CFLAGS) entry.o nfs-handler.o -o nfs-handler $(LIBGCC)

NFSDismount: NFSDismount.c
	$(CC) -O2 -noixemul -Wall -Wno-pointer-sign NFSDismount.c -o NFSDismount

# Protocol harness against the live Linux nfsd (no Amiga in the loop).
test:
	python3 tests/nfswire.py selftest 192.168.68.117 /home/creep/nfs-share

clean:
	rm -f nfs-handler NFSDismount

.PHONY: all test clean
