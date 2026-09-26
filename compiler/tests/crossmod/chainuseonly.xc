// chainuseonly.xc — an app that imports only chainuse's library. chainbase's
// library is still needed at run time, because chainuse imports from it.
#import "Stdio.xc"
#import <ChainUse>

i32 main(void)
    {
    Stdio.printf("boot=%lu\n", ChainU.booted());
    Stdio.printf("many=%lu\n", ChainU.many((u32)3));
    return 0;
    }
