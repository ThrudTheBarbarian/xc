//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// at the integrated assembler (phase-171).
// asm_var.xc — inline asm byte-extraction operators (<,>) on a local,
// proving the local binds into the asm body and both bytes are reached.
#import "Stdio.xc"

u8 lo; u8 hi;

void main(void)
{
    u16 val = $1234;
    asm
    {
        LDA #<val     // low byte  -> $34 (52)
        STA lo
        LDA #>val     // high byte -> $12 (18)
        STA hi
    }
    Stdio.printf("lo=%d hi=%d\n", (u16)lo, (u16)hi);
    return;
}
