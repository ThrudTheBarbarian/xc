// par_gpu_reads_only.xc — arrays a par block only reads (a captured local, a
// global table) are not copied back from the device (gpuReadsOnly), and the
// host's own later write to one must stand. Every sum must be the CPU's.
#import "Stdio.xc"
#import "Par.xc"
u32 table[4096];
u32 out[4096];
i32 main(i32 argc, u8** argv)
    {
    u32 src[4096];
    u32 dst[4096];
    for (u32 i in 0..4096) { table[i] = i * 7; src[i] = i + (u32)1; dst[i] = 1; out[i] = 2; }
    par
        {
        for (u32 i in 0..4096)
            {
            dst[i] = src[i] * 2 + table[i];
            out[i] = table[(i * 13) & 4095];
            }
        }
    // A read-only array the host then changes and reads: it must be the host's.
    src[5] = 99;
    u32 a = (u32)0; u32 b = (u32)0;
    for (u32 i in 0..4096) { a = a + dst[i]; b = b + out[i] + src[i] + table[i]; }
    Stdio.printf("%u %u %u\n", a, b, src[5]);
    return 0;
    }
