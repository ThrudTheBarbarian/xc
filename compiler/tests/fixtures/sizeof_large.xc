//xtc-na: xt6502 — sizeof is a u16 on the 6502, so a 1 MB buffer's size is refused there
// sizeof is the target's size type, as C's size_t: u64 where pointers are 8
// bytes, u32 where they are 4, u16 on the banked 6502. It was always u16, so
// the size of anything over 64 KB wrapped (this buffer's read 0) (bug 615).
#import "Stdio.xc"
u8 buffer[1024 * 1024];
struct P { u32 x; u16 y; }
i32 main(void)
{
    u32 size = sizeof(buffer);
    u16 small = sizeof(P);
    Stdio.printf("%u %u %u\n", size, (u32)small, (u32)sizeof(u64));
    return 0;
}
