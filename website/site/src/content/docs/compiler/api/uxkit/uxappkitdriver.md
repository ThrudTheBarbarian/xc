---
title: UXAppKitDriver
description: "The macOS backend: real NSWindows, real NSTableViews and real panels, driven through the same neutral UXViewDriver interface every other backend implements."
---

`UXAppKitDriver` is the macOS realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/). The neutral toolkit
([`UXView`](/compiler/api/uxkit/uxview/),
[`UXWindow`](/compiler/api/uxkit/uxwindow/), the widgets) runs on it unchanged.

```c
#use <UXKit>            // or #import "UXAppKitDriver.xc"
```

## You do not call this

Like every driver, it is selected at
[boot](/compiler/api/uxkit/uxboot/) and reached through `gDriver`. Application
code names it in one place, the platform line that chooses a backend, and
nowhere else.

A program that calls `UXAppKitDriver` methods directly only runs on macOS.

## The shadow tree, and why there is one

A `UXWindow` is a real `NSWindow`, but a `UXView` is generally **not** a real
`NSView`. The driver keeps its own **shadow tree**, a flat array of nodes with
parent and sibling links, and walks it to paint and to hit-test.

Painting goes through one flipped `UXDrawView` per window, whose `drawRect:` is
the paint entry point. A window with forty views has one native view and forty
drawn ones.

[`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/) and
[`UXGtkDriver`](/compiler/api/uxkit/uxgtkdriver/) share this shape. The walk is
backend-neutral, and only the painting vocabulary differs.

:::note[Which is why a click-catcher needs to be real]
Most views are drawn and not realized, so a view does not intercept a press
merely by being on top. [`UXShieldView`](/compiler/api/uxkit/uxshieldview/) is
the toolkit's solution: a native surface above the controls that forwards
presses back to the toolkit.

A design surface, such as the Rocks canvas, needs this to select a pop-up or a
text field instead of letting the control take the click.
:::

## Native where native is visible

Some widgets are realized, as native overlays that read directly from the
neutral model:

| neutral | native |
| --- | --- |
| [`UXTableView`](/compiler/api/uxkit/uxtableview/) | `NSTableView` |
| [`UXOutlineView`](/compiler/api/uxkit/uxoutlineview/) | `NSOutlineView` |
| [`UXSlider`](/compiler/api/uxkit/uxslider/) | `NSSlider` |
| [`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/) | `NSPopUpButton` |
| [`UXStepper`](/compiler/api/uxkit/uxstepper/) | `NSStepper` |
| [`UXSegmentedControl`](/compiler/api/uxkit/uxsegmentedcontrol/) | `NSSegmentedControl` |
| [`UXProgressBar`](/compiler/api/uxkit/uxprogressbar/) | `NSProgressIndicator` |
| [`UXToolbar`](/compiler/api/uxkit/uxtoolbar/) | `NSToolbar` (window chrome, not a subview) |

The framework's rule is to **use the native UI** where the user can tell the
difference. A drawn approximation of an `NSTableView` is never as good as an
`NSTableView`, and a slider that does not feel like the platform's slider is
worse than one that does.

The overlay reads the neutral object and does not copy from it, so the model
stays the single source of truth and there is no synchronisation step.

## The shim owns every NSRect

Everything AppKit-specific goes through `libUXAppKit.m`. At that boundary,
**no `NSRect` crosses into xc**. The shim's exported signatures use only
primitives:

```c
i32  ux_ak_window_create(i32 x, i32 y, i32 w, i32 h);
void ux_ak_window_open(i32 handle);
i32  ux_ak_open_panel(u8* prompt, u8* startDir, u8* out, i32 outCap);
```

Windows are `i32` handles, not pointers. Strings are `u8*` with an explicit
capacity, and structs do not cross the boundary. Both sides can then agree on
the ABI without knowing each other's layout rules.

## What is live, and what is not

Live: events, menus, alerts, scrolling, tables and outlines, and the native
open, colour and font panels.

Not implemented:

- `windowSetSubtitle` / `Info` / `Icon` / `Modified`. `NSWindow` has `subtitle`
  and `documentEdited`, so these are **unfinished, not unavailable**.
- the toolkit's own file-panel operations (`listDir`, `fileDelete`, …). These
  are intentionally **unused**, because macOS presents `NSOpenPanel`.

When reading the driver, treat an unimplemented method as a gap and an
intentionally absent one as a decision.

## Headless, capture, and getting a GL surface

A plain run is headless: it paints offscreen and the app draws its own controls.
A headless client that needs the **real** view tree — GL above all — calls
`ux_ak_set_capture(1)` before boot. Capture mode realises the tree *without ever
showing a window*, which is what the portrait pipeline wants it for; without it
`realizeTree` builds no native view at all, so there is no surface for `makeGL`
to bind and it returns false with a message that reads like a missing GL
backend on a backend whose `glKind` says otherwise.

### The GL frame is painted into the window

The GL never draws to the window. It renders into a 4× multisampled framebuffer
the driver owns, which is the renderer's default framebuffer, so a renderer needs
no change. `presentGL` resolves that into an IOSurface-backed texture and marks
the GL view's part of the window dirty; the toolkit's next 2-D pass draws the
frame where the GL view sits, and every view after it in the tree is drawn over
it by draw order. There is no second plane, so nothing can be ordered wrongly,
tiled or left stale by the window server, and `compositesWithGL` answers false.
The IOSurface entry points are resolved at run time, so the shim's link line is
unchanged.

A view that asked for [its own surface](/compiler/api/uxkit/uxview/#setownsurface)
is drawn as a transparency layer in the same pass: it starts empty, so its
`clearRect` erases only its own ink and leaves the map under it.

Two dumps answer "what was drawn":

- `ux_ak_gl_grab(peer, path)` reads the last **presented frame** — the map and
  nothing over it.
- `ux_ak_gl_grab_window(peer, path)` draws the window's own picture — the map
  with the 2-D views over it, as the window shows them. `ux_ak_gl_grab_pixel(x, y)`
  reads one colour from that picture, for a test that has to say which thing is
  on top at a point.

If something appears in both, the renderer drew it; if only in the window grab,
a 2-D view did.

## Interactive mode

Under `[NSApp run]`, AppKit owns the thread, and the toolkit's dispatch is
driven from it (see [`UXApplication`](/compiler/api/uxkit/uxapplication/)).

Note the nuance: `driverOwnsRunLoop` returns **false** for AppKit, because the
neutral loop is still the one that runs — its `nextEvent` simply blocks in
`[NSApp run]` while the platform's loop dispatches. The consequence is that
nothing *above* the driver gets a turn, which is why an interactive app's frame
clock comes from the driver's own timer
([`setTurnHook`](/compiler/api/uxkit/uxviewdriver/#a-turn-comes-from-the-driver-or-from-the-loop)
answers true here, and false in a headless run).

That timer runs in the run loop's common modes, so the turn keeps firing while
AppKit tracks a live resize, a scroller drag or a menu. A `stop()` made from
the turn breaks `[NSApp run]` just as one made from an event does. A live
resize reaches the toolkit at every step of the drag, not only when the mouse
comes up, so the app lays out and repaints at the size the window has while it
is being dragged.

For the same reason, an `@autoreleasepool` around window ordering or activation
causes trouble: the scope ends inside AppKit's own bookkeeping.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface every
  backend implements
- [`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/): the drawing
  vocabulary this driver uses
- [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/): the sibling with the
  same shadow-tree shape
- [`UXShieldView`](/compiler/api/uxkit/uxshieldview/): the native surface for
  catching clicks
