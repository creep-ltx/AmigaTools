#!/usr/bin/env bash
# uae9.sh CONFIG - start FS-UAE with ~/FS-UAE/Configurations/CONFIG.fs-uae and
# put its window on workspace (tag) 9 without switching the view there
cfg=${1:-A1200-Stock-net}
(cd ~/FS-UAE && setsid fs-uae "Configurations/$cfg.fs-uae" >/dev/null 2>&1 &)
for i in $(seq 1 40); do
  id=$(mmsg get all-clients 2>/dev/null | python3 -c 'import json,sys
for c in json.load(sys.stdin)["clients"]:
    if c["appid"]=="fs-uae": print(c["id"]); break' 2>/dev/null)
  [ -n "$id" ] && { mmsg dispatch tagsilent,9 client,$id >/dev/null 2>&1; exit 0; }
  sleep 0.5
done
