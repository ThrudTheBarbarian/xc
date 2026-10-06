---
title: UXPng
description: "A PNG decoder and encoder in xc: bytes to a UXImage with alpha and back, the same code on every backend."
---

`UXPng` turns the bytes of a PNG file into a [`UXImage`](/compiler/api/uxkit/uximage/),
and an image into a PNG file's bytes.
It is written in xc and has nothing behind it: its own inflate, the chunk
grammar and the five scanline filters. It is the same code on every backend, and
a backend with no image decoder of its own (GEM) can still load a PNG. Its
sibling for JPEG is [`UXJpeg`](/compiler/api/uxkit/uxjpeg/).

```c
#use <UXKit>            // or #import "UXPng.xc"
```

## Overview

```c
UXImage* atlas = UXPng.decode(bytes, length);
if (atlas == (UXImage*)0)
    {
    // not a PNG, damaged, or a kind it refuses
    }
```

Pixels come out as `0xAARRGGBB` with straight (not premultiplied) alpha.

**Supported:** non-interlaced images at 8 and 16 bits per sample (and the
sub-byte grey and palette depths), colour types grey, RGB, palette, grey with
alpha and RGBA, with `tRNS` transparency. A 16-bit sample is taken to 8 bits by
its high byte, which is what browsers do (Chrome's decode of a 16-bit RGBA sheet
matches it byte for byte). ImageMagick rounds instead, `(v + 128) / 257`, so its
8-bit export of the same file differs by 1 wherever a sample is not a multiple
of 257.

**Refused**, with a null return rather than a wrong picture: Adam7 interlaced
images, a bad CRC, and a truncated or empty file.

**Encoding** writes 8-bit RGB when every pixel is opaque and 8-bit RGBA
otherwise, non-interlaced, so `decode` of the result gives back the same words.
Each row takes the filter whose output is smallest, and the rows are deflated
with LZ77 matches over a 32K window and deflate's fixed Huffman codes. A
picture of a window, with its large flat areas, compresses to well under 1% of
its pixels.

```c
UXImage* shot = window.snapshot((UXRect*)0);
UXFileIO.write((u8*)"shot.png", UXPng.encode(shot));
```

## Topics

**Decoding** · [decode](#decode)
**Encoding** · [encode](#encode)

### decode

```c
static UXImage* decode(u8* bytes, i32 n)
```

The image in the `n` bytes at `bytes`, or null when they are not a PNG this
decoder supports. The bytes are only read, and the image is a new allocation.

### encode

```c
static Data* encode(UXImage* img)
```

The image as a PNG file's bytes, or null for an empty image. The image is only
read.

## See also

- [`UXJpeg`](/compiler/api/uxkit/uxjpeg/): the JPEG decoder
- [`UXImage`](/compiler/api/uxkit/uximage/): what both decoders return
- [`UXGraphics.drawPixels`](/compiler/api/uxkit/uxgraphics/#drawpixels): drawing one
