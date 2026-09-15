---
title: UXViewDriver
description: "The seam between the neutral toolkit and a native backend: the methods a backend implements, in eight groups, and the one platform name a UXKit program uses, once."
---

`UXViewDriver` is **the** seam between the toolkit and a platform. Views,
controls, layout and the responder chain above it are one body of code; each
platform sits below it. It is also the only platform-specific name a
well-written program contains, and that name appears once:

```c
gDriver = new UXAppKitDriver();
```

```c
#use <UXKit>            // or #import "UXViewDriver.xc"
```

## You implement this only to add a backend

Most readers never implement `UXViewDriver`; they choose one. This page serves
two audiences: someone porting UXKit to a new platform, and someone who wants to
understand why the toolkit behaves as it does, since most unexpected behaviour
elsewhere follows from something here.

To pick a backend, read [the driver model](/compiler/api/uxkit/guide-drivers/)
instead.

## The eight groups

The protocol falls into eight groups:

| group | what it covers |
| --- | --- |
| **windows** | create, open, title, icon, invalidate, destroy, scroll offset |
| **the shadow tree** | `struct*` — the flat object array the platform walks |
| **realization** | `realizeTree` — make native controls and push their state |
| **events** | `nextEvent`, `pumpMessages`, `runLoop`, `trackDragStep` |
| **drawing** | `beginViewDraw`, `treeDraw`, `setDrawOffset`, text measurement |
| **native panels** | file open, colour picker, font picker — each behind a `has…` flag |
| **menus** | `menuBuild`, `menuShow`, `menuCheck`, `runPopupMenu` |
| **platform services** | clock, settings, directory listing, file operations |

The last group exists because a toolkit that can open a window but cannot read a
preference forces every app to add its own platform seam, and the app then has
two.

## The patterns worth knowing

### Capability flags, not assumptions

```c
bool hasNativeFileOpen(void);
bool hasNativeColorPicker(void);
bool hasNativeFontPicker(void);
bool scrollsNatively(void);
bool driverOwnsRunLoop(void);
```

Each flag guards a facility the backend may or may not have. Ask, then use the
native facility or the toolkit's own. This is how
[`UXFilePanel`](/compiler/api/uxkit/uxfilepanel/) is a real `NSOpenPanel` on
macOS and a drawn panel on GEM, from one call site.

`driverOwnsRunLoop` has the largest effect. AppKit returns **true** because
`[NSApp run]` owns the loop and events must be pushed into the application. GEM
and Win32 return **false** and let the neutral loop pull events with
`nextEvent`. Both shapes exist because each platform requires its own.

### The shadow tree is the platform's, not ours

```c
pointer structNew(void);
i32     structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht);
void    structAddChild(pointer h, i32 parent, i32 child);
void    structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht);
```

The driver owns the node array. The toolkit holds an opaque handle and never
allocates or relinks the array itself. On GEM the array **is** the AES `OBJECT`
tree, so `objc_draw` and `objc_find` work on it directly with no translation.

See [`UXViewTree`](/compiler/api/uxkit/uxviewtree/) for the part the toolkit
uses.

### Setters push, or they do not — and that is a decision

A `structSet*` either writes the shadow node **and pushes to the native
control**, or writes only the node and leaves the push to the next
`realizeTree`. Both are valid; inconsistency is not.

The rule: anything a user can observe immediately must push immediately. Hidden,
enabled, frame and toggle state all push. A flag that only affects the next draw
need not.

This affects more than backend authors. A state change that "only works
sometimes" is nearly always a setter that writes the shadow tree while something
*else* happens to trigger a realize.

### A drag is modal

```c
i32 trackDragStep(i32* x, i32* y);      // 1 while dragging, 0 on release
```

Toolkit-drawn drags (a scrollbar thumb, a split divider, an editor moving an
object) call this in a loop. It **blocks** until the pointer moves or the
button is released, and emits no events.

