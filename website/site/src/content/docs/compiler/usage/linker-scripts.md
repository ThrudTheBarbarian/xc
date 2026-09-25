---
title: Linker scripts (.lnk)
description: The .lnk format that defines a memory model, with sections, address syntax, banking and shadow specs, and how to write your own.
---

A **linker script** (`.lnk`) is a UTF-8 text file that describes a complete target layout: zero-page reservations, address spaces, banking mechanism (if any), shadow-mode configuration, stack and heap placement, and the startup hook. Each shipped memory model (`xt`, `xt-heap`) is a `.lnk` file under `support/xt6502/layouts/`.

:::note[The format is broader than the shipped layouts]
The `.lnk` parser understands the `[shadow]` and `[cloaked]` sections described below, but **no shipped layout uses them**. They are documented because the format supports them and a custom layout may use them. The `xt6502` target reaches its extra RAM through the two bank windows instead.
:::

```bash
xcc-bootstrap -m ./my-layout.lnk app.xc -o app.xex   # use a custom layout
xcc-bootstrap -m xt app.xc -o app.xex                # use a shipped layout by name
xcc-bootstrap --dump-layout -m xt                    # print a layout's diagram
```

`xcc` always builds 6502 programs against the standard `xt` layout. Loading any
other layout, and the `--list-layouts` and `--dump-layout` flags, need `xcc-bootstrap`, which
is installed beside it (see [CLI → Two drivers](/compiler/usage/cli/#two-drivers)).

To support custom hardware (cartridge slots, non-stock RAM expansions, smaller or larger screen areas), write a `.lnk` file and pass it. The compiler does not need changes.

## Format overview

INI-style sections, `key = value` entries, `#` comments to end of line.

```ini
# A trimmed example
[zp]
sp       = $82-$83        # stack pointer (2-byte pair)
tmp      = $84-$85
hp       = $86-$87
vars     = $88-$AF, $BC-$FF
runtime  = $B0-$BB

[memory]
main     = $2000-$9FFF

[stack]
range    = after-code

[heap]
range    = before-screen
```

### Value syntax

| Form | Meaning |
|------|---------|
| `$XXXX` | hex address (16-bit) |
| `1234`, `42` | decimal |
| `$XXXX-$YYYY` | inclusive address range |
| `$XXXX:$MM` | hardware register at `$XXXX` with bitmask `$MM` |
| `after-code`, `after-system`, `before-screen` | symbolic — linker resolves after layout |
| `key1 = a, b, c` | comma-separated list |
| `true` / `false` | booleans |

**Disambiguation rule:** `-` always means an address range, and `:` always means a bitmask on a hardware register. Bitmask values are always hex-prefixed (`$XX`). There is no address:size notation; use a range. A single 2-byte ZP pair is also written as a range (`$82-$83`).

## Sections

### `[zp]` — zero-page layout

Names the ZP slots that the code generator and runtime depend on. Every entry is a range, even for a 2-byte slot.

```ini
[zp]
sp       = $82-$83        # stack pointer (2 bytes)
tmp      = $84-$85        # scratch pair
hp       = $86-$87        # heap pointer (2 bytes)
vars     = $88-$AF, $BC-$FF     # allocatable user-var region(s)
runtime  = $B0-$BB        # reserved for runtime params
```

Named entries (`sp`, `tmp`, `hp`, `runtime`) are fixed reservations that the code generator references by name. `vars` declares the runs the ZP allocator draws from.

On banked targets, additional entries appear:

```ini
# xt has no ZP bank register: its selectors are memory-mapped ($D5C0/$D5C1, in [banking]).
```

### `[memory]` — address-space regions

Named regions, given as comma-separated address ranges. The linker packs code and data into the `main` region, first-fit across all listed runs.

```ini
[memory]
main     = $2000-$9FFF
screen   = $8000-$9FFF
```

Multi-run main regions (shadow mode):

```ini
[memory]
main     = $A000-$BFFF, $C000-$CFFF, $D800-$FFF9
system   = $2000-$3FFF
screen   = $8000-$9FFF
```

The linker treats each comma-separated range as an independent run. A function is packed within a single run and never straddles a gap. Overflow spills to banked pages if banking is configured, and is reported as an error otherwise.

### `[banking]` — bank-switched memory

Describes the hardware banking mechanism: which registers control bank selection, which address range is the bank window, and how large each page is. The code generator derives the bank-select instruction sequence from these entries.

```ini
# xt — two independent bank windows, each selected by a memory-mapped register.
# This is the shipped layout (support/xt6502/layouts/xt.lnk).
[banking]
code-window = $6000-$9FFF   # 16 KB code page; 256 pages -> 4 MB of code
code-reg    = $D5C0         # code-bank select register (memory-mapped)
data-window = $A000-$CFFF   # 12 KB data page; 256 pages -> 3 MB of data
data-reg    = $D5C1         # data-bank select register (memory-mapped)
```

The two windows are independent. Code is paged through `$6000-$9FFF` via `$D5C0` and is never placed in the data window. Data is paged through `$A000-$CFFF` via `$D5C1`. Both selectors are memory-mapped hardware registers, not zero-page locations. The parser also accepts the single-window and bit-masked forms (zero-page `$82/$83` or PORTB `$D301` selectors) used by the Atari `xe`/`rambo256` models, but no shipped layout uses them.

Bit-mask layouts that need a non-contiguous set of bits use the union of the bits (for example, `$4C` = `$0C | $40` for bits 2-3 plus bit 6). The code generator builds the deposit pattern from the mask, so you specify only the bits.

### `[shadow]` — ROM-disable configuration

Describes how to switch the OS ROM out and back in for shadow targets:

```ini
[shadow]
register = $D301:$01      # PORTB bit 0 controls OS ROM
charsetCopy = $E000       # source address of the charset to copy
```

The `:needsOS` function annotation makes the runtime wrap each call to the flagged function in a save / disable / call / restore sequence.

### `[cloaked]` — code regions for `:cloaked` decls

Each `[cloaked]` block declares one region of the bank window where source-level `:cloaked` code can live. A layout may have several `[cloaked]` blocks. Together they form a pool that auto-cloak's overflow ladder spills through.

```ini
# Banking-off region — code lives in main RAM at $4000-$7FFF and the
# call site sets PORTB to expose it.
[cloaked]
range = $4000-$7FFF
bank  = none
id    = lib

# Numbered-bank region — code loads into bank 2's image of the
# window; the call site sets PORTB to select bank 2.
[cloaked]
range = $4000-$7FFF
bank  = 2
id    = ext1
```

`range` is the address span the region occupies inside the bank window. `bank` is `none` for a banking-off region (PORTB bit 4 = 1), or a decimal bank index for a numbered region; the code generator emits the matching PORTB bracket per region. `id` is the name used by source-level annotations (`:cloaked(<id>)`). Plain `:cloaked` (no id) packs into the first declared region.

#### Pool form: `bank = N-M` + `id = <prefix><n>`

Layouts with many available banks can declare a pool in one block:

```ini
[cloaked]
range = $4000-$7FFF
bank  = 4-12
id    = ext<n>
```

The `<n>` placeholder is required in the `id` template and is replaced with each bank's index. The example above expands to nine regions: `ext4`, `ext5`, …, `ext12`. Each is selectable from source as `:cloaked(ext7)` and so on, and on overflow the auto-spill ladder walks them in declaration order.

Validation rejects:

- a range form without `<n>` in the id (the expansion would yield duplicate ids),
- a single-bank form with `<n>` in the id (the placeholder has nothing to bind to),
- duplicate ids across all `[cloaked]` blocks in the file (a `:cloaked(<id>)` annotation would be ambiguous).

Each region's bank is also reserved with the page tracker, so `:banked` decls are not packed on top of cloaked code. Empty regions cost nothing (the code generator and xcc-as both skip zero-byte buffers), so a layout can over-declare its pool with no runtime overhead. No shipped layout uses the pool form.

`[cloaked]` suits PORTB-style banking layouts. No shipped layout declares the section, so it has no effect in practice: the parser accepts it, and `xt` (which reaches its extra RAM through the two bank windows) rejects a `:cloaked` annotation.

### `[stack]` — xcc software stack

```ini
[stack]
range = after-code        # symbolic — the linker places the stack right after the code/data block
size  = $0100             # optional explicit cap (otherwise grows toward the heap)
```

### `[heap]` — heap region (optional)

A layout that **declares** `[heap]` makes the coalescing free-list allocator available. A layout that omits the section forces `-falloc=bump`.

```ini
[heap]
range = before-screen     # symbolic — heap grows down from just below screen RAM
```

The shipped `xt` heap is *on-demand*: it claims one data bank at a time from a shared bitmap as allocation needs it, and gives empty banks back. The runtime selects the right bank on each allocator call.

### `[entry]` — entry point address

```ini
[entry]
address = $2000           # where main() lands; sets the XEX RUNAD
```

### `[startup]` — startup template

```ini
[startup]
template = startup/xt.asm     # hand-written .asm template under support/<platform>/startup/
```

The template is a 6502 assembly file with placeholders that the linker fills with addresses derived from the rest of the layout. Banked targets ship startup code that loads each bank page into the bank window at boot via INITAD preload stubs.

### `[output]` — binary format

```ini
[output]
format = xex
```

Used when `-o file` has no extension; otherwise the extension takes precedence.

## Memory-map diagram (comment header)

By convention, every shipped `.lnk` opens with a Unicode box-art comment showing the memory layout the file describes:

```ini
# flat.lnk — a hypothetical flat 6502 target (no banking, no shadow)
#
# ┌──────────────────────────────────────────────┐
# │ $0000-$0081  OS/hardware zero page           │
# │ $0082-$00BB  xcc ZP: SP, tmp, HP, vars       │
# │ $00B0-$00BB  runtime params (reserved)       │
# │ $00BC-$00FF  xcc ZP: vars (continued)        │
# ├──────────────────────────────────────────────┤
# │ $2000-$9FFF  Main region (32 KB)             │
# │   $2000      Code + data (entry point here)  │
# │              Stack ↑ (grows up after code)   │
# │              (free RAM)                      │
# │   $9FFF      Heap ↓ (grows down from here)   │
# ├──────────────────────────────────────────────┤
# │ $A000-$BFFF  Unused / OS area                │
# │ $C000-$CFFF  OS self-test ROM                │
# │ $D000-$D7FF  Hardware I/O                    │
# │ $D800-$FFFF  OS ROM                          │
# └──────────────────────────────────────────────┘
```

The diagram is for human readers; the linker does not parse it. `xcc-bootstrap --dump-layout -m <name>` prints the same diagram from the parsed config, so you can confirm a custom file describes what you intend.

## Built-in models

```bash
xcc-bootstrap --list-layouts
```

Prints every shipped layout grouped by platform. Each one is a `.lnk` file you can copy as a starting point for a custom variant.

The shipped layouts are `xt` (the standard xt6502 model, with two bank windows and an
on-demand banked heap) and `xt-heap` (the same map with a fixed heap reservation). Layouts
apply to the 6502 backend only; the native targets have no layout to choose.

See [Memory models](/compiler/usage/memory-models/) for what each one is for and when to pick it.

## Writing your own

Start by copying a shipped layout:

1. Run `xcc-bootstrap --dump-layout -m <closest match>` to see the layout you're starting from.
2. Copy `support/<platform>/layouts/<closest>.lnk` to a new file.
3. Edit the sections you need to change: typically `[memory]`, `[banking]` (if your hardware has a different bank-bit pattern), and the comment-header diagram.
4. Run `xcc-bootstrap --dump-layout -m ./your-file.lnk` and check that the printed diagram matches your intent.
5. Compile with `xcc-bootstrap -m ./your-file.lnk`. If the file is next to the shipped layouts under `support/<platform>/layouts/`, you can reference it by name without the path.

If you write a layout for hardware that others are likely to use (a memory expansion, a cartridge form factor, an unusual screen-RAM placement), contribute it upstream.

## CLI surface

| Flag | Purpose |
|------|---------|
| `-m <layout>` | Activate a layout. Searches `<layout>` as a path (appends `.lnk` if needed), then `support/layouts/<layout>.lnk`, then `support/<platform>/layouts/<layout>.lnk`. |
| `--list-layouts` | List every built-in layout. |
| `--dump-layout` | Print the active layout's parsed diagram and exit. |
| `-H <path>` / `XCC_HOME=...` | Point the search at a specific xcc home (so a custom `support/` tree is preferred over the system one). |
