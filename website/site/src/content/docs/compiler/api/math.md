---
title: Math
description: "Random numbers, absolute value, square root, log/exp/pow, trigonometry, and a full set of float and double constants."
---

`Math` provides random-number generation, integer and floating-point arithmetic
helpers, transcendental functions, and a set of mathematical constants. Every
method is **`static`**: call `Math.sqrt(...)`, `Math.PI()` and so on without
creating an instance.

```c
#import <Math.xc>
```

## Overview

Each backend architecture has its own `Math` (`support/arm64/lib/Math.xc`,
`support/xt6502/lib/Math.xc`, …). The **public API is the same everywhere**, with
the same overloads and constants, so overload resolution behaves the same on
every target. Only the bodies differ. The native backends wrap the host C
library (`libm`) and use libc's PRNG. xt6502 uses its own softfloat / MECH
routines and an xorshift generator that matches the host sequence bit-for-bit.

Zero-argument methods use xcc's overloading by **return type**: `Math.rand()`
and constants such as `Math.PI()` resolve from the type of the variable they
are assigned to, and the compiler emits the version that produces that type.
An argument takes the type of its parameter, so `check(Math.E())` with
`void check(f64 v)` gets the `f64` constant.

Both `f32` (IEEE-754 binary32) and `f64` (IEEE-754 binary64) values have the
same bit layout on every target, so a value computed on one target and read on
another is identical.

