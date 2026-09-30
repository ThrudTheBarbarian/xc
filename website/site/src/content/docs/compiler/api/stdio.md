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

`printf` follows C: the same conversions, flags, widths and precisions, with the
same output, plus `%@` for objects. On the native backends it is built on
[`String.withFormat`](/compiler/api/string/#withformat), so the two always agree.
The xt6502 build is a smaller formatter with the same argument rules; see
[Format specifiers](#format-specifiers) for what it leaves out.

:::note[Availability]
- [`putChar`](#putchar), [`scroll`](#scroll) and [`printFpDec`](#printfpdec) exist
  only in the **xt6502** build, because they are screen-model / fixed-point operations.
  Calling `putChar` or `scroll` on a native backend is a compile error
  (`No method 'putChar' on class 'Stdio'`).
- [`setCursor`](#setcursor) and the `(x, y)` position of [`printfAt`](#printfat)
  are no-ops on the native backends: stdout has no cursor.
- The 64-bit `print` overloads ([`print(i64)` / `print(u64)`](#print)) and
  `%lld`/`%llu` are on both; `%llx` and `printHex(u64)` are **native only**
  (xt6502's `printHex` tops out at 32-bit and its `printf` has no `%llx`).
- On xt6502, `%@` object formatting is gated on the front-end `HAS_ATFMT`
  pre-scan so a program that never uses it pays no `Object`/`String` footprint.
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
The main formatted-output method: C's `printf`, plus `%@`. See
[Format specifiers](#format-specifiers) below for the full contract.

### printfAt
```c
static void printfAt(u8 x, u8 y, string fmt, ...)
```
[`setCursor(x, y)`](#setcursor) followed by [`printf`](#printf), for
table-style screens. On xt6502 it is a pure forwarder that does not call
`va_start` itself, so it is exempt from the varargs-reentrance check. On the
native backends the `(x, y)` is ignored.

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

The conversions are C's, and so are the rules for the arguments. The same
contract covers [`String.withFormat`](/compiler/api/string/#withformat),
[`String.appendFormat`](/compiler/api/string/#appendformat) and `Log.error`,
`Log.warning` and `Log.info`.

A conversion is `%`, then any flags (`-` left-justify, `+` always a sign, space
a space for a positive number, `#` the alternate form, `0` pad with zeros), a
field width, a `.` and a precision, a length, and the conversion letter. A `*`
for the width or precision takes it from an `i32` argument.

| Conversion | Argument | Output |
|------------|----------|--------|
| `%d` `%i` | integer | signed decimal |
| `%u` | integer | unsigned decimal |
| `%x` `%X` | integer | hex, lower / upper case, no leading zeros |
| `%o` | integer | octal |
| `%c` | integer | one character |
| `%f` `%F` | `float` or `double` | fixed point, 6 places unless a precision is given |
| `%e` `%E` | `float` or `double` | exponent form, `1.500000e+03` |
| `%g` `%G` | `float` or `double` | the shorter of the two, trailing zeros removed |
| `%s` | `string` (`u8*`) | NUL-terminated string |
| `%p` | pointer | `0x` and the address in hex |
| `%@` | class instance, or an enum | the object's `description()`; an enum's name |
| `%%` | — | literal `%` |

The arguments follow C. An integer narrower than `int` is passed as an `int` and
a `float` as a `double`, so `%c` takes a `u8` and `%f` a `float` as they are.
`int` is 32 bits, except on xt6502, where it is 16. The length says how wide the
integer is: none for an `int`, `h` and `hh` for narrower ones, `l` for a `long`,
which is 64 bits on the 64-bit targets and 32 elsewhere, `ll` for 64 bits, and
`z` or `t` for a pointer-sized value.

When the format is a **string literal**, the compiler sets each integer
conversion's length from the argument actually passed, so the length can be
left off: `%d` prints an `i64` whole, and `%lld` given an `i32` reads only the
32 bits that are there. What it cannot fix is the wrong kind of argument — a
`double` for `%d`, an integer for `%s` — and it warns about that, and about a
count that does not match (`-Wno-printf-format` silences both). A format built
at run time is read as C reads it, and then the length has to be right.

A variadic function or method that passes its own format parameter and `...`
straight on to one of these gets the same treatment at its own call sites:

```c
void say(string fmt, ...) { _out.appendFormat(fmt, ...); }
```

```c
u16 score  = 1234;
i64 millis = -50000;
float pi   = 3.14159;
string name = "Player 1";

Stdio.printf("%s scored %u in %d ms\n", name, score, millis);
Stdio.printf("pi ~ %.2f\n", pi);              // pi ~ 3.14
Stdio.printf("[%-6s|%06x]\n", "id", 255);     // [id    |0000ff]
Stdio.printf("ratio: %u%%\n", 42);            // ratio: 42%
```

On **xt6502** the formatter is smaller: a width, the flags and a precision are
read but only the precision is applied, `%e` and `%g` print in fixed point as
`%f` does, and `%o`, `%p` and `%llx` are not there.

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

### Enum names

Given a value **statically typed as an enum**, `%@` prints the member's name.
`%e` does the same with an enum; with a `float` or `double` it is C's exponent
form. The translation happens at **compile time**: the conversion becomes `%s`,
and a small `_enum_lookup_<EnumName>(value)` helper, emitted once per enum,
supplies the name.

```c
enum direction = {N = 1, E, S, W};

direction d = E;
Stdio.printf("heading: %@\n", d);     // heading: E
Stdio.printf("raw    : %u\n", d);     // raw    : 2
```

This needs a literal format, where the compiler can see which conversion the
enum meets. A value outside the enum prints `?`.

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
