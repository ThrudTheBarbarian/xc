---
title: Operators
description: Full operator precedence table including the rotate and byte-extract operators.
---

xcc operators are mostly a subset of C's, with two additions: a pair of **rotate** operators (`<:` and `:>`) that map to the 6502's `ROL` / `ROR` instructions, and four **byte-extract** prefix operators (`<`, `>`, `>>`, `>>>`) that select individual bytes of wider constants and symbols. The byte-extract operators apply only inside [`asm { ... }`](/compiler/language/inline-asm/) blocks.

## Precedence table

Listed from highest to lowest. Rows at the same level have the same precedence; within a level, **Assoc** records the associativity.

| Operators | Assoc | Notes |
|-----------|-------|-------|
| `a[i]`, `f(...)`, `.`, `->`, postfix `++`, postfix `--` | left | primary |
| prefix `+ -`, `!`, `~`, prefix `++`, prefix `--`, `*` (deref), `&` (addr-of), `(type)` cast, `sizeof()`, `<` `>` `>>` `>>>` (byte extract, asm) | right | unary |
| `*`, `/`, `%` | left | multiplicative |
| `+`, `-` | left | additive |
| `<:`, `:>` | left | rotate (ROL / ROR) |
| `<<`, `>>` | left | shift (ASL / ASR) |
| `<`, `>`, `<=`, `>=` | left | relational |
| `==`, `!=` | left | equality |
| `&` | left | bitwise AND |
| `^` | left | bitwise XOR |
| `\|` | left | bitwise OR |
| `&&` | left | logical AND |
| `\|\|` | left | logical OR |
| `? :` | right | ternary |
| `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `\|=`, `^=`, `<<=`, `>>=`, `<:=`, `:>=` | right | assignment |

## Notes on specific operators

### Rotate vs shift

`<:` and `:>` **rotate** through carry. They map to the 6502 `ROL` / `ROR` instructions, which read and write the carry flag. `<<` and `>>` are **arithmetic shifts** (`ASL`, and `ASR` for the right shift). Use rotate to chain bytes through carry; use shift to multiply or divide by powers of two.

```c
u8 a = $80;
u8 b = a <: 1;    // a is rotated left through carry; one-bit shift left + carry-in
u8 c = a << 1;    // arithmetic left shift; bit 7 lost
```

### Pointer dereference and address-of

`*` is the unary dereference operator; `&` takes an address. Each undoes the other:

```c
u8 v   = 42;
u8* p  = &v;
u8 q   = *p;     // q == 42
*p     = 99;     // v becomes 99
```

`->` dereferences and then accesses a member: `p->x` is the same as `(*p).x`. xcc also accepts the dot form `p.x` on a pointer and dereferences automatically. See [Types → Pointers](/compiler/language/types/#pointers) for the rationale.

### Cast extensions

Inside the `(type)` cast, two forms have non-C semantics:

- `(Dog*) animal` — runtime-checked downcast. Traps on mismatch.
- `(Dog* ?) animal` — failable downcast. Yields `(Dog*)0` on mismatch.

These are class-pointer-only; `(u16 ?)x` is a compile-time error. Details on [Inheritance & protocols](/compiler/language/inheritance/).

### `sizeof`

`sizeof(T)` evaluates to a compile-time `u16` byte count. Works on any type, including `struct` and `class`.

### Byte-extract prefixes (asm context)

These operators apply only inside an `asm { ... }` block. They select individual bytes of a constant or symbol that the assembler would otherwise treat as a 16- or 32-bit address:

| Prefix | Meaning |
|--------|---------|
| `<x`   | low 8 bits of `x` |
| `>x`   | bits 8..15 of `x` |
| `>>x`  | bits 16..23 of `x` |
| `>>>x` | bits 24..31 of `x` |

```c
u16 val = $1234;

