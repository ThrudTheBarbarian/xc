// arc_alloc — allocate an object per iteration and let ARC free it.
// Exercises: heap allocation, retain/release traffic, method dispatch.
#import "Stdio.xc"

class Node
    {
    u32 v;
    void init(u32 x) { v = x; }
    u32 get(void)    { return v; }
    }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    u32 acc  = (u32)0;
    for (u32 r = (u32)0; r < (u32)2000000; r++)
        {
        Node* n = new Node(r + seed);
        acc = acc + n.get();
        }
    Stdio.printf("%lu\n", acc);
    return 0;
    }
