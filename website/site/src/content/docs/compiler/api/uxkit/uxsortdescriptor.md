---
title: UXSortDescriptor
description: "Order objects by one key, ascending or descending, comparing as text or as a number. The other half of the filter-then-sort pair a list view uses."
---

`UXSortDescriptor` orders an array of objects that answer
[`UXEvaluable`](/compiler/api/uxkit/uxevaluable/), the same protocol
[`UXPredicate`](/compiler/api/uxkit/uxpredicate/) filters on.

```c
#use <UXKit>            // or #import "UXSortDescriptor.xc"
```

## Overview

```c
UXSortDescriptor.make((u8*)"name", true).sort(rows);          // A → Z
UXSortDescriptor.make((u8*)"name", false).sort(rows);         // Z → A
UXSortDescriptor.numericKey((u8*)"size", true).sort(rows);    // 3, 9, 20, 100
```

Filter with a predicate, then sort with one of these. A table or list view does
this to its rows. It works on **your** objects, which only need to implement
`valueForKey`.

## Values are strings, so numbers need saying so

`valueForKey` returns text, which lets one protocol serve filtering, sorting and
display. As a result, a numeric column must be declared:

```c
"size as text:  Alpha(100) charlie(20) bravo(3) delta(9)"
"size numeric:  bravo(3) delta(9) charlie(20) Alpha(100)"
```

A string sort of `"100"`, `"20"`, `"3"` orders them **lexically** (`1` before
`2` before `3`), which gives the familiar wrong-looking file listing.
[`numericKey`](#numerickey) reads each value as an integer instead.

:::note[The numeric read is lenient]
It uses the same parser as
[`UXPredicate`](/compiler/api/uxkit/uxpredicate/): leading digits, then stop.
`"12kb"` sorts as 12, and text with no digits sorts as **0**, which puts it
first ascending, alongside any real zero.

For a column that might hold either, this is usually what you want. When it is
not, validate the values on the way in.
:::

## Comparison is by byte

```
by name asc:  Alpha bravo charlie delta
```

`Alpha` comes first because `A` (65) is below `b` (98). The comparison is a
plain byte comparison, with no case folding, locale or accent handling.

For a user-visible list this is often wrong. To fix it, sort on a key your
object computes: return a lowercased copy from `valueForKey` for a
`"name_sort"` key, and sort on that. The descriptor stays simple and the
normalisation lives with the data.

UTF-8 also sorts by byte, which puts every multi-byte character after every
ASCII one. The order is consistent and deterministic, but not alphabetical in
any language.

## An unknown key leaves the order alone

```c
UXSortDescriptor.make((u8*)"nope", true).sort(rows);   // unchanged
```

`valueForKey` is expected to return `""` for a key it does not know, so every
row compares equal and nothing moves. A typo in a key name gives a sort that
silently does nothing, not an error. Check the key name when a column header
stops working.

## The sort is selection sort, and not stable

`sort` is a selection sort **in place**: O(n²) comparisons, and each comparison
calls `valueForKey` twice.

This suits list-view-sized data (a few hundred rows) and needs no extra
allocation. It is the wrong choice for thousands of rows, especially with an
expensive `valueForKey`.

:::caution[Equal elements may be reordered]
Selection sort swaps distant elements, so rows that compare equal do not keep
their previous relative order.

This affects the usual multi-column idiom, "sort by name, then by size within
equal names". Running two descriptors in sequence does **not** give that order,
because the second sort scrambles the first. For a compound order, sort on one
key that combines both.
:::

## Topics

[make](#make) · [numericKey](#numerickey) · [compare](#compare) · [sort](#sort)

### make

```c
static UXSortDescriptor* make(u8* key, bool ascending)
```

Compare the key's value as **text**. The key is kept, not copied, so pass a
literal.

### numericKey

```c
static UXSortDescriptor* numericKey(u8* key, bool ascending)
```

Compare as an **integer**.

### compare

```c
i32 compare(UXEvaluable* a, UXEvaluable* b)
```

`-1`, `0` or `1`, already honouring `numeric` and `ascending`. Descending
returns the opposite sign; the caller does not flip it.

Use it directly to merge two already-sorted lists, or to insert one row into a
sorted array without re-sorting.

### sort

```c
void sort(Array<UXEvaluable>* items)
```

Order the array **in place**. Null values are treated as `""`, so a row with a
missing value sorts first ascending instead of crashing.

## Fields

### key / ascending / numeric

```c
u8*  key
bool ascending
bool numeric
```

Readable and writable, so a column header click can flip `ascending` on an
existing descriptor instead of making a new one.

## Example

```
unsorted:      delta(9) Alpha(100) charlie(20) bravo(3)
by name asc:   Alpha(100) bravo(3) charlie(20) delta(9)
by name desc:  delta(9) charlie(20) bravo(3) Alpha(100)
size as text:  Alpha(100) charlie(20) bravo(3) delta(9)
size numeric:  bravo(3) delta(9) charlie(20) Alpha(100)
unknown key:   delta(9) Alpha(100) charlie(20) bravo(3)
compare bravo vs delta: -1
```

The program is `website/site/examples/uxkit/records.xc`; the `doc-examples`
gate compiles it, and the output above is its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXPredicate`](/compiler/api/uxkit/uxpredicate/): filtering, the other half
- [`UXEvaluable`](/compiler/api/uxkit/uxevaluable/): the one method your
  objects implement
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): the click-to-sort column
  header this sits behind
