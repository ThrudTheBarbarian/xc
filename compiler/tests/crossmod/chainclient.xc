// chainclient.xc — the app of chain.sh: a Sub made by the second library,
// called through the first library's Base, the second's Sub and directly.
#import "Stdio.xc"
#import <ChainBase>
#import <ChainSub>

i32 main(void)
    {
    Sub@ s = ChainB.make();
    Stdio.printf("base=%lu\n", ChainA.viaBase((Base*)s));
    Stdio.printf("sub=%lu\n", ChainB.viaSub(s));
    Stdio.printf("app=%lu\n", s.h() * (u32)100 + s.f());
    return 0;
    }
