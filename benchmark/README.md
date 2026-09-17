# Benchmarks

The same programs written twice, once in xc and once in Objective-C, both with
automatic reference counting, compiled at four optimisation levels and timed
against each other. Objective-C rather than C, so both sides carry the same
reference-counting obligations and the comparison is of generated code rather
than of memory models.

## Running

```
python3 benchmark/run.py                 # measure, write v0.6/results.json
python3 benchmark/report.py              # render v0.6/index.html
```

Useful flags: `--version` picks the output directory, `--bench` restricts to one
benchmark, `--opt` to one level, `--repeats` sets runs per data point.

## Layout

```
benchmark/
  src/        the benchmark pairs: <name>.xc and <name>.m
  run.py      builds and times every pair, writes results.json
  report.py   renders results.json as a self-contained HTML page
  v0.6/       one directory per compiler version: results and report
```

Sources are shared rather than copied per version, so a later version measures
the same programs and the numbers stay comparable. Only results move into the
version directory.

## How a benchmark is written

Each pair computes the same thing and prints the same checksum. The runner
rejects a pair whose two halves disagree, because a timing comparison between
programs that compute different things means nothing.

Three rules keep the measurements honest, each learned by getting it wrong:

- **The work must depend on something unknown at compile time.** Every
  benchmark seeds its data from `argc`. Without that the whole loop folds to a
  constant and the benchmark times an empty program.
- **Each repetition must differ from the last.** An outer loop that recomputes
  identical values is loop-invariant and gets hoisted away, which looks like a
  large win and is not one.
- **The result must not depend on the order of the arithmetic.** A vectorising
  compiler reorders additions. Float benchmarks use small exact integer values
  and a double accumulator so the sum is exact either way, otherwise the two
  languages disagree on rounding and the checksum fails.

Each program times itself. Both halves call
`clock_gettime(CLOCK_MONOTONIC)`, the same primitive through the same libc, and
print `<checksum> <elapsed_us>`. Sampling inside the program keeps process
startup and data setup out of the figure, so nothing has to be subtracted, and
it removes the jitter of a process launch per sample.

xc reaches libc with a bare prototype, the way the standard library declares
`write`:

```
i32 clock_gettime(i32 clk, u8* ts);
```

The helpers live in `src/include/`, which the pair discovery skips. An earlier
version timed from outside the process and subtracted a startup baseline; both
methods agree to within a few percent, so the change buys precision rather than
a correction.

## Reading the report

The page carries a table of times and ratios, a chart per benchmark, and a table
of which optimisations each target enables. That last table is read from the
compiler's target profiles at render time rather than written down here, so it
cannot drift.

A ratio below 1 means xc was faster. The interesting entries are not the
absolute numbers but the places where a ratio moves sharply between two
optimisation levels, which usually points at one pass helping or hurting.
