---
title: UXStr
description: "Concatenation and number conversion: the small amount of string work a UI toolkit needs, since xc's Stdio has no snprintf."
---

`UXStr` covers the minimum: joining two strings, and turning integers into text
and back.

Building a label, a status line or an alert body means concatenating and
formatting, and xc's `Stdio` has no `snprintf` to format *into* a buffer. Every
application would otherwise write this code, so it lives here.

```c
#use <UXKit>            // or #import "UXString.xc"
```

## Overview

```c
UXStr.append((u8*)"Zoom: ", UXStr.fromInt(150));    // "Zoom: 150"
UXStr.cat((u8*)"Ada", (u8)' ', (u8*)"Lovelace");    // "Ada Lovelace"
UXStr.toInt((u8*)"  -17px");                        // -17
UXStr.fromHex((u32)0xDEADBEEF);                     // "deadbeef"
```

All methods are static and return fresh buffers.

## `cat` skips the separator when the left side is empty

This rule is why the method has three arguments instead of two:

```c
u8* list = (u8*)"";
list = UXStr.cat(list, (u8)',', (u8*)"red");      // "red"       — no leading comma
list = UXStr.cat(list, (u8)',', (u8*)"green");    // "red,green"
list = UXStr.cat(list, (u8)',', (u8*)"blue");     // "red,green,blue"
```

Accumulating a separated list needs **no "is this the first one" test**, the
check that is easy to forget and that leaves a stray comma at the front. Start
from `""` and the first item gets no separator.

[`append`](#append) is `cat` with no separator, for building one string instead
of a list.

:::note[It joins two, not many]
There is no varargs form, so three pieces take two calls. For a list already in
an array, [`UXText.join`](/compiler/api/uxkit/uxtext/#join) is one call and one
allocation instead of N.
:::

## `toInt` is a reader, not a validator

```c
UXStr.toInt((u8*)"  -17px");    // -17   leading blanks, sign, digits, then stop
UXStr.toInt((u8*)"12.9");       // 12    stops at the dot
UXStr.toInt((u8*)"+8");         // 8     an explicit plus is allowed
UXStr.toInt((u8*)"abc");        // 0     no digits at all
UXStr.toInt((u8*)0);            // 0     null-safe
```

It reads what it can and stops at the first character that is not part of a
number.

:::caution[`0` does not mean "not a number"]
A value that is not numeric reads as `0`, and so does the string `"0"`. The
result cannot tell them apart.

This suits its job: a corrupted settings value should fall back, not abort.
For the same reason [`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/)
layers **registered defaults** on top instead of relying on the parse. When you
need to know whether the user typed a number, validate before converting.
:::

## Topics

[len](#len) · [cat](#cat) · [append](#append) · [dup](#dup) · [toInt](#toint) · [fromInt](#fromint) · [fromHex](#fromhex)

### len

```c
static u16 len(u8* s)
```

Byte length.

:::caution
Returns `u16`, not `i32`, and unlike
[`UXText.slen`](/compiler/api/uxkit/uxtext/#slen) it is **not null-safe**. It is
sized for labels and status lines, which is what this class is for.
:::

### cat

```c
static u8* cat(u8* a, u8 sep, u8* b)
```

`a` + `sep` + `b` in a fresh buffer. A `sep` of `0` means none, and the
separator is skipped when `a` is empty; see
[above](#cat-skips-the-separator-when-the-left-side-is-empty).

The separator is a single **byte**, so it is one character, not a string.

### append

```c
static u8* append(u8* a, u8* b)
```

[`cat`](#cat) with no separator.

### dup

```c
static u8* dup(u8* s)
```

A private copy.

Use it for a string that came out of a **shared scratch buffer** and must
outlive the next call that fills it.
[`UXKeyValueStore`](/compiler/api/uxkit/uxkeyvaluestore/) does this when it
reads a value out of the settings store. If you are holding onto a `u8*` that a
driver handed you, copy it.

### toInt

```c
static i32 toInt(u8* s)
```

Leading blanks, one optional sign, then digits, stopping at the first character
that is none of these. Null-safe, returning `0`.

It is a **reader, not a validator**: see
[above](#toint-is-a-reader-not-a-validator) for why `0` cannot be told apart
from "not a number", and why that suits a settings value.

### fromInt

```c
static u8* fromInt(i32 v)
```

Decimal, with a `-` for negatives. Handles `0` and the full 32-bit range.

### fromHex

```c
static u8* fromHex(u32 v)
```

Lowercase hex, with **no `0x` prefix** and no leading zeros: `255` is `"ff"`,
`0` is `"0"`. Add a prefix yourself if you want one. Without it the result
serves a colour literal, a byte dump and an address alike.

## Example

```
accumulated: red,green,blue
label: Zoom: 150%
fromInt: 0 -42 2147483647
fromHex: 0 ff deadbeef
toInt: '  -17px'=-17 'abc'=0 '12.9'=12 '+8'=8
```

The program is `website/site/examples/uxkit/strings.xc`; the `doc-examples`
gate compiles it, and the output above is its real output.

## UXStr or UXText?

Both do string work, split by weight:

| | |
| --- | --- |
| [`UXStr`](/compiler/api/uxkit/uxstr/) | joining two strings, numbers to and from text |
| [`UXText`](/compiler/api/uxkit/uxtext/) | trim, split, tokenize, join, case, search |

The toolkit itself uses `UXStr` to build labels, so it depends on almost
nothing. `UXText` is the fuller toolbox and pulls in
[`Array`](/compiler/api/array/) and
[`UXCharacterSet`](/compiler/api/uxkit/uxcharacterset/).

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass); all
  methods are static

## See also

- [`UXText`](/compiler/api/uxkit/uxtext/): the larger string toolbox
- [`UXNumberFormatter`](/compiler/api/uxkit/uxnumberformatter/): when a number
  needs grouping, decimals or a currency symbol
