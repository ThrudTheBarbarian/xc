---
title: "A GPU on another machine (tutorial)"
description: "Install xcd, the par daemon, on a machine with a GPU, and run a program on another machine so its par blocks use that GPU over the network: a secret, the firewall, the TLS pin, checking it worked, and finding daemons by mDNS."
slug: versions/1.0.2/tutorials/remote-gpu
banner:
  content: 'This is the documentation for xc 1.0.2. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

A [`par` block](/versions/1.0.2/compiler/language/par/) can run on a GPU in another machine. That machine
runs `xcd`, the par daemon, and serves its GPUs; your program names it and sends tiles of
its blocks there, beside its own CPU cores and GPU, or instead of them where the remote
card is faster. This tutorial sets up a daemon on one machine and runs a program from
another against it.

You need:

- **The GPU machine**: Windows or Linux with an NVIDIA card and its driver (CUDA or
  Vulkan), Linux with any Vulkan GPU, or a Mac. Nothing else is installed there: the
  daemon does not compile anything.
- **The program's machine**: a Mac, Linux, Windows or a Raspberry Pi 5, with `xcc`
  [installed](/versions/1.0.2/compiler/usage/install/).
- **The same xcc version on both.** A daemon and a program of different versions refuse
  each other, and say so.
- **A network between them** on which the program's machine can reach the daemon's port,
  7227 by default.

## 1. Install the daemon

On the GPU machine, download the `xcd` archive for its system from
[Downloads](/compiler/downloads/) and unpack it anywhere. It holds `xcd`, the TLS library
it needs (beside it in `bin/`), and `xcmon`, a monitor you can use later.

```sh
# Linux
tar xjf xcd-linux-1.0.2.tar.bz2
# macOS
tar xjf xcd-osx-1.0.2.tar.bz2
```

On Windows, unzip `xcd-win64-1.0.2.zip`.

## 2. Start it with a secret

Choose a secret: a program must know it to use this daemon. Start the daemon with it:

```sh
XC_PAR_SECRET=correct-horse-battery xcd-linux-1.0.2/bin/xcd -port 7227
```

```powershell
# Windows (PowerShell)
$env:XC_PAR_SECRET = "correct-horse-battery"
.\xcd-win64-1.0.2\bin\xcd.exe -port 7227
```

It prints a serving line naming the device it serves and its certificate's fingerprint:

```
xcd: serving cuda:NVIDIA GeForce RTX 5080 on port 7227, certificate 86210d8a…
```

The certificate is made the first time the daemon starts, under `~/.xcc/xcd` (or the
directory `XCD_HOME` names), and kept: a program remembers it, as below. A daemon started
without a secret takes any program that has none either, from any address, so use one on
any network you share.

**Open the port.** On Windows, allow it through the firewall (as an administrator):

```powershell
New-NetFirewallRule -DisplayName "xcd" -Direction Inbound -Protocol TCP -LocalPort 7227 -Action Allow
```

On Linux with a firewall, open TCP 7227 the way it is managed there (`ufw allow 7227/tcp`,
for example).

To keep the daemon running, start it as a service the usual way for the system (a
systemd unit, a launchd job, or a scheduled task at log-on), with `XC_PAR_SECRET` in its
environment.

## 3. Build a program that carries every kernel

A daemon runs your blocks' GPU kernels only, and needs the form its own GPU takes: PTX for
CUDA, SPIR-V for Vulkan, Metal Shading Language on a Mac. A program normally carries only
its own machine's form, so build it with `-fpar-kernels=all`, which puts every form in
every block.

This program iterates each pixel of a large image until it escapes: a lot of arithmetic
for very little data, which is the work a GPU across a network pays for.

