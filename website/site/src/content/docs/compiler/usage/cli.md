---
title: CLI flag reference
description: Every command-line option for xcc, grouped by purpose.
---

Every flag the `xcc` driver accepts, grouped by purpose. For the flat listing the
compiler itself prints, run `xcc -h`.

## The short version

```bash
xcc -o prog prog.xc
```

This is a complete invocation. With no `-A`, `xcc` builds a native executable for
the machine it is running on, finds the standard library relative to its own
binary, and optimises at `-O3`. A simple program needs nothing else.

```bash
xcc [options] <input.xc>
```

## One source file per invocation

`xcc` compiles one source file at a time. A second `.xc` on the command line is an
error:

```
xcc: error: multi-file inputs not supported on the new-IR path yet
```

To build a program from several source files, compile each one to an object with
`-c`, then link the objects in a separate invocation:

```bash
xcc -c -o main.o main.xc
xcc -c -o util.o util.xc
xcc -o prog main.o util.o
```

Objects (`.o`) and archives (`.a`) may be named together on the link line, but not
alongside a source file. `-c` is available on `arm64` (including `ios` and
`ios-sim`), `x86_64`, `win64` and `arm9`. On `6502`, `m68k` and `wasm32` a program
is compiled from one file; use `#include` to pull in the rest of its source.

## Inputs and outputs

| Flag | Effect |
|------|--------|
| `-o <path>` | Output file. On a native target this is a runnable executable unless the path ends in `.s` (assembly) or `.o` (object). On 6502 and m68k the extension picks the container (see below). The long form is `--output`. |
| `-c` | Compile and assemble to a relocatable object (`.o`), but do not link. |
| `-S` | Stop after code generation and write assembly to the `-o` path, as `cc -S` does. |
| `-E <path>`, `--preprocessed <path>` | Write the preprocessed source to `<path>` and continue. Shows what the lexer sees. |
| `-I <path>` | Add an include-search path. Repeatable. The long form is `--include`. |
| `-D <name>[=<value>]` | Define a preprocessor symbol. `-D DEBUG` is `#define DEBUG 1`; `-D LEVEL=3` defines it as `3`. The name may follow as a separate argument or be joined to the flag: `-D DEBUG` and `-DDEBUG` are the same. |
| `-q`, `--quiet` | Suppress informational output. Errors and warnings still print. |
| `-V`, `--verbose` | Print the resolved support root and every include path at startup. First stop when *Cannot find include file* fires. |
| `-v`, `--version` | Print the version and exit. |
| `-h`, `--help` | Print the full flag listing and exit. |

Output containers on the non-native targets:

| Extension | Format |
|---|---|
| `.asm` | assembly source (stops before the assembler) |
| `.xex` `.exe` `.bin` `.com` | banked 6502 executable (`.xex`) |
| `.tos` `.prg` | GEMDOS executable (m68k) |

## Target architecture

| Flag | Effect |
|------|--------|
| `-A <arch>` | Target architecture. With no `-A`, `xcc` builds for the machine it is running on. The long form is `--arch`. |

| `-A` | Target | Output |
|---|---|---|
| *(none)* | the host you are on | native executable |
| `arm64` | macOS / Linux on 64-bit ARM | Mach-O / ELF; run it |
| `ios` / `ios-sim` | iOS device / simulator (arm64) | Mach-O; sign with `xcc-sign`, install on device/simulator |
| `android` | Android (arm64) | with `--emit-apk`, a signed `.apk` |
| `x86_64` | Linux (musl) | ELF; run it |
| `win64` | Windows | PE/COFF `.exe` |
| `arm9` | AArch32 / **XTOS** | ELF, or a `.so` (see `--emit-lib`) |
| `m68k` | Motorola 68000 | GEMDOS `.prg`/`.tos`; run under `xcc-sim-68k`. `68000` is another spelling of `m68k`; `68030` targets the 68030. |
| `wasm32` | WebAssembly | `.wasm` / WAT |
| `6502` | banked **xt6502** | banked 6502 executable (`.xex`); run under `xcc-sim-6502 -m xt` |

