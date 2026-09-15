---
title: UXSegment
description: "One button of a segmented control: its label, its tag, whether it is selected, and the layout the control computed for it."
---

`UXSegment` is one segment of a
[`UXSegmentedControl`](/compiler/api/uxkit/uxsegmentedcontrol/).

```c
#use <UXKit>            // or #import "UXSegmentedControl.xc"
```

## Overview

```c
class UXSegment : Object {
    u8*  label;
    i32  tag;         // your identity for it
    bool selected;
    i16  x; i16 w;    // computed layout, within the control
}
```

The five fields split in two. `label`, `tag` and `selected` are **model**, which
you set. `x` and `w` are **layout**, which the control computes.

## Model and layout in one object

`x` and `w` are filled in when the control lays itself out, and overwritten the
next time it does. Values written to them by hand do not last.

They are public because hit-testing needs them. Finding the segment a click
landed on is a walk over the segments comparing against `x` and `x + w`. Keeping
the geometry beside the item makes that a loop rather than a recalculation.

Read them; do not set them.

## The tag is your identity

```c
i32 tag
```

An integer the toolkit never interprets. An action handler uses it to know
*which* segment was chosen without depending on the index. Indices shift when
segments are inserted or removed; tags do not.

Use an enum value, a mode constant, or a row id. The label is for the user; the
tag is for your code.

## `selected` is a field, not a command

```c
bool selected
```

Setting it marks the segment. It does **not** enforce the control's selection
mode. Making two segments `selected` in a single-selection control leaves both
marked, because the field is state rather than a request.

Go through the control's selection methods and the mode is applied for you.
Reading the field directly is fine and tells you which segments are on.

For a **multiple**-selection control, several being true is the normal case, and
reading the segments collects the set.

## Fields

### label

```c
u8* label
```

The text. **Kept, not copied**: pass a literal, or a
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup) of anything built at run time.

### tag

```c
i32 tag
```

### selected

```c
bool selected
```

### x / w

```c
i16 x; i16 w
```

Position and width within the control, in its coordinates. Recomputed on layout.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXSegmentedControl`](/compiler/api/uxkit/uxsegmentedcontrol/): the control
- [`UXRadioGroup`](/compiler/api/uxkit/uxradiogroup/): the same
  one-of-several idea as separate controls
- [`UXPopUpItem`](/compiler/api/uxkit/uxpopupitem/): one-of-many when there is
  no room for a row
