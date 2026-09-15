//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
// at the integrated assembler (phase-171).
// asm_block.xc — inline assembly: compute a result through an asm body
// and print it, proving the block executes and stores to a named global.
#import "Stdio.xc"

u8 result;

void main(void)
{
    asm
    {
        LDA #$5A
        CLC
        ADC #$36     // $5A + $36 = $90 (144)
        STA result
    }
    Stdio.printf("result=%d\n", (u16)result);
    return;
}
