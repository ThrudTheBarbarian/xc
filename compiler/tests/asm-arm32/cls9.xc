#import "Runtime.xc"

i32 write(i32 fd, u8* buf, u32 n);

class Counter
    {
    u32 n;
    void bump(void)
        {
        n = n + (u32)1;
        }
    }

    void
    main(void)
    {
    Counter* c = new Counter();
    for (u32 i = (u32)0; i < (u32)7; i = i + (u32)1)
        c.bump();
    u8* digits = (u8*)"0123456789";
    u8* out = (u8*)"classes and ARC, linked pure: N\n";
    out[30] = digits[c.n];
    write((i32)1, out, (u32)32);
    }
