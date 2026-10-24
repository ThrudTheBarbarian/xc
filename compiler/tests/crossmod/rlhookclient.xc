// A client posting to the loop whose wake hook the library set: the client's
// post() calls the library's block. See wakehook.sh.
#import <Stdio.xc>
#import <RLHookLib>
#import "RunLoop.xc"
i32 gN;
i32 main(void)
    {
    RLHookLib.hook();
    RunLoop.main().post(block void(void) { gN = gN + 1; });
    RunLoop.main().post(block void(void) { gN = gN + 10; });
    u32 ran = RLHookLib.drain();
    Stdio.printf("drained %u, n=%d\n", ran, gN);
    return 0;
    }
