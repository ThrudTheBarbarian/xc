---
title: Hashable
description: "Protocol for hash codes that let a class key a Map or Set."
slug: versions/0.86/compiler/api/hashable
banner:
  content: 'This is the documentation for xc 0.86. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

`Hashable` is the protocol a class adopts so its instances can key a
[`Map`](/versions/0.86/compiler/api/map/) or be stored in a [`Set`](/versions/0.86/compiler/api/set/). It
pairs a hash code with value equality.

```c
class MyKey <Hashable, Comparable> { ... }
```

## Overview

A hashed collection finds a candidate slot from a key's hash, then confirms the
match by equality. `Hashable` therefore declares **both** a hash and an
`equals`. A hash alone can only select a bucket; it cannot decide which entry in
the bucket is the one you want.

The `equals` slot is the *same* slot [`Comparable`](/versions/0.86/compiler/api/comparable/)
declares, so a class listing `<Comparable, Hashable>` writes one `equals` body
and satisfies both protocols: two vtable entries, one implementation.

## Required methods

**Topics** · [hash](#hash) · [equals](#equals)

### hash
```c
u32 hash(void);   // xt6502: u8
```
Return a hash code derived from the value of `self`. The hard requirement is
**consistency**: equal values (per [`equals`](#equals)) must produce equal hash
codes, or a lookup misses what `set()` stored. The distribution need not be
perfect; any non-degenerate hash keeps probe chains short at realistic loads.
Foundation's byte-hashing implementation (`String`) FNV-1a-folds the bytes, and
`Number` and `Object` fold their value or address with an XOR–multiply. Either
approach is easy to copy for a user type.

[↑ Topics](#required-methods)

### equals
```c
bool equals(Object* other);
```
Value equality, identical to [`Comparable.equals`](/versions/0.86/compiler/api/comparable/#equals):
downcast `other` with a safe-checked cast and return `true` only when the values
match. A lookup uses it to pick the right entry out of a bucket's probe chain.

[↑ Topics](#required-methods)

## Conforming types

Standard-library classes that conform (each implements `hash` and `equals`):

- [`Object`](/versions/0.86/compiler/api/object/): the root declares `<Hashable, Comparable>`, so every object has an identity-based default hash and equality until it overrides them.
- [`String`](/versions/0.86/compiler/api/string/): FNV-1a over the bytes.
- [`Number`](/versions/0.86/compiler/api/number/): hashes the numeric value.
- [`Data`](/versions/0.86/compiler/api/data/): hashes the byte buffer.

See also the sibling protocols [`Comparable`](/versions/0.86/compiler/api/comparable/) and
[`Copying`](/versions/0.86/compiler/api/copying/).

## Usage

Conform to `Hashable` (plus [`Comparable`](/versions/0.86/compiler/api/comparable/)) to use a
type as a [`Map`](/versions/0.86/compiler/api/map/) key or [`Set`](/versions/0.86/compiler/api/set/) member.
`Hashable` locates the bucket, and `Comparable`'s `equals` confirms the match
inside it. The two protocols are independent, so a value-only collection can use
`Comparable` alone without a hash.
