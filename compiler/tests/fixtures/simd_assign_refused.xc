//xtc-flags: expect=sema-error
// A `simd:` pointer may hold only what `new[]` returned or what another
// `simd:` pointer holds: the qualifier promises a page-aligned block the
// runtime can find, and a par block that captures the pointer is sized from
// that block. A plain pointer stored into one at a declaration, an assignment
// or a return breaks the promise with no sign at the site, so each is refused
// as the argument form is (simd_param_refused.xc). nil is fine, arithmetic on
// a `simd:` pointer keeps the qualifier, and a cast says it is meant.
// Refused: initialiser: a plain pointer cannot be stored in a simd: pointer
//xtc-na: xt6502, m68k
#import "Stdio.xc"

simd: u8* give(u8* p)
{
    return p;                                // return: refused
}

i32 main(void)
{
    u8* plain = new u8[16];
    simd: u8* a = plain;                     // initialiser: refused
    simd: u8* b = nil;                       // fine
    b = plain;                               // assignment: refused
    simd: u8* c = new u8[16];                // fine: new[]
    simd: u8* d = c + (u32)4;                // fine: arithmetic keeps simd:
    Stdio.printf("%u\n", (u32)(a == b) + (u32)(d == c) + (u32)(give(plain) == nil));
    return (i32)0;
}
