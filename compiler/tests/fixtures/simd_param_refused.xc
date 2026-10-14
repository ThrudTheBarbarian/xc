//xtc-flags: expect=sema-error
// A `simd:` parameter holds every caller: a plain pointer cannot satisfy it,
// because the callee may hand the buffer to a GPU with no copy, which needs the
// page-aligned storage only a `simd:` pointer promises (par-blocks.md). The
// other direction — a `simd:` argument into a plain parameter — only drops the
// guarantee and is fine (simd_ptr.xc).
// Refused: argument 1 of 'touch' is not a simd: pointer where a simd: pointer is declared
//xtc-na: xt6502, m68k
#import "Stdio.xc"

void touch(simd: u8* p) { p[0] = (u8)1; }

i32 main(void)
{
    u8* plain;
    touch(plain);
    return 0;
}
