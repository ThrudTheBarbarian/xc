---
title: "How to DIY: run the benchmarks yourself"
description: "From a fresh Ubuntu to your own results JSON: install xcc, get the benchmark sources, run the par and language suites with the exact parameters each target uses, and read the JSON."
---

This page runs the benchmarks behind the [performance](/compiler/performance/)
figures on your own machine, from a freshly installed Ubuntu to a results file
in JSON. It ends where [Build the visualiser](/compiler/benchmarks/build-the-visualiser/)
begins: that page turns the JSON into graphs.

Two suites are published.

- The **par suite** is four programs — `mandelbrot`, `perlin`, `nbody`, `saxpy`
  — each written as one `par` block that runs on one CPU thread, on every CPU
  thread, or on the GPU. It needs only the compiler. This is the suite to run
  first, and the one the visualiser's CPU and GPU filters are for.
- The **language suite** is each benchmark in `benchmark/src/`, written in xc,
  Objective-C, C++, and Swift, measured at four optimisation levels. It needs
  the other toolchains as well, so this page marks it optional.

Every run records its checksum. A run counts only when the checksums match,
because a timing between programs that compute different things means nothing.

## What you need

- A 64-bit x86-64 Ubuntu. Tested on 26.04. A GPU is optional; without a
  usable one the GPU modes are skipped, and the collector says why.
- xcc 0.8 for Linux, from the [downloads](/compiler/downloads/) page.
- Python 3, which Ubuntu ships, for the collector.
- For the language suite only: `clang`, `clang++`, `g++`, and `swiftc`, plus
  GNUstep for the Objective-C half. A toolchain that is absent is skipped, not
  failed.

## 1. Install xcc

The Linux archive is a static musl build, so it runs as-is. It is compressed
with bzip2, which a minimal Ubuntu may not have; if `tar` says it cannot run
`bzip2`, install it first with `sudo apt-get install -y bzip2`.

```bash
tar xjf xcc-linux-0.8.tar.bz2
export PATH="$PWD/xcc-linux-0.8/bin:$PATH"
xcc -v
```

The compiler finds its libraries relative to its own binary, so the directory
can be moved anywhere. Put the `export` in your shell profile to keep it. The
collector also finds a compiler installed as `/opt/xcc/0.8/`, with no `PATH`
change.

### Set up the GPU (optional)

On Linux xc reaches the GPU through Vulkan, so the machine needs the Vulkan
loader and a Vulkan driver. A desktop Ubuntu usually has both; a minimal or
server install does not.

```bash
sudo apt-get install -y libvulkan1 mesa-vulkan-drivers vulkan-tools
vulkaninfo --summary        # lists each GPU and its driver
```

- **AMD and Intel:** `mesa-vulkan-drivers` is the driver (RADV for AMD, ANV for
  Intel). Nothing else is needed; ROCm is not used.
- **NVIDIA:** install NVIDIA's own driver (`sudo ubuntu-drivers install`),
  which carries its Vulkan driver. `libvulkan1` is still needed.
- **Over ssh, or with no desktop session:** the account needs access to the
  GPU device, which a desktop login grants and ssh does not. Add it to the
  `render` group and log in again:
  `sudo usermod -aG render $USER`.

`vulkaninfo --summary` should name the GPU itself. If it lists only
`llvmpipe`, that is Mesa's software device running on the CPU, and the GPU is
not reachable yet.

To check that a program really reaches the GPU (with the sources from step
2), run it with `XC_PAR_REPORT=1`. It names the device it uses; a line saying
`a block stays on the CPU` gives the reason it could not use the GPU.

```bash
xcc -O3 -o mandelbrot benchmark/par/mandelbrot.xc
XC_PAR=gpu XC_PAR_REPORT=1 ./mandelbrot
# par: Vulkan device is vulkan:… (RADV …)
```

On macOS the GPU is reached through Metal and needs nothing installed. On
Windows an NVIDIA GPU needs only NVIDIA's driver, which carries both CUDA and
Vulkan.

## 2. Get the benchmark sources

