#!/usr/bin/env bash
# prof2.sh PROFBUILD [tests...] - cold-start FS-UAE stock, run cbone per test in XC1:, ccstat2 after each
S=$(cd "$(dirname "$0")" && pwd)
H="/home/creep/FS-UAE/Hard Drives/AmigaOS3.2"
B=$1; shift; T=${*:-plain block scroll sgr perchar sync eeol}
export WASABI_HOST=127.0.0.1
pkill -x fs-uae; sleep 2
cp "$B" "$H/L/xc1-handler"; cp $S/ccstat3 "$H/T/ccstat2"; cp $S/cbone "$H/T/"
{ echo "FailAt 30"; echo "Stack 20000"; for t in $T; do echo "SYS:T/ccstat2 RESET"; echo "SYS:T/cbone $t N ${N:-1}"; echo "echo \"== $t\" >>SYS:T/prof.txt"; echo "SYS:T/ccstat2 >>SYS:T/prof.txt"; done; echo "echo DONE >>SYS:T/prof.txt"; echo EndCLI; } > "$H/S/xprof"
rm -f "$H/T/prof.txt"
$(cd "$(dirname "$0")" && pwd)/uae9.sh ${CFG:-A1200-Stock-net}; sleep 45
until wasabi ping >/dev/null 2>&1; do sleep 2; done
wasabi run "Mount XC1: FROM DEVS:XC-mountlist"
wasabi run 'NewShell "XC1:0/0/640/256/prof/DEFAULTS" FROM S:xprof'
for i in $(seq 1 115); do grep -q DONE "$H/T/prof.txt" 2>/dev/null && break; sleep 5; done
cat "$H/T/prof.txt"
