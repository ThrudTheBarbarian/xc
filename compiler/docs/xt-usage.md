# xt memory model: usage summary

## Overview

xt is xtc's bank-switched target for Atari 8-bit hardware. It has a flat system region plus three independent bank windows in the $4000-$7FFF aperture:

- `$82` selects an 8 KB code page at $4000-$5FFF (region A, ~2 MB addressable).
- `$83` selects a 4 KB data page at $6000-$6FFF (region B, ~2 MB addressable).
- `$84`/`$85` is a 16-bit selector pair that picks a 4 KB page at $7000-$7FFF (region C). Region C scales with the HyperRAM size: 4 MB on 8 MB, 12 MB on 16 MB, 28 MB on 32 MB.

Code, region B and region C are paged independently, so switching the data bank for a heap access does not swap the caller's code page out from under the instruction fetcher. xe's single PORTB-driven 16 KB window needs a trampoline round trip for every move between code and data; xt's three-register split avoids that cost.

First-fit bank-page packing (XTBankPageTracker) lets classes and free functions share pages in each pool independently.

## Memory map

```
$2000  System region (8 KB)     startup, stubs, class descriptors,
                                string literals, spilled globals
$2000  stack_low → SP at $89/$8A, grows upward
       ↓ HP at $8D/$8E, grows downward
$3FFF  heap_top
$4000  Code bank ($82,  8 KB)   first-fit packed classes + functions
$5FFF
$6000  Data bank ($83,  4 KB)   region B — banked globals, heap
$6FFF
$7000  Region C ($84/$85, 4 KB) HyperRAM beyond $82+$83's 3 MB reach
                                 (5 MB default on 8 MB HyperRAM)
$7FFF
$8000  Screen RAM                SAVMSC points here
$9FFF
$A000  Main code (8 KB)          main(), xcall stubs, runtime routines,
                                 heap allocator
$BFFF
$C000  OS ROM / I/O              GTIA, POKEY, ANTIC, PIA, ROM
$FFFF
```

## ZP layout

| Range   | Use |
|---------|-----|
| $82/$83 | Code / region-B bank selectors (8-bit each) |
| $84/$85 | Region-C 16-bit selector pair (lo / hi byte, little-endian). Reserved only when sema finds reachable region-C use; otherwise free for user variables |
| $86-$88 | Free |
| $89/$8A | Xtc stack pointer (SP) |
| $8B/$8C | Scratch tmp |
| $8D/$8E | Heap pointer (HP) |
| $8F-$9F | User vars |
| $A0-$AF | Hardware-banked ZP slice (16 bytes per code bank, swapped by $82) |
| $B0-$BF | Runtime params / register-result slot (small-struct return, float) |
| $C0-$CF | Hardware-banked ZP slice (16 bytes per code bank, swapped by $82) |
| $D0-$DF | Hardware-banked ZP slice (16 bytes per code bank, swapped by $82) |
| $E0-$FF | User vars (unbanked) |

## Calling convention

- `$82` is the code bank. The `_xcall` trampoline saves and restores it around cross-bank calls.
- `$83` is a live region-B selector. Code writes `$83` freely to page through data banks. A function that writes `$83` saves it in its prologue and restores it in its epilogue (callee-saves), so banking stays transparent to user code.
- `$84`/`$85` is region C's 16-bit selector, saved and restored as a pair under the same callee-saves rule. It is reserved only when needed; see "Pay-for-what-you-use" below.

## Pay-for-what-you-use (region C)

A program whose call graph never reaches region C pays nothing for it. The compiler tracks this automatically; there is no user-facing annotation. XTSemanticAnalyzer maintains two sets:

- `regionCLocallyUsing`: functions whose own body touches region C. The body writes $84/$85 from emitted code, allocates a global or heap object that lands in region C, contains an inline-asm block referencing $84 or $85, or calls a runtime helper known to clobber the pair.
- `regionCUsing`: the transitive closure of `regionCLocallyUsing` over `_callEdges`.

The per-function set decides which functions get prologue/epilogue brackets. The program-wide union decides whether $84/$85 are reserved in ZP, whether the region-C variant of heap.asm is linked, and the shape of the `_xcall` trampoline. A fixture that never lands in region C produces an XEX byte-identical to one built for a layout without the region-C machinery.

## Region C span declaration

`.lnk` files declare `regionSpan` in bytes for region C, sized so that region C covers everything $82 (2 MB) and $83 (1 MB) cannot reach:

| HyperRAM | regCRegion  | Region C       |
|----------|-------------|----------------|
| 8 MB     | `$500000`   | 5 MB (default) |
| 16 MB    | `$D00000`   | 13 MB          |
| 32 MB    | `$1D00000`  | 29 MB          |

The theoretical ceiling is a 16-bit selector × 4 KB pages = 256 MB, well beyond any plausible HyperRAM size. When HyperRAM grows, only the regCRegion value changes; code generation scales automatically.

## Cross-bank calls

All inter-bank calls go through the shared `_xcall` trampoline in the main region. The XEX writer uses preload-stub INITAD segments to load each bank page directly into its window, with no staging area. Code-bank stubs target $82 ($4000-$5FFF), region-B stubs target $83 ($6000-$6FFF), and region-C stubs write the 16-bit pair $84/$85 ($7000-$7FFF).

## Layout files

| File                 | Layout |
|----------------------|--------|
| `xt.lnk`             | Base layout: bump-allocated heap in the system region |
| `xt-heap.lnk`        | Data-pool free-list heap (banks 1-4, 16 KB) |
| `xt-shadow.lnk`      | Shadow ROM, giving a ~22 KB main code region |
| `xt-shadow-heap.lnk` | Both: the "maximum xt" shape |

## Usage

```
./bin/osx/xcc input.xc -o output.xex -m xt
./bin/osx/xcc-as input.asm -o output.xex -b    # -b = banked
./bin/osx/xcc-sim-6502 -m xt output.xex              # simulator
```

## Patterns

- Pointers: the 3-byte banked form (lo, hi, bank) when pointing into a bank window; the plain 2-byte form for main-region objects. Pointer types use @.
- Strings and literals: placed in the system region so they are always mapped.
- Heap: grows downward from $3FFF in the system region (`xt.lnk`), or lives in data-pool banks 1-4 (`xt-heap.lnk` / `xt-shadow-heap.lnk`). Region C takes the overflow when the data pool fills.
- ARC: banked-heap ARC works end to end on xt-heap.
- `-Q loop`: recommended for non-trivial programs. A plain main_entry RTS can fall into disabled-ROM regions on some configurations.

## Hardware notes

The xt target is a modern redesign of the Atari 8-bit, not a period machine. It has a ~21 MHz bus (≈12× the original) and 8 MB of HyperRAM with a ~400 KB on-chip page cache (LRU eviction, a 2-3 clock stall on a miss). Banking is transparent to user code. Three bank registers expose three windows in the 6502 address space, all within the existing $4000-$7FFF aperture, so the bank window does not need to grow.

## Caveats

- Function code is limited to 8 KB, the code-window size. The packer raises an error if a banked unit overflows.
- Banked globals or heap blocks larger than 4 KB do not fit in a single data page. They must be split, or moved to region C (when the packer's fallover places them there) or back to the code pool.
- 16-bit selector order: $84 is the low byte and $85 the high byte, matching the 6502's little-endian convention.
