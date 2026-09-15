//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// inline_asm_label_dup.xc — calling the same `inline:` function
// multiple times must not produce duplicate asm-block labels at
// assemble time. Pre-fix, a function whose body contained an asm
// label (e.g. a branch loop) failed assembly with "duplicate
// label" the second time it was inlined. The codegen now appends
// a per-expansion suffix so each inlined copy carries fresh
// labels (`_lbl__i1`, `_lbl__i2`, …).
//
// The test compiles only when the rewrite works — without it the
// assembler would refuse the binary with "duplicate label
// '_leaf_lp'". The runtime asserts then verify the inline body
// actually executed and produced the right side effect.

#import "Stdio.xc"
#import "Assert.xc"

// Globals avoid the address-of-stack / banked-store-byte path so
// the same fixture exercises the bug uniformly across xl, xt, xe.
u8 _g_count;

// Leaf with a branch loop labelled `_leaf_lp`. Counts down from
// `n` and stores the iteration count to the global. The asm form
// guarantees a labelled branch so the duplicate-label scenario
// triggers when the function gets inlined twice.
void countdown(u8 n)
{
    asm
    {
        LDA #$00
        STA _g_count
        LDX n
    _leaf_lp:
        INC _g_count
        DEX
        BNE _leaf_lp
    }
    return;
}

// Wrapper called from main. Inlining `wrap` itself ALSO inlines
// the two countdown calls inside — pre-fix, that produced four
// copies of `_leaf_lp` and a duplicate-label assemble error.
void wrap(u8 a)
{
    inline:countdown(a);
    return;
}

void main(void)
{
    Assert.reset();

    _g_count = 0;
    inline:countdown(3);                          // T1
    Assert.isEqual((u16)_g_count, 3);

    _g_count = 0;
    inline:countdown(7);                          // T2
    Assert.isEqual((u16)_g_count, 7);

    _g_count = 0;
    inline:wrap(5);                               // T3
    Assert.isEqual((u16)_g_count, 5);

    _g_count = 0;
    inline:wrap(9);                               // T4
    Assert.isEqual((u16)_g_count, 9);

    Stdio.printf("DONE 4\n");
    return;
}