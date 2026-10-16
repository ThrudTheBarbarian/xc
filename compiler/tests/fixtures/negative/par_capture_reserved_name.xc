// A capture becomes an ivar of the block's class, whose own methods are
// named run, merge, copyChunk, …; a local called `run` captured by a par
// block made the body's `run` resolve to the block's run() and the block
// was refused as recursive, with a message that said nothing about the
// name. The name is refused up front.
// xtc: error "block cannot capture 'run'"
#import "Stdio.xc"
#import "Par.xc"

i32 main(void)
    {
    u32 run = 3;
    u32 out[64];
    par scale
        {
        for (u32 i in 0..64)
            out[i] = i * run;
        }
    Stdio.printf("%u\n", out[5]);
    return 0;
    }
