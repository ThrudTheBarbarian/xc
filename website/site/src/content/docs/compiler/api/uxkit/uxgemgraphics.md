---
title: UXGemGraphics
description: "The GEM/VDI drawing vocabulary: thin, because a custom view drawing itself uses the same VDI calls the AES uses for a stock widget."
---

`UXGemGraphics` is the GEM realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the AES's own VDI
workstation, plus the theme.

```c
#use <UXKit>            // or #import "UXGemGraphics.xc"
```

## Thin on purpose

It is the thinnest of the seven vocabularies. A
[`UXView`](/compiler/api/uxkit/uxview/) that draws itself makes the same VDI
calls that `objc_draw` makes for a `G_BUTTON`.

Custom views and stock widgets are therefore pixel-consistent **by
construction**. There is no separate drawing path to drift and no palette
to keep in step, so a custom control drawn beside a native one matches it.

Every other backend (GDI, CoreGraphics, cairo, Canvas2D) is a sibling of
this class, implementing the same protocol over a different surface.

## The coordinate contract

Incoming coordinates are **bounds-relative**; the bound origin makes them
absolute:

```c
g.bind(handle, theme, absRect);
g.fillRect(UXGeom.make(0, 0, 10, 10), pen);   // the view's own top-left
```

All seven vocabularies share this contract, so a `drawRect` body is written
once. A view never knows where on screen it is.

GEM's y grows **down**, the direction the whole protocol uses. The Mac shim
flips to match; the other backends already agree.

## It has theme art

```c
hasThemeArt()      // true
```

GEM has a real theme with drawable slices, so
[`drawTheme`](/compiler/api/uxkit/uxgraphics/) draws something here. The GDI
and Cocoa vocabularies answer **false**, and the toolkit falls back to
drawing the pieces itself.

Capability queries in this toolkit follow this pattern: ask what the
backend can do, and have a neutral answer for when it cannot.

## It is the one that does not stroke natively

```c
strokesNatively()     // false — the only backend that says so
```

The VDI has no path stroker with joins and caps, so `strokeNative` is empty
and [`UXPainter`](/compiler/api/uxkit/uxpainter/)'s neutral stroker does all
the work: a quad per segment, a fan per join, a polygon per cap.

Because GEM is the one backend where the neutral stroker is the **only**
path, that stroker is exercised every time anything is stroked here. A
regression in it shows up as a failing GEM test instead of going unnoticed.

On the other six backends, the neutral stroker still draws every arrowhead,
because no platform has one.

## Pens are indices

Colours are VDI pen indices rather than RGB, with `fillRectRGB` and
`fillPolygonRGB` as the true-colour entry points. Pen `0` is white and pen
`1` is ink. A default
[`UXCharAttr`](/compiler/api/uxkit/uxcharattr/) uses `1` so that a
default-constructed style is visible.

The other backends mirror the same index table, so a pen means the same
colour everywhere.

## Fonts

`fontIdFor` maps a family name to a VDI font id. A family the workstation
does not have falls back instead of failing, so a document written on one
machine stays legible on another.

Text measurement goes through the driver, not this class. Layout needs to
measure text before `drawTextFont` draws it.

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol, and the
  primitive set
- [`UXGemDriver`](/compiler/api/uxkit/uxgemdriver/): which owns the context it
  hands to `drawRect`
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): the neutral stroker this
  backend depends on entirely
- [`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/): the first sibling
