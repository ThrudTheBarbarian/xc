// ssclient.xc — a program using the stdlib singletons of the library it
// imports (stdstate.sh): each must be the library's, one per process.
#import <Stdio.xc>
#import <SsLib>
class Hits : Object { u32 n; }
i32 main(void)
    {
#if !ARCH_wasm32
    Hits* h = new Hits();
    RunLoop.main().post(block void(void) { h.n = h.n + (u32)1; });
    u32 ran = SsLib.drain();
    Stdio.printf("library ran %u of the program's posts, hits %u\n", ran, h.n);
    Stdio.printf("one RunLoop.main(): %d\n", (i32)(SsLib.loop() == (pointer)RunLoop.main()));
#endif
    Stdio.printf("one OperationQueue.main(): %d\n", (i32)(SsLib.queue() == (pointer)OperationQueue.main()));
    Stdio.printf("one NotificationCenter.shared(): %d\n", (i32)(SsLib.center() == (pointer)NotificationCenter.shared()));
    Stdio.printf("one Null.null(): %d\n", (i32)(SsLib.nothing() == (pointer)Null.null()));
#if SS_ANSWER == 42
    Stdio.printf("the library's defines: %d %d\n", SS_ANSWER, SS_TWICE(7));
#else
    Stdio.printf("the library's defines: missing\n");
#endif
    return 0;
    }
