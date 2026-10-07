---
title: Downloads
description: Prebuilt xcc toolchain archives for macOS, Linux and Windows, the arm9 sysroot, and UXKit's GTK 4 library.
---

The current release line is **xcc 0.72**. One install contains the whole toolchain: the
compiler (`xcc`, which runs every stage itself, from parsing through code generation
for all seven targets to assembly and linking), the signing tool (`xcc-sign`), the
6502 assembler (`xcc-as`), the simulators (`xcc-sim-6502`, `xcc-sim-68k`), the
complete standard library, and the Linux (musl) and Windows (mingw) link pools. A single machine can
cross-build native binaries for every target with **no other toolchain installed**.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (Apple silicon) | [xcc-osx-0.72.tar.bz2](/downloads/xcc-osx-0.72.tar.bz2) | 8.7 MB |
| Linux (x86_64) | [xcc-linux-0.72.tar.bz2](/downloads/xcc-linux-0.72.tar.bz2) | 6.4 MB |
| Windows (x64) | [xcc-win64-0.72.zip](/downloads/xcc-win64-0.72.zip) | 7.4 MB |
| arm9 sysroot (any host) | [xcc-arm9-sysroot-0.72.tar.bz2](/downloads/xcc-arm9-sysroot-0.72.tar.bz2) | 830 KB |
| UXKit GTK 4 library (Linux x86_64) | [xcc-uxgtk-linux-0.72.tar.bz2](/downloads/xcc-uxgtk-linux-0.72.tar.bz2) | 99 KB |

Every archive contains the same compiler. Each host build cross-compiles to **all**
targets, so the platform you download for decides only where the compiler runs.

The arm9 sysroot is the one extra piece, and only for `-A arm9`: that target links
against the XTOS loader's `libc.so` and reads the C library out of its DWARF, so
that one file has to be on the library search path. Every other target is complete
in the host archive.

## macOS

```bash
tar xjf xcc-osx-0.72.tar.bz2
export PATH="$PWD/xcc-osx-0.72/bin:$PATH"
xcc -v
```

The compiler finds its libraries **relative to its own binary**, with no flags,
environment variables or fixed install path, so you can move the directory anywhere.
The binaries are not notarised, so the first run on a fresh macOS install may need a
one-time Gatekeeper override (`xattr -dr com.apple.quarantine xcc-osx-0.72/`).

## arm9 sysroot

Needed only for `-A arm9`. Unpack it anywhere and point `-L` at it:

```bash
tar xjf xcc-arm9-sysroot-0.72.tar.bz2
xcc -A arm9 -L path/to/xcc-arm9-sysroot-0.72 -o prog.so prog.xc
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
by default from 0.72:

```bash
tar xjf xcc-uxgtk-linux-0.72.tar.bz2
xcc -A x86_64 app.xc -L xcc-uxgtk-linux-0.72 -lUXGtk -lgtk-4 -o app
```

The machine that runs the program needs glibc 2.34 or later and GTK 4; this
build is against GTK 4.22, and an older GTK 4 may lack a symbol it uses. Linking
from a Mac also needs a copy of the target's `libgtk-4.so` on the `-L` path.
UXKit is LGPLv3: the archive carries the library's source and a script that
rebuilds it against any machine's GTK 4.

## Linux

```bash
tar xjf xcc-linux-0.72.tar.bz2
export PATH="$PWD/xcc-linux-0.72/bin:$PATH"
xcc -v
```

The binaries are static (musl), so they run on any x86_64 distribution with no
library dependencies.

## Windows

Unzip `xcc-win64-0.72.zip` anywhere and add the folder to `PATH` (or invoke
`xcc.exe` by path). The binaries are self-contained; no runtime installer is
needed.

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
