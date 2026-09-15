---
title: GfxFactory
description: "The factory that returns a Gfx drawing surface for a chosen display mode, plus the per-mode subclasses Gfx6, Gfx7, Gfx8 and Gfx15."
---

`GfxFactory` is the entry point for obtaining a [`Gfx`](/compiler/api/gfx/)
drawing surface. You pick a display mode by constant, and
[`gfxCreate`](#gfxcreate) returns an instance of the matching mode subclass
([`Gfx6`](#gfx6), [`Gfx7`](#gfx7), [`Gfx8`](#gfx8) or [`Gfx15`](#gfx15)) typed
as a base `Gfx*`, so you draw through the shared API.

```c
#import "GfxFactory.xc"      // the factory + every mode subclass

Gfx* g = gfxCreate(GFX_320_192_1, 0);   // 320x192, 1bpp
g.setPen(1);
g.line(0, 0, 319, 191);
```

## Overview

Importing the factory pulls in every subclass it can construct, so
`#import "GfxFactory.xc"` gives you all the modes. Importing a single subclass
header (`Gfx8.xc`, say) pulls in only that mode's code plus the shared
[`Gfx`](/compiler/api/gfx/) base. All the mode headers re-export the same
definitions, so `#import "Gfx.xc"` also reaches the factory.

Every subclass shares the whole [`Gfx`](/compiler/api/gfx/) API: pen state,
shapes, lines, curves and flood fill are inherited unchanged. A mode differs in
two things: its pixel **primitives** (`plot` / `getPixel` / `hline` / `vline`,
overridden for the mode's resolution and bit-packing) and its **mode setup**
(framebuffer size and dimensions set at construction). Once you have a `Gfx*`
you rarely need to know which subclass it is. To switch resolution or colour
depth, change the constant you pass to [`gfxCreate`](#gfxcreate).

The four modes are:

| Mode constant   | Subclass         | Resolution | Colours          | Framebuffer |
|-----------------|------------------|------------|------------------|-------------|
| `GFX_160_96_1`  | [`Gfx6`](#gfx6)  | 160 × 96   | 2 (1 bit/pixel)  | 1920 bytes  |
| `GFX_160_96_2`  | [`Gfx7`](#gfx7)  | 160 × 96   | 4 (2 bits/pixel) | 3840 bytes  |
| `GFX_320_192_1` | [`Gfx8`](#gfx8)  | 320 × 192  | 2 (1 bit/pixel)  | 7680 bytes  |
| `GFX_160_192_2` | [`Gfx15`](#gfx15)| 160 × 192  | 4 (2 bits/pixel) | 7680 bytes  |

Each constant also has a numeric spelling (`GFX_GR6`, `GFX_GR7`, `GFX_GR8`,
`GFX_GR15`, with values 6, 7, 8 and 15) that matches the traditional display-mode
numbering. The `GFX_<w>_<h>_<bpp>` aliases are the descriptive names.

:::note[Availability]
`GfxFactory` and its subclasses exist on the display-capable targets
(**xt6502**, **arm64**, **arm9** and **m68k**) and are absent on **x86_64**,
**win64** and **wasm32**, which have no display surface. On xt6502 the
primitives are hand-written 6502 assembly and the surface is real display
memory. On the other targets the primitives are portable code drawing into an
off-screen heap buffer. The bit layouts match byte-for-byte across targets.
:::

## Conforms to

Every `Gfx*` the factory returns is also an [`Object*`](/compiler/api/object/)
and fits anywhere one is expected.

## Topics

**Factory** · [gfxCreate](#gfxcreate)

**Display modes** · [Gfx6](#gfx6) · [Gfx7](#gfx7) · [Gfx8](#gfx8) · [Gfx15](#gfx15)

---

## Factory

### gfxCreate
```c
Gfx* gfxCreate(u8 mode, u8 textRows)
```
Constructs a drawing surface for `mode` (one of the mode constants above) and
returns it as a [`Gfx*`](/compiler/api/gfx/), or null (`(Gfx*)0`) if the build
has no subclass for that mode. The caller owns the returned pointer: ARC retains
it on assignment, and `delete` / release frees it.

On the **xt6502** target, `textRows` requests a split display with that many
text rows below the graphics region. Pass `0` for a full-screen graphics
display; modes that don't support a split ignore it. The other targets have no
physical display and no text region, so `textRows` is accepted for source
compatibility and ignored, and the mode always allocates a full off-screen
buffer.

When `mode` is a compile-time constant, calling through `inline:gfxCreate(...)`
lets the optimiser drop the dead mode branches, which noticeably shrinks a small
"factory + draw" program. Use a bare `gfxCreate(...)` call for a mode chosen at
runtime.

[↑ Topics](#topics)

## Display modes

Each subclass extends [`Gfx`](/compiler/api/gfx/) and overrides only its
construction and the four pixel primitives ([`plot`](/compiler/api/gfx/#plot),
[`getPixel`](/compiler/api/gfx/#getpixel), [`hline`](/compiler/api/gfx/#hline),
[`vline`](/compiler/api/gfx/#vline)). You get an instance from
[`gfxCreate`](#gfxcreate) rather than constructing one directly, then use it
through the shared [`Gfx`](/compiler/api/gfx/) API. None of these classes adds
public drawing methods of its own.

### Gfx6
160 × 96, 1 bit per pixel (2 colours), a 1920-byte framebuffer. Pixels are
packed 8 to a byte across 20 bytes per row (byte = `y*20 + x/8`, bit
`7 - (x & 7)`). The [pen](/compiler/api/gfx/#setpen) is a single bit: `0` clears
the pixel, non-zero sets it.

### Gfx7
160 × 96, 2 bits per pixel (4 colours), a 3840-byte framebuffer. Pixels are
packed 4 to a byte across 40 bytes per row (byte = `y*40 + x/4`). The low two
bits of the [pen](/compiler/api/gfx/#setpen) select the colour index 0–3.

### Gfx8
320 × 192, 1 bit per pixel (2 colours), a 7680-byte framebuffer. This is the
highest-resolution monochrome mode. Pixels are packed 8 to a byte across 40
bytes per row (byte = `y*40 + x/8`, bit `7 - (x & 7)`), with pen semantics as in
[`Gfx6`](#gfx6).

### Gfx15
160 × 192, 2 bits per pixel (4 colours), a 7680-byte framebuffer. This is the
full-height 4-colour mode. It is packed like [`Gfx7`](#gfx7) (4 pixels per byte,
40 bytes per row, byte = `y*40 + x/4`) but is twice as tall.

[↑ Topics](#topics)

## Worked example

Pick a mode, draw through the [`Gfx`](/compiler/api/gfx/) API, and switch mode
by changing one constant:

```c
#import "GfxFactory.xc"

i32 main(void)
{
    // 4-colour 160x192 surface; try GFX_320_192_1 for hi-res mono.
    Gfx* g = gfxCreate(GFX_160_192_2, 0);
    if (g == (Gfx*)0) { return 1; }

    g.setFillColor((u8)0);
    g.clear();

    g.setPen((u8)3);                 // colour index 3
    g.fillCircle(80, 96, 40);
    g.setPen((u8)1);
    g.rect(0, 0, 159, 191);

    return 0;
}
```

See [`Gfx`](/compiler/api/gfx/) for the full set of drawing methods every mode
shares.
