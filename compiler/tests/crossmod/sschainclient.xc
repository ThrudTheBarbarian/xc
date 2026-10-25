// sschainclient.xc — a program importing only the SECOND library of a chain
// (stdstate.sh): its singletons must be the ones that library uses, SsLib's,
// one per process. It kept a copy of its own before (2026-10-24): the second
// library bound its state to the first and offered none, so this program
// found nothing to bind to.
#import <Stdio.xc>
#import <SsChain>
i32 main(void)
    {
    Stdio.printf("one OperationQueue.main(): %d\n", (i32)(SsChain.queue() == (pointer)OperationQueue.main()));
    Stdio.printf("one NotificationCenter.shared(): %d\n", (i32)(SsChain.center() == (pointer)NotificationCenter.shared()));
    Stdio.printf("one Null.null(): %d\n", (i32)(SsChain.nothing() == (pointer)Null.null()));
    return 0;
    }
