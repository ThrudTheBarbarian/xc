//xtc-flags: expect=sema-error
// `defer` takes a block. Braces keep what is deferred unambiguous at a glance,
// and leave `defer <statement>` free to mean something later. The reference
// refused the bare form; the self-hosted compiler accepted it.
// Refused: 'defer' wants a block: defer { ... }
#import "Stdio.xc"

i32 main(void)
{
    defer Stdio.printf("done\n");
    return 0;
}