The sources live in the project repository under `benchmark/`. Clone the
repository, or unpack the [benchmark sources](/compiler/benchmarks/#downloads)
archive:

```bash
git clone https://github.com/ThrudTheBarbarian/xc.git
cd xc
```

`benchmark/diy.py` is the collector. It builds and times the programs and
writes one contribution JSON; it does not touch the network.

## 3. The par suite

`diy.py` builds each program with the shipped compiler and runs it in every
mode the machine has. Each program runs its `par` block eight times and prints
`<checksum> <best_us> <first_us>`; the best of the eight is the figure, and the
first is printed because it carries one-off costs (a GPU builds its kernel on
the first run). The collector repeats the whole process five times by default
and keeps every repeat, so the spread can be drawn and not only the best.

```bash
python3 benchmark/diy.py --suite par
```

It writes `benchmark/xc-bench-<host>.json`. Add `--repeats 7` for more samples,
or `--no-gpu` to leave the GPU out. Before each GPU mode the collector makes
one run with `XC_PAR_REPORT=1`. If the block would stay on the CPU, it skips
that mode and prints the reason, so a CPU time is never recorded as a GPU one.

The exact parameters, per run, are:

| mode | environment | meaning |
|---|---|---|
| one thread | `XC_PAR=cpu XC_PAR_THREADS=1` | every `par` block on a single CPU thread |
| all threads | `XC_PAR=cpu` | every CPU thread |
| GPU | `XC_PAR=gpu` | the GPU (CUDA on x86-64 Windows, Metal on macOS, Vulkan on Linux) |
| Vulkan | `XC_PAR=gpu XC_PAR_GPU=vulkan` | the GPU through Vulkan, on Windows |
| auto | (none) | the block measures both devices and picks |

The build is one command per program, at `-O3`:

```bash
xcc -O3 -o build/diy/par_nbody benchmark/par/nbody.xc
XC_PAR=cpu XC_PAR_THREADS=1 ./build/diy/par_nbody   # prints "<checksum> <best_us> <first_us>"
```

The four programs must print these checksums:

| benchmark | checksum |
|---|---|
| `mandelbrot` | `199` |
| `nbody` | `42` |
| `perlin` | `243` |
| `saxpy` | `3011510272` |

A different checksum means the program was not the one being measured, so the
timing is refused.

### With the Phoronix Test Suite

The par suite is also a [Phoronix Test Suite](https://www.phoronix-test-suite.com/)
test profile, `benchmark/pts/xc-par-1.0.0/`. It downloads the published Linux
compiler and benchmark sources, builds the four programs, and offers each one
on one CPU thread, every CPU thread, the GPU, every GPU, every device, or
`auto`. Each result is the best of the program's eight runs, and the first run
is reported beside it. The profile checks the checksum, and it refuses a GPU
mode that would run on the CPU.

```bash
mkdir -p ~/.phoronix-test-suite/test-profiles/local
cp -R benchmark/pts/xc-par-1.0.0 ~/.phoronix-test-suite/test-profiles/local/
phoronix-test-suite benchmark local/xc-par-1.0.0
```

## 4. Comparing against other languages

This suite measures each program in `benchmark/src/` written five times: in xc,
in Objective-C, in C++ built twice (with clang and with GCC), and in Swift, as
the comparison. The same algorithm and the same data are used on every side, and
every program prints the same checksum, so the numbers compare generated code and
not memory models.

`diy.py` builds every program it can. A language whose compiler is missing is
skipped, so a machine without Swift still measures the rest. Each program prints
`<checksum> <elapsed_us>`, timed inside the process, so process start-up is
outside the figure. The collector repeats each program, checks that the
languages agree on the checksum, and keeps every sample.

Set up a language, then add it. Each section below gives what to install, the
flags for a level `<opt>`, and what the flags do.

### xc

xc is the program under test, so its compiler is already installed in step 1.
Nothing else is needed.

```bash
xcc -I benchmark/src -O3 -o out benchmark/src/<name>.xc
```

`-<opt>` is `-O0`, `-O1`, `-O2` or `-O3`. By default xcc builds each vectorised
function for every instruction set the machine has (`-msimd=auto`) and picks one
when the program starts, so there is no `-march` flag to pass.

### Objective-C (clang, with the GNUstep runtime)

On Linux, Objective-C is clang against **libobjc2** and **gnustep-base**, the
pair the project's own x86-64 runs use. Install clang and GNUstep:

```bash
sudo apt-get update
sudo apt-get install -y clang gnustep-make gnustep-base-runtime libgnustep-base-dev
```

libobjc2 is the reference-counting runtime clang needs here. If your
distribution does not package it, build it from the GNUstep project and install
it beside gnustep-base.

```bash
clang -fobjc-arc -fobjc-runtime=gnustep-2.2 -I/opt/gnustep/include -I benchmark/src \
      -O3 -march=native -L/opt/gnustep/lib -lobjc -lgnustep-base -o out <name>.m
```

- `-fobjc-arc` turns on automatic reference counting, the same memory model as
  xc, so both sides carry the same retain and release obligations and the
  comparison is of generated code.
- `-fobjc-runtime=gnustep-2.2` selects libobjc2's ABI rather than the older GNU
  runtime.
- `-march=native` gives clang the machine's whole instruction set, as xc gets by
  default.
- `-I` and `-L` point at GNUstep. If the program cannot find the libraries when
  it runs, put them on the search path first: `export LD_LIBRARY_PATH=/opt/gnustep/lib`.
- This is the Linux form. On macOS, Objective-C uses Apple's Foundation: drop
  `-fobjc-runtime`, the GNUstep include and library paths and the two `-l`
  libraries, and add `-framework Foundation` with `-mcpu=native`.

### C++ (clang)

C++ needs clang, which the Objective-C step already installs.

```bash
sudo apt-get install -y clang
```

```bash
clang++ -std=c++17 -O3 -march=native -I benchmark/src -o out benchmark/src/<name>.cpp
```

- `-std=c++17` matches the source, which uses `std::array` and `std::shared_ptr`.
- `-march=native` gives clang the machine's whole instruction set.
- The C++ sources are written to carry the same reference-counting obligation as
  the xc and Objective-C sides, so the comparison stays about generated code.

### C++ (GCC)

GCC builds the same C++ source a second time, with the other large compiler.

```bash
sudo apt-get install -y g++
```

```bash
g++ -std=c++17 -O3 -march=native -I benchmark/src -o out benchmark/src/<name>.cpp
```

- The source is the same as the clang column, so a difference between the two
  C++ rows is a difference between the compilers and not the language.
- On macOS `g++` is Apple's clang under another name, so the collector skips
  this column there. The published runs measure GCC on x86-64 Linux.

### Swift

Install the Swift toolchain for your Ubuntu version from
[swift.org](https://www.swift.org/install/linux/), and put its `bin/` on `PATH`.
`swiftc --version` should then answer.

```bash
swiftc -O -target-cpu native -parse-as-library -o out \
       benchmark/src/include/bench_time.swift benchmark/src/<name>.swift
```

- `swiftc` has only two useful levels, `-Onone` and `-O`, so every optimising
  level from `O1` to `O3` builds with `-O`, and `O0` builds with `-Onone`.
- `-parse-as-library` makes each program an `@main` struct, so its counters are
  locals of `main` as they are in the C versions and not globals.
- `-target-cpu native` gives Swift the machine's instruction set.
- `-O` also asks for whole-module optimisation, which is what a release Swift
  build uses.

Then run the suite:

```bash
python3 benchmark/diy.py --suite langs
python3 benchmark/diy.py --suite langs --opt O3    # one level, quicker
```

The compilers' versions are recorded in the JSON, so a contribution says what it
was measured against.

## 5. Read the JSON

Either suite writes one contribution, schema `xc-bench/1`. It opens with the
machine and the toolchains, then one entry per run:

```json
{
  "schema": "xc-bench/1",
  "id": "6f9c...",
  "collected": "2026-10-10T09:30:00Z",
  "machine": { "os": "Ubuntu 26.04.1 LTS", "arch": "x86_64",
               "cpu": "Example 16-core x86-64 CPU",
               "gpu": "Example GPU (CUDA)", "memory_mb": 65536 },
  "toolchains": { "xcc": "0.8", "clang": "...", "gcc": "...", "swiftc": "..." },
  "repeats": 5,
  "runs": [
    { "suite": "par", "benchmark": "nbody", "target": "xc", "device": "gpu",
      "opt": "O3", "arch": "x86_64",
      "params": { "XC_PAR": "gpu", "opt": "O3" },
      "samples_us": [1080, 1051, 1066, 1058, 1062],
      "best_us": 1051, "first_us": 202245, "checksum": "42" }
  ]
}
```

`samples_us` is every repeat's time in microseconds, so the visualiser can draw
the spread; `best_us` is the fastest; `first_us` (par only) is the first run,
with its one-off costs. `params` is the exact environment that run used.

The file can be read with any JSON tool, or turned into graphs by hand. To see
it as a chart and to move it into the published corpus,
[build the visualiser](/compiler/benchmarks/build-the-visualiser/).

## 6. What you should see

Every program prints a checksum, and the checksum is the same in every
language. That is the rule that makes a timing between them meaningful: the five
programs for one benchmark do the same work, and the same work gives the same
checksum. A different number means a build is not measuring the same thing, and
the timing is refused.

So a run looks like this, and the second number is the time and moves from run
to run:

```
$ ./int_accum.objc x
579066029 1259289
$ ./int_accum.xc x
579066029 1198201
```

The checksums for the language benchmarks, at any optimisation level and in any
language, are:

| benchmark | checksum | benchmark | checksum |
|---|---|---|---|
| `arc_alloc` | 206027777 | `int_muldiv` | 1297506048 |
| `arc_array` | 1219002368 | `matrix_mul_f32` | 189955312 |
| `array_map` | 3484696576 | `matrix_mul` | 186162176 |
| `array_sum` | 3738828800 | `mem_copy` | 1238237824 |
| `baseline` | 2 | `method_call` | 271517696 |
| `bit_ops` | 3629374464 | `poly_dispatch` | 1538534913 |
| `branch_mix` | 4177264640 | `sieve` | 154350000 |
| `call_depth` | 2825455104 | `sort_small` | 615912388 |
| `float_math` | 1917359744 | `string_scan` | 1287843840 |
| `hash_mix` | 3811172047 | `struct_copy` | 3027028224 |
| `int_accum` | 579066029 | | |

`baseline` prints `2` and a time of `0`: it runs no work, which shows that
start-up is outside the measured region. The four `par` checksums are in
[step 3](#3-the-par-suite).

These values are for the shipped sources. If a benchmark source changes, its
checksum changes with it, and `run.py` records which releases are comparable.

If every language prints its benchmark's row, the suite ran clean, and the JSON
holds a valid comparison. That file is the input to the visualiser:

[Build the visualiser](/compiler/benchmarks/build-the-visualiser/)
