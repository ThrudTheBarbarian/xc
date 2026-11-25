---
title: Types
description: The fixed-width scalars, structs, enums, pointers, arrays, type inference and casting.
---

## Primitive types

| Type | Size | Meaning |
|------|------|---------|
| `u8`, `i8` | 1 byte | 8-bit unsigned / signed integer |
| `u16`, `i16` | 2 bytes | 16-bit unsigned / signed integer |
| `u32`, `i32` | 4 bytes | 32-bit unsigned / signed integer |
| `u64`, `i64` | 8 bytes | 64-bit unsigned / signed integer |
| `f32` | 4 bytes | IEEE-754 binary32; `float` is an alias |
| `f64` | 8 bytes | IEEE-754 binary64; `double` is an alias |
| `f16` | 2 bytes | IEEE-754 binary16 (pack `e5m10`) |
| `bf16` | 2 bytes | bfloat16, `f16:pack(e8m7)` |
| `f8` | 1 byte | OCP FP8 E4M3 (pack `e4m3`, `finite`) |
| `bool` | 1 byte | alias of `u8`; values are `true` and `false` |
| `void` | — | absence of value (function returns, parameter list `(void)`) |
| `string` | pointer | alias of `u8*` (pointer to null-terminated bytes) |
| `pointer` | target-defined | typeless pointer |

Every width is the same on every target: a `u32` is four bytes on the 6502 and on
arm64. Only pointers vary: 3 bytes on the banked xt6502 (`{lo, hi, bank}`), 8
bytes on the 64-bit hosts, 4 on arm9/m68k. Code that needs the number should use
`sizeof(T*)` instead of a fixed constant.

Casting an integer to a pointer keeps the full width of the target's pointer. A
wider integer gives its low bytes, and a narrower one is sign-extended if it is
signed and zero-extended if not. So a pointer stored in an `i64` or `u64`, or in
a `u32` where pointers are 4 bytes or less, converts back to the same pointer. On
xt6502 the integer's third byte is the bank. An integer narrower than three bytes
fills the 16-bit address and gives bank 0, so its sign never reaches the bank.

Floating point is IEEE-754 on every target, including the 6502, where a software
runtime or hardware on the FPGA does the arithmetic.

### `f32` and `f64`

`f32` and `f64` name the floating point types, as `i32` and `u64` name the
integer ones. `float` is another name for `f32`, and `double` another name for
`f64`: each pair is one type, so values pass between the two spellings with no
conversion, `sizeof(f32)` and `sizeof(float)` are both 4, and an `Array<f32>` is
an `Array<float>`. Two functions whose parameters differ only in the spelling
have the same signature, and declaring both is a redefinition. Diagnostics,
interfaces and the debugger show these types as `float` and `double`.

`f32` and `f64` are built-in type names, not keywords, so a variable, parameter
or field may still be called `f32` or `f64`.

### Small floats: `f16`, `bf16` and `f8`

`f16` is the IEEE-754 binary16 type: one sign bit, 5 exponent bits and 10
mantissa bits, with a largest finite value of 65504. `bf16` is bfloat16: 8
exponent bits and 7 mantissa bits, the range of `f32` with less precision
(largest finite value about 3.39e38). Both are 2 bytes, aligned as `u16` is on
the target.

`f8` is the OCP FP8 E4M3 type: one sign bit, 4 exponent bits and 3 mantissa
bits. It has no infinity, and only the all-ones patterns (`0x7F` and `0xFF`)
are NaN, which gives it one more binade: its largest finite value is 448.
`f8:pack(e5m2)` is OCP FP8 E5M2, with IEEE's infinities and NaNs and a largest
finite value of 57344. `f8:pack(ue8m0)` is the unsigned scale of the OCP
microscaling formats: 8 exponent bits and no sign or mantissa, holding the
powers of two from 2^-127 to 2^127; `0xFF` is NaN, and it has no zero and no
infinity. Every `f8` pack is 1 byte, aligned to 1.

All of them work on every target, in locals, globals, arrays, struct fields,
ivars, parameters, returns, `Array<T>`, `new T[n]` and library interfaces, and
all keep subnormals as IEEE-754 defines them. `f16`, `bf16` and `f8` are
built-in type names, so no import is needed.

#### Packs

