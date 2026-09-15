---
title: ChangeLog
description: Release notes for the xcc toolchain, with bug fixes and new features per version.
---

## Version 0.4 — the xcc rename, blocks, UTF-8 strings, the ambient platform

The toolchain is renamed. The driver is **`xcc`** (formerly `xtc`), the assembler
`xcc-as`, and the simulators `xcc-sim-6502` / `xcc-sim-68k`. The *language* keeps the
xtc name. Installs go to `/opt/xcc/<version>`, and the compiler finds its libraries
relative to its own binary with no flags or environment variables. `xcc --migrate`
rewrites the mechanical parts of pre-0.4 source, and library declarations carry
`since("0.4")` markers so that version mismatches are diagnosed rather than mis-parsed.

### Blocks

Closures as first-class values, declared like variables
(`block b u32(u16 x, u16 y) = { … };`), with by-value snapshot captures. Blocks are
storable in fields and registries and passable inline to methods. `block:` write-back
captures come with escape analysis that turns the unsound cases into compile errors.
Blocks are lowered onto classes at parse time, so they work on every backend including
the 6502. See [Blocks](/compiler/language/blocks/).

### Strings are UTF-8, end to end

`String` is UTF-8-native with parallel byte and character interfaces. String literals
gain `\xNN` (ASCII only), `\uNNNN` and `\UNNNNNNNN` escapes with fixed digit counts,
unlike C's greedy `\x`.

### The ambient platform surface

`Url` (an NSURL-style value whose `fetch` completion is a block), the `Logger`
protocol behind the `Log` facade, and the `Platform` delegate seam are available
with **zero imports** on every target. Each platform's prelude wires its own
transport and logger (browser fetch/console on wasm32, tty-coloured console on
hosted targets), and application source never names a platform.

### The toolchain-free cross matrix

`make install` copies the musl and mingw link pools into the install, so a Mac with
only xcc on it produces static Linux ELFs and Windows PEs. A link that finds no pool
fails with an error naming the missing pool, never a silent fallback. The in-house
Mach-O path is the default on every host.

### Sharper edges made safe

- Raw and class pointers no longer convert silently in either direction; a sema error
  names the fix.
- An `extern` definition exports its *spelled* name even when overloads mangle the
  symbol internally, and two externs of one name are an error.
- A Linux binary's `main` return flushes stdio through `exit(3)`, so piped output is no
  longer truncated at the buffer.
- A 64-bit multiply by a wide constant keeps its top bits on x86-64.

## Version 0.3 — two more backends, separate compilation, categories

This line took the toolchain from five backends to seven, still under the `xtc` name:

- **win64**: PE executables with full C interop (callbacks included), corpus-verified
  under Wine, with xcc's own PE writer.
- **wasm32**: `.wasm` plus a universal Node/browser loader, in-house WAT assembler and
  binary writer, with classes, ARC, protocols, i64 and floats complete.
- **Separate compilation**: `-c` objects carrying their interfaces, `-flto`
  whole-program re-optimisation, and `--emit-lib` shared libraries on arm9, arm64,
  x86_64 and win64, with the interface inside the binary.
- **Class categories**: extending a class from another module, with chain dispatch
  that survives subclass overrides across library boundaries.
- **Threading** on the native hosts: `Thread.spawn(&obj.method)`, `Mutex`, `Cond`,
  `Sem`, `Atomic`, `ThreadLocal`. ARC refcounts become atomic automatically in modules
  that use threads.
- **`i64`/`u64` on every target**, including the 8- and 16-bit ones, byte-identical
  through the self-hosted compiler.
- The **native toolchain is complete**: xcc's own assemblers and executable writers
  for every target. Falling back to an external toolchain requires an explicit opt-in.

## Version 0.2 — five backends, shared libraries, bound methods

A new version line. 0.12 was the last release of the AST code generator; **0.2** is the
first of the IR compiler, which replaces it. The old code generator is removed.

### Five backends, one IR

The compiler lowers to a single architecture-neutral IR and out through five live backends,
each passing the full fixture corpus:

| `-A` | Target | Output |
|---|---|---|
| `6502` *(default)* | banked **xt6502** — 4 KB hidden hardware stack, SP-relative addressing | banked 6502 executable (`.xex`), run under `xcc-sim-6502` |
| `arm64` | native macOS / Linux host | Mach-O / ELF executable |
| `arm9` | AArch32 / **XTOS** | ELF executable, or a `.so` |
| `m68k` | Motorola 680x0 | GEMDOS `.tos`, run under `xcc-sim-68k` |
| `x86_64` | Linux (musl) | ELF executable |

Standard-library classes resolve by **architecture × platform**, so one source serves all
of them.

The `xl` / `xe` flat and PORTB memory models, and the Commodore `c64` target, are
**retired**.

### Shared libraries — `--emit-lib` and `#import <Lib>`

On `arm9`, a program can be split into a library and its clients:

```bash
xcc -A arm9 --emit-lib -o libXtg.so xtg.xc
xcc -A arm9 -L . -o app.so app.xc
```

The library carries its **own interface inside the `.so`**, so `#import <Xtg>` type-checks
the client against the real binary, with no header to fall out of sync. Classes (with
inheritance and virtual dispatch back into a client subclass), protocols, structs by value,
enums (constants *and* type names), free functions, typedefs, `weak:` fields, bound methods,
and C types re-exported from *other* libraries all cross the boundary.

`#import <Foo>` also reads a plain **C** library's DWARF for its functions, types and enum
constants. Build the C library with `-fno-eliminate-unused-debug-types`, or gcc drops the
enum constants. See [Modules](/compiler/language/modules/).

### Protocols across a `.so`

A protocol method is identified by its **index within its own declaration**, and the
protocol by a hash of its **name**. Every module derives both identically with no
coordination, so two independently built libraries compose, and a class conforming to a
protocol from each dispatches correctly through both.

### Bound methods (`callback`) and optional protocol methods

`&obj.method` yields a storable, callable `{receiver, code}` value. A plain function or a
static method **widens** into the same type, so one `action` field accepts any of them. A
stored callback never owns its receiver and auto-zeroes when the receiver dies.

An `optional` protocol method may be left unimplemented, which leaves a **null slot**, so
testing a callback is equivalent to `respondsTo`:

```c
callback resized void(i32 w, i32 h) = &delegate.didResize;
if (resized) { resized(w, h); }
```

Together these support the delegate and target/action patterns.

### `extern` globals

Globals are scoped to the module they are compiled in. `extern u16 gCounter;` refers to one
defined elsewhere without reserving storage for a second copy, as an imported library's
globals require.

### `weak:` without a table

Weak slots are linked onto an **intrusive list** whose head lives in the referent's own
heap header. There is no capacity limit (the bounded side table and its `[weak] entries`
setting are removed), stores are O(1), and destroying an object with **no** weak references
costs one null test instead of a full table scan. A stored callback gets the same
auto-zeroing with nothing to declare.

### `final`

Removes a method from the vtable under `--emit-lib`, where whole-program devirtualisation
is unsound because the program is not whole.

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
