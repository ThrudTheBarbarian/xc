---
title: Allocator & ARC
description: Picking between -falloc=bump and -falloc=heap, and between -farc=on automatic and -farc=off manual reference counting.
---

xcc has two independent flags that shape heap allocation:

- **`-falloc=bump|heap`** picks the *allocator*. Bump is fast and one-way; heap supports `delete` / `release`.
- **`-farc=on|off`** picks the *lifecycle policy*. ARC-on emits retains and releases automatically; ARC-off leaves lifecycle to the programmer.

The two flags combine. The defaults (`heap` on layouts with a `[heap]` region, `arc=on` everywhere) suit most programs. Use the other settings when a program has a specific need.

## Allocator: `-falloc=bump|heap`

```bash
xcc -falloc=bump tiny.xc -o tiny.xex
xcc -falloc=heap full.xc -o full.xex
```

### Bump allocator

```c
u8* buf = new u8[256];          // bump pointer advances by 256
// ... use buf ...
// no free — the bytes stay allocated for the rest of the program
```

A **bump allocator** reserves space by advancing a pointer. Allocation is cheap: a 16-bit add and a bounds check. There is no deallocation. `delete` is rejected at sema time, and ARC has nothing to call. When the space runs out, allocation stops.

Use bump when:

- The program allocates a fixed set of long-lived buffers up front and never frees them.
- Binary size matters more than the bytes spent on the heap allocator's coalescing logic.
- The target layout has no dedicated `[heap]` region.

The bump allocator is **always available**: every layout supports it. It is the **default** on layouts without a `[heap]` region.

### Heap allocator

```c
u8* buf = new u8[256];
// ... use buf ...
delete buf;                     // returns the bytes to the free list
```

The **heap allocator** differs by target. On **xt6502** it is a hand-written coalescing free list. Every allocation carries a 7-byte header (15-bit size, 1 free bit, 16-bit retain count). Every free returns the block to the list and merges it with any adjacent free blocks. Allocation is O(free-block count) for first-fit traversal. Free is O(1) for the release plus O(neighbour) for coalescing. A single block is capped at 32 KB because the free flag takes the top bit of the size field.

On the **native targets** (`arm64`, `x86_64`, `win64`, `arm9`, `m68k`) allocation goes through the host allocator with a 24-byte header (cookie, stride, count, `dealloc` pointer, refcount). Cost and size limit are the host allocator's, and the 15-bit cap does not apply.

On every target the **16-bit retain count is at `obj-2`**. The back ends' inline retain/release sequences depend on that position.

Use heap when:

- The program needs to free and reuse memory.
- Class instances come and go (heap classes need `dealloc`, which needs `release`, which needs the heap allocator).
- The program uses the `Heap.size()` / `Heap.largest()` / `Heap.totalSize()` introspection helpers.

The heap allocator is **available on any layout that declares a `[heap]` region** (the shipped 6502 `xt` layouts do) and on all five native backends. On those targets `-falloc=heap` is the default. A layout without a `[heap]` region falls back to bump and rejects heap-only constructs (`delete`, `release`, the introspection helpers) at sema time.

### Mixing

Mixing is not supported. The allocator choice is global per compile: `-falloc` is a single flag, not a per-class setting. If one program needs both behaviours, pick `heap` and use static or register variables for what you would otherwise bump-allocate.

## Reference counting: `-farc=on|off`

```bash
xcc -farc=on   game.xc -o game.xex      # default
xcc -farc=off  game.xc -o game.xex      # manual lifecycle
```

ARC and manual mode are **mutually exclusive per compile**. One program cannot mix them.

### `-farc=on` — automatic (default)

The compiler emits retains and releases where they are needed. Examples: when one slot is initialised from another (`Foo* b = a;` → retain), at scope exit (release every tracked strong class-pointer local, LIFO), and inside aggregate dealloc (release every strong class-pointer ivar before the bytes return to the free list). **You never write `retain` or `release`**; those statements are rejected at sema time.

The calling convention follows from these rules:

- A function returning a class pointer hands the caller a `+1` reference. The caller does not retain it.
- A class-pointer parameter is retained on entry and released on exit. This is net-neutral for transient use, and a store that outlives the call keeps the `+1` from the retain.

Full mechanics are on [Heap, ARC & weak refs](/compiler/language/memory/).

### `-farc=off` — manual

```c
Foo* p = new Foo();             // arrives with refcount 1
Foo* q = p;                     // q holds a *borrowed* reference
retain p;                       // refcount 2
// ... share / pass around ...
release p;                      // refcount 1
release q;                      // refcount 0 → dealloc → free
```

Manual mode disables every automatic retain and release the compiler emits under ARC. You write `retain` / `release` (or the deprecated `delete` alias) explicitly.

`retain` and `release` behave the same as the operations ARC emits. Both are null-safe, and `retain` saturates at `$FFFF` rather than wrapping, so a runaway loop cannot wrap the count through zero and cause a spurious free.

Use manual mode when:

- You are integrating with a hand-written runtime that has its own lifecycle rules.
- A specific lifecycle pattern (large pool, short-lived ownership transfer) does not match what ARC emits and you want explicit control.
- You are debugging a refcount mismatch and want to single-step retains and releases.

For most code, use ARC. It prevents forgotten releases, double frees, and (combined with `weak:`) leaks through reference cycles, at the cost of a few JSRs the program would emit anyway.

## The compose table

|             | `-farc=on` (default) | `-farc=off` |
|-------------|----------------------|-------------|
| `-falloc=heap` | **The default for capable layouts.** Allocator manages the heap; compiler manages refcounts. Write `new`; everything else is implicit. | Allocator manages the heap; you write `retain` / `release`. |
| `-falloc=bump` | New allocations succeed but nothing is ever freed. ARC retains and releases happen, but no `dealloc` runs at refcount 0 (the allocator cannot reclaim). Use only when you want a program that never frees. | New allocations succeed; you have no way to free. Equivalent in effect to ARC-on. |

`bump + arc=on` is the unusual combination; pick it only on purpose. The usual pairings are `heap + arc=on` (the default) and `heap + arc=off` (heap with hand-written lifecycle).

## Stack allocations are unaffected

Both flags govern only **heap** allocation. Stack-allocated class instances (`MyClass mine;` rather than `MyClass* p = new MyClass();`) live in the enclosing scope's local storage, and their lifetime is the scope, not a refcount. Neither the ARC mode nor the allocator choice changes them: they cost nothing to free, their lifetime is predictable, and their storage is reused at scope exit.

For stack vs heap class allocation, see [Classes → Two ways to allocate](/compiler/language/classes/#two-ways-to-allocate).
