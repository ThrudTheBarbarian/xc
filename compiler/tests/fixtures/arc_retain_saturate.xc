// arc_retain_saturate.xc — an object retained more than 65,535 times at once.
//
// xt6502, arm9, m68k and wasm32 keep a 16-bit retain count. It saturates at
// $FFFF: a retain at $FFFF leaves it there, and so does a release, so an
// object that reaches the ceiling is never freed. It used to wrap to 0 on arm9,
// m68k and wasm32, and on xt6502 a release took a saturated count back down;
// either way the object was freed while references to it were still live
// (bug 261). The 64-bit hosts keep a 32-bit count and simply count to 70001.
//
// The count is driven with the container intrinsics so no 70,000-slot array is
// needed on the small targets. The object must survive every release, keep its
// ivars, answer a method call, and not share its block with a later
// allocation.
#import "Foundation.xc"
#import "Stdio.xc"

u16 gFreed;

class Box : Object
{
    u32 _tag;
    void init(void) { _tag = (u32)0; }
    u32 tag(void) { return _tag; }
    void dealloc(void) { gFreed = gFreed + (u16)1; }
}

i32 main(void)
{
    gFreed = (u16)0;
    Box* b = new Box();
    b._tag = (u32)123456;
    u32 n = (u32)70000;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        __arc_retain((pointer)b);
    Stdio.printf("retained: freed=%d\n", gFreed);
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        __arc_release((pointer)b);
    Stdio.printf("released: freed=%d\n", gFreed);

    // A freed block would be handed out again here and overwritten.
    Box* c = new Box();
    c._tag = (u32)777;
    Box* d = new Box();
    d._tag = (u32)888;
    Stdio.printf("tag=%ld method=%ld other=%ld,%ld\n", b._tag, b.tag(), c._tag, d._tag);
    Stdio.printf("distinct=%d freed=%d\n", ((pointer)b != (pointer)c && (pointer)b != (pointer)d) ? 1 : 0, gFreed);
    return 0;
}
