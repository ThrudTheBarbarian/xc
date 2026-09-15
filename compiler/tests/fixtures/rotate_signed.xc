// rotate_signed.xc — `<:` / `:>` on SIGNED narrow types, at several counts.
//
// Found by the differential fuzzer (tests/fuzz), where it was the largest
// single class: 19 of 61 findings. A rotate is synthesised in the shared
// lowering as `(x << rn) | (x LShr rev)`, and arm64 keeps a narrow value
// SIGN-EXTENDED in its w register — so `lsr` shifted 0xFFFF8F6C rather than
// 0x8F6C and pulled the extension bits down into the result. `>>` on a signed
// type is an AShr, so this expansion is the only producer of an LShr on a
// signed narrow type, which is why u8/u16/u32 rotates were right all along and
// only the signed ones were wrong.
//
// Rotating a bit pattern is signedness-agnostic: the i16 and u16 columns below
// hold the same bits and must therefore print the same value.
#import "Stdio.xc"

void main(void)
{
    i16 si = (i16)-28820;               // $8F6C — sign bit set
    u16 ui = (u16)36716;                // the same 16 bits, unsigned
    for (i16 n = (i16)0; n < (i16)5; n = n + (i16)1) {
        Stdio.printf("i16 %lu %lu %lu  u16 %lu %lu\n",
                     (u32)n, (u32)(u16)(si <: n), (u32)(u16)(si :> n),
                     (u32)(ui <: (u16)n), (u32)(ui :> (u16)n));
    }

    i8 sb = (i8)-84;                    // $AC
    u8  ub = (u8)172;
    for (i16 n = (i16)0; n < (i16)4; n = n + (i16)1) {
        Stdio.printf("i8 %lu %lu %lu  u8 %lu %lu\n",
                     (u32)n, (u32)(u8)(sb <: (i8)n), (u32)(u8)(sb :> (i8)n),
                     (u32)(ub <: (u8)n), (u32)(ub :> (u8)n));
    }
    return;
}
