---
title: UXFrameHud
description: "An on-screen frame-time readout: frames per second, and the fastest, average and slowest frame of the last whole second."
---

`UXFrameHud` is a small panel that shows how fast the app's turn is running:
the frames in the last whole second, and the fastest, average and slowest
frame in that same second. It is a view like any other, so it travels to every
backend. That matters because the developer's machine is fast and the target
device may not be.

```c
#use <UXKit>
```

## Overview

```c
UXFrameHud* hud = new UXFrameHud();
hud.setEnabled(true);
canvas.addSubview(hud, UXGeom.make(8, 8, hud.preferredWidth(), hud.preferredHeight()));
app.everyTurn(&tick, 0);   // and in tick(): hud.tick();
```

Call `tick()` once per turn from the app's turn function. Each call is one
frame boundary. Every whole second the panel publishes that second, and all
four numbers come from the same frames:

| shown | meaning |
| --- | --- |
| `fps` | the frames in the second |
| `min` | the fastest frame in it, in milliseconds |
| `avg` | the second's length divided by its frames, so `1000 / fps` |
| `max` | the slowest frame in it |

So it always reads `min ≤ avg ≤ max`, and `avg` agrees with `fps`. The latest
single frame is not shown, because the turn that repaints the panel tends to
be a long one, which makes the reading misleading. Code that wants it can call
`framePrev`.

The panel asks for its own surface, so where the backend has GL it draws over
the GL view rather than under it.

## Topics

**Showing** · [setEnabled / isEnabled / toggle](#setenabled--isenabled--toggle) · [preferredWidth / preferredHeight](#preferredwidth--preferredheight)
**Sampling** · [tick](#tick) · [reset](#reset)
**Reading** · [frameFps / frameMin / frameAvg / frameMax](#framefps--framemin--frameavg--framemax) · [framePrev](#frameprev)

### setEnabled / isEnabled / toggle

```c
void setEnabled(bool e)
bool isEnabled(void)
void toggle(void)
```

Shows the panel and starts sampling, or hides it. Turning it on restarts the
clock, so the first second after that is a fresh one.

### preferredWidth / preferredHeight

```c
i32 preferredWidth(void)
i32 preferredHeight(void)
```

The size the readout needs. The width is measured on the backend's own font
for the widest text the panel can show (a three-digit frame rate, frame times
up to 999.99 ms), so the app does not have to guess. The panel fills whatever
frame it is given.

### tick

```c
void tick(void)
```

One frame boundary. The first call only starts the clock; each later one is a
frame.

### reset

```c
void reset(void)
```

Drops the numbers and starts a fresh second.

### frameFps / frameMin / frameAvg / frameMax

```c
i32 frameFps(void)
i32 frameMin(void)
i32 frameAvg(void)
i32 frameMax(void)
```

The last whole second: its frame count, and its fastest, average and slowest
frame in microseconds. They are `0` until a second has passed.

### framePrev

```c
i32 framePrev(void)
```

The latest single frame, in microseconds.

## See also

- [`UXApplication`](/compiler/api/uxkit/uxapplication/): `everyTurn`, the
  app's turn function
- [`UXView`](/compiler/api/uxkit/uxview/): `setOwnSurface`
