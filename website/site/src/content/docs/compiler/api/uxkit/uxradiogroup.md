---
title: UXRadioGroup
description: "The exclusion set: the object that makes a handful of radio buttons behave as one choice, and the only thing that knows they are related."
---

`UXRadioGroup` makes several
[`UXRadioButton`](/compiler/api/uxkit/uxradiobutton/)s mutually exclusive.

```c
#use <UXKit>            // or #import "UXControl.xc"
```

## Overview

```c
UXRadioGroup* g = new UXRadioGroup();
g.add(small);
g.add(medium);
g.add(large);

g.select(medium);
g.selected();            // medium
```

The whole concept of "one of these" is these three methods.

## Grouping is by membership, not by layout

A radio button's exclusivity does not come from its position on screen, a common
parent view, or a shared tag. It comes from **being in a group**.

The alternatives break in a real window. If grouping were positional, two
unrelated sets of radio buttons in the same box would exclude each other. If
grouping were by parent, a set split across two columns would stop working.

`add` sets the button's `group` back-pointer, so the relationship is established
once, from one side, and both halves know about it.

## Selecting is the group's job

```c
void select(UXRadioButton* chosen)
```

`select` walks the members and sets each one's state: the chosen button on,
every other off. That single pass is the exclusivity. No rule is enforced
elsewhere, and no invariant is maintained between calls.

This has a consequence:

:::caution[Setting a button's state directly bypasses the group]
Calling `setSelected(true)` on a member marks that button without clearing its
siblings, so two can be lit at once. The group does not notice, because nothing
is watching.

Go through `select`. Reading a button's state directly is fine; only writing
skips the rule.

[`UXSegment.selected`](/compiler/api/uxkit/uxsegment/#selected-is-a-field-not-a-command)
works the same way: the field is state, and the container applies the policy.
:::

## `selected()` scans

```c
UXRadioButton* selected(void)
```

It returns the first member that is on, or **null** when nothing has been chosen
yet. A validator can test for that null.

Because it scans rather than caching, it stays accurate after a state has been
set directly: it reports what is lit, not what the group last decided.

A group with two lit members returns the first. This is how the bypass above
shows up.

## Members are held strongly

```c
Array* buttons
```

The group keeps its buttons alive, and each button holds the group. That is a
bounded **cycle**: both are released together when the window that owns them
goes.

If a group outlives its buttons for some other reason, the buttons are not
collected while the group holds them.

## Topics

[add](#add) · [select](#select) · [selected](#selected)

### add

```c
void add(UXRadioButton* b)
```

Join the group, and set the button's back-pointer to it.

There is no `remove`. A button belongs to a group for as long as both exist,
which matches the lifetime of a radio set.

### select

```c
void select(UXRadioButton* chosen)
```

Turn `chosen` on and everything else off.

Passing a button that is **not** a member turns every member off. That clears the
group, which is useful when intended and a surprise when not.

### selected

```c
UXRadioButton* selected(void)
```

The lit member, or null.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXRadioButton`](/compiler/api/uxkit/uxradiobutton/): the member
- [`UXSegmentedControl`](/compiler/api/uxkit/uxsegmentedcontrol/): the same
  one-of-many choice as a single control
- [`UXPopUpButton`](/compiler/api/uxkit/uxpopupbutton/): one-of-many when there
  is no room to show them all
