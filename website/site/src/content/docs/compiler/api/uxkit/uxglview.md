---
title: UXGLView
description: "A view that owns a GL context: the driver keeps the surface and the frame, the app keeps the renderer."
---

`UXGLView` is a [`UXView`](/compiler/api/uxkit/uxview/) that can own a GL
context instead of being painted by `drawRect`. The driver owns the surface,
its size, its order and its swap. The app owns the renderer and finds its entry
points through [`UXViewDriver.glProc`](/compiler/api/uxkit/uxviewdriver/#gl-the-driver-owns-the-surface-and-the-frame),
or as plain C functions linked against the platform's GL library (`-framework
OpenGL` on macOS, `-lGL` on Linux).

```c
#import "UXView.xc"
```

## Overview

```c
if (map.makeGL()) {
    // draw the frame
    map.presentGL();
}
```

Where the backend has no GL, or no surface could be made, `makeGL` answers false
and the view is still a view: `drawRect` paints it.

## Topics

**The context** · [glKind](#glkind) · [makeGL](#makegl) · [glContext](#glcontext) · [presentGL](#presentgl) · [destroyGL](#destroygl)
**The drawable** · [drawableSize](#drawablesize) · [snapshot](#snapshot)

### glKind

```c
i32 glKind(void)
```

Which GL the backend offers: `UX_GL_GL33`, `UX_GL_GLES3`, `UX_GL_WEBGL2`, or
`UX_GL_NONE`.

### makeGL

```c
bool makeGL(void)
```

Binds a context to the view. It can be called again safely.

### glContext

```c
pointer glContext(void)
```

The backend's opaque context, or 0. The renderer hands it back and never reads
through it.

### presentGL

```c
void presentGL(void)
```

The frame is finished. Call it once per turn, after any 2-D view over this one
has been damaged, so both land in one present.

### destroyGL

```c
void destroyGL(void)
```

Releases the context. The view also releases it when it leaves the tree or is
freed.

### drawableSize

```c
bool drawableSize(i32* pw, i32* ph)
```

The drawable's size in pixels, the size the renderer draws at: the bounds times
the backing scale, or the driver's framebuffer where the GPU cannot take the full
size. False before the view has a surface.

### snapshot

```c
UXImage* snapshot(void)
```

The view's last GL frame alone, without the 2-D views over it, at the drawable's
size. AppKit, GTK and Win32 read it. Elsewhere, and before the view has a
surface, it is null. For the window as it shows, use [`UXWindow.snapshot`](/compiler/api/uxkit/uxwindow/).
