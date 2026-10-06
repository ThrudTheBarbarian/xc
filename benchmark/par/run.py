#!/usr/bin/env python3
"""benchmark/par/run.py — time the par benchmarks on each machine and device.

Each benchmark in this directory prints "<checksum> <best_us> <first_us>": it
runs its par block eight times and reports the best run and the first (which
carries one-off costs, such as building the GPU version). This script builds
each one with the shipped xcc and runs it four ways on each machine:

  serial   one CPU thread (XC_PAR=cpu XC_PAR_THREADS=1)
  cpu      every CPU thread (XC_PAR=cpu)
  gpu      the GPU (XC_PAR=gpu), where the machine has one
  vulkan   the same GPU through Vulkan, on Windows (from 0.72; gpu is CUDA there)
  auto     the default: the block picks its device by measuring

Machines: this Mac (arm64, Metal), the Linux host (x86-64; from 0.72 its
integrated GPU through Vulkan) and the Windows host (x86-64, NVIDIA). Their ssh names come from build.env
(XTC_LINUX_HOST, XTC_WIN_GPU_HOST), so none is written into the tree. A run
counts only if every mode's checksum agrees, and the Mac and the Linux host are
timed only when idle (as ../run.py does). The best of three runs is kept.

  python3 benchmark/par/run.py                  # all machines, all benchmarks
  python3 benchmark/par/run.py --bench nbody    # one benchmark
  python3 benchmark/par/run.py --machines mac   # one machine
  python3 benchmark/par/run.py --xcc compiler/bin/osx/xcc-xc   # a build-tree compiler

Writes benchmark/par/<version>/results.json and prints the markdown table the
performance page uses.
"""
import argparse
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import run as common  # noqa: E402  (../run.py: load waiting, build.env, the shipped xcc)

BENCHES = ["mandelbrot", "perlin", "nbody", "saxpy"]
REPEATS = 3
XCC = None   # --xcc: a compiler other than the shipped one (development runs)


