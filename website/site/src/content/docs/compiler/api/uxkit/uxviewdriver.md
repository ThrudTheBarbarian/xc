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
bool hasNativeFileSave(void);
bool hasNativeNavigation(void);
bool dragTrackingIsModal(void);
bool hasNativeColorPicker(void);
bool hasNativeFontPicker(void);
bool scrollsNatively(void);
bool driverOwnsRunLoop(void);
```

Each flag guards a facility the backend may or may not have. Ask, then use the
native facility or the toolkit's own. This is how
[`UXFilePanel`](/compiler/api/uxkit/uxfilepanel/) is a real `NSOpenPanel` on
macOS and a drawn panel on GEM, from one call site.

`dragTrackingIsModal` is about *how* a drag arrives. Where it is true (the
desktops, GEM, the web's worker), a view that drags may loop on
`trackDragStep` inside its `mouseDown`. On iOS and Android it is false: the
platform owns the loop, so a drag arrives as `mouseDragged` and `mouseUp`
events (see [`UXWindow`](/compiler/api/uxkit/uxwindow/#touch)), and a view
that drags continues from those instead.

`driverOwnsRunLoop` has the largest effect. iOS and Android return **true**:
their native loops never return from `runLoop`, so the neutral loop is never
entered and the app's life continues through driver callbacks. Everything else
— AppKit (interactive included), GEM, Win32, GTK and the web — returns
**false** and lets the neutral loop pull events with `nextEvent`. Both shapes
exist because each platform requires its own; an interactive AppKit app is the
interesting middle case, because the driver does not own the loop and yet
`nextEvent` blocks in `[NSApp run]` anyway (see
[the turn hook](#a-turn-comes-from-the-driver-or-from-the-loop)).

### A turn comes from the driver, or from the loop

```c
bool setTurnHook(turnHook_t* fn, i32 ms)
```

An animated app asks for a turn with
[`UXApplication.everyTurn`](/compiler/api/uxkit/uxapplication/#everyturn), and
this is where the answer comes from. The **return value says who calls `fn`**:

- **true** — the driver armed its own source and calls `fn`. This is the
  loop-owning case: interactive AppKit blocks in `[NSApp run]` inside
  `nextEvent`, and iOS and Android never return from `runLoop`, so nothing
  above the driver would get a turn at all. AppKit arms a repeating
  `NSTimer` on the main queue; Android reposts a `Handler` message; iOS
  schedules the same timer.
- **false** — the driver has no turn of its own to offer, and the **neutral
  loop** paces itself instead: `ms` becomes the wait it hands `nextEvent`, so a
  turn comes round even when no input does, and `fn` runs after that turn's
  draws.

A client that needs to know which it got asks `turnIsDriven()` rather than
guessing. `fn` takes **no arguments** and is a plain function, not a bound
method: the loop-owning backends hold it as a C function pointer, which has
nowhere to keep a captured `self`. `ms` of 0 means "every turn the loop has",
and `everyTurn(0, 0)` stops the clock.

Because the answer is *false* for a driver that does not own the loop,
`nextEvent`'s timeout is a real deadline:

```c
void nextEvent(i32 timeoutMs, UXEvent* ev)   // >0: return UXEventNone on the deadline
```

A positive `timeoutMs` means the wait must **end** on its own — Win32 waits
with `MsgWaitForMultipleObjects` instead of blocking in `GetMessageA`, GTK
attaches a one-shot timer to its `GMainContext`, GEM adds `MU_TIMER` to the
event mask, the web ring waits on the deadline, and headless AppKit polls for
exactly that long. Zero or less keeps the old block-until-there-is-one
behaviour, so a client without a clock is unchanged.

### GL: the driver owns the surface and the frame

```c
i32     glKind(void);
bool    compositesWithGL(void);
pointer glProc(u8* name);
pointer makeGLContext(pointer view);
void    destroyGLContext(pointer view);
void    resizeGL(pointer view, i32 w, i32 h);
void    presentGL(pointer view);
void    glSetSwapInterval(i32 interval);
```

A view may own a GL context instead of being painted by `drawRect`. This is the
DRI split, not indirect GLX: **the driver owns the surface** — the native
drawable, its order, its resize, its swap — and **the app owns the renderer**,
which loads its own entry points through `glProc`. Routing GL through
`UXGraphics` instead would be one round trip per call, and is refused.

`glKind()` names the call set (`UX_GL_NONE`, `UX_GL_GLES3`, `UX_GL_GL33`,
`UX_GL_WEBGL2`); a backend with none answers `UX_GL_NONE`, and the view is drawn
by `drawRect` like any other. `makeGLContext` binds a context to a view and
`presentGL` ends the frame. The driver sets the viewport from the drawable's own
pixels, resizes both in the same turn as the resize, and skips `drawRect` for a
view that owns a context — the two are alternative renderers, never both.

On AppKit the drawable is **offscreen**: the renderer draws into a framebuffer
the driver owns (it is the renderer's default framebuffer, so the renderer does
not change), `presentGL` resolves it, and the toolkit paints the frame into the
window's one 2-D pass. A view after the GL view in the tree is drawn over the map
by draw order, and there is no GL plane for the window server to order.

Win32 does the same: the frame is rendered into a framebuffer object, read back
into a DIB at the present, and blitted with `StretchDIBits` in the window's own
paint. It matters more there, because the GL used to be a child window and
Windows clips a parent's painting around its children — nothing the toolkit drew
could land on the map at all. A GL without framebuffer objects keeps the visible
child window. GTK and the web still put the GL on a plane of its own.

**The drawable never exceeds what the GPU can hold.** Its size in pixels is the
view's size at the display's scale, but a maximised window on a 5K display, or
one stretched across two monitors, can be larger than an older GPU's limit
(`GL_MAX_TEXTURE_SIZE`, `GL_MAX_RENDERBUFFER_SIZE`, `GL_MAX_VIEWPORT_DIMS`). Then
every backend with GL shrinks the drawable by one factor on both sides, so the
aspect is kept, and stretches the frame back over the view. The picture gets
softer but is never cropped. The viewport follows the drawable, so the renderer
needs no change. On the web the canvas keeps the view's CSS size and the
browser does the stretching. On GTK, whose `GtkGLArea` sizes its own
framebuffer, the renderer draws into one the driver makes at the clamped size,
and the area's render signal stretches it over GTK's.

**The present cadence is the rule GL rests on: present happens at most once per
loop turn, after damage is consolidated, and the driver owns the frame clock.**
A GL view is the bottom of the stack and every other view is above it, so
nothing is ever drawn between two GL draws and the present is enough on its own. A
GL view never runs a clock of its own: it requests a frame
([the turn hook](#a-turn-comes-from-the-driver-or-from-the-loop)) and lets the
driver pace it.

`compositesWithGL()` is the one query about ordering. It asks whether the
platform composites the 2-D layer and the GL present in **one step**, or leaves
the driver two producers to order and pace. A view drawn over a GL surface
composites on every backend, because the display server composites; the question
is who owns that step, and the app picks its overlay and redraw strategy from the
answer. GTK and the web answer **true** (the surface is a distinct plane the
compositor merges — a `GtkGLArea`, a canvas stacked under the 2-D one). AppKit
and Win32 answer **false**: their frame is painted into the 2-D pass and ordered
by the driver. GEM, iOS and Android answer **false** (no GL).

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
i32 textWidthWeight(u8* s, u8* family, i32 size, i32 weight, bool italic);
i32 textAscent(u8* family, i32 size, i32 weight, bool italic);
```

