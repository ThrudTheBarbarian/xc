---
title: UXGL
description: "The GL calls a renderer makes, declared once: the same renderer source builds on every backend with GL."
---

`UXGL.xc` declares the GL 3.2-core calls a renderer makes: buffers, vertex
arrays, shaders, textures, framebuffers, uniforms and their deletes, with
`glViewport` and `glGetError`. A renderer imports it instead of declaring its own
`gl*` externs, and the same source builds on every backend with GL.

```c
#import "UXGL.xc"
```

A client of the installed library imports it *after* `#use <UXKit>` — the `#use` puts the library's
`xc/` contract directory on the quote path, where the file ships as `3p/uxkit/xc/UXGL.xc` — and
links GL itself:

```c
#use <UXKit>
#import "UXGL.xc"
```

## Overview

On macOS, Linux, iOS, Android and the web the calls are the platform's own. The
build's link line names the GL library, and only that differs between platforms:

| Backend | Link |
|---|---|
| macOS (AppKit or GTK) | `-framework OpenGL` |
| Linux (GTK) | `-lGL` |
| iOS | `-framework OpenGLES` |
| Android | `libGLESv3.so` as a dependency of the app library |
| Web | nothing: the calls are host imports, backed by WebGL2 |
| Windows | nothing: see below |

`opengl32.dll` exports only GL 1.1, and the win64 toolchain links none of it. On
win64 each call in `UXGL.xc` is a small function instead. The first time it is
called, with a context current, it finds the real entry point through the
driver's `glProc` (`wglGetProcAddress`, else `opengl32`'s own export), then
calls it. A call the context does not have does nothing and answers 0.

The shading language follows [`UXGLView.glKind`](/compiler/api/uxkit/uxglview/#glkind):
`UX_GL_GL33` takes `#version 150` or later, and `UX_GL_GLES3` and `UX_GL_WEBGL2`
take `#version 300 es`.

To read back what was drawn, use [`UXGLView.snapshot`](/compiler/api/uxkit/uxglview/#snapshot)
after `presentGL`. `glReadPixels` cannot read a multisampled framebuffer, and on
AppKit the renderer draws into one.

## See also

- [`UXGLView`](/compiler/api/uxkit/uxglview/): the view that owns the context
- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/#gl-the-driver-owns-the-surface-and-the-frame): `glProc`, for a call `UXGL.xc` does not declare
