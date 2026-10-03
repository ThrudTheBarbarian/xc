//xtc-na: xt6502 — its heap is byte-addressed and has no alignment rule
// heap_payload_alignment.xc — bug 598. Every heap payload starts 8-aligned.
// On wasm32 the object header was 38 bytes, so every `new u32[n]` (and every
// object) sat at 2 mod 4: xc's own loads were fine, but JavaScript that views
// module memory as an Int32Array at ptr >> 2 read the wrong words, and wasm
// atomics would trap. Arrays of every element width, interleaved, and
// objects; the count of misaligned payloads must be 0.
#import "Stdio.xc"

class Box
{
    u32 v;
}

u32 misaligned(pointer p)
{
    u64 a = (u64)p;
    return (a & (u64)7) != (u64)0 ? (u32)1 : (u32)0;
}

i32 main(void)
{
    u32 bad = (u32)0;
    u32 n = (u32)0;
    for (u32 i = (u32)1; i < (u32)40; i = i + (u32)1)
    {
        u8* b = new u8[i];
        u32* w = new u32[i];
        double* d = new double[i];
        Box* x = new Box;
        bad = bad + misaligned((pointer)b) + misaligned((pointer)w) + misaligned((pointer)d) + misaligned((pointer)x);
        n = n + (u32)4;
        delete b;
        delete w;
        delete d;
    }
    Stdio.printf("misaligned %u of %u\n", bad, n);
    return 0;
}
