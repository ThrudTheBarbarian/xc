---
title: "Performance: GPU"
description: How xc's par blocks run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, and what --par-auto makes of plain loops, measured with the released xcc.
---

Each figure is measured with the released 0.9 `xcc`, on an Apple
MacBook Pro with an M3 Max (Metal), a Linux machine with an AMD Ryzen 9
9955HX and its integrated Radeon (Vulkan), and a Windows machine with an RTX
5080 and an RTX 3090 (CUDA and Vulkan). How the CPU code compares with other
compilers is on [Performance: CPU](/compiler/performance/); GPUs on other
machines are on [Performance: networked](/compiler/benchmarks/network/).

## Parallel blocks

A [`par` block](/compiler/language/par/) runs a loop's iterations at once,
across every CPU thread, on the GPU, or across several devices at once: the
block is cut into tiles handed to every GPU the machine
has, and to the CPU, together. The GPU is reached through:

- **Metal** on Apple silicon;
- **CUDA** on an NVIDIA GPU under Windows;
- **Vulkan** on Linux, Windows and Android;
- **WebGPU** in a browser.

Six programs in `benchmark/par` measure it:

- `mandelbrot`: a 2048×2048 escape-time image, at most 256 iterations a pixel;
- `perlin`: 2048×2048 improved noise, four octaves;
- `nbody`: the force on each of 8192 bodies from all the others;
- `saxpy`: `y = a·x + y` over 16 million integers, with a sum;
- `md5`, `md5_mask`: the hashcat MD5 workload, hashing 64 million candidates
  through the full 64-round compression and summing the digests.

Each runs its block eight times and reports the best run. The single-device
modes are *one thread* (`XC_PAR=cpu XC_PAR_THREADS=1`), *all threads*
(`XC_PAR=cpu`) and *GPU* (`XC_PAR=gpu`). A block can also run on *every
GPU* (`XC_PAR=gpus`) or on *every device* (`XC_PAR=all`), and `XC_PAR_WORKERS=…`
names an exact set (`cuda`, `vulkan`, `metal`, `cpu`). `auto`, the default,
times the sets the machine can form and keeps the fastest; it
remembers the choice, per program and per machine, so later runs do not measure
again. Every mode's checksum must agree. On Windows *GPU* is CUDA and *Vulkan*
the same work through Vulkan (`XC_PAR_GPU=vulkan`).

**Apple MacBook Pro, M3 Max, a 40-core GPU (12 performance and 4 efficiency cores), its GPU through Metal** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 164 | 13.5 | 1.0 | 990 µs | 873 µs | 12.9× faster | 36.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1349 | 108 | 4.9 | 5.5 | 4.9 | 22× faster | 40.7 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 1064 | 85.1 | 4.1 | 4.2 | 4.1 | 21× faster | 35.7 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 14.5 | 1.5 | 478 µs | 948 µs | 654 µs | 3.1× faster | 21.1 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 87.3 | 7.8 | 1.2 | 797 µs | 1.2 | 6.4× faster | 24.4 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.4 | 1.1 | 3.9 | 4.6 | 1.1 | 3.6× slower | 26.4 |

**AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 55.9 | 2.5 | 9.4 | 9.5 | 3.4 | 3.8× slower | 27.8 |
| [`md5`](/compiler/benchmark-sources/#md5) | 228 | 14.0 | 107 | 110 | 9.8 | 7.6× slower | 135 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 188 | 8.9 | 88.7 | 87.4 | 9.0 | 9.9× slower | 115 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 7.4 | 964 µs | 3.5 | 3.6 | 540 µs | 3.6× slower | 24.6 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 80.3 | 5.7 | 5.4 | 5.5 | 3.9 | 1.06× faster | 27.0 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.4 | 2.4 | 9.6 | 3.0 | 2.4 | 4.1× slower | 35.2 |

**Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 95.3 | 8.5 | 215 µs | 268 µs | 224 µs | 216 µs | 39× faster | 123 | 110 |
| [`md5`](/compiler/benchmark-sources/#md5) | 766 | 72.0 | 1.5 | 2.7 | 1.7 | 1.5 | 49× faster | 212 | 111 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 622 | 60.1 | 1.2 | 2.2 | 1.3 | 1.2 | 49× faster | 208 | 114 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.5 | 3.4 | 372 µs | 417 µs | 383 µs | 372 µs | 9.2× faster | 210 | 110 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 106 | 10.4 | 367 µs | 1.1 | 374 µs | 363 µs | 28× faster | 211 | 108 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.3 | 2.4 | 6.3 | 25.6 | 3.7 | 2.5 | 2.6× slower | 142 | 145 |

**Raspberry Pi 5 (four Cortex-A76 cores at 2.4 GHz), Raspberry Pi OS, its VideoCore VII GPU (V3D 7.1) through Vulkan (from 0.89)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 52528 | 13990 | 22853 | 19156 | 9389 | 1.63× slower | 22923 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 340 | 90.5 | 204 | 205 | 90.5 | 2.3× slower | 248 |
| [`md5`](/compiler/benchmark-sources/#md5) | 2860 | 715 | 660 | 1165 | 623 | 1.08× faster | 703 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2346 | 587 | 495 | 496 | 336 | 1.18× faster | 536 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 93.4 | 23.4 | 111 | 111 | 23.4 | 4.7× slower | 152 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 401 | 100 | 119 | 118 | 74.4 | 1.19× slower | 164 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 26.1 | 30.9 | 131 | 104 | 31.0 | 4.2× slower | 202 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 84.1 | 4.3 | 145 µs | 161 µs | 275 µs | 161 µs | 145 µs | 29× faster | 116 | 155 |
| [`md5`](/compiler/benchmark-sources/#md5) | 818 | 40.1 | 882 µs | 702 µs | 1.6 | 712 µs | 842 µs | 46× faster | 96.4 | 154 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 658 | 33.0 | 733 µs | 691 µs | 1.3 | 660 µs | 733 µs | 45× faster | 118 | 158 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 15.0 | 1.1 | 400 µs | 419 µs | 550 µs | 420 µs | 401 µs | 2.9× faster | 100.0 | 156 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 122 | 7.9 | 440 µs | 445 µs | 1.0 | 329 µs | 436 µs | 18.0× faster | 115 | 166 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.9 | 3.0 | 5.4 | 5.4 | 29.6 | 3.3 | 3.0 | 1.78× slower | 145 | 195 |

**Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); measured with 0.86, as the M3 Max has no Chrome** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 366 | – | 1.9 | 1.6 | 192× faster | 10.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 3655 | – | 4.6 | 4.6 | 795× faster | 26.3 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2882 | – | 3.7 | 3.7 | 779× faster | 21.9 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 52.8 | – | 1.3 | 1.4 | 41× faster | 5.9 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 91.3 | – | 2.4 | 2.4 | 38× faster | 8.8 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.4 | – | 21.1 | 1.5 | 15.1× slower | 58.0 |




What the tables show:

- **A discrete GPU wins by a wide margin** on the programs that do real work per
  element — `md5` hashes 64 million candidates in about a millisecond on one
  discrete card against hundreds on the CPU — and `auto` finds that and uses it.
- **`saxpy` stays on the CPU.** It does one multiply-add for every eight bytes
  it moves, so copying to and from the GPU outweighs the arithmetic, and `auto`
  keeps it on the CPU everywhere.
- **The tile queue scales a block across GPUs, where that pays.**
  `saxpy` spreads across both cards as the sum of their PCIe links — one GPU
  16 ms, both 7.9 — though it is memory-bound, so the CPU still wins and `auto`
  keeps it there. `md5` at 64 million candidates takes 0.9 ms on one card and
  0.7 on both: a block this short gains little from a second card, since the
  queue's cost per tile is paid twice, and `auto` chooses between them by
  measuring. A second GPU pays most on a block big enough to need its compute
  and not bound by the transfer to it.
- **Mixed graphics APIs.** The scheduler does not require one API: a block
  can run one card through CUDA beside another through Vulkan, so an NVIDIA
  and an AMD card could share a block the same way.
- **The Raspberry Pi 5** (from 0.89): the V3D runs `par` blocks through
  Vulkan in 32-bit kernels, as it has no 64-bit integers. On its own it
  trails the four cores on most blocks and edges them on `md5`; `auto`
  measures both and then the two together, and runs `perlin`, `md5`,
  `md5_mask` and `mandel_deep` across the CPU and the GPU at once:
  `mandel_deep` in 9.6 s, against 14.0 s on the cores and 22.9 s on the GPU
  alone, where GCC with OpenMP takes about 32 s
  ([Performance: C](/compiler/benchmarks/c/)). The "all devices" column is
  the set forced from the start, before `auto` has measured the CPU, so it is
  mostly the GPU's tiles.
- **The Ryzen's integrated Radeon** has 128 shader lanes against the CPU's 32
  threads. It just beats them on `mandelbrot`, `perlin` and `md5` and loses on
  `nbody` and `saxpy`, where `auto` keeps the CPU.
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (34.2 ms against 19.4) and `mandelbrot` (275 µs against 145 µs) and `md5` (1.6 ms against 882 µs) and `md5_mask` (1.3 ms against 733 µs) and `nbody` (550 µs against 400 µs) and `perlin` (1.0 ms against 440 µs) and `saxpy` (29.6 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 96 to 145 ms through CUDA and 154 to 211 ms through Vulkan. `auto` pays it
  once, while it measures.

## Plain loops: `--par-auto`

`--par-auto` turns a loop whose iterations are independent into a `par`
block. Four of the programs above, written again as plain loops with no `par`
in them, are built as written and with `--par-auto`, and each mode's checksum
must agree. The last column is the hand-written `par` version's `auto`.

**Apple M3 Max, Metal** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 164 | 13.6 | 1.2 | 1.6 | 873 µs |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 45.4 | 1.5 | 1.1 | 1.4 | 654 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 86.8 | 7.7 | 1.2 | 942 µs | 1.2 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.4 | 1.1 | 3.8 | 1.1 | 1.1 |

**AMD Ryzen 9 9955HX, its integrated Radeon through Vulkan** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 56.0 | 3.4 | 9.4 | 2.9 | 3.4 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 94.7 | 780 µs | 3.4 | 763 µs | 540 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 85.0 | 5.8 | 5.4 | 4.2 | 3.9 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.2 | 9.7 | 2.4 | 2.4 |

**Windows, RTX 5080 through CUDA** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 83.5 | 4.3 | 145 µs | 145 µs | 145 µs |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 118 | 1.1 | 401 µs | 400 µs | 401 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 127 | 8.0 | 440 µs | 436 µs | 436 µs |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.8 | 3.0 | 5.4 | 3.1 | 3.0 |


## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/par/run.py --autopar    # the --par-auto tables
python3 benchmark/page.py
```
