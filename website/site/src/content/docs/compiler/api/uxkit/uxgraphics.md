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

## Alpha

Every RGB primitive has an RGBA sibling, with `alpha` as a straight `0..255`
(`255` is the opaque form):

```c
g.fillRectRGBA(r, 48, 80, 160, 128);   // half over what is behind it
g.fillPolygonRGBA(xy, n, 48, 80, 160, 64);
g.drawTextRGBA((u8*)"12", 6, 4, 48, 80, 160, 200, 12);
g.strokeNativeRGBA(ops, n, width, startCap, endCap, join, dashes, ndash, 0, 48, 80, 160, 128);
                                                 // ^ dash run, count, phase (see dashesNatively)
```

The alpha is **straight**, not premultiplied: `128` over white gives mid
grey, not a darkened colour. Where a translucent shape overlaps another, the
blend is source-over, the same on every backend that blurs at all.

### Emptying a rect

A layer that composites over something has to start empty each frame, and no
RGBA fill does that: `fillRectRGBA(r, 0, 0, 0, 0)` is a source-over fill, so
alpha 0 paints **nothing** and leaves whatever was there:

```c
g.clearRect(g.bounds());   // the rect carries nothing afterwards
```

`clearRect` clears to transparent where the surface has an alpha, and to the
window background where it does not (GEM and GDI — the same two that answer
[`blendsAlpha`](#blendsalpha) false). It is the one call whose meaning is
"nothing here", and it is deliberately not alpha 0 of the family above.

## Capability flags, not assumptions

Three methods ask the backend what it can do. A well-written widget draws
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

### blendsAlpha

```c
bool blendsAlpha(void)
```

True where a translucent fill or stroke actually **composites** over what is
behind it. GDI's solid brushes have no alpha, so Windows answers **false**. GEM
answers **false** too: its blitter composites a translucent rectangle and a
bitmap, but a translucent polygon, stroke or text run is drawn opaque. The other
backends blend.

This matters when a layer is built from overlapping translucent pieces — a
coastline at 0.92 drawn as three concentric slabs reads as a coastline only
if they blend. Ask first, and pick a different construction when the answer
is false rather than let the shape silently flatten to solid:

```c
if (g.blendsAlpha()) { /* layered translucent slabs */ }
else                 { /* one opaque outline */ }
```

### strokesNatively

```c
bool strokesNatively(void)
void strokeNative(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                  i32* dash, i32 ndash, i32 phase, i32 pen)
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
[`UXPainter`](/compiler/api/uxkit/uxpainter/) draws it as one. Joins are
miter, round or bevel (`UXJOIN_*` from
[`UXShapePath`](/compiler/api/uxkit/uxshapepath/#joins)), passed the same way
as a cap because they belong to the path, not the backend.

The last three arguments are the **dash** ([`dashesNatively`](#dashesnatively)).

`width` is in **device pixels and may be a fraction** — a border stroked at
`1.536` is a border stroked at 1.536, not at 2. Every backend that strokes
through a real stroker (AppKit, cairo, Skia, CoreGraphics, Canvas2D) draws the
fraction exactly. GDI's pen width and the VDI's line width are whole numbers,
so those two round to the nearest pixel: a coarse hairline beats a wrong
precise one. The **dash run and phase stay whole pixels** — a paint's dashes
are its solid rhythm, and no caller has wanted a fraction of one.

### dashesNatively

```c
bool dashesNatively(void)
```

True where the backend's stroker also lays down a **dash**: an on/off run in
whole **device pixels** plus a phase. The run and the phase are whole pixels
even where the stroke [width](#strokenative) is a fraction. AppKit
(`setLineDash:count:phase:`), cairo (`cairo_set_dash`), Skia
(`DashPathEffect`), CoreGraphics (`CGContextSetLineDash`) and Canvas2D
(`setLineDash` with `lineDashOffset`) all do.

GEM answers false — it has no path stroker to dash with. Windows answers
false as well: `ExtCreatePen` accepts `PS_DASH` only on a **cosmetic** pen,
which is one pixel wide, has no joins and takes no phase. A correctly coarse
dash beats a wrong precise one, so the neutral dasher takes it.

Where the answer is false,
[`UXPainter`](/compiler/api/uxkit/uxpainter/) walks the flattened centreline
and emits the ON pieces as segments of its own — never a silently solid
line.

The run and the phase travel with the **call**, not as context state:
`ndash == 0` means solid, the phase may be negative, and a two-element
pattern is the common case (up to `UX_DASH_MAX`, 8). The run itself lives on
the [path](/compiler/api/uxkit/uxshapepath/#dashes).

All five dashers share one rule, and it was measured on each of them rather
than assumed from one: **the phase restarts at every subpath**. Two subpaths
of 85 px in one call with the run `[8,8]` put 85 % 16 = 5 px between the
restart rule and a phase that continued, so the two answers cannot be
confused; `make mac-dash`, `make gtk-real`, `make android-real` and
`make ios-real` each draw that pair and compare it pixel for pixel. A run
**shorter than the stroke's width** — `[2,2]` at width 6 — still dashes on
all five.

## Topics

[fillRect](#fillrect) · [fillRectRGB](#fillrectrgb) · [fillRectRGBA](#fillrectrgba) · [clearRect](#clearrect) · [drawPixels](#drawpixels) · [fillPolygon](#fillpolygon) · [fillPolygonRGB](#fillpolygonrgb) · [fillPolygonRGBA](#fillpolygonrgba) · [fillTriangle](#filltriangle) · [fillCircle](#fillcircle) · [drawLine](#drawline) · [drawText](#drawtext) · [drawTextRGBA](#drawtextrgba) · [drawTextFont](#drawtextfont) · [drawTextFontRGBA](#drawtextfontrgba) · [drawTheme](#drawtheme) · [hasThemeArt](#hasthemeart) · [blendsAlpha](#blendsalpha) · [strokesNatively](#strokesnatively) · [dashesNatively](#dashesnatively) · [strokeNative](#strokenative) · [strokeNativeRGB](#strokenativergb) · [strokeNativeRGBA](#strokenativergba)

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

### fillRectRGBA

```c
void fillRectRGBA(UXRect r, i32 red, i32 green, i32 blue, i32 alpha)
```

[`fillRectRGB`](#fillrectrgb) with an alpha. See [Alpha](#alpha) and
[`blendsAlpha`](#blendsalpha).

### clearRect

```c
void clearRect(UXRect r)
```

Make the rect carry nothing. See [Emptying a rect](#emptying-a-rect).

### drawPixels

```c
void drawPixels(u8* data, i32 w, i32 h, i32 format, UXRect src, UXRect dst, i32 alpha)
```

A region of a bitmap drawn into the view, scaled smoothly, with an overall
`alpha` (255 = as stored): the canvas's `drawImage(img, sx, sy, sw, sh, dx, dy,
dw, dh)`. `data` is `w`×`h` pixels, row-major, top row first; `format` is
`UXPIX_RGBA` (bytes R,G,B,A — a decoded PNG) or `UXPIX_ARGB32` (`0xAARRGGBB`
words — a [`UXImage`](/compiler/api/uxkit/uximage/), see its `drawIn`). Both are
straight (not premultiplied) alpha and sRGB. `src` is in the bitmap's pixels and
`dst` in view coordinates.

The bitmap is not copied. A backend may keep what it builds from `data` keyed by
its address — a 28 MB texture atlas is wrapped once, not on every call — so the
bytes must not change after they are first drawn; draw changed pixels from a new
buffer. Every backend draws it. On GEM the region goes through the blitter's
scaled source-over transfer (`vr_transfer_bits`, `VR_OVER`).

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

### fillPolygonRGBA

```c
void fillPolygonRGBA(i16* xy, i32 n, i32 red, i32 green, i32 blue, i32 alpha)
```

[`fillPolygonRGB`](#fillpolygonrgb) with an alpha. The polygon must still be
convex.

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

### drawTextRGBA

```c
void drawTextRGBA(u8* s, i16 x, i16 y, i32 red, i32 green, i32 blue, i32 alpha, i32 size)
```

[`drawText`](#drawtext) in true colour with an alpha.

### drawTextFont

```c
void drawTextFont(u8* s, i16 x, i16 y, i32 pen,
                  u8* family, i32 size, bool bold, bool italic)
```

A named family with traits, as a font chooser's preview needs. Windows and
macOS render the real family and traits. GEM synthesises bold and italic
(`vst_effects`) on its single loaded face and honours the size. An unknown
or empty family falls back instead of failing.

### drawTextFontRGBA

```c
void drawTextFontRGBA(u8* s, i16 x, i16 y, u8* family, i32 size, i32 weight, bool italic,
                      i32 red, i32 green, i32 blue, i32 alpha)
```

A family **and** a colour **and** an alpha at once, with the weight on the
CSS scale rather than a bool — a map's labels are `600`, and semibold is
neither bold nor not:

```c
g.drawTextFontRGBA((u8*)"N", x, y, (u8*)"ui-monospace", 10,
                   UXWEIGHT_SEMIBOLD, false, 70, 80, 90, 200);
```

`weight` is one of `UXWEIGHT_THIN` (100), `UXWEIGHT_LIGHT` (300),
`UXWEIGHT_NORMAL` (400), `UXWEIGHT_MEDIUM` (500), `UXWEIGHT_SEMIBOLD`
(600), `UXWEIGHT_BOLD` (700) or `UXWEIGHT_BLACK` (900). A family with no
such weight resolves to the nearest it has; the number is passed through, so
an intermediate value is honoured rather than snapped to a named step. GEM has
one loaded face, so the weight picks its bold or regular cut; the other
backends ask the platform for the real weight.

### drawTheme

```c
void drawTheme(u8* slice, UXRect r)
```

A themed 9-slice of native widget art, by name: `"button"`,
`"radio.selected"`, `"popup"`. Check [`hasThemeArt`](#hasthemeart) first if
the widget has a geometric fallback.

### strokeNative

```c
void strokeNative(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                  i32* dash, i32 ndash, i32 phase, i32 pen)
```

Strokes a path with the backend's own stroker, when
[`strokesNatively`](#strokesnatively) reports one.

`ops` is an encoded run (one opcode plus up to six coordinates per element)
instead of a path object, because a path object cannot cross the shim
boundary. The signature **is** the ABI: nothing casts a function pointer or
a struct to get through it.

Caps are passed alongside because they belong to the
[shape](/compiler/api/uxkit/uxshapepath/#caps-belong-to-the-path), not to
the backend. The line **join** is passed the same way (`UXJOIN_MITER`,
`UXJOIN_ROUND`, `UXJOIN_BEVEL`). `dash`/`ndash`/`phase` are the dash run,
its length and the phase, and `ndash == 0` means solid — see
[`dashesNatively`](#dashesnatively). An arrowhead is never passed here. No
platform has one, so
[`UXPainter`](/compiler/api/uxkit/uxpainter/) draws every arrowhead itself
on every backend.

On [`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/) this is empty and
`strokesNatively` answers false: the VDI has no path stroker, so the neutral
one does all the work there.

### strokeNativeRGB

```c
void strokeNativeRGB(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                     i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue)
```

[`strokeNative`](#strokenative) in true colour instead of a pen index.

### strokeNativeRGBA

```c
void strokeNativeRGBA(i32* ops, i32 n, double width, i32 startCap, i32 endCap, i32 join,
                      i32* dash, i32 ndash, i32 phase, i32 red, i32 green, i32 blue, i32 alpha)
```

[`strokeNativeRGB`](#strokenativergb) with an alpha. The map's ink is
strokes, so this is the call that carries a translucent border.

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
