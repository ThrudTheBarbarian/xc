---
title: "Performance: GPU"
description: How xc's par blocks run on every CPU thread and on GPUs through Metal, CUDA, Vulkan and WebGPU, and what --par-auto makes of plain loops, measured with the released xcc.
---

Each figure is measured with the released 0.85 `xcc`, on an Apple
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
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 445 | 93.3 | 2.0 | 2.0 | 2.1 | 47× faster | 37.8 |
| [`md5`](/compiler/benchmark-sources/#md5) | 6909 | 590 | 4.2 | 4.8 | 4.3 | 142× faster | 32.7 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 5435 | 464 | 3.5 | 3.7 | 3.9 | 132× faster | 31.4 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 18.8 | 2.1 | 1.1 | 993 µs | 1.2 | 1.89× faster | 26.3 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 79.5 | 9.0 | 1.3 | 1.8 | 1.9 | 6.7× faster | 36.5 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 1.9 | 600 µs | 10.6 | 11.9 | 754 µs | 17.7× slower | 34.9 |

**AMD Ryzen 9 9955HX (16 cores, 32 threads), Linux, its integrated Radeon 610M (2 compute units, 128 shader lanes) through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all devices | `auto` | GPU vs all threads | GPU's first run |
|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 395 | 40.0 | 9.7 | 9.8 | 9.7 | 4.1× faster | 28.5 |
| [`md5`](/compiler/benchmark-sources/#md5) | 6408 | 253 | 108 | 113 | 108 | 2.3× faster | 135 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 5145 | 208 | 88.9 | 87.7 | 70.2 | 2.3× faster | 115 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 6.0 | 602 µs | 3.4 | 3.6 | 652 µs | 5.7× slower | 22.2 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 299 | 17.0 | 5.9 | 5.9 | 5.9 | 2.9× faster | 29.7 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 3.7 | 2.3 | 22.0 | 13.7 | 2.3 | 9.7× slower | 59.9 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | all GPUs | Vulkan | all devices | `auto` | GPU vs all threads | GPU's first run | Vulkan's first run |
|---|---|---|---|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 448 | 48.0 | 144 µs | 162 µs | 271 µs | 161 µs | 144 µs | 333× faster | 97.7 | 133 |
| [`md5`](/compiler/benchmark-sources/#md5) | 6952 | 299 | 876 µs | 709 µs | 1.6 | 715 µs | 822 µs | 342× faster | 83.3 | 134 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 5608 | 239 | 729 µs | 665 µs | 1.3 | 656 µs | 799 µs | 328× faster | 132 | 139 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 141 | 5.2 | 400 µs | 419 µs | 549 µs | 420 µs | 400 µs | 13.1× faster | 83.4 | 137 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 353 | 19.1 | 498 µs | 444 µs | 1.1 | 325 µs | 489 µs | 38× faster | 83.6 | 137 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 5.0 | 3.0 | 16.0 | 7.9 | 30.4 | 4.4 | 3.2 | 5.3× slower | 119 | 169 |

**Chrome on the Apple M4 Max: wasm32 (one thread) and WebGPU (from 0.73)** (ms; best of eight runs)

| benchmark | one thread | all threads | GPU | `auto` | GPU vs one thread | GPU's first run |
|---|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 485 | – | 1.5 | 1.5 | 323× faster | 9.2 |
| [`md5`](/compiler/benchmark-sources/#md5) | 4610 | – | 4.6 | 4.5 | 1002× faster | 30.8 |
| [`md5_mask`](/compiler/benchmark-sources/#md5_mask) | 3788 | – | 3.7 | 3.7 | 1024× faster | 24.6 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 59.5 | – | 1.3 | 1.4 | 46× faster | 5.9 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 94.4 | – | 1.5 | 2.3 | 63× faster | 8.9 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 2.5 | – | 26.8 | 2.4 | 10.7× slower | 75.7 |


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
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 49.7 | 49.2 | 75.5 |

**AMD Ryzen 9 5950X (16 cores, 32 threads), Windows, an NVIDIA RTX 5080 through CUDA and an RTX 3090 through Vulkan** (ms; best of eight runs)

| benchmark | GPU | all GPUs | Vulkan | `auto` | GPU's first run |
|---|---|---|---|---|---|
| [`mandel_deep`](/compiler/benchmark-sources/#mandel_deep) | 19.4 | 11.3 | 34.3 | 11.4 | 122 |


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
- **Vulkan against CUDA:** the RTX 3090 through Vulkan against the RTX 5080 through CUDA, two cards, so this compares the APIs only roughly: Vulkan is slower on `mandel_deep` (34.3 ms against 19.4) and `mandelbrot` (271 µs ms against 144 µs) and `md5` (1.6 ms against 876 µs) and `md5_mask` (1.3 ms against 729 µs) and `nbody` (549 µs ms against 400 µs) and `perlin` (1.1 ms against 498 µs) and `saxpy` (30.4 ms against 16.0).
- **The first run** carries one-off costs (building the kernel, and on NVIDIA
  creating the driver context and compiling the PTX or SPIR-V), so it is shown
  apart: a few tens of milliseconds on Metal and the integrated GPU, and on the
  3090 83 to 132 ms through CUDA and 133 to 188 ms through Vulkan. `auto` pays it
  once, while it measures.

## Plain loops: `--par-auto`

`--par-auto` turns a loop whose iterations are independent into a `par`
block. Four of the programs above, written again as plain loops with no `par`
in them, are built as written and with `--par-auto`, and each mode's checksum
must agree. The last column is the hand-written `par` version's `auto`.

**Apple M4 Max, Metal** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 444 | 93.8 | 778 µs | 2.1 | 2.1 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 70.8 | 2.0 | 1.1 | 1.3 | 1.2 |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 79.9 | 9.0 | 1.4 | 2.0 | 1.9 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 5.2 | 509 µs | 10.8 | 602 µs | 754 µs |

**AMD Ryzen 9 9955HX, its integrated Radeon through Vulkan** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 392 | 40.1 | 9.7 | 9.7 | 9.7 |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 94.3 | 772 µs | 3.4 | 629 µs | 652 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 297 | 21.6 | 5.8 | 5.9 | 5.9 |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 8.3 | 2.5 | 22.6 | 2.3 | 2.3 |

**Windows, RTX 5080 through CUDA** (ms; best of eight runs)

| benchmark | as written | `--par-auto`, all threads | `--par-auto`, GPU | `--par-auto`, `auto` | hand-written `par`, `auto` |
|---|---|---|---|---|---|
| [`mandelbrot`](/compiler/benchmark-sources/#mandelbrot) | 444 | 46.2 | 145 µs | 145 µs | 144 µs |
| [`nbody`](/compiler/benchmark-sources/#nbody) | 118 | 5.3 | 401 µs | 400 µs | 400 µs |
| [`perlin`](/compiler/benchmark-sources/#perlin) | 353 | 18.9 | 498 µs | 491 µs | 489 µs |
| [`saxpy`](/compiler/benchmark-sources/#saxpy) | 10.3 | 3.0 | 16.0 | 3.1 | 3.2 |


## Reproducing

```
python3 benchmark/par/run.py              # the par tables
python3 benchmark/par/run.py --autopar    # the --par-auto tables
python3 benchmark/page.py
```
