---
title: Parallel blocks
description: par blocks — a loop whose iterations run in parallel, with reductions — on the CPU's threads, and from 0.7 on the GPU.
---

**From 0.7.** A `par` block marks a loop whose iterations are independent, so
the compiler may run them in parallel: on the CPU's threads, or on the GPU
where there is one (see below). The same source has to run on both, which is
why the rules about what a block may contain are stricter than for an ordinary
loop.

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

or, from the release after 0.71, `par [name] :grid(w, h[, d]) (:reduce(op variable))* { … }`
over the points of a grid (see [Grids](#grids)).

- The body is **one ascending loop** over a range: `a..b` (up to but not
  including `b`) or `a...b` (including `b`), stepping by one. Each iteration is
  a work item.
- The **name** is optional (`par fill`). It names the block in messages, in
  `XC_PAR_REPORT=1`, and to [`Par.device`](#which-device), which sets one block's
  device; an unnamed block goes by `file:line`.
- `par` is not a reserved word: it starts a block only where a block can start,
  so a variable called `par` still works.

## Grids

**From the release after 0.71.** `:grid(w, h)` or `:grid(w, h, d)` makes the
work items the points of a 2-D or 3-D grid, and the body is then any code,
run once for each point, rather than one loop:

```c
#import "Par.xc"

#define W 1920
#define H 1080

u32 image[W * H];

par shade :grid(W, H)
    {
    if (par.x == 0 || par.y == 0)
        {
        image[par.y * par.width + par.x] = 0;
        return;
        }
    image[par.y * par.width + par.x] = par.x ^ par.y;
    }
```

- **`par.x`, `par.y` and `par.z`** are the work item's point, from 0. In a
  2-D grid `par.z` is 0.
- **`par.width`, `par.height` and `par.depth`** are the grid's size. In a 2-D
  grid `par.depth` is 1.
- The sizes are any integer expressions, worked out once before the block
  runs. All of these values are `u32`, and a grid has at most 2³² points.
- **`return;` ends the work item.** It takes no value, and it may not be
  inside a loop of the body's own, where it would only end that loop. To leave
  such a loop early, `break` out of it and return after it.
- `break` and `continue` work inside the body's own loops and switches. A
  `break` that would leave the body is refused; use `return`.
- Reductions and `:goal` work as they do for the loop form.
- Inside a `:grid` body, `par.x` and the others always mean the grid, even
  where a variable called `par` is in scope.

Points are numbered with `x` changing fastest, so `par.y * par.width + par.x`
(or `(par.z * par.height + par.y) * par.width + par.x` in 3-D) is the work
item's own element of a row-major array. The compiler knows that index is
different for every work item, so writing through it needs no warning (see
[Independent work items](#independent-work-items)).

A grid block has the same limits as the loop form (see
[What a body may contain](#what-a-body-may-contain)). It runs on the CPU's threads or on the GPU in the same way.

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

## Running on the GPU

**From 0.7: macOS on Apple silicon, and Windows with an NVIDIA GPU.** A block
that can run on the GPU does so when that is faster: through Metal on a Mac, and
through NVIDIA's driver on Windows. The compiler gives each block a GPU version
of its loop, and a program needs no extra flags or libraries. On Windows it
needs no CUDA toolkit either, only the driver that comes with the card. Results
are the same as on the CPU: integer reductions match exactly, because the GPU's
partial results are combined in the same order the CPU combines its chunks. A
block that cannot run on the GPU stays on the CPU, as do all blocks when there
is no GPU.

In this first version a block runs on the GPU when it works on arrays (captured
locals or globals), scalars, reductions, and helper functions that take and
return plain values. On an Apple GPU, which has no 64-bit floating point, a
block that uses `double` runs on the CPU. On an NVIDIA GPU, `double` values are
fine, but an array of them still keeps the block on the CPU. Anywhere, a block that calls a helper that takes a pointer or
an array, or that uses a global itself, runs on the CPU.

When you compile for a target with a GPU, the compiler warns at each block that
cannot run there and says why, for example:

```
blur.xc:12:5: warning: this 'par' block runs on the CPU only, because it uses
double, which Apple GPUs do not have
```

`-Wno-par-gpu` turns the warning off, for a program that keeps some blocks on
the CPU on purpose.

### Speed or accuracy

A block's goal says what its GPU version favours: `:goal(speed)`, the default,
or `:goal(accuracy)`.

```c
par waves :reduce(+ high)                       // the goal is speed
    { … }
par measure :reduce(+ total) :goal(accuracy)    // precise maths
    { … }
```

With speed, the GPU uses its fast maths. On a Mac that is Metal's fast mode,
which also lets the GPU reorder float arithmetic and assume there are no NaNs
or infinities. On an NVIDIA GPU, `sin`, `cos`, `exp`, `ln` and `pow` of `float`
values use the hardware's approximations. Float results can then differ from
the CPU's in the last few bits; integer results are the same either way.

With accuracy, the maths is precise and float results land within about one
ULP of the CPU's. NVIDIA GPUs have no precise `sin`, `cos`, `exp`, `ln` or
`pow`, so there a block that calls them runs on the CPU. Choose accuracy for a
block that depends on NaN or infinity, or on exact float results.

On the CPU, both goals run the same code, except that from the release after
0.71 the block's goal also holds for the loops in its body, as
[`:goal` on a `for` loop](/compiler/language/statements/#speed-or-accuracy-goal)
does.

### Which device

By default each block's device is chosen automatically, by measuring it. A block
without a GPU version runs on the CPU. Otherwise it runs on the CPU first, and a
block the CPU finishes in under a millisecond stays there: the GPU's fixed costs
alone are more. A longer block then runs on the GPU too, and from then on wherever
it was faster. So a block that does little work per item, where copying its
arrays to the GPU costs more than the work, settles on the CPU, and a heavy one on
the GPU, however few items it has. Each device's first run of a block is a
warm-up and is not counted: it pays one-off costs, such as building the GPU
version and starting threads, that later runs do not.

To choose instead:

- `XC_PAR=cpu`, `XC_PAR=gpu` or `XC_PAR=auto` in the environment, for every
  block in one run;
- `Par.device("name", "gpu")` in the program, for one block by its name (`par
  name { … }`, or `file:line` for an unnamed block), or `Par.device("par", …)`
  for every block without its own choice. An app that keeps this in its Settings
  passes the value on to `Par.device`.

`XC_PAR_REPORT=1` prints where each block ran, what it took, why a block stayed
on the CPU, and what `auto` decided.

## What a body may contain

The compiler holds every block to what a GPU can run, on every target, even
one with no GPU, so a block that builds anywhere builds for a GPU without
changes. The rule covers the body and every function it calls, however deep
the calls go.

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

## Independent work items

Work items may run in any order and at the same time, so none may read what
another writes. A body may read and rewrite its own element of a buffer
(`b[i] = b[i] + a[i]`), use a fixed offset consistently (`b[i + 1]`, written
and read back), and read freely from buffers it does not write, including
through an index table (`a[i] = g[idx[i]]`).

Reading a buffer the block also writes, at another item's element, is refused:

```c
par { for (u32 i in 1..n) { b[i] = a[i] + b[i - 1]; } }   // error: a scan, not a par
```

Each `b[i - 1]` is another item's result, which may not have been computed yet.
That loop is a scan (a running sum); write it as an ordinary `for` loop.

## Errors in the shape

| The compiler refuses | Because |
| --- | --- |
| a body that is not one ascending loop (without `:grid`) | each work item is one iteration of a range |
| `return` with a value, or inside a loop of the body's own, in a `:grid` body | `return;` ends the work item, and inside a loop it would only end that loop |
| a `break` that would leave a `:grid` body | `return` ends a work item |
| assigning a captured scalar | each work item has its own copy; use a reduction or an array |
| a block without `#import "Par.xc"` | the block needs its runtime |
