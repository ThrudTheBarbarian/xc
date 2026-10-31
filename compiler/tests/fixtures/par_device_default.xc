// par_device_default — a block's :device(…) default (owner 2026-10-31).
//
// `par name :device(gpu) { … }` is the developer's DEFAULT device: XC_PAR, the
// user's settings (par.<name>) and the program's Par.device come before it,
// and auto after it, so auto does not measure a block that has one. Checked
// here with the answers that do not depend on the machine: a :device(cpu)
// block runs on the CPU, and the program's Par.device(…, "cpu") outranks a
// block's :device(gpu). tests/driver/par-device.sh adds the user's setting
// and the report (no measuring).
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
{
    u32 n = 4096;
    float* a = new float[n];
    par own :device(cpu)
    {
        for (u32 i in 0..n)
            a[i] = (float)i * 0.5f;
    }
    Array* on = Par.ranOn("own");
    Stdio.printf("own: %s\n", on.count() > (u32)0 ? ((String*)on.get((u32)0)).cString() : "-");
    Par.device("prog", "cpu");
    par prog :device(gpu)
    {
        for (u32 i in 0..n)
            a[i] = a[i] + 1.0f;
    }
    on = Par.ranOn("prog");
    Stdio.printf("prog: %s\n", on.count() > (u32)0 ? ((String*)on.get((u32)0)).cString() : "-");
    Stdio.printf("%.1f\n", (double)a[n - 1]);
    return 0;
}
