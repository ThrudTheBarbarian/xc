// subscript_large.xc — coverage for u16/u32 subscript across the
// i*width < 256 / i*width >= 256 boundary.
//
// A 192-element u16 array (byte offsets up to 382) and a
// 96-element u32 array (offsets up to 380) are written and read
// back at indices that straddle the offset-256 carry boundary.
// The dynamic-index path (Y = i*width) must carry bit 8 of the
// product; index 128 (u16 off=256) and index 191 (off=382) are
// the load-bearing cases. The printed readback values are the
// oracle.

#import "Stdio.xc"

void main(void)
{
    // ── u16 array, 192 elements (offsets 0..382) ──────────────
    u16* p = new u16[192];

    p[5]   = $AAAA;
    p[127] = $BBBB;    // off=254, fits in Y
    p[128] = $CCCC;    // off=256, needs carry handling
    p[191] = $DDDD;    // off=382, well past carry

    Stdio.printf("C5=%u C127=%u C128=%u C191=%u\n", p[5], p[127], p[128], p[191]);

    u8 i5   = 5;
    u8 i127 = 127;
    u8 i128 = 128;
    u8 i191 = 191;
    p[i5]   = $1111;
    p[i127] = $2222;
    p[i128] = $3333;
    p[i191] = $4444;

    Stdio.printf("D5=%u D127=%u D128=%u D191=%u\n", p[i5], p[i127], p[i128], p[i191]);
    delete p;

    // ── u32 array, 96 elements (offsets 0..380) ───────────────
    u32* q = new u32[96];

    q[0]  = $01020304;
    q[63] = $11223344;   // off=252
    q[64] = $55667788;   // off=256, crosses boundary
    q[95] = $DEADBEEF;   // off=380

    Stdio.printf("Q0=%lu Q63=%lu Q64=%lu Q95=%lu\n", q[0], q[63], q[64], q[95]);
    delete q;
    return;
}
