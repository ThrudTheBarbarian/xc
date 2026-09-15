---
title: UXGradient
description: "Colour stops sampled by position: a themed fill or a background sweep that computes identically on every backend, because the blend is integer arithmetic."
---

`UXGradient` is a sorted list of colour **stops** at positions `0`–`255`.
[`colorAt`](#colorat) samples it.

```c
#use <UXKit>            // or #import "UXGradient.xc"
```

## Overview

```c
UXGradient* g = UXGradient.twoColor(UXColor.black(), UXColor.white());
g.colorAt(0);      // black
g.colorAt(128);    // 128,128,128
g.colorAt(255);    // white
```

```c
UXGradient* sunset = new UXGradient();
sunset.addStop(0,   UXColor.rgb(255, 200, 0));
sunset.addStop(128, UXColor.rgb(220, 60,  40));
sunset.addStop(255, UXColor.rgb(0,   0,   80));
```

It has the shape of `NSGradient`, with one difference: **it computes
colours and does not draw them.** The drawing code decides where they go: a
linear sweep, a radial fill or a themed button. See
[`UXPainter.fillShapeRadial`](/compiler/api/uxkit/uxpainter/#fillshaperadial)
for the one the toolkit ships.

## Positions are 0–255, and so is the blend

The axis is a byte and the blend factor is a byte. This makes the result
**bit-identical on every backend**, because there is no float to round
differently.

The blend between two stops is
[`UXColor.blend`](/compiler/api/uxkit/uxcolor/#blend), which is linear per
channel in the same integer arithmetic.

```c
addStop(-50, …);     // stored as 0
addStop(999, …);     // stored as 255
```

Positions are clamped on the way in, so an out-of-range stop becomes an
endpoint instead of being dropped or breaking the ordering.

## Stops stay sorted, however you add them

```c
sunset.addStop(255, …);
sunset.addStop(0,   …);
sunset.addStop(128, …);
// stopAt(0).pos == 0, stopAt(1).pos == 128, stopAt(2).pos == 255
```

[`addStop`](#addstop) inserts in position order, so you can build a gradient
in whatever order the data arrives (from a file, a theme or a colour
picker) without sorting afterwards.

A new stop at a position that already has one goes **after** the existing
stop. Two stops at the same position make a hard edge: the colour jumps
instead of ramping.

## Outside the range it clamps

```c
narrow.addStop(100, red);
narrow.addStop(150, blue);

narrow.colorAt(0);      // red  — not extrapolated past the first stop
narrow.colorAt(255);    // blue — not extrapolated past the last
```

Before the first stop the first colour holds, and after the last stop the
last colour holds. A gradient that occupies only the middle of the range is
a **band** with flat colour on either side; it never extrapolates to
out-of-range colours.

You can therefore define a gradient over part of the axis and sample it over
the whole axis.

## Degenerate cases answer

```c
new UXGradient().colorAt(128);          // black, stopCount() == 0
```

An empty gradient returns black instead of trapping. A themed control with
no gradient configured draws something visible, and the missing
configuration is obvious on screen.

A gradient with **one** stop returns that colour everywhere, by the same
clamping rule.

## Topics

[addStop](#addstop) · [colorAt](#colorat) · [stopCount](#stopcount) · [stopAt](#stopat) · [twoColor](#twocolor)

### addStop

```c
void addStop(i32 pos, UXColor* c)
```

Inserts a stop, keeping the list sorted. `pos` is clamped to `0`–`255`.

The colour is **kept, not copied**. A
[`UXColor`](/compiler/api/uxkit/uxcolor/) is immutable in practice, so
sharing one between stops and gradients is safe.

### colorAt

```c
UXColor* colorAt(i32 t)
```

Samples at `t` (`0`–`255`). Returns the blend of the bracketing pair, or an
endpoint colour outside the range.

:::note[Sampling allocates]
Each call between stops builds a new `UXColor`. Sampling a 256-step ramp
makes 256 of them.

For a banded fill, sample once per band instead of once per pixel.
[`fillShapeRadial`](/compiler/api/uxkit/uxpainter/#fillshaperadial) does
this: it takes a band count and does not work per pixel.

Sampling at the position of a stop returns that stop's colour object
itself, with no allocation.
:::

### stopCount

```c
i32 stopCount(void)
```

### stopAt

```c
UXGradientStop* stopAt(i32 i)
```

The i-th stop in position order. Use it to read a gradient back, for
example to serialise it or draw the handles of a gradient editor.

### twoColor

```c
static UXGradient* twoColor(UXColor* a, UXColor* b)
```

Stops at `0` and `255`: the common case in one call.

## Example

```
two-colour stops=2
black->white: 0:(0,0,0) 64:(64,64,64) 128:(128,128,128) 192:(192,192,192) 255:(255,255,255)
sunset stops in order: 0 128 255
sunset:       0:(255,200,0) 64:(237,130,19) 128:(220,60,40) 192:(109,29,60) 255:(0,0,80)
narrow band:  0:(255,0,0) 64:(255,0,0) 128:(113,0,142) 192:(0,0,255) 255:(0,0,255)
clamped stop positions: 0 255
empty gradient: (0,0,0) stops=0
```

The sunset stops were added out of order (255, then 0, then 128) and come
back sorted. The program is `website/site/examples/uxkit/canvas.xc`. The
`doc-examples` gate compiles it, and the output above is its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXGradientStop`](/compiler/api/uxkit/uxgradientstop/): one stop
- [`UXColor`](/compiler/api/uxkit/uxcolor/): the colour, and the `blend` this
  is built on
- [`UXPainter`](/compiler/api/uxkit/uxpainter/): drawing a gradient-filled
  shape
