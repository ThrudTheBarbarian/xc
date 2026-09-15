---
title: String
description: "Heap-owned UTF-8 string. Byte and Char in the method names tell you which unit you index in; a complete method reference grouped by task."
---

`String` is a heap-owned, NUL-terminated **UTF-8** string. Every method that
indexes says which unit it works in:

- **`Byte` in the name → byte semantics.** Indexes, lengths and slices count
  raw bytes. These are O(1), and bytes are the right unit for parsing, protocols
  and file formats.
- **`Char` in the name → character semantics.** Indexes and counts are Unicode
  code points decoded from the UTF-8. `charAt(1)` of `"héllo"` is `U+00E9`,
  not the second byte of its encoding.
- **No unit in the name → whole-string.** `append`, `trimmed`, `equals`,
  `hasPrefix` … treat the string as a value and take no index.

```c
#import "String.xc"          // or the Foundation umbrella
```

## Overview

A `String` owns a growable byte buffer and keeps it NUL-terminated so
[`cString()`](#cstring) is always valid. It inherits from
[`Object`](/compiler/api/object/) and needs a real heap (`-falloc=heap`, the
default on the `xt` 6502 layout and every native backend).

UTF-8 preserves code-point order under byte comparison, so the value methods
([`equals`](#equals), [`compare`](#compare), [`hash`](#hash)) need no
character-aware variants: byte order is character order. Ordering is
lexicographic by unsigned byte then by length, so a prefix sorts before its
extension (`"go"` before `"gone"`).

Searches return a byte index and a miss is [`notFound()`](#notfound), never a
negative number. Out-of-range slicing **clamps to empty** rather than faulting.

:::note[Availability]
This is the String of **every target but xt6502**. The xt6502 String is
byte-oriented, with no character layer, because a UTF-8 decoder is too costly on
a 6502. It is documented on [String (xt6502)](/compiler/api/string-xt6502/).
:::

## Conforms to

- [`Comparable`](/compiler/api/comparable/): [`compare`](#compare) gives total ordering, so `String` can be sorted and used as a key.
- [`Hashable`](/compiler/api/hashable/): [`hash`](#hash) (FNV-1a over the bytes), so `String` can be a `Map`/`Set` key.
- [`Copying`](/compiler/api/copying/): [`copy`](#copy) returns an independent duplicate.

Every `String*` is also an [`Object*`](/compiler/api/object/) and fits anywhere one is expected.

## Topics

**Creating strings** · [withCString](#withcstring) · [withString](#withstring) · [withBytes](#withbytes) · [withChar](#withchar) · [withFormat](#withformat) · [withEncodedBytes](#withencodedbytes) · [init](#init)

**Numbers → String** · [withI32 / withU32](#withi32--withu32) · [withI16 / withU16](#withi16--withu16) · [withI64 / withU64](#withi64--withu64) · [withFloat](#withfloat)

**Reading bytes** · [byteLength](#bytelength) · [isEmpty](#isempty) · [byteAt](#byteat) · [capacity](#capacity) · [cString](#cstring) · [copyCString](#copycstring) · [getBytes](#getbytes)

**Characters (Unicode)** · [charCount](#charcount) · [charAt](#charat) · [charAtByte](#charatbyte) · [charByteLength](#charbytelength) · [byteIndexOfChar](#byteindexofchar) · [nextCharByte](#nextcharbyte) · [prevCharByte](#prevcharbyte) · [isCharBoundary](#ischarboundary) · [appendChar](#appendchar) · [substringChars](#substringchars) · [isValidUtf8](#isvalidutf8) · [sanitizedUtf8](#sanitizedutf8)

**Searching** · [byteIndexOf](#byteindexof) · [indexOfByte](#indexofbyte) · [lastIndexOfByte](#lastindexofbyte) · [contains](#contains) · [hasPrefix](#hasprefix) · [hasSuffix](#hassuffix) · [notFound](#notfound)

**Slicing** · [substringBytes](#substringbytes) · [substringFromByte](#substringfrombyte) · [substringToByte](#substringtobyte)

**Mutating** · [append](#append) · [appendCString](#appendcstring) · [appendByte](#appendbyte) · [appendBytes](#appendbytes) · [appendFormat](#appendformat) · [insertAtByte](#insertatbyte) · [insertByte](#insertbyte) · [insertCStringAtByte](#insertcstringatbyte) · [deleteByteRange](#deletebyterange) · [replaceByteRange](#replacebyterange) · [replaceOccurrences](#replaceoccurrences) · [clear](#clear) · [setTo](#setto) · [setCString](#setcstring) · [reserve](#reserve)

**Deriving new strings** · [appending](#appending) · [replacing](#replacing) · [trimmed](#trimmed) · [uppercased](#uppercased) · [lowercased](#lowercased) · [copy](#copy) · [description](#description)

**Case-insensitive** · [caseInsensitiveCompare](#caseinsensitivecompare) · [equalsIgnoringCase](#equalsignoringcase)

**Splitting & joining** · [splitOnByte](#splitonbyte) · [splitOnSet](#splitonset) · [join](#join)

**Character sets** · [byteIndexOfSet](#byteindexofset) · [lastByteIndexOfSet](#lastbyteindexofset) · [containsByteFromSet](#containsbytefromset) · [asCharacterSet](#ascharacterset)

**Paths** · [pathSeparator](#pathseparator) · [isAbsolutePath](#isabsolutepath) · [lastPathComponent](#lastpathcomponent) · [deletingLastPathComponent](#deletinglastpathcomponent) · [pathExtension](#pathextension) · [deletingPathExtension](#deletingpathextension) · [appendingPathComponent](#appendingpathcomponent) · [appendingPathExtension](#appendingpathextension)

**Other encodings** · [withEncodedBytes](#withencodedbytes) · (encode via [`Data.withStringEncoded`](/compiler/api/data/))

**Protocol methods** · [equals](#equals) · [compare](#compare) · [hash](#hash) · [dealloc](#dealloc)

---

## Creating strings

### withCString
```c
static String* withCString(u8* src)
```
Builds a String by copying a NUL-terminated C string. The bytes are copied
unchanged and assumed to be UTF-8, with no validation. This is the most common
constructor.

### withString
```c
static String* withString(String* other)
```
Returns an independent copy of `other` (same as [`copy`](#copy)).

### withBytes
```c
static String* withBytes(u8* src, u32 n)
```
Copies `n` bytes, including any NUL bytes. The buffer may contain embedded NULs,
though [`cString()`](#cstring) stops at the first one.

### withChar
```c
static String* withChar(u32 cp)
```
A one-character String: encodes the Unicode code point `cp` as UTF-8.

### withFormat
```c
static String* withFormat(string fmt, ...)
```
Builds a String from a `printf`-style format (see [`appendFormat`](#appendformat)
for the conversions). `String.withFormat("%d items", n)`.

### withEncodedBytes
```c
static String* withEncodedBytes(u8* src, u32 n, StrEncoding enc)
```
Decodes `n` bytes in encoding `enc` into a (UTF-8) String. Malformed input is
repaired to `U+FFFD`. See [Other encodings](#other-encodings).

### init
```c
void init(void)
```
The default initializer (an empty String). Prefer `new String()` or the
`with…` constructors; you rarely call `init` directly.

[↑ Topics](#topics)

## Numbers → String

### withI32 / withU32
```c
static String* withI32(i32 v)
static String* withU32(u32 v)
```
Decimal rendering of a 32-bit signed / unsigned integer.

### withI16 / withU16
```c
static String* withI16(i16 v)
static String* withU16(u16 v)
```
Convenience wrappers that widen to 32-bit and render as above.

### withI64 / withU64
```c
static String* withI64(i64 v)
static String* withU64(u64 v)
```
Decimal rendering of a 64-bit signed / unsigned integer.

### withFloat
```c
static String* withFloat(float f, u8 precision)
static String* withFloat(float f)               // precision 6
```
Renders `f` with `precision` digits after the point (default 6).

[↑ Topics](#topics)

## Reading bytes

### byteLength
```c
u32 byteLength(void)
```
Number of bytes in the string (not counting the terminator). O(1). This is the
UTF-8 encoded length, not the character count; see [`charCount`](#charcount).

### isEmpty
```c
bool isEmpty(void)
```
`true` when the byte length is zero.

### byteAt
```c
u8 byteAt(u32 idx)
```
The raw byte at `idx`. For the *character* at a position use
[`charAt`](#charat) or [`charAtByte`](#charatbyte).

### capacity
```c
u32 capacity(void)
```
Bytes currently allocated in the backing buffer (≥ [`byteLength`](#bytelength)).
See [`reserve`](#reserve).

### cString
```c
u8* cString(void)
```
A **borrowed** pointer into the String's own NUL-terminated buffer. Valid until
the next growth ([`append`](#append), [`appendChar`](#appendchar),
[`appendFormat`](#appendformat), [`insertAtByte`](#insertatbyte) …), which may
reallocate and free the old buffer, leaving the pointer dangling. If the bytes
must outlive the next mutation, use [`copyCString`](#copycstring).

### copyCString
```c
u8* copyCString(void)
```
A new heap copy of the bytes (NUL-terminated) that the caller owns and frees
with `delete`. Use it when you need a pointer that survives mutation of the
String.

### getBytes
```c
u32 getBytes(u8* dst, u32 max)
```
Copies up to `max` bytes into `dst`, returning the number copied. Does not
NUL-terminate. Safe against overrun.

[↑ Topics](#topics)

## Characters (Unicode)

Available on every target but xt6502.

### charCount
```c
u32 charCount(void)
```
Number of Unicode code points, decoded from the UTF-8. O(n).

### charAt
```c
u32 charAt(u32 n)
```
The `n`-th code point. O(n): it restarts from the front on each call, so a
`charAt` loop is O(n²). Walk by byte index instead (see the example).

### charAtByte
```c
u32 charAtByte(u32 at)
```
The code point whose encoding starts at byte `at`. Returns `U+FFFD` if `at` is
not a valid sequence start. O(1).

### charByteLength
```c
u32 charByteLength(u32 at)
```
How many bytes the character starting at byte `at` occupies (1–4; 1 for an
invalid byte).

### byteIndexOfChar
```c
u32 byteIndexOfChar(u32 n)
```
The byte offset where the `n`-th character's encoding begins.

### nextCharByte
```c
u32 nextCharByte(u32 at)
```
The byte offset of the next character after the one at `at`. Use it to iterate
characters in O(n).

### prevCharByte
```c
u32 prevCharByte(u32 at)
```
The byte offset of the character before the one at `at`.

### isCharBoundary
```c
bool isCharBoundary(u32 at)
```
`true` if byte `at` begins a UTF-8 sequence (or is the end).

### appendChar
```c
void appendChar(u32 cp)
```
Encodes code point `cp` as UTF-8 and appends it.

### substringChars
```c
String* substringChars(u32 fromChar, u32 count)
```
A new String of `count` characters starting at character index `fromChar`.
Clamps to empty if out of range.

### isValidUtf8
```c
bool isValidUtf8(void)
```
`true` if the whole buffer is well-formed UTF-8 (rejects overlong encodings,
unpaired surrogates, values above `U+10FFFF`, truncated sequences).

### sanitizedUtf8
```c
String* sanitizedUtf8(void)
```
A repaired **copy**: each maximal invalid subpart becomes one `U+FFFD` (the
Unicode-recommended repair). Valid input comes back byte-identical.

[↑ Topics](#topics)

## Searching

Byte offsets; a miss is [`notFound()`](#notfound).

### byteIndexOf
```c
u32 byteIndexOf(String* needle)
u32 byteIndexOf(String* needle, u32 from)
```
First byte offset of `needle`, optionally starting the search at byte `from`.

### indexOfByte
```c
u32 indexOfByte(u8 ch)
```
First offset of byte `ch`.

### lastIndexOfByte
```c
u32 lastIndexOfByte(u8 ch)
```
Last offset of byte `ch`.

### contains
```c
bool contains(String* needle)
```
`true` if `needle` occurs anywhere (`byteIndexOf(needle) != notFound()`).

### hasPrefix
```c
bool hasPrefix(String* p)
```
`true` if the string starts with `p`.

### hasSuffix
```c
bool hasSuffix(String* s)
```
`true` if the string ends with `s`.

### notFound
```c
static u32 notFound(void)          // 0xFFFFFFFF
```
The sentinel returned by the search methods on a miss.

[↑ Topics](#topics)

## Slicing

Out-of-range clamps to empty.

### substringBytes
```c
String* substringBytes(u32 from, u32 len)
```
A new String of `len` bytes starting at byte `from`.

### substringFromByte
```c
String* substringFromByte(u32 from)
```
Everything from byte `from` to the end.

### substringToByte
```c
String* substringToByte(u32 to)
```
Everything before byte `to`.

[↑ Topics](#topics)

## Mutating

These modify the String in place.

### append
```c
void append(String* other)
```
Appends `other`'s bytes.

### appendCString
```c
void appendCString(u8* src)
```
Appends a NUL-terminated C string.

### appendByte
```c
void appendByte(u8 ch)
```
Appends one raw byte. This may leave the buffer holding partial UTF-8 (see
[`sanitizedUtf8`](#sanitizedutf8)).

### appendBytes
```c
void appendBytes(u8* src, u32 n)
```
Appends `n` bytes.

### appendFormat
```c
void appendFormat(string fmt, ...)
```
Appends `printf`-style formatted text. Conversions: `%d`/`%u` (16-bit),
`%ld`/`%lu` (32-bit), `%x`/`%lx`, `%s`, `%c`, `%f`, `%%`. See
[Stdio](/compiler/api/stdio/) for the shared format contract.

### insertAtByte
```c
void insertAtByte(u32 at, String* other)
```
Inserts `other` at byte offset `at`.

### insertByte
```c
void insertByte(u32 at, u8 ch)
```
Inserts one byte at `at`.

### insertCStringAtByte
```c
void insertCStringAtByte(u32 at, u8* src)
```
Inserts a C string at byte `at`.

### deleteByteRange
```c
void deleteByteRange(u32 at, u32 len)
```
Removes `len` bytes starting at `at`.

### replaceByteRange
```c
void replaceByteRange(u32 at, u32 len, String* other)
```
Replaces `len` bytes at `at` with `other` (which may be a different length).

### replaceOccurrences
```c
u32 replaceOccurrences(String* find, String* sub)
```
Replaces every occurrence of `find` with `sub` in place; returns the count
replaced. For a non-mutating version see [`replacing`](#replacing).

### clear
```c
void clear(void)
```
Empties the String (keeps the allocated buffer).

### setTo
```c
void setTo(String* other)
```
Replaces the contents with a copy of `other`.

### setCString
```c
void setCString(u8* src)
```
Replaces the contents with a C string.

### reserve
```c
void reserve(u32 need)
```
Grows the buffer so at least `need` bytes fit without reallocating, which
amortises a series of appends.

[↑ Topics](#topics)

## Deriving new strings

Non-mutating: each returns a new `String*`, leaving the receiver unchanged.

### appending
```c
String* appending(String* other)
```
A new String of the receiver followed by `other`.

### replacing
```c
String* replacing(String* find, String* sub)
```
A new String with every `find` replaced by `sub` (non-mutating
[`replaceOccurrences`](#replaceoccurrences)).

### trimmed
```c
String* trimmed(void)                    // ASCII whitespace
String* trimmed(CharacterSet* set)       // any set
```
A copy with leading and trailing whitespace (or the bytes of any
[`CharacterSet`](/compiler/api/characterset/)) removed.

### uppercased
```c
String* uppercased(void)
```
An ASCII-uppercased copy (non-ASCII bytes pass through).

### lowercased
```c
String* lowercased(void)
```
An ASCII-lowercased copy.

### copy
```c
String* copy(void)
```
An independent duplicate (the [`Copying`](/compiler/api/copying/) method).

### description
```c
String* description(void)
```
A String describing the object; for `String` itself, a copy. This is the
[`Object`](/compiler/api/object/) hook used by printing helpers.

[↑ Topics](#topics)

## Case-insensitive

These use ASCII case folding only; a full Unicode fold is not provided because
of its cost.

### caseInsensitiveCompare
```c
i8 caseInsensitiveCompare(String* other)
```
Like [`compare`](#compare) but ASCII-case-insensitive.

### equalsIgnoringCase
```c
bool equalsIgnoringCase(String* other)
```
ASCII-case-insensitive equality.

[↑ Topics](#topics)

## Splitting & joining

### splitOnByte
```c
Array* splitOnByte(u8 sep)
```
Splits on byte `sep`, returning an [`Array`](/compiler/api/array/) of Strings.
Empty fields are kept for consecutive, leading or trailing separators, so
`"a,,b"` is three fields. Filter out the empty fields if you want tokens.

### splitOnSet
```c
Array* splitOnSet(CharacterSet* set)
```
Splits on any byte in `set`.

### join
```c
static String* join(Array* parts, String* sep)
```
Joins an Array of Strings with `sep` between them. The inverse of
[`splitOnByte`](#splitonbyte).

[↑ Topics](#topics)

## Character sets

Work with [`CharacterSet`](/compiler/api/characterset/).

### byteIndexOfSet
```c
u32 byteIndexOfSet(CharacterSet* set)
```
First byte offset of any character in `set`.

### lastByteIndexOfSet
```c
u32 lastByteIndexOfSet(CharacterSet* set)
```
Last byte offset of any character in `set`.

### containsByteFromSet
```c
bool containsByteFromSet(CharacterSet* set)
```
`true` if any byte belongs to `set`.

### asCharacterSet
```c
CharacterSet* asCharacterSet(void)
```
A `CharacterSet` of the distinct bytes in this String.

[↑ Topics](#topics)

## Paths

Treat the String as a `/`-separated path. Non-mutating.

### pathSeparator
```c
static u8 pathSeparator(void)            // '/'
```
The separator byte these methods use.

### isAbsolutePath
```c
bool isAbsolutePath(void)
```
`true` if the path starts at the root (`/`).

### lastPathComponent
```c
String* lastPathComponent(void)
```
The final component (the file name).

### deletingLastPathComponent
```c
String* deletingLastPathComponent(void)
```
The parent directory (drops the last component).

### pathExtension
```c
String* pathExtension(void)
```
The extension of the last component, without the dot (empty if none).

### deletingPathExtension
```c
String* deletingPathExtension(void)
```
The path with the last component's extension removed.

### appendingPathComponent
```c
String* appendingPathComponent(String* component)
```
The path with `component` appended, inserting a separator as needed.

### appendingPathExtension
```c
String* appendingPathExtension(String* ext)
```
The path with `.ext` appended to the last component.

[↑ Topics](#topics)

## Other encodings

Internally a String is always UTF-8; there is no per-String encoding mode.
Other encodings are transcoded **at the edge**:

```c
enum StrEncoding = {ENC_UTF8, ENC_ASCII, ENC_LATIN1, ENC_UTF16LE, ENC_UTF16BE};

String* s = String.withEncodedBytes(buf, n, ENC_LATIN1);   // decode: bytes -> String
Data*   d = Data.withStringEncoded(s, ENC_ASCII);          // encode: String -> bytes
```

- **Decoding** ([`withEncodedBytes`](#withencodedbytes)) repairs malformed input
  to `U+FFFD`: an unpaired UTF-16 surrogate, an odd trailing byte, an ASCII
  byte above 127. Latin-1 cannot be malformed, because each byte is its code
  point.
- **Encoding** ([`Data.withStringEncoded`](/compiler/api/data/)) substitutes
  `?` for a code point the target cannot express (Latin-1 above `U+00FF`, ASCII
  above `U+007F`). UTF-16 emits surrogate pairs for the astral planes.
- `ENC_UTF8` output is a plain byte copy, **including** any invalid bytes.
  Call [`sanitizedUtf8`](#sanitizedutf8) first if you want repair.

The encoder lives on [`Data`](/compiler/api/data/), not `String`, because Data
already imports String and the bridge is kept on one side.

[↑ Topics](#topics)

## Protocol methods

Inherited/overridden hooks from [`Object`](/compiler/api/object/),
[`Comparable`](/compiler/api/comparable/) and [`Hashable`](/compiler/api/hashable/).

### equals
```c
bool equals(String* other)
bool equals(Object* other)
```
Byte-exact equality. The `Object*` overload lets a `String` compare inside a
heterogeneous container.

### compare
```c
i8 compare(String* other)
i8 compare(Object* other)
```
Total ordering: lexicographic by unsigned byte, then by length. Returns
negative / zero / positive. This method makes `String` [`Comparable`](/compiler/api/comparable/).

### hash
```c
u32 hash(void)
```
FNV-1a over the bytes. This is the [`Hashable`](/compiler/api/hashable/) method,
so a `String` can key a [`Map`](/compiler/api/map/) or [`Set`](/compiler/api/set/).

### dealloc
```c
void dealloc(void)
```
Frees the backing buffer. ARC calls it when the last reference goes away; you
do not call it directly.

[↑ Topics](#topics)

## Worked example

Compiles and runs on every target but xt6502 (`examples/compiler/strings.xc`):

```c
// strings.xc — the String: bytes and characters, named apart.
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    // "héllo⚡" — 6 characters, 9 bytes: é is 2 bytes, ⚡ is 3.
    String* s = String.withCString("h");
    s.appendChar((u32)$E9);          // é   U+00E9, encoded as 2 bytes
    s.appendCString("llo");
    s.appendChar((u32)$26A1);        // ⚡  U+26A1, encoded as 3 bytes

    Stdio.printf("bytes %d, chars %d\n",
                 (i16)s.byteLength(), (i16)s.charCount());

    // Byte in the name = byte semantics; Char = code points.
    Stdio.printf("byteAt(1) %lx, charAt(1) U+%lx\n",
                 (u32)s.byteAt((u32)1), s.charAt((u32)1));

    // Walk characters by byte index — no O(n^2) charAt loop.
    u32 i = (u32)0;
    while (i < s.byteLength()) {
        Stdio.printf("U+%lx ", s.charAtByte(i));
        i = s.nextCharByte(i);
    }
    Stdio.printf("\n");
    return 0;
}
```

```
bytes 9, chars 6
byteAt(1) 000000C3, charAt(1) U+000000E9
U+00000068 U+000000E9 U+0000006C U+0000006C U+0000006F U+000026A1
```

String literals also take Unicode escapes directly: `"héllo⚡"` is the same
nine bytes. See [lexical structure](/compiler/language/lexical/#string-and-character-literals).
