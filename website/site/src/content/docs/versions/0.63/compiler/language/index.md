---
title: Language reference
description: The xcc language — syntax, types, classes, protocols, memory, collections, threading and inline assembly.
slug: versions/0.63/compiler/language
banner:
  content: 'This is the documentation for xc 0.63. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

xcc is a small, statically-typed language with C-family syntax, ObjC-like classes
and protocols, and a focus on producing dense code for machines with little
memory. Every page below has a **worked example that compiles and runs**. The
programs live in the repository and a script builds them, so the code blocks
match what the compiler does.

## Where to start

To read the reference in order:

1. [**Lexical structure**](/versions/0.63/compiler/language/lexical/): comments, identifiers, numeric and string literals, reserved words.
2. [**Preprocessor**](/versions/0.63/compiler/language/preprocessor/): `#include` / `#import`, `#define`, conditional compilation.
3. [**Types**](/versions/0.63/compiler/language/types/): the fixed-width scalars including `i64`/`u64`, structs, enums, pointers, arrays, inference, casting.
4. [**Operators**](/versions/0.63/compiler/language/operators/): the full precedence table, including the rotate (`<:` `:>`) and byte-extract (`<` `>` `>>` `>>>`) operators.
5. [**Statements & control flow**](/versions/0.63/compiler/language/statements/): declaration modifiers, `if`, `switch`, the two `for` loops, `while`, `defer`, `:unroll`.
6. [**Functions**](/versions/0.63/compiler/language/functions/): declarations, multiple return values, varargs, overloading, function annotations.
7. [**Classes**](/versions/0.63/compiler/language/classes/): heap and stack allocation, methods, properties, `init` / `dealloc`.
8. [**Inheritance & protocols**](/versions/0.63/compiler/language/inheritance/): single inheritance, virtual dispatch, downcasts (`(Dog*)a` and the failable `(Dog* ?)a`), protocols and optional methods.
9. [**Bound methods & callbacks**](/versions/0.63/compiler/language/bound-methods/): `callback`, target/action, and why a callback needs no context pointer.
10. [**Blocks**](/versions/0.63/compiler/language/blocks/): `{ … }` closures that capture their surrounding scope, and how they pair with bound methods.
11. [**Errors**](/versions/0.63/compiler/language/errors/): the `throws` effect, `throw`, typed and untyped `catch` arms, the `Error` protocol.
12. [**Heap, ARC & weak refs**](/versions/0.63/compiler/language/memory/): `new` / `delete`, automatic reference counting, `weak:` references.
13. [**Collections & strings**](/versions/0.63/compiler/language/collections/): `Array<T>`, `Map<V>`, `Set<T>`, `String`, and how element types are checked then erased.
14. [**Threading**](/versions/0.63/compiler/language/threading/): `Thread`, `Mutex`, `Atomic`, `Pool`, and the automatic atomic-refcount decision. Native targets only.
15. [**Modules & shared libraries**](/versions/0.63/compiler/language/modules/): `--emit-lib`, `#import <Lib>`, what crosses a library boundary, and `extern` globals.
16. [**Inline assembly**](/versions/0.63/compiler/language/inline-asm/): `asm { … }` blocks, byte-extract operators, reaching xcc variables, the `clobbers` annotation.

For day-to-day reference, open the page you need from the sidebar.

## Things that differ from C

- **The pointer sigil binds to the type.** `u8* a, b;` declares **two pointers**,
  not a pointer and an integer.
- **No promotion to `int`.** Same-width arithmetic stays at that width, so
  `u8 + u8` wraps at 8 bits. Only mixed-width operands widen.
- **`printf` widths are explicit.** `%d` is 16-bit, `%ld` is 32-bit and `%lld`
  is 64-bit. All three are signed, so use the `%u` family (`%u`, `%lu`, `%llu`)
  for unsigned. The compiler checks the format string against the argument
  types, and *widens* a conversion whose argument is statically wider, so
  `%d` on an `i64` prints the whole value instead of truncating.
- **Source files are `.xc`.**

## What's not on these pages

- **Compiler flags, optimisation levels, memory-model selection** are in
  [Compiler usage](/versions/0.63/compiler/usage/). They shape the output but are not part of
  the language. Start with [Install](/versions/0.63/compiler/usage/install/).
- **Standard library classes** (`Stdio`, `Math`, `Heap`, `Assert`, …) are in the
  [Standard library reference](/versions/0.63/compiler/api/).
- **Memory-model internals** (the two bank windows, the hardware stack) are
  summarised where they affect semantics. The full map is in
  [Compiler usage → Memory models](/versions/0.63/compiler/usage/memory-models/).
