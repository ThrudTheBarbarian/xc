# Using the xcc compiler

`xcc` compiles the xtc language, a C-like language described in
[doc/LANGUAGE-SPEC.md](doc/LANGUAGE-SPEC.md) and at <https://compile-xc.org>,
to one of seven backends:

| Architecture | Selector          | Output                                   | Run with              |
|--------------|-------------------|------------------------------------------|-----------------------|
| **arm64**    | `-A arm64`        | native Mach-O executable / `.dylib`      | run it directly       |
| **x86_64**   | `-A x86_64`       | native Linux ELF over musl (exe / `.so`) | run it directly       |
| **win64**    | `-A win64`        | native Windows PE (`.exe` / DLL)         | run it (Windows/wine) |
| **arm9**     | `-A arm9`         | AArch32 PIC ELF (exe / `.so`)            | qemu / loader         |
| **m68k**     | `-A m68k`/`68030` | Atari ST/TT GEMDOS `.prg` (68000/68030)  | `xcc-sim-68k`         |
| **wasm32**   | `-A wasm32`       | WebAssembly (`.wasm` / WAT)              | Node.js / browser     |
| **xt6502**   | `-A 6502` / `-m xt6502` | banked XEX binary (`.xex`)          | `xcc-sim-6502`        |

`-A` picks the target; with none, the native host is the default. All seven
back ends are self-hosting (the compiler exists a second time in the xtc
language, byte-identical at every stage).

## Which of those the SHIPPED compiler drives

The table above is the whole toolchain. The binary you install as `xcc` is the
**xc-built** compiler, the one written in the xtc language, and it drives
every target end to end. It is the only compiler that ships.

| Target | Shipped `xcc` | Notes |
|---|---|---|
| `arm64`  | **yes** | the host; the compiler builds itself with it |
| `x86_64` | **yes** | static ELF over real musl, no vendor toolchain. 382/382 fixtures verified by EXECUTING them on x86-64 Linux |
| `xt6502` | **yes** | 405/405 in the corpus sweep |
| `android`| **yes** | arm64 back end, Android ABI and link |
| `m68k`   | **yes** | GEMDOS `.prg` |
| `wasm32` | **yes** | `.wasm` + loader |
| `win64`  | **yes** | PE32+ console executable, in-house COFF writer and linker |
| `arm9`   | **yes** | ELF ARM EABI5; no `arm-none-eabi-gcc` or other external toolchain |
| `ios`    | **yes** | Mach-O arm64 with in-house bundle + signing |

Every row above was checked by building with the installed `xcc` for that
target and inspecting the output. `xcc-bootstrap` sits beside it as the
Objective-C compiler that built it, and never ships.

The compiler always runs the IR pipeline (parse → sema → IR-lower → verify →
backend). `--with-ir` is accepted and ignored. Internally `xcc` is a thin
dispatcher that spawns `xcc-fe` (front end → IR text), `xcc-cg-<arch>`
(IR → asm) and, for the linked targets, `xcc-ln-<arch>`. The native links are
done **in-house, with no clang** (6502 links through `xcc-as`, m68k emits the
GEMDOS executable directly).

Build the toolchain first:

```bash
make            # builds bin/<platform>/xcc and the xcc-* tools
make install    # installs to /opt/xcc/<version>  (override with PREFIX=)
```

(On macOS the binaries land in `bin/osx/`; on Linux, `bin/linux/`.)

---

## arm64 (native host)

Compile straight to a runnable executable:

```bash
xcc test.xc -O2 -A arm64 -o test
./test
```

Stop at assembly (e.g. to inspect codegen):

```bash
xcc test.xc -O2 -A arm64 -o test.s     # any .s output path → assembly only
```

When the `-o` path does **not** end in `.s`, `xcc` assembles and links a native
executable in-house (`xcc-ln-arm64`, no clang). The arm64 backend ignores `-m`
(no memory model is loaded); libraries resolve from `support/arm64/lib/` with a
small host runtime in `support/arm64/runtime/libxt.c`.

---

## wasm32 (Node.js + browser)

Compile to a WebAssembly module plus a universal JS loader:

```bash
xcc test.xc -O2 -A wasm32 -o test
node test.js                        # Node
# or serve test.js + test.wasm and add <script src="test.js"></script>
```

The output is `test.wasm` (built by the in-house `xcc-ln-wasm32`, no external
tools) and `test.js`, one loader that runs under Node (CommonJS) and in a
browser. The loader provides the `env` host surface (stdout, time, math, rand);
in a browser, output goes to `globalThis.xccOut` (or `console.log`). After
instantiation the module is reachable as `globalThis.xcc.instance` /
`globalThis.xcc.memory`.

