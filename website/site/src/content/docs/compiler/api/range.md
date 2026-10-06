---
title: Range
description: "A half-open range of indexes [loc, loc + len): containment, overlap, intersection and union, equal by value."
---

`Range` is a half-open range of indexes, `[loc, loc + len)` (`NSRange` in
shape). It is a class rather than a struct so ranges can live in an
[`Array`](/compiler/api/array/), a [`Set`](/compiler/api/set/) or a
[`Map`](/compiler/api/map/): a wrapped line, a selected block of rows and a run
of styled characters are each a list of ranges. **From the release after 0.71.**

```c
#import "Range.xc"         // or the Foundation umbrella
```

## Overview

```c
Range* r = Range.make((i32)3, (i32)4);       // [3, 7)
r.contains((i32)3);                          // true
r.contains((i32)7);                          // false: end() is not in the range
Range* both = r.intersection(Range.make((i32)5, (i32)10));   // [5, 7)
```

**Half-open is the contract.** `loc` is in the range and [`end`](#end) is not.
An empty range has `len` 0, and adjacent ranges meet with `a.end() == b.loc`:
no gap and no overlap.

**Equal by value.** Two ranges are equal when their `loc` and `len` are, and
[`hash`](#hash) agrees, so a range works as a `Set` member or a `Map` key by
value.

:::note[Availability]
Every heap-capable target, the 6502 included. `loc` and `len` are `i32`
everywhere; the 6502's `hash` is a `u8`, as the 6502 Foundation's hashes are.
:::

## Topics

**Creating** · [make](#make) · [loc and len](#loc-and-len)

**Testing** · [end](#end) · [isEmpty](#isempty) · [contains](#contains) · [overlaps](#overlaps)

**Combining** · [intersection](#intersection) · [unionWith](#unionwith)

**Equality** · [equals](#equals) · [hash](#hash)

---

## Creating

### make
```c
static Range* make(i32 loc, i32 len)
```
A new range starting at `loc`, `len` long.

### loc and len
```c
i32 loc;
i32 len;
```
The first index and the length. `new Range()` is the empty range at 0.

[↑ Topics](#topics)

## Testing

### end
```c
i32 end(void)
```
One past the last index: `loc + len`.

### isEmpty
```c
bool isEmpty(void)
```
Whether `len` is zero (or negative).

### contains
```c
bool contains(i32 i)
```
Whether `loc <= i < end()`.

### overlaps
```c
bool overlaps(Range* o)
```
Whether the two cover an index in common. Ranges that only touch end to end
(`[0,3)` and `[3,5)`) do not overlap, and an empty range overlaps nothing, even
a range it sits inside. A null `o` overlaps nothing.

[↑ Topics](#topics)

## Combining

### intersection
```c
Range* intersection(Range* o)
```
A new range of the indexes both cover, or an empty range at the later start
when they share none.

### unionWith
```c
Range* unionWith(Range* o)
```
A new range, the smallest covering both, including any gap between them. An
empty or null `o` gives a copy of this range.

[↑ Topics](#topics)

## Equality

### equals
```c
bool equals(Object* other)
```
Whether `other` is a `Range` with the same `loc` and `len`.

### hash
```c
u32 hash(void)        // u8 on the 6502
```
A hash of `loc` and `len`; equal ranges hash equally.

[↑ Topics](#topics)
