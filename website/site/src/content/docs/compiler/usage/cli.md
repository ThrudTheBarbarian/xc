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
xcc [options] <input.xc> [<input2.xc> …]
```

## Inputs and outputs

| Flag | Effect |
|------|--------|
| `-o <path>`, `--output <path>` | Output file. On a native target this is a runnable executable unless the path ends in `.s` (assembly) or `.o` (object). On 6502 and m68k the extension picks the container (see below). |
| `-c` | Compile and assemble to a relocatable object (`.o`), but do not link. |
| `-a`, `--assemble-only` | Stop after producing assembly; don't assemble or link. |
| `-E <path>`, `--preprocessed <path>` | Write the preprocessed source to `<path>` and continue. Shows what the lexer sees. |
| `-I <path>`, `--include <path>` | Add an include-search path. Repeatable. |
| `-D <name>[=<value>]` | Define a preprocessor symbol. `-DDEBUG` is `#define DEBUG 1`; `-DLEVEL=3` defines it as `3`. |
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
| `-A <arch>`, `--arch <arch>` | Target architecture. With no `-A`, `xcc` builds for the machine it is running on. |

| `-A` | Target | Output |
|---|---|---|
| *(none)* | the host you are on | native executable |
| `arm64` | macOS / Linux on 64-bit ARM | Mach-O / ELF; run it |
| `ios` / `ios-sim` | iOS device / simulator (arm64) | Mach-O; sign with `xcc-sign`, install on device/simulator |
| `android` | Android (arm64) | with `--emit-apk`, a signed `.apk` |
| `x86_64` | Linux (musl) | ELF; run it |
| `win64` | Windows | PE/COFF `.exe` |
| `arm9` | AArch32 / **XTOS** | ELF, or a `.so` (see `--emit-lib`) |
| `m68k` (`68000`) / `68030` | Motorola 68000/68030 | GEMDOS `.prg`/`.tos`; run under `xcc-sim-68k` |
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
| `-Xlinker <arg>`, `-Wl,<arg>` | Pass an argument to the linker. `$XTC_LDFLAGS` is also appended. |
| `--self-host` | In-house assemble + link + sign. This is the default; the flag is accepted but has no effect. |
| `--no-self-host` | Use the `clang` link path instead. |
| `-fpic`, `-fPIC`, `-mpic` | Position-independent code. Implied by `--emit-lib`; on arm9 it is what produces an `ET_DYN` `.so` rather than a fixed-load ELF. |

## Shared libraries

| Flag | Effect |
|------|--------|
| `--emit-lib` | Emit a **shared library** instead of an executable, together with a sibling `.xtc.iface` describing the classes, protocols, structs and enums it exports. Implies `-fpic`. |
| `-L <path>`, `--library-path <path>` | Add a search path for `#import <Lib>`, which resolves to `lib<Lib>.so` and reads its interface (or, for a C library, its DWARF). Repeatable. |

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
| `-H <path>`, `--xcc-home <path>` | Root holding the support tree. Rarely needed, because `xcc` finds it relative to its own binary. See [Install](/compiler/usage/install/). |
| `-m <layout>`, `--memory-model <layout>` | Load a memory layout (`.lnk`). Searches `<layout>` as a path (appending `.lnk`), then the built-in layout directories. `-m xt` is the banked 6502 map and implies `-A 6502`. There is no default: with neither `-m` nor `-A`, `xcc` targets the host. |
| `-ll`, `--list-layouts` | List every built-in layout, grouped by platform, and exit. |
| `-dl`, `--dump-layout` | Print the active layout's memory-map diagram and exit. Use with `-m`. |
| `-dp`, `--dump-placement` | After codegen, print every function's final placement (main / banked page N / irq / vbi) with per-bank byte usage. |
| `-du`, `--dump-usage` | After codegen, print a per-segment usage summary for every region and bank in the layout. |

See [Memory models](/compiler/usage/memory-models/).

## Optimisation

