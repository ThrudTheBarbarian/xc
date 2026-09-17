// baseline — startup and teardown only. The harness subtracts this from every
// other result so the numbers compare generated code, not process launch.
#import "Stdio.xc"

i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("%lu\n", (u32)argc);
    return 0;
    }
