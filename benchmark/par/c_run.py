#!/usr/bin/env python3
"""benchmark/par/c_run.py — the C (or C++) par programs against GCC and clang.

The same C files (benchmark/par/c/*.c, undecorated) built by xcc, and, for
OpenMP, the copies in benchmark/par/c/openmp/ with one `#pragma omp` line each,
built by GCC and clang. --lang c++ runs the C++ ports the same way
(benchmark/par/cpp/*.cpp, their OpenMP copies in cpp/openmp/ with a pragma on
each loop that does the work) against g++ and clang++, into cpp.json (cpp-pi.json
on the Pi). Two comparisons, never mixed:

  one thread     xcc -O3 --par-style=cpu (no lifting)  against  gcc / clang -O3 -march=native
  every thread   xcc -O3 --par-style=auto, on the CPU (XC_PAR=cpu)
                                          against  gcc / clang -O3 -march=native -fopenmp

All on one Linux machine (XTC_C_HOST in build.env, else XTC_LINUX_HOST): xcc
cross-builds here with the shipped compiler, GCC and clang build there. Each
program prints "<checksum> <best_us> <first_us>"; every build is run several
times, round-robin, the machine idle before each round (../run.py's check),
and the figure is the median of the runs' best times (the spread is wide on
all three, so a single run says little). Every build's checksum must agree.
Writes benchmark/par/v<version>/c.json; page.py makes the C page from it.
--machine pi runs the same suite on an arm64 Linux machine
(XTC_LINUX_ARM64_HOST, a Raspberry Pi 5) with xcc building for arm64-linux,
into c-pi.json. Where that machine's clang has no OpenMP runtime (libomp) its
every-thread build is left out and the file says so.

  python3 benchmark/par/c_run.py
  python3 benchmark/par/c_run.py --bench md5 --runs 5
  python3 benchmark/par/c_run.py --machine pi --xcc compiler/bin/osx/xcc-xc
  python3 benchmark/par/c_run.py --lang c++
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
# Each language: its sources' directory and extension, its compilers on the
# Linux machine (the files' "gcc" and "clang" keys), their standard flag, and
# the results file's stem.
LANGS = {
    "c": {"dir": "c", "ext": ".c", "gcc": "gcc", "clang": "clang", "std": "", "stem": "c"},
    "c++": {"dir": "cpp", "ext": ".cpp", "gcc": "g++", "clang": "clang++", "std": "-std=c++17", "stem": "cpp"},
}
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
    ap.add_argument("--skip", action="append", default=[],
                    help="leave a benchmark out of this run (a release runs the Pi's mandel_deep last, "
                         "on its own, and publishes without waiting for it; owner 2026-11-06)")
    ap.add_argument("--runs", type=int, default=15, help="the most runs of a build")
    ap.add_argument("--version", default=common.COMPILER_VERSION)
    ap.add_argument("--machine", choices=["linux", "pi"], default="linux")
    ap.add_argument("--lang", choices=sorted(LANGS), default="c")
    ap.add_argument("--xcc", help="the compiler to measure (default: the installed release)")
    ap.add_argument("--carry-from", metavar="VERSION",
                    help="time xcc only, and carry GCC's and clang's figures (and toolchains) from that "
                         "version's file: a point release re-times the compiler that changed")
    a = ap.parse_args()
    env = common.build_env()
    L = LANGS[a.lang]
    sdir = os.path.join(HERE, L["dir"])
    std = L["std"].split()
    if a.machine == "pi":
        host, arch, name = env.get("XTC_LINUX_ARM64_HOST"), "arm64-linux", L["stem"] + "-pi.json"
        if not host:
            sys.exit("par/c_run.py: no XTC_LINUX_ARM64_HOST in build.env")
    else:
        host, arch, name = env.get("XTC_C_HOST") or env.get("XTC_LINUX_HOST"), "x86_64", L["stem"] + ".json"
        if not host:
            sys.exit("par/c_run.py: no XTC_C_HOST or XTC_LINUX_HOST in build.env")
    benches = [b for b in (a.bench or BENCHES) if b not in a.skip]
    work = os.path.join(HERE, "build", L["stem"] + "-" + a.machine)
    os.makedirs(work, exist_ok=True)
    if a.xcc:
        xp = os.path.abspath(a.xcc)
        xcc = [xp] + ([] if xp.startswith("/opt/xcc/") else ["-H", os.path.join(common.REPO, "compiler")]) \
            + common.bench_flags(xp)
    else:
        xcc = [common.xcc_path()] + common.xcc_home_args() + common.bench_flags()
    for b in benches:
        src = os.path.join(sdir, b + L["ext"])
        # One thread is --par-style=cpu: since 0.9.2 lifting is the default,
        # so a build with no flag ran its loops on every thread (or the GPU)
        # and the "one thread" column compared that with gcc's single thread.
        for tag, extra in (("xcc-one", ["--par-style=cpu"]), ("xcc-all", ["--par-style=auto"])):
            out = os.path.join(work, "%s.%s" % (b, tag))
            r = subprocess.run(xcc + ["-q", "-A", arch, "-O3"] + std + extra + ["-o", out, src],
                               capture_output=True, text=True)
            if r.returncode != 0:
                sys.exit("par/c_run.py: xcc does not build %s:\n%s" % (b, r.stderr))
    # The sources as they lie here (c/, and cpp/ beside it, whose files
    # include ../c/bench_time.h), built in the language's directory.
    top = "/tmp/xc-cbench"
    rdir = "%s/%s" % (top, L["dir"])
    sh(host, "rm -rf %s && mkdir -p %s/openmp %s/c" % (top, rdir, top))
    subprocess.run(["scp", "-q"] + [os.path.join(CDIR, f) for f in os.listdir(CDIR) if f.endswith(".h")]
                   + ["%s:%s/c/" % (host, top)], check=True)
    subprocess.run(["scp", "-q"] + [os.path.join(sdir, f) for f in os.listdir(sdir) if f.endswith((L["ext"], ".h"))]
                   + ["%s:%s/" % (host, rdir)], check=True)
    od = os.path.join(sdir, "openmp")
    subprocess.run(["scp", "-q"] + [os.path.join(od, f) for f in os.listdir(od)] + ["%s:%s/openmp/" % (host, rdir)],
                   check=True)
    subprocess.run(["scp", "-q"] + [os.path.join(work, f) for f in os.listdir(work) if f.split(".")[0] in benches]
                   + ["%s:%s/" % (host, rdir)], check=True)
    # clang's OpenMP needs libomp, which a distribution's clang may not have.
    probe = "echo 'int main(void){return 0;}' > %s/omp%s && %s -fopenmp -o %s/omp %s/omp%s" % (
        rdir, L["ext"], L["clang"], rdir, rdir, L["ext"])
    clang_omp = subprocess.run(["ssh", host, probe], capture_output=True).returncode == 0
    missing = [] if clang_omp else ["all/clang: no OpenMP runtime (libomp) for clang on that machine"]
    carried = None
    if a.carry_from:
        cp = os.path.join(HERE, "v" + a.carry_from, name)
        if not os.path.exists(cp):
            sys.exit("par/c_run.py: --carry-from %s: no %s" % (a.carry_from, os.path.relpath(cp, common.REPO)))
        with open(cp) as fh:
            carried = json.load(fh)
    builds = []
    for b in benches:
        if carried:
            continue
        f = dict(b=b, e=L["ext"], g=L["gcc"], c=L["clang"], s=L["std"])
        builds.append("{g} {s} -O3 -march=native -w -o {b}.gcc-one {b}{e} -lm".format(**f))
        builds.append("{c} {s} -O3 -march=native -w -o {b}.clang-one {b}{e} -lm".format(**f))
        builds.append("{g} {s} -O3 -march=native -fopenmp -w -o {b}.gcc-all openmp/{b}{e} -lm".format(**f))
        if clang_omp:
            builds.append("{c} {s} -O3 -march=native -fopenmp -w -o {b}.clang-all openmp/{b}{e} -lm".format(**f))
    if builds:
        sh(host, "cd %s && %s" % (rdir, " && ".join(builds)))
    if carried:
        toolchains = dict(carried.get("toolchains", {}))
        toolchains["xcc"] = a.version
        toolchains["carried"] = a.carry_from
        missing = carried.get("missing", [])
    else:
        toolchains = {"xcc": a.version,
                      "gcc": sh(host, "%s --version" % L["gcc"]).splitlines()[0],
                      "clang": sh(host, "%s --version" % L["clang"]).splitlines()[0]}
    # x86 names its CPU in /proc/cpuinfo; arm64 Linux does not, but lscpu does,
    # and a Raspberry Pi names the board in its device tree.
    cpu = sh(host, "grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-", check=False).strip() \
        or sh(host, "lscpu | grep -m1 'Model name' | cut -d: -f2-", check=False).strip()
    board = sh(host, "tr -d '\\0' < /proc/device-tree/model 2>/dev/null", check=False).strip()
    if board:
        cpu = "%s (%s)" % (board, cpu)
    threads = int(sh(host, "nproc").strip())

    def run_once(b, mode, comp):
        pre = "XC_PAR=cpu " if (comp == "xcc" and mode == "all") else ""
        out = sh(host, "cd %s && %s./%s.%s-%s" % (rdir, pre, b, comp, mode)).split()
        return out[0], int(out[1])

    results = {}
    for b in benches:
        results[b] = {"one": {}, "all": {}}
        times = {(m, c): [] for m in MODES for c in MODES[m] if clang_omp or (m, c) != ("all", "clang")}
        if carried:
            times = {k: v for k, v in times.items() if k[1] == "xcc"}
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
        if carried:
            # The carried compilers' answer is the one xcc's must give.
            want = carried.get("results", {}).get(b, {}).get("checksum")
            if want is not None and set(sums.values()) != {want}:
                sys.exit("par/c_run.py: %s: xcc gave %s, the carried figures %s" % (b, set(sums.values()), want))
            for m in ("one", "all"):
                for c, v in carried.get("results", {}).get(b, {}).get(m, {}).items():
                    if c != "xcc":
                        results[b][m][c] = v
        if len(set(sums.values())) != 1:
            sys.exit("par/c_run.py: %s: the builds disagree: %s" % (b, sums))
        for (m, c), ts in times.items():
            results[b][m][c] = {"median_us": statistics.median(ts), "runs": len(ts)}
        results[b]["checksum"] = next(iter(sums.values()))
        print("%-12s one: %s   all: %s" % (b, "  ".join("%s %.2f ms" % (c, results[b]["one"][c]["median_us"] / 1000)
                                                        for c in MODES["one"]),
                                           "  ".join("%s %.2f ms" % (c, results[b]["all"][c]["median_us"] / 1000)
                                                     for c in MODES["all"] if c in results[b]["all"])), flush=True)
    outdir = os.path.join(HERE, "v" + a.version)
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, name)
    prev = {}
    if a.bench and os.path.exists(path):
        with open(path) as fh:
            prev = json.load(fh).get("results", {})
    prev.update(results)
    with open(path, "w") as fh:
        json.dump({"cpu": cpu, "threads": threads, "toolchains": toolchains, "results": prev,
                   "missing": missing},
                  fh, indent=1, sort_keys=True)
    print("results -> %s" % os.path.relpath(path, common.REPO))


if __name__ == "__main__":
    main()
