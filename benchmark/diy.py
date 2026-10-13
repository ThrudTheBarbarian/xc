#!/usr/bin/env python3
"""diy.py — measure one machine's benchmarks and write a contribution JSON.

This is the collector behind the "How to DIY" page: it runs the published
benchmarks on the machine you are sitting at and writes a single file in the
contribution shape the visualiser reads (schema "xc-bench/1").  It is the
single-machine companion to run.py and par/run.py, which measure the project's
own machines; the sources, the flags and the environment are the same, so a
contribution means the same thing.

Two suites, chosen with --suite:

  par     the four par benchmarks (mandelbrot, perlin, nbody, saxpy), each run
          one thread, on every CPU thread, on the GPU, and on auto, exactly as
          par/run.py does.  Needs only xcc (and a GPU for the GPU modes; a
          GPU mode that would run on the CPU is skipped and says why).
  langs   the language comparison: each benchmark in src/, in xc, Objective-C,
          C++ (clang), C++ (GCC) and Swift, at O0..O3, with run.py's flags.  A
          language whose compiler is absent is skipped, not failed.

Every run is repeated (--repeats, five by default) and every repeat's time is
recorded, so the visualiser can draw the spread and not just the best.

  python3 benchmark/diy.py                     # both suites, xc-bench-<host>.json
  python3 benchmark/diy.py --suite par
  python3 benchmark/diy.py --repeats 7 --out my-run.json
  python3 benchmark/diy.py --no-gpu            # skip the GPU modes

The contribution is JSON; nothing here talks to the network.  Submit it with
the visualiser, or upload it by hand.
"""

import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import time
import uuid

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
SRC = os.path.join(ROOT, "src")
PAR = os.path.join(ROOT, "par")
OPTS = ["O0", "O1", "O2", "O3"]
PAR_BENCHES = ["mandelbrot", "perlin", "nbody", "saxpy"]
# par's modes: the environment each run sets, exactly as par/run.py.
PAR_MODES = [("serial", {"XC_PAR": "cpu", "XC_PAR_THREADS": "1"}),
             ("cpu", {"XC_PAR": "cpu"}),
             ("gpu", {"XC_PAR": "gpu"}),
             ("vulkan", {"XC_PAR": "gpu", "XC_PAR_GPU": "vulkan"}),
             ("auto", {})]


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def xcc():
    """The shipped compiler: /opt/xcc/<version>/bin/xcc, else xcc on PATH."""
    with open(os.path.join(REPO, "compiler", "VERSION")) as fh:
        version = fh.read().strip()
    installed = os.path.join("/opt/xcc", version, "bin", "xcc")
    if os.access(installed, os.X_OK):
        return installed, version
    found = shutil.which("xcc")
    return (found, version) if found else (None, version)


def first_line(cmd):
    """The first line of a command's stdout, or None when it is absent or fails."""
    if not cmd:
        return None
    try:
        r = sh(cmd, shell=True)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    out = (r.stdout or "").strip().splitlines()
    return out[0].strip() if out else None


def read_first(path, key):
    try:
        with open(path) as fh:
            for line in fh:
                if line.startswith(key):
                    return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return None


def machine_info():
    """What the machine is, as far as it can be read without privileges."""
    os_name = None
    try:
        with open("/etc/os-release") as fh:
            for line in fh:
                if line.startswith("PRETTY_NAME="):
                    os_name = line.split("=", 1)[1].strip().strip('"')
    except OSError:
        os_name = platform.platform()
    cpu = read_first("/proc/cpuinfo", "model name")
    if not cpu:
        cpu = first_line("sysctl -n machdep.cpu.brand_string")
    if not cpu:
        cpu = platform.processor() or None
    cores = os.cpu_count()
    if cpu and cores:
        cpu = "%s (%d cores)" % (cpu, cores)
    mem_kb = read_first("/proc/meminfo", "MemTotal")
    memory_mb = int(mem_kb.split()[0]) // 1024 if mem_kb else None
    gpu = gpu_driver = None
    nv = first_line("nvidia-smi --query-gpu=name,driver_version --format=csv,noheader")
    if nv:
        parts = [p.strip() for p in nv.split(",")]
        gpu = parts[0]
        gpu_driver = "CUDA driver " + parts[1] if len(parts) > 1 else None
    if not gpu:
        try:
            out = sh("lspci")
        except Exception:
            out = None
        for line in ((out.stdout if out else "") or "").splitlines():
            if re.search(r"VGA|3D|Display", line, re.I):
                gpu = line.split(":", 2)[-1].strip()
                break
    return {"os": os_name, "arch": platform.machine(),
            "cpu": cpu, "gpu": gpu, "gpu_driver": gpu_driver, "memory_mb": memory_mb}


def toolchain_info():
    return {"xcc": xcc()[1],
            "clang": first_line("clang --version"),
            "clangxx": first_line("clang++ --version"),
            "gcc": first_line("g++ --version"),
            "swiftc": first_line("swiftc --version")}


def parse_two(text):
    """'<checksum> <us>' -> (checksum, us)."""
    parts = text.split()
    if len(parts) != 2:
        return None
    try:
        return parts[0], int(parts[1])
    except ValueError:
        return None


