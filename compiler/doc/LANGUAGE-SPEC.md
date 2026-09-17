# xtc language specification

This specification covers the xtc source language as you type it.
The canonical documentation is the website at
https://compile-xc.org. Where this document and the website
disagree, the website is correct.

The intermediate representation, the calling convention, the xt
CPU extensions and the standard library (in
`support/<platform>/lib/` and `support/generic/lib/`) are outside
its scope. It defines what the compiler accepts, not what it
emits.

§§1-3 cover lexical structure, the preprocessor and types; §§4-6
cover operators, statements and functions; §§7-9A add classes,
inheritance, ARC and bound methods; §10 covers inline assembly.
Reserved words and grammar pointers are in §11.

---

## 1. Lexical structure

### 1.1 Comments

```
// line comment — runs to end of line
/* block comment — runs to the matching closer */
```

### 1.2 Identifiers

- Case-sensitive (`Foo ≠ foo`).
- Start with a letter; subsequent characters may be letters,
  digits, or underscore.
- Reserved words (§11.1) may not be used as variable, class, or
  struct names.

### 1.3 Numeric literals

There are three radix forms. Underscores are ignored anywhere
inside the literal, for digit grouping:

```
1234         // decimal
$1234        // hex (NB: 6502-style, no 0x prefix)
%1010_0101   // binary
16_777_216   // grouped decimal
```

### 1.4 String and character literals

Strings are double-quoted, null-terminated. The trailing `\0`
is not counted in `.length`. Strings never split across source
lines. Escape sequences:

| Escape | Means |
|--------|-------|
| `\n` | newline (CR + LF) |
| `\r` | carriage return |
| `\t` | tab |
| `\0` | end-of-string marker |
| `\\` | a literal backslash |
| `\"` | a literal `"` in a string |
| `\'` | a literal `'` in a char literal |
| `\xNN` | an ASCII byte, exactly 2 hex digits, `00`–`7F` (since 0.4) |
| `\uNNNN` | a Unicode code point, exactly 4 hex digits (since 0.4) |
| `\UNNNNNNNN` | a Unicode code point, exactly 8 hex digits (since 0.4) |

`\u` and `\U` are stored in the string as UTF-8: `"\u00E9"` is the two
bytes `C3 A9`. A surrogate (`D800`–`DFFF`) or a value above `10FFFF` is
a compile error. Unlike C, `\x` is capped at `7F`. A byte above `7F`
inside a UTF-8 string is either half a character (write it with `\u`)
or binary data (write it with `appendByte`).
Source files are UTF-8, so a raw `é` in a string literal is equivalent
to `\u00E9`.

Character literals are a single character (or `\<x>`) in single
quotes, typed as `u8`: `'A'`, `'\t'`, `'\x41'`. `\u` in a char
literal must fit a `u8` (`'\u00E9'` is the Latin-1 byte `E9`). A raw
non-ASCII character between single quotes is not portable; write it
with `\u`.

### 1.5 Block delimiters

`{ ... }`. There is no alternative form.

`(( ... ))` is not a block delimiter; `((T*)p).f = v;` is an
ordinary expression. On a keyboard without `{` and `}` keys, such
as the Atari 8-bit keyboard, use an editor key mapping.

### 1.6 Statement terminator

`;`. It is not optional: function declarations without a body,
variable declarations and expression statements all end with `;`.

---

## 2. Preprocessor

The preprocessor runs before the lexer and produces preprocessed
source. It is not part of the language proper.

### 2.1 File inclusion

```
#include <file.xc>     // search system / -I paths only
#include "file.xc"     // search next to current file first
#import  <Stdio.xc>    // include-once form
#import  "Sprite.xc"
```

- `"..."` searches next to the including file first, then
  system / `-I` paths.
- `<...>` skips the current source's directory and goes
  straight to system / `-I` paths.
- Filename matching is case-sensitive, including on
  case-insensitive filesystems.
- `#import` is identical to `#include` except that the named file
  is included only once per compilation unit. Library headers use
  `#import`.
- Source files use the `.xc` extension. The `.xt` extension is
  accepted during a transition: a bare `#import <X>` falls back
  to `X.xt`, and an explicit `#import "X.xt"` that does not
  resolve is retried as `X.xc`. The second rule lets a tree that
  still uses `.xt` names import libraries that use `.xc`. Both
  fallbacks are transitional.

### 2.2 `#use` — import + bare-call promotion

```
#use Stdio          // == #import "Stdio.xc" + use Stdio;
#use Math
#use <Time>
#use "Sprite"
```

Expands to a `#import` plus a top-level `use ClassName;`
directive (§7.3). A `.xc` extension in the name is stripped.

### 2.3 Macros

```
#define DBL(x)        (double(x))
#define ZP_BASE       $80
#define ENABLE_DOUBLE 1
```

Both function-like and object-like macros are supported. Variadic
macros use `...` for the trailing parameter and `__VA_ARGS__` in
the body, as in C. `#undef` removes a defined macro.

### 2.4 Conditional compilation

```
#ifdef DEBUG     #endif
#ifndef X        #endif
#if EXPR         #elif EXPR  #else  #endif
```

`#if` evaluates a constant integer expression. Macros may be
defined on the command line with `-D NAME[=VALUE]`.

### 2.5 Diagnostics

```
#warning need to implement doFrobble()
#error neither ATARI nor C64 layout selected
```

`#warning` issues a warning and lets the build continue;
`#error` fails the build.

---

## 3. Types

### 3.1 Primitive types

| Type | Size | Meaning |
|------|------|---------|
| `u8` / `i8` | 1 byte | 8-bit unsigned / signed integer |
| `u16` / `i16` | 2 bytes | 16-bit unsigned / signed integer |
| `u32` / `i32` | 4 bytes | 32-bit unsigned / signed integer |
| `u64` / `i64` | 8 bytes | 64-bit unsigned / signed integer. Every target lays out eight bytes. The 64-bit hosts also compute in them; narrow targets reject 64-bit arithmetic with a diagnostic rather than miscompiling it. The width is a layout contract; arithmetic support varies by target |
| `float` | single precision | abstract single-precision FP; bit-layout target-decided |
| `double` | double precision | abstract double-precision FP; bit-layout target-decided |
| `bool` | 1 byte | alias of `u8`; values `true` / `false` |
| `void` | — | absence of value |
| `string` | pointer | alias of `u8*` (pointer to null-terminated bytes) |
| `pointer` | target-defined | typeless pointer |

**Pointer width is target-defined.** On a banked 6502 target
(xt, xe, or any target that maps a bankable address region) a
pointer is 3 bytes: `{bank, 16-bit addr}`. On a flat, unbanked
6502 layout (xl) there is no bank byte and a pointer is 2 bytes.
On arm64, x86-64 and other flat 64-bit hosts a pointer is 8
bytes. The language treats `T*` as opaque. Code that needs the
width uses `sizeof(T*)` at compile time rather than a constant.

**Float and double encoding is target-decided.** The language
commits only to the abstract precision (single or double). On
6502 targets `float` is xtc's 5-byte format (1 sign byte, a
signed 8-bit exponent and a 24-bit mantissa; **not** IEEE 754)
and `double` is the corresponding 8-byte format with a 48-bit
mantissa. On FPU targets (arm64, x86-64) `float` is IEEE 754
single and `double` is IEEE 754 double. Float results may differ
in the last ULP between targets.

**Truncation rules:**

- Assigning wider integer → narrower: truncates, no sign
  extension.
- Assigning `float`/`double` → integer: takes the integral part,
  truncated toward zero. Out-of-range magnitudes saturate to 0.
- Mixed-width arithmetic widens the result type (`u8 + u16` →
  `u16`).
- **Same-width arithmetic does not widen.** An operator's type is the
  widening of its operands only, so `u8 + u8` is a `u8` and wraps at
  8 bits. There is no C-style promotion to `int`. The assignment
  widens the result afterwards, so the destination cannot change how
  the operator computes:

  ```c
  u8 a = 200, b = 100;
  u8  narrow = a + b;          // 44  — 300 & 0xFF
  u16 wide   = a + b;          // 44  — STILL a u8 add
  u16 real   = (u16)a + (u16)b;// 300 — widen the OPERANDS
  ```

  Unlike C, an expression means the same thing wherever its result
  goes.

### 3.2 Structs

Value type, copy semantics (passed and returned by value).

**The layout contract has two tiers.** Scalar widths are
identical on every target where the type exists (`i64`/`u64`
are 8 bytes everywhere, whatever the target's arithmetic can
do). A struct's field offsets are per-target, derived from one
rule:

