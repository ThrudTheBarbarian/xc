---
title: Stdio
description: "Standard-output printing and a printf-style formatter that handles every primitive plus objects and enums."
---

`Stdio` is the console-output class. It prints values and formats them through a
`printf`-style API. Every method is **`static`**, so there is no instance to
create. Call `Stdio.printf(...)` directly, or add `use Stdio;` to drop the
`Stdio.` prefix and write `printf(...)`.

```c
#import <Stdio.xc>
```

## Overview

`Stdio` is reimplemented per backend architecture, resolved ahead of
`support/generic/lib` on the include path. The native backends format each value
to ASCII and push it a byte at a time through the host runtime's `_putc`, so
output is an ordinary byte stream with no addressable grid; on wasm32 the
loader passes it to the page, and on Android the app's glue copies it to
logcat. The banked 6502 writes to a text-mode screen with a cursor and
scrolling, with a smaller formatter: see [Stdio (xt6502)](/compiler/api/stdio-xt6502/).

`printf` follows C: the same conversions, flags, widths and precisions, with the
same output, plus `%@` for objects. It is built on
[`String.withFormat`](/compiler/api/string/#withformat), so the two always agree.

:::note[Availability]
Every target. [`setCursor`](#setcursor) and the `(x, y)` of
[`printfAt`](#printfat) do nothing where there is no screen: stdout has no
cursor. `putChar`, `scroll`, `printFpDec` and a `printStruct` that walks a
struct exist only on xt6502.
:::

## Topics

**Printing values** · [print](#print) · [printHex](#printhex)

**Formatted output** · [printf](#printf) · [printfAt](#printfat) · [setCursor](#setcursor)

**Struct & object printing** · [printStruct](#printstruct)

---

## Printing values

Direct, non-formatted printing. `print` is overloaded across every primitive
type, and sema picks the overload from the argument's type. None of these append
a newline; supply `"\n"` yourself.

### print
```c
static void print(string s)                  // u8* C string
static void print(String* s)
static void print(u16 v)
static void print(i16 v)
static void print(u32 v)
static void print(i32 v)
static void print(float f)                   // 6 dp default
static void print(double d)                  // 10 dp default
static void print(float f,  u8 precision)    // %.Nf
static void print(double d, u8 precision)    // %.Nlf
```
Prints a value in its natural decimal (or, for `string`/`String*`, verbatim)
form. There is no `print(u8)` overload: `u8` widens implicitly to `u16`, so pass
`u8` values directly. The 64-bit widths are printed by `printf` (`%lld`, `%llu`)
through internal helpers. The precision-carrying float and double overloads
back the `%.Nf` / `%.Nlf` conversions: they round at `N+1` decimal places and
keep `N`.

### printHex
```c
static void printHex(u8 n)          // 2 digits
static void printHex(u16 v)         // 4 digits
static void printHex(u32 v)         // 8 digits
static void printHex(u64 v)         // 16 digits
```
Fixed-width, uppercase, left-zero-padded hex with no `$` prefix. The width is the
type's full width, so `printHex((u16)$2A)` prints `002A`.

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
[`setCursor(x, y)`](#setcursor) followed by [`printf`](#printf). On a byte
stream the `(x, y)` is ignored; it positions the text on the 6502's screen.

### setCursor
```c
static void setCursor(u8 x, u8 y)
```
Moves the cursor to column `x`, row `y` on a target with a screen; a no-op on
the native backends, where stdout is a byte stream.

[↑ Topics](#topics)

## Struct & object printing

### printStruct
```c
static void printStruct(void)
```
Prints a single `?`: `%@` on a plain `struct` is not implemented on the native
backends. On xt6502 the method walks the struct's descriptor and prints its
fields ([Stdio (xt6502)](/compiler/api/stdio-xt6502/#printstruct)).

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

The 6502's formatter applies only the precision and lacks `%o`, `%p` and
`%llx`; its calls also share one 64-byte argument buffer. Both are described in
[Stdio (xt6502)](/compiler/api/stdio-xt6502/#format-specifiers).

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
`description()`, so `%@` on a struct prints `?` here; the 6502 formats its
fields ([printStruct](/compiler/api/stdio-xt6502/#printstruct)).

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
