---
title: UXStrItem
description: "A string in a box, so it can live in an Array. split returns these and join consumes them."
---

`UXStrItem` is one string, boxed so it can go in a collection.

```c
#use <UXKit>            // or #import "UXText.xc"
```

## Overview

```c
class UXStrItem : Object {
    u8* s;      // the string, NUL-terminated
}
```

The class has one field.

## Why it exists

[`Array`](/compiler/api/array/) holds [`Object`](/compiler/api/object/)s, and a
bare `u8*` is not one, so a list of strings needs a wrapper. `UXStrItem` is that
wrapper.

[`UXPathComp`](/compiler/api/uxkit/uxpathcomp/) and
[`UXKVEntry`](/compiler/api/uxkit/uxkventry/) exist for the same reason. Boxing
is explicit in xc, not automatic, so the wrapper appears in signatures:

```c
static Array<UXStrItem>* split(u8* s, u8 delim)
```

## You mostly do not touch it

[`UXText.partAt`](/compiler/api/uxkit/uxtext/#partat) unwraps for you, so the
common loop never names the type:

```c
Array<UXStrItem>* parts = UXText.split(line, (u8)',');
for (i32 i = 0; i < (i32)parts.count(); i = i + 1) {
    Stdio.printf("  [%s]\n", UXText.partAt(parts, i));
}
```

[`UXText.join`](/compiler/api/uxkit/uxtext/#join) takes the whole array back,
so a split → filter → join never builds one by hand.

## Building one yourself

Two cases need it: making a list to hand to `join`, and holding strings that did
not come from a split.

```c
Array<UXStrItem>* items = new Array();
UXStrItem* it = new UXStrItem();
it.s = UXStr.dup(name);          // copy if `name` is borrowed
items.add(it);
```

:::caution[`s` is a plain pointer: assignment does not copy]
Setting `s` stores the pointer you give it. It is not managed, retained or
duplicated.

Everything in [`UXText`](/compiler/api/uxkit/uxtext/) gives the box bytes it
allocated itself, so a split result owns its strings for as long as the array
lives. If you assign a string that belongs to something else, such as a scratch
buffer or a value from a driver, copy it first with
[`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).
:::

`init` sets `s` to `""`, not null, so a new item is safe to print before it is
filled in. [`join`](/compiler/api/uxkit/uxtext/#join) relies on this because it
walks every element.

## Fields

### s

```c
u8* s
```

The string. Never null after `init`.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXText`](/compiler/api/uxkit/uxtext/): split, join, and everything else
  that produces or consumes these
- [`UXStr`](/compiler/api/uxkit/uxstr/): `dup`, for when the string is borrowed
- [`UXPathComp`](/compiler/api/uxkit/uxpathcomp/): the same boxing for a path
  component
