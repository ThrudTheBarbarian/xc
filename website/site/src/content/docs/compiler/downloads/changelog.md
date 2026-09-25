---
title: ChangeLog
description: Release notes for the xcc toolchain, with bug fixes and new features per version.
---

## Version 0.61 — optimiser work, measured, and wrong code fixed

Most of this release is optimiser and back-end work, measured against clang on
a new benchmark suite. It also fixes wrong-code bugs found by building real
programs, and refuses several mistakes that used to compile without a word.

### Licence

- The compiler and its tools are GPLv3. The archives carry the text as `COPYING`.
- The standard library and runtime (`lib/xc/` in an install) are GPLv3 with the
  GCC Runtime Library Exception (`lib/xc/COPYING.RUNTIME`). They are compiled
  into every program xcc builds, and the exception means those programs carry
  no obligation. Closed and commercial programs are fine.

### New errors

- A pointer to a scalar of a different width is refused as an argument.
  Passing `&narrow` (an `i32`) where `i64*` is declared used to write eight
  bytes into four; the reverse left the high half unset. Differences of sign
  only, `void*`, function pointers, and struct and class pointers are not
  affected. A cast still overrides the check.
- Two file-scope declarations of one name at different types, such as
  `u32 gX;` in one file and `u32 gX[64];` in another, are an error naming both
  types. They used to share one object. Identical redeclarations still merge.
- `new C(args)` checks its arguments against the class's `init` methods,
  including inherited ones. A subclass with no `init` of its own used to run
  no initialiser, so every field read back zero. Arguments that match no `init`
  are an error. `new C()` with no arguments is still the allocate-and-zero form.
- `xcc` refuses more than one source file. It used to compile only the last
  one and write a binary with no `main`, which failed at load time with
  `Symbol not found: _main`. Objects and archives can still be listed beside
  the source file.

### Wrong code fixed

- `.length` on an array of more than 65535 elements returned the count
  modulo 65536 (120000 read as 54464). `for (v in arr)` used the same value, so
  long arrays were iterated short. The count is 32 bits on arm64, x86-64, win64,
  arm9 and wasm32.
- `new i64[N]` and `new u64[N]` called the allocator with a missing argument
  and could abort with a nonsense size.
- arm64: a function containing a floating-point conditional, such as
  `if (c) x = -x;`, could corrupt a `double` its caller held in a register.
- x86-64 Linux: storing a callback into a slot holding stale data, such as a
  reused union member, could crash. arm64 already had this fix.
- `Pool.forRangeWithThreads` skipped any chunk whose thread failed to start
  and returned as if it had run. Those chunks now run on the calling thread.
- `printf` field widths now apply to `%ld`, `%lu` and `%c` on x86-64, win64,
  arm9, Atari ST and wasm32, as they already did on arm64.

### Checked builds

- `-fbounds-check` checks fixed-size arrays (locals, globals, and arrays sized
  by their initialiser) against their declared length. Before, only heap
  allocations were checked and other subscripts passed unchecked.
- A failed check reports the source position. Most sites used to print
  `?:0:0`.
- `-fbounds-check` on a target other than arm64 is an error. `xcc` used to accept
  it and then fail at link on x86-64 and win64, or build a wasm32 module that
  checked nothing.

### Performance

The repository has a benchmark suite in `benchmark/`: nineteen programs, each
written in xtc and in Objective-C with ARC, both built at `-O3`, with a
checksum that must agree. The figures come from the compiler that ships.
Against clang the geometric mean is 0.92x on arm64 and 1.04x on x86-64, where
lower is faster. The [Performance](/compiler/performance/) page has the
per-program table and the caveats.

Optimiser:

- More loops vectorise: counting matches over bytes, loops that carry two
  accumulators, division by a constant, and reductions over the loop counter
  with no array.
- Small structs passed or copied by value are split into fields and kept in
  registers.
- Functions whose locals have their address taken can be inlined. On arm64,
  x86-64 and win64 so can functions taking a struct by value.
- A value stored to a field and read back in the same block is reused.
- An `if`/`else` choosing between two values becomes a branch-free select, and
  a short-circuit `&&` no longer builds a boolean in memory.
- Full unrolling is capped by the size of the result, so large unrolled loops
  no longer spill.
- On arm64, loop blocks are laid out so the hot path falls through.

arm64:

- Functions with large stack arrays get full register allocation and
  single-instruction frame access. Past 16 KB of frame, each access cost three
  instructions, and past 32 KB nothing was kept in a register.
- Functions with several loops reuse registers again. A live-range error made
  every value overlap every other.
