#!/usr/bin/env bash
# build.sh - engine.c -> engine.bin, the position-independent blob the
# handler INCBINs. Linked at two addresses: the images must be identical
# (no absolute address anywhere), or the build fails.
set -e
cd "$(dirname "$0")"
T=$HOME/opt/m68k-elf/bin/m68k-elf
python3 genstruct.py ../ccon-handler.e con.h >/dev/null
$T-gcc -m68020 -O2 -fno-late-combine-instructions -fno-strict-aliasing -fomit-frame-pointer -ffreestanding -fno-builtin \
  -fno-tree-loop-distribute-patterns -fno-pic -mpcrel -Wall -c engine.c -o engine.o
$T-as -m68020 entry.s -o entry.o
vasmm68k_mot -Felf -m68020 -quiet -o pgroups.o pgroups.s
for a in 0 0x4000; do
  $T-ld -nostdlib -e _start -Ttext=$a entry.o engine.o pgroups.o -o engine-$a.elf
  $T-objcopy -O binary -j .text engine-$a.elf engine-$a.bin
done
if ! cmp -s engine-0.bin engine-0x4000.bin; then
  echo "build.sh: engine.bin is NOT position independent" >&2; exit 1
fi
for o in engine.o pgroups.o; do
  if $T-readelf -S $o | grep -E '\.(data|bss|rodata)' | grep -v -E ' 0+ 00 ' | grep -q .; then
    echo "build.sh: $o has data" >&2; exit 1
  fi
done
cp engine-0.bin engine.bin
rm -f engine-0x4000.bin engine-0x4000.elf
echo "engine.bin $(stat -c %s engine.bin) bytes"