Only the backend knows its glyphs.
[`UXTextLayout.wrapFont`](/compiler/api/uxkit/uxtextlayout/) breaks lines using
these, while its `wrap` uses a uniform width and needs no driver. Layout logic
is therefore testable headlessly; rendering is not.

`textWidthWeight` is `textWidthStyled` with the weight on the CSS scale rather
than a bool, so a measure and a
[`drawTextFontRGBA`](/compiler/api/uxkit/uxgraphics/#drawtextfontrgba) at the
same weight agree: `textWidthStyled(s, family, size, bold, italic)` answers
exactly as `textWidthWeight` at `UXWEIGHT_SEMIBOLD` or `UXWEIGHT_NORMAL`. The
same string can measure 27 at bold and 25 at 600, and only one of those is what
the backend draws.

`textAscent` is the other half of a measure: the distance from the **top of the
line** — the `y` a
[`drawText*`](/compiler/api/uxkit/uxgraphics/#drawtext) call is handed — down to
the **baseline**, for a family, size and weight. A caller holding a baseline (a
canvas' `y`, a print metric, another toolkit's metric) converts it with
`y = baseline - driver.textAscent(...)`. It is the **face's** ascent, not the
string's: a line of digits is not shorter than a line with a bracket, and a line
whose height moves with its own text is the bug this avoids. It is also the
number each backend's own draw call offsets by, so a conversion done with it
lands the ink where the caller asked: every bring-up gate lays one cap-height
row and checks the ink's last row against the baseline the metric names
(`make mac-weight`, `make gtk-real`, `make ios-real`, `make android-real`).

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
bool appSetIcon(u8* data, i32 w, i32 h, i32 format)
bool audioPlay(i16* pcm, i32 frames, i32 rate)
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
void structSetClipShape(pointer h, i32 i, i32 radius, i32 inset)
void structSetSpec(pointer h, i32 i, pointer spec)
void structSetSelectable(pointer h, i32 i, i32 on)
void structSetEditable(pointer h, i32 i, i32 on)
void structSetPeer(pointer h, i32 i, pointer peer)
void structSetAutoresize(pointer h, i32 i, i32 mask)
void treeSetUserDraw(pointer fn, pointer ud)
void treeDraw(pointer tree, i32 start, i32 clx, i32 cly, i32 clw, i32 clh)
```

`structSetClipShape` gives a clipping node's subtree clip a shape: its frame inset
by `inset` on every side, with corners of `radius` (`0` is square). It is how a
rounded scroll view clips its content where the toolkit draws the scroll view.
GEM's AES clip is a rectangle, so GEM keeps the square clip.

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
bool setTurnHook(turnHook_t* fn, i32 ms)
```

### Drawing

```c
UXGraphics* beginViewDraw(i32 ax, i32 ay, i32 aw, i32 ah)
void endViewDraw(void)
void setDrawOffset(i32 x, i32 y)
bool scrollsNatively(void)
```

`beginViewDraw` binds the drawing context to one view, and `endViewDraw` follows
when that view's `drawRect` returns. A view's drawing is clipped to its frame on
every backend. GEM does it here: its traversal is the AES's `objc_draw`, so it
pushes the frame onto the VDI clip stack in `beginViewDraw` and pops it in
`endViewDraw`. The others clip in their own tree walk and do nothing here.

### Text measurement

```c
i32 textWidth(u8* s, i32 size)
i32 textWidthStyled(u8* s, u8* family, i32 size, bool bold, bool italic)
i32 textWidthWeight(u8* s, u8* family, i32 size, i32 weight, bool italic)
i32 textAscent(u8* family, i32 size, i32 weight, bool italic)
i32 fontFamilyCount(void)
i32 fontFamilyName(i32 idx, u8* out, i32 cap)
```

### Native panels

```c
bool hasNativeFileOpen(void)
i32 fileOpen(u8* prompt, u8* startDir, u8* out, i32 outCap)
bool hasNativeFileSave(void)
i32 fileSave(u8* prompt, u8* startDir, u8* defaultName, u8* out, i32 outCap)
bool hasNativeNavigation(void)
pointer navAttach(i32 win, i32 navId, i32 x, i32 y, i32 w, i32 h)
void navPush(pointer nav, u8* title, i32 animated)
void navPop(pointer nav, i32 animated)
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
i32 orientation(void)
```

`orientation` is the device's orientation now: `UX_ORIENT_PORTRAIT` or
`UX_ORIENT_LANDSCAPE` on iOS and Android, and `UX_ORIENT_NONE` on the
desktop backends, which have no orientation axis. It feeds
[`UXNibV2.selectTreeOriented`](/compiler/api/uxkit/uxnibv2/#selecttreeoriented).

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
