---
title: UXNavItem
description: "One entry on a UXNavigationController's stack: a title and the view that form shows."
---

`UXNavItem` is one entry on a
[`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/)'s stack:
a **title** and the **content view** that form shows. The controller makes
them; you normally read them rather than construct them.

```c
#use <UXKit>
```

## Overview

```c
class UXNavItem : Object {
    u8*     title;        // what the bar shows for this form
    UXView* content;      // the form itself
}
```

The class has two fields and no behaviour. The navigation stack is a **pure
model** (push, pop, depth, top) that can be exercised with no window and no
driver, which works because the entries on the stack are inert.

You get one by pushing a form:

```c
UXNavigationController* nav = new UXNavigationController();
UXView* detail = new UXView();
nav.push((u8*)"Detail", detail);        // makes the UXNavItem for you
```

You reach one through the controller:

```c
i32 d = nav.depth();                     // how many forms deep
UXNavItem* it = nav.itemAt(d - 1);       // the top entry
u8* t = it.title;                        // "Detail"
UXView* v = it.content;                  // the view pushed with it
```

## Reading the stack without UXNavItem

You rarely need the item itself. The controller exposes the same information
directly, which reads better at a call site:

| instead of | write |
| --- | --- |
| `nav.itemAt(i).title` | [`nav.titleAt(i)`](/compiler/api/uxkit/uxnavigationcontroller/) |
| `nav.itemAt(i).content` | [`nav.contentAt(i)`](/compiler/api/uxkit/uxnavigationcontroller/) |
| `nav.itemAt(nav.depth()-1).title` | [`nav.topTitle()`](/compiler/api/uxkit/uxnavigationcontroller/) |
| `nav.itemAt(nav.depth()-1).content` | [`nav.topContent()`](/compiler/api/uxkit/uxnavigationcontroller/) |

Those methods are built on `UXNavItem`. The class is public so that code walking
the whole stack, such as a breadcrumb or a restore-state pass, can hold an entry
instead of a pair of parallel indices.

## Lifetime

The controller owns its items strongly, in push order. A
[`pop`](/compiler/api/uxkit/uxnavigationcontroller/) removes the entry from the
stack but **leaves the content view attached and hidden**, so pushing the same
form again re-reveals it instead of rebuilding it. The item is freed; the view
it named is not.

## Fields

### title

```c
u8* title
```

What the navigation bar shows while this form is on top, and what the **back**
affordance of the form above it shows.
[`backTitle`](/compiler/api/uxkit/uxnavigationcontroller/) returns the title of
the entry *under* the top, because back returns to that entry.

### content

```c
UXView* content
```

The form's view. The controller shows only the top one. On first push, if the
view is not already in a tree, the controller adds it as a subview at
[`contentFrame`](/compiler/api/uxkit/uxnavigationcontroller/) (the bounds minus
the navigation bar).

## See also

- [`UXNavigationController`](/compiler/api/uxkit/uxnavigationcontroller/): the
  stack that owns these, and the delegate that reports forms appearing and
  leaving
- [`UXView`](/compiler/api/uxkit/uxview/): what `content` is
