// f16_convert.xc — conversions to the 16-bit floats, f16 (IEEE binary16) and
// bf16 (pack e8m7), from f32 and f64, and back to f32, checked bit for bit.
// The expected patterns come from an independent model that rounds the exact
// value to nearest even (checked against numpy's float16 for f16). The cases
// cover the largest finite value, overflow to infinity, the smallest normal,
// the smallest and largest subnormals, the subnormal boundary, ties to even,
// signed zeros and NaN, which keeps its sign and the top of its payload and is
// made quiet. A 32-bit pattern prints as two 16-bit halves, which every
// target's printf shows the same way. f16_convert_int.xc has the integers.
#define ENABLE_64BIT 1
#import "Stdio.xc"

u16 hbits(f16 h) { return *(u16*)&h; }
u16 bbits(bf16 g) { return *(u16*)&g; }
f16 hfrom(u16 u) { return *(f16*)&u; }
bf16 bfrom(u16 u) { return *(bf16*)&u; }
f32 ffrom(u32 u) { return *(f32*)&u; }

void put32(f32 f)
{
    u32 u = *(u32*)&f;
    Stdio.printf(" %x:%x", (u16)(u >> 16), (u16)u);
}


u32 F32[96] = {$00000000, $80000000, $7F800000, $FF800000, $7FC00000, $FFC00000, $7F800001, $7FA00000, $477FE000, $477FEFFF, $477FF000, $477FFFFF, $47800000, $C77FE000, $C77FF000, $38800000, $387FC000, $387FE000, $33800000, $33000000, $33000001, $33400000, $32FFFFFF, $B3800000, $3F801000, $3F803000, $3F805000, $3F807000, $BF801000, $3F800FFF, $3F801001, $7F7F0000, $7F7F7FFF, $7F7F8000, $00800000, $007F0000, $00010000, $00008000, $00018000, $00008001, $3F808000, $3F818000, $3F828000, $3F838000, $BF808000, $3DCCCCCD, $3EAAAAAB, $40490FDB, $42F6E979, $C2280000, $461C4000, $FE4D580A, $7D92234B, $135EEC44, $09919063, $42900ACF, $B41E6725, $D9FF1F9B, $6A064EBF, $E54A8ADF, $952FC888, $90EF709C, $CA7C4B25, $98F8B9D2, $8E63445C, $D6EC9D52, $512C6A0C, $F9C05907, $6C9BB36E, $E2DDDFE9, $3EC2D748, $CFE991A4, $F454FAF6, $82DD5A9A, $837AAC05, $50E64183, $F365C36C, $A8919D4B, $98E36417, $E66FDD6F, $34D553BB, $C56FCCF9, $3F98A326, $D5F8C2A7, $E38FE086, $CDA24225, $396026D3, $6BD3FE5B, $DA8176CC, $A8C6489B, $9A2567E5, $914ED483, $12E846BD, $A7C94B34, $D632DEB7, $40394659};
f64 F64[16] = {0.1d, 0.3333333333333333d, 65504.0d, 65519.99999d, 65520.0d, 5.960464477539063e-08d, 2.9802322387695312e-08d, 2.9802322388562674e-08d, 8.940696716308594e-08d, 1.00048828125d, 1.0004882812500009d, 3.3895313892515355e+38d, 3.3961775292304e+38d, 1e-300d, -2.5d, 123456.789d};

i32 main(void)
{
    Stdio.printf("f32\n");
    for (u32 i = 0; i < 96; i++)
    {
        f32 f = ffrom(F32[i]);
        f16 h = (f16)f;
        bf16 g = (bf16)f;
        Stdio.printf("%x %x", hbits(h), bbits(g));
        put32((f32)h);
        put32((f32)g);
        Stdio.printf("\n");
    }
    Stdio.printf("f64\n");
    for (u32 i = 0; i < 16; i++)
        Stdio.printf("%x %x\n", hbits((f16)F64[i]), bbits((bf16)F64[i]));
    return 0;
}
