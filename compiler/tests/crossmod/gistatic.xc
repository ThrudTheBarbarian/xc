// gistatic.xc — links giextra.o (-static, x86-64) and checks the header in
// front of its global instance: the magic and the immortal count, which a
// thousand retains and releases of `&gSpot` move and put back, leaving the
// global after the instance alone.
#import "Stdio.xc"
#import "Array.xc"
class Spot : Object { i32 a; }
Spot* spot(void);
u32 next(void);
i32 main(void)
    {
    u32* h = (u32*)(pointer)spot() - 2;
    Stdio.printf("header %x %x\n", h[0], h[1]);
    Array* arr = new Array();
    for (i32 i = 0; i < 1000; i = i + 1)
        arr.add(spot());
    Stdio.printf("held %x\n", h[1]);
    arr.removeAll();
    Stdio.printf("released %x next %d\n", h[1], next());
    return 0;
    }