def build(name, arch, out):
    if XCC:
        cmd = [XCC, "-H", os.path.join(common.REPO, "compiler"), "-O3"]
    else:
        cmd = [common.xcc_path()] + common.xcc_home_args() + ["-O3"]
    if arch:
        cmd += ["-A", arch]
    cmd += ["-o", out, os.path.join(HERE, name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("par/run.py: %s (%s) does not build:\n%s" % (name, arch or "arm64", r.stderr))


def parse(out):
    parts = out.split()
    if len(parts) != 3:
        return None
    return parts[0], int(parts[1]), int(parts[2])


def run_mac(binary, env):
    common.wait_quiet()
    e = dict(os.environ)
    e.update(env)
    r = subprocess.run([binary], capture_output=True, text=True, env=e)
    return parse(r.stdout)


def run_linux(host, binary, env):
    common.wait_quiet(host)
    pre = " ".join("%s=%s" % kv for kv in env.items())
    r = subprocess.run(["ssh", host, "%s %s" % (pre, binary)], capture_output=True, text=True)
    return parse(r.stdout)


def run_windows(host, binary, env):
    sets = "".join("$env:%s='%s'; " % kv for kv in env.items())
    r = subprocess.run(["ssh", host, "%s& '%s'" % (sets, binary)], capture_output=True, text=True)
    return parse(r.stdout.replace("\r", ""))


MODES = [("serial", {"XC_PAR": "cpu", "XC_PAR_THREADS": "1"}),
         ("cpu", {"XC_PAR": "cpu"}),
         ("gpu", {"XC_PAR": "gpu"}),
         ("vulkan", {"XC_PAR": "gpu", "XC_PAR_GPU": "vulkan"}),
         ("auto", {})]


def measure(runner, binary, gpus):
    """Best of REPEATS for each mode (gpus: the GPU modes this machine has);
    the checksums must all agree."""
    out, sums = {}, set()
    for mode, env in MODES:
        if mode in ("gpu", "vulkan") and mode not in gpus:
            continue
        best = None
        for _ in range(REPEATS):
            got = runner(binary, env)
            if got is None:
                sys.exit("par/run.py: %s (%s) printed nothing usable" % (binary, mode))
            sums.add(got[0])
            if best is None or got[1] < best["best_us"]:
                best = {"best_us": got[1], "first_us": got[2]}
        out[mode] = best
    if len(sums) != 1:
        sys.exit("par/run.py: %s: the checksums differ between modes: %s" % (binary, sorted(sums)))
    out["checksum"] = sums.pop()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", action="append")
    ap.add_argument("--machines", default="mac,linux,windows")
    ap.add_argument("--version", default=common.COMPILER_VERSION)
    ap.add_argument("--xcc", help="measure this compiler instead of the shipped one")
    a = ap.parse_args()
    global XCC
    XCC = a.xcc
    benches = a.bench or BENCHES
    machines = a.machines.split(",")
    env = common.build_env()
    work = os.path.join(HERE, "build")
    os.makedirs(work, exist_ok=True)
    results = {}
    for name in benches:
        results[name] = {}
        if "mac" in machines:
            exe = os.path.join(work, name)
            build(name, None, exe)
            results[name]["mac"] = measure(run_mac, exe, ["gpu"])
        if "linux" in machines and env.get("XTC_LINUX_HOST"):
            host = env["XTC_LINUX_HOST"]
            exe = os.path.join(work, name + ".x86")
            build(name, "x86_64", exe)
            subprocess.run(["scp", "-q", exe, "%s:/tmp/par-%s" % (host, name)], check=True)
            results[name]["linux"] = measure(lambda b, e: run_linux(host, b, e), "/tmp/par-" + name,
                                             ["gpu"] if a.version >= "0.72" else [])
        if "windows" in machines and env.get("XTC_WIN_GPU_HOST"):
            host = env["XTC_WIN_GPU_HOST"]
            exe = os.path.join(work, name + ".exe")
            build(name, "win64", exe)
            subprocess.run(["scp", "-q", exe, "%s:par-%s.exe" % (host, name)], check=True)
            results[name]["windows"] = measure(lambda b, e: run_windows(host, b, e), ".\\par-%s.exe" % name,
                                               ["gpu", "vulkan"] if a.version >= "0.72" else ["gpu"])
        print(name, json.dumps(results[name]), flush=True)
    outdir = os.path.join(HERE, "v" + a.version)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "results.json"), "w") as fh:
        json.dump(results, fh, indent=1, sort_keys=True)
    print(table(results))


def ms(us):
    return "%.1f" % (us / 1000.0) if us < 100000 else "%.0f" % (us / 1000.0)


def table(results):
    """Milliseconds for the best run, per machine and mode, for the performance page."""
    names = {"mac": "Apple silicon, Metal", "linux": "x86-64 Linux, an integrated GPU through Vulkan",
             "windows": "x86-64 Windows, NVIDIA through CUDA and Vulkan"}
    lines = []
    for m in ("mac", "linux", "windows"):
        rows = [(n, r[m]) for n, r in results.items() if m in r]
        if not rows:
            continue
        lines.append("\n**%s** (ms, best of eight runs)\n" % names[m])
        vk = any("vulkan" in r for _, r in rows)
        lines.append("| benchmark | one thread | all threads | GPU |%s auto |" % (" Vulkan |" if vk else ""))
        lines.append("|---|---|---|---|%s---|" % ("---|" if vk else ""))
        for n, r in rows:
            gpu = ms(r["gpu"]["best_us"]) if "gpu" in r else "—"
            v = (" %s |" % ms(r["vulkan"]["best_us"])) if vk else ""
            lines.append("| %s | %s | %s | %s |%s %s |" % (n, ms(r["serial"]["best_us"]), ms(r["cpu"]["best_us"]),
                                                       gpu, v, ms(r["auto"]["best_us"])))
    return "\n".join(lines)


if __name__ == "__main__":
    main()
