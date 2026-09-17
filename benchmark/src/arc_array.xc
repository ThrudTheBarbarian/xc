// arc_array — hold objects in an array and walk them.
// Exercises: retain/release on stored references, field access through a pointer.
#import "Stdio.xc"
#define N 1024

class Cell { u32 v; void init(u32 x) { v = x; } u32 get(void) { return v; } }

i32 main(i32 argc, u8** argv)
    {
    u32 seed = (u32)argc;
    Cell* cells[N];
    for (u32 i = (u32)0; i < (u32)N; i++) cells[i] = new Cell(i + seed);
    u32 acc = (u32)0;
    for (u32 r = (u32)0; r < (u32)20000; r++)
        for (u32 i = (u32)0; i < (u32)N; i++) acc = acc + cells[i].get();
    Stdio.printf("%lu\n", acc);
    return 0;
    }