asm {
    lda #<val;    // LDA #$34
    ldx #>val;    // LDX #$12
}
```

Outside an `asm` block these tokens have their normal meaning: `<` and `>` are relational comparisons and `>>` is the shift operator. Inside a block the byte-extract reading is unambiguous, because the assembler grammar accepts only constants and symbols after the prefix.

## Compound assignment

Every arithmetic, bitwise and shift binary operator has a compound-assignment form: `+=`, `-=`, `*=`, `/=`, `%=`, `&=`, `|=`, `^=`, `<<=`, `>>=`, plus the rotate forms `<:=` and `:>=`. Each behaves as its expansion:

```c
x += 1;            // x = x + 1
flags &= ~MASK;    // flags = flags & ~MASK
acc <:= 1;         // acc = acc <: 1
```

When the left-hand side goes through a property setter (see [Classes → Properties](/compiler/language/classes/#properties)), the expansion evaluates the base expression twice. This costs nothing for identifiers and `self`, and matters only if the base has a side effect.

## Worked example

The operators that differ from C, and the ones that do not:

```c
// operators.xc — the operators that differ from C, and the ones that don't.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // ---- Arithmetic, at the operands' own width -----------------------------
    // Same-width arithmetic stays at that width, so these WRAP rather than
    // promoting to int as C would: 300 & $FF = 44, 600 & $FF = 88.
    u8 a = (u8)200;
    u8 b = (u8)100;
    Stdio.printf("u8   200+100=%d  200*3=%d\n", (u16)(a + b), (u16)(a * (u8)3));
    // Widening the OPERANDS is what gets the true sum.
    Stdio.printf("wide 200+100=%d\n", (u16)a + (u16)b);

    // Division and modulo. Integer division truncates toward zero.
    i16 n = (i16)-17;
    Stdio.printf("-17/5=%d  -17%%5=%d\n", n / (i16)5, n % (i16)5);

    // ---- Shift vs rotate ----------------------------------------------------
    // `<<` and `>>` shift; `<:` and `:>` ROTATE through the carry flag, which
    // is what lets you chain bytes together. On the 6502 they are ROL / ROR.
    u8 hi = $81;
    Stdio.printf("$81 << 1 = $%x   $81 >> 1 = $%x\n",
                 (u16)(hi << (u8)1), (u16)(hi >> (u8)1));
    Stdio.printf("$81 <: 1 = $%x   $81 :> 1 = $%x\n",
                 (u16)(hi <: (u8)1), (u16)(hi :> (u8)1));

    // ---- Bitwise ------------------------------------------------------------
    u8 m = $F0;
    u8 k = $AA;
    Stdio.printf("and=$%x or=$%x xor=$%x not=$%x\n",
                 (u16)(m & k), (u16)(m | k), (u16)(m ^ k), (u16)(~m));

    // ---- Logical, and short-circuit ----------------------------------------
    // && and || evaluate left to right and stop as soon as the answer is known.
    u16 zero = (u16)0;
    bool safe = (zero != (u16)0) && ((u16)100 / zero > (u16)1);   // never divides
    Stdio.printf("short-circuit ok: %d\n", safe ? (u16)1 : (u16)0);

    // ---- Comparison and the ternary ----------------------------------------
    u16 x = (u16)7;
    u16 y = (u16)11;
    Stdio.printf("max=%d  eq=%d  ne=%d\n",
                 x > y ? x : y,
                 (u16)(x == y ? 1 : 0),
                 (u16)(x != y ? 1 : 0));

    // ---- Compound assignment, including the rotates ------------------------
    u8 acc = (u8)1;
    acc += (u8)4;       // 5
    acc *= (u8)3;       // 15
    acc <<= (u8)1;      // 30
    acc |= (u8)1;       // 31
    Stdio.printf("compound=%d\n", (u16)acc);

    // ---- Increment / decrement ---------------------------------------------
    // Prefix updates then yields; postfix yields then updates.
    u16 i = (u16)5;
    u16 pre = ++i;      // i=6, pre=6
    u16 post = i++;     // post=6, i=7
    Stdio.printf("pre=%d post=%d i=%d\n", pre, post, i);

    // ---- sizeof -------------------------------------------------------------
    // A compile-time constant. Pointer width is the only one that varies by
    // target; every scalar is the same everywhere.
    Stdio.printf("sizeof u8=%d u16=%d u32=%d u64=%d float=%d double=%d\n",
                 (u16)sizeof(u8), (u16)sizeof(u16), (u16)sizeof(u32),
                 (u16)sizeof(u64), (u16)sizeof(float), (u16)sizeof(double));

    // ---- Address-of and dereference ----------------------------------------
    u16 v = (u16)42;
    u16* p = &v;
    *p = *p + (u16)1;
    Stdio.printf("through pointer: %d\n", v);
    return 0;
}
```

```
u8   200+100=44  200*3=88
wide 200+100=300
-17/5=-3  -17%5=-2
$81 << 1 = $0002   $81 >> 1 = $0040
$81 <: 1 = $0003   $81 :> 1 = $00C0
and=$00A0 or=$00FA xor=$005A not=$000F
short-circuit ok: 0
max=11  eq=0  ne=1
compound=31
pre=6 post=6 i=7
sizeof u8=1 u16=2 u32=4 u64=8 float=4 double=8
through pointer: 43
```

In the first line, `u8 + u8` and `u8 * u8` stay at 8 bits and wrap (44 and 88). C would promote both to `int` and print 300 and 600. To get the full value, widen the **operands**.
