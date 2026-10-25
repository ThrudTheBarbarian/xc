---
title: Downloads
description: Prebuilt xcc toolchain archives for macOS, Linux and Windows, the arm9 sysroot, and UXKit's GTK 4 library.
---

The current release line is **xcc 0.87**. One install contains the whole toolchain: the
compiler (`xcc`, which runs every stage itself, from parsing through code generation
for all seven targets to assembly and linking), the signing tool (`xcc-sign`), the
6502 assembler (`xcc-as`), the simulators (`xcc-sim-6502`, `xcc-sim-68k`), the
complete standard library, and the Linux (musl) and Windows (mingw) link pools. A single machine can
cross-build native binaries for every target with **no other toolchain installed**.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (Apple silicon) | [xcc-osx-0.87.tar.bz2](/downloads/xcc-osx-0.87.tar.bz2) | 10.4 MB |
| Linux (x86_64) | [xcc-linux-0.87.tar.bz2](/downloads/xcc-linux-0.87.tar.bz2) | 6.9 MB |
| Windows (x64) | [xcc-win64-0.87.zip](/downloads/xcc-win64-0.87.zip) | 8.5 MB |
| arm9 sysroot (any host) | [xcc-arm9-sysroot-0.87.tar.bz2](/downloads/xcc-arm9-sysroot-0.87.tar.bz2) | 830 KB |
| xcd, the par daemon (macOS) | [xcd-osx-0.87.tar.bz2](/downloads/xcd-osx-0.87.tar.bz2) | 858 KB |
| xcd, the par daemon (Linux x86_64) | [xcd-linux-0.87.tar.bz2](/downloads/xcd-linux-0.87.tar.bz2) | 799 KB |
| xcd, the par daemon (Windows x64) | [xcd-win64-0.87.zip](/downloads/xcd-win64-0.87.zip) | 923 KB |
| UXKit GTK 4 library (Linux x86_64) | [xcc-uxgtk-linux-0.75.tar.bz2](/downloads/xcc-uxgtk-linux-0.75.tar.bz2) | 110 KB |
| UXKit library (macOS arm64, Windows x64, Linux x86_64, web) | [xcc-uxkit-0.75.tar.bz2](/downloads/xcc-uxkit-0.75.tar.bz2) | 2.9 MB |

Every archive contains the same compiler. Each host build cross-compiles to **all**
targets, so the platform you download for decides only where the compiler runs.

The arm9 sysroot is the one extra piece, and only for `-A arm9`: that target links
against the XTOS loader's `libc.so` and reads the C library out of its DWARF, so
that one file has to be on the library search path. Every other target is complete
in the host archive.

## macOS

```bash
tar xjf xcc-osx-0.87.tar.bz2
export PATH="$PWD/xcc-osx-0.87/bin:$PATH"
xcc -v
```

The compiler finds its libraries **relative to its own binary**, with no flags,
environment variables or fixed install path, so you can move the directory anywhere.
The binaries are not notarised, so the first run on a fresh macOS install may need a
one-time Gatekeeper override (`xattr -dr com.apple.quarantine xcc-osx-0.87/`).

## arm9 sysroot

Needed only for `-A arm9`. Unpack it anywhere and point `-L` at it:

```bash
tar xjf xcc-arm9-sysroot-0.87.tar.bz2
xcc -A arm9 -L path/to/xcc-arm9-sysroot-0.87 -o prog.so prog.xc
```

It holds one file: `libc.so`, newlib 4.4.0.20231231 rebuilt as position-independent
code for the Cortex-A9, plus the loader's directory and malloc-lock support. BSD-style
licensed throughout — `COPYING.NEWLIB` and `NOTICE` are in the archive — so linking
against it places no obligation on your program.

Compiling is what this archive is for. **Running** an arm9 binary also needs an XTOS
kernel to host it, which is not distributed here.

`make install` also vendors a sysroot into `lib/xc/arm9-sysroot/` when it can find
one, and then `-A arm9` needs no `-L` at all.

## UXKit GTK 4 library

