// A work item's own array (`u32 a[32];` in the body): Astronomancy's median
// combine kept every such block on the CPU ("it uses an operation its GPU
// version cannot express yet"). On Metal it is a thread array of the kernel;
// the answer is the serial loop's on every device.
#import "Stdio.xc"
#import "Par.xc"
i32 main(void)
    {
    u32 w = (u32)64;
    u32 h = (u32)48;
    u32 n = (u32)9;
    u32 plane = w * h;
    simd: u32* stack = new u32[plane * n];
    simd: u32* med = new u32[plane];
    for (u32 j = (u32)0; j < plane * n; j = j + (u32)1)
        stack[j] = ((j * (u32)2654435761) >> (u32)9) % (u32)1000;
    par median :grid(w, h)
        {
        u32 i = par.y * par.width + par.x;
        u32 a[32];
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
            {
            u32 v = stack[k * plane + i];
            u32 at = k;
            while (at > (u32)0 && a[at - (u32)1] > v)
                {
                a[at] = a[at - (u32)1];
                at = at - (u32)1;
                }
            a[at] = v;
            }
        med[i] = a[n / (u32)2];
        }
    // The same median, serially.
    u32 bad = (u32)0;
    u64 sum = (u64)0;
    u32 b[32];
    for (u32 i = (u32)0; i < plane; i = i + (u32)1)
        {
        for (u32 k = (u32)0; k < n; k = k + (u32)1)
            b[k] = stack[k * plane + i];
        for (u32 x = (u32)1; x < n; x = x + (u32)1)
            for (u32 y = x; y > (u32)0 && b[y - (u32)1] > b[y]; y = y - (u32)1)
                {
                u32 t = b[y]; b[y] = b[y - (u32)1]; b[y - (u32)1] = t;
                }
        if (med[i] != b[n / (u32)2])
            bad = bad + (u32)1;
        sum = sum + (u64)med[i];
        }
    Stdio.printf("medians %u, wrong %u, sum %lu\n", plane, bad, sum);
    return 0;
    }