| Flag | Effect |
|------|--------|
| `-O0` | No optimisation. A debug aid; the production level is `-O3`. |
| `-O`, `-O1` | Peephole + register tracking. |
| `-O2` | Adds const propagation, dead code / dead store elimination, tail-call optimisation, leaf-function inlining, loop unrolling for small trip counts. |
| `-O3` | **The default.** Adds branch inversion and threading, strength reduction, cross-function dead-code elimination, label cleanup, and on arm64 the NEON auto-vectoriser. |
| `-Fli <n>`, `--fn-leaf-inline <n>` | Max leaf-function size (instructions) eligible for inlining. Default 100; needs `-O2+`. |
| `-Flu <n>`, `--fn-loop-unroll <n>` | Auto-unroll counted `for` loops with trip count ≤ `n`. Default 5 at `-O2+`, 0 below. |
| `-Fmb <n>`, `--fn-min-banked <n>` | Minimum function size (6502 instructions) to be banked. Smaller functions stay in main RAM so their call sites skip the `_xcall` trampoline. Default 0 (off). |

Full discussion on [Optimisation](/compiler/usage/optimization/).

## Allocator, ARC and threads

| Flag | Effect |
|------|--------|
| `-falloc=bump` | Inline bump allocator. Fast `new`, no `delete`. |
| `-falloc=heap` | Coalescing free-list allocator; supports `delete`. Default on targets with a dedicated heap region: the `xt` layouts and the native hosts. |
| `-farc[=on\|off]` | Automatic reference counting. `on` (default) emits retains and releases and rejects manual `retain` / `release`; `off` disables auto-emit and accepts manual lifecycle. |
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

| Flag | Effect |
|------|--------|
| `-S`, `--xtc-stack` | Use the xcc software stack globally for return addresses and saved registers. |
| `-ss <n>`, `--stack-size <n>` | Cap the xcc stack at `n` bytes (decimal, `$hex` or `0xhex`; 1..65535). No effect on banked-heap or non-heap targets, which is all of the current ones. |

## Runtime behaviour

| Flag | Effect |
|------|--------|
| `-Q rts`, `--quit-style rts` | When `main` returns, `RTS` to the caller (DOS). Default. |
| `-Q loop`, `--quit-style loop` | When `main` returns, spin. For "the program owns the machine" builds where the caller does not expect control back. |

## Diagnostics

| Flag | Effect |
|------|--------|
| `--emit-ir` | Dump the IR after lowering, to stderr. Does not change the generated code. |
| `--emit-ir-opt` | Dump the IR after the optimiser, to stderr. |

## More build flags

| Flag | Effect |
|------|--------|
| `-flto` | Link-time optimisation: recompile the whole program from its IR as one module. |
| `-fbounds-check` | Insert array/heap bounds checks (native targets). |
| `--sign <identity.pem>` | Sign the output with a developer identity (iOS/macOS); pair with `--sign-entitlements <plist>`. See also the standalone `xcc-sign`. |
| `--emit-apk` | On `-A android`, package a signed `.apk` (with `--with-dex`, `--with-lib`, `--lib-name`, `--needed`). |
| `--emit-iface` | Emit the `.xtc.iface` module interface alongside the object. |
| `-fmalloc=system\|mimalloc` | Choose the native heap backend. |

`xcc --help` prints the complete flag list.

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

## Library versioning

| Flag | Effect |
|------|--------|
| `--migrate=<base>:<to>` | Compile as if the standard library were still `<base>`: methods annotated `since("V")` with `V` newer than `<base>` are removed from lookup, so a call whose **meaning changed** between the versions is an error instead of resolving to the new method. Use it when a library you depend on has renamed or repurposed a method between its versions. |

## Environment

| Variable | Effect |
|---|---|
| `XCC_HOME` | Override the support-tree search. `-H` beats it. |
| `XTC_HOME` | The older spelling, also read. |
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
xcc -a -o app.s app.xc

# See the 6502 memory map, and where functions ended up
xcc -dl -m xt
xcc -A 6502 -dp -o app.xex app.xc

# Manual lifecycle, debug build, one warning silenced
xcc -farc=off -O0 -DDEBUG -Wno-escape -o app app.xc
```
