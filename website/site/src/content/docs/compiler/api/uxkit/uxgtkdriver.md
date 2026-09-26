---
title: UXGtkDriver
description: "The Linux desktop backend: GTK4 widgets over the shared shadow tree, painting through cairo, with the neutral loop pumping GTK's main context."
---

`UXGtkDriver` is the GTK4 realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the Linux desktop
backend.

```c
#use <UXKit>            // or #import "UXGtkDriver.xc"
```

## Built to a pattern, not from scratch

It is a sibling of [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/)
and uses the same arrangement as the iOS driver:

- the **shared shadow tree**, which the driver walks to paint and hit-test
- custom views painting through `drawRect` →
  [`UXCairoGraphics`](/compiler/api/uxkit/uxcairographics/) → the `cairo_t` of
  the current draw
- `realizeTree` overlaying **real** GTK widgets whose signals land in the
  toolkit's `fire` / `value` / `field` seams

| neutral | GTK4 |
| --- | --- |
| [`UXButton`](/compiler/api/uxkit/uxbutton/) | `GtkButton` |
| [`UXCheckbox`](/compiler/api/uxkit/uxcheckbox/) | `GtkCheckButton` |
| [`UXTextField`](/compiler/api/uxkit/uxtextfield/) | `GtkEntry` |
| [`UXSlider`](/compiler/api/uxkit/uxslider/) | `GtkScale` |
| [`UXStepper`](/compiler/api/uxkit/uxstepper/) | `GtkSpinButton` |
| [`UXProgressBar`](/compiler/api/uxkit/uxprogressbar/) | `GtkProgressBar` |
| [`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/) | `GtkDropDown` |

This fifth backend follows the existing pattern without adding to it. The
interface already reflects three very different systems: GEM's AES objects,
Win32's HWNDs and AppKit's NSViews.

## The neutral loop owns the run loop

```c
driverOwnsRunLoop()    // false
```

GTK's main context **pumps under** the neutral blocking loop; GTK does not
call the toolkit back.

This is the desktop arrangement, and the opposite of
[`UXIOSDriver`](/compiler/api/uxkit/uxiosdriver/) and
[`UXAndroidDriver`](/compiler/api/uxkit/uxandroiddriver/), where the
platform owns the loop and the application is a set of callbacks.
`driverOwnsRunLoop` is the one flag that tells the neutral layer which
arrangement applies.

## Pointer input had to be added

By default GTK4 does not deliver raw button and motion events to a drawing
area; it expects gesture controllers. The driver therefore attaches a
`GtkEventControllerLegacy` and exposes `ux_gtk_drag_next`.

:::caution[The motion flag is consumed *after* the wait, not before]
Clearing the moved flag **before** waiting drops any motion that arrives
while the caller is still redrawing. The drag then stutters when the repaint
is slow.

The same problem affects any loop of this shape: a consume-then-wait loop
loses whatever happens between the consume and the wait.
:::

## The shim keeps structs out of xc

As on every other hosted backend, the exported signatures use primitives
only:

```c
i32  ux_gtk_boot(i32* w, i32* h);
void ux_gtk_pump(void);
void ux_gtk_wait_event(void);
i32  ux_gtk_alert(i32 parent, u8* lines, u8* buttons, i32 defBtn);
```

No `GdkRectangle` or `cairo_t*` crosses into portable code. For the same
reason, the clip stack is `ux_gtk_clip` / `ux_gtk_clip_end` instead of a
context object.

## Testing

The gates are `run_gtk_real.sh`, `run_gtk_loop.sh`, `run_gtk_mouse.sh`,
`run_gtk_alert.sh` and `run_gtk_settings.sh`. They run on Linux and cannot
run on macOS, so verify a change here on Linux.

The GTK gates print a heartbeat, because a headless GTK run that has
stopped looks the same as one that is waiting.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface
- [`UXCairoGraphics`](/compiler/api/uxkit/uxcairographics/): the drawing
  vocabulary
- [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/): the sibling this
  follows
- [`UXIOSDriver`](/compiler/api/uxkit/uxiosdriver/): where the platform owns
  the loop instead
