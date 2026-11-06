---
title: xcc
description: xcc compiles xc and C into programs that run their loops across every CPU core and on GPUs through Metal, CUDA, Vulkan and WebGPU, on several devices at once or on a GPU elsewhere on the network, from one source and with no GPU toolkit.
---

**xcc** is the compiler for **xc**, a data-parallel language for machines with many cores and
one or more GPUs. A loop whose iterations are independent becomes a
[`par` block](/compiler/language/par/), and the same block runs across every CPU thread with
the vector units, on a GPU, on several GPUs from different vendors at once, or on a GPU on
another machine. The program measures the devices it finds and keeps the fastest choice.
xcc does this for C too: it compiles `.c` files, and their loops get the same treatment.

xc itself is a statically-typed language close to C, with classes, protocols, automatic
reference counting and closures. The compiler is self-hosting, and it behaves like a C
compiler:

```bash
xcc -o brighten brighten.xc     # a native binary for this machine, GPU kernels included
xcc -o saxpy saxpy.c            # the same for a C file
xcc -A win64 -o app.exe app.xc  # cross-compile, here for Windows
```

A program needs nothing more. No flag selects the host or the GPU, no environment variable
points at libraries or SDKs, and the standard library and the parallel runtime are linked
automatically. How it works is in [Architecture](/compiler/architecture/), and how fast it is
in [Benchmarks](/compiler/benchmarks/).

## Targets

With no `-A`, `xcc` builds for the machine it is running on. Pass `-A` to cross-compile.

| `-A` | Target | Output | Run with |
|---|---|---|---|
| *(none)* | the host you are on | native executable | run it |
| `arm64` | macOS / Linux on 64-bit ARM, including the Raspberry Pi 5 | Mach-O / ELF | run it |
| `x86_64` | Linux | a glibc ELF that loads system libraries; with `-static`, a static ELF over musl | run it |
| `win64` | Windows | PE/COFF `.exe`, or a DLL (`--emit-lib`) | run it, or Wine |
| `wasm32` | WebAssembly | `.wasm` / WAT | a browser or a WASM runtime |

Every executable carries its `par` blocks' GPU kernels, which xcc generates itself:

| GPU API | Where | Kernel form |
|---|---|---|
| Metal | Apple silicon | Metal Shading Language |
| CUDA | NVIDIA GPUs, Windows and Linux | PTX |
| Vulkan | Linux, Windows, Android, the Raspberry Pi 5 | SPIR-V |
| WebGPU | a browser | WGSL |

The native targets assemble and link **in-house**: `xcc` carries its own assemblers, linkers
and Mach-O / ELF / PE writers, so a build needs no system toolchain.

### Smaller machines

The same language and standard library reach down to machines without a GPU or an
operating system to speak of. Every target passes the full fixture corpus.

| `-A` | Target | Output | Run with |
|---|---|---|---|
| `arm9` | AArch32, the **XTOS** loader | ELF, or a shared library (`--emit-lib`) | the board, or QEMU |
| `m68k` (`68000`) / `68030` | Motorola 68000/68030 | GEMDOS `.prg`/`.tos` | `xcc-sim-68k` |
| `6502` | banked **xt6502**, a custom FPGA 6502 with a 4 KB hidden hardware stack and SP-relative addressing | banked 6502 executable (`.xex`) | `xcc-sim-6502` |

On a machine with bank-switched RAM, banking is a first-class resource: programs spread code
and data across paged windows and grow beyond normal RAM limits, and the compiler decides what
lives where. The 6502 path has two more pieces: **`xcc-as`**, a two-pass assembler that emits
XEX with RUNAD/INITAD and banked preload, and **`xcc-sim-6502`**, a headless simulator that
runs `.xex` files with the memory-model semantics the code generator targets. The `m68k` path
has its own simulator, **`xcc-sim-68k`**.

## What the language gives you

- **Classes** with single inheritance from a root `Object`, virtual dispatch, and
  `init` / `dealloc` that chain automatically up the hierarchy, including for a subclass
  that declares neither.
- **Protocols**, including **optional methods**. An unimplemented optional method leaves a
  null slot, so `&delegate.method` doubles as `respondsTo`. This supports the delegate
  pattern.
- **Bound methods** (`callback`). `&obj.method` yields a `{receiver, code}` value you can
  store and call later. A plain function *widens* into the same type, so one `action` field
  accepts either. This gives target/action with no protocol and no context pointer. See
  [Bound methods & callbacks](/compiler/language/bound-methods/).
- **ARC**, with `weak:` references that auto-zero when their referent dies. A stored
  callback never owns its receiver, which keeps a view hierarchy from becoming one large
  retain cycle.
- **Typed collections**: `Array<String>*`, `Map<Point>*`, `Set<String>*`. The element type
  is checked at compile time and erased at run time, so an instantiation adds no code size.
  See [Collections & strings](/compiler/language/collections/).
- **Threading** on the native targets: `Thread`, `Mutex`, `Cond`, `Sem`, `Atomic` and
  `Pool.forRange`. ARC refcounts become atomic automatically in any module that spawns a
  thread. See [Threading](/compiler/language/threading/).
- **Errors as a checked effect.** A function that can fail is marked `throws`, and a caller
  must handle the error or be `throws` itself. See [Errors](/compiler/language/errors/).
- **Shared libraries.** `--emit-lib` produces a library carrying its own interface, and
  `#import <Lib>` type-checks a client against the real binary. Classes, protocols (with
  working cross-module dispatch), structs, enums, `weak:` fields, bound methods and C types
  re-exported from *other* libraries all cross the boundary. See
  [Modules & shared libraries](/compiler/language/modules/).
- **Fixed-width types**: `i8`…`u64`, `float`, `double`, `bool`, `pointer`. There is no
  C-style promotion to `int`, so same-width arithmetic stays at that width.
- **Inline assembly** on every target, with byte-extract operators and `clobbers`.

## These pages

- **[Install](/compiler/usage/install/)**: where the toolchain goes and how it finds its
  own libraries. Start here.
- **[Language reference](/compiler/language/)**: syntax, types, classes, protocols, ARC,
  collections, threading, modules, inline assembly. Each page carries a worked example that
  compiles and runs.
- **[Standard library](/compiler/api/)**: the classes shipped with the compiler, with
  method signatures and example usage.
- **[Compiler usage](/compiler/usage/)**: CLI flags, optimisation levels, allocator and
  memory-model selection, banking, and linker scripts.
- **[Future work](/compiler/future-work/)**: what's next, and what's known to be incomplete.

Prebuilt binaries for macOS, Linux and Windows are on the [Downloads](/compiler/downloads/) page.
