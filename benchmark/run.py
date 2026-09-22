#!/usr/bin/env python3
"""Benchmark xc against Objective-C, both with ARC, over the same programs.

Every benchmark is a pair in src/: <name>.xc and <name>.m. The two compute the
same thing and print the same checksum, so a mismatch is a miscompile in one of
them rather than a timing result.

Each program times its own measured region with clock_gettime(CLOCK_MONOTONIC)
and prints "<checksum> <elapsed_us>". Both languages call the same primitive
through the same libc, so the measurement is identical on both sides, and
process startup and data setup fall outside the figure with nothing to subtract.
Each program runs REPEATS times and the fastest is kept, which is the usual
choice on a machine that is also doing other things.

  run.py                     measure everything, write results to <version>/
  run.py --version v0.6      which directory to write to (default: v0.6)
  run.py --bench int_accum   restrict to one benchmark
  run.py --repeats 7         runs per data point
  run.py --opt O2            restrict to one optimisation level

Hosts for platforms other than this one come from build.env at the repository
root. A variable left empty turns off that platform and the run reports the skip.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
SRC = os.path.join(ROOT, "src")
OPTS = ["O0", "O1", "O2", "O3"]
BASELINE = "baseline"


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


def xcc_path():
    """The SHIPPED compiler, not the bootstrap one.

    `xcc` is the Objective-C reference; `xcc-xc` is the self-hosted compiler
    that is actually released, and it is the only one a published figure may
    come from. The two are gated byte-identical, but "gated byte-identical" has
    meant -O0 for most of this project's life and the benchmarks build at -O3 —
    where they were NOT identical until the optimisers were made to agree
    (private bug 228). Measuring the oracle and publishing it as the product is
    exactly the mistake that invites.
    """
    return os.path.join(REPO, "compiler", "bin", "osx", "xcc-xc")


def compile_xc(name, opt, out):
    cmd = [xcc_path(), "-H", os.path.join(REPO, "compiler"), "-I", SRC, "-" + opt,
           "-o", out, os.path.join(SRC, name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def compile_xc_x86(name, opt, out):
    """Cross-build for x86-64 Linux. The result is a static ELF, so the remote
    host needs no toolchain and no loader of its own."""
    cmd = [xcc_path(), "-H", os.path.join(REPO, "compiler"), "-I", SRC, "-A", "x86_64",
           "-" + opt, "-o", out, os.path.join(SRC, name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stderr or r.stdout)


def build_objc_remote(name, opt, tag, host):
    """Compile the Objective-C half ON the remote host.

    GNUstep Objective-C cannot be cross-built from macOS, so the source goes
    over and clang runs there against libobjc2 and gnustep-base. The flags
    mirror the ones that host's own environment script sets.
    """
    src = os.path.join(SRC, name + ".m")
    inc = os.path.join(SRC, "include", "bench_time.h")
    rdir = "/tmp/xcbench"
    pre = ("mkdir -p %s/include" % rdir)
    if subprocess.run(["ssh", "-o", "ConnectTimeout=10", host, pre]).returncode != 0:
        return None, "remote mkdir failed"
    for f, dest in ((src, rdir + "/"), (inc, rdir + "/include/")):
        if subprocess.run(["scp", "-q", f, "%s:%s" % (host, dest)]).returncode != 0:
            return None, "scp failed"
    out = "%s/%s.%s" % (rdir, name, tag)
    cmd = ("set -a; [ -f ~/ci/ci-env.sh ] && . ~/ci/ci-env.sh; set +a; cd %s && "
           "clang -fobjc-arc -fobjc-runtime=gnustep-2.2 -I/opt/gnustep/include -I%s "
           "-%s -L/opt/gnustep/lib -lobjc -lgnustep-base -o %s %s.m"
           % (rdir, rdir, opt, out, name))
    r = subprocess.run(["ssh", "-o", "ConnectTimeout=20", host, cmd],
                       capture_output=True, text=True)
    if r.returncode != 0:
        return None, (r.stderr or r.stdout).strip().splitlines()[:2]
    return out, None


def run_remote(remote_path, repeats, host, env_prefix=""):
    """Run an already-present remote binary and take the fastest report."""
    best, checksum = None, None
    for _ in range(repeats):
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


def compile_objc(name, opt, out):
    cmd = ["clang", "-fobjc-arc", "-" + opt, "-I", SRC, "-framework", "Foundation",
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
    ap = argparse.ArgumentParser(description="xc against Objective-C, both with ARC")
    ap.add_argument("--version", default="v0.6")
    ap.add_argument("--bench", default=None)
    ap.add_argument("--opt", default=None)
    ap.add_argument("--repeats", type=int, default=5)
    args = ap.parse_args()

    names, unpaired = benchmarks()
    if unpaired:
        print("unpaired sources (skipped): " + ", ".join(unpaired))
    if args.bench:
        names = [n for n in names if n == args.bench]
        if not names:
            sys.exit("no such benchmark: " + args.bench)
    opts = [args.opt] if args.opt else OPTS

    env = build_env()
    if not env.get("XTC_LINUX_HOST"):
        print("XTC_LINUX_HOST is empty in build.env: measuring this host only")

    work = os.path.join(ROOT, "build")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)

    results, failures, mismatches = {}, [], []
    langs = [("xc", compile_xc), ("objc", compile_objc)]
    host = env.get("XTC_LINUX_HOST")
    if host:
        langs.append(("xc_x86_64", compile_xc_x86))
        langs.append(("objc_x86_64", None))   # compiled on the remote host
        print("x86-64 legs enabled on the configured host: xc is cross-built here "
              "and shipped as a static ELF; Objective-C is compiled there against "
              "libobjc2 and gnustep-base, which cannot be cross-built from macOS.")

    for opt in opts:
        for name in names:
            checks = {}
            for lang, compiler in langs:
                if lang == "objc_x86_64":
                    rpath, err = build_objc_remote(name, opt, opt, host)
                    if rpath is None:
                        failures.append((name, lang, opt, err if isinstance(err, list) else [str(err)]))
                        continue
                    secs, checksum = run_remote(
                        rpath, args.repeats, host,
                        env_prefix="export LD_LIBRARY_PATH=/opt/gnustep/lib; ")
                    if secs is None:
                        failures.append((name, lang, opt, [checksum]))
                        continue
                    checks[lang] = checksum
                    results.setdefault(name, {}).setdefault(opt, {})[lang] = secs
                    print("  %-14s %-11s %-2s  %8.4fs  checksum %s"
                          % (name, lang, opt, secs, checksum))
                    continue
                out = os.path.join(work, "%s.%s.%s" % (name, lang, opt))
                ok, log = compiler(name, opt, out)
                if not ok:
                    failures.append((name, lang, opt, log.strip().splitlines()[:2]))
                    continue
                if lang == "xc_x86_64":
                    secs, checksum = measure_remote(out, args.repeats, host)
                else:
                    secs, checksum = measure(out, args.repeats)
                if secs is None:
                    failures.append((name, lang, opt, [checksum]))
                    continue
                checks[lang] = checksum
                results.setdefault(name, {}).setdefault(opt, {})[lang] = secs
                print("  %-14s %-9s %-2s  %8.4fs  checksum %s"
                      % (name, lang, opt, secs, checksum))
            if len(set(checks.values())) > 1:
                mismatches.append((name, opt, checks))
                print("  %-14s %-9s %-2s  CHECKSUM MISMATCH %s" % (name, "", opt, checks))

    # Timing is taken inside the program, so there is nothing to subtract.
    # The baseline pair is kept only to show that startup is excluded: it
    # reports zero.
    adjusted = {n: v for n, v in results.items() if n != BASELINE}

    outdir = os.path.join(ROOT, args.version)
    os.makedirs(outdir, exist_ok=True)
    payload = {
        "version": args.version,
        "platform": subprocess.run(["uname", "-m"], capture_output=True, text=True).stdout.strip(),
        "repeats": args.repeats,
        "raw": results,
        "net": adjusted,
        "mismatches": [{"benchmark": n, "opt": o, "checksums": c} for n, o, c in mismatches],
    }
    with open(os.path.join(outdir, "results.json"), "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("\nresults -> %s" % os.path.relpath(os.path.join(outdir, "results.json"), REPO))

    for n, l, o, log in failures:
        print("BUILD/RUN FAILED  %s %s %s: %s" % (n, l, o, " ".join(log)))
    if mismatches:
        print("CHECKSUM MISMATCHES: %d. The two programs do not agree, so the "
              "timings are not comparable." % len(mismatches))
        return 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
