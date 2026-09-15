---
title: UXGraphics
description: "The drawing context handed to every drawRect: one set of primitives, native pixels on every backend, in bounds-relative coordinates."
---

`UXGraphics` is the drawing context your `drawRect` receives. It is a
**protocol**, so each backend supplies its own realization (the VDI on GEM,
GDI on Windows, CoreGraphics on macOS, a canvas on the web). Your drawing
code never learns which one it is using.

```c
#use <UXKit>            // or #import "UXGraphics.xc"
```

## Overview

```c
class Badge : UXView {
    void drawRect(UXGraphics* g, UXRect dirty) {
        UXRect b = self.bounds();
        g.fillRect(UXGeom.make(0, 0, b.w, b.h), 1);
        g.drawText((u8*)"12", 6, 4, 0, 12);
    }
}
```

**Coordinates are bounds-relative.** `0,0` is your view's top-left, and the
backend adds the view's origin. A `drawRect` never needs to know where it
sits on screen, and moving a view needs no drawing change.

## Pens and RGB

Most primitives come in two forms:

```c
g.fillRect(r, 1);                     // a VDI pen index
g.fillRectRGB(r, 48, 80, 160);        // true 8-bit RGB
```

Pens are indices into the platform's palette (pen 1 is ink), and the theme
and the AES use them. Use a pen when you want the platform's own ink colour.
Use RGB when you have a specific colour, typically from
[`UXColor`](/compiler/api/uxkit/uxcolor/).

## Capability flags, not assumptions

Two methods ask the backend what it can do. A well-written widget draws
differently depending on the answer.

### hasThemeArt

```c
bool hasThemeArt(void)
```

True where [`drawTheme`](#drawtheme) renders **real atlas art** (GEM and the
web), and false where it draws a flat stand-in. A widget picks sprite art or
geometry accordingly:

```c
if (g.hasThemeArt()) { g.drawTheme((u8*)"radio.selected", box); }
else                 { /* draw the ring and dot with primitives */ }
```

With this check, one `drawRect` gives a radio button that looks native on
GEM and still looks right on a backend with no atlas.

### strokesNatively

```c
bool strokesNatively(void)
void strokeNative(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap, i32 pen)
```

True where the **backend** can stroke a path itself: AppKit through
`NSBezierPath` with `setLineWidth:`, and GDI through a geometric pen and
`PolyBezierTo`. Those two draw the curve at sub-pixel precision with their
own joins and caps. This gives a smooth silhouette. The toolkit's own
stroker offsets a polyline whose vertices are whole pixels, so it wobbles by
up to half a pixel.

GEM answers false and keeps the neutral stroker: the VDI has no wide-curve
stroke, and on hard pixels the wobble is invisible.

The path is passed as a **flat op run** instead of an object, because the
AppKit side is Objective-C and the Win32 side is GDI calls, and neither can
walk an xc class:

```
UXSTROKE_MOVE   x y
UXSTROKE_LINE   x y
UXSTROKE_CURVE  c1x c1y c2x c2y x y
UXSTROKE_CLOSE
```

Caps are none, round or square only. An arrowhead is a *shape*, and
[`UXPainter`](/compiler/api/uxkit/uxpainter/) draws it as one.

## Topics

