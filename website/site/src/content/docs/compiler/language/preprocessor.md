---
title: Preprocessor
description: "#include, #import, #define with arguments and varargs, conditional compilation, #warning and #error."
---

The preprocessor runs before the lexer and produces the source the rest of the compiler operates on. It sits alongside the language, not inside it: it handles file inclusion, conditional compilation and simple macro substitution, and has no semantic role.

## File inclusion

```c
#include <file.xc>      // search the system / -I paths only
#include "file.xc"      // search next to the current file first

#import  <Stdio.xc>     // include-once form, same search rules
#import  "Sprite.xc"
```

The two quote forms select different search orders, matching C/C++ convention:

- **`"file.xc"`**: look next to the file doing the include first, then fall through to the system directories and any `-I` paths. Use this for files that live alongside your source.
- **`<file.xc>`**: skip the current source's directory and go straight to system / `-I` paths. Use this for library headers, so a same-named file in your project cannot silently shadow the real library.

Filename matching is **case-sensitive** even on case-insensitive filesystems. `#import <Sort.xc>` never matches a sibling `sort.xc`, even on macOS's HFS+/APFS. This prevents a common collision where a user names their program after a library they import.

`#import` is identical to `#include` except that the named file is included only once across the entire compilation unit. Library headers should use `#import`, so a user can `#import` them freely without two copies of the contents in scope.

## Importing and promoting a class: `#use`

