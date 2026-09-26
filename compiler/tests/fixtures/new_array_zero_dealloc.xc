// new_array_zero_dealloc.xc — freeing `new C[N]` runs dealloc N times, and N
// may be zero.
//
// Bug 472: the allocator raised a count of 0 to 1 before writing it into the
// object header, so `new C[0]` recorded one element and freeing it ran one
// dealloc on an element that does not exist. The count in the header is also
// what `.length` and for-in read, so they reported one element as well.
//
// Test surface:
//   T1  new C[0], new C[1], new C[3]: dealloc runs 0, 1 and 3 times
//   T2  a runtime-computed count of 0 behaves as the literal one
//   T3  a scalar `new C()` still runs dealloc once
//   T4  zero-length struct and primitive arrays allocate and delete

#import "Stdio.xc"

u16 deallocs;

class Counted
{
    u8 tag;
    void dealloc(void)
    {
        deallocs = deallocs + (u16)1;
    }
}

struct Pair
{
    i16 a;
    i16 b;
}

u16 zero(void) { return (u16)0; }

u16 freed(u16 n)
{
    deallocs = (u16)0;
    { Counted* arr = new Counted[n]; }
    return deallocs;
}

i16 main(void)
{
    // T1: literal counts.
    deallocs = (u16)0;
    { Counted* a0 = new Counted[0]; }
    Stdio.printf("C[0] %d\n", deallocs);

    deallocs = (u16)0;
    { Counted* a1 = new Counted[1]; }
    Stdio.printf("C[1] %d\n", deallocs);

    deallocs = (u16)0;
    { Counted* a3 = new Counted[3]; }
    Stdio.printf("C[3] %d\n", deallocs);

    // T2: runtime counts.
    Stdio.printf("n=0 %d n=1 %d n=3 %d\n", freed(zero()), freed((u16)1), freed((u16)3));

    // T3: a scalar is one element.
    deallocs = (u16)0;
    { Counted* one = new Counted(); }
    Stdio.printf("C() %d\n", deallocs);

    // T4: zero-length struct and primitive arrays.
    Pair* ps = new Pair[0];
    delete ps;
    Pair* pz = new Pair[zero()];
    delete pz;
    u8* bs = new u8[zero()];
    delete bs;
    Stdio.printf("struct/primitive [0] ok\n");
    return 0;
}
