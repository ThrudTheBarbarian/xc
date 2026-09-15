---
title: UXGemDriver
description: "The GEM backend: the AES's OBJECT tree does the walking, and the wind_* calls sit behind the interface every other backend implements."
---

`UXGemDriver` is the GEM realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/), and the backend the
interface is modelled on.

```c
#use <UXKit>            // or #import "UXGemDriver.xc"
```

## The reference backend

Every operation here is a `wind_*` or `objc_*` call that portable code such
as `UXWindow` would otherwise make directly. Keeping those calls in a driver
leaves room for other backends:
[`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/) has the same structure,
with `CreateWindowEx`/`DestroyWindow` in place of `wind_create` and
`wind_close`+`wind_delete`.

Reading this driver is the shortest route to understanding what the neutral
interface is *for*. Each method exists so that portable code does not name a
GEM call.

## The AES owns the tree

This is the structural difference from every other backend. GEM has an
`OBJECT[]` array that the AES itself walks (`objc_draw` paints it and
`objc_find` hit-tests it), so this driver does **not** keep a shadow tree.

```
GEM        the AES walks OBJECT[]              — the system does the work
Win32      the driver walks its own node array — nothing else will
AppKit     same
GTK, Web   same
```

The shadow tree exists because the other backends have no system-owned tree
to walk.

The `OBJECT[]` lives in the driver, not in
[`UXViewTree`](/compiler/api/uxkit/uxviewtree/). The view tree holds it only
as an **opaque handle** and never names `OBJECT`. The rule is that the
driver owns structure, so the neutral tree knows nothing about GEM objects.

## Two calls to close a window

```
wind_close   tells gemd to drop the window and free the surface
wind_delete  frees the client-side handle slot
```

**Both** are needed. The native object on GEM is the gemd window *plus* its
surface. Closing without deleting leaks a handle slot, and deleting without
closing leaves the server holding a surface.

This follows the AES's own `menu.c` pattern.

## The native-object counter

```c
i32 gGemNativeLive;
```

A driver-module global that counts the natives **of this backend**; it is
not per-view state. `liveNativeCount()` exposes it, and the memory gate
asserts that it balances.

This is one half of the toolkit's per-backend memory rule, which requires
an object counter *and* an allocator probe. A driver can balance its own
count while still leaking the memory behind it, so a backend checked only by
its counter could pass a test it should fail.

## This driver runs its own menus

`runPopupMenu` reads the peer
[`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/)'s items and runs the
menu **itself**. The other backends hand a list to the platform.

Alerts work the same way: `form_alert` takes a single
`[icon][lines][buttons]` string, which this driver builds. Where a backend
has a rich dialog API the driver is a thin mapping; where it takes one
string, the driver assembles the string.

## Testing it on a desktop

The GEM stack runs natively on macOS through the host build.
`build_gemd.sh` produces `libGEM.dylib` and `libxtos.dylib`, and clients
build against the toolkit headers with `-L /tmp`. Most clients need
`host_gemd serve` running.

Filesystem paths like `/OS/fonts` are redirected **per libc call**, with
`fopen`, `font_face_open` and `opendir` each wrapped, not globally. A new
entry point must be added to the wrapper; it does not inherit the redirect.

`run_gem_tests.sh` is the gate: 18 tests pass, and 4 are quarantined as
building but not passing.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface
- [`UXGemGraphics`](/compiler/api/uxkit/uxgemgraphics/): the VDI drawing
  vocabulary
- [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/): the second backend,
  and the first with a shadow tree
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/): which holds this driver's
  `OBJECT[]` as an opaque handle
