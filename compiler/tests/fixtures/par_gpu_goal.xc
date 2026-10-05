//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_gpu_goal.xc — a `par` block's goal: speed (the default) or accuracy.
//
// The same block twice. With the default goal, speed, the GPU (XC_PAR=gpu)
// uses its fast maths: Metal's fast mode, and NVIDIA's sin.approx,
// ex2.approx and lg2.approx for sin, cos, exp, ln and pow, which have no
// precise GPU instructions there. With :goal(accuracy) the maths is precise:
// on NVIDIA that block runs on the CPU. Fast maths can differ from the CPU's
// in the last few bits, so what is printed is coarse: how many items fall in
// each band, to the nearest thousand.
#import "Stdio.xc"
#import "Math.xc"
#import "Par.xc"

#define SIZE (1024 * 1024)

float wave[SIZE];

i32 main(void)
{
    u32 high = (u32)0;
    u32 low = (u32)0;
    par waves :reduce(+ high) :reduce(+ low)
        {
        for (u32 i in 0..SIZE)
            {
            float x = (float)i / 65536.0f;
            float v = Math.sin(x) * Math.cos(x * 0.5f) + Math.exp(0.0f - x) * 0.25f
                      + Math.pow(x + 1.0f, 0.5f) * 0.01f + Math.ln(x + 1.0f) * 0.01f;
            wave[i] = v;
            if (v > 0.3f)
                high = high + (u32)1;
            if (v < -0.3f)
                low = low + (u32)1;
            }
        }
    Stdio.printf("speed: high ~%uk, low ~%uk\n", (high + (u32)500) / (u32)1000, (low + (u32)500) / (u32)1000);

    high = (u32)0;
    low = (u32)0;
    par precise :reduce(+ high) :reduce(+ low) :goal(accuracy)
        {
        for (u32 i in 0..SIZE)
            {
            float x = (float)i / 65536.0f;
            float v = Math.sin(x) * Math.cos(x * 0.5f) + Math.exp(0.0f - x) * 0.25f
                      + Math.pow(x + 1.0f, 0.5f) * 0.01f + Math.ln(x + 1.0f) * 0.01f;
            if (v > 0.3f)
                high = high + (u32)1;
            if (v < -0.3f)
                low = low + (u32)1;
            }
        }
    Stdio.printf("accuracy: high ~%uk, low ~%uk\n", (high + (u32)500) / (u32)1000, (low + (u32)500) / (u32)1000);
    return 0;
}
