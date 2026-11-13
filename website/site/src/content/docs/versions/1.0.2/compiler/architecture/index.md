---
title: Architecture
description: How xcc works, a heterogeneous data-parallel compiler. xc and C front ends, one SSA intermediate representation and optimiser, CPU back ends and generated GPU kernels for Metal, CUDA, Vulkan and WebGPU in one executable, and a runtime that measures the devices and tiles work across them.
slug: versions/1.0.2/compiler/architecture
banner:
  content: 'This is the documentation for xc 1.0.2. <a href="/compiler/">The current documentation</a> describes the newest version.'
pagefind: false
---

xcc is a **heterogeneous data-parallel compiler**. One source, in xc or in C, becomes one
executable that holds native code for the CPU and a kernel for every GPU API the target can
reach. The program decides at run time, on the machine it runs on, which devices to use.

<svg class="xc-diagram" viewBox="0 0 860 330" style="max-width:860px" role="img" aria-label="How xcc compiles a program: xc or C source, one SSA IR and optimiser, CPU code and GPU kernels in one executable, and the par runtime choosing devices at run time">
<rect class="box" x="10" y="60" width="130" height="50" rx="6"/>
<text x="75" y="81.0" text-anchor="middle" class="head">xc source</text>
<text x="75" y="98.0" text-anchor="middle" class="muted">.xc</text>
<rect class="box" x="10" y="190" width="130" height="60" rx="6"/>
<text x="75" y="207.5" text-anchor="middle" class="head">C source</text>
<text x="75" y="224.5" text-anchor="middle" class="muted">.c, through clang's</text>
<text x="75" y="241.5" text-anchor="middle" class="muted">front end</text>
<rect class="key" x="180" y="115" width="140" height="90" rx="6"/>
<text x="250" y="139.0" text-anchor="middle" class="head">One SSA IR</text>
<text x="250" y="156.0" text-anchor="middle" class="muted">front ends lower once;</text>
<text x="250" y="173.0" text-anchor="middle" class="muted">par blocks found</text>
<text x="250" y="190.0" text-anchor="middle" class="muted">and validated here</text>
<path class="line" d="M140 85 L160 85 L160 140 L180 140"/>
<polygon class="arrow" points="180,140 173,136 173,144"/>
<path class="line" d="M140 220 L160 220 L160 180 L180 180"/>
<polygon class="arrow" points="180,180 173,176 173,184"/>
<rect class="box" x="360" y="115" width="130" height="90" rx="6"/>
<text x="425" y="139.0" text-anchor="middle" class="head">Optimiser</text>
<text x="425" y="156.0" text-anchor="middle" class="muted">SSA passes, loops,</text>
<text x="425" y="173.0" text-anchor="middle" class="muted">vectorisation,</text>
<text x="425" y="190.0" text-anchor="middle" class="muted">devirtualisation</text>
<path class="line" d="M320 160 L360 160"/>
<polygon class="arrow" points="360,160 353,156 353,164"/>
<rect class="box" x="530" y="30" width="150" height="110" rx="6"/>
<text x="605" y="55.5" text-anchor="middle" class="head">CPU code</text>
<text x="605" y="72.5" text-anchor="middle" class="muted">arm64, x86-64, win64,</text>
<text x="605" y="89.5" text-anchor="middle" class="muted">wasm32; and 68000,</text>
<text x="605" y="106.5" text-anchor="middle" class="muted">arm9, banked 6502</text>
<text x="605" y="123.5" text-anchor="middle" class="muted">(in-house assemblers)</text>
<rect class="key" x="530" y="180" width="150" height="110" rx="6"/>
<text x="605" y="205.5" text-anchor="middle" class="head">GPU kernels</text>
<text x="605" y="222.5" text-anchor="middle" class="muted">Metal (MSL)</text>
<text x="605" y="239.5" text-anchor="middle" class="muted">CUDA (PTX)</text>
<text x="605" y="256.5" text-anchor="middle" class="muted">Vulkan (SPIR-V)</text>
<text x="605" y="273.5" text-anchor="middle" class="muted">WebGPU (WGSL)</text>
<path class="line" d="M490 140 L510 140 L510 85 L530 85"/>
<polygon class="arrow" points="530,85 523,81 523,89"/>
<path class="line" d="M490 180 L510 180 L510 235 L530 235"/>
<polygon class="arrow" points="530,235 523,231 523,239"/>
<rect class="box" x="720" y="95" width="130" height="130" rx="6"/>
<text x="785" y="122.0" text-anchor="middle" class="head">One executable</text>
<text x="785" y="139.0" text-anchor="middle" class="muted">native code,</text>
<text x="785" y="156.0" text-anchor="middle" class="muted">embedded kernels,</text>
<text x="785" y="173.0" text-anchor="middle" class="muted">the par runtime;</text>
<text x="785" y="190.0" text-anchor="middle" class="muted">no GPU toolkit</text>
<text x="785" y="207.0" text-anchor="middle" class="muted">needed to build</text>
<path class="line" d="M680 85 L700 85 L700 140 L720 140"/>
<polygon class="arrow" points="720,140 713,136 713,144"/>
<path class="line" d="M680 235 L700 235 L700 180 L720 180"/>
<polygon class="arrow" points="720,180 713,176 713,184"/>
<text x="430" y="322" text-anchor="middle" class="muted">At run time the par runtime measures the CPU's threads, each GPU and any remote GPU, and keeps the fastest.</text>
</svg>

## The parts

- **Front ends.** xc has a hand-written recursive-descent parser; C is read through clang's
  front end as LLVM IR before any LLVM optimisation, and xcc translates it into its own IR.
  Both lower to the same **SSA intermediate representation**.
- **[Data-parallel extraction](/versions/1.0.2/compiler/architecture/extraction/).** Loops whose iterations
  are independent become `par` blocks, in three phases: **acquisition** of candidate loops,
  **validation** of each one, and **run-time device-under-test measurement** that picks the
  devices.
- **[The optimiser](/versions/1.0.2/compiler/architecture/optimisations/).** SSA passes over the shared IR:
  inlining, CSE, LICM, loop vectorisation for NEON, AVX2, AVX-512 and WebAssembly SIMD,
  guarded devirtualisation, idiom recognition and more.
- **[GPU kernels](/versions/1.0.2/compiler/architecture/gpu-kernels/).** Every `par` block is printed as
  Metal Shading Language, PTX, SPIR-V and WGSL by xcc itself, and embedded in the
  executable: **zero-dependency GPU inlining**, with no GPU toolkit at build time.
- **[Tiles, devices and the network](/versions/1.0.2/compiler/architecture/tiling/).** The runtime cuts a
  block into tiles and schedules them across every CPU core, GPUs from different vendors at
  once, and GPUs on other machines served by `xcd`: **transparent, scalable network
  tiling**.
- **CPU back ends.** arm64, x86-64, Windows x64 and WebAssembly, with in-house assemblers,
  linkers and Mach-O, ELF and PE writers, so a build needs no system toolchain. The same
  back-end design reaches the Motorola 68000, 32-bit ARM and a banked 6502.

## Self-hosting

xcc is written in xc and compiles itself. A release is built three times over, the compiler
building the compiler, and the second and third builds must be byte-identical before it
ships.
