---
title: UXIndexSet
description: "A set of non-negative indices stored as coalesced ranges, so a selection of a million contiguous rows costs one range."
---

`UXIndexSet` is a set of non-negative integer indices, with the shape of
`NSIndexSet`. A table's multi-selection is one of these.

```c
#use <UXKit>            // or #import "UXIndexSet.xc"
```

## Overview

The set is stored as **a sorted list of non-overlapping, non-adjacent
[`UXRange`](/compiler/api/uxkit/uxrange/)s**, not as a list of integers.

A selection of rows 3, 4, 5, 9 and 10 is two ranges, `[3,3]` and `[9,2]`,
instead of five numbers. A contiguous block of a million rows costs **one
range**, and "select all" on a large table is O(1) in space instead of
O(rows).

Every mutation maintains that invariant, so ranges merge and split
automatically:

```c
UXIndexSet* s = new UXIndexSet();
s.addIndex(3); s.addIndex(4); s.addIndex(5);
// count=3 ranges=1  [ 3..5 ]        <- three adds, one range: they COALESCED
```

A disjoint block stays separate. Closing the gap merges everything:

```c
s.addRange(9, 2);       // count=5 ranges=2  [ 3..5 9..10 ]
s.addRange(6, 3);       // count=8 ranges=1  [ 3..10 ]      <- the gap closed
```

Removing from the middle **splits** a range:

```c
s.removeRange(5, 2);    // count=6 ranges=2  [ 3..4 7..10 ]
```

You never manage this yourself. `addRange` absorbs every range it touches or
overlaps and inserts one merged range in sorted position; `removeRange`
trims, splits or deletes as needed. Adjacency counts as touching, so `[3,3]`
and `[6,3]` become `[3,8]`. Keeping adjacent ranges separate would let the
structure degrade to one range per index.

## Topics

[addIndex](#addindex) · [addRange](#addrange) · [addIndexes](#addindexes) · [removeIndex](#removeindex) · [removeRange](#removerange) · [removeAllIndexes](#removeallindexes) · [containsIndex](#containsindex) · [containsRange](#containsrange) · [intersectsRange](#intersectsrange) · [count](#count) · [isEmpty](#isempty) · [firstIndex](#firstindex) · [lastIndex](#lastindex) · [indexGreaterThan](#indexgreaterthan) · [indexLessThan](#indexlessthan) · [isEqualTo](#isequalto) · [rangeCount](#rangecount) · [rangeAt](#rangeat)

### addIndex

```c
void addIndex(i32 i)
```

Adds one index. It coalesces with neighbours, so adding 3, 4 and 5 leaves
one range.

### addRange

```c
void addRange(i32 loc, i32 len)
```

Adds `len` indices from `loc`. A non-positive length or a negative location
is ignored, not treated as an error, so a computed empty selection needs no
guard at the call site.

### addIndexes

```c
void addIndexes(UXIndexSet* other)
```

Union, in place. A null argument is ignored.

### removeIndex

```c
void removeIndex(i32 i)
```

Removes one index, splitting a range if the index was in the middle.

### removeRange

```c
void removeRange(i32 loc, i32 len)
```

Removes a block. It trims, splits or deletes ranges as needed to keep the
invariant.

### removeAllIndexes

```c
void removeAllIndexes(void)
```

Empties the set.

### containsIndex

```c
bool containsIndex(i32 idx)
```

Membership. It walks the **ranges**, not the indices, so it is cheap even on
a huge selection.

### containsRange

```c
bool containsRange(i32 loc, i32 len)
```

Whether **every** index in the block is present.
[`intersectsRange`](#intersectsrange) asks whether *any* is.

### intersectsRange

```c
bool intersectsRange(i32 loc, i32 len)
```

Whether any index in the block is present. A redraw uses this to ask whether
the selection touches the rows it is about to paint.

### count

```c
i32 count(void)
```

The number of **indices** in the set: the sum of the range lengths, not the
number of ranges. For the number of ranges, see
[`rangeCount`](#rangecount).

### isEmpty

```c
bool isEmpty(void)
```

### firstIndex

```c
i32 firstIndex(void)      // -1 when empty
```

### lastIndex

```c
i32 lastIndex(void)       // -1 when empty
```

### indexGreaterThan

```c
i32 indexGreaterThan(i32 idx)      // -1 when there is none
```

The next index present after `idx`, **skipping gaps**. Iterate with this and
[`firstIndex`](#firstindex):

```c
i32 i = s.firstIndex();
while (i >= 0) {
    use(i);
    i = s.indexGreaterThan(i);
}
```

This walk visits only the indices in the set. Looping
`for (i = 0; i < rowCount; …)` and calling `containsIndex` each time is
O(rows), which the range storage is meant to avoid.

### indexLessThan

```c
i32 indexLessThan(i32 idx)         // -1 when there is none
```

The same, backwards. Use it to delete selected rows from the end, so the
earlier indices stay valid as you go.

### isEqualTo

```c
bool isEqualTo(UXIndexSet* other)
```

Set equality. The storage is canonical (sorted, coalesced, non-adjacent), so
two sets holding the same indices always have the same ranges, and this is
a direct comparison instead of a search.

:::note[Not `equals`]
Dispatch in xc is by name only, and `Object.equals(Object@)` would shadow a
custom `equals`. The toolkit uses a distinct name, `isEqualTo`, where it
needs its own comparison.
:::

### rangeCount

```c
i32 rangeCount(void)
```

The number of ranges the set occupies. This is the storage cost, and a
useful value to assert in a test of coalescing.

### rangeAt

```c
UXRange* rangeAt(u16 i)
```

The i'th range, in ascending order. Use it to walk blocks instead of
indices: a table redrawing a selection can draw rows 3..5 as one rectangle
instead of three.

## Example

```c
#import <Stdio.xc>
#import "UXIndexSet.xc"

void main(void) {
    UXIndexSet* s = new UXIndexSet();

    s.addIndex(3); s.addIndex(4); s.addIndex(5);   // [ 3..5 ]      one range
    s.addRange(9, 2);                              // [ 3..5 9..10 ]
    s.addRange(6, 3);                              // [ 3..10 ]     the gap closed
    s.removeRange(5, 2);                           // [ 3..4 7..10 ] split

    Stdio.printf("count=%d ranges=%d\n", s.count(), s.rangeCount());   // 6, 2
    Stdio.printf("contains 4: %s\n", s.containsIndex(4) ? (u8*)"yes" : (u8*)"no");
    Stdio.printf("contains 5: %s\n", s.containsIndex(5) ? (u8*)"yes" : (u8*)"no");

    i32 i = s.firstIndex();
    while (i >= 0) { Stdio.printf("%d ", i); i = s.indexGreaterThan(i); }
    Stdio.printf("\n");                            // 3 4 7 8 9 10
}
```

The full program is `website/site/examples/uxkit/indexset.xc`, and the
`doc-examples` gate compiles it. The comments are its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXRange`](/compiler/api/uxkit/uxrange/): what the set is made of, and the
  half-open contract the coalescing relies on
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): its multi-selection is
  one of these
- [`UXEvent`](/compiler/api/uxkit/uxevent/): `UXEventSelected` carries one as
  its payload
