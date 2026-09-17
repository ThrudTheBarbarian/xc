// hash_mix — an integer avalanche chain.
// Exercises: multiply, shift and xor chains with a serial dependency.
#import "Stdio.xc"
i32 main(i32 argc, u8** argv)
    {
    u32 h = (u32)argc; 
    for (u32 r = (u32)0; r < (u32)8000000; r++)
        {
        h = h ^ (h >> (u32)16);
        h = h * (u32)2246822519;
        h = h ^ (h >> (u32)13);
        h = h + r;
        }
    Stdio.printf("%lu\n", h);
    return 0;
    }
