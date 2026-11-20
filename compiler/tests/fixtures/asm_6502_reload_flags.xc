//xtc-na: arm64,arm9,m68k,x86_64,win64,wasm32 — uses inline 6502 assembly
// asm_6502_reload_flags.xc — the redundant-reload peephole must leave an
// inline-asm body alone. It dropped the body's `LDA g` after `STA g` as a
// reload of what A already held, but the load also set Z, which the BEQ
// after the CLC reads: the branch fell through and the program printed 2
// instead of 1.
#import "Stdio.xc"

u8 g;
u8 r;

i32 main()
    {
    asm {
        LDA #0
        LDX #1
        STA g
        LDA g
        CLC
        BEQ .rf_zero
        LDA #2
        STA r
        JMP .rf_done
.rf_zero:
        LDA #1
        STA r
.rf_done:
    }
    Stdio.printf("%d\n", (u16)r);
    return 0;
    }
