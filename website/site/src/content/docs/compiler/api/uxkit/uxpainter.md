---
title: UXPainter
description: "Strokes, fills and gradient fills computed in neutral integer arithmetic, so a shape described once looks the same on GEM, Win32 and AppKit."
---

`UXPainter` draws **vector shapes** through the graphics seam: stroke a path,
fill a path, fill one with a radial gradient.

```c
#use <UXKit>            // or #import "UXPainter.xc"
```

## Overview

```c
UXPainter.fillShape(g, path, colour);
UXPainter.strokePath(g, path, 3, colour);
UXPainter.strokeOutlined(g, path, 8, fill, outline, 1);
UXPainter.fillShapeRadial(g, path, gradient, 24);
```

Everything is static. The [`UXGraphics`](/compiler/api/uxkit/uxgraphics/) is the
destination.

## Why this exists at all

The seam has **one primitive**, fill a polygon, instead of a call per effect.

The work here happens **once**, in neutral integer arithmetic, and every
backend gets the result. A 16-pixel stroke with a rounded start and an arrowhead
is the same pixels on GEM, Win32 and AppKit, because it is the same polygons on
all three.

With a `strokePath` call per backend, VDI's odd-only line widths, GDI's
geometric-pen joins and AppKit's line caps would all disagree about a shape the
application described once. Neither VDI nor GDI has an arrowhead.

## Stroking makes convex pieces, not one outline

A quad per segment, a fan per join, a polygon per cap, drawn in sequence and
overlapping.

A true offset outline is a much harder problem (self-intersection on tight
curves). Also, **a single path containing overlapping pieces cannot be filled
even-odd without the overlaps cancelling to holes**. Overdrawing convex pieces
in an opaque colour has neither problem, and the [fill-rule
difference](/compiler/api/uxkit/uxshapepath/#containment-is-even-odd) between
backends cannot show through it.

:::caution[It assumes an opaque colour]
Overlapping pieces fill the joins. Draw a stroke in a semi-transparent colour
and the overlaps show as darker patches at every joint and cap.

For translucent strokes, stroke into an offscreen surface at full opacity and
composite that.
:::

## Native stroking where it is better

```c
if (g.strokesNatively()) { … }
```

Where a backend strokes properly, [`strokePath`](#strokepath) passes it the
path. A backend draws the **curve** at sub-pixel precision with its own joins.
The neutral stroker cannot: it offsets a polyline whose vertices are whole
pixels, so its silhouette wobbles by up to half a pixel and looks lumpy wherever
something antialiases.

The neutral code always handles:

- **Arrowheads**, because no backend has one
- **GEM entirely**, which has no native stroker

The neutral path is therefore the only path on one backend and part of every
stroke on the others.

## strokeOutlined, and the arrowhead exception

```c
UXPainter.strokeOutlined(g, p, width, fill, outline, rim);
```

A stroke with a border: the body drawn `2 × rim` wider in the outline colour,
then the real stroke on top.

That dilation works for a disc cap (a bigger disc is the right disc) and a
square one (a wider quad is the right quad). It does **not** work for an
arrowhead, because a bigger similar triangle is not an offset one. The rim
pinches to nothing at the tip, so an outlined arrow looks like a second triangle
instead of a line of even thickness. It also vanishes across the rear edge,
because both triangles share it.

Arrowheads are therefore suppressed in the wide pass and outlined separately, as
a **filled, truly offset** triangle drawn under the fill. Filling a dilated
shape, instead of stroking the real shape's outline, keeps the rim outside the
shape. A stroke straddles the edge, so half the rim would land inside and show
through wherever the fill did not quite reach.

## The radial fill is banded, on purpose

```c
UXPainter.fillShapeRadial(g, path, gradient, 24);
```

Draw the shape in the outermost colour, then a stack of progressively smaller
copies through to the centre colour.

This is neutral because only AppKit has a radial gradient primitive. GDI's
`GradientFill` is linear-only and VDI has nothing, so a native path would make
one backend look different from the other two.

The result is a set of **bands**. 24 is smooth at widget size, and the cost is
24 polygon fills instead of a per-pixel sweep. The count is clamped to
`2`–`64`.

## Topics

[fillShape](#fillshape) · [fillShapeRGB](#fillshapergb) · [strokePath](#strokepath) · [strokeOutlined](#strokeoutlined) · [fillShapeRadial](#fillshaperadial)

### fillShape

```c
static void fillShape(UXGraphics* g, UXShapePath* p, i32 colour)
```

Fill a path. Curves are flattened first, so a curved path fills as the polyline
that approximates it.

`colour` is a **pen index or a packed RGB**. The painter tells them apart and
calls the matching seam entry, so one signature covers a 16-colour palette and a
true-colour backend.

### fillShapeRGB

```c
static void fillShapeRGB(UXGraphics* g, UXShapePath* p, i32 r, i32 gr, i32 b)
```

Fill in an explicit colour, when you have components instead of a packed value.

### strokePath

```c
static void strokePath(UXGraphics* g, UXShapePath* p, i16 width, i32 colour)
```

Stroke, including any [caps](/compiler/api/uxkit/uxshapepath/#caps-belong-to-the-path)
the path carries. Uses the backend's stroker where there is one; see
[above](#native-stroking-where-it-is-better).

### strokeOutlined

```c
static void strokeOutlined(UXGraphics* g, UXShapePath* p, i16 width,
                           i32 fill, i32 outline, i16 rim)
```

A stroke with a border of `rim` pixels each side.

:::note[It restores the path's caps, but does mutate briefly]
The arrowhead suppression sets the path's caps to `UXCAP_NONE` and then restores
them. The path is unchanged afterwards, but calling this on one path from two
places at once is not safe.
:::

### fillShapeRadial

```c
static void fillShapeRadial(UXGraphics* g, UXShapePath* p,
                            UXGradient* grad, i32 bands)
```

Centre-to-edge gradient fill. The centre is the bounding box's centre; `bands`
is clamped to `2`–`64`.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass); all
  methods are static

## See also

- [`UXShapePath`](/compiler/api/uxkit/uxshapepath/): the shapes, the caps, and
  the flattener
- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the seam this draws through
- [`UXGradient`](/compiler/api/uxkit/uxgradient/): the colours `fillShapeRadial`
  samples
