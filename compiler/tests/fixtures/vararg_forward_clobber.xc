//xtc-flags: expect=sema-error
// A variadic that PACKS its own arguments and also forwards — private:docs/bugs/050.
//
// On every target but arm9 a variadic's arguments live in ONE shared buffer,
// filled by the CALLER. Forwarding works precisely because the forwarder never
// touches that buffer. Calling anything variadic WITH arguments overwrites it,
// and what gets overwritten is the pack being forwarded:
//
//     logIt("a=%d b=%d\n", 222, 333)   ->   [9] a=9 b=333
//
// `b=333` survived because the inner call packed one slot, which is what made
// this read as a formatting bug rather than a clobber. You reach it by adding a
// debug printf to a wrapper — exactly when you least suspect the compiler.
#import "Foundation.xc"
#import "Stdio.xc"

void logIt(string fmt, ...)
{
    Stdio.printf("[%d] ", (u16)9);   // packs into the shared buffer
    Stdio.printf(fmt, ...);          // ...which is the pack being forwarded
}

i32 main(void)
{
    logIt("a=%d b=%d\n", (u16)222, (u16)333);
    return 0;
}
