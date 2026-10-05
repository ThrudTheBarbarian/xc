//xtc-warn: because it uses double, which Apple GPUs do not have
//xtc-warn: because it uses table, an array of double; the GPU holds arrays of float and integers
//xtc-warn: because it calls scaled, which cannot run on the GPU (it uses the global factor)
// On a target with a GPU, a `par` block that cannot run there says why: it
// runs on the CPU's threads instead, which otherwise shows only in timings.
// Suppressed with -Wno-par-gpu.
#import "Par.xc"
float out[4096];
double table[4096];
float factor[1];
float scaled(float x)
    {
    return x * factor[0];
    }
void main(void)
    {
    par dbl { for (u32 i in 0..4096) { double x = (double)i * 0.5; out[i] = (float)(x * x); } }
    par arr { for (u32 i in 0..4096) { table[i] = (double)i; } }
    par help { for (u32 i in 0..4096) { out[i] = scaled((float)i); } }
    }
