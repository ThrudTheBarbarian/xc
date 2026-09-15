---
title: UXCharClass
description: "A compiled [abc] or [^a-z]: a set of character codes plus a negation flag, answering membership in one call."
---

`UXCharClass` is what a regex bracket expression compiles to: the set of
character codes it accepts, and whether the sense is inverted.

```c
#use <UXKit>            // or #import "UXRegex.xc"
```

## Overview

```c
class UXCharClass : Object {
    UXIndexSet* set;        // the codes named
    bool        negated;    // [^...] inverts the answer
}

void addChar(i32 c)
void addRange(i32 lo, i32 hi)      // inclusive at both ends
bool contains(i32 c)
```

[`UXRegex`](/compiler/api/uxkit/uxregex/) builds these while parsing. The
matcher's `CLASS` instruction is a single [`contains`](#contains) call.

## Negation is a flag, not a different set

```c
[a-z]     set = {a…z},  negated = false
[^a-z]    set = {a…z},  negated = true
```

`[^a-z]` stores the **same** set and flips the answer. Storing the complement
would mean enumerating every code that is *not* a lowercase letter, which is
most of them, and would need an upper bound to stop at.

`[^a]` therefore means *anything but `a`*, with no ceiling, and the class costs
the same whichever way round it is written.

## Built on UXIndexSet

```c
UXIndexSet* set
```

Character codes are indices, so the set is a
[`UXIndexSet`](/compiler/api/uxkit/uxindexset/), the same run-coalescing
structure a table view uses for selected rows.

A range like `a-z` is stored as **one run**, not 26 entries, and
`[A-Za-z0-9_]` is four runs however many characters it names. Membership is a
search over runs rather than over characters.

`addRange` takes an inclusive `lo`–`hi` pair, as a regex writes it, and
converts to the length-based form the index set wants. A reversed range
(`hi < lo`) adds nothing.

## The predefined classes are ordinary ones

`\d`, `\w`, `\s` and their negations are built as `UXCharClass` instances with
the appropriate ranges added. There is no separate instruction for them and no
fast path.

They match what their ranges say: `\w` is `[A-Za-z0-9_]`, `\s` is the ASCII
whitespace codes, `\d` is `[0-9]`. There are no Unicode categories and no
locale effects.

## Bytes, not characters

The matcher works on bytes, so a class holds byte values. A UTF-8 character
outside ASCII is several bytes, and `[é]` is a class of the two bytes that
spell it. It matches either byte on its own.

ASCII classes, which regex patterns in this toolkit are for, are unaffected.
Keep this in mind before writing a class that contains a non-ASCII literal.

## Topics

[addChar](#addchar) · [addRange](#addrange) · [contains](#contains)

### addChar

```c
void addChar(i32 c)
```

Add one code.

### addRange

```c
void addRange(i32 lo, i32 hi)
```

Add an inclusive range. `hi < lo` is ignored.

### contains

```c
bool contains(i32 c)
```

Membership, with `negated` applied. This is the only question the matcher asks.

## Fields

### set

```c
UXIndexSet* set
```

### negated

```c
bool negated
```

## Conforms to

- Inherits [`Object`](/compiler/api/object/)

## See also

- [`UXRegex`](/compiler/api/uxkit/uxregex/): compiles and runs these
- [`UXIndexSet`](/compiler/api/uxkit/uxindexset/): the run-coalescing set
  underneath
- [`UXCharacterSet`](/compiler/api/uxkit/uxcharacterset/): the Foundation-style
  set [`UXText`](/compiler/api/uxkit/uxtext/) trims and tokenizes with
