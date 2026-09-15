---
title: UXCharAttr
description: "One character's style (bold, italic, colour pen and point size), the value type the attributed-text model is built on."
---

`UXCharAttr` is the style of a single character: four fields, and the equality
test that makes runs possible.

```c
#use <UXKit>            // or #import "UXAttributedString.xc"
```

## Overview

```c
class UXCharAttr : Object {
    bool bold;
    bool italic;
    i32  pen;      // colour pen; 1 = ink, the default
    i16  size;     // point size; 0 = the view's default
}
```

[`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/) keeps **one of
these per character**. This costs memory, and it makes setting and querying a
style trivially correct: there is no run list to split, merge or keep in order.

The runs a drawing pass wants are [derived on
demand](/compiler/api/uxkit/uxattributedstring/) by coalescing neighbours that
compare equal.

## `sameAs` is what makes a run

```c
bool sameAs(UXCharAttr* o)
```

Compares all four fields by value. This is the coalescing rule: two adjacent
characters belong to the same run when their attributes are `sameAs` each
other.

Adding a field to this class therefore changes what counts as a run, in one
place. If you add a field and do not compare it in `sameAs`, spans that should
draw differently are silently merged. Change the two together.

## `dup` is what keeps runs independent

```c
UXCharAttr* dup(void)
```

A run carries a **copy** of the attributes, not a pointer into the string's
per-character array. A run you hold stays valid and unchanged if the string is
restyled underneath you.

Writing to a run's `attr` changes nothing in the string. To restyle, use the
string's `setBold`/`setItalic`/`setColor`/`setSize`.

## The defaults are meaningful

```c
pen  = 1     // ink
size = 0     // "whatever the view is using"
```

`size == 0` means **unset**, not a zero-point font. The drawing code falls back
to the view's font. This lets you colour a span without fixing its size, which
matters when the same text is drawn at two zoom levels.

`pen == 1` is ink. Pen `0` is the background in the GEM model these pens come
from, so a default-constructed attribute is *visible*.

:::note[Out-of-range queries return a default, not null]
[`attributesAt`](/compiler/api/uxkit/uxattributedstring/) returns a fresh
default `UXCharAttr` for an index outside the string, so reading is always safe
and needs no guard.

**Writing** through an out-of-range query is silently discarded:
`a.attributesAt(999).bold = true` sets a field on a temporary. Use the range
setters, which clamp.
:::

## Fields

### bold

```c
bool bold
```

### italic

```c
bool italic
```

The two combine freely. A character can be both, which is a third distinct run
style.

### pen

```c
i32 pen         // 1 = ink
```

A colour **pen index**, not an RGB value. The indirection lets the same model
drive a 16-colour GEM palette and a true-colour backend.

### size

```c
i16 size        // 0 = inherit
```

Point size, or `0` to inherit.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXAttributedString`](/compiler/api/uxkit/uxattributedstring/): the text
  these attach to
- [`UXAttrRun`](/compiler/api/uxkit/uxattrrun/): a span sharing one of these
- [`UXTextRun`](/compiler/api/uxkit/uxtextrun/): the same style, positioned for
  drawing
