// bignum_modexp.xc — selfhost/link/Bignum.xc's modexp against Python's pow()
// for odd moduli of 2048, 3072 and 4096 bits (#291): tests/link/bignum.sh
// builds this with the self-hosted compiler and compares each line. Then the
// interleaved montMul against the full product reduced (montReduce of mul),
// which is exact up to 79 limbs: P-256 (Es256) and 2048-bit moduli.
#import "Foundation.xc"
#import "Stdio.xc"
#import "Bignum.xc"

Data* pattern(u32 bytes, u32 seed, bool odd)
{
    Data* d = new Data();
    for (u32 i = (u32)0; i < bytes; i = i + (u32)1)
    {
        u32 v = (i * (u32)37 + seed * (u32)101 + (i >> (u32)3) * (u32)13) & (u32)255;
        if (i == (u32)0)
            v = v | (u32)128;
        if (odd && i == bytes - (u32)1)
            v = v | (u32)1;
        d.appendByte((u8)v);
    }
    return d;
}

void hexOut(Data* d)
{
    for (u32 i = (u32)0; i < d.length(); i = i + (u32)1)
        Stdio.printf("%02x", (u32)d.byteAt(i));
    Stdio.printf("\n");
}

i32 main(void)
{
    u32 sizes[3];
    sizes[0] = (u32)256;
    sizes[1] = (u32)384;
    sizes[2] = (u32)512;
    for (u32 s = (u32)0; s < (u32)3; s = s + (u32)1)
    {
        u32 b = sizes[s];
        Bignum* n = Bignum.fromBytes(pattern(b, (u32)1, true));
        Bignum* base = Bignum.fromBytes(pattern(b - (u32)1, (u32)2, false));
        Bignum* e = Bignum.fromBytes(pattern(b, (u32)3, false));
        hexOut(Bignum.modexp(base, e, n).toBytes(b));
    }
    u32 bad = (u32)0;
    for (u32 b = (u32)32; b <= (u32)256; b = b + (u32)32)
    {
        Bignum* n = Bignum.fromBytes(pattern(b, b, true));
        u32 np = Bignum.montInv(n.limb((u32)0));
        for (u32 t = (u32)0; t < (u32)4; t = t + (u32)1)
        {
            Bignum* x = Bignum.mod(Bignum.fromBytes(pattern(b, t + (u32)5, false)), n);
            Bignum* y = Bignum.mod(Bignum.fromBytes(pattern(b - (u32)3, t + (u32)9, false)), n);
            if (Bignum.cmp(Bignum.montMul(x, y, n, np), Bignum.montReduce(Bignum.mul(x, y), n, np)) != (i32)0)
                bad = bad + (u32)1;
        }
    }
    Stdio.printf("montmul %s\n", bad == (u32)0 ? "agrees" : "DIFFERS");
    return 0;
}
