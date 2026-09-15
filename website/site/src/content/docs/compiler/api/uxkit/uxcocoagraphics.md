---
title: UXCocoaGraphics
description: "The macOS drawing vocabulary: the same primitives over the current NSGraphicsContext, with the view flipped so y grows down as on every other backend."
---

`UXCocoaGraphics` is the AppKit realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/), sibling of
[`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/).

```c
#use <UXKit>            // or #import "UXCocoaGraphics.xc"
```

## The same primitives, over an NSGraphicsContext

The drawing ops act on the `NSGraphicsContext` set by the draw in progress. They
live in the shim (`libUXAppKit.m`), so no Cocoa type crosses into portable code.

Coordinates passed in are **bounds-relative**; the bound origin makes them
absolute. This matches GEM and GDI, so a `drawRect` body is written once.

## The view is flipped, and that is a decision

macOS is the one platform whose default coordinate space grows **y upward**. The
toolkit's protocol grows y **down**, as GEM, GDI, cairo, Canvas2D, UIKit and
Android Canvas all do.

Instead of inverting every coordinate in every primitive and every view, the
shim's `UXDrawView` declares itself **flipped**. That one override makes the
vocabulary agree with the other six backends, with no `height - y` anywhere.

Flipping per call would make every custom view's arithmetic
platform-dependent, and a bug there would look like a layout bug rather than a
coordinate one.

## It has no theme art

```c
hasThemeArt()      // false
```

There are no drawable theme slices to call, so the toolkit draws the pieces
itself, as on Windows.

This applies only to the *drawing vocabulary* for views the toolkit paints
itself. The native controls
[`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/) realizes (`NSTableView`,
`NSSlider`, `NSPopUpButton` and the rest) are fully native and look it.

## It strokes natively

```c
strokesNatively()      // true
```

A stroked path goes to Cocoa at sub-pixel precision with Cocoa's own joins. The
neutral offsetter's whole-pixel vertices wobble by up to half a pixel, which is
visible under antialiasing.

Arrowheads remain neutral, because Cocoa has no arrowhead. See
[`UXPainter`](/compiler/api/uxkit/uxpainter/#native-stroking-where-it-is-better).

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol
- [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/): the backend
- [`UXIosGraphics`](/compiler/api/uxkit/uxiosgraphics/): the CoreGraphics
  sibling that needs no flip
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): strokes, fills and gradients
