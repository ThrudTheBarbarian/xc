#!/usr/bin/env python3
"""Cross-architecture performance harness for the xtc compiler.

For every kernel in kernels/*.xc this compiles through each backend and records a
per-backend metric plus (where the target runs on this host) an integer checksum:

  backend   metric (headline)                     runs here?  checksum
  --------  ------------------------------------  ----------  --------
  m68k      DYNAMIC instruction count (xst)       yes         yes
  xt6502    DYNAMIC instruction count (xts)       yes         yes
  arm64     STATIC insns in the kernel functions  yes         yes
  x86_64    STATIC insns in the kernel functions  no (Linux)  no
  arm9      STATIC insns in the kernel functions  no (qemu)   no

The dynamic count (from the xst / xts simulators) is exact and deterministic —
the real perf signal for the two simulated targets, which previously had none.
The static count (instructions emitted for the user's own functions, excluding
the constant library runtime) is the uniform regression signal for the native /
emulated targets that don't execute on this host.

Kernels are integer-only and print a checksum with %ld, so every backend that
runs MUST agree — a divergence is a miscompile, not a perf delta, and is flagged
loudly (this harness doubles as a differential correctness check).

Usage:
  run_perf.py                    measure, compare to baseline.json, print a table
  run_perf.py --update           write the measured numbers back to baseline.json
  run_perf.py --kernel reduce    restrict to one kernel
  run_perf.py --threshold 3      regression/improvement flag threshold, percent
"""

import argparse
import json
import os
import re
import subprocess
import sys


def _load_build_env():
    """Export build.env values (repository root) that the environment does not set."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "build.env")
    if not os.path.isfile(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            if value and not os.environ.get(name):
                os.environ[name] = value


_load_build_env()

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
BIN = os.path.join(ROOT, "bin", "osx")
XTC = os.path.join(BIN, "xtc")
XST = os.path.join(BIN, "xst")
XTS = os.path.join(BIN, "xts")
KERNELS = os.path.join(HERE, "kernels")
BASELINE = os.path.join(HERE, "baseline.json")
ARM9_SYSROOT = os.environ.get("XTC_ARM9_SYSROOT", "")

# Per-backend recipes. `asm` compiles to assembly (for the static count); `run`
# (optional) compiles a runnable artifact and executes it for the dynamic count
# + checksum. `count_re` extracts the dynamic instruction count from the run's
# stderr. `metric` picks which number is the headline.
BACKENDS = [
    {
        "name": "arm64", "metric": "static",
        "asm": lambda src, out: [XTC, "-O2", "-A", "arm64", "-S", src, "-o", out],
        "build": lambda src, out: [XTC, "-O2", "-A", "arm64", src, "-o", out],
        "run": lambda binp: [binp],
        "ext": "",
    },
    {
        "name": "x86_64", "metric": "static",
        "asm": lambda src, out: [XTC, "-O2", "-A", "x86_64", "-S", src, "-o", out],
    },
    {
        "name": "m68k", "metric": "dynamic",
        "asm": lambda src, out: [XTC, "-mhard-float", "-A", "68030", "-q", "-S", src, "-o", out],
        "build": lambda src, out: [XTC, "-mhard-float", "-A", "68030", "-q", src, "-o", out],
        "run": lambda prg: [XST, "--cpu", "68030", "--cycles", "-d", prg],
        "count_re": r"sim68k:\s*(\d+)\s+instructions",
        "ext": ".prg",
    },
    {
        "name": "xt6502", "metric": "dynamic",
        "build": lambda src, out: [XTC, "-fnew-ir", "-m", "xt", "-q", src, "-o", out],
        "run": lambda xex: [XTS, "-m", "xt", "--cycles", "-d", xex],
        "count_re": r"sim6502:\s*(\d+)\s+instructions",
        "ext": ".xex",
    },
    {
        "name": "arm9", "metric": "static",
        "asm": lambda src, out: [XTC, "-A", "arm9", "-q", "-L", ARM9_SYSROOT, "-S", src, "-o", out],
    },
]

TMP = "/tmp/xtc-perf"


def sh(cmd, timeout=120):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return -1, "", "timeout"


def user_functions(src_path):
    """Names of functions defined in the kernel (a return type + name + '(' at
    column 0). Used to scope the static count to the user's own code."""
    names = []
    typ = r"(?:i8|u8|i16|u16|i32|u32|void|float|bool|string)@?"
    pat = re.compile(r"^\s*" + typ + r"\s+([A-Za-z_]\w*)\s*\(")
    with open(src_path) as f:
        for line in f:
            m = pat.match(line)
            if m:
                names.append(m.group(1))
    return set(names)