A float type's bit layout is its pack, written `:pack(eXmY)` after the type: one
sign bit, X exponent bits and Y mantissa bits, with 1 + X + Y the type's width.
The pack is part of the type, so it can appear anywhere a type can: in
declarations, fields, parameters, returns, casts, `Array<…>`, typedefs,
`sizeof` and `new`.

| Spelling | Type |
|----------|------|
| `f16:pack(e5m10)` | `f16` (its default pack) |
| `f16:pack(e8m7)` | `bf16` |
| `f16:pack(e6m9)`, `f16:pack(e7m8)` | other 16-bit packs |
| `f8:pack(e4m3)` | `f8` (its default pack) |
| `f8:pack(e5m2)` | OCP FP8 E5M2 |
| `f8:pack(e2m5)` … `f8:pack(e6m1)` | other 8-bit packs |
| `f8:pack(ue8m0)` | the unsigned scale |
| `f32:pack(e8m23)` | `f32` (its only pack) |
| `f64:pack(e11m52)` | `f64` (its only pack) |

A pack also fixes its special values, its kind, which a custom pack may name
after the split, as in `f8:pack(e3m4, finite)`:

| Kind | Meaning | Default for |
|------|---------|-------------|
| `ieee` | the all-ones exponent is infinity (mantissa 0) or NaN | every pack but E4M3 |
| `finite` | no infinity; only the all-ones pattern is NaN | `f8` (E4M3) |
| `none` | no infinity and no NaN | — |

A `finite` or `none` pack has at most 7 exponent bits. `ue8m0` takes no kind.
Every pack is a distinct type, and every pack with its kind: `f8:pack(e5m2)`
and `f8:pack(e5m2, finite)` are two types. Diagnostics write a pack as it is
spelled here. Any other pack is an error that names what to write.

#### Conversions and type rules

A value converts implicitly only when every value of its type, its infinities
and NaNs included, converts exactly:

| From | Converts implicitly to |
|------|------------------------|
| `f8` (E4M3) | `f16`, `bf16`, `f32`, `f64` |
| `f8:pack(e5m2)` | `f16`, `bf16`, `f32`, `f64` |
| `f8:pack(ue8m0)` | `bf16`, `f32`, `f64` |
| `f16`, `bf16` | `f32`, `f64` |
| any other pack | each pack, `f32` and `f64` with the mantissa bits, the range and the special values to hold it |

Everything else needs a cast: `f32` or `f64` to any pack, `f16` to `bf16` and
back, `f8` to `f8:pack(e5m2)` and back, an integer to a pack, and a pack to an
integer. A literal takes the type its context needs and is rounded to it, so
`f8 w = 0.1;`, `w + 1` and `w * 0.5` need no cast. A literal beyond the type's
range is an error, in every pack: `f8 w = 500.0;` is refused, and a literal of
`f8:pack(ue8m0)` must be above zero.

Mixed arithmetic widens to the type that holds both operands: `f8 + f16` is
`f16`, `f16 + f32` is `f32`, and `f16 + u8` is `f16`. Two packs neither of which
holds the other have no common type: `f16 + bf16` and `f8 + f8:pack(e5m2)` are
errors; convert both, as in `(f32)a + (f32)b`. `f8:pack(ue8m0)` is a scale and
mixes with no other type: `s * x` with an `f32` `x` needs `(f32)s * x`. It
cannot be negated.

Conversions round to nearest, ties to even, and keep subnormals. A value too
large for the type becomes an infinity of its sign where the pack has one
(`ieee`). Where it has none (`finite`, `none`, `ue8m0`) the value saturates to
the largest finite value of its sign, and so does an infinity. A NaN stays a
NaN, with its sign, except in a `none` pack, which has no NaN and gives +0. For
`ue8m0`, zero and values below 2^-127 give 2^-127, and a negative value gives
NaN. A conversion to an integer takes the integral part, truncated toward zero;
a value beyond the integer type's range saturates to its end, and a NaN gives
0. A conversion to `bool` is `false` for both zeros and `true` for anything
else, NaN included (every `ue8m0` value is `true`).

`printf` and other variadic functions receive a small float as a `double`, as
they do a `float`, so `%f` prints it.

#### Explicit conversions

`Fp8.xc` has the conversions to the standard 8-bit packs with the overflow rule
a cast does not give, as the OCP FP8 specification's saturating and
non-saturating conversions do, and the default ones by name:

