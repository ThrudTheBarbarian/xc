---
title: Data
description: "An Object owning a heap byte block: opaque bytes, no trailing NUL, with growth, slicing, hex, and the String-encoding bridge."
---

`Data` is an [`Object`](/compiler/api/object/) that owns a heap-allocated block
of bytes of a given length. Unlike [`String`](/compiler/api/string/) it adds
**no trailing NUL** and treats the bytes as opaque, with no character-class
operations. It is the value type for a raw blob: a file's contents, a packet, an
encoded string.

```c
#import "Foundation.xc"          // or #import "Data.xc"
```

## Overview

A `Data` owns a growable byte buffer and a length. It grows **geometrically**
(16, then doubling), so a run of [`appendByte`](#appendbyte) is amortised O(1)
per byte instead of O(n) for reallocating on every byte.
[`capacity`](#capacity) reports bytes allocated, [`length`](#length) bytes used.

The buffer is a raw `u8*`, not a class pointer, so `Data` frees it in
[`dealloc`](#dealloc); the automatic aggregate walker does not reclaim raw
allocations. [`bytes`](#bytes) returns that pointer for direct access. It stays
valid as long as the `Data` does.

Searches and slices follow the same conventions as `String`: a search miss is
[`Data.notFound()`](#notfound), and an out-of-range slice **clamps to empty**
rather than faulting.

`Data` also holds the byte/encoding **bridge** with `String`. Both directions
live here ([`withString`](#withstring), [`stringValue`](#stringvalue),
[`withStringEncoded`](#withstringencoded)) because `Data` already imports
`String`, and the reverse import would make the two files cyclic.

:::note[Availability]
Heap-capable targets only: the xt6502 `xt` layouts and every native backend
(`-falloc=heap`, the default there). A bump-only target rejects `new u8[N]` and
so cannot build a `Data`. On the 32-bit generic build lengths and indices are
`u32`. The xt6502 build narrows them to `u16`, and a narrower caller index
widens at the call boundary, so portable source compiles against both.
:::

## Conforms to

- [`Comparable`](/compiler/api/comparable/): [`compare`](#compare) gives
  memcmp-order total ordering, so `Data` can be sorted and used as a key.
- [`Hashable`](/compiler/api/hashable/): [`hash`](#hash) (FNV-1a over the
  bytes) makes a `Data` a [`Map`](/compiler/api/map/) / [`Set`](/compiler/api/set/) key.
- [`Copying`](/compiler/api/copying/): [`copy`](#copy) returns an independent
  duplicate over the same bytes.

Every `Data*` is also an [`Object*`](/compiler/api/object/) and fits anywhere one
is expected.

## Topics

**Creating** · [withBytes](#withbytes) · [withCapacity](#withcapacity) · [withLength](#withlength) · [withData](#withdata) · [init](#init)

**Reading** · [length](#length) · [isEmpty](#isempty) · [bytes](#bytes) · [byteAt](#byteat) · [capacity](#capacity)

**Mutating** · [setByteAt](#setbyteat) · [appendByte](#appendbyte) · [append](#append) · [appendBytes](#appendbytes) · [increaseLengthBy](#increaselengthby) · [setLength](#setlength) · [reserve](#reserve)

**Slicing** · [subdata](#subdata) · [subdataFrom](#subdatafrom)

**Searching** · [indexOfByte](#indexofbyte) · [containsByte](#containsbyte) · [notFound](#notfound)

**String bridge** · [withString](#withstring) · [stringValue](#stringvalue) · [withStringEncoded](#withstringencoded)

**Text** · [hexString](#hexstring)

**Protocol methods** · [description](#description) · [equals](#equals) · [compare](#compare) · [hash](#hash) · [copy](#copy) · [dealloc](#dealloc)

---

## Creating

### withBytes
```c
static Data* withBytes(u8* src, u32 len)
```
Copies `len` bytes from `src` into a new heap allocation. The caller's source
pointer can be freed or reused immediately afterwards. This is the usual
constructor.

### withCapacity
```c
static Data* withCapacity(u32 len)
```
**Reserves** room for `len` bytes but returns an **empty** `Data` (length 0);
grow it with the append methods. This avoids reallocation while building up to
`len` bytes. It does *not* pre-fill; use [`withLength`](#withlength) for that.

### withLength
```c
static Data* withLength(u32 len)
```
Allocates `len` **zero-filled** bytes, with length already `len`. Use when you
want to fill the bytes in place via [`setByteAt`](#setbyteat) before handing the
`Data` off.

### withData
```c
static Data* withData(Data* other)
```
An independent copy of `other`'s bytes (same as [`copy`](#copy)). A null `other`
yields an empty `Data`.

### init
```c
void init(void)
```
The default initializer: an empty `Data` (null buffer, zero length). Prefer the
`with…` factories; you rarely call `init` directly.

[↑ Topics](#topics)

## Reading

### length
```c
u32 length(void)
```
Number of valid bytes. O(1).

### isEmpty
```c
bool isEmpty(void)
```
`true` when the length is zero.

### bytes
```c
u8* bytes(void)
```
A **borrowed** pointer to the `Data`'s own buffer, for direct access. It is
valid as long as the `Data` instance is, until the buffer grows: an append may
reallocate, after which an earlier pointer dangles.

### byteAt
```c
u8 byteAt(u32 idx)
```
The raw byte at `idx`.

### capacity
```c
u32 capacity(void)
```
Bytes currently allocated in the backing buffer (≥ [`length`](#length)). See
[`reserve`](#reserve).

[↑ Topics](#topics)

## Mutating

### setByteAt
```c
void setByteAt(u32 idx, u8 value)
```
Writes `value` at `idx` (in range `[0, length)`).

### appendByte
```c
void appendByte(u8 b)
```
Appends one byte, growing the buffer geometrically if needed.

### append
```c
void append(Data* other)
```
Appends every byte of `other`. A null or empty `other` is a no-op.

### appendBytes
```c
void appendBytes(u8* src, u32 n)
```
Appends `n` bytes from `src`.

### increaseLengthBy
```c
void increaseLengthBy(u32 n)
```
Grows the length by `n` **zero** bytes (Foundation's `increaseLengthBy:`). The
new bytes are zeroed rather than left with the allocator's previous contents.

### setLength
```c
void setLength(u32 n)
```
Truncates to `n` bytes, or extends with zeroes (via
[`increaseLengthBy`](#increaselengthby)) if `n` is larger than the current
length.

### reserve
```c
void reserve(u32 need)
```
Grows the buffer so at least `need` bytes fit without reallocating, which
amortises a known series of appends. A request that already fits does not touch
the heap.

[↑ Topics](#topics)

## Slicing

Out-of-range clamps to empty, as [`String`](/compiler/api/string/)'s slicing
does. Each returns a new `Data*`.

### subdata
```c
Data* subdata(u32 from, u32 len)
```
A new `Data` of `len` bytes starting at byte `from` (clamped to what is
available).

### subdataFrom
```c
Data* subdataFrom(u32 from)
```
Everything from byte `from` to the end.

[↑ Topics](#topics)

## Searching

### indexOfByte
```c
u32 indexOfByte(u8 needle)
```
First offset of byte `needle`, or [`Data.notFound()`](#notfound) if absent.

### containsByte
```c
bool containsByte(u8 needle)
```
`true` if `needle` occurs anywhere (`indexOfByte(needle) != notFound()`).

### notFound
```c
static u32 notFound(void)          // 0xFFFFFFFF
```
The sentinel returned by [`indexOfByte`](#indexofbyte) on a miss.

[↑ Topics](#topics)

## String bridge

The byte/encoding bridge with [`String`](/compiler/api/string/). Both directions
live on `Data` (see [Overview](#overview)); the exported bytes never include a
trailing NUL.

### withString
```c
static Data* withString(String* s)
```
The string's bytes as a `Data`, **without** the trailing NUL (Foundation's
`dataUsingEncoding:` UTF-8 form). A null `s` yields an empty `Data`.

### stringValue
```c
String* stringValue(void)
```
These bytes as a [`String`](/compiler/api/string/). An embedded NUL is copied
like any other byte, so the length is preserved, but `cString()` on the result
stops at that NUL (a limit of the C representation).

### withStringEncoded
*(0.4)*
```c
static Data* withStringEncoded(String* s, StrEncoding enc)
```
Encodes a String as `enc` bytes: `ENC_UTF8` / `ENC_ASCII` / `ENC_LATIN1` /
`ENC_UTF16LE` / `ENC_UTF16BE`. A code point the target encoding cannot express
(Latin-1 above `U+00FF`, ASCII above `U+007F`) becomes `?`. UTF-16 emits
surrogate pairs above the BMP. `ENC_UTF8` is a plain byte copy **including** any
invalid bytes; call `s.sanitizedUtf8()` first if you want repair. This is the
encoding counterpart to
[`String.withEncodedBytes`](/compiler/api/string/#withencodedbytes); see
[String § other encodings](/compiler/api/string/#other-encodings).

[↑ Topics](#topics)

## Text

### hexString
```c
String* hexString(void)
```
The bytes as lowercase hex with no separators, for example `"deadbeef"`. Useful
for writing a blob to a log line or comparing it in a test.

[↑ Topics](#topics)

## Protocol methods

The [`Object`](/compiler/api/object/) / [`Comparable`](/compiler/api/comparable/)
/ [`Hashable`](/compiler/api/hashable/) / [`Copying`](/compiler/api/copying/)
hooks.

### description
```c
String* description(void)
```
The `%@` hook: `<Data 4: deadbeef>` (the length, then [`hexString`](#hexstring)).

### equals
```c
bool equals(Data* other)
bool equals(Object* other)
```
Byte-exact equality (equal length and equal bytes). The `Object*` overload is
the protocol slot heterogeneous containers use; it returns `false` against a
non-`Data`.

### compare
```c
i8 compare(Data* other)
i8 compare(Object* other)
```
Total ordering: lexicographic by unsigned byte, then by length (memcmp order),
so a shorter buffer that is a prefix of a longer one sorts first. Returns
negative / zero / positive. The `Object*` overload returns `0` against a
non-`Data`.

### hash
```c
u32 hash(void)
```
FNV-1a over the bytes. This is the [`Hashable`](/compiler/api/hashable/) method,
so a `Data` can key a [`Map`](/compiler/api/map/) or [`Set`](/compiler/api/set/).
Equal byte sequences always hash the same.

### copy
```c
Data* copy(void)
```
An independent duplicate over the same bytes (the [`Copying`](/compiler/api/copying/)
method). `Data` owns its buffer, so this copies it rather than sharing.

### dealloc
```c
void dealloc(void)
```
Frees the backing buffer. ARC calls it when the last reference goes away; you
do not call it directly.

[↑ Topics](#topics)

## Worked example

```c
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    u8 raw[4] = { $DE, $AD, $BE, $EF };
    Data* d = Data.withBytes(&raw[0], (u32)4);

    Stdio.printf("%s\n", d.hexString().cString());     // deadbeef
    Stdio.printf("%s\n", d.description().cString());    // <Data 4: deadbeef>

    d.appendByte((u8)$FF);
    Stdio.printf("%d\n", (i16)d.length());              // 5
    return 0;
}
```
