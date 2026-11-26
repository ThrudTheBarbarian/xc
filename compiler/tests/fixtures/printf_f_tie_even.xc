// %f rounds a value exactly halfway between two results to EVEN, as C's
// printf does (#696): xt6502 printed 0.1015625 as 0.101563. Values off the
// halfway point round to nearest as before.
#import "Stdio.xc"

i32 main(void)
    {
    float a = 0.1015625;       // exact in binary: ...62|5, previous digit even
    float b = 0.0546875;       // ...87|5, previous digit odd -> rounds up
    Stdio.printf("%f %f\n", a, b);
    Stdio.printf("%f\n", 0.1015626);
    return 0;
    }
