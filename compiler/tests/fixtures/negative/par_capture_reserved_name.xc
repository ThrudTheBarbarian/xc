// A capture named as one of the block's own members (run, lo, merge, ...)
// keeps its name in the body through a local of run(); a struct has no such
// local, so a struct captured under one of those names is still refused, by
// name (it used to be refused as recursive, with a message that said nothing
// about the name). Numbers, pointers and arrays may use them
// (par_reserved_capture_names).
// xtc: error "block cannot capture 'lo'"
#import "Stdio.xc"
#import "Par.xc"

struct Span { u32 a; u32 b; }

i32 main(void)
    {
    Span lo;
    lo.a = (u32)2;
    lo.b = (u32)3;
    u32 out[64];
    par scale
        {
        for (u32 i in 0..64)
            out[i] = i * lo.a + lo.b;
        }
    Stdio.printf("%u\n", out[5]);
    return 0;
    }
