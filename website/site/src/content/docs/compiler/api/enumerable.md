---
title: Enumerable
description: "Protocol that lets a class instance be walked with the for-in loop."
---

`Enumerable` is the protocol a class adopts so its instances can drive a
`for (T* x in collection)` loop. It provides a count and an indexed accessor
that the for-in codegen calls.

```c
class MyContainer <Enumerable> { ... }
```

## Overview

xc's `for … in` handles fixed-size arrays, slices, ranges and heap-allocated
pointers: anything where the codegen can derive a count and an element address
up front. A **class instance** can't be walked that way because its storage
layout is private. A class that conforms to `Enumerable` provides two methods
the loop can call, and the codegen rewrites

```c
for (Object* e in col) { body; }
```

into a counted loop that reads [`enumLength`](#enumlength) **once** at loop entry
and calls [`enumAt`](#enumat) on each iteration. The walk is stateless, so nested
iteration over the same collection works and `break` / `continue` behave
normally. Calls go through the protocol's vtable slot, so the concrete class's
methods run even when the static type of `col` is `Object*`.

## Required methods

**Topics** · [enumLength](#enumlength) · [enumAt](#enumat)

### enumLength
```c
u32 enumLength(void);   // xt6502: u16
```
Return the total number of elements. The for-in codegen reads this once, at loop
entry, to bound the loop.

[↑ Topics](#required-methods)

### enumAt
```c
Object* enumAt(u32 i);
```
Return the element at 0-based index `i`. The element type is `Object*`. A
container storing typed pointers ([`Number`](/compiler/api/number/),
[`String`](/compiler/api/string/), user classes) returns them here, and the loop
body downcasts if it needs the concrete type:

```c
for (Object* o in arr) {
    Number* n = (Number* ?)o;
    if (n != 0) Stdio.printf("%d\n", n.asI16());
}
```

[↑ Topics](#required-methods)

## Conforming types

Standard-library containers that conform (each implements `enumLength` and
`enumAt`):

- [`Array`](/compiler/api/array/)
- [`Map`](/compiler/api/map/)
- [`Set`](/compiler/api/set/)

Primitive-element collections ([`String`](/compiler/api/string/)'s `u8`
characters, [`Data`](/compiler/api/data/)'s `u8` bytes) use the pointer-style
for-in and don't box each element through `Object*`.

## Usage

Adopt `Enumerable` on a custom container so callers can walk it with the same
`for … in` they use on the built-in collections, without exposing its internal
layout. Iteration is index-based and stateless, so two loops over the same
instance, including nested ones, don't interfere.
