// select_wide.xc — a Select of a 64-bit value copies both halves.
//
// At -O2 the optimiser turns a small `if` or a ternary that picks between two
// values into one Select instruction. The m68k back end built the Select in
// d0 and stored that one register, so only the HIGH long of an i64, u64 or
// double reached the result and the low long kept whatever the slot held.
// The arm9 Select was one register wide as well. A value whose low half is
// zero hides it, so every value here has a non-zero low half.
//
// The conditions come from memory so that nothing folds away.
#import "Stdio.xc"

u64 bumpU(u64 q, bool s)
{
    u64 m = q;
    if (s)
        m = m + (u64)1;
    return m;
}

i64 pickI(bool s, i64 a, i64 b)
{
    return s ? a : b;
}

double pickD(bool s, double a, double b)
{
    double r = b;
    if (s)
        r = a;
    return r;
}

u64 bitsOf(double d)
{
    double v = d;
    u64* p = (u64*)&v;
    return *p;
}

// The Select's result is reinterpreted through memory, the shape a
// bit-pattern round trip (a Coder number) takes.
double bumpAsDouble(u64 q, bool s)
{
    u64 m = q;
    if (s)
        m = m + (u64)1;
    double v = 0.0d;
    u64* p = (u64*)&v;
    *p = m;
    return v;
}

void main(void)
{
    bool* flags = new bool[2];
    flags[0] = false;
    flags[1] = true;
    u64 x = (u64)0x3FFD5023 << (u64)32 | (u64)0x89ABCDEF;
    for (u32 i = (u32)0; i < (u32)2; i++)
        {
        bool f = flags[i];
        Stdio.printf("bumpU %s\n", String.withU64(bumpU(x, f)).cString());
        Stdio.printf("pickI %s\n", String.withI64(pickI(f, (i64)-5000000001, (i64)7000000003)).cString());
        Stdio.printf("pickD %s\n", String.withU64(bitsOf(pickD(f, 3.1d, -2.7d))).cString());
        Stdio.printf("asDouble %s\n", String.withU64(bitsOf(bumpAsDouble(x, f))).cString());
        }
}
