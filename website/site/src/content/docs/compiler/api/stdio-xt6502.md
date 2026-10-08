---
title: Stdio (xt6502)
description: "The 6502 build of Stdio: text-mode screen output with a cursor and scrolling, a smaller printf, struct printing, and the shared varargs buffer's limits."
---

The banked 6502 gets its own `Stdio`, in `support/xt6502/lib/`, resolved ahead of
the generic one. It writes ATASCII screen codes straight into text-mode screen
RAM, keeps a cursor, scrolls when the cursor runs off the bottom, and formats
with a smaller `printf` built for a 16-bit `int` and a 64-byte argument buffer.
The API is [`Stdio`](/compiler/api/stdio/)'s; this page is what differs.

```c
#import <Stdio.xc>
```

## Overview

Every method is **`static`**, as on the other targets. The screen is the
output device: [`init`](#init) reads the screen mode and base from the OS, and
[`putChar`](#putchar) converts each ATASCII character to a screen code as it
stores it. A newline moves to the start of the next row; running off the bottom
of the text region [scrolls](#scroll). In a graphics mode with no text window,
output does nothing.

`%@` on an object is gated on the front-end `HAS_ATFMT` pre-scan: a program that
never uses it pays no `Object` or `String` footprint. `%@` on a plain `struct`
goes through [`printStruct`](#printstruct), which the other targets do not have.

## Topics

**Screen** · [putChar](#putchar) · [scroll](#scroll) · [setCursor](#setcursor) · [printfAt](#printfat) · [init](#init)

**Values** · [print](#print) · [printHex](#printhex) · [printFpDec](#printfpdec) · [printStruct](#printstruct)

**Limits** · [Format specifiers](#format-specifiers) · [Variadic limits](#variadic-limits)

---

## Screen

### putChar
```c
static void putChar(u8 ch)
```
Emits one character to the active text-mode screen, doing the ATASCII →
screen-code conversion and advancing the cursor. A newline (`$0A`) moves to the
start of the next row; running off the bottom of the text region calls
[`scroll`](#scroll) and backs the cursor onto the now-empty bottom row. In a
graphics mode (`canPrint == 0`) it does nothing. Not on the other targets:
calling it there is a compile error (`No method 'putChar' on class 'Stdio'`).

### scroll
```c
static void scroll(void)
```
Scrolls the text region up by one row and blanks the new bottom row. It stays
within `screenBase + cols * rows`, so a split-screen text strip cannot write
into the RAM around it. [`putChar`](#putchar) calls it at the end of the screen;
it is rarely called directly. xt6502 only.

### setCursor
```c
static void setCursor(u8 x, u8 y)
```
Moves the cursor to column `x`, row `y`, by computing a screen-RAM offset. On
the other targets the method exists and does nothing: a byte stream has no
cursor.

### printfAt
```c
static void printfAt(u8 x, u8 y, string fmt, ...)
```
[`setCursor(x, y)`](#setcursor) followed by [`printf`](/compiler/api/stdio/#printf),
for table-style screens. It is a pure forwarder that does not call `va_start`
itself, so it is exempt from the [reentrance check](#variadic-limits).

### init
```c
void init(void)
```
The zero-argument initializer, run by `new Stdio()`. It reads the screen mode
from `DINDEX` (`$57`), the screen base from `SAVMSC` (`$58/$59`) and the
text-window row count from `BOTSCR` (`$02BF`), and derives the column count from
the mode: GR.0 is 40 columns, GR.1/2/3 are 20, and a graphics mode has no text
output. Static callers never need it.

[↑ Topics](#topics)

## Values

### print
```c
static void print(string s)
static void print(String* s)                 // HAS_ATFMT only
static void print(u16 v)
static void print(i16 v)
static void print(u32 v)
static void print(i32 v)
static void print(u64 v)
static void print(i64 v)
static void print(float f)                   // 6 places
static void print(double d)                  // 10 places
static void print(float f,  u8 precision)    // %.Nf
static void print(double d, u8 precision)    // %.Nlf
```
The same overloads as the other targets, plus `print(u64)` and `print(i64)` as
public methods (elsewhere the 64-bit widths are printed by `printf` through
internal helpers). The precision-carrying overloads round at `N+1` decimal
places and keep `N`, as the native targets do.

### printHex
```c
static void printHex(u8 n)          // 2 digits
static void printHex(u16 v)         // 4 digits
static void printHex(u32 v)         // 8 digits
```
Fixed-width, uppercase, zero-padded hex with no `$` prefix. There is no
`printHex(u64)` here, and `printf` has no `%llx`.

### printFpDec
```c
static void printFpDec(double v, u8 keep, u8 roundAt)
```
The fixed-point float formatter behind `print(float)`, `print(double)` and the
`%.Nf` / `%.Nlf` conversions. It extracts `v`'s integer part and fractional
digits with the MECH float operations, rounds half-up at decimal place
`roundAt`, and prints the first `keep` places. A bare `%f` uses
`keep == roundAt == 6`, a bare `%lf` uses `10`; `%.Nf` uses `keep = N,
roundAt = N+1`. xt6502 only.

### printStruct
```c
static void printStruct(void)
```
Walks a compiler-generated struct descriptor and prints the struct's fields in
parentheses, recursing into nested structs and class-pointer fields. It is what
`%@` does with a plain `struct`: the `printf` `%@` branch stores the data and
descriptor pointers in the class's ivars and calls it.

```c
typedef struct { u16 x; u16 y; u8 tint; } Sprite;

Sprite s = {160, 96, 7};
Stdio.printf("sprite=%@\n", s);       // sprite=(160, 96, 7)
```

On the other targets `%@` on a struct prints a single `?`.

[↑ Topics](#topics)

## Format specifiers

The conversions and the argument rules are [`Stdio`'s](/compiler/api/stdio/#format-specifiers),
with `int` 16 bits wide. The formatter is smaller: a width, the flags and a
precision are read but only the precision is applied, `%e` and `%g` print in
fixed point as `%f` does, and `%o`, `%p` and `%llx` are not there.

## Variadic limits

A variadic call marshals its arguments through one shared 64-byte pack buffer
(`__xtc_va_buf`; the address comes from the active layout, see
[Functions → Shared pack buffer](/compiler/language/functions/#shared-pack-buffer-and-reentrance)).
For `printf`:

- The argument payload of one call is at most 62 bytes (64 minus the 2-byte
  format-pointer header).
- A `printf` call inside another variadic that has already called `va_start`
  overwrites the outer call's buffer. Sema diagnoses this at compile time.
- [`printfAt`](#printfat) is a pure forwarder with no `va_start` of its own, so
  it is exempt.

The other targets use their platform's varargs ABI, so there is no shared
buffer, no payload cap and no reentrance hazard. Code that stays within the
limit runs on all of them.

[↑ Topics](#topics)
