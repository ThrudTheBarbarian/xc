// chainrev.xc — an app that names chainuse's library before chainbase's.
// chainuse's startup code calls into chainbase, so chainbase must be set up
// first whatever order the app imports them in.
#import "Stdio.xc"
#import <ChainUse>
#import <ChainBase>

i32 main(void)
    {
    Stdio.printf("boot=%lu\n", ChainU.booted());
    Stdio.printf("many=%lu\n", ChainU.many((u32)4));
    Base@ b = new Base();
    Stdio.printf("base=%lu\n", ChainA.viaBase(b));
    return 0;
    }
