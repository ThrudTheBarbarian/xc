// chainmany.xc — an app that calls chainuse's library but not its startup
// code: ChainU.many frees a `new Base[N]` made in that library, so the
// library takes the address of chainbase's Base$dealloc.
#import "Stdio.xc"
#import <ChainBase>
#import <ChainUse>

i32 main(void)
    {
    Stdio.printf("many=%lu\n", ChainU.many((u32)4));
    Stdio.printf("many=%lu\n", ChainU.many((u32)2));
    return 0;
    }
