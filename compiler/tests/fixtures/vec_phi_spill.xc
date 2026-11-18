// vec_phi_spill.xc — many vector accumulators live through one loop (#307).
//
// The escape vectoriser runs an item loop across items, and every value the
// counted inner loop carries becomes a vector phi there. With more of them than
// the back end has vector registers (36 here: arm64 has 19 at most, x86-64 14,
// and 30 for the AVX-512 copy), the phis themselves have to live in frame
// slots. The phi classes were never given up, so the build stopped with
// "vector register pressure exceeded". Each item is checked against the same
// chains run one item at a time; the blocks stay on the CPU, whose code this is.

#import "Stdio.xc"
#import "Par.xc"

#define N 1024
u32 iv[N];
float fv[N];

u32 serialU(u32 i, u32 k)
    {
    u32 a0 = i * (u32)2246822519;
    u32 a1 = a0 ^ (u32)40510;
    u32 a2 = a0 ^ (u32)81013;
    u32 a3 = a0 ^ (u32)121516;
    u32 a4 = a0 ^ (u32)162019;
    u32 a5 = a0 ^ (u32)202522;
    u32 a6 = a0 ^ (u32)243025;
    u32 a7 = a0 ^ (u32)283528;
    u32 a8 = a0 ^ (u32)324031;
    u32 a9 = a0 ^ (u32)364534;
    u32 a10 = a0 ^ (u32)405037;
    u32 a11 = a0 ^ (u32)445540;
    u32 a12 = a0 ^ (u32)486043;
    u32 a13 = a0 ^ (u32)526546;
    u32 a14 = a0 ^ (u32)567049;
    u32 a15 = a0 ^ (u32)607552;
    u32 a16 = a0 ^ (u32)648055;
    u32 a17 = a0 ^ (u32)688558;
    u32 a18 = a0 ^ (u32)729061;
    u32 a19 = a0 ^ (u32)769564;
    u32 a20 = a0 ^ (u32)810067;
    u32 a21 = a0 ^ (u32)850570;
    u32 a22 = a0 ^ (u32)891073;
    u32 a23 = a0 ^ (u32)931576;
    u32 a24 = a0 ^ (u32)972079;
    u32 a25 = a0 ^ (u32)1012582;
    u32 a26 = a0 ^ (u32)1053085;
    u32 a27 = a0 ^ (u32)1093588;
    u32 a28 = a0 ^ (u32)1134091;
    u32 a29 = a0 ^ (u32)1174594;
    u32 a30 = a0 ^ (u32)1215097;
    u32 a31 = a0 ^ (u32)1255600;
    u32 a32 = a0 ^ (u32)1296103;
    u32 a33 = a0 ^ (u32)1336606;
    u32 a34 = a0 ^ (u32)1377109;
    u32 a35 = a0 ^ (u32)1417612;
    for (u32 r = (u32)0; r < (u32)40; r = r + (u32)1)
        {
        a0 = a0 * k + (u32)1;
        a1 = a1 * k + (u32)3;
        a2 = a2 * k + (u32)5;
        a3 = a3 * k + (u32)7;
        a4 = a4 * k + (u32)9;
        a5 = a5 * k + (u32)11;
        a6 = a6 * k + (u32)13;
        a7 = a7 * k + (u32)15;
        a8 = a8 * k + (u32)17;
        a9 = a9 * k + (u32)19;
        a10 = a10 * k + (u32)21;
        a11 = a11 * k + (u32)23;
        a12 = a12 * k + (u32)25;
        a13 = a13 * k + (u32)27;
        a14 = a14 * k + (u32)29;
        a15 = a15 * k + (u32)31;
        a16 = a16 * k + (u32)33;
        a17 = a17 * k + (u32)35;
        a18 = a18 * k + (u32)37;
        a19 = a19 * k + (u32)39;
        a20 = a20 * k + (u32)41;
        a21 = a21 * k + (u32)43;
        a22 = a22 * k + (u32)45;
        a23 = a23 * k + (u32)47;
        a24 = a24 * k + (u32)49;
        a25 = a25 * k + (u32)51;
        a26 = a26 * k + (u32)53;
        a27 = a27 * k + (u32)55;
        a28 = a28 * k + (u32)57;
        a29 = a29 * k + (u32)59;
        a30 = a30 * k + (u32)61;
        a31 = a31 * k + (u32)63;
        a32 = a32 * k + (u32)65;
        a33 = a33 * k + (u32)67;
        a34 = a34 * k + (u32)69;
        a35 = a35 * k + (u32)71;
        }
    return a0 + a1 + a2 + a3 + a4 + a5
        + a6 + a7 + a8 + a9 + a10 + a11
        + a12 + a13 + a14 + a15 + a16 + a17
        + a18 + a19 + a20 + a21 + a22 + a23
        + a24 + a25 + a26 + a27 + a28 + a29
        + a30 + a31 + a32 + a33 + a34 + a35;
    }

