#use Stdio
#import <SLib>
extern u16 gSCounter;
void sbump(void);
i32 main(void)
    {
    gSCounter = (u16)10;
    sbump();
    printf("global %u\n", (u32)gSCounter);
    printf("lenOwn %lu\n", SLib.lenOwn());
    String* s = String.withCString("abcdef");
    printf("lenOf  %lu\n", SLib.lenOf(s));
    i32 n = 0;
    if (s.byteLength() > (u32)0)
        {
        SRect r = SLib.make((i16)1, (i16)2, (i16)30, (i16)40);
        n = (i32)r.x + (i32)r.y + (i32)r.w + (i32)r.h;
        }
    printf("make   %d\n", n);
    return (i32)0;
    }
