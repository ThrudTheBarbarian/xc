// A float add or multiply of two NaNs with different payloads gives the
// first operand's NaN at every -O level (#726). On x86-64 the back end
// swapped the operands where the second already sat in the result's
// register, so the NaN that came out depended on register allocation.
#import "Stdio.xc"

float ffrom(u32 u) { return *(float*)&u; }
u32 fbits(float f) { return *(u32*)&f; }
double dfrom(u64 u) { return *(double*)&u; }
u64 dbits(double d) { return *(u64*)&d; }

float addk(float x, float y) { float t = y * 1.0f; return x + t; }
float mulk(float x, float y) { float t = y * 1.0f; return x * t; }
double daddk(double x, double y) { double t = y * 1.0d; return x + t; }

i32 main(void)
    {
    float a = ffrom($7FC00102);
    float b = ffrom($7FC00103);
    double da = dfrom($7FF8000000000102);
    double db = dfrom($7FF8000000000103);
    Stdio.printf("%x %x %x %lx\n", fbits(a + b), fbits(addk(a, b)), fbits(mulk(a, b)), dbits(daddk(da, db)));
    return 0;
    }
