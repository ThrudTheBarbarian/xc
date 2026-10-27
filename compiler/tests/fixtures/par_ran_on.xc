// par_ran_on — Par.ranOn names the hardware a block's last run used
// (2026-10-27, owner: float results can differ between devices; say which
// device made them rather than promise they cannot). Before the block runs
// the list is empty; forced onto the CPU, it is exactly "cpu".
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
{
    u32 n = 4096;
    float* a = new float[n];
    Par.device("fill", "cpu");
    Stdio.printf("before: %u\n", Par.ranOn("fill").count());
    par fill
    {
        for (u32 i in 0..n)
            a[i] = (float)i * 0.5f;
    }
    Array* on = Par.ranOn("fill");
    Stdio.printf("after: %u %s\n", on.count(), on.count() > (u32)0 ? ((String*)on.get((u32)0)).cString() : "-");
    Stdio.printf("other: %u\n", Par.ranOn("nosuch").count());
    Stdio.printf("%.1f\n", (double)a[n - 1]);
    return 0;
}
