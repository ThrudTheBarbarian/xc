# Benchmark visualiser

An xc program on UXKit that reads a benchmark contribution, draws it, and moves
contributions to and from the project's corpus. It is the second half of the
[How to DIY](/compiler/benchmarks/how-to-diy/) flow: `benchmark/diy.py` writes
the JSON, and this reads it.

```
benchmark/
  diy.py            measure this machine -> xc-bench-<host>.json
  visualiser/
    Model.xc        the contribution model: JSON, statistics and the filter
    Chart.xc        the chart view: Phoronix-style bars with error bars
    Net.xc          the corpus download and the submission, over https
    Visualiser.xc   the window, the controls and the head-less check
    sample.json     a small contribution to try it with
    Makefile
    package.sh      the prebuilt archives for the site's downloads
    README.dist     the README those archives carry
```

## Build

The program is built against the UXKit **sources**, not the installed library,
because it needs JSON, Http and Socket beside the toolkit. The toolkit's library
and those standard-library modules each declare the Foundation classes, so they
are compiled together in one translation unit.

```sh
make UXKIT=/path/to/uxkit      # the UXKit source directory
make selftest                  # head-less check of the model, against sample.json
make run FILE=../xc-bench-$(hostname).json
```

The Makefile builds `arm64` on macOS (and its ObjC shim). `UXKIT` defaults to
`../../frameworks/uxkit`, which is right inside a full checkout.

The corpus is reached over https, which needs the TLS library at
`/opt/xcc/3p/tls` (`frameworks/3p/tls/install.sh`, with Mbed TLS from
Homebrew). xcc 0.74's TLS library does not load in a GTK program on Linux and
has no Windows build, so the visualiser is built for macOS until it does.

`XC_BENCH_SERVER` points the program at another corpus server, such as a local
`php -S` over `website/site/public`. With it set, `--selftest` also downloads,
submits and downloads again.

`sh package.sh <version>` writes the macOS and sources archives the benchmarks
page links to `website/downloads/`.

## What it does

- **Loads** a contribution JSON, the project's `results.json` files (run.py's
  and par's) and saved corpora; File ▸ Open a contribution, and File ▸ Download
  contributions merges the whole public corpus.
- **Draws** one bar per run, grouped by benchmark, with an error bar for one
  standard deviation over the repeats.
- **Downloads** the corpus: the project's published results and every submitted
  run, so it has something to show with no file open.
- **Filters** by CPU, GPU, suite, device, optimisation level, architecture and
  metric, and can draw the speed-up over the slowest run in each benchmark.
- **Compares compilers** in the Heat map view: a row per benchmark and a column
  per series (xc, C++ (clang), C++ (GCC), Swift, ...) at each architecture and
  level. A cell compares its run with the fastest of the row, or with the
  series picked as the Heat map baseline, in words ("1.50x slower", "2.10x
  faster"), coloured green (better) to red (worse) on a log scale clamped at
  4x. A difference within one standard
  deviation is grey, and the last row is each column's geometric mean. Set Arch
  to `x86_64` and Optimisation to `O3` for one like-for-like table.
- **Shows the parameters**: every filtered run is a row in the table with its
  best time, spread, machine, and the exact environment the run used.
- **Submits** the contribution you opened to the corpus, once the consent box
  is ticked.
- **Checks itself** head-less with `--selftest <file>`, which parses, filters,
  round-trips the JSON, builds the chart rows and merges a corpus.
