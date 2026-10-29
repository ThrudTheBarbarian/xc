---
title: "Performance: C"
description: Plain C built by xcc, against the same C built by GCC and clang, on one thread and on every thread with OpenMP.
---

xcc compiles C ([C programs](/compiler/usage/c-programs/)): it reads a `.c`
file through clang's front end and generates the code itself. These are the
seven par benchmarks as plain C, the same files for every compiler, timed on
one machine: an AMD Ryzen 9 9955HX (32 hardware threads) running Linux, with xcc
0.88, GCC 15.2 and clang 21.1.

The two sections below measure different things and are never mixed: one
thread is the code each core runs; every thread adds how a compiler spreads
a loop across the cores.

## One thread

Each compiler builds the plain C with no parallel code: `xcc -O3` against
`gcc -O3 -march=native` and `clang -O3 -march=native`.

Milliseconds; the median of up to fifteen runs.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 8604 | 56245 | 58452 | **6.5× faster** | **6.8× faster** |
| `mandelbrot` | 56.2 | 327 | 334 | **5.8× faster** | **6.0× faster** |
| `md5` | 229 | 387 | 212 | **1.69× faster** | **1.08× slower** |
| `md5_mask` | 189 | 278 | 176 | **1.47× faster** | **1.07× slower** |
| `nbody` | 6.02 | 27.3 | 96.1 | **4.5× faster** | **16.0× faster** |
| `perlin` | 82.1 | 64.4 | 74.9 | **1.27× slower** | **1.10× slower** |
| `saxpy` | 3.45 | 3.39 | 3.60 | **1.02× slower** | **1.04× faster** |
| geometric mean | | | | **2.3× faster** | **2.5× faster** |

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
| `mandel_deep` | 355 | 2050 | 2140 | **5.8× faster** | **6.0× faster** |
| `mandelbrot` | 2.91 | 12.3 | 12.5 | **4.2× faster** | **4.3× faster** |
| `md5` | 9.50 | 16.0 | 15.5 | **1.69× faster** | **1.63× faster** |
| `md5_mask` | 9.04 | 12.0 | 13.1 | **1.33× faster** | **1.45× faster** |
| `nbody` | 0.60 | 1.28 | 9.78 | **2.1× faster** | **16.2× faster** |
| `perlin` | 5.84 | 4.35 | 6.83 | **1.34× slower** | **1.17× faster** |
| `saxpy` | 2.37 | 2.18 | 2.29 | **1.09× slower** | **1.03× slower** |
| geometric mean | | | | **1.87× faster** | **2.7× faster** |

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
[xcc-c-bench-sources-0.88.tar.bz2](/downloads/xcc-c-bench-sources-0.88.tar.bz2),
and in the repository's `benchmark/par/c/` and `benchmark/par/c/openmp/`;
`benchmark/par/c_run.py` repeats the whole measurement.
