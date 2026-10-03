//xtc-na: xt6502, arm9 — both keep a 16-bit count by design (rt.c: two bytes an object matter there), so 70,000 references are out of range
// arc_refcount_wide.xc — bug 598. One object held by 70,000 references is
// freed exactly once, when the last goes. On wasm32 the count was 16-bit and
// SATURATED at 65,535 (bug 261), so this object leaked for good: dealloc never
// ran. The hosts moved to 32 bits after bugs 025/079; wasm32 now matches.
#import "Stdio.xc"
#import "Foundation.xc"

u32 deallocCount = (u32)0;

class Held
{
    u32 tag;
    void dealloc(void)
    {
        deallocCount = deallocCount + (u32)1;
    }
}

i32 main(void)
{
    u32 n = (u32)70000;
    Array* refs = new Array();
    Held* h = new Held;
    for (u32 i = (u32)0; i < n; i = i + (u32)1)
        refs.add((Object*)h);
    h = (Held*)0;
    Stdio.printf("after dropping the local: dealloc %u\n", deallocCount);
    refs = (Array*)0;
    Stdio.printf("after dropping all %u: dealloc %u\n", n, deallocCount);
    return 0;
}
