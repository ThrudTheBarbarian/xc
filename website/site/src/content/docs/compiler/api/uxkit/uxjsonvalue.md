---
title: UXJSONValue
description: "One node of a parsed JSON document (object, array, string, number, bool or null) and the accessors for reading it."
---

`UXJSONValue` is a node in the tree
[`UXJSON.parse`](/compiler/api/uxkit/uxjson/#parse) builds. One class covers all
six JSON types, with a `type` tag saying which.

```c
#use <UXKit>            // or #import "UXJSON.xc"
```

## Overview

```c
class UXJSONValue : Object {
    i32    type;      // JV_NULL JV_BOOL JV_NUM JV_STR JV_ARR JV_OBJ
    u8*    key;       // set when this node is a member of an object
    bool   b;
    i32    num;
    u8*    str;
    Array<UXJSONValue>* items;   // array elements, or object members
}
```

## One class, six types

The node is a tagged union rather than six classes. Each node carries a few
unused fields, and in exchange you can walk the tree without casting at every
step:

```c
UXJSONValue* v = doc.get((u8*)"zoom");
if (v.valueType() == JV_NUM) { zoom = v.asInt(); }
```

The type constants are `JV_NULL` `JV_BOOL` `JV_NUM` `JV_STR` `JV_ARR` `JV_OBJ`.

:::caution[The accessors do not check the type]
`asInt` on a string returns `0`, and `asString` on a number returns `""`: the
value of the field that was never filled in. There is no conversion and no
error.

This is fine for your own config, where you know the shape. When the document
comes from elsewhere, test [`valueType`](#valuetype) first. A silent `0` where
you expected a number is much harder to trace than a rejected file.
:::

## Objects and arrays share `items`

Both container types hold their children in the same array. An **object
member** has its `key` set; an array element does not.

```c
doc.get((u8*)"title");     // by key   — objects
origin.at(0);              // by index — arrays
doc.count();               // members or elements, either way
```

`at(i)` also works on an object and returns the i-th member in **document
order**. This is useful for writing the keys back out in the order they were
read, and it is why the order is preserved rather than sorted.

## A missing key is null

```c
doc.get((u8*)"nope");       // 0 — not a JV_NULL node
doc.has((u8*)"nope");       // false
```

JSON has its own `null`, and the two cases differ:

| | |
| --- | --- |
| `get` returns `0` | the key is **absent** |
| `get` returns a node with `type == JV_NULL` | the key is present, with the value `null` |

`has` distinguishes them. Use it as the guard before dereferencing.

Lookup is a **linear scan** over the members, so reading a large object in a
loop is quadratic. Document-sized objects are fine. To read thousands of keys,
move them into a [`UXCache`](/compiler/api/uxkit/uxcache/) or a plain array
once.

## Strings are unescaped

`str` holds the **decoded** text: `\"` has already become `"`. Escaping happens
only at [`serialize`](/compiler/api/uxkit/uxjson/#serialize) time, so what you
read is what the document meant, and what you write is escaped for you.

You can assign any text to `str` directly, including quotes, backslashes and
newlines. It is escaped correctly on output.

## Topics

[valueType](#valuetype) · [asInt](#asint) · [asBool](#asbool) · [asString](#asstring) · [count](#count) · [at](#at) · [get](#get) · [has](#has)

### valueType

```c
i32 valueType(void)
```

Which of the six. Compare against `JV_*`.

### asInt

```c
i32 asInt(void)
```

The number. `0` for any other type; see the
[caution](#one-class-six-types).

### asBool

```c
bool asBool(void)
```

### asString

```c
u8* asString(void)
```

Decoded text. `""` rather than null for a non-string, so printing is always
safe.

### count

```c
i32 count(void)
```

Children: array elements or object members. `0` for a scalar.

### at

```c
UXJSONValue* at(i32 i)
```

The i-th child, in document order.

### get

```c
UXJSONValue* get(u8* k)
```

An object member by key, or **null** if absent. Keys compare by content.

### has

```c
bool has(u8* k)
```

Whether the key is present, including when its value is JSON `null`.

## Fields

### key

```c
u8* key      // null unless this node is an object member
```

Set by the parser, and used by
[`serialize`](/compiler/api/uxkit/uxjson/#serialize) to write the member name.
A node built by hand and added to an object needs its `key` set, or it
serialises with an empty name.

### items

```c
Array<UXJSONValue>* items
```

Children, held strongly. Never null: an empty object or array has an empty
array, so a walk needs no guard.

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXJSON`](/compiler/api/uxkit/uxjson/): parse and serialize
- [`UXCSVRow`](/compiler/api/uxkit/uxcsvrow/): the tabular equivalent of a
  container node
