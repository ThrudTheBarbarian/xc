---
title: UXAndroidDriver
description: "The Android backend: real android.widget views over JNI, with the one Java class the platform requires carried as a committed bootstrap dex, and an explicit hop to the UI thread."
---

`UXAndroidDriver` is the Android realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/). It is the seventh backend,
and the device-realm sibling of
[`UXIosDriver`](/compiler/api/uxkit/uxiosdriver/).

```c
#use <UXKit>            // or #import "UXAndroidDriver.xc"
```

## Real widgets, over JNI

The toolkit's rule is to **use the native UI**. On Android that means real
`android.widget` views, built through JNI in `libUXAndroid.c`.

| neutral | Android |
| --- | --- |
| [`UXButton`](/compiler/api/uxkit/uxbutton/) | `Button` |
| [`UXLabel`](/compiler/api/uxkit/uxlabel/) | `TextView` |
| [`UXSlider`](/compiler/api/uxkit/uxslider/) | `SeekBar` |
| [`UXWindow`](/compiler/api/uxkit/uxwindow/) | `FrameLayout` |
| [`UXStepper`](/compiler/api/uxkit/uxstepper/) | a composed `-`/`+` button pair |

**Android has no platform stepper**, so the driver composes one from two
buttons. A backend that cannot realize a control natively builds the closest
real equivalent. This is better than drawing a fake, because the pieces are
real widgets with native behaviour.

## The one Java class the platform forces

Android does not let native code register a listener directly: a
`View.OnClickListener` has to be a Java object. There is therefore **one** Java
class, the listener bridge, carried as a **committed bootstrap dex** in
`tools/android/`.

The built artefact is committed so that applications do not need a Java
toolchain in their build to produce one small class that never changes. The dex
is tested and checked in, so building an Android application needs only the
NDK.

A press travels `OnClickListener` → `UXBridge` → `nativeFire` → the toolkit's
fire-by-peer path, the same entry point every other backend's controls use.

## The thread hop is explicit

The loop has the same shape as on iOS, with the thread hop visible:

```
the framework's UI thread   owns the loop
the compiler's glue         runs xt_main on a DETACHED thread
runLoop()                   posts the app's start onto the UI thread, then parks
```

`boot()`, windows, `realizeTree`, painting and firing all happen **on the UI
thread**, inside the posted entry or a widget callback. This is Android's rule,
and breaking it causes a crash, not a warning.

Because the driver makes the hop, neutral code never has to know about it. An
application's `main` runs where the compiler put it, and the driver moves the
work to where Android requires it.

## Two libraries, one APK

The APK carries two native libraries, and `addneeded.py` patches the
`DT_NEEDED` entry so the loader finds the second one.

:::caution[Assembling `.s` through the NDK does not work]
The compiler emits Mach-O-dialect assembly, which the NDK's assembler does not
accept. The build uses the compiler's own path instead.

Do not try to shortcut the toolchain here. It looks as if it should work, and
the failure reads like a missing flag.
:::

## Bring-up state

Working, covered by the `android-real` gate: windows as `FrameLayout`s, the
shadow tree, custom-view painting through `Canvas`
([`UXAndroidGraphics`](/compiler/api/uxkit/uxandroidgraphics/)), native `Button`
and `TextView` overlays, the fire-by-peer path, time and measurement, and the
offscreen `Bitmap` readback rig that allows visual checks without a screen.

Stubbed: the value controls (`Switch`/`SeekBar`/`ProgressBar`/`Spinner`), the
`EditText` overlay, menus, alerts (`AlertDialog`), scrolling (`ScrollView`),
`SharedPreferences` settings, and `Typeface`-styled measurement.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface
- [`UXAndroidGraphics`](/compiler/api/uxkit/uxandroidgraphics/): the `Canvas`
  drawing vocabulary
- [`UXIosDriver`](/compiler/api/uxkit/uxiosdriver/): the sibling, with the same
  loop shape
- [`UXWebDriver`](/compiler/api/uxkit/uxwebdriver/): the other backend across a
  foreign-function boundary
