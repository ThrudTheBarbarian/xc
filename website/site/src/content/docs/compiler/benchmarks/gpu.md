---
title: "Performance: GPU"
description: How plain loops, which xcc makes par blocks of, run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, measured with the released xcc.
---

Each figure is measured with the released 0.9.7 `xcc`, on an Apple
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
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 164 | 13.6 | 1.1 | 878 µs | 1.1 | 12.6× faster | 37.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1349 | 108 | 5.0 | 5.7 | 5.0 | 22× faster | 34.2 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 1064 | 84.9 | 4.2 | 4.4 | 4.2 | 20× faster | 31.9 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 17.3 | 1.8 | 1.0 | 1.3 | 1.2 | 1.74× faster | 27.7 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 68.4 | 6.1 | 862 µs | 1.1 | 1.3 | 7.0× faster | 33.5 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.6 | 1.1 | 3.7 | 2.1 | 1.1 | 3.4× slower | 3.8 |

### AMD Ryzen 9 9955HX

AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 56.2 | 2.4 | 9.4 | 9.4 | 2.4 | 3.9× slower | 31.6 |
| [`md5`](/compiler/benchmark-sources/#md5) | 229 | 9.5 | 108 | 109 | 9.5 | 11.3× slower | 138 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 199 | 8.1 | 89.0 | 87.2 | 8.4 | 10.9× slower | 117 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 7.5 | 527 µs | 3.3 | 3.4 | 538 µs | 6.3× slower | 34.0 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 83.8 | 6.1 | 5.0 | 5.3 | 4.9 | 1.22× faster | 42.4 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.2 | 9.7 | 2.5 | 2.3 | 4.3× slower | 14.1 |

### Intel Core i5-14500 with an RTX 5070

Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88) (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 96.5 | 8.3 | 197 µs | 373 µs | 234 µs | 198 µs | 42× faster | 212 | 117 |
| [`md5`](/compiler/benchmark-sources/#md5) | 766 | 72.0 | 1.5 | 2.7 | 1.7 | 1.5 | 49× faster | 124 | 112 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 621 | 60.1 | 1.2 | 2.3 | 1.3 | 1.2 | 49× faster | 210 | 108 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.5 | 3.4 | 364 µs | 439 µs | 393 µs | 364 µs | 9.3× faster | 206 | 109 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 111 | 10.6 | 371 µs | 1.0 | 414 µs | 376 µs | 28× faster | 126 | 107 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.3 | 2.5 | 6.3 | 25.9 | 2.7 | 2.6 | 2.5× slower | 10.7 | 31.7 |

### Raspberry Pi 5

Raspberry Pi 5 (four Cortex-A76 cores at 2.4 GHz), Raspberry Pi OS, its VideoCore VII GPU (V3D 7.1) through Vulkan (from 0.89) (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 54984 | 14643 | 8395 | 8356 | 5799 | 1.74× faster | 8465 |
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 335 | 89.2 | 110 | 111 | 65.0 | 1.24× slower | 157 |
| [`md5`](/compiler/benchmark-sources/#md5) | 2868 | 717 | 660 | 1133 | 614 | 1.09× faster | 707 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2320 | 580 | 474 | 475 | 327 | 1.22× faster | 519 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 96.1 | 23.8 | 23.7 | 23.9 | 17.2 | the same | 66.1 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 325 | 81.4 | 55.9 | 77.1 | 55.9 | 1.46× faster | 126 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 25.1 | 34.3 | 130 | 56.7 | 27.0 | 3.8× slower | 134 |

### AMD Ryzen 9 5950X with an RTX 5080 and an RTX 3090

AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 81.2 | 4.0 | 140 µs | 196 µs | 290 µs | 197 µs | 142 µs | 28× faster | 88.3 | 154 |
| [`md5`](/compiler/benchmark-sources/#md5) | 812 | 40.6 | 896 µs | 783 µs | 1.6 | 785 µs | 896 µs | 45× faster | 94.6 | 160 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 651 | 32.4 | 748 µs | 661 µs | 1.4 | 676 µs | 751 µs | 43× faster | 77.0 | 157 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 15.0 | 1.0 | 397 µs | 443 µs | 738 µs | 442 µs | 396 µs | 2.6× faster | 82.5 | 170 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 133 | 8.3 | 447 µs | 490 µs | 1.0 | 378 µs | 443 µs | 18.6× faster | 94.1 | 158 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.8 | 3.0 | 5.4 | 5.4 | 29.7 | 2.9 | 3.1 | 1.80× slower | 16.1 | 31.3 |

### Chrome: wasm32 and WebGPU

Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); measured with 0.86, as the M3 Max has no Chrome (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 486 | – | 2.0 | 2.4 | 243× faster | 10.7 |
| [`md5`](/compiler/benchmark-sources/#md5) | 4229 | – | 5.4 | 5.3 | 783× faster | 30.0 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 3395 | – | 4.4 | 4.4 | 772× faster | 23.3 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 55.0 | – | 900 µs | 1.5 | 61× faster | 9.3 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 102 | – | 3.0 | 2.7 | 34× faster | 14.2 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.9 | – | 29.5 | 1.8 | 15.5× slower | 47.8 |




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
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (32.4 ms against 17.5) and `mandelbrot` (290 µs against 140 µs) and `md5` (1.6 ms against 896 µs) and `md5_mask` (1.4 ms against 748 µs) and `nbody` (738 µs against 397 µs) and `perlin` (1.0 ms against 447 µs) and `saxpy` (29.7 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 16 to 122 ms through CUDA and 31 to 209 ms through Vulkan. `auto` pays it
  once, while it measures.

## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/page.py
```
