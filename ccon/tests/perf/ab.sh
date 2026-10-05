#!/usr/bin/env bash
# ab.sh NAME1 BUILD1 NAME2 BUILD2 [rounds] - alternate full conbench runs on the stock A1200, print per-test table
S=$(cd "$(dirname "$0")" && pwd)
H="/home/creep/FS-UAE/Hard Drives/AmigaOS3.2"
R=${5:-2}
for r in $(seq 1 $R); do
  $S/live30.sh $2 $1-$r >/dev/null 2>&1
  $S/live30.sh $4 $3-$r >/dev/null 2>&1
done
pkill -x fs-uae
python3 - "$1" "$3" "$R" <<'PY'
import sys,re
H="/home/creep/FS-UAE/Hard Drives/AmigaOS3.2/T"
a,b,R=sys.argv[1],sys.argv[2],int(sys.argv[3])
def load(n):
    d={}
    for l in open(f"{H}/cb-{n}.txt"):
        m=re.match(r'\s+([a-z0-9-]+)\s+\d+\s+([\d.]+)',l)
        if m: d[m.group(1)]=float(m.group(2))
    return d
A=[load(f"{a}-{r}") for r in range(1,R+1)]; B=[load(f"{b}-{r}") for r in range(1,R+1)]
print(f"{'test':14s} " + " ".join(f"{a}-{r}" .rjust(8) for r in range(1,R+1)) + " | " + " ".join(f"{b}-{r}".rjust(8) for r in range(1,R+1)))
for t in A[0]:
    print(f"{t:14s} " + " ".join(f"{x[t]:8.2f}" for x in A) + " | " + " ".join(f"{x[t]:8.2f}" for x in B))
PY
