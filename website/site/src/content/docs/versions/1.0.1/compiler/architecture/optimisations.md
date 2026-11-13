---
title: Optimisations
description: The optimisations xcc performs. SSA construction, inlining, CSE, LICM, loop vectorisation (NEON, SSE2, AVX2, AVX-512, WebAssembly SIMD), guarded devirtualisation, function multiversioning, matrix-multiply idiom recognition, strength reduction, register allocation, FMA contraction rules and more.
slug: versions/1.0.1/compiler/architecture/optimisations
banner:
  content: 'This is the documentation for xc 1.0.1. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

xcc's optimiser works on its SSA intermediate representation, shared by every target and by
the GPU kernel generator. `-O3`, the default, is the same as `-O2`. `-O1` runs only the
cheapest passes, and `-O0` only the mandatory ones.

## SSA construction

- **Direct SSA from structured control flow.** The lowering keeps each local's current value
  and places a **phi** at each join and loop header for the names that differ, so scalar
  locals never live in memory.
- **mem2reg** in the Cytron style, with **iterated dominance frontiers** and dominator-tree
  renaming, promotes aggregates' fields, and every local of a C program.
- **Memory ordering** by a single chain of memory tokens.

## IR optimisations

| Optimisation | What xcc does |
|---|---|
| Inlining | Small functions inlined, twice over, with a size limit (`-Fli`). |
| Common subexpression elimination | With redundant-load elimination and store-to-load forwarding, partly across blocks. |
| Constant folding and algebraic simplification | Including integer tree-height reduction. |
| Dead code and dead store elimination | Dead functions, unused values and local dead stores. |
| Scalar replacement of aggregates (SROA) | Struct locals split into scalars. |
| If-conversion | Branches that pick a value become selects. |
| Jump threading and block merging | |
| Tail-recursion elimination | Self-tail-calls become loops. |
| Demanded-width narrowing | Arithmetic done at the width its result needs. |
| Loop-invariant code motion (LICM) | |
| Strength reduction and pointer induction variables | Index arithmetic becomes pointer increments. |
| Loop rotation and induction-variable narrowing | |
| Full and partial loop unrolling | Constant trip counts fully, unknown ones four-fold. |
| Loop-invariant reduction collapse | A reduction over an invariant value computed directly. |
| Loop vectorisation | Maps, sums, dot products, minimum and maximum, widening sums and counts, with interleaved accumulators, loop distribution and scalar epilogues, for **NEON**, **SSE2**, **AVX2**, **AVX-512** and **WebAssembly SIMD**. |
| Outer-loop vectorisation | |
| Vector combining | Bit-select and rotate on arm64, ternary logic on AVX-512. |
| Function multiversioning | AVX2 and AVX-512 clones chosen at load time (`-msimd=auto`). |
| Guarded devirtualisation | A virtual call becomes a class test and a direct call that can be inlined. |
| Idiom recognition | `memset` loops, and matrix multiplication replaced by kernels xcc emits for **SME** on Apple silicon and AVX2 and AVX-512 on x86-64. |
| Bounds-check elimination | Range analysis removes checks it can prove, when checks are on. |
| Floating-point contraction | Fused multiply-add only in `:goal(speed)` code, on arm64 and x86-64, so an exact loop's result does not depend on which CPU or GPU runs it; C on arm64 fuses within an expression, as GCC and clang do there. |
| Select-to-branch | A float select on one bit becomes a branch when one arm is costly (arm64). |
| Hot-path block placement | arm64. |

A float reduction is reassociated, and multiply-adds are fused, only under [`:goal(speed)`](/versions/1.0.1/compiler/language/par/#which-goal-applies), which
`par` blocks use by default, written in the source or made from a loop by `--par-style`, though a float sum in such a loop is reassociated only when speed is asked for explicitly; a plain loop is exact unless its file or build asks for speed.

## Code generation

- **Register allocation** over live intervals from backward liveness, most-used values
  first, callee-saved registers for values live across calls, phi coalescing, and stack-slot
  colouring.
- **Peephole optimisation** of the generated assembly: spill forwarding, redundant reload
  and compare removal, copy propagation, fused shift-and-add, and fallthrough branch
  removal.
- **Instruction selection** for conditional selects (`csel`, `cmov`), compare-and-branch,
  test-bit-and-branch (`tbz`), address-mode folding, and fixed-point conversions.
- **Division by constants** with multiply-high magic numbers, vectorised on arm64.
- **Loop alignment** on x86-64.

## GPU kernels

Each `par` block's kernel is generated from a copy of its IR optimised again for the GPU:
reductions are split across lanes, and loops with an escape test can run several trips per
test. See [GPU kernels](/versions/1.0.1/compiler/architecture/gpu-kernels/).
