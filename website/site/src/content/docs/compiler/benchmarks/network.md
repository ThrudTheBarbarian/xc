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

Each program runs five ways: on the machine alone (`XC_PAR_REMOTE=none`), on
the remote GPU alone (`XC_PAR_WORKERS=remote`), on every GPU, the machine's
own and the remote one (`XC_PAR=gpus`), and twice as `auto` chooses with the
remote GPU among its choices. **`auto`, first run** starts from empty
settings, so the program spends its runs measuring each candidate, and its
best is the best run while it measures. **`auto`, once learned** is a later
run of the program, after one run has measured and kept its choice: what a
program settles on. A remote-only figure counts only if every block ran on
the remote GPU. Every mode's checksum must agree.

## From an Apple M4 Max

Apple M4 Max (Metal), using the remote RTX 5080 (ms; best of eight runs; measured with 0.9.6)

| benchmark | this machine | the remote GPU | every GPU | `auto`, first run | `auto`, once learned |
|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 34.9 | 217 | 103 | 34.4 | 34.6 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 1.9 | 1.1 | 2.1 | 2.1 | 1.5 |
| [`md5`](/compiler/benchmark-sources/#md5) | 6.4 | 201 | 105 | 4.6 | 7.6 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 495 µs | 242 | 96.5 | 850 µs | 503 µs |

## From an AMD Ryzen 9 9955HX

AMD Ryzen 9 9955HX with its integrated Radeon (Vulkan), using the remote RTX 5080 (ms; best of eight runs; measured with 0.9.6)

| benchmark | this machine | the remote GPU | every GPU | `auto`, first run | `auto`, once learned |
|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 348 | 293 | 238 | 288 | 228 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 2.8 | 830 µs | 2.9 | 1.1 | 872 µs |
| [`md5`](/compiler/benchmark-sources/#md5) | 10.7 | 44.2 | 33.5 | 9.6 | 9.3 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 2.6 | 343 | 119 | 3.1 | 2.2 |

## From a Raspberry Pi 5

Raspberry Pi 5 with its V3D GPU (Vulkan), using the remote RTX 5080 (ms; best of eight runs; measured with 0.9.6)

| benchmark | this machine | the remote GPU | every GPU | `auto`, first run | `auto`, once learned |
|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 6237 | 635 | 1740 | 636 | 636 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 70.1 | 1.0 | 23.5 | 1.5 | 1.0 |
| [`md5`](/compiler/benchmark-sources/#md5) | 632 | 488 | 255 | 419 | 388 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 26.1 | 890 | 424 | 34.6 | 26.6 |


## What the tables show

- **A remote GPU pays where a block computes much from little data.** From
  the Raspberry Pi, `mandel_deep` runs about ten times faster on the remote RTX
  5080 than on the Pi's own CPU and GPU, and `mandelbrot` some sixty times
  faster. From the Linux machine, `mandelbrot` runs three times faster on the
  remote card, and `mandel_deep` half as fast again on its own GPU and the
  remote card together.
- **It does not pay where the machine's own GPU is already fast**, as on the
  M4 Max, or where a block moves more than it computes: `saxpy` crosses
  the network for every element.
- **Every GPU together is fastest only sometimes.** For `md5` from the Pi, its
  own GPU and the remote card together take half the remote card's time
  alone, and for `mandel_deep` from the Linux machine a fifth less. More often
  a slow GPU's share holds the fast one back.
- **`auto` settles on the best choice.** Once learned, `auto` is as fast as
  the best of the other columns, or within a few percent of it, on the
  M4 Max, on the Linux machine, and on the Pi for all but `md5`, where
  it takes 319 ms against 254 ms for both GPUs together. Its first run is
  slower where it has several candidates to measure, the remote GPU among
  them: it runs each twice, and keeps the fastest for every run after.

## Reproducing

```
python3 benchmark/par/remote.py
python3 benchmark/page.py
```

`remote.py` starts `xcd` on the configured GPU machine and measures from this
machine and the configured Linux host; `--clients pi` measures from the
configured Raspberry Pi.
