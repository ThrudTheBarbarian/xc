// new_object_over_64k.xc — an object larger than 64 KiB is allocated whole.
// Monokracy M4: every World is ~75 KB of fields, and `new W` allocated it
// SHORT on x86-64. The allocator's stride was emitted as a u16 constant while
// carrying a larger value: arm64 materialised all 32 bits, x86-64 put it
// through a 16-bit register, so a 65544-byte class was handed an 8-byte block
// and init() wrote past it. Threshold: the object's own size must exceed
// 65535, so the array is one element past a 64 KiB field.
//
//xtc-na: xt6502, arm9, m68k — a banked or 16-bit-address target cannot hold an object this big
#import "Stdio.xc"

class Big : Object
{
    i32 a[16384];                    // 65536 bytes + the header > 65535
    void init(void)
    {
        i32 i = (i32)0;
        while (i < (i32)16384) { a[i] = i; i = i + (i32)1; }
    }
}

i32 main(void)
{
    Big* b = new Big();
    Stdio.printf("first %d last %d\n", b.a[0], b.a[16383]);
    return 0;
}
