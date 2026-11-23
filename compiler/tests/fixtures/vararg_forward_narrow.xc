// vararg_forward_narrow — integers narrower than `int` through a forwarded
// `...`, where no format check can widen them at the call. Each is packed as
// an int (C's default promotion) and va_arg reads it back as one: a u16 packed
// as two bytes left the rest of its slot to whatever an earlier call had put
// there, so after a -1 a forwarded (u16)7 printed -65529 on x86-64 and 458974
// on big-endian m68k. The narrow va_arg reads must agree on both byte orders.
#import "Foundation.xc"
#import "Stdio.xc"

void logIt(string fmt, ...) { Stdio.printf(fmt, ...); }
void logTwice(string fmt, ...) { logIt(fmt, ...); }

u32 sumNarrow(u32 n, ...)
    {
    u8 ap;
    va_start(ap);
    u32 s = (u32)0;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        s = s + (u32)va_arg(ap, u16);
    i8 last = va_arg(ap, i8);
    return s + (u32)(i32)last;
    }

i32 main(void)
    {
    logTwice("big %d\n", (i32)-1);
    logTwice("small %d\n", (u16)7);
    logTwice("u8 %d char %c i8 %d i16 %d\n", (u8)200, (u8)65, (i8)-3, (i16)-300);
    logTwice("bool %d\n", 3 > 2);
    Stdio.printf("sum %u\n", sumNarrow((u32)3, (u16)1000, (u16)2000, (u16)40000, (i8)-1));
    return 0;
    }