:::note[Availability]
On **xt6502** the `f64` overloads are gated behind the `ENABLE_DOUBLE` macro
(default `1`). Reachability analysis trims unused methods, so importing
`Math.xc` does not enlarge `f32`-only programs. To override the gate, pass
`-DENABLE_DOUBLE=1` or `-DENABLE_DOUBLE=0`. On the native
backends the `f64` family is always present. The `f64` constants and the
`f64`-taking overloads of [`rand`](#rand), [`abs`](#abs), [`sqrt`](#sqrt),
[`sin`/`cos`/`tan`/`atan`](#sin), [`ln`](#ln), [`exp`](#exp) and [`pow`](#pow)
are the ones the gate covers.
:::

## Topics

**Random numbers** · [setSeed](#setseed) · [step](#step) · [rand](#rand)

**Arithmetic** · [abs](#abs) · [sqrt](#sqrt) · [ln](#ln) · [exp](#exp) · [pow](#pow)

**Trigonometry** · [sin](#sin) · [cos](#cos) · [tan](#tan) · [atan](#atan)

**Constants** · [E · LOG2E · LOG10E · LN2 · LN10 · PI · PI_2 · PI_4 · INV_PI · TWO_PI · TWO_SQRTPI · SQRT2 · SQRT1_2](#constants)

**Lifecycle** · [init](#init)

---

## Random numbers

The generator is a small PRNG: a Marsaglia xorshift on xt6502, and the host libc
generator on the native backends. It seeds deterministically on
first use; seed it explicitly with [`setSeed`](#setseed).

### setSeed
```c
static void setSeed(u16 seed)
```
Re-seeds the generator.

### step
```c
static void step(void)
```
Advances the generator one tick, refreshing the internal `seedLo`/`seedHi` state
that the integer [`rand`](#rand) overloads read. The `rand` overloads call it,
so you rarely need to.

### rand
```c
static u8     rand(void)              // 0..255
static u16    rand(void)              // 0..65535
static u32    rand(void)              // 0..2^32-1
static u8     rand(u8 max)            // 0..max  (max exclusive of +1 wrap)
static u8     rand(u8 lo, u8 hi)      // lo..hi inclusive
static u16    rand(u16 max)           // 0..max
static u16    rand(u16 lo, u16 hi)    // lo..hi inclusive
static f32 rand(void)                // [0.5, 1.0)  (native: see note)
static f64 rand(void)                // [0.5, 1.0)
```
A random value. The unbounded integer overloads span the whole width; the
bounded forms take a maximum or an inclusive `lo`/`hi` range. The `f32` and
`f64` overloads return a value in `[0.5, 1.0)`, the range of the xt6502
implementation (exponent −1, random mantissa). The native ports inline the
expression `0.5 + (random()/2^31)*0.5` so the IR inliner can fold it.

```c
u8  d6   = Math.rand(1, 6);   // dice roll, 1..6
u16 cell = Math.rand(40);        // 0..39
f32 f  = Math.rand();                 // 0.5 <= f < 1.0
```

[↑ Topics](#topics)

## Arithmetic

### abs
```c
static i8     abs(i8 v)
static i16    abs(i16 v)
static i32    abs(i32 v)
static f32 abs(f32 v)
static f64 abs(f64 v)                // xt6502: ENABLE_DOUBLE
```
Absolute value, overloaded across the signed integer widths and both float types.

### sqrt
```c
static f32 sqrt(f32 v)
static f64 sqrt(f64 v)
```
Square root.

```c
f32 hyp = Math.sqrt(dx * dx + dy * dy);
```

### ln
```c
static f32 ln(f32 v)
static f64 ln(f64 v)                 // xt6502: ENABLE_DOUBLE
```
Natural logarithm (base `e`). For other bases divide by `Math.LN2()`,
`Math.LN10()`, etc.

### exp
```c
static f32 exp(f32 x)
static f64 exp(f64 x)                // xt6502: ENABLE_DOUBLE
```
`e^x`, the inverse of [`ln`](#ln).

### pow
```c
static f32 pow(f32 base, f32 power)
static f32 pow(f32 base, i16 power)
static f64 pow(f64 base, f64 power)            // xt6502: ENABLE_DOUBLE
static f64 pow(f64 base, i16 power)             // xt6502: ENABLE_DOUBLE
static f64 pow(f64 base, i32 power)              // xt6502: ENABLE_DOUBLE
static f64 pow(f64 base, u32 power)              // xt6502: ENABLE_DOUBLE
```
`base` raised to `power`, overloaded by exponent type. For an integer exponent,
the integer-typed overload is much cheaper than the float-by-float version.

```c
f32 sq = Math.pow(r, 2);                 // squared, integer fast path
f32 rt = Math.pow((f32)2.0, (f32)0.5);        // square root via pow
```

[↑ Topics](#topics)

## Trigonometry

Angles are in **radians**. All four functions exist in both `f32` and `f64`
precision (the `f64` forms gated by `ENABLE_DOUBLE` on xt6502).

### sin
```c
static f32 sin(f32 angle)
static f64 sin(f64 angle)            // xt6502: ENABLE_DOUBLE
```
Sine of `angle`.

### cos
```c
static f32 cos(f32 angle)
static f64 cos(f64 angle)            // xt6502: ENABLE_DOUBLE
```
Cosine of `angle`.

### tan
```c
static f32 tan(f32 angle)
static f64 tan(f64 angle)            // xt6502: ENABLE_DOUBLE
```
Tangent of `angle`.

### atan
```c
static f32 atan(f32 x)
static f64 atan(f64 x)               // xt6502: ENABLE_DOUBLE
```
Arctangent of `x`.

```c
f32 a = Math.PI() / 4;
f32 s = Math.sin(a);                 // ~ 0.7071
f32 c = Math.cos(a);
```

[↑ Topics](#topics)

## Constants

Each constant is a zero-argument accessor with an `f32` and an `f64` overload;
the compiler picks based on the assignment target (the `f64` forms are gated
by `ENABLE_DOUBLE` on xt6502).

```c
static f32 PI(void)
static f64 PI(void)                  // xt6502: ENABLE_DOUBLE  (pattern for all constants)
```

| Method | Value |
|--------|-------|
| `Math.E()` | Euler's number |
| `Math.LOG2E()` | log₂(e) |
| `Math.LOG10E()` | log₁₀(e) |
| `Math.LN2()` | ln(2) |
| `Math.LN10()` | ln(10) |
| `Math.PI()` | π |
| `Math.PI_2()` | π / 2 |
| `Math.PI_4()` | π / 4 |
| `Math.INV_PI()` | 1 / π |
| `Math.TWO_PI()` | 2π |
| `Math.TWO_SQRTPI()` | 2 / √π |
| `Math.SQRT2()` | √2 |
| `Math.SQRT1_2()` | √(1/2) |

```c
f32 pi_f = Math.PI();                // f32 overload
f64 pi_d = Math.PI();                // f64 overload
```

[↑ Topics](#topics)

## Lifecycle

### init
```c
void init(void)
```
The zero-argument initializer. On the native backends it does nothing (the host
PRNG self-seeds on first use); on xt6502 it prepares the generator state. Static
callers never need it.

[↑ Topics](#topics)

## A note on the float format

`f32` is **IEEE-754 binary32** (4 bytes) and `f64` is **IEEE-754 binary64**
(8 bytes) on every target, including the 6502. A literal carries IEEE bytes from
the lexer through to the back end, so a value written in source, stored to a file
on one target and read back on another is bit-identical.

The 6502 ROM math pack uses a different format: **BCD**-encoded floats with a
6-decimal-digit mantissa. xcc floats are binary, which is much cheaper to
multiply and divide on a CPU with no decimal arithmetic, at the cost of a
binary↔ASCII conversion to print.

On the register machines the arithmetic is native hardware floating point. On
xt6502 the hand-written routines in `support/xt6502/asm/float/` and
`support/xt6502/asm/double/` implement add, subtract, multiply, divide and the
math functions. The code generator emits `JSR` to them and links only the ones a
program reaches.
