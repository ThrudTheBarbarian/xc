---
title: UXColor
description: "An RGBA colour with integer channels: construction, HSB, blending, and the luminance test for choosing readable text. No floats anywhere."
---

`UXColor` is an RGBA colour with four channels, `0..255`, using **integers
throughout**. Like the rest of the toolkit's arithmetic, this makes every
backend produce identical pixels.

```c
#use <UXKit>            // or #import "UXColor.xc"
```

## Overview

```c
UXColor* brand = UXColor.fromHex($3050A0);     // rgb(48,80,160)
UXColor* red   = UXColor.red();
UXColor* ghost = brand.withAlpha(96);
```

Every operation **returns a new colour**; none mutates the receiver. A colour
you pass to a view cannot be changed underneath it by another holder, and you
can derive colours without defensive copies:

```c
UXColor* ghost = brand.withAlpha(96);
// brand is still rgb(48,80,160) a=255
```

Channels are clamped on construction, so arithmetic that overshoots saturates
instead of wrapping: `lightened` on an almost-white colour gives white, not
black.

## Topics

[rgb](#rgb) · [rgba](#rgba) · [fromHex](#fromhex) · [fromHexA](#fromhexa) · [toHex](#tohex) · [hsb](#hsb) · [toHSB](#tohsb) · [blend](#blend) · [lightened](#lightened) · [darkened](#darkened) · [withAlpha](#withalpha) · [luminance](#luminance) · [isDark](#isdark) · [isEqualTo](#isequalto) · [named colours](#named-colours)

### rgb

```c
static UXColor* rgb(i32 r, i32 g, i32 b)
```

Opaque colour from three channels. Values outside `0..255` are clamped.

### rgba

```c
static UXColor* rgba(i32 r, i32 g, i32 b, i32 a)
```

With alpha. `a` is `255` for opaque, `0` for invisible.

### fromHex

```c
static UXColor* fromHex(u32 hex)        // 0xRRGGBB, opaque
```

```c
UXColor* brand = UXColor.fromHex($3050A0);
```

### fromHexA

```c
static UXColor* fromHexA(u32 hex)       // 0xAARRGGBB
```

Alpha is in the **high** byte, the order a packed colour word usually arrives
in.

### toHex

```c
u32 toHex(void)                          // 0xRRGGBB
```

Drops alpha. To keep alpha across a round trip, hold the colour rather than its
hex.

### hsb

```c
static UXColor* hsb(i32 h, i32 s, i32 v)     // h 0..359, s/v 0..255
```

Hue wraps instead of clamping, so `hsb(370, …)` is `hsb(10, …)` and negative
hues work. This suits rotating a hue by arithmetic.

### toHSB

```c
void toHSB(i32* h, i32* s, i32* v)
```

Uses out-parameters, because three values come back:

```c
i32 h = 0; i32 s = 0; i32 v = 0;
brand.toHSB(&h, &s, &v);        // h=223 s=178 v=160
```

The round trip is exact for the values it can represent:
`UXColor.hsb(223, 178, 160)` gives back `rgb(48,80,160)`.

### blend

```c
UXColor* blend(UXColor* other, i32 t)    // t 0..255
```

Linear interpolation, including alpha. `t = 0` is the receiver unchanged,
`t = 255` is `other`, `128` is halfway.

### lightened

```c
UXColor* lightened(i32 amt)
```

A blend toward white (a tint). `lightened(64)` on `rgb(48,80,160)` gives
`rgb(99,123,183)`.

### darkened

```c
UXColor* darkened(i32 amt)
```

A blend toward black (a shade).

Use these to build a widget's pressed and disabled states from one colour
instead of storing three: `base`, `base.darkened(40)`, `base.lightened(90)`.

### withAlpha

```c
UXColor* withAlpha(i32 alpha)
```

The same colour at a different opacity, as a copy. See
[Overview](#overview).

### luminance

```c
i32 luminance(void)                      // 0..255
```

Perceptual brightness with Rec. 601 weights (`77r + 150g + 29b`). Green counts
for roughly twice red and five times blue, matching human vision. A plain
average would rate pure blue and pure green equally bright, which they are not.

### isDark

```c
bool isDark(void)                        // luminance < 128
```

Luminance exists for **choosing readable text over a background**:

```c
UXColor* ink = background.isDark() ? UXColor.white() : UXColor.black();
```

Unlike a palette of hand-picked pairs, this line keeps working when the
background comes from a theme, a file, or a user.

### isEqualTo

```c
bool isEqualTo(UXColor* o)
```

Channel-wise equality, including alpha; null is false.

:::note[Not `equals`]
Dispatch in xc is by name only, so `Object.equals`, which compares pointer
identity, would shadow a custom `equals`. The toolkit uses `isEqualTo` wherever
it needs value comparison. Two separately built `UXColor.red()` objects are
`isEqualTo` and are **not** `equals`.
:::

### Named colours

```c
UXColor.black()   UXColor.white()   UXColor.gray()
UXColor.red()     UXColor.green()   UXColor.blue()
```

Constructed fresh on each call, so they are never shared and are safe to derive
from.

For colours with a *meaning* rather than a value, such as "window background"
or "selected text", use [`UXColorList`](/compiler/api/uxkit/uxcolorlist/), a
named palette that a theme can replace as a whole.

## Example

```c
#import <Stdio.xc>
#import "UXColor.xc"

void main(void) {
    UXColor* brand = UXColor.fromHex($3050A0);          // rgb(48,80,160)

    brand.lightened(64);                                // rgb(99,123,183)
    brand.darkened(64);                                 // rgb(35,59,119)
    brand.blend(UXColor.red(), 128);                    // rgb(151,39,79)

    UXColor* ghost = brand.withAlpha(96);               // a=96
    // brand is unchanged: a=255

    i32 h = 0; i32 s = 0; i32 v = 0;
    brand.toHSB(&h, &s, &v);                            // 223, 178, 160
    UXColor.hsb(h, s, v);                               // back to rgb(48,80,160)

    // Readable text over any background.
    UXColor* ink = brand.isDark() ? UXColor.white() : UXColor.black();
    Stdio.printf("brand luminance %d -> %s text\n", brand.luminance(),
                 brand.isDark() ? (u8*)"white" : (u8*)"black");   // 79 -> white
}
```

The full program is `website/site/examples/uxkit/colour.xc`. The
`doc-examples` gate compiles it, and the values above are what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXColorList`](/compiler/api/uxkit/uxcolorlist/): named, themeable colours
- [`UXColorPanel`](/compiler/api/uxkit/uxcolorpanel/): letting a user pick one
- [`UXGradient`](/compiler/api/uxkit/uxgradient/): interpolating between
  several
- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): where a colour becomes
  pixels
