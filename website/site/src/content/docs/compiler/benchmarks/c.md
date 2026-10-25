---
title: "Performance: C"
description: Plain C built by xcc, against the same C built by GCC and clang, on one thread and on every thread with OpenMP.
---

xcc compiles C ([C programs](/compiler/usage/c-programs/)): it reads a `.c`
file through clang's front end and generates the code itself. These are the
seven par benchmarks as plain C, the same files for every compiler, timed on
one machine: an AMD Ryzen 9 9955HX (32 hardware threads) running Linux, with xcc
0.87, GCC 15.2 and clang 21.1.

The two sections below measure different things and are never mixed: one
thread is the code each core runs; every thread adds how a compiler spreads
a loop across the cores.

## One thread

Each compiler builds the plain C with no parallel code: `xcc -O3` against
`gcc -O3 -march=native` and `clang -O3 -march=native`.

Milliseconds; the median of up to fifteen runs.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 8593 | 56236 | 58434 | **6.5× faster** | **6.8× faster** |
| `mandelbrot` | 56.2 | 326 | 334 | **5.8× faster** | **5.9× faster** |
| `md5` | 229 | 387 | 212 | **1.69× faster** | **1.08× slower** |
| `md5_mask` | 189 | 277 | 176 | **1.47× faster** | **1.07× slower** |
| `nbody` | 6.02 | 27.3 | 96.1 | **4.5× faster** | **16.0× faster** |
| `perlin` | 84.1 | 64.4 | 74.8 | **1.31× slower** | **1.12× slower** |
| `saxpy` | 3.42 | 3.35 | 3.59 | **1.02× slower** | **1.05× faster** |
| geometric mean | | | | **2.3× faster** | **2.4× faster** |

## Every thread

The same C, run across all 32 threads:

- **xcc:** `xcc -O3 --par-auto` on the unchanged files. `--par-auto` finds
  the loops that can run in parallel and runs them as `par` blocks; here they
  are kept on the CPU (`XC_PAR=cpu`), so this is CPU against CPU.
- **GCC and clang:** `-O3 -march=native -fopenmp`, on a copy of each file
  with one `#pragma omp parallel for` line (with its `reduction` clause where
  the loop has one) before the timed loop: the work a programmer does to get
  OpenMP's threads.

Milliseconds; the median of up to fifteen runs. xcc is ahead of both on
5 of the 7.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 354 | 2050 | 2147 | **5.8× faster** | **6.1× faster** |
| `mandelbrot` | 2.74 | 12.3 | 13.5 | **4.5× faster** | **4.9× faster** |
| `md5` | 14.0 | 16.1 | 15.2 | **1.15× faster** | **1.09× faster** |
| `md5_mask` | 9.97 | 12.0 | 13.4 | **1.21× faster** | **1.34× faster** |
| `nbody` | 0.64 | 1.28 | 9.78 | **2.0× faster** | **15.3× faster** |
| `perlin` | 6.34 | 4.37 | 7.03 | **1.45× slower** | **1.11× faster** |
| `saxpy` | 2.32 | 2.19 | 2.25 | **1.06× slower** | **1.03× slower** |
| geometric mean | | | | **1.74× faster** | **2.6× faster** |

The same programs on GPUs, where `--par-auto` sends them by default, are on
[Performance: GPU](/compiler/benchmarks/gpu/).

## How they were measured

Every program prints its checksum and its best time over its own repeats; each
build was run several times, round-robin with the others, the machine idle
before each round, and the figure is the median of those runs' best times.
The spread from run to run is wide for all three compilers on this machine
(several tens of percent on the shortest programs), which is why one run is
never the figure. Every build of a program gave the same checksum.

The C sources and their OpenMP copies are in
[xcc-c-bench-sources-0.87.tar.bz2](/downloads/xcc-c-bench-sources-0.87.tar.bz2),
and in the repository's `benchmark/par/c/` and `benchmark/par/c/openmp/`;
`benchmark/par/c_run.py` repeats the whole measurement.
