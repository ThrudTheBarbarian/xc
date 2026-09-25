---
title: Compiler usage
description: How to drive the xcc toolchain with CLI flags, optimisation, memory models, allocator selection and linker scripts.
---

This section covers **driving** the xcc toolchain: picking flags, choosing memory models, tuning the optimiser, configuring the allocator, and writing your own linker script when needed. It deals with what affects the **binary** rather than the **source**. Language details (syntax, types, classes) are in the [Language reference](/compiler/language/), and standard-library APIs are under [Standard library](/compiler/api/).

## A typical invocation

```bash
xcc -o game game.xc
```

This is a complete native build. With no `-A` the target is this machine, the
standard library is found relative to the `xcc` binary, and the optimiser runs
at `-O3`. Cross-compiling adds one flag:

```bash
xcc -A 6502 -o game.xex game.xc
```

A successful build prints nothing on most targets. Errors and warnings go to the terminal with the source line and a caret under the position. A `wasm32` build prints one line naming the module and its loader; `-q` silences it.

`xcc` compiles one source file per invocation. A program split across several files is built with `-c` and a separate link step; see [CLI → One source file per invocation](/compiler/usage/cli/#one-source-file-per-invocation).

## What's where

- **[Install](/compiler/usage/install/)**: where `make install` puts things, and how `xcc` locates its own libraries. Read this first.
- **[CLI flag reference](/compiler/usage/cli/)**: every command-line option, grouped by purpose, and which ones need `xcc-bootstrap`. Start here to look up a specific flag.
- **[Optimisation](/compiler/usage/optimization/)**: what each `-O` level does, the `-Flu` unroll cap, and which targets vectorise.
- **[Memory models](/compiler/usage/memory-models/)**: the `xt6502` map, with two bank windows, the 4 KB hardware stack, and the on-demand banked heap. 6502 only; the native targets have no layout to choose.
- **[Allocator & ARC](/compiler/usage/allocator-arc/)**: `-falloc=bump` vs `-falloc=heap`, and how automatic reference counting works with each.
- **[Linker scripts (.lnk)](/compiler/usage/linker-scripts/)**: the file format that defines a memory model. Customise an existing layout or write a new one for non-standard hardware.

## What's not in this section

- **Function annotations** (`:banked`, `:main`, `:shadow`, `:irq`, `:vbi`, `:naked`, `:hwStack`, `:xtcStack`, `:needsOS`) are language-level placement and calling-convention markers. They are on the [Functions](/compiler/language/functions/#function-annotations) page.
- **Memory-model implementation details** (bank-switching mechanics, the `_xcall` trampoline, ZP byte allocation) are documented in the language pages where they affect semantics: [Functions](/compiler/language/functions/), [Heap, ARC & weak refs](/compiler/language/memory/), [Inline assembly](/compiler/language/inline-asm/).
- **Standard-library APIs** such as `Heap.size()` and `Vbi.addDeferred()` are under [Standard library](/compiler/api/).

## Output format selection

On a **native** target (`arm64`, `x86_64`, `win64`, `arm9`) the output is a runnable executable unless `-o` ends in `.s` (assembly) or `.o` (object). `--emit-lib` produces a shared library instead. `xcc` carries its own assembler and linker, so no system tools are involved.

On **6502** and **m68k** the `-o` extension picks the container, or the `[output]` section of the active `.lnk` file does:

| Extension | Format |
|-----------|--------|
| `.asm` | assembly source (stops before the assembler) |
| `.xex`, `.exe`, `.bin`, `.com` | banked 6502 executable (`.xex`) |
| `.tos`, `.prg` | GEMDOS executable (m68k) |

A **wasm32** build emits a `.wasm` module, or WAT text when `-o` ends in `.wat`.

Asking for `.asm` or `.s` stops the pipeline after code generation, which lets you inspect what the compiler produced.

## Support file search order

`xcc` locates its support tree (standard library, linker scripts, runtime asm) by probing each of these roots for `lib/xc`, then `xc`, then `support`:

```
-H <path> > the directory holding xcc, and its parent
          > cwd > /opt/xcc/<version> > /opt/xcc
          > /usr/local/xcc > /usr/local/xtc > /opt/xtc
```

`xcc-bootstrap` also reads `$XCC_HOME` and `$XTC_HOME` after `-H`, and `~/xcc` and `~/xtc` after the working directory.

The binary-relative step makes an install self-locating, so in normal use you set nothing. `-H` points a specific compiler at a specific tree, most often when running one from a source checkout. `-V` prints the include paths under the root that was chosen. Details are on [Install](/compiler/usage/install/).
