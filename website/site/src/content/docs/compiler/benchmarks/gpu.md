---
title: "Performance: GPU"
description: How plain loops, which xcc makes par blocks of, run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, measured with the released xcc.
---

Each figure is measured with the released 0.9.5 `xcc`, on an Apple
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

The programs in `benchmark/par` are plain loops: none of them says `par`.
xcc turns each loop whose iterations are independent into a `par` block by
itself (`--par-style=auto`, the default), so they are built with no flags.
They are:

- `mandelbrot`: a 2048×2048 escape-time image, at most 256 iterations a pixel;
- `perlin`: 2048×2048 improved noise, four octaves;
- `nbody`: the force on each of 8192 bodies from all the others;
- `saxpy`: `y = a·x + y` over 16 million integers, with a sum;
- `md5`, `md5_mask`: the hashcat MD5 workload, hashing 64 million candidates
  through the full 64-round compression and summing the digests;
- `mandel_deep`: the mandelbrot image at up to 65,536 iterations a pixel.

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
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 164 | 13.5 | 1.2 | 1.2 | 1.3 | 11.7× faster | 27.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1349 | 109 | 4.8 | 5.5 | 4.9 | 23× faster | 26.6 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 1064 | 85.2 | 4.1 | 4.2 | 4.1 | 21× faster | 32.3 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 17.5 | 1.8 | 569 µs | 978 µs | 1.1 | 3.2× faster | 33.0 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 70.1 | 6.1 | 1.2 | 1.2 | 1.3 | 5.0× faster | 24.4 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.5 | 1.1 | 3.8 | 4.6 | 1.1 | 3.5× slower | 3.8 |

**AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 56.1 | 2.4 | 9.5 | 9.5 | 2.4 | 4.0× slower | 31.1 |
| [`md5`](/compiler/benchmark-sources/#md5) | 228 | 9.4 | 108 | 110 | 9.5 | 11.5× slower | 138 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 199 | 8.3 | 88.7 | 87.4 | 8.3 | 10.7× slower | 115 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 7.4 | 528 µs | 3.3 | 3.4 | 522 µs | 6.3× slower | 28.2 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 83.7 | 6.0 | 5.3 | 5.4 | 4.1 | 1.12× faster | 29.0 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.2 | 9.9 | 3.0 | 2.3 | 4.5× slower | 9.9 |

**Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 95.7 | 8.4 | 194 µs | 242 µs | 216 µs | 194 µs | 43× faster | 207 | 109 |
| [`md5`](/compiler/benchmark-sources/#md5) | 766 | 72.0 | 1.5 | 2.7 | 1.7 | 1.5 | 49× faster | 210 | 109 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 621 | 60.1 | 1.2 | 2.3 | 1.3 | 1.2 | 49× faster | 211 | 107 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.5 | 3.4 | 363 µs | 410 µs | 385 µs | 363 µs | 9.3× faster | 123 | 110 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 111 | 10.6 | 367 µs | 1.1 | 401 µs | 374 µs | 29× faster | 208 | 113 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.5 | 2.5 | 6.3 | 25.9 | 3.6 | 2.4 | 2.5× slower | 10.6 | 31.6 |

**Raspberry Pi 5 (four Cortex-A76 cores at 2.4 GHz), Raspberry Pi OS, its VideoCore VII GPU (V3D 7.1) through Vulkan (from 0.89)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 51867 | 13814 | 11017 | 9288 | 6138 | 1.25× faster | 11090 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 336 | 89.5 | 114 | 115 | 59.6 | 1.28× slower | 161 |
| [`md5`](/compiler/benchmark-sources/#md5) | 2868 | 717 | 660 | 1165 | 624 | 1.09× faster | 707 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2320 | 580 | 495 | 496 | 346 | 1.17× faster | 540 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 96.0 | 23.8 | 32.5 | 32.6 | 20.0 | 1.37× slower | 75.5 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 325 | 81.4 | 96.7 | 95.6 | 63.9 | 1.19× slower | 145 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 25.9 | 34.5 | 130 | 104 | 26.2 | 3.8× slower | 134 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 83.8 | 4.2 | 136 µs | 172 µs | 284 µs | 173 µs | 137 µs | 31× faster | 83.0 | 153 |
| [`md5`](/compiler/benchmark-sources/#md5) | 816 | 39.7 | 894 µs | 761 µs | 1.6 | 763 µs | 848 µs | 44× faster | 81.9 | 174 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 650 | 32.4 | 745 µs | 743 µs | 1.4 | 721 µs | 747 µs | 44× faster | 81.3 | 157 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 14.9 | 1.1 | 394 µs | 432 µs | 734 µs | 430 µs | 392 µs | 2.7× faster | 80.6 | 163 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 132 | 8.3 | 446 µs | 477 µs | 1.0 | 370 µs | 441 µs | 18.7× faster | 78.2 | 157 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.8 | 3.1 | 5.4 | 5.4 | 29.6 | 3.3 | 3.0 | 1.76× slower | 16.0 | 31.0 |

**Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); measured with 0.86, as the M3 Max has no Chrome** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 478 | – | 2.2 | 1.9 | 217× faster | 133 |
| [`md5`](/compiler/benchmark-sources/#md5) | 4227 | – | 5.4 | 5.4 | 783× faster | 56.4 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 3394 | – | 4.4 | 4.3 | 771× faster | 61.6 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 56.5 | – | 1.6 | 1.6 | 35× faster | 6.6 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 102 | – | 2.4 | 2.2 | 43× faster | 9.8 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.9 | – | 29.6 | 1.9 | 15.6× slower | 50.1 |




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
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (33.3 ms against 17.5) and `mandelbrot` (284 µs against 136 µs) and `md5` (1.6 ms against 894 µs) and `md5_mask` (1.4 ms against 745 µs) and `nbody` (734 µs against 394 µs) and `perlin` (1.0 ms against 446 µs) and `saxpy` (29.6 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 16 to 118 ms through CUDA and 31 to 208 ms through Vulkan. `auto` pays it
  once, while it measures.

## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/page.py
```
