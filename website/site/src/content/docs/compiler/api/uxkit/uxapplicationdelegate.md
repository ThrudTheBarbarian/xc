---
title: UXApplicationDelegate
description: "The one protocol every UXKit program implements: build your interface in applicationDidStart, and optionally hear about resizes."
---

`UXApplicationDelegate` is the protocol your controller adopts to become a
program. It has one required method and one optional one.

```c
#use <UXKit>            // or #import "UXApplication.xc"
```

## Overview

```c
protocol UXApplicationDelegate {
    i32 applicationDidStart(UXApplication* app);
    optional void windowDidResize(UXApplication* app, UXWindow* win,
                                  i32 width, i32 height);
}
```

```c
class MyApp : Object <UXApplicationDelegate>
{
    i32 applicationDidStart(UXApplication* app) {
        UXView*   content = new UXView();
        UXWindow* win     = new UXWindow();
        app.addWindow(win);
        win.open((u8*)"Hello", UXGeom.make(80, 80, 240, 120), content);
        // … build the interface …
        win.tree.finalise();
        win.displayAll();
        return 0;
    }
}
```

### A delegate, not a base class

Your controller **conforms to a protocol** and does not inherit from an
application class. Its inheritance stays free for whatever your program needs,
and one small class can be the application delegate, a
[table data source](/compiler/api/uxkit/uxtabledatasource/) and a
[table delegate](/compiler/api/uxkit/uxtabledelegate/) at once. This is normal
for a single-window program.

## Topics

[applicationDidStart](#applicationdidstart) · [windowDidResize](#windowdidresize)

### applicationDidStart

```c
i32 applicationDidStart(UXApplication* app)
```

Runs **once**, after the toolkit is up and before the first event. Build your
interface here.

The toolkit is fully available: the driver has booted, the screen size is
known, and [`UXMetrics`](/compiler/api/uxkit/uxmetrics/) can answer form-factor
questions. Make decisions that depend on the platform here, not at construction
time.

Return `0` for success. A non-zero return means "do not continue". A program
uses it to refuse to run when something it needs is missing. The usual case is
the wiring check in a nib-loading app:

```c
i32 applicationDidStart(UXApplication* app) {
    if (!Builder.buildInto(content, self, W, H)) {
        Stdio.printf("FAIL: a wiring name was rejected\n");
        return 1;                      // a typo the nib path would hit too
    }
    …
    return 0;
}
```

### windowDidResize

```c
optional void windowDidResize(UXApplication* app, UXWindow* win,
                              i32 width, i32 height)
```

The user resized a window. `width` and `height` are the **new content-area**
size.

When this runs, the native frame has finished the drag, and the toolkit has
**already reflowed the tree and repainted** using the autoresize masks. Most
programs (any whose layout springs and struts describe) ignore this method, so
it is `optional`. Implement it when anchors cannot express your layout: a view
whose contents reflow by recomputing, or one that switches arrangement at a
size threshold.

## What `main` does

The delegate is half of the pattern. The other half is four lines:

```c
void main(void) {
    gDriver = new UXAppKitDriver();       // the ONE platform-aware line
    UXApplication* app = new UXApplication();
    app.setDelegate(new MyApp());
    app.run();                            // does not return
}
```

`run` takes over. The event loop dispatches to windows, windows to views, and
controls to your callbacks. It ends when the last window closes or something
calls [`stop`](/compiler/api/uxkit/uxapplication/).

See [the driver model](/compiler/api/uxkit/guide-drivers/) for turning that
first line into a multiplatform seam.

## See also

- [`UXApplication`](/compiler/api/uxkit/uxapplication/): the run loop, windows,
  the menu bar and the event tap
- [Your first window](/compiler/api/uxkit/guide-first-window/): the whole
  pattern in forty lines
- [`UXWindow`](/compiler/api/uxkit/uxwindow/): what you open in
  `applicationDidStart`
- [`UXMetrics`](/compiler/api/uxkit/uxmetrics/): form-factor answers, available
  when it runs
