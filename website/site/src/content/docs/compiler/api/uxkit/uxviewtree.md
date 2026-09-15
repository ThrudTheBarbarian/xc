---
title: UXViewTree
description: "The flat array of objects the backend walks, paired one-to-one with the views that give them behaviour, and the damage region that decides what repaints."
---

`UXViewTree` is the structure underneath every window: a **flat array of
objects** that the backend walks, and a parallel array of
[`UXView`](/compiler/api/uxkit/uxview/)s that give each object behaviour.

You rarely call it directly. `addSubview`, `setHidden` and `setFrame` on a view
all end up here, and the tree explains much of the toolkit's behaviour.

```c
#use <UXKit>            // or #import "UXViewTree.xc"
```

## Overview

The hierarchy is **not** a private structure handed to the platform later. On
GEM it *is* a real AES `OBJECT` tree: `objc_draw` walks it, `objc_find`
hit-tests it, `objc_offset` positions it, and the AES theme draws every standard
widget in it, with no translation layer.

The other backends keep the same shape in their own shadow arrays, so one
hit-test, one damage model and one autoresize pass serve all of them.

### Two arrays, indexed the same

```
objects[i]   the thing the backend walks
views[i]     the UXView that gives it behaviour
```

The backend works with **indices**; your code works with **objects**. `views[i]`
and `objects[i]` map to each other in O(1), with no map, lookup or reflection.
This pairing lets a native `NSButton` click become your controller's callback by
index, without a search.

### The tree is flat, and links are relative

Parent/child/sibling links are `i16` indices **relative to the root**, not
pointers. `addSubview` and `removeFromSuperview` only relink a flat array, as
the classic AES `objc_add` / `objc_delete` / `objc_order` do.

Two consequences:

- Adding and removing views is cheap and does not allocate.
- A removed node keeps its **slot**. It is unlinked, not compacted, so indices
  held elsewhere stay valid. A view that is off the tree is detached, not
  destroyed, so a realize pass must check whether a node is reachable from the
  root instead of assuming every slot is live.

## The damage region

```c
UXRect dirty;
bool   hasDirty;
```

Every `setNeedsDisplay` unions a rectangle into `dirty`, in **absolute**
coordinates. The next display pass repaints that area and clears it.

The region lives on the tree and not on [`UXWindow`](/compiler/api/uxkit/uxwindow/)
for a structural reason: a view must be able to mark itself dirty without
knowing about windows. A view already holds its tree, and a
`UXView → UXWindow` import would be a cycle.

The union uses [`UXGeom.unite`](/compiler/api/uxkit/uxgeom/#unite), which ignores
empty operands, so `dirty` can start at zero and accumulate with no special case
for the first rectangle. Otherwise one empty rect would extend the damage to the
origin and every repaint would cover the whole window.

## Topics

[append](#append) · [bind](#bind) · [adopt](#adopt) · [viewAt](#viewat) · [objects](#objects) · [addChild](#addchild--removechild) · [removeChild](#addchild--removechild) · [finalise](#finalise) · [markDirty](#markdirty) · [takeDirty](#takedirty) · [frameOf](#frameof--setframeof) · [setFrameOf](#frameof--setframeof) · [hiddenOf](#hiddenof--sethiddenof) · [setHiddenOf](#hiddenof--sethiddenof) · [enabledOf](#enabledof--setenabledof) · [setEnabledOf](#enabledof--setenabledof) · [selectedOf](#selectedof--setselectedof) · [setSelectedOf](#selectedof--setselectedof) · [setSpecOf](#setspecof) · [setPeerOf](#setpeerof) · [setAutoresizeOf](#setautoresizeof)

### append

```c
u16 append(i32 kind, UXRect f, Object* view)
```

Adds an object of `kind` with frame `f`, bound to `view`, and returns its index.
`UXView.attachTo` calls it; you use `addSubview` instead.

### bind

```c
void bind(u16 i, Object* view)
```

Points slot `i` at a view. This is the `.rsc` path, where the object already
exists and only the behaviour is supplied.

### adopt

```c
void adopt(pointer t, u16 n)
```

Takes over an existing object array of `n` entries. A resource file or a nib
becomes a live tree this way: the objects come from disk, and the views are
attached afterwards.

### viewAt

```c
Object* viewAt(u16 i)
```

The view backing object `i`, or null. The reverse direction of the pairing.

### objects

```c
pointer objects(void)
```

The raw object array, for the driver.

### addChild / removeChild

```c
void addChild(u16 parent, u16 child)
void removeChild(u16 parent, u16 child)
```

Relink. `removeChild` unlinks without compacting. See
[the flat tree](#the-tree-is-flat-and-links-are-relative).

### finalise

```c
void finalise(void)
```

Closes the tree: the shape is complete, so the backend may realize native
controls for it. Build the whole interface, then finalise once.

### markDirty

```c
void markDirty(UXRect abs)
```

Unions `abs` into the damage region.

### takeDirty

```c
UXRect takeDirty(void)
```

Returns the accumulated damage **and clears it** in one call, so a repaint
cannot race with a mark that arrives while it is running.

### frameOf / setFrameOf

```c
UXRect frameOf(u16 i)
void   setFrameOf(u16 i, UXRect f)
```

The object's frame, relative to its parent.

### hiddenOf / setHiddenOf

```c
bool hiddenOf(u16 i)
void setHiddenOf(u16 i, bool on)
```

The object's **own** hidden flag. This differs from "is it on screen": hiding a
container hides its children too, but the child's own flag is left unchanged so
that un-hiding the parent restores the previous state. Use the driver's
`effectiveHidden` for the inherited answer.

### enabledOf / setEnabledOf

```c
bool enabledOf(u16 i)
void setEnabledOf(u16 i, bool on)
```

### selectedOf / setSelectedOf

```c
bool selectedOf(u16 i)
void setSelectedOf(u16 i, bool on)
```

### setSpecOf

```c
void setSpecOf(u16 i, pointer spec)
```

The object's content, such as a title string for a button or a field editor for
a text field. Its meaning depends on the kind.

### setPeerOf

```c
void setPeerOf(u16 i, pointer peer)
```

Points the object at its neutral widget, so a backend with native controls can
fire an action **by handle and node** without a hit-test. Through this link a
real `NSButton` press runs your callback directly.

### setAutoresizeOf

```c
void setAutoresizeOf(u16 i, i32 mask)
```

Springs and struts. See
[the view tree guide](/compiler/api/uxkit/guide-view-tree/#resizing-springs-and-struts).

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXView`](/compiler/api/uxkit/uxview/): the behaviour half of each pair, and
  the API you normally use
- [`UXWindow`](/compiler/api/uxkit/uxwindow/): owns a tree and displays it
- [`UXGeom`](/compiler/api/uxkit/uxgeom/): `unite`, and why empty is its
  identity
- [The view tree and layout](/compiler/api/uxkit/guide-view-tree/)
