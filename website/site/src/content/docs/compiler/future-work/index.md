---
title: Future work
description: What's planned, in progress, and known to be incomplete in xcc.
---

xcc is pre-1.0. This page lists where it is going and what is known to be incomplete.
What has shipped is in the [ChangeLog](/compiler/downloads/changelog/).

## Where things stand

The compiler lowers to a single architecture-neutral IR and out through **seven live
backends**: xt6502, arm64 (macOS, iOS and Android), arm9, m68k, x86_64 (Linux: glibc, or
static musl with `-static`), win64 and **wasm32**. Every one passes the full fixture
corpus, and every one is built end to end by the **in-house toolchain**: xcc's own
assemblers, linkers and executable-format writers, with no external compiler in the
chain. A macOS machine with only xcc installed cross-builds native binaries for Linux,
Windows, the phones and the browser.

The whole compiler also exists a **second time, written in xcc**, and that is the
compiler you download. Forty differential harnesses hold every stage of it
byte-identical to the original, and they run on every commit.

`par` blocks run on the CPU's cores and on GPUs through Metal, CUDA, Vulkan and WebGPU,
across several cards at once and across machines. `auto` measures the choices for each
block and keeps the fastest.

## Planned

### A visualiser for `par` work

A live 3D view of where a program's work goes, on one machine or across the network:

- **Worker nodes in 3D space**, placed at first by a force-directed layout. You can move
  them and save the layout. The view rotates, pans and zooms, with buttons to bring it
  home if you get lost.
- **Connections that show their use.** A link grows and brightens as work crosses it and
  shrinks and dims when idle. Packets travel at a speed relative to the link's
  bandwidth; a local GPU is drawn as a continuous line.
- **Each node as semi-transparent cubes** in a cube layout, one cube per block of GPU
  units (CUDA cores or their equivalent; 100, 250, 500 or 1000 a cube, whatever reads
  best). A cube's colour says which user or application holds those units, and its fill
  level how many of them are busy.
- **"VCR" controls**: stop at a moment and zoom in, single-step, play at different
  speeds, and snap back to the live view.
- **Filters** to show one user or application, or the whole picture.
- **Telemetry over a WebSocket** from the host application, so the viewer can be a
  native program or a WebAssembly one in a browser. The number of particles will call
  for instanced drawing.
- **Attaching in time.** A viewer has to be connected before a program's work starts to
  see it. One answer is a telemetry daemon, `xctd`, running in the background as a
  repository: it finds the programs and the `xcd` daemons over mDNS and keeps what they
  report, so a viewer can attach at any time.

### A tensor library in xc

An equivalent of PyTorch, written in xc: tensors, their operations and automatic
differentiation, with the work spread across every GPU and CPU available, on one
machine or several, the way a `par` block's tiles are today.

### A C++ front end

`xcc` compiling C++ files directly, through the path [C programs](/compiler/usage/c-programs/)
take: `clang` turns the source into LLVM IR, `xcc` compiles what it reads of it, and
`--par-auto` finds its loops in the IR as it finds C's.

### A generic LLVM back end

An option for `xcc` to hand its optimised IR to LLVM as LLVM IR, so a program can be
built for any processor LLVM supports, RISC-V and POWER among them, not only the ones
`xcc` has its own back ends for. `xcc`'s own back ends stay the default where they
exist: that is where its vector code, SIMD dispatch and `par` runtimes are tuned.

### `par` on FPGAs, through `xcd`

A `par` block run on an FPGA as well as on GPUs and CPUs: its body compiled to logic by
high-level synthesis, and the board served by an `xcd` worker like a remote GPU, so its
tiles join the same queue as every other device's. Integer and fixed-point work suits it
best; floating point would use the FPGA's DSP blocks.

### A straight comparison

Once C or C++ compiles, a benchmark comparison on equal terms: the same C or C++
source built by xcc with every parallel and GPU option available to it, against the
other compilers with all their usual optimisations.

### Also

- Fixes for the bugs that turn up.
- Improvements to the `par` scheduler: how tiles are shared between devices of very
  different speeds when nothing has been measured yet, and the fixed cost of each tile.

## Accepted limitations

These are tradeoffs and will not be changed:

- **A callback widened in two *different* modules compares unequal.** Two callbacks
  widened in the *same* module always compare equal, which covers a program registering
  and unregistering its own callbacks. Making the cross-module case equal would need a
  canonical trampoline address, which the loader cannot provide.
- **Floating point is IEEE-754 everywhere**: `float` is binary32 and `double` is
  binary64 on every target, with literals encoded at lex time. xcc does not promise that
  a *transcendental* function (`sin`, `pow`, …) returns bit-identical results across
  targets. Each platform's math library rounds the final bit its own way, as with C
  compilers across different libms.

## Known issues

Report bugs through [the feedback form](/feedback/).