`-A` and `-m` are orthogonal: `-A` picks the instruction set, `-m` picks the
memory layout within it. Only the 6502 path has layouts to choose.

## Native linking

These apply when `xcc` produces a native executable or library. By default it
assembles, links and (on macOS) signs **in-house**, with no system assembler,
linker or `clang`.

| Flag | Effect |
|------|--------|
| `-l<name>` | Link a system library, forwarded to the linker, for example `-lobjc`. |
| `-framework <F>` | Link a macOS framework, for example `-framework AppKit`. |
| `-Xlinker <file>` | Link a library or object file named by path. |
| `-Wl,<arg>[,<arg>…]` | The same, in the form clang users write. `xcc` links in-house: a file is linked, `-rpath <dir>` adds a run-path entry on arm64 and iOS, and any other linker flag is ignored with a note. `-Xlinker` takes the same arguments. |
| `--self-host` | In-house assemble + link + sign. This is the default; the flag is accepted but has no effect. |
| `--no-self-host` | Link through `clang` instead of in-house. |
| `-fpic`, `-fPIC`, `-mpic` | Position-independent code. Implied by `--emit-lib`; on arm9 it is what produces an `ET_DYN` `.so` rather than a fixed-load ELF. |

## Shared libraries

| Flag | Effect |
|------|--------|
| `--emit-lib` | Emit a **shared library** instead of an executable, together with a sibling `.xtc.iface` describing the classes, protocols, structs and enums it exports. Implies `-fpic`. |
| `-L <path>` | Add a search path for `#import <Lib>`, which resolves to `lib<Lib>.so` and reads its interface (or, for a C library, its DWARF). Repeatable. The long form is `--library-path`. |

```bash
xcc --emit-lib -o libXtg.so xtg.xc      # build the library
xcc -L . -o app app.xc                  # build a client against it
```

`#import <Lib>` type-checks the client against the **actual binary**, so there is no
header to fall out of sync. It also works on a plain **C** `.so`, whose DWARF
supplies its functions, types and enum constants. See
[Modules & shared libraries](/compiler/language/modules/).

## Support tree and memory model

| Flag | Effect |
|------|--------|
| `-H <path>` | Root holding the support tree. Rarely needed, because `xcc` finds it relative to its own binary. See [Install](/compiler/usage/install/). |
| `-m <layout>` | Select a memory layout. `-m xt` is the banked 6502 map and implies `-A 6502`. There is no default: with neither `-m` nor `-A`, `xcc` targets the host. The argument is a built-in layout name, or the path of a `.lnk` file (`.lnk` is appended if missing). The long form is `--memory-model`. See [Linker scripts](/compiler/usage/linker-scripts/). |
| `-ll`, `--list-layouts` | List every built-in layout, grouped by platform, and exit. |
| `-dl`, `--dump-layout` | Print the active layout's memory-map diagram and exit. Use with `-m`. |
| `-dp`, `--dump-placement` | Accepted, with a warning that it has no effect: the compiler does not report 6502 placement. |
| `-du`, `--dump-usage` | Accepted, with a warning that it has no effect: the compiler does not report 6502 segment usage. |

See [Memory models](/compiler/usage/memory-models/).

## Optimisation