- Floating-point code uses d16-d31 in functions that do not vectorise, and
  values between calls use x0-x7.
- More constants are encoded in the instruction: shifted 12-bit immediates
  such as `#4096`, logical immediates, shift counts and shifted-register
  operands.

x86-64:

- Floats are kept in registers instead of stack slots.
- The register allocator gains six caller-saved registers on Linux and four
  on win64.
- A block that ends by jumping to the next block falls through.
- Loop heads are aligned to 32 bytes, and ELF `.text` is aligned to 64 bytes
  so that alignment holds.
- A conditional select reuses the flags from its compare, and vector
  operations no longer copy a source register that dies at the instruction.
- Division by a constant vectorises, and constant array indices fold into the
  address.

Runtime:

- Small objects are cheaper to allocate. The macOS and x86-64 Linux runtimes
  no longer round every allocation up to 256 bytes, and x86-64 Linux keeps up
  to 64 freed blocks per 16-byte size class, up to 1 KB, for reuse. The
  allocation benchmark is now faster than clang on both hosts. win64 and arm9
  are unchanged.

wasm32:

- Three optimisations are on: unrolling loops with a run-time trip count,
  inlining functions that take a struct by value, and hoisting global
  addresses. Over eight benchmarks under Node, code is 31.5% faster on the
  geometric mean for modules 1.9% larger.
- The loader provides `clock_gettime`, so programs that time themselves run.

### Assemblers

- x86-64: SSE shifts by an immediate (`psrlw`, `psrld`, `psrlq`, `psllq`) were
  encoded as the register form and produced invalid code. `psrad`, `pslld`,
  `psrlq` and `psllq` by immediate, and `pcmpeqb`, `pcmpeqw`, `pcmpgtb` and
  `pcmpgtw`, were missing.
- arm64: `umull2` and `ushr` are supported.
- arm9: `//` comments are accepted as well as `@`, and neither is treated as a
  comment inside a quoted string.

### Install contents

- The install and every archive hold `xcc`, `xcc-sign`, `xcc-as` and the two
  simulators, `xcc-sim-6502` and `xcc-sim-68k`, plus the support tree in
  `lib/xc`. `xcc` runs every stage itself, from parsing to linking, so there are
  no separate stage programs in `bin/`.

### Options

<!-- FLAGS: list of options that now work in xcc -->

### Tools and documentation

- An `xcc` run from outside an install looked for `/opt/xcc/0.6` as its fallback
  library root, so a newer compiler could build against 0.6's libraries. The
  fallback now follows the compiler's own version.
- `XTIR_OPT_STOP_AFTER=<pass>` works with an installed `xcc`. It used to be
  ignored. An unknown pass name is refused with the list of valid names, and
  an empty value counts as unset.
- The language reference has a Grammar page, and `docs/xtc.bnf` holds the same
  grammar.

## Version 0.6 — the compiler is written in xtc

The `xcc` in this release is the compiler written in xtc, compiled by itself. 0.5 was
the internal line that led to this release and was never published, so its changes are
all listed here.

### `xcc` is written in xtc

- `xcc` is the compiler written in xtc, compiled by itself. The whole toolchain
  rebuilds itself to a fixed point.
- It ships for all three hosts: macOS on Apple silicon, Linux x86-64 and Windows x64.
  Each is a single self-contained binary. With no `-A`, it builds for the host it
  runs on.
- `xcc-sign` is written in xtc too.
- `xcc` rejects an option it does not implement with an error rather than ignoring it.
- The install goes to `/opt/xcc/0.6` and leaves an installed 0.4 alone. `xcc -v`
  reports `xcc 0.6 (xc, self-hosted)`.

### `callback`

A bound method now has a named type, spelled like `block`, with the signature inline:

```c
callback onChange void(i32 value) = &controller.valueChanged;
if (onChange) { onChange(3); }
onChange = (callback void(i32))0;
```

It works for locals, fields, parameters, globals and return types, and the standard
library uses it. A stored callback always auto-zeroes when its receiver dies, so writing
`weak:` on one is an error.

- A callback can be called from any expression: an array element, a struct field,
  another object's field, or the result of a call.
- Arrays of callbacks, and global arrays of pointers, take initialisers such as
  `{ &dbl, &sq }`.
- `(pointer)cb` gives the function's code address, and `(callback i32(i32))p` makes a
  callable callback from a C function pointer.
- A C function can no longer declare a `callback` parameter. C expects a one-word
  function pointer, and the two-word callback shifted every argument after it. Declare
  the parameter as `pointer` and pass `(pointer)&fn`.
- Assigning `&obj.method` to a `block` is refused. Before, it compiled and the call did
  nothing.

