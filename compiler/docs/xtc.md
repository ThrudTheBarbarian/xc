# Xtc

Xtc is a statically typed language with classes, single inheritance, protocols
and automatic reference counting. It compiles through one architecture-neutral
SSA intermediate representation to a banked 6502, arm64, x86-64, win64, arm9,
68000 and WebAssembly. The same source and the same standard library run on all
of them.

The compiler is called `xcc` and behaves like a C compiler:

```
xcc -o hello hello.xc                 # a native binary for this machine
xcc -A 6502 -o hello.xex hello.xc     # the same source, for the banked 6502
```

## Where the reference lives

The reference is published a page per topic at <https://compile-xc.org>:

| Topic | Page |
|---|---|
| Language reference | `/compiler/language/` |
| Grammar | `/compiler/language/grammar/` |
| Lexical structure | `/compiler/language/lexical/` |
| Preprocessor | `/compiler/language/preprocessor/` |
| Types | `/compiler/language/types/` |
| Operators | `/compiler/language/operators/` |
| Statements and control flow | `/compiler/language/statements/` |
| Classes and inheritance | `/compiler/language/classes/` |
| Heap, ARC and weak refs | `/compiler/language/memory/` |
| Inline assembly | `/compiler/language/inline-asm/` |
| Command line | `/compiler/usage/cli/` |
| Memory models | `/compiler/usage/memory-models/` |
| Installing | `/compiler/usage/install/` |

The grammar also ships in this directory as `xtc.bnf`, so a checkout carries it
without the site. The two are kept in step.

## What used to be here

This file held a language manual written when the 6502 was the only target.
Every one of its chapters is now covered by the pages above, and parts of it had
fallen out of date: it listed memory models the compiler no longer accepts, and
a support directory layout that no longer matches the tree. It was replaced
rather than repaired, so there is one reference to keep current instead of two.
