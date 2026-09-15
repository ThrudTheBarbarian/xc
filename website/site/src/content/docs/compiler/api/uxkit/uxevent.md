---
title: UXEvent
description: "One UI event, neutral. The driver decodes the backend's native event into one of these, so the run loop and your code name no platform."
---

`UXEvent` is one UI event, in neutral terms. Each driver's `nextEvent` decodes
the backend's native event (a GEM message, a Win32 `MSG`, an `NSEvent`, a DOM
event) into one of these, so the run loop and everything above it name no
platform.

```c
#use <UXKit>            // or #import "UXEvent.xc"
```

## Overview

```c
class UXEvent {
    u8      kind;         // UXEventKind
    i16     x, y;         // where, in the window's coordinates
    u16     buttons;
    u16     key;          // (scancode << 8) | ascii
    u16     modifiers;
    i32     handle;       // which window a system event refers to
    i32     a, b;         // decoded payload, per kind
    Object* data;         // optional payload: an UXIndexSet, a String
}
```

Most programs never build one. Events arrive, the window routes them, and you
see the result as a callback firing or a delegate method running. Read this page
to learn **what a kind means** when you tap the stream or write a driver.

The fields are flat and mostly integers. An event is copied, recorded and
replayed, and a structure that owns nothing can be kept by a recorder without
keeping other objects alive. The one exception is
[`data`](#carrying-more-than-two-integers).

## The kinds

### Input

| kind | meaning |
| --- | --- |
| `UXEventNone` | nothing happened (a timed-out wait) |
| `UXEventMouseDown` | a press, at `x, y` |
| `UXEventMouseUp` | a release |
| `UXEventMouseDragged` | movement with a button held |
| `UXEventKeyDown` | a key, in [`key`](#keys-and-modifiers) |
| `UXEventWheel` | a wheel notch over a client-drawn scroll region; `a` is the notch count |

### From the window system

| kind | meaning |
| --- | --- |
| `UXEventRedraw` | repaint; `handle` says which window |
| `UXEventClose` | the close box; `handle` says which window |
| `UXEventResize` | the window was resized |
| `UXEventMove` | the window was moved |
| `UXEventMenuSelect` | a menu item was chosen; `a` is the title object, `b` the item |
| `UXEventQuit` | the application should end |

### Outcomes, not input

Three kinds can look redundant, but each has a specific purpose:

| kind | meaning |
| --- | --- |
| `UXEventScrolled` | a scroll view came to rest; `a` its node, `b` the new offset |
| `UXEventSelected` | a table's selection settled; `a` its node, `b` the anchor row, `data` an [`UXIndexSet`](/compiler/api/uxkit/uxindexset/) of every selected row |
| `UXEventTextChanged` | a native field's contents changed; `a` its node, `data` a `String` |

These announce **what happened**, not what the user did, and for certain
interactions they are the only trace.

- Dragging a scrollbar runs inside the driver's modal `trackDragStep`, which
  emits no events. A recorder would capture the initial press and nothing else,
  then replay it and leave the view scrolled to a different position.
- On a backend whose table is a native list, a click never reaches the toolkit.
  It arrives as `WM_NOTIFY`/`LVN_ITEMCHANGED`.
- Keystrokes in a native text field go straight to the `EDIT` or `NSTextField`
  and surface only as "the text is now this".

In each case the input cannot be recorded, so the toolkit records the outcome
instead. This lets [`UXEventRecorder`](/compiler/api/uxkit/uxeventrecorder/)
work across backends that handle input in completely different ways.

## Keys and modifiers

GEM hands over `key = (scancode << 8) | ascii`, and the toolkit keeps that shape
on every backend:

```c
#define UX_KEY_ASCII   $00FF      // mask for the character
#define UX_KEY_TAB     $09
#define UX_KEY_RETURN  $0D
```

```c
u16 ch = e.key & UX_KEY_ASCII;    // the character
u16 sc = e.key >> 8;              // the scancode, for keys with no character
```

Modifiers follow `evnt_multi`'s `kstate`:

```c
#define UX_MOD_SHIFT   $03        // either shift
#define UX_MOD_CTRL    $04
```

```c
if ((e.modifiers & UX_MOD_CTRL) != 0) { /* ctrl was held */ }
```

## Carrying more than two integers

```c
Object* data
```

Some events do not fit in `a` and `b`. A table's selection is a **set** of rows
(an anchor alone would replay as a single row however many were chosen), and a
field's contents are a string.

`data` is whatever that kind documents: an
[`UXIndexSet`](/compiler/api/uxkit/uxindexset/) for a selection, a `String` for
text. A recorder copies the reference, so a captured event keeps its payload.

## Tapping the stream

```c
callback gEventTap void(UXEvent* e);      // set via UXApplication.setEventTap
```

A tee on every event, used by the recorder and by tests that need a clock.

It lives on the event module, not on
[`UXApplication`](/compiler/api/uxkit/uxapplication/), and the placement
matters. On backends whose controls are native, a click becomes `BN_CLICKED` or
an `NSButton` action and is turned straight into `ctl.mouseDown` **without
passing through the application's dispatch**. A tap that only watched
`dispatchEvent` would see everything on GEM and nothing on Windows or macOS.
Drivers announce such clicks here, at their coordinates, so they can be
recorded, and replaying one goes back through the ordinary hit test to the same
control.

The tap is a **tee, not a filter**: it is called before dispatch and must not
consume the event.

## Replay

```c
bool gInputReplay;      // true while a recording is being replayed
```

While this is set, `trackDragStep` reports "not dragging" immediately.

This prevents the modal drag problem. A replayed press on a scrollbar would
re-enter the driver's modal loop, which tracks the **live** mouse, so the widget
would keep scrolling under the user's hand after the replay finished. With the
flag set, a replayed press does the press and nothing more.

## Example

Watching the stream with a tap, the only way to see every event on every
backend:

```c
class Watcher : Object {
    i32 presses;
    void init(void) { presses = 0; }

    void onEvent(UXEvent* e) {
        if (e.kind == UXEventMouseDown) {
            presses = presses + 1;
            Stdio.printf("press %d at %d,%d\n", presses, e.x, e.y);
        } else if (e.kind == UXEventSelected) {
            Stdio.printf("table %d selection settled, anchor row %d\n", e.a, e.b);
        }
    }
}

Watcher* w = new Watcher();
app.setEventTap(&w.onEvent);
```

## Topics

[init](#init)

### init

```c
void init(void)
```

Zeroes every field and sets `kind` to `UXEventNone`. Drivers reuse a single
event object across the loop instead of allocating per event, so `init` is
called before each fill. A stale `data` pointer surviving into the next event
would carry a payload from the wrong interaction.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXApplication`](/compiler/api/uxkit/uxapplication/): the run loop that
  dispatches these, and `setEventTap`
- [`UXWindow`](/compiler/api/uxkit/uxwindow/): routes a mouse event to a view
  by hit test
- [`UXEventRecorder`](/compiler/api/uxkit/uxeventrecorder/): records and
  replays the stream
- [`UXIndexSet`](/compiler/api/uxkit/uxindexset/): the payload of a selection
