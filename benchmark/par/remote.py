#!/usr/bin/env python3
"""benchmark/par/remote.py — a GPU on another machine (xcd) as a par worker.

Starts `xcd`, the par worker daemon, on the Windows host (XTC_WIN_GPU_HOST in
build.env: its NVIDIA cards through CUDA), then runs benchmarks on this Mac
and on the Linux host (XTC_LINUX_HOST), each four ways:

  local    the machine on its own (XC_PAR_REMOTE=none), as `auto` chooses
  remote   the other machine's GPU alone (XC_PAR_WORKERS=remote)
  all      every GPU, the machine's own and the remote one (XC_PAR=gpus)
  auto     `auto`, with the remote one among the sets it measures

Each program is built with -fpar-kernels=all, so the daemon has a kernel form
its GPU takes (PTX for CUDA), and each run starts from empty par settings, so
`auto` measures afresh and pins the daemon's certificate anew. The programs
are the par benchmarks: two that compute much from little data (md5,
mandel_deep), one in between (mandelbrot) and one that moves eight bytes for
every multiply-add (saxpy), where the network costs more than the GPU saves.

The machines are timed only when idle (../run.py's load check), and every
mode's checksum must agree. Writes benchmark/par/v<version>/remote.json and
prints the tables for the performance page.

  python3 benchmark/par/remote.py
  python3 benchmark/par/remote.py --clients mac --bench md5
  python3 benchmark/par/remote.py --xcc compiler/bin/osx/xcc-xc
"""
import argparse
import json
import os
import random
import secrets
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import run as common  # noqa: E402

BENCHES = ["md5", "mandel_deep", "mandelbrot", "saxpy"]
_HASHCAT = os.path.join(common.REPO, "apps", "hashcat")
SRC_DIRS = {"md5": _HASHCAT, "md5_mask": _HASHCAT}
REPEATS = 3
XCC = None


def xcc_cmd():
    if XCC:
        return [XCC, "-H", os.path.join(common.REPO, "compiler")]
    return [common.xcc_path()] + common.xcc_home_args()


def build(src, arch, out, extra=()):
    cmd = xcc_cmd() + ["-O3"] + (["-A", arch] if arch else []) + list(extra) + ["-o", out, src]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("par/remote.py: %s (%s) does not build:\n%s" % (src, arch or "host", r.stderr))


def parse(out):
    parts = out.split()
    if len(parts) != 3:
        return None
    return parts[0], int(parts[1]), int(parts[2])


