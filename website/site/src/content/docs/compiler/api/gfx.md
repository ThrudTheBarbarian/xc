---
title: Gfx
description: "The 2D drawing surface: pen state, pixels, shapes, lines and curves in a mode-independent API, with each display mode supplying its own pixel primitives."
---

`Gfx` is the shared 2D drawing API. It holds the pen state and a current point,
and builds the higher-level primitives (rectangles, circles, arcs, ovals,
lines, Bézier curves and flood fill) on top of four per-pixel operations:
[`plot`](#plot), [`getPixel`](#getpixel), [`hline`](#hline) and
[`vline`](#vline).

`Gfx` itself is abstract: those four primitives are empty stubs. A concrete
**display-mode subclass** ([`Gfx6`, `Gfx7`, `Gfx8`, `Gfx15`](/compiler/api/gfxfactory/))
overrides them for its own resolution and bit-packing, so every shape method
here works unchanged on every mode. You do not construct a `Gfx` directly. Ask
the factory for the mode you want and draw through the base API.

```c
#import "Gfx.xc"             // the drawing class (re-exports GfxFactory.xc)

Gfx* g = gfxCreate(GFX_320_192_1, 0);   // a 320x192 1bpp surface
g.setPen(1);
g.line(0, 0, 319, 191);
```

## Overview

The coordinate model is a top-left origin: `x` increases to the right, `y`
downward, both signed `i16`. Higher-level routines may step briefly out of
bounds during clipping or line stepping. The per-mode primitives clamp, so an
off-screen `plot` or a partly off-screen `hline` is trimmed rather than
faulting.

Drawing state is two values. [`setPen`](#setpen) sets the value written by
stroke operations: on a 1bpp mode pen `0` clears the pixel and non-zero sets
it, and on a 2bpp mode the low two bits are the colour index.
[`setFillColor`](#setfillcolor) sets the value used by [`clear`](#clear) and as
the fill target of [`floodFill`](#floodfill). A `Point` is the value type for
positions:

```c
struct Point { i16 x; i16 y; }
```

The current point (moved by [`moveTo`](#moveto) and advanced by
[`lineTo`](#lineto) / [`bezierTo`](#bezierto)) lets the line and curve methods
draw relative to where the pen last was.

The arc-family methods ([`arc`](#arc), [`fillArc`](#fillarc), [`pie`](#pie),
[`fillPie`](#fillpie)) take a `quadrants` bit-mask selecting which quarters of
the circle to draw: `$01` top-right, `$02` top-left, `$04` bottom-left, `$08`
bottom-right. OR the bits to combine quadrants; `$0F` is a full circle.

:::note[Availability]
`Gfx` exists on the display-capable targets (**xt6502**, **arm64**, **arm9**
and **m68k**) and is absent on **x86_64**, **win64** and **wasm32**, which have
no display surface. On xt6502 the primitives are hand-written 6502 assembly for
the per-pixel hot loops. On the other targets they are portable subscript /
shift / mask code. The bit layouts match byte-for-byte across targets, so the
same drawing produces the same framebuffer everywhere.
:::

## Conforms to

Every `Gfx*` is also an [`Object*`](/compiler/api/object/) and fits anywhere one
is expected.

## Topics

**State** · [init](#init) · [setPen](#setpen) · [setFillColor](#setfillcolor) · [moveTo](#moveto) · [currentPoint](#currentpoint) · [currentX / currentY](#currentx--currenty) · [clear](#clear)

**Pixels** · [plot](#plot) · [getPixel](#getpixel) · [hline](#hline) · [vline](#vline)

**Shapes** · [rect](#rect) · [fillRect](#fillrect) · [circle](#circle) · [fillCircle](#fillcircle) · [arc](#arc) · [fillArc](#fillarc) · [pie](#pie) · [fillPie](#fillpie) · [oval](#oval) · [fillOval](#filloval)

**Lines & curves** · [line](#line) · [lineTo](#lineto) · [bezier](#bezier) · [bezierTo](#bezierto) · [floodFill](#floodfill)

---

## State

Pen, fill colour and the current point.

### init
```c
void init(void)
```
Zeroes the drawing state (null framebuffer, current point `0,0`, pen `1`, fill
colour `0`). The mode subclasses override `init` to also set up the framebuffer
and record the mode's dimensions, so you obtain a ready-to-draw surface from
[`gfxCreate`](/compiler/api/gfxfactory/#gfxcreate) rather than calling `init`
yourself.

### setPen
```c
void setPen(u8 c)
```
Sets the value stroke operations write. On a 1bpp mode `0` clears a pixel and
non-zero sets it; on a 2bpp mode the low two bits are the colour index (0–3).

### setFillColor
```c
void setFillColor(u8 c)
```
Sets the value used by [`clear`](#clear) (a non-zero fill colour clears the whole
surface to set pixels) and the colour [`floodFill`](#floodfill) paints with.

### moveTo
```c
void moveTo(i16 x, i16 y)
void moveTo(Point p)
```
Moves the current point without drawing. [`lineTo`](#lineto) and
[`bezierTo`](#bezierto) draw from here and then advance it.

### currentPoint
```c
Point currentPoint(void)
```
The current pen position as a `Point`.

### currentX / currentY
```c
i16 currentX(void)
i16 currentY(void)
```
The x / y of the current point individually.

### clear
```c
void clear(void)
```
Fills the whole framebuffer with all-zero bytes when the fill colour is `0`, and
with all-ones bytes (`$FF`) otherwise. It writes the mode's full byte count, so
it costs the same regardless of what was drawn.

[↑ Topics](#topics)

## Pixels

The four per-mode primitives. In `Gfx` they are empty stubs; the display-mode
subclass supplies the real bit-packing. Call these directly for point work, or
let the shape methods call them for you.

### plot
```c
void plot(i16 x, i16 y)
```
Sets the pixel at `(x, y)` using the current [pen](#setpen). Out-of-range
coordinates are ignored.

### drawChar
```c
void drawChar(i16 x, i16 y, u8 ch)     // xt6502 only
```
Draws character `ch` at pixel `(x, y)` in the current pen colour.

### drawText
```c
void drawText(i16 x, i16 y, string s)  // xt6502 only
```
Draws the string `s` starting at `(x, y)`, advancing one glyph width per
character (calls [`drawChar`](#drawchar) per byte).

### getPixel
```c
u8 getPixel(i16 x, i16 y)
```
Reads the pixel value at `(x, y)`: `0`/`1` on a 1bpp mode, `0`–`3` on a 2bpp
mode. Off-screen reads return `0`.

### hline
```c
void hline(i16 x0, i16 x1, i16 y)
```
Draws a horizontal run between `x0` and `x1` (inclusive, either order) at row
`y`, clipped to the surface. This is the scanline primitive the fills are built
on.

### vline
```c
void vline(i16 x, i16 y0, i16 y1)
```
Draws a vertical run between `y0` and `y1` (inclusive, either order) at column
`x`, clipped to the surface.

[↑ Topics](#topics)

## Shapes

Outlines stroke with the current [pen](#setpen); the `fill…` variants fill with
the pen as well (they scan the interior with [`hline`](#hline)). All coordinates
are `i16` and clipping happens in the primitives.

### rect
```c
void rect(i16 x0, i16 y0, i16 x1, i16 y1)
```
The outline of the rectangle with corners `(x0,y0)` and `(x1,y1)`, drawn as two
[`hline`](#hline)s and two [`vline`](#vline)s.

### fillRect
```c
void fillRect(i16 x0, i16 y0, i16 x1, i16 y1)
```
The solid rectangle, filled row by row with [`hline`](#hline).

### circle
```c
void circle(i16 cx, i16 cy, i16 r)
```
A circle outline of radius `r` centred at `(cx, cy)`, drawn with an 8-octant
Bresenham (`plot`) walk. A negative `r` is treated as its absolute value; `r`
of 0 plots the centre.

### fillCircle
```c
void fillCircle(i16 cx, i16 cy, i16 r)
```
A solid disk of radius `r`, filled with [`hline`](#hline) scanlines.

### arc
```c
void arc(i16 cx, i16 cy, i16 r, u8 quadrants)
```
The outline of the selected quarters of a circle. `quadrants` is the
bit-mask (`$01` top-right, `$02` top-left, `$04` bottom-left, `$08`
bottom-right); a zero mask draws nothing.

### fillArc
```c
void fillArc(i16 cx, i16 cy, i16 r, u8 quadrants)
```
The filled wedge(s) for the selected `quadrants`, scanned with
[`hline`](#hline) from the centre outward.

### pie
```c
void pie(i16 cx, i16 cy, i16 r, u8 quadrants)
```
The outline of a pie slice: like [`arc`](#arc), but the figure is closed with
radial edges along the axes where the selected quadrants begin or end.

### fillPie
```c
void fillPie(i16 cx, i16 cy, i16 r, u8 quadrants)
```
The filled pie slice for the selected `quadrants` (the same interior as
[`fillArc`](#fillarc)).

### oval
```c
void oval(i16 cx, i16 cy, i16 rx, i16 ry)
```
An ellipse outline with horizontal radius `rx` and vertical radius `ry`, traced
parametrically from a 256-entry sine table (with midpoints filled so the curve
stays connected). Degenerate radii collapse to a [`vline`](#vline),
[`hline`](#hline) or single [`plot`](#plot).

### fillOval
```c
void fillOval(i16 cx, i16 cy, i16 rx, i16 ry)
```
A solid ellipse, filled with [`hline`](#hline) scanlines whose half-width comes
from an integer square root per row.

[↑ Topics](#topics)

## Lines & curves

### line
```c
void line(i16 x0, i16 y0, i16 x1, i16 y1)
```
A straight line between the two endpoints, drawn with Bresenham. Axis-aligned
lines route to [`hline`](#hline) / [`vline`](#vline). Does **not** move the
current point.

### lineTo
```c
void lineTo(i16 x, i16 y)
void lineTo(Point p)
```
Draws a line from the current point to `(x, y)` and makes that the new current
point. This is the pen-relative form of [`line`](#line).

### bezier
```c
void bezier(i16 x0, i16 y0, i16 x1, i16 y1, i16 x2, i16 y2)
```
A quadratic Bézier curve through control points `(x0,y0)`, `(x1,y1)`, `(x2,y2)`,
approximated as 32 straight segments (fixed-step forward differencing). Leaves
the current point at the end `(x2, y2)`.

### bezierTo
```c
void bezierTo(i16 x1, i16 y1, i16 x2, i16 y2)
void bezierTo(Point p1, Point p2)
```
A quadratic Bézier starting from the current point, with control point `p1` and
end point `p2`. Advances the current point to the end.

### floodFill
```c
bool floodFill(i16 sx, i16 sy)
```
Flood-fills the connected region of same-coloured pixels around the seed
`(sx, sy)` with the current [fill colour](#setfillcolor), using a scanline fill
and a lazily heap-allocated seed queue. Returns `true` on success and `false` if
the seed queue overflowed (the region was too complex to complete). If it
returns `false`, fill again from a seed in the unfilled area. An off-screen seed, or a seed already the
fill colour, is a no-op that returns `true`.

[↑ Topics](#topics)

## Worked example

Obtain a surface from the factory and draw through the shared API. The same
code runs on every display-capable target:

```c
#import "Gfx.xc"

i32 main(void)
{
    Gfx* g = gfxCreate(GFX_320_192_1, 0);   // 320x192, 1bpp
    if (g == (Gfx*)0) { return 1; }

    g.setFillColor((u8)0);
    g.clear();                              // blank the surface

    g.setPen((u8)1);
    g.rect(10, 10, 309, 181);               // border
    g.circle(160, 96, 60);                  // centred circle
    g.moveTo(0, 96);
    g.lineTo(319, 96);                       // horizontal diameter

    g.setFillColor((u8)1);
    g.floodFill(2, 2);                       // fill outside the border

    return 0;
}
```

To pick a different resolution or colour depth, change only the mode constant
passed to [`gfxCreate`](/compiler/api/gfxfactory/#gfxcreate); every call above
is unchanged. See [`GfxFactory`](/compiler/api/gfxfactory/) for the modes.
