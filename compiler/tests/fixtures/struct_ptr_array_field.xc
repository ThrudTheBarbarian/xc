// struct_ptr_array_field.xc — subscripting an array FIELD through a struct
// POINTER (blewit finding #6). `c.buf[i]` with `c: C*` (dot form — the sugar
// for arrow) used to fall into addressOfStructLValue on the bare identifier
// and abandon with "struct 'c' is neither a pinned local, global, nor ivar";
// only value bases worked. Reads, writes, AND `&c.buf[i]` element addresses —
// the hiredis binding took a u8* byte-offset workaround for exactly this.
#use Stdio

struct C
{
    u8  tag;
    u8  buf[8];
    u32 tail;
}

void fillVia(C* c)
{
    for (u8 i = 0; i < 8; i = i + 1) { c.buf[i] = i * 3; }
    c.tag = $AA;
    c.tail = 123456;
}

u8 readVia(C* c, u8 i)
{
    return c.buf[i];
}

i32 main()
{
    C local;
    C* c = &local;
    fillVia(c);

    // Element ADDRESS through the pointer — the exact finding-#6 shape.
    u8* p2 = &c.buf[2];
    u8* p5 = &c.buf[5];
    printf("p2=%u p5=%u\n", *p2, *p5);

    // Write through the taken address, read back through the subscript.
    *p2 = 99;
    printf("rb=%u via=%u\n", c.buf[2], readVia(c, 2));

    // Neighbours undamaged (the workaround era's risk was mis-scaled strides).
    printf("tag=%x tail=%ld sum=%u\n", (u16)c.tag, c.tail,
           (u16)(c.buf[0] + c.buf[1] + c.buf[3] + c.buf[4]));
    return 0;
}
