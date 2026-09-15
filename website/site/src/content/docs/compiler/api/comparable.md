---
title: Comparable
description: "Protocol for value equality, and optionally a total ordering, across heterogeneous Object* references."
---

`Comparable` is the protocol a class adopts to be compared **by value** rather
than by pointer identity. Equality is required; a total ordering is optional.

```c
class MyType <Comparable> { ... }
```

## Overview

By default, two `Object*` references are equal only when they are the same
pointer. For value-like data, such as two `Number`s holding `42` or two
`String`s spelling `"go"`, you usually want value equality. Conforming to
`Comparable` lets a class define when two of its instances are equal, so
instances can be stored in the value-comparing collections
([`Array`](/compiler/api/array/), [`Map`](/compiler/api/map/),
[`Set`](/compiler/api/set/)) and found by content instead of by address.

A class that also implements the optional [`compare`](#compare) has a **total
ordering**: it is sortable ([`Array.sort`](/compiler/api/array/)) and can be
used wherever the library needs an order.

## Required methods

**Topics** · [equals](#equals) · [compare](#compare)

### equals
```c
bool equals(Object* other);
```
The only required method. Return `true` when `self` and `other` hold the same
value. `other` is an arbitrary `Object*`, so a conformer starts with a
safe-checked downcast and returns `false` for a mismatch:

```c
bool equals(Object* other) {
    MyType* o = (MyType* ?)other;      // null if the kinds differ
    if (o == 0) return false;
    return /* self vs o, by value */;
}
```

A class may also provide a same-kind fast path, `equals(MyType* other)`. The
overload resolver picks the typed version when the argument's static type is
known and uses the `Object*` slot otherwise, so one protocol slot serves both.

[↑ Topics](#required-methods)

### compare
```c
optional i8 compare(Object* other);
```
**Optional.** Returns the C / Foundation three-way convention:

| return | meaning | Foundation |
|---|---|---|
| `< 0` | `self` sorts **before** `other` | `NSOrderedAscending` |
| `0`   | they sort **equally**          | `NSOrderedSame` |
| `> 0` | `self` sorts **after** `other`  | `NSOrderedDescending` |

It is optional because every value can be tested for equality but not every
value has an order: a colour or a network packet can be compared for sameness
without one being "less than" another. A class that omits `compare` has no
order.

An unimplemented optional method leaves a **NULL vtable slot**, which is what
`respondsTo` tests:

```c
callback f i8(Object* o) = &obj.compare;   // null when the class doesn't implement it
if (f) { /* it has an order */ }
```

[`Array.sort`](/compiler/api/array/) uses that test and returns `false` for
elements that define no order. To order values that are not
`Comparable`-ordered, pass `sortUsing()` a comparator.

The protocol header has a typedef for the bound-method type:

```c
typedef i8 cmp1_t(Object*);    // the type of &obj.compare
```

[↑ Topics](#required-methods)

## Conforming types

Standard-library classes that conform:

- [`Object`](/compiler/api/object/): the root **declares** `<Hashable, Comparable>` and supplies identity-based `equals`/`hash`, but does **not** implement `compare`. A concrete subclass that needs ordering provides its own, as the value classes below do.
- [`String`](/compiler/api/string/): lexicographic by unsigned byte, then by length.
- [`Number`](/compiler/api/number/): numeric ordering.
- [`Data`](/compiler/api/data/): byte-wise ordering.

See also the sibling protocols [`Hashable`](/compiler/api/hashable/) and
[`Copying`](/compiler/api/copying/).

## Usage

Conform to `Comparable` when instances need to be **sorted** or **keyed** by
value. A [`Map`](/compiler/api/map/) or [`Set`](/compiler/api/set/) key must
conform to both `Comparable` (to break ties inside a bucket's probe chain) and
[`Hashable`](/compiler/api/hashable/) (to find the bucket). The two are
independent, so a value that only needs to be found or sorted, and is never
hashed, can adopt `Comparable` alone.
