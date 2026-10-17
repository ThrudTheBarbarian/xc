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
integrated GPU through Vulkan) and the Windows host (x86-64, NVIDIA), and from
0.73 a browser: the wasm32 build in headless Chrome on this Mac, with WebGPU
(Metal underneath). The browser has no threads for wasm, so it runs serial,
gpu and auto; Chrome (and node 22 or later, for the DevTools driver
webgpu-run.js) must be installed. Their ssh names come from build.env
(XTC_LINUX_HOST, XTC_WIN_GPU_HOST), so none is written into the tree. A run
counts only if every mode's checksum agrees, and the Mac and the Linux host are
timed only when idle (as ../run.py does). The best of three runs is kept.

  python3 benchmark/par/run.py                  # all machines, all benchmarks
  python3 benchmark/par/run.py --bench nbody    # one benchmark
  python3 benchmark/par/run.py --machines mac   # one machine
  python3 benchmark/par/run.py --xcc compiler/bin/osx/xcc-xc   # a build-tree compiler
  python3 benchmark/par/run.py --autopar        # the same programs as plain loops, with --par-auto

--autopar measures the programs in auto/: each par benchmark with its `par`
block taken out, so its loop is a plain one. It builds each twice, as written
(one thread: there is no block) and with --par-auto, and runs the second on
all threads, on the GPU and with `auto`; the table sets those beside the
hand-written block's `auto` from this version's results.json.

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

BENCHES = ["mandelbrot", "perlin", "nbody", "saxpy", "md5", "md5_mask"]
# GPU-saturation benchmarks (from 0.8x): sized so one GPU is busy for tens of
# milliseconds, long enough that spreading the block across a second GPU pays
# off. That size makes a single CPU thread minutes per run and `auto` would
# never pick the CPU, so these run only the GPU paths — no serial/all-threads/
# all-devices — and the page keeps them in their own section.
GPU_BENCHES = ["mandel_deep"]
REPEATS = 3
XCC = None   # --xcc: a compiler other than the shipped one (development runs)

# Most benchmarks live beside this script; md5 and md5_mask are the hashcat
# workloads in apps/hashcat, so run.py builds them from there.
_HASHCAT = os.path.join(common.REPO, "apps", "hashcat")
SRC_DIRS = {"md5": _HASHCAT, "md5_mask": _HASHCAT}


AUTO_BENCHES = ["mandelbrot", "perlin", "nbody", "saxpy"]


