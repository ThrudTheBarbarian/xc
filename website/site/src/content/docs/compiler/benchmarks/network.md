---
title: "Performance: networked"
description: A par block's tiles on a GPU in another machine, served by xcd, beside the program's own devices, measured with the released xcc.
---

`xcd`, the par daemon, serves a machine's GPUs to programs on others (see
[par](/compiler/language/par/)). Here it runs on a Windows machine with an
RTX 5080, on the local network, and three machines use it: an Apple MacBook Pro
with an M4 Max, whose own GPU is fast; a Linux machine with an AMD Ryzen 9
9955HX, whose only GPU is integrated; and a Raspberry Pi 5, whose small V3D GPU
it reaches over gigabit Ethernet. Each table gives the `xcc` release it was
measured with.

Each program runs four ways: on the machine alone (`XC_PAR_REMOTE=none`), on
the remote GPU alone (`XC_PAR_WORKERS=remote`), on every GPU, the machine's
own and the remote one (`XC_PAR=gpus`), and as `auto` chooses with the remote
GPU among its choices. Each run starts from empty settings, so `auto`
measures afresh, and a remote-only figure counts only if every block ran on
the remote GPU. Every mode's checksum must agree.

**Apple M4 Max (Metal), using the remote RTX 5080** (ms; best of eight runs; measured with 0.9.5)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 43.9 | 221 | 97.2 | 44.7 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 1.9 | 2.0 | 1.9 | 1.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 6.2 | 202 | 115 | 10.1 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 496 µs | 242 | 96.9 | 892 µs |

**AMD Ryzen 9 9955HX with its integrated Radeon (Vulkan), using the remote RTX 5080** (ms; best of eight runs; measured with 0.9.5)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 348 | 293 | 239 | 289 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 2.8 | 812 µs | 2.9 | 956 µs |
| [`md5`](/compiler/benchmark-sources/#md5) | 9.6 | 44.0 | 32.9 | 9.5 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 2.6 | 342 | 119 | 2.9 |

**Raspberry Pi 5 with its V3D GPU (Vulkan), using the remote RTX 5080** (ms; best of eight runs; measured with 0.9.5)

| benchmark | this machine | the remote GPU | every GPU | `auto` |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 6129 | 634 | 1740 | 637 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 62.2 | 1.0 | 23.1 | 1.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 624 | 488 | 254 | 417 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 25.3 | 890 | 437 | 34.4 |


What the tables show:

- **A remote GPU pays where a block computes much from little data.** From
  the Raspberry Pi, `mandel_deep` runs about ten times faster on the remote RTX
  5080 than on the Pi's own CPU and GPU, and `mandelbrot` some sixty times
  faster. From the Linux machine, `mandelbrot` runs three and a half times
  faster on the remote card, and `mandel_deep`, which its own sixteen cores
  run well, a fifth faster. `auto` finds the remote card in each case.
- **It does not pay where the machine's own GPU is already fast**, as on the
  M4 Max, or where a block moves more than it computes: `saxpy` crosses
  the network for every element, and on every machine `auto` keeps it local.
- **Every GPU together is fastest only sometimes.** For `md5` from the Pi,
  its own GPU and the remote card together take half the remote card's time
  alone, and for `mandel_deep` from the Linux machine a fifth less. More often
  a slow GPU's share holds the fast one back.
- **`auto` does not yet choose best everywhere.** For `md5` from the Pi and
  `mandel_deep` from the Linux machine it keeps the remote card alone where
  every GPU together is faster. For `md5` on the M4 Max it runs 1.6
  times slower than the Mac alone, and for `saxpy` 36% slower than the Pi alone
  and 12% slower than the Linux machine alone.

## Reproducing

```
python3 benchmark/par/remote.py
python3 benchmark/page.py
```

`remote.py` starts `xcd` on the configured GPU machine and measures from this
machine and the configured Linux host; `--clients pi` measures from the
configured Raspberry Pi.