### Checked builds and analysis

- `-fbounds-check` checks every subscript against the array's declared length or the
  allocation's own count. A failing check prints the index, the real bound and a
  symbolised stack, then aborts. It is implemented for arm64.
- `-Wanalyze` turns on static checks for unreachable code, dead stores, conditions that
  are always true or false, and unused locals. It is off by default.
- The "`new` in a loop will leak" warning is removed. Under ARC none of the cases it
  reported leaked.

### Language

- `q - p` on two pointers gives the distance in elements, as in C, as a signed integer
  of the target's pointer width. It used to be rejected.
- Dereferencing a value that is not a pointer is an error. Before, it compiled and read
  from whatever address the value held. To write to an absolute address, cast first:
  `*(main:u8*)addr = v`.
- The `: unroll` loop annotation now makes the optimiser unroll that loop beyond its
  usual limits. It used to be accepted and ignored.
- A type that is never defined but used only through a pointer (`Handle*` as a field,
  parameter, return type or cast) is an opaque handle, as in C.
- `struct Foo;` declares a struct that is defined later.

### Library and runtime

- `Data.withCapacity(n)` reserves space, as `Array`, `Set` and `Map` do. It used to
  return `n` zero bytes already counted as content. `Data.withLength(n)` is the sized
  buffer.
- `cString()` on an empty `String` returns an empty string instead of null.
- `printf` honours flags and field widths (`%5d`, `%-10s`). An unrecognised
  specification used to shift every argument after it. The 6502 copies accept widths
  but do not pad.
- On 64-bit hosts the reference count is 32 bits, so an object can be retained more than
  65,535 times without being freed while still in use.
- File and process functions (`Files`, `Process`) work on x86-64 Linux, Windows, wasm32
  under Node, and m68k.
- Load-time constructors run on Android, x86-64 Linux and Windows.
- xt6502: `Math.TWO_PI()` for `float` returns 2π instead of 2/π, and `Math` seeds its
  random generator instead of writing to address `$0000`.

### Targets

- **arm64:** variadic functions use the native AAPCS convention, so a variadic xtc
  function can be called through a prototype from another unit or from C. Structs and
  callbacks passed by value that do not fit in registers go on the stack as AAPCS
  requires.
- **Separate compilation:** uninitialised file-scope globals and `extern` globals are
  common symbols on arm64 and x86-64, so every unit shares one copy and the largest
  definition wins. Initialised globals are exported on x86-64.
- **x86-64 linking:** the static link drops unreachable functions and duplicate data from
  separately compiled objects, and uninitialised globals take no space in the file. A
  program built from separate objects is now about the size of the same program built as
  one unit.
- **iOS:** `xcc --sign <identity.pem>` (with `--sign-entitlements <plist>`) signs the
  output as part of the build. `xcc-sign --seal-resources` writes an app bundle's
  resource seal, and `--info-plist`, `--code-resources` and entitlements are bound into
  the signature, so a bundle signed without Apple's `codesign` installs on a device.
  `Url.fetch` and `Log` work on iOS.

### Bug fixes

- A chain of constants such as `192 * 128 * 16` folds at full precision. It wrapped at
  16 bits, silently giving 0.
- Integer literal division such as `840 / 56` gives 15. The dividend was truncated to
  8 bits.
- `while (n-- > 0)` terminates.
- A `switch` case reached by fall-through sees the previous case's updates to locals, and
  a local updated inside a `switch` inside a loop keeps its value across iterations.
- Swapping two class-pointer locals inside a loop is no longer lost at loop exit (arm64,
  arm9).
- Taking the address of a parameter no longer corrupts the caller's arguments when the
  function is inlined.
- Values in very long functions are no longer corrupted across calls at `-O2` and above
  (arm64).
- A sum of two `double` products (`a*a + b*b`) is computed correctly on arm64.
- `double` to `i64`/`u64` conversion keeps values above 2³² on arm64.
- A function-local `static` array keeps its contents between calls.
- `!` on a `float` compiles.
- `s.n++`, `p->n++`, `s.n += k` and `++` on an instance variable compile and update the
  field.
- A struct's array field decays to a pointer; `&local` inside a ternary and `&*p`
  compile.
- A name declared as an array in one block and a scalar in another no longer shares one
  slot and crashes.
- A function returned as a callback no longer loses half its address and crashes.
- `p = c ? new P() : new P()` no longer leaks the object.
- Returning a `weak:` field retains it. The caller used to release an object it did not
  own.
- Storing a new object into a `weak:` local, field, global or array element, and a
  `weak:` return type, no longer leak.
