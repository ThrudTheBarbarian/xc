---
title: Allocator & ARC
description: Picking between -falloc=bump and -falloc=heap, and how automatic reference counting interacts with the allocator.
---

**`-falloc=bump|heap`** picks the *allocator*. Bump is fast and one-way; heap supports `delete` and frees class instances when their refcount reaches zero. The default, `heap` on layouts with a `[heap]` region, suits most programs.

Reference counting is not a choice: ARC is always on (see [Reference counting](#reference-counting)).

Every supported target has a heap region, so every build uses the heap allocator. `xcc` accepts `-falloc=heap`, and accepts `-falloc=bump` with a warning that the build is unchanged. The bump allocator below applies only to a layout without a `[heap]` region, and no shipped layout lacks one.

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

On the **other targets** allocation goes through the host allocator, or on wasm32 the module's own, with a header holding a cookie, the stride, the count, the `dealloc` pointer, the weak-slot list head and the retain count. Cost and size limit are the allocator's, and the 15-bit cap does not apply.

The retain count is the last field of the header: 16-bit at `obj-2` on xt6502, m68k, arm9 and wasm32, and 32-bit at `obj-4` on arm64, x86_64 and win64. The back ends' inline retain/release sequences depend on that position. See [Memory model](/compiler/language/memory/) for the header size on each target.

Use heap when:

- The program needs to free and reuse memory.
- Class instances come and go (heap classes need `dealloc`, which needs `release`, which needs the heap allocator).
- The program uses the `Heap.size()` / `Heap.largest()` / `Heap.totalSize()` introspection helpers.

The heap allocator is **available on any layout that declares a `[heap]` region** (the shipped 6502 `xt` layouts do) and on all five native backends. On those targets `-falloc=heap` is the default. A layout without a `[heap]` region falls back to bump and rejects heap-only constructs (`delete`, `release`, the introspection helpers) at sema time.

### Mixing

Mixing is not supported. The allocator choice is global per compile: `-falloc` is a single flag, not a per-class setting. If one program needs both behaviours, pick `heap` and use static or register variables for what you would otherwise bump-allocate.

## Reference counting

ARC is always on. The compiler emits retains and releases where they are needed. Examples: when one slot is initialised from another (`Foo* b = a;` → retain), at scope exit (release every tracked strong class-pointer local, LIFO), and inside aggregate dealloc (release every strong class-pointer ivar before the bytes return to the free list). **You never write `retain` or `release`** on a class instance; those statements are rejected at compile time.

The calling convention follows from these rules:

- A function returning a class pointer hands the caller a `+1` reference. The caller does not retain it.
- A class-pointer parameter is retained on entry and released on exit. This is net-neutral for transient use, and a store that outlives the call keeps the `+1` from the retain.

Full mechanics are on [Heap, ARC & weak refs](/compiler/language/memory/).

Earlier releases documented `-farc=off`, a manual lifecycle mode. The flag never changed the generated code and is retired: `xcc` accepts it with a warning that it does nothing.

### With the bump allocator

Under `-falloc=bump`, ARC retains and releases still happen, but no `dealloc` runs at refcount 0, because the allocator cannot reclaim. Use it only when you want a program that never frees. The usual setting is `-falloc=heap`, the default on capable layouts.

## Stack allocations are unaffected

The allocator and ARC govern only **heap** allocation. Stack-allocated class instances (`MyClass mine;` rather than `MyClass* p = new MyClass();`) live in the enclosing scope's local storage, and their lifetime is the scope, not a refcount. Neither ARC nor the allocator choice changes them: they cost nothing to free, their lifetime is predictable, and their storage is reused at scope exit.

For stack vs heap class allocation, see [Classes → Two ways to allocate](/compiler/language/classes/#two-ways-to-allocate).
