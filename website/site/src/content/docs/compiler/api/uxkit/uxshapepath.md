---
title: UXShapePath
description: "A vector path with curves. Build it, bound it and hit-test it; it flattens on demand in integer arithmetic, so every backend gets the same pixels."
---

`UXShapePath` is a vector path: `moveTo`, `lineTo`, `curveTo`, `quadTo`,
`close`. Ask it for a bounding box, for its edges, or whether a point is inside.

It is pure geometry with no driver or backend to boot, so a custom-shaped
control can hit-test itself in a unit test.

```c
#use <UXKit>            // or #import "UXShapePath.xc"
```

## Overview

```c
UXShapePath* tri = new UXShapePath();
tri.moveTo(10, 10);
tri.lineTo(90, 10);
tri.lineTo(50, 80);
tri.close();

tri.boundingBox();                  // 10,10 80x70
tri.containsPoint(50, 30);          // true
tri.containsPoint(5, 5);            // false
```

It is shaped like `NSBezierPath`. Coordinates are `i16`, which is the authoring
range; see [sub-pixel units](#sub-pixel-output-and-why) for where the precision
lives.

## Curves are stored, not flattened on the way in

A path keeps the cubic you drew. [`flattened`](#flattened) produces the polyline
**on demand**:

```c
blob.hasCurves();              // true
UXShapePath* flat = blob.flattened();
flat.hasCurves();              // false
blob.hasCurves();              // still true — the original is untouched
```

Flattening is **lossy and resolution-dependent**. The same path may want 8
segments in a 40-pixel thumbnail and 200 in a printout. A path that discarded
its curves at build time could only answer at one of them.

Every consumer here ([`boundingBox`](#boundingbox), [`edges`](#edges),
[`containsPoint`](#containspoint)) routes through `flattened()`, so **a curved
path behaves the same as the straight-line path it approximates**. There is no
separate curve code path to disagree with the line one.

### The bounding box is of the curve, not the control points

```c
blob.moveTo(20, 50);
blob.curveTo(20, 10, 80, 10, 80, 50);   // control points at y = 10
blob.boundingBox();                      // y = 20, not 10
```

The box is measured from the flattened polyline, so it is the box the shape
occupies. A control-point box would be ten pixels too large here, and a hit
test built on it would accept clicks in empty space.

## Integer flattening, and why it is de Casteljau

The flattener **subdivides**: it halves the curve, tests whether the halves are
flat enough to be lines, and recurses if not. All arithmetic is integer.

Halving is add-and-shift, so it cannot overflow. Evaluating B(t) at `t = i/n`
needs `n³ × coordinate`, which leaves `i32` at around `n = 16`, and xt has no
64-bit integer. Integer arithmetic also means every backend flattens a given
path to **the same pixels**, instead of each rounding a float its own way.

Two constants bound it:

| | |
| --- | --- |
| tolerance | a **quarter pixel** of chord deviation |
| depth cap | 9 levels — at most 512 segments per curve |

The deviation is measured against the true chord length, not a *Manhattan*
length. The Manhattan length over-estimates the true length by up to 41%, which
would loosen a whole-pixel tolerance to about 1.4 px and turn a 60-pixel blob
into a visible octagon. The depth cap stops a pathological curve subdividing for
ever.

## Sub-pixel output, and why

A path stores **whole-pixel** coordinates, which suits authoring. A stroke built
from whole-pixel vertices has a silhouette that wobbles by up to half a pixel,
and a one-pixel wobble is visible on *every* backend, antialiased or not. Hard
pixels on GEM do not hide it.

The flattener can therefore also emit **1/16 px** units. The neutral stroker
works in these and rounds **once**, at the end.

## Containment is even-odd

[`containsPoint`](#containspoint) casts a horizontal ray and counts crossings.
This has two consequences:

```c
ring.containsPoint(10, 50);    // true  — in the wall
ring.containsPoint(50, 50);    // false — in the hole
```

A second subpath inside the first is a **hole**. This is even-odd fill, and it
cuts a hole without a boolean operation.

Every subpath is also **implicitly closed** for containment, so a path you did
not `close()` still hit-tests as the shape you drew:

```c
open.containsPoint(50, 30);    // true, with no close() anywhere
```

`close()` still matters for *stroking*: an unclosed path has two loose ends,
and caps go on ends.

## Caps belong to the path

```c
arrow.setEndCap(UXCAP_ARROW);
arrow.setCapWidth(6);
```

| | |
| --- | --- |
| `UXCAP_NONE` | stop dead at the endpoint (butt) |
| `UXCAP_ROUND` | a half-disc of the stroke width |
| `UXCAP_SQUARE` | a half-width square extension |
| `UXCAP_ARROW` | an arrowhead pointing the way the path was going |

Caps live here and not on a backend because a cap is a property of **the shape
the author drew**, whatever renders it. The cap geometry uses the same integer
arithmetic as the rest of this page. A closed subpath has no ends and therefore
no caps.

## Topics

[moveTo](#moveto) · [lineTo](#lineto) · [curveTo](#curveto) · [quadTo](#quadto) · [close](#close) · [rect](#rect) · [hasCurves](#hascurves) · [flattened](#flattened) · [boundingBox](#boundingbox) · [edges](#edges) · [containsPoint](#containspoint) · [setStartCap](#setstartcap--setendcap) · [setEndCap](#setstartcap--setendcap) · [setCapWidth](#setcapwidth) · [setArrowLength](#setarrowlength) · [capOutline](#capoutline)

### moveTo

```c
void moveTo(i16 x, i16 y)
```

Start a new subpath. A path may have any number.

### lineTo

```c
void lineTo(i16 x, i16 y)
```

### curveTo

```c
void curveTo(i16 c1x, i16 c1y, i16 c2x, i16 c2y, i16 x, i16 y)
```

A cubic Bézier: two off-curve control points, then the on-curve end.

### quadTo

```c
void quadTo(i16 cx, i16 cy, i16 x, i16 y)
```

A quadratic, **elevated to a cubic** on the way in, so there is one curve type
to flatten. `hasCurves()` becomes true.

### close

```c
void close(void)
```

Close the current subpath. Affects stroking and caps; containment closes
implicitly either way.

### rect

```c
static UXShapePath* rect(i16 x, i16 y, i16 w, i16 h)
```

A shortcut for the commonest shape.

### elementCount / elemAt

```c
i32 elementCount(void)
UXPathElement* elemAt(i32 i)
```

Walk the path's commands. A path *editor* uses these to draw the handles,
serialise the shape, or re-emit it transformed. They read the path and do not
build it; see [`UXPathElement`](/compiler/api/uxkit/uxpathelement/) for what
each element carries.

### add

```c
void add(i32 type, i16 x, i16 y)
```

Append a raw element. [`moveTo`](#moveto), [`lineTo`](#lineto) and
[`close`](#close) are written in terms of it. Use it to replay a path you walked
with [`elemAt`](#elementcount--elemat).

It takes no control points, so it cannot append a curve. `UXPE_CURVE` needs
[`curveTo`](#curveto).

### startCapKind / endCapKind / arrowLength

```c
i32 startCapKind(void)
i32 endCapKind(void)
i16 arrowLength(void)
```

Read back what [`setStartCap`](#setstartcap--setendcap) and the related setters
set. The stroker uses them; an application reads them to show the current cap
in an inspector.

### hasCurves

```c
bool hasCurves(void)
```

Whether any element is a curve. When false, [`flattened`](#flattened) is a
no-op.

### flattened

```c
UXShapePath* flattened(void)
```

A new path of straight lines only. The receiver is unchanged.

### boundingBox

```c
UXRect boundingBox(void)
```

The [`UXRect`](/compiler/api/uxkit/uxgeom/) the flattened shape occupies. An
empty path gives an empty box.

### edges

```c
Array<UXEdge>* edges(void)
```

The path as line segments, with each subpath closed. Zero-length segments are
dropped, so consecutive identical points do not become degenerate edges.

:::note[`edges()` allocates, and `containsPoint` calls it]
Each call flattens (if needed) and builds a fresh array, so a hit test costs a
flatten.

For a shape you test repeatedly, such as a control's outline against every
mouse move, flatten once, keep the result, and test against that.
:::

### containsPoint

```c
bool containsPoint(i16 px, i16 py)
```

Even-odd containment. See [above](#containment-is-even-odd).

### setStartCap / setEndCap

```c
void setStartCap(i32 c)
void setEndCap(i32 c)
```

### setCapWidth

```c
void setCapWidth(i16 w)
```

The stroke width the caps are built for. `0` means ask at cap time.

### setArrowLength

```c
void setArrowLength(i16 n)
```

Arrowhead length along the direction of travel. `0` means three times the width.

### capOutline

```c
UXShapePath* capOutline(bool atStart, i16 width)
```

The cap as its own path, ready to fill. Null when that end has no cap (a closed
subpath, or `UXCAP_NONE`).

## Example

```
triangle:  x=10 y=10 w=80 h=70 edges=3
inside (50,30)=1  outside (5,5)=0  outside (50,90)=0
unclosed:  x=10 y=10 w=80 h=70 edges=3
still contains (50,30): 1
blob has curves: 1
blob:      x=20 y=20 w=60 h=60 edges=70
flattened has curves: 0  edges=70
original still curved: 1
ring:      x=0 y=0 w=100 h=100 edges=8
in the wall (10,50)=1   in the hole (50,50)=0
empty:     x=0 y=0 w=0 h=0 edges=0
```

The blob's control points sit at `y = 10` and its box starts at `y = 20`, the
curve's real extent. The program is `website/site/examples/uxkit/shapes.xc`; the
`doc-examples` gate compiles it, and the output above is its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXPathElement`](/compiler/api/uxkit/uxpathelement/): one command in the
  path
- [`UXEdge`](/compiler/api/uxkit/uxedge/): one line segment
- [`UXRect`](/compiler/api/uxkit/uxgeom/): what `boundingBox` returns
- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the drawing seam these are
  stroked through