A starter `test.html` (stdout into a `<pre>` via `xccOut`) is written **only
if absent**. The page is yours to edit: rebuilds regenerate the `.js` and
`.wasm` but never touch an existing `.html`.

**Exports and host imports**: `extern` on a
*definition* exports it — it survives dead-function elimination and appears in
`instance.exports` (globals export their linear-memory address as an immutable
i32 global). `extern` on a bodyless declaration is an import, and
`#package <name>` sets the wasm import namespace for the externs that follow
(default `env`):

```c
extern i32 addTwo(i32 a, i32 b) { return a + b; }   // JS: xcc.instance.exports.addTwo(2, 3)
extern i32 counter = 42;                            // JS: read memory at exports.counter.value

#package js
extern void jsPing(i32 v);                          // imported from "js"."jsPing"
```

Supply non-`env` packages (and `env` overrides) by setting
`globalThis.xccImports = { js: { jsPing: v => ... } }` **before** the loader
script runs. `#package` is wasm32-only and a hard error elsewhere.

**Worker run loop** (for programs whose `main()` blocks — GUI event loops):
set `globalThis.xccConfig = { runLoop: "worker", workerScript: "driver.js" }`
before the script tag. The page's main thread then only feeds a
`SharedArrayBuffer` event ring (mouse/key events from the `#xcc-canvas`
element, or anything via `globalThis.xccPushEvent(type, a, ...)`). The module
runs, and may block, in a Web Worker, waking via `Atomics.wait` through the
`env` primitives `_xt_ring_wait` / `_xt_ring_read` / `_xt_req_block`. The
module's own memory stays non-shared. `workerScript` runs inside the Worker
(page globals are not visible there) to define `xccImports`, for example a
drawing package over the transferred `OffscreenCanvas` (`globalThis.xccCanvas`).
Requires COOP/COEP response headers for the SAB; `examples/wasm32/worker-spike/`
is a complete click-to-draw example with a header-setting `serve.py`.

**Target-specific options** use one spelling across architectures:
`-x-<arch>,<option>[,<option>…]`. Options for an arch other than the one being
compiled are validated and ignored, so one flag set can serve a multi-target
build script. Unknown options are a hard error naming the arch. Currently:

| arch | option | effect |
|------|--------|--------|
| `wasm32` | `return-call` | emit wasm tail calls (`return_call` / `return_call_indirect`) for calls in tail position, so mutual and indirect tail recursion stop consuming stack. Off by default for maximum engine portability; the instructions are standardised and shipped in current V8 / SpiderMonkey / JavaScriptCore (Node ≥ 18 works). |

---

## xt6502 (banked 6502)

Compile to a banked XEX binary and run it in the simulator:

```bash
xcc test.xc -O2 -m xt6502/xt -o test.xex
xcc-sim-6502 test.xex                            # 6502 simulator
xcc-sim-6502 -d test.xex                         # with instruction trace
```

Stop at 6502 assembly:

```bash
xcc test.xc -m xt6502/xt -o test.asm    # .asm output → assembly only
```

Available xt6502 layouts (`--list-layouts` shows all):

| Layout            | Notes                                          |
|-------------------|------------------------------------------------|
| `xt6502/xt`       | the standard banked target                     |
| `xt6502/xt-heap`  | on-demand banked heap (`[heap] bank = true`)   |

The standalone assembler `xcc-as` can also turn a hand-written `.asm` into an
XEX (`xcc-as foo.asm -o foo.xex -b` for banked output).

---

## A minimal program

```c
#import "Stdio.xc"

i32 main()
((
    i32 sum = 0;
    for (i32 i = 0; i < 10; i = i + 1) ((
        sum = sum + i;
    ))
    Stdio.printf("sum=%ld\n", sum);     // %ld = 32-bit, %d = 16-bit
    return 0;
))
```

```bash
xcc sum.xc -O2 -A arm64 -o sum && ./sum            # → sum=45
xcc sum.xc -O2 -m xt6502/xt -o sum.xex && xcc-sim-6502 sum.xex
```

---

## Common options

| Option                | Meaning                                                        |
|-----------------------|----------------------------------------------------------------|
| `-O0 … -O3`           | optimisation level (`-O3` is the default)                      |
| `-A <target>`         | arm64, x86_64, win64, arm9, m68k, wasm32, xt6502, android, ios. With no `-A` the HOST is the default, as `cc` does |
| `-m <platform>/<layout>` | memory layout for 6502 targets (e.g. `xt6502/xt`)           |
| `-o <path>`           | output file; extension decides the format (`.s`/`.asm` = asm)  |
| `-I <path>`           | add an include search path                                     |
| `-D name[=value]`     | define a preprocessor symbol                                   |
| `-falloc=bump\|heap`  | heap allocator (default `heap` where a heap region exists)     |
| `-farc[=on\|off]`     | automatic reference counting (`retain`/`release`)              |
| `-fthread-safe-arc`   | atomic ARC refcounts (default: on iff the program spawns a thread) |
| `-fno-thread-safe-arc`| force plain, non-atomic ARC refcounts                          |
| `-Flu <n>`            | auto-unroll counted loops with trip count ≤ n (default 5 @ -O2)|
| `-fbounds-check`      | checked build: trap out-of-range subscripts (native targets)    |
| `--list-layouts`      | list built-in memory layouts by platform                       |
| `-dl` / `-dp` / `-du` | dump memory map / function placement / segment usage           |
| `-V`                  | print resolved `XTC_HOME` and include search paths             |
| `-v`                  | print version                                                  |
| `-Wno-<category>`     | suppress a warning category (see below)                        |

