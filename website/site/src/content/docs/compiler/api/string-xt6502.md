---
title: String (xt6502)
description: "The byte-oriented String the xt6502 target ships: a String is a byte string and a char is a u8, because a UTF-8 decoder is too costly on a 6502."
---

This is the **byte-oriented** `String` the **xt6502** target ships. On the
6502 a String is a byte string and a "char" is a `u8`, as in C. There is no
character layer, because a UTF-8 decoder is too costly on a 6502. For 6502 code,
this page is the reference, not the [UTF-8 String](/compiler/api/string/) the
native targets ship.

:::note[This is the xt6502 surface]
On xt6502 a String is byte-oriented and indexes are `u16`. It also accepts the
`Byte`-named spellings the UTF-8 String uses, so byte-only source compiles on
every target from one file; see [the Byte-name aliases](#the-byte-name-aliases)
below. The reference for the other targets is
[String (UTF-8)](/compiler/api/string/).
:::

A heap-owned, NUL-terminated byte string. `charAt(i)` returns **the i-th
byte**.

```c
String* s = String.withCString("  Hello, World  ");
String* t = s.trimmed();                             // "Hello, World"

if (t.hasPrefix(String.withCString("Hello"))) { … }

Array* fields = String.withCString("a,b,,c").split((u8)',');   // 4 parts — the gap counts
String* back  = String.join(fields, String.withCString("-"));  // "a-b--c"
```

| | |
|---|---|
| **Build** | `String.withCString(p)`, `withString(s)`, `withBytes(p, n)` |
| **Numbers** | `String.withI32(v)`, `withU32(v)`, `withI16(v)`, `withU16(v)`, `withFloat(v)` |
| **Read** | `length()`, `isEmpty()`, `charAt(i)`, `cString()`, `copyCString()` |
| **Search** | `indexOf(needle)`, `indexOfChar(c)`, `lastIndexOfChar(c)`, `contains(s)`, `hasPrefix(s)`, `hasSuffix(s)` |
| **Slice** | `substring(from, len)`, `substringFrom(from)`, `substringTo(to)` |
| **Mutate** | `append(s)`, `appendChar(c)`, `appendCString(p)`, and `appending(s)`, which returns a new String instead |
| **Case** | `uppercased()`, `lowercased()`, `caseInsensitiveCompare(s)`, `equalsIgnoringCase(s)` |
| **Other** | `trimmed()`, `split(sep)` → `Array*`, `String.join(parts, sep)`, `replacing(find, sub)`, `description()` |
| **Value** | `equals(other)`, `compare(other)`, `hash()`: a `u8` rotate-and-XOR fold of the bytes (the 32-bit generic `String` uses FNV-1a) |

Out-of-range slicing **clamps to empty** rather than faulting:
`substringFrom(999)` is an empty String, as Foundation does for a clamped range.

`split` yields empty components for consecutive, leading or trailing
separators, so `"a,,b"` is three fields. CSV parsing needs this; filter out the
empty components if you want tokens.

Ordering is lexicographic by unsigned byte, then by length, so a prefix sorts
before its extension (`"go"` before `"gone"`).

**`cString()` is a borrow.** It returns a pointer into the String's own
buffer. Any mutation that grows the String (`append`, `appendChar`,
`appendCString`, `appendFormat`, `insert`) may reallocate that buffer and free
the old one. The pointer is valid until the String next grows; after that it
dangles. A dangling pointer usually still appears to work, so this bug tends to
survive testing. A `string` is not a class pointer, so holding one neither
retains the String nor prevents it from growing. If the bytes must outlive the
next mutation, take a copy: `copyCString()` returns a new heap copy that the
caller owns (and frees with `delete`).

## The Byte-name aliases

So that byte-only code can be written once for every target, the xt6502 String
also accepts the `Byte`-named spellings the UTF-8 String uses. Each is a thin
alias for the method shown next to it:

| Byte-name spelling (alias) | xt6502 implementation |
|---|---|
| `byteLength()` | `length()` |
| `byteAt(i)` | `charAt(i)` |
| `appendByte(c)` | `appendChar(c)` |
| `byteIndexOf(needle[, from])` | `indexOf(…)` |
| `indexOfByte(c)` / `lastIndexOfByte(c)` | `indexOfChar(c)` / `lastIndexOfChar(c)` |
| `substringBytes(from, len)` / `substringFromByte(from)` / `substringToByte(to)` | `substring(…)` / `substringFrom(…)` / `substringTo(…)` |
| `insertAtByte(at, s)` / `insertByte(at, c)` / `insertCStringAtByte(at, p)` | `insert(…)` / `insertChar(…)` / `insertCString(…)` |
| `deleteByteRange(at, len)` / `replaceByteRange(at, len, s)` | `deleteRange(…)` / `replaceRange(…)` |
| `byteIndexOfSet(cs)` / `lastByteIndexOfSet(cs)` / `containsByteFromSet(cs)` | `indexOfCharacterFrom(cs)` / `lastIndexOfCharacterFrom(cs)` / `containsCharacterFrom(cs)` |
| `splitOnSet(cs)` / `splitOnByte(sep)` | `split(cs)` / `split(sep)` |

xt6502 has no `charCount`, no code-point `charAt`, and no encodings.
