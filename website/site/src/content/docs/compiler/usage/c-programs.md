---
title: C programs
description: Building a C program with xcc, what it needs installed, which parts xcc compiles itself, and how its loops become par blocks.
---

`xcc` builds a C program the way it builds an xc one:

```bash
xcc -o mandel mandel.c
```

The program's loops become `par` blocks wherever their iterations are
independent, so the same unchanged C runs on every core and on the GPU. The
source needs no pragmas or annotations. `--par-style=cpu` builds it as written,
on one thread. See [par blocks](/compiler/language/par/) for how a block chooses
its devices.

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

A C program is built for the machine `xcc` runs on by default. `-A x86_64`,
`-A win64` and `-A arm64-linux` cross-compile it, given that target's C headers:
musl's for x86-64 Linux (`XTC_MUSL_ROOT`), mingw's for win64, and glibc's for arm64
Linux (`XTC_ARM64_LINUX_ROOT`, a copy of an arm64 Linux machine's `usr/include`).
Without them `xcc` says which headers it needs. Other targets do not build C.

## What xcc compiles

`clang` turns the C into LLVM IR, before any of LLVM's own optimisation, and
`xcc` reads each function of it into its own IR. From there the function takes the
same path as an xc one: `xcc`'s optimiser, its vectoriser (with SIMD copies picked
at load on x86-64), the outliner that makes `par` blocks, and its back end and
linker.

A function `xcc` cannot read yet is compiled by `clang` instead, and so are the
program's global variables; the two halves are linked into one executable.
A global array of a numeric type, 64 KB or more, gets pages of its own in
clang's half, so a `par` block on a unified-memory GPU uses it in place (see
[global arrays](/compiler/language/par/#arrays-the-gpu-shares-simd-pointers)). A
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
for an xc program. `--par-style=auto` and the `par` environment variables (`XC_PAR`,
`XC_PAR_THREADS` and the rest) behave as they do for xc.

## Floating point

`xcc` fuses a multiply into the add or subtract that uses it within an
expression (one rounding instead of two), as C allows and as `clang` does by
default (`-ffp-contract=on`), on every target. A result can therefore differ
from the separately rounded one in its last bits. On x86-64 the fused
instruction needs FMA, so it is in the code built for a CPU that has it: the
whole program under `-mavx2` or `-msimd=avx512`, and under the default
`-msimd=auto` the AVX2 and AVX-512 copies of a function that the program picks
at load; the baseline copy rounds each operation on its own.

`-ffp-contract=fast` also fuses across statements, as GCC does by default, and
`-ffp-contract=off` fuses nothing. Under `-fgoal=accuracy` nothing is fused on
any target, whatever `-ffp-contract` says: each operation is rounded on its
own, as ISO C describes.

## Not yet

C++ is planned, through the same path: see [Future work](/compiler/future-work/).
