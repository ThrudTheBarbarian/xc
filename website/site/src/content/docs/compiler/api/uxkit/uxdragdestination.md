---
title: UXDragDestination
description: "Anything that can receive a drop: say what you would do with it, then do it. Two methods, and a negotiation the session arbitrates."
---

`UXDragDestination` is what a view adopts to **receive a drop**. It has two
methods: one asks what you would do, the other does it.

```c
#use <UXKit>            // or #import "UXDragSession.xc"
```

## Overview

```c
protocol UXDragDestination {
    i32  dragEntered(UXDragSession* s);      // the op you WOULD perform
    bool dragPerform(UXDragSession* s);      // consume it; true = accepted
}
```

`dragEntered` is called repeatedly as the pointer moves, and decides the
feedback under the cursor. You answer with an operation, and the session tells
you whether the source permits it. `dragPerform` runs once, on release.

```c
class Well : UXView <UXDragDestination> {
    i32 dragEntered(UXDragSession* s) {
        return s.hasType((u8*)"text") ? UX_DRAG_COPY : UX_DRAG_NONE;
    }
    bool dragPerform(UXDragSession* s) {
        u8* t = s.stringForType((u8*)"text");
        if (t == (u8*)0) { return false; }
        self.setLabel(t);
        return true;
    }
}
```

## The negotiation

Both ends have a say, and the session arbitrates:

```c
i32 enter(UXDragDestination* target) {
    i32 want = target.dragEntered(self);
    operation = want & allowedOps;      // masked to what the SOURCE permits
    return operation;
}
```

The destination says what it **wants**. The source declared what it **allows**
when it began the session. The result is the intersection. A view that would
move something still only copies it if the source offered copy alone, and
neither end has to know the other's policy.

```c
#define UX_DRAG_NONE 0
#define UX_DRAG_COPY 1
#define UX_DRAG_MOVE 2
#define UX_DRAG_LINK 4
```

Returning `UX_DRAG_NONE` from `dragEntered` means "not for me". A view declines
a drag it cannot use this way, and the cursor stops offering a drop over it.

The drawing code calls `canDrop()` on the session to decide whether to
highlight. `deliver()` does not call `dragPerform` when the negotiated operation
is empty, so a destination is never asked to consume something it declined.

## Asking what is being dragged

The session forwards to the [pasteboard](/compiler/api/uxkit/uxpasteboard/) it
carries:

```c
s.hasType((u8*)"text")              // is this kind of thing on offer?
s.stringForType((u8*)"text")        // …and what is it
```

Check the **type** in `dragEntered`, not the contents. That method is called on
every pointer move, so it should be cheap. Extract the payload in `dragPerform`,
which runs once.

## Where the drag loop lives

A toolkit-drawn drag is **modal**: the source enters the driver's
`trackDragStep`, which follows the pointer itself and returns when the button is
released. No `mouseDragged` events are emitted, so a destination never sees the
drag as events. It sees `dragEntered` calls made by the source as the pointer
crosses it.

For that reason a drag source is written as a loop, not as an event handler:

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

## Topics

[dragEntered](#dragentered) · [dragPerform](#dragperform)

### dragEntered

```c
i32 dragEntered(UXDragSession* s)
```

The operation you would perform: one of the `UX_DRAG_*` values, or
`UX_DRAG_NONE` to decline. Called repeatedly, so keep it cheap.

### dragPerform

```c
bool dragPerform(UXDragSession* s)
```

Consume the drop. Return `true` if you accepted it. Returning `false` tells the
source nothing happened. This distinguishes "dropped on something that
declined" from "dropped successfully", which matters for a move that would
otherwise delete the original.

## See also

- [`UXDragSession`](/compiler/api/uxkit/uxdragsession/): the negotiation, the
  hot spot, and the pasteboard passthroughs
- [`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/): what is being carried
- [`UXEvent`](/compiler/api/uxkit/uxevent/): events, and why a modal drag emits
  none
- [The driver model](/compiler/api/uxkit/guide-drivers/): `trackDragStep`
