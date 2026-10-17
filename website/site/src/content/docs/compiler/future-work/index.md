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

### A C front end

`xcc` compiling `.c` files directly, alongside `.xc`. The proposal and design are
written. C is an add-on: it uses the platform's own C headers.

### A C++ front end

`xcc` compiling C++ files directly. The proposal and design are written. It moves
`--par-auto`'s search for loops from the source parser to the IR, so that loops from C
and C++ are found the same way as loops from xc.

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
