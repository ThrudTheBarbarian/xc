---
title: JSON
description: "JSON text to Foundation objects and back: Map, Array, String, Number and Null, with exact numbers and compact or indented output."
---

`JSON` reads JSON text into Foundation objects and writes them back
(`NSJSONSerialization` in shape). Objects become a [`Map`](/compiler/api/map/),
arrays an [`Array`](/compiler/api/array/), and the scalars a
[`String`](/compiler/api/string/), a [`Number`](/compiler/api/number/) or
[`Null`](/compiler/api/null/). **From 0.72.**

```c
#import "JSON.xc"          // not in the Foundation umbrella: import it by name
```

## Overview

```c
try
    {
    Map* m = (Map*)JSON.parse(String.withCString("{\"name\":\"xc\",\"tags\":[1,2.5,true,null]}"));
    String* name = (String*)m.get(String.withCString("name"));
    Stdio.printf("%s\n", JSON.stringify(m).cString());   // {"name":"xc","tags":[1,2.5,true,null]}
    }
catch (JSONError e)
    {
    Stdio.printf("%s\n", e.message().cString());        // bad JSON at byte 12: …
    }
```

| JSON | Foundation |
|---|---|
| object | `Map` with `String` keys, in the order the text has them |
| array | `Array` |
| string | `String`, UTF-8, with `\u` escapes and surrogate pairs decoded |
| number | `Number`: an int when written without `.` or an exponent and it fits 64 bits, otherwise a double |
| `true` / `false` | [`Number.withBool`](/compiler/api/number/#withbool) |
| `null` | [`Null.null()`](/compiler/api/null/) |

**Numbers are exact both ways.** An integer keeps all 64 bits. A double is read
correctly rounded and written in the shortest form that reads back as the same
bits, always with a `.` or an exponent (`3.0`, `1.0e+300`), so it reads back as
a double.

**Objects** keep their keys in the order the text has them, so a parse and a
write give the members back in the same order. A key that appears twice keeps
its last value. Nesting deeper than 256 is refused.

:::note[Availability]
Every target except xt6502. [`Coder`](/compiler/api/coder/) reads its archives
with the same parser.
:::

## Topics

**Reading** · [parse](#parse) · [parseData](#parsedata)

**Writing** · [stringify](#stringify) · [stringifyPretty](#stringifypretty) · [data](#data)

**Errors** · [JSONError](#jsonerror)

---

## Reading

### parse
```c
static Object* parse(String* text) throws
```
The value `text` holds: a `Map`, `Array`, `String`, `Number` or `Null`. Any value
may be the root, so `"42"` parses to a `Number`. Throws a
[`JSONError`](#jsonerror) for text that is not one complete JSON value.

### parseData
```c
static Object* parseData(Data* data) throws
```
The same, from UTF-8 bytes.

[↑ Topics](#topics)

## Writing

The writers accept the classes above, and write a null reference as `null`.
They throw a [`JSONError`](#jsonerror) for anything else: another class, a `Map`
key that is not a `String`, a NaN or infinite double (JSON has no spelling for
them), or a `String` that is not valid UTF-8.

### stringify
```c
static String* stringify(Object* v) throws
```
`v` as compact JSON: no spaces or newlines.

### stringifyPretty
```c
static String* stringifyPretty(Object* v) throws
```
`v` as indented JSON: two spaces a level, `"key": value`, one member or element a
line, empty containers as `{}` and `[]`, and a final newline.

```json
{
  "a": [
    1,
    2
  ],
  "b": {}
}
```

### data
```c
static Data* data(Object* v) throws
```
The compact text as UTF-8 bytes.

[↑ Topics](#topics)

## Errors

### JSONError
```c
class JSONError <Error>
String* message(void)
```
What the methods throw. A parse error gives the byte offset where reading
stopped, as in `bad JSON at byte 4: unterminated array`; a write error names
what could not be written, as in `JSON: a Set cannot be written as JSON`.

[↑ Topics](#topics)