- A function with a prototype in a shared header and a definition in one unit links from
  every unit.
- Virtual and protocol calls work in x86-64 programs built from separately compiled
  objects. They could crash at startup.
- String literals in two arm64 objects compiled with `-c` no longer collide at link.
- A static x86-64 program that uses OpenSSL (through libpq, for example) no longer
  crashes at exit.
- `main` receives `argc` and `argv` on Windows. On xt6502 they are zero rather than
  undefined.
- wasm32: `main(argc, argv)`, float-heavy code, locals of one name in sibling blocks,
  64-bit pointer offsets and `new T[n]` with a 64-bit count all produce valid modules. A
  comparison inside a ternary is typed `bool`, and inline assembly is a hard error. A
  library can call a virtual method on an object the application created.
- The m68k assembler no longer mis-resolves labels longer than 79 characters.
- The arm64 assemblers accept `fmsub` and `fnmadd`.
- In-house links that include Objective-C objects keep the data after them aligned.
- A code signature is the last thing in the file, as device install and `codesign`
  require.

## Version 0.4 — blocks, UTF-8 strings, the ambient platform, iOS and Android

The first release published as `xcc` archives.

### Host builds for Linux and Windows

Every host build (macOS, Linux as static musl binaries that run on any x86_64
distribution, and Windows) carries all the code generators, so the host decides only
where the compiler runs, never what it can produce. On a Windows host the default
target is win64.

### Blocks

Closures as first-class values, declared like variables
(`block b u32(u16 x, u16 y) = { … };`), with by-value snapshot captures. A block can
be passed as a parameter, returned, stored in an ivar, written inline as a method
argument, and given a bare `{ … }` body that takes the declared signature. A named
literal can call itself. Locals declared `block:` are captured copy-in/write-back;
returning such a block or storing it through a member or subscript is a compile
error. Capturing `self` or an ivar is an error in this release: copy it into a local
first. A block passed where a bound method is expected is refused. Blocks are
lowered onto classes at parse time, so they work on every backend including the 6502.
See [Blocks](/compiler/language/blocks/).

### Strings are UTF-8, end to end

`String` is UTF-8-native. Methods that work in bytes carry `Byte` in their name, and
methods that work in characters carry `Char`. This is a breaking change: `length` is
now `byteLength`, `substring` is `substringBytes`, `indexOf` is `byteIndexOf`, and
the other byte-position methods follow the same pattern. Two names keep their
spelling with a new meaning: `charAt(n)` returns the n-th code point, and
`appendChar` appends a code point. New members include `charCount`,
`substringChars`, `isValidUtf8` and `sanitizedUtf8` (invalid sequences become
U+FFFD). `String.withEncodedBytes` and `Data.withStringEncoded` transcode UTF-8,
ASCII, Latin-1 and UTF-16LE/BE at the edges.

String and char literals gain `\uNNNN` and `\UNNNNNNNN` escapes with fixed digit
counts, unlike C's greedy `\x`. The code point is stored as UTF-8. `\xNN` is limited
to ASCII (`\x7F` and below): use `\u` for a character, or `appendByte` for a raw
byte.

### Moving code to 0.4

Renamed methods fail to compile, so the compiler finds those call sites for you.
`charAt` and `appendChar` still compile with their new meaning, so library members
added in 0.4 carry `since("0.4")`, and `xcc --migrate=0.3:0.4` compiles as if the
library were still 0.3. Newer members drop out of lookup, and every call that relied
on the old meaning fails with a position. Fix those, then build without the flag.

### The ambient platform surface

`Url` (with a `fetch` whose completion is a block), `Log` with the `Logger` protocol
behind it, and the `Platform` facade with its `PlatformDelegate` are available with
**zero imports** on every target. Each target's prelude wires its own transport and
logger (browser fetch and console on wasm32, a tty-coloured console on hosted
targets), and application source never names a platform. On wasm32 the generated
loader carries default browser implementations, and a page can replace any of them
through `globalThis.xccImports.browser`.

### iOS, Android and code signing

- `-A ios` and `-A ios-sim` build arm64 Mach-O for iOS devices and the simulator.
- `xcc --sign <identity.pem>` (or the standalone `xcc-sign`) replaces the ad-hoc
  signature with a developer signature; `--sign-entitlements` embeds an entitlements
  plist. The signer has no Apple dependency and runs on Linux and Windows hosts.
- `-A android` builds aarch64 ELF for Android, and `--emit-apk` packages an
  installable APK. Both link in-house, with no Android SDK, NDK or JDK.

### The toolchain-free cross matrix