| Flag | Effect |
|------|--------|
| `-O0` | No optimisation. A debug aid; the production level is `-O3`. |
| `-O1`, `-O` | Removes unreachable functions. |
| `-O2` | The full optimiser: inlining, constant folding, dead-code elimination, if-conversion, loop unrolling, vectorisation on `arm64`, `x86_64`, `win64`, `arm9` and `wasm32`, strength reduction, loop-invariant code motion and block layout. |
| `-O3` | **The default.** Currently the same pipeline as `-O2`. |
| `-Flu <n>`, `--fn-loop-unroll <n>` | Fully unroll counted loops whose constant trip count is at most `n`. The default depends on the target; see [Optimisation](/compiler/usage/optimization/#-flu--loop-unroll-cap). |
| `-Fli <n>`, `--fn-leaf-inline <n>` | Max leaf-function size (instructions) eligible for inlining. Default 100; needs `-O2+`. |
| `-Fmb <n>`, `--fn-min-banked <n>` | Accepted, with a warning that it has no effect: the 6502 back end banks every function except the entry point and interrupt handlers. |

Full discussion on [Optimisation](/compiler/usage/optimization/).

## Allocator, ARC and threads

| Flag | Effect |
|------|--------|
| `-falloc=bump` | Inline bump allocator. Fast `new`, no `delete`. |
| `-falloc=heap` | Coalescing free-list allocator; supports `delete`. Default on targets with a dedicated heap region: the `xt` layouts and the native hosts. |
| `-farc[=on\|off]` | Retired. ARC is always on. `xcc` accepts the flag and warns that it does nothing. |
| `-fthread-safe-arc` | Force atomic ARC refcounts, so two threads can share an object. |
| `-fno-thread-safe-arc` | Force plain, non-atomic refcounts. |

Atomic refcounts are decided **per module** and switch on when the module spawns a
thread. These flags override that choice. See
[Allocator & ARC](/compiler/usage/allocator-arc/) and
[Threading](/compiler/language/threading/).

## Floating point (arm9)

| Flag | Effect |
|------|--------|
| `-mhard-float`, `-mfpu` | Use VFP instructions for `float` and `double`. The default on boards that have it. |
| `-msoft-float` | Route floating point through the libgcc soft-float helpers instead. |

## Stack control

`-S` is not a stack flag; it keeps the assembly (see [Inputs and outputs](#inputs-and-outputs)).

| Flag | Effect |
|------|--------|
| `--xtc-stack` | Accepted, with a warning that it has no effect: the 6502 back end gives a function a software-stack frame only when its locals do not fit in zero page. |
| `-ss <n>`, `--stack-size <n>` | Cap the xcc stack at `n` bytes (decimal, `$hex` or `0xhex`; 1..65535). No effect on banked-heap or non-heap targets, which is all of the current ones. |

## Runtime behaviour

| Flag | Effect |
|------|--------|
| `-Q <rts\|loop>`, `--quit-style <rts\|loop>` | Accepted, with a warning that it has no effect: an xt6502 program stops at a `BRK` when `main` returns. |

## Diagnostics

| Flag | Effect |
|------|--------|
| `--emit-ir` | Dump the IR after lowering, to stderr. Does not change the generated code. |
| `--emit-ir-opt` | Dump the IR after the optimiser, to stderr. |

## More build flags

| Flag | Effect |
|------|--------|
| `-flto` | Link-time optimisation: recompile the whole program from its IR as one module. |
| `-fbounds-check` | Build with subscript bounds checking; see [Checked builds](#checked-builds). arm64 only so far. |
| `--sign <identity.pem>` | Sign the output with a developer identity (iOS/macOS); pair with `--sign-entitlements <plist>`. See also the standalone `xcc-sign`. |
| `--emit-apk` | On `-A android`, package a signed `.apk`. `--sign-key <path>` names the signing key. See the packaging options below. |
| `--emit-iface` | Write the module interface (the `.xtc.iface` description) to the `-o` path, or to standard output with no `-o`, and stop. `-c` and `--emit-lib` produce the interface as part of their output without this flag. |
| `-fmalloc=system\|mimalloc` | Choose the native heap backend. |
| `--with-dex <path>` | With `--emit-apk`, carry this `classes.dex` in the package and mark the manifest `hasCode="true"`. |
| `--with-lib <path>` | With `--emit-apk`, store an extra prebuilt `.so` in `lib/arm64-v8a/`. |
| `--lib-name <name>` | With `--emit-apk`, the manifest's `android.app.lib_name`: which packaged library the system loads. Default: the program itself. |
| `--needed <soname>` | On `-A android`, add a `DT_NEEDED` entry naming `<soname>`. Repeatable. A library that calls into a companion `.so` must name it. |

`xcc --help` prints the complete flag list.

## Checked builds

`-fbounds-check` compiles a program that range-checks its subscripts. It is a
debug-time build: the checks cost code and time, and they are not meant to be
left on in what you ship.

What each kind of subscript is checked against:

| The base | Checked against |
|----------|-----------------|
| an array with a declared length (`u16 a[8]`), local or global | that length |
| an array sized by its own initialiser (`u16 a[] = { 1, 2, 3 }`) | the inferred length |
| a heap allocation (`new T[n]`) | the count in its own allocation header |
| a bare pointer | the allocation header, so the check means something only if the pointer really points at one |

A failing check prints the site, the real bound, and a symbolised stack, then
aborts:

```
=== xcc: out-of-bounds access ===
  at grid.xc:9:8
  array: index 9, but it holds 5 elements
  stack:
    #0  _xt_check_bounds_n +176
    #1  main +88
    #2  xtc_start +16
```

The flag is implemented for arm64 so far. On a target that does not have it
`xcc` stops with an error rather than quietly building an unchecked program.

## Warnings

Suppress a category with `-Wno-<category>`. All are on by default.

| Category | Triggered by |
|----------|--------------|
| `asm-clobbers` | an `asm{}` block's `clobbers` annotation disagrees with the registers the compiler thinks it touched |
| `class-init` | a bad initialiser on a stack-allocated class |
| `escape` | a stack address stored into a longer-lived slot (global, heap field, outer scope), which is likely to dangle |
| `printf-format` | a `printf`-family format string that disagrees with its arguments (`%d` is 16-bit, `%ld` is 32-bit) |
| `unguarded-action` | an action used before it was tested since assignment |
| `packed-align` | a `packed` struct field whose access may be misaligned on the target |
| `unknown-annotation` | an unrecognised function annotation, e.g. `:foo` |
| `unknown-pragma` | an unrecognised `#` directive |
| `toolchain-fallback` | the build fell back from the in-house assembler/linker to an external tool |

`xcc --help` prints the full category list, including any checks added after this
page.

### Static analysis

`-Wanalyze` turns on a further set of checks that are off by default:

- a condition that is always true or always false
- a value that is overwritten before anything reads it
- a local that is never used (prefix its name with `_` to say that is intended)
- code that can never run

## Library versioning

| Flag | Effect |
|------|--------|
| `--migrate=<base>:<to>` | Compile as if the standard library were still `<base>`: methods annotated `since("V")` with `V` newer than `<base>` are removed from lookup, so a call whose **meaning changed** between the versions is an error instead of resolving to the new method. Use it when a library you depend on has renamed or repurposed a method between its versions. |

## Environment

| Variable | Effect |
|---|---|
| `XCC_HOME` | Override the support-tree search. `-H` beats it. |
| `XTC_HOME` | The older spelling of `XCC_HOME`, still read. |
| `XTC_LDFLAGS` | Extra arguments appended to the native link. |

## Combined examples

```bash
# Native build for this machine
xcc -o app app.xc

# Cross-compile the same source three ways
xcc -A win64 -o app.exe app.xc
xcc -A m68k  -o app.tos app.xc
xcc -A 6502  -o app.xex app.xc

# Link against a system library and a framework (macOS)
xcc -o app app.xc -lobjc -framework AppKit

# Build a shared library, then a client against it
xcc --emit-lib -o libgfx.so gfx.xc
xcc -L . -o app app.xc

# Inspect the generated assembly rather than linking
xcc -o app.s app.xc

# Build from two source files: compile each, then link
xcc -c -o main.o main.xc
xcc -c -o util.o util.xc
xcc -o app main.o util.o

# Debug build, one symbol defined, one warning silenced
xcc -O0 -D DEBUG -Wno-escape -o app app.xc

# The 6502 memory map, and where functions ended up
xcc -dl -m xt
xcc -A 6502 -dp -o app.xex app.xc
```
