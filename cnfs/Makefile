# cnfs-handler - cross-built with Bebbo's m68k-amigaos-gcc.
# No startup code, no libc: the handler is its own world (see the
# comment atop cnfs-handler.c). -fno-toplevel-reorder keeps cnfs_entry
# first in the text hunk, which is what makes it the entry point.

CC      = $(HOME)/opt/amiga/bin/m68k-amigaos-gcc
CFLAGS  = -O2 -noixemul -fomit-frame-pointer \
          -Wall -Wno-pointer-sign -nostartfiles -nostdlib
LIBGCC  = $(shell $(CC) -noixemul -print-libgcc-file-name)

all: cnfs-handler

# entry.o MUST stay first: it is the entry point (see entry.c).
cnfs-handler: entry.c cnfs-handler.c
	$(CC) $(CFLAGS) -c entry.c -o entry.o
	$(CC) $(CFLAGS) -c cnfs-handler.c -o cnfs-handler.o
	$(CC) $(CFLAGS) entry.o cnfs-handler.o -o cnfs-handler $(LIBGCC)

# Protocol harness against the live Linux nfsd (no Amiga in the loop).
test:
	python3 tests/nfswire.py selftest 192.168.68.117 /home/creep/nfs-share

clean:
	rm -f cnfs-handler

.PHONY: all test clean
