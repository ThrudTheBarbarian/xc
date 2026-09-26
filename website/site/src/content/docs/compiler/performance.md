---
title: Performance
description: How xcc-compiled code compares with clang on the same programs, measured on nineteen benchmarks across arm64 and x86-64.
---

The compiler is measured against clang on nineteen programs, each written twice:
once in the xc language and once in Objective-C with ARC, doing the same work
with the same algorithm. Both are built at `-O3` and both print a checksum, and
a run only counts if the two checksums agree.

## Summary

Ratios are xcc time divided by clang time, so **lower is faster** and 1.00 means
parity.

| | arm64 | x86-64 |
|---|---|---|
| **Geometric mean** | **0.93** | **1.03** |
| Arithmetic mean | 1.06 | 1.15 |
| Within 0.3x-2.0x of clang | 18 of 19 | 16 of 19 |

On arm64 the suite is slightly faster than clang overall. On x86-64 it is
within three percent.

The geometric mean is the one to read. Averaging ratios arithmetically is
misleading: a benchmark at 2.00x and one at 0.50x are exactly compensating,
and their arithmetic mean is 1.25x while their geometric mean is 1.00x. The
arithmetic figure is given only for completeness.

## Per benchmark

Times are seconds for the timed region, best of five, measured with the released 0.62 `xcc`. Each run waits until the machine doing the timing is otherwise idle.

| benchmark | arm64 xcc | arm64 clang | ratio | x86-64 xcc | x86-64 clang | ratio |
|---|---|---|---|---|---|---|
| `arc_array` | 0.99 | 5.56 | **0.18** | 1.16 | 3.72 | **0.31** |
| `method_call` | 0.96 | 2.88 | **0.33** | 1.35 | 1.90 | **0.71** |
| `string_scan` | 1.00 | 2.62 | **0.38** | 1.62 | 3.15 | **0.52** |
| `arc_alloc` | 1.03 | 1.41 | **0.73** | 0.95 | 2.06 | **0.46** |
| `sieve` | 1.21 | 1.58 | **0.77** | 1.85 | 0.81 | **2.30** |
| `call_depth` | 1.01 | 1.07 | **0.94** | 1.06 | 0.95 | **1.11** |
| `array_sum` | 0.96 | 0.96 | **1.00** | 1.20 | 1.44 | **0.84** |
| `hash_mix` | 1.26 | 1.23 | **1.03** | 1.01 | 1.12 | **0.91** |
| `branch_mix` | 1.22 | 1.10 | **1.11** | 0.82 | 0.81 | **1.01** |
| `int_accum` | 1.42 | 1.27 | **1.12** | 0.97 | 0.97 | **1.00** |
| `bit_ops` | 1.42 | 1.27 | **1.13** | 0.97 | 0.97 | **1.00** |
| `poly_dispatch` | 1.37 | 1.20 | **1.14** | 0.97 | 1.23 | **0.79** |
| `struct_copy` | 1.33 | 1.09 | **1.21** | 1.13 | 0.79 | **1.44** |
| `int_muldiv` | 1.23 | 1.02 | **1.21** | 2.02 | 1.70 | **1.19** |
| `sort_small` | 1.33 | 1.03 | **1.29** | 2.24 | 1.49 | **1.50** |
| `array_map` | 1.69 | 1.18 | **1.43** | 2.12 | 1.57 | **1.35** |
| `float_math` | 1.26 | 0.85 | **1.48** | 1.51 | 0.74 | **2.03** |
| `mem_copy` | 1.68 | 0.94 | **1.80** | 1.54 | 1.05 | **1.46** |
| `matrix_mul` | 1.83 | 1.00 | **1.83** | 2.43 | 1.20 | **2.02** |

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

**Alignment noise on x86-64.** Before 0.61, an individual x86-64 figure could
move by ten to fifteen percent between builds whose hot function was
instruction-for-instruction identical, because where a loop landed relative to
a 32-byte fetch boundary depended on how much unrelated code preceded it. xcc
now aligns every loop head on x86-64 to a 32-byte boundary and the start of
`.text` to 64 bytes, which fixes where a loop lands; see
[Optimisation](/compiler/usage/optimization/#per-target-settings). The summary
is still a geometric mean over nineteen programs rather than any single number.

## Reproducing

The benchmark sources are in `benchmark/src`, one `.xc` and one `.m` per
program, and the runner builds and times both:

```
python3 benchmark/run.py --version v0.62 --opt O3 --repeats 5
```

The x86-64 legs cross-build here and run on a configured Linux host; without
one the runner measures the local platform only and says so. Results land in
`benchmark/<version>/results.json`.
