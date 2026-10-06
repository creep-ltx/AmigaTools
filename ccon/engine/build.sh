#!/usr/bin/env bash
# build.sh - engine.c -> engine.bin, the position-independent blob the
# handler INCBINs. Linked at two addresses: the images must be identical
# (no absolute address anywhere), or the build fails.
set -e
cd "$(dirname "$0")"
T=$HOME/opt/m68k-elf/bin/m68k-elf
python3 genstruct.py ../ccon-handler.e con.h >/dev/null
# Audit8 J29: what E and C agree on by hand - the console's size (E's
# FXCONSIZE vs the generated con.h) and the shared buffer sizes
csize=$(sed -n 's/.*size \([0-9]*\) \*\/.*/\1/p' con.h)
esize=$(sed -n 's/^ *FXCONSIZE=\([0-9]*\).*/\1/p' ../ccon-handler.e)
if [ "$csize" != "$esize" ]; then
  echo "build.sh: FXCONSIZE=$esize in ccon-handler.e, con.h says $csize" >&2; exit 1
fi
for k in WOBSZ DFROWS INQMAX; do
  ev=$(sed -n "s/^ *$k=\([0-9]*\).*/\1/p" ../ccon-handler.e)
  cv=$(sed -n "s/^#define $k \([0-9]*\).*/\1/p" engine.c)
  if [ -z "$ev" ] || [ "$ev" != "$cv" ]; then
    echo "build.sh: $k is '$ev' in ccon-handler.e, '$cv' in engine.c" >&2; exit 1
  fi
done
# the console's field offsets for the asm (CON_name = offset), from con.h
awk '/^  LONG [a-z0-9_]+; \/\* [0-9]+ \*\//{gsub(";","",$2); print "CON_"$2"\t= "$4}' con.h > conoffs.i
$T-gcc -m68020 -O2 -fno-late-combine-instructions -fno-strict-aliasing -fomit-frame-pointer -ffreestanding -fno-builtin \
  -fno-tree-loop-distribute-patterns -fno-pic -mpcrel -Wall ${PROF:+-DPROF} -c engine.c -o engine.o
$T-as -m68020 entry.s -o entry.o
vasmm68k_mot -Felf -m68020 -quiet -o pgroups.o pgroups.s
for a in 0 0x4000; do
  $T-ld -nostdlib -e _start -Ttext=$a entry.o engine.o pgroups.o -o engine-$a.elf
  $T-objcopy -O binary -j .text engine-$a.elf engine-$a.bin
done
if ! cmp -s engine-0.bin engine-0x4000.bin; then
  echo "build.sh: engine.bin is NOT position independent" >&2; exit 1
fi
# Audit8 J30: the LINKED image may hold nothing allocated but .text -
# objcopy -j .text would silently drop .sdata/.sbss/COMMON, and PC-
# relative references to them look the same at both link addresses
extra=$($T-readelf -S -W engine-0.elf | sed -n 's/^ *\[ *[0-9]*\] //p' \
  | awk '$1 != ".text" && $7 ~ /A/ {print $1}')
if [ -n "$extra" ]; then
  echo "build.sh: engine has allocated sections besides .text: $extra" >&2; exit 1
fi
for o in engine.o pgroups.o; do
  if $T-readelf -S $o | grep -E '\.(data|bss|rodata)' | grep -v -E ' 0+ 00 ' | grep -q .; then
    echo "build.sh: $o has data" >&2; exit 1
  fi
done
cp engine-0.bin engine.bin
rm -f engine-0x4000.bin engine-0x4000.elf
echo "engine.bin $(stat -c %s engine.bin) bytes"
