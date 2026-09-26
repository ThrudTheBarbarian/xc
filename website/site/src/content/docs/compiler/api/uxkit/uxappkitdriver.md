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

## Interactive mode

Under `[NSApp run]`, AppKit owns the run loop, and the toolkit's dispatch is
driven from it (see [`UXApplication`](/compiler/api/uxkit/uxapplication/)).

This is the usual arrangement for a hosted toolkit. For the same reason, an
`@autoreleasepool` around window ordering or activation causes trouble: the
scope ends inside AppKit's own bookkeeping.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface every
  backend implements
- [`UXCocoaGraphics`](/compiler/api/uxkit/uxcocoagraphics/): the drawing
  vocabulary this driver uses
- [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/): the sibling with the
  same shadow-tree shape
- [`UXShieldView`](/compiler/api/uxkit/uxshieldview/): the native surface for
  catching clicks
