---
title: UXIosGraphics
description: "The iOS drawing vocabulary: the same primitives over the CGContext of the current draw, with no flip because UIKit already grows y downward."
---

`UXIosGraphics` is the UIKit realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/), sibling of
[`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/).

```c
#use <UXKit>            // or #import "UXIosGraphics.xc"
```

## The CGContext of the draw in flight

The ops act on the `CGContext` that UIKit set for **this** draw, inside
`libUXIos.m`'s `UXDrawView`. It is valid during the callback and not outside
it, the same arrangement as `NSGraphicsContext` on macOS and `cairo_t` on GTK.

Coordinates passed in are bounds-relative; the bound origin makes them absolute.

## No flip, unlike its macOS sibling

This is the main difference between the two Apple vocabularies, and it is easy
to get backwards.

| | |
| --- | --- |
| **AppKit** | default space grows y **up**; the shim declares a flipped view |
| **UIKit** | default space grows y **down**; nothing to do |

UIKit already matches the protocol, so there is no flipped-view override here
and no arithmetic to invert. Both frameworks draw through CoreGraphics, yet they
differ in this convention, which would otherwise leak into every custom view.

The platforms do not agree on a coordinate convention, so the toolkit defines
one in the protocol instead of in each view.

## It strokes natively

```c
strokesNatively()      // true
```

CoreGraphics strokes at sub-pixel precision with its own joins, so a path goes
to it rather than through the neutral offsetter. Arrowheads stay neutral
because CoreGraphics has no arrowhead, as on every hosted backend.

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol
- [`UXIosDriver`](/compiler/api/uxkit/uxiosdriver/): the backend
- [`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/): the sibling, and
  the flip
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): strokes and gradient fills
