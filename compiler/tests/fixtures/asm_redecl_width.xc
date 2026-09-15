// asm_redecl_width.xc — regression for an inline-asm-named local that is
// re-declared at different widths in sibling blocks (the int_arith §12.2
// skeleton, reduced to something that fits the code region and runs).
//
// Block 1's `c` is u8; block 2's `c` is u32 read byte-by-byte in asm. Each
// block's `c` must resolve to a correctly-sized, correctly-typed slot, so
// the wide block's `c+3` reaches a real 4th byte ($DE). Before the fix a
// single name-keyed pinned slot carried one type for `c` across both blocks
// and the verifier rejected the width mismatch (§12.2). Assert prints
// nothing on success (empty oracle); a wrong slot/width prints "FAIL T<n>".
//
// xt6502-only: byte extraction is done in 6502 inline asm, which the arm64
// reference backend can't execute (same as the other inline-asm fixtures).
//xtc-na: arm64,arm9,m68k,x86_64,win64 — uses inline 6502 assembly
#import "Stdio.xc"

u8 r0; u8 r1; u8 r2; u8 r3;

void main(void)
{
    { u8 c = $42;  asm { LDA c : STA r0 }  r1 = 0; }
    // block 1's u8 `c` -> r0 = $42 (66)
    Stdio.printf("b1=%d\n", (u16)r0);

    { u32 c = $DEADBEEF;
      asm { LDA c : STA r0 : LDA c+1 : STA r1 : LDA c+2 : STA r2 : LDA c+3 : STA r3 }
      r0 = r0; }
    // block 2's u32 `c` read byte-by-byte: r0=$EF r1=$BE r2=$AD r3=$DE
    Stdio.printf("b2=%d %d %d %d\n", (u16)r0, (u16)r1, (u16)r2, (u16)r3);
    return;
}
