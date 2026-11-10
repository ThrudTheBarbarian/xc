#!/usr/bin/env python3
"""benchmark/par/cpp_run.py — the C++ par programs against clang++, on this Mac.

benchmark/par/cpp/<name>.cpp are plain loops over std::vector, and
<name>_par.cpp the same work with the C++17 parallel algorithms
(std::execution::par). Each is built by clang++ (-O3; the _par ones with
libc++'s own parallel backend, -fexperimental-library) and by xcc -O3, which
makes par blocks of the loops it can lift. xcc's builds run three ways:
--par-style=cpu (one thread, nothing lifted), and lifted with XC_PAR=cpu and
XC_PAR=gpu. Each program prints "<checksum> <best_us> <first_us>"; every
build runs several times, round-robin, the machine idle before each run
(run.py's wait_quiet), and the figure is the median of the runs' best times.
Every build's checksum must agree. Prints a table; writes nothing.

  python3 benchmark/par/cpp_run.py --xcc compiler/build/contrib/xcc-stage2
  python3 benchmark/par/cpp_run.py --bench saxpy --runs 5
"""
import argparse
import os
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import run as common  # noqa: E402

CPPDIR = os.path.join(HERE, "cpp")
COMPILER = os.path.join(os.path.dirname(os.path.dirname(HERE)), "compiler")


def build(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("cpp_run.py: %s\n%s" % (" ".join(cmd), r.stderr[-2000:]))


def run_once(binary, env):
    common.wait_quiet()
    r = subprocess.run([binary], capture_output=True, text=True, env=dict(os.environ, **env))
    if r.returncode != 0:
        sys.exit("cpp_run.py: %s failed\n%s" % (binary, r.stderr[-2000:]))
    check, best, _first = r.stdout.split()
    return check, int(best)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--xcc", required=True)
    ap.add_argument("--bench", action="append")
    ap.add_argument("--runs", type=int, default=5)
    args = ap.parse_args()
    xcc = os.path.abspath(args.xcc)
    names = sorted({f[:-4] for f in os.listdir(CPPDIR) if f.endswith(".cpp")})
    if args.bench:
        names = [n for n in names if n in args.bench or n.replace("_par", "") in args.bench]
    work = tempfile.mkdtemp(prefix="cpp_run.")
    rows = []
    for n in names:
        src = os.path.join(CPPDIR, n + ".cpp")
        par = n.endswith("_par")
        std = ["-std=c++17"]
        ref = os.path.join(work, n + ".clang")
        build(["clang++", "-O3"] + std + (["-fexperimental-library"] if par else []) + ["-o", ref, src])
        one = os.path.join(work, n + ".xcc1")
        build([xcc, "-q", "-O3", "--par-style=cpu", "-H", COMPILER] + std + ["-o", one, src])
        lifted = os.path.join(work, n + ".xcc")
        build([xcc, "-q", "-O3", "-H", COMPILER] + std + ["-o", lifted, src])
        builds = [("clang++", ref, {}), ("xcc one thread", one, {}),
                  ("xcc lifted, CPU", lifted, {"XC_PAR": "cpu"}), ("xcc lifted, GPU", lifted, {"XC_PAR": "gpu"})]
        times = {b[0]: [] for b in builds}
        checks = set()
        for _ in range(args.runs):
            for label, binary, env in builds:
                check, best = run_once(binary, env)
                checks.add(check)
                times[label].append(best)
        if len(checks) != 1:
            sys.exit("cpp_run.py: %s: the builds' checksums differ: %s" % (n, sorted(checks)))
        rows.append((n, {k: statistics.median(v) for k, v in times.items()}))
    labels = ["clang++", "xcc one thread", "xcc lifted, CPU", "xcc lifted, GPU"]
    print("| program | " + " | ".join(labels) + " |")
    print("|---|" + "---:|" * len(labels))
    for n, t in rows:
        print("| %s | " % n + " | ".join("%.1f ms" % (t[k] / 1000.0) for k in labels) + " |")


if __name__ == "__main__":
    main()
