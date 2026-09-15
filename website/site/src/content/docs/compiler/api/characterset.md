---
title: CharacterSet
description: "A set of byte values stored as a 256-bit bitmap, with membership tests and the predefined classes (whitespace, digits, letters) that String's search, trim and split methods take."
---

`CharacterSet` is a set of byte values, stored as a 256-bit bitmap (32 bytes).
Membership is O(1). [`String`](/compiler/api/string/)'s set-based methods
([`trimmed`](/compiler/api/string/#trimmed),
[`splitOnSet`](/compiler/api/string/#splitonset),
[`byteIndexOfSet`](/compiler/api/string/#byteindexofset)) take one, so "any
whitespace" or "any digit" is a single value rather than a hand-written test.

```c
#import "CharacterSet.xc"        // or the Foundation umbrella
```

## Overview

The set holds byte values `0–255`, one bit each, so it works over the *bytes*
of a UTF-8 string, not its code points. This suits the lexical classes it is
built for (whitespace, digits, ASCII letters); it is not a Unicode
character-property set. Instances are heap objects (`-falloc=heap`), inherit from
[`Object`](/compiler/api/object/), and are built either from the predefined
class methods or by adding bytes to a new set.

```c
CharacterSet* ws = CharacterSet.whitespaceAndNewlines();
String* trimmed = line.trimmed(ws);

CharacterSet* delims = CharacterSet.withCString((u8*)",;\t");
Array* fields = line.splitOnSet(delims);
```

## Topics

**Creating** · [init](#init) · [withCString](#withcstring) · [withRange](#withrange)

**Predefined sets** · [whitespace](#whitespace) · [newlines](#newlines) · [whitespaceAndNewlines](#whitespaceandnewlines) · [decimalDigits](#decimaldigits) · [hexDigits](#hexdigits) · [letters](#letters) · [alphanumerics](#alphanumerics) · [identifiers](#identifiers)

**Membership** · [contains](#contains) · [isEmpty](#isempty)

**Building** · [add](#add) · [remove](#remove) · [addRange](#addrange) · [addCString](#addcstring)

**Set operations** · [inverted](#inverted) · [formUnion](#formunion) · [formIntersection](#formintersection)

---

## Creating

### init
```c
void init(void)
```
Initialises an empty set. Use `new CharacterSet()` and then [`add`](#add) bytes,
or use one of the predefined class methods below.

### withCString
```c
static CharacterSet* withCString(u8* s)
```
A set containing the bytes in the C string `s`, for example
`CharacterSet.withCString(",;\t")`.

### withRange
```c
static CharacterSet* withRange(u8 lo, u8 hi)
```
A set of every byte from `lo` to `hi` inclusive.

[↑ Topics](#topics)

## Predefined sets

Each returns a new set for a common lexical class.

### whitespace
```c
static CharacterSet* whitespace(void)
```
Space and tab.

### newlines
```c
static CharacterSet* newlines(void)
```
The line-break characters: LF (10), CR (13), VT (11) and FF (12).

### whitespaceAndNewlines
```c
static CharacterSet* whitespaceAndNewlines(void)
```
Space, tab, CR and LF: the usual set for trimming lines.

### decimalDigits
```c
static CharacterSet* decimalDigits(void)
```
`0`–`9`.

### hexDigits
```c
static CharacterSet* hexDigits(void)
```
`0`–`9`, `a`–`f`, `A`–`F`.

### letters
```c
static CharacterSet* letters(void)
```
ASCII `A`–`Z` and `a`–`z`.

### alphanumerics
```c
static CharacterSet* alphanumerics(void)
```
ASCII letters and digits.

### identifiers
```c
static CharacterSet* identifiers(void)
```
The bytes valid in an identifier: letters, digits and `_`.

[↑ Topics](#topics)

## Membership

### contains
```c
bool contains(u8 c)
```
`true` if byte `c` is in the set. O(1).

### isEmpty
```c
bool isEmpty(void)
```
`true` if the set contains no bytes.

[↑ Topics](#topics)

## Building

These methods modify the set in place.

### add
```c
void add(u8 c)
```
Adds byte `c`.

### remove
```c
void remove(u8 c)
```
Removes byte `c`.

### addRange
```c
void addRange(u8 lo, u8 hi)
```
Adds every byte from `lo` to `hi` inclusive.

### addCString
```c
void addCString(u8* s)
```
Adds every byte in the C string `s`.

[↑ Topics](#topics)

## Set operations

### inverted
```c
CharacterSet* inverted(void)
```
A new set of every byte *not* in this one.

### formUnion
```c
void formUnion(CharacterSet* other)
```
Adds every byte of `other` to this set (in place).

### formIntersection
```c
void formIntersection(CharacterSet* other)
```
Keeps only the bytes present in both this set and `other` (in place).

[↑ Topics](#topics)