`make install` copies the musl and mingw link pools into the install, so a machine
with only xcc on it produces static Linux ELFs and Windows PEs. An x86-64 link that
finds no musl pool fails with an error naming where it looked, never a silent
fallback. A win64 link without the mingw pool uses the freestanding runtime, which
carries its own allocator and `printf`. The in-house Mach-O path is now the default
on Linux and Windows hosts too; linking `-l` against macOS system libraries still
needs an Apple SDK's `.tbd` stubs. x86-64 shared libraries link and run in-house.

### Sharper edges made safe

- Raw and class pointers no longer convert silently in either direction; a sema error
  names the fix. An explicit cast still works.
- On wasm32, an `extern` definition exports its *spelled* name even when overloads
  mangle the symbol internally, and two `extern` definitions of one name are an
  error.
- A C-variadic import on wasm32 is a compile error instead of an invalid module. Use
  `Stdio.printf` or a fixed-arity import.
- A Linux binary's `main` return flushes stdio through `exit(3)`, so piped output is no
  longer truncated at the buffer.
- A 64-bit multiply by a constant wider than 32 bits keeps its top bits on x86_64 and
  win64.

### Fixes

- A global whose initialiser cannot be folded, such as a string literal, held zero.
  It is now initialised before the first statement of `main`.
- A cyclic `#import` could silently corrupt field offsets at `-O2` and above.
- A declaration that shadowed an outer name rebound it for the rest of the function.
  The outer binding is now restored at scope exit, and a C-style `for` variable is
  scoped to the loop.
- An enum constant now matches an enum-typed parameter in an overloaded call.
- Assigning a strong local to a class-pointer parameter freed the object while the
  parameter still used it.

## Version 0.3 — wasm32, separate compilation, the in-house toolchain

### Renamed to `xcc`, and installable

The binaries are renamed: the driver is **`xcc`**, the assembler `xcc-as`, and the
simulators `xcc-sim-6502` / `xcc-sim-68k`. The language keeps the xtc name.
`make install` puts the toolchain in `/opt/xcc/<version>`, and the compiler finds its
libraries relative to its own binary. With no `-A` or `-m`, `xcc` builds for the host,
as `cc` does; the 6502 is `-A 6502`.

Source files use the `.xc` extension, and the pointer sigil is `*` (`u8* p`, `*p`).
The old `.xt` extension and `@` sigil are still accepted.

### wasm32

`-A wasm32` produces a `.wasm` file and a loader that runs under Node or in a browser.
The WAT assembler and binary writer are in-house. Classes, ARC, protocols, weak
references, `i64` and floats all work. It also has structured control flow at `-O1`
and above, `v128` SIMD, and multi-module `--emit-lib`. `#package` and `extern` declare
wasm imports and exports.

### The in-house toolchain

xcc has its own assembler, object writer and linker for every target: Mach-O (with an
ad-hoc code signer), ELF, PE/COFF and wasm. It is the default everywhere. A Mac builds
Linux and Windows executables with no other toolchain installed, and the compiler
builds and runs on Linux and Windows. The in-house linkers read static archives and
resolve `-l` themselves. A failed in-house link fails the build. `--no-self-host`
selects the external toolchain, and any build it finishes carries a warning.

### Separate compilation

- **`-c`** writes a relocatable object with its interface (`.xtc.iface`) beside it. A
  client compiles against the interface, not the source, and virtual dispatch across
  objects uses the defining module's slot numbering.
- **`-flto`** recompiles the IR each object carries as one module, so inlining and
  dead-code removal work across objects again.
- Both work on arm64, x86_64, win64 and arm9.
- `--emit-lib` can build a library that wraps an external C library. Third-party
  libraries install under `/opt/xcc/3p`.

### Categories and extensions

`class Shape (Drawing) { … }` adds methods to any class in scope, including one inside
a prebuilt shared library. `class Shape () { … }` may also add fields, but only where
the class itself is compiled. Category methods that a subclass overrides dispatch
correctly across library boundaries, and several libraries may extend one class.

### Threading

`Thread.spawn(&obj.method)`, `Mutex`, `Cond`, `Sem`, `Atomic`, `ThreadLocal` and
`Pool.forRange` are available on arm64, x86_64, win64 and arm9 (XTOS). ARC refcounts
become atomic automatically in modules that use threads; `-fthread-safe-arc` and
`-fno-thread-safe-arc` override the choice.

### Language

- **`i64` / `u64` on every target**, including xt6502, m68k and arm9. `Number` holds
  64-bit values and `printf` prints them.
- **`defer { … }`** runs when the enclosing scope exits by any path, before that
  scope's ARC releases.
