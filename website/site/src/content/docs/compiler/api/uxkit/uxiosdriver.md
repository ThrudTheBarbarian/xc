---
title: UXIosDriver
description: "The iOS backend: real UIKit views. The platform owns the run loop, and the device is a phone or tablet rather than a desktop."
---

`UXIosDriver` is the iOS realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/). It is the fifth backend,
designed as a sibling of [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/).

```c
#use <UXKit>            // or #import "UXIOSDriver.xc"
```

## Real UIKit views

The framework uses the native UI on every platform: GEM's AES objects,
Win32's `HWND`s, AppKit's `NSControl`s. On iOS that means real UIKit views,
which bring Apple's own behaviour with them.

A drawn approximation of a `UIButton` would differ in many small ways: the
press animation, the hit slop, the accessibility behaviour, the appearance
under a future OS release. Realizing the native control inherits all of these,
including future changes.

## The platform owns the run loop

This is the structural difference from the desktop backends.

```
desktop   the neutral blocking loop runs; the platform pumps under it
iOS       UIKit owns the main thread; the app starts from didFinishLaunching
```

`UXApplication.run()`'s iOS branch enters the shell (`ux_ios_shell_run` is
`UIApplicationMain`), and the application starts from
`didFinishLaunching`. **Nothing here blocks.**

Input arrives as target-actions through the control-fire seam, the same
notification model as the Mac driver. The same application code works with
both models. The difference lives in the driver and in
[`driverOwnsRunLoop`](/compiler/api/uxkit/uxviewdriver/), the flag that tells
the neutral layer which model is in use.

## The first backend that is not a desktop

```c
formFactorClass()      // phone or tablet, from the idiom
```

Every earlier backend answers *desktop*. On iOS the answer is phone or tablet,
so neutral code can lay out differently on a phone without asking which
platform it runs on.

Code that asks for the *form factor* adapts; code that asks for the
*platform* has to special-case each one.

## Bring-up state

Working, and covered by the `ios-real` gate: windows, the shadow tree,
custom-view painting through `CGContext`
([`UXIosGraphics`](/compiler/api/uxkit/uxiosgraphics/)), native `UIButton` and
`UILabel` overlays via `realizeTree`, the fire-by-peer action path, and
time/settings/measurement.

Stubbed, each with a milestone:

| stubbed | the shape it will take |
| --- | --- |
| menus | `UIMenu` |
| `alertRun` | `UIAlertController` + a nested `CFRunLoop` (the sync-modal shape) |
| scrolling containers | `UIScrollView` |
| the field overlay | `UITextField` |
| tables | `UITableView` |
| ring-fed `nextEvent` | the `ios-loop` milestone |

The neutral `alertRun` protocol is synchronous: it returns which button was
pressed. UIKit's alert is asynchronous. Bridging the two needs a nested run
loop, the standard technique, so the stub is more than a one-line change.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface
- [`UXIosGraphics`](/compiler/api/uxkit/uxiosgraphics/): the `CGContext`
  drawing vocabulary
- [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/): the sibling it was
  designed against
- [`UXAndroidDriver`](/compiler/api/uxkit/uxandroiddriver/): the other
  device backend, with the same loop shape
