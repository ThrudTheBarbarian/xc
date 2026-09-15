---
title: Object
description: "The universal root class: pointer-identity equals, an address-derived hash, and the description hook every class inherits and overrides."
---

`Object` is the universal root class. Every class you write without an explicit
parent (every `class X { … }`) inherits from it implicitly. Its three methods
are the defaults your own types get, and the ones a
[`Map`](/compiler/api/map/), [`Set`](/compiler/api/set/) or
[`Array`](/compiler/api/array/) uses when you don't override them.

```c
#import "Foundation.xc"          // Object comes in with the umbrella
```

## Overview

You write nothing to inherit from `Object`: it is the implicit parent of any
parentless `class`. An `Object*` accepts a pointer to any class you define, and
any of your instances fits wherever an `Object*` is expected.

Its defaults are the cheapest correct implementations:

- [`equals`](#equals) is **pointer identity**: two `Object*`s are equal only
  when they point at the same heap block.
- [`hash`](#hash) folds the receiver's **address**. Distinct instances live at
  distinct addresses, so they always hash apart.
- [`description`](#description) returns the placeholder `<Object>`.

The pointer hash is **not cached** on the instance. It takes two instructions,
so a one-byte cache field on every object in the program would cost more memory
than it saves in cycles. A class whose hash is expensive (a long
[`String`](/compiler/api/string/)) can cache it in a private ivar of its own.

Override [`equals`](#equals) and [`hash`](#hash) **together** when your class
needs *value* semantics rather than identity. [`Number`](/compiler/api/number/)
compares by stored numeric value; [`String`](/compiler/api/string/) and
[`Data`](/compiler/api/data/) fold over their bytes. The default hash is
address-derived and varies between runs, which is why
[`Map`](/compiler/api/map/) and [`Set`](/compiler/api/set/) iterate in insertion
order rather than hash order.

:::note[Availability]
`hash` returns the target's native hash width: **`u32`** on the 32-bit generic
build (arm64, arm9, m68k, x86_64) and **`u8`** on the xt6502 build, where a
four-byte hash on every lookup is too costly for an 8-bit CPU. The width comes
from the [`Hashable`](/compiler/api/hashable/) protocol. `hash` is the only
width-dependent part of `Object`, so `Object` is shared across targets rather
than duplicated.
:::

## Conforms to

- [`Hashable`](/compiler/api/hashable/): [`hash`](#hash) makes any object usable
  as a [`Map`](/compiler/api/map/) / [`Set`](/compiler/api/set/) key.
- [`Comparable`](/compiler/api/comparable/): [`equals`](#equals) is the
  required slot. The optional `compare` is not implemented (identity has no
  natural order), so plain `Object`s have equality but no ordering.

Every class is an `Object`, so every class has these protocol vtables and
defaults from the moment it is declared.

## Topics

**Protocol methods** · [equals](#equals) · [hash](#hash) · [description](#description)

---

## Protocol methods

The complete public surface: the three hooks your classes inherit and override.

### equals
```c
bool equals(Object* other)
```
Pointer identity: `true` only when `self` and `other` are the same heap block.
This is the [`Comparable`](/compiler/api/comparable/) / [`Hashable`](/compiler/api/hashable/)
`equals` slot, dispatched through the vtable every object carries. Override it
(together with [`hash`](#hash)) to give your class value semantics.

### hash
```c
u32 hash(void)          // u8 on the xt6502 build
```
An XOR-and-multiply scramble of the receiver's address (a plain XOR-fold of the
low address bytes on the 6502). Distinct instances live at distinct heap
addresses, so they always hash apart. This is the
[`Hashable`](/compiler/api/hashable/) method, so any object can key a
[`Map`](/compiler/api/map/) or [`Set`](/compiler/api/set/) with no extra work.
It is not cached; see [Overview](#overview).

### description
```c
String* description(void)
```
A [`String`](/compiler/api/string/) describing the object. The default returns
the placeholder `<Object>`. `Stdio.printf`'s `%@` conversion dispatches through
this hook, so overriding it controls how your class prints: a
[`Number`](/compiler/api/number/) renders its value, and a
[`Data`](/compiler/api/data/) renders `<Data 4: deadbeef>`.

[↑ Topics](#topics)