def build_auto(name, arch, out, autopar):
    """auto/<name>.xc, as written or with --par-auto."""
    if XCC:
        cmd = [XCC, "-H", os.path.join(common.REPO, "compiler"), "-O3"]
    else:
        cmd = [common.xcc_path()] + common.xcc_home_args() + ["-O3"]
    if arch:
        cmd += ["-A", arch]
    if autopar:
        cmd += ["--par-auto"]
    cmd += ["-o", out, os.path.join(HERE, "auto", name + ".xc")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("par/run.py: auto/%s (%s) does not build:\n%s" % (name, arch or "arm64", r.stderr))


def measure_auto(runner, plain, auto, gpus):
    """As written (one run mode), then the --par-auto build on all threads,
    the GPU (where there is one) and auto; the checksums must agree."""
    out, sums = {}, set()
    runs = [("written", plain, {}), ("cpu", auto, {"XC_PAR": "cpu"})]
    if "gpu" in gpus:
        runs.append(("gpu", auto, {"XC_PAR": "gpu"}))
    runs.append(("auto", auto, {}))
    for mode, binary, env in runs:
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
        sys.exit("par/run.py: %s: the checksums differ: %s" % (plain, sorted(sums)))
    out["checksum"] = sums.pop()
    return out


def autopar(a, machines, env, work):
    results = {}
    for name in a.bench or AUTO_BENCHES:
        results[name] = {}
        if "mac" in machines:
            p, q = os.path.join(work, name + ".plain"), os.path.join(work, name + ".autopar")
            build_auto(name, None, p, False)
            build_auto(name, None, q, True)
            results[name]["mac"] = measure_auto(run_mac, p, q, ["gpu"])
        if "linux" in machines and env.get("XTC_LINUX_HOST"):
            host = env["XTC_LINUX_HOST"]
            for tag, ap_ in (("plain", False), ("autopar", True)):
                exe = os.path.join(work, "%s.%s.x86" % (name, tag))
                build_auto(name, "x86_64", exe, ap_)
                subprocess.run(["scp", "-q", exe, "%s:/tmp/par-%s-%s" % (host, tag, name)], check=True)
            results[name]["linux"] = measure_auto(lambda b, e: run_linux(host, b, e), "/tmp/par-plain-" + name,
                                                  "/tmp/par-autopar-" + name, ["gpu"])
        if "windows" in machines and env.get("XTC_WIN_GPU_HOST"):
            host = env["XTC_WIN_GPU_HOST"]
            for tag, ap_ in (("plain", False), ("autopar", True)):
                exe = os.path.join(work, "%s.%s.exe" % (name, tag))
                build_auto(name, "win64", exe, ap_)
                subprocess.run(["scp", "-q", exe, "%s:par-%s-%s.exe" % (host, tag, name)], check=True)
            results[name]["windows"] = measure_auto(lambda b, e: run_windows(host, b, e),
                                                    ".\\par-plain-%s.exe" % name, ".\\par-autopar-%s.exe" % name,
                                                    ["gpu"])
        print(name, json.dumps(results[name]), flush=True)
    outdir = os.path.join(HERE, "v" + a.version)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "autopar.json"), "w") as fh:
        json.dump(results, fh, indent=1, sort_keys=True)
    hand = {}
    hp = os.path.join(outdir, "results.json")
    if os.path.isfile(hp):
        with open(hp) as fh:
            hand = json.load(fh)
    print(table_auto(results, hand))


def table_auto(results, hand):
    names = {"mac": "Apple silicon, Metal", "linux": "x86-64 Linux, an integrated GPU through Vulkan",
             "windows": "x86-64 Windows, NVIDIA through CUDA"}
    lines = []
    for m in ("mac", "linux", "windows"):
        rows = [(n, r[m]) for n, r in results.items() if m in r]
        if not rows:
            continue
        lines.append("\n**%s** (ms, best of eight runs)\n" % names[m])
        lines.append("| benchmark | as written | --par-auto, all threads | --par-auto, GPU | --par-auto, `auto` "
                     "| hand-written `par`, `auto` |")
        lines.append("|---|---|---|---|---|---|")
        for n, r in rows:
            h = hand.get(n, {}).get(m, {}).get("auto")
            lines.append("| %s | %s | %s | %s | %s | %s |" % (n, ms(r["written"]["best_us"]), ms(r["cpu"]["best_us"]),
                                                          ms(r["gpu"]["best_us"]) if "gpu" in r else "—",
                                                          ms(r["auto"]["best_us"]), ms(h["best_us"]) if h else "—"))
    return "\n".join(lines)


def build(name, arch, out):
    if XCC:
        cmd = [XCC, "-H", os.path.join(common.REPO, "compiler"), "-O3"]
    else:
        cmd = [common.xcc_path()] + common.xcc_home_args() + ["-O3"]
    if arch:
        cmd += ["-A", arch]
    cmd += ["-o", out, os.path.join(SRC_DIRS.get(name, HERE), name + ".xc")]
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


