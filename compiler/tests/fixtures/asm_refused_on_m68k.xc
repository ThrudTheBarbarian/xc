// asm_refused_on_m68k.xc — the m68k back end refuses an inline asm block it
// cannot lower.
//
// It used to drop the block and build the program anyway. The result ran and
// exited 0 with the block's effect missing: double_math_lnexp.xc copies each
// double out through a 6502 `asm { LDA d ... }` block, and built for m68k it
// printed FAIL lines that looked like a 68881 fault. The m68k back end has no
// inline asm lowering, so a block with any text in it is now a compile error.
// A block the preprocessor emptied still compiles.
//
//xtc-flags: expect=sema-error
//xtc-na: arm64,xt6502,arm9,x86_64,win64,wasm32 — the block is 6502 code; this checks the m68k refusal only

#import "Stdio.xc"

u8 r0;

void main(void)
{
    u8 c = 66;
    asm { LDA c : STA r0 }
    Stdio.printf("r0=%u\n", r0);
}