def static_insns(asm_path, func_names):
    """Count instruction lines inside the user functions only, excluding the
    constant library runtime. Function boundaries are the `.globl`-declared
    symbols (every function, user or runtime, is exported; internal block labels
    — `.L`, `Lmain_bb`, `.foo$bb` — are not), so a body runs from its global
    label to the next global label regardless of the backend's local-label
    convention. A global whose name (minus any leading '_') is a kernel function
    counts; runtime globals don't."""
    if not os.path.exists(asm_path):
        return None
    with open(asm_path) as f:
        lines = f.readlines()
    globls = set()
    gpat = re.compile(r"^\s*\.globa?l\s+(\S+)")
    for ln in lines:
        m = gpat.match(ln)
        if m:
            globls.add(m.group(1).rstrip(","))
    label = re.compile(r"^([A-Za-z_.$][\w.$]*):")        # any column-0 label
    insn = re.compile(r"^\s+[a-zA-Z]")                   # indented mnemonic
    directive = re.compile(r"^\s+\.")                    # indented .directive
    total, inside = 0, False
    for ln in lines:
        m = label.match(ln)
        if m:
            lbl = m.group(1)
            if lbl in globls:                            # a real function boundary
                inside = lbl.lstrip("_") in func_names
        elif inside and insn.match(ln) and not directive.match(ln):
            total += 1
    return total


def measure_kernel(kernel, threshold_unused=None):
    src = os.path.join(KERNELS, kernel + ".xc")
    funcs = user_functions(src)
    result = {"checksum": None}
    checksums = {}
    for be in BACKENDS:
        name = be["name"]
        entry = {}
        # static count (all backends that can emit asm)
        if "asm" in be:
            asm = os.path.join(TMP, f"{kernel}.{name}.s")
            rc, _, err = sh(be["asm"](src, asm))
            if rc == 0:
                entry["static"] = static_insns(asm, funcs)
            else:
                entry["error"] = "asm: " + (err.strip().splitlines()[-1] if err.strip() else f"rc={rc}")
        # dynamic count + checksum (backends that run on this host)
        if "run" in be:
            art = os.path.join(TMP, f"{kernel}.{name}{be['ext']}")
            rc, _, err = sh(be["build"](src, art))
            if rc != 0:
                entry["error"] = "build: " + (err.strip().splitlines()[-1] if err.strip() else f"rc={rc}")
            else:
                rc, out, err = sh(be["run"](art), timeout=120)
                cs = out.strip().splitlines()
                checksums[name] = cs[-1] if cs else "(none)"
                if "count_re" in be:
                    m = re.search(be["count_re"], err)
                    if m:
                        entry["dynamic"] = int(m.group(1))
                    else:
                        entry.setdefault("error", "no instruction count in run output")
        result[name] = entry
    # cross-backend checksum agreement (a divergence = miscompile)
    uniq = set(checksums.values())
    result["checksum"] = checksums
    result["checksum_ok"] = (len(uniq) <= 1)
    return result


def headline(entry, metric):
    if entry is None:
        return None
    return entry.get(metric, entry.get("dynamic", entry.get("static")))


def fmt(n):
    return "-" if n is None else f"{n:,}"


# ── Wall-clock bench: xtc vs a reference compiler on the native targets ──
# arm64 runs locally (xtc vs clang); x86_64 runs on the Linux host (XTC_PERF_REMOTE or XTC_LINUX_HOST)
# over ssh (xtc's ELF vs gcc). Kernels are built -DBENCH (argc-seeded so the
# reference compiler can't constant-fold the array away) at a large REPS, run
# with one fixed argument, and timed best-of-N. The xtc and reference checksums
# must agree per target — a correctness cross-check against a real compiler.
BENCH_KERNELS = ["reduce", "map", "dot"]
# Sized so even the reference compiler's vectorised code runs long enough (~tens
# of ms) that process startup isn't the dominant term. The accumulator is u32
# (defined wraparound), so a huge iteration count is fine.
BENCH_REPS = 50_000_000
BENCH_ARG = "X"            # one arg → argc == 2, a stable runtime seed
BENCH_RUNS = 5
REMOTE = os.environ.get("XTC_PERF_REMOTE", os.environ.get("XTC_LINUX_HOST", ""))


def _clock(cmd, runs=BENCH_RUNS):
    import time
    best, cs = None, None
    for _ in range(runs):
        t = time.perf_counter()
        p = subprocess.run(cmd, capture_output=True, text=True)
        dt = (time.perf_counter() - t) * 1000.0
        best = dt if best is None else min(best, dt)
        cs = p.stdout.strip().splitlines()[-1] if p.stdout.strip() else "(none)"
    return best, cs