float serialF(u32 i, float kf)
    {
    float a0 = (float)(i & (u32)7) * 0.001f;
    float a1 = a0 + 1.0f;
    float a2 = a0 + 2.0f;
    float a3 = a0 + 3.0f;
    float a4 = a0 + 4.0f;
    float a5 = a0 + 5.0f;
    float a6 = a0 + 6.0f;
    float a7 = a0 + 7.0f;
    float a8 = a0 + 8.0f;
    float a9 = a0 + 9.0f;
    float a10 = a0 + 10.0f;
    float a11 = a0 + 11.0f;
    float a12 = a0 + 12.0f;
    float a13 = a0 + 13.0f;
    float a14 = a0 + 14.0f;
    float a15 = a0 + 15.0f;
    float a16 = a0 + 16.0f;
    float a17 = a0 + 17.0f;
    float a18 = a0 + 18.0f;
    float a19 = a0 + 19.0f;
    float a20 = a0 + 20.0f;
    float a21 = a0 + 21.0f;
    float a22 = a0 + 22.0f;
    float a23 = a0 + 23.0f;
    float a24 = a0 + 24.0f;
    float a25 = a0 + 25.0f;
    float a26 = a0 + 26.0f;
    float a27 = a0 + 27.0f;
    float a28 = a0 + 28.0f;
    float a29 = a0 + 29.0f;
    float a30 = a0 + 30.0f;
    float a31 = a0 + 31.0f;
    float a32 = a0 + 32.0f;
    float a33 = a0 + 33.0f;
    float a34 = a0 + 34.0f;
    float a35 = a0 + 35.0f;
    for (u32 r = (u32)0; r < (u32)40; r = r + (u32)1)
        {
        a0 = a0 * kf + 0.5f;
        a1 = a1 * kf + 0.5f;
        a2 = a2 * kf + 0.5f;
        a3 = a3 * kf + 0.5f;
        a4 = a4 * kf + 0.5f;
        a5 = a5 * kf + 0.5f;
        a6 = a6 * kf + 0.5f;
        a7 = a7 * kf + 0.5f;
        a8 = a8 * kf + 0.5f;
        a9 = a9 * kf + 0.5f;
        a10 = a10 * kf + 0.5f;
        a11 = a11 * kf + 0.5f;
        a12 = a12 * kf + 0.5f;
        a13 = a13 * kf + 0.5f;
        a14 = a14 * kf + 0.5f;
        a15 = a15 * kf + 0.5f;
        a16 = a16 * kf + 0.5f;
        a17 = a17 * kf + 0.5f;
        a18 = a18 * kf + 0.5f;
        a19 = a19 * kf + 0.5f;
        a20 = a20 * kf + 0.5f;
        a21 = a21 * kf + 0.5f;
        a22 = a22 * kf + 0.5f;
        a23 = a23 * kf + 0.5f;
        a24 = a24 * kf + 0.5f;
        a25 = a25 * kf + 0.5f;
        a26 = a26 * kf + 0.5f;
        a27 = a27 * kf + 0.5f;
        a28 = a28 * kf + 0.5f;
        a29 = a29 * kf + 0.5f;
        a30 = a30 * kf + 0.5f;
        a31 = a31 * kf + 0.5f;
        a32 = a32 * kf + 0.5f;
        a33 = a33 * kf + 0.5f;
        a34 = a34 * kf + 0.5f;
        a35 = a35 * kf + 0.5f;
        }
    return a0 + a1 + a2 + a3 + a4 + a5
        + a6 + a7 + a8 + a9 + a10 + a11
        + a12 + a13 + a14 + a15 + a16 + a17
        + a18 + a19 + a20 + a21 + a22 + a23
        + a24 + a25 + a26 + a27 + a28 + a29
        + a30 + a31 + a32 + a33 + a34 + a35;
    }

