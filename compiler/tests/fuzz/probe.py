#!/usr/bin/env python3
"""Run a hand-written .xc program on every backend/opt pair and show the outputs.

The fuzzer may only generate a construct once every backend agrees on it; this
is how that is established (and how a construct that is legitimately
target-divergent gets ruled OUT before it floods the findings).

  python3 tests/fuzz/probe.py file.xc [--only ...] [--opt 0,3]
"""
import sys, os, argparse, tempfile, shutil
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz import run_backend, parse_spec, label, BACKENDS

ap = argparse.ArgumentParser()
ap.add_argument("files", nargs="+")
ap.add_argument("--only", default="arm64,xt6502,m68k,wasm32")
ap.add_argument("--opt", default="0,3")
a = ap.parse_args()
specs = [parse_spec(n, o) for n in a.only.split(",") for o in a.opt.split(",")]
specs = [s for s in specs if s]
rc = 0
for f in a.files:
    print(f"=== {f}")
    wd = tempfile.mkdtemp(prefix="xtprobe_")
    try:
        outs = {}
        for s in specs:
            st, out = run_backend(s, os.path.abspath(f), wd)
            outs[label(s)] = (st, out)
        base = None
        for k, (st, out) in outs.items():
            if st != "ok":
                print(f"  {k:14s} {st}: {out.strip()[-300:]}"); rc = 1
            elif base is None:
                base = out
                print(f"  {k:14s} ok\n{''.join('      '+l+chr(10) for l in out.splitlines())}", end="")
            elif out != base:
                print(f"  {k:14s} DIVERGES\n{''.join('      '+l+chr(10) for l in out.splitlines())}", end="")
                rc = 1
            else:
                print(f"  {k:14s} agrees")
    finally:
        shutil.rmtree(wd, ignore_errors=True)
sys.exit(rc)
