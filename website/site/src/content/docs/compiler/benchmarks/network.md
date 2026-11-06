---
title: "Performance: networked"
description: A par block's tiles on a GPU in another machine, served by xcd, beside the program's own devices, measured with the released xcc.
---

`xcd`, the par daemon, serves a machine's GPUs to programs on others (see
[par](/compiler/language/par/)). Here it runs on a Windows machine with an
RTX 5080, on the local network, and three machines use it: an Apple MacBook Pro
with an M3 Max, whose own GPU is fast; a Linux machine with an AMD Ryzen 9
9955HX, whose only GPU is integrated; and a Raspberry Pi 5, whose small V3D GPU
it reaches over gigabit Ethernet. Each table gives the `xcc` release it was
measured with.

Each program runs four ways: on the machine alone (`XC_PAR_REMOTE=none`), on
the remote GPU alone (`XC_PAR_WORKERS=remote`), on every GPU, the machine's
own and the remote one (`XC_PAR=gpus`), and as `auto` chooses with the remote
GPU among its choices. Each run starts from empty settings, so `auto`
measures afresh, and a remote-only figure counts only if every block ran on
the remote GPU. Every mode's checksum must agree.

**Apple M3 Max (Metal), using the remote RTX 5080** (ms; best of eight runs; measured with 0.9)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 50.3 | 638 | 336 | 49.7 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 1.2 | 2.8 | 1.5 | 1.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 5.3 | 232 | 119 | 5.6 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.1 | 695 | 212 | 1.3 |

**AMD Ryzen 9 9955HX with its integrated Radeon (Vulkan), using the remote RTX 5080** (ms; best of eight runs; measured with 0.9)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 928 | 300 | 246 | 295 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 2.5 | 836 µs | 2.8 | 972 µs |
| [`md5`](/compiler/benchmark-sources/#md5) | 9.8 | 43.6 | 32.9 | 30.9 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 2.4 | 356 | 127 | 3.3 |

**Raspberry Pi 5 with its V3D GPU (Vulkan), using the remote RTX 5080** (ms; best of eight runs; measured with 0.9.4)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 6132 | 634 | 1740 | 637 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 59.9 | 927 µs | 23.1 | 1.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 628 | 488 | 254 | 418 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 26.6 | 892 | 419 | 34.5 |


What the tables show:

- **A remote GPU pays where a block computes much from little data.**
  `mandel_deep` runs about three times faster from the Linux machine on the
  remote RTX 5080 than on its own devices, and about ten times faster from the
  Raspberry Pi; `mandelbrot` runs some sixty times faster from the Pi. `auto`
  finds the remote card in each case.
- **It does not pay where the machine's own GPU is already fast**, as on the
  M3 Max, or where a block moves more than it computes: `saxpy` crosses
  the network for every element, and on the Mac `auto` keeps it local.
- **Every GPU together is fastest only sometimes.** For `md5` on the Pi, its
  own GPU and the remote card together beat the remote card alone. More often a
  slow GPU's share holds the fast one back.
- **`auto` does not yet choose best everywhere.** For `md5` from the Linux
  machine it runs about three times slower than that machine on its own, and
  for `saxpy` about a third slower from the Linux machine and 30% slower from
  the Pi. For `md5` from the Pi it keeps the remote card alone where both GPUs
  together are faster.

## Reproducing

```
python3 benchmark/par/remote.py
python3 benchmark/page.py
```

`remote.py` starts `xcd` on the configured GPU machine and measures from this
machine and the configured Linux host; `--clients pi` measures from the
configured Raspberry Pi.