Needed only for a Linux GUI program built with UXKit's GTK back end. The
program is a glibc executable that loads GTK 4, which is how `-A x86_64` links
by default:

```bash
tar xjf xcc-uxgtk-linux-0.75.tar.bz2
xcc -A x86_64 app.xc -L xcc-uxgtk-linux-0.75 -lUXGtk -lgtk-4 -o app
```

The machine that runs the program needs glibc 2.34 or later and GTK 4; this
build is against GTK 4.22, and an older GTK 4 may lack a symbol it uses. Linking
from a Mac also needs a copy of the target's `libgtk-4.so` on the `-L` path.
UXKit is LGPLv3: the archive carries the library's source and a script that
rebuilds it against any machine's GTK 4.

## UXKit library

UXKit built as a library for macOS (arm64), Windows (x64), Linux (x86_64) and the
web, for xcc 0.8. Put its `3p/` beside the versioned install, so that
`/opt/xcc/3p/uxkit/` sits next to `/opt/xcc/0.8/`:

```bash
tar xjf xcc-uxkit-0.75.tar.bz2
sudo cp -R xcc-uxkit-0.75/3p /opt/xcc/
```

A program then names UXKit once, with `#use <UXKit>`, and builds with nothing
else: `xcc -A arm64 app.xc -o app`. On Windows ship `libUXKit.dll` beside the
program; on Linux `libUXKit.so` and `libUXGtk.so` (the machine needs GTK 4); on
the web `libUXKit.wasm`, `libUXKit.json` and the two `ux_web_*.js` files. UXKit
is LGPLv3; the archive carries its source and the script that rebuilds it.

## Linux

The archives are compressed with bzip2, which a minimal Linux install may not
have. If `tar` says it cannot run `bzip2`, install it first (on Ubuntu,
`sudo apt-get install -y bzip2`).

```bash
tar xjf xcc-linux-0.87.tar.bz2
export PATH="$PWD/xcc-linux-0.87/bin:$PATH"
xcc -v
```

The binaries are static (musl), so they run on any x86_64 distribution with no
library dependencies.

A `par` block reaches the GPU on Linux through Vulkan, so running one on the
GPU needs the Vulkan loader and a driver. A desktop install usually has both.
[Set up the GPU](/compiler/benchmarks/how-to-diy/#set-up-the-gpu-optional)
covers a minimal install, NVIDIA, and access over ssh.

## Windows

Unzip `xcc-win64-0.87.zip` anywhere and add its `bin` folder to `PATH` (or
invoke `bin\xcc.exe` by path). The binaries are self-contained; no runtime installer is
needed.

## xcd, the par worker daemon

A machine that only lends its GPUs to `par` programs on the network needs no
compiler: each release also ships `xcd-osx-<version>.tar.bz2`,
`xcd-linux-<version>.tar.bz2` and `xcd-win64-<version>.zip`, holding the
daemon and the TLS library it talks through, and `xcmon`, a monitor that
draws the daemons and the programs using them in a browser page. Unpack it
and run `bin/xcd` (see
[Across machines](/compiler/language/par/#across-machines-xcd)).

## First build

```c
// hello.xc — no imports needed: Log is ambient on every target.
void main(void) {
    Log.info("hello from %s", "xcc");
}
```

```bash
xcc -o hello hello.xc      # native binary for this machine, like cc
./hello
```

The same file cross-compiles to every target by picking an architecture:

```bash
xcc -A x86_64 -o hello-linux hello.xc    # Linux ELF against glibc (-static: self-contained, musl)
xcc -A win64  -o hello.exe    hello.xc   # Windows PE
xcc -A wasm32 -o hello        hello.xc   # hello.wasm + a Node/browser loader
xcc -A 6502   -o hello.xex    hello.xc   # banked 6502 executable (run: xcc-sim-6502 -m xt hello.xex)
```

Next, [Compiler usage → CLI reference](/compiler/usage/cli/) covers the common flags,
and [Install](/compiler/usage/install/) covers a system-wide `make install`.

Older archives are on the
[Historical Releases](/compiler/downloads/historical/) page, and the
[ChangeLog](/compiler/downloads/changelog/) lists what changed per version.
