#!/usr/bin/env python3
"""Differential tests: every tests/*.c is built with clang and run, then
converted with c2xc, built with xcc and run; stdout and the exit code must
agree. Usage: tests/run.py [name ...]  (all when none)."""
import sys, os, subprocess, glob
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
OUT = os.path.join(HERE, "out"); os.makedirs(OUT, exist_ok=True)
XCC = os.environ.get("XCC", "/opt/xcc/0.5/bin/xcc")
# the in-house arm64 assembler lacks a few mnemonics (fmsub, 2026-09-04): let xcc fall back to clang for those
os.environ["XTC_ALLOW_CLANG_FALLBACK"] = "1"
names = sys.argv[1:] or sorted(os.path.basename(f)[:-2] for f in glob.glob(os.path.join(HERE, "*.c")))
# known compiler issues (private:XCC-BUGS.md): a failure here is reported, not counted
XFAIL = {"t02_structs": "0.5: fmsub missing from the arm64 assembler", "t13_callbacks": "0.5: a callback compared with a fresh &fn reads unequal"}
fails = 0; xfails = 0
def fail(n, msg):
    global fails, xfails
    if n in XFAIL: xfails += 1; print("xfail %-23s %s (%s)" % (n, msg[:90], XFAIL[n])); return
    fails += 1; print("FAIL %-24s %s" % (n, msg))
for n in names:
    c = os.path.join(HERE, n + ".c"); cb = os.path.join(OUT, n + "_c"); xf = os.path.join(OUT, n + ".xc"); xb = os.path.join(OUT, n + "_x")
    r = subprocess.run(["clang", "-w", "-o", cb, c], capture_output=True, text=True)
    if r.returncode: fail(n, "clang: %s" % r.stderr.strip().splitlines()[0][:120]); continue
    want = subprocess.run([cb], capture_output=True, timeout=20)
    r = subprocess.run([sys.executable, os.path.join(ROOT, "c2xc.py"), "-q", "-o", xf, c], capture_output=True, text=True)
    if r.returncode: fail(n, "c2xc: %s" % (r.stderr or r.stdout).strip().splitlines()[-1][:160]); continue
    r = subprocess.run([XCC, "-q", "-o", xb, xf], capture_output=True, text=True, timeout=120)
    if r.returncode:
        msg = [l for l in (r.stderr + r.stdout).splitlines() if "error" in l.lower() or "§" in l]
        fail(n, "xcc: %s" % (msg[0] if msg else (r.stderr + r.stdout).strip()[:160]).replace("\x1b[1m", "").replace("\x1b[0m", "").replace("\x1b[1;31m", "")[:170]); continue
    try: got = subprocess.run([xb], capture_output=True, timeout=20)
    except subprocess.TimeoutExpired: fail(n, "xc run: timeout"); continue
    if got.stdout != want.stdout or got.returncode != want.returncode:
        fail(n, "output differs: want exit %d %r, got exit %d %r" % (want.returncode, want.stdout[:80], got.returncode, got.stdout[:80])); continue
    print("ok   %s" % n)
print("%d of %d failed, %d expected failures" % (fails, len(names), xfails))
sys.exit(1 if fails else 0)
