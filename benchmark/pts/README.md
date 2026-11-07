# Phoronix Test Suite profiles

Two profiles, each pinned to one release's published archives by SHA-256 in
its `downloads.xml`. The current versions are for xcc 0.9.5.1, on x86-64 Linux
and on arm64 Linux (a Raspberry Pi 5, an Arm server): each downloads the
compiler for the machine it runs on.

| profile | runs | pins |
|---|---|---|
| `xc-par-1.8.0` | the par suite, written in xc | `xcc-linux-0.9.5.1` or `xcc-linux-arm64-0.9.5.1`, `xcc-bench-sources-0.9.5` |
| `xc-c-1.8.0` | plain C programs, xcc against GCC and Clang | `xcc-linux-0.9.5.1` or `xcc-linux-arm64-0.9.5.1`, `xcc-c-bench-sources-0.9.5` |

The benchmark sources did not change in 0.9.5.1, so the profiles use 0.9.5's
archives. On arm64, GCC and Clang build with `-mcpu=native` where x86-64 uses
`-march=native`, which is why the build options are named "native CPU".

The older versions (`xc-par-1.0.0` for 0.8, `xc-c-1.0.0` for 0.87.3, both 1.1.0s
for 0.89, both 1.2.0s for 0.9, both 1.3.0s for 0.9.1, both 1.4.0s for 0.9.2,
both 1.5.0s for 0.9.3, both 1.6.0s for 0.9.4, both 1.7.0s for 0.9.5) stay, and
so do the archives they pin, so a result made with them can still be checked.

## xc-par: the par suite

Downloads the Linux compiler and the benchmark sources, builds the five
programs at `-O3` (mandelbrot, mandel_deep, perlin, nbody, saxpy), and offers
each on one CPU thread, every CPU thread, the GPU, every GPU, every device, or
`auto`. Each result is the best of the program's eight runs; the first run is
reported beside it.

A run is refused when the checksum is wrong, or when a GPU mode ran on the CPU
(no usable GPU): under `XC_PAR_REPORT=1` a GPU run reports "items on the GPU",
or "tiles across" the devices of a set.

    mkdir -p ~/.phoronix-test-suite/test-profiles/local
    cp -R xc-par-1.8.0 ~/.phoronix-test-suite/test-profiles/local/
    phoronix-test-suite benchmark local/xc-par-1.8.0

## xc-c: the C programs

Seven plain C programs (no pragmas or annotations) built by GCC and by Clang
at `-O2` and at `-O3 -march=native`, and by xcc, plain (one thread, `--par-style=cpu`) and with
`--par-style=auto` (every CPU thread, the GPU, every GPU, or `auto`). For comparison
it also builds OpenMP copies, the same files with one `#pragma omp parallel
for` on the timed loop, with GCC and Clang at `-O3 -march=native -fopenmp`. It
needs `gcc` and `clang` (xcc's C path uses clang's front end); Clang's OpenMP
build needs libomp, and without it that one build is reported as not built.

Each program runs at 1, 4 or 16 times its standard work (`BENCH_SCALE`, a
build option), so that a big GPU, or two, has enough to do. saxpy stops at 4x:
16x would need 2 GB of static arrays, and it is bound by memory anyway. The
larger sizes take hours on one CPU thread; they are meant for the parallel
builds. The sources archive holds only the C files (the OpenMP copies in
`openmp/`).

    mkdir -p ~/.phoronix-test-suite/test-profiles/local
    cp -R xc-c-1.8.0 ~/.phoronix-test-suite/test-profiles/local/
    phoronix-test-suite benchmark local/xc-c-1.8.0

## One combination, unattended

`PRESET_OPTIONS_VALUES` takes the options' values, keyed by the profile's name
without its version:

    PRESET_OPTIONS_VALUES="xc-par.bench=mandel_deep;xc-par.device=gpu" \
        phoronix-test-suite batch-run local/xc-par-1.8.0
    PRESET_OPTIONS_VALUES="xc-c.bench=mandelbrot;xc-c.build=xcc-par-gpu;xc-c.size=16" \
        phoronix-test-suite batch-run local/xc-c-1.8.0

## A new release

Each release needs a new version of each profile: the archive names, sizes
and checksums in `downloads.xml`, the names in `install.sh`, `AppVersion` and
the profile `Version` in `test-definition.xml`. The par sources archive is
`git archive --prefix=xcc-bench-sources-<ver>/ v<ver> benchmark`, built from
the release tag; a published archive is never replaced, because a profile pins
its SHA-256.