`#use` is sugar for the common case of *"import a library class and let me call its static methods bare."* It expands to `#import "ClassName.xc"` followed by [`use ClassName;`](/compiler/language/classes/#bare-call-promotion-use-classname) (the language-level directive), so one line replaces two.

```c
#use Stdio          // == #import "Stdio.xc" + use Stdio;
#use Math
#use <Time>         // angle-bracket and quote forms also accepted
#use "Sprite"

void main(void) {
    printf("answer = %u\n", 42);    // resolves to Stdio.printf
    u8 r = rand((u8)100);           // resolves to Math.rand
}
```

The class name may be written bare (`#use Stdio`), in angle brackets (`#use <Stdio>`), or in quotes (`#use "Stdio"`). A trailing `.xc` extension is stripped if you include it. The `< >` vs `" "` search-order rule of `#include` / `#import` applies to the underlying file lookup.

After `#use Stdio`, `printf("hi")` resolves the same way as `Stdio.printf("hi")`, with the receiver class implied. This affects bare calls only; explicit `Klass.method(...)` calls, free functions and local variables are unaffected. The resolution rules (overload scoring, ambiguity diagnostics when several `use`'d classes expose a method with the same name, and the file-local scope of the promotion) are documented with the [language-level `use` directive](/compiler/language/classes/#bare-call-promotion-use-classname).

## Macros

```c
#define DBL(x)   (double(x))
#define ZP_BASE  $80
#define ENABLE_DOUBLE 1
```

`#define` introduces a macro, optionally taking comma-separated arguments. At each later occurrence, the comma-separated actuals are substituted for the placeholders. Macros can be removed with `#undef`.

### Variadic macros

A macro whose last parameter is `...` is variadic; substitute the variadic tail with `__VA_ARGS__` in the body:

```c
#define LOG(level, ...)   Stdio.printf("[" level "] " __VA_ARGS__)

LOG("warn", "value=%d\n", x);
// expands to: Stdio.printf("[" "warn" "] " "value=%d\n", x);
```

This follows the standard C model. GNU's `, ##__VA_ARGS__` comma-swallow is also supported: an
empty variadic tail removes the comma before it, so `LOG("hi")` expands cleanly:

```c
#define LOG(fmt, ...)   Stdio.printf(fmt, ##__VA_ARGS__)

LOG("done\n");          // → Stdio.printf("done\n")     — no dangling comma
LOG("x=%d\n", x);       // → Stdio.printf("x=%d\n", x)
```

### Stringize (`#`) and token paste (`##`)

`#param` replaces the parameter with a **string literal** of the argument as written.
`a ## b` **pastes** two tokens into one.

Both operate on the unexpanded argument, so the idiomatic form uses two levels: the outer
macro expands its arguments normally, and only the inner one applies the operator.

```c
#define CAT2(a,b)  a##b
#define CAT(a,b)   CAT2(a,b)
#define STR2(x)    #x
#define STR(x)     STR2(x)
#define VER        7

CAT(x, VER)     // → x7      — VER expanded first, then pasted
CAT2(x, VER)    // → xVER    — pasted raw
STR(VER)        // → "7"
STR2(VER)       // → "VER"
```

The usual application is building a name from its parts, such as an ABI symbol from a version
number, so that a mismatch fails at link time by name instead of surfacing later as a wild
jump through a stale vtable.

### Substitution is token-aware

A parameter is substituted only where it appears as a **whole token**. It is not replaced
inside a longer identifier, and not inside a string literal:

```c
#define ABS_OK(a)   a + abs_val      // `a` does NOT rewrite `abs_val`
#define INSTR(a)    "a is here"      // `a` does NOT rewrite the string
```

Likewise, a comma inside a string argument is part of that argument, not a separator:
`P("a,b")` passes one argument.

## Conditional compilation

```c
#ifndef ENABLE_DOUBLE
 #define ENABLE_DOUBLE 1
#endif

#if ENABLE_DOUBLE
 // …double-precision code…
#elif ENABLE_FLOAT
 // …single-precision fallback…
#else
 #error neither double nor float enabled
#endif

#ifdef DEBUG
 Stdio.print("debug build\n");
#endif
```

`#ifdef` / `#ifndef` test for the presence (or absence) of a macro definition. `#if` evaluates a constant integer expression. The chain may include any number of `#elif` clauses and an optional `#else`, terminated by `#endif`.

Macros may be defined on the command line with `-D`, one name per flag:

```bash
xcc -D ENABLE_DOUBLE=0 -D DEBUG -o app app.xc
```

The name may also be joined to the flag: `-DDEBUG` is the same as `-D DEBUG`.

## Predefined macros

The driver predefines an `ARCH_<arch>` sentinel for the target being built, so a
single source file can serve every backend. The standard library uses this to
keep one copy of each class:

| Target | Defined |
|---|---|
| `-A arm64` | `ARCH_arm64` |
| `-A x86_64` | `ARCH_x86_64` |
| `-A win64` | `ARCH_x86_64` **and** `ARCH_win64` |
| `-A arm9` | `ARCH_arm9` |
| `-A m68k` | `ARCH_m68k` |
| `-A wasm32` | `ARCH_wasm32` |
| `-A 6502` | `ARCH_6502` |

Windows defines both because it uses the x86-64 instruction set. ISA-guarded
code (inline assembly, register names) keys off `ARCH_x86_64`, and OS-specific
code (calling convention, system calls) keys off `ARCH_win64`.

```c
#if ARCH_6502
    // a byte-oriented path, and no i64 arithmetic
#elif ARCH_win64
    // kernel32, and the Microsoft x64 calling convention
#else
    // the 64-bit hosts
#endif
```

Threading headers use this to fail at compile time: on `xt6502` and `m68k`,
`Thread.xc` is an `#error`, not a stub.

Also predefined: `BANK_DATA`, `BANK_CODE`, `BANK_C` (selector constants for the
`bank(…)` builtin), `XTC_POINTER_WIDTH`, and, on 6502 targets, a set of
layout-derived addresses (`XT_PRINTF_BUF`, `XTC_HP_LO` …) that inline assembly
in the runtime needs, since the preprocessor cannot test a memory-model
property directly. These come from the active `.lnk` file, so a custom layout
changes them.

## Diagnostics from source

```c
#warning need to implement doFrobble()
#error no supported target selected
```

`#warning` produces a compile-time warning containing the text and lets the build continue. `#error` produces a fatal error and stops compilation. Both honour conditional compilation, so you can use them inside `#if` chains to enforce build-configuration invariants.
