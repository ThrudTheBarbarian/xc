//xtc-na: arm64,arm9,m68k,x86_64,win64 — dereferences the 6502 zero-page ($0000) sentinel
// asm_zp_pressure.xc — pin the codegen-side ZP pre-allocation for
// inline-asm `(name),Y` indirect addressing.
//
// The 6502's indirect-indexed addressing modes can only reach
// memory through a ZP-resident pointer pair; the assembler
// encodes only the LOW byte of the named operand. Without
// pre-allocation the codegen would let other locals fill ZP
// first, then spill the pointer to a data-section label — at
// which point the encoded LOW byte points into unrelated ZP
// at runtime and the indirect load reads garbage.
//
// Forces the issue by allocating a stack-pressure-heavy method
// (lots of i32 multiplications in nested blocks) that ALSO uses
// inline asm with `(_ptr),Y`. Pre-fix, _ptr spilled and the
// `(_ptr),Y` reads / writes pointed through random ZP — the
// poke into buf[5] silently missed and buf[5] stayed zero.
//
// `_ptr` must end up in zero page; the post-asm read confirms
// the byte landed at the expected offset.

#import "Stdio.xc"

void main(void)
{
    u8 buf[16];
    u16 i;
    for (i = (u16)0; i < (u16)16; i = i + (u16)1) {
        buf[i] = (u8)0;
    }

    // Heavy ZP pressure — many i32 locals to push the asm-touched
    // `_ptr` toward spill if the codegen weren't smart about it.
    i32 a = (i32)1234;
    i32 b = (i32)5678;
    i32 c = a * b;
    i32 d = a * a;
    i32 e = b * b;
    i32 f = c + d + e;
    i32 g = a + b + c + d + e + f;
    i32 h = a * b * c;
    i32 ii = b * d * e;
    i32 j = c * d * e;
    i32 k = a + h;
    i32 m = b + j;
    i32 n = (a * b) + (c * d) + (e * f);

    u16 _ptr;       // pointer for indirect-Y — MUST stay in ZP
    u8  val = $7F;

    asm
    {
        LDA #<buf
        STA _ptr
        LDA #>buf
        STA _ptr+1
        LDY #$05
        LDA val
        STA (_ptr),Y
    }

    // Touch the pressure locals so they don't get optimised out.
    if ((u16)f != (u16)0) { i = i + (u16)0; }
    if ((u16)g != (u16)0) { i = i + (u16)0; }
    if ((u16)h != (u16)0) { i = i + (u16)0; }
    if ((u16)ii != (u16)0) { i = i + (u16)0; }
    if ((u16)j != (u16)0) { i = i + (u16)0; }
    if ((u16)k != (u16)0) { i = i + (u16)0; }
    if ((u16)m != (u16)0) { i = i + (u16)0; }
    if ((u16)n != (u16)0) { i = i + (u16)0; }

    if (buf[5] == $7F) Stdio.printf("PASS\n");
    else                Stdio.printf("FAIL got=%d expected=127\n", (u16)buf[5]);
}