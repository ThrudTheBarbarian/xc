// sschain.xc — the second library of a chain (stdstate.sh): it imports SsLib,
// so its standard-library state is SsLib's, and hands out its singletons.
#import <SsLib>
#import "OperationQueue.xc"
#import "NotificationCenter.xc"
#import "Null.xc"
class SsChain
    {
    static pointer queue(void) { return (pointer)OperationQueue.main(); }
    static pointer center(void) { return (pointer)NotificationCenter.shared(); }
    static pointer nothing(void) { return (pointer)Null.null(); }
    }
