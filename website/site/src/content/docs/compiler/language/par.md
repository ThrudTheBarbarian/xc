---
title: Parallel blocks
description: par blocks — a loop whose iterations run in parallel, with reductions — on the CPU's threads and on the GPU (Metal, CUDA, Vulkan and WebGPU).
---

 A `par` block marks a loop whose iterations are independent, so
the compiler may run them in parallel: on the CPU's threads, or on the GPU
where there is one (see below). The same source has to run on both, which is
why the rules about what a block may contain are stricter than for an ordinary
loop.

```c
#import "Par.xc"

u32 a[100000];
u32 sum = 0;
u32 best = 0;
par fill :reduce(+ sum) :reduce(max best)
    {
    for (u32 i in 0..100000)
        {
        a[i] = (i * 3) % 1000;
        sum = sum + a[i];
        if (a[i] > best)
            best = a[i];
        }
    }
```

A program that uses `par` imports `Par.xc`, its runtime.

## The shape

`par [name] (:reduce(op variable))* { for (T i in a..b) { … } }`

or, `par [name] :grid(w, h[, d]) (:reduce(op variable))* { … }`
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

 `:grid(w, h)` or `:grid(w, h, d)` makes the
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
[Independent work items](#independent-work-items)); the same holds
when the grid's size is a constant and the index spells it out, as
`par.y * 640 + par.x` under `:grid(640, 480)` does.

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
targets without threads (`xt6502`, `m68k`), and on `wasm32`, where threads
would make the page need cross-origin isolation, the whole range runs on the
calling thread (or on the GPU through WebGPU).

## Running on the GPU

**macOS on Apple silicon, and Windows with an NVIDIA GPU. Also Linux, Windows with any GPU, Android, and the browser.** A block that can
run on the GPU does so when that is faster. The compiler gives each block a GPU
version of its loop, and a program needs no extra flags, libraries or SDKs, only
the driver that comes with the GPU:

| Target | GPU interface | Needs |
|---|---|---|
| `arm64` (macOS) | Metal | Apple silicon |
| `win64` | NVIDIA's driver (CUDA), else Vulkan | an NVIDIA GPU, or any GPU with a Vulkan driver |
| `x86_64` (Linux) | Vulkan | a Vulkan driver (`libvulkan.so.1`); a program linked with `-static` stays on the CPU |
| `android` | Vulkan | a device whose Vulkan driver has 64-bit integers |
| `wasm32` | WebGPU | a browser with WebGPU and JavaScript promise integration (JSPI), such as Chrome |

Results are the same as on the CPU: integer reductions match exactly, because
each of the seven operators gives the same integer whatever order its values
are combined in. The GPU combines a block's reductions itself, in
groups of 256 work items (on CUDA and Metal so far), rather than handing every
work item's value back to be combined on the CPU. A floating-point reduction can
therefore differ in its last bits between the CPU and the GPU, as it can between
two numbers of CPU threads; on one device it gives the same result every run. A block that cannot run on the GPU stays on the CPU, as do all blocks
when there is no GPU.

A block runs on the GPU when it works on arrays (captured locals or globals),
scalars, reductions, and helper functions that take and return plain values.
Anywhere, a block that calls a helper that takes a pointer or an array, or that
uses a global itself, runs on the CPU. What else each GPU can hold:

- On an Apple GPU, which has no 64-bit floating point, a block that uses
  `double` runs on the CPU.
- On an NVIDIA GPU through CUDA, `double` values are fine, but an array of them
  still keeps the block on the CPU.
- Through Vulkan the GPU must have 64-bit integers, which desktop GPUs have;
  `double` is used where the GPU has it. 8- and 16-bit values and `bool`s,
  alone or in arrays, are exact on every Vulkan GPU, and they can be reduced
  there and through WebGPU too.
- Through WebGPU, which has only 32-bit numbers, 64-bit integers are worked in
  two halves and 8- and 16-bit values exactly, as through Vulkan; a block that
  uses `double` runs on the CPU. 64-bit integers are divided and
  converted to and from `float` there too, with the CPU's results. A block that needs more arrays, or a larger
  one, than the device can hold runs on the CPU.

On Windows with an NVIDIA GPU, a block can reach it through CUDA or Vulkan.
`auto` measures both and keeps the faster for each block (see
[Which device](#which-device)).
`XC_PAR_GPU=vulkan` or `XC_PAR_GPU=cuda` in the environment picks one
interface where both work, and `XC_PAR=gpu` uses CUDA unless
`XC_PAR_GPU=vulkan` is set. Where a machine has more than one Vulkan GPU,
a discrete one is chosen first; `XC_PAR_VULKAN_DEVICE=<n>` picks the n-th
instead, counting from 0 in the driver's order.

On the web the loader runs the GPU's work while the program waits for it, so a
page needs nothing but the usual `<script src="prog.js">`; `XC_PAR` and the
other settings below come from `globalThis.xccEnv`, an object of strings the
page sets before the script.

When you compile for a target with a GPU, the compiler warns at each block that
cannot run there and says why, for example:

```
blur.xc:12:5: warning: this 'par' block runs on the CPU only, because it uses
double, which Apple GPUs do not have
```

`-Wno-par-gpu` turns the warning off, for a program that keeps some blocks on
the CPU on purpose.

### Read-only data the GPU broadcasts: `:constant`

 A block's header may name captured arrays the body only reads
as constant data:

```c
u32 table[256];
par lookup :constant(table)
{
    for (u32 i in 0..n)
        ys[i] = table[xs[i] & (u32)255];
}
```

A `:constant` array is bound in Metal's constant address space, which is
read-only, cached and broadcast to every thread, the right home for a small
table every item reads; the other GPU forms and the CPU path take it as any
other read-only array. It is a hint, never a change of meaning: the result is
the same with or without it. Each name must be a captured array, or a pointer
to numbers, that the body indexes and never writes; anything else is refused
at the `par`. Keep it small, a few kilobytes to a few tens: a constant buffer
is cached, not streamed.

### Arrays the GPU shares: `simd:` pointers

 A block's arrays are copied to the GPU before a run and back
after it. On a discrete card that is the bus, and unavoidable; on a
unified-memory GPU — Apple silicon, or an integrated GPU on Linux — it is a
copy the hardware never needed. A heap array can be declared so that such a
GPU uses it where it lies:

```c
simd: u32* xs = new u32[N];
simd: u32* ys = new u32[N];
par saxpy
{
    for (u32 i in 0..N)
        ys[i] = (u32)3 * xs[i] + ys[i];
}
```

`simd:` is a pointer qualifier, written where `weak:` is. A `new T[N]` into a
`simd:` pointer allocates the array page-aligned, on whole 16 KB pages, so a
GPU can map it; `.length`, `delete` and reference counting work as for any
heap array. A block that indexes a `simd:` pointer takes it as a GPU array,
sized from the block the pointer points into, and on Apple silicon Metal binds
the pages in place, with no copy either way; so does a Linux integrated GPU
whose Vulkan driver imports host memory (`VK_EXT_external_memory_host`, which
Mesa's drivers have). A discrete card copies a `simd:` array as it copies any
other; a CUDA card pins a page-aligned block of a megabyte or more
where it lies for as long as the block exists, so every copy is a transfer
straight from the program's memory rather than a copy into the driver's own
buffer first.

**Resident data.** A CUDA card also keeps what it was sent: a
block's array that the program has not written since its last upload is not
sent again, so a block run over the same arrays again uploads nothing, and
`XC_PAR_REPORT=1` says "already on the GPU". The runtime sees a write by
making the array's pages read-only after an upload and absorbing the first
write's page fault, whoever writes (a library, a `memcpy`), so there is nothing
to declare. One fault per array per upload is the cost. Under a debugger that
fault is reported as an access violation, or as SIGBUS on macOS and SIGSEGV on
Linux, before the runtime handles it: tell lldb `process handle SIGBUS SIGSEGV
-s false -n false`, gdb `handle SIGSEGV nostop noprint`, and in Visual Studio
continue past the first-chance exception.

**Most arrays need no qualifier.** The runtime keeps a registry of
its page-aligned blocks, and allocates every numeric array of 64 KB or more
(`new u32[N]`, no qualifier) page-aligned and registered as well, at a cost of
at most two pages per array. A block that indexes any pointer to numbers asks
the registry for the block it points into, so a plain `new u32[1 << 20]` is a
GPU array like a `simd:` one, and a pointer offset into either (`xs + 4096`)
is sized from where it points to the block's end; Metal binds the block at
that offset when the offset is a multiple of 256 bytes, and copies otherwise.
A pointer into no registered block — a small array, a stack array, a global —
keeps the block on the CPU, as a plain pointer always did. `simd:` is for
arrays under 64 KB that a GPU should still share, and for the contract below.

Because the promise rides on the type, a `simd:` pointer may hold only what
`new[]` returned or what another `simd:` pointer holds, and arithmetic on one
keeps the qualifier. A plain pointer stored into one — passed where a function
declares a `simd:` parameter, or as an initialiser, an assignment or a return
value — is an error, since the holder may hand it to a GPU with no copy, and a
cast says that is meant; `nil` is fine. The 8-,
16- and 32-bit targets accept `simd:` and allocate as plain `new` does.

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
or infinities. On an NVIDIA GPU, and through Vulkan and WebGPU, `sin`, `cos`,
`exp`, `ln` and `pow` of `float` values use the hardware's approximations. Float results can then differ from
the CPU's in the last few bits; integer results are the same either way.

With accuracy, the maths is precise and float results land within about one
ULP of the CPU's. NVIDIA GPUs have no precise `sin`, `cos`, `exp`, `ln` or
`pow`, so there a block that calls them runs on the CPU. Vulkan and WebGPU
round `+`, `-` and `*` exactly but not division or square roots; a
block whose goal is accuracy divides and takes square roots of `float`s there
in integer arithmetic, correctly rounded, so its results are the CPU's. They have no precise `sin`, `cos`, `exp`,
`ln` or `pow`, so a block whose goal is accuracy and that calls them runs on
the CPU. Apple GPUs flush subnormal `float`s (below about 1.2e-38) to zero, so
results that pass through them can differ from the CPU's there. Choose
accuracy for a block that depends on NaN or infinity, or on exact float
results.

On the CPU, both goals run the same code, except that the block's goal also holds for the loops in its body, as
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

What `auto` measures is kept, so a program measures once on a machine
rather than on every run. It is kept in the program's own settings store (see
[Settings](/compiler/api/settings/): the system's store on macOS, Windows and
the web, else `~/.config/<program>.conf`), under `par.learned.…` keys, as a
size threshold for each block: the largest number of items the CPU won at and
the smallest the GPU won at. A run whose size falls outside those is decided
without measuring; one between them is measured once and narrows them. The keys
include a hash of the machine's GPU and CPU, so a new GPU is measured afresh
(and the old one's values wait for it to come back), and a hash of the block's
GPU version, so a block that changes is measured afresh too. On
Windows with both CUDA and Vulkan, the value also names the interface `auto`
chose (`…,cuda` or `…,vulkan`).

#### How `auto` learns across runs of different sizes

For each block, `auto` keeps two numbers: the largest number of items the CPU
has won at, and the smallest the GPU has won at. Either may be unknown. Each
time the block starts, its number of items (`n`) is compared with them:

| `n` is… | the block runs on | and `auto`… |
|---|---|---|
| at least the GPU's smallest win | the GPU | measures nothing |
| at most the CPU's largest win | the CPU | measures nothing |
| between the two, or either is unknown | the CPU first, then the GPU | measures this size and learns from it |

Measuring a size takes several runs of the block in one run of the program,
because each device's first run is a warm-up. The block runs on the CPU, and
the second CPU run is timed. If it took under a millisecond, the CPU wins at
`n` and the block stays there. Otherwise the block runs on the GPU, its second
GPU run is timed, and the faster device wins at `n`. A size the block meets once
and never again is not measured to the end; one it meets repeatedly is.

The win moves the matching number: a CPU win at `n` raises the CPU's largest
win to `n`, a GPU win lowers the GPU's smallest win to `n`. The two always
leave a gap between them. A win that contradicts the other number (the GPU
winning at a size the CPU had won at, say) drops that number, so the newer
measurement is the one kept. Both numbers are saved straight away.

While a size is being measured, a run more than twice as large, or less than
half as large, starts the measurement again at the new size. The devices stay
warm, so no second warm-up is needed. Without this rule, a block whose size
never repeats would never finish measuring.

An example, for one block whose GPU version is worth it on large inputs:

| program run | sizes it calls the block with | what `auto` does | kept afterwards (CPU up to, GPU from) |
|---|---|---|---|
| 1st | 1,000, several times | the CPU takes 0.2 ms: a CPU win | 1,000, unknown |
| 1st, later | 1,000,000, several times | above the CPU's win, so measured: CPU 40 ms, GPU 8 ms | 1,000, 1,000,000 |
| 2nd | 1,000 and 1,000,000 | both decided at once, nothing measured | 1,000, 1,000,000 |
| 2nd, later | 300,000, several times | between the two, so measured: CPU 12 ms, GPU 4 ms | 1,000, 300,000 |
| 3rd | 2,000,000 | above the GPU's win: the GPU, nothing measured | 1,000, 300,000 |

So the gap between the two numbers narrows only at sizes the program really
uses, and a size outside it is never measured again. The numbers belong to one
machine and one version of the block. A new GPU, or a change to the block,
starts from nothing; the old values stay in the store for when the old GPU or
block comes back.

To start again, delete the block's `par.learned.…` keys from the settings store,
or set the block's own setting (below), which `auto` never overrides.
`XC_PAR_REPORT=1` prints each decision, each measurement and each change to
the two numbers as it happens.

#### Several devices at once

A block can run on every device the machine has at once: each GPU
(an NVIDIA card through CUDA, another vendor's through Vulkan, Apple's through
Metal) and the CPU's cores together. The range is cut into tiles of a few
megabytes each way, and each device takes the next tile when it has room —
three in flight on a GPU, so a tile's copies overlap another's kernel — until
the range is done; a device that finishes sooner takes more. The tiles'
reductions fold in tile order whichever device ran them, so the answer does
not depend on which device took what. Two cards split a memory-bound block
as the sum of their links (on a machine with an RTX 5080 and an RTX 3090,
`saxpy` over 16 million floats: 16 ms on one card, 10 ms on both); a block
with compute to hide gains more.

`auto` treats the two sets as two more candidates after the CPU and the one
GPU: the GPUs together, and the GPUs with the CPU. Each is measured twice
(the first run a warm-up, as above), and the fastest of the four wins at that
size. The learned record grows to four numbers — the CPU's largest win and
the smallest size each of the other three won from — and the hardware key
takes in every device, so a machine that gains a card is measured afresh. A
block that would make a single tile, or that no second device can hold, is
not tried on a set. Neither is the CPU with a GPU that shares its
memory (Apple silicon, an integrated GPU) when the block is bandwidth-bound:
the two draw on one memory bus, so together they move no more bytes a second
than the faster of them alone, and `XC_PAR_REPORT=1` says so. What is
measured so far is saved as it lands, under
`par.measuring.…`, so a program that runs a block only a few times per run
still finishes measuring over several runs.

A device slower than the others on a block is not a free gain: it takes its
share of the tiles, and the CPU's cores compete with the cards' copies for
the same memory. That is why the sets are measured rather than assumed, and
why on an Apple-silicon Mac or a machine with an integrated GPU `auto`
usually keeps a memory-bound block on the CPU.

To choose instead, in order of precedence:

- `XC_PAR=cpu`, `XC_PAR=gpu`, `XC_PAR=gpus` (every GPU, tiled),
  `XC_PAR=all` (every GPU and the CPU) or `XC_PAR=auto` in the
  environment, for every block in one run. `XC_PAR_WORKERS=cuda,
  vulkan,metal,remote,cpu` names the devices of the set itself, and then
  every block runs on that set: `remote` is the daemons `XC_PAR_REMOTE`
  names (see [Across machines](#across-machines-xcd)), and
  `XC_PAR_CUDA_DEVICES=0,1` picks CUDA cards by ordinal;
  `XC_PAR_TILE_MB=<n>` sets the tile size (8 MB each way by default) and
  `XC_PAR_TILES=0` turns tiling off;
- `Par.device("name", "gpu")` in the program, for one block by its name (`par
  name { … }`, or `file:line` for an unnamed block), or `Par.device("par", …)`
  for every block without its own choice; `"gpus"` and `"all"` too;
- the user's own settings, in the same store: `par.<name> = cpu`,
  `gpu`, `auto`, or a number of items from which the block runs on the GPU (`par.heavy
  = 200000`), and `par = …` for every block without its own; `gpus`
  and `all` as well. The program never writes these.

`XC_PAR_REPORT=1` prints where each block ran, what it took, why a block stayed
on the CPU, what `auto` decided and learned, the hardware key, and
the tiles and the devices a run on a set used.

### Loops that become blocks: `--par-auto`

With `--par-auto`, a `for (T i in a..b) { … }`
loop in plain code — or `a...b`, or the C-style `for (T i = a; i < b; i++)`
with `<=`, `++i`, `i += 1` or `i = i + 1` — becomes a `par` block when its
shape allows, so an existing program takes the GPU and every core without
being rewritten. The program need not import `Par.xc`: when a loop becomes a
block, `--par-auto` imports the runtime itself, and a program with nothing to
wrap is built without it.

```c
for (u32 i in 0..N)
    a[i] = (u32)3 * x[i] + y[i];            // becomes par autopar_1 { … }
u32 total = (u32)0;
for (u32 i in 0..N)
    total = total + a[i];                   // becomes par autopar_2 :reduce(+ total) { … }
```

A loop that does not qualify stays a loop, and the loops inside it are then
judged on their own, so the work inside a timing or retry loop is still found:

```c
for (u32 rep in 0..8) {                      // writes `first`: stays a loop
    total = (u32)0;
    for (u32 i in 0..N)
        total = total + a[i];                // becomes a block, once a repetition
    if (rep == (u32)0) first = total;
}
```

A loop qualifies when its body writes only its own locals, array elements,
and integer reductions — `acc = acc + e` or `acc += e` with `+`, `*`, `&`,
`|` or `^`, a count `acc++;`, or the smallest or largest value seen,
`if (e < acc) acc = e;` (any of `<`, `>`, `<=`, `>=`, `acc` on either side,
the same `e` twice and no `else`), `acc` an integer local used nowhere else
in the body — and is in the program's own files: loops in the standard library
are never wrapped. It must also have no `break` of its own, `return`, `goto` or label, and no outer name
incremented, taken by address or written through a member. A float
reduction is left alone (its sum would reassociate across the items) unless
the goal is speed, as is any other write to an outer variable. The decision
is made before parsing, from the loop's tokens, so it is the same in every
build.

**The goal.** A loop's `:goal(speed)` or `:goal(accuracy)` holds for the block
it becomes. Without one, the file's `#goal speed` or `#goal accuracy` line
sets the default, and without that the build's `-fgoal=`; under an explicit
speed, from any of the three, a `+` reduction over a `float` or `double` is
wrapped too. A loop marked `:serial` is never wrapped:

```c
#goal speed
float sum = 0.0f;
for (u32 i in 0..N)                     // becomes par autopar_1 :reduce(+ sum) :goal(speed)
    sum = sum + x[i] * y[i];
for (u32 i in 0..N) : serial            // left as it is
    order[i] = order[i - 1] + 1;
```

**Nests and block literals.** A loop whose body is nothing but a second
ascending loop, with bounds that do not depend on the outer index, becomes
one block over the whole `W × H` grid (the `:grid` form), so a small outer
count no longer limits the work items: `for (i in 0..480) for (j in 0..640)
… ` is 307200 items in one dispatch. Any other loop inside the body stays as
it is, run serially by each work item. A loop inside a block literal is
wrapped like any other; a loop inside a written `par` block is left alone.

What the tokens cannot tell, the compiler's `par` checks decide afterwards —
whether the items are independent (a scan, `b[i] = b[i - 1] + …`, is not)
and whether a GPU could run the body. A written `par` block that fails is an
error; an automatic one is **demoted to a serial run** instead, so the program
still means what it did. `-Wpar-auto` reports what was wrapped and what was
demoted, and why; it is off by default, since the report is useful once and
noise in every build after. Blocks the checks pass run as any `par` block
does: `auto` measures and chooses the device, and `XC_PAR_REPORT=1` names
them `autopar_<n>`.

### Across machines: `xcd`

 A GPU on another machine can be a worker on the same tile
queue. The other machine runs `xcd`, the par worker daemon, and the program
names it:

```
# on the machine with the GPU
XC_PAR_SECRET=… xcd -port 7227

# where the program runs
XC_PAR_SECRET=… XC_PAR_REMOTE=<that machine>:7227 ./prog
```

`XC_PAR_REMOTE` is a comma-separated list of `host[:port]`; each becomes a
worker named `remote:<host>:<device>` in `auto`'s hardware key, so the choice
learned with a remote present is kept apart from the one without. A run that
`auto` (or `XC_PAR=gpus` / `all`) sends to the set splits its tiles across the
local devices and the remote ones by their measured throughput, as it does
between two cards in one box; a tile travels as its range plus the slices it
reads of every array whose footprint the compiler knows (as a discrete card's
tile loop stages them), an array with no footprint travels once per run, and
the written slices and the reduction partials come back, folded in tile
order, so the result is the one a local run gives.

With a remote GPU present, `auto` has a fifth candidate: the remote GPUs
alone, the machine's own devices left out. A card across the network can be
many times faster than the machine's own (an integrated GPU beside a remote
RTX 5080), and in a set with it the slow device's share holds the fast one
back; this candidate is measured and learned like the other four, so such a
block goes to the remote card alone.

The daemon runs GPU kernels only (it has none of the program's compiled code),
and it needs the kernel form its GPU takes: build the program with
`-fpar-kernels=all`, which puts every form — Metal, PTX, SPIR-V, WGSL — in
every block, so a Mac program's blocks can run on an NVIDIA card across the
room; a build made where `XC_PAR_REMOTE` is set does this by itself. Both sides must be the same xcc version. `XC_PAR_SECRET` is a pool
secret the program proves to the daemon (SHA-256 over a nonce); a daemon
started without one takes any program on its network. `XC_PAR_REPORT=1` on
either side says what is sent and run.

Every connection is TLS. The daemon makes itself a certificate the first
time it starts, under `~/.xcc/xcd` (or the directory `XCD_HOME` names), and
prints its fingerprint on its serving line. The program keeps the fingerprint
it sees first for each daemon, in its `par` settings under
`tls.pin.<host>:<port>`, and refuses a daemon that later shows another one,
saying which pin to remove when the change is expected (a reinstalled
daemon, say). The TLS library is not linked into a program: it is loaded when
a daemon is first spoken to, from the toolchain's third-party tree
(`/opt/xcc/3p/tls` on macOS and Linux; the file `XC_TLS_LIB` names takes
precedence). A machine without it reports the daemon unreachable and the
program runs on; the daemon itself does not start without it.

The daemon's greeting says what it has: its GPU's memory and what is free
of it, and the machine's RAM, which the report shows (`par: remote worker …,
14761 MB of 16275 MB VRAM free`); each finished tile comes back with the
daemon's own time on it, summed in the report at the end of a run (`… items
in … us on the daemon's GPU`), so the link's share of a tile's time is
visible beside the compute's. The frames are tagged fields, read by tag, so
a side may carry a field the other does not know.

`XC_PAR_TRACE=<file>` (or `XC_PAR_TRACE=1`, which writes `par-trace.xcpt` in
the current directory) records every run on the tile queue: each
tile as it was handed out, to which device, what the queue expected it to
take, when it came back and how long the device itself spent on it. Open
the file with `tools/par-trace.html` in the compiler's source tree, a page
that draws each run as a timeline per device.

`XC_PAR_TRACE=<host>:<port>` sends the same records, as each run ends, to
`xcmon`, the par monitor in the `xcd` archive. It finds the daemons on the
subnet itself (`-pool NAME` for a pool, `-at host[:port],…` for others),
asks each for its heartbeat every second, and draws them and the programs
tracing to it in a browser page, a stack of cubes per machine, one cube per
device, lit while it has tiles out:

```sh
xcmon                                    # page at http://localhost:7480/
XC_PAR_TRACE=monitor-host:7482 ./prog    # this program's runs appear on it
```

A daemon that stops answering stays on the page, greyed, until it is
removed there. `-port N` moves the page (its feed takes N+1), `-trace N`
the port programs send to.

`XC_PAR_PROBE=1` makes a block's first run a probe: every
worker that takes the block, local or remote, runs it alone at tile sizes
from its floor up by powers of two, the arrays the block writes are put
back between passes, and the report prints each worker's curve, its knee
(the smallest tile at nine tenths of its best rate) and where it saturates,
and for a remote the link's share of the time. What it found is kept in the
program's settings as a starting point: the next run begins from those tile
sizes and rates and keeps adjusting as it goes. Use it once on a machine or
a network to find the boundaries rather than letting them be learned over
many runs.

A daemon keeps what it is sent: every whole array and every
tile's slice, by block, array, offset and length, with a hash of the bytes.
A later run of the block, by the same program or another, sends the hashes
first and the bytes only for what the daemon does not hold; a slice the
daemon wrote stays held too, so a pass over the last pass's result sends
nothing. The queue prefers, for a tile, a daemon that holds its slices. The
cache lives in the daemon's memory, least recently used out first, under
`xcd -cache MB` (half of the first card's memory by default); a slice gone
by the time a tile names it is simply sent again. The report shows, per
daemon, the bytes not sent, and the daemon's log what it served from the
cache.

A daemon checks its device memory before it takes work: a
block whose arrays and tiles in flight would not fit the memory its GPU
reports free is declined, and a tile that would not fit when it arrives
goes back to the program's queue for another device. The program's report
names the figures. A GPU that reports no free figure, as Vulkan devices do
not, is not checked.

A heartbeat measures the link when the program connects (its round trip, and
its bandwidth from a one-megabyte ping) and then asks the daemon every second,
while tiles are being handed out, whether it takes work now. The round trip
sets the smallest tile the program sends that daemon, so the latency is a few
percent of each tile's transfer at most. `xcd -nimby 09:00-17:00` keeps the
daemon's hours free: inside the window it takes no block from a new program
and tells a running one to send its tiles elsewhere, and the program's answer
is the same either way. The window may cross midnight (`-nimby 23:00-07:00`).

A daemon advertises itself on its subnet (multicast DNS, as `_xcd._tcp`),
and `xcd -pool NAME` names the pool it belongs to, so projects on one network
keep separate host sets. A program with no `XC_PAR_REMOTE` setting looks
for daemons by itself: at its first `par` run it asks the
subnet once, waits a moment, and takes every daemon that answered, of the
pool `XC_PAR_POOL` names (daemons with no pool when it is unset) and of its
own xcc version. `XC_PAR_REMOTE=none` keeps a program on its own machine,
as does `XC_PAR=cpu`; `XC_PAR_REMOTE=mdns` says the default in so many
words, and may be combined with addresses. A program carries the kernel
form of its own target's GPU unless it was built with `-fpar-kernels=all`
(or with `XC_PAR_REMOTE` naming a remote at build time, which means the
same), so a daemon of another kind takes a block only from a program built
that way; the daemon says so in its log. `xcd -no-mdns` keeps a daemon
off the air; it is still reachable by address. One subnet only: multicast
does not cross routers or VPNs.

A daemon that goes away mid-run costs the run nothing but time: the tiles it
held are handed to the other workers, and a tile is the same wherever it
runs, so the answer is the one a local run gives.

Several programs may use one daemon at once. Its GPUs serve one program's run
at a time: while one runs, another's heartbeat is told "not now" and it sends
its tiles elsewhere, and a run that waits too long for the GPUs is declined
for that run and asks again on the next.

What pays: blocks with a lot of work per byte moved (deep fractals, searches,
batched scoring) on a fast link. A streaming block moves more than it computes
and loses to the link, and `auto` measures that and keeps the local devices.

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

The test is the usual one for an index that is linear in the item (`k * i + c`):
two accesses can meet across items only when the difference of their offsets
is a multiple of the greatest common divisor of their strides. That
lets `a[2 * i] = a[2 * i + 1] * 3` through — the even elements are written and
the odd ones only read, so no item sees another's work — where the first rule
refused every pair with different offsets. An index computed from data is
taken as able to meet anything.

An offset held in a variable the block captures, `a[i + off] = a[i] * 3`,
cannot be settled when the program is built: an `off` of `n` keeps every
item to its own elements, and an `off` of `1` makes each item read the one
before it. Such a block is accepted with a check the runtime
makes before each run, using the variable's value then: where two items
could meet, the block runs serially, as its source reads, and
`XC_PAR_REPORT=1` says so. The check covers one captured integer, added
to or scaled into the index, with the same stride on both sides; anything
else is refused as before. A block whose GPU form cannot be built, so has
nowhere to carry the check, runs serially.

Two captured pointers the block sees as two arrays may be one block of
memory (`u32* b = a;`), which no test at compile time can rule out. The
runtime checks before each run: where two of a block's arrays
overlap and one is written, the block runs serially, one item after another,
as its source reads (`XC_PAR_REPORT=1` says so). Separate arrays are
unaffected.

## Errors in the shape

| The compiler refuses | Because |
| --- | --- |
| a body that is not one ascending loop (without `:grid`) | each work item is one iteration of a range |
| `return` with a value, or inside a loop of the body's own, in a `:grid` body | `return;` ends the work item, and inside a loop it would only end that loop |
| a `break` that would leave a `:grid` body | `return` ends a work item |
| assigning a captured scalar | each work item has its own copy; use a reduction or an array |
| a block without `#import "Par.xc"` | the block needs its runtime |
