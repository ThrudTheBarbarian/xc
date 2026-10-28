---
title: "Performance: C"
description: Plain C built by xcc, against the same C built by GCC and clang, on one thread and on every thread with OpenMP.
---

xcc compiles C ([C programs](/compiler/usage/c-programs/)): it reads a `.c`
file through clang's front end and generates the code itself. These are the
seven par benchmarks as plain C, the same files for every compiler, timed on
one machine: an AMD Ryzen 9 9955HX (32 hardware threads) running Linux, with xcc
0.87.3, GCC 15.2 and clang 21.1.

The two sections below measure different things and are never mixed: one
thread is the code each core runs; every thread adds how a compiler spreads
a loop across the cores.

## One thread

Each compiler builds the plain C with no parallel code: `xcc -O3` against
`gcc -O3 -march=native` and `clang -O3 -march=native`.

Milliseconds; the median of up to fifteen runs.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 8597 | 56246 | 58459 | **6.5× faster** | **6.8× faster** |
| `mandelbrot` | 56.2 | 327 | 334 | **5.8× faster** | **5.9× faster** |
| `md5` | 229 | 387 | 212 | **1.69× faster** | **1.08× slower** |
| `md5_mask` | 189 | 278 | 176 | **1.47× faster** | **1.07× slower** |
| `nbody` | 6.02 | 27.3 | 96.1 | **4.5× faster** | **16.0× faster** |
| `perlin` | 84.4 | 64.4 | 74.9 | **1.31× slower** | **1.13× slower** |
| `saxpy` | 3.46 | 3.36 | 3.61 | **1.03× slower** | **1.04× faster** |
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
| `mandel_deep` | 353 | 2050 | 2142 | **5.8× faster** | **6.1× faster** |
| `mandelbrot` | 3.09 | 12.3 | 13.6 | **4.0× faster** | **4.4× faster** |
| `md5` | 13.8 | 16.1 | 15.1 | **1.16× faster** | **1.09× faster** |
| `md5_mask` | 8.31 | 12.0 | 13.4 | **1.44× faster** | **1.61× faster** |
| `nbody` | 0.51 | 1.29 | 9.76 | **2.5× faster** | **19.3× faster** |
| `perlin` | 5.98 | 4.34 | 7.01 | **1.38× slower** | **1.17× faster** |
| `saxpy` | 2.30 | 2.15 | 2.30 | **1.07× slower** | **the same** |
| geometric mean | | | | **1.82× faster** | **2.7× faster** |

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
[xcc-c-bench-sources-0.87.3.tar.bz2](/downloads/xcc-c-bench-sources-0.87.3.tar.bz2),
and in the repository's `benchmark/par/c/` and `benchmark/par/c/openmp/`;
`benchmark/par/c_run.py` repeats the whole measurement.
