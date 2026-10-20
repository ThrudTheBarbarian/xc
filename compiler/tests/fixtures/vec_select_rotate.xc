// vec_select_rotate.xc — the arm64 vector bit select (bsl/bit/bif), the lane
// rotate (shl + usra) and the round-constant table, each checked against the
// same arithmetic done one element at a time. The loop below is forty
// MD5-like rounds: a select written with an and-not (the mask on either
// side), the same select in its xor form, a three-way xor, and a rotate by a
// different amount each round. Forty constants make the body big enough that
// they come from a read-only table (one load each) rather than being splatted
// in registers. Lane by lane, the vector loop must give the scalar one's sums.
#import "Stdio.xc"

#define N 1003

u32 x[N];
u32 y[N];

u32 rounds(u32 n)
{
    u32 total = (u32)0;
    for (u32 i in 0..n)
        {
            u32 a = x[i];
            u32 b = y[i];
            u32 c = a ^ (u32)0x5bd1e995;
            u32 d = b + (u32)0x1b873593;
            { u32 t = a + ((b & c) | (~b & d)) + (u32)2675342405; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)3185950873; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)4051686260; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)2787324501; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3869338171; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)486215926; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1059022248; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)2335435112; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)2465058629; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)930847394; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1200367645; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)3288765765; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3423720279; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)2651938379; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)544169062; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)3742654890; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)4219466551; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)3746962816; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1242556253; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)4129516530; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)879521323; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)2966284567; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)3838591282; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)1283288560; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)1551298954; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)625784932; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)279772928; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)1451255993; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)1331259175; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)3515508378; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1356321087; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)2066817247; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3026530898; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)244817139; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)3220345089; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)3628735802; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3383310246; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)1572750345; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)38991381; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)844054145; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            total = total + a + b + c + d;
        }
    return total;
}

u32 roundsSerial(u32 n)
{
    u32 total = (u32)0;
    for (u32 i in 0..n) : serial
        {
            u32 a = x[i];
            u32 b = y[i];
            u32 c = a ^ (u32)0x5bd1e995;
            u32 d = b + (u32)0x1b873593;
            { u32 t = a + ((b & c) | (~b & d)) + (u32)2675342405; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)3185950873; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)4051686260; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)2787324501; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3869338171; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)486215926; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1059022248; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)2335435112; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)2465058629; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)930847394; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1200367645; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)3288765765; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3423720279; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)2651938379; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)544169062; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)3742654890; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)4219466551; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)3746962816; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1242556253; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)4129516530; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)879521323; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)2966284567; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)3838591282; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)1283288560; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)1551298954; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)625784932; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)279772928; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)1451255993; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)1331259175; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)3515508378; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)1356321087; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)2066817247; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3026530898; a = d; d = c; c = b; b = b + ((t << (u32)1) | (t >> (u32)31)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)244817139; a = d; d = c; c = b; b = b + ((t << (u32)5) | (t >> (u32)27)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)3220345089; a = d; d = c; c = b; b = b + ((t << (u32)7) | (t >> (u32)25)); }
            { u32 t = a + (b ^ c ^ d) + (u32)3628735802; a = d; d = c; c = b; b = b + ((t << (u32)12) | (t >> (u32)20)); }
            { u32 t = a + ((b & c) | (~b & d)) + (u32)3383310246; a = d; d = c; c = b; b = b + ((t << (u32)17) | (t >> (u32)15)); }
            { u32 t = a + ((b & d) | (c & ~d)) + (u32)1572750345; a = d; d = c; c = b; b = b + ((t << (u32)22) | (t >> (u32)10)); }
            { u32 t = a + (d ^ (b & (c ^ d))) + (u32)38991381; a = d; d = c; c = b; b = b + ((t << (u32)25) | (t >> (u32)7)); }
            { u32 t = a + (b ^ c ^ d) + (u32)844054145; a = d; d = c; c = b; b = b + ((t << (u32)31) | (t >> (u32)1)); }
            total = total + a + b + c + d;
        }
    return total;
}

i32 main(void)
{
    for (u32 i in 0..N)
    {
        x[i] = i * (u32)2654435761;
        y[i] = (i ^ (u32)0xdeadbeef) * (u32)40503;
    }
    u32 v = rounds((u32)N);
    u32 s = roundsSerial((u32)N);
    Stdio.printf("rounds %u serial %u %s\n", v, s, v == s ? "same" : "DIFFER");
    u32 v2 = rounds((u32)7);
    u32 s2 = roundsSerial((u32)7);
    Stdio.printf("short %u serial %u %s\n", v2, s2, v2 == s2 ? "same" : "DIFFER");
    return 0;
}
