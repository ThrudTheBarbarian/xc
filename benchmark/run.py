#!/usr/bin/env python3
"""Benchmark xc against Objective-C (both with ARC), C++ and Swift, over the same
programs.

Every benchmark is a pair in src/, <name>.xc and <name>.m, and may also have a
<name>.cpp and a <name>.swift. They all compute the same thing and print the
same checksum, so a mismatch is a miscompile in one of them rather than a
timing result. C++ is built with clang++ and Swift with swiftc, on each host,
and on the Linux host the C++ goes through g++ as well.

Every compiler is given the machine's full instruction set, as xc has it
through its default -msimd=auto (each vectorised function built for SSE2, AVX2
and AVX-512 and picked when the program starts): -march=native on x86-64 and
-mcpu=native on arm64 for clang and GCC, -target-cpu native for swiftc. The
toolchains' versions are recorded in results.json, so the page can state them.

Each program times its own measured region with clock_gettime(CLOCK_MONOTONIC)
and prints "<checksum> <elapsed_us>". Both languages call the same primitive
through the same libc, so the measurement is identical on both sides, and
process startup and data setup fall outside the figure with nothing to subtract.
Each program runs REPEATS times and the fastest is kept, which is the usual
choice on a machine that is also doing other things.

  run.py                     measure everything, write results to <version>/
  run.py --version v0.61     which directory to write to (default: v<compiler/VERSION>)
  run.py --bench int_accum   restrict to one benchmark
  run.py --repeats 7         runs per data point
  run.py --opt O2            restrict to one optimisation level
  run.py --langs cpp,swift   restrict to some languages (xc objc cpp gcc swift;
                             gcc is the C++ source through the Linux host's g++)
  run.py --max-load 0.25     wait until each machine's 1-minute load average,
                             per core, is at or below this before timing on it
  run.py --platform pi       an arm64 Linux machine (XTC_LINUX_ARM64_HOST, a
                             Raspberry Pi 5) alone: xc cross-built here, the C++
                             source through its clang++ and g++; results-pi.json
  run.py --xcc PATH          measure this compiler, not the installed release

Hosts for platforms other than this one come from build.env at the repository
root. A variable left empty turns off that platform and the run reports the skip.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
SRC = os.path.join(ROOT, "src")
with open(os.path.join(REPO, "compiler", "VERSION")) as _vf:
    COMPILER_VERSION = _vf.read().strip()
# XC_BENCH_XCC_VERSION=<v> measures the installed /opt/xcc/<v> instead: how a
# benchmark added later is measured for earlier releases (--version names the
# results it merges into).
COMPILER_VERSION = os.environ.get("XC_BENCH_XCC_VERSION") or COMPILER_VERSION
OPTS = ["O0", "O1", "O2", "O3"]
BASELINE = "baseline"

MAX_LOAD = 0.25          # per core; --max-load overrides
LOAD_POLL = 15           # seconds between checks
LOAD_GIVE_UP = 3600      # seconds before the run stops rather than time a busy machine
_load_ok = {}            # host -> time of the last passing check


def load_per_core(host=None):
    """1-minute load average divided by core count, here or on `host`."""
    if host is None:
        return os.getloadavg()[0] / (os.cpu_count() or 1)
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", host,
                        "cut -d' ' -f1 /proc/loadavg; nproc"],
                       capture_output=True, text=True)
    load, cores = r.stdout.split()
    return float(load) / int(cores)


def wait_quiet(host=None):
    """Do not time anything on a busy machine: wait for its load to drop.

    Checked at most once a minute per machine, so the check itself does not
    add ssh traffic to every run.
    """
    now = time.time()
    if now - _load_ok.get(host, 0) < 60:
        return
    start, said = now, False
    while True:
        lpc = load_per_core(host)
        if lpc <= MAX_LOAD:
            _load_ok[host] = time.time()
            if said:
                print("  load on %s is %.2f per core: continuing" % (host or "this host", lpc),
                      flush=True)
            return
        if time.time() - start > LOAD_GIVE_UP:
            sys.exit("run.py: %s stayed above %.2f load per core for %d s; not timing a busy machine"
                     % (host or "this host", MAX_LOAD, LOAD_GIVE_UP))
        if not said:
            print("  load on %s is %.2f per core (limit %.2f): waiting"
                  % (host or "this host", lpc, MAX_LOAD), flush=True)
            said = True
        time.sleep(LOAD_POLL)


def build_env():
    """Values from build.env, so no host or path is written into the tree."""
    out = {}
    path = os.path.join(REPO, "build.env")
    if not os.path.isfile(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def toolchains(host):
    """The version line of each compiler used, here and on `host`, so the
    results say what they were measured against."""
    def first_line(cmd, remote=None):
        if remote:
            cmd = "set -a; [ -f ~/ci/ci-env.sh ] && . ~/ci/ci-env.sh; set +a; " + cmd
            r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", remote, cmd],
                               capture_output=True, text=True)
        else:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        out = (r.stdout or r.stderr).strip().splitlines()
        return out[0].strip() if out else None
    tc = {"xcc": COMPILER_VERSION,
          "arm64": {"clang": first_line("clang++ --version"),
                    "swiftc": first_line("swiftc --version 2>&1")}}
    if gpp():
        tc["arm64"]["gcc"] = first_line(gpp() + " --version")
    # The CPU and the features that change the code xcc emits (SME on arm64,
    # AVX-512 on x86-64), so results from two machines are never mistaken
    # for one (0.87 measures arm64 on an M3 Max, which has no SME).
    brand = first_line("sysctl -n machdep.cpu.brand_string")
    if brand:
        sme = first_line("sysctl -n hw.optional.arm.FEAT_SME 2>/dev/null") == "1"
        tc["arm64"]["cpu"] = "%s (%s SME)" % (brand, "with" if sme else "no")
    if host:
        tc["x86_64"] = {"clang": first_line("clang++ --version", host),
                        "gcc": first_line("g++ --version", host),
                        "swiftc": first_line("swiftc --version 2>&1", host)}
        model = first_line("grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2-", host)
        if model:
            avx = first_line("grep -c -m1 -w avx512f /proc/cpuinfo", host) == "1"
            tc["x86_64"]["cpu"] = "%s (%s AVX-512)" % (model, "with" if avx else "no")
    return tc


def benchmarks():
    """Pairs present in src/, baseline first."""
    names = set()
    for f in os.listdir(SRC):
        stem, ext = os.path.splitext(f)
        if ext in (".xc", ".m"):
            names.add(stem)
    have = sorted(n for n in names
                  if os.path.isfile(os.path.join(SRC, n + ".xc"))
                  and os.path.isfile(os.path.join(SRC, n + ".m")))
    unpaired = sorted(names - set(have))
    return have, unpaired


XCC_OVERRIDE = None     # --xcc


def xcc_path():
    """The SHIPPED compiler: the installed release, /opt/xcc/<VERSION>/bin/xcc.

    The performance page says its figures come from the xcc in the download,
    and the installed release is that binary (make install and make dist stage
    the same stage-2 build). A build-tree compiler is used only when no release
    is installed, and the run says so. The Objective-C bootstrap is never
    measured.
    """
    if XCC_OVERRIDE:
        return XCC_OVERRIDE
    installed = os.path.join("/opt/xcc", COMPILER_VERSION, "bin", "xcc")
    if os.access(installed, os.X_OK):
        return installed
    for name in ("xcc-xc2", "xcc-xc"):
        p = os.path.join(REPO, "compiler", "bin", "osx", name)
        if os.access(p, os.X_OK):
            print("note: no installed xcc %s; measuring the build tree's %s"
                  % (COMPILER_VERSION, name))
            return p
    sys.exit("run.py: no xcc to measure (make install, or make production)")


def xcc_home_args():
    """An installed xcc finds its own library; a build-tree one needs -H."""
    return [] if xcc_path().startswith("/opt/xcc/") else ["-H", os.path.join(REPO, "compiler")]


_NO_CHECKS = {}


def bench_flags(xcc=None):
    """Benchmarks are built without subscript checks (owner, 2026-10-22), so the
    figures stay comparable with clang's and GCC's. An xcc from before the
    checks became the default (0.86) has no such flag and needs none."""
    x = xcc or xcc_path()
    if x not in _NO_CHECKS:
        try:
            r = subprocess.run([x, "--help"], capture_output=True, text=True)
            _NO_CHECKS[x] = "-fno-bounds-check" in (r.stdout + r.stderr)
        except OSError:
            _NO_CHECKS[x] = False
    return ["-fno-bounds-check"] if _NO_CHECKS[x] else []


def compile_xc(name, opt, out):
    cmd = [xcc_path()] + xcc_home_args() + bench_flags() + ["-I", SRC, "-" + opt,
           "-o", out, os.path.join(SRC, name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def compile_xc_pi(name, opt, out):
    """Cross-build for arm64 Linux (glibc), as `-A arm64-linux` links it."""
    cmd = [xcc_path()] + xcc_home_args() + bench_flags() + ["-I", SRC, "-A", "arm64-linux",
           "-" + opt, "-o", out, os.path.join(SRC, name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def compile_xc_x86(name, opt, out):
    """Cross-build for x86-64 Linux, linked as the release links it by default:
    a static ELF up to 0.71, a glibc executable from 0.72. Either way the remote
    host needs no toolchain of its own."""
    cmd = [xcc_path()] + xcc_home_args() + bench_flags() + ["-I", SRC, "-A", "x86_64",
           "-" + opt, "-o", out, os.path.join(SRC, name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def build_remote(name, opt, tag, host, lang):
    """Compile the Objective-C, C++ or Swift version ON the remote host.

    GNUstep Objective-C cannot be cross-built from macOS, so the source goes
    over and clang runs there against libobjc2 and gnustep-base, with the
    flags that host's own environment script sets. C++ and Swift are built
    there too, with that host's clang++ and swiftc.
    """
    ext = {"objc": ".m", "cpp": ".cpp", "gcc": ".cpp", "swift": ".swift"}[lang]
    src = os.path.join(SRC, name + ext)
    incs = [os.path.join(SRC, "include", "bench_time.h")]
    if lang == "swift":
        incs.append(os.path.join(SRC, "include", "bench_time.swift"))
    rdir = "/tmp/xcbench"
    pre = ("mkdir -p %s/include" % rdir)
    if subprocess.run(["ssh", "-o", "ConnectTimeout=10", host, pre]).returncode != 0:
        return None, "remote mkdir failed"
    for f, dest in [(src, rdir + "/")] + [(i, rdir + "/include/") for i in incs]:
        if subprocess.run(["scp", "-q", f, "%s:%s" % (host, dest)]).returncode != 0:
            return None, "scp failed"
    out = "%s/%s.%s.%s" % (rdir, name, lang, tag)
    if lang == "objc":
        build = ("clang -fobjc-arc -fobjc-runtime=gnustep-2.2 -I/opt/gnustep/include -I%s "
                 "-%s -march=native -L/opt/gnustep/lib -lobjc -lgnustep-base -o %s %s.m"
                 % (rdir, opt, out, name))
    elif lang == "cpp":
        build = "clang++ -std=c++17 -I%s -%s -march=native -o %s %s.cpp" % (rdir, opt, out, name)
    elif lang == "gcc":
        # The same C++ source through that host's GCC: the comparison a Linux
        # reader expects, beside clang's.
        build = "g++ -std=c++17 -I%s -%s -march=native -o %s %s.cpp" % (rdir, opt, out, name)
    else:
        build = ("swiftc %s -target-cpu native -parse-as-library -o %s include/bench_time.swift %s.swift"
                 % (swift_opt(opt), out, name))
    cmd = ("set -a; [ -f ~/ci/ci-env.sh ] && . ~/ci/ci-env.sh; set +a; cd %s && %s"
           % (rdir, build))
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=20", host, cmd],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr or r.stdout).strip().splitlines()[:2]
    return out, None


def run_remote(remote_path, repeats, host, env_prefix=""):
    """Run an already-present remote binary and take the fastest report."""
    best, checksum = None, None
    for _ in range(repeats):
        wait_quiet(host)
        r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", host,
                            "%schmod +x %s && %s x" % (env_prefix, remote_path, remote_path)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return None, "remote exit %d" % r.returncode
        parts = r.stdout.split()
        if len(parts) != 2:
            return None, "bad remote output %r" % r.stdout.strip()[:40]
        checksum = parts[0]
        try:
            us = int(parts[1]) / 1e6
        except ValueError:
            return None, "bad elapsed %r" % parts[1]
        best = us if best is None else min(best, us)
    return best, checksum


def measure_remote(binary, repeats, host):
    """Copy once, then run there. Same self-reported timing as the local path."""
    if subprocess.run(["scp", "-q", binary, "%s:/tmp/" % host]).returncode != 0:
        return None, "scp failed"
    remote = "/tmp/" + os.path.basename(binary)
    best, checksum = None, None
    for _ in range(repeats):
        wait_quiet(host)
        r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", host,
                            "chmod +x %s && %s x" % (remote, remote)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            return None, "remote exit %d" % r.returncode
        parts = r.stdout.split()
        if len(parts) != 2:
            return None, "bad remote output %r" % r.stdout.strip()[:40]
        checksum = parts[0]
        try:
            best = min(best, int(parts[1]) / 1e6) if best is not None else int(parts[1]) / 1e6
        except ValueError:
            return None, "bad elapsed %r" % parts[1]
    return best, checksum


def compile_cpp(name, opt, out):
    cmd = ["clang++", "-std=c++17", "-" + opt, "-mcpu=native", "-I", SRC,
           "-o", out, os.path.join(SRC, name + ".cpp")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


_GPP = None
def gpp():
    """Real GCC on this host: the Homebrew g++-NN (the bare `g++` on macOS is
    Apple clang). Highest version wins; None if no real GCC is installed."""
    global _GPP
    if _GPP is None:
        import glob
        c = sorted(glob.glob("/opt/homebrew/bin/g++-[0-9]*"), reverse=True) or \
            sorted(glob.glob("/usr/local/bin/g++-[0-9]*"), reverse=True)
        _GPP = c[0] if c else ""
    return _GPP


def compile_gcc(name, opt, out):
    g = gpp()
    if not g:
        return False, "no real GCC (Homebrew g++-NN) on this host"
    cmd = [g, "-std=c++17", "-" + opt, "-mcpu=native", "-I", SRC,
           "-o", out, os.path.join(SRC, name + ".cpp")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def swift_opt(opt):
    """swiftc has -Onone and -O; every optimising level maps to -O. Each
    program is an @main struct (-parse-as-library), so its counters are locals
    of main, as they are in the C versions, rather than globals."""
    return "-Onone" if opt == "O0" else "-O"


def compile_swift(name, opt, out):
    cmd = ["swiftc", swift_opt(opt), "-target-cpu", "native", "-parse-as-library", "-o", out,
           os.path.join(SRC, "include", "bench_time.swift"), os.path.join(SRC, name + ".swift")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def compile_objc(name, opt, out):
    cmd = ["clang", "-fobjc-arc", "-" + opt, "-mcpu=native", "-I", SRC, "-framework", "Foundation",
           "-o", out, os.path.join(SRC, name + ".m")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def measure(binary, repeats):
    """Fastest self-reported elapsed time of `repeats` runs, and the checksum.

    Each program prints "<checksum> <elapsed_us>". It times its own measured
    region with clock_gettime(CLOCK_MONOTONIC), the same call the other language
    makes, so process startup and data setup are outside the figure and nothing
    has to be subtracted afterwards.
    """
    best, checksum = None, None
    for _ in range(repeats):
        wait_quiet()
        r = subprocess.run([binary, "x"], capture_output=True, text=True)
        if r.returncode != 0:
            return None, "exit %d" % r.returncode
        parts = r.stdout.split()
        if len(parts) != 2:
            return None, "bad output %r" % r.stdout.strip()[:40]
        checksum = parts[0]
        try:
            us = int(parts[1])
        except ValueError:
            return None, "bad elapsed %r" % parts[1]
        secs = us / 1e6
        best = secs if best is None else min(best, secs)
    return best, checksum


def main():
    global MAX_LOAD
    ap = argparse.ArgumentParser(description="xc against Objective-C, both with ARC")
    with open(os.path.join(REPO, "compiler", "VERSION")) as f:
        default_version = "v" + f.read().strip()
    ap.add_argument("--version", default=default_version)
    ap.add_argument("--bench", default=None)
    # -O3 only by default: the page shows -O3 and nothing else (owner
    # 2026-10-31: the benchmarks showcase the best we offer, and four levels
    # took most of a release's benchmark time). `--opt all` measures every
    # level, for a look at the others; diy.py keeps all four.
    ap.add_argument("--opt", default="O3", help="one level (O0..O3), or all")
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--max-load", type=float, default=MAX_LOAD)
    ap.add_argument("--langs", default=None,
                    help="comma-separated subset of xc,objc,cpp,gcc,swift (gcc: the C++ source "
                         "through the Linux host's g++; x86-64 only)")
    ap.add_argument("--platform", default=None, choices=["arm64", "x86_64", "pi"],
                    help="measure one target's legs only (the other machine may be busy); "
                         "pi: the arm64 Linux machine alone, into results-pi.json")
    ap.add_argument("--xcc", default=None, help="the compiler to measure (default: the installed release)")
    args = ap.parse_args()
    MAX_LOAD = args.max_load
    global XCC_OVERRIDE
    if args.xcc:
        XCC_OVERRIDE = os.path.abspath(args.xcc)

    names, unpaired = benchmarks()
    if unpaired:
        print("unpaired sources (skipped): " + ", ".join(unpaired))
    if args.bench:
        names = [n for n in names if n == args.bench]
        if not names:
            sys.exit("no such benchmark: " + args.bench)
    opts = OPTS if args.opt == "all" else [args.opt]

    env = build_env()
    if not env.get("XTC_LINUX_HOST"):
        print("XTC_LINUX_HOST is empty in build.env: measuring this host only")

    work = os.path.join(ROOT, "build")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)

    results, failures, mismatches = {}, [], []
    langs = [("xc", compile_xc), ("objc", compile_objc),
             ("cpp", compile_cpp), ("swift", compile_swift)]
    if gpp():
        langs.append(("gcc", compile_gcc))   # real GCC on this host (macOS: Homebrew g++)
    host = env.get("XTC_LINUX_HOST")
    if args.platform == "pi":
        # The Pi alone: its own legs, under their own names, in their own file.
        host = env.get("XTC_LINUX_ARM64_HOST")
        if not host:
            sys.exit("run.py: --platform pi needs XTC_LINUX_ARM64_HOST in build.env")
        langs = [("xc_pi", compile_xc_pi), ("cpp_pi", None), ("gcc_pi", None)]
    elif host:
        langs.append(("xc_x86_64", compile_xc_x86))
        langs.append(("objc_x86_64", None))   # compiled on the remote host
        langs.append(("cpp_x86_64", None))
        langs.append(("gcc_x86_64", None))    # the C++ source through GCC, Linux only
        langs.append(("swift_x86_64", None))
        print("x86-64 legs enabled on the configured host: xc is cross-built here "
              "and shipped as the release links it by default; Objective-C, C++ and Swift are compiled "
              "there (GNUstep Objective-C cannot be cross-built from macOS).")
    if args.langs:
        want = set(args.langs.split(","))
        langs = [(l, c) for l, c in langs if l.split("_x86_64")[0].split("_pi")[0] in want]
    if args.platform in ("arm64", "x86_64"):
        langs = [(l, c) for l, c in langs if l.endswith("_x86_64") == (args.platform == "x86_64")]
    source_ext = {"xc": ".xc", "objc": ".m", "cpp": ".cpp", "gcc": ".cpp", "swift": ".swift"}

    for opt in opts:
        for name in names:
            checks = {}
            for lang, compiler in langs:
                base = lang.split("_x86_64")[0].split("_pi")[0]
                # C++ and Swift versions are optional: a benchmark without one
                # is simply not measured in that language.
                if not os.path.isfile(os.path.join(SRC, name + source_ext[base])):
                    continue
                if lang in ("objc_x86_64", "cpp_x86_64", "gcc_x86_64", "swift_x86_64", "cpp_pi", "gcc_pi"):
                    rpath, err = build_remote(name, opt, opt, host, base)
                    if rpath is None:
                        failures.append((name, lang, opt, err if isinstance(err, list) else [str(err)]))
                        continue
                    secs, checksum = run_remote(
                        rpath, args.repeats, host,
                        env_prefix="export LD_LIBRARY_PATH=/opt/gnustep/lib; " if base == "objc" else "")
                    if secs is None:
                        failures.append((name, lang, opt, [checksum]))
                        continue
                    checks[lang] = checksum
                    results.setdefault(name, {}).setdefault(opt, {})[lang] = secs
                    print("  %-14s %-12s %-2s  %8.4fs  checksum %s"
                          % (name, lang, opt, secs, checksum), flush=True)
                    continue
                out = os.path.join(work, "%s.%s.%s" % (name, lang, opt))
                ok, log = compiler(name, opt, out)
                if not ok:
                    failures.append((name, lang, opt, log.strip().splitlines()[:2]))
                    continue
                if lang in ("xc_x86_64", "xc_pi"):
                    secs, checksum = measure_remote(out, args.repeats, host)
                else:
                    secs, checksum = measure(out, args.repeats)
                if secs is None:
                    failures.append((name, lang, opt, [checksum]))
                    continue
                checks[lang] = checksum
                results.setdefault(name, {}).setdefault(opt, {})[lang] = secs
                print("  %-14s %-12s %-2s  %8.4fs  checksum %s"
                      % (name, lang, opt, secs, checksum), flush=True)
            if len(set(checks.values())) > 1:
                mismatches.append((name, opt, checks))
                print("  %-14s %-9s %-2s  CHECKSUM MISMATCH %s" % (name, "", opt, checks))

    # Timing is taken inside the program, so there is nothing to subtract.
    # The baseline pair is kept only to show that startup is excluded: it
    # reports zero.
    outdir = os.path.join(ROOT, args.version)
    os.makedirs(outdir, exist_ok=True)
    # A run restricted with --langs or --bench adds to the results already in
    # this version's directory instead of replacing them, so a language can be
    # measured later without re-timing the others.
    rname = "results-pi.json" if args.platform == "pi" else "results.json"
    prev_path = os.path.join(outdir, rname)
    tc = toolchains(None if args.platform == "pi" else host)
    if args.platform == "pi":
        def rl(cmd):
            r = subprocess.run(["ssh", "-o", "ConnectTimeout=10", host, cmd], capture_output=True, text=True)
            o = r.stdout.strip().splitlines()
            return o[0].strip() if o else None
        tc = {"xcc": tc["xcc"] if not XCC_OVERRIDE else args.version,
              "arm64_linux": {"clang": rl("clang++ --version"), "gcc": rl("g++ --version"),
                              "cpu": "%s (%s)" % (rl("tr -d '\\0' < /proc/device-tree/model"),
                                                  rl("lscpu | grep -m1 'Model name' | cut -d: -f2-"))}}
    if (args.langs or args.bench or args.platform) and os.path.isfile(prev_path):
        with open(prev_path) as fh:
            prev_all = json.load(fh)
        prev = prev_all.get("raw", {})
        for n, by_opt in results.items():
            for o, by_lang in by_opt.items():
                prev.setdefault(n, {}).setdefault(o, {}).update(by_lang)
        results = prev
        # The toolchains a partial run did not touch keep their recorded versions.
        for k, v in prev_all.get("toolchains", {}).items():
            if k not in tc or tc[k] is None:
                tc[k] = v
    adjusted = {n: v for n, v in results.items() if n != BASELINE}

    payload = {
        "version": args.version,
        "platform": "arm64-linux" if args.platform == "pi" else
                    subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip(),
        "repeats": args.repeats,
        "toolchains": tc,
        "raw": results,
        "net": adjusted,
        "mismatches": [{"benchmark": n, "opt": o, "checksums": c} for n, o, c in mismatches],
    }
    with open(os.path.join(outdir, rname), "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("\nresults -> %s" % os.path.relpath(os.path.join(outdir, rname), REPO))

    for n, l, o, log in failures:
        print("BUILD/RUN FAILED  %s %s %s: %s" % (n, l, o, " ".join(log)))
    if mismatches:
        print("CHECKSUM MISMATCHES: %d. The two programs do not agree, so the "
              "timings are not comparable." % len(mismatches))
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
