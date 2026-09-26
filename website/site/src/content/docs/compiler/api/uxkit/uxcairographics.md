---
title: UXCairoGraphics
description: "The GTK4 drawing vocabulary: the same primitives over the cairo_t of the draw in flight."
---

`UXCairoGraphics` is the GTK4 realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/).

```c
#use <UXKit>            // or #import "UXCairoGraphics.xc"
```

## The cairo_t of the draw in flight

The drawing ops act on the `cairo_t` that GTK passed to the drawing area for
**the current draw**. The shim (`libUXGtk.c`) sets it before the callback, and
it is not valid outside the callback.

The `NSGraphicsContext` on macOS and the `CGContext` on iOS work the same way:
the surface belongs to the draw in progress and is not an object you hold. For
that reason the vocabulary has no context field for you to keep, and a draw
request outside a draw callback has nothing to draw onto.

Coordinates passed in are **bounds-relative**. The bound origin makes them
absolute, as on every backend.

## No flipping needed

Cairo's space grows y **down**, which is the protocol's direction. Unlike
[`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/), where the shim
declares a flipped view, nothing here has to be inverted.

Six of the seven backends draw y-down without a flip: cairo, Canvas2D, UIKit
and Android `Canvas`, plus VDI and GDI. Only Cocoa needs one.

## Clipping is a stack, not an object

```c
void ux_gtk_clip(i32 x, i32 y, i32 w, i32 h);
void ux_gtk_clip_end(void);
```

Clipping is push and pop, with no clip object. A clip object would be a
`cairo_rectangle_t`, which is a struct, and structs do not travel into xc.

The whole shim surface uses primitives only: integers, and `u8*` with an
explicit capacity. Both sides of the foreign-function boundary can agree on that
without knowing each other's layout rules.

## It strokes natively

```c
strokesNatively()      // true
```

Cairo is a good stroker, so a path goes to it directly with its own joins and
sub-pixel precision. Arrowheads stay neutral, as on every backend.

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol
- [`UXGtkDriver`](/compiler/api/uxkit/uxgtkdriver/): the backend
- [`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/): the sibling that
  needs a flip
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): strokes and gradient fills
