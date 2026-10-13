---
title: Benchmarks
description: The published benchmark suites, the JSON they write, the visualiser that draws and compares them, its download, and the two step-by-step guides.
---

The [performance page](/compiler/performance/) is measured on the project's own
machines. This section is the same benchmarks you can run and see yourself: two
step-by-step guides, a contribution JSON that holds a machine's results, and a
program that turns the JSON into graphs and merges runs from other machines.

## The two guides

- [**How to DIY**](/compiler/benchmarks/how-to-diy/) starts from a freshly
  installed Ubuntu, installs xcc, gets the benchmark sources, runs the par and
  language suites with the exact parameters each target uses, and writes a
  results JSON.
- [**Build the visualiser**](/compiler/benchmarks/build-the-visualiser/) builds
  the xc/UXKit program that reads the JSON, draws it as Phoronix-style bars with
  error bars or as a heat map of compiler against compiler, filters by CPU, GPU,
  suite, device, optimisation level and architecture, submits a run to the
  corpus and downloads the corpus back.

## The benchmarks

| suite | programs | needs |
|---|---|---|
| `par` | `mandelbrot`, `perlin`, `nbody`, `saxpy` — one `par` block, on one CPU thread, every CPU thread, or the GPU | xcc only |
| `langs` | each program in `benchmark/src/`, in xc, Objective-C, C++ and Swift at `O0`..`O3` | xcc, clang, g++, Swift, GNUstep |

The `par` sources are `benchmark/par/*.xc`; the language pairs are
`benchmark/src/<name>.xc` and `<name>.m`. The collector is
`benchmark/diy.py`. The same sources, in every language, are on the
[benchmark sources](/compiler/benchmark-sources/) page.

## The contribution JSON

One run of one suite on one machine is a **contribution**, schema `xc-bench/1`.
It carries the machine (OS, CPU, GPU, memory), the version of every compiler
used, and one entry per run: the benchmark, the target, the optimisation level,
the exact `params`, every repeat's time in `samples_us`, the `best_us`, and the
checksum. The [DIY page](/compiler/benchmarks/how-to-diy/#5-read-the-json) shows
a full example. A contribution holds no personal data.

## Downloads

The visualiser is written in xc and built with UXKit.

| Platform | Visualiser | Size |
| --- | --- | --- |
| macOS (Apple silicon) | [xcc-benchviz-0.75-osx.tar.bz2](/downloads/xcc-benchviz-0.75-osx.tar.bz2) | 970 KB |
| Linux (x86-64, GTK 4) | [xcc-benchviz-0.75-linux.tar.bz2](/downloads/xcc-benchviz-0.75-linux.tar.bz2) | 1.0 MB |
| Windows (x86-64) | [xcc-benchviz-0.75-win64.zip](/downloads/xcc-benchviz-0.75-win64.zip) | 941 KB |
| Benchmark sources (any host) | [xcc-bench-sources-0.8.tar.bz2](/downloads/xcc-bench-sources-0.8.tar.bz2) | 94 KB |

Unpack the archive and run `./visualiser` (`visualiser.exe` on Windows). The
archive carries the libraries the program loads beside it: the TLS library and,
on macOS and Linux, the toolkit's shim.

- macOS: the archive is not notarised. If macOS refuses to open it, run
  `xattr -dr com.apple.quarantine .` in the unpacked directory once.
- Linux: the machine needs GTK 4 (`libgtk-4-1` on Ubuntu).
- Windows: the program is new and not signed, so Chrome may say the file
  "isn't commonly downloaded"; choose **Download suspicious file**. Windows may
  then say it "protected your PC" on the first run; choose **More info**, then
  **Run anyway**. https certificates are checked against the Windows
  certificate store.

The benchmark sources archive is the `benchmark/` tree: the suite sources, the
collector, and the visualiser source.

## The corpus

Contributions submitted through the visualiser are merged into a public
corpus and served back to every visualiser that asks, together with the
project's own results from the [performance page](/compiler/performance/).
The corpus is read at `/benchmarks/corpus.php` and written through
`/benchmarks/submit.php`, both over https. A run is added only after the person
running it ticks **I agree to publish this run**. A submission never replaces
an earlier one, and one address can submit once a minute.

The corpus is open data: it holds benchmark times, the run parameters, and the
machine's CPU and GPU names, and nothing else.
