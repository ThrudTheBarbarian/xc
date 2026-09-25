---
title: Optimisation
description: What -O0 through -O3 do, the -Flu unroll cap, which targets vectorise, and how loops are aligned on x86-64.
---

xcc has four optimisation levels. **The default is `-O3`.** It is the production level and the level the fixture corpus is validated at. The lower levels are debugging aids: use `-O0` when you want the generated code to follow the source line for line.

```bash
xcc -O0 -o game game.xc
```

Optimisation happens on the compiler's intermediate representation, before code generation, so the same passes run for every target. What differs per target is a profile of limits and switches, described [below](#per-target-settings).

## The four levels

### `-O0`: no optimisation

Straight code generation. Every variable gets a stable home and every expression is evaluated as written. The output corresponds closely to the source, which makes single-stepping and reasoning about code paths easier.

### `-O1`: unreachable functions removed

Functions that nothing calls are dropped from the program. The code inside each function is left as `-O0` produces it.

### `-O2`: the optimiser

The full pass pipeline, including:

- **Inlining** of small functions at their call sites.
- **Constant folding** and **dead-code elimination**.
- **If-conversion**: a short diamond becomes a select instead of a branch.
- **Jump threading** and **tail-recursion elimination**.
- **Promotion to registers**: locals and struct fields that do not need a memory home are kept in SSA values.
- **Loop unrolling**: counted loops with a small constant trip count are unrolled fully. See [`-Flu`](#-flu--loop-unroll-cap).
- **Vectorisation** of simple loops on the targets that support it.
- **Strength reduction**, **loop-invariant code motion** and **loop rotation**.
- **Block layout**, so the hot path falls through.

### `-O3`: the default

Currently the same pipeline as `-O2`. It is kept as a separate level so that transforms that trade size for speed have a place to go.

## `-Flu` — loop-unroll cap

```bash
xcc -Flu 8 -o app app.xc
```

Fully unroll counted loops whose trip count is known at compile time and is at most `<n>`. The unroller runs at `-O2` and above. Set `-Flu 0` to disable it. Without the flag each target uses its own cap:

| Target | Default cap |
|---|---|
| `xt6502` | 4 |
| `wasm32` | 8 |
| `m68k`, `arm9` | 16 |
| `arm64`, `x86_64`, `win64` | 32 |

The cap trades binary size for cycle count. A loop with 12 iterations unrolls into 12 copies of the body: the compare, branch and step disappear, and the body's code is multiplied by 12. A separate limit on body size keeps a large body from being unrolled even when the trip count fits.

To unroll a specific loop past the cap, use the `:unroll` annotation. See [Statements & control flow → Manual unrolling](/compiler/language/statements/#manual-unrolling-unroll).

`-Fli <n>` sets the leaf-function inlining cap (default 100, at `-O2` and above). See the [CLI flag reference](/compiler/usage/cli/#optimisation).

## `-Fmb` — small functions in main RAM (xt6502)

```bash
xcc -m xt -Fmb 50 -o app.xex app.xc
```

On the banked `xt` layout every function except the entry point and the interrupt handlers goes into a 16 KB code bank. A call into another bank goes through the `_xcall` trampoline, which saves the code-bank register, selects the callee's bank and restores the register on return. For a function of a few instructions the trampoline costs more than the body.

`-Fmb <n>` keeps a function of fewer than `n` instructions in main RAM. Every call to it is a plain `JSR`, from main RAM or from any bank. The count is of the function's own 6502 instructions, prologue and epilogue included. The default, 0, keeps nothing back.

Main RAM also holds the runtime and the program's data. If the functions kept there do not fit, the assembler reports the overflow; lower `n`. `-dp` lists where each function went and `-du` the bytes each region holds. See [the CLI reference](/compiler/usage/cli/#support-tree-and-memory-model).

## Per-target settings

| Target | Vectorises loops | Unrolls loops with a run-time trip count |
|---|---|---|
| `arm64` | yes (NEON) | yes |
| `x86_64`, `win64` | yes (SSE) | yes |
| `arm9` | yes (NEON) | yes |
| `wasm32` | yes (SIMD128) | yes |
| `m68k` | no | no |
| `xt6502` | no | no |

A loop whose trip count is only known at run time is unrolled four times, with each copy of the body checking the exit condition, so no separate remainder loop is needed.

On `x86_64` and `win64` the head of every loop is aligned to a 32-byte boundary. On `x86_64` the ELF `.text` section starts on a 64-byte boundary, so the alignment holds in the linked program and a loop's position within the processor's fetch window does not depend on how much code precedes it.

## Choosing a level

| When | Pick |
|------|------|
| Active development / single-stepping | `-O0` |
| Debugging with smaller binaries | `-O1` |
| Shipped builds | `-O3` (the default) |
| Profiling / measuring real overhead | the ship build; `-O0` numbers don't predict shipped behaviour |

## Caveat: `volatile` and inline assembly

The optimiser respects `volatile`: every access to a `volatile` variable emits its read or write. Put hardware register pokes in `volatile` slots so that `-O2` dead-store elimination does not remove them.

`asm { ... }` blocks are opaque to the optimiser. The compiler saves and restores the registers it thinks the block touches (override this with `clobbers`; see [Inline assembly](/compiler/language/inline-asm/)) and treats the block as a memory barrier: values held in compiler-tracked registers are flushed to memory before the block runs and reloaded after.
