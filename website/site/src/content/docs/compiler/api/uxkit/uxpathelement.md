---
title: UXPathElement
description: "One command in a UXShapePath: a move, a line, a close, or a cubic curve with its two control points."
---

`UXPathElement` is one step of a
[`UXShapePath`](/compiler/api/uxkit/uxshapepath/): what to do, and where.

```c
#use <UXKit>            // or #import "UXShapePath.xc"
```

## Overview

```c
class UXPathElement : Object {
    i32 type;                    // UXPE_MOVE / UXPE_LINE / UXPE_CLOSE / UXPE_CURVE
    i16 x;   i16 y;              // the on-curve point
    i16 c1x; i16 c1y;            // UXPE_CURVE only
    i16 c2x; i16 c2y;
}
```

A path is an array of these, in order. You build them with
[`moveTo`](/compiler/api/uxkit/uxshapepath/#moveto) and related methods instead
of constructing them yourself. The class is public because reading a path back
(to serialise it, edit it, or draw handles for it) means walking the elements.

## The four types

| constant | meaning | fields used |
| --- | --- | --- |
| `UXPE_MOVE` | start a new subpath at `x,y` | `x`, `y` |
| `UXPE_LINE` | straight line to `x,y` | `x`, `y` |
| `UXPE_CLOSE` | close the current subpath | none |
| `UXPE_CURVE` | cubic Bézier to `x,y` | all six |

There is **no quadratic type**. `quadTo` elevates its control point to a cubic
pair on the way in, so flattening, bounds and containment handle one curve form.
A path you read back shows `UXPE_CURVE` where you wrote a quad.

`UXPE_CLOSE` carries no coordinates: the subpath's start is already known from
the `UXPE_MOVE` that opened it.

## The control points are the previous point's partners

A cubic needs four points, and the element stores three. The fourth, the start,
is the **current point**: wherever the previous element left off.

```c
p.moveTo(20, 50);                          // current point is 20,50
p.curveTo(20, 10, 80, 10, 80, 50);         // P0 = 20,50 implicitly
```

This is the usual path convention. Elements cannot be reordered or removed
independently, because each one's meaning depends on the one before it.

## Coordinates are `i16`

Whole pixels, with a range of ±32767. That is an authoring range, well past any
window and any printed page at device resolution.

The precision *rendering* needs lives elsewhere: the flattener can emit
1/16-pixel units, which the stroker works in and rounds once at the end. See
[sub-pixel
output](/compiler/api/uxkit/uxshapepath/#sub-pixel-output-and-why). The element
type stays small and exact, and the fractional work happens where it is needed.

## Fields

### type

```c
i32 type
```

One of the four constants above.

### x / y

```c
i16 x; i16 y
```

The on-curve point this element ends at. Unused by `UXPE_CLOSE`.

### c1x / c1y / c2x / c2y

```c
i16 c1x; i16 c1y;    // first control point
i16 c2x; i16 c2y;    // second
```

Meaningful only for `UXPE_CURVE`. For other types they are zero: `init` clears
them, so a move or line element reads as `0,0`, not as leftover memory.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXShapePath`](/compiler/api/uxkit/uxshapepath/): the path these build
- [`UXEdge`](/compiler/api/uxkit/uxedge/): what a flattened path becomes
