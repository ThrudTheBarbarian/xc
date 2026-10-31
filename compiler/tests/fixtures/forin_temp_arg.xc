// forin_temp_arg — a for-in over a call whose argument is itself a temporary
// (2026-10-31, from Astronomancy: `for (String* w in amWords(name.deletingPathExtension()))`).
//
// The call's result is adopted by the loop; the argument's temporary ends with
// the subject's evaluation and must be released ONCE, before the loop. The
// shipped compiler released it once per element (an over-release: freed memory
// written, the heap's free list damaged under the compact header), the
// reference never (a leak). Each Tag made by mk() must be freed exactly once:
// 100 loops of 3 elements each free 100 tags (and the arrays hold the rest).
#import "Foundation.xc"
#import "Stdio.xc"

u32 gFreed;

class Tag
{
    u32 id;
    void init(u32 i) { id = i; }
    void dealloc(void) { gFreed = gFreed + (u32)1; }
}

Array<Tag>* listOf(Tag* t)
    {
    Array<Tag>* a = new Array();
    a.add(t);
    a.add(t);
    a.add(t);
    return a;
    }

Tag* mk(u32 i) { return new Tag(i); }

i32 main(void)
{
    u32 n = (u32)0;
    for (u32 r = (u32)0; r < (u32)100; r = r + (u32)1)
        {
        for (Tag* x in listOf(mk(r)))
            n = n + x.id;
        }
    Stdio.printf("%u %u\n", n, gFreed);
    return (i32)0;
}
