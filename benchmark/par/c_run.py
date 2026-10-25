#!/usr/bin/env python3
"""benchmark/par/c_run.py — the C par programs against GCC and clang.

The same C files (benchmark/par/c/*.c, undecorated) built by xcc, and, for
OpenMP, the copies in benchmark/par/c/openmp/ with one `#pragma omp` line each,
built by GCC and clang. Two comparisons, never mixed:

  one thread     xcc -O3 (no --par-auto)  against  gcc / clang -O3 -march=native
  every thread   xcc -O3 --par-auto, on the CPU (XC_PAR=cpu)
                                          against  gcc / clang -O3 -march=native -fopenmp

All on one Linux machine (XTC_C_HOST in build.env, else XTC_LINUX_HOST): xcc
cross-builds here with the shipped compiler, GCC and clang build there. Each
program prints "<checksum> <best_us> <first_us>"; every build is run several
times, round-robin, the machine idle before each round (../run.py's check),
and the figure is the median of the runs' best times (the spread is wide on
all three, so a single run says little). Every build's checksum must agree.
Writes benchmark/par/v<version>/c.json; page.py makes the C page from it.

  python3 benchmark/par/c_run.py
  python3 benchmark/par/c_run.py --bench md5 --runs 5
"""
import argparse
import json
import os
import shlex
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import run as common  # noqa: E402

CDIR = os.path.join(HERE, "c")
BENCHES = ["saxpy", "nbody", "perlin", "md5", "md5_mask", "mandelbrot", "mandel_deep"]
# mode -> (the build's file suffix, the environment it runs with)
MODES = {
    "one": ["xcc", "gcc", "clang"],
    "all": ["xcc", "gcc", "clang"],
}
BUDGET_US = 30e6        # about this long per build: fewer runs of a long program


def sh(host, cmd, check=True):
    r = subprocess.run(["ssh", host, cmd], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit("par/c_run.py: on %s: %s\n%s" % (host, cmd, r.stderr))
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", action="append")
    ap.add_argument("--runs", type=int, default=15, help="the most runs of a build")
    ap.add_argument("--version", default=common.COMPILER_VERSION)
    a = ap.parse_args()
    env = common.build_env()
    host = env.get("XTC_C_HOST") or env.get("XTC_LINUX_HOST")
    if not host:
        sys.exit("par/c_run.py: no XTC_C_HOST or XTC_LINUX_HOST in build.env")
    benches = a.bench or BENCHES
    work = os.path.join(HERE, "build", "c")
    os.makedirs(work, exist_ok=True)
    xcc = [common.xcc_path()] + common.xcc_home_args() + common.bench_flags()
    for b in benches:
        src = os.path.join(CDIR, b + ".c")
        for tag, extra in (("xcc-one", []), ("xcc-all", ["--par-auto"])):
            out = os.path.join(work, "%s.%s" % (b, tag))
            r = subprocess.run(xcc + ["-q", "-A", "x86_64", "-O3"] + extra + ["-o", out, src],
                               capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit("par/c_run.py: xcc does not build %s:\n%s" % (b, r.stderr))
    rdir = "/tmp/xc-cbench"
    sh(host, "rm -rf %s && mkdir -p %s/openmp" % (rdir, rdir))
    subprocess.run(["scp", "-q"] + [os.path.join(CDIR, f) for f in os.listdir(CDIR) if f.endswith((".c", ".h"))]
                   + ["%s:%s/" % (host, rdir)], check=True)
    od = os.path.join(CDIR, "openmp")
    subprocess.run(["scp", "-q"] + [os.path.join(od, f) for f in os.listdir(od)] + ["%s:%s/openmp/" % (host, rdir)],
                   check=True)
    subprocess.run(["scp", "-q"] + [os.path.join(work, f) for f in os.listdir(work) if f.split(".")[0] in benches]
                   + ["%s:%s/" % (host, rdir)], check=True)
    builds = []
    for b in benches:
        builds.append("gcc -O3 -march=native -w -o {b}.gcc-one {b}.c -lm".format(b=b))
        builds.append("clang -O3 -march=native -w -o {b}.clang-one {b}.c -lm".format(b=b))
        builds.append("gcc -O3 -march=native -fopenmp -w -o {b}.gcc-all openmp/{b}.c -lm".format(b=b))
        builds.append("clang -O3 -march=native -fopenmp -w -o {b}.clang-all openmp/{b}.c -lm".format(b=b))
    sh(host, "cd %s && %s" % (rdir, " && ".join(builds)))
    toolchains = {"xcc": common.COMPILER_VERSION,
                  "gcc": sh(host, "gcc --version").splitlines()[0],
                  "clang": sh(host, "clang --version").splitlines()[0]}
    cpu = sh(host, "grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-").strip()
    threads = int(sh(host, "nproc").strip())

    def run_once(b, mode, comp):
        pre = "XC_PAR=cpu " if (comp == "xcc" and mode == "all") else ""
        out = sh(host, "cd %s && %s./%s.%s-%s" % (rdir, pre, b, comp, mode)).split()
        return out[0], int(out[1])

    results = {}
    for b in benches:
        results[b] = {"one": {}, "all": {}}
        times = {(m, c): [] for m in MODES for c in MODES[m]}
        sums = {}
        # The first round sets each build's number of runs from its time.
        common.wait_quiet(host)
        for key in times:
            s, t = run_once(b, *key)
            sums[key] = s
            times[key].append(t)
        runs = {k: max(3, min(a.runs, int(BUDGET_US / max(v[0], 1)))) for k, v in times.items()}
        for r in range(1, max(runs.values())):
            common.wait_quiet(host)
            for key in times:
                if r < runs[key]:
                    s, t = run_once(b, *key)
                    if s != sums[key]:
                        sys.exit("par/c_run.py: %s %s-%s gave checksum %s, then %s" % (b, key[1], key[0], sums[key], s))
                    times[key].append(t)
        if len(set(sums.values())) != 1:
            sys.exit("par/c_run.py: %s: the builds disagree: %s" % (b, sums))
        for (m, c), ts in times.items():
            results[b][m][c] = {"median_us": statistics.median(ts), "runs": len(ts)}
        results[b]["checksum"] = next(iter(sums.values()))
        print("%-12s one: %s   all: %s" % (b, "  ".join("%s %.2f ms" % (c, results[b]["one"][c]["median_us"] / 1000)
                                                        for c in MODES["one"]),
                                           "  ".join("%s %.2f ms" % (c, results[b]["all"][c]["median_us"] / 1000)
                                                     for c in MODES["all"])), flush=True)
    outdir = os.path.join(HERE, "v" + a.version)
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, "c.json")
    prev = {}
    if a.bench and os.path.exists(path):
        with open(path) as fh:
            prev = json.load(fh).get("results", {})
    prev.update(results)
    with open(path, "w") as fh:
        json.dump({"cpu": cpu, "threads": threads, "toolchains": toolchains, "results": prev},
                  fh, indent=1, sort_keys=True)
    print("results -> %s" % os.path.relpath(path, common.REPO))


if __name__ == "__main__":
    main()
