//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc)
// par_gpu_perlin.xc — Perlin noise (Ken Perlin's improved noise, 2D, four
// octaves) for a 1024x1024 image in one `par` block: on the GPU with
// XC_PAR=gpu on Apple silicon, on every CPU thread otherwise.
//
// The permutation table is a global array the block reads, and the image a
// global array it writes, one pixel per work item; fade, lerp and grad are
// helpers taking and returning plain values. The maths is single precision
// (Apple GPUs have no f64), so a pixel on the GPU can round differently from
// the CPU's in the last place: the summary printed is coarse enough to be the
// same either way. Give a file name to also write the image as a PPM.
#import "Stdio.xc"
#import "Files.xc"
#import "Par.xc"

u32 perm[512];
u8 img[1048576];

float fade(float t)
    {
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
    }

float lerp(float t, float a, float b)
    {
    return a + t * (b - a);
    }

float grad(u32 h, float x, float y)
    {
    u32 g = h & (u32)7;
    float u = g < (u32)4 ? x : y;
    float v = g < (u32)4 ? y : x;
    float a = (g & (u32)1) != (u32)0 ? 0.0f - u : u;
    float b = (g & (u32)2) != (u32)0 ? 0.0f - 2.0f * v : 2.0f * v;
    return a + b;
    }

i32 main(i32 argc, u8** argv)
    {
    // A fixed permutation of 0..255 (a seeded shuffle), repeated once so
    // perm[i + 1] never needs a wrap.
    u32 seed = (u32)12345;
    for (u32 i in 0..256)
        perm[i] = i;
    for (u32 i in 0..256)
        {
        seed = seed * (u32)1103515245 + (u32)12345;
        u32 j = i + (seed >> (u32)16) % ((u32)256 - i);
        u32 t = perm[i];
        perm[i] = perm[j];
        perm[j] = t;
        }
    for (u32 i in 0..256)
        perm[i + (u32)256] = perm[i];

    u32 total = (u32)0;
    u32 lowest = (u32)255;
    u32 highest = (u32)0;
    par perlin :reduce(+ total) :reduce(min lowest) :reduce(max highest)
        {
        for (u32 i in 0..1048576)
            {
            float x = (float)(i % (u32)1024) / 128.0f;
            float y = (float)(i / (u32)1024) / 128.0f;
            float sum = 0.0f;
            float amp = 1.0f;
            float norm = 0.0f;
            for (u32 o in 0..4)
                {
                u32 xi = (u32)x;
                u32 yi = (u32)y;
                float xf = x - (float)xi;
                float yf = y - (float)yi;
                u32 X = xi & (u32)255;
                u32 Y = yi & (u32)255;
                u32 aa = perm[perm[X] + Y];
                u32 ab = perm[perm[X] + Y + (u32)1];
                u32 ba = perm[perm[X + (u32)1] + Y];
                u32 bb = perm[perm[X + (u32)1] + Y + (u32)1];
                float u = fade(xf);
                float v = fade(yf);
                float n = lerp(v, lerp(u, grad(aa, xf, yf), grad(ba, xf - 1.0f, yf)),
                               lerp(u, grad(ab, xf, yf - 1.0f), grad(bb, xf - 1.0f, yf - 1.0f)));
                sum = sum + n * amp;
                norm = norm + amp;
                amp = amp * 0.5f;
                x = x * 2.0f;
                y = y * 2.0f;
                }
            float s = (sum / norm) * 0.5f + 0.5f;
            if (s < 0.0f)
                s = 0.0f;
            if (s > 1.0f)
                s = 1.0f;
            u32 p = (u32)(s * 255.0f);
            img[i] = (u8)p;
            total = total + p;
            if (p < lowest)
                lowest = p;
            if (p > highest)
                highest = p;
            }
        }

    // Coarse on purpose (see the top): the mean to a tenth, the range in
    // bands of 8.
    u32 tenths = (total * (u32)10 + (u32)524288) / (u32)1048576;
    Stdio.printf("perlin 1024x1024: mean %u.%u, low band %u, high band %u\n",
                 tenths / (u32)10, tenths % (u32)10, lowest / (u32)8, highest / (u32)8);

    if (argc > 1)
        {
        Data* ppm = Data.withString(String.withCString("P6\n1024 1024\n255\n"));
        for (u32 i in 0..1048576)
            {
            ppm.appendByte(img[i]);
            ppm.appendByte(img[i]);
            ppm.appendByte(img[i]);
            }
        String* path = String.withCString(argv[1]);
        if (!Files.writeData(path, ppm))
            {
            Stdio.printf("could not write %s\n", argv[1]);
            return 1;
            }
        }
    return 0;
    }
