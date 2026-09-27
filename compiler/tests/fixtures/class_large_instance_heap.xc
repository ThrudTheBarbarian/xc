// class_large_instance_heap.xc — objects bigger than 56 bytes keep their own
// storage and their destructor.
//
// Bug 510: the xt6502 allocator took a fixed 64-byte block for every `new`, and
// kept the element count, stride and dealloc descriptor at payload+56..62. A
// class with more than 56 bytes of ivars wrote over that header and ran into
// the next block: two 80-byte objects came back 71 bytes apart, filling one
// changed the other, and a destructor dispatched through ivar data.
//
// Test surface:
//   T1  two large objects, every byte written: neither disturbs the other
//   T2  a large object with a dealloc, filled to the last ivar, runs it once
//   T3  an array of three large objects runs dealloc three times, one per
//       element, and each element saw its own data
//   T4  a large struct array and a primitive array allocate, hold their
//       data and delete

#import "Stdio.xc"

u16 deallocs;
u16 tagSum;

class Big
{
    u8 head;
    u8 data[100];
    u16 tail;

    void fill(u8 seed)
    {
        head = seed;
        for (u16 i = (u16)0; i < (u16)100; i = i + (u16)1)
            data[i] = (u8)(seed + (u8)i);
        tail = (u16)seed * (u16)100;
    }

    u16 check(u8 seed)
    {
        u16 bad = (u16)0;
        if (head != seed) bad = bad + (u16)1;
        for (u16 i = (u16)0; i < (u16)100; i = i + (u16)1)
            if (data[i] != (u8)(seed + (u8)i)) bad = bad + (u16)1;
        if (tail != (u16)seed * (u16)100) bad = bad + (u16)1;
        return bad;
    }
}

class BigD
{
    u8 data[90];
    u16 tag;

    void fill(u16 t)
    {
        for (u16 i = (u16)0; i < (u16)90; i = i + (u16)1)
            data[i] = (u8)$A5;
        tag = t;
    }

    void dealloc(void)
    {
        deallocs = deallocs + (u16)1;
        tagSum = tagSum + tag;
    }
}

struct Rec
{
    u16 a;
    u8 pad[60];
    u16 b;
}

i16 main(void)
{
    // T1
    Big* p = new Big();
    Big* q = new Big();
    p.fill((u8)11);
    q.fill((u8)77);
    Stdio.printf("T1 p bad %u q bad %u\n", p.check((u8)11), q.check((u8)77));

    // T2
    deallocs = (u16)0;
    tagSum = (u16)0;
    {
        BigD* d = new BigD();
        d.fill((u16)500);
    }
    Stdio.printf("T2 deallocs %u tags %u\n", deallocs, tagSum);

    // T3
    deallocs = (u16)0;
    tagSum = (u16)0;
    {
        BigD* arr = new BigD[3];
        arr[0].fill((u16)1);
        arr[1].fill((u16)20);
        arr[2].fill((u16)300);
    }
    Stdio.printf("T3 deallocs %u tags %u\n", deallocs, tagSum);

    // T4
    Rec* rs = new Rec[2];
    u8* bytes = new u8[70];
    rs[0].a = (u16)1;
    rs[0].b = (u16)2;
    rs[1].a = (u16)3;
    rs[1].b = (u16)4;
    for (u16 i = (u16)0; i < (u16)70; i = i + (u16)1)
        bytes[i] = (u8)$5A;
    u16 sum = rs[0].a + rs[0].b + rs[1].a + rs[1].b;
    u16 ok = (u16)0;
    for (u16 i = (u16)0; i < (u16)70; i = i + (u16)1)
        if (bytes[i] == (u8)$5A) ok = ok + (u16)1;
    delete rs;
    delete bytes;
    Stdio.printf("T4 sum %u bytes %u\n", sum, ok);
    Stdio.printf("T5 p bad %u q bad %u\n", p.check((u8)11), q.check((u8)77));
    return 0;
}