def bench_arm64(kernel):
    src = os.path.join(KERNELS, kernel + ".xc")
    csrc = os.path.join(KERNELS, kernel + ".c")
    xb = os.path.join(TMP, f"{kernel}.arm64.xtc")
    cb = os.path.join(TMP, f"{kernel}.arm64.clang")
    d = ["-DBENCH", f"-DREPS={BENCH_REPS}"]
    rc, _, err = sh([XTC, "-O2", *d, "-A", "arm64", src, "-o", xb])
    if rc != 0:
        return {"error": "xtc: " + err.strip().splitlines()[-1]}
    rc, _, err = sh(["clang", "-O3", *d, csrc, "-o", cb])
    if rc != 0:
        return {"error": "clang: " + err.strip().splitlines()[-1]}
    xt_ms, xt_cs = _clock([xb, BENCH_ARG])
    rf_ms, rf_cs = _clock([cb, BENCH_ARG])
    return {"xtc_ms": xt_ms, "ref_ms": rf_ms, "ref": "clang",
            "xtc_cs": xt_cs, "ref_cs": rf_cs}


def bench_x86_64_remote():
    """Build every bench kernel's x86_64 ELF locally, ship it plus the C source
    to the remote Linux host, compile the C with gcc there, and time both with
    GNU `/usr/bin/time`. Returns {kernel: result} or {} if the host is down."""
    rc, _, _ = sh(["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
                   REMOTE, "true"])
    if rc != 0:
        return None
    rdir = "/tmp/xtc-perf-remote"
    sh(["ssh", REMOTE, f"mkdir -p {rdir}"])
    files = []
    for k in BENCH_KERNELS:
        elf = os.path.join(TMP, f"{k}.x86_64.xtc")
        rc, _, err = sh([XTC, "-O2", "-DBENCH", f"-DREPS={BENCH_REPS}",
                         "-A", "x86_64", os.path.join(KERNELS, k + ".xc"), "-o", elf])
        if rc != 0:
            return {k: {"error": "xtc x86_64: " + err.strip().splitlines()[-1]} for k in BENCH_KERNELS}
        files += [elf, os.path.join(KERNELS, k + ".c")]
    rc, _, err = sh(["scp", "-q", *files, f"{REMOTE}:{rdir}/"], timeout=120)
    if rc != 0:
        return None
    # One remote script: gcc-compile each kernel, print checksums, then N timed
    # runs of each binary (GNU time %e → elapsed seconds, on stderr).
    lines = [f"cd {rdir}"]
    for k in BENCH_KERNELS:
        lines.append(f"gcc -O3 -DBENCH -DREPS={BENCH_REPS} {k}.c -o {k}.gcc 2>/dev/null || echo GCCFAIL {k}")
        lines.append(f'echo CS {k} xtc $(./{k}.x86_64.xtc {BENCH_ARG}) gcc $(./{k}.gcc {BENCH_ARG})')
        # GNU time %e (elapsed seconds); at REPS=50M runtimes are >>10 ms so the
        # centisecond resolution is fine. Emit "T <kernel> <who> <seconds>".
        for w, b in (("xtc", f"{k}.x86_64.xtc"), ("gcc", f"{k}.gcc")):
            lines.append(f"for i in $(seq 1 {BENCH_RUNS}); do "
                         f"/usr/bin/time -f 'T {k} {w} %e' ./{b} {BENCH_ARG} >/dev/null; done")
    rc, out, err = sh(["ssh", REMOTE, " ; ".join(lines)], timeout=300)
    text = out + err
    res = {k: {"ref": "gcc"} for k in BENCH_KERNELS}
    times = {(k, w): [] for k in BENCH_KERNELS for w in ("xtc", "gcc")}
    for ln in text.splitlines():
        f = ln.split()
        if len(f) == 6 and f[0] == "CS":
            _, k, _, xc, _, gc = f
            res[k]["xtc_cs"], res[k]["ref_cs"] = xc, gc
        elif len(f) == 4 and f[0] == "T":
            _, k, w, t = f
            try:
                times[(k, w)].append(float(t) * 1000.0)
            except ValueError:
                pass
        elif f[:1] == ["GCCFAIL"]:
            res[f[1]]["error"] = "gcc build failed"
    for k in BENCH_KERNELS:
        if times[(k, "xtc")]:
            res[k]["xtc_ms"] = min(times[(k, "xtc")])
        if times[(k, "gcc")]:
            res[k]["ref_ms"] = min(times[(k, "gcc")])
    return res


