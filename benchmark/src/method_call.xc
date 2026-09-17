// method_call — a virtual method call per iteration.
// Exercises: dispatch cost, inlining across a method boundary.
#import "Stdio.xc"

class Shape      { u32 k; void init(u32 x) { k = x; } u32 score(void) { return k; } }
class Boxy : Shape
    {
    void init(u32 x) { super.init(x); }
    u32 score(void)  { return k + (u32)1; }
    }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    Shape* s = new Boxy(seed);
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)8000000; r++) acc = acc + s.score() + r;
    Stdio.printf("%lu\n", acc);
    return 0;
    }
