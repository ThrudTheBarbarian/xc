---
title: Heap
description: "Runtime introspection on the coalescing free-list allocator: free bytes, largest extent, and compile-time capacity, with a complete method reference."
---

`Heap` reports the state of the allocator at runtime: how many bytes are free,
the size of the largest single free extent, and the compile-time heap capacity.
It does not allocate; `new` and `delete` do that.

```c
#import <Heap.xc>          // or the Foundation umbrella
```

## Overview

`Heap` is a `static` utility class. Call every method on the class
(`Heap.size()`), never on an instance; the `init` exists only as class
boilerplate. It is meaningful only under `-falloc=heap`, which is the default on
the 6502 `xt` layouts and on every native backend. With a bump allocator there
is no free-list metadata, so [`size`](#size) and [`largest`](#largest) would
report misleading values.

All three counts are in **bytes** and **include** the 4-byte per-block header
(2-byte size + 2-byte retain count) the allocator stores in front of every
allocation. A `new u8[100]` consumes **104** bytes from [`size`](#size), not 100.

:::note[Availability]
This page documents the **xt6502** allocator's introspection, which walks the
coalescing free list across the reserved banks. The native backends ship their
own `Heap` (`support/arm64/lib/Heap.xc`) with the same three methods, but there
the host OS owns the process heap, so the methods return fixed placeholder
figures rather than walking a free list. Treat the values as informational on
native targets; they are accurate only on xt6502.
:::

## Topics

**Introspection** · [size](#size) · [largest](#largest) · [totalSize](#totalsize)

---

## Introspection

### size
```c
static u32 size(void)
```
Total free bytes, summed across every free block in every reserved bank. The
return type is `u32` because a multi-bank heap can exceed 64 KB: the 6502 `xt`
heap grows on demand across the data window's pages. Cost is O(free-block count)
per bank, so it is safe to call often but not free.

### largest
```c
static u16 largest(void)
```
The size of the biggest single **contiguous** free extent. First-fit allocation
cannot satisfy a request larger than this, even when [`size`](#size) is much
bigger: fragmentation can leave plenty of total free space and no large block.
The return type is `u16` because one free extent never spans a bank boundary; it
is bounded by the flat region or a single 16 KB bank. To test whether `new T[N]`
will fit, compare `largest()` against `N` plus the 4-byte header:

```c
if (Heap.largest() < (u16)needed + 4) {
    Stdio.print("not enough contiguous heap; bailing\n");
    return;
}
u8* buf = new u8[needed];
```

### totalSize
```c
static u32 totalSize(void)
```
The compile-time heap capacity: the sum of `heap_end - heap_low` over every
bank the layout reserves (banked heaps), or the flat region size (single-region
layouts). The codegen emits it as the linker-resolved constant
`heap_total_bytes` (with `_b2`/`_b3` equates for the high half), so it costs
nothing at runtime and is correct on both single- and multi-bank layouts.

[↑ Topics](#topics)

## Worked example

```c
#import <Stdio.xc>
#import <Heap.xc>

void main(void)
{
    u32 free  = Heap.size();
    u16 max   = Heap.largest();
    u32 total = Heap.totalSize();
    Stdio.printf("heap: %lu free of %lu (largest extent: %u)\n", free, total, max);
}
```
