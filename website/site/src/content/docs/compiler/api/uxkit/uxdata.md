---
title: UXData
description: "A growable byte buffer: the binary counterpart to a string, with doubling capacity so appends amortise to O(1)."
---

`UXData` is a growable byte buffer: append, read back, slice, compare, render as
hex. It has the shape of `NSData`/`NSMutableData`.

```c
#use <UXKit>            // or #import "UXData.xc"
```

## Overview

```c
UXData* d = UXData.fromString((u8*)"GEM");
d.appendByte(0);
d.appendByte(255);

d.length();       // 5
d.toHex();        // "47454d00ff"
d.subdata(0, 3);  // "GEM"
```

Binary pasteboard payloads, serialised structures and file contents travel in a
`UXData`. The string-only classes cannot carry them.

## Bytes, not characters

A string stops at the first `0`. A `UXData` has an explicit length, so a zero
byte is a byte like any other.

Anything with an embedded NUL (a length-prefixed record, a binary header, an
image) cannot travel as a `u8*` without losing its tail at the first zero. This
class exists to carry such data.

```c
UXData.fromString(s);      // takes the bytes up to the NUL
UXData.fromBytes(p, n);    // takes exactly n bytes, zeros included
```

`fromString` is the bridge in; `toHex` is a readable bridge out. There is no
`toString`, because a buffer with a zero in the middle has no faithful string
form.

### There is no string literal for an arbitrary byte

Both candidate spellings mean something else:

```c
"\xff"        // not valid: \xNN is ASCII by definition, 00-7F only
"\u00ff"      // TWO bytes — 195 191 — \u is a CODE POINT, UTF-8 encoded
```

A string literal is UTF-8 text, so it cannot spell the single byte `0xFF`. This
is a property of the language. [`appendByte`](#appendbyte) and
[`fromBytes`](#frombytes) are the intended way to build binary data.

A **character** literal is different: `'\u00ff'` is the code point as a `u8`,
which is `255`, and it composes as expected:

```c
d.appendByte('\u00ff');       // one byte, 255
```

## Capacity doubles

Growth doubles the buffer, so a sequence of appends amortises to **O(1)** each
instead of reallocating per byte.

[`withCapacity`](#withcapacity) pre-sizes the buffer when you know roughly how
much is coming, which avoids the doubling. It sets capacity, not length: a
`withCapacity(1024)` still has `length() == 0`.

:::caution[`bytes()` hands out the live buffer, and appending can move it]
[`bytes`](#bytes) returns the internal pointer, not a copy. Growth reallocates,
so **any append can leave a previously returned pointer dangling**:

```c
u8* p = d.bytes();
d.appendByte(0);        // may reallocate
p[0];                   // may now be freed memory
```

Take the pointer after the last append, use it, and do not store it. When you
need something that survives further writes, [`subdata`](#subdata) and
[`toHex`](#tohex) both copy.

[`byteAt`](#byteat) is the safe single-byte read. It is bounds-checked and hands
out no pointer, so nothing can invalidate a loop over `byteAt`.
:::

## Slicing clamps

```c
d.subdata(2, 999).length();     // whatever is actually there
```

An over-long range is clamped to the end instead of reading past it, so
`subdata(start, veryLarge)` is the idiom for "the rest from here".

The result is a **copy**, independent of the original. Appending to the source
afterwards does not change it.

## Comparison is by content

```c
slice.isEqualTo(other);      // same length, same bytes
```

Comparison does not use identity or pointers. Two buffers built separately from
the same bytes are equal, which a pasteboard round-trip test needs.

:::note[It is `isEqualTo`, not `equals`]
Dispatch in xtc is by name, and `Object.equals(Object@)` would shadow a custom
`equals`. For that reason the toolkit spells content comparison `isEqualTo`
throughout.
:::

## Topics

[withCapacity](#withcapacity) · [fromBytes](#frombytes) · [fromString](#fromstring) · [appendByte](#appendbyte) · [appendBytes](#appendbytes) · [appendData](#appenddata) · [subdata](#subdata) · [isEqualTo](#isequalto) · [toHex](#tohex) · [length](#length) · [byteAt](#byteat) · [bytes](#bytes)

### withCapacity

```c
static UXData* withCapacity(i32 n)
```

Empty, with room for `n` bytes.

### fromBytes

```c
static UXData* fromBytes(u8* src, i32 n)
```

`n` bytes, **copied**. Zeros included.

### fromString

```c
static UXData* fromString(u8* s)
```

The bytes up to the terminating NUL, not including it.

### appendByte

```c
void appendByte(u8 b)
```

One byte. The clearest way to build a small binary blob, and it can carry every
byte value.

### appendBytes

```c
void appendBytes(u8* src, i32 n)
```

### appendData

```c
void appendData(UXData* o)
```

Concatenate another buffer. The source is unchanged.

### subdata

```c
UXData* subdata(i32 start, i32 n)
```

A copy of a range, clamped to what exists.

### isEqualTo

```c
bool isEqualTo(UXData* o)
```

### toHex

```c
u8* toHex(void)
```

Lowercase hex, two characters per byte, no separators and no prefix. A fresh
string each call.

It serves as both a debugging tool and a readable serialisation: you can paste a
`UXData` printed as hex into a test.

### length

```c
i32 length(void)
```

Bytes held, not capacity.

### byteAt

```c
u8 byteAt(i32 i)
```

One byte, **bounds-checked**: an index outside the buffer reads as `0` instead
of faulting. A loop that runs one past the end gives a wrong answer instead of
a crash. That suits a format parser walking a buffer whose length it is still
working out.

### bytes

```c
u8* bytes(void)
```

The **live internal buffer**, not a copy. Use it to hand the bytes to something
that wants a plain pointer, such as a write syscall or a hash.

Read the [caution](#capacity-doubles) above before storing it anywhere: an
append may reallocate and leave it dangling. `bytes()` is also not
NUL-terminated, so treat it as a pointer plus [`length`](#length), never as a
string.

## Example

```
data: len=7 hex=47454d000102ff
slice(0,3): len=3 hex=47454d
equal=1  differs from whole=0
joined hex=61626364   over-long slice len=5
```

`47454d00` is `GEM` followed by a zero byte, which a `u8*` could not carry.
The program is `website/site/examples/uxkit/toolbox.xc`; the `doc-examples`
gate compiles it, and the output above is what it prints.

## Conforms to

- A plain class (not an [`Object`](/compiler/api/object/) subclass)

## See also

- [`UXPasteboard`](/compiler/api/uxkit/uxpasteboard/): the main consumer of
  binary payloads
- [`UXText`](/compiler/api/uxkit/uxtext/): the string counterpart
- [`UXJSON`](/compiler/api/uxkit/uxjson/): a text serialisation, when the
  payload does not have to be binary
