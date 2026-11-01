// vectorize_escape_jam_fit.xc — the escape vectoriser's copies fit the vector
// registers (2026-11-01).
//
// An item loop whose body runs a counted inner loop is vectorised across
// items, and on arm64 four vectors stand side by side. Three or more
// multiply-add chains carried through the inner loop then needed more than the
// 14 vector registers the back end has, and the build stopped: "vector register
// pressure exceeded the 14-register pool" (0.89 and 0.9; 0.88 built it). The
// copies are halved now until they fit. Three chains and four, in a plain loop
// and in a par block.

#import "Stdio.xc"
#import "Par.xc"

#define N 4096
float out3[N];
float out4[N];
float par3[N];

i32 main(i32 argc, u8** argv)
    {
    float k = (float)argc * 0.999f;
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1)
        {
        float a = (float)(i & (u32)7) * 0.001f;
        float b = a + 1.0f;
        float c = a + 2.0f;
        for (u32 r = (u32)0; r < (u32)256; r = r + (u32)1)
            {
            a = a * k + 0.5f;
            b = b * k + 0.5f;
            c = c * k + 0.5f;
            }
        out3[i] = a + b + c;
        }
    for (u32 i = (u32)0; i < (u32)N; i = i + (u32)1)
        {
        float a = (float)(i & (u32)7) * 0.001f;
        float b = a + 1.0f;
        float c = a + 2.0f;
        float d = a + 3.0f;
        for (u32 r = (u32)0; r < (u32)256; r = r + (u32)1)
            {
            a = a * k + 0.5f;
            b = b * k + 0.5f;
            c = c * k + 0.5f;
            d = d * k + 0.5f;
            }
        out4[i] = a + b + c + d;
        }
    par chains
        {
        for (u32 i in 0..(u32)N)
            {
            float a = (float)(i & (u32)7) * 0.001f;
            float b = a + 1.0f;
            float c = a + 2.0f;
            for (u32 r = (u32)0; r < (u32)256; r = r + (u32)1)
                {
                a = a * k + 0.5f;
                b = b * k + 0.5f;
                c = c * k + 0.5f;
                }
            par3[i] = a + b + c;
            }
        }
    Stdio.printf("%.3f %.3f %.3f %.3f %.3f\n", (double)out3[(u32)5], (double)out3[(u32)4095],
                 (double)out4[(u32)5], (double)out4[(u32)4095], (double)par3[(u32)5]);
    return (i32)0;
    }
