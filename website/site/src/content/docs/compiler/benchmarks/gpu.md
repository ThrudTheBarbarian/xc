---
title: "Performance: GPU"
description: How plain loops, which xcc makes par blocks of, run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, measured with the released xcc.
---

Each figure is measured with the released 0.9.3 `xcc`, on an Apple
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
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 164 | 13.5 | 1.3 | 1.2 | 1.0 | 10.1× faster | 27.7 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1349 | 108 | 4.9 | 5.5 | 4.8 | 22× faster | 40.1 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 1064 | 85.2 | 4.1 | 4.3 | 4.1 | 21× faster | 26.5 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 17.7 | 1.8 | 609 µs | 1.3 | 1.3 | 3.0× faster | 22.7 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 89.9 | 7.7 | 1.2 | 1.2 | 1.2 | 6.4× faster | 24.1 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.4 | 1.1 | 3.9 | 5.2 | 1.1 | 3.6× slower | 3.9 |

**AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 56.0 | 2.3 | 9.4 | 9.5 | 2.4 | 4.1× slower | 29.0 |
| [`md5`](/compiler/benchmark-sources/#md5) | 228 | 9.3 | 108 | 110 | 9.3 | 11.5× slower | 138 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 199 | 8.2 | 88.7 | 87.5 | 8.3 | 10.8× slower | 115 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 7.4 | 515 µs | 3.5 | 3.6 | 518 µs | 6.7× slower | 25.6 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 83.6 | 5.9 | 5.4 | 5.5 | 3.9 | 1.09× faster | 27.3 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.2 | 9.9 | 3.1 | 2.2 | 4.4× slower | 9.9 |

**Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 95.6 | 8.4 | 194 µs | 250 µs | 214 µs | 194 µs | 43× faster | 214 | 105 |
| [`md5`](/compiler/benchmark-sources/#md5) | 766 | 72.0 | 1.5 | 2.7 | 1.7 | 1.5 | 49× faster | 212 | 109 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 622 | 60.2 | 1.2 | 2.2 | 1.3 | 1.2 | 49× faster | 123 | 108 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.5 | 3.4 | 375 µs | 426 µs | 393 µs | 375 µs | 9.0× faster | 124 | 109 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 111 | 10.6 | 371 µs | 1.1 | 396 µs | 382 µs | 29× faster | 125 | 108 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.3 | 2.5 | 6.3 | 25.7 | 3.7 | 2.5 | 2.5× slower | 10.4 | 31.5 |

**Raspberry Pi 5 (four Cortex-A76 cores at 2.4 GHz), Raspberry Pi OS, its VideoCore VII GPU (V3D 7.1) through Vulkan (from 0.89)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 52528 | 13990 | 11017 | 9288 | 6203 | 1.27× faster | 11090 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 340 | 90.5 | 114 | 115 | 71.9 | 1.26× slower | 161 |
| [`md5`](/compiler/benchmark-sources/#md5) | 2868 | 717 | 660 | 1165 | 632 | 1.09× faster | 710 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2320 | 580 | 495 | 496 | 338 | 1.17× faster | 543 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 96.2 | 23.9 | 111 | 111 | 23.9 | 4.6× slower | 160 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 401 | 100 | 119 | 118 | 80.0 | 1.19× slower | 167 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 25.5 | 34.5 | 131 | 104 | 26.9 | 3.8× slower | 135 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 83.4 | 4.3 | 136 µs | 173 µs | 284 µs | 173 µs | 137 µs | 32× faster | 80.1 | 157 |
| [`md5`](/compiler/benchmark-sources/#md5) | 814 | 39.7 | 894 µs | 764 µs | 1.6 | 771 µs | 880 µs | 44× faster | 98.7 | 155 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 652 | 32.4 | 746 µs | 752 µs | 1.4 | 739 µs | 747 µs | 43× faster | 80.0 | 153 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 15.0 | 1.0 | 405 µs | 437 µs | 562 µs | 437 µs | 406 µs | 2.5× faster | 81.8 | 154 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 133 | 8.4 | 444 µs | 476 µs | 1.0 | 359 µs | 442 µs | 18.9× faster | 97.7 | 155 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.8 | 3.0 | 5.4 | 5.4 | 29.7 | 3.3 | 3.1 | 1.79× slower | 16.5 | 34.5 |

**Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); measured with 0.86, as the M3 Max has no Chrome** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 485 | – | 1.7 | 1.9 | 285× faster | 12.0 |
| [`md5`](/compiler/benchmark-sources/#md5) | 4229 | – | 5.3 | 5.4 | 798× faster | 26.9 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 3396 | – | 4.4 | 4.3 | 772× faster | 23.4 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 58.5 | – | 1.3 | 1.1 | 45× faster | 6.5 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 103 | – | 2.8 | 2.1 | 37× faster | 13.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.9 | – | 29.3 | 1.8 | 15.4× slower | 49.0 |




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
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (33.0 ms against 17.5) and `mandelbrot` (284 µs against 136 µs) and `md5` (1.6 ms against 894 µs) and `md5_mask` (1.4 ms against 746 µs) and `nbody` (562 µs against 405 µs) and `perlin` (1.0 ms against 444 µs) and `saxpy` (29.7 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 16 to 110 ms through CUDA and 34 to 206 ms through Vulkan. `auto` pays it
  once, while it measures.

## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/page.py
```
