---
title: UXGdiGraphics
description: "The Win32/GDI drawing vocabulary: the same primitives every drawRect calls, over a device context instead of the VDI."
---

`UXGdiGraphics` is the Win32 realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/), and the first sibling of
[`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/).

```c
#use <UXKit>            // or #import "UXGdiGraphics.xc"
```

## The same primitives, a different surface

Every `drawRect` in the toolkit calls the same small set of methods. This
class implements them over a **device context** rather than a VDI
workstation.

Incoming coordinates are **bounds-relative**, and the bound origin makes
them absolute, as on GEM. Because the contract does not change, a view's
drawing body is written once and is correct on every backend.

GDI's y grows down, as GEM's does, so nothing needs flipping.

## Two implementations define the protocol

This class shows that [`UXGraphics`](/compiler/api/uxkit/uxgraphics/) is an
interface and not a description of the VDI. Two implementations satisfy
it: one over an early-80s workstation model, the other over a
device-context model. The later backends implement the same methods.

## It has no theme art

```c
hasThemeArt()      // false
```

Windows has no equivalent of GEM's drawable theme slices, so
[`drawTheme`](/compiler/api/uxkit/uxgraphics/) has nothing to call and the
toolkit draws the pieces itself.

Answering `false` is safe because there is a neutral fallback. A capability
query asks whether the backend *can* do something, not whether it must, and
the toolkit always has an answer for no.

## It strokes natively

```c
strokesNatively()      // true
```

[`UXPainter.strokePath`](/compiler/api/uxkit/uxpainter/#strokepath) hands
GDI the path, and GDI draws the curve at its own precision with its own
joins, instead of the toolkit offsetting a whole-pixel polyline.

Arrowheads stay neutral, because GDI has none. All six hosted backends use
this split: the platform draws what it draws well, and the toolkit draws
what no platform has.

## Pens map to a colour table

The toolkit draws with VDI pen indices. This vocabulary keeps the
index-to-RGB table (`penColor`) that converts them for GDI.

[`UXCanvasGraphics`](/compiler/api/uxkit/uxcanvasgraphics/) mirrors the same
table, split per channel because the host import signature takes `r`, `g`
and `b` separately. Keeping the table in several places has a maintenance
cost; in return a pen number means the same colour on every backend.

`fillRectRGB` and `fillPolygonRGB` are the true-colour entry points for
[`UXColor`](/compiler/api/uxkit/uxcolor/)-driven drawing that bypasses the
palette.

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol
- [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/): the backend this draws
  for
- [`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/): the original
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): where the neutral stroking
  happens