[fillRect](#fillrect) · [fillRectRGB](#fillrectrgb) · [fillPolygon](#fillpolygon) · [fillPolygonRGB](#fillpolygonrgb) · [fillTriangle](#filltriangle) · [fillCircle](#fillcircle) · [drawLine](#drawline) · [drawText](#drawtext) · [drawTextFont](#drawtextfont) · [drawTheme](#drawtheme) · [hasThemeArt](#hasthemeart) · [strokesNatively](#strokesnatively) · [strokeNative](#strokenative) · [strokeNativeRGB](#strokenativergb)

### fillRect

```c
void fillRect(UXRect r, i32 pen)
```

A solid rectangle. Also use it to draw a **hairline**: a 1px-wide fill is
reliable on every backend, including those where [`drawLine`](#drawline) is
a stand-in. The toolkit draws its own frames and dividers as four thin
fills.

### fillRectRGB

```c
void fillRectRGB(UXRect r, i32 red, i32 green, i32 blue)
```

### fillPolygon

```c
void fillPolygon(i16* xy, i32 n, i32 pen)
```

A filled **convex** polygon. `xy` is `x,y,x,y…` in view coordinates, and `n`
is the point count.

Every vector shape is built from this primitive: a stroked curve is a run of
quads and joins, a cap is a polygon, and a radial gradient is a stack of
shrinking polygons. One call covers them all, so no shape needs a backend
entry of its own. The flat `i16` array matches VDI's `v_fillarea` signature
and maps directly to GDI's `Polygon` and to `NSBezierPath`.

The polygon must be **convex**. The fill rule for self-crossing outlines
differs between backends, and `UXPainter` only passes convex pieces, so the
difference never shows.

### fillPolygonRGB

```c
void fillPolygonRGB(i16* xy, i32 n, i32 red, i32 green, i32 blue)
```

### fillTriangle

```c
void fillTriangle(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2, i32 pen)
```

### fillCircle

```c
void fillCircle(i16 cx, i16 cy, i16 r, i32 pen)
```

A filled disc. GEM uses it for the radio button; other backends use native
art.

### drawLine

```c
void drawLine(i16 x0, i16 y0, i16 x1, i16 y1, i32 pen)
```

A stroked segment, for checkmarks and rules. For a true hairline frame,
prefer [`fillRect`](#fillrect) (see the note there).

### drawText

```c
void drawText(u8* s, i16 x, i16 y, i32 pen, i32 size)
```

Text in the UI font at `size`; `0` means the platform default.

### drawTextFont

```c
void drawTextFont(u8* s, i16 x, i16 y, i32 pen,
                  u8* family, i32 size, bool bold, bool italic)
```

A named family with traits, as a font chooser's preview needs. Windows and
macOS render the real family and traits. GEM synthesises bold and italic
(`vst_effects`) on its single loaded face and honours the size. An unknown
or empty family falls back instead of failing.

### drawTheme

```c
void drawTheme(u8* slice, UXRect r)
```

A themed 9-slice of native widget art, by name: `"button"`,
`"radio.selected"`, `"popup"`. Check [`hasThemeArt`](#hasthemeart) first if
the widget has a geometric fallback.

### strokeNative

```c
void strokeNative(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap, i32 pen)
```

Strokes a path with the backend's own stroker, when
[`strokesNatively`](#strokesnatively) reports one.

`ops` is an encoded run (one opcode plus up to six coordinates per element)
instead of a path object, because a path object cannot cross the shim
boundary. The signature **is** the ABI: nothing casts a function pointer or
a struct to get through it.

Caps are passed alongside because they belong to the
[shape](/compiler/api/uxkit/uxshapepath/#caps-belong-to-the-path), not to
the backend. An arrowhead is never passed here. No platform has one, so
[`UXPainter`](/compiler/api/uxkit/uxpainter/) draws every arrowhead itself
on every backend.

On [`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/) this is empty and
`strokesNatively` answers false: the VDI has no path stroker, so the neutral
one does all the work there.

### strokeNativeRGB

```c
void strokeNativeRGB(i32* ops, i32 n, i32 width, i32 startCap, i32 endCap,
                     i32 red, i32 green, i32 blue)
```

[`strokeNative`](#strokenative) in true colour instead of a pen index.

## Implementations

You never construct one of these. The driver hands you the right one:

| backend | realization |
| --- | --- |
| GEM | [`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/) over the VDI |
| Windows | [`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/) |
| macOS | [`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/) |
| Linux | [`UXCairoGraphics`](/compiler/api/uxkit/uxcairographics/) |
| web | [`UXCanvasGraphics`](/compiler/api/uxkit/uxcanvasgraphics/) |
| iOS / Android | [`UXIosGraphics`](/compiler/api/uxkit/uxiosgraphics/) / [`UXAndroidGraphics`](/compiler/api/uxkit/uxandroidgraphics/) |

## See also

- [`UXView`](/compiler/api/uxkit/uxview/): where `drawRect` is declared
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): shapes and strokes built on
  these primitives
- [`UXColor`](/compiler/api/uxkit/uxcolor/): what the RGB forms take
- [The driver model](/compiler/api/uxkit/guide-drivers/): who supplies the
  realization
