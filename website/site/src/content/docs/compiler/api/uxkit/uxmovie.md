---
title: UXMovie
description: "Frames in, a WebM movie out: a VP8 encoder and a WebM writer in xc, the same on every backend."
---

`UXMovie` makes a movie file from frames you give it. It encodes them as VP8
and writes a WebM file, the kind a browser's `MediaRecorder` makes. The encoder
is written in xc, so the output is the same on every backend, byte for byte,
and it needs no codec from the platform.

```c
#use <UXKit>            // or #import "UXMovie.xc"
```

## Overview

```c
UXMovie* m = UXMovie.make(1280, 832, 25);   // 25 ticks a second
m.add(frame);                               // one frame, one tick
m.addHeld(frame, 5);                        // one frame, shown for five ticks
Data* webm = m.finish();

u8* path = UXSavePanel.run((u8*)"Save the movie", (u8*)".", (u8*)"turns.webm");
if (path != (u8*)0)
    {
    UXFileIO.write(path, webm);
    free((pointer)path);
    }
```

A movie has one size and one tick rate. Each frame is shown for a whole number
of ticks. If you add the same picture again, it is not encoded again: the
frame before is shown for longer. So adding a frame on every tick costs little
while nothing on screen changes.

The movies play in every current browser and in VLC. QuickTime Player does not
play WebM.

## What it writes

Every frame is a VP8 key frame. Each frame is coded on its own, so the movie
seeks to any frame, and edges and text in a UI stay sharp. The file is larger
than an encoder that codes the changes between frames would make. A
1280x832 frame takes about 35 ms to encode.

The colour is BT.601 at limited range, with chroma at half resolution (4:2:0),
which is what VP8 players expect. A detail of one coloured pixel loses some of
its colour; edges between flat areas keep theirs.

The file has the parts players use to seek: the track's size, the duration,
clusters of up to five seconds, and an index of the clusters. The last frame
carries its own duration, so it stays on screen for as long as it was held.

## Topics

**Making** · [make](#make) · [setQuantizer](#setquantizer)
**Adding frames** · [add](#add) · [addHeld](#addheld) · [addPixels](#addpixels)
**Finishing** · [finish](#finish)
**Inspecting** · [frameCount](#framecount) · [durationMs](#durationms) · [reconstruction](#reconstruction)

### make

```c
static UXMovie* make(i32 width, i32 height, i32 framesPerSecond)
```

A movie of `width` x `height` pixels (1 to 16383 each) that runs at
`framesPerSecond` ticks a second.

### setQuantizer

```c
void setQuantizer(i32 q)
```

VP8's quantizer index, from 0 (finest, largest file) to 127 (coarsest). The
default is 10, where a UI's text and edges stay sharp. It applies to the frames
added after it.

### add

```c
bool add(UXImage* img)
```

Adds `img` as one frame, shown for one tick. Answers false if the image is not
the movie's size, or if the movie is finished.

### addHeld

```c
bool addHeld(UXImage* img, i32 held)
```

Adds `img` as one frame, shown for `held` ticks. Answers false as `add` does,
and also when `held` is less than 1.

### addPixels

```c
bool addPixels(u8* rgba, i32 width, i32 height, i32 held)
```

Adds a frame from RGBA bytes, four to a pixel, top row first, shown for `held`
ticks. The size must be the movie's.

### finish

```c
Data* finish(void)
```

The whole movie as a WebM file. The movie takes no frames after this.

### frameCount

```c
i32 frameCount(void)
```

The number of distinct frames added so far. A frame added again unchanged does
not count again.

### durationMs

```c
i32 durationMs(void)
```

The movie's length so far, in milliseconds.

### reconstruction

```c
Data* reconstruction(void)
```

The last frame added, as a VP8 decoder will show it: I420, cropped to the
movie's size (the Y plane, then U and V at half size, rounded up). The encoder
predicts each block from this, as the decoder does. The tests use it to check
a real decoder's output byte for byte.

## See also

- [`UXImage`](/compiler/api/uxkit/uximage/): the frames
- [`UXSavePanel`](/compiler/api/uxkit/uxsavepanel/) and
  [`UXFileIO`](/compiler/api/uxkit/uxfileio/): saving the file
