---
title: UXWebDriver
description: "The browser backend: the same shadow tree in wasm linear memory, drawn onto a canvas with no JS crossings for the structural half."
---

`UXWebDriver` is the web realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the toolkit compiled to
wasm and running in a browser.

```c
#use <UXKit>            // or #import "UXWebDriver.xc"
```

## The same shadow tree, in linear memory

GEM uses the AES's `OBJECT[]` and Win32 keeps a shadow tree beside real `HWND`s.
This driver keeps **the same shadow tree** (a flat node array, ported from
[`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/)) and draws everything
onto a per-window canvas.

As a result, **the entire structural half makes no JS crossings.** Adding a view,
moving it, hit-testing a click and walking the tree to paint are all wasm
operations on linear memory, with no call into the host.

The host surface is small: the window group, eight drawing primitives, and the
ring.

This follows from the toolkit being platform-neutral. If views were platform
objects, the web backend would need a DOM node per view and a crossing per
operation.

## The run loop runs in a Worker

The module runs in a **Worker**, and the three blocking methods block on the
loader's `SharedArrayBuffer` ring via `_xt_ring_wait`.

Nothing else touches shared memory. One worker runs the whole toolkit as
single-threaded xtc, so **atomic ARC is not needed**: one thread updates
reference counts, with no atomics.

This is an intended constraint. Allowing a second thread into the toolkit would
make every retain and release an atomic operation, on every backend.

## Draw callbacks are the ABI

The draw-seam callbacks go through `call_indirect` against a **declared
signature**, and those signatures *are* the ABI. No code casts a function
pointer to a different shape to put it in the table.

wasm enforces this at run time: a signature mismatch traps and does not corrupt
the stack. This is the one platform where the funcref discipline is checked for
you.

## What is not here yet

Each missing feature fails in a defined way and does not crash:

| missing | current behaviour |
| --- | --- |
| menus | not present |
| `alertRun` across the ring | returns the **default button**, which the protocol permits |
| the `<input>` field overlay | `editText`'s own engine covers ASCII |
| native panels | `hasNative*` answer **false**, so the toolkit's own panels take over |
| drag tracking | not present |

The `hasNative*` flags are the general mechanism: a backend that cannot present
a platform colour picker says so, and the neutral toolkit supplies its own. A
backend can be useful before it is complete.

## Testing

The wasm32 suite runs headless (58 tests). `run_web_real.sh` and
`run_web_loop.sh` cover the driver and the loop, and `run_web_memgate.sh`
checks that natives balance.

The visual captures need headless Chrome, so they are produced only where it is
installed.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface
- [`UXCanvasGraphics`](/compiler/api/uxkit/uxcanvasgraphics/): the eight
  primitives this draws through
- [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/): where the shadow tree
  came from
- [`UXAndroidDriver`](/compiler/api/uxkit/uxandroiddriver/): the other backend
  reached across a foreign-function boundary
