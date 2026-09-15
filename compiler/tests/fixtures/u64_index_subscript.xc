// u64_index_subscript.xc — subscripting with a 64-BIT index (blewit finding
// #8). `pointerField[i]` with a u64 `i` made the arm64 backend emit
// `ldr xN, [xN, xM, uxtw #3]` — invalid AArch64 (uxtw is a W-index form; the
// hardware would silently read only wM), which the in-house assembler then
// ACCEPTED and encoded as the W form. The backend now uses the X-register
// `lsl` form for 64-bit indices, and both assemblers reject a width-
// mismatched extend outright. The large-index probe is what the truncated
// W-read cannot survive when the index's low 32 bits differ from its value.
#use Stdio

struct T { u8 pad; u64* words; u32* ints; }

i32 main()
{
    u64 store[8];
    u32 istore[8];
    T t;
    t.words = &store[0];
    t.ints = &istore[0];

    for (u64 i = 0; i < 8; i = i + 1) {
        t.words[i] = i * 1000 + 7;      // u64 index, 8-byte stride
        t.ints[i] = (u32)(i * 11);      // u64 index, 4-byte stride
    }
    u64 sum = 0;
    for (u64 i = 0; i < 8; i = i + 1) { sum = sum + t.words[i]; }
    printf("sum=%ld i3=%ld u5=%ld\n", (u32)sum, (u32)t.words[3], t.ints[5]);

    // A 64-bit index whose LOW 32 BITS are zero: the truncated-W read would
    // address element 0 instead. (In-bounds: index (1<<32) is out of range,
    // so probe via pointer arithmetic that lands back inside the array.)
    u64* base = &store[0];
    u64 big = ((u64)1 << 32) + 2;
    u64* wrapped = &base[big - ((u64)1 << 32)];   // = &base[2], via u64 math
    printf("w2=%ld\n", (u32)*wrapped);
    return 0;
}