```c
#import "Stdio.xc"

#define W 4096
#define H 4096

u32 counts[W * H];

i32 main(void)
{
    // Each pixel iterates until it escapes: a lot of arithmetic for very
    // little data, which is the work a GPU across a network pays for.
    for (u32 i in 0..W * H)
    {
        float cx = (float)(i % W) * 3.0 / (float)W - 2.0;
        float cy = (float)(i / W) * 3.0 / (float)H - 1.5;
        float x = 0.0;
        float y = 0.0;
        u32 n = 0;
        while (n < 2000 && x * x + y * y < 4.0)
        {
            float t = x * x - y * y + cx;
            y = 2.0 * x * y + cy;
            x = t;
            n = n + 1;
        }
        counts[i] = n;
    }
    u64 total = 0;
    for (u32 i in 0..W * H)
        total = total + (u64)counts[i];
    Stdio.printf("%llu\n", total);
    return 0;
}
```

```sh
xcc -O3 -fpar-kernels=all -o escape escape.xc
```

## 4. Run it against the daemon

On the program's machine, give the program the daemon's address and the secret, and ask
for the report so you can see what it did:

```sh
XC_PAR_SECRET=correct-horse-battery XC_PAR_REMOTE=gpu-box:7227 XC_PAR_REPORT=1 ./escape
```

The report names the daemon as a worker and the tiles it ran:

```
par: remote worker remote:gpu-box:cuda:NVIDIA GeForce RTX 5080, depth 3, …
par: escape.xc:12: 16777216 items in 9 tiles across remote:gpu-box:cuda:NVIDIA GeForce RTX 5080 (…)
```

The first run measures: it times the block on this machine's devices, on the remote GPU,
and on both together, and keeps the fastest for every later run (see
[Which device](/versions/1.0.2/compiler/language/par/#which-device)). `XC_PAR=gpus` uses every GPU, local
and remote, without measuring; `XC_PAR_WORKERS=remote` uses the remote GPU alone.

The first time a program speaks to a daemon it keeps the daemon's certificate fingerprint,
in its settings under `tls.pin.gpu-box:7227`, and later refuses a daemon that shows a
different one. If you reinstall the daemon, its certificate changes and the program says
which pin to remove.

The program loads the TLS library only when it first speaks to a daemon: from the file
`XC_TLS_LIB` names, beside the program, or from the installed toolchain. A program copied
to a machine without the toolchain needs the library beside it (the one in the `xcd`
archive will do). Without it the daemon is reported unreachable and the program runs on
its own devices.

## 5. Find daemons without naming them

On one subnet, daemons advertise themselves (multicast DNS). Give daemons a pool name, and
programs the same, and they find each other:

```sh
# on each GPU machine
XC_PAR_SECRET=… xcd -pool render

# where the program runs
XC_PAR_SECRET=… XC_PAR_POOL=render ./escape
```

A program looks for daemons only when told to, by `XC_PAR_POOL` or `XC_PAR_REMOTE=mdns`;
it takes those of its pool and its own xcc version. Multicast does not cross routers or
VPNs: across those, name the daemons in `XC_PAR_REMOTE`, a comma-separated list.

## 6. Watch it

`xcmon`, in the same archive, shows the daemons on the subnet and the programs that send
it their runs, in a browser page:

```sh
xcmon                                     # page at http://localhost:7480/
XC_PAR_TRACE=monitor-host:7482 ./escape   # this program's runs appear on it
```

## When it does not connect

| Symptom | What to do |
|---|---|
| cannot connect to `gpu-box:7227` | The daemon is not running, the address is wrong, or a firewall drops the port. |
| the daemon refused the secret | The program's `XC_PAR_SECRET` differs from the daemon's. |
| a different xcc version | Install the same release on both machines. |
| a different data layout | The two machines differ in byte order or pointer width, and cannot share arrays. |
| the certificate changed | The daemon was reinstalled or is not the one you pinned: remove the pin it names if you expect the change. |
| the daemon has no form for its GPU | Build the program with `-fpar-kernels=all`. |

A daemon also declines work when its GPU's free memory cannot hold a block's data, and
inside the hours `xcd -nimby 09:00-17:00` keeps for its owner; the program then runs those
blocks on its own devices, with the same answer. Everything the daemon offers is described
in [Across machines](/versions/1.0.2/compiler/language/par/#across-machines-xcd), and the figures from
real machines are on [Performance: networked](/compiler/benchmarks/network/).
