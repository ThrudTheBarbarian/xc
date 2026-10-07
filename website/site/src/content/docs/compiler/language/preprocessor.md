---
title: Preprocessor
description: "#import and #include (source files and libraries), #use, #define with arguments and varargs, conditional compilation, #warning and #error."
---

The preprocessor runs before the lexer and produces the source the rest of the compiler operates on. It sits alongside the language, not inside it: it handles file inclusion, conditional compilation and simple macro substitution, and has no semantic role.

## File inclusion: `#import` and `#include`

```c
#import  <Stdio.xc>     // a library file: the -I paths and the standard library
#import  "Sprite.xc"    // your own file: next to this one first
#import  <Stdio>        // the extension may be left off
#import  <Xtg>          // a shared library: libXtg.dylib / .so / .dll on -L
#include "table.xc"     // as #import, but included every time it appears
```

`#import` includes a file **once** per compilation, however many times it is
named. `#include` pastes the file in every time, as C's does. Library files and
anything another file might also import should use `#import`. Both directives
take the same names and look in the same places.

### What a name can resolve to

The name in an `#import` is looked up as a **source file** first and, if there is
none, as a **library**:

| The name finds | What happens |
|---|---|
| a `.xc` source file | its text is compiled as part of this file (once, for `#import`) |
| an xcc shared library (`--emit-lib`) | nothing is pasted in: the library's classes, protocols, structs, enums and functions are read from the interface embedded in the binary, and the program links against it |
| a separately compiled module's `Name.xtc.iface` | the same, for an object built with `xcc -c` |
| a C shared library | its functions, types and enum constants are read from its DWARF debug information. From 0.72 that includes a stripped library's separate debug file, as a Linux distribution installs it with the library's debug package (`-dbgsym`, `-debuginfo`): found by build ID or `.gnu_debuglink` under `/usr/lib/debug`, or under the directories in `XCC_DEBUG_DIR` (colon-separated) when that is set. From 0.73, on `-A win64`, a DLL built by a MinGW toolchain with `-g` is read the same way (its DWARF is in the DLL; build it with `-fno-eliminate-unused-debug-types` to keep enum constants). A library with no debug information anywhere gets a warning, and the functions you call from it then need declaring |
| a macOS or iOS system framework (from 0.65) | the program is linked against it, as `-framework` does; it declares nothing, so its functions are declared in your source without bodies |

So `#import <Xtg>` and `#import <Stdio>` look alike but do different things: the
first finds `libXtg.dylib` and imports its interface, the second finds
`Stdio.xc` and compiles it. See [Modules & shared libraries](/compiler/language/modules/)
for building and using libraries.

### Where it looks

**Source files**, in this order:

1. **The directory of the file doing the import**, for the quoted form only
   (`"Sprite.xc"`). The angle form (`<Stdio.xc>`) skips it, so a file of yours
   with a library's name cannot be picked up by mistake.
2. **Each `-I` directory**, in the order given on the command line.
3. **The standard library**: the target's own directory (`lib/xc/<target>/lib`
   in an install), then the shared one (`lib/xc/generic/lib`).

A `-I` directory comes before the standard library, so a file there replaces
the library's file of the same name. That is deliberate (it is how a project
carries a patched copy), but it also means a stray `Stdio.xc` in a `-I`
directory hides the real one.

**Libraries**, when no source file matched:

1. **Each `-L` directory**, trying `lib<Name>` with the target's library
   extension: `.dylib` then `.so` for arm64; `.so` then `.dylib` for x86-64 and
   arm9; `.dll`, then the `.dll.a` and `.a` import libraries, for win64; `.wasm`
   for wasm32. Then the name exactly as written (`libfoo.a`), then
   `Name.xtc.iface`.
2. **The third-party tree**: `$XCC_3P` if it is set, then the `3p` directory
   beside the compiler's own (`/opt/xcc/3p` for an install in
   `/opt/xcc/<version>`). A library there lives at
   `3p/<vendor>/<target>/lib<Name>.<ext>`; `<Name>` looks in the vendor
   directory of the same name, and `<vendor/Name>` names the vendor explicitly.
   When one is found, the vendor's `3p/<vendor>/xc` directory of xc sources is
   added to the **end** of the search path, so its helper files can be
   imported but never hide the standard library's.