class Browser:
    """Headless Chrome and a page server on this Mac, for the wasm32 builds:
    each run is a page that sets globalThis.xccEnv and loads the program."""
    CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    def __init__(self, work):
        import random
        import time
        self.work = work
        self.http = random.randint(20000, 29999)
        self.devtools = random.randint(30000, 39999)
        self.node = "/opt/homebrew/bin/node" if os.path.exists("/opt/homebrew/bin/node") else "node"
        self.server = subprocess.Popen([sys.executable, "-m", "http.server", str(self.http), "--bind", "127.0.0.1"],
                                       cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.chrome = subprocess.Popen([self.CHROME, "--headless=new", "--enable-unsafe-webgpu",
                                        "--remote-debugging-port=%d" % self.devtools,
                                        "--user-data-dir=" + os.path.join(work, "chrome-profile"),
                                        "--disk-cache-size=1", "about:blank"],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(4)
        self.pages = 0

    def run(self, name, env):
        common.wait_quiet()
        self.pages += 1
        page = "run_%s_%d.html" % (name, self.pages)
        sets = ", ".join('%s: "%s"' % kv for kv in env.items())
        with open(os.path.join(self.work, page), "w") as fh:
            fh.write('<!doctype html><html><body><pre id=o></pre><script>\n'
                     'globalThis.xccEnv = { %s };\n'
                     'const o = document.getElementById("o");\n'
                     'globalThis.xccOut = (s) => { o.textContent += s + "\\n"; };\n'
                     '</script><script src="%s.js"></script></body></html>\n' % (sets, name))
        r = subprocess.run([self.node, os.path.join(HERE, "webgpu-run.js"), str(self.devtools),
                            "http://127.0.0.1:%d/%s" % (self.http, page), "1"],
                           capture_output=True, text=True)
        return parse(r.stdout)

    def close(self):
        self.chrome.terminate()
        self.server.terminate()


def run_windows(host, binary, env):
    sets = "".join("$env:%s='%s'; " % kv for kv in env.items())
    r = subprocess.run(["ssh", host, "%s& '%s'" % (sets, binary)], capture_output=True, text=True)
    return parse(r.stdout.replace("\r", ""))


MODES = [("serial", {"XC_PAR": "cpu", "XC_PAR_THREADS": "1"}),
         ("cpu", {"XC_PAR": "cpu"}),
         ("gpu", {"XC_PAR": "gpu"}),
         ("gpus", {"XC_PAR": "gpus"}),      # every GPU, tiled (from 0.8)
         ("vulkan", {"XC_PAR": "gpu", "XC_PAR_GPU": "vulkan"}),
         ("all", {"XC_PAR": "all"}),        # every GPU and the CPU (from 0.8)
         ("auto", {})]


def measure(runner, binary, gpus, threads=True, multi=True, gpu_only=False):
    """Best of REPEATS for each mode (gpus: the GPU modes this machine has;
    threads false where there are none, as in a browser's wasm); the checksums
    must all agree. gpu_only drops the CPU-bound modes for a GPU-saturation
    benchmark (serial/all-threads/all-devices), leaving the GPU paths and auto."""
    out, sums = {}, set()
    for mode, env in MODES:
        if gpu_only and mode in ("serial", "cpu", "all"):
            continue
        if mode in ("gpu", "vulkan") and mode not in gpus:
            continue
        # every-GPU needs a GPU; every-device needs a GPU and the CPU threads
        # (from 0.8). On a machine with one GPU they equal "gpu" / "gpu+cpu".
        if mode == "gpus" and (not multi or "gpu" not in gpus):
            continue
        if mode == "all" and (not multi or "gpu" not in gpus or not threads):
            continue
        if mode == "cpu" and not threads:
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
    ap.add_argument("--machines", default="mac,linux,windows,browser")
    ap.add_argument("--version", default=common.COMPILER_VERSION)
    ap.add_argument("--xcc", help="measure this compiler instead of the shipped one")
    ap.add_argument("--autopar", action="store_true", help="the plain-loop programs in auto/, with --par-auto")
    a = ap.parse_args()
    global XCC
    XCC = a.xcc
    benches = a.bench or (BENCHES + GPU_BENCHES)
    machines = a.machines.split(",")
    env = common.build_env()
    work = os.path.join(HERE, "build")
    os.makedirs(work, exist_ok=True)
    if a.autopar:
        autopar(a, [m for m in machines if m != "browser"], env, work)
        return
    results = {}
    browser = None
    for name in benches:
        results[name] = {}
        gpu_only = name in GPU_BENCHES
        if "mac" in machines:
            exe = os.path.join(work, name)
            build(name, None, exe)
            results[name]["mac"] = measure(run_mac, exe, ["gpu"], gpu_only=gpu_only)
        # The GPU-saturation benchmarks target a discrete GPU kept busy for tens
        # of milliseconds; the Linux host's integrated Radeon takes seconds on
        # one, which does not fit the premise and makes the suite slow, so they
        # skip it (its CPU would be measured as "—" anyway for a GPU-only bench).
        if "linux" in machines and env.get("XTC_LINUX_HOST") and not gpu_only:
            host = env["XTC_LINUX_HOST"]
            exe = os.path.join(work, name + ".x86")
            build(name, "x86_64", exe)
            subprocess.run(["scp", "-q", exe, "%s:/tmp/par-%s" % (host, name)], check=True)
            results[name]["linux"] = measure(lambda b, e: run_linux(host, b, e), "/tmp/par-" + name,
                                             ["gpu"] if a.version >= "0.72" else [], gpu_only=gpu_only)
        if "windows" in machines and env.get("XTC_WIN_GPU_HOST"):
            host = env["XTC_WIN_GPU_HOST"]
            exe = os.path.join(work, name + ".exe")
            build(name, "win64", exe)
            subprocess.run(["scp", "-q", exe, "%s:par-%s.exe" % (host, name)], check=True)
            results[name]["windows"] = measure(lambda b, e: run_windows(host, b, e), ".\\par-%s.exe" % name,
                                               ["gpu", "vulkan"] if a.version >= "0.72" else ["gpu"], gpu_only=gpu_only)
        # The GPU-saturation blocks are a two-GPU story; the browser has one
        # WebGPU device and a long kernel there is only harness flakiness, so
        # they skip it.
        if "browser" in machines and not gpu_only and a.version >= "0.73" and os.path.exists(Browser.CHROME):
            web = os.path.join(work, "web")
            os.makedirs(web, exist_ok=True)
            build(name, "wasm32", os.path.join(web, name))
            if browser is None:
                browser = Browser(web)
            results[name]["browser"] = measure(lambda b, e: browser.run(b, e), name, ["gpu"], threads=False, multi=False)
        print(name, json.dumps(results[name]), flush=True)
    if browser:
        browser.close()
    outdir = os.path.join(HERE, "v" + a.version)
    os.makedirs(outdir, exist_ok=True)
    # A run restricted with --machines or --bench adds to the results already
    # in this version's directory instead of replacing them, so one machine
    # can be measured later without re-timing the others (the language suite's
    # run.py does the same). A full run still replaces the file.
    out_path = os.path.join(outdir, "results.json")
    if (a.bench or a.machines != "mac,linux,windows,browser") and os.path.isfile(out_path):
        with open(out_path) as fh:
            prev = json.load(fh)
        for name, by_machine in results.items():
            prev.setdefault(name, {}).update(by_machine)
        results = prev
    with open(out_path, "w") as fh:
        json.dump(results, fh, indent=1, sort_keys=True)
    print(table(results))


def ms(us):
    return "%.1f" % (us / 1000.0) if us < 100000 else "%.0f" % (us / 1000.0)


def table(results):
    """Milliseconds for the best run, per machine and mode, for the performance page."""
    names = {"mac": "Apple silicon, Metal", "linux": "x86-64 Linux, an integrated GPU through Vulkan",
             "windows": "x86-64 Windows, NVIDIA through CUDA and Vulkan",
             "browser": "Chrome on Apple silicon, wasm32 and WebGPU"}
    lines = []
    for m in ("mac", "linux", "windows", "browser"):
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
            # GPU-saturation benchmarks have no serial/all-threads figures.
            serial = ms(r["serial"]["best_us"]) if "serial" in r else "—"
            lines.append("| %s | %s | %s | %s |%s %s |" % (n, serial,
                                                       ms(r["cpu"]["best_us"]) if "cpu" in r else "—",
                                                       gpu, v, ms(r["auto"]["best_us"])))
    return "\n".join(lines)


if __name__ == "__main__":
    main()
