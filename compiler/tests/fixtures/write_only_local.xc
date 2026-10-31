// write_only_local — a struct local whose stores nothing reads (2026-10-31).
// After bump() is inlined, p's frame slot is only ever stored to: its values
// travel in registers. The dead-code pass drops those stores (struct_copy's
// loop went from 11 instructions to 7). q's address reaches a call, so its
// stores stay; r is read back after the loop, so its stores stay too.
#import "Stdio.xc"
struct Pt { u32 x, y; }
Pt bump(Pt p, u32 d) { Pt q; q.x = p.x + d; q.y = p.y ^ d; return q; }
void show(Pt* a) { Stdio.printf("%u %u\n", a.x, a.y); }
i32 main(i32 argc, u8** argv)
    {
    u32 acc = (u32)0;
    Pt p; p.x = (u32)argc; p.y = (u32)argc;
    for (u32 i = (u32)0; i < (u32)1000; i++)
        { p = bump(p, i); acc = acc + p.x + p.y; }
    Pt q; q.x = acc; q.y = acc + (u32)1;
    show(&q);
    Pt r; r.x = (u32)0; r.y = (u32)0;
    for (u32 i = (u32)0; i < (u32)10; i++) { r.x = r.x + i; r.y = r.y ^ i; }
    Stdio.printf("%u %u %u\n", acc, r.x, r.y);
    return 0;
    }
