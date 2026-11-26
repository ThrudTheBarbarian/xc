---
title: "Performance: GPU"
description: How plain loops, which xcc makes par blocks of, run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, measured with the released xcc.
---

Each figure is measured with the released 1.0.3 `xcc`, on an Apple
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

### Apple M3 Max

Apple MacBook Pro, M3 Max, a 40-core GPU (12 performance and 4 efficiency cores), its GPU through Metal (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 165 | 13.6 | 1.1 | 1.1 | 1.2 | 12.8× faster | 33.3 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1452 | 114 | 4.9 | 5.8 | 5.0 | 23× faster | 27.9 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 1191 | 97.8 | 4.1 | 4.4 | 4.2 | 24× faster | 27.7 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.1 | 1.5 | 1.1 | 1.3 | 1.2 | 1.40× faster | 24.1 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 66.3 | 5.8 | 867 µs | 851 µs | 991 µs | 6.7× faster | 23.9 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.6 | 1.1 | 4.0 | 4.7 | 1.1 | 3.7× slower | 4.0 |

### AMD Ryzen 9 9955HX

AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 56.1 | 2.3 | 9.3 | 9.4 | 2.4 | 4.1× slower | 30.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 228 | 9.4 | 108 | 109 | 9.4 | 11.5× slower | 138 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 199 | 8.2 | 89.2 | 87.1 | 8.2 | 10.9× slower | 118 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 7.5 | 540 µs | 3.3 | 3.4 | 547 µs | 6.1× slower | 27.2 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 70.1 | 4.8 | 4.9 | 5.3 | 3.3 | 1.03× slower | 28.3 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.2 | 9.7 | 2.5 | 3.3 | 4.3× slower | 10.2 |

### Intel Core i5-14500 with an RTX 5070

Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88) (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 102 | 8.4 | 198 µs | 284 µs | 235 µs | 198 µs | 42× faster | 204 | 109 |
| [`md5`](/compiler/benchmark-sources/#md5) | 647 | 61.7 | 1.5 | 2.6 | 1.7 | 1.5 | 42× faster | 124 | 108 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 527 | 48.6 | 1.2 | 2.3 | 1.3 | 1.2 | 39× faster | 212 | 108 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.5 | 3.4 | 365 µs | 486 µs | 395 µs | 366 µs | 9.3× faster | 208 | 111 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 95.0 | 9.3 | 375 µs | 677 µs | 413 µs | 370 µs | 25× faster | 123 | 113 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.4 | 2.6 | 6.3 | 14.6 | 2.8 | 2.5 | 2.5× slower | 10.5 | 27.6 |

### Raspberry Pi 5

Raspberry Pi 5 (four Cortex-A76 cores at 2.4 GHz), Raspberry Pi OS, its VideoCore VII GPU (V3D 7.1) through Vulkan (from 0.89) (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 50772 | 13523 | 8395 | 8356 | 5705 | 1.61× faster | 8467 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 325 | 86.5 | 110 | 111 | 60.9 | 1.28× slower | 157 |
| [`md5`](/compiler/benchmark-sources/#md5) | 2866 | 716 | 660 | 1133 | 612 | 1.09× faster | 707 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2343 | 586 | 474 | 475 | 327 | 1.23× faster | 520 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 95.9 | 23.8 | 23.7 | 23.9 | 18.5 | the same | 68.5 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 300 | 75.3 | 55.9 | 77.1 | 49.6 | 1.35× faster | 126 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 27.0 | 34.7 | 132 | 58.7 | 28.6 | 3.8× slower | 135 |

### AMD Ryzen 9 5950X with an RTX 5080 and an RTX 3090

AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 84.4 | 4.2 | 143 µs | 195 µs | 292 µs | 197 µs | 144 µs | 29× faster | 95.7 | 163 |
| [`md5`](/compiler/benchmark-sources/#md5) | 712 | 32.0 | 897 µs | 783 µs | 1.6 | 783 µs | 896 µs | 36× faster | 80.4 | 166 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 575 | 27.4 | 748 µs | 665 µs | 1.4 | 689 µs | 746 µs | 37× faster | 98.7 | 169 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 14.8 | 1.1 | 396 µs | 443 µs | 728 µs | 443 µs | 399 µs | 2.7× faster | 79.9 | 166 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 98.3 | 6.4 | 447 µs | 493 µs | 705 µs | 377 µs | 444 µs | 14.3× faster | 93.0 | 167 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.8 | 3.1 | 5.4 | 5.4 | 16.6 | 3.2 | 3.2 | 1.77× slower | 16.0 | 27.2 |

### Chrome: wasm32 and WebGPU

Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); measured with 0.86, as the M3 Max has no Chrome (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 478 | – | 2.6 | 2.6 | 184× faster | 10.6 |
| [`md5`](/compiler/benchmark-sources/#md5) | 4570 | – | 5.2 | 5.4 | 879× faster | 35.4 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 3755 | – | 4.3 | 4.3 | 873× faster | 27.9 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 57.1 | – | 1.0 | 1.7 | 57× faster | 7.4 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 102 | – | 2.7 | 2.7 | 38× faster | 11.2 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.5 | – | 29.0 | 1.5 | 19.3× slower | 47.4 |




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
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (27.5 ms against 17.5) and `mandelbrot` (292 µs against 143 µs) and `md5` (1.6 ms against 897 µs) and `md5_mask` (1.4 ms against 748 µs) and `nbody` (728 µs against 396 µs) and `perlin` (705 µs against 447 µs) and `saxpy` (16.6 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 16 to 112 ms through CUDA and 27 to 226 ms through Vulkan. `auto` pays it
  once, while it measures.

## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/page.py
```
