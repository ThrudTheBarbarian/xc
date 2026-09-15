// array_slice_heap.xc — for-in slicing on a heap-allocated
// pointer. Mirror of array_slice.xc's tests, but with a heap
// pointer base whose `.length` resolves at runtime via the
// heap-block header. Heap-capable targets only (xl-shadow,
// xe-nobank, xe-heap, xt-heap) — bump allocators don't write
// the header.

#import "Stdio.xc"

void main(void)
{
    u16 fails = 0;

    u8* buf = new u8[10];
    for (u8 i = 0; i < 10; i++) buf[i] = (i + 1) * 10;

    // T1: buf[2..5] half-open should sum 30 + 40 + 50 = 120.
    u16 t1 = 0;
    for (u8 v in buf[2..5]) t1 = t1 + v;
    if (t1 != 120) fails++;

    // T2: buf[..3] open-start should sum 10 + 20 + 30 = 60.
    u16 t2 = 0;
    for (u8 v in buf[..3]) t2 = t2 + v;
    if (t2 != 60) fails++;

    // T3: buf[7..] open-end. Reads buf.length (heap-header lookup)
    // for the cap. Should sum 80 + 90 + 100 = 270.
    u16 t3 = 0;
    for (u8 v in buf[7..]) t3 = t3 + v;
    if (t3 != 270) fails++;

    // T4: buf[2...4] inclusive should sum 30 + 40 + 50 = 120.
    u16 t4 = 0;
    for (u8 v in buf[2...4]) t4 = t4 + v;
    if (t4 != 120) fails++;

    if (fails == 0) Stdio.printf("DONE 4\n");
    else            Stdio.printf("FAIL %u\n", fails);
}
