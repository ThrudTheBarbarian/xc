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

Both `float` (IEEE-754 binary32) and `double` (IEEE-754 binary64) values have the
same bit layout on every target, so a value computed on one target and read on
another is identical.

:::note[Availability]
On **xt6502** the `double` overloads are gated behind the `ENABLE_DOUBLE` macro
(default `1`). Reachability analysis trims unused methods, so importing
`Math.xc` does not enlarge `float`-only programs. To override the gate, pass
`-DENABLE_DOUBLE=1` or `-DENABLE_DOUBLE=0`. On the native
backends the `double` family is always present. The `double` constants and the
`double`-taking overloads of [`rand`](#rand), [`abs`](#abs), [`sqrt`](#sqrt),
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
static float  rand(void)             // [0.5, 1.0)  (native: see note)
static double rand(void)             // [0.5, 1.0)
```
A random value. The unbounded integer overloads span the whole width; the
bounded forms take a maximum or an inclusive `lo`/`hi` range. The `float` and
`double` overloads return a value in `[0.5, 1.0)`, the range of the xt6502
implementation (exponent −1, random mantissa). The native ports inline the
expression `0.5 + (random()/2^31)*0.5` so the IR inliner can fold it.

```c
u8  d6   = Math.rand((u8)1, (u8)6);   // dice roll, 1..6
u16 cell = Math.rand((u16)40);        // 0..39
float f  = Math.rand();               // 0.5 <= f < 1.0
```

[↑ Topics](#topics)

## Arithmetic

### abs
```c
static i8     abs(i8 v)
static i16    abs(i16 v)
static i32    abs(i32 v)
static float  abs(float v)
static double abs(double v)          // xt6502: ENABLE_DOUBLE
```
Absolute value, overloaded across the signed integer widths and both float types.

### sqrt
```c
static float  sqrt(float v)
static double sqrt(double v)
```
Square root.

```c
float hyp = Math.sqrt(dx * dx + dy * dy);
```

### ln
```c
static float  ln(float v)
static double ln(double v)           // xt6502: ENABLE_DOUBLE
```
Natural logarithm (base `e`). For other bases divide by `Math.LN2()`,
`Math.LN10()`, etc.

### exp
```c
static float  exp(float x)
static double exp(double x)          // xt6502: ENABLE_DOUBLE
```
`e^x`, the inverse of [`ln`](#ln).

### pow
```c
static float  pow(float base, float power)
static float  pow(float base, i16 power)
static double pow(double base, double power)   // xt6502: ENABLE_DOUBLE
static double pow(double base, i16 power)       // xt6502: ENABLE_DOUBLE
static double pow(double base, i32 power)        // xt6502: ENABLE_DOUBLE
static double pow(double base, u32 power)        // xt6502: ENABLE_DOUBLE
```
`base` raised to `power`, overloaded by exponent type. For an integer exponent,
the integer-typed overload is much cheaper than the float-by-float version.

```c
float sq = Math.pow(r, (i16)2);               // squared, integer fast path
float rt = Math.pow((float)2.0, (float)0.5);  // square root via pow
```

[↑ Topics](#topics)

## Trigonometry

Angles are in **radians**. All four functions exist in both `float` and `double`
precision (the `double` forms gated by `ENABLE_DOUBLE` on xt6502).

### sin
```c
static float  sin(float angle)
static double sin(double angle)      // xt6502: ENABLE_DOUBLE
```
Sine of `angle`.

### cos
```c
static float  cos(float angle)
static double cos(double angle)      // xt6502: ENABLE_DOUBLE
```
Cosine of `angle`.

### tan
```c
static float  tan(float angle)
static double tan(double angle)      // xt6502: ENABLE_DOUBLE
```
Tangent of `angle`.

### atan
```c
static float  atan(float x)
static double atan(double x)         // xt6502: ENABLE_DOUBLE
```
Arctangent of `x`.

```c
float a = Math.PI() / 4;
float s = Math.sin(a);               // ~ 0.7071
float c = Math.cos(a);
```

[↑ Topics](#topics)

## Constants

Each constant is a zero-argument accessor with a `float` and a `double` overload;
the compiler picks based on the assignment target (the `double` forms are gated
by `ENABLE_DOUBLE` on xt6502).

```c
static float  PI(void)
static double PI(void)               // xt6502: ENABLE_DOUBLE  (pattern for all constants)
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
float  pi_f = Math.PI();             // float overload
double pi_d = Math.PI();             // double overload
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

`float` is **IEEE-754 binary32** (4 bytes) and `double` is **IEEE-754 binary64**
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
