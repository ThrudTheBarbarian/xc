---
title: IndexSet
description: "A set of non-negative integer indexes kept as merged ranges: a table's multi-row selection, with shifting for inserted and deleted rows."
---

`IndexSet` is a set of non-negative integer indexes (`NSIndexSet` in shape),
stored as a sorted list of [`Range`](/compiler/api/range/)s that neither overlap
nor touch. A block of a million rows costs one range, and adding and removing
merge and split ranges to keep it so. It is what a table's multi-row selection
wants. **From 0.72.**

```c
#import "IndexSet.xc"      // not in the Foundation umbrella: import it by name
```

## Overview

```c
IndexSet* rows = new IndexSet();
rows.addRange(Range.make((i32)3, (i32)3));   // 3, 4, 5
rows.addIndex((i32)9);
rows.addIndex((i32)10);
rows.count();                  // 5
rows.rangeCount();             // 2: [3,6) and [9,11)
Stdio.printf("%@\n", rows);    // (3-5, 9-10)

rows.shiftIndexes((i32)4, (i32)2);   // two rows inserted at 4: (3, 6-7, 11-12)
```

Finding the range for an index is a binary search. Indexes are `i32` and at
least 0; a method that finds an index returns
[`IndexSet.notFound()`](#notfound) (-1) when there is none. Two index sets are
equal when they hold the same indexes, and hash alike.

:::note[Availability]
Every heap-capable target, the 6502 included.
:::

## Topics

**Creating** · [withIndex / withRange](#withindex--withrange) · [copy](#copy)

**Adding** · [addIndex](#addindex) · [addRange](#addrange) · [addIndexes](#addindexes)

**Removing** · [removeIndex](#removeindex) · [removeRange](#removerange) · [removeIndexes](#removeindexes) · [removeAllIndexes](#removeallindexes)

**Testing** · [containsIndex](#containsindex) · [containsRange](#containsrange) · [containsIndexes](#containsindexes) · [intersectsRange](#intersectsrange)

**Counting and finding** · [count](#count) · [isEmpty](#isempty) · [firstIndex / lastIndex](#firstindex--lastindex) · [indexGreaterThan …](#indexgreaterthan-) · [notFound](#notfound)

**Ranges** · [rangeCount](#rangecount) · [rangeAt](#rangeat)

**Shifting** · [shiftIndexes](#shiftindexes)

---

## Creating

### withIndex / withRange
```c
static IndexSet* withIndex(i32 i)
static IndexSet* withRange(Range* r)
```
A set of one index, or of every index in `r`. `new IndexSet()` is empty.

### copy
```c
IndexSet* copy(void)
```

[↑ Topics](#topics)

## Adding

### addIndex
```c
void addIndex(i32 i)
```

### addRange
```c
void addRange(Range* r)
```
Every index of `r`; any part below 0 is ignored.

### addIndexes
```c
void addIndexes(IndexSet* other)
```

[↑ Topics](#topics)

## Removing

### removeIndex
```c
void removeIndex(i32 i)
```

### removeRange
```c
void removeRange(Range* r)
```

### removeIndexes
```c
void removeIndexes(IndexSet* other)
```

### removeAllIndexes
```c
void removeAllIndexes(void)
```

[↑ Topics](#topics)

## Testing

### containsIndex
```c
bool containsIndex(i32 i)
```

### containsRange
```c
bool containsRange(Range* r)
```
Whether every index of `r` is in the set; true for an empty range.

### containsIndexes
```c
bool containsIndexes(IndexSet* other)
```

### intersectsRange
```c
bool intersectsRange(Range* r)
```
Whether any index of `r` is in the set.

[↑ Topics](#topics)

## Counting and finding

### count
```c
u32 count(void)
```
The number of indexes (not ranges).

### isEmpty
```c
bool isEmpty(void)
```

### firstIndex / lastIndex
```c
i32 firstIndex(void)
i32 lastIndex(void)
```
The smallest and largest index, or [`notFound()`](#notfound).

### indexGreaterThan …
```c
i32 indexGreaterThan(i32 i)
i32 indexGreaterThanOrEqualTo(i32 i)
i32 indexLessThan(i32 i)
i32 indexLessThanOrEqualTo(i32 i)
```
The nearest index in the set on that side of `i`, or
[`notFound()`](#notfound): what moving a selection with the arrow keys asks.

### notFound
```c
static i32 notFound(void)      // -1
```

[↑ Topics](#topics)

## Ranges

### rangeCount
```c
u32 rangeCount(void)
```

### rangeAt
```c
Range* rangeAt(u32 k)
```
A copy of the `k`-th range, in order: walking the ranges is how to visit a large
selection without visiting every index.

[↑ Topics](#topics)

## Shifting

### shiftIndexes
```c
void shiftIndexes(i32 start, i32 delta)
```
Moves every index at or after `start` by `delta`, as when rows are inserted or
deleted. With `delta > 0` a gap opens at `start` (a range that spans it is
split). With `delta < 0` the indexes in `[start + delta, start)` go and the rest
close up.

[↑ Topics](#topics)
