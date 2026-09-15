//xtc-flags: target=arm64
// class_big_ivar_offset.xc — finding #13: an ivar sitting BEHIND a 32KB array
// ivar has a field offset that is neither under 4096 nor a multiple of it, so
// the arm64 backend's single `add xD, xN, #off` failed to encode
// (`add x10, x16, #32796: imm out of range`) and the program did not link.
// Heap objects are not bounded by the 16KB frame budget, so this is a distinct
// trigger from the #1151 frame-offset family. The struct half covers the same
// overflow in the aggregate paths: a field past #4095 in a >4KB struct
// overflows the narrow ldr/str immediates (AggExtract/AggInsert), and a
// >4KB struct COPY's sub-8-byte tail overflows strb/strh (emitAggCopy).
#use Stdio

struct Wide { u8 head; u8 pad[4200]; u8 tail; }   // tail at #4201: past the imm12

class Poller {
    u8 buf[32768];
    u32 tally;
    u8 mark;
    void init(void) { tally = (u32)7; mark = (u8)3; buf[(u32)32000] = (u8)42; }
    u32 peek(void) { return tally + (u32)mark + (u32)buf[(u32)32000]; }
}

void classHalf(void)
{
    Poller@ p = new Poller();
    printf("%lu\n", p.peek());              // 7 + 3 + 42 = 52
    p.tally = (u32)100;
    p.mark = (u8)9;
    printf("%lu\n", p.peek());              // 100 + 9 + 42 = 151
    return;
}

void structHalf(void)
{
    Wide a;
    a.head = (u8)1;
    a.tail = (u8)5;
    Wide b = a;                             // >4KB struct copy, sub-8 tail
    b.tail = (u8)6;
    printf("%d %d\n", (i16)a.tail, (i16)b.tail);   // 5 6
    return;
}

i32 main(void)
{
    classHalf();
    structHalf();
    return 0;
}
