---
title: UXCanvasGraphics
description: "The Canvas2D drawing vocabulary: the same primitives over host imports, with the pen table kept in wasm so the JS surface only sees r, g, b."
---

`UXCanvasGraphics` is the Canvas2D realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/). The web backend draws through
it.

```c
#use <UXKit>            // or #import "UXCanvasGraphics.xc"
```

## Eight imports is the whole host surface

It is the sibling of [`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/): the
same primitives every `drawRect` calls, over **host canvas imports** instead of
a device context.

Coordinates passed in are bounds-relative, and the bound origin makes them
absolute, as on the other backends. Canvas2D's y grows down, so nothing needs
flipping.

The important number is how *few* imports there are. Together with the window
group and the ring, eight drawing primitives make up the entire JS surface. That
lets the structural half of the toolkit run with
[zero crossings](/compiler/api/uxkit/uxwebdriver/#the-same-shadow-tree-in-linear-memory).

## The pen table stays in wasm

```c
i32 penR(i32 pen) { … }     // and penG, penB
```

The toolkit draws with VDI pen indices. Resolving an index to a colour happens
**xc-side**, so the JS surface only sees `r`, `g`, `b`.

There are two reasons. A pen table in JS would be a second copy of the table in
[`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/), free to drift. And the
import signature would have to take a pen, so the host would need to know what a
pen *is*. The boundary exists to keep that knowledge out of the host.

The colour is split per channel instead of packed because the import signature
takes three integers. Packing would save a parameter and require the host to
unpack, which brings back host-side knowledge for no benefit.

## It has theme art

```c
hasThemeArt()      // true
```

Unlike GDI and Cocoa, the canvas backend can draw theme slices, so
[`drawTheme`](/compiler/api/uxkit/uxgraphics/) does something here.

It is one of two backends out of seven that answer yes, alongside
[`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/). The capability queries
track what a *surface* can do, not how modern it is.

## It strokes natively

```c
strokesNatively()      // true
```

Canvas2D has a real stroker with joins and caps, so paths go to it directly.
Arrowheads stay neutral, as on every backend.

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol
- [`UXWebDriver`](/compiler/api/uxkit/uxwebdriver/): the backend, and how it
  avoids crossings
- [`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/): the sibling whose pen
  table this mirrors
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): strokes and gradient fills
