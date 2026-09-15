---
title: UXPopUpItem
description: "One choice in a pop-up button: the title the user sees and the tag your code matches on."
---

`UXPopUpItem` is one entry in a
[`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/)'s list.

```c
#use <UXKit>            // or #import "UXPopUpButton.xc"
```

## Overview

```c
class UXPopUpItem : Object {
    u8* title;    // what the user reads
    i32 tag;      // what your code matches on
}
```

The class has two fields, one for the user and one for your code.

## Title for the user, tag for you

Select by **tag** and the code keeps working when the list is reordered, an item
is inserted, or the titles are translated:

```c
popup.selectByTag(MODE_OUTLINE);
if (popup.selectedTag() == MODE_OUTLINE) { … }
```

Select by **index** (`selectItem`) and it breaks the first time someone adds an
item at the top. Select by **title** (`selectByTitle`) and it breaks the first
time the wording changes.

Each of the three has a use: index to restore the previous position, title for a
list built from data where the string *is* the identity. A fixed set of choices
should use the tag.

:::note[A tag that matches nothing leaves the selection alone]
`selectByTag` and `selectByTitle` scan for a match and return without changing
anything if there is none. A stale saved preference does not clear the
selection; the pop-up keeps showing its current item.

That is usually what you want on restore. When it is not, check
[`selectedTag`](/compiler/api/uxkit/uxpopupbutton/) afterwards.
:::

## The list is the model; the menu is the backend's

The items and the selection are the pure, testable part: adding, reordering,
selecting and querying the selection all work with no window.

The backend runs the pop-up menu when the button is clicked and draws the closed
button showing the current title. A pop-up's *behaviour* is tested headless, and
only its appearance needs a platform.

For the same reason the class has only two plain fields. Anything a menu item
carries on a given platform (an image, a key equivalent, a submenu) belongs to
the backend's menu.

## Duplicate tags are allowed

Nothing stops two items sharing a tag, and `selectByTag` takes the first.
That can be useful for two spellings of the same choice; otherwise it is a bug
that shows up as "selecting the wrong item".

Duplicate **titles** are also permitted, so title lookup is the weakest of the
three.

## Fields

### title

```c
u8* title
```

**Kept, not copied.** Use a literal, or a
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup) of any string built at run time.
A title from a scratch buffer leaves the menu showing whatever that buffer later
holds.

### tag

```c
i32 tag
```

Never interpreted by the toolkit. `0` is a valid tag.

Avoid `-1`: `selectedTag()` returns `-1` when nothing is selected, so an item
tagged `-1` is indistinguishable from no selection.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/): the control
- [`UXSegment`](/compiler/api/uxkit/uxsegment/): the same one-of-many choice
  when there is room to show them all
- [`UXMenuItem`](/compiler/api/uxkit/uxmenuitem/): a menu bar item, which
  carries much more
