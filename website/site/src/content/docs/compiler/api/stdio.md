---
title: Stdio
description: "Screen / stdout output, cursor positioning, and a printf-style formatter that handles every primitive plus structs and classes."
---

`Stdio` is the console-output class. It emits characters, positions the cursor,
and formats values through a `printf`-style API. Every method is **`static`**,
so there is no instance to create. Call `Stdio.printf(...)` directly, or add
`use Stdio;` to drop the `Stdio.` prefix and write `printf(...)`.

```c
#import <Stdio.xc>
```

## Overview

`Stdio` is reimplemented per backend architecture, resolved ahead of
`support/generic/lib` on the include path. The xt6502 build writes ATASCII
screen codes straight into text-mode screen RAM (reading screen mode and base
from the OS at [`init`](#init)) and scrolls when the cursor runs off the bottom.
The native backends (arm64 and the other register targets) format each value to
ASCII and push it a byte at a time through the host runtime's `_putc`, so output
is an ordinary byte stream with no addressable grid.

The two builds produce **byte-compatible** formatted text, so the dual-backend
test corpus gives the same output on every target: decimals carry no padding,
`%x` is four uppercase hex digits, `%lx` is eight, `%f` is six decimal places and
`%lf` ten.

:::note[Availability]
- [`putChar`](#putchar), [`scroll`](#scroll) and [`printFpDec`](#printfpdec) exist
  only in the **xt6502** build, because they are screen-model / fixed-point operations.
  Calling `putChar` or `scroll` on a native backend is a compile error
  (`No method 'putChar' on class 'Stdio'`).
- [`setCursor`](#setcursor) and the `(x, y)` position of [`printfAt`](#printfat)
  are no-ops on the native backends: stdout has no cursor.
- The 64-bit `print` overloads ([`print(i64)` / `print(u64)`](#print)) and
  `%lld`/`%llu` are on both; `%llx` and `printHex(u64)` are **arm64 only**
  (xt6502's `printHex` tops out at 32-bit and its `printf` has no `%llx`).
- `%@` object formatting is gated on the front-end `HAS_ATFMT` pre-scan so a
  program that never uses it pays no `Object`/`String` footprint.
:::

## Topics

**Screen output (xt6502)** · [putChar](#putchar) · [scroll](#scroll) · [setCursor](#setcursor)

**Printing values** · [print](#print) · [printHex](#printhex) · [printFpDec](#printfpdec)

**Formatted output** · [printf](#printf) · [printfAt](#printfat)

**Struct & object printing** · [printStruct](#printstruct)

**Lifecycle** · [init](#init)

---

## Screen output (xt6502)

Low-level screen operations. `putChar` and `scroll` exist only under
`support/xt6502/lib/`; `setCursor` is on every target but is a no-op where there
is no addressable screen.

### putChar
```c
static void putChar(u8 ch)          // xt6502 only
```
Emits one character to the active text-mode screen, doing the ATASCII →
screen-code conversion and advancing the cursor. A newline (`$0A`) moves to the
start of the next row; running off the bottom of the text region triggers
[`scroll`](#scroll) and backs the cursor onto the now-empty bottom row. In a
graphics mode (`canPrint == 0`) it does nothing.

### scroll
```c
static void scroll(void)            // xt6502 only
```
Scrolls the text region up by one row and blanks the new bottom row. It stays
within `screenBase + cols * rows`, so a split-screen text strip cannot write
into surrounding RAM. Called automatically by [`putChar`](#putchar) at
end-of-screen; rarely called directly.

### setCursor
```c
static void setCursor(u8 x, u8 y)
```
Moves the cursor to column `x`, row `y`. On xt6502 this computes a screen-RAM
offset; on the native backends it is a no-op (stdout is a byte stream).

[↑ Topics](#topics)

## Printing values

Direct, non-formatted printing. `print` is overloaded across every primitive
type, and sema picks the overload from the argument's type. None of these append
a newline; supply `"\n"` yourself.

### print
```c
static void print(string s)                  // u8* C string
static void print(String* s)                 // HAS_ATFMT only
static void print(u16 v)
static void print(i16 v)
static void print(u32 v)
static void print(i32 v)
static void print(u64 v)                     // xt6502 build
static void print(i64 v)                     // xt6502 build
static void print(float f)                   // 6 dp default
static void print(double d)                  // 10 dp default
static void print(float f,  u8 precision)    // %.Nf
static void print(double d, u8 precision)    // %.Nlf
```
Prints a value in its natural decimal (or, for `string`/`String*`, verbatim)
form. There is no `print(u8)` overload: `u8` widens implicitly to `u16`, so pass
`u8` values directly. On the native backends the 64-bit widths are printed by
`printf` through internal emit helpers rather than a public `print(i64)`/`print(u64)`
overload; the xt6502 build exposes them as `print` overloads too. The
precision-carrying float/double overloads back the `%.Nf` / `%.Nlf` conversions:
they round at `N+1` decimal places and keep `N`, matching the native targets.

### printHex
```c
static void printHex(u8 n)          // 2 digits
static void printHex(u16 v)         // 4 digits
static void printHex(u32 v)         // 8 digits
static void printHex(u64 v)         // 16 digits — arm64 only
```
Fixed-width, uppercase, left-zero-padded hex with no `$` prefix. The width is the
type's full width, so `printHex((u16)$2A)` prints `002A`.

### printFpDec
```c
static void printFpDec(double v, u8 keep, u8 roundAt)   // xt6502 only
```
The shared fixed-point float formatter behind `print(float)`, `print(double)` and
the `%.Nf` / `%.Nlf` conversions on xt6502. Extracts `v`'s integer part and
fractional digits via the MECH float ops, rounds half-up at decimal place
`roundAt`, and prints the first `keep`. A bare `%f` uses `keep == roundAt == 6`,
a bare `%lf` uses `10`; `%.Nf` uses `keep = N, roundAt = N+1`.

[↑ Topics](#topics)

## Formatted output

### printf
```c
static void printf(string fmt, ...)
```
The main formatted-output method. Walks `fmt`, copying literal bytes and
expanding `%` conversions by pulling matching arguments from the varargs buffer.
See [Format specifiers](#format-specifiers) below for the full contract.

### printfAt
```c
static void printfAt(u8 x, u8 y, string fmt, ...)
```
[`setCursor(x, y)`](#setcursor) followed by [`printf`](#printf), for
table-style screens. It is a pure forwarder that does not call `va_start`
itself, so it is exempt from the xt6502 varargs-reentrance check. On the native
backends the `(x, y)` is ignored.

[↑ Topics](#topics)

## Struct & object printing

### printStruct
```c
static void printStruct(void)
```
Walks a compiler-generated struct descriptor and prints the struct's fields
inside parentheses, recursing into nested structs and class-pointer fields. It
implements `%@` on a plain struct: the `printf` `%@` branch stores the data and
descriptor pointers in the class's ivars, then calls it. On the native backends
it prints a single `'?'` placeholder, because struct `%@` is not implemented
there; the full descriptor walk exists only in the xt6502 build.

[↑ Topics](#topics)

## Lifecycle

### init
```c
void init(void)
```
The zero-argument initializer, run by `new Stdio()`. On xt6502 it reads the
screen mode from `DINDEX` (`$57`), the screen base from `SAVMSC` (`$58/$59`) and
the text-window row count from `BOTSCR` (`$02BF`), deriving the column count from
the mode (GR.0 = 40 columns, GR.1/2/3 = 20, graphics modes = no text output). On
the native backends it does nothing. Static callers never need it.

[↑ Topics](#topics)

## Format specifiers

The `printf` / `printfAt` conversions. The **width contract** is shared with [`String.appendFormat`](/compiler/api/string/#appendformat):
`%d`/`%u` are 16-bit, `%ld`/`%lu` are 32-bit.

| Specifier | Argument type | Output |
|-----------|---------------|--------|
| `%d`  | `i16` | signed decimal, 16-bit |
| `%u`  | `u16` | unsigned decimal, 16-bit |
| `%x`  | `u16` | hex, 4 digits, uppercase |
| `%ld` | `i32` | signed decimal, 32-bit |
| `%lu` | `u32` | unsigned decimal, 32-bit |
| `%lx` | `u32` | hex, 8 digits |
| `%lld`| `i64` | signed decimal, 64-bit |
| `%llu`| `u64` | unsigned decimal, 64-bit |
| `%llx`| `u64` | hex, 16 digits — **arm64 only** |
| `%f`  | `float` | float, 6 dp (`%.Nf` for N places) |
| `%lf` | `double` | double, 10 dp (`%.Nlf` for N places) |
| `%c`  | `u8` | one character (no width promotion) |
| `%s`  | `string` (`u8*`) | NUL-terminated string |
| `%e`  | enum value (statically typed as an enum) | textual name of the enum value |
| `%@`  | class instance | the object's `description()`, through its vtable |
| `%%`  | — | literal `%` |

```c
u16 score  = 1234;
i32 millis = -50000;
float pi   = 3.14159;
string name = "Player 1";

Stdio.printf("%s scored %u in %ld ms\n", name, score, millis);
Stdio.printf("pi ~ %f\n", pi);
Stdio.printf("ratio: %u%%\n", (u16)42);   // "ratio: 42%"
```

### Objects: `%@`

`%@` takes a **class instance** and prints whatever its `description()` returns,
dispatched through the vtable. `Object` supplies a default, so any class works.
Override `description()` to change what every `%@` in the program prints for
that class:

```c
class Point : Object
{
    i32 x;
    i32 y;
    String* description(void)
    {
        String* s = String.withCString("(");
        s.append(String.withI32(x));
        s.appendCString("|");
        s.append(String.withI32(y));
        s.appendCString(")");
        return s;
    }
}

Stdio.printf("last %@\n", p);        // last (3|4)
```

`%@` on an object is a virtual call, and a plain `struct` has no vtable and no
`description()`. On xt6502, `%@` on a plain struct goes through
[`printStruct`](#printstruct) instead, which formats the fields recursively:

```c
typedef struct { u16 x; u16 y; u8 tint; } Sprite;

Sprite s = {160, 96, 7};
Stdio.printf("sprite=%@\n", s);       // sprite=(160, 96, 7)
```

### Enum names: `%e`

`%e` prints the **textual name** of an enum value. The translation happens at
**compile time**, so the runtime `printf` never sees a `%e`:

1. The compiler scans every `printf` / `printfAt` format string at the call site.
2. Each `%e` is rewritten in place to `%s`.
3. A small `_enum_lookup_<EnumName>(value)` helper is generated for any enum
   reached by a `%e`; the call site emits a `JSR` to it and packs its returned
   string pointer as the matching `%s` argument.

In the binary every `%e` is an ordinary `%s`, and the feature costs one helper
per enum (emitted once, however many call sites use it).

```c
enum direction = {N = 1, E, S, W};

direction d = E;
Stdio.printf("heading: %e\n", d);      // heading: E
Stdio.printf("raw    : %u\n", (u16)d); // raw    : 2
```

The argument paired with `%e` **must be statically typed as an enum**; a non-enum
argument is a compile-time error (`printf '%e' requires an enum argument`). For
the underlying number, use `%u`/`%d` and cast explicitly; there is no automatic
fallback.

### Pre-scanning and code-size gating

The compiler scans every `printf` format string at compile time and links only
the specifier handlers in use. A program that prints only strings and `u16`s
pays for `%s` and `%u`, and none of the floating-point, double or `%@` code
reaches the binary. Force-include or force-exclude specifiers with
`-DHAS_FFMT=1`, `-DHAS_LFMT=0`, `-DHAS_ATFMT=1`, and so on.

## Variadic limits (xt6502 only)

On **xt6502** a variadic call marshals its arguments through a single shared
64-byte pack buffer (`__xtc_va_buf`; the address comes from the active layout,
see [Functions → Shared pack buffer](/compiler/language/functions/#shared-pack-buffer-and-reentrance)). For `printf`:

- Total argument payload per call ≤ 62 bytes (64 minus the 2-byte fmt-pointer header).
- A `printf` call inside another variadic that has already called `va_start`
  overwrites the outer call's buffer. Sema diagnoses this at compile time.
- `printfAt` is a pure forwarder (no `va_start` of its own), so it is exempt.

The non-6502 targets (`arm64`, `x86_64`, `win64`, `arm9`, `m68k`, `wasm32`) use
their platform's own varargs ABI (registers and stack, per call), so there is no
shared buffer, no payload cap and no reentrance hazard. Code that stays within
the limit is portable to all of them. Code that exceeds it works everywhere
except xt6502.
