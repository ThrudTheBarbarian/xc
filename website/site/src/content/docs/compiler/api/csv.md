---
title: CSV
description: "Comma-separated values to rows of strings and back (RFC 4180): quoted fields, any separator, records keyed by the header row."
---

`CSV` reads comma-separated text into rows of strings and writes rows back
(RFC 4180). A row is an [`Array`](/compiler/api/array/) of
[`String`](/compiler/api/string/) fields, and the text is an `Array` of rows.
**From 0.72.**

```c
#import "CSV.xc"           // not in the Foundation umbrella: import it by name
```

## Overview

```c
try
    {
    Array* rows = CSV.parse(String.withCString("name,qty\r\n\"Smith, J\",3\r\n"));
    Array* first = (Array*)rows.get(1);          // ["Smith, J", "3"]
    Stdio.printf("%s", CSV.stringify(rows).cString());
    }
catch (CSVError e)
    {
    Stdio.printf("%s\n", e.message().cString());
    }
```

**Reading.** A field in double quotes may hold the separator, line breaks and
`""` for one quote; any other field is taken as it stands, spaces included.
Lines end in `\r\n`, `\n` or `\r`. A final line break does not start another
row, and an empty text has no rows. Rows may have different numbers of fields:
the parser does not make them equal.

**Writing** quotes a field only when it holds the separator, a quote, `\r` or
`\n`, doubles its quotes, and ends every row with `\n`. A field may be any
object: a `String` as it is, a null reference or [`Null`](/compiler/api/null/)
as an empty field, anything else as its `description`.

:::note[Availability]
Every heap-capable target, the 6502 included, where lengths and indexes are
`u16`.
:::

## Topics

**Reading** · [parse](#parse) · [parseWith](#parsewith) · [records](#records)

**Writing** · [stringify](#stringify) · [stringifyWith](#stringifywith)

**Errors** · [CSVError](#csverror)

---

## Reading

### parse
```c
static Array* parse(String* text) throws
```
The rows of comma-separated `text`.

### parseWith
```c
static Array* parseWith(String* text, u8 sep) throws
```
The rows of `text` with another separator: `(u8)'\t'` for tab-separated values,
`(u8)';'` for the form many European spreadsheets write.

### records
```c
static Array* records(Array* rows)
```
One [`Map`](/compiler/api/map/) per row after the first, from each header field
to the field under it. A short row's missing fields are empty strings, fields
past the header's are dropped, and a header name that repeats keeps its last
column.

```c
Array* people = CSV.records(CSV.parse(text));
String* name = (String*)((Map*)people.get(0)).get(String.withCString("name"));
```

[↑ Topics](#topics)

## Writing

### stringify
```c
static String* stringify(Array* rows)
```
`rows` as comma-separated text.

### stringifyWith
```c
static String* stringifyWith(Array* rows, u8 sep)
```
The same with another separator.

[↑ Topics](#topics)

## Errors

### CSVError
```c
class CSVError <Error>
String* message(void)
```
What [`parse`](#parse) and [`parseWith`](#parsewith) throw: for a quoted field
that is never closed, or one followed by anything but the separator or a line
break. The message gives the byte offset, as in
`bad CSV at byte 2: a quoted field is never closed`.

[↑ Topics](#topics)
