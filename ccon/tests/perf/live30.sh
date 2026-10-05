#!/usr/bin/env bash
# live20.sh BUILD NAME - cold-start FS-UAE stock, BUILD as live L:ccon-handler, conbench REPS3 SCALE1 SYNC in a 77x30 CCON: window
H="/home/creep/FS-UAE/Hard Drives/AmigaOS3.2"; export WASABI_HOST=127.0.0.1
pkill -x fs-uae; sleep 2
cp "$1" "$H/L/ccon-handler"
printf 'FailAt 30\nStack 20000\nC:conbench CCON TO SYS:T/cb-%s.txt REPS 3 SCALE 1 SYNC\nEndCLI\n' $2 > "$H/S/x30"; rm -f "$H/T/cb-$2.txt"
$(cd "$(dirname "$0")" && pwd)/uae9.sh A1200-Stock-net; sleep 45
until wasabi ping >/dev/null 2>&1; do sleep 2; done
wasabi run "Version L:ccon-handler"
wasabi run 'NewShell "CCON:0/0/640/256/CCON/DEFAULTS" FROM S:x30' >/dev/null
for i in $(seq 1 110); do grep -q TOTAL "$H/T/cb-$2.txt" 2>/dev/null && break; sleep 5; done
sed -n '/window/p;/test /,$p' "$H/T/cb-$2.txt"
