// operators.xc — the operators that differ from C, and the ones that don't.
#import "Foundation.xc"
#import "Stdio.xc"

i32 main(void)
{
    // ---- Arithmetic, at the operands' own width -----------------------------
    // Same-width arithmetic stays at that width, so these WRAP rather than
    // promoting to int as C would: 300 & $FF = 44, 600 & $FF = 88.
    u8 a = 200;
    u8 b = 100;
    Stdio.printf("u8   200+100=%d  200*3=%d\n", (u16)(a + b), (u16)(a * 3));
    // Widening the OPERANDS is what gets the true sum.
    Stdio.printf("wide 200+100=%d\n", (u16)a + (u16)b);

    // Division and modulo. Integer division truncates toward zero.
    i16 n = -17;
    Stdio.printf("-17/5=%d  -17%%5=%d\n", n / (i16)5, n % (i16)5);

    // ---- Shift vs rotate ----------------------------------------------------
    // `<<` and `>>` shift; `<:` and `:>` ROTATE through the carry flag, which
    // is what lets you chain bytes together. On the 6502 they are ROL / ROR.
    u8 hi = $81;
    Stdio.printf("$81 << 1 = $%02X   $81 >> 1 = $%02X\n",
                 (u16)(hi << 1), (u16)(hi >> 1));
    Stdio.printf("$81 <: 1 = $%02X   $81 :> 1 = $%02X\n",
                 (u16)(hi <: 1), (u16)(hi :> 1));

    // ---- Bitwise ------------------------------------------------------------
    u8 m = $F0;
    u8 k = $AA;
    Stdio.printf("and=$%02X or=$%02X xor=$%02X not=$%02X\n",
                 (u16)(m & k), (u16)(m | k), (u16)(m ^ k), (u16)(~m));

    // ---- Logical, and short-circuit ----------------------------------------
    // && and || evaluate left to right and stop as soon as the answer is known.
    u16 zero = 0;
    bool safe = (zero != 0) && (100 / zero > 1);   // never divides
    Stdio.printf("short-circuit ok: %d\n", safe ? (u16)1 : (u16)0);

    // ---- Comparison and the ternary ----------------------------------------
    u16 x = 7;
    u16 y = 11;
    Stdio.printf("max=%d  eq=%d  ne=%d\n",
                 x > y ? x : y,
                 (u16)(x == y ? 1 : 0),
                 (u16)(x != y ? 1 : 0));

    // ---- Compound assignment, including the rotates ------------------------
    u8 acc = 1;
    acc += 4;       // 5
    acc *= 3;       // 15
    acc <<= 1;      // 30
    acc |= 1;       // 31
    Stdio.printf("compound=%d\n", (u16)acc);

    // ---- Increment / decrement ---------------------------------------------
    // Prefix updates then yields; postfix yields then updates.
    u16 i = 5;
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
    u16 v = 42;
    u16* p = &v;
    *p = *p + 1;
    Stdio.printf("through pointer: %d\n", v);
    return 0;
}
