---
title: UXCSV
description: "An RFC 4180-style CSV parser and serializer: quoted fields that may contain commas, quotes and newlines, quoted on output only when they need it."
---

`UXCSV` reads CSV text into rows of string fields and writes them back. It is
the tabular counterpart to [`UXJSON`](/compiler/api/uxkit/uxjson/): what a
multi-column list view loads and saves, and what a data import reads.

```c
#use <UXKit>            // or #import "UXCSV.xc"
```

## Overview

```c
Array<UXCSVRow>* rows = UXCSV.parse(text);

UXCSVRow* row = (UXCSVRow* ?)rows.get((u16)0);
row.count();           // fields in this row
row.field(1);          // one field, already unquoted

u8* out = UXCSV.serialize(rows);
```

Pure string work, with no file handling, no encoding conversion and no platform
code. Pass it text and it returns rows.

## Why not split on commas

A comma inside a quoted field is data, and
[`UXText.split`](/compiler/api/uxkit/uxtext/#split) cannot know that. `UXCSV`
handles the three things RFC 4180 allows a quoted field to contain:

```
a,"b,c","say ""hi""","two
lines"
```

| in the file | the field is |
| --- | --- |
| `"b,c"` | `b,c` — the comma is not a separator |
| `"say ""hi"""` | `say "hi"` — a doubled quote is one quote |
| `"two⏎lines"` | `two⏎lines` — the newline does not end the row |

Because of the last case, a CSV file cannot be read a line at a time, so this
parser takes the whole text rather than a line.

## Serialising quotes only what needs it

```c
key,value
greeting,"hello, world"
```

A field is quoted when it contains a comma, a quote, or a newline, and left
alone otherwise. Ordinary data stays readable in a text editor and awkward data
stays correct, with no switch to choose between them.

Round trips are exact: `parse` → `serialize` → `parse` is a fixed point,
including doubled quotes and embedded newlines.

## Empty fields are fields

```c
UXCSV.parse((u8*)"a,,c");       // three fields; the middle one is ""
```

This is the same rule as [`UXText.split`](/compiler/api/uxkit/uxtext/#split),
for the same reason: a blank cell is a cell, and a table with a missing value in
column 2 must not become a two-column table.

## Line endings

A row ends at `\n`, `\r`, or `\r\n`, so files with DOS or Unix line endings read
without conversion. Output always uses `\n`.

:::note[Rows may differ in length]
Nothing enforces a rectangle: a row with four fields and a row with two both
parse, and `count()` differs per row.

Ragged files exist, and refusing to read them would help nobody. A column index
is therefore not guaranteed to exist. Check `row.count()` before calling
`field(3)`, or the cast inside will fault on a short row.
:::

## What it does not do

- **No header row concept.** Row 0 is a row. If the first line is a header, that
  is your convention, not the parser's, so a headerless file reads too.
- **No type inference.** Every field is a string; `"3"` stays `"3"`. Use
  [`UXStr.toInt`](/compiler/api/uxkit/uxstr/#toint) where you want a number.
- **No encoding handling.** Bytes in, bytes out. UTF-8 passes through intact,
  since no byte of a multi-byte sequence can be mistaken for a comma or a quote.
- **No alternate delimiter.** Comma only. `;` and tab-separated files need a
  different reader.

## Topics

[parse](#parse) · [serialize](#serialize) · [needsQuote](#needsquote) · [slen](#slen) · [dup](#dup)

### parse

```c
static Array<UXCSVRow>* parse(u8* text)
```

Whole text to rows. Never fails: there is no malformed CSV, only CSV that means
something other than you intended. An unterminated quote runs to the end of the
text and becomes one long field.

### serialize

```c
static u8* serialize(Array<UXCSVRow>* rows)
```

Rows back to text, in a fresh buffer. Rows are separated by `\n`, with **no
trailing newline**, so text for another appended row needs its own separator.

It works in two passes: measure the exact length, including the quotes and the
doubling, then fill.

### needsQuote

```c
static bool needsQuote(u8* s)
```

Whether a field would be quoted on output: it contains a comma, a quote, `\n`
or `\r`. It is public because it also tests whether a value will survive being
written into a column.

### slen

```c
static i32 slen(u8* s)
```

### dup

```c
static u8* dup(u8* s, i32 start, i32 len)
```

## Example

```
csv rows=4
  row 0 fields=2: [name] [note]
  row 1 fields=2: [Rocks] [a, b]
  row 2 fields=2: [GEM] [say "hi"]
  row 3 fields=2: [Web] [two
lines]
csv out:
name,note
Rocks,"a, b"
GEM,"say ""hi"""
Web,"two
lines"
sparse fields=3 middle=[]
built:
key,value
greeting,"hello, world"
```

The program is `website/site/examples/uxkit/data.xc`. The `doc-examples` gate
compiles it, and the above is its real output.

## Gate

`run_json_csv.sh` asserts the quoted-comma, doubled-quote and embedded-newline
cases in both directions, that the round trip is a fixed point, and that empty
fields survive.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXCSVRow`](/compiler/api/uxkit/uxcsvrow/): one row
- [`UXCSVField`](/compiler/api/uxkit/uxcsvfield/): one field
- [`UXJSON`](/compiler/api/uxkit/uxjson/): the structured counterpart
- [`UXTableView`](/compiler/api/uxkit/uxtableview/): where these rows usually
  end up