i32 main(i32 argc, u8** argv)
    {
    u32 k = (u32)argc * (u32)2654435761;
    float kf = (float)argc * 0.999f;
    par ints :device(cpu)
        {
        for (u32 i in 0..(u32)N)
            {
            u32 a0 = i * (u32)2246822519;
            u32 a1 = a0 ^ (u32)40510;
            u32 a2 = a0 ^ (u32)81013;
            u32 a3 = a0 ^ (u32)121516;
            u32 a4 = a0 ^ (u32)162019;
            u32 a5 = a0 ^ (u32)202522;
            u32 a6 = a0 ^ (u32)243025;
            u32 a7 = a0 ^ (u32)283528;
            u32 a8 = a0 ^ (u32)324031;
            u32 a9 = a0 ^ (u32)364534;
            u32 a10 = a0 ^ (u32)405037;
            u32 a11 = a0 ^ (u32)445540;
            u32 a12 = a0 ^ (u32)486043;
            u32 a13 = a0 ^ (u32)526546;
            u32 a14 = a0 ^ (u32)567049;
            u32 a15 = a0 ^ (u32)607552;
            u32 a16 = a0 ^ (u32)648055;
            u32 a17 = a0 ^ (u32)688558;
            u32 a18 = a0 ^ (u32)729061;
            u32 a19 = a0 ^ (u32)769564;
            u32 a20 = a0 ^ (u32)810067;
            u32 a21 = a0 ^ (u32)850570;
            u32 a22 = a0 ^ (u32)891073;
            u32 a23 = a0 ^ (u32)931576;
            u32 a24 = a0 ^ (u32)972079;
            u32 a25 = a0 ^ (u32)1012582;
            u32 a26 = a0 ^ (u32)1053085;
            u32 a27 = a0 ^ (u32)1093588;
            u32 a28 = a0 ^ (u32)1134091;
            u32 a29 = a0 ^ (u32)1174594;
            u32 a30 = a0 ^ (u32)1215097;
            u32 a31 = a0 ^ (u32)1255600;
            u32 a32 = a0 ^ (u32)1296103;
            u32 a33 = a0 ^ (u32)1336606;
            u32 a34 = a0 ^ (u32)1377109;
            u32 a35 = a0 ^ (u32)1417612;
            for (u32 r = (u32)0; r < (u32)40; r = r + (u32)1)
                {
                a0 = a0 * k + (u32)1;
                a1 = a1 * k + (u32)3;
                a2 = a2 * k + (u32)5;
                a3 = a3 * k + (u32)7;
                a4 = a4 * k + (u32)9;
                a5 = a5 * k + (u32)11;
                a6 = a6 * k + (u32)13;
                a7 = a7 * k + (u32)15;
                a8 = a8 * k + (u32)17;
                a9 = a9 * k + (u32)19;
                a10 = a10 * k + (u32)21;
                a11 = a11 * k + (u32)23;
                a12 = a12 * k + (u32)25;
                a13 = a13 * k + (u32)27;
                a14 = a14 * k + (u32)29;
                a15 = a15 * k + (u32)31;
                a16 = a16 * k + (u32)33;
                a17 = a17 * k + (u32)35;
                a18 = a18 * k + (u32)37;
                a19 = a19 * k + (u32)39;
                a20 = a20 * k + (u32)41;
                a21 = a21 * k + (u32)43;
                a22 = a22 * k + (u32)45;
                a23 = a23 * k + (u32)47;
                a24 = a24 * k + (u32)49;
                a25 = a25 * k + (u32)51;
                a26 = a26 * k + (u32)53;
                a27 = a27 * k + (u32)55;
                a28 = a28 * k + (u32)57;
                a29 = a29 * k + (u32)59;
                a30 = a30 * k + (u32)61;
                a31 = a31 * k + (u32)63;
                a32 = a32 * k + (u32)65;
                a33 = a33 * k + (u32)67;
                a34 = a34 * k + (u32)69;
                a35 = a35 * k + (u32)71;
                }
            iv[i] = a0 + a1 + a2 + a3 + a4 + a5
                + a6 + a7 + a8 + a9 + a10 + a11
                + a12 + a13 + a14 + a15 + a16 + a17
                + a18 + a19 + a20 + a21 + a22 + a23
                + a24 + a25 + a26 + a27 + a28 + a29
                + a30 + a31 + a32 + a33 + a34 + a35;
            }
        }
    par floats :device(cpu)
        {
        for (u32 i in 0..(u32)N)
            {
            float a0 = (float)(i & (u32)7) * 0.001f;
            float a1 = a0 + 1.0f;
            float a2 = a0 + 2.0f;
            float a3 = a0 + 3.0f;
            float a4 = a0 + 4.0f;
            float a5 = a0 + 5.0f;
            float a6 = a0 + 6.0f;
            float a7 = a0 + 7.0f;
            float a8 = a0 + 8.0f;
            float a9 = a0 + 9.0f;
            float a10 = a0 + 10.0f;
            float a11 = a0 + 11.0f;
            float a12 = a0 + 12.0f;
            float a13 = a0 + 13.0f;
            float a14 = a0 + 14.0f;
            float a15 = a0 + 15.0f;
            float a16 = a0 + 16.0f;
            float a17 = a0 + 17.0f;
            float a18 = a0 + 18.0f;
            float a19 = a0 + 19.0f;
            float a20 = a0 + 20.0f;
            float a21 = a0 + 21.0f;
            float a22 = a0 + 22.0f;
            float a23 = a0 + 23.0f;
            float a24 = a0 + 24.0f;
            float a25 = a0 + 25.0f;
            float a26 = a0 + 26.0f;
            float a27 = a0 + 27.0f;
            float a28 = a0 + 28.0f;
            float a29 = a0 + 29.0f;
            float a30 = a0 + 30.0f;
            float a31 = a0 + 31.0f;
            float a32 = a0 + 32.0f;
            float a33 = a0 + 33.0f;
            float a34 = a0 + 34.0f;
            float a35 = a0 + 35.0f;
            for (u32 r = (u32)0; r < (u32)40; r = r + (u32)1)
                {
                a0 = a0 * kf + 0.5f;
                a1 = a1 * kf + 0.5f;
                a2 = a2 * kf + 0.5f;
                a3 = a3 * kf + 0.5f;
                a4 = a4 * kf + 0.5f;
                a5 = a5 * kf + 0.5f;
                a6 = a6 * kf + 0.5f;
                a7 = a7 * kf + 0.5f;
                a8 = a8 * kf + 0.5f;
                a9 = a9 * kf + 0.5f;
                a10 = a10 * kf + 0.5f;
                a11 = a11 * kf + 0.5f;
                a12 = a12 * kf + 0.5f;
                a13 = a13 * kf + 0.5f;
                a14 = a14 * kf + 0.5f;
                a15 = a15 * kf + 0.5f;
                a16 = a16 * kf + 0.5f;
                a17 = a17 * kf + 0.5f;
                a18 = a18 * kf + 0.5f;
                a19 = a19 * kf + 0.5f;
                a20 = a20 * kf + 0.5f;
                a21 = a21 * kf + 0.5f;
                a22 = a22 * kf + 0.5f;
                a23 = a23 * kf + 0.5f;
                a24 = a24 * kf + 0.5f;
                a25 = a25 * kf + 0.5f;
                a26 = a26 * kf + 0.5f;
                a27 = a27 * kf + 0.5f;
                a28 = a28 * kf + 0.5f;
                a29 = a29 * kf + 0.5f;
                a30 = a30 * kf + 0.5f;
                a31 = a31 * kf + 0.5f;
                a32 = a32 * kf + 0.5f;
                a33 = a33 * kf + 0.5f;
                a34 = a34 * kf + 0.5f;
                a35 = a35 * kf + 0.5f;
                }
            fv[i] = a0 + a1 + a2 + a3 + a4 + a5
                + a6 + a7 + a8 + a9 + a10 + a11
                + a12 + a13 + a14 + a15 + a16 + a17
                + a18 + a19 + a20 + a21 + a22 + a23
                + a24 + a25 + a26 + a27 + a28 + a29
                + a30 + a31 + a32 + a33 + a34 + a35;
            }
        }
    u32 bad = (u32)0;
    u32 sum = (u32)0;
    double fsum = 0.0;
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1)
        {
        if (iv[i] != serialU(i, k)) bad = bad + (u32)1;
        if (fv[i] != serialF(i, kf)) bad = bad + (u32)1;
        sum = sum * (u32)31 + iv[i];
        fsum = fsum + (double)fv[i];
        }
    Stdio.printf("%u %u %u %.3f %.3f\n", bad, sum, iv[(u32)5], (double)fv[(u32)5], fsum);
    return (i32)0;
    }
