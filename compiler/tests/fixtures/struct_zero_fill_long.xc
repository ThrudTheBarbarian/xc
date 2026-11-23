// A struct local with no initialiser, and one with a short `= {…}`, are
// zero-filled however long their array fields are (#617). A long zero tail of
// fixed-width scalars is one MemSet; a short one, a pointer array and an array
// of structs keep their stores. dirty() first fills the same stack depth with
// junk, so a field the zero-fill missed shows up as non-zero.
#import "Stdio.xc"

#if ARCH_6502
#define BIG 300
#else
#define BIG 4200
#endif

struct Inner { u16 a; u8 b; }

struct Wide
    {
    u8 head;
    u8 pad[BIG];
    u32 words[100];
    i16 halves[20];
    float fs[17];
    double ds[16];
    bool flags[40];
    u8 shortRun[3];
    u8* ptrs[20];
    Inner inner[2];
    u8 tail;
    }

u32 junk;

void dirty(void)
    {
    u8 noise[BIG + 1200];
    for (u32 i = (u32)0; i < (u32)(BIG + 1200); i++)
        noise[i] = (u8)(i * (u32)37 + (u32)11) | (u8)1;
    for (u32 i = (u32)0; i < (u32)(BIG + 1200); i = i + (u32)97)
        junk = junk + (u32)noise[i];
    }

// The count of non-zero bytes in every field, so one number checks them all.
u32 nonZero(Wide* w)
    {
    u32 n = (u32)0;
    if (w.head != (u8)0) n++;
    for (u32 i = (u32)0; i < (u32)BIG; i++) if (w.pad[i] != (u8)0) n++;
    for (u32 i = (u32)0; i < (u32)100; i++) if (w.words[i] != (u32)0) n++;
    for (u32 i = (u32)0; i < (u32)20; i++) if (w.halves[i] != (i16)0) n++;
    for (u32 i = (u32)0; i < (u32)17; i++) if (w.fs[i] != 0.0) n++;
    for (u32 i = (u32)0; i < (u32)16; i++) if (w.ds[i] != 0.0) n++;
    for (u32 i = (u32)0; i < (u32)40; i++) if (w.flags[i]) n++;
    for (u32 i = (u32)0; i < (u32)3; i++) if (w.shortRun[i] != (u8)0) n++;
    for (u32 i = (u32)0; i < (u32)20; i++) if (w.ptrs[i] != (u8*)0) n++;
    for (u32 i = (u32)0; i < (u32)2; i++) if (w.inner[i].a != (u16)0 || w.inner[i].b != (u8)0) n++;
    if (w.tail != (u8)0) n++;
    return n;
    }

void plain(void)
    {
    Wide w;
    Stdio.printf("plain: %u non-zero\n", nonZero(&w));
    }

void listed(void)
    {
    // A partial list: head and pad's first three bytes given, the rest of pad
    // (a long tail) and every later field zero.
    Wide w = {(u8)9, {(u8)1, (u8)2, (u8)3}};
    u32 n = nonZero(&w);
    Stdio.printf("listed: head %d, pad %d %d %d %d, %u non-zero\n", (i32)w.head, (i32)w.pad[0],
                 (i32)w.pad[1], (i32)w.pad[2], (i32)w.pad[3], n);
    }

i32 main(void)
    {
    dirty();
    plain();
    dirty();
    listed();
    return 0;
    }
