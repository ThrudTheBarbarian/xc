// struct_copy — pass and return a small struct by value.
// Exercises: struct copy semantics, field layout, argument passing.
#import "Stdio.xc"
struct Pt { u32 x, y; }
Pt bump(Pt p, u32 d) { Pt q; q.x = p.x + d; q.y = p.y ^ d; return q; }
i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc; u32 acc = (u32)0;
    Pt p; p.x = seed; p.y = seed;
    for (u32 r = (u32)0; r < (u32)4000000; r++)
        { p = bump(p, r); acc = acc + p.x + p.y; }
    Stdio.printf("%lu\n", acc);
    return 0;
    }
