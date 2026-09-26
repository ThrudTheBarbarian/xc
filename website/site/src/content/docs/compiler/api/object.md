---
title: Object
description: "The universal root class: pointer-identity equals, an address-derived hash, the description hook every class inherits and overrides, and runtime class names."
---

`Object` is the universal root class. Every class you write without an explicit
parent (every `class X { … }`) inherits from it implicitly. Its protocol
methods are the defaults your own types get, and the ones a
[`Map`](/compiler/api/map/), [`Set`](/compiler/api/set/) or
[`Array`](/compiler/api/array/) uses when you don't override them. It also
gives every object its class name at run time, and makes an instance from a
class name.

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
- [`encodeWithCoder`](#encodewithcoder--initwithcoder) and
  [`initWithCoder`](#encodewithcoder--initwithcoder) archive nothing.

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
- [`Codable`](/compiler/api/codable/): the empty
  [`encodeWithCoder` / `initWithCoder`](#encodewithcoder--initwithcoder) pair,
  so any object can be given to a [`Coder`](/compiler/api/coder/). Not on
  xt6502, where `Object` has only the three methods above.

Every class is an `Object`, so every class has these protocol vtables and
defaults from the moment it is declared.

## Topics

**Protocol methods** · [equals](#equals) · [hash](#hash) · [description](#description) · [encodeWithCoder / initWithCoder](#encodewithcoder--initwithcoder)

**Class names** · [className](#classname) · [newInstanceOfClass](#newinstanceofclass)

---

## Protocol methods

The hooks your classes inherit and override.

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

### encodeWithCoder / initWithCoder
```c
void encodeWithCoder(Coder* coder)
void initWithCoder(Coder* coder)
```
The [`Codable`](/compiler/api/codable/) pair, empty here. A class with state to
archive overrides both and calls `super` first, so every level of a hierarchy
codes its own fields; see [`Codable`](/compiler/api/codable/) for an example.
Not present on xt6502.

[↑ Topics](#topics)

---

## Class names

The name of an object's class at run time, and an instance made from a name.
A keyed archiver uses the pair: it writes `className()` beside each object's
fields, and reads the object back with `newInstanceOfClass`.

```c
Object* o = new Circle();
Stdio.printf("%s\n", o.className().cString());      // Circle

Object* c = Object.newInstanceOfClass(String.withCString("Circle"));
```

:::note[Availability]
Every target except xt6502. On xt6502 `Object` does not have these methods,
and calling one is a compile error.
:::

### className
```c
final String* className(void)
```
The name of the receiver's class as written in its source: `"Circle"` for a
`Circle`, even when you hold it as an `Object*` or as a pointer to one of its
parents. The result is a new [`String`](/compiler/api/string/) that the caller
owns. `className` is `final`: a class cannot override it.

It works for an instance whose class came from another module, a `-c` object
or an `--emit-lib` library, because each module records the names of the
classes it defines. It returns null for an instance of a class built by an
older compiler, which recorded no names.

### newInstanceOfClass
```c
static Object* newInstanceOfClass(String* name)
```
A new instance of the class called `name`, made as `new C()` makes one: it
comes back with a reference count of 1, owned by the caller, and the class's
zero-argument `init` runs, after its parents' `init`s as usual. A class that
declares only `init`s with parameters comes back zero-filled with no `init`
run, as `new C()` does for it. Returns null when `name` is null or no class of
that name can be found.

The search covers the classes of the module that holds `main` (or, called from
inside a library, the library's own classes), and then every module it
imports, and every module those import, in import order. A class in a `-c`
object or an `--emit-lib` library is found when the program `#import`s that
module. A library cannot find a class that only its client defines.

A program that uses neither method and imports no module pays a few dozen
bytes at most. A library, a `-c` object, or a program that imports one carries
a small table: one name function per class, and one function that makes each
class by name.

[↑ Topics](#topics)
