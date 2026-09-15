//xtc-na: m68k,xt6502 — timing benchmark; the xt6502/m68k sims can't run the reps in time
// Scaled Ahl benchmark for timing xtc-arm64 vs C.
// Same inner computation as ahl.xc, wrapped in an outer REPS loop so the
// total wall time is measurable on a GHz host. Accumulators reset each rep
// so the reported Accuracy/Random stay identical to the single-shot ahl.xc
// (a correctness check), while Time covers all REPS.

#import "Stdio.xc"
#import "Time.xc"

void main(void)
    {
    float r = 0;
    float s = 0;
    u16 reps = 10000;

    Stdio.printf("Begin (reps=%u)\n", reps);
    Time.clearTimer();

    for (u16 rep = 0; rep < reps; rep++)
        {
        r = 0;
        s = 0;
        for (u8 n = 1; n <= 100; n++)
            {
            float a = n;
            for (u8 i = 1; i <= 10; i++)
                {
                a = Math.sqrt(a);
                r += Math.rand();
                }
            for (u8 i = 1; i <= 10; i++)
                {
                a = Math.pow(a, 2);
                r += Math.rand();
                }
            s += a;
            }
        }

    Stdio.printf("Accuracy   %f\n", 1010.0d - s / 5.0);
    Stdio.printf("Random     %f\n", Math.abs(1000.0 - r));
    Stdio.printf("Time taken %f secs\n", Time.secondsSince(0));
    }