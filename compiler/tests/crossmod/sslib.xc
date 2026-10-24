// sslib.xc — a library holding standard-library singletons (stdstate.sh).
// RunLoop needs threads, which wasm32 has not.
#if !ARCH_wasm32
#import "RunLoop.xc"
#endif
#import "OperationQueue.xc"
#import "NotificationCenter.xc"
#import "Null.xc"
// A library's own #defines reach its clients through its interface.
#define SS_ANSWER 42
#define SS_TWICE(x) ((x) * 2)
class SsLib
    {
#if !ARCH_wasm32
    static u32 drain(void) { return RunLoop.main().runPending(); }
    static pointer loop(void) { return (pointer)RunLoop.main(); }
#endif
    static pointer queue(void) { return (pointer)OperationQueue.main(); }
    static pointer center(void) { return (pointer)NotificationCenter.shared(); }
    static pointer nothing(void) { return (pointer)Null.null(); }
    }