| Function | Result | Beyond the largest finite value, and an infinity |
|----------|--------|---------------------------------------------------|
| `fp8E4M3(f64 x)` | `f8` | the largest finite value (the cast's rule) |
| `fp8E4M3Nan(f64 x)` | `f8` | NaN |
| `fp8E5M2(f64 x)` | `f8:pack(e5m2)` | infinity (the cast's rule) |
| `fp8E5M2Sat(f64 x)` | `f8:pack(e5m2)` | the largest finite value |
| `fp8UE8M0(f64 x)` | `f8:pack(ue8m0)` | 2^127 (the cast's rule) |
| `fp8UE8M0Nan(f64 x)` | `f8:pack(ue8m0)` | NaN |

`fp8E4M3Value`, `fp8E5M2Value` and `fp8UE8M0Value` give a value as an `f32`,
exactly. All of them round to nearest, ties to even, and are `extern`, so C can
call them (see below).

```c
#import "Fp8.xc"

f8 a = (f8)big;               // 448 when big is beyond it
f8 b = fp8E4M3Nan(big);       // NaN when big is beyond 448
```

#### Arithmetic

`+`, `-`, `*`, `/`, unary minus, the comparisons, compound assignment, `++` and
`--` work on every pack. Each operation converts its operands to `f32`, works
in `f32`, and rounds the result to the operands' type, saturating or becoming
an infinity as a conversion does. Because `f32` has more than twice the
precision of any pack plus two bits, the result is the correctly rounded
result of the operation, and a chain of operations rounds after every step, as
ISO C's `_Float16` does. Negation flips the sign bit. The square root is
`(f16)Math.sqrt((f32)h)`, which rounds once and is exact in the same way.

```c
f16 a = 1.0;
f16 b = 0.0004887;
f16 s = a + b;                   // 1.0009765625, the f16 nearest the sum
f32 t = (f32)a + (f32)b;         // 1.0004887
f8 w = 448.0;
f8 x = w * 2;                    // 448: E4M3 saturates
```

The arithmetic is done in software on every target. A `par` block that
computes in `f16`, `bf16` or `f8` runs on the CPU; the compiler says so when
the block could otherwise use the GPU.

#### Calling C

C has no 8-bit float type. An `f8` of any pack, and a 16-bit pack other than
`f16` and `bf16`, crosses to and from C as its bit pattern: C sees a
`uint8_t` (or `uint16_t`), and an `extern` function taking or returning one
passes it as that integer on every target. C converts with `Fp8.xc`'s
functions, which take and return those patterns (`uint8_t fp8E4M3Nan(double)`,
`float fp8E4M3Value(uint8_t)`).

`f16` and `bf16` are C's `_Float16` and `__bf16`. Between xc functions either
travels as its 16-bit pattern, in an integer register or stack slot. A function
that C calls or defines takes and returns them as C does:

- a C library function, imported with `#import <Lib>` (whose debug
  information declares a `_Float16` parameter as `f16` and a `__bf16` one as
  `bf16`);
- a function declared without a body and ending in `...`;
- a function declared `extern`, with a body or without. Declare a C function
  you write the prototype for `extern`, and give an xc function that C calls,
  by name or through a pointer, `extern` too.

| Target | Where C passes `_Float16` and `__bf16` |
|--------|----------------------------------------|
| `arm64` | the low 16 bits of `v0`–`v7` (`h0`–`h7`); on the stack, 2 bytes packed on macOS and iOS, an 8-byte slot on Linux and Android |
| `x86_64` | the low 16 bits of `xmm0`–`xmm7`; on the stack, an 8-byte slot |
| `win64` | the low 16 bits of `xmm0`–`xmm3`, by position; on the stack, an 8-byte slot |
| `arm9` | the low 16 bits of a core register or 4-byte stack slot (the soft-float convention) |

`wasm32`, `m68k` and `xt6502` have no C with these types, so a C library
function or bodyless variadic that takes or returns one is an error there; give
it a `float`. An `extern` function keeps xc's convention on those targets.

### `i64` / `u64` on every target

64-bit arithmetic works on all seven targets. `arm64`, `x86_64` and `win64` do it
in registers, and `wasm32` through the VM's native `i64` opcodes. The narrow
targets do it out of line: m68k through line-A HLE selectors, arm9 through inline
`adds`/`adc` plus libgcc, and xt6502 through hand-written routines in
`support/xt6502/asm/{i64,u64}/`.

The answers are identical everywhere, including 64-bit literals. Add, multiply,
divide, shift, unsigned wraparound and comparison of a 2^40 value all agree
byte-for-byte between a 6502 and an arm64.

`sizeof(i64)` is 8 on every target, because width is a layout contract: a struct
containing an `i64` lays out identically everywhere.

### Conversions

- Assigning a wider integer to a narrower one **truncates**, with no sign
  extension.
- Assigning `f32`/`f64` to an integer takes the **integral part**, truncated
  toward zero: `(i32)3.7` is `3`, `(i32)-3.7` is `-3`. Magnitudes that overflow
  the destination saturate to `0`.
- **Same-width arithmetic stays at that width.** There is no C-style promotion to
  `int`, so `u8 + u8` wraps at 8 bits. Only mixed-width operands widen
  (`u8 + u16` → `u16`). To get a wider result, widen the operands:

```c
u8 a = 200, b = 100;
u8  narrow = a + b;                  // 44  — 300 & 0xFF
u16 wide   = a + b;                  // 44  — STILL a u8 add
u16 real   = (u16)a + (u16)b;        // 300 — widen the OPERANDS
```

The destination does not change how the operator computes, so an expression means
the same thing wherever its result goes. C differs: it promotes both operands to
`int` and would give 300 for the second line.

## Structs

Structs gather related data into a value type with copy semantics, passed and
returned by value. Field alignment is target-defined. The 6502 packs fields
byte by byte (padding would waste bytes on a byte-oriented CPU), and the register
machines insert padding so each field lands on its natural boundary. Declaration
order is always preserved.

```c
typedef struct {
    u16 x;
    u8  y;
} CursorPos;

CursorPos topRight = {319, 0};
CursorPos middle   = {159, 100};
```

Initialisers use `{ … }`, as C does. Members are listed in declaration order;
omitted trailing members are zero-filled, and supplying more elements than the
struct holds is a compile-time error.

A struct local with no initialiser is zero-filled as well, as a stack class
instance is: every member of `CursorPos p;` starts at zero, and nothing is left
as whatever the stack held.

A struct can be returned by value:

```c
CursorPos centre(void) {
    CursorPos c = {160, 96};
    return c;
}
```

You may not return a pointer to a stack-resident struct, because the storage goes
away when the scope ends:

```c
CursorPos* bad(void) {
    CursorPos c = {1, 2};
    return &c;        // illegal — c dies at scope exit
}
```

Passing `&struct` as an argument is fine: the callee only holds the pointer for
the duration of the call.

## Enumerations

```c
enum suits = {hearts, clubs, diamonds, spades};
enum directions = {N = 4, S, E, W};      // 4, 5, 6, 7
```

Enumerations start at 0 unless given an explicit value; subsequent entries
increment by 1. The compiler picks the smallest unsigned type that holds every
value.

## Arrays

```c
u8  cakes[3];
u8  spaces[]  = {' ', '\t', '\n'};       // size inferred from the initialiser
u16 scores[8] = {100, 87};               // remaining 6 slots zero-filled
```

Array size is part of the type; with an initialiser present the size in `[ ]` may
be omitted.

Arrays are one-dimensional. A second `[ ]` on the same declarator is a parse
error — `i32 g[2][3];` is rejected at the second bracket, in a global position
and in a local one alike — so a rectangular table is flattened by hand and
indexed `row * width + col`. (Heap arrays from `new T[N]` are one-dimensional
for the same reason.)

A global, local or field array is at most 4 GB, on every target; a larger one
is a compile error that says so. Allocate it with `new T[n]` instead: on
arm64, x86-64 and win64 a heap array takes any size.

### Range initialiser

Fixed-size arrays with an integer element type also accept a range:

```c
u8  buf[10] = 0..10;      // 0, 1, 2, 3, 4, 5, 6, 7, 8, 9
u8  b2[5]   = 1...5;      // 1, 2, 3, 4, 5   (inclusive)
u16 b3[4]   = 100..104;   // 100, 101, 102, 103
i8  b4[3]   = -2..1;      // -2, -1, 0
```

Both bounds must constant-fold, and the resulting count must match the declared
element count; mismatches and non-literal bounds are rejected at compile time.
Float, struct and class arrays still need the `{ … }` form.

### `.length`

Fixed-size arrays and heap-allocated pointers both expose a `.length`
pseudo-property:

```c
u16 local[8];
u16 n1 = local.length;        // compile-time constant: 8

u16* heap = new u16[64];
u64 n2 = heap.length;         // 64
```

On a heap pointer, `.length` reads the element count from the allocation header.
Its type follows the target: `u64` on `arm64`, `x86_64` and `win64`, so an array of
more than 2³² elements reports its whole length; `u32` on `arm9` and `wasm32`; `u16`
on `m68k`, whose header holds a 16-bit count. A fixed-size array's `.length` has the
same type. The same width counts `for (v in arr)` and slice loops over a heap array.

Assigning `.length` to a narrower integer is allowed, as any narrowing is. Passing it
to an overloaded function needs an overload that takes the full width, or a cast:
with only `u16` and `u32` overloads, a `u64` argument matches neither without
narrowing, and the call is ambiguous.

`.length` on a pointer the compiler did not record a count for (one that crossed a
function boundary, or came from anywhere but `new T[N]`) is a compile error, since
there is no map entry to answer from. It never yields a wrong number.

## Pointers

Pointer syntax uses `*`, as C does. `&` takes an address, and `*` dereferences:

```c
u16  value = 1234;
u16* p = &value;
u16  v = *p;                  // load
*p = 4321;               // store
```

:::caution[The sigil binds to the TYPE]
Unlike C, `*` is part of the type rather than the declarator, so this declares
**two pointers**:

```c
u16* x, y;                    // BOTH are u16*
```

In C the same line gives you a pointer and an integer. This is intended, and it is
the difference most likely to surprise a C programmer reading xcc.
:::

`->` is sugar for "dereference and reach a member": `p->x` is `(*p).x`. Unlike C,
`.` on a pointer-to-struct or pointer-to-class also works, because the compiler
auto-dereferences. Class receivers conventionally use `.`, because a class
instance is nearly always reached through a pointer, and `sprite.draw()` reads
better than `sprite->draw()`.

Adding an integer to a pointer steps by elements, as in C. Subtracting two
pointers gives the number of elements between them, as a signed integer the
width of a pointer on the target:

```c
u32  arr[10];
u32* p = &arr[7];
u32* q = &arr[2];
auto d = p - q;               // 5
u32* r = q + 3;               // &arr[5]
```

A pointer argument must point at a scalar of the width the parameter declares.
Passing an `i32*` where an `i64*` is declared would let the callee write eight
bytes into four, so it is an error:

```c
void wide(i64* out) { out[0] = 1; }

i32 narrow = 0;
wide(&narrow);                // error: argument 1 of 'wide' is a i32* where a i64* is declared
wide((i64*)&narrow);          // accepted: the cast says it is meant
```

The check compares widths only. `u32*` for `i32*` differs in sign and is accepted,
as are `void*`, pointers to pointers, and pointers to structs and classes.

A hardware register is a pointer to a fixed address, reached by casting:

```c
volatile u8* COLBK = (u8*)$D01A;
*COLBK = *COLBK + 1;      // both accesses happen even at -O3 (volatile)
```

### The null pointer: `nil`

`nil` is the null pointer, of whatever pointer type the place it is used in
has: a class pointer, a pointer to a scalar, a `string` or the raw `pointer`.
It is written wherever a pointer is wanted and compared with `==` and `!=`.

```c
Node* head = nil;
if (head == nil) head = Node.make();
u32* p = nil;
string s = nil;
Node* firstOr(Node* a, Node* b) { return a != nil ? a : b; }
```

`nil` is a pointer and nothing else: `u32 n = nil`, `nil + 1`, `nil < p` and
`n == nil` with an integer `n` are errors. The literal `0` still converts to a
pointer as it always has, so existing code is unaffected; `nil` says what is
meant, and the compiler holds it to that. A class pointer assigned `nil`
releases what it held, as assigning `0` does.

Among overloads, `nil` chooses a pointer parameter and never an integer one:
with `f(Node* n)` and `f(u32 x)` declared, `f(nil)` calls the first. It fits
every pointer parameter alike, so a call that could go to two pointer
overloads is ambiguous, and a cast picks one: `g((Node*)nil)`. And `nil` is a
pointer of no particular type, so `auto p = nil` is an error; name the type.

## Casting

Casting uses C's `(type)` syntax:

```c
u16 n = (u16)x;
```

Two extensions handle class-pointer traffic:

- `(Dog*) animal`: runtime-checked downcast. On a mismatch the program traps.
- `(Dog* ?) animal`: **failable** downcast. On a mismatch it yields `(Dog*)0`;
  on success, the retyped pointer. Pair it with an `if (d != 0)` guard.

Upcasts, same-class casts and non-class-pointer casts are unaffected. See
[Inheritance & protocols](/compiler/language/inheritance/) for details.

## Type inference: `auto`

`auto` infers a variable's type from its initialiser:

```c
auto x = 3;          // u8
auto x = -3;         // i8
auto x = 257;        // u16
auto x = -259;       // i16
auto x = 65589;      // u32
auto x = -555_555;   // i32
auto x = 4.5;        // f32
auto x = "hi";       // string (u8*)
auto x = true;       // bool
```

Integer literals pick the smallest type that holds them; positive values become
unsigned, negative values signed.

Inference follows expressions and function returns too, widening where a
mixed-width expression requires it:

```c
u8 a = 4, b = 5;
auto c = a + b;       // c is u8

u8 a = 4; u16 d = 500;
auto e = a + d;       // e is u16  (widened)

// given:  u8 fn(void) { … }
auto v = fn();        // v is u8
```

Prefer explicit types. Use `auto` where the expression makes the type obvious.

## Type aliases: `typedef`

Any type can be aliased:

```c
typedef u16   Tick;
typedef u8*   bytes;
typedef RGB[] palette;
```

Aliases are transparent: `Tick` and `u16` are interchangeable everywhere.

A typedef of a function signature also spells a bound-method type:
`typedef void Handler(i32 v);` gives you `Handler^`. See
[Bound methods & callbacks](/compiler/language/bound-methods/).

## Protocols

A `protocol` is a named interface: method signatures with no bodies. In the type
system, a protocol name in a type position (usually as a pointer, e.g.
`Drawable*`) accepts any conforming class instance. Conformance and
optional methods are covered on
[Inheritance & protocols](/compiler/language/inheritance/).

## Worked example

```c
// types.xc — the scalar types, integer width rules, and pointers.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    u8  small = 200;
    u16 mid   = 60000;
    i32 wide  = -100000;
    u64 huge  = (u64)1 << (u64)40;

    // printf follows C: a narrower integer is passed as an int, and with a
    // literal format the compiler sizes each conversion to its argument, so
    // plain %d prints every one of these whole.
    Stdio.printf("u8=%d u16=%d (as i32 %d) i32=%d\n", small, mid, (i32)mid, wide);
    Stdio.printf("2^40 = %ld:%ld (hi:lo)\n", (u32)(huge >> 32), (u32)huge);

    // Same-width arithmetic stays at that width.
    u8 a = 200, b = 100;
    u8  wrapped = a + b;                 // 300 & 0xFF = 44
    // Widening the DESTINATION does not help — `u16 w = a + b;` is still a u8
    // add, and still 44. To get the true sum, widen the OPERANDS.
    u16 widened = (u16)a + (u16)b;       // 300
    Stdio.printf("u8 200+100 -> %d   widened -> %d\n", (u16)wrapped, widened);

    // Literal prefixes: $ hex, % binary, _ ignored anywhere in a literal.
    u16 hex = $BEEF;
    u8  bin = %1010_0101;
    u32 big = 1_000_000;
    Stdio.printf("hex=%ld bin=%d big=%ld\n", (i32)hex, (u16)bin, big);

    // Pointers use *, & takes an address.
    u16 value = 1234;
    u16* p = &value;
    Stdio.printf("*p = %d\n", *p);
    *p = 4321;
    Stdio.printf("value now %d\n", value);

    // The sigil binds to the TYPE, so this declares TWO pointers.
    u16* x, y;
    x = &value; y = &value;
    Stdio.printf("both pointers: %d %d\n", *x, *y);

    bool ok = true;
    f32 f = 1.5;
    f64 d = 3.1d;
    Stdio.printf("bool=%d float=%f double=%lf\n", ok ? (u16)1 : (u16)0, f, d);
    return 0;
}
```

```
u8=200 u16=60000 (as i32 60000) i32=-100000
2^40 = 256:0 (hi:lo)
u8 200+100 -> 44   widened -> 300
hex=48879 bin=165 big=1000000
*p = 1234
value now 4321
both pointers: 4321 4321
bool=1 float=1.500000 double=3.100000
```