> a field is placed at the next offset that is a multiple of
> `min(its natural alignment, the target's alignment cap)`,
> and `sizeof` rounds the total up to the struct's alignment
> (the max of its fields', capped the same way).

A leaf's natural alignment is its width when that is a power
of two; a nested struct's is its own (capped) alignment; an
array's is its element's. The caps are the target's C ABI:

| target | field cap | tail cap | i.e. |
|---|---|---|---|
| arm64, x86_64, win64, arm9, wasm32 | 8 | 8 | full C natural alignment |
| m68k | 2 | 2 | the m68k C ABI (everything 2-aligned) |
| xt6502 | 1 | 8 | tightly packed, pow2-rounded `sizeof` |

A default struct therefore lays out as the target's C compiler
lays out the equivalent C struct. A naturally padded C header
type (`struct timespec`, `llhttp_t`, …) can be declared in xtc
verbatim, and every member lands where the C side reads it.
Layouts still differ across targets (a pointer is 8 bytes on
arm64 and 3 on the 6502), but each target agrees with its own
platform ABI.

`struct Name :packed { … }` is the other tier: no padding
anywhere. Offsets are the raw sum of field widths and `sizeof`
skips the tail rounding. A `:packed` struct therefore has the
same layout on every target (for fields whose widths do not
vary), and matches kernel and wire layouts byte for byte (for
example epoll_event: u32 @0, u64 @4, size 12). On the
strict-alignment targets (m68k, arm9) a packed multi-byte field
at a misaligned offset draws the `packed-align` warning; the
layout is still emitted as declared.

C structs imported through DWARF (`#import <lib>`) arrive with
their C padding materialised as explicit `__padN` fields and
are marked `:packed`, so their offsets are always the C
compiler's, independent of the rule above.

```c
typedef struct {
    u16 x;
    u8  y;
} CursorPos;

CursorPos topRight = {319, 0};
CursorPos middle   = {159, 100};   // braces and brackets interchangeable
CursorPos middle2  = [159, 100];
```

- Initialiser members are in declaration order. Trailing missing
  members are zero-filled. More elements than the struct holds
  is a compile-time error.
- Return by value is allowed. **Returning a pointer to a
  stack-resident struct is illegal**: the storage is released at
  scope exit.
- `Stdio.printf("%@", s)` recursively formats a struct's
  members.

### 3.3 Enumerations

```c
enum suits = {hearts, clubs, diamonds, spades};
enum directions = {N = 4, S, E, W};   // 4, 5, 6, 7
```

Values start at 0 unless an explicit value is given, and each
subsequent entry increments by 1. The compiler picks the smallest unsigned type
that holds every value.

### 3.4 Arrays

```c
u8  cakes[3];
u8  spaces[]  = {' ', '\t', '\n'};      // size inferred
u16 scores[8] = {100, 87};              // remaining slots zero-filled
```

Array size is part of the type. With an initialiser, the `[ ]`
may be empty.

#### 3.4.1 Range initialiser

Fixed-size integer arrays accept a range as the initialiser:

```c
u8 buf[10] = 0..10;       // 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 (exclusive)
u8 b2[5]   = 1...5;       // 1, 2, 3, 4, 5 (inclusive)
u16 b3[4]  = 100..104;    // 100, 101, 102, 103 (each u16, exclusive)
i8 b4[3]   = -2..1;       // -2, -1, 0 (exclusive)
```

Bounds must constant-fold and produce a count matching the
declared `elementCount`. The element type must be an integer
scalar; float, struct and class arrays need the `{ ... }` form.

#### 3.4.2 `.length`

Both fixed arrays and heap-allocated pointers (from `new T[N]`)
expose a `.length` pseudo-property of type `u16`. For fixed
arrays it constant-folds; for heap pointers it reads the heap
block's header at runtime.

`.length` on a non-heap pointer (a `T*` that did not come from
`new T[N]`) is undefined. Bump-allocator targets store no
header, so `.length` is meaningful only on heap-allocator
targets.

A literal `new T[N]` bound to a local constant-folds on every
target. A runtime-sized `new T[n]` reads the allocation header
(the `_xtc_count` runtime helper) on every target whose
allocator writes an element count. That is every target except
xt6502, whose primitive-array allocator stores no count. There,
a runtime-sized `.length` is a compile-time diagnostic telling
you to keep your own count.

### 3.5 Pointers

Pointer syntax uses `*`, as in C. Whitespace around it is
irrelevant; all three declare the same `u8*`:

```c
u8* p;
u8 *p;
u8 * p;
```

The sigil binds to the type, not the declarator, so
`u8* a, b;` declares **two pointers**. In C, `b` would be a
plain `u8`.

The older `@` sigil is still accepted. It is transitional.

- `&x` takes the address of a value.
- `*p` dereferences. The operand must be a pointer: `*x` where `x` is
  an integer, `bool`, `float` or `double` is a compile error, not a
  reinterpretation of the value as an address. An address held in an
  integer is still writable: name it as a pointer at the point of
  use, `*(u8*)addr`, as the 6502 libraries do. The same rule rejects
  `*p.Real` (C's `(*p).Real` with the parentheses lost) when `Real`
  is a `double`.
- `*` as a unary prefix on a literal denotes a pointer literal:
  `u8* x = $400` makes `x` point at address $400.
- `->` is sugar for "deref then member": `p->x` ≡ `(*p).x`.
  Unlike C, plain `.` on a pointer to a struct or class also
  works; the compiler dereferences automatically.

**Pointer arithmetic follows C.** `p + n` and `p - n` move the
pointer by `n` elements (scaled by the size of the pointee), and
only an integer may be added to or subtracted from a pointer.

The difference of two pointers, `p - q`, is also in elements,
and its type is C's `ptrdiff_t`: a signed integer spanning the
target's address space. It is `i64` where pointers are 8 bytes,
`i32` where they are 4, and `i16` on the banked 6502, whose
3-byte pointer is a 16-bit address plus a bank byte and whose
allocations cannot span banks. So

```c
(p + n) - p == n
```

for every `n`. Both operands should address the same object;
this is not checked.

**A raw pointer is not a class reference** (since 0.4). A value
conversion where exactly one side is a class pointer (`String* s =
buf;`, `u8* p = obj;`, a `u8*` argument into a `String*` parameter, a
string literal into a `String*`) is a compile error at every site:
initialiser, assignment, argument and return. A class reference names
a heap object with a refcount header and a vtable; a raw pointer names
bytes. A silent conversion would dispatch through arbitrary bytes.
Two conversions are allowed: an explicit cast (`(String*)p`) when the
pointer holds an instance, and the untyped `pointer` type, which
converts freely in both directions. To convert between strings and
bytes, use the API: `String.withBytes`/`withCString` to build,
`cString()`/`bytes()` to view.

### 3.6 Casting

C-style `(type)value`. There are two extensions for class
pointers (detailed in §8.4):

- `(Dog@) animal`: trapping downcast (BRK on mismatch).
- `(Dog@ ?) animal`: failable downcast (yields `(Dog@)0` on
  mismatch).

The `?` marker is **class-pointer only**.

### 3.7 Type inference: `auto`

```c
auto x = 3;          // u8
auto x = -3;         // i8
auto x = 257;        // u16
auto x = -259;       // i16
auto x = 65589;      // u32
auto x = -555_555;   // i32
auto x = 4.5;        // float
auto x = "hi";       // string
auto x = true;       // bool

u8 a = 4, b = 5;
auto c = a + b;      // c: u8
u16 d = 500;
auto e = a + d;      // e: u16 (widened)
```

Integer literals pick the smallest type that holds them;
positive → unsigned, negative → signed.

### 3.8 Type aliases: `typedef`

Transparent aliases:

```c
typedef u16   Tick;
typedef u8@   bytes;
typedef RGB[] palette;
```

### 3.9 Protocols as types

A protocol name in a type position (typically `Drawable@`)
accepts any conforming class instance. See §8.5.

---

## 4. Operators

### 4.1 Full precedence table (highest → lowest)

| Level | Operators | Assoc | Notes |
|------|-----------|-------|-------|
| 1 | `a[i]`, `f(...)`, `.`, `->`, postfix `++`, postfix `--` | L | primary |
| 2 | prefix `+ -`, `!`, `~`, prefix `++`, prefix `--`, `@` (deref), `&` (addr-of), `(type)` cast, `sizeof()`, `<` `>` `>>` `>>>` (byte-extract; asm-only) | R | unary |
| 3 | `*` `/` `%` | L | multiplicative |
| 4 | `+` `-` | L | additive |
| 5 | `<:` `:>` | L | rotate (ROL / ROR) |
| 6 | `<<` `>>` | L | shift (ASL / ASR) |
| 7 | `<` `>` `<=` `>=` | L | relational |
| 8 | `==` `!=` | L | equality |
| 9 | `&` | L | bitwise AND |
| 10 | `^` | L | bitwise XOR |
| 11 | `\|` | L | bitwise OR |
| 12 | `&&` | L | logical AND |
| 13 | `\|\|` | L | logical OR |
| 14 | `? :` | R | ternary |
| 15 | `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=`, `<:=`, `:>=` | R | assignment |

### 4.2 Notes on specific operators

**Rotate vs shift.** `<:` and `:>` are **rotate** operators:
they shift by one position through a 1-bit carry, so a value's
high bit becomes the new low bit on the next rotate (the
"chain N bytes through carry" idiom). `<<` and `>>` are
**arithmetic shift** operators: `<<` shifts left and zero-fills
the low bit; `>>` shifts right, sign-extending signed operands
and zero-filling unsigned ones. Use rotate to chain bytes through
carry; use shift to multiply / divide by powers of two.

The target chooses the realisation:

- **6502 family:** `<:` / `:>` map directly to `ROL` / `ROR`
  (which read and write the architectural carry flag). `<<` /
  `>>` map to `ASL` / `LSR` (unsigned right shift) or a small
  inlined `ASR`-equivalent sequence (signed right shift).
- **arm64 / x86-64:** rotate maps to the native rotate-through-
  carry instruction (`RRX` / `RCR` and friends) when the IR
  passes through carry-aware lowering; otherwise the backend
  may synthesise the rotate from shifts + bit-or. Shifts map
  to native `LSL` / `LSR` / `ASR`.

**Pointer deref / addr-of.** `@` (unary prefix) dereferences;
`&` (unary prefix) takes an address. They are inverses.

**`sizeof(T)`** evaluates to a compile-time `u16`. It works on
any type, including structs and classes.

**Byte-extract prefixes** (asm context only; §10):

| Prefix | Meaning |
|--------|---------|
| `<x`   | low 8 bits |
| `>x`   | bits 8..15 |
| `>>x`  | bits 16..23 |
| `>>>x` | bits 24..31 |

Outside `asm { ... }` these tokens parse as their normal
precedences (`<` / `>` relational, `>>` arithmetic shift). The
assembler-level grammar disambiguates by accepting only
constants and symbols after the prefix.

### 4.3 Compound assignment

`+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`,
`<:=`, `:>=`. Behaviour matches the expansion (`x += 1` ⇔
`x = x + 1`). When the left-hand side resolves to a property
setter (§7.4), the base expression is evaluated **twice**. This
is safe for identifiers and `self`; take care when the base has
a side effect.

### 4.4 Logical operators

`&&` and `||` short-circuit, as in C. `!x` is logical
negation. `bool` is a 1-byte alias of `u8` with values 0/1.

---

## 5. Statements & control flow

### 5.1 Variable declarations

```c
u8  myVal;
u8  myVal = 5;
u8  a, b = 1, 2;             // a = 1, b = 2

u8  bytes[32];
u8  rgb[]   = {255, 0, 0};
RGB white   = {255, 255, 255};
RGB white   = [255, 255, 255];   // [..] interchangeable with {..}
```

Brace and bracket initialisers also work on the raw bytes of any
value, regardless of type. Trailing missing bytes are zero-filled.

#### 5.1.1 Storage modifiers

| Modifier | Storage class | Persistence | Visibility |
|----------|---------------|-------------|------------|
| *(default)* | fastest-access (target's preferred register file / scratch area) | local scope | current block |
| `register` | fastest-access (priority allocation) | local scope | current block |
| `volatile` | fastest-access, with store-elimination disabled | local scope | current block |
| `static` | data section | permanent | current file or block |
| `global static` | data section | permanent | every file |

- `register`: a hint to the backend's storage allocator that
  this variable gets priority for the target's fastest-access
  area (zero page on 6502; a register on arm64 / x86-64, when
  liveness permits).
- `volatile`: disables store-elimination and read-caching, so
  every read and write is a real memory access. Use it for
  memory-mapped I/O and any location the compiler should not
  assume is stable across instructions.
- `static`: persists across calls; file-local by default.
- `global static`: persists, and is visible across translation
  units.

"Fastest-access" is abstract. On 6502 the target's storage
allocator hands out zero-page bytes (and sometimes spills); on
arm64 / x86-64 it hands out registers (with stack-slot spills
when liveness or a taken address forces it).

### 5.2 If / else

```c
if (cond) {
    ...
} else if (cond) {
    ...
} else {
    ...
}
```

Condition in `(...)`; body is a block.

### 5.3 Switch

```c
switch (c) {
    case ..12:     break;       // c <= 12   (range, u8 only)
    case 13..18:   break;       // 13..18 inclusive
    case 22:                    // fall through
    case 23:       myFunction(c); break;
    case 40..:     break;       // c >= 40
    default:       break;
}
```

`switch` extends C's form with **range cases**: `..N`, `M..N`,
`N..` (≤N, M..N inclusive, ≥N). Range cases are `u8` only;
single-value cases work on any integer. At `-O2+` the compiler
may emit a jump-table for dense switches.

### 5.4 C-style `for`

```c
for (u8 i = 0; i < 40; i++) {
    ...
}
```

Setup may declare a fresh loop variable scoped to the loop. All
three clauses (init / condition / step) are optional.

### 5.5 For-in over an array

```c
u8 chars[] = {'h', 'e', 'l', 'l', 'o'};
for (u8 ch in chars) { ... }
```

Iterates the array. The loop variable type is usually explicit;
`auto` works. The collection may be a fixed array or a heap pointer
(from `new T[N]`); for heap pointers `.length` is read from the
block header at loop entry.

### 5.6 For-in over a range

```c
for (u8 i in 0..10)  { ... }   // exclusive: 0..9   (10 iters)
for (u8 i in 0...10) { ... }   // inclusive: 0..10  (11 iters)
```

`..` is exclusive and `...` is inclusive, as in Rust.

#### 5.6.1 Stride: `step`

Optional `step <signed-int-literal>` clause:

```c
for (u8 i in 0..10 step 2)    { ... }   // 0, 2, 4, 6, 8
for (u16 i in 100..0 step -5) { ... }   // 100, 95, …, 5
```

Step must be a compile-time integer literal: a bare integer or
its negation, not an expression. A negative step descends.

When both bounds are integer literals, `start > end`, and no
explicit step is given, the loop descends with `step -1`. For non-literal bounds, the loop is ascending unless
you write `step -N` explicitly. Inconsistent combinations
(e.g. `0..10 step -1`) are rejected at parse time.

#### 5.6.2 Type inference

When no loop type is given and the bounds + step are all
`u8`-fitting integer literals, the loop variable defaults to
`u8`. Anything else needs an explicit type.

#### 5.6.3 Caveat — unsigned descending wrap

`for (u8 i in 20..0 step -3)` walks 20, 17, …, 2, then `2 - 3`
wraps to 255 and the loop continues. Align bounds with step (`21..0 step
-3`) or widen the loop variable to `u16`/`i16`.

#### 5.6.4 Lowering

The range form is rewritten to an equivalent C-style `for` at
parse time:

| Source | Equivalent C-style |
|--------|--------------------|
| `for (T i in 0..N)`     | `for (T i = 0; i < N; i += 1)` |
| `for (T i in 0...N)`    | `for (T i = 0; i <= N; i += 1)` |
| `for (T i in 0..N step 2)` | `for (T i = 0; i < N; i += 2)` |
| `for (T i in N..0)` (literal) | `for (T i = N; i > 0; i -= 1)` |
| `for (T i in N..0 step -3)` | `for (T i = N; i > 0; i -= 3)` |

### 5.7 For-in over an array slice

```c
u8 arr[10] = {10,20,30,40,50,60,70,80,90,100};
for (u8 v in arr[2..5])  { ... }   // 30, 40, 50
for (u8 v in arr[2...4]) { ... }   // 30, 40, 50 inclusive
for (u8 v in arr[..3])   { ... }   // 10, 20, 30 (open start = 0)
for (u8 v in arr[7..])   { ... }   // 80, 90, 100 (open end = .length)
```

Bounds may be any integer expression. Heap pointers also work,
with `.length` from the block header for the open-end form.
Slice expressions are valid **only** as the iterable of a
for-in loop. There are no first-class slice values.

### 5.8 While

```c
while (cond) { ... }
```

The body runs while the condition is non-zero.

### 5.9 Loop control

- `break` exits the enclosing loop.
- `continue` skips to the loop's increment and re-test.

### 5.10 Manual unrolling: `:unroll`

The auto-unroller runs at `-O2+` for counted `for` loops with a
small trip count (default ≤5; tunable with `-Flu`). `:unroll`
forces an unroll regardless of trip count or `-O` level:

```c
for (u8 i = 0; i < 40; i++) :unroll {
    poke(scrn + i, ' ');
}
```

The annotation goes after the closing `)` and before the body.

### 5.11 Program entry: `main`

Execution begins at `main`. Two signatures are accepted:

```c
void main(void) { ... }
i16  main(u8 numArgs, string args[]) { ... }
```

When `main` returns, the program issues `RTS` to the caller,
unless `-Q loop` is passed, in which case the runtime loops
forever.

---

## 6. Functions

### 6.1 Declaration

```c
u16 add(u8 a, u8 b) {
    return a + b;
}

void greet(string name) {
    Stdio.printf("hello, %s\n", name);
}
```

Forward declarations (signature without body, terminated with
`;`) work as in C. A function may be called before its
definition in the same compilation unit, so forward declarations
are mainly needed to declare external functions in headers.

### 6.2 Tuple returns

A function may return multiple values. The return type is a
comma-separated list; the `return` statement carries a matching
list of values:

```c
u8, u16 myFunc(void) {
    return 42, 1969;
}
```

Tuples are unpacked at the call site:

```c
(u8 x, u16 y) = myFunc();    // declares fresh variables
u8 x; u16 y;
(x, y) = myFunc();           // assigns to existing
```

If the return type is `void`, `return` has no arguments.

### 6.3 Varargs

A function with `...` as the last parameter is variadic:

```c
void printAll(string fmt, ...) { ... }
```

**A body-less variadic declaration names a C function.** With no
xtc body to walk a pack, the call is made with the target's C
calling convention: the trailing arguments are C-default-promoted
(`float` → `double`, sub-`int` integers widen) and passed as the
platform ABI requires, with no pack buffer and no `va_list`.

```c
i32 dprintf(i32 fd, u8* fmt, ...);   // C linkage: fcntl, ioctl,
dprintf(1, "n=%d\n", n);             // open(2), the printf family
```

The rest of this section describes variadics with an xtc body,
which use the pack-buffer convention.

Walk the argument pack with `va_start`, `va_arg`, `va_end`. The
cursor `ap` is a `u8` that the compiler advances per read:

```c
u8 ap;
va_start(ap);
u16    n = va_arg(ap, u16);
string s = va_arg(ap, string);
va_end(ap);
```

Supported `va_arg` types: `u8`, `i8`, `u16`, `i16`, `u32`, `i32`,
`float`, `double`, `string`, and `T@` for any pointer-to-type.

**Pointer-to-struct from varargs:** `va_arg(ap, T@)` where `T` is
a user-defined struct returns a typed pointer **into the pack
buffer** and advances the cursor by `sizeof(T)`. The returned
pointer is valid **only for the lifetime of the variadic call**.

**Shared pack buffer + reentrance:** All varargs functions share
a single 64-byte pack buffer. A variadic `F` that has called
`va_start` cannot call another variadic `G`, because the call
would clobber `F`'s buffer mid-walk. Semantic analysis diagnoses
this. Pure forwarders (variadics that never call `va_start` and
only pass their `...` to another variadic) are exempt.

The per-call payload cap is 62 bytes (64 minus a 2-byte format
header). `printfAt` uses 7 header bytes, so its cap is 57.

### 6.4 Inline expansion at the call site

```c
u8 myVal = inline:calculate(4, 5);
```

`inline:` directs the compiler to inline the callee at this
call, independent of the `-O2` leaf-inliner heuristic.

### 6.5 Function overloading

Overload by parameter type:

```c
void show(u32 val)   { ... }
void show(u8 val)    { ... }
void show(string s)  { ... }
```

Overloading by return type also works. The compiler picks the
overload from the assignment context:

```c
float  myValue(void) { ... }
i16    myValue(void) { ... }
string myValue(void) { ... }
```

### 6.6 Function annotations

Annotations follow the parameter list, each introduced by `:`.
They are case-insensitive.

```c
void fn(void) :naked      { ... }
void fn(void) :needsOS    { ... }
void fn(void) :irq        { ... }
void fn(void) :vbi        { ... }
void fn(void) :banked     { ... }
void fn(void) :main       { ... }
void fn(void) :shadow     { ... }
void fn(void) :cloaked    { ... }
void fn(void) :cloaked(extN) { ... }
```

**Calling convention / prologue:**

- `:naked`: no prologue or epilogue. You write whatever the
  body needs. Mutually exclusive with `:irq` / `:vbi`.

**Interrupt handlers (6502 platforms):**

- `:irq`: emitted naked, ends with `RTI`. You install the
  address in the IRQ vector.
- `:vbi`: VBI handler. The prologue saves A/X/Y, the body runs,
  and the epilogue restores them and `JMP`s through `XITVBV`
  ($E462). Install it with `Vbi.addImmediate(&fn)` /
  `Vbi.addDeferred(&fn)`.

On banked targets (xt / xe), `:irq` and `:vbi` handlers are
placed in main RAM at a stable address. The OS dispatcher
`JMP`s through their vector slot directly, so the bank-switch
trampoline cannot intervene.

**Placement (6502 platforms):**

- `:banked`: force into the bank window. On a non-banked target
  this warns and falls back to `:main`.
- `:main`: force into main RAM (overrides the xt / xe auto-bank
  default).
- `:shadow`: place under the OS ROM. Unreachable when the ROM is
  mapped in; do not call it from a `:needsOS` function.
- `:cloaked` / `:cloaked(<id>)`: xe family only. Place in a
  layout-declared cloaked region.

`:banked`, `:main` and `:shadow` are mutually exclusive.

**Shadow-target helper (Atari):**

- `:needsOS`: wraps the body with ROM enable / disable on
  shadow targets (no-op elsewhere).

On non-6502 architectures, placement annotations are accepted
but have no effect, because there is only one address space.
`:naked` still applies (the backend skips the standard
prologue).

### 6.7 Default calling convention

Each target has a single stack. Parameters, return addresses,
saved registers, and locals all share it. The backend's ABI
determines the layout:

- **xt 6502:** the caller pushes parameters with `PHA` and the
  callee reads them with SP-relative loads. The frame uses
  `PSH #N` / `PLL #N`, a saved-register block at fixed offsets,
  and parameters starting at +N+9.
- **arm64-macOS:** AAPCS64. Integer parameters 0..7 are in
  `x0..x7` and the return value is in `x0`. The frame uses the
  standard `stp x29, x30, [sp, #-FRAME]!` prologue.

There is no separate software stack for parameters: on xt, the
CPU's 4 KB hidden hardware stack holds parameters and return
addresses. The `:hwStack` / `:xtcStack` annotations are
obsolete.

### 6.8 Blocks

A **block** is a function with a body written where a value is
expected, plus the state it captured when it was created. It is a heap
object, ARC-managed like any other, and it can outlive the function
that made it.

The keyword is the kind, **the name is the second token**, and the
signature follows. `callback` uses the same shape (§9A):

```c
block b u32(u16 x, u16 y) = { return (u32)x + (u32)y; }
Stdio.printf("%ld\n", b(2, 3));                  // 5
```

Declared without a body, a block is filled later. Once it has a
declaration, the body alone is enough; the signature is inherited and
not repeated:

```c
block d u32(u16 x, u16 y);
d = b;                                           // another block
d = { return (u32)x * (u32)y; };                 // a bare body
auto e = d;                                      // `auto` works too
```

#### Captures are a snapshot

A block copies what it reads at the moment it is created. Later writes
by the enclosing function are not visible to it:

```c
u32 base = (u32)100;
block c u32(u16 n) = { return base + (u32)n; }
base = (u32)999;                                 // c still sees 100
Stdio.printf("%ld\n", c(7));                     // 107
```

To let a block change the enclosing variable, mark it `block:` at its
declaration. It is copied in at creation and **written back** at every
invocation's exit, so the enclosing frame is correct the statement
after a block-taking call returns:

```c
block:u32 total = (u32)0;
u32 r = drive(block u32(u32 v) { total = total + v; return v; }, (u32)5);
Stdio.printf("%ld %ld\n", total, r);             // 10 10
```

A read-only capture stays a snapshot even alongside a `block:` capture;
the two kinds are independent.

#### As a parameter, and as a result

A block parameter is declared like the variable:

```c
u32 fn(block blk u32(u16 x, u16 y))
{
    return blk(3, 4) * blk(4, 5);
}
```

A block may be **returned**, and its captures come with it. They are
ivars of the block object, which ARC owns, so they outlive the frame
that created them:

```c
block cb u32(u32 n) makeAdder(u32 base)
{
    block a u32(u32 n) = { return base + n; }
    return a;
}

auto add5 = makeAdder((u32)5);
auto add9 = makeAdder((u32)9);
Stdio.printf("%ld %ld\n", add5((u32)10), add9((u32)10));   // 15 19
```

This is the difference from a `callback`: **a block owns what it
captured; a callback owns nothing.** A stored block keeps its captures
alive; a stored callback goes empty when its receiver dies. §9A.9
compares the two.

#### The empty block

Cast zero to the block's type, and guard the same way:

```c
block maybe u32(u32 n);
maybe = (block u32(u32))0;
if (!maybe) { Stdio.printf("nothing to run\n"); }
```

`block` is a **contextual** keyword: it opens a declaration only when a
type follows, so an existing program that uses `block` as an ordinary
name keeps working.

---

## 7. Classes

A class has instance variables (ivars), methods, an optional
`init` constructor, and an optional `dealloc` destructor. By
convention classes are one-per-file as `<classname>.xc` so
`#import "Foo.xc"` resolves. The compiler does not enforce this.

```c
class Gfx {
    u8 red;
    u8 green;
    u8 blue;

    void hLine(u16 x, u8 y, u8 len) { ... }
}
```

### 7.1 Two allocation flavours

#### Stack instance

```c
MyClass mine;
```

- Zero-fills storage in the enclosing scope.
- Runs parameterless `init()` if present.
- Reuses bytes at scope exit (no heap touch).

#### Heap instance

```c
MyClass@ mine = new MyClass();
```

- Allocates on the heap, refcount = 1.
- Scope exit emits an automatic `release` of the variable's
  reference. This is not optional: ARC is always on.

#### Parameterised construction

Both forms accept an argument list dispatched to a matching
`init(...)`:

```c
class Sprite {
    u16 x; u16 y; u8 tint;
    void init(void)                 { x = 0;  y = 0;  tint = 0; }
    void init(u16 px, u16 py)       { x = px; y = py; tint = 0; }
    void init(u16 px, u16 py, u8 t) { x = px; y = py; tint = t; }
}

Sprite  origin;                       // stack, init()
Sprite  ship(160, 96);                // stack, init(160, 96)
Sprite@ boss = new Sprite(80, 40, 7); // heap, init(80, 40, 7)
```

Calling `Sprite ship(160, 96);` against a class that only has
`init(void)` is a compile-time error.

### 7.2 Methods, `init`, `dealloc`

```c
class Counter {
    u16 n;
    void init(void)  { n = 0; }
    void tick(void)  { n = n + 1; }
    u16  value(void) { return n; }
}

Counter c;
c.tick(); c.tick();
Stdio.printInt(c.value());     // 2
```

- The receiver `self` is implicit inside the body.
- Multiple `init` overloads are supported via the standard
  overload-resolution rules.
- `dealloc(void)` runs when a heap-allocated instance's refcount
  hits zero, **before** the bytes return to the free list. Every
  class gets an auto-generated empty `dealloc` stub. Override
  only for external state (file handles, mapped I/O, caches the
  ARC walker cannot see). It runs once; for arrays of class
  instances, once per element.

xtc has method overloading but **no operator overloading**.

### 7.3 Static methods + `use ClassName`

A `static` method is a class-scoped function. It is callable
without an instance and has no access to ivars:

```c
class Math {
    static u16 lerp(u16 a, u16 b, u8 t) {
        return a + (((b - a) * t) >> 8);
    }
}

u16 mid = Math.lerp(0, 100, 128);
```

The top-level `use ClassName;` directive promotes a class's
static methods into the bare-identifier call space for the rest
of the file:

```c
#import <Stdio.xc>
use Stdio;

void main(void) {
    printf("answer = %u\n", 42);     // resolves to Stdio.printf
}
```

- Multiple `use` directives stack.
- The directive is scoped to the textual file (not propagated
  across `#import`).
- Ambiguous resolution (two `use`'d classes both expose the
  same name with a matching overload) is a compile-time error;
  write `Klass.method(...)` to disambiguate.
- Only bare identifier lookup is affected. Fields, locals, free
  functions and explicit `Klass.method(...)` calls are not.

An ivar may also be `static`. It then has **one instance for the
whole class** rather than one per object. This class-level state
is shared by every instance and by the class's static methods,
and is visible under its bare name in both:

```c
class Counter {
    static u16 made;          // one copy for the class
    static u16 limit = 7;     // …initialised once, before main
    u16 id;                   // one per instance

    void init(void)  { made = made + 1; id = made; }
    u16  myId(void)  { return id; }               // per instance
    static u16 total(void) { return made; }       // same variable
}
```

- A static ivar occupies **no space in an instance**. It is not
  part of the object's layout, and it is not copied, released or
  torn down when an instance dies.
- Its initialiser must be a compile-time constant; it is written
  at load time, not on any `init`. Without one it starts zeroed.
- Subclasses share the parent's copy: `class Tally : Counter`
  reads and writes the same `made`.
- Two classes may declare the same static ivar name without
  interfering; the name is class-scoped, like a method's.
- Uninstantiated "static classes" (`Stdio`, `Assert`) are
  unaffected; their ordinary ivars keep their existing meaning.

### 7.4 Properties: getter / setter rewrite

Dot-syntax member access is rewritten into a method call **when
a method by that name exists**:

- **Read** `obj.name` rewrites to `obj.name()` when a zero-arg
  method `name` exists on the class.
- **Write** `obj.name = value` rewrites to `obj.setName(value)`
  when a one-arg method `setName` exists whose parameter accepts
  `value`'s type.

Camel-casing applies (`foo` ↔ `setFoo`, `lineWidth` ↔
`setLineWidth`). Either half is optional; a missing side falls
through to direct ivar access.

```c
class Box {
    u8 _w;                              // backing ivar (underscored)
    void init(void) { _w = 0; }
    u8   w(void)    { return _w; }
    void setW(u8 v) { if (v > 100) v = 100; _w = v; }
}

b.w = 150;      // calls setW(150); _w becomes 100
u8 v = b.w;     // calls w(); returns 100
```

**Warning:** writing `self.w` inside the `w()` getter recurses
infinitely. Read the bare ivar (`_w`) instead. The
leading-underscore convention helps.

Compound assignment desugars through both sides: `b.w += 1`
becomes `b.w = b.w + 1`. The base expression is evaluated
**twice** in the desugared form. This costs nothing for
identifiers and `self`; take care when the base has a side
effect.

---

## 8. Inheritance & protocols

### 8.1 Single inheritance

```c
class Animal {
    u8 legs;
    void init(void)     { legs = 4; }
    void describe(void) { Stdio.printf("animal\n"); }
}

class Dog : Animal {
    u8 tailWag;
    void describe(void) { Stdio.printf("dog\n"); }   // override
    void wag(void)      { tailWag = tailWag + 1; }   // new
}
```

Ivars and methods inherit. Children can add ivars / methods, and
override any inherited method by redeclaring its signature.

Every class without an explicit parent inherits from the
universal `Object` base: `class Foo { ... }` and `class Foo :
Object { ... }` mean the same thing.

### 8.2 Construction and destruction chaining

- `init`: the compiler inserts an implicit call to the parent's
  matching `init` at the **top** of the subclass's body. If no
  parent `init` matches the call's argument list, the class is
  rejected at compile time. Write `super.init(...)` explicitly
  to suppress the implicit call (e.g. to pass different args).
- `dealloc`: chains in **reverse**. The subclass body runs first,
  then the compiler emits an implicit call to the parent's
  `dealloc` at the **end** of the subclass's body. An explicit
  `super.dealloc()` suppresses the implicit call.

Both chains walk up to `Object`.

### 8.3 Virtual dispatch

Overridden methods dispatch through a per-class **vtable**. Every
class has a unique class-id byte; `new` stamps the id into the
first byte of the allocation; a call site reads the id and
indexes the class's vtable for the method slot.

Methods that are **never overridden** keep a direct `JSR`. The
vtable is used only for methods that some subclass overrides.

`super.method()` always calls the parent's body directly,
skipping the vtable, regardless of further subclassing.

### 8.4 Casting class pointers

| Cast | Behaviour |
|------|-----------|
| Upcast (subclass → ancestor) | Implicit, no check, compile-time no-op |
| Same-class cast | Compile-time no-op |
| Trapping downcast `(Dog@) animal` | Runtime class-id walk; BRK on mismatch |
| Failable downcast `(Dog@ ?) animal` | Runtime class-id walk; yields `(Dog@)0` on mismatch |
| Unrelated-tree cast | Compile-time error |
| `(u16 ?)x` | Compile-time error: `?` is class-pointer only |

A null operand passes through unchanged for both downcast
flavours.

### 8.5 Protocols

A protocol is a named interface: a list of method signatures
with no bodies, no ivars and no implementation:

```c
protocol Drawable {
    void draw(void);
    u8   width(void);
}
```

Bodies, ivars, static methods, and nested decls inside a
protocol are rejected at parse time.

#### Conformance

A class adopts protocols via a `<...>` clause after the class
name (and after `: Parent` if present):

```c
class Sprite <Drawable> {
    u8 w;
    void init(void)   { w = 16; }
    void draw(void)   { Stdio.printf("sprite\n"); }
    u8   width(void)  { return w; }
}

class Badge : Sprite <Labelled> {       // parent + protocol
    void label(void)  { Stdio.printf("badge\n"); }
}
```

Either clause is optional. A class that claims conformance but
omits a method is rejected at compile time. **Subclasses
inherit their parent's conformances**: a subclass of `Sprite`
does not re-list `Drawable`.

#### Protocol-typed values

A protocol name in a type position (typically `Drawable@`)
accepts any conforming class instance:

```c
void render(Drawable@ d) { d.draw(); }

Sprite@  s = new Sprite();
render(s);                 // calls Sprite.draw
```

Passing a non-conforming instance is a compile-time error.

#### Dispatch

Calls through a protocol-typed pointer go through the per-class
vtable. Every protocol method gets a global slot; each conforming
class's implementation lands in that slot in its own vtable. Each
call is one indirect `JMP`, with no string lookup.

When two protocols declare a method with the same name and
signature, each gets its own slot, and a class conforming to
both fills both slots with the same implementation. A call
through either protocol reaches that implementation.

#### Optional methods

A protocol method marked `optional` may be omitted by a conforming
class:

```c
protocol WindowDelegate {
    void windowDidResize(Window@ w);            // required
    optional bool windowShouldClose(Window@ w); // may be absent
}
```

Conformance checking enforces only the required set. An omitted
optional method leaves its vtable slot empty (a null word), which
makes it detectable: a bound method reference to it is an **empty**
callback, so `if (h)` is the "does it respond?" test. See §9A.7.

Calling an optional method **directly** is a compile error, because
it would jump through a zero slot. Take `&d.m` and test the result,
which also covers a null receiver:

```c
callback h bool(Window* w);
h = &delegate.windowShouldClose;   // empty if absent OR delegate is null
if (h) { shouldClose = h(win); }
```

---

## 9. Heap, ARC, and weak references

The heap is a coalescing free-list allocator with refcounted
ownership. It is available on layouts that declare a `[heap]`
region: `xl-shadow`, `xe-nobank`, `xt`, `xe-heap`, and `rambo*` /
`compy*`. On those targets `-falloc=heap` is the default. Layouts
without `[heap]` fall back to a bump allocator, and heap-only
statements are rejected during semantic analysis.

### 9.1 Allocation

Every successful `new` zero-fills the payload and sets refcount
= 1:

```c
MyClass@ p   = new MyClass();       // class instance — init() runs
MyClass@ q   = new MyClass(4, 2);   // parameterised init
RGB@ pixel   = new RGB;             // struct scalar
u8@ buf      = new u8[128];         // array of primitives
MyClass@ mob = new MyClass[8];      // array of class instances
```

`new T[N]` is the only way to allocate an array on the heap. For
arrays of class instances, every element is zero-filled and its
`init()` runs.

On out-of-memory, `new` returns null.

### 9.2 Automatic reference counting (ARC, default)

Every heap block has a 4-byte header before the payload:

- 15-bit size
- 1 free-flag bit
- 16-bit retain count

The compiler emits retain / release operations at:

| Event | What the compiler emits |
|-------|--------------------------|
| `Foo@ a = new Foo()` | take the allocator's +1; no extra retain |
| `Foo@ b = a` (borrowed read) | retain `a`'s pointee |
| `var = expr` | release the old pointee; retain the new if borrowed, else absorb the +1 if `expr` is a producer (`new` / call) |
| scope exit | release every tracked strong class-pointer local, LIFO |
| class dealloc | when refcount hits 0, the aggregate walker releases every strong class-pointer ivar recursively before freeing |

Two calling-convention rules:

- **Always-`+1` returns.** A function returning a class pointer
  hands the caller an owning reference.
- **Callee-retains-params.** A class-pointer parameter is
  retained on entry and released on exit. This is net-neutral
  for transient use; stores that outlive the call (into globals
  or other heap objects) pick up the +1.

Under ARC, the manual `retain` / `release` / `delete` statements
on class instances are **rejected during semantic analysis**
(§9.5).

### 9.3 The dealloc callback

`dealloc(void)` runs once when the last owning reference drops,
**before** the bytes return to the free list. Every class gets an
auto-generated empty `dealloc` stub. Override it only for
external state; the aggregate walker releases strong
class-pointer ivars.

For arrays of class instances, `dealloc` runs once per element
before the block is freed.

### 9.4 Weak references

`weak:T@` is a non-owning class-pointer slot, invisible to
refcounting. Assigning to it does not retain, and releasing the
pointee does not consult it. The runtime tracks every
live weak slot in a bounded side table; when a block's refcount
hits 0, the dealloc path zeros every weak slot pointing at it,
so reads after that return null.

```c
class Child {
    weak:Parent@ dad;     // non-owning back-pointer
    u8 tag;
}

class Parent {
    Child@ kid;           // strong, owning
    u8 tag;
}
```

Slot shapes:

```c
weak:Foo@ g;                     // module-scope global
weak:Foo@ local;                 // stack-resident local
weak:Foo@ arr[8];                // stack array
class Observer {
    weak:Subject@ target;        // ivar
}
```

**Rules:**

- **Class pointers only.** `weak:u8@` is rejected at compile time.
- **Use `weak:banked:T@`** when the pointee is itself banked.
  Bare `weak:T@` uses whatever placement a bare `T@` would on
  the target.
- **No cycle collector.** `weak:` tells the compiler which edge
  in a cycle is the non-owning one.
- **Reading is a plain pointer read.** A non-null weak slot is
  guaranteed to point at a live block, so `if (w != 0) ...` is
  enough.

**Side-table sizing.** The default is 64 entries; the maximum is
255. Each entry costs 6 bytes (obj lo/hi/bank, slot lo/hi/bank).
Raise the cap with `[weak] entries = 128` in the linker script.

### 9.5 Freeing what ARC does not own

ARC owns **class instances**, both single objects and arrays of
them. The compiler manages their lifetime: `retain`, `release`
and `delete` on a class instance are rejected during semantic
analysis, because a hand-written decrement on top of an inserted
one frees an object that is still aliased.

`delete` frees everything ARC does not manage:

```c
u8@ buf   = new u8[20];      delete buf;     // primitive array
Point@ ps = new Point[4];    delete ps;      // array of structs
```

There is no manual-lifecycle mode. The `-farc=off` flag is
accepted and warns that it has no effect; the build emits the
same retains and releases as without it.

### 9.6 Introspection (`Heap` library)

| Method | Type | Meaning |
|--------|------|---------|
| `Heap.size()` | `u32` | total free bytes across reserved banks |
| `Heap.largest()` | `u16` | size of the biggest single free extent |
| `Heap.totalSize()` | `u32` | compile-time heap capacity |

### 9.7 Limits

Language-level limits that apply across all targets:

- **Retain counts saturate at $FFFF** (65535).
- **Weak side table** defaults to 64 entries; max 255.

Target-specific limits (6502 platforms):

- **Maximum single block size is bounded by the underlying
  bank-page size.** On `xe-heap` that is one 16 KB bank page; on
  `xt` the data bank is 12 KB; on unbanked layouts (`xl-shadow`,
  `xe-nobank`) the cap is the size of the contiguous `[heap]`
  region. Multi-bank layouts hold more in total, but no single
  allocation spans a bank boundary.
- On `xt` and `xe-heap`, **any function or method that touches
  a heap pointer must be annotated `:main`**. A `:banked`
  function runs with its own bank selected, so the heap bank is
  not visible during the call.

On arm64 / x86-64 and similar architectures with a single flat
address space, neither the per-block bank-page cap nor the
`:main` rule applies. `new T[N]` is bounded only by the host
allocator's available memory, and any function may touch any
pointer.

---

## 9A. Bound methods (`callback`)

`&obj.method` yields a **bound method**: a two-word value pairing a
receiver with an implementation. Calling it calls that method on that
object. There is no separate "context" argument, so the wrong receiver
cannot be paired with the wrong function.

A variable that holds one is declared with `callback` (since 0.5). The
keyword is the kind, **the name is the second token**, and the signature
follows:

```c
callback onDone void(i32 status);
//       ^^^^^^ name
//              ^^^^^^^^^^^^^^^^ signature: return type, then parameters
```

Parameter names in the signature are documentation, not part of the
type: `callback f void(i32 n)` and `callback f void(i32)` declare the
same thing, and either can be assigned to the other.

The older spelling is the `^` sigil, which needs a `typedef` to bind
to:

```c
typedef void act_t(i32);
act_t^ onDone;                    // same type, older spelling — see §9A.8
```

Both spellings intern to the same type, so they are interchangeable in
either direction with no conversion.

**Use `callback`. `^` is transitional and still accepted**, on the
same terms as `@` for pointers: existing code keeps compiling, and the
sigil will be removed when nothing depends on it. The standard library
uses `callback` throughout (`Array`, `Pool`, `Thread`).

Because they are the same type, a `^`-declared value may be passed to
a `callback` parameter and vice versa, and a library may change its own
spelling without its callers changing.

### 9A.1 What can fill one

Three things, all called through the same ABI:

| filled with | example | receiver word |
|---|---|---|
| a bound method | `&c.save` | the object |
| a plain function | `&freeFunction` | none (widened) |
| a static method | `&Controller.onClick` | none (it is a function pointer) |

A plain function pointer implicitly widens to a callback. A callback
does **not** narrow back: it is two words and has no C-ABI equivalent,
so it cannot be passed where a plain function pointer is expected.

### 9A.2 A local callback

```c
#import "Stdio.xc"

class Counter
{
    i32 total;
    void init(void)     { total = (i32)0; }
    void add(i32 n)     { total = total + n; }
}

i32 main(void)
{
    Counter* c = new Counter();

    callback f void(i32 n);         // declare: keyword, name, then signature
    f = &c.add;                     // fill: a method bound to its receiver
    if (f) { f((i32)7); }           // call through the variable

    Stdio.printf("total=%d\n", c.total);
    return 0;
}
```

```
total=7
```

### 9A.3 As a parameter

This is the common case: a function that calls back into whatever the
caller nominated. The parameter is declared as a variable is:

```c
// `Counter` is the class from §9A.2.
void forEach(i32* xs, u16 n, callback visit void(i32 x))
{
    for (u16 i = (u16)0; i < n; i = i + (u16)1) { visit(xs[i]); }
}

i32 main(void)
{
    Counter* c = new Counter();
    i32 xs[3];
    xs[0] = (i32)1; xs[1] = (i32)2; xs[2] = (i32)3;

    forEach(&xs[0], (u16)3, &c.add);        // no context argument
    Stdio.printf("total=%d\n", c.total);    // total=6
    return 0;
}
```

There is no `void* userData` passed through `forEach` and handed
back. The receiver is part of the value.

### 9A.4 As a return type

The header goes where a return type goes, and the function's own name
follows it:

```c
class Ops
{
    i32 pad;
    void init(void)     { pad = (i32)0; }
    i32 dbl(i32 n)      { return n * (i32)2; }
    i32 neg(i32 n)      { return (i32)0 - n; }
}

callback op i32(i32 n) chooseOp(Ops* o, bool doubling)
{
    if (doubling) { return &o.dbl; }
    return &o.neg;
}

i32 main(void)
{
    Ops* o = new Ops();
    auto op = chooseOp(o, true);            // `auto` infers the callback type
    Stdio.printf("r=%d\n", op((i32)21));    // r=42
    return 0;
}
```

### 9A.5 As a class member — the delegate

A callback **ivar** implements the delegate/observer pattern, and
relies on the auto-zeroing rule (§9A.6):

```c
class Model
{
    i32 value;
    void init(void)      { value = (i32)0; }
    void onTick(i32 n)   { value = value + n; }
    void dealloc(void)   { Stdio.printf("listener died\n"); }
}

class Timer
{
    callback tick void(i32 n);          // no keyword: a stored callback
    void init(void) { }                 //   auto-zeroes when its receiver dies
    void fire(i32 n)
    {
        if (tick) { tick(n); }
        else      { Stdio.printf("no listener\n"); }
    }
}

i32 main(void)
{
    Timer* t = new Timer();

    {
        Model* m = new Model();
        t.tick = &m.onTick;
        t.fire((i32)5);
        Stdio.printf("value=%d\n", m.value);
    }                                   // m's scope ends; ARC releases it

    t.fire((i32)5);                     // the guard now takes the else branch
    return 0;
}
```

```
value=5
listener died
no listener
```

In the second `fire`, the timer has outlived its listener, and the
existing `if (tick)` guard catches it.

### 9A.6 Ownership

**A callback never owns its receiver**, and a **stored callback always
auto-zeroes**.

Almost every callback is a back-reference (a control into its
controller, a window into its delegate), and those are the edges that
close a retain cycle, so a callback does not own its receiver.

An unowned field that did not zero would fail undetectably: nothing
writes to a pointer when its target is freed, so the receiver word
would keep its old, non-null value, and an `if (f)` guard would pass
and call through a freed object.

A callback **field** is therefore registered automatically and goes
falsy as soon as its receiver is deallocated. There is no keyword and
no opt-out. A callback holding a widened function costs nothing: a
code address never dies, so no slot is taken. Only object receivers
consume the weak table.

### 9A.7 Truthiness, `respondsTo`, and the empty value

A callback is **falsy** when it cannot be called, which covers both:

- the receiver was null, or has since been deallocated
  (`&nullDelegate.m` yields an empty callback, it does not fault); and
- the method is an `optional` protocol method the class did not implement.

One test covers both, so `if (h)` is the "does it respond?" query.
There is no separate `respondsTo`:

```c
protocol WinDelegate
{
    void          winDidResize(void);      // required
    optional bool winShouldClose(void);    // may be absent
}

void probe(WinDelegate* d, u16 tag)
{
    callback h bool(void);
    h = &d.winShouldClose;                 // empty if d is null OR d's class
    if (h) { Stdio.printf("%d responds, close=%d\n", tag, (u16)h()); }
    else   { Stdio.printf("%d does not respond\n", tag); }
}
```

```
1 does not respond
2 responds, close=0
```

To empty a callback explicitly, cast zero to its type, as with
`block`:

```c
f = (callback void(i32))0;
if (!f) { /* nothing to call */ }
```

Binding through a **base** pointer still reaches the derived override,
because a callback records the method, not the address the base pointer
would have dispatched to:

```c
class Base            { u16 tag(void) { return (u16)1;  } }
class Derived : Base  { u16 tag(void) { return (u16)42; } }

Derived* d = new Derived();
Base*    b = d;

callback t u16(void);
t = &b.tag;
Stdio.printf("tag=%d\n", t());          // tag=42
```

### 9A.8 Identity, and the two spellings

Two callbacks naming the same action compare equal, so
`removeListener(&f)` finds what `addListener(&f)` stored:

```c
callback f void(i32 n);
callback g void(i32 n);
f = &c.a;  g = &c.a;   //  f == g   is true
g = &c.b;              //  f == g   is now false
```

`==` and `if (f)` ask **different questions**. `if (f)` asks "is this
still callable?" and reads the receiver word, which auto-zeroing
clears. `f == g` asks "do these name the same action?" and compares
both words. After a receiver dies, `!f` is true while `f == 0` is
false, because the code word still holds a method address. **Use
`if (f)` for liveness.**

The two spellings are one type, and mix freely:

```c
typedef void act_t(i32);

callback f void(i32 n);
f = &c.add;

act_t^ old = f;        // new spelling  → transitional sigil
callback back void(i32 n);
back = old;            // transitional sigil → new spelling
```

### 9A.9 `callback` is not `block`

They look alike but are not interchangeable. They differ in
ownership:

| | `callback` | `block` |
|---|---|---|
| what it is | an action on an object that already exists | a new object holding a copy of what it captured |
| owns | nothing, not even its receiver | its captures, strongly |
| when the target dies | goes falsy; the guard catches it | cannot happen; it holds them alive |
| written as | `&obj.method` | a literal body `{ … }` |

```c
    // A callback names an action on an object that already exists. It does
    // not own the object, and it empties itself if the object dies.
    callback cb void(i32 n);
    cb = &c.add;
    cb((i32)10);

    // A block is a new object holding a copy of what it captured. It OWNS
    // its captures, and they live as long as the block does.
    i32 bias = (i32)100;
    block bl i32(i32 n) = { return bias + n; }
    bias = (i32)999;                        // the block kept the snapshot

    Stdio.printf("total=%d block=%d\n", c.total, bl((i32)5));
```

```
total=10 block=105
```

Choose by lifetime: a callback for "tell this object when something
happens", a block for "here is some work, hold onto it". Neither
converts to the other.

### 9A.10 Arrays, and calling from anywhere

A callback can be stored anywhere a value can, and **called from
wherever it is stored**, without a copy to a local first. An array of
them is a dispatch table:

```c
class Ops
{
    i32 pad;
    void init(void)  { pad = (i32)0; }
    i32 inc(i32 n)   { return n + (i32)1; }
    i32 dec(i32 n)   { return n - (i32)1; }
}

i32 main(void)
{
    Ops* o = new Ops();

    callback tbl[2] i32(i32 n);        // the declarator binds to the NAME
    tbl[0] = &o.inc;
    tbl[1] = &o.dec;

    for (u16 i = (u16)0; i < (u16)2; i = i + (u16)1) {
        Stdio.printf("tbl[%d](5)=%d\n", i, tbl[i]((i32)5));
    }
    return 0;
}
```

```
tbl[0](5)=6
tbl[1](5)=4
```

The callee may be any expression of callback type: a subscript, a
struct field, another object's ivar, or what a call returned:

```c
tbl[0]((i32)5);          // a subscript
s.fn((i32)6);            // a struct field
w.onChange((i32)7);      // another object's ivar
chooseOp(o, true)(21);   // what a call returned
```

All of this holds for `block` as well, in the same spellings.

---

## 10. Inline assembly

```c
asm {
    lda #$ff;
    sta $D40E;          // disable VBI interrupts
}

asm ((
    lda #$ff;
    sta $D40E;
))
```

`{ ... }` and `(( ... ))` are interchangeable.

### 10.1 Default save/restore + `clobbers`

By default the compiler scans the block, determines which 6502
registers it writes, and emits save / restore around the block.
Override this with `clobbers`:

```c
asm {
    lda #$00;
    tax;
    tay;
} : clobbers A, X, Y
```

Mismatch warnings (the scan found a write to A that `clobbers`
omits, or the reverse) appear under the `asm-clobbers` warning
category. Suppress them with `-Wno-asm-clobbers` once you have
checked the block.

### 10.2 Accessing xtc variables

Identifiers declared in xtc are visible inside `asm` blocks
under their declared names; the assembler resolves them to
their allocated address.

```c
u16 score = 0;

void incScore(void) {
    asm {
        inc score;
        bne done;
        inc score+1;
        done:
    }
}
```

The same applies to global symbols, struct ivar offsets and
class-instance ivars.

### 10.3 Byte-extract operators (asm context)

| Prefix | Range |
|--------|-------|
| `<x` | bits 0..7 (low byte) |
| `>x` | bits 8..15 |
| `>>x` | bits 16..23 |
| `>>>x` | bits 24..31 |

```c
u16 val = $1234;
asm {
    lda #<val;        // LDA #$34
    ldx #>val;        // LDX #$12
}

u32 big = $11223344;
asm {
    lda #<big;        // LDA #$44
    ldx #>big;        // LDX #$33
    ldy #>>big;       // LDY #$22
    sta #>>>big;      // STA #$11
}
```

### 10.4 What the assembler accepts

The grammar inside `asm { ... }` blocks is **target-specific**:
xtc dispatches to the per-target inline assembler. Conventions
common to all targets:

- Instructions end with `;` (matching xtc's statement terminator).
- Labels are bare identifiers followed by `:`, local to the
  current `asm` block.
- Platform memory-map symbols are predefined for the active
  target; the symbol tables are in
  `support/<platform>/symbols/*.sym`.

Per-target details (instructions, operand modes, syntax for
immediates, addresses and indexing, and extended instructions
beyond the stock ISA):

| Target | Inline-asm reference |
|--------|----------------------|
| 6502 family (including xt) | instruction set in `src/xta/XA6502.m` |
| arm64-macOS | not supported in `asm { }` blocks; put the routine in a `.S` file and call it from xtc |

> **6502 family: what xta accepts.** Every official 6502
> instruction with the standard operand modes: implied,
> accumulator, immediate (`#$nn`), zero-page (`$nn`), zp,X /
> zp,Y, absolute (`$nnnn`), absolute,X / absolute,Y, indirect
> (`($nnnn)`), indexed-indirect (`($nn,x)`), and
> indirect-indexed (`($nn),y`). xt 6502 also supports
> SP-relative loads/stores/arith (`lda +5,SP`), `add SP,#imm`,
> `PSH #N` / `PLL #N` framing, `BRA`, and direct push/pop of
> X / Y (`PHX`, `PHY`, `PLX`, `PLY`).

Longer asm helpers (multi-byte arithmetic, bank-switching
trampolines, hardware-seeded PRNGs) go in a hand-written `.asm`
file under `support/<arch>/asm/` or `support/<platform>/asm/`
(for example `support/xt6502/asm/`), called with `JSR` (or `BL`
on arm64) from xtc. Use inline `asm { }` blocks for short
sequences inside xtc code.

---

## 11. Reserved words and grammar pointers

### 11.1 Reserved words (lexer-recognised)

`asm`, `auto`, `bool`, `break`, `case`, `class`, `clobbers`,
`continue`, `default`, `delete`, `dealloc`, `do`, `double`,
`else`, `enum`, `false`, `float`, `for`, `global`, `i8`, `i16`,
`i32`, `if`, `in`, `init`, `inline`, `naked`, `new`, `pointer`,
`optional`, `protocol`, `register`, `release`, `retain`, `return`,
`self`,
`sizeof`, `static`, `string`, `struct`, `super`, `switch`,
`true`, `typedef`, `u8`, `u16`, `u32`, `va_arg`, `va_end`,
`va_start`, `void`, `volatile`, `weak`, `while`.

The parser accepts additional in-context tokens (function
annotations such as `:irq`, `:vbi` and `:banked`; see §6.6) that
are not reserved at the lexer level.

`block` (§6.8) and `callback` (§9A) are **contextual** keywords and
are not on the list above. They open a declaration only when a type
follows, so a program that uses either as an ordinary name keeps
working: `i32 callback = 7;` compiles.

### 11.2 Formal grammar

The full grammar is on the website at `/compiler/language/grammar`,
and the same grammar ships in the source tree as `docs/xtc.bnf`, so a
checkout carries its own copy. The two are kept in step: change one and
change the other. Both are written from the parser.

### 11.3 What's out of scope here

- **Compiler flags, optimisation levels, memory-model
  selection.** See `USAGE.md` and the website.
- **Standard library classes** (`Stdio`, `Math`, `Heap`, `Vbi`,
  `Assert`, etc.). See `support/<platform>/lib/`,
  `support/generic/lib/`, and the website's API section.
- **Memory-model internals** (zero-page layouts, bank windows,
  PORTB encoding).
- **Linker scripts.**
- **The IR and the lowering rules.**

---

## 12. Drift watch

The website at https://compile-xc.org is the canonical reference.
Its language section has a page per topic: `index`, `lexical`,
`preprocessor`, `types`, `operators`, `statements`, `functions`,
`blocks`, `classes`, `inheritance`, `memory`, `bound-methods`,
`inline-asm`, `modules`, `collections`, `errors` and `threading`.
Sections 1-10 of this specification correspond to the first
thirteen.

The website page for a feature holds its corner cases,
diagnostics and worked examples in full. Read it before extending
the lowering or code generation for that feature.