def parse_three(text):
    """'<checksum> <best_us> <first_us>' -> (checksum, best, first)."""
    parts = text.split()
    if len(parts) != 3:
        return None
    try:
        return parts[0], int(parts[1]), int(parts[2])
    except ValueError:
        return None


def measure(binary, repeats, env=None, args=("x",), parser=parse_two, label=""):
    """Run `binary` repeats times; return (samples_us, extra, checksum).

    Every run must print the same checksum, or the timing compares programs
    that compute different things and the run is refused.
    """
    e = dict(os.environ)
    if env:
        e.update(env)
    samples, extra, checksum = [], None, None
    for _ in range(repeats):
        r = sh([binary] + list(args), env=e)
        if r.returncode != 0:
            return None, None, "exit %d%s" % (r.returncode, (" (%s)" % label) if label else "")
        got = parser(r.stdout)
        if got is None:
            return None, None, "bad output %r%s" % (r.stdout.strip()[:40], (" (%s)" % label) if label else "")
        if parser is parse_three:
            c, best, first = got
            extra = first if extra is None else extra
        else:
            c, best = got
        if checksum is None:
            checksum = c
        elif c != checksum:
            return None, None, "checksum changed between repeats (%s vs %s)" % (checksum, c)
        samples.append(best)
    return samples, extra, checksum


def gpu_refusal(binary, env):
    """Why a GPU mode would run on the CPU, or None when it reaches the GPU.

    A block asked for the GPU on a machine without a usable one runs on the
    CPU and says so only under XC_PAR_REPORT, so one reported run is made
    first; the timed runs would otherwise be CPU figures recorded as GPU ones.
    """
    e = dict(os.environ)
    e.update(env)
    e["XC_PAR_REPORT"] = "1"
    r = sh([binary, "x"], env=e)
    for line in (r.stdout + r.stderr).splitlines():
        if "stays on the CPU" in line:
            return line.split("stays on the CPU:", 1)[-1].strip() or "no usable GPU"
    return None


def run_contribution(exe, opt, samples, suite, benchmark, target, device, params, arch, checksum, first=None):
    run = {"suite": suite, "benchmark": benchmark, "target": target, "device": device,
           "opt": opt, "arch": arch, "params": params,
           "samples_us": samples, "best_us": min(samples), "checksum": checksum}
    if first is not None:
        run["first_us"] = first
    return run


# ---- the par suite -------------------------------------------------------

def suite_par(compiler, work, repeats, want_gpu):
    runs = []
    for name in PAR_BENCHES:
        source = os.path.join(PAR, name + ".xc")
        if not os.path.isfile(source):
            print("  par/%s: no source, skipped" % name)
            continue
        exe = os.path.join(work, "par_" + name)
        r = sh([compiler, "-O3", "-o", exe, source])
        if r.returncode != 0:
            print("  par/%s: does not build, skipped: %s" % (name, (r.stderr or r.stdout).strip()[:80]))
            continue
        for mode, env in PAR_MODES:
            if mode in ("gpu", "vulkan") and not want_gpu:
                continue
            if mode == "vulkan" and platform.system() != "Windows":
                continue
            if mode in ("gpu", "vulkan"):
                why = gpu_refusal(exe, env)
                if why:
                    print("  par/%s/%s: skipped, the block would run on the CPU: %s" % (name, mode, why))
                    continue
            samples, first, checksum = measure(exe, repeats, env=env, parser=parse_three, label=mode)
            if samples is None:
                print("  par/%s/%s: %s" % (name, mode, checksum))
                continue
            params = {"XC_PAR": env.get("XC_PAR", ""), "opt": "O3"}
            if "XC_PAR_THREADS" in env:
                params["XC_PAR_THREADS"] = env["XC_PAR_THREADS"]
            if "XC_PAR_GPU" in env:
                params["XC_PAR_GPU"] = env["XC_PAR_GPU"]
            runs.append(run_contribution(exe, "O3", samples, "par", name, "xc", mode,
                                         params, platform.machine(), checksum, first))
            print("  par/%-12s %-8s best %7d us" % (name, mode, min(samples)))
    return runs


# ---- the language suite --------------------------------------------------

LANG_SOURCES = {"xc": ".xc", "objc": ".m", "cpp": ".cpp", "gcc": ".cpp", "swift": ".swift"}


def arch_flag():
    """The machine's whole instruction set: -mcpu=native on Apple silicon,
    -march=native on x86-64, so both match xc's default -msimd=auto."""
    return "-mcpu=native" if platform.system() == "Darwin" else "-march=native"


