// `struct X :packed { … }` (blewit item 3, Task #1081). Total size becomes
//xtc-na: m68k — m68k struct sizes follow the m68k C ABI since blewit #5 (fields and sizeof align to 2, so the unpacked EvPadded is 12 not 16); the shared oracle encodes the 8-cap sizes and the width-invariant tripwire guards the m68k rule
// the RAW field-width sum — no tail rounding to natural alignment — which
// is the byte-compatibility knob for kernel/wire structs: epoll_event is
// u32 @0 + u64 @4, size 12, and the padded sizeof of 16 mis-strided every
// events[] array the kernel filled. Field OFFSETS are unchanged: xtc packs
// those tightly on every target regardless, so `:packed` means exactly
// "packed as much as the layout ever could be" — no per-target refusals.
// The array probes below are what a wrong stride cannot survive.
#use Stdio

struct Ev :packed
{
    u32 events;
    u64 data;
}

struct EvPadded
{
    u32 events;
    u64 data;
}

struct Odd :packed
{
    u8  tag;
    u16 v;
}

i32 main(void)
{
    Stdio.printf("packed=%d padded=%d odd=%d\n",
                 (u16)sizeof(Ev), (u16)sizeof(EvPadded), (u16)sizeof(Odd));

    Ev e;
    e.events = (u32)$11223344;
    e.data = (u64)$DEADBEEF;
    Stdio.printf("ev=%lx data=%lx\n", e.events, (u32)e.data);

    Ev arr[3];
    for (u16 i = (u16)0; i < (u16)3; i++) {
        arr[i].events = (u32)i + (u32)$50;
        arr[i].data = (u64)i + (u64)$A0;
    }
    Stdio.printf("stride=%lx,%lx %lx,%lx %lx,%lx\n",
                 arr[0].events, (u32)arr[0].data,
                 arr[1].events, (u32)arr[1].data,
                 arr[2].events, (u32)arr[2].data);

    Odd o;
    o.tag = (u8)$DE;
    o.v = (u16)$BEEF;
    Stdio.printf("odd tag=%x v=%x\n", (u16)o.tag, o.v);
    return 0;
}
