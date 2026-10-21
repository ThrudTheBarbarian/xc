---
title: C programs
description: Building a C program with xcc, what it needs installed, which parts xcc compiles itself, and how its loops become par blocks.
slug: versions/0.85/compiler/usage/c-programs
banner:
  content: 'This is the documentation for xc 0.85. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

`xcc` builds a C program the way it builds an xc one:

```bash
xcc -o mandel mandel.c
xcc --par-auto -o mandel mandel.c
```

The second form turns the program's loops into `par` blocks wherever their shape
allows, so the same unchanged C runs on every core and on the GPU. The source
needs no pragmas or annotations. See [par blocks](/versions/0.85/compiler/language/par/) for how
a block chooses its devices.

## What it needs

C is an add-on: `xcc` uses the C compiler and headers already on the machine and
ships none of its own. `clang` must be on the `PATH`:

| Platform | What to install |
|---|---|
| macOS | the Xcode Command Line Tools (`xcode-select --install`) |
| Linux | the distribution's `clang` package |
| Windows | LLVM for Windows (`clang` on the `PATH`) and Microsoft's C headers and libraries (the Visual Studio Build Tools or the Windows SDK), which that `clang` uses |

Without `clang`, building a `.c` file stops with
`a C file needs clang, which compiles it`. xc programs never need it.

A C program is built for the machine `xcc` runs on; `-A` does not cross-compile C.

## What xcc compiles

`clang` turns the C into LLVM IR, before any of LLVM's own optimisation, and
`xcc` reads each function of it into its own IR. From there the function takes the
same path as an xc one: `xcc`'s optimiser, its vectoriser (with SIMD copies picked
at load on x86-64), the outliner that makes `par` blocks, and its back end and
linker.

A function `xcc` cannot read yet is compiled by `clang` instead, and so are the
program's global variables; the two halves are linked into one executable. A
variadic function's definition is one of these, as is anything using an
intrinsic, an atomic or a construct the reader does not know. Set
`XC_C_TRACE=1` to list each function left to `clang` and why:

```bash
XC_C_TRACE=1 xcc -o prog prog.c
xcc: C path: left to clang: @log_line
xcc: C path:   because of a parameter of a type not read (in log_line: ...)
```

## Options

`-I <dir>` and `-D<name>[=<value>]` are passed to `clang`; the optimisation level
(`-O0` to `-O3`, `-O3` by default) and every code-generation option are `xcc`'s, as
for an xc program. `--par-auto` and the `par` environment variables (`XC_PAR`,
`XC_PAR_THREADS` and the rest) behave as they do for xc.

## Floating point

On arm64 `xcc` fuses a multiply into the add or subtract that uses it (one
rounding instead of two), as C allows and as `clang` does by default. A result can
therefore differ from the separately rounded one in its last bits; x86-64 rounds
each operation separately unless an FMA instruction is in use.

## Not yet

C++ is planned, through the same path: see [Future work](/compiler/future-work/).
