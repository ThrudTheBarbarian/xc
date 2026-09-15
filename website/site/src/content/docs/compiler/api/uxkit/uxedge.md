---
title: UXEdge
description: "One line segment of a flattened path, the form that containment tests and scanline filling run on."
---

`UXEdge` is a single line segment: two endpoints, and nothing else.

```c
#use <UXKit>            // or #import "UXShapePath.xc"
```

## Overview

```c
class UXEdge : Object {
    i16 x0; i16 y0;
    i16 x1; i16 y1;
}
```

[`UXShapePath.edges`](/compiler/api/uxkit/uxshapepath/#edges) produces them.
Edges reduce the path to the form that geometry code handles most easily:
segments only, with no curves, no subpath structure and no current point.

## Why a separate type from UXPathElement

They describe the same shape at different stages.

| | |
| --- | --- |
| [`UXPathElement`](/compiler/api/uxkit/uxpathelement/) | what the **author** drew: commands, curves, and an implicit current point |
| `UXEdge` | what the **geometry** runs on: explicit, self-contained segments |

An element depends on the one before it; an edge does not. Because each edge
carries both of its endpoints, a containment test can look at edges in any
order, and a scanline filler can sort them.

## Every subpath arrives closed

`edges()` closes each subpath as it emits it, whether or not you called
[`close`](/compiler/api/uxkit/uxshapepath/#close). The edge list therefore
always describes closed regions. Even-odd containment depends on this, since an
open outline has no inside.

As a result, an unclosed triangle still hit-tests as a triangle, and its edge
count is three, not two.

## Zero-length edges are dropped

Consecutive identical points produce no edge. A degenerate segment has no
direction, and a containment test that counted it would either double-count a
crossing or divide by zero computing one.

An edge from `edges()` is always a real segment with `(x0,y0) != (x1,y1)`, and
the count can be lower than the number of `lineTo` calls that produced it.

## Direction is preserved, and unused

An edge runs from `0` to `1` in the order the path was drawn. Even-odd
containment counts crossings, not windings, so the direction has no meaning for
the tests here.

Direction matters if you add a **non-zero winding** rule of your own, which
needs to know which way each edge crosses the ray. The information is kept for
that purpose; nothing in the toolkit reads it.

## Fields

### x0 / y0

```c
i16 x0; i16 y0
```

The start point.

### x1 / y1

```c
i16 x1; i16 y1
```

The end point.

## Example

```
triangle:  x=10 y=10 w=80 h=70 edges=3
unclosed:  x=10 y=10 w=80 h=70 edges=3
blob:      x=20 y=20 w=60 h=60 edges=70
ring:      x=0 y=0 w=100 h=100 edges=8
empty:     x=0 y=0 w=0 h=0 edges=0
```

The closed and unclosed triangles give the same three edges. The two-subpath
ring gives eight. A curved blob gives seventy, the flattener's result at a
quarter-pixel tolerance.

The program is `website/site/examples/uxkit/shapes.xc`; the `doc-examples` gate
compiles it, and the output above is what it prints.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXShapePath`](/compiler/api/uxkit/uxshapepath/): `edges()` and
  `containsPoint`
- [`UXPathElement`](/compiler/api/uxkit/uxpathelement/): the authored form
- [`UXGeom`](/compiler/api/uxkit/uxgeom/): `UXPoint` and `UXRect`, for a point
  or a box instead of a segment
