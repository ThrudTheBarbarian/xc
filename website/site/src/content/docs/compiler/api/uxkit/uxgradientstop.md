---
title: UXGradientStop
description: "One colour at one position along a gradient: the pair a ramp is built from."
---

`UXGradientStop` is a colour pinned to a position on a
[`UXGradient`](/compiler/api/uxkit/uxgradient/)'s axis.

```c
#use <UXKit>            // or #import "UXGradient.xc"
```

## Overview

```c
class UXGradientStop : Object {
    i32      pos;      // 0..255 along the gradient
    UXColor* color;
}
```

[`addStop`](/compiler/api/uxkit/uxgradient/#addstop) makes stops and keeps
them in position order. You read them back through
[`stopAt`](/compiler/api/uxkit/uxgradient/#stopat), for example to serialise
a theme or draw the handles of a gradient editor.

## Position is a byte, not a fraction

```c
i32 pos      // 0..255
```

The range is `0`–`255` rather than `0.0`–`1.0` because the whole gradient
uses integer arithmetic. The same stops sample to the same colours on every
backend, with no float to round differently.

256 positions is finer than the eye resolves in a ramp, and finer than most
displays can show without banding. If you need more steps than the axis
has, add stops. The resolution that matters is the number of distinct
colours, not the number of positions between them.

`addStop` clamps out-of-range positions to the ends instead of rejecting
them, so a stop at `-50` becomes a stop at `0`.

## Two stops at one position make a hard edge

A new stop is inserted **after** any existing stop at the same position.
Two stops sharing a position have zero span between them, so
[`colorAt`](/compiler/api/uxkit/uxgradient/#colorat) jumps instead of
ramping:

```c
g.addStop(128, red);
g.addStop(128, blue);      // colour switches at 128, with no blend
```

Use this for a stepped ramp or a two-tone fill. It follows from the
ordering rule, so no flag is needed.

## The colour is shared, not copied

```c
UXColor* color
```

The stop keeps the pointer you passed to `addStop`. The toolkit treats a
[`UXColor`](/compiler/api/uxkit/uxcolor/) as immutable, and every operation
returns a new one, so sharing a colour between stops, gradients and
controls is normal and safe.

Changing a `UXColor`'s fields in place would change every stop that holds
it. `lightened`, `darkened` and `blend` all return new colours, so you never
need to.

`init` leaves `color` **null**, but a stop in a gradient always has a
colour, because `addStop` is the only way to add one.

## Fields

### pos

```c
i32 pos      // 0..255
```

### color

```c
UXColor* color
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXGradient`](/compiler/api/uxkit/uxgradient/): the ramp these define
- [`UXColor`](/compiler/api/uxkit/uxcolor/): the colour, and `blend`
- [`UXColorList`](/compiler/api/uxkit/uxcolorlist/): named colours, when
  position is not what you want
