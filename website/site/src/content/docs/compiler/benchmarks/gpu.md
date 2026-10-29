---
title: "Performance: GPU"
description: How xc's par blocks run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, and what --par-auto makes of plain loops, measured with the released xcc.
---

Each figure is measured with the released 0.88 `xcc`, on an Apple
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
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 167 | 13.7 | 1.0 | 979 µs | 1.8 | 13.2× faster | 29.7 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1379 | 109 | 4.8 | 5.5 | 4.8 | 22× faster | 35.7 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 1141 | 84.9 | 4.1 | 4.2 | 4.5 | 21× faster | 27.5 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 14.5 | 1.5 | 1.1 | 1.6 | 1.5 | 1.34× faster | 34.6 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 93.2 | 7.7 | 1.2 | 1.2 | 954 µs | 6.6× faster | 24.3 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.5 | 1.1 | 4.1 | 4.1 | 1.1 | 3.7× slower | 26.8 |

**AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 55.8 | 3.2 | 9.7 | 9.7 | 2.7 | 3.0× slower | 30.7 |
| [`md5`](/compiler/benchmark-sources/#md5) | 228 | 13.1 | 108 | 113 | 14.2 | 8.2× slower | 134 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 188 | 10.2 | 88.6 | 87.6 | 8.4 | 8.7× slower | 117 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 6.7 | 765 µs | 3.4 | 3.6 | 542 µs | 4.5× slower | 24.4 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 80.1 | 5.9 | 5.7 | 5.8 | 5.7 | 1.03× faster | 28.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.4 | 9.8 | 3.1 | 2.4 | 4.1× slower | 36.0 |

**Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 95.5 | 8.6 | 216 µs | 316 µs | 224 µs | 216 µs | 40× faster | 209 | 108 |
| [`md5`](/compiler/benchmark-sources/#md5) | 766 | 72.0 | 1.5 | 2.6 | 1.7 | 1.5 | 49× faster | 214 | 113 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 624 | 60.4 | 1.2 | 2.3 | 1.3 | 1.2 | 49× faster | 210 | 108 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.5 | 3.4 | 371 µs | 341 µs | 383 µs | 372 µs | 9.2× faster | 123 | 107 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 106 | 10.4 | 359 µs | 1.2 | 385 µs | 364 µs | 29× faster | 208 | 110 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.4 | 2.5 | 6.3 | 25.7 | 3.2 | 2.5 | 2.5× slower | 137 | 140 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 83.7 | 4.2 | 143 µs | 161 µs | 274 µs | 161 µs | 144 µs | 30× faster | 111 | 157 |
| [`md5`](/compiler/benchmark-sources/#md5) | 811 | 39.9 | 877 µs | 700 µs | 1.6 | 710 µs | 826 µs | 46× faster | 136 | 162 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 658 | 32.9 | 729 µs | 682 µs | 1.3 | 661 µs | 733 µs | 45× faster | 113 | 157 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 15.0 | 1.1 | 399 µs | 419 µs | 546 µs | 418 µs | 400 µs | 2.8× faster | 113 | 160 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 122 | 8.0 | 440 µs | 444 µs | 1.0 | 329 µs | 436 µs | 18.1× faster | 127 | 158 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.9 | 3.0 | 5.4 | 5.4 | 29.6 | 3.3 | 3.0 | 1.79× slower | 143 | 189 |

**Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73); measured with 0.86, as the M3 Max has no Chrome** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 366 | – | 1.9 | 1.6 | 192× faster | 10.4 |
| [`md5`](/compiler/benchmark-sources/#md5) | 3655 | – | 4.6 | 4.6 | 795× faster | 26.3 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 2882 | – | 3.7 | 3.7 | 779× faster | 21.9 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 52.8 | – | 1.3 | 1.4 | 41× faster | 5.9 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 91.3 | – | 2.4 | 2.4 | 38× faster | 8.8 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.4 | – | 21.1 | 1.5 | 15.1× slower | 58.0 |


### GPU-saturation benchmarks

These blocks are sized so that a single GPU stays busy for tens of milliseconds
— long enough that the tile queue's fixed per-tile cost is amortised and
spreading the block across a **second GPU** cuts the wall-clock time. The
benchmarks above each finish on one modern card in around a millisecond, too
little for a second card to help; these are the opposite case. There are no
*one thread*, *all threads* or *all devices* columns: at this size a single CPU
thread takes minutes per run, and `auto` would never put a saturating GPU block
on the CPU, so only the GPU paths are measured. On a one-GPU machine *all GPUs*
is the same device as *GPU* and is dropped; the point is the machine with two.

These figures are from the **development compiler for 0.8.1**, not released 0.8:
they need two fixes landing in that release — a narrow integer now converts to
float in a CUDA (PTX) kernel instead of dropping the kernel to a Vulkan
fallback, and the tile queue keeps a card's second back end in reach so a block
can spread across both NVIDIA cards. On released 0.8 this block stays on one
card. The two cards are not a matched pair — an RTX 5080 and an older RTX 3090
— so the gain is not 2×; read it from the slower card, which is the fairer
baseline: the 3090 alone against the two together. `auto` still keeps this
block on the single faster card for now — the per-tile cost during its short
probe hides the second card's gain — so the two-card figure is the `all GPUs`
column (`XC_PAR=gpus`); teaching `auto` to choose it is the next step.

**Apple MacBook Pro, M3 Max, a 40-core GPU (12 performance and 4 efficiency cores), its GPU through Metal** (ms; best of eight runs)

| benchmark | GPU | `auto` | GPU's first run |
|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 50.2 | 50.3 | 87.5 |

**Intel Core i5-14500 (14 cores, 20 threads), Linux, an NVIDIA RTX 5070 through CUDA and Vulkan (from 0.88)** (ms; best of eight runs)

| benchmark | GPU | Vulkan | `auto` | GPU's first run |
|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 23.6 | 34.4 | 23.5 | 240 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | GPU | all GPUs | Vulkan | `auto` | GPU's first run |
|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 19.4 | 11.3 | 34.2 | 11.4 | 160 |


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
- **The Ryzen's integrated Radeon** has 128 shader lanes against the CPU's 32
  threads. It just beats them on `mandelbrot`, `perlin` and `md5` and loses on
  `nbody` and `saxpy`, where `auto` keeps the CPU.
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (34.2 ms against 19.4) and `mandelbrot` (274 µs ms against 143 µs) and `md5` (1.6 ms against 877 µs) and `md5_mask` (1.3 ms against 729 µs) and `nbody` (546 µs ms against 399 µs) and `perlin` (1.0 ms against 440 µs) and `saxpy` (29.6 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 111 to 160 ms through CUDA and 157 to 210 ms through Vulkan. `auto` pays it
  once, while it measures.

## Plain loops: `--par-auto`

`--par-auto` turns a loop whose iterations are independent into a `par`
block. Four of the programs above, written again as plain loops with no `par`
in them, are built as written and with `--par-auto`, and each mode's checksum
must agree. The last column is the hand-written `par` version's `auto`.

**Apple M3 Max, Metal** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 167 | 13.7 | 1.1 | 870 µs | 1.8 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 46.9 | 1.5 | 1.1 | 1.1 | 1.5 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 92.8 | 7.7 | 1.2 | 833 µs | 954 µs |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.5 | 1.1 | 3.2 | 1.1 | 1.1 |

**AMD Ryzen 9 9955HX, its integrated Radeon through Vulkan** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 55.9 | 2.4 | 9.7 | 2.7 | 2.7 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 94.6 | 689 µs | 3.4 | 529 µs | 542 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 84.9 | 5.9 | 5.7 | 5.7 | 5.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.4 | 2.4 | 9.7 | 2.4 | 2.4 |

**Windows, RTX 5080 through CUDA** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 83.5 | 4.3 | 145 µs | 145 µs | 144 µs |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 117 | 1.1 | 401 µs | 401 µs | 400 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 127 | 8.0 | 440 µs | 437 µs | 436 µs |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.8 | 3.0 | 5.4 | 3.1 | 3.0 |


## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/par/run.py --autopar    # the --par-auto tables
python3 benchmark/page.py
```
