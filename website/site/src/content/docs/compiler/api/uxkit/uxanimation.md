---
title: UXAnimation
description: "A from/to value over a duration, shaped by an easing curve. You ask it for its value at a time; it drives nothing, so it is exact and needs no clock."
---

`UXAnimation` interpolates between two values over a span of time, shaped by an
easing curve.

```c
#use <UXKit>            // or #import "UXAnimation.xc"
```

## Overview

```c
UXAnimation* a = UXAnimation.make(0, 100, startMs, 400, UX_EASE_IN_OUT);

a.valueAt(now);         // where the property should be at `now`
a.isFinished(now);      // whether to stop ticking
```

The run loop ticks a timer and reads `valueAt` each frame to move a property.

## It is asked, not told

The animation does not drive anything, does not hold a target, and does not read
a clock. You give it a time and it returns a value.

This makes it testable. All of the easing arithmetic can be checked by sampling
at chosen times, with no timer, no frame rate and no waiting. The
[example](#example) samples four curves at five instants, and the output is
identical on every run and every backend.

One animation can also drive several properties (call `valueAt` twice), and a
paused animation is one you stopped asking.

## The curves

All four map a progress of `0`–`255` to an eased `0`–`255`:

| | |
| --- | --- |
| `UX_EASE_LINEAR` | constant speed |
| `UX_EASE_IN` | starts slow, ends fast |
| `UX_EASE_OUT` | starts fast, ends slow |
| `UX_EASE_IN_OUT` | slow at both ends |

```
0->100 over 400ms, sampled every 100ms:
  linear:     0  24  49  74  100
  ease-in:    0   5  24  56  100
  ease-out:   0  43  74  93  100
  in-out:     0  12  49  87  100
```

Use `ease-out` by default for anything appearing or moving under the user's
hand. It arrives quickly and settles, which feels responsive. `ease-in` alone
usually feels sluggish, because the first frames barely move.

The curves are quadratic, computed in integers: `t*t/255` and its mirror. They
are not cubic Béziers like `CAMediaTimingFunction`, which would need floating
point or a lookup table. A quadratic curve is exact in `i32` and close enough
for interface motion.

## Everything clamps at the ends

```c
a.valueAt(before);      // `from` — not extrapolated backwards
a.valueAt(after);       // `to`
```

Before the start it reads `from`, and after the end it reads `to`. A frame that
arrives late, or a value read again after the animation has finished, gives the
resting value and never an overshoot.

`isFinished(now)` is true from the **instant** the duration elapses, at
`start + duration` and not after it, so a loop that stops on it does not draw
an extra frame.

A duration of zero or less is clamped to `1`, so an "instant" animation is a
single tick and not a division by zero.

## Reversing is a from greater than a to

There is no reverse flag. `make(100, 0, …)` counts down. The easing applies to
the progress and not to the direction, so `ease-in` still means *starts slow*
whichever way the value moves.

## Topics

[make](#make) · [valueAt](#valueat) · [progress](#progress) · [rawProgress](#rawprogress) · [isFinished](#isfinished) · [ease](#ease)

### make

```c
static UXAnimation* make(i32 from, i32 to, i32 startMs, i32 durationMs, i32 easing)
```

`startMs` is an absolute time on the clock you pass to `valueAt`, usually the
driver's milliseconds. Duration is clamped to at least `1`.

### valueAt

```c
i32 valueAt(i32 now)
```

The interpolated value. It is an integer, so a range of 0–100 gives 101
distinct values and a range of 0–3 gives four. Animate the **pixel** quantity,
not a small abstract one.

### progress

```c
i32 progress(i32 now)
```

The eased fraction, `0`–`255`. Use it to drive something the animation cannot
interpolate itself, such as a colour blend:
[`UXColor.blend`](/compiler/api/uxkit/uxcolor/#blend) takes the same `0`–`255`
factor.

### rawProgress

```c
i32 rawProgress(i32 now)
```

The **un-eased** fraction, `0`–`255`. Use it to drive a second thing linearly
while the first eases.

### isFinished

```c
bool isFinished(i32 now)
```

### ease

```c
static i32 ease(i32 mode, i32 t)
```

The curve alone, `0`–`255` in and out. A caller with its own progress, such as
a drag or a scroll position, can shape it without constructing an animation.

## Example

```
animation (0->100 over 400ms, sampled every 100ms):
  linear:     0 24 49 74 100
  ease-in:    0 5 24 56 100
  ease-out:   0 43 74 93 100
  in-out:     0 12 49 87 100
  before=10 after=20 finished@1399=0 finished@1400=1
  reverse at halfway: 51
```

The program is `website/site/examples/uxkit/toolbox.xc`. The `doc-examples`
gate compiles it, and the output above is its real output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXTimer`](/compiler/api/uxkit/uxtimer/): what ticks the frames
- [`UXColor`](/compiler/api/uxkit/uxcolor/): `blend`, which takes the same
  0–255 factor `progress` returns
- [`UXViewport`](/compiler/api/uxkit/uxviewport/): the other integer mapper,
  for space instead of time
