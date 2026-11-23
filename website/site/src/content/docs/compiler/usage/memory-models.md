---
title: Memory models
description: The -m flag and the xt6502 memory map, with two bank windows, a 4 KB hardware stack, and the on-demand banked heap.
---

A **memory model** is the layout a 6502 build targets: where code and data live, how
banking works, and where the stack and heap sit. Pick one with `-m <name>`.

```bash
xcc -m xt app.xc -o app.xex
```

Memory models apply to the **6502 backend only**. The other six targets
(`arm64`, `x86_64`, `win64`, `arm9`, `m68k`, `wasm32`) are native platforms, or a
managed runtime in the case of `wasm32`, with their own loaders. They have no layout
to choose, and `-m` does not apply. The fixed wasm32 layout and the Atari ST's stack are
described [below](#the-wasm32-layout).

`-m xt` implies `-A 6502`, so it selects the target on its own.

To list every layout the compiler ships with:

```bash
xcc --list-layouts
```

To inspect a layout's memory map:

```bash
xcc --dump-layout -m xt
```

## The xt6502 target

There is **one** 6502 target: **xt6502**, a custom FPGA 6502 core. The `xl`
(flat 64 KB) and `xe` (PORTB-banked) models, the `rambo*` / `compy*` expansion variants, and
the Commodore `c64` target are **not supported**. `-m xl`, `-m xe` and `-m c64` fail with
an error instead of producing a program that won't run.

The shipped layout is:

```
xt         ← the standard model: two bank windows + on-demand banked heap
```

`support/xt6502/layouts/xt.lnk` is the **single source of truth** for the map. The code
generator, the assembler (`xcc-as`) and the simulator (`xcc-sim-6502`) all read the bank
registers and regions from it; none of them hardcodes these values.

## The map

```
$0500-$07FF   spill-frame region (grows up)
$2400-$3FFF   system region — entry point, startup, descriptors, literals
$4000-$5FFF   screen RAM
$6000-$9FFF   CODE bank window — one 16 KB page, selected by $D5C0
$A000-$CFFF   DATA bank window — one 12 KB page, selected by $D5C1
$D800-$FFF9   unbanked code
```

Entry is at `$2400`.

### Two windows, memory-mapped selectors

The bank selectors are **memory-mapped registers**, not zero page: **`$D5C0`** selects the
code window and **`$D5C1`** the data window. Zero-page selectors would not work, because
the boot ROM's RAM-clear loop zeroes zero page during initialisation. Generated code and
the runtime asm see the selectors as the symbols `__bank_code_reg` / `__bank_data_reg`,
taken from the layout.

With an 8-bit selector each:

| Window | Page size | Pages | Addressable |
|---|---|---|---|
| Code (`$6000-$9FFF`) | 16 KB | 256 | **4 MB** of code |
| Data (`$A000-$CFFF`) | 12 KB | 256 | **3 MB** of data |

**Code lives in two places only**: the code-bank pages and the unbanked `$D800-$FFF9`
region. It is **never** placed in the data window. `main` and a few helpers that must stay
resident run unbanked. Everything else is packed into 16 KB code pages and reached through
the unbanked `_xcall` trampoline, which saves the current code bank, switches, calls, and
restores.

Banking is invisible to the source:

```c
class World  { … }     // lands in some code bank
class Player { … }     // possibly a different one

i16 main(void)
{
    World*  w = new World();
    Player* p = new Player();
    p.bumpInto(w);      // cross-bank call — the trampoline handles it
    return 0;
}
```

Banking is **function-granular**, so a single function larger than the 16 KB window cannot
be placed. `xcc-as` fails the build rather than putting code where it can't run. Split the
function into smaller ones. Intra-function banking is a planned fix (see
[Future work](/compiler/future-work/)).

### Pointers carry their bank

xcc's 6502 pointers are **three bytes**: `[addr-lo, addr-hi, data-bank]`. The backend writes
`$D5C1` from byte 2 on **every** dereference, so a pointer into any of the 256 data pages
needs no annotation or manual bank switching.

### The hardware stack

The xt6502 core has a **4 KB hidden hardware stack** (12-bit SP) with SP-relative addressing
(`d,SP`, `(d,SP),Y`, `d,SP,X`). It is the primary stack: it carries frames, parameters and
register spills, and the runtime libraries push their recursion frames on it. Its top 256
bytes alias `$0100-$01FF`, so existing `TSX` + `$0100,X` code still works.

There is **one** software stack pointer (SSP). It is used only for the rare non-leaf spill
frame whose pinned locals don't fit in zero page, and those frames live in the
`$0500-$07FF` region.

### The heap grows on demand

`xt` declares a **banked free-list heap** in the data window, which makes `-falloc=heap`
(and therefore ARC, `new` / `delete`) the default on this target. The heap is
*on-demand*: it claims one data bank at a time from a shared bank bitmap as allocation
needs it, grows up to the window's last page (3 MB), and gives empty banks back.

There is no fixed reservation to tune, and a program uses as much heap as it needs without
editing the layout. The one limit: **a single allocation cannot span a bank boundary**, so
no one object may exceed ~12 KB. Total heap size is unaffected.

## The wasm32 layout

A wasm32 program's linear memory, from address 0 up:

```
0x00000             unused: an address below 0x10000 is a class id, not a pointer
0x10000             shadow stack, 1 MiB by default; __sp starts at its top
                    and the stack grows down towards 0x10000 (__stack_low)
stack top           the program's static data, up to __data_end
__data_end          each wasm library's static data, placed by the loader
__heap_base         the heap, on a 64 KiB boundary, growing the memory as needed
```

Static data comes after a fixed-size stack, so a program's data can be as large as it
needs without leaving the stack less room. Each function that uses the shadow stack checks
its frame against `__stack_low` on entry. A call that would pass the bottom of the stack
traps (`RuntimeError: unreachable`) before it writes anything, so an overflow stops the
program and never overwrites data.

`-ss <n>` (`--stack-size <n>`) sets the shadow stack's size in bytes, rounded up to 16:

```bash
xcc -A wasm32 -ss 0x400000 app.xc -o app.wasm    # a 4 MiB stack
```

A wasm library has no stack of its own. Its functions run on the app's stack, so the
option goes on the app's build.

When an app imports wasm libraries, the loader places each library's data after
`__data_end`, growing the memory to fit, and then moves `__heap_base` above the last
library before the program runs. The ARC runtime treats an address below `__heap_base` as
static or stack storage and an address above it as a heap object. Library data must
therefore sit below the heap.

## The Atari ST stack

At start-up a GEMDOS program (`-A atarist`) keeps the memory it needs and gives the rest
back to TOS: its text, data and bss, the 256-byte basepage, and a stack reserve above
them. The stack starts at the top of that block and grows down. The heap is allocated from
TOS separately, so the reserve is all the stack there is. A program that recurses deeply,
or keeps large local arrays, needs a bigger reserve; one for a 512 KB machine may want a
smaller one.

The reserve is 64 KB unless `-ss <n>` (`--stack-size <n>`) sets it, in bytes, rounded up
to a multiple of 4:

```bash
xcc -A atarist -ss 0x8000 app.xc -o app.prg      # a 32 KB stack
```

## Libraries resolve by architecture × platform

The standard library is selected on **two** axes: the backend's CPU tree
(`support/xt6502/`, `support/arm64/`) and the architecture-neutral `support/generic/lib`
beneath it. A platform-specific file of the same name takes precedence. This lets one
`Stdio.xc` or `Math.xc` source serve a banked 6502 and a 64-bit host.

## Customising or writing your own

Every memory model is a `.lnk` file under `support/xt6502/layouts/`. The files are
commented, and the format is documented at
[Linker scripts (.lnk)](/compiler/usage/linker-scripts/). Copy one and modify it, then pass
your file with `-m ./my-layout.lnk`, or put it next to the shipped layouts and reference it
by name.
