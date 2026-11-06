---
title: Data-parallel extraction
description: How xcc turns ordinary loops into parallel blocks automatically, in three phases. Acquisition of candidate loops in xc and C, validation by dependence analysis and GPU-safety checks with run-time guards, and run-time device-under-test measurement with a learned per-machine record.
slug: versions/0.9.5/compiler/architecture/extraction
banner:
  content: 'This is the documentation for xc 0.9.5. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

xcc finds the loops in a program that can run in parallel and makes each one a
[`par` block](/versions/0.9.5/compiler/language/par/), with no annotations in the source. This is
**automatic parallelisation** in three phases: acquisition, validation, and run-time
device-under-test (DUT) measurement. It is on by default (`--par-style=auto`).

<svg class="xc-diagram" viewBox="0 0 860 250" style="max-width:860px" role="img" aria-label="Three phases of data-parallel extraction: acquisition at compile time, validation at compile time and before each run, and run-time device-under-test measurement">
<rect class="key" x="10" y="30" width="260" height="190" rx="6"/>
<text x="140" y="78.5" text-anchor="middle" class="head">1. Acquisition</text>
<text x="140" y="95.5" text-anchor="middle" class="muted">compile time</text>
<text x="140" y="112.5" text-anchor="middle" class="muted">xc: the parser scans each loop</text>
<text x="140" y="129.5" text-anchor="middle" class="muted">C: the IR outliner walks</text>
<text x="140" y="146.5" text-anchor="middle" class="muted">clang's loops, outermost first</text>
<text x="140" y="163.5" text-anchor="middle" class="muted">every candidate becomes a</text>
<text x="140" y="180.5" text-anchor="middle" class="muted">par block beside the plain loop</text>
<rect class="box" x="300" y="30" width="260" height="190" rx="6"/>
<text x="430" y="78.5" text-anchor="middle" class="head">2. Validation</text>
<text x="430" y="95.5" text-anchor="middle" class="muted">compile time, and before each run</text>
<text x="430" y="112.5" text-anchor="middle" class="muted">loop shape, reductions, calls</text>
<text x="430" y="129.5" text-anchor="middle" class="muted">GCD dependence test per array</text>
<text x="430" y="146.5" text-anchor="middle" class="muted">GPU-safety scan of the body</text>
<text x="430" y="163.5" text-anchor="middle" class="muted">unproven pairs: run-time guards</text>
<text x="430" y="180.5" text-anchor="middle" class="muted">failure: the plain loop runs</text>
<rect class="key" x="590" y="30" width="260" height="190" rx="6"/>
<text x="720" y="78.5" text-anchor="middle" class="head">3. Runtime DUT measurement</text>
<text x="720" y="95.5" text-anchor="middle" class="muted">the first runs on each machine</text>
<text x="720" y="112.5" text-anchor="middle" class="muted">static cost: compute- or</text>
<text x="720" y="129.5" text-anchor="middle" class="muted">bandwidth-bound</text>
<text x="720" y="146.5" text-anchor="middle" class="muted">every device under test runs</text>
<text x="720" y="163.5" text-anchor="middle" class="muted">the real block, timed</text>
<text x="720" y="180.5" text-anchor="middle" class="muted">the winner is learned per size</text>
<path class="line" d="M270 125 L300 125"/>
<polygon class="arrow" points="300,125 293,121 293,129"/>
<path class="line" d="M560 125 L590 125"/>
<polygon class="arrow" points="590,125 583,121 583,129"/>
<text x="430" y="244" text-anchor="middle" class="muted">Later runs read the learned record and go straight to the winning device; a new size, machine or compiler version measures again.</text>
</svg>

## 1. Acquisition

Acquisition finds the candidate loops.

**In xc**, the parser looks at each `for` loop before it parses it. A candidate is an
ascending counted loop, `for (T i in a..b)` or the C form `for (T i = a; i < b; i++)`, whose
body may:

