// A float argument and result through a function pointer, a bound method and a
// callback made from a free function. On arm64 the result comes back in s0,
// not w0 (bug 290: the reference read w0 and printed 0 0 0).
#import "Stdio.xc"

typedef float fop_t(float);

float half(float f)
{
    return f / (float)2;
}

class K
    {
    float h(float f)
        {
        return f / (float)2;
        }
    }

i32 main(void)
{
    fop_t* p = &half;
    float a = p((float)9);
    K* k = new K();
    callback hm float(float f) = &k.h;
    float b = (float)0;
    if (hm)
        b = hm((float)9);
    callback hf float(float f) = &half;
    float c = (float)0;
    if (hf)
        c = hf((float)9);
    Stdio.printf("%d %d %d\n", (i32)(a * (float)10), (i32)(b * (float)10), (i32)(c * (float)10));
    return 0;
}
