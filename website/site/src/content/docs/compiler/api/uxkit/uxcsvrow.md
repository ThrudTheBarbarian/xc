---
title: UXCSVRow
description: "One row of a CSV table: an ordered list of string fields, with the unwrapping done for you."
---

`UXCSVRow` is one line of a [`UXCSV`](/compiler/api/uxkit/uxcsv/) table: an
ordered list of fields, already unquoted.

```c
#use <UXKit>            // or #import "UXCSV.xc"
```

## Overview

```c
class UXCSVRow : Object {
    Array<UXCSVField>* fields;
}

row.count();            // how many fields
row.field(1);           // the field's text, unwrapped
row.add((u8*)"hello");  // append, boxing for you
```

With these three methods you never need to name
[`UXCSVField`](/compiler/api/uxkit/uxcsvfield/): `field` unwraps and `add`
boxes.

## Reading one

```c
for (u16 r = 0; r < rows.count(); r = r + 1) {
    UXCSVRow* row = (UXCSVRow* ?)rows.get(r);
    for (i32 c = 0; c < row.count(); c = c + 1) {
        Stdio.printf(" [%s]", row.field(c));
    }
}
```

Fields are in **file order**, and the text is what the field meant: quotes
stripped, doubled quotes collapsed, embedded newlines intact.

:::caution[Check `count()` before indexing a column]
Rows in a CSV file are not guaranteed to be the same length, and `UXCSV` does
not pad them. `field(3)` on a two-field row indexes past the end of the array
and faults inside the cast.

If your code assumes a rectangle, test `row.count()` once per row and decide
what a short row means: skip it, or treat the missing columns as empty. The
parser cannot choose that for you.
:::

## Building one to write

```c
UXCSVRow* r = new UXCSVRow();
r.add((u8*)"greeting");
r.add((u8*)"hello, world");      // no quoting needed here
rows.add(r);
```

Add the field's real text, not a pre-quoted version.
[`serialize`](/compiler/api/uxkit/uxcsv/#serialize) decides what needs quoting
and quotes it. If you quote it yourself, the file gets `"""hello, world"""`,
with the quotes as data.

Inside the toolkit, text is plain. The format's syntax exists only in the
serialised bytes. The same rule applies to
[`UXJSONValue.str`](/compiler/api/uxkit/uxjsonvalue/#strings-are-unescaped).

## Topics

[count](#count) · [field](#field) · [add](#add)

### count

```c
i32 count(void)
```

Fields in this row. `0` is possible: a blank line parses as a row with one
empty field, but a row you built and never added to has none.

### field

```c
u8* field(i32 i)
```

One field's text, unwrapped from its
[`UXCSVField`](/compiler/api/uxkit/uxcsvfield/) box. No bounds check.

### add

```c
void add(u8* s)
```

Append a field, boxing the string.

:::note
The box **keeps the pointer**; it does not copy. Fields from
[`parse`](/compiler/api/uxkit/uxcsv/#parse) are freshly allocated and owned by
the row, but a string you add yourself must outlive the row. Use a literal, or a
copy made with [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup).
:::

## Fields

### fields

```c
Array<UXCSVField>* fields
```

The boxed fields, held strongly. Never null.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXCSV`](/compiler/api/uxkit/uxcsv/): parse and serialize
- [`UXCSVField`](/compiler/api/uxkit/uxcsvfield/): the box
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): displaying rows like these
