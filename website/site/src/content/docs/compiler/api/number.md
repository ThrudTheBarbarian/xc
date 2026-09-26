---
title: Number
description: "An Object wrapping any sized integer or float, with lazy cached cross-kind conversion. A typed collection stores primitives in this box."
---

`Number` is an [`Object`](/compiler/api/object/) that wraps a single primitive:
any of xc's sized integers (`i8`/`u8`/`i16`/`u16`/`i32`/`u32`/`i64`/`u64`) **or**
a `float`/`double`. A typed collection stores primitives in it (an `Array<i32>`
keeps its elements as `Number`s), and it lets a heterogeneous collection hold
mixed values.

```c
#import "Foundation.xc"          // or #import "Number.xc"
```

## Overview

A `Number` has two storage kinds, **integer** and **float**, and one is
canonical at a time. The setters ([`setI8`](#seti8--setu8), [`setFloat`](#setfloat--setdouble) …)
set the kind, the predicates [`isInt`](#isint--isfloat) / [`isFloat`](#isint--isfloat)
report it, and the getters read the value back in whatever type you ask for.

**Two slots, widest of their kind.** Integers are held bit-preserving in an
`i64` slot, floats in an IEEE-754 `double` slot. Every narrow accessor
(`asI8`, `asU16`, `asFloat` …) is a cast from one of the two. The wide slots
are what make `Array<i64>` and `Array<double>` possible.

**Cross-kind conversion is lazy and cached.** Each `Number` tracks a two-bit
valid bitmap. Reading a float out of an int `Number` (or an int out of a float
one) converts on the first call, stores the result in the inactive slot, and
sets its valid bit. A `Number` compared against many values of the other kind
pays the conversion cost once. Any setter clears the other bit, so a stale
conversion never survives a new value.

**Bit-preserving casts.** `setU32(0xFFFFFFFF).asI32()` returns `-1` and
`setI32(-1).asU32()` returns `0xFFFFFFFF`, matching plain `(i32)`/`(u32)` casts.
As a result, `withU32(0xFFFFFFFF).asFloat()` converts from the *signed* view
(`-1.0`), not `4294967295.0`. Set the kind with [`withFloat`](#withfloat--withdouble)
if you need the unsigned magnitude.

:::note[Availability]
On xt6502, `Array<i64>` / `Array<double>`, and so a `Number` that boxes a 64-bit
value, need **`-DENABLE_64BIT=1`**. The wide `i64`/`double` slots cost ~4.5 KB
in any 6502 program that uses the class, so wide storage is off by default
there. The 32-bit generic build (arm64, arm9, m68k, x86_64) is always wide.
With the option off, a 64-bit element type is a compile error, not a
truncation. The hash width also follows the target: `u32` on the 32-bit build,
`u8` on xt6502 (see [`hash`](#hash)).
:::

## Conforms to

- [`Comparable`](/compiler/api/comparable/): [`compare`](#compare) orders two
  `Number`s (cross-kind via float promotion), so numbers can be sorted and used
  as keys.
- [`Hashable`](/compiler/api/hashable/): [`hash`](#hash) makes a `Number` a
  [`Map`](/compiler/api/map/) / [`Set`](/compiler/api/set/) key, and it agrees
  with [`equals`](#equals): `Int(42)` and `Float(42.0)` hash the same.

Every `Number*` is also an [`Object*`](/compiler/api/object/) and fits anywhere
one is expected, such as a collection slot or a dictionary value.

## Topics

**Creating (inferred kind)** · [with](#with)

**Creating (pinned kind)** · [withI8 / withU8](#withi8--withu8) · [withI16 / withU16](#withi16--withu16) · [withI32 / withU32](#withi32--withu32) · [withI64 / withU64](#withi64--withu64) · [withFloat / withDouble](#withfloat--withdouble) · [init](#init)

**Setting (inferred kind)** · [set](#set)

**Setting (pinned kind)** · [setI8 / setU8](#seti8--setu8) · [setI16 / setU16](#seti16--setu16) · [setI32 / setU32](#seti32--setu32) · [setI64 / setU64](#seti64--setu64) · [setFloat / setDouble](#setfloat--setdouble)

**Reading (by destination)** · [value](#value)

**Reading (pinned type)** · [asI8 / asU8](#asi8--asu8) · [asI16 / asU16](#asi16--asu16) · [asI32 / asU32](#asi32--asu32) · [asI64 / asU64](#asi64--asu64) · [asFloat / asDouble](#asfloat--asdouble)

**Predicates** · [isInt / isFloat](#isint--isfloat)

**Protocol methods** · [description](#description) · [equals](#equals) · [compare](#compare) · [hash](#hash)

---

## Creating (inferred kind)

### with
```c
static Number* with(i8 v)      static Number* with(u8 v)
static Number* with(i16 v)     static Number* with(u16 v)
static Number* with(i32 v)     static Number* with(u32 v)
static Number* with(i64 v)     static Number* with(u64 v)
static Number* with(float v)   static Number* with(double v)
```
Overloaded on the argument's type: the compiler picks the storage kind from
`v`. Use it when the literal's natural type is the one you want;
`Number.with(50000)` boxes a `u16`. To force a wider or differently-signed slot,
use the pinned `withXxx` factory instead.

[↑ Topics](#topics)

## Creating (pinned kind)

Each factory sets the storage kind regardless of the argument's natural type.
Use them when you need a wider or differently-signed slot than the natural fit.

### withI8 / withU8
```c
static Number* withI8(i8 v)
static Number* withU8(u8 v)
```
A `Number` holding an 8-bit signed / unsigned integer.

### withI16 / withU16
```c
static Number* withI16(i16 v)
static Number* withU16(u16 v)
```
A `Number` holding a 16-bit signed / unsigned integer.

### withI32 / withU32
```c
static Number* withI32(i32 v)
static Number* withU32(u32 v)
```
A `Number` holding a 32-bit signed / unsigned integer.

### withI64 / withU64
```c
static Number* withI64(i64 v)
static Number* withU64(u64 v)
```
A `Number` holding a 64-bit signed / unsigned integer. Needs `-DENABLE_64BIT=1`
on xt6502 (see [Availability](#overview)).

### withFloat / withDouble
```c
static Number* withFloat(float v)
static Number* withDouble(double v)
```
A `Number` holding a floating-point value (both stored in the `double` slot).

### init
```c
void init(void)
```
The default initializer: an integer `Number` holding 0. Prefer `new Number()`
plus a setter, or the `with…` factories; you rarely call `init` directly.

[↑ Topics](#topics)

## Setting (inferred kind)

### set
```c
void set(i8 v)      void set(u8 v)
void set(i16 v)     void set(u16 v)
void set(i32 v)     void set(u32 v)
void set(i64 v)     void set(u64 v)
void set(float v)   void set(double v)
```
The mutating counterpart of [`with`](#with): overloaded on the argument's type,
it stores a new value in an existing `Number`, picking the kind from `v`.

[↑ Topics](#topics)

## Setting (pinned kind)

Each setter sets the canonical kind, writes its slot, and updates the valid
bitmap, so the next cross-kind read converts afresh rather than returning a
stale conversion.

### setI8 / setU8
```c
void setI8(i8 v)
void setU8(u8 v)
```
Store an 8-bit integer, pinning the int kind.

### setI16 / setU16
```c
void setI16(i16 v)
void setU16(u16 v)
```
Store a 16-bit integer.

### setI32 / setU32
```c
void setI32(i32 v)
void setU32(u32 v)
```
Store a 32-bit integer.

### setI64 / setU64
```c
void setI64(i64 v)
void setU64(u64 v)
```
Store a 64-bit integer.

### setFloat / setDouble
```c
void setFloat(float v)
void setDouble(double v)
```
Store a floating-point value, pinning the float kind.

[↑ Topics](#topics)

## Reading (by destination)

### value
```c
i8  value(void)     u8  value(void)
i16 value(void)     u16 value(void)
i32 value(void)     u32 value(void)
i64 value(void)     u64 value(void)
float value(void)   double value(void)
```
Overloaded on return type: `value()` picks its type from the expected-type
context (assignment LHS, variable declaration, call argument), the same
mechanism `Math.rand()` uses to pick `i16` or `float`. `i32 v = n.value();`
reads the int view; `float f = n.value();` reads the float view. Each narrow
overload goes through the cache-aware conversion points, so kind conversion
happens at most once.

[↑ Topics](#topics)

## Reading (pinned type)

Explicit return type. `asI64` and `asDouble` are the cache-aware conversion
points. Every other getter delegates to them with a bit-preserving cast, so a
stale slot is converted at most once.

### asI8 / asU8
```c
i8 asI8(void)
u8 asU8(void)
```
The value truncated to 8 bits, signed / unsigned.

### asI16 / asU16
```c
i16 asI16(void)
u16 asU16(void)
```
The value truncated to 16 bits.

### asI32 / asU32
```c
i32 asI32(void)
u32 asU32(void)
```
The value truncated to 32 bits.

### asI64 / asU64
```c
i64 asI64(void)
u64 asU64(void)
```
The full 64-bit integer view. `asI64` is a conversion point: on a float `Number`
it converts via the `(i64)double` cast (truncate toward zero, saturate to 0 on
overflow), caches the result, and returns the cached value on later calls.

### asFloat / asDouble
```c
float  asFloat(void)
double asDouble(void)
```
The floating-point view. `asDouble` is a conversion point: on an int `Number` it
converts via `(double)i64` (exact to 2^53, losing precision beyond), caches the
result, and returns the cached value on later calls. `asFloat` narrows that to
binary32.

[↑ Topics](#topics)

## Predicates

### isInt / isFloat
```c
bool isInt(void)
bool isFloat(void)
```
Which kind is canonical: the one a setter last set. One of the two is always
`true`.

[↑ Topics](#topics)

## Protocol methods

The [`Object`](/compiler/api/object/) / [`Comparable`](/compiler/api/comparable/)
/ [`Hashable`](/compiler/api/hashable/) hooks that give `Number` value semantics.

### description
```c
String* description(void)
```
The `%@` hook. An int renders exactly ([`String.withI64`](/compiler/api/string/#withi64--withu64));
a float renders to six decimal places (`String.withFloat`'s default, matching
C's `printf %f`).

### equals
```c
bool equals(Number* other)
bool equals(Object* other)
```
Value equality. Same-kind compares stay bit-exact; cross-kind promotes both
sides to float, so `Number.withI16(42)` **equals** `Number.withFloat(42.0)`, and
a non-integer float never equals any integer `Number`. The `Object*` overload is
the [`Comparable`](/compiler/api/comparable/) slot heterogeneous containers use;
it returns `false` against a non-`Number`.

### compare
```c
i8 compare(Number* other)
i8 compare(Object* other)
```
Ordering: `<0` / `0` / `>0` (the C / `NSComparisonResult` convention). The kind
rules match [`equals`](#equals), so `Int(42)` and `Float(42.0)` compare
**equal** here too. Comparing against a non-`Number` returns `0` ("these sort
equally"), because there is no meaningful order between a `Number` and another
kind of object. Pass a comparator if you need an order across kinds.

### hash
```c
u32 hash(void)          // u8 on the xt6502 build
```
Scrambles the 32-bit integer view. Cross-kind `equals` promotes to float, and
`Int(42)` and `Float(42.0)` both `asI32()` to `42`, so they hash the same, as
the [`Hashable`](/compiler/api/hashable/) contract requires. `Float(42.5)` also folds to
`42` and collides with `Int(42)`, but probe-chain equality keeps lookups
correct.

[↑ Topics](#topics)

## Worked example

```c
#import "Stdio.xc"
#import "Foundation.xc"

i32 main(void)
{
    Number* n = Number.withI16((i16)-42);
    if (n.isInt())   Stdio.printf("%d\n", n.asI16());      // -42

    Number* f = Number.withFloat(3.25);
    Stdio.printf("%s\n", f.description().cString());        // 3.250000

    // Cross-kind equality: promotes to float.
    Number* a = Number.with((i16)42);
    Number* b = Number.withFloat(42.0);
    Stdio.printf("%d\n", (i16)a.equals(b));                 // 1 (true)
    return 0;
}
```
