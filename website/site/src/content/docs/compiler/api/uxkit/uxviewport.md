---
title: UXViewport
description: "Pan and zoom as integer arithmetic: document coordinates to screen and back, with zoom-toward-the-cursor solved once instead of in every canvas."
---

`UXViewport` maps **document coordinates to screen** and back, through an
integer zoom (percent, `100` = 1:1) and a pan offset.

```c
#use <UXKit>            // or #import "UXViewport.xc"
```

## Overview

```c
UXViewport* vp = new UXViewport();
vp.setZoom(200);
vp.panTo(10, 20);

vp.docToScreenX(100);        // 210
vp.screenToDocX(210);        // 100
```

A drawing view maps its coordinates through this instead of writing
scroll-plus-scale code each time. It is arithmetic only, with no driver or
window, so the mapping can be tested without a mouse.

## The mapping

```
screen = doc × zoom / 100 + pan
doc    = (screen − pan) × 100 / zoom
```

Division is integer throughout. The round trip is exact at the zoom levels a UI
usually offers (25%, 50%, 100%, 200%, 400%) and loses at most one unit at other
levels. In exchange, the mapping is identical on every backend.

## zoomAtPoint is the one that is hard to get right

```c
vp.zoomAtPoint(400, cursorX, cursorY);
```

This changes the zoom while keeping the document point under
`(cursorX, cursorY)` at the same screen position ("zoom toward the pointer"). A
canvas that sets zoom and pan separately usually gets this slightly wrong.

```
doc under cursor before = 320
after 100% -> 400%      = 320      (pan became -960, -720)
then      400% -> 50%   = 320
```

The required pan is solved directly: read the document point, set the new zoom,
then set the pan so that point maps back to the same screen position. Repeated
zooms do not drift. The example above zooms in 4× and back out 8×, and the point
under the cursor is still 320.

Setting zoom **without** a focal point keeps the document origin in place
instead, which suits a "Fit" or "100%" menu command.

## Zoom is clamped to at least 1%

```c
vp.setZoom(0);     // becomes 1
vp.setZoom(-5);    // becomes 1
```

`screenToDoc` divides by the zoom, so a zoom of zero would divide by zero on
every mouse move. Clamping in the setter keeps the inverse mapping defined, and
no caller needs a guard.

There is no upper clamp; a zoom of 10000% is arithmetically fine. The coordinate
range of your data overflows before the viewport does.

## visibleDocRect is what a redraw culls against

```c
UXRect vis = vp.visibleDocRect(640, 480);
```

The document rectangle currently visible in a screen viewport of that size.

```
at 200%, pan(-100,-60):  x=50  y=30  w=320  h=240
at 50%,  pan(-100,-60):  x=200 y=120 w=1280 h=960
```

Zooming **in** shows less of the document; zooming **out** shows more. A draw
pass requests this once and skips every object that does not intersect it, so
the canvas stays responsive at 25% and does not redraw a thousand off-screen
shapes.

:::caution[The result is a `UXRect`, so its fields are `i16`]
`visibleDocRect` builds its rectangle with `i16` fields. At very low zoom over a
large document the visible width can exceed 32767 and wrap.

The mapping functions use `i32` throughout and are unaffected: `screenToDocX`
gives the right answer at any zoom. Only the packed-rectangle convenience has
the narrower range.
:::

## Topics

[docToScreenX](#doctoscreenx--doctoscreeny) · [docToScreenY](#doctoscreenx--doctoscreeny) · [screenToDocX](#screentodocx--screentodocy) · [screenToDocY](#screentodocx--screentodocy) · [setZoom](#setzoom) · [panTo](#panto) · [panBy](#panby) · [zoomAtPoint](#zoomatpoint) · [visibleDocRect](#visibledocrect)

### docToScreenX / docToScreenY

```c
i32 docToScreenX(i32 dx)
i32 docToScreenY(i32 dy)
```

Document to screen. The axes are independent. There is one zoom, so there is no
aspect distortion.

### screenToDocX / screenToDocY

```c
i32 screenToDocX(i32 sx)
i32 screenToDocY(i32 sy)
```

The inverse, used to convert a mouse position.

### setZoom

```c
void setZoom(i32 pct)
```

Percent; `100` is 1:1. Clamped to at least `1`. Keeps the pan, so the document
origin stays in place.

### panTo

```c
void panTo(i32 x, i32 y)
```

Places the document origin at an absolute screen offset.

### panBy

```c
void panBy(i32 dx, i32 dy)
```

Relative pan, as from a drag or a scroll wheel. In **screen** units, so a drag
of ten pixels moves the view ten pixels at any zoom.

### zoomAtPoint

```c
void zoomAtPoint(i32 pct, i32 screenX, i32 screenY)
```

Zooms while pinning the document point under a screen location. See
[above](#zoomatpoint-is-the-one-that-is-hard-to-get-right).

### visibleDocRect

```c
UXRect visibleDocRect(i32 w, i32 h)
```

The visible area, in document coordinates.

## Fields

### zoom

```c
i32 zoom     // percent; 100 = 1:1, never below 1
```

### panX / panY

```c
i32 panX; i32 panY    // screen offset of the document origin
```

Readable directly. A scrollbar's position is derived from these, and a saved
view is these three numbers.

## Example

```
default: zoom=100 pan=0,0
1:1 doc(100,50) -> screen(100,50)
200% pan(10,20): doc(100,50) -> screen(210,120)
  and back: screen(210,120) -> doc(100,50)
zoomAtPoint 100%->400% at (320,240):
  doc under cursor before=320 after=320  pan now -960,-720
  then 400%->50%: doc under cursor=320 zoom=50
setZoom(0) -> 1;  setZoom(-5) -> 1
visible doc rect at 200%: x=50 y=30 w=320 h=240
visible doc rect at 50%:  x=200 y=120 w=1280 h=960
```

The program is `website/site/examples/uxkit/canvas.xc`. The `doc-examples` gate
compiles it, and the block above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXGeom`](/compiler/api/uxkit/uxgeom/): `UXRect`, what `visibleDocRect`
  returns
- [`UXScrollView`](/compiler/api/uxkit/uxscrollview/): scrolling a view the
  toolkit manages, where this is for a canvas you draw yourself
- [`UXShapePath`](/compiler/api/uxkit/uxshapepath/): the shapes a canvas maps
  through this
