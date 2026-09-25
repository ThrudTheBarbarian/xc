---
title: Historical Releases
description: Previous xcc and xtc toolchain releases, kept for archival reference.
---

These archives are kept so that an existing build can be reproduced byte-for-byte with the version it was compiled with. For new work, use the [most recent release](/compiler/downloads/). The [ChangeLog](/compiler/downloads/changelog/) lists what has changed since.

## xcc 0.6

The previous release line, and the first in which the shipped `xcc` is the
self-hosted compiler.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (Apple silicon) | [xcc-osx-0.6.tar.bz2](/downloads/xcc-osx-0.6.tar.bz2) | 13 MB |
| Linux (x86_64) | [xcc-linux-0.6.tar.bz2](/downloads/xcc-linux-0.6.tar.bz2) | 67 MB |
| Windows (x64) | [xcc-win64-0.6.zip](/downloads/xcc-win64-0.6.zip) | 78 MB |
| arm9 sysroot (any host) | [xcc-arm9-sysroot-0.6.tar.bz2](/downloads/xcc-arm9-sysroot-0.6.tar.bz2) | 830 KB |

## xcc 0.4

The last release before the self-hosted compiler became the shipped one. The driver is `xcc` and the layout is the current `lib/xc` one,
so these archives behave as the rest of this site describes, as an older version.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (Apple silicon) | [xcc-osx-0.4.tar.bz2](/downloads/xcc-osx-0.4.tar.bz2) | 8.9 MB |
| Linux (x86_64) | [xcc-linux-0.4.tar.bz2](/downloads/xcc-linux-0.4.tar.bz2) | 61 MB |
| Windows (x64) | [xcc-win64-0.4.zip](/downloads/xcc-win64-0.4.zip) | 71 MB |

The version is in the install path, so 0.4 and the current release can be
installed side by side without seeing each other's libraries. See
[Install](/compiler/usage/install/).

## xtc 0.12

The last release of the AST code generator, from **before the toolchain was
renamed**. The driver in these archives is `xtc`, not `xcc`, and they use the
older `resources/support/` layout. They work as originally documented; the rest
of this site describes the current toolchain.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (universal) | [xtc-osx-0.12.tar.bz2](/downloads/xtc-osx-0.12.tar.bz2) | 1.1 MB |
| Linux (x86_64) | [xtc-linux-0.12.tar.bz2](/downloads/xtc-linux-0.12.tar.bz2) | 16 MB |
| Windows (x64) | [xtc-win64-0.12.zip](/downloads/xtc-win64-0.12.zip) | 18 MB |

These builds find their `support/` tree via `-H`, `XTC_HOME`, or the search
paths of that release (alongside the source, `$HOME/xtc`, `/usr/local/xtc`,
`/opt/xtc`). See the notes shipped inside each archive.

## xtc 0.11

Foundation-style class library (`Object`, `Number`, `String`, `Data`, `Array`, `Map`, `Set` plus `Comparable` / `Hashable` / `Enumerable` protocols), autoboxing, range-based `for-in`, array slicing, the `bank()` builtin and `raw:T@` pointer flavour, full cross-region cloaked-code support, and the `xt-shadow-heap-regC` layout.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (universal) | [xtc-osx-0.11.tar.bz2](/downloads/xtc-osx-0.11.tar.bz2) | 1.0 MB |
| Linux (x86_64) | [xtc-linux-0.11.tar.bz2](/downloads/xtc-linux-0.11.tar.bz2) | 16 MB |
| Windows (x64) | [xtc-win64-0.11.zip](/downloads/xtc-win64-0.11.zip) | 18 MB |

## xtc 0.1

The first public release.

| Platform | Download | Size |
| --- | --- | --- |
| macOS (universal) | [xtc-osx-0.1.tar.bz2](/downloads/xtc-osx-0.1.tar.bz2) | 1.8 MB |
| Linux (x86_64) | [xtc-linux-0.1.tar.bz2](/downloads/xtc-linux-0.1.tar.bz2) | 16 MB |
| Windows (x64) | [xtc-win64-0.1.zip](/downloads/xtc-win64-0.1.zip) | 18 MB |

Each archive contains the compiler driver (`xtc`), the assembler (`xta`), the simulator (`xts`), and the matching `resources/support/` tree. Install it as described on the current download page, substituting `0.1` for the version number in the unpack and `cd` commands.