This has effects elsewhere. A widget waiting for `mouseDragged` waits forever. A
recorder captures the press and nothing else, so
[`UXEvent`](/compiler/api/uxkit/uxevent/) has outcome kinds such as
`UXEventScrolled`. A replayed press must not re-enter the loop, which
`gInputReplay` prevents.

A backend whose native controls handle their own dragging returns `0`
immediately.

### Text measurement belongs to the backend

```c
i32 textWidth(u8* s, i32 size);
i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic);
```

Only the backend knows its glyphs.
[`UXTextLayout.wrapFont`](/compiler/api/uxkit/uxtextlayout/) breaks lines using
these, while its `wrap` uses a uniform width and needs no driver. Layout logic
is therefore testable headlessly; rendering is not.

## The whole protocol

The groups above organise the protocol; this is the surface a backend must
provide. All methods are required. There are no `optional` methods, because a
half-implemented backend is worse than an absent one.

A method a platform cannot perform returns a constant, and the
[capability flags](#capability-flags-not-assumptions) let a caller find out
before asking. The contract is that *answering* is mandatory and *doing* is not.

### Windows

```c
i32 windowCreate(i32 x, i32 y, i32 w, i32 h)
void windowSetContent(i32 handle, pointer fn, pointer ud)
void windowOpen(i32 handle, i32 x, i32 y, i32 w, i32 h)
void windowDestroy(i32 handle)
void windowSetTitle(i32 handle, u8* s)
void windowSetSubtitle(i32 handle, u8* s)
void windowSetInfo(i32 handle, u8* s)
void windowSetIcon(i32 handle, u8* slice)
void windowSetModified(i32 handle, bool m)
void windowContentSize(i32 handle, i32 w, i32 h)
i32 windowScrollX(i32 handle)
i32 windowScrollY(i32 handle)
void windowSetScroll(i32 handle, i32 x, i32 y)
void windowContentGeometry(i32 handle, i32* w, i32* h)
void windowInvalidate(i32 handle)
void windowInvalidateRect(i32 handle, i32 x, i32 y, i32 w, i32 h)
void windowOrderFront(i32 handle)
i32 windowAtPoint(i32 x, i32 y)
```

### The shadow tree

```c
void treeOffset(pointer tree, i32 obj, i32* ax, i32* ay)
i32 treeHitTest(pointer tree, i32 start, i32 x, i32 y)
void structAbsFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
pointer structNew(void)
void structFree(pointer h)
void structAdopt(pointer h, pointer t, i32 n)
pointer structObjects(pointer h)
i32 structLength(pointer h)
i32 structAppend(pointer h, i32 kind, i32 x, i32 y, i32 w, i32 ht)
void structAddChild(pointer h, i32 parent, i32 child)
void structRemoveChild(pointer h, i32 parent, i32 child)
void structFinalise(pointer h)
void structSetFrame(pointer h, i32 i, i32 x, i32 y, i32 w, i32 ht)
void structFrame(pointer h, i32 i, i32* x, i32* y, i32* w, i32* ht)
void structSetHidden(pointer h, i32 i, i32 on)
i32 structIsHidden(pointer h, i32 i)
void structSetEnabled(pointer h, i32 i, i32 on)
i32 structIsEnabled(pointer h, i32 i)
void structSetSelected(pointer h, i32 i, i32 on)
i32 structIsSelected(pointer h, i32 i)
void structSetClips(pointer h, i32 i, i32 on)
void structSetSpec(pointer h, i32 i, pointer spec)
void structSetSelectable(pointer h, i32 i, i32 on)
void structSetEditable(pointer h, i32 i, i32 on)
void structSetPeer(pointer h, i32 i, pointer peer)
void structSetAutoresize(pointer h, i32 i, i32 mask)
void treeSetUserDraw(pointer fn, pointer ud)
void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
```

### Realization

```c
void realizeTree(i32 handle, pointer tree)
pointer fieldEditorNew(u8* buf, i32 cap)
i32 liveNativeCount(void)
```

### Events and the run loop

```c
void nextEvent(i32 timeoutMs, UXEvent* ev)
void pumpMessages(i32 timeoutMs, UXEvent* ev)
i32 trackDragStep(i32* x, i32* y)
bool driverOwnsRunLoop(void)
void runLoop(void)
```

### Drawing

```c
UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
void setDrawOffset(i32 x, i32 y)
bool scrollsNatively(void)
```

### Text measurement

```c
i32 textWidth(u8* s, i32 size)
i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
i32 fontFamilyCount(void)
i32 fontFamilyName(i32 idx, u8* out, i32 cap)
```

### Native panels

```c
bool hasNativeFileOpen(void)
i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
bool hasNativeColorPicker(void)
i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
bool hasNativeFontPicker(void)
i32 pickFont(u8* inFamily, i32 inSize, i32 inBold, i32 inItalic,
             u8* outFamily, i32 outCap, i32* outSize, i32* outBold, i32* outItalic)
i32 fileDelete(u8* path)
i32 fileRename(u8* src, u8* dst)
i32 fileCopy(u8* src, u8* dst)
void nativeScrollTo(pointer h, i32 node, i32 px)
i32 nativeScrollPx(pointer h, i32 node)
i32 alertRun(i32 icon, u8* lines, u8* buttons, i32 defaultBtn)
```

### Menus

```c
i32 runPopupMenu(pointer peer, i32 x, i32 y)
pointer menuBuild(pointer defs, i32 n, i32 screenW)
void menuShow(pointer menu, i32 show)
i32 menuItemOrd(pointer menu, i32 titleOrd, i32 itemObj)
void menuCheck(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
void menuEnable(pointer menu, i32 titleOrd, i32 itemOrd, i32 on)
```

### Platform services

```c
i32 nowMs(void)
void nowUTC(i32* out7)
i32 localOffsetMinutes(void)
bool settingGet(u8* domain, u8* key, u8* out, i32 cap)
bool settingSet(u8* domain, u8* key, u8* value)
bool settingRemove(u8* domain, u8* key)
i32 formFactorClass(void)
```

### Everything else

```c
i32 pickColor(i32 r, i32 g, i32 b, i32* outR, i32* outG, i32* outB)
i32 listDir(u8* path, u8* out, i32 outCap)
bool driverAutoresizes(void)
void fieldEditorSetValid(pointer ed, u8* valid)
void fieldEditorSetPlaceholder(pointer ed, u8* s)
void fieldEditorSetSecure(pointer ed, i32 on)
void fieldEditorFree(pointer ed)
i32 editText(pointer tree, i32 obj, i32 key, i32* caret, i32 mode)
bool boot(i32* screenW, i32* screenH)
```

## Implementations

| backend | driver |
| --- | --- |
| macOS | [`UXAppKitDriver`](/compiler/api/uxkit/uxappkitdriver/) |
| Windows | [`UXWin32Driver`](/compiler/api/uxkit/uxwin32driver/) |
| Linux | [`UXGtkDriver`](/compiler/api/uxkit/uxgtkdriver/) |
| Atari | [`UXGemDriver`](/compiler/api/uxkit/uxgemdriver/) |
| iOS | [`UXIosDriver`](/compiler/api/uxkit/uxiosdriver/) |
| Android | [`UXAndroidDriver`](/compiler/api/uxkit/uxandroiddriver/) |
| web | [`UXWebDriver`](/compiler/api/uxkit/uxwebdriver/) |

Each is the one file that knows its platform. Adding an eighth means answering
every question here, and the capability flags let a new backend answer "no" to
the native panels and still be complete.

## See also

- [The driver model and multiplatform](/compiler/api/uxkit/guide-drivers/):
  choosing one, and writing the `#ifdef` seam correctly
- [`UXViewTree`](/compiler/api/uxkit/uxviewtree/): the shadow tree from the
  toolkit's side
- [`UXGraphics`](/compiler/api/uxkit/uxgraphics/): the drawing protocol a
  driver supplies a realization of
- [`UXEvent`](/compiler/api/uxkit/uxevent/): what `nextEvent` produces
