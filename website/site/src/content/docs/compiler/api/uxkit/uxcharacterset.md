---
title: UXCharacterSet
description: "A set of bytes with an inverted flag, so 'everything except these' costs nothing, and trimming or tokenizing takes the delimiters as a parameter."
---

`UXCharacterSet` is a set of character codes over the byte range `0`–`255`,
with the shape of `NSCharacterSet`.

```c
#use <UXKit>            // or #import "UXCharacterSet.xc"
```

## Overview

```c
UXText.trim(s, UXCharacterSet.whitespaceAndNewlines());
UXText.tokenize(line, UXCharacterSet.whitespace());

UXCharacterSet* quotes = new UXCharacterSet();
quotes.addString((u8*)"\"'");
UXText.trim((u8*)"\"quoted\"", quotes);       // quoted
```

It lets trimming, tokenizing and validation take their delimiters as a
**parameter** instead of hard-coding whitespace. One `trim` can then strip
quotes, brackets, or whatever delimiters the format uses.

## Built on UXIndexSet

A byte is an index, so the storage is a
[`UXIndexSet`](/compiler/api/uxkit/uxindexset/), the same run-coalescing
structure a table view uses for selected rows.

`a-z` is **one run**, not 26 entries, and `alphanumerics()` is three runs
however many characters it names. Membership is a search over runs.

[`UXCharClass`](/compiler/api/uxkit/uxcharclass/), the regex engine's bracket
expression, uses the same storage. The two classes are different vocabularies
over one set implementation.

## Inversion is a flag

```c
UXCharacterSet* notDigits = UXCharacterSet.decimalDigits().inverted();
```

`inverted()` does not enumerate the complement. It sets a flag that flips the
answer from [`contains`](#contains).

Storing the complement would mean listing every code that is *not* a digit,
which is most of them and needs an upper bound. The flag costs nothing, so
"everything except these" is as cheap as the original set.

## The standard sets

```c
UXCharacterSet.whitespace()              // space and tab
UXCharacterSet.whitespaceAndNewlines()   // plus CR and LF
UXCharacterSet.decimalDigits()           // 0-9
UXCharacterSet.letters()                 // A-Z a-z
UXCharacterSet.alphanumerics()           // letters + digits
UXCharacterSet.punctuation()
```

Each returns a **fresh set**, so modifying one does not affect the next caller.
`UXCharacterSet.whitespace().addChar(',')` changes a local throwaway, not a
global set.

:::caution[ASCII only, and that is the byte range]
The set covers `0`–`255`, and the standard sets name ASCII codes. There is no
Unicode category and no notion of a letter outside A–Z.

Because the range is **bytes**, a multi-byte UTF-8 character is not a member of
any standard set: each of its bytes is ≥ 0x80. `tokenize` on UTF-8 text
therefore splits on ASCII delimiters and leaves multi-byte characters intact,
but "is this a letter" is answered for ASCII only.
:::

## Topics

[addChar](#addchar) · [addRange](#addrange) · [addString](#addstring) · [contains](#contains) · [inverted](#inverted) · [unionWith](#unionwith) · [whitespace](#the-standard-sets) · [whitespaceAndNewlines](#the-standard-sets) · [decimalDigits](#the-standard-sets) · [letters](#the-standard-sets) · [alphanumerics](#the-standard-sets) · [punctuation](#the-standard-sets)

### addChar

```c
void addChar(i32 c)
```

### addRange

```c
void addRange(i32 lo, i32 hi)
```

Inclusive at both ends, as a range of characters is normally written.

### addString

```c
void addString(u8* s)
```

Every byte of the string becomes a member. This is the quickest way to build a
set of delimiters:

```c
sep.addString((u8*)",;\t");
```

### contains

```c
bool contains(i32 c)
```

Membership, with [`inverted`](#inverted) applied.

### inverted

```c
UXCharacterSet* inverted(void)
```

A **new** set with the flag flipped. The receiver is unchanged.

### unionWith

```c
UXCharacterSet* unionWith(UXCharacterSet* o)
```

A new set containing both. Use it to build "whitespace or comma" from a
standard set plus your own, without redefining the standard one.

## Example

```
trim: 'hello world'
unquote: quoted
tokenize     -> 3: [ls] [-l] [/usr]
```

The unquote line uses a set built with `addString`, and the tokenize line uses
`whitespaceAndNewlines`. The program is
`website/site/examples/uxkit/strings.xc`. The `doc-examples` gate compiles it,
and the listing above is its output.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXText`](/compiler/api/uxkit/uxtext/): `trim` and `tokenize`, which take
  one of these
- [`UXIndexSet`](/compiler/api/uxkit/uxindexset/): the storage
- [`UXCharClass`](/compiler/api/uxkit/uxcharclass/): the regex engine's
  equivalent
