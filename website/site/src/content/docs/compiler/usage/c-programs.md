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

A loop that updates a global array through an index read from data, such as a
histogram, becomes a block too:

```c
for (unsigned i = 0; i < n; i++)
    hist[key[i]] += 1;
```

The update must be `+=`, `|=`, `&=` or `^=` on an integer element, the array a
global of fixed size, and the loop must touch it in no other way. Each thread
updates a private copy of the array, and the copies are combined into it when the
block ends, so the result is the serial loop's. Such a block runs on the CPU's
threads; it has no GPU version yet.

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

## Heap arrays

A loop over two pointers runs as a block only when the runtime can tell the
arrays apart. On x86-64 Linux (glibc, the default dynamic link) and on macOS,
the program's own `malloc`, `calloc`, `realloc`, `aligned_alloc` and
`posix_memalign` calls of 64 KB and more get a block from `xcc`'s runtime, which
records where it starts and how long it is. Smaller requests go to the C
library, and a block of the C library's stays one when `realloc` grows it. A
loop runs as a block when its arrays are such blocks, each passed from its
start; a pointer into the middle of a block, a smaller block, or memory a
library allocated is unknown, and the loop runs serially, with the same answer.

The blocks work with every C library: a library may realloc or free one, and the
program may free memory a library allocated. On Linux the executable exports
`free`, `realloc` and `malloc_usable_size` for this; on macOS the blocks come
from a malloc zone of their own, so `malloc_size` answers for them. A program
that defines its own `malloc` keeps it. C++ `new` and `new[]` work the same way:
the program's `operator new` and `operator delete` calls are the runtime's for
64 KB and more (the aligned forms stay the C++ library's). A `-static` Linux
program and the other targets use the C library for every block.

## Options

`-I <dir>`, `-D<name>[=<value>]` and `-std=<standard>` (such as `-std=c99`,
`-std=c11` or `-std=c17`; without it, `clang`'s own default) are passed to
`clang`, which also reports a standard it does not know; the optimisation level
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

## 16-bit floats

`_Float16` and `__bf16` are xc's [`f16` and `bf16`](/compiler/language/types/#f16-and-bf16),
and `xcc` compiles the functions that use them. Each operation is worked in
`float` and rounded to the type once, the result ISO C gives for `_Float16` under
`FLT_EVAL_METHOD` 0. Where `clang` itself evaluates a `_Float16` expression in
`float` and rounds once at the end (on x86-64, where it keeps that excess
precision), its IR says so and `xcc` follows it, so the program prints what the
`clang`-built one does. A multiply-add `clang` marks for fusing rounds once, as a
fused instruction does. A function taking or returning either type passes it as
C does, so it calls and is called by the functions `clang` compiles. A loop over
`_Float16` arrays becomes a `par` block that runs on the CPU's threads. A vector
of either type leaves its function to `clang`.

## C++

C++ takes the same path: see [C++ programs](/compiler/usage/cpp-programs/).