Warning categories for `-Wno-`: `escape`, `class-init`, `asm-clobbers`,
`unknown-annotation`, `unknown-pragma`, `printf-format`, `unowned-bound`,
`cloaked-transitive`, `unreachable-catch`, `comment`, `packed-align`,
`range-init-count`, `covariant-return`, `unguarded-action`,
`toolchain-fallback`. An unknown category is itself a warning, never an error,
so a mistyped suppression does not stop a compile. Both compilers accept these.

`xcc --help` lists the full set, including the function-placement annotations
(`:banked`, `:main`, `:shadow`, `:irq`, `:vbi`) and the debug environment
variables.

---

## Checked builds (`-fbounds-check`)

A debug-time build that catches an out-of-range subscript at the moment it
happens, instead of letting it corrupt something and fail somewhere else:

```bash
xcc -fbounds-check -o prog prog.xc
```

Every subscript is checked against the allocation's own header, so the bound
is the real one. On a failure the program prints where it was, what it asked
for, what was there, and how it got there:

```
=== xcc: out-of-bounds access ===
  at vary.xc:2:46
  array: index 6, but the allocation holds 3 elements of 4 bytes
  stack:
    #0  _xt_check_bounds +356
    #1  inner +52
         args: arg0=0x158e04626 arg1=6 arg2=117
    #2  mid +44
         args: arg0=0x158e04626 arg1=6 arg2=117
    #3  main +204
    #4  xtc_start +16
  aborting
```

Function names come from the binary's own symbol table and argument values
from walking the frame chain, so **nothing has to be built or shipped
alongside the binary**: no `.dSYM`, no sidecar table, no separate runtime
library. An argument the walk cannot recover prints `<in a register, not
recovered>` rather than a plausible wrong number.

Build a checked program at **`-O0` or `-O1`** if you want the fullest trace.
The checks themselves are emitted at every level and catch the same errors,
but inlining collapses the frames that name them: the run above at the default
`-O3` reports the same error at the same source position with `inner` and
`mid` folded into `main`.

On a terminal it offers `c` to continue; with stdin redirected it aborts, so
a checked build in a script fails the script.

**Native targets only, which currently means arm64.** On any other target
`-fbounds-check` is a hard error rather than a flag that quietly does nothing.
An ordinary build is unaffected: no checks are emitted and none of this
machinery is linked.

---

## Library resolution

For a given target, includes resolve in this order:

1. `-I` paths (in order)
2. `support/<platform>/lib/` — `arm64` for the arm64 backend, the memory
   model's platform (`xt6502`) for 6502 targets
3. `support/generic/lib/` — architecture-neutral classes (e.g. `Assert.xc`)

So `#import "Stdio.xc"` picks the arm64 or xt6502 implementation automatically
depending on which backend you compiled for.

---

## Notes

- With neither `-A` nor `-m`, `xcc` targets the host.
- `XTC_HOME` (or `-H`) overrides where `support/` is found; otherwise it is
  found relative to the `xcc` binary first (so an install needs no flag at
  all), then `-H` / `$XCC_HOME`, the cwd, and the well-known install roots.
  The tree is `lib/xc` in an install and `support/` in the source tree; both
  spellings are accepted.
- `printf`-family format width contract in xcc: `%d` is 16-bit, `%ld` is 32-bit.
- **Threads** (`#import "Thread.xc"`, plus `Mutex`/`Cond`/`Sem`/`Atomic`/
  `ThreadLocal`/`Pool`) are available on the native hosts. Spawning one turns
  atomic ARC on automatically (see
  <https://compile-xc.org/compiler/language/threading/>). On xt6502 and m68k
  importing those files is a compile-time error rather than a silently
  sequential "thread".
- There is **no clang fallback**. If the in-house assembler or linker cannot
  build something, that is an error naming the failing instruction, not a quiet
  retry with clang. A silent fallback would produce a working binary while
  hiding a gap in the in-house toolchain. Set `XTC_ALLOW_CLANG_FALLBACK=1` to
  allow the clang retry if you need to work around a gap.