def ssh_hostname(alias):
    """What an ssh alias resolves to, for programs that cannot read ssh's config."""
    r = subprocess.run(["ssh", "-G", alias], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("hostname "):
            return line.split()[1]
    return alias


class Daemon:
    """xcd on the Windows host, on a port of its own, with a fresh secret."""

    def __init__(self, host, work):
        self.host = host
        self.port = random.randint(47300, 47900)
        self.secret = secrets.token_hex(16)
        exe = os.path.join(work, "xcd.exe")
        build(os.path.join(common.REPO, "compiler", "selfhost", "tools", "xcd.xc"), "win64", exe)
        tls = "/opt/xcc/3p/tls/win64/libtls.dll"
        subprocess.run(["ssh", host, "New-Item -ItemType Directory -Force xcdbench | Out-Null"], check=True)
        subprocess.run(["scp", "-q", exe, tls, "%s:xcdbench/" % host], check=True)
        cmd = ("cd xcdbench; $env:XC_PAR_SECRET='%s'; $env:XC_TLS_LIB=\"$PWD\\libtls.dll\"; "
               "$env:XCD_HOME=\"$PWD\\home\"; .\\xcd.exe -port %d -no-mdns" % (self.secret, self.port))
        self.proc = subprocess.Popen(["ssh", host, cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        deadline = time.time() + 60
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                break
            if "xcd: serving" in line:
                print("  " + line.strip(), flush=True)
                return
        sys.exit("par/remote.py: xcd did not start on %s" % host)

    def close(self):
        self.proc.terminate()
        # The ssh session going does not always end the daemon on Windows.
        subprocess.run(["ssh", self.host, "Stop-Process -Name xcd -ErrorAction SilentlyContinue"],
                       capture_output=True)


MODES = [("local", {"XC_PAR_REMOTE": "none"}),
         ("remote", {"XC_PAR_WORKERS": "remote"}),
         ("all", {"XC_PAR": "gpus"}),
         ("auto", {})]


def measure(runner, binary, remote_env):
    out, sums = {}, set()
    for mode, env in MODES:
        e = dict(env)
        if mode != "local":
            e.update(remote_env)
        best = None
        for _ in range(REPEATS):
            got = runner(binary, e)
            if got is None:
                sys.exit("par/remote.py: %s (%s) printed nothing usable" % (binary, mode))
            sums.add(got[0])
            if best is None or got[1] < best["best_us"]:
                best = {"best_us": got[1], "first_us": got[2]}
        out[mode] = best
    if len(sums) != 1:
        sys.exit("par/remote.py: %s: the checksums differ between modes: %s" % (binary, sorted(sums)))
    out["checksum"] = sums.pop()
    return out


def run_mac(binary, env):
    common.wait_quiet()
    e = dict(os.environ)
    e.update(env)
    e["XCC_SETTINGS_DIR"] = fresh_settings()
    r = subprocess.run([binary], capture_output=True, text=True, env=e)
    return parse(r.stdout)


_settings_n = [0]


def fresh_settings():
    _settings_n[0] += 1
    d = os.path.join(HERE, "build", "remote-settings", str(_settings_n[0]))
    os.makedirs(d, exist_ok=True)
    return d


def run_linux(host, binary, env):
    common.wait_quiet(host)
    _settings_n[0] += 1
    pre = " ".join("%s=%s" % kv for kv in env.items())
    pre += " XCC_SETTINGS_DIR=/tmp/par-remote-settings-%d" % _settings_n[0]
    pre += " XC_TLS_LIB=$HOME/ci/3p/tls/x86_64/libtls.so"
    r = subprocess.run(["ssh", host, "%s %s" % (pre, binary)], capture_output=True, text=True)
    return parse(r.stdout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bench", action="append")
    ap.add_argument("--clients", default="mac,linux")
    ap.add_argument("--version", default=common.COMPILER_VERSION)
    ap.add_argument("--xcc", help="measure this compiler instead of the shipped one")
    a = ap.parse_args()
    global XCC
    XCC = a.xcc
    env = common.build_env()
    gpu_host = env.get("XTC_WIN_GPU_HOST")
    if not gpu_host:
        sys.exit("par/remote.py: no XTC_WIN_GPU_HOST in build.env (the machine whose GPU is served)")
    work = os.path.join(HERE, "build")
    os.makedirs(work, exist_ok=True)
    daemon = Daemon(gpu_host, work)
    remote_env = {"XC_PAR_REMOTE": "%s:%d" % (ssh_hostname(gpu_host), daemon.port), "XC_PAR_SECRET": daemon.secret}
    clients = a.clients.split(",")
    results = {}
    try:
        for name in a.bench or BENCHES:
            src = os.path.join(SRC_DIRS.get(name, HERE), name + ".xc")
            results[name] = {}
            if "mac" in clients:
                exe = os.path.join(work, name + ".remote")
                build(src, None, exe, ["-fpar-kernels=all"])
                results[name]["mac"] = measure(run_mac, exe, remote_env)
            if "linux" in clients and env.get("XTC_LINUX_HOST"):
                host = env["XTC_LINUX_HOST"]
                exe = os.path.join(work, name + ".remote.x86")
                build(src, "x86_64", exe, ["-fpar-kernels=all"])
                subprocess.run(["scp", "-q", exe, "%s:/tmp/par-remote-%s" % (host, name)], check=True)
                results[name]["linux"] = measure(lambda b, e: run_linux(host, b, e), "/tmp/par-remote-" + name,
                                                 remote_env)
            print(name, json.dumps(results[name]), flush=True)
    finally:
        daemon.close()
    outdir = os.path.join(HERE, "v" + a.version)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "remote.json"), "w") as fh:
        json.dump(results, fh, indent=1, sort_keys=True)
    print(table(results))


def ms(us):
    return "%.1f" % (us / 1000.0) if us < 100000 else "%.0f" % (us / 1000.0)


def table(results):
    names = {"mac": "Apple M4 Max (Metal) using the Windows host's RTX 5080 over the network",
             "linux": "Ryzen 9 9955HX with its integrated Radeon (Vulkan) using the Windows host's RTX 5080"}
    lines = []
    for m in ("mac", "linux"):
        rows = [(n, r[m]) for n, r in results.items() if m in r]
        if not rows:
            continue
        lines.append("\n**%s** (ms, best of eight runs)\n" % names[m])
        lines.append("| benchmark | this machine | the remote GPU | every GPU | `auto` |")
        lines.append("|---|---|---|---|---|")
        for n, r in rows:
            lines.append("| %s | %s | %s | %s | %s |" % (n, ms(r["local"]["best_us"]), ms(r["remote"]["best_us"]),
                                                    ms(r["all"]["best_us"]), ms(r["auto"]["best_us"])))
    return "\n".join(lines)


if __name__ == "__main__":
    main()
