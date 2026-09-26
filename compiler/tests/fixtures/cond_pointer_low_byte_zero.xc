// cond_pointer_low_byte_zero.xc — bug 272. A pointer or a callback used as a
// condition is true when it is not null. xt6502 tested only its low byte, so a
// pointer to $xx00 read as null: a comparator placed at $9000 made
// Array.sortUsing skip every comparison and leave the array unsorted.

#import "Stdio.xc"

u8 gBuf[512];

i8 one(Object* a, Object* b) { return (i8)1; }

u16 test(u8* p, callback cmp i8(Object* a, Object* b))
{
    u16 r = (u16)0;
    if (p) r = r + (u16)1;
    if (!p) r = r + (u16)10;
    if (cmp) r = r + (u16)100;
    return r;
}

void main(void)
{
    // An address whose low byte is 0, and null.
    u8* p = &gBuf[0];
    u16 off = (u16)(256 - (u16)((u32)(pointer)p & (u32)$FF));
    u8* z = &gBuf[off & (u16)$FF];
    Stdio.printf("low byte %u\n", (u16)((u32)(pointer)z & (u32)$FF));
    Stdio.printf("aligned %u\n", test(z, &one));
    Stdio.printf("null %u\n", test((u8*)0, &one));
}
