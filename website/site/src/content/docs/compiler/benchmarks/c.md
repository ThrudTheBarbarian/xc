---
title: "Performance: C"
description: Plain C built by xcc, against the same C built by GCC and clang, on one thread and on every thread with OpenMP.
---

xcc compiles C ([C programs](/compiler/usage/c-programs/)): it reads a `.c`
file through clang's front end and generates the code itself. These are the
seven par benchmarks as plain C, the same files for every compiler, timed on
one machine: an AMD Ryzen 9 9955HX (32 hardware threads) running Linux, with xcc
0.9.3, GCC 15.2 and clang 21.1.

The two sections below measure different things and are never mixed: one
thread is the code each core runs; every thread adds how a compiler spreads
a loop across the cores.

## One thread

Each compiler builds the plain C with no parallel code: `xcc -O3` against
`gcc -O3 -march=native` and `clang -O3 -march=native`.

Milliseconds; the median of up to fifteen runs.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 8588 | 56190 | 58389 | **6.5× faster** | **6.8× faster** |
| `mandelbrot` | 55.9 | 326 | 334 | **5.8× faster** | **6.0× faster** |
| `md5` | 229 | 386 | 212 | **1.69× faster** | **1.08× slower** |
| `md5_mask` | 188 | 277 | 176 | **1.47× faster** | **1.07× slower** |
| `nbody` | 6.00 | 27.2 | 96.0 | **4.5× faster** | **16.0× faster** |
| `perlin` | 81.7 | 64.3 | 74.8 | **1.27× slower** | **1.09× slower** |
| `saxpy` | 3.33 | 3.29 | 3.56 | **1.01× slower** | **1.07× faster** |
| geometric mean | | | | **2.3× faster** | **2.5× faster** |

The three do not compute quite the same arithmetic. GCC fuses a multiply and
the add that follows it into one fused multiply-add instruction by default
(`-ffp-contract=fast`, outside strict ISO C mode), and clang does so within a
single expression (`-ffp-contract=on`). xcc's build of the C on x86-64 rounds
each multiply and each add on its own, as ISO C describes it, so its results
are the ones the C standard gives. `perlin` is mostly multiply-adds, and that
difference is a large part of its gap.

## Every thread

The same C, run across all 32 threads:

- **xcc:** `xcc -O3 --par-style=auto` on the unchanged files. `--par-style=auto` finds
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
| `mandel_deep` | 351 | 2040 | 2139 | **5.8× faster** | **6.1× faster** |
| `mandelbrot` | 2.44 | 12.2 | 13.1 | **5.0× faster** | **5.4× faster** |
| `md5` | 9.39 | 16.1 | 15.1 | **1.72× faster** | **1.61× faster** |
| `md5_mask` | 8.17 | 12.1 | 13.0 | **1.48× faster** | **1.59× faster** |
| `nbody` | 0.45 | 1.30 | 9.23 | **2.9× faster** | **21× faster** |
| `perlin` | 5.61 | 4.38 | 7.07 | **1.28× slower** | **1.26× faster** |
| `saxpy` | 2.26 | 2.17 | 2.32 | **1.04× slower** | **1.03× faster** |
| geometric mean | | | | **2.1× faster** | **3.0× faster** |

The same programs on GPUs, where `--par-style=auto` sends them by default, are on
[Performance: GPU](/compiler/benchmarks/gpu/).

## A Raspberry Pi 5

The same seven programs on a Raspberry Pi 5 Model B Rev 1.0 (Cortex-A76), its 4 cores, under Raspberry Pi
OS: xcc 0.9.3 cross-built them with `-A arm64-linux`; GCC 14.2 and clang 19.1
built them on the Pi, with the same flags as above.

One thread, milliseconds; the median of up to fifteen runs:

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 50883 | 127670 | 132472 | **2.5× faster** | **2.6× faster** |
| `mandelbrot` | 322 | 770 | 809 | **2.4× faster** | **2.5× faster** |
| `md5` | 2860 | 5154 | 2913 | **1.80× faster** | **1.02× faster** |
| `md5_mask` | 2347 | 4107 | 2386 | **1.75× faster** | **1.02× faster** |
| `nbody` | 95.7 | 108 | 97.2 | **1.13× faster** | **1.02× faster** |
| `perlin` | 403 | 286 | 339 | **1.41× slower** | **1.19× slower** |
| `saxpy` | 29.6 | 30.8 | 30.7 | **1.04× faster** | **1.04× faster** |
| geometric mean | | | | **1.48× faster** | **1.29× faster** |

Every thread (xcc `--par-style=auto`, GCC and clang with OpenMP), milliseconds. xcc
is ahead of both on 5 of the 7:

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 13590 | 31952 | 34010 | **2.4× faster** | **2.5× faster** |
| `mandelbrot` | 86.8 | 193 | 203 | **2.2× faster** | **2.3× faster** |
| `md5` | 715 | 1296 | 732 | **1.81× faster** | **1.02× faster** |
| `md5_mask` | 585 | 1027 | 598 | **1.75× faster** | **1.02× faster** |
| `nbody` | 23.8 | 26.9 | 24.1 | **1.13× faster** | **1.01× faster** |
| `perlin` | 101 | 71.6 | 88.2 | **1.41× slower** | **1.14× slower** |
| `saxpy` | 34.8 | 34.5 | 34.2 | **1.01× slower** | **1.02× slower** |
| geometric mean | | | | **1.45× faster** | **1.27× faster** |

On the Pi, xcc's escape vectoriser runs `mandelbrot`'s and `mandel_deep`'s
per-pixel loop four pixels at a time in NEON, which neither GCC nor clang
vectorises.

## How they were measured

Every program prints its checksum and its best time over its own repeats; each
build was run several times, round-robin with the others, the machine idle
before each round, and the figure is the median of those runs' best times.
The spread from run to run is wide for all three compilers on this machine
(several tens of percent on the shortest programs), which is why one run is
never the figure. Every build of a program gave the same checksum.

The C sources and their OpenMP copies are in
[xcc-c-bench-sources-0.9.3.tar.bz2](/downloads/xcc-c-bench-sources-0.9.3.tar.bz2),
and in the repository's `benchmark/par/c/` and `benchmark/par/c/openmp/`;
`benchmark/par/c_run.py` repeats the whole measurement.
