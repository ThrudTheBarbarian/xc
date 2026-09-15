//xtc-na: arm9,m68k,xt6502,x86_64,win64 — uses inline arm64 assembly
// asm_arm64.xc — exercise the arm64 inline-asm path (phase-171).
//
// The xtc inline-asm block is emitted verbatim by the arm64
// backend; clang's integrated assembler runs over it downstream.
// A name reference inside the block (`result`) resolves to the
// local's SP-relative slot — the user writes `strh w0, [result]`
// and codegen plants `strh w0, [sp, #N]`.
//
// First block stores 42 into `result`; second block reloads it,
// adds 58, and stores 100 back. The printed values are the
// oracle. arm64-only (the body is arm64 mnemonics).

#import "Stdio.xc"

void main(void)
{
    u16 result = 0;
    asm
    {
        mov w0, #42
        strh w0, [result]
    }
    Stdio.printf("A=%u\n", result);   // 42, written by inline asm

    asm
    {
        ldrh w1, [result]
        add w1, w1, #58
        strh w1, [result]
    }
    Stdio.printf("B=%u\n", result);   // 100 = 42 + 58
}
