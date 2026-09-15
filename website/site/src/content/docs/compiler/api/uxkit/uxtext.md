---
title: UXText
description: "Trim, split, tokenize, join, case-fold and search: the NSString convenience methods, all returning fresh buffers and never mutating in place."
---

`UXText` provides the common string operations that the base `String` does not:
trimming, splitting, joining, case folding, prefix/suffix/contains, and
single-character replacement.

Every method is **static**, and every result is a **fresh buffer**. Nothing is
mutated in place, so the methods are safe to call on a literal, on a field, or
on a pointer that other code still holds.

```c
#use <UXKit>            // or #import "UXText.xc"
```

## Overview

```c
UXText.trimWhitespace((u8*)"   hello world \n");     // "hello world"
UXText.toUpper((u8*)"Grand Bleu");                   // "GRAND BLEU"
UXText.hasSuffix((u8*)"system.fnt", (u8*)".fnt");    // true

Array<UXStrItem>* parts = UXText.split((u8*)"a,b,c", (u8)',');
UXText.partAt(parts, 1);                             // "b"
UXText.join(parts, (u8*)" | ");                      // "a | b | c"
```

Split results come back as an `Array` of
[`UXStrItem`](/compiler/api/uxkit/uxstritem/). The box is needed because an
array holds objects and a bare `u8*` is not one. [`partAt`](#partat) unwraps
a part, so you rarely name the box.

## split keeps empties, tokenize drops them

The two methods give different answers, and each is correct for a different job.

```c
UXText.split((u8*)"a,,b", (u8)',');     // 3: "a"  ""  "b"
UXText.split((u8*)"a,b,", (u8)',');     // 3: "a"  "b"  ""
UXText.split((u8*)"", (u8)',');         // 1: ""
```

[`split`](#split) is **structural**: a delimiter marks a field boundary, so an
empty field is a field. A CSV row needs this: a blank cell is a cell, and a
trailing comma means a trailing empty column.

Split and join also **round-trip**: `join(split(s, ','), ",")` returns `s`
unchanged, because the empty fields are kept.

```c
UXText.tokenize((u8*)"  ls   -l  /usr  ",
                UXCharacterSet.whitespaceAndNewlines());   // 3: "ls" "-l" "/usr"
```

[`tokenize`](#tokenize) is **lexical**: a run of delimiters is one gap, and
leading and trailing delimiters produce nothing. Use it to split a command line,
a sentence into words, or a space-separated attribute.

The delimiter also differs. `split` takes **one byte**; `tokenize` takes a
[`UXCharacterSet`](/compiler/api/uxkit/uxcharacterset/), so "break on comma,
semicolon or tab" is one set and one pass.

## The character set is a parameter

[`trim`](#trim) also takes a set, so it can trim more than whitespace:

```c
UXCharacterSet* quotes = new UXCharacterSet();
quotes.addString((u8*)"\"'");
UXText.trim((u8*)"\"quoted\"", quotes);       // quoted
```

[`trimWhitespace`](#trimwhitespace) covers the common case, such as a line read
from a file.

## Bytes, ASCII, and UTF-8

These methods work on **bytes**. `slen` is a byte count, `split` takes a byte,
and [`toLower`](#tolower--toupper) folds `A`–`Z` only; accented letters are left
alone.

UTF-8 is self-synchronizing, which limits the effect of this:

:::note[ASCII operations are safe on UTF-8 text]
Every byte of a multi-byte UTF-8 sequence is ≥ 0x80, and no ASCII byte appears
inside one. Splitting on a comma, testing a `.fnt` suffix, or folding case
cannot land in the middle of a character or corrupt one. `toUpper` on `"café"`
gives `"CAFé"`: the characters it cannot fold are left unchanged.

These methods do **not** provide Unicode-correct folding: no `ß`→`SS`, no
Turkish dotless `i`, and no locale awareness. This matters for case-insensitive
comparison of user-visible text. It does not matter for matching a file
extension or an attribute name.
:::

## Predicates and their empty cases

```c
UXText.contains((u8*)"abc", (u8*)"");        // true  — everything contains nothing
UXText.hasPrefix((u8*)"abc", (u8*)"");       // true
UXText.hasPrefix((u8*)"ab", (u8*)"abcdef");  // false — stops at the NUL
```

The empty-needle answers match `NSString`. They let an empty search box match
everything without a special case.

A prefix longer than the string is **safe**: the comparison reaches the
haystack's NUL and fails there without reading past it.

:::caution[`contains` is a naive scan]
It is O(n×m): every start offset, compared byte by byte. That is fine for a
label, a filename or a menu item, which is its intended use.

Do not use it to scan a document on every keystroke. Use
[`UXSearchIndex`](/compiler/api/uxkit/uxsearchindex/) when the haystack is large
or the search repeats.
:::

## Topics

[trim](#trim) · [trimWhitespace](#trimwhitespace) · [split](#split) · [tokenize](#tokenize) · [partAt](#partat) · [join](#join) · [toLower / toUpper](#tolower--toupper) · [hasPrefix](#hasprefix) · [hasSuffix](#hassuffix) · [contains](#contains) · [replaceChar](#replacechar) · [slen](#slen) · [dup](#dup)

### trim

```c
static u8* trim(u8* s, UXCharacterSet* cs)
```

Removes leading and trailing characters that are in the set. A string made
entirely of delimiters becomes `""`.

### trimWhitespace

```c
static u8* trimWhitespace(u8* s)
```

[`trim`](#trim) with
[`whitespaceAndNewlines`](/compiler/api/uxkit/uxcharacterset/).

### split

```c
static Array<UXStrItem>* split(u8* s, u8 delim)
```

Splits on one byte, **keeping** empty fields. Always returns at least one part.

### tokenize

```c
static Array<UXStrItem>* tokenize(u8* s, UXCharacterSet* sep)
```

Splits on any character in the set, **dropping** empty fields. A string made
entirely of delimiters gives an empty array.

### partAt

```c
static u8* partAt(Array<UXStrItem>* parts, i32 i)
```

Unwraps one part, so you do not need to name
[`UXStrItem`](/compiler/api/uxkit/uxstritem/).

### join

```c
static u8* join(Array<UXStrItem>* parts, u8* sep)
```

Concatenates with a separator **between** parts, with none leading or trailing.
An empty array gives `""`.

### toLower / toUpper

```c
static u8* toLower(u8* s)
static u8* toUpper(u8* s)
```

ASCII case folding. See [above](#bytes-ascii-and-utf-8).

### hasPrefix

```c
static bool hasPrefix(u8* s, u8* p)
```

### hasSuffix

```c
static bool hasSuffix(u8* s, u8* suf)
```

The extension test. False when the suffix is longer than the string.

### contains

```c
static bool contains(u8* hay, u8* needle)
```

Substring search. True for an empty needle. See the
[caution](#predicates-and-their-empty-cases) on cost.

### replaceChar

```c
static u8* replaceChar(u8* s, u8 from, u8 to)
```

Replaces every occurrence of one byte with another, in a new buffer. The length
is preserved, so this cannot replace a character with a string; use split and
join for that.

### slen

```c
static i32 slen(u8* s)
```

Byte length. **Null-safe**: returns `0` for null, so the other methods do not
each need a null guard.

### dup

```c
static u8* dup(u8* s, i32 start, i32 len)
```

A fresh NUL-terminated copy of a range. A negative length is clamped to zero.

## Example

```
trim: 'hello world'
unquote: quoted
split a,,b   -> 3: [a] [] [b]
split a,b,   -> 3: [a] [b] []
split ''     -> 1: []
tokenize     -> 3: [ls] [-l] [/usr]
join: a |  | b
round trip: a,b,
prefix=1 suffix=1 contains=1
empty needle=1 empty prefix=1
long prefix=0
case: GRAND BLEU grand bleu
```

The program is `website/site/examples/uxkit/strings.xc`. The `doc-examples`
gate compiles it, and the output above is what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass). All
  methods are static, so there is nothing to instantiate.

## See also

- [`UXStr`](/compiler/api/uxkit/uxstr/): concatenation and number conversion
- [`UXStrItem`](/compiler/api/uxkit/uxstritem/): the box split results come in
- [`UXCharacterSet`](/compiler/api/uxkit/uxcharacterset/): the delimiter sets
- [`UXCSV`](/compiler/api/uxkit/uxcsv/): when the fields are quoted and
  `split` is not enough