- **Checked errors:** `throws`, `throw`, `try` and `catch`, with typed `catch (T e)`
  arms. Calling a `throws` function outside a `try` is a compile error.
- **Typed collections:** `Array<String>*`, `Set<T>` and `Map<K, V>` check what goes in
  and return the element type without a cast. `for (i32 v in coll)` unboxes.
- A `static` field has one copy per class.
- Structs lay out with the target's C alignment. `struct Name :packed { … }` opts out.
- A bodyless function declared with `...` uses the C variadic ABI, and `f(fmt, ...)`
  forwards a variadic's arguments.
- Adjacent string literals concatenate.
- `return;` in a function that declares a return value is an error. `-farc=off` is
  removed.

### Foundation

A `Copying` protocol. `String.appendFormat` and `String.withFormat`, in-place string
editing, path helpers and `CharacterSet`. Array insert, remove and replace. Host file
I/O and `argv`. `Map` and `Set` iterate in insertion order.

### Self-hosting

The front end, optimiser, every back end, the assemblers and the linkers are ported to
xtc. The port produces byte-identical output and builds itself to a fixed point.

### Options

`-fmalloc=mimalloc` (x86_64), `-Wunguarded-action` (a callback called without being
tested), `-x-<arch>,<option>` for target-specific options, and `xcc -v` reports the
build identity.

### Fixes

- ARC: `break` and `continue` released nothing, the right arm of `&&`/`||` leaked a
  temporary, and a store through a pointer did not retain.
- Returning a strong local through an upcast freed it.
- arm64 passes call arguments past the eighth on the stack, and its frame limit rises
  from 16 KB to 4 MB.
- Inline assembly was silently dropped on x86_64 and arm9.
- x86_64 returns a struct larger than 16 bytes through memory, as System V requires.
- A Mach-O dylib is no longer limited to 255 exported symbols.
- A failed checked downcast aborts on every target.
- A reduction loop that did not start at zero produced wrong results.

## Version 0.2 — the IR compiler, shared libraries, bound methods

A new version line. 0.12 was the last release of the AST code generator; **0.2** is the
first of the IR compiler, which replaces it. The old code generator is removed.

### One IR, six targets

The compiler lowers to a single architecture-neutral IR, and each backend passes the
full fixture corpus:

| `-A` | Target | Output |
|---|---|---|
| `6502` *(default)* | banked **xt6502**: 4 KB hidden hardware stack, SP-relative addressing | banked 6502 executable (`.xex`), run under `xts` (now `xcc-sim-6502`) |
| `arm64` | native macOS / Linux host | Mach-O / ELF executable |
| `arm9` | AArch32 / **XTOS** | ELF executable, or a `.so` |
| `m68k` | Motorola 680x0, `-m atarist` | GEMDOS `.tos`, run under `xst` (now `xcc-sim-68k`) |
| `x86_64` | Linux (musl) | ELF executable |
| `win64` | Windows x64 | PE executable or DLL |

`win64` joined later in the line. It runs under Wine and has full C interop, including
struct arguments, callbacks from C, and `#import <user32>` for the Windows API.

Standard-library classes resolve by **architecture × platform**, so one source serves
all of them. The compiler imports a per-platform prelude before every file, so
application source does not name its platform.

The `xl` / `xe` flat and PORTB memory models, and the Commodore `c64` target, are
**retired**.

On the m68k, floats are software by default; `-mhard-float` uses a 68881/68882. On
the xt6502, `float` and `double` are IEEE, computed by the MECH math coprocessor, which
also handles 32-bit multiply and divide. The 5-byte software float is removed.

### Optimiser

`-O3` is the default. Every backend has a register allocator. The IR optimiser adds
inlining, loop-invariant code motion, loop unrolling, recursion-to-loop, if-conversion
and strength reduction. Loops auto-vectorise to NEON on arm64 and arm9 and to SSE on
x86_64.

### Shared libraries: `--emit-lib` and `#import <Lib>`

A program can be split into a library and its clients:

```bash
xtc -A arm9 --emit-lib -o libShapes.so shapes.xt
xtc -A arm9 -L . -o app.so app.xt
```

This works on arm9 (`.so`), arm64 (`.dylib`), x86_64 (`.so`) and win64 (DLL). The
library carries its **own interface inside the binary**, so `#import <Shapes>`
type-checks the client against the real library, with no header to fall out of sync.
Classes (with inheritance, virtual dispatch back into a client subclass, and
downcasts), protocols, structs by value, enums (constants *and* type names), free
functions, typedefs, `weak:` fields, bound methods, and C types re-exported from
*other* libraries all cross the boundary.