3. **A system framework** (from 0.65), on macOS and iOS only, for a name with
   no `.` or `/`: `CoreFoundation.framework` in the SDK when one is installed, else in
   `/System/Library/Frameworks`. `#import <CoreFoundation>` is then the same
   as `-framework CoreFoundation` on the command line:

   ```c
   #import <CoreFoundation>
   pointer CFStringCreateWithCString(pointer alloc, u8* s, u32 encoding);
   void CFRelease(pointer cf);
   ```

   A library can carry its own framework dependencies this way, so the
   programs that use it need no flags.

If nothing matches, the error names every directory searched:

```
app.xc:3:1: error: Cannot find include file 'Xtg' (searched: '/opt/xcc/0.65/lib/xc/arm64/lib' '/opt/xcc/0.65/lib/xc/generic/lib' -L 'build')
```

### Spelling the name

- **The extension is optional.** A name with no `.` also tries `Name.xc`, so
  `#import <Stdio>` finds `Stdio.xc`. A name with an extension is used exactly.
- **Matching is case-sensitive**, even on macOS's case-insensitive filesystems:
  `#import <Sort.xc>` never matches a file called `sort.xc`. This keeps a
  program named after a library from importing itself.
- **The old `.xt` extension** is still accepted: a bare name falls back to
  `Name.xt`, and an explicit `"Name.xt"` that is missing is retried as
  `Name.xc`.
- **A library's name has no `lib` prefix and no extension**: `#import <Xtg>`
  for `libXtg.dylib`. `#import <c>` imports the C library itself, on the arm9
  target, whose loader provides one.

## Importing and promoting: `#use`

`#use` imports a name and then lets you call its class's static methods without
the class name. It expands to `#import` of the name followed by the
language-level [`use Name;`](/compiler/language/classes/#bare-call-promotion-use-classname),
so one line replaces two:

```c
#use Stdio          // #import "Stdio" + use Stdio;
#use Math

void main(void) {
    printf("answer = %u\n", 42);    // Stdio.printf
    u8 r = rand((u8)100);           // Math.rand
}
```

The name may be written bare, in angle brackets or in quotes, and a trailing
`.xc` is dropped:

| Written | Imports as | Looks next to this file first? |
|---|---|---|
| `#use Stdio` | `#import "Stdio"` | yes |
| `#use "Sprite"` | `#import "Sprite"` | yes |
| `#use <Time>` | `#import <Time>` | no |

The bare form behaves like the quoted one, so a `Stdio.xc` of your own next to
the source would be found before the library's. Use `#use <Stdio>` when you
want to be sure of the library's.

Because the import half is an ordinary `#import`, `#use` reaches everything
`#import` does, and the `use` half then applies to the class of that name, if
there is one:

```c
#use Stdio          // a standard library class
#use "Sprite"       // a class in your own Sprite.xc
#use <Greet>        // a shared library, libGreet.dylib on -L, with a class Greet
#use <tls>          // a third-party library from /opt/xcc/3p
```

With `#use <Greet>`, `hello()` calls `Greet.hello()` from the library. Where the
library has no class of that name, as with `tls`, the `use` half has nothing to
promote and the line simply imports the library, so `#use <tls>` and
`#import <tls>` are the same.

After `#use Stdio`, `printf("hi")` resolves as `Stdio.printf("hi")` would. Only
bare calls are affected: `Klass.method(...)`, free functions and local
variables are not. If several `use`d classes have a method of the same name, the
call is resolved by overload scoring, and a call that matches two equally well
is an error that names both. The promotion holds for the rest of the file. See
[`use`](/compiler/language/classes/#bare-call-promotion-use-classname) for the
full rules.

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
| `-A android` | `ARCH_arm64` **and** `PLATFORM_android` |
| `-A x86_64` | `ARCH_x86_64` |
| `-A win64` | `ARCH_x86_64` **and** `ARCH_win64` |
| `-A arm9` | `ARCH_arm9` |
| `-A m68k` | `ARCH_m68k` |
| `-A wasm32` | `ARCH_wasm32` |
| `-A 6502` | `ARCH_6502` |

Windows defines both because it uses the x86-64 instruction set. ISA-guarded
code (inline assembly, register names) keys off `ARCH_x86_64`, and OS-specific
code (calling convention, system calls) keys off `ARCH_win64`. Android is the
arm64 instruction set on a different operating system, so it adds
`PLATFORM_android`; the iOS targets add `PLATFORM_ios` (and `PLATFORM_ios_sim`
for the simulator) in the same way.

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
