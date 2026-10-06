---
title: Bag
description: "A counted set: each member carries a count, raised by add and lowered by remove, with totals and members in the order they first arrived."
---

`Bag` is a counted set (a multiset; `NSCountedSet` or `CFBag` in shape). Like a
[`Set`](/compiler/api/set/), it holds each member once; unlike one, it counts
how many times each was added. Adding a member again raises its count,
[`remove`](#remove) lowers it, and the member leaves when its count reaches
zero. **From 0.72.**

```c
#import "Bag.xc"           // or the Foundation umbrella
```

## Overview

```c
Bag* words = new Bag();
words.add(String.withCString("the"));
words.add(String.withCString("cat"));
words.add(String.withCString("the"));
Stdio.printf("%d words, %d different; 'the' %d times\n",
             words.totalCount(), words.uniqueCount(),
             words.countFor(String.withCString("the")));   // 3 words, 2 different; 'the' 2 times
```

**Membership** is a `Set`'s: a member's `hash()` picks its slot and `equals()`
settles collisions. [`Object`](/compiler/api/object/)'s own `hash` and `equals`
are its identity, so a bag of plain objects counts **references** (a tally of
tokens, "how many of these are selected"), while a
[`String`](/compiler/api/string/) or a [`Number`](/compiler/api/number/) is
counted **by value**, as in the example above.

**Storage** is `Set`'s table with a count beside each member: open addressing
over a power-of-two capacity, so [`add`](#add), [`countFor`](#countfor) and
[`remove`](#remove) are close to O(1). A dense insertion order makes
[`memberAt`](#memberat) and [`countAt`](#countat) O(1) and walks the members in
the order they first arrived; removing one closes the gap.

**Ownership (ARC).** The bag holds one strong reference to each distinct member,
however many times it was added, and releases it when the member leaves.

:::note[Availability]
The 32-bit Bag (`support/generic/lib`) is for arm64, arm9, m68k, x86_64 and
wasm32: indexes are `u32`, so the number of distinct members is limited only by
memory. The 6502 build (`support/xt6502/lib`) has the **same API** with the 6502
Foundation's narrower types: `u16` indexes and a `u8` hash. Heap-capable targets
only.
:::

## Conforms to

- [`Enumerable`](/compiler/api/enumerable/): [`enumLength`](#enumlength) / [`enumAt`](#enumat), so `for (Object* m in bag)` walks the distinct members.

## Topics

**Adding** · [add](#add) · [addTimes](#addtimes)

**Removing** · [remove](#remove) · [removeAllOf](#removeallof) · [removeAll](#removeall)

**Counting** · [countFor](#countfor) · [contains](#contains) · [totalCount](#totalcount) · [uniqueCount](#uniquecount)

**Members in order** · [memberAt](#memberat) · [countAt](#countat)

**Iterating** · [enumLength](#enumlength) · [enumAt](#enumat)

---

## Adding

### add
```c
void add(Object* o)
```
One more of `o`. A member not yet in the bag joins it with a count of one and is
retained. A null `o` is ignored.

### addTimes
```c
void addTimes(Object* o, i32 n)
```
`n` more of `o`; nothing when `n` is zero or negative.

[↑ Topics](#topics)

## Removing

### remove
```c
void remove(Object* o)
```
One fewer of `o`. At zero the member leaves the bag and is released; a member
not in the bag is ignored.

### removeAllOf
```c
void removeAllOf(Object* o)
```
Every one of `o`: the member leaves whatever its count.

### removeAll
```c
void removeAll(void)
```
Empties the bag, releasing every member.

[↑ Topics](#topics)

## Counting

### countFor
```c
i32 countFor(Object* o)
```
How many of `o` the bag holds: 0 when it is not a member.

### contains
```c
bool contains(Object* o)
```
Whether `o` is a member (its count is at least one).

### totalCount
```c
i32 totalCount(void)
```
The sum of every member's count.

### uniqueCount
```c
i32 uniqueCount(void)
```
The number of distinct members.

[↑ Topics](#topics)

## Members in order

### memberAt
```c
Object* memberAt(i32 i)
```
The `i`-th distinct member, in the order members first arrived; null when `i` is
out of range.

### countAt
```c
i32 countAt(i32 i)
```
The count of the `i`-th distinct member; 0 when `i` is out of range.

[↑ Topics](#topics)

## Iterating

### enumLength
```c
u32 enumLength(void)
```
The number of distinct members (`u16` on the 6502), for `for`-`in`.

### enumAt
```c
Object* enumAt(u32 i)
```
The same as [`memberAt`](#memberat), for `for`-`in`.

[↑ Topics](#topics)
