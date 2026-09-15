---
title: UXJSON
description: "A small JSON parser and serializer: text to a value tree and back, with integer numbers and an exact round trip. NSJSONSerialization in shape."
---

`UXJSON` parses JSON text into a tree of
[`UXJSONValue`](/compiler/api/uxkit/uxjsonvalue/) and writes it back out.

Use it to read and write settings, config and simple data interchange. It
pairs with [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/), which
holds the same data without the file.

```c
#use <UXKit>            // or #import "UXJSON.xc"
```

## Overview

```c
UXJSONValue* doc = UXJSON.parse(text);
if (doc == (UXJSONValue*)0) { /* malformed */ }

doc.get((u8*)"title").asString();     // "Rocks"
doc.get((u8*)"zoom").asInt();         // 150
doc.get((u8*)"grid").asBool();        // true

UXJSONValue* origin = doc.get((u8*)"origin");
origin.at(0).asInt();                 // 10

u8* out = UXJSON.serialize(doc);
```

The parser is recursive descent; the serialiser makes two passes (measure, then
fill). Both are static. The instance fields are the parser's own cursor and are
not part of the interface.

## Failure is null, not a partial tree

```c
UXJSON.parse((u8*)"{\"a\":");      // 0
```

A malformed document returns **null**, not the part parsed before the error.
A half-read config is more dangerous than no config, because it looks as if it
loaded.

There is no error position. If you need to tell the user *where* the file is
broken, use a different parser. To decide whether a file is usable, one null
check is enough.

## Strings round-trip exactly

Text that contains JSON's own delimiters is the case most likely to go
untested:

```c
UXJSONValue* v = UXJSON.parse((u8*)"{\"say\":\"he said \\\"hi\\\"\"}");
v.get((u8*)"say").asString();     // he said "hi"     — unescaped in the tree
UXJSON.serialize(v);              // {"say":"he said \"hi\""}   — escaped again
```

Values in the tree are **plain text**, with the escapes removed. `serialize`
puts them back, so parse → serialize → parse is a fixed point and the output is
always valid JSON, quotes and backslashes included.

Object **keys** are escaped the same way, so a key containing a quote emits and
re-reads correctly.

The escapes handled in both directions are `\"` `\\` `\/` `\n` `\t` `\r` `\b`
`\f`.

:::caution[`\uXXXX` is not decoded]
A `\u0041` escape is not turned into `A`. The backslash is dropped and the rest
is taken literally, giving `u0041`.

UTF-8 bytes pass through untouched, so text *written* as UTF-8 (rather than as
`\u` escapes) works end to end. JSON from encoders that escape non-ASCII
characters does not read correctly.
:::

## Numbers are integers

```c
UXJSON.parse((u8*)"{\"a\":3.7,\"b\":-3.7}");
// a.asInt() == 3, b.asInt() == -3        — truncated toward zero
UXJSON.serialize(...);                    // {"a":3,"b":-3}
```

A fractional part is **parsed and discarded**, not rejected. A document with
decimals loads and loses its decimals. The round trip is lossy for those values
and exact for everything else.

The `i32` model covers sizes, counts, coordinates, flags and enumerations,
which is what a UI toolkit's config contains.

:::caution[Exponent notation is refused]
`1e3` does not parse, and the whole document comes back null. The number
scanner stops at the `e` and the structure check then fails.

`1e3` is valid JSON that some encoders emit for large round numbers, and the
failure affects the whole document, not only that value.
:::

## Topics

[parse](#parse) · [serialize](#serialize) · [streq](#streq) · [slen](#slen) · [dup](#dup)

### parse

```c
static UXJSONValue* parse(u8* s)
```

Text to a tree, or **null** if the document is malformed. The input is copied
into the tree, so `s` can be freed afterwards.

### serialize

```c
static u8* serialize(UXJSONValue* v)
```

A tree to text, in a fresh buffer. The output is compact, with no whitespace
and no indentation, which suits a config file written by a program.

Two passes: `measure` computes the length including escapes, then `fill`
writes it. The two must agree, so [the gate](#gate) asserts round trips over
text full of delimiters.

A null value serialises as `null` rather than crashing, so a partially built
tree still writes.

### streq

```c
static bool streq(u8* a, u8* b)
```

Content comparison, used for key lookup. It is public because code that walks
the value tree usually needs it too.

### slen

```c
static i32 slen(u8* s)
```

Byte length, null-safe.

### dup

```c
static u8* dup(u8* s, i32 start, i32 len)
```

A fresh copy of a range.

## Example

```
title=Rocks zoom=150 grid=1
origin count=2 [10,20]
has(title)=1 has(nope)=0 get(nope)=0
re-serialised: {"title":"Rocks","zoom":150,"grid":true,"origin":[10,20],"font":null}
awkward: {"say":"he said \"hi\"","path":"C:\\Users","two":"a\nb"}
stable:  {"say":"he said \"hi\"","path":"C:\\Users","two":"a\nb"}
say is really: [he said "hi"]
3.7 -> 3   -3.7 -> -3   reserialised: {"a":3,"b":-3}
bad input: 0   exponent: 0
```

The program is `website/site/examples/uxkit/data.xc`. The `doc-examples` gate
compiles it, and the listing above is its output.

## Gate

`run_json_csv.sh` asserts the escaping in both directions, the fixed-point round
trip, escaped keys, and each documented limit above, so the docs stay in step
with the code. It runs with `MallocScribble=1`, because a two-pass serializer
that under-measures its buffer can otherwise pass by luck.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXJSONValue`](/compiler/api/uxkit/uxjsonvalue/): a node in the tree
- [`UXCSV`](/compiler/api/uxkit/uxcsv/): the tabular counterpart
- [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/): settings without a
  file format
