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
| `float` | 4 bytes | IEEE-754 binary32 |
| `double` | 8 bytes | IEEE-754 binary64 |
| `bool` | 1 byte | alias of `u8`; values are `true` and `false` |
| `void` | — | absence of value (function returns, parameter list `(void)`) |
| `string` | pointer | alias of `u8*` (pointer to null-terminated bytes) |
| `pointer` | target-defined | typeless pointer |

Every width is the same on every target: a `u32` is four bytes on the 6502 and on
arm64. Only pointers vary: 3 bytes on the banked xt6502 (`{lo, hi, bank}`), 8
bytes on the 64-bit hosts, 4 on arm9/m68k. Code that needs the number should use
`sizeof(T*)` instead of a fixed constant.

Floating point is IEEE-754 on every target, including the 6502, where a software
runtime or hardware on the FPGA does the arithmetic.

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
- Assigning `float`/`double` to an integer takes the **integral part**, truncated
  toward zero: `(i32)3.7` is `3`, `(i32)-3.7` is `-3`. Magnitudes that overflow
  the destination saturate to `0`.
- **Same-width arithmetic stays at that width.** There is no C-style promotion to
  `int`, so `u8 + u8` wraps at 8 bits. Only mixed-width operands widen
  (`u8 + u16` → `u16`). To get a wider result, widen the operands:

```c
u8 a = (u8)200, b = (u8)100;
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
u16 n2 = heap.length;         // 64
```

`.length` on a pointer the compiler did not record a count for (one that crossed a
function boundary, or came from anywhere but `new T[N]`) is a compile error, since
there is no map entry to answer from. It never yields a wrong number.

## Pointers

Pointer syntax uses `*`, as C does. `&` takes an address, and `*` dereferences:

```c
u16  value = (u16)1234;
u16* p = &value;
u16  v = *p;                  // load
*p = (u16)4321;               // store
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

A hardware register is a pointer to a fixed address, reached by casting:

```c
volatile u8* COLBK = (u8*)$D01A;
*COLBK = *COLBK + (u8)1;      // both accesses happen even at -O3 (volatile)
```

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
auto x = 4.5;        // float
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
    u8  small = (u8)200;
    u16 mid   = (u16)60000;
    i32 wide  = (i32)-100000;
    u64 huge  = (u64)1 << (u64)40;

    // printf's width contract: %d is 16-BIT and %ld is 32-bit, and both are
    // signed — which is why 60000 in a u16 prints as -5536.
    Stdio.printf("u8=%d u16=%d (as i32 %ld) i32=%ld\n", small, mid, (i32)mid, wide);
    Stdio.printf("2^40 = %ld:%ld (hi:lo)\n", (u32)(huge >> (u64)32), (u32)huge);

    // Same-width arithmetic stays at that width.
    u8 a = (u8)200, b = (u8)100;
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
    u16 value = (u16)1234;
    u16* p = &value;
    Stdio.printf("*p = %d\n", *p);
    *p = (u16)4321;
    Stdio.printf("value now %d\n", value);

    // The sigil binds to the TYPE, so this declares TWO pointers.
    u16* x, y;
    x = &value; y = &value;
    Stdio.printf("both pointers: %d %d\n", *x, *y);

    bool ok = true;
    float f = 1.5;
    double d = 3.1d;
    Stdio.printf("bool=%d float=%f double=%lf\n", ok ? (u16)1 : (u16)0, f, d);
    return 0;
}
```

```
u8=200 u16=-5536 (as i32 60000) i32=-100000
2^40 = 256:0 (hi:lo)
u8 200+100 -> 44   widened -> 300
hex=48879 bin=165 big=1000000
*p = 1234
value now 4321
both pointers: 4321 4321
bool=1 float=1.500000 double=3.1000000000
```
