---
title: UXJpeg
description: "A baseline JPEG decoder in xc: bytes to a UXImage, the same code on every backend, matching libjpeg byte for byte."
---

`UXJpeg` turns the bytes of a JPEG file into a [`UXImage`](/compiler/api/uxkit/uximage/).
It is written in xc and has nothing behind it, so it is the same code on every
backend, and a backend with no image decoder of its own (GEM) can still load a
JPEG. Its sibling for PNG is [`UXPng`](/compiler/api/uxkit/uxpng/).

```c
#use <UXKit>            // or #import "UXJpeg.xc"
```

## Overview

```c
UXImage* paper = UXJpeg.decode(bytes, length);
if (paper == (UXImage*)0)
    {
    // not a JPEG, or one of the kinds it refuses
    }
```

The result is opaque: every pixel is `0xFFRRGGBB`.

**Supported:** baseline and extended sequential JPEG (`SOF0`, `SOF1`) at 8 bits
per sample, greyscale and three-component YCbCr (or RGB, when an Adobe marker
says the image is untransformed), any chroma subsampling (4:4:4, 4:2:2, 4:2:0
and others), interleaved and single-component scans, and restart intervals.

**Refused**, with a null return rather than a wrong picture: progressive JPEG,
lossless and arithmetic-coded files, 12-bit samples, four-component (CMYK)
images, and a file that ends partway through its data.

The output matches libjpeg's **default** decode, `djpeg -dct int`, exactly: the
same integer IDCT, the same YCbCr-to-RGB arithmetic, and the same "fancy"
chroma upsampling (libjpeg's triangle filters for 4:2:2, 4:2:0 and 4:4:0, with
its rounding). That is also what browsers show: on real 4:2:0 photographs the
output is byte-identical to headless Chrome's decode. The tests compare every
byte with libjpeg's own decode of the same files.

Decoding a 1024 × 1024 4:2:0 photograph takes about 7.6 ms on an Apple silicon
Mac. libjpeg-turbo's hand-written NEON is still about four times faster.

## Topics

**Decoding** · [decode](#decode)

### decode

```c
static UXImage* decode(u8* bytes, i32 n)
```

The image in the `n` bytes at `bytes`, or null when they are not a JPEG this
decoder supports. The bytes are only read, and the image is a new allocation.

## See also

- [`UXPng`](/compiler/api/uxkit/uxpng/): the PNG decoder
- [`UXImage`](/compiler/api/uxkit/uximage/): what both decoders return
- [`UXGraphics.drawPixels`](/compiler/api/uxkit/uxgraphics/#drawpixels): drawing one
