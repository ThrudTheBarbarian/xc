---
title: UXCSVField
description: "One cell of a CSV table: a string in a box, holding the field's real text rather than its quoted form."
---

`UXCSVField` is one cell of a [`UXCSV`](/compiler/api/uxkit/uxcsv/) table.

```c
#use <UXKit>            // or #import "UXCSV.xc"
```

## Overview

```c
class UXCSVField : Object {
    u8* s;      // the field's text, unquoted
}
```

It is boxed because [`Array`](/compiler/api/array/) holds
[`Object`](/compiler/api/object/)s and a bare `u8*` is not one. The same reason
applies to [`UXStrItem`](/compiler/api/uxkit/uxstritem/) and
[`UXPathComp`](/compiler/api/uxkit/uxpathcomp/).

You seldom name it: [`UXCSVRow.field`](/compiler/api/uxkit/uxcsvrow/#field)
unwraps and [`UXCSVRow.add`](/compiler/api/uxkit/uxcsvrow/#add) boxes.

## `s` is the text, not the syntax

Get this right when building a table to write out.

```c
field.s;       // hello, world      — with a real comma in it
```

A field holds what the value **is**, never how CSV spells it. The quotes and the
doubled quotes exist only in the serialised bytes:

| in the file | `s` holds |
| --- | --- |
| `"hello, world"` | `hello, world` |
| `"say ""hi"""` | `say "hi"` |
| `plain` | `plain` |

[`serialize`](/compiler/api/uxkit/uxcsv/#serialize) adds quoting when the text
needs it, and [`parse`](/compiler/api/uxkit/uxcsv/#parse) removes it. Doing
either yourself double-encodes: a value you pre-quote comes out with its quotes
as data.

## `s` is a borrowed pointer

Assignment stores the pointer; nothing is copied and nothing is managed.

Fields produced by [`parse`](/compiler/api/uxkit/uxcsv/#parse) are freshly
allocated and belong to the row, so a parsed table owns its text. A field you
fill in yourself must point at something that outlives the row: a literal, or a
copy made with [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).

`init` sets `s` to `""` rather than null, so a fresh field is safe to serialise
before it is filled in. It produces an empty cell, not a crash.

## Fields

### s

```c
u8* s
```

The field's text. Never null after `init`.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXCSVRow`](/compiler/api/uxkit/uxcsvrow/): the row these sit in
- [`UXCSV`](/compiler/api/uxkit/uxcsv/): parse and serialize
- [`UXStrItem`](/compiler/api/uxkit/uxstritem/): the same boxing
