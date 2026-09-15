---
title: Future work
description: What's planned, in progress, and known to be incomplete in xcc.
---

xcc is pre-1.0. This page lists where it is going, what is known to be incomplete, and
what has shipped recently.

## Where things stand

The compiler lowers to a single architecture-neutral IR and out through **seven live
backends**: xt6502, arm64 (macOS), arm9, m68k, x86_64 (Linux/musl), win64 and
**wasm32**. Every one passes the full fixture corpus, and every one is built end to end
by the **in-house toolchain**: xcc's own assemblers, linkers and executable-format
writers, with no external compiler in the chain. A macOS machine with only xcc installed
cross-builds native binaries for Linux, Windows and the browser, because the libc link
pools ship inside the install.

The whole compiler also exists a **second time, written in xcc**. Twenty-four
differential harnesses hold every stage of it byte-identical to the original, and they
run on every commit.

Application code is **platform-neutral by default**. `Url`, `Log` and `Platform` are
available on every target (each platform's prelude wires its own transports and loggers),
so the same directive-free source file compiles, links and *runs* on a Mac, a Linux
server, a browser and a banked 6502. Where a feature is missing, the program degrades
instead of failing to build: a fetch with no transport completes with status 0 and a
logged warning.

## Mobile: iOS and Android

**iOS/iPadOS and Android are implemented**, so one language covers desktop, server,
browser and phone. The two ports have a similar shape:

- **iOS is a platform variant of the arm64/Mach-O target** (`-A ios` / `-A ios-sim`),
  with the same ISA, object format and calling convention as macOS. It adds a platform
  stamp in the binary, the iOS SDK's stub libraries, a small native shell that owns the
  run loop and feeds events in, and in-house code signing (`xcc-sign`, or `xcc --sign`)
  that a real device accepts, with no Xcode `codesign` step. The simulator makes the
  whole loop scriptable on a Mac.
- **Android pairs the arm64 code generator with the ELF writer** (`-A android`,
  `--emit-apk`), links against Android's libc as a shared object, and uses
  **NativeActivity**: an app whose logic is all native code behind a boilerplate
  manifest, the same mechanism Qt and SDL use. No Java is required.
- On both, the UI comes from **Xtg**, which does **not** draw its own widgets. It
  delegates to the platform's native widget set through a thin shim, so each control is
  the platform's own: an `NSTableView` on AppKit, the native table control on Win32, a
  GTK table on Linux, a GEM object on the Atari targets, and UIKit and the Android view
  toolkit on the phones. What stays constant across platforms is the **programming
  interface** (the AppKit-style datasource / delegate pattern), while the appearance is
  native. On both phones the acceptance test is the same unchanged file that runs on
  every other target. The platform prelude handles the differences: `Log.info` goes to
  the console on a server, the browser console on the web, and the system log on a
  phone, with no change to the app source.

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

## Recently shipped

- **The ambient platform surface.** `Url` (an NSURL-style value with a cross-platform
  `fetch`), a `Logger` protocol behind the `Log` facade (tty-coloured console on hosted
  targets, browser console on wasm), and a `Platform` delegate seam. All are available
  with zero imports in application code and are wired per target by each platform's
  prelude.
- **The wasm32 target.** `xcc -A wasm32 -o app app.xc` produces a `.wasm` plus a
  universal loader that runs unchanged under Node and in a browser. Classes, ARC,
  protocols, blocks, 64-bit integers and IEEE floats all work, and the browser's
  fetch/DOM/console surface is carried inside the generated loader.
- **Blocks.** Closures as first-class values with by-value snapshot captures, declared
  like variables (`block b u32(u16 x) = { … };`), storable in fields and registries, and
  passable inline to methods. `block:` write-back captures support accumulating into a
  local, and escape analysis turns the unsound cases into compile errors. See
  [Blocks](/compiler/language/blocks/).
- **UTF-8 strings, end to end.** `String` is UTF-8-native with byte *and* character
  interfaces. 0.4 adds `\xNN`, `\uNNNN` and `\UNNNNNNNN` escapes with fixed digit counts
  (unlike C's greedy `\x`).
- **The toolchain-free cross matrix.** `make install` copies the Linux (musl) and
  Windows (mingw) link pools into the install, so building static Linux ELFs and Windows
  PEs on a Mac needs no external toolchain. A missing pool is an error that names what is
  absent, never a silent fallback.
- **Export names are fixed.** An `extern` definition exports under its *spelled* name
  even when overload resolution mangles the symbol internally, and two `extern`
  definitions of one name are a compile error. A host that looks up an export by name
  always finds it under that name.
- **A full Mach-O export trie.** The export writer builds the full prefix tree, so a
  dylib is no longer capped at 255 exported symbols. A 400-symbol library round-trips with
  clients calling symbols on both sides of the former limit.
- **Shared libraries and `#import <Lib>`** on arm9, arm64, x86_64 and win64. A library
  carries its own interface *inside* the binary, so clients type-check against the real
  artifact rather than a header that may be out of date. Protocols compose across
  libraries built independently of each other, and `weak:` fields, bound methods and
  re-exported C types all cross the boundary.
- **`weak:` without a table.** Weak slots are linked onto an intrusive list in the
  referent's own heap header: no capacity limit, O(1) stores, and destroying an object
  with no weak references costs one null test.
- **A differential fuzzer.** It generates random programs, compiles them through every
  backend, and treats any divergence between two targets as a bug. It found seven bugs
  the corpus had missed.
- **Collections.** `Array`, `Map`, `Set`, `String`, `Data`, `Number` and `Sort`, plus the
  `Comparable` / `Hashable` / `Enumerable` protocols, with one implementation shared by
  every backend.

## Known issues

None outstanding. Report bugs through [the feedback form](/feedback/).
