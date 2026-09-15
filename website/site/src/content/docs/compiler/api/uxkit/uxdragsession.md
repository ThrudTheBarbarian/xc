---
title: UXDragSession
description: "One drag in flight: what is being carried, what the source allows, and the negotiated operation the destination agreed to."
---

`UXDragSession` is one drag in flight. It carries the payload, remembers what
the source permits, and arbitrates the operation with whatever the pointer is
over.

```c
#use <UXKit>            // or #import "UXDragSession.xc"
```

## Overview

```c
UXPasteboard* pb = new UXPasteboard();
pb.writeText(self.label());
UXDragSession* s = UXDragSession.begin((Object*)self, pb, UX_DRAG_COPY);
```

A session takes three things: **who** started it, **what** is being carried, and
**which operations are allowed**.

```c
#define UX_DRAG_NONE 0
#define UX_DRAG_COPY 1
#define UX_DRAG_MOVE 2
#define UX_DRAG_LINK 4
```

`allowedOps` is a bitmask, so a source that accepts either passes
`UX_DRAG_COPY | UX_DRAG_MOVE`.

### A drag carries its own pasteboard

A drag does not use the clipboard. Dragging something never destroys what the
user copied earlier.

## The negotiation

```c
i32 enter(UXDragDestination* target) {
    i32 want = target.dragEntered(self);
    operation = want & allowedOps;      // masked to what the SOURCE permits
    return operation;
}
```

The destination says what it **wants**, the source declared what it **allows**,
and the result is the intersection. Neither end needs to know the other's
policy: a view that would move something still only copies if the source
offered copy alone.

```c
bool canDrop(void)                      // the negotiated op is non-empty
bool deliver(UXDragDestination* target) // refuses when it is not
```

`deliver` does not call `dragPerform` when the negotiated operation is
`UX_DRAG_NONE`, so a destination is never asked to consume something it
declined.

## Driving a drag

A toolkit-drawn drag is **modal**. The driver's `trackDragStep` follows the
pointer and returns when the button is released, emitting no events, so the
source runs the loop:

```c
void mouseDown(UXEvent* e) {
    UXPasteboard* pb = new UXPasteboard();
    pb.writeText(self.label());
    UXDragSession* s = UXDragSession.begin((Object*)self, pb, UX_DRAG_COPY);

    i32 x = (i32)e.x; i32 y = (i32)e.y;
    while (gDriver.trackDragStep(&x, &y) != 0) {
        well.hot = self.over(well, x, y) && (s.enter(well) != UX_DRAG_NONE);
        self.setNeedsDisplay();
        if (gApp != (UXApplication*)0) { gApp.displayIfNeeded(); }
    }
    if (self.over(well, x, y) && s.canDrop()) { s.deliver(well); }
}
```

In this loop:

- `enter` is called **per step**, which keeps the highlight under the cursor
  accurate. For this reason
  [`dragEntered`](/compiler/api/uxkit/uxdragdestination/) must be cheap.
- The `displayIfNeeded` inside the loop makes the feedback appear, since no
  event arrives to trigger a redraw.
- The drop is delivered **after** the loop, guarded by `canDrop`.

## Topics

[begin](#begin) · [enter](#enter) · [canDrop](#candrop) · [deliver](#deliver) · [hasType](#hastype--stringfortype) · [stringForType](#hastype--stringfortype) · [setHotSpot](#sethotspot)

### begin

```c
static UXDragSession* begin(Object* source, UXPasteboard* pb, i32 allowedOps)
```

### enter

```c
i32 enter(UXDragDestination* target)
```

Asks a candidate what it would do, masks the answer to the allowed set,
remembers the result and returns it. Call it each step while the pointer is over
a candidate.

### canDrop

```c
bool canDrop(void)
```

Whether the last [`enter`](#enter) negotiated a non-empty operation. The drawing
code uses it to decide whether to highlight.

### deliver

```c
bool deliver(UXDragDestination* target)
```

Performs the drop. Returns whether the destination **accepted** it. This
distinguishes "dropped on something that declined" from "dropped successfully",
which matters for a `UX_DRAG_MOVE` that would otherwise delete the original.

### hasType / stringForType

```c
bool hasType(u8* type)
u8*  stringForType(u8* type)
```

Passthroughs to the carried [pasteboard](/compiler/api/uxkit/uxpasteboard/), so
a destination does not have to reach through the session to get at it. Null-safe
if there is no pasteboard.

### setHotSpot

```c
void setHotSpot(i16 x, i16 y)
```

Where the pointer sits **within** the dragged image. A drag that began 12 pixels
into a tile keeps that offset instead of snapping the corner to the cursor. A
move in an editor needs the same correction. Without it the dragged item jumps
on mouse-down, and the drag feels broken.

## Fields

```c
Object*       source;        // who started it
UXPasteboard* pasteboard;    // what is being carried
i32           allowedOps;    // the bitmask the source permits
i32           operation;     // the last negotiated op, masked
i16 hotX; i16 hotY;
```

## See also

- [`UXDragDestination`](/compiler/api/uxkit/uxdragdestination/): the two
  methods a receiver implements
- [`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/): typed payloads, and why
  a copy offers several
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): `trackDragStep`, and why
  a modal drag emits no events
