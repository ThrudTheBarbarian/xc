---
title: C++ programs
description: Building a C++ program with xcc, what it needs installed, which parts xcc compiles itself, and how its loops become par blocks.
---

`xcc` builds a C++ program the way it builds a C or xc one:

```bash
xcc -o mandel mandel.cpp
```

The program's loops become `par` blocks wherever their iterations are
independent, so the same unchanged C++ runs on every core and on the GPU: a
`for` over a `std::vector`, a range-`for`, an iterator loop over a vector of
structs, `std::transform`, `std::accumulate`, `std::for_each` and the other
algorithms clang inlines into a loop. The source needs no pragmas, no
`std::execution` policy and no annotations. `--par-style=cpu` builds it as
written, on one thread. See [par blocks](/compiler/language/par/) for how a
block chooses its devices.

## What it needs

As for C, `xcc` uses the compiler and the C++ standard library already on the
machine and ships none of its own. `clang++` and `clang` must be on the `PATH`:

| Platform | What to install |
|---|---|
| macOS | the Xcode Command Line Tools (`xcode-select --install`): `clang++` and libc++ |
| Linux | the distribution's `clang` package and its libstdc++ (the `g++` package brings its headers) |

Without them, building a `.cpp` file stops with
`a c++ file needs clang++ and clang, which compile it`. xc programs never need
either.

A C++ program is built for the machine `xcc` runs on by default. From another
host, `-A x86_64` and `-A arm64-linux` build it for Linux given a copy of that
target's `usr/include` (with libstdc++'s `c++/<version>` headers) and of its
`libstdc++.so.6` and `libgcc_s.so.1` (under `usr/lib/<triple>`):
`XTC_X86_64_LINUX_ROOT` (by default `/opt/clang/linux/x86_64-linux-gnu`) and
`XTC_ARM64_LINUX_ROOT` (by default `/opt/clang/linux/aarch64-linux-gnu`).
`-A win64` builds it with the llvm-mingw root (`/opt/clang/win64`), whose
libc++, libc++abi and libunwind it links.

## What xcc compiles

`clang++` turns the C++ into LLVM IR and runs its own inliner over it, so that
the standard library's small functions (a `std::vector`'s `size()` and
`operator[]`, an iterator's `++`, the body of `std::transform`) are inside the
loops that call them. `xcc` then reads each function with a loop into its own
IR, and from there the function takes the same path as an xc one: `xcc`'s
optimiser, its vectoriser, the outliner that makes `par` blocks, and its back
end and linker.

A function an exception may pass through (one that allocates, such as `main`
with its vectors) is compiled by `clang++`, but its loops are not: each loop
whose own body cannot throw is moved into a function of its own, which `xcc`
reads and lifts like any other. The rest of the program, the global variables,
the exception tables and the standard library's own code are `clang++`'s, and
the two halves are linked into one executable by `xcc`'s linker: exceptions,
RTTI, virtual calls and the constructors of global objects work as they do in
a program `clang++` links. Set `XC_C_TRACE=1` to list each function with a loop
left to `clang++` and why.

## Options

`-I <dir>`, `-D<name>[=<value>]` and `-std=<standard>` (such as `-std=c++17`
or `-std=c++20`) are passed to `clang++`; the optimisation level (`-O0` to
`-O3`, `-O3` by default) and every code-generation option are `xcc`'s.
`--par-style=auto` and the `par` environment variables (`XC_PAR`,
`XC_PAR_THREADS` and the rest) behave as they do for xc and C.

## Floating point

As for [C](/compiler/usage/c-programs/#floating-point): `xcc` fuses a multiply
into the add or subtract that uses it within an expression, as `clang++` does
by default, and nothing under `-fgoal=accuracy`.
