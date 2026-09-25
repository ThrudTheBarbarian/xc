---
title: Performance
description: How xcc-compiled code compares with clang on the same programs, measured on nineteen benchmarks across arm64 and x86-64.
---

The compiler is measured against clang on nineteen programs, each written twice:
once in the xtc language and once in Objective-C with ARC, doing the same work
with the same algorithm. Both are built at `-O3` and both print a checksum, and
a run only counts if the two checksums agree.

## Summary

Ratios are xc time divided by clang time, so **lower is faster** and 1.00 means
parity.

| | arm64 | x86-64 |
|---|---|---|
| **Geometric mean** | **0.92** | **1.04** |
| Arithmetic mean | 1.05 | 1.18 |
| Within 0.3x-2.0x of clang | 18 of 19 | 16 of 19 |

On arm64 the suite is slightly faster than clang overall. On x86-64 it is
within four percent.

The geometric mean is the one to read. Averaging ratios arithmetically is
misleading: a benchmark at 2.00x and one at 0.50x are exactly compensating,
and their arithmetic mean is 1.25x while their geometric mean is 1.00x. The
arithmetic figure is given only for completeness.

## Per benchmark

Times are seconds for the timed region, best of five. The figures were measured with a 0.61 build of the self-hosted compiler taken before loop heads on x86-64 were aligned to 32 bytes (see below), so the x86-64 columns do not include that change.

| benchmark | arm64 xc | arm64 clang | ratio | x86-64 xc | x86-64 clang | ratio |
|---|---|---|---|---|---|---|
| `arc_array` | 1.08 | 6.07 | **0.18** | 1.16 | 3.72 | **0.31** |
| `method_call` | 1.00 | 3.04 | **0.33** | 1.35 | 1.90 | **0.71** |
| `string_scan` | 1.06 | 2.77 | **0.38** | 1.62 | 3.15 | **0.51** |
| `arc_alloc` | 1.01 | 1.54 | **0.65** | 0.94 | 2.08 | **0.45** |
| `sieve` | 1.26 | 1.63 | **0.77** | 1.89 | 0.81 | **2.35** |
| `call_depth` | 1.05 | 1.12 | **0.93** | 1.06 | 0.95 | **1.11** |
| `array_sum` | 0.96 | 0.96 | **1.00** | 1.20 | 1.44 | **0.84** |
| `hash_mix` | 1.35 | 1.31 | **1.03** | 1.01 | 1.12 | **0.90** |
| `bit_ops` | 1.44 | 1.31 | **1.09** | 0.98 | 0.97 | **1.00** |
| `branch_mix` | 1.27 | 1.15 | **1.10** | 0.82 | 0.81 | **1.01** |
| `int_accum` | 1.49 | 1.32 | **1.13** | 0.97 | 0.97 | **1.00** |
| `poly_dispatch` | 1.44 | 1.25 | **1.15** | 0.97 | 1.23 | **0.79** |
| `struct_copy` | 1.35 | 1.17 | **1.16** | 1.13 | 0.79 | **1.44** |
| `int_muldiv` | 1.30 | 1.06 | **1.23** | 2.02 | 1.70 | **1.19** |
| `sort_small` | 1.39 | 1.09 | **1.27** | 2.17 | 1.50 | **1.44** |
| `array_map` | 1.71 | 1.20 | **1.43** | 2.11 | 1.56 | **1.35** |
| `float_math` | 1.34 | 0.92 | **1.46** | 1.52 | 0.75 | **2.03** |
| `mem_copy` | 1.90 | 1.09 | **1.74** | 2.11 | 1.06 | **2.00** |
| `matrix_mul` | 1.90 | 1.05 | **1.82** | 2.43 | 1.20 | **2.03** |

The fastest results are where the runtime does the work: `arc_array`,
`method_call` and `string_scan` are reference counting, dynamic dispatch and
string scanning, and those are library code rather than generated code. The
slowest are `sieve`, `float_math` and `matrix_mul` on x86-64, all of which
clang vectorises more aggressively than xcc does.

## What is being compared, and what is not

**The compiler that ships.** The numbers come from the `xcc` in the download.

**Two different Objective-C runtimes.** The clang column is Apple's Foundation
and objc_msgSend on arm64/macOS, and GNUstep with libobjc2 on x86-64/Linux.
Those are different implementations of dispatch and of reference counting, so
the clang times compare within a platform and not across one. The same is true
of the ratios that come from them.

**Timed regions of about one second.** Each benchmark times its own inner loop
rather than the process, and the loops are sized so the region runs for roughly
a second. Shorter runs were tried and abandoned: at a few milliseconds the
measurement is dominated by everything that is not the program.

**Alignment noise on x86-64.** In the build these figures come from, an
individual x86-64 figure could move by ten to fifteen percent between builds whose
hot function was instruction-for-instruction identical, because where a loop
landed relative to a 32-byte fetch boundary depended on how much unrelated code
preceded it. This is why the summary is a geometric mean over nineteen programs
rather than any single number. The released 0.61 aligns every loop head on x86-64
to a 32-byte boundary and the start of `.text` to 64 bytes, which fixes where a
loop lands; see [Optimisation](/compiler/usage/optimization/#per-target-settings).

## Reproducing

The benchmark sources are in `benchmark/src`, one `.xc` and one `.m` per
program, and the runner builds and times both:

```
python3 benchmark/run.py --version v0.61 --opt O3 --repeats 5
```

The x86-64 legs cross-build here and run on a configured Linux host; without
one the runner measures the local platform only and says so. Results land in
`benchmark/<version>/results.json`.
