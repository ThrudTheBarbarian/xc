---
title: UXTextRun
description: "A span of text with a pixel position and an optional style: what line breaking hands to drawing, one stroke at a time."
---

`UXTextRun` is a span of characters that has been **placed**: a
[`UXRange`](/compiler/api/uxkit/uxrange/) into the original text, the `x` at
which it starts, and the style to draw it in.

```c
#use <UXKit>            // or #import "UXTextLayout.xc"
```

## Overview

```c
class UXTextRun : UXRange {
    i32         x;       // pixels from the left of the line
    UXCharAttr* attr;    // null = the view's default style
}
```

[`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/) produces runs and a draw
call consumes them: move to `x`, set the style, and stroke `len` characters
starting at `loc`.

## Range into the original, not a copy

`loc` and `len` index the **source text**. Nothing is cut up or duplicated, so
wrapping a paragraph allocates run objects, not strings.

The text must therefore outlive the layout:

:::caution[The runs are only as valid as the text they index]
A run holds no characters of its own. If the string it was laid out from is
freed or its contents change, every run still points into it.

Lay the text out again after editing. The layout is cheap to recompute and
cannot be patched correctly. [`UXAttrRun`](/compiler/api/uxkit/uxattrrun/) makes
the same trade.
:::

## `x` is why this is not a UXAttrRun

Both are ranges with a style, but they answer different questions:

| | |
| --- | --- |
| [`UXAttrRun`](/compiler/api/uxkit/uxattrrun/) | *what style* these characters have — derived from the model |
| `UXTextRun` | *where* these characters go — derived from measuring |

A styled span may be split across two lines, becoming two `UXTextRun`s with
different `x` values and the same `attr`. A single line may hold several runs
because the style changes mid-line. The mapping is not one-to-one in either
direction, so there are two types.

## `attr` may be null

```c
UXTextRun.at(loc, len, x);                  // attr == 0
UXTextRun.styled(loc, len, x, someAttr);    // attr set
```

Null means **the view's default style**. Plain unstyled text lays out without
allocating an attribute per run, and a drawing pass reads null as "leave the
font unchanged".

Check before dereferencing:

```c
if (r.attr != (UXCharAttr*)0 && r.attr.bold) { … }
```

## Topics

[at](#at) · [styled](#styled)

### at

```c
static UXTextRun* at(i32 l, i32 n, i32 px)
```

An unstyled run; `attr` is null.

### styled

```c
static UXTextRun* styled(i32 l, i32 n, i32 px, UXCharAttr* a)
```

A run carrying a style. The attribute is **kept, not copied**, so it must
outlive the run. Normally it does, because it comes from the attributed string
being laid out.

## Fields

### x

```c
i32 x
```

Pixels from the left edge of the line, including the width of the runs before
it. The value is absolute within the line, not a delta.

### attr

```c
UXCharAttr* attr     // null = the view's default
```

### loc / len

Inherited from [`UXRange`](/compiler/api/uxkit/uxrange/). Half-open, indexing
the source text.

## Conforms to

- Inherits [`UXRange`](/compiler/api/uxkit/uxrange/), and through it
  [`Object`](/compiler/api/object/)

## See also

- [`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/): the line breaker that
  produces these
- [`UXAttrRun`](/compiler/api/uxkit/uxattrrun/): the model-side run
- [`UXCharAttr`](/compiler/api/uxkit/uxcharattr/): the style itself
- [`UXRange`](/compiler/api/uxkit/uxrange/): the half-open contract both share
