---
title: Sort
description: "In-place quicksort over a u16 array, ordered by a user-supplied comparator."
---

`Sort` is an in-place quicksort over a `u16` array, with the ordering supplied by
a user-written comparator. The comparator follows the standard C `qsort`
convention: negative, zero or positive for less, equal or greater. The only
public entry point, [`qsort`](#qsort), is **`static`**.

```c
#import <Sort.xc>
```

## Overview

`Sort` lives under `support/generic/lib/`, so it works the same on every
platform. The implementation is a recursive Lomuto-partition quicksort with the
pivot at the high end of each partition, sorting in place with no auxiliary
buffers. The recursive driver (`_xtc_qsortRec`) is a free function rather than a
class method, so on the banked target its `cmp` parameter slot cannot collide
with the comparator's own parameter window.

The comparator type is:

```c
typedef i16 cmpU16_t(u16, u16);
```

Define your own with that signature:

```c
i16 ascending(u16 a, u16 b) {
    if (a < b) { return (i16)-1; }
    if (a > b) { return (i16)1; }
    return (i16)0;
}

i16 descending(u16 a, u16 b) { return ascending(b, a); }
```

:::note[Why i16 and not i8]
The comparator returns `i16` for the same reason C's `qsort` uses `int`. xcc's
codegen currently treats an `i8` call result as **unsigned** when a relational
operator consumes it directly (`cmp(x, y) < 0`), so the `< 0` test on an `i8`
comparator would never be true for negative returns. Returning `i16` avoids
this. The alternative is to store the result in a named local before the test.
:::

## Topics

**Sorting** · [qsort](#qsort)

**Lifecycle** · [init](#init)

---

## Sorting

### qsort
```c
static void qsort(u16* base, u16 n, cmpU16_t* cmp)
```
Sorts the `n` elements of `base` in place, ordering them by `cmp`. Arrays of
fewer than two elements return immediately.

```c
void main(void) {
    u16 arr[8] = {7, 2, 9, 1, 5, 8, 3, 6};
    Sort.qsort(arr, (u16)8, &ascending);
    for (u16 v in arr) {
        Stdio.printf("%u ", v);
    }
    Stdio.print("\n");                       // 1 2 3 5 6 7 8 9
}
```

[↑ Topics](#topics)

## Lifecycle

### init
```c
void init(void)
```
The trivial zero-argument initializer (the class has a single dummy ivar).
`qsort` is static, so you never need an instance.

[↑ Topics](#topics)

## Global arrays

Sorting a module-scope array works the same as sorting a local one. A global
`u16[]` sorts correctly on **both** live backends (arm64 and xt6502), at `-O0`
and at the default `-O3`:

```c
u16 g[4] = {4, 1, 3, 2};

void main(void) {
    Sort.qsort(g, (u16)4, &ascending);   // 1 2 3 4
}
```

## Recursion and the call stack

On **xt6502**, the internal driver of `Sort.qsort` is recursive. The codegen
marks recursive functions ineligible for the static-frame fast path, so the
driver allocates its frame on the software stack. Non-recursive comparators stay
eligible, so the comparator itself costs no more than an indirect `JSR`. On the
register targets the frame is an ordinary stack frame and none of this applies.

For arrays of thousands of elements, watch the recursion depth: worst-case
quicksort is O(N) deep on already-sorted input. The xcc stack size can be raised
with `-ss` / `--stack-size`.
