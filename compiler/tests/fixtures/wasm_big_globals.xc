//xtc-flags: target=arm64
// wasm_big_globals.xc — globals larger than the 1 MiB the heap used to start
// at (bug 627): on wasm32 the module did not load ("data segment out of
// bounds"). The heap must still work above them: objects made after the big
// array are retained, released and read back.
#import "Stdio.xc"
#import "Array.xc"
#import "String.xc"

u32 big[2000000];
u32 tail[4] = { 7, 11, 13, 17 };

i32 main(void)
    {
    for (u32 i = (u32)0; i < (u32)2000000; i = i + (u32)1)
        big[i] = i * (u32)3;
    u32 sum = (u32)0;
    for (u32 i = (u32)0; i < (u32)2000000; i = i + (u32)1)
        sum = sum + big[i];
    Array* a = new Array();
    for (u32 k = (u32)0; k < (u32)100; k = k + (u32)1)
        a.add((Object*)String.withU32(k * tail[k % (u32)4]));
    String* last = (String*)a.get((u32)99);
    Stdio.printf("sum=%u big[1999999]=%u count=%u last=%s tail=%u\n", sum, big[1999999], a.count(),
                 last.cString(), tail[3]);
    return 0;
    }