- assign its own locals freely;
- write the outer program's state only as a **reduction**: `acc += e`, `acc *= e`, `&=`,
  `|=`, `^=`, `acc++`, or a minimum or maximum written as `if (e < acc) acc = e;`;
- not `return`, `goto` or `break` out of the loop, use varargs, or take an outer name's
  address.

A perfect two- or three-deep nest whose inner bounds do not depend on the outer index
becomes one block over the whole grid. The loop is parsed twice, once as written and once
as a block, and the program carries both: the block runs where it was proved safe, the plain
loop everywhere else.

**In C**, xcc works on the IR it reads from clang. An **IR outliner** walks the natural loops,
outermost first, and outlines each candidate into a function with a captured-variable record
and reduction state. A loop that is declined has its inner loops judged on their own, so an
outer loop that cannot run in parallel still gets its inner loops lifted.

Small loops stay as they are: a constant trip count below a threshold, with no inner work,
costs more to launch than to run.

## 2. Validation

Validation proves each candidate safe, at compile time where it can and before each run
where it must.

- **Loop shape.** One entry, a top test against a loop-invariant bound, a positive constant
  step, and no other exit.
- **Reductions.** Every value carried from one iteration to the next must be a reduction
  with an associative operator: integer `+`, `*`, `&`, `|`, `^`, minimum and maximum,
  including if-converted conditional updates and chains like `t = t + x1 + x2`. A float sum
  is reassociated only under [`:goal(speed)`](/versions/0.9.5/compiler/language/par/), so the default
  result matches the plain loop's.
- **Dependence analysis.** Each array index is reduced to an affine form `k·i + c`, or a
  symbolic one over captured integers, and every read is tested against every write to the
  same array with the **GCD test**. Pairs the compiler cannot settle become **run-time
  guards**, written into the block and checked before each run. A failed guard, or two
  arrays found to overlap at run time, runs the block serially.
- **GPU safety.** The body and everything it calls is scanned for what a GPU cannot run:
  reference-counted objects, virtual and indirect calls, heap allocation, recursion, inline
  assembly, varargs, writes to global scalars, and calls outside the program other than math
  intrinsics.
- **Calls.** Calls to the program's own functions are followed; indirect calls and calls into
  libraries without a body are refused.

A lifted loop that fails any check is **demoted**, not rejected: the plain loop runs, and
`-Wpar-auto` says what was lifted, what was demoted, and why. A block written with `par` by
hand gets the same checks as errors and warnings.

## 3. Run-time device-under-test measurement

The third phase happens on the user's machine, the first times the block runs.

**A static cost model** comes first. The compiler writes each block's instruction count,
whether it loops inside, and each array's footprint per item into the block. The runtime
classifies the block as **compute-bound** or **bandwidth-bound**: a bandwidth-bound block is
kept off a GPU across a bus without being timed, since the copies would cost more than the
work.

**Then each device under test runs the real block**, and is timed:

- the GPU;
- remote GPUs, where an [`xcd` daemon](/versions/0.9.5/compiler/architecture/tiling/) serves them;
- every GPU together, tiled;
- every CPU core;
- one CPU thread;
- every device together, GPUs and CPU cores.

The GPUs go first, while the card is still at speed, and each device's first run, which
builds its kernel, is a warm-up that is not counted. Every one of these runs is a real run of
the program's own work: nothing is repeated just to time it. Where CUDA and Vulkan reach the
same card, CUDA is tried first. A device that cannot run a block, such as a GPU without
64-bit integers, leaves the comparison and the others finish.

**The winner is learned** per machine, per block and per problem size, as size bounds in the
program's own settings store. The key carries a hash of the hardware (the GPUs, the CPU and
its thread count, the set of tile workers), a hash of the block's code, and the compiler
version, so a new machine, a changed block or a new compiler measures again, and old records
are purged. Later runs read the record and go straight to the winning device; a size well
outside what was measured is measured again.

The user's settings and `XC_PAR` override all of this, and
[`XC_PAR_REPORT=1`](/versions/0.9.5/compiler/usage/environment/) prints each decision.
