---
title: UXPasteboardEntry
description: "One representation on a pasteboard: a type identifier and the payload written for it."
---

`UXPasteboardEntry` is one type/payload pair held by a
[`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/).

```c
#use <UXKit>            // or #import "UXPasteboard.xc"
```

## Overview

```c
class UXPasteboardEntry : Object {
    u8* type;    // "public.utf8-plain-text", "public.file-url", your own UTI
    u8* data;    // the payload written for that type
}
```

## One entry per type is the whole idea

A pasteboard holds **one payload per type**, so a single copy can offer the same
thing several ways and a paste takes the richest form it understands.

```
copy a shape:
  "com.example.shape"       the real thing, exactly
  "public.utf8-plain-text"  "Rectangle 100x60"
```

Paste into your own canvas and you get the shape back. Paste into a text editor
and you get a sensible line of text. Neither side negotiates: the writer offers
what it can and the reader asks for what it wants.

Writing the same type twice **replaces** the payload. There are never two
payloads for one type, so "ask for this type" has one answer.

## Type strings are conventions, not an enum

The types are plain strings. The toolkit defines the common ones by convention
(`public.utf8-plain-text`, `public.file-url`), and an application adds its own
by picking a string nobody else will use, usually in reverse-DNS form.

Nothing registers a type and nothing validates one. Two programs interoperate by
agreeing on a string, as the platform pasteboards do.

`public.file-url` payloads are [`UXURL`](/compiler/api/uxkit/uxurl/) text, which
links `file:` URLs and [`UXPath`](/compiler/api/uxkit/uxpath/).

## Payloads are strings for now

```c
u8* data
```

Text, serialised structures and URLs all travel as strings. Raw bytes are not
supported yet.

Strings cover the current cases: a clipboard of text, a drag of file references,
an application's own model serialised as [JSON](/compiler/api/uxkit/uxjson/).
They also keep the pasteboard neutral across backends that disagree about binary
formats. If your payload is binary, encode it.

:::note[Both fields are kept, not copied]
The entry stores the pointers it was given. Duplicate a payload built in a
scratch buffer with [`UXStr.dup`](/compiler/api/uxkit/uxstr/#dup) before it goes
on the pasteboard, because the clipboard outlives the copy operation.
:::

## Fields

### type

```c
u8* type
```

The type identifier, compared by content.

### data

```c
u8* data
```

The payload.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/): the board, and its
  change count
- [`UXURL`](/compiler/api/uxkit/uxurl/): what a `public.file-url` payload holds
- [`UXJSON`](/compiler/api/uxkit/uxjson/): a reasonable way to serialise your
  own type
