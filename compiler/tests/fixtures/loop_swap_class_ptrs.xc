#use Stdio
#import "Foundation.xc"
i32 main(i32 argc, u8** argv)
{
    Array* a = new Array(); Array* b = new Array();
    // 1. swap through a loop-scoped temp, one iteration
    Array* src = a; Array* dst = b;
    for (u32 w = (u32)1; w < (u32)2; w = w * (u32)2) { Array* t = src; src = dst; dst = t; }
    printf("loop-temp:   src==a %d (expect 0)\n", (i16)(src == a ? 1 : 0));
    // 2. same swap, temp declared OUTSIDE the loop
    src = a; dst = b; Array* t2 = (Array*)0;
    for (u32 w = (u32)1; w < (u32)2; w = w * (u32)2) { t2 = src; src = dst; dst = t2; }
    printf("outer-temp:  src==a %d (expect 0)\n", (i16)(src == a ? 1 : 0));
    // 3. plain reassignment in a loop, no temp
    src = a;
    for (u32 w = (u32)1; w < (u32)2; w = w * (u32)2) { src = b; }
    printf("plain:       src==a %d (expect 0)\n", (i16)(src == a ? 1 : 0));
    // 4. the swap inside an if, not a loop
    src = a; dst = b;
    if (argc > (i32)0) { Array* t = src; src = dst; dst = t; }
    printf("if-temp:     src==a %d (expect 0)\n", (i16)(src == a ? 1 : 0));
    // 5. the same with a non-class pointer type
    u32 x = (u32)1; u32 y = (u32)2; u32 p = x; u32 q = y;
    for (u32 w = (u32)1; w < (u32)2; w = w * (u32)2) { u32 t = p; p = q; q = t; }
    printf("u32-temp:    p==x %d (expect 0)\n", (i16)(p == x ? 1 : 0));
    return (i32)0;
}