`#import <Foo>` also reads a plain **C** library's DWARF for its functions, types and
enum constants. Build the C library with `-fno-eliminate-unused-debug-types`, or gcc
drops the enum constants. See [Modules](/compiler/language/modules/).

### Protocols across a shared library

A protocol method is identified by its **index within its own declaration**, and the
protocol by a hash of its **name**. Every module derives both identically with no
coordination, so two independently built libraries compose, and a class conforming to
a protocol from each dispatches correctly through both. An object can be downcast to a
protocol at runtime.

### Bound methods and optional protocol methods

`&obj.method` yields a storable, callable `{receiver, code}` value. A plain function or
a static method **widens** into the same type, so one `action` field accepts any of
them. A stored callback never owns its receiver and auto-zeroes when the receiver dies.
The type was spelled with `^` in this release; it is written `callback` today, as below.

An `optional` protocol method may be left unimplemented, which leaves a **null slot**,
so testing a callback is equivalent to `respondsTo`:

```c
callback resized void(i32 w, i32 h) = &delegate.didResize;
if (resized) { resized(w, h); }
```

Together these support the delegate and target/action patterns.

### `extern` globals

Globals are scoped to the module they are compiled in. `extern u16 gCounter;` refers to
one defined elsewhere without reserving storage for a second copy, as an imported
library's globals require.

### `weak:` without a table

Weak slots are linked onto an **intrusive list** whose head lives in the referent's own
heap header. There is no capacity limit (the bounded side table and its
`[weak] entries` setting are removed), stores are O(1), and destroying an object with
**no** weak references costs one null test instead of a full table scan. A stored
callback gets the same auto-zeroing with nothing to declare.

### `final`

Removes a method from the vtable under `--emit-lib`, where whole-program
devirtualisation is unsound because the program is not whole.

### Smaller changes

- `main` returns the process exit code. A `void main` returns 0, and the 6502
  simulator reports the code.
- The preprocessor supports `#` and `##`, and macro arguments substitute whole tokens
  only.
- `printf` `%d`, `%u` and `%x` format an argument at its own width.
- Foundation gains ordering and sorting, a full `String`, set algebra, functional
  `Array` methods and `Data.hexString`. The containers no longer leak.

### Diagnostics

Cases that previously degraded silently are now **errors**: a store to a non-existent
struct field, an unknown type name, an unresolvable imported type, and a construct the
lowering cannot express. Before, these produced notes and the build succeeded with the
code missing.

## Version 0.12

### New features

The main change is **3-byte heap pointers on banked-heap layouts**. A heap pointer carries its bank byte alongside lo/hi, so a class instance, struct, or array allocated in any heap bank can be passed, returned, stored as an ivar, or kept in a collection without losing track of its bank. Every codegen path that moves a heap pointer was updated: ARC retains/releases, member access, ivar stores, multi-return tuples, downcasts, weak slots, stack-array zero-init / scope-exit walkers, subscript stores (const- and dyn-indexed), chained writes (`o.mid.leaf = …`), and Foundation `Array` / `Map` / `Set` storage. Programs on `xt`, `rambo*`, `compy*`, and `xe-heap` can spread their object graph across the full heap without trampolining through main RAM.

The **bank-switch bracket optimiser** covers more multi-byte field-access patterns:

- width=2 path-A bracket gate
- multi-byte heap-pointer field reads
- width=4 global-base banked field reads
- ARC field stores + struct copies
- multi-byte banked-store clusters (ExprAssign, ExprMembers)
- width=2 / width=4 dyn-banked-array reads
- xe-family bracket coverage

Each removes a save/restore around bank-select registers when the cluster shares a bank. On real programs this means fewer cycles per banked field access.

**Bank-register addresses are layout-configurable.** Layouts may place the bank-select hardware registers (previously hardcoded at `$82`/`$83`/`$84`/`$85`) at any address, for cartridge-mapped designs that expose the bank latches outside zero page. The compiler, the xcc-as preload-stub generator, and the xcc-sim-6502 simulator all use the layout's addresses.

**Graphics:**

- `Gfx7`: GR.7 (160×96 4-colour) with bulk-byte hline / vline fast paths
- `Gfx15`: GR.15 (160×192 4-colour) with the same bulk-byte path
- `gfxCreate(mode, textRows)` factory in `GfxFactory.xc`, with `GFX_<w>_<h>_<b>` aliases (`GFX_320_192_1`, etc.). It picks the right subclass and returns a `Gfx@` for polymorphic use. Call it as `inline:gfxCreate(MODE, ROWS)` when the mode is a compile-time constant: asm-level branch elimination then drops the unused subclass arms (~5 KB saved on a typical factory call)
- `Gfx.clear()` moved to the base class so it dispatches through `Gfx@`

