//xtc-flags: target=arm64
//xtc-warn: because it uses double, which Apple GPUs do not have
//xtc-warn: because it uses a captured value its Vulkan version cannot hold
// par_capture_kinds.xc — every kind of capture a par body may take: pointers
// (heap, simd:, a fixed array, a string, a plain pointer), scalars of each
// width, a bool, a struct and an enum. The hoisted locals in run() cover the
// pointers and scalars; the struct and enum stay as ivar reads.
#import "Stdio.xc"
#import "Par.xc"

struct Px
    {
    u8 r;
    u8 g;
    }

enum Mode = {Slow, Fast};

i32 main(void)
    {
    u32 n = (u32)256;
    u32* a = new u32[n];
    simd: u32* b = new u32[n];
    u32 fixed[256];
    string s = "abc";
    pointer raw = (pointer)a;
    i8 k8 = (i8)1; u8 ku8 = (u8)2; i16 k16 = (i16)3; u16 ku16 = (u16)4;
    i32 k32 = (i32)5; u32 ku32 = (u32)6; i64 k64 = (i64)7; u64 ku64 = (u64)8;
    float kf = 1.5f; double kd = 2.5; bool flag = true;
    Px p; p.r = (u8)3; p.g = (u8)4;
    Mode m = Fast;
    for (u32 i in 0..n) { a[i] = i; b[i] = i; fixed[i] = i; }
    u64 total = (u64)0;
    par kinds :reduce(+ total)
        {
        for (u32 i in 0..n)
            {
            u32 v = a[i] + b[i] + fixed[i] + (u32)s[0] + (u32)((u32*)raw)[i];
            v = v + (u32)k8 + (u32)ku8 + (u32)k16 + (u32)ku16 + (u32)k32 + ku32 + (u32)k64 + (u32)ku64;
            v = v + (u32)kf + (u32)kd + (flag ? (u32)1 : (u32)0) + (u32)p.r + (u32)p.g + (m == Fast ? (u32)1 : (u32)0);
            b[i] = v;
            total = total + (u64)v;
            }
        }
    Stdio.printf("%lu %u\n", total, b[255]);
    return (i32)0;
    }
