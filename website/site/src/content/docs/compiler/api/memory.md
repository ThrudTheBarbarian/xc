---
title: Memory
description: "Bulk fill, clear, copy and overlap-safe move, using self-modifying 6502 inner loops for page-aligned bulk work. xt6502 only."
---

`Memory` is a static class of bulk byte primitives: fill, clear, copy, and an
overlap-safe move. All four methods are **`static`** and take **raw `u16`
addresses** rather than typed pointers. Take the address of the first element
and cast:

```c
#import <Memory.xc>

u8 screen[960];
Memory.memclr((u16)&screen[0], (u16)960);
```

## Overview

`Memory` lives in `support/xt6502/lib/` and is **xt6502 only**. Its method
bodies are inline 6502 assembly whose bulk paths patch the high byte of their own
`LDA`/`STA` instructions once per page (self-modifying code), which is where the
speed comes from. There is no stub in `generic/lib`: on other targets you get a
missing-class error naming the file, rather than a class that compiles and does
nothing.

:::note[Availability]
`Memory` exists only in the **xt6502** support tree. A program that calls one of
its methods on any other backend fails at assembly time (the inline 6502
mnemonics are unrecognised there). Unlike [`Sort`](/compiler/api/sort/) and
[`Assert`](/compiler/api/assert/), it is **not** a cross-platform generic class.
:::

## Topics

**Bulk operations** · [memset](#memset) · [memclr](#memclr) · [memcpy](#memcpy) · [memmove](#memmove)

---

## Bulk operations

All four return immediately when `len == 0`.

### memset
```c
static void memset(u16 addr, u8 val, u16 len)
```
Sets `len` bytes starting at `addr` to `val`. It handles an arbitrary
`[addr, len)` in three phases: leading bytes up to the next page boundary go
through a simple per-byte loop, the page-aligned middle runs an unrolled 16-`STA`
inner loop, and the trailing bytes use the simple loop again. The bulk middle
costs about **5.7 cycles/byte**, compared with roughly **11 cycles/byte** for a
naive `(ptr),Y` loop.

### memclr
```c
static void memclr(u16 addr, u16 len)
```
Shorthand for `memset(addr, $00, len)`: fills `len` bytes with zero.

### memcpy
```c
static void memcpy(u16 dst, u16 src, u16 len)
```
Copies `len` bytes from `src` to `dst`. **Source and destination must not
overlap.** If overlap is possible or unknown, use [`memmove`](#memmove). A
4-cycle check at the top of the call picks one of two paths:

| Case | Inner loop | Cost |
|---|---|---|
| `src` **and** `dst` both page-aligned | unrolled 16×(`LDA`+`STA`) absolute,Y, high bytes patched once per page | ~10 cycles/byte |
| anything else, and every trailing partial page | simple indirect-`Y` loop | ~16 cycles/byte |

The fast path needs *both* addresses on a page boundary; otherwise the 16
absolute-addressed stores would cross a page mid-loop. The check pays for itself
as soon as a copy spans one full aligned page, so there is no need to choose
between the paths yourself.

### memmove
```c
static void memmove(u16 dst, u16 src, u16 len)
```
Overlap-safe copy. When `dst <= src` (or the regions do not overlap) it calls
[`memcpy`](#memcpy). When `dst > src` and the regions might overlap, it copies
**backward** from the highest byte so the source is not overwritten mid-copy.
The backward path is the simple indirect-`Y` loop with no unrolling, because
overlapping copies are typically small in-buffer shifts where page alignment
would not help.

[↑ Topics](#topics)

## Self-modifying code

The unrolled paths patch the high byte of their own `LDA` / `STA` instructions
once per page, so the method body must live in **writable RAM**. xcc methods
always do, whatever their placement (`:main`, `:banked`, `:shadow`), so you have
nothing to arrange.

## Reachability

If a program never calls `memset` / `memclr` / `memcpy` / `memmove`, the
bodies are stripped at link time. Importing the file with `#import` alone costs
nothing.
