// par_devred_split.xc — a device reduction over more items than one Vulkan
// dispatch takes (65535 workgroups of 256), with a partial last workgroup
// (issue #12).
//
// Each item loops (8 to 15 trips), so the runtime runs it one item a thread:
// whole workgroups in dispatches of at most 65535, each told the workgroups
// the earlier ones took (the header's `goff`), and the last 232 items in a
// workgroup of their own. Every workgroup writes its own partial, and the
// fold sees them all: the sum, minimum and maximum must be the CPU's.
//xtc-na: xt6502, m68k, arm9, wasm32 — par runs on the native hosts

#import "Stdio.xc"
#import "Par.xc"

#define N (65535 * 256 * 2 + 1000)

i32 main(void)
    {
    u32 total = (u32)0;
    u32 low = (u32)0xffffffff;
    u32 high = (u32)0;
    par split :reduce(+ total) :reduce(min low) :reduce(max high)
        {
        for (u32 i in 0..(u32)N)
            {
            u32 k = (u32)0;
            u32 v = i;
            while (k < (u32)8 + (i & (u32)7))
                {
                v = v * (u32)1664525 + (u32)1013904223;
                k = k + (u32)1;
                }
            total = total + (v >> (u32)8);
            if (v < low)
                low = v;
            if (v > high)
                high = v;
            }
        }
    Stdio.printf("total %u low %u high %u\n", total, low, high);
    return (i32)0;
    }
