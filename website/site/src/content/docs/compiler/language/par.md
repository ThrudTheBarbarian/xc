---
title: Parallel blocks
description: par blocks — a loop whose iterations run in parallel, with reductions — on the CPU's threads today, and on GPUs later.
---

**From 0.67.** A `par` block marks a loop whose iterations are independent, so
the compiler may run them in parallel. Today a block runs on the CPU's threads;
the same source is meant to run on a GPU in a later release, which is why the
rules about what a block may contain are stricter than for an ordinary loop.

```c
#import "Par.xc"

u32 a[100000];
u32 sum = (u32)0;
u32 best = (u32)0;
par fill :reduce(+ sum) :reduce(max best)
    {
    for (u32 i in 0..100000)
        {
        a[i] = (i * (u32)3) % (u32)1000;
        sum = sum + a[i];
        if (a[i] > best)
            best = a[i];
        }
    }
```

A program that uses `par` imports `Par.xc`, its runtime.

## The shape

`par [name] (:reduce(op variable))* { for (T i in a..b) { … } }`

- The body is **one ascending loop** over a range: `a..b` (up to but not
  including `b`) or `a...b` (including `b`), stepping by one. Each iteration is
  a work item.
- The **name** is optional (`par fill`). It is how a block will be chosen per
  device later; today it only labels error messages.
- `par` is not a reserved word: it starts a block only where a block can start,
  so a variable called `par` still works.

## What the body sees

The body reads the variables around it, and works on arrays declared outside it:

- **Arrays** are shared: every work item reads and writes the same array, so
  `a[i] = …` lands in the caller's array.
- **Scalars and structs** are copied into each work item. The body may read them
  but may not assign to them, because every work item has its own copy and the
  write would be lost. The compiler refuses such an assignment and says why.
- To combine values across work items, use a **reduction**.

## Reductions

`:reduce(op variable)` names a variable declared before the block and the
operator that combines it: `+`, `*`, `&`, `|`, `^`, `min` or `max`. Inside the
body the variable is updated as usual (`sum = sum + a[i]`, or
`if (a[i] > best) best = a[i]`). Each thread works on its own copy, and the
copies are combined at the end with the variable's value before the block, so
`sum` above ends as its starting value plus every element.

Integer reductions give the same result whatever the number of threads. A
floating-point sum can differ in its last bits from a sequential one, because
addition in a different order rounds differently.

## Threads

The range is split into one contiguous chunk per CPU thread (`Thread.cpuCount`).
Setting `XC_PAR_THREADS=<n>` in the environment chooses the number of threads for
one run; `XC_PAR_THREADS=1` runs the block on the calling thread alone. On
targets without threads (`xt6502`, `m68k` and `wasm32`) the whole range runs on
the calling thread.

## What a body may contain

A block runs on the CPU today, but the compiler holds every block to what a GPU
can run, on every target. A block that builds now will then build for a GPU
later without changes. The rule covers the body and every function it calls,
however deep the calls go.

**Allowed:** integer, floating-point and `bool` arithmetic; structs; arrays
local to the work item; captured scalars and structs (read-only); captured
arrays and global arrays (read and written element by element); reading
globals; `if`, nested loops, `break` and `continue`; calls to functions that
follow the same rules; and the maths that GPUs have natively, such as
`Math.sqrt`, `sin`, `cos`, `exp`, `ln` and `pow`.

**Refused**, each with an error at the block that names what it found:

| The compiler refuses | Because |
| --- | --- |
| `new`, and any class instance, `String`, `Array`, `Map` or block, used or captured | a GPU has no heap and no reference counting |
| a virtual or protocol call, a function pointer or a callback | a GPU kernel's calls must all be known when it is built |
| recursion, even through a helper | a GPU has no general call stack |
| varargs, `printf` and any other I/O, and calls to code outside the program | a GPU cannot run them |
| writing a global scalar | every work item would race on it; use a reduction, or write an array |
| inline assembly | it is for one CPU |

## Errors in the shape

| The compiler refuses | Because |
| --- | --- |
| a body that is not one ascending loop | each work item is one iteration of a range |
| assigning a captured scalar | each work item has its own copy; use a reduction or an array |
| a block without `#import "Par.xc"` | the block needs its runtime |
