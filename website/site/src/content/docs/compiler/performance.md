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
| **Geometric mean** | **0.94** | **0.88** |
| Arithmetic mean | 1.06 | 0.94 |
| Within 0.3x-2.0x of clang | 18 of 19 | 19 of 19 |

On both targets the suite is faster than clang overall: by six percent on
arm64 and by twelve on x86-64, where 0.64's register allocation and loop
rotation closed most of the gap.

The geometric mean is the one to read. Averaging ratios arithmetically is
misleading: a benchmark at 2.00x and one at 0.50x are exactly compensating,
and their arithmetic mean is 1.25x while their geometric mean is 1.00x. The
arithmetic figure is given only for completeness.

## Per benchmark

Times are seconds for the timed region, best of five, measured with the released 0.64 `xcc`. Each run waits until the machine doing the timing is otherwise idle.

| benchmark | arm64 xcc | arm64 clang | ratio | x86-64 xcc | x86-64 clang | ratio |
|---|---|---|---|---|---|---|
| `arc_array` | 0.96 | 5.40 | **0.18** | 1.15 | 3.72 | **0.31** |
| `method_call` | 1.04 | 2.81 | **0.37** | 1.35 | 1.90 | **0.71** |
| `string_scan` | 0.95 | 2.47 | **0.38** | 1.62 | 3.15 | **0.51** |
| `arc_alloc` | 1.01 | 1.38 | **0.74** | 0.93 | 2.05 | **0.45** |
| `sieve` | 1.17 | 1.52 | **0.77** | 1.49 | 0.82 | **1.82** |
| `call_depth` | 0.98 | 1.04 | **0.94** | 1.05 | 0.95 | **1.11** |
| `array_sum` | 0.94 | 0.94 | **1.00** | 0.93 | 1.44 | **0.65** |
| `hash_mix` | 1.32 | 1.24 | **1.06** | 1.01 | 1.08 | **0.94** |
| `branch_mix` | 1.19 | 1.07 | **1.11** | 0.81 | 0.81 | **1.00** |
| `bit_ops` | 1.38 | 1.24 | **1.12** | 0.97 | 0.97 | **1.00** |
| `int_accum` | 1.37 | 1.22 | **1.12** | 0.97 | 0.97 | **1.00** |
| `poly_dispatch` | 1.34 | 1.17 | **1.14** | 0.97 | 1.23 | **0.79** |
| `int_muldiv` | 1.20 | 0.99 | **1.22** | 2.01 | 1.70 | **1.19** |
| `struct_copy` | 1.24 | 0.99 | **1.25** | 0.85 | 0.78 | **1.09** |
| `sort_small` | 1.32 | 0.99 | **1.34** | 1.80 | 1.49 | **1.21** |
| `array_map` | 1.47 | 1.07 | **1.37** | 1.56 | 1.56 | **0.99** |
| `float_math` | 1.31 | 0.89 | **1.48** | 0.74 | 0.75 | **0.99** |
| `mem_copy` | 1.60 | 0.90 | **1.78** | 1.07 | 1.05 | **1.02** |
| `matrix_mul` | 1.77 | 0.97 | **1.82** | 1.30 | 1.20 | **1.08** |

The fastest results are where the runtime does the work: `arc_array`,
`method_call` and `string_scan` are reference counting, dynamic dispatch and
string scanning, and those are library code rather than generated code. The
slowest are `matrix_mul` and `mem_copy` on arm64 and `sieve` on x86-64, whose
inner loops clang vectorises and xcc does not.

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
python3 benchmark/run.py --version v0.64 --opt O3 --repeats 5
```

The x86-64 legs cross-build here and run on a configured Linux host; without
one the runner measures the local platform only and says so. Results land in
`benchmark/<version>/results.json`.
