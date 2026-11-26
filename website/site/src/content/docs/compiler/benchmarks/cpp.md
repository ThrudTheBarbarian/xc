---
title: "Performance: C++"
description: Plain C++ built by xcc, against the same C++ built by g++ and clang++, on one thread and on every thread with OpenMP.
---

xcc compiles C++ ([C++ programs](/compiler/usage/cpp-programs/)): it reads a
`.cpp` file through clang's front end, takes its loops and generates their
code itself. These are the seven par benchmarks as plain C++ (`std::vector`,
`std::array`, templates, the loops in functions of their own), the same files
for every compiler, timed on an AMD Ryzen 9 9955HX (32 hardware threads) running
Linux, with xcc 1.0.3, GCC 15.2 and clang 21.1.

Each machine has two tables, which measure different things and are never
mixed: one thread is the code each core runs; every thread adds how a
compiler spreads a loop across the cores.

## AMD Ryzen 9 9955HX

### One thread

Each compiler builds the plain C++ with no parallel code: `xcc -O3` against
`g++ -O3 -march=native` and `clang++ -O3 -march=native`, all `-std=c++17`.

Milliseconds; the median of up to fifteen runs.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 57241 | 56107 | 58412 | **1.02× slower** | **1.02× faster** |
| `mandelbrot` | 343 | 326 | 334 | **1.05× slower** | **1.03× slower** |
| `md5` | 2543 | 386 | 212 | **6.6× slower** | **12.0× slower** |
| `md5_mask` | 1924 | 275 | 176 | **7.0× slower** | **11.0× slower** |
| `nbody` | 96.3 | 6.02 | 95.7 | **16.0× slower** | **1.01× slower** |
| `perlin` | 79.7 | 64.0 | 73.5 | **1.25× slower** | **1.09× slower** |
| `saxpy` | 4.62 | 5.00 | 4.95 | **1.08× faster** | **1.07× faster** |
| geometric mean | | | | **2.6× slower** | **2.0× slower** |

### Every thread

The same C++, run across all 32 threads:

- **xcc:** `xcc -O3 --par-style=auto` on the unchanged files, its blocks kept
  on the CPU (`XC_PAR=cpu`), so this is CPU against CPU.
- **GCC and clang:** `-O3 -march=native -fopenmp`, on a copy of each file
  with a `#pragma omp parallel for` line (with its `reduction` clause where the
  loop has one) before each loop that does the work.

Milliseconds; the median of up to fifteen runs. xcc is ahead of both on
1 of the 7.

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 2443 | 2209 | 2231 | **1.11× slower** | **1.09× slower** |
| `mandelbrot` | 14.7 | 37.1 | 37.0 | **2.5× faster** | **2.5× faster** |
| `md5` | 213 | 16.2 | 15.2 | **13.2× slower** | **14.1× slower** |
| `md5_mask` | 167 | 12.1 | 12.9 | **13.8× slower** | **12.9× slower** |
| `nbody` | 96.6 | 1.30 | 9.97 | **74× slower** | **9.7× slower** |
| `perlin` | 78.8 | 4.48 | 7.23 | **17.6× slower** | **10.9× slower** |
| `saxpy` | 2.21 | 2.17 | 2.38 | **1.02× slower** | **1.07× faster** |
| geometric mean | | | | **5.2× slower** | **3.6× slower** |

## Raspberry Pi 5

The same seven programs on a Raspberry Pi 5 Model B Rev 1.0 (Cortex-A76), its 4 cores: xcc 1.0.3
cross-built them with `-A arm64-linux`; GCC 14.2 and clang 19.1 built them on the Pi,
with the same flags as above.

### One thread

Milliseconds; the median of up to fifteen runs:

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 140518 | 127766 | 135950 | **1.10× slower** | **1.03× slower** |
| `mandelbrot` | 856 | 774 | 821 | **1.10× slower** | **1.04× slower** |
| `md5` | 2928 | 5154 | 2929 | **1.76× faster** | **the same** |
| `md5_mask` | 2378 | 4126 | 2377 | **1.73× faster** | **the same** |
| `nbody` | 145 | 92.7 | 95.7 | **1.56× slower** | **1.51× slower** |
| `perlin` | 310 | 298 | 339 | **1.04× slower** | **1.10× faster** |
| `saxpy` | 29.6 | 30.1 | 30.2 | **1.02× faster** | **1.02× faster** |
| geometric mean | | | | **1.07× faster** | **1.05× slower** |

### Every thread

xcc `--par-style=auto`, GCC and clang with OpenMP, milliseconds. xcc is ahead
of both on 1 of the 7:

| benchmark | xcc | GCC | clang | xcc against GCC | xcc against clang |
|---|---|---|---|---|---|
| `mandel_deep` | 37341 | 32206 | 33148 | **1.16× slower** | **1.13× slower** |
| `mandelbrot` | 226 | 370 | 393 | **1.63× faster** | **1.74× faster** |
| `md5` | 3183 | 1293 | 729 | **2.5× slower** | **4.4× slower** |
| `md5_mask` | 3574 | 1027 | 593 | **3.5× slower** | **6.0× slower** |
| `nbody` | 145 | 27.0 | 23.9 | **5.4× slower** | **6.0× slower** |
| `perlin` | 306 | 75.6 | 85.7 | **4.0× slower** | **3.6× slower** |
| `saxpy` | 37.4 | 37.1 | 36.8 | **1.01× slower** | **1.01× slower** |
| geometric mean | | | | **2.0× slower** | **2.3× slower** |

## How they were measured

As for [Performance: C](/compiler/benchmarks/c/): every program prints its
checksum and its best time over its own repeats; each build was run several
times, round-robin with the others, the machine idle before each round, and
the figure is the median of those runs' best times. Every build of a program
gave the same checksum, the same as the C version's.

The C++ sources and their OpenMP copies are in the repository's
`benchmark/par/cpp/` and `benchmark/par/cpp/openmp/`;
`benchmark/par/c_run.py --lang c++` repeats the whole measurement.
