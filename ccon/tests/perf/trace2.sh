#!/usr/bin/env bash
# trace2.sh DRIVER BLOB N - instruction trace of the engine under vamos; per function, then per C source line (>= 15/iter)
S=$(cd "$(dirname "$0")" && pwd)
cd ~/Projects/AmigaTools/ccon/engine; T=$HOME/opt/m68k-elf/bin/m68k-elf
$T-gcc -m68020 -O2 -fno-late-combine-instructions -fno-strict-aliasing -fomit-frame-pointer -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns -fno-pic -mpcrel -Wall -g -c engine.c -o $S/gbuild/engine.o
vasmm68k_mot -Felf -m68020 -quiet -o $S/gbuild/pg.o pgroups.s
$T-ld -nostdlib -e _start -Ttext=0 entry.o $S/gbuild/engine.o $S/gbuild/pg.o -o $S/gbuild/e.elf
$T-objcopy -O binary -j .text $S/gbuild/e.elf $S/gbuild/e.bin
cmp -s $S/gbuild/e.bin $2 || echo "WARNING: debug build differs from $2"
$T-nm -n $S/gbuild/e.elf > $S/syms.txt
cp $2 $S/e.bin; cd $S; vamos -C 68020 -m 4096 -I $1 e.bin $3 > trace.txt 2>&1
B=$(grep -o 'BLOB [0-9a-f]*' trace.txt | cut -d' ' -f2); SZ=$(stat -c %s $2)
python3 $S/icount.py $S $B $SZ $3 | head -14
python3 - "$S" "$B" "$SZ" "$3" <<'PY'
import re,collections,subprocess,sys,os
S,B,SZ,N=sys.argv[1],int(sys.argv[2],16),int(sys.argv[3]),int(sys.argv[4])
pcs=collections.Counter(); seen=False
for l in open(S+'/trace.txt',errors='ignore'):
    if 'BLOB' in l: seen=True; continue
    if not seen: continue
    m=re.search(r'N/A\s+([0-9a-f]{6})\s',l)
    if m:
        o=int(m.group(1),16)-B
        if 0<=o<SZ: pcs[o]+=1
addrs=sorted(pcs)
out=subprocess.run([os.path.expanduser('~/opt/m68k-elf/bin/m68k-elf-addr2line'),'-e',S+'/gbuild/e.elf']+[hex(a) for a in addrs],capture_output=True,text=True).stdout.split('\n')
lines=collections.Counter()
for a,o in zip(addrs,out):
    k=o.split('/')[-1].split(' ')[0]
    if k.startswith('engine.c'): lines[int(k.split(':')[1])]+=pcs[a]
print('C total per iter', sum(lines.values())/N)
src=open(os.path.expanduser('~/Projects/AmigaTools/ccon/engine/engine.c')).read().split('\n')
for k,v in sorted(lines.items()):
    if v/N>=15: print(f'{k:5d} {v/N:6.0f}  {src[k-1].strip()[:70]}')
PY
