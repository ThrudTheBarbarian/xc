---
title: "Performance: networked"
description: A par block's tiles on a GPU in another machine, served by xcd, beside the program's own devices, measured with the released xcc.
---

`xcd`, the par daemon, serves a machine's GPUs to programs on others (see
[par](/compiler/language/par/)). Here it runs on a Windows machine with an
RTX 5080, on the local network, and two machines use it: an Apple MacBook Pro
with an M4 Max, whose own GPU is fast, and a Linux machine with an AMD Ryzen 9
9955HX, whose only GPU is integrated. Each figure is measured with the
released 0.86 `xcc`.

Each program runs four ways: on the machine alone (`XC_PAR_REMOTE=none`), on
the remote GPU alone (`XC_PAR_WORKERS=remote`), on every GPU, the machine's
own and the remote one (`XC_PAR=gpus`), and as `auto` chooses with the remote
GPU among its choices. Each run starts from empty settings, so `auto`
measures afresh, and a remote-only figure counts only if every block ran on
the remote GPU. Every mode's checksum must agree.

**Apple M4 Max (Metal), using the remote RTX 5080** (ms; best of eight runs)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 44.0 | 238 | 112 | 44.1 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 2.1 | 2.0 | 1.8 | 1.8 |
| [`md5`](/compiler/benchmark-sources/#md5) | 5.8 | 203 | 105 | 6.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 502 µs | 273 | 120 | 901 µs |

**AMD Ryzen 9 9955HX with its integrated Radeon (Vulkan), using the remote RTX 5080** (ms; best of eight runs)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 942 | 309 | 251 | 302 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 2.6 | 654 µs | 2.9 | 792 µs |
| [`md5`](/compiler/benchmark-sources/#md5) | 16.0 | 71.4 | 52.5 | 48.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 2.9 | 372 | 136 | 3.7 |


What the tables show:

- **A remote GPU pays where a block computes much from little data.** The
  hashcat MD5 workload sends almost nothing and hashes 64 million candidates:
  from the Linux machine it runs on the remote RTX 5080 many times faster than
  on its own devices, and `auto` picks the remote card.
- **It does not pay where the machine's own GPU is already fast**, as on the
  M4 Max, or where a block moves more than it computes (`saxpy`): `auto` keeps
  those local.
- **Every GPU together is not always faster.** Beside a remote card many times
  faster, a slow integrated GPU's share holds the fast one back; `auto`
  measures the remote card alone too and keeps whichever is fastest.

## Reproducing

```
python3 benchmark/par/remote.py
python3 benchmark/page.py
```

`remote.py` starts `xcd` on the configured GPU machine and measures from this
machine and the configured Linux host.
