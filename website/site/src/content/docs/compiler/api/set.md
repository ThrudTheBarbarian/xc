---
title: Set
description: "Hash set of unique Hashable + Comparable Object* elements, with union, intersection, difference and the subset relations."
---

`Set` is a heap-owned hash set (an `NSMutableSet`) of **unique** elements, each
any `Hashable` + `Comparable` `Object*`. Membership is by value, and every
stored element is held with a strong reference.

```c
#import "Set.xc"           // or the Foundation umbrella
```

## Overview

A `Set` stores its elements in a single power-of-two slot table (one cell per
slot) using **open addressing with linear probing**, and keeps a parallel dense
`_order` array so [`enumAt`](#enumat) is O(1) and iteration is deterministic. It
inherits from [`Object`](/compiler/api/object/) and needs a real heap
(`-falloc=heap`, the default on the `xt` 6502 layout and every native backend).

`Set` is a **generic** container only at compile time: the element type
parameter is a check the compiler erases, and the slots are type-erased
`pointer` cells at runtime.

**Elements** must conform to both [`Hashable`](/compiler/api/hashable/) (for
slot selection) and [`Comparable`](/compiler/api/comparable/) (for
collision-chain equality). Foundation's [`Number`](/compiler/api/number/),
[`String`](/compiler/api/string/) and [`Data`](/compiler/api/data/) conform to
both. A user element type adds `<Hashable, Comparable>` to its class line and
supplies the two methods.

**Uniqueness by value.** [`add`](#add) uses the element's `equals` on the probe
chain, so re-adding a value-equal element is a no-op (no duplicate, no extra
retain). [`contains`](#contains) is value membership, not identity.

**Ownership (ARC).** The Set holds a strong reference on every element.
[`add`](#add) retains a fresh element; [`remove`](#remove) /
[`removeAll`](#removeall) release what they drop; [`dealloc`](#dealloc) releases
every element and frees the table. The set-algebra methods and
[`copy`](#copy) return **new** sets that hold their own strong reference to every
element. These are shallow: the elements are shared.

**Load factor.** The table grows (doubling) when it would pass α > 0.75, so
membership stays close to O(1). Removed entries leave a tombstone rather than
clearing, so later entries' probe chains still resolve.

:::note[Availability]
This is the **32-bit** Set (`support/generic/lib`) for arm64, arm9, m68k and
x86_64: counts/indices are `u32` and the hash is a `u32`. The 6502 build
(`support/xt6502/lib`) has the **same API** with narrower types: `u16`
counts/indices and a `u8` hash. Heap-capable targets only.
:::

## Conforms to

- [`Enumerable`](/compiler/api/enumerable/): [`enumLength`](#enumlength) / [`enumAt`](#enumat), so `for (Object* e in s)` walks the elements.
- [`Copying`](/compiler/api/copying/): [`copy`](#copy) returns an independent (shallow) duplicate.

Every `Set*` is also an [`Object*`](/compiler/api/object/) and fits anywhere one is expected.

## Topics

**Creating** · [withCapacity](#withcapacity) · [withArray](#witharray) · [init](#init)

**Accessing** · [add](#add) · [contains](#contains) · [count](#count) · [isEmpty](#isempty)

**Removing** · [remove](#remove) · [removeAll](#removeall)

**Set algebra** · [unionWith](#unionwith) · [intersect](#intersect) · [subtract](#subtract) · [symmetricDifference](#symmetricdifference)

**Relations** · [isSubsetOf](#issubsetof) · [isSupersetOf](#issupersetof) · [intersects](#intersects) · [isDisjointFrom](#isdisjointfrom) · [equalsSet](#equalsset)

**Conversion** · [allObjects](#allobjects)

**Iterating** · [enumLength](#enumlength) · [enumAt](#enumat)

**Lifecycle** · [copy](#copy) · [dealloc](#dealloc)

---

## Creating

### withCapacity
```c
static Set* withCapacity(u32 cap)
```
Pre-allocates the slot table rounded up to a power of two (minimum 16), skipping
a future resize copy when the rough upper bound is known. A bare `new Set()`
allocates lazily on the first [`add`](#add).

### withArray
```c
static Set* withArray(Array* items)
```
A new Set of the distinct elements of `items` (null and duplicate entries are
dropped). A null argument yields an empty Set.

### init
```c
void init(void)
```
The default initializer: an empty Set with no allocation. Prefer `new Set()` or
the `with…` constructors; you rarely call `init` directly.

[↑ Topics](#topics)

## Accessing

### add
```c
void add(Hashable* elem)
```
Adds `elem` if no value-equal element is already present, retaining it and
appending it to the insertion order. Re-adding an existing value is a no-op.
Triggers a resize first if the table would pass α > 0.75.

### contains
```c
bool contains(Hashable* elem)
```
`true` if a value-equal element is a member. O(1) average.

### count
```c
u32 count(void)
```
Number of live elements (excludes tombstones). O(1).

### isEmpty
```c
bool isEmpty(void)
```
`true` when [`count`](#count) is zero.

[↑ Topics](#topics)

## Removing

### remove
```c
void remove(Hashable* elem)
```
Removes the value-equal element (plants a tombstone, closes the gap in the
insertion order, releases the element). A missing element is a no-op.

### removeAll
```c
void removeAll(void)
```
Releases every element and empties the table.

[↑ Topics](#topics)

## Set algebra

Each returns a **new** Set; the receiver and the argument are untouched. The
result holds its own strong reference to every element it contains.

### unionWith
```c
Set* unionWith(Set* other)
```
Everything in either set.

### intersect
```c
Set* intersect(Set* other)
```
Only what is in **both** sets.

### subtract
```c
Set* subtract(Set* other)
```
What is in the receiver but not in `other`.

### symmetricDifference
```c
Set* symmetricDifference(Set* other)
```
What is in one set or the other, but not both.

[↑ Topics](#topics)

## Relations

Predicates over two sets; none of them allocate a result set.

### isSubsetOf
```c
bool isSubsetOf(Set* other)
```
`true` if every element of the receiver is in `other`. The empty set is a subset
of anything (including a null `other`).

### isSupersetOf
```c
bool isSupersetOf(Set* other)
```
`true` if the receiver contains every element of `other` (`other.isSubsetOf(self)`).

### intersects
```c
bool intersects(Set* other)
```
`true` if the two sets share at least one element.

### isDisjointFrom
```c
bool isDisjointFrom(Set* other)
```
`true` if the two sets share no element (`!intersects(other)`).

### equalsSet
```c
bool equalsSet(Set* other)
```
`true` if the two sets have the same members, in any order (same count, and the
receiver is a subset of `other`).

[↑ Topics](#topics)

## Conversion

### allObjects
```c
Array* allObjects(void)
```
The members as a new [`Array`](/compiler/api/array/), in iteration order (a Set
has no meaningful order of its own).

[↑ Topics](#topics)

## Iterating

The [`Enumerable`](/compiler/api/enumerable/) hooks; you normally use
`for (Object* e in s)` rather than calling these directly.

### enumLength
```c
u32 enumLength(void)
```
Number of elements the `for-in` driver will visit (== [`count`](#count)).

### enumAt
```c
Object* enumAt(u32 i)
```
The `i`-th element for the `for-in` driver. A plain O(1) index, because `_order`
is dense.

[↑ Topics](#topics)

## Lifecycle

### copy
```c
Set* copy(void)
```
A new Set holding the same elements. The copy is **shallow**: the elements are
shared, each retained by the new Set. This is the
[`Copying`](/compiler/api/copying/) method.

### dealloc
```c
void dealloc(void)
```
Releases every element, then frees the slot and order buffers. ARC calls it when
the last reference goes away; you do not call it directly.

[↑ Topics](#topics)

## Worked example

```c
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    Set* a = new Set();
    a.add(Number.with((i32)1));
    a.add(Number.with((i32)2));
    a.add(Number.with((i32)2));     // duplicate value — ignored

    Set* b = new Set();
    b.add(Number.with((i32)2));
    b.add(Number.with((i32)3));

    Set* both = a.intersect(b);     // { 2 }
    Stdio.printf("count(a)=%d  shared=%d\n",
                 (i16)a.count(), (i16)both.count());
    return 0;
}
```

```
count(a)=2  shared=1
```
