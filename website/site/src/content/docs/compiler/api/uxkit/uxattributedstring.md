---
title: UXAttributedString
description: "Text carrying per-character attributes, coalesced into runs on demand: bold, italic, colour pen and size over any range."
---

`UXAttributedString` is text plus a small attribute record for each character:
bold, italic, colour pen, point size. It has the shape of `NSAttributedString`,
and it is the model behind styled canvas text and a rich-text field.

```c
#use <UXKit>            // or #import "UXAttributedString.xc"
```

## Overview

```c
UXAttributedString* a = UXAttributedString.make((u8*)"hello brave world");
a.setBold(true, 6, 5);          // "brave"
```

### Stored per character, read as runs

The storage is **one attribute record per character**. Setting a style over a
range is a loop with no merging, and querying a character is a direct index.
There is no interval tree to keep balanced and no case where two adjacent spans
disagree about who owns a boundary.

Drawing needs **runs**, so it can stroke one styled span at a time. Runs are
*derived on demand* by coalescing equal neighbours:

```
plain:                  1 run   [0..16]
bold 6..10:             3 runs  [0..5] [6..10 B] [11..16]
+ italic 9..12:         5 runs  [0..5] [6..8 B] [9..10 B I] [11..12 I] [13..16]
```

Overlapping styles **split** runs where the styles differ, so you never compute
that boundary yourself. Because runs are derived, setting a style back to match
its neighbours **coalesces again** with no merge step:

```
all cleared:            1 run   [0..16]
```

The run list cannot drift out of step with the characters, because it is
recomputed from them.

## Topics

[make](#make) · [stringValue](#stringvalue) · [length](#length) · [attributesAt](#attributesat) · [setBold](#setbold) · [setItalic](#setitalic) · [setColor](#setcolor) · [setSize](#setsize) · [runs](#runs) · [runCount](#runcount)

### make

```c
static UXAttributedString* make(u8* s)
```

Wraps a string, giving every character default attributes. The text is not
copied.

### stringValue

```c
u8* stringValue(void)
```

The underlying characters.

:::note[Why not `string`]
`string` is a reserved word in xc, so the accessor is `stringValue`. For the
same reason `contains_` carries an underscore on
[`UXPredicate`](/compiler/api/uxkit/uxpredicate/).
:::

### length

```c
i32 length(void)
```

Character count.

### attributesAt

```c
UXCharAttr* attributesAt(i32 i)
```

The style of **one character**. Querying is always per character, whatever the
run structure, so a caret asking "am I inside bold text?" needs no run search.

### setBold

```c
void setBold(bool v, i32 start, i32 length)
```

### setItalic

```c
void setItalic(bool v, i32 start, i32 length)
```

### setColor

```c
void setColor(i32 pen, i32 start, i32 length)
```

A colour **pen**, not an RGB value. Pen 1 is ink. The model uses pens because it
is shared with backends whose text colour is an index into a palette, and
resolving a pen late lets a theme change without rewriting the string.

### setSize

```c
void setSize(i16 size, i32 start, i32 length)
```

Point size. `0` means the view's default, so a run that never had a size set
follows the view's size instead of pinning its own.

### Ranges are clamped

Every setter clamps `start` and `length` to the string:

```c
a.setItalic(true, 12, 999);     // harmless — applies to 12..end
```

An over-long span is not an error. These setters are usually driven by a
selection, and a selection that runs to the end of the text should not require
the caller to compute the remaining length.

### runs

```c
Array<UXAttrRun>* runs(void)
```

The coalesced runs, in order. Each is a
[`UXRange`](/compiler/api/uxkit/uxrange/) extended with its style:

```c
class UXAttrRun : UXRange {
    UXCharAttr* attr;
}
```

A run **is a range**, so there is no separate type that repeats `loc`/`len`
beside a payload. [`UXTextRun`](/compiler/api/uxkit/uxtextlayout/#uxtextrun)
follows the same pattern.

### runCount

```c
i32 runCount(void)
```

How many runs the current styling produces. Useful to assert in a test of
coalescing.

## UXCharAttr

```c
class UXCharAttr : Object {
    bool bold;
    bool italic;
    i32  pen;       // colour pen; 1 = ink
    i16  size;      // point size; 0 = the view's default
}
```

`dup()` copies one. `sameAs()` compares by value, and run coalescing tests
against it.

## Example

```c
UXAttributedString* a = UXAttributedString.make((u8*)"hello brave world");

a.setBold(true, 6, 5);        // 3 runs: [0..5] [6..10 B] [11..16]
a.setItalic(true, 9, 4);      // 5 runs: [0..5] [6..8 B] [9..10 B I] [11..12 I] [13..16]

a.setBold(false, 6, 5);
a.setItalic(false, 9, 4);     // 1 run again — coalesced, with no merge step

a.attributesAt(0).bold;       // per-character query, whatever the runs are
a.setItalic(true, 12, 999);   // clamped: applies to 12..end
```

The full program is `website/site/examples/uxkit/richtext.xc`. The
`doc-examples` gate compiles it, and the run listings above are its output.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXTextLayout`](/compiler/api/uxkit/uxtextlayout/): `wrapAttr` measures each
  run in its own font, so a bold word breaks where the eye expects
- [`UXRange`](/compiler/api/uxkit/uxrange/): what a run extends
- [`UXText`](/compiler/api/uxkit/uxtext/): the view that draws one
- [`UXFont`](/compiler/api/uxkit/uxfont/): the descriptor a size resolves
  against
