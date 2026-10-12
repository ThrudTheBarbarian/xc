---
title: "Build the visualiser"
description: "Step by step from the DIY results JSON to a UXKit program that draws the results as Phoronix-style bars or a heat map of compiler against compiler, filters by CPU, GPU, architecture and more, submits a run to the corpus and downloads the corpus back."
---

This page continues from [How to DIY](/compiler/benchmarks/how-to-diy/). It
builds the **visualiser**: an xc program on [UXKit](/compiler/api/uxkit/) that
reads the results JSON and shows it. It draws one horizontal bar per run in the
Phoronix manner, with the run's parameters and an error bar for the spread over
the repeats, or a heat map with a row per benchmark and a column per compiler.
It filters by CPU, GPU, suite, device, optimisation level and architecture,
sends a run up to the project's corpus, and downloads the corpus back and
merges it.

The whole program is in the repository under `benchmark/visualiser/`. It is
four files: `Model.xc` (the contribution model, JSON, statistics and the
filter), `Chart.xc` (the chart view), `Net.xc` (the corpus and the submission),
and `Visualiser.xc` (the window and the controls).

## What you need

- A Mac with Apple silicon. Linux and Windows builds follow once xcc's TLS
  library runs there (see [Downloads](/compiler/benchmarks/#downloads)).
- xcc 0.74 or later.
- The UXKit sources. The [UXKit library archive](/compiler/downloads/#uxkit-library)
  carries them; in a full checkout they are `frameworks/uxkit/`.
- The Xcode command-line tools, for the small Objective-C shim the toolkit
  builds.
- The TLS library, which the corpus needs for https. It is not in the xcc
  archive. Build and install it from a checkout, with Mbed TLS from Homebrew:

  ```bash
  brew install mbedtls
  sudo sh frameworks/3p/tls/install.sh      # installs /opt/xcc/3p/tls
  ```

The program is built against the UXKit **sources**, not the installed library,
because it needs JSON, Http and Socket beside the toolkit. The toolkit's
library and those standard-library modules each declare the Foundation classes,
so they are compiled together in one place and not imported twice.

## 1. Get the source

The visualiser source ships with the benchmark sources, in
`benchmark/visualiser/`. From the repository:

```bash
cd benchmark/visualiser
```

## 2. Build it

`UXKIT` points at the UXKit source directory. In a full checkout it is already
in the tree, two levels up from here:

```bash
make UXKIT=../../frameworks/uxkit
```

That is also the Makefile's default, so plain `make` builds it in a checkout.
With the [UXKit library archive](/compiler/downloads/#uxkit-library) instead,
point `UXKIT` at wherever you unpacked its sources:

```bash
make UXKIT=/path/to/uxkit
```

The Makefile builds `arm64` on macOS, with the toolkit's Objective-C shim.

The program has a head-less mode that checks the model without a window. Run it
first:

```bash
make selftest          # parses sample.json, filters, round-trips the JSON, prints PASS
```

It parses a contribution, checks that every run carries samples and a good
mean, applies the CPU-only filter, round-trips the contribution through the
JSON writer, builds the chart rows and the heat map, and merges a small corpus.
`PASS` means the model is sound; the window is the next step.

With `XC_BENCH_SERVER` set, the selftest also tests the corpus round trip
against that server: a download, a submission, a second submission refused by
the rate limit, and the download again with the first in it. A local PHP
server over the site's `public/` directory is enough:

```bash
(cd ../../website/site/public && php -S 127.0.0.1:8099) &
XC_BENCH_SERVER=http://127.0.0.1:8099 ./build/visualiser --selftest sample.json
```

## 3. Open a results file

Build from step 2 of the DIY page (`benchmark/xc-bench-<host>.json`), then:

```bash
make run FILE=../xc-bench-$(hostname).json
```

The visualiser also opens the project's own results files directly, so the
figures on the site can be examined without re-measuring:

```bash
./build/visualiser ../v0.74/results.json          # the language suite
./build/visualiser ../par/v0.74/results.json      # par, one contribution per machine
```

A published file holds one best time per point, so its bars carry no error bar;
the spread comes from a contribution, which keeps every repeat.

The window has a rail on the left, the chart, and the table.

- **Data.** **Open JSON...** opens a results file; **Download** fetches the
  corpus (step 5).
- **Filters and view.** **CPU** and **GPU** (one of the values found in the
  data), **Suite** (`par` or `langs`), **Device** (only the devices the data
  holds: one thread, all threads, GPU, Vulkan, auto, plus `CPU only` or
  `GPU only` when both kinds are present), **Optimisation** (`O0`..`O3`),
  **Arch** (`arm64`, `x86_64`, ...), **View** (per benchmark, the summary, or
  the heat map), **Heat map baseline**, and **Metric** (time, or the speed-up
  over the slowest run in each benchmark). Click a filter to pick a value from
  those the data holds; `Any` clears it. A **First run** checkbox draws par's
  one-off-cost figure instead of the best.
- **Publish.** The consent checkbox and **Submit to the corpus** (step 4).
- **Chart.** In **View ▸ Per benchmark**, one row per run, grouped by benchmark
  and sorted fastest first. Each benchmark's rows sit on their own card. A
  row's label names the series and the machine it ran on (`Objective-C  arm64`
  beside `Objective-C  x86-64`), because two machines' times are not
  comparable. The bar is the value; the error bar across it is one standard
  deviation over the repeats; the value is printed at the bar's end. In
  **View ▸ Summary** the chart becomes a grid of panels, one per series, with
  every benchmark along the bottom of each panel as a bar, and every panel on
  one scale. `matrix_mul_f32` is left out of the summary: xcc replaces its loop
  nest with a matrix kernel of its own, so it is tens to hundreds of times
  faster on one side and would flatten every other bar. **View ▸ Heat map** is
  described under [What the chart shows](#what-the-chart-shows).
- **Table.** Every filtered run spelled out: benchmark, series, best time, the
  spread, the machine, and the exact parameters.

Change any filter and the chart and the table follow. The status line under the
table reports what loaded and what the server said.

## 4. Submit your run

The rail's **Publish** pane has the consent checkbox and **Submit to the
corpus**, and the File menu has the same item. A submission sends your
contribution to the project's corpus, so it can be merged with everyone
else's. Only a contribution you opened from your own disk is sent, never one
that came down from the corpus.

The run is sent only when you tick **I agree to publish this run**. That is the
whole consent step: nothing leaves the machine until you tick it and press
Submit. The contribution holds the benchmark numbers and the run parameters;
the machine's CPU and GPU names are part of it, because the comparison is the
point. It holds no name, no email and no path from your machine.

Submission is an https POST of the JSON to `benchmarks/submit.php`, which
checks its shape, stores it in the corpus and answers with the id it filed it
under; the status line shows that id. A submission never replaces an earlier
one: an id already in the corpus gets a new one. One address can submit once
a minute.

## 5. Download the corpus

**Download** (or **File ▸ Download contributions**) reads the corpus
(`benchmarks/corpus.php`, over https) and merges it into the data set in front
of you. The corpus holds two kinds of contribution: the project's own results,
the ones on the [performance page](/compiler/performance/), and every run
people have submitted. So Download is useful with nothing open: it shows the
published results at once, and your run beside them once you open it.

The table's Machine column says which contribution each row came from. Each
contribution carries the machine it was measured on and the version of every
compiler it used, so two rows can be compared or kept apart.

## What the chart shows

- **Time (ms)** is the measured region, the bar's value at its own scale.
- **Speed-up over slowest** divides each run into the slowest run of its
  benchmark, so the slowest is `1.00x` and every other bar is how many times
  faster it is. A par GPU run beside a one-thread run is the interesting row.
- The **error bar** is the mean plus and minus one standard deviation over the
  repeats. A long bar is a noisy run, and the run's own parameters are beside
  it so the cause can be read off.
- The **heat map** has a row per benchmark and a column per compiler at one
  setting (for example `xc` at `x86-64 O3`). Columns are grouped by setting,
  with xc first and the others in alphabetical order. Each cell compares its
  run with a baseline and says which way in words: `1.50x slower`,
  `2.10x faster`, `same`. With **Heat map baseline** at **Fastest**, the
  baseline is the fastest run of the row: that cell reads `fastest` and is
  green, and the others run through yellow to red at 4x slower. With a
  compiler as the baseline, each cell is compared with that compiler at the
  same setting: green is faster, white the same, red slower, full at 4x
  either way. A cell within one standard deviation of its baseline is grey, a
  pair that was not measured is `-`, and the last row is each column's
  geometric mean, without `matrix_mul_f32`.

The bar colours follow the series: xc, Objective-C, C++, GCC and Swift in the
language suite; one thread, all threads, GPU, Vulkan and auto in the par suite.

## Next

The [benchmark index](/compiler/benchmarks/#downloads) has the prebuilt
visualiser for macOS, if you would rather not build it.