def lang_compile(lang, compiler, name, opt, out):
    """The command run.py uses for each language, native to this machine.

    Objective-C is Apple Foundation on macOS and libobjc2 with gnustep-base on
    Linux, the same two the project's own runs use.
    """
    src = os.path.join(SRC, name + LANG_SOURCES[lang])
    af = arch_flag()
    if lang == "xc":
        return [compiler, "-I", SRC, "-" + opt, "-o", out, src]
    if lang == "objc":
        if platform.system() == "Darwin":
            return ["clang", "-fobjc-arc", "-" + opt, "-mcpu=native", "-I", SRC,
                    "-framework", "Foundation", "-o", out, src]
        return ["clang", "-fobjc-arc", "-fobjc-runtime=gnustep-2.2", "-I/opt/gnustep/include",
                "-I", SRC, "-" + opt, af, "-L/opt/gnustep/lib", "-lobjc", "-lgnustep-base",
                "-o", out, src]
    if lang == "cpp":
        return ["clang++", "-std=c++17", "-" + opt, af, "-I", SRC, "-o", out, src]
    if lang == "gcc":
        return ["g++", "-std=c++17", "-" + opt, af, "-I", SRC, "-o", out, src]
    swift_opt = "-Onone" if opt == "O0" else "-O"
    return ["swiftc", swift_opt, "-target-cpu", "native", "-parse-as-library", "-o", out,
            os.path.join(SRC, "include", "bench_time.swift"), src]


def available_langs(compiler):
    have = {"xc": bool(compiler)}
    have["cpp"] = bool(shutil.which("clang++"))
    # macOS's g++ is Apple clang under another name: measuring it would put
    # clang's times in the GCC column, so a g++ that is clang is not GCC.
    have["gcc"] = (bool(shutil.which("g++"))
                   and "clang" not in (first_line("g++ --version") or "").lower())
    have["swift"] = bool(shutil.which("swiftc"))
    have["objc"] = bool(shutil.which("clang")) and (
        os.path.isdir("/opt/gnustep") or platform.system() == "Darwin"
        or shutil.which("gnustep-config"))
    return have


def suite_langs(compiler, work, repeats, opts):
    names = set()
    for f in os.listdir(SRC):
        stem, ext = os.path.splitext(f)
        if ext in (".xc", ".m"):
            names.add(stem)
    names = sorted(n for n in names
                   if os.path.isfile(os.path.join(SRC, n + ".xc"))
                   and os.path.isfile(os.path.join(SRC, n + ".m")))
    have = available_langs(compiler)
    if not all(have.values()):
        missing = [l for l, ok in have.items() if not ok]
        print("  languages not installed, skipped: " + ", ".join(missing))
    runs = []
    for opt in opts:
        for name in names:
            checksums = {}
            for lang, ok in have.items():
                if not ok:
                    continue
                if not os.path.isfile(os.path.join(SRC, name + LANG_SOURCES[lang])):
                    continue
                out = os.path.join(work, "%s.%s.%s" % (name, lang, opt))
                r = sh(lang_compile(lang, compiler, name, opt, out))
                if r.returncode != 0:
                    print("  %-14s %-6s %s: does not build, skipped" % (name, lang, opt))
                    continue
                samples, _, checksum = measure(out, repeats, label=lang)
                if samples is None:
                    print("  %-14s %-6s %s: %s" % (name, lang, opt, checksum))
                    continue
                checksums[lang] = checksum
                runs.append(run_contribution(out, opt, samples, "langs", name, lang, "cpu",
                                             {"lang": lang, "opt": opt, "arch": platform.machine()},
                                             platform.machine(), checksum))
                print("  %-14s %-6s %s best %7d us" % (name, lang, opt, min(samples)))
            if len(set(checksums.values())) > 1:
                print("  %-14s %s CHECKSUM MISMATCH %s" % (name, opt, checksums))
    return runs


def main():
    ap = argparse.ArgumentParser(description="measure this machine and write a contribution JSON")
    ap.add_argument("--suite", choices=["par", "langs", "both"], default="both")
    ap.add_argument("--repeats", type=int, default=5)
    ap.add_argument("--opt", default=None, help="one optimisation level (langs suite)")
    ap.add_argument("--no-gpu", action="store_true", help="skip the GPU modes (par suite)")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()

    compiler, version = xcc()
    if not compiler:
        sys.exit("diy.py: no xcc. Install one (see the downloads page) and put it on PATH, "
                 "or set XC_BENCH_XCC to a full path.")
    work = os.path.join(ROOT, "build", "diy")
    shutil.rmtree(work, ignore_errors=True)
    os.makedirs(work, exist_ok=True)

    started = time.time()
    runs = []
    print("xc %s at %s" % (version, compiler))
    if a.suite in ("par", "both"):
        print("== par suite ==")
        runs += suite_par(compiler, work, a.repeats, not a.no_gpu)
    if a.suite in ("langs", "both"):
        print("== language suite ==")
        runs += suite_langs(compiler, work, a.repeats, [a.opt] if a.opt else OPTS)

    payload = {"schema": "xc-bench/1",
               "id": str(uuid.uuid4()),
               "collected": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started)),
               "machine": machine_info(),
               "toolchains": toolchain_info(),
               "repeats": a.repeats,
               "runs": runs}
    out = a.out or os.path.join(ROOT, "xc-bench-%s.json" % platform.node())
    with open(out, "w") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
    print("\n%d runs -> %s" % (len(runs), os.path.relpath(out, REPO)))
    if not runs:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
