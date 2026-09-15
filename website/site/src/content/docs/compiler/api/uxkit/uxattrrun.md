---
title: UXAttrRun
description: "A maximal span of characters sharing one style: a UXRange with a UXCharAttr attached, produced by coalescing rather than stored."
---

`UXAttrRun` is a span of characters that all have the same style: a
[`UXRange`](/compiler/api/uxkit/uxrange/) with a
[`UXCharAttr`](/compiler/api/uxkit/uxcharattr/) attached.

```c
#use <UXKit>            // or #import "UXAttributedString.xc"
```

## Overview

```c
class UXAttrRun : UXRange {
    UXCharAttr* attr;
}
```

It extends `UXRange` instead of repeating `loc`/`len` beside the payload, so
`end()`, `contains()` and `overlaps()` all work on a run, and a run reads like
every other range in the toolkit.

```c
Array<UXAttrRun>* rs = a.runs();
for (u16 i = 0; i < rs.count(); i = i + 1) {
    UXAttrRun* r = (UXAttrRun* ?)rs.get(i);
    drawSpan(text + r.loc, r.len, r.attr);     // one styled span per call
}
```

Runs exist for that loop: a drawing pass sets a font once and strokes a span
instead of querying every character.

## Runs are derived, not stored

[`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/) keeps one
attribute per **character**. `runs()` walks them and coalesces equal neighbours
into runs, fresh, each time you call it.

This has consequences that differ from the usual rich-text model:

- **Restyling never corrupts the run list**, because there is no stored run
  list. Setting bold over a span that straddles three runs changes characters
  and nothing else.
- **Coalescing happens by itself.** Clearing a style so a span matches its
  neighbours merges them again on the next `runs()`.
- **Runs are always maximal and in order**, with no empty runs and no adjacent
  pair sharing a style. They tile the string: `r[i].end() == r[i+1].loc`.

## What it costs

`runs()` **allocates** a fresh array of fresh run objects on every call. Call it
at the top of a drawing pass, not inside a loop.

:::caution[`runCount()` is not a cheap accessor]
It is implemented as `runs().count()`, which builds the whole array and throws
it away. Calling it as a loop bound rebuilds the runs on every iteration.

Hold the array:

```c
Array<UXAttrRun>* rs = a.runs();
for (u16 i = 0; i < rs.count(); i = i + 1) { … }
```
:::

## `attr` is a copy

The style on a run is a [`dup`](/compiler/api/uxkit/uxcharattr/) of the
characters' attributes, not a pointer into the string. A run stays valid and
unchanged if the string is restyled afterwards, and writing to `r.attr` changes
only the run you hold.

To restyle the string, use its range setters.

## An empty string has no runs

```c
UXAttributedString.make((u8*)"").runs().count();    // 0
```

Every other string has at least one run. `runs()` is safe to iterate without a
guard, and a zero count means the text is empty.

## Fields

### attr

```c
UXCharAttr* attr
```

The style shared by every character in the range. Never null on a run returned
by `runs()`.

### loc / len

Inherited from [`UXRange`](/compiler/api/uxkit/uxrange/). The range is
half-open: `loc` is included and `end()` is not.

## Example

```
plain:
  1 run(s): [0..16]
bold 6..10:
  3 run(s): [0..5] [6..10 B] [11..16]
+ italic 9..12:
  5 run(s): [0..5] [6..8 B] [9..10 B I] [11..12 I] [13..16]
all cleared:
  1 run(s): [0..16]
```

An overlapping italic **splits** the runs where the styles differ. Clearing both
merges everything back to one run with no merge step, because the runs were
never stored.

The program is `website/site/examples/uxkit/richtext.xc`. The `doc-examples`
gate compiles it, and the listing above is its output.

## Conforms to

- Inherits [`UXRange`](/compiler/api/uxkit/uxrange/), and through it
  [`Object`](/compiler/api/object/)

## See also

- [`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/): produces
  runs
- [`UXCharAttr`](/compiler/api/uxkit/uxcharattr/): the style, and the `sameAs`
  that defines a run boundary
- [`UXTextRun`](/compiler/api/uxkit/uxtextrun/): the laid-out counterpart, with
  an x position
