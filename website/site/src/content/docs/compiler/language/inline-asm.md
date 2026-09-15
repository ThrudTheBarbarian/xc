---
title: Inline assembly
description: asm blocks, byte-extract operators, accessing xcc variables, the clobbers annotation.
---

xcc supports embedded assembly in `asm { ... }` blocks. Inside a block the grammar is the same as `xcc-as` (see the [xcc-as reference](/compiler/api/)), with two additions: you can refer to xcc identifiers by name, and you can select individual bytes of wider values.

## The asm block

```c
asm {
    lda #$ff;
    sta $D40E;          // disable VBLANK interrupts
}
```

The body is delimited by `{ ... }`, like an xcc statement body.

By default the compiler scans the block, works out which registers it writes, and emits save / restore code around it. If the block has *intended* side effects on a register the scan misses (or the scan reports a register the block does not touch), override it with a `clobbers` annotation:

```c
asm {
    lda #$00;
    tax;
    tay;
} : clobbers A, X, Y
```

When the annotation and the scan disagree (for example, the scan finds a write to A that the annotation omits), the compiler warns under the `asm-clobbers` category. After checking the block, you can suppress these warnings with `-Wno-asm-clobbers`.

## Accessing xcc variables

Identifiers declared in xcc are visible inside `asm` blocks under their declared names. The assembler resolves each to its allocated address, so it can appear anywhere a label or constant can.

```c
u16 score = 0;

void incScore(void) {
    asm {
        inc score;          // 16-bit increment
        bne done;
        inc score+1;
        done:
    }
}
```

The same applies to global symbols, struct ivar offsets and class-instance ivars; the compiler emits the computed address.

## Byte-extract operators

Wider values (`u16`, `u32`, addresses of arrays / classes / functions) do not fit in a single 6502 immediate. The four byte-extract prefix operators select one byte:

| Prefix | Range |
|--------|-------|
| `<x` | bits 0..7 (low byte) |
| `>x` | bits 8..15 |
| `>>x` | bits 16..23 |
| `>>>x` | bits 24..31 |

```c
u16 val = $1234;

asm {
    lda #<val;        // LDA #$34
    ldx #>val;        // LDX #$12
}

u32 big = $11223344;

asm {
    lda #<big;        // LDA #$44
    ldx #>big;        // LDX #$33
    ldy #>>big;       // LDY #$22
    sta #>>>big;      // STA #$11    (pseudo, illustrative)
}
```

The assembler grammar recognises these prefixes inside `asm` blocks. They do not clash with the xcc `<` / `>` comparison operators, because the assembler accepts only constants and symbols after them. (See [Operators → Byte-extract prefixes](/compiler/language/operators/#byte-extract-prefixes-asm-context).)

## What the assembler accepts

The assembler recognises every official instruction, with operand modes written in the standard way. The 6502 modes are:

| Mode | Example |
|------|---------|
| Accumulator | `asl;` |
| Immediate | `lda #$00;` |
| Zero-page | `lda $80;` |
| ZP, X | `lda $80,x;` |
| Absolute | `lda $1234;` |
| Absolute, X / Y | `lda $1234,x;` |
| Indirect | `jmp ($fffc);` |
| (ZP, X) | `lda ($80,x);` |
| (ZP), Y | `lda ($80),y;` |

Instruction lines end with `;`, like xcc statements. Labels are bare identifiers followed by `:`, and are local to the current `asm` block.

Platform memory-map symbols are predefined for the active target. On xt6502 these are `POKMSK`, `SDMCTL`, `AUDF1` and the other OS shadow and hardware register names, so you can use them without declaring constants. The assembler loads the symbol table from `support/<platform>/symbols/*.sym`; look there for the set available on a platform, or to add your own. Each `.sym` file is a list of `NAME = $hex` lines (anything after `;` on a line is a comment), so adding a symbol takes one line.

## A complete example

This helper disables NMI generation around a critical section and then restores it. It shows variable access, control flow and the `clobbers` annotation:

```c
volatile u8* NMIEN = (u8*)$D40E;

// xtc has no C function pointers; a callback is a bound method.
typedef void Body(void);

void atomic(callback body void(void)) {
    u8 saved;

    asm {
        lda NMIEN;
        sta saved;
        lda #$00;
        sta NMIEN;
    } : clobbers A

    body();

    asm {
        lda saved;
        sta NMIEN;
    } : clobbers A
}
```

Put larger helpers, such as multi-byte arithmetic, bank-switching trampolines or hardware-seeded PRNGs, in a hand-written `.asm` file under `support/` (see the repository's `support/generic/asm/` and `support/<platform>/asm/` directories) and `JSR` to them from xcc. Use inline `asm` blocks for short sections of assembly within xcc code.
