---
title: Optimisation
description: What -O0 through -O3 add, the tuning knobs (-Fli, -Flu), and how to read the optimiser's summary line.
---

xcc has four optimisation levels and two tuning knobs for the most expensive transforms (leaf inlining and loop unrolling). **The default is `-O3`.** It is the production level and the level the fixture corpus is validated at. The lower levels are debugging aids: use `-O0` when you want the generated code to follow the source line for line.

```bash
xcc -O3 game.xc -o game.xex
```

```
xcc: optimised -O3 (9877 → 9698 instructions)
```

The before/after instruction count is printed when any optimisation pass changed the code. Use it to check that a flag had the effect you expect.

## The four levels

### `-O0` — no optimisation

Straight code generation. Every variable gets a stable home, every expression evaluates left to right with intermediate stores, and every JSR / RTS pair is emitted. The output is **predictable**: it corresponds closely to the source, which makes single-stepping in `xcc-sim-6502` and reasoning about code paths easier. Use it during development and for asm debugging.

### `-O1` (`-O`) — peephole + register tracking

Two cheap, local transforms:

- **Peephole.** Adjacent instruction patterns are replaced with shorter equivalents. For example, `LDA #0; STA x` followed by `LDA x` collapses, and `LDX foo; CPX #0` collapses to a flag-set form. All changes are local and can be inspected in the listing.
- **Register tracking.** The code generator models A / X / Y across instructions, so a value already in the right register is not reloaded.

Compile time is about the same as `-O0`, so there is little reason to ship below `-O1`.

### `-O2` — the heavy lifters

Adds, on top of `-O1`:

- **Constant propagation**: replace reads of compile-time-known values with the immediate value.
- **Dead code elimination**: drop blocks that are statically unreachable.
- **Dead store elimination**: drop writes to a variable whose later reads can be proven to come from a later write.
- **Tail-call optimisation**: convert a `JSR` immediately followed by `RTS` into a `JMP`, saving a hardware-stack slot per recursion depth.
- **Leaf-function inlining**: expand small leaf functions at the call site instead of emitting a `JSR`. Tunable via [`-Fli`](#-fli--leaf-inline-cap).
- **Loop unrolling**: unroll `for` loops with small constant trip counts. Tunable via [`-Flu`](#-flu--loop-unroll-cap).

`-O2` is the recommended baseline for shipped programs.

### `-O3` — aggressive (the default)

Adds, on top of `-O2`:

- **Branch inversion**: flip a comparison and its branch when that produces shorter code (for example, to avoid a `JMP` past a body).
- **Branch threading**: when a branch targets an unconditional branch, retarget the original branch to the final destination.
- **Strength reduction**: replace expensive operations with cheaper ones. Multiplying by a power of two becomes a shift, a constant divide becomes a multiply-and-shift, and array index multiplication folds when the element size is a power of two.
- **Cross-function DCE**: remove functions that are statically never reached. The reachability analysis traces every call edge in the program.
- **Label cleanup**: collapse redundant labels and remove labels that nothing branches to.

`-O3` produces smaller and faster binaries for most programs, but the code is further from the source. Set breakpoints by line number rather than by reading the listing.

## Tuning knobs

### `-Fli` — leaf inline cap

```bash
xcc -O2 -Fli 200 app.xc -o app.xex
```

Maximum leaf-function size, **in 6502 instructions**, that the inliner expands at a call site. Default: 100. Requires `-O2` or higher.

A leaf function calls no other functions. The inliner targets leaf functions because the inlined copy needs no frame, does not touch the stack, and folds completely into the caller. A larger cap inlines more, which lowers cycle counts and raises byte counts. Lower it if the binary is close to a memory budget.

### `-Flu` — loop-unroll cap

```bash
xcc -O2 -Flu 16 app.xc -o app.xex
```

Auto-unroll counted `for` loops whose trip count is **≤ `<n>`** at compile time. Default: 5 at `-O2` and above, 0 below. Set to 0 to disable.

The threshold trades binary size for cycle count. A loop with 12 iterations unrolls into 12 copies of the body. The loop overhead (compare / branch / step) disappears, but the body's code bytes are multiplied by 12. The default of 5 handles small loops without growing the binary much.

To unroll a specific loop regardless of the cap, use the `:unroll` annotation. See [Statements & control flow → Manual unrolling](/compiler/language/statements/#manual-unrolling-unroll).

## How to read "9877 → 9698 instructions"

The summary line shows the **6502-instruction** count before and after the optimiser ran on the program's intermediate representation. It approximates binary size: most 6502 instructions are 2 or 3 bytes, so the byte-count change tracks the instruction-count change closely.

A small change at `-O2` or `-O3` does not mean the optimiser did nothing. Register tracking and peephole at `-O1` may have done most of the work, leaving little for the higher levels. A program that is already tight at `-O1` often gains ≤2 % at `-O3`; a program with redundant loads and unreachable branches can shrink 15–20 %.

## Choosing a level

| When | Pick |
|------|------|
| Active development / asm-level debugging | `-O0` |
| CI builds, smoke tests | `-O1` |
| Default ship build | `-O2` |
| Small-binary / cycle-critical | `-O3` (and consider raising `-Fli` cautiously) |
| Profiling / measuring real overhead | match the ship build (`-O2` or `-O3`); `-O0` numbers don't predict shipped behaviour |

## Caveat: `volatile` and inline assembly

The optimiser respects `volatile`: every access to a `volatile` variable emits its read or write. Put hardware register pokes in `volatile` slots so that `-O2` dead-store elimination does not remove them.

`asm { ... }` blocks are opaque to the optimiser. The compiler saves and restores the registers it thinks the block touches (override this with `clobbers`; see [Inline assembly](/compiler/language/inline-asm/)) and treats the block as a memory barrier: values held in compiler-tracked registers are flushed to memory before the block runs and reloaded after.
