---
title: UXPlatform
description: "The driver for the backend a build links, so an application's main() is the same on every platform."
---

`UXPlatform` gives an application the driver for the backend its build links.
With it in the build, `new UXApplication()` installs that driver, so `main()`
names no platform:

```c
#import "UXPlatform.xc"

void main(void) {
    UXApplication* app = new UXApplication();
    app.setDelegate(new Controller());
    app.run();
}
```

## Overview

The backend follows the target where the target decides it: win64 is Win32,
wasm32 the web, arm9 GEM, `ios-sim` and `ios` iOS, `android` Android. Otherwise
the build names it with `-D UX_GTK` or `-D UX_GEM` (GEM on a host). With
neither, an arm64 build is the Mac's AppKit and an x86_64 build is GTK on Linux.
Only the driver the build uses is imported.

Import `UXPlatform.xc` before the other UXKit files (`#use <UXKit>` does this),
so the application's constructor sees it. A program that has set `gDriver`, or
calls [`setDriver`](/compiler/api/uxkit/uxapplication/#setdriver) itself, keeps
the driver it chose.

A build script may differ per platform, in its link flags, its shims and these
defines. The `.xc` source does not.

## Topics

**The backend** · [driver](#driver) · [fillsScreen](#fillsscreen) · [displayName](#displayname) · [name](#name)

### driver

```c
static UXViewDriver* driver(void)
```

A new driver for the backend this build links, for
[`UXApplication.setDriver`](/compiler/api/uxkit/uxapplication/#setdriver).

### fillsScreen

```c
static bool fillsScreen(void)
```

Whether an application's main window is the whole screen: true on iOS and
Android, where an app has one window that fills the display, and false on the
desktops, where a window opens at a size of its own.

### displayName

```c
static u8* displayName(void)
```

The platform's name for a title or an about box: `"macOS"`, `"Windows"`,
`"Linux"`, `"iOS"`, `"Android"`, `"the web"` or `"GEM"`.

### name

```c
static u8* name(void)
```

The backend's name for a log line: `"appkit"`, `"gtk"`, `"win32"`, `"web"`,
`"ios"`, `"android"` or `"gem"`.

## See also

- [`UXApplication`](/compiler/api/uxkit/uxapplication/): `setDriver`, `setHeadless`, `run`, `stop`
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the protocol every driver implements
