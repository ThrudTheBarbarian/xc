---
title: UXColorEntry
description: "One named colour in a theme: the indirection that lets a widget ask for 'windowBackground' instead of a pen number."
---

`UXColorEntry` is one name/colour pair in a
[`UXColorList`](/compiler/api/uxkit/uxcolorlist/).

```c
#use <UXKit>            // or #import "UXColorList.xc"
```

## Overview

```c
class UXColorEntry : Object {
    u8*      name;      // "windowBackground", "accent", "text"
    UXColor* color;
}
```

## The name is the point

A widget that hardcodes a pen number cannot be re-themed. A widget that asks for
`"windowBackground"` gets whatever the current theme says, and swapping the
theme restyles the whole interface without touching any control.

This two-field class provides that **indirection**.

The names in the default theme are semantic: they describe what the colour is
*for*, not what it looks like. `"text"` is used instead of `"black"`, so a dark
theme can make it white and every label follows.

## Overriding is adding

An application customises a theme by setting a name that already exists. There
is no separate "override" concept: any lookup finds the entry for that name, so
replacing the entry is the mechanism.

An application can also invent names of its own and keep them in the same list
as the standard ones. A `"gridLine"` entry is no different in kind from
`"accent"`; only the default theme's own entries are shipped.

## The colour is shared, not copied

```c
UXColor* color
```

The entry holds the pointer it was given.
[`UXColor`](/compiler/api/uxkit/uxcolor/) is treated as immutable throughout
the toolkit (`lightened`, `darkened` and `blend` all return new colours), so
several entries can share one colour and a control can keep what it looked up.

Mutating a colour's fields in place would change every entry that refers to it.
No toolkit code does this.

## Fields

### name

```c
u8* name
```

Compared by content, so a name built at run time matches a literal. **Kept, not
copied**: pass a literal or a [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

### color

```c
UXColor* color
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXColorList`](/compiler/api/uxkit/uxcolorlist/): the theme these make up
- [`UXColor`](/compiler/api/uxkit/uxcolor/): the colour itself
- [`UXGradientStop`](/compiler/api/uxkit/uxgradientstop/): a colour at a
  position, where this is a colour with a name
