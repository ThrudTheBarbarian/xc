// gicmain.xc — C code sees a global instance (#641) through its symbol,
// which names the fields (gic.c), with the header before them.
#import "Stdio.xc"
class P : Object { i32 a; i32 b; i32 sum(void) { return a + b; } }
P g;
i32 c_sum(void);
void c_set(i32 a);
pointer c_addr(void);
u32 c_count(void);
i32 main(void)
    {
    g.a = 3;
    g.b = 4;
    Stdio.printf("C sees %d\n", c_sum());
    c_set(30);
    Stdio.printf("xc sees %d %d\n", g.a, g.sum());
    Stdio.printf("same address %d count %x\n", c_addr() == (pointer)&g, c_count());
    return 0;
    }
