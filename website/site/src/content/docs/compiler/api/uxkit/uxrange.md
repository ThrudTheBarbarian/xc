---
title: UXRange
description: "A half-open range [loc, loc+len) as an object: one vocabulary for wrapped lines, selected rows and styled runs."
---

`UXRange` is a half-open range `[loc, loc + len)`: `loc` is included, `end()` is
not. It has the shape of Foundation's `NSRange`, and it is the toolkit's single
vocabulary for "a run of consecutive indices".

```c
#use <UXKit>            // or #import "UXRange.xc"
```

## Overview

```c
UXRange* r = UXRange.make(3, 4);    // indices 3,4,5,6
r.end()        // 7  — one past the last
r.isEmpty()    // false
r.contains(6)  // true
r.contains(7)  // false
```

### Why it is a class and not a struct

Ranges live in arrays. A wrapped paragraph is a list of lines, a table's
selection is a list of blocks, and a styled string is a list of runs: all are
lists of ranges. xc autoboxes primitives but not structs, so a packed struct
could not go into an [`Array`](/compiler/api/array/) without a wrapper at every
site. Making it a class costs an allocation and gives the whole collection API.

### Why there is only one of it

Every part of the toolkit that needs a run of indices uses this type:

- `UXIndexSet` stores its blocks as `UXRange`s
- `UXTextLayout` returns wrapped lines as `UXRange`s
- `UXAttributedString`'s runs (`UXAttrRun`) and `UXTextLayout`'s runs
  (`UXTextRun`) are subclasses of `UXRange` that add a payload

There is one name, one field pair and one half-open contract. A range that
carries a payload **extends** this class rather than restating the pair.

## The half-open contract

Every behaviour below follows from it:

- `loc` is **in** the range; `end()` is **not**
- an empty range has `len == 0` and covers no index at all
- adjacent ranges satisfy `a.end() == b.loc`: no gap, no overlap

The last property is the reason for half-open ranges. `[0,3)` and `[3,2)` tile:
they meet with nothing between them and nothing counted twice. With inclusive
ends you would write `[0,2]` and `[3,4]` and have to remember the `+1` at every
boundary.

## Topics

[make](#make) · [end](#end) · [isEmpty](#isempty) · [contains](#contains) · [overlaps](#overlaps)

### make

```c
static UXRange* make(i32 l, i32 n)
```

A range starting at `l` covering `n` indices.

```c
UXRange* line = UXRange.make(0, 40);     // characters 0..39
```

### end

```c
i32 end(void)
```

`loc + len`: **one past** the last index, not the last index. Compare against it
with `<`. The next adjacent range starts at this value.

### isEmpty

```c
bool isEmpty(void)
```

True when `len <= 0`. A negative length counts as empty, so a range built from a
backwards selection tests as nothing rather than as a strange shape.

### contains

```c
bool contains(i32 i)
```

`i >= loc && i < end()`. The asymmetry is the contract, not an off-by-one.

### overlaps

```c
bool overlaps(UXRange* o)
```

Whether the two cover any index in common.

The obvious implementation gets two cases wrong:

**Touching end-to-end is not overlapping.** `[0,3)` and `[3,2)` share no index.
This follows from the half-open contract, and it lets adjacent runs be tested for
merging without every pair reporting a conflict.

**An empty range overlaps nothing**, including a range it sits inside. `[5,0)`
against `[0,10)` satisfies the arithmetic test (`5 < 10 && 0 < 5`) and is still
false, because an empty range covers no index and so has none in common with
anything. A caret inside a selection does not overlap it.

A null argument returns false rather than an error.

## Example

Walking a line-broken paragraph, where each line is a range into one string:

```c
Array<UXRange>* lines = layout.wrap(text, 200);

for (i32 i = 0; i < (i32)lines.count(); i = i + 1) {
    UXRange* ln = (UXRange* ?)lines.get((u16)i);
    Stdio.printf("line %d: chars %d..%d (%d)\n", i, ln.loc, ln.end() - 1, ln.len);
}

// Adjacent lines meet exactly — no gap, nothing counted twice.
UXRange* a = (UXRange* ?)lines.get((u16)0);
UXRange* b = (UXRange* ?)lines.get((u16)1);
Stdio.printf("tile: %s\n", a.end() == b.loc ? (u8*)"yes" : (u8*)"no");
Stdio.printf("overlap: %s\n", a.overlaps(b) ? (u8*)"yes" : (u8*)"no");   // no
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXIndexSet`](/compiler/api/uxkit/uxindexset/): a set of these, which is
  what a table's multi-selection is
- [`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/): returns wrapped lines as
  ranges
- [`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/): styled runs,
  a range with a payload