def run_bench():
    print(f"\n=== wall-clock bench (best of {BENCH_RUNS}, REPS={BENCH_REPS:,}, "
          f"-DBENCH argc-seeded) ===")
    print("xtc vs clang (arm64, local) / gcc (x86_64, on "
          f"{REMOTE}). ratio = xtc / reference.\n")
    hdr = f"{'kernel':<8} {'target':<8} {'xtc (ms)':>10} {'ref (ms)':>10} {'ratio':>7}  {'ref':<6} check"
    print(hdr)
    print("-" * len(hdr))
    remote = bench_x86_64_remote()
    diverged = False
    for kernel in BENCH_KERNELS:
        rows = [("arm64", bench_arm64(kernel))]
        if remote is None:
            rows.append(("x86_64", {"error": f"{REMOTE} unreachable — skipped"}))
        else:
            rows.append(("x86_64", remote.get(kernel, {"error": "no data"})))
        for target, r in rows:
            if r.get("error"):
                print(f"{kernel:<8} {target:<8} {r['error']}")
                continue
            xm, rm = r.get("xtc_ms"), r.get("ref_ms")
            ratio = f"{xm / rm:.2f}x" if xm is not None and rm else "-"
            ok = r.get("xtc_cs") == r.get("ref_cs")
            diverged = diverged or not ok
            chk = "ok" if ok else f"DIVERGE xtc={r.get('xtc_cs')} ref={r.get('ref_cs')}"
            xs = f"{xm:.1f}" if xm is not None else "-"
            rs = f"{rm:.1f}" if rm is not None else "-"
            print(f"{kernel:<8} {target:<8} {xs:>10} {rs:>10} {ratio:>7}  {r.get('ref',''):<6} {chk}")
    print()
    if diverged:
        print("RESULT: bench checksum divergence vs reference compiler. ‼️")
        sys.exit(2)
    print("RESULT: bench ok")


def main():
    ap = argparse.ArgumentParser(description="xtc cross-arch perf harness")
    ap.add_argument("--bench", action="store_true",
                    help="wall-clock xtc vs clang/gcc on the native targets (arm64 local, x86_64 remote)")
    ap.add_argument("--update", action="store_true", help="write measured numbers to baseline.json")
    ap.add_argument("--kernel", help="restrict to one kernel (basename, no .xc)")
    ap.add_argument("--threshold", type=float, default=2.0, help="flag threshold, percent")
    args = ap.parse_args()

    os.makedirs(TMP, exist_ok=True)

    if args.bench:
        run_bench()
        return

    kernels = ([args.kernel] if args.kernel
               else sorted(k[:-3] for k in os.listdir(KERNELS) if k.endswith(".xc")))

    baseline = {}
    if os.path.exists(BASELINE):
        with open(BASELINE) as f:
            baseline = json.load(f)

    measured = {}
    regressed = False
    diverged = False

    for kernel in kernels:
        res = measure_kernel(kernel)
        measured[kernel] = res
        base = baseline.get(kernel, {})

        print(f"\n=== {kernel} ===")
        hdr = f"{'backend':<9} {'metric':<8} {'value':>12} {'baseline':>12} {'delta':>9}"
        print(hdr)
        print("-" * len(hdr))
        for be in BACKENDS:
            name, metric = be["name"], be["metric"]
            entry = res.get(name, {})
            if entry.get("error"):
                print(f"{name:<9} {'-':<8} {'ERROR':>12}   {entry['error']}")
                continue
            val = headline(entry, metric)
            bval = headline(base.get(name), metric) if base.get(name) else None
            delta = ""
            if val is not None and bval:
                pct = 100.0 * (val - bval) / bval
                mark = ""
                if pct > args.threshold:
                    mark, regressed = " ▲", True
                elif pct < -args.threshold:
                    mark = " ▼"
                delta = f"{pct:+.1f}%{mark}"
            print(f"{name:<9} {metric:<8} {fmt(val):>12} {fmt(bval):>12} {delta:>9}")

        cs = res["checksum"]
        if res["checksum_ok"]:
            any_cs = next(iter(cs.values())) if cs else "(not run)"
            print(f"checksum: {any_cs}  (agree across {len(cs)} run backends)")
        else:
            diverged = True
            print(f"checksum: DIVERGENCE — {cs}  ‼️  MISCOMPILE")

    if args.update:
        # store only the numeric metrics, not the volatile checksum maps
        out = {}
        for k, res in measured.items():
            out[k] = {be["name"]: {m: v for m, v in res.get(be["name"], {}).items()
                                   if m in ("static", "dynamic")}
                      for be in BACKENDS}
            csvals = list(res["checksum"].values())
            out[k]["checksum"] = csvals[0] if csvals else None
        with open(BASELINE, "w") as f:
            json.dump(out, f, indent=2, sort_keys=True)
            f.write("\n")
        print(f"\nbaseline written → {os.path.relpath(BASELINE, ROOT)}")

    print()
    if diverged:
        print("RESULT: checksum divergence detected — a backend miscompiles. ‼️")
        sys.exit(2)
    if regressed and not args.update:
        print(f"RESULT: regression(s) over {args.threshold}% vs baseline. ▲")
        sys.exit(1)
    print("RESULT: ok" + ("" if args.update else " (no regressions vs baseline)"))


if __name__ == "__main__":
    main()
