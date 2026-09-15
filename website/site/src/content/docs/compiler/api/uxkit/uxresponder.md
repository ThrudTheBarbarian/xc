---
title: UXResponder
description: "The responder chain: an event nobody consumes climbs from a view to its superview, to the window, to the application. Overriding without calling super consumes it."
---

`UXResponder` is the base of the **responder chain**, the path an unhandled
event climbs:

```
view → superview → … → contentView → window → application
```

Every [`UXView`](/compiler/api/uxkit/uxview/) is a responder, so in practice you
use this class by overriding one of its handlers.

```c
#use <UXKit>            // or #import "UXResponder.xc"
```

## Overview

Each base handler **forwards to the next responder** and does nothing else. The
chain is ordinary virtual dispatch through a linked list, with no lookup or
probe. It gives three rules:

- **Override, do not call super** → you consumed it. It stops here.
- **Override and call super** → you saw it *and* passed it on.
- **Do not override** → it goes straight past you.

```c
class Board : UXView {
    void mouseDown(UXEvent* e) {
        self.pick(e.x, e.y);      // consumed: no super call, the window never sees it
    }
}
```

### Why it is not AppKit's version

AppKit walks its chain by asking `respondsToSelector:`. xc has no reflection, no
selectors and no message forwarding, and the chain does not need them. Because
the base implementation forwards, the chain is **explicit and compiler-checked**
rather than probed at run time. A misspelled override is a method that never
runs, rather than a message that quietly goes nowhere.

### Ownership

```c
weak: UXResponder* nextResponder
```

A responder never owns the next one. The chain runs *upward* (a view points at
its superview, which points at the window) while ownership runs *downward*. The
weak link stops the two directions forming a cycle around every view in the
tree.

## Topics

[setNextResponder](#setnextresponder) · [mouseDown](#mousedown) · [mouseUp](#mouseup) · [mouseDragged](#mousedragged) · [scrollWheel](#scrollwheel) · [keyDown](#keydown) · [acceptsFirstResponder](#acceptsfirstresponder) · [becomeFirstResponder](#becomefirstresponder) · [resignFirstResponder](#resignfirstresponder)

### setNextResponder

```c
void setNextResponder(UXResponder* r)
```

Links this responder to the next one up. The view tree does this when a view is
added to a parent. Call it directly only when building a chain outside the tree.

### mouseDown

```c
void mouseDown(UXEvent* e)
```

A press, in **window** coordinates. Convert them to get coordinates relative to
the view:

```c
void mouseDown(UXEvent* e) {
    UXRect a = self.absoluteFrame();
    i16 lx = (i16)(e.x - a.x);
    i16 ly = (i16)(e.y - a.y);
}
```

A [`UXControl`](/compiler/api/uxkit/uxcontrol/) consumes its press and fires its
action rather than passing it up.

### mouseUp

```c
void mouseUp(UXEvent* e)
```

A release.

A toolkit-drawn **drag** does not arrive as events. Pressing a scrollbar or a
split divider enters the driver's modal `trackDragStep`, which follows the
pointer itself and returns only when the button comes up. Use that primitive for
a draggable widget. Waiting for `mouseDragged`/`mouseUp` pairs on those paths
waits forever.

### mouseDragged

```c
void mouseDragged(UXEvent* e)
```

Movement with a button held, on backends that report it.

### scrollWheel

```c
void scrollWheel(UXEvent* e)
```

A wheel notch, count in `e.a`. This handler is designed to climb. A table row or
a cell does not scroll, so it forwards, and the first ancestor that scrolls (the
table, or a [`UXScrollView`](/compiler/api/uxkit/uxscrollview/)) consumes it. The
wheel acts on whatever the pointer is over, not on the focused view.

### keyDown

```c
void keyDown(UXEvent* e)
```

A key, delivered to the **first responder** and climbing from there. See
[`UXEvent`](/compiler/api/uxkit/uxevent/) for decoding `e.key` and `e.modifiers`.

### acceptsFirstResponder

```c
bool acceptsFirstResponder(void)      // default false
```

Whether the view can take the keyboard. Return true to accept;
[`UXTextField`](/compiler/api/uxkit/uxtextfield/) does. The default is false, so
a plain view does not take focus when clicked.

### becomeFirstResponder

```c
bool becomeFirstResponder(void)       // default true
```

Called when the view receives the keyboard. Returning **false refuses it**.

### resignFirstResponder

```c
bool resignFirstResponder(void)       // default true
```

Called when the view is asked to give up the keyboard. Returning **false
declines**. A field holding an invalid value uses this to keep focus until the
value is fixed:

```c
bool resignFirstResponder(void) {
    return self.isValid();      // refuse to leave a bad value
}
```

## A note on `self.`

Every call to an overridable method inside the toolkit is written `self.method()`
rather than bare `method()`. The compiler devirtualises a bare self-call, so it
runs the **base** implementation. In a responder chain that means events vanish
instead of reaching your override. Write `self.` in your own responders too.

## Example

A view that handles a click itself and lets the wheel climb to whatever scrolls:

```c
class Board : UXView {
    i32 clicks;
    void init(void) { super.init(); clicks = 0; }

    // Consumed — no super call.
    void mouseDown(UXEvent* e) {
        clicks = clicks + 1;
        self.setNeedsDisplay();
    }

    // Seen, then passed up.
    void scrollWheel(UXEvent* e) {
        Stdio.printf("wheel over the board: %d\n", e.a);
        super.scrollWheel(e);
    }
}
```

## Conforms to

- The base class of [`UXView`](/compiler/api/uxkit/uxview/), and so of every
  view and control in the toolkit

## See also

- [`UXEvent`](/compiler/api/uxkit/uxevent/): what the handlers receive
- [`UXWindow`](/compiler/api/uxkit/uxwindow/): hit-tests a press to find where
  the chain starts, and owns the first responder
- [`UXControl`](/compiler/api/uxkit/uxcontrol/): consumes its press and fires
  an action
