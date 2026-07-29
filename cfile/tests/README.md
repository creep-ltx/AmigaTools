# CFile test harnesses

- `isogen.py` — masters small but structurally honest ISO9660 images
  (PVD, L/M path tables, records never straddling sectors, pad bytes)
  plus a JSON ground-truth manifest per image. Verify its output with
  7z (an independent implementation) before trusting it.
- `isoh.e` — the ISO9660 parser harness: the iso* procs exactly as
  they live in cfile.e, wrapped in a `LIST`/`CAT` CLI. Build with
  ecompile, run under vamos against isogen.py's images, diff listings
  against the manifests and md5 the extractions. The 30.7.26 run:
  143 entries listed, 132 files extracted byte-perfect, before the
  code ever touched cfile.e.

The three-way rule: generator ↔ 7z ↔ parser must agree; any two
agreeing against the third finds the liar.
