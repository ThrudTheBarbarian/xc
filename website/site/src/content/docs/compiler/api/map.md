---
title: Map
description: "Hash map keyed by any Hashable + Comparable Object*, with deterministic insertion-order iteration and retaining ownership of keys and values."
---

`Map` is a heap-owned hash map (an `NSMutableDictionary`) keyed by any
`Hashable` + `Comparable` `Object*`, with plain `Object*` values. Iteration is
in **insertion order** and both keys and values are held with a strong
reference.

```c
#import "Map.xc"            // or the Foundation umbrella
```

## Overview

A `Map` stores its entries in a single power-of-two slot table (two cells per
slot: key, value) using **open addressing with linear probing**, and keeps a
parallel dense `_order` array of slot indices so iteration is deterministic and
[`enumAt`](#enumat) is O(1). It inherits from [`Object`](/compiler/api/object/)
and needs a real heap (`-falloc=heap`, the default on the `xt` 6502 layout and
every native backend).

`Map` is a **generic** container only at compile time: the key/value type
parameters are a check the compiler erases, and the slots are type-erased
`pointer` cells at runtime.

**Keys** must conform to both [`Hashable`](/compiler/api/hashable/) (for slot
selection) and [`Comparable`](/compiler/api/comparable/) (for collision-chain
equality). Foundation's [`Number`](/compiler/api/number/),
[`String`](/compiler/api/string/) and [`Data`](/compiler/api/data/) conform to
both. A user key type adds `<Hashable, Comparable>` to its class line and
supplies the two methods.

**Ownership (ARC).** The Map holds a strong reference on every key **and** every
value. [`set`](#set) retains the incoming pair (and releases the outgoing pair
when overwriting a live key); [`remove`](#remove) / [`removeAll`](#removeall)
release what they drop; [`dealloc`](#dealloc) releases every live pair and frees
the table. A [`copy`](#copy) is **shallow**: keys and values are shared, each
retained by both maps.

**Iteration order is deterministic.** Slot order is hash order, and the default
`Object.hash` is derived from the object's address, so a raw-slot walk would
enumerate in heap-layout order and differ between runs. The `_order` array
prevents this: `for-in`, [`allKeys`](#allkeys) and [`allValues`](#allvalues) all yield
**first-insertion order**.

**Load factor.** The table grows (doubling) when it would pass α > 0.75, so
lookups stay close to O(1). Removed entries leave a tombstone rather than
clearing, so later entries' probe chains still resolve.

:::note[Availability]
This is the **32-bit** Map (`support/generic/lib`) for arm64, arm9, m68k and
x86_64: counts/indices are `u32` and the hash is a `u32`. The 6502 build
(`support/xt6502/lib`) has the **same API** with narrower types: `u16`
counts/indices and a `u8` hash. Heap-capable targets only.
:::

## Conforms to

- [`Enumerable`](/compiler/api/enumerable/): [`enumLength`](#enumlength) / [`enumAt`](#enumat) yield the map's **keys** in insertion order, so `for (Object* k in m)` walks keys.
- [`Copying`](/compiler/api/copying/): [`copy`](#copy) returns an independent (shallow) duplicate.

Every `Map*` is also an [`Object*`](/compiler/api/object/) and fits anywhere one is expected.

## Topics

**Creating** · [withCapacity](#withcapacity) · [init](#init)

**Accessing** · [set](#set) · [get](#get) · [getOrDefault](#getordefault) · [count](#count) · [isEmpty](#isempty)

**Membership** · [contains](#contains) · [containsKey](#containskey)

**Removing** · [remove](#remove) · [removeAll](#removeall)

**Views** · [allKeys](#allkeys) · [allValues](#allvalues)

**Iterating** · [enumLength](#enumlength) · [enumAt](#enumat)

**Lifecycle** · [copy](#copy) · [dealloc](#dealloc)

---

## Creating

### withCapacity
```c
static Map* withCapacity(u32 cap)
```
Pre-allocates the slot table rounded up to a power of two (minimum 16), skipping
a future resize copy when the rough upper bound is known. A bare `new Map()`
allocates lazily on the first [`set`](#set).

### init
```c
void init(void)
```
The default initializer: an empty Map with no allocation. Prefer `new Map()` or
[`withCapacity`](#withcapacity); you rarely call `init` directly.

[↑ Topics](#topics)

## Accessing

### set
```c
void set(Hashable* key, Object* value)
```
Inserts or overwrites the entry for `key`. On a fresh key the pair is retained
and appended to the insertion order; on an existing key the incoming pair is
retained and the outgoing key+value released. Triggers a resize first if the
table would pass α > 0.75.

### get
```c
Object* get(Hashable* key)
```
The value stored for `key`, or null when the key is absent. O(1) average. A key
can be stored with a null value; use [`containsKey`](#containskey) to tell the
two cases apart.

### getOrDefault
```c
Object* getOrDefault(Hashable* key, Object* fallback)
```
The value for `key`, or `fallback` when the key is absent. Useful for settings
with defaults, since the caller needs no null test.

### count
```c
u32 count(void)
```
Number of live entries (excludes tombstones). O(1).

### isEmpty
```c
bool isEmpty(void)
```
`true` when [`count`](#count) is zero.

[↑ Topics](#topics)

## Membership

### contains
```c
bool contains(Hashable* key)
```
`true` if `get(key)` is non-null. It tests for a **non-null value** for the key,
not for the key's presence: a key stored with a null value returns `false` here.
Use [`containsKey`](#containskey) for key presence.

### containsKey
```c
bool containsKey(Hashable* key)
```
`true` if `key` is present in the table, regardless of its value.

[↑ Topics](#topics)

## Removing

### remove
```c
void remove(Hashable* key)
```
Removes the entry for `key` (plants a tombstone, closes the gap in the insertion
order, releases the key and value). A missing key is a no-op.

### removeAll
```c
void removeAll(void)
```
Releases every live key+value pair and empties the table.

[↑ Topics](#topics)

## Views

Both return a new [`Array`](/compiler/api/array/) in **insertion order**, and
index for index they line up (`allKeys()[i]` maps to `allValues()[i]`).

### allKeys
```c
Array* allKeys(void)
```
An Array of the keys, in insertion order.

### allValues
```c
Array* allValues(void)
```
An Array of the values, in insertion order (matching [`allKeys`](#allkeys)).

[↑ Topics](#topics)

## Iterating

The [`Enumerable`](/compiler/api/enumerable/) hooks. `for-in` yields the map's
**keys** in insertion order, as `NSDictionary` does; call [`get`](#get) for the
matching value.

### enumLength
```c
u32 enumLength(void)
```
Number of keys the `for-in` driver will visit (== [`count`](#count)).

### enumAt
```c
Object* enumAt(u32 i)
```
The `i`-th key in insertion order. A plain O(1) index, because `_order` is dense.

[↑ Topics](#topics)

## Lifecycle

### copy
```c
Map* copy(void)
```
A new Map with the same key/value pairs, in the same insertion order. The copy
is **shallow**: keys and values are shared, each retained by the new Map. This
is the [`Copying`](/compiler/api/copying/) method.

### dealloc
```c
void dealloc(void)
```
Releases every live key and value, then frees the slot and order buffers. ARC
calls it when the last reference goes away; you do not call it directly.

[↑ Topics](#topics)

## Worked example

```c
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    Map* m = new Map();
    m.set(String.withCString("one"),   Number.with((i32)1));
    m.set(String.withCString("two"),   Number.with((i32)2));
    m.set(String.withCString("three"), Number.with((i32)3));

    for (Object* k in m) {              // keys, in insertion order
        String* key = (String*)k;
        Number* v   = (Number*)m.get((Hashable*)key);
        Stdio.printf("%s=%d ", key.cString(), v.asI16());
    }
    Stdio.printf("\n");
    return 0;
}
```

```
one=1 two=2 three=3
```
