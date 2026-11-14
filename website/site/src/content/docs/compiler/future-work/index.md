---
title: Future work
description: Where xc's heterogeneous data-parallel compiler stands, the machines it is measured on (the Raspberry Pi 5 among them), the hardware we would like to test on, and what is planned next.
---

xcc is pre-1.0. This page lists where it is going and what is known to be incomplete.
What has shipped is in the [ChangeLog](/compiler/downloads/changelog/).

## Where things stand

xc is a heterogeneous data-parallel language. A loop whose iterations are independent
becomes a [`par` block](/compiler/language/par/), and that block runs across every CPU
core, on GPUs through Metal, CUDA, Vulkan and WebGPU, on several GPUs from different
vendors at once, and on GPUs on other machines through the `xcd` daemon. `auto` measures
the choices for each block on the machine it runs on and keeps the fastest. C programs get
the same treatment. How it works is in [Architecture](/compiler/architecture/).

It is measured, every release, on an Apple M3 Max and M4 Max (Metal), an AMD Ryzen 9
9955HX with its integrated Radeon (Vulkan), an Intel Core i5-14500 with an RTX 5070, an AMD
Ryzen 9 5950X with an RTX 5080 and an RTX 3090 (CUDA and Vulkan together), Chrome with
WebGPU, and a Raspberry Pi 5. The results are on the [benchmark pages](/compiler/benchmarks/).

The CPU code comes from xcc's own back ends for arm64 (macOS, Linux, iOS and Android),
x86-64 (Linux and Windows) and WebAssembly, assembled and linked by its own toolchain with
no external compiler in the chain, so a Mac with only xcc installed cross-builds for Linux,
Windows, the phones and the browser. The same back ends reach the Motorola 68000, 32-bit
ARM and a banked 6502, and every target passes the full test corpus. The compiler is
written in xc and builds itself.

### The Raspberry Pi 5

The Pi 5 is a full target, and the smallest machine xc is measured on:

- **xcc runs on the Pi itself**: the `xcc-linux-arm64` download is a native compiler, and
  programs built anywhere with `-A arm64-linux` run there too.
- **`par` blocks run on its VideoCore VII GPU** through Vulkan, which has no 64-bit
  integers: xcc gives each block a 32-bit form of its kernel where the block's range
  allows, and `auto` keeps the CPU's four cores where the GPU cannot help.
- **It can borrow a bigger GPU.** With an `xcd` daemon on the network, a Pi runs its
  blocks on a desktop's card: `mandel_deep` runs about ten times faster on a remote RTX
  5080 than on the Pi's own CPU and GPU.

## Hardware we would like to test on

Every figure on these pages is measured on hardware the project has bought, and the
machines that matter most for data-parallel work are expensive. A loan or donation goes
straight into the compiler: a back end and a runtime tuned on the device, kept working by
being tested on it every release, and its figures published here beside the others. We
would most like:

- **Discrete AMD GPUs**, Radeon and Instinct: xc reaches them through Vulkan today, and
  has only an integrated Radeon to measure on.
- **Intel GPUs**, Arc and data-centre parts, through Vulkan.
- **Data-centre NVIDIA GPUs and multi-GPU servers**, where tiling across many cards, and
  across machines, is meant to pay.
- **Arm servers** (Graviton, Ampere, Grace) and their wider vector units.
- **RISC-V boards with the vector extension**, and their GPUs.
- **Fast interconnect**: 25, 100 GbE or InfiniBand between GPU machines, for `xcd`.

If you make or sell hardware like this and would like xc to run well on it, write to
[xc@oobergeek.net](mailto:xc@oobergeek.net).

## Planned

### `xcd` at the scale of a rack

Today a daemon serves one program at a time, on the first of its GPUs that fits the
block. The next steps are a daemon that spreads one block across every GPU it has and
serves several programs at once, and scheduling that weighs each machine's link as well as
its speed, so a block can use a room of GPU machines as one.

### A tensor library in xc

An equivalent of PyTorch, written in xc: tensors, their operations and automatic
differentiation, with the work spread across every GPU and CPU available, on one
machine or several, the way a `par` block's tiles are today.

### LLVM IR from any language

`xcc` already compiles C by reading the LLVM IR `clang` makes from it, before any of LLVM's
own optimisation, and putting that through its own optimiser: the same passes, the same
data-parallel extraction that makes `par` blocks of independent loops, the same GPU kernel
generation and the same back ends as an xc program (see [C programs](/compiler/usage/c-programs/)).

C++ takes the same path (see [C++ programs](/compiler/usage/cpp-programs/)). The plan is
to accept LLVM IR from any front end that makes it: Rust, Swift, Zig, Fortran through
`flang`, and the rest. Any language that compiles
through LLVM would then get the same acceleration as xc and C: its loops lifted into `par`
blocks, run across every CPU core and on GPUs through Metal, CUDA, Vulkan and WebGPU, on
several GPUs at once or over the network, with no change to its source. Most of the work
is widening what `xcc` reads of LLVM IR: today it takes the subset C needs.

### `par` on FPGAs, through `xcd`

A `par` block run on an FPGA as well as on GPUs and CPUs: its body compiled to logic by
high-level synthesis, and the board served by an `xcd` worker like a remote GPU, so its
tiles join the same queue as every other device's. Integer and fixed-point work suits it
best; floating point would use the FPGA's DSP blocks.

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
