---
title: "Performance: GPU"
description: How xc's par blocks run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, and what --par-auto makes of plain loops, measured with the released xcc.
---

Each figure is measured with the released 0.86 `xcc`, on an Apple
MacBook Pro with an M4 Max (Metal), a Linux machine with an AMD Ryzen 9
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

**Apple MacBook Pro, M4 Max (12 performance and 4 efficiency cores), its GPU through Metal** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 144 | 11.9 | 2.0 | 734 µs | 878 µs | 6.0× faster | 33.8 |
| [`md5`](/compiler/benchmark-sources/#md5) | 1189 | 102 | 4.2 | 4.8 | 4.1 | 24× faster | 26.7 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 924 | 77.4 | 3.5 | 3.6 | 3.5 | 22× faster | 38.3 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 19.6 | 2.0 | 1.2 | 2.0 | 1.1 | 1.75× faster | 32.8 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 78.8 | 6.5 | 1.1 | 1.1 | 1.2 | 5.7× faster | 24.0 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.3 | 499 µs | 1.6 | 3.1 | 502 µs | 3.3× slower | 28.6 |

**AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 57.9 | 3.3 | 9.7 | 9.8 | 2.7 | 3.0× slower | 28.7 |
| [`md5`](/compiler/benchmark-sources/#md5) | 394 | 16.6 | 108 | 113 | 16.0 | 6.5× slower | 135 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 314 | 13.5 | 88.1 | 87.7 | 13.2 | 6.5× slower | 116 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 6.0 | 506 µs | 3.4 | 3.6 | 503 µs | 6.8× slower | 23.0 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 114 | 8.7 | 5.7 | 5.8 | 5.7 | 1.52× faster | 32.6 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.9 | 9.6 | 3.1 | 2.9 | 3.3× slower | 35.6 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 259 | 10.8 | 143 µs | 161 µs | 269 µs | 160 µs | 143 µs | 75× faster | 95.8 | 144 |
| [`md5`](/compiler/benchmark-sources/#md5) | 830 | 44.0 | 875 µs | 707 µs | 1.6 | 711 µs | 829 µs | 50× faster | 96.7 | 144 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 669 | 36.1 | 727 µs | 667 µs | 1.3 | 670 µs | 729 µs | 50× faster | 95.0 | 142 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 144 | 5.3 | 400 µs | 417 µs | 548 µs | 415 µs | 398 µs | 13.3× faster | 95.6 | 138 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 181 | 12.5 | 440 µs | 444 µs | 1.0 | 326 µs | 427 µs | 28× faster | 82.0 | 142 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 5.1 | 4.1 | 5.4 | 5.4 | 30.1 | 3.5 | 4.0 | 1.33× slower | 114 | 173 |

**Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73)** (ms; best of eight runs)

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

**Apple MacBook Pro, M4 Max (12 performance and 4 efficiency cores), its GPU through Metal** (ms; best of eight runs)

| benchmark | GPU | `auto` | GPU's first run |
|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 44.0 | 44.1 | 88.1 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | GPU | all GPUs | Vulkan | `auto` | GPU's first run |
|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 19.3 | 11.4 | 34.5 | 11.3 | 115 |


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
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (34.5 ms against 19.3) and `mandelbrot` (269 µs ms against 143 µs) and `md5` (1.6 ms against 875 µs) and `md5_mask` (1.3 ms against 727 µs) and `nbody` (548 µs ms against 400 µs) and `perlin` (1.0 ms against 440 µs) and `saxpy` (30.1 ms against 5.4).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 82 to 115 ms through CUDA and 138 to 198 ms through Vulkan. `auto` pays it
  once, while it measures.

## Plain loops: `--par-auto`

`--par-auto` turns a loop whose iterations are independent into a `par`
block. Four of the programs above, written again as plain loops with no `par`
in them, are built as written and with `--par-auto`, and each mode's checksum
must agree. The last column is the hand-written `par` version's `auto`.

**Apple M4 Max, Metal** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 144 | 12.0 | 2.0 | 1.9 | 878 µs |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 39.7 | 2.0 | 1.1 | 1.2 | 1.1 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 79.4 | 6.5 | 1.3 | 1.2 | 1.2 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.4 | 502 µs | 2.4 | 497 µs | 502 µs |

**AMD Ryzen 9 9955HX, its integrated Radeon through Vulkan** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 57.9 | 2.4 | 9.7 | 2.4 | 2.7 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 95.0 | 555 µs | 3.4 | 464 µs | 503 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 112 | 8.7 | 5.7 | 5.7 | 5.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.3 | 2.8 | 9.6 | 2.8 | 2.9 |

**Windows, RTX 5080 through CUDA** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 258 | 10.8 | 143 µs | 142 µs | 143 µs |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 119 | 5.3 | 397 µs | 397 µs | 398 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 169 | 11.8 | 432 µs | 437 µs | 427 µs |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 4.9 | 4.2 | 5.4 | 4.0 | 4.0 |


## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/par/run.py --autopar    # the --par-auto tables
python3 benchmark/page.py
```
