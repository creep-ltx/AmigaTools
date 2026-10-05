#!/usr/bin/env bash
# pxab2.sh BUILD FILE - cold-start stock FS-UAE, BUILD as XC1:, Type FILE into a DPFORCE and a NODIRECT
# window at several x positions, compare the windows' row hashes (wgrab)
S=$(cd "$(dirname "$0")" && pwd)
H="/home/creep/FS-UAE/Hard Drives/AmigaOS3.2"
export WASABI_HOST=127.0.0.1
pkill -x fs-uae; sleep 2
cp "$1" "$H/L/xc1-handler"
$S/uae9.sh A1200-Stock-net; sleep 45
until wasabi ping >/dev/null 2>&1; do sleep 2; done
wasabi run "Mount XC1: FROM DEVS:XC-mountlist" >/dev/null
for x in ${XS:-0 4 6 11 1}; do
  for m in DPFORCE DPFORCE2; do
    f=px-$x-$m; rm -f "$H/T/$f" "$H/T/$f.done"
    printf 'Type SYS:T/%s\nSYS:T/wgrab PXA SYS:T/%s\nEndCLI\n' $2 $f > "$H/S/xpx"
    wasabi run "NewShell \"XC1:$x/0/632/256/PXA/DEFAULTS/JUMP0/DPFORCE\" FROM S:xpx" >/dev/null
    for i in $(seq 1 90); do [ -e "$H/T/$f.done" ] && break; sleep 2; done
    sleep 2
  done
  if cmp -s "$H/T/px-$x-DPFORCE" "$H/T/px-$x-DPFORCE2"; then echo "x=$x identical ($(stat -c %s "$H/T/px-$x-DPFORCE") bytes of row hashes)"; else echo "x=$x DIFFER"; cmp -l "$H/T/px-$x-DPFORCE" "$H/T/px-$x-DPFORCE2" | head -3; fi
done
pkill -x fs-uae
