// u64_loop_phi.xc — a 64-bit value carried round a loop.
//
// A loop-carried i64 or u64 is a phi. The arm9 and m68k back ends keep every
// 64-bit value in a two-word frame slot and exclude it from register homing,
// but the exclusion looked at instruction results only and never at phis. So
// the phi was given a home register as well, the loop's copies wrote its slot,
// and a narrowing read after the loop (`(u32)rem`) took the home register,
// which nothing had written. On arm9 the remainder below came back as 2.
//
// The long division is the shape of a bignum-to-decimal conversion: divide
// a multi-word number by 10^9, carrying the remainder in a u64.
#import "Stdio.xc"

u32 remOnly(u32* x, u32 n, u32 d)
{
    u64 rem = (u64)0;
    for (u32 i = n; i > (u32)0; i--)
        {
        u64 cur = (rem << (u64)32) | (u64)x[i - (u32)1];
        rem = cur % (u64)d;
        }
    return (u32)rem;
}

u32 divWords(u32* x, u32 n, u32 d)
{
    u64 rem = (u64)0;
    for (u32 i = n; i > (u32)0; i--)
        {
        u64 cur = (rem << (u64)32) | (u64)x[i - (u32)1];
        x[i - (u32)1] = (u32)(cur / (u64)d);
        rem = cur % (u64)d;
        }
    return (u32)rem;
}

u64 phiOnly(u32 n)
{
    u64 acc = (u64)0;
    for (u32 i = n; i > (u32)0; i--)
        acc = (acc << (u64)32) | (u64)i;
    return acc;
}

// A signed accumulator narrowed after the loop, and one read back whole.
i32 lowOfSum(i64 step, u32 n)
{
    i64 s = (i64)0;
    for (u32 i = (u32)0; i < n; i++)
        s = s + step;
    return (i32)s;
}

i64 sum(i64 step, u32 n)
{
    i64 s = (i64)0;
    for (u32 i = (u32)0; i < n; i++)
        s = s + step;
    return s;
}

// Two 64-bit phis that feed each other.
u64 fib(u32 n)
{
    u64 a = (u64)0;
    u64 b = (u64)1;
    for (u32 i = (u32)0; i < n; i++)
        {
        u64 t = a + b;
        a = b;
        b = t;
        }
    return a;
}

// A u64 as a decimal string, nine digits at a time.
String* decimal(u32* words, u32 n)
{
    String* out = String.withCString("");
    bool zero = false;
    while (!zero)
        {
        u32 r = divWords(words, n, (u32)1000000000);
        zero = true;
        for (u32 i = (u32)0; i < n; i++)
            if (words[i] != (u32)0)
                zero = false;
        String* chunk = String.withU32(r);
        String* next = String.withCString("");
        if (!zero)
            for (u32 p = chunk.byteLength(); p < (u32)9; p++)
                next.appendByte((u8)'0');
        next.append(chunk);
        next.append(out);
        out = next;
        }
    return out;
}

void main(void)
{
    u32* w = new u32[2];
    w[0] = (u32)0x9999999A;
    w[1] = (u32)0x19999999;
    Stdio.printf("rem %s\n", String.withU32(remOnly(w, (u32)2, (u32)1000000000)).cString());
    u32 r = divWords(w, (u32)2, (u32)1000000000);
    Stdio.printf("div rem %s q %s %s\n", String.withU32(r).cString(),
                 String.withU32(w[1]).cString(), String.withU32(w[0]).cString());
    Stdio.printf("phi %s\n", String.withU64(phiOnly((u32)2)).cString());
    Stdio.printf("low %d\n", lowOfSum((i64)3000000000, (u32)3));
    Stdio.printf("sum %s\n", String.withI64(sum((i64)0 - (i64)3000000000, (u32)3)).cString());
    Stdio.printf("fib %s\n", String.withU64(fib((u32)90)).cString());
    u32* big = new u32[4];
    big[0] = (u32)0xFFFFFFFF;
    big[1] = (u32)0xFFFFFFFF;
    big[2] = (u32)0xFFFFFFFF;
    big[3] = (u32)0xFFFFFFFF;
    Stdio.printf("2^128-1 %s\n", decimal(big, (u32)4).cString());
}
