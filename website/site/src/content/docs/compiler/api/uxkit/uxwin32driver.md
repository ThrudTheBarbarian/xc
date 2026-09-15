---
title: UXWin32Driver
description: "The Windows backend: real common controls over a shadow tree, with HWNDs kept in a side table because the neutral protocol uses i32 handles."
---

`UXWin32Driver` is the Win32 realization of
[`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/). The neutral toolkit runs on
it unchanged.

```c
#use <UXKit>            // or #import "UXWin32Driver.xc"
```

## The driver that invented the shadow tree

[`UXGemDriver`](/compiler/api/uxkit/uxgemdriver/) has the AES's `OBJECT[]` array,
and `objc_draw`/`objc_find` do the tree work for it. Win32 has no equivalent, so
this driver keeps its **own** flat node array with parent and sibling links and
walks it for painting (through `WM_PAINT` into the neutral draw seam) and for
hit-testing.

`UXAppKitDriver`, `UXGtkDriver` and `UXWebDriver` keep the same shadow tree. It
is the neutral form of the GEM-specific structure.

## Handles are `i32`, HWNDs are not

The neutral protocol passes windows as `i32` handles, and an `HWND` is
pointer-width. The driver keeps a **small table** indexed by the handle, and the
protocol never sees a pointer.

This lets one interface serve a 16-bit AES object index, a 64-bit `HWND`, an
`NSWindow` pointer and a DOM node id without any of them reaching the neutral
layer.

## Native common controls

The realized widgets are the platform's own, reading directly from the neutral
model:

| neutral | native class |
| --- | --- |
| [`UXTableView`](/compiler/api/uxkit/uxtableview/) | `SysListView32` |
| [`UXOutlineView`](/compiler/api/uxkit/uxoutlineview/) | `SysTreeView32` |
| [`UXSlider`](/compiler/api/uxkit/uxslider/) | `msctls_trackbar32` |
| [`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/) | combobox, `CBS_DROPDOWNLIST` |
| [`UXStepper`](/compiler/api/uxkit/uxstepper/) | `msctls_updown32` |
| [`UXProgressBar`](/compiler/api/uxkit/uxprogressbar/) | `msctls_progress32` |
| [`UXSegmentedControl`](/compiler/api/uxkit/uxsegmentedcontrol/) | `ToolbarWindow32` check-group |
| [`UXToolbar`](/compiler/api/uxkit/uxtoolbar/) | `ToolbarWindow32` button row |

Windows has no segmented control, so the closest equivalent is a toolbar
check-group: a row of connected buttons with one or many latched. This is a
*mapping* decision, not a drawing one, and it is why the neutral model describes
behaviour and not appearance.

## What is not implemented, and why

Implemented: menus, field editors, scrolling, tables and outlines, the toolbar
and the common dialogs.

Not implemented: `windowSetSubtitle`, `windowSetInfo`, `windowSetIcon`,
`windowSetModified`. These return a constant because **Win32 has no
window-chrome equivalent**: there is no subtitle line and no edited dot in the
title bar.

On [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/) the same methods are
different: `NSWindow` *does* have `subtitle` and `documentEdited`, and the
methods are not yet implemented. In a driver, a method returning a constant can
mean either; the comments say which.

:::note[Do not add `-l` flags for the system libraries]
`gdi32`, `user32` and `kernel32` are linked automatically.
:::

## Testing without Windows

A large set of `run_win32_*` gates exercises the Win32 backend: menus, focus,
scrolling, radio groups, text layout and the kitchen sink. They run under Wine
locally, and on a real Windows machine when the behaviour is something Wine does
not reproduce accurately.

Wine catches logic errors, and the real machine catches cases where Wine is more
forgiving than Windows.

## See also

- [`UXViewDriver`](/compiler/api/uxkit/uxviewdriver/): the interface
- [`UXGdiGraphics`](/compiler/api/uxkit/uxgdigraphics/): the drawing vocabulary
- [`UXGemDriver`](/compiler/api/uxkit/uxgemdriver/): the first backend, whose
  AES objects this generalises
- [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/): the sibling built on
  the same shadow tree
