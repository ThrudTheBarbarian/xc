---
title: UXAndroidGraphics
description: "The Android drawing vocabulary: the same primitives over an android.graphics.Canvas, whether that Canvas is a view on screen or an offscreen Bitmap."
---

`UXAndroidGraphics` is the Android realization of
[`UXGraphics`](/compiler/api/uxkit/uxgraphics/).

```c
#use <UXKit>            // or #import "UXAndroidGraphics.xc"
```

## The Canvas of the draw in flight

The operations act on the `android.graphics.Canvas` for the current draw,
reached through JNI in `libUXAndroid.c`.

Incoming coordinates are bounds-relative, and the bound origin makes them
absolute. Android's `Canvas` grows y **down**, so nothing needs flipping. The
same is true on cairo, Canvas2D and UIKit.

## Two Canvases, one vocabulary

The drawing surface is not always a window:

| | |
| --- | --- |
| `UXDrawView.onDraw` | the real thing, on screen |
| the offscreen `Bitmap` rig | the same drawing, into a buffer that can be read back |

The vocabulary does not know which surface it has. Both are a `Canvas`, so the
same code path produces the pixels in either case.

This allows visual checking on Android **without a screen**: draw into a
`Bitmap`, read it back, and compare. If offscreen rendering used a different
path, the checks would test something other than what ships.

## Every call crosses JNI

Unlike the in-process vocabularies, each primitive here is a JNI call. Each
call has a real cost, so the primitive set is **small and coarse**: fill a
rectangle, fill a polygon, draw text, draw a line.

A protocol with a per-pixel or per-vertex entry point would be unusable across
this boundary. Designing for the narrowest backend keeps the same protocol
viable on all of them.

[`UXCanvasGraphics`](/compiler/api/uxkit/uxcanvasgraphics/) has the same
constraint, with a wasm-to-JS boundary in place of native-to-Java.

## It strokes natively

```c
strokesNatively()      // true
```

`Canvas` strokes paths with joins and caps, so a path goes to it directly and
not through the neutral offsetter. Arrowheads stay neutral, as on every
backend.

## See also

- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the protocol
- [`UXAndroidDriver`](/compiler/api/uxkit/uxandroiddriver/): the backend, and
  the UI-thread rule
- [`UXCanvasGraphics`](/compiler/api/uxkit/uxcanvasgraphics/): the other
  vocabulary across a foreign-function boundary
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): strokes and gradient fills
