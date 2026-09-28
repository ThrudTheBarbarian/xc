---
title: Lexical structure
description: Comments, identifiers, numeric and string literals, reserved words.
---

## Comments

xcc uses C-family comment syntax:

```c
// single-line — runs to end of line
/* block — runs until the matching closer */
```

## Identifiers

- Case-sensitive (`Foo` and `foo` are distinct).
- Start with a letter; subsequent characters may be letters, digits, or underscore.
- Reserved words may not be used as variable, class, or struct names.

## Numeric literals

Three radix prefixes are recognised. `_` is ignored anywhere inside a numeric literal, so you can group digits for readability.

```c
u16 a = 1234;        // decimal
u16 b = $1234;       // hex
u16 c = 0x1234;      // hex, the C spelling — identical to the line above
u8  d = %1010_0101;  // binary, with grouping underscore
u32 big = 16_777_216;
u32 mask = 0xFFFF_0000;   // underscores work in either hex spelling
```

`$` comes from 6502 assembler tradition and `0x` (or `0X`) from C. They mean the
same thing and either can be used anywhere. Binary uses `%`.

### Float literals

A decimal literal with a `.` and digits after it is a `float` (4-byte IEEE-754):

```c
float f = 0.5;
float g = 3.25;
```

A trailing suffix sets the width, and either suffix makes a literal a floating
point number even without a decimal point:

| Suffix | Type | Example |
|--------|------|---------|
| `f` / `F` | `float` | `0.68f`, `1f` |
| `d` / `D` | `double` | `0.68d`, `1d` |

`f` and `d` are C's (and Java's) spellings, so a table of constants ported from
either compiles unchanged.

A literal with **no suffix is a `float`**, whatever it is assigned to, and is
widened to `double` afterwards if that is where it lands. `double d = 0.1;` is
therefore the `float` value `0.1` widened, printed as `0.10000000149011611`, not
the `double` `0.1`. Write `0.1d` when the extra precision matters.

## String and character literals

Strings are double-quoted and null-terminated. The trailing `\0` is not counted in `length`. The recognised escape sequences are:

| Escape | Means |
|--------|-------|
| `\n` | newline (CR + LF) |
| `\r` | carriage return |
| `\t` | tab |
| `\0` | end-of-string marker |
| `\\` | a literal backslash |
| `\"` | a literal `"` inside a string |
| `\'` | a literal `'` inside a character literal |
| `\xNN` | an ASCII byte: 2 hex digits, `00`–`7F` |
| `\uNNNN` | a Unicode code point: 4 hex digits |
| `\UNNNNNNNN` | a Unicode code point: 8 hex digits |

```c
string greeting = "hello\n";
String* s = String.withCString("caf\u00E9 \U0001F600");   // "café 😀"
```

`\u` and `\U` are encoded in the string as **UTF-8** (`"\u00E9"` is the two bytes
`C3 A9`). A surrogate (`D800`–`DFFF`) or a value above `10FFFF` is a
compile error. The digit counts are fixed, unlike C's greedy `\x`. Also unlike C,
`\x` is capped at `7F`. A bare byte above `7F` inside a UTF-8 string is either
half a character (use `\u`) or intended binary (use `Data`/`appendByte`), so the
compiler rejects it instead of silently re-encoding it. Source files are UTF-8, so a raw
`é` in a literal is equivalent to `\u00E9`.

A character literal is a single character (or an escape) inside single quotes, evaluated as a `u8`:

```c
u8 tab = '\t';
u8 a   = 'A';
u8 e   = '\u00E9';    // must fit a u8 — the Latin-1 view
```

Spell a non-ASCII character in a char literal with `\u`, not as a raw
character. A raw multi-byte character between single quotes is not portable.

A single string literal cannot span source lines, but **adjacent string
literals concatenate**, as in C, and a newline between them makes no difference:

```c
Stdio.print("one" "two\n");                 // onetwo

Stdio.print("a long message that would "
            "otherwise be one unbreakable "
            "source line as wide as itself\n");
```

The parser joins the pieces into one literal before any later stage sees them,
so there is no run-time concatenation or cost.

## Reserved words

The **lexer** turns these words into keyword tokens. They are never identifiers.

`asm`, `auto`, `bool`, `break`, `case`, `catch`, `class`, `continue`, `default`, `defer`, `delete`, `double`, `else`, `enum`, `extern`, `false`, `final`, `float`, `for`, `global`, `i8`, `i16`, `i32`, `if`, `in`, `inline`, `new`, `optional`, `pointer`, `protocol`, `register`, `release`, `retain`, `return`, `sizeof`, `static`, `string`, `struct`, `switch`, `throw`, `throws`, `true`, `try`, `typedef`, `u8`, `u16`, `u32`, `use`, `void`, `volatile`, `while`.

The parser also rejects the **C reserved words** as variable names, even where xcc gives them no meaning, so that C-shaped source cannot silently acquire a different meaning:

`char`, `const`, `do`, `goto`, `int`, `long`, `restrict`, `short`, `signed`, `union`, `unsigned`, plus those above that C also reserves.

### Contextual words

A third group is meaningful only in a particular position, and is an ordinary identifier everywhere else: `self` and `super` inside a method body; `init` and `dealloc` as method names; `weak:`, `banked:`, `block:`, `main:` and `shadow:` as declaration qualifiers; `va_start` / `va_arg` / `va_end` inside a variadic; `clobbers` after an `asm` block; and the function annotations (`:naked`, `:hwStack`, `:irq`, `:vbi`, …) documented on the [Functions](/compiler/language/functions/) page. Using one of these as a variable name is legal but confusing to read.

## Block delimiters

A block is `{ ... }`.

```c
void greet(void) {
    Stdio.print("hi\n");
}
```

## Statement terminator

Statements terminate with `;`. The terminator is required: function declarations without a body, variable declarations, and expression statements all end in `;`.