**Other:**

- `inline:method()` on banked-heap (xe) PORTB-brackets the inlined body
- Vtable reachability uses the call-site × instantiation cross product, so dead vtable slots are zeroed instead of dangling
- Dead ARC retval stash/restore pairs are elided
- `xcc-as` warns on indirect-indexed addressing through a non-ZP operand
- `xcc-as` enforces split-bank size limits in `writeBankedXEX`

### Bug fixes

- codegen: `_virtual_dispatch` tail switched from `JMP (__vt_call_vec)` to self-modifying `JMP $0000` (the indirect form hit the 6502 `JMP ($XXFF)` page-crossing bug at -O3 on xl-shadow / xe-nobank)
- codegen: pin vtable targets to `:main`, because virtual dispatch is not bank-aware
- codegen: pre-allocate ZP for inline-asm `(name),Y` operands
- codegen: `_method_call_tramp` routes region-C receivers via `$84`/`$85`
- codegen: `emitMethodDispatch` receiver bank source for heap-w3
- codegen: `_xcall_*_resume` preserves Y across the trampoline
- codegen: bank packer estimator counts long-branch rewrites
- codegen: heap-w3 for-in stores result + bank source for spilled receiver
- codegen: heap-w3 ZP-resident struct field loads slot+2 bank
- codegen: heap-w3 pointer null-check tests lo+hi (was lo only)
- codegen: heap-w3 borrowed-init retain on 3-byte strong class pointer
- codegen: widen narrow call return when target type is wider
- codegen: gate `_cast_op_bank` emit on heap-w3 cast site
- foundation: `Map.contains` delegates to `get`; `Set.contains` uses if/else (avoids `&&` short-circuit bool-return path)
- foundation: `Gfx7.vline` pen=0 erase + colour overwrite

## Version 0.11

### New features

The main addition is a Foundation-style class library:
- an `Object` root class
- primitive wrappers (`Number` / `String` / `Data`)
- heterogeneous collections: `Array`, hash-based `Map` and `Set`
- the supporting `Comparable` / `Hashable` / `Enumerable` protocols

Autoboxing promotes primitives at `Object@` call sites, with matching unboxing into primitive destinations. The language also gained:

- range-based `for-in` (`for (T i in start..end)`, with step and descending forms)
- array slicing (`arr[m..n]`, `arr[..n]`, `arr[m..]`)
- range expressions as fixed-array initialisers

To obtain pointers to banks used as data, `bank(BANK_TYPE, idx)` is a builtin, and the `raw:T@` pointer flavour is added.

In codegen, cloaked code regions extend across the full set of bank windows that a target's memory-map layout defines. Calls across regions are transparent, an auto-overflow demote ladder handles full regions, and same-region bracket elision means a call from a bank to a function in the same bank pays no banked calling-convention penalty.

A new `xt-shadow-heap-regC` layout adds shadow main + region-C heap fallover, and the xt layouts are restructured to use banking by default.

The toolchain has a `-v/--version` flag, which helps diagnose why an include file is not found.

### Bug fixes

- codegen: retbuf-aliasing and banked frame-save symbol leak
- codegen: per-region cloak tracker + xe-heap bank-0 cloak placement
- codegen: zero out vtable slots whose implementation was dropped by reachability
- codegen: preserve Z = retval-lo across banked-call trampolines
- codegen: float→int cast staging bugs
- codegen: drop stackRangeSet gate on auto-cloak; fix xe-heap dispatch
- driver: -H path sanitisation, search-path diagnostics, ASCII output mode
- driver: sanitise XTC_HOME env var on Windows (strip quotes, normalise backslashes)
- driver: use strtoull in parseLongLongAddr for GNUstep portability
- sema: preserve resolved return type on implicit-self bare calls
- arc: set Y to heap_bank_first before stashing _arc_retval_bank
- banked: nested method-call trampoline + Number cross-kind equals
- xl-shadow: reserve screen RAM at $8000-$9FFF; ship Array.dealloc
- xcc-sim-6502: keep SAVMSC at $8000 for explicit banked targets
- xcc-as: keep longbr trio together when previous line has its `; longbr` comment
- xcc-as: bank-page overflow handling
- stdio: use BOTSCR (1-based row count), not BOTSCR-1
- stdio: port scroll() into cloaked Stdio variant
- optimiser: incorrect CMP #$00 elision in for-in range loops
- foundation: Number lazy cross-kind cache + float-cast ivar store fix
