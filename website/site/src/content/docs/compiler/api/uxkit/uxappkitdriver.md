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

Two dumps answer "where did the drawing go", and they are a pair on purpose:

- `ux_ak_gl_grab(peer, path)` reads back the GL **surface** — the map and
  nothing over it.
- `ux_ak_gl_grab_window(peer, path)` reads back the view the tree hangs in — the
  2-D views and their text. A panel appears in the window grab and not the
  surface grab; that asymmetry is the answer, not a bug in either dump.

Which grab a panel's own drawing lands in follows from one rule, and it is the
one thing a GL app has to know:

- a 2-D **paint** goes into the parent's `drawRect`, and a view's own paint is
  drawn *before* its subviews, so a paint is **under** the surface;
- a native **view** — a control, or a scroll view's document view — is a real
  subview, and the surface is added at the bottom of the stack, so a view is
  **over** the surface.

A panel over the map is therefore a *mix*, not one kind of thing. A drawn sheet
needs a native subview of its own — `UXScrollView`'s document is the one the
toolkit makes for you, and it draws the peer's subtree into it — while the
buttons and fields standing on that sheet are ordinary native controls and need
nothing special. `ux_ak_gl_place` puts the surface below every sibling for
exactly that reason, and neither grab on its own shows the whole window.

Any view can ask for that native subview directly with
[`UXView.setOwnSurface`](/compiler/api/uxkit/uxview/#setownsurface): its kind
becomes `UXKindSurface`, and AppKit realises a real subview at the view's frame
whose `drawRect` draws the view's subtree — so the view's own paint and its
children land *over* the surface, which is the general form of the scroll
document. A backend that cannot make one declines and draws the view inline, so
one tree is correct everywhere and only the stacking over a GL surface differs.

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
