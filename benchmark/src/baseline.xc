// baseline — startup only. With timing taken inside the program there is
// nothing to subtract; this reports zero elapsed and exists to prove it.
#import "Stdio.xc"

i32 main(i32 argc, u8** argv)
    {
    Stdio.printf("%lu 0\n", (u32)argc);
    return 0;
    }
