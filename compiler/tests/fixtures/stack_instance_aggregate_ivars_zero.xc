// A class instance's array and struct ivars start at zero, as its scalar
// and object ivars do (#755): a stack instance whose frame slot held
// other bytes reads 0 from them, and so does one from `new`.
#import "Stdio.xc"

struct Pair { u32 a; u16 b; }

class V
    {
    u64 s[2];
    Pair p;
    u8 tail[40];
    u32 n;
    }

u64 dirty(void)
    {
    u64 junk[16];
    u64 t = (u64)0;
    for (u32 i = (u32)0; i < (u32)16; i = i + (u32)1)
        {
        junk[i] = (u64)0x5A5A5A5A5A5A5A5A + (u64)i;
        t = t + junk[i];
        }
    return t;
    }

u64 sum(V* v)
    {
    u64 t = v.s[0] + v.s[1] + (u64)v.p.a + (u64)v.p.b + (u64)v.n;
    for (u32 i = (u32)0; i < (u32)40; i = i + (u32)1)
        t = t + (u64)v.tail[i];
    return t;
    }

u64 onStack(void)
    {
    V t;
    return sum(&t);
    }

i32 main(void)
    {
    u64 d = dirty();
    u64 a = onStack();
    V* h = new V();
    Stdio.printf("%lu %lu %d\n", a, sum(h), d != (u64)0 ? 1 : 0);
    return 0;
    }
