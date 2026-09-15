---
title: UXPathComp
description: "One component of a path: a single directory or file name, boxed so it can live in an Array."
---

`UXPathComp` is one segment of a [`UXPath`](/compiler/api/uxkit/uxpath/): a
single directory or file name, with no separators.

```c
#use <UXKit>            // or #import "UXPath.xc"
```

## Overview

```c
class UXPathComp : Object {
    u8* s;      // the name, NUL-terminated, no '/'
}
```

The class has one field.

## Why it exists at all

`UXPath` keeps its components in an [`Array`](/compiler/api/array/), and an
`Array` holds [`Object`](/compiler/api/object/)s, so a bare `u8*` cannot go in
one. `UXPathComp` is the **box** that lets a C string live in a collection.

[`UXStrItem`](/compiler/api/uxkit/uxstritem/) and
[`UXKVEntry`](/compiler/api/uxkit/uxkventry/) exist for the same reason. Boxing
is explicit, so the wrapper appears in the type and not only in the
implementation.

You rarely name it directly: `UXPath.component(i)` unwraps it and returns the
`u8*`.

```c
for (i32 i = 0; i < p.count(); i = i + 1) {
    Stdio.printf("  %s\n", p.component(i));      // no UXPathComp in sight
}
```

It matters for the breadcrumb bar. A path bar shows a normalized path's
components, one control per box, and each crumb needs something with identity
to hang a target/action on.

## The name is a plain pointer

```c
u8* s
```

`s` is **not owned** in any managed sense. It is a raw pointer, and whoever
allocated it decides who frees it. In practice `UXPath` always gives it bytes it
allocated itself ([`parse`](/compiler/api/uxkit/uxpath/#parse) and
[`appendingComponent`](/compiler/api/uxkit/uxpath/#appendingcomponent) both
copy), so the component owns its name for as long as the path lives.

The exception is [`UXPath.copy`](/compiler/api/uxkit/uxpath/#copy), which makes
new boxes that **share** the original's buffers. Nothing in the toolkit writes
through a component pointer, so the sharing is invisible. Do not write through
one yourself.

`init` sets `s` to `""` instead of null, so a new component is safe to print
before it is filled in.

## Fields

### s

```c
u8* s
```

The component name. No separators, never null after `init`.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXPath`](/compiler/api/uxkit/uxpath/): the path these make up
- [`UXStrItem`](/compiler/api/uxkit/uxstritem/): the same boxing for a
  general string list
