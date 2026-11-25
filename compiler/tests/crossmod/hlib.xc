// hlib.xc — a library with the 16-bit floats in its interface: functions
// taking and returning f16 and bf16, a struct with f16 and bf16 fields, and a
// class holding one. See f16-lib.sh.
#import "Stdio.xc"

struct HPoint
{
    f16 x;
    bf16 y;
};

f16 half(f32 v)
{
    return (f16)(v / 2);
}

bf16 brain(f16 h)
{
    return (bf16)h * 4;
}

HPoint hpoint(f16 x, bf16 y)
{
    HPoint p;
    p.x = x;
    p.y = y;
    return p;
}

class HScale : Object
    {
    f16 factor;
    void init(f16 k) { factor = k; }
    f16 apply(f16 v) { return v * factor; }
    }
