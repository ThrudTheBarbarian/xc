// operations.xc — UXOperationQueue: work with dependencies, run in a correct
// order.
//
// The queue is the SCHEDULER, and it is deterministic: no threads, no clock, no
// driver. The order it produces is a property of the dependency graph, which is
// what makes it testable.
#import <Stdio.xc>
#import "UXOperationQueue.xc"

class Work : Object
{
    void init(void) { }
    void run(UXOperation* op) { Stdio.printf("    ran %d\n", op.tag); }
}

void report(u8* label, UXOperationQueue* q) {
    Stdio.printf("%s order:", label);
    for (i32 i = (i32)0; i < q.ranCount(); i = i + (i32)1) {
        Stdio.printf(" %d", q.ranTagAt(i));
    }
    Stdio.printf("   ran=%d of %d  deadlocked=%d  allFinished=%d\n",
                 q.ranCount(), q.count(),
                 q.isDeadlocked() ? 1 : 0, q.allFinished() ? 1 : 0);
}

void main(void) {
    Work* w = new Work();

    // ---- a diamond --------------------------------------------------------
    //        1
    //       / \
    //      2   3
    //       \ /
    //        4
    UXOperationQueue* q = new UXOperationQueue();
    UXOperation* o1 = UXOperation.make((i32)1, &w.run);
    UXOperation* o2 = UXOperation.make((i32)2, &w.run);
    UXOperation* o3 = UXOperation.make((i32)3, &w.run);
    UXOperation* o4 = UXOperation.make((i32)4, &w.run);

    o2.addDependency(o1);
    o3.addDependency(o1);
    o4.addDependency(o2);
    o4.addDependency(o3);

    // Added in a deliberately unhelpful order: the queue sorts it out.
    q.addOperation(o4);
    q.addOperation(o3);
    q.addOperation(o2);
    q.addOperation(o1);

    Stdio.printf("diamond, added 4,3,2,1:\n");
    q.run();
    report((u8*)"  ", q);

    // ---- cancellation unblocks dependents ---------------------------------
    // A cancelled operation does not RUN, but it does FINISH — so anything
    // waiting on it proceeds rather than stalling.
    UXOperationQueue* c = new UXOperationQueue();
    UXOperation* a = UXOperation.make((i32)10, &w.run);
    UXOperation* b = UXOperation.make((i32)20, &w.run);
    UXOperation* d = UXOperation.make((i32)30, &w.run);
    b.addDependency(a);
    d.addDependency(b);
    b.cancel();
    c.addOperation(a); c.addOperation(b); c.addOperation(d);

    Stdio.printf("chain 10->20->30 with 20 cancelled:\n");
    c.run();
    report((u8*)"  ", c);
    Stdio.printf("  20 finished=%d cancelled=%d\n",
                 b.isFinished() ? 1 : 0, b.isCancelled() ? 1 : 0);

    // ---- a cycle is detected, not looped over ------------------------------
    UXOperationQueue* cyc = new UXOperationQueue();
    UXOperation* x = UXOperation.make((i32)100, &w.run);
    UXOperation* y = UXOperation.make((i32)200, &w.run);
    UXOperation* z = UXOperation.make((i32)300, &w.run);
    x.addDependency(y);
    y.addDependency(x);      // x and y wait on each other
    z.addDependency(x);      // z waits on the deadlock

    cyc.addOperation(x); cyc.addOperation(y); cyc.addOperation(z);
    Stdio.printf("cycle 100<->200, with 300 downstream:\n");
    cyc.run();
    report((u8*)"  ", cyc);

    // ---- independent work, and an operation with no block ------------------
    UXOperationQueue* flat = new UXOperationQueue();
    flat.addOperation(UXOperation.make((i32)7, &w.run));
    flat.addOperation(UXOperation.make((i32)8, &w.run));
    // A null block is a legal no-op — useful as a barrier others depend on.
    UXOperation* barrier = UXOperation.make((i32)9,
                                            (callback void(UXOperation* op))0);
    flat.addOperation(barrier);

    Stdio.printf("three independent (9 has no block):\n");
    flat.run();
    report((u8*)"  ", flat);

    // ---- running twice is harmless ----------------------------------------
    // Everything is already finished, so nothing re-runs.
    Stdio.printf("run() again on the diamond:\n");
    q.run();
    report((u8*)"  ", q);

    // An empty queue finishes immediately and is not deadlocked.
    UXOperationQueue* none = new UXOperationQueue();
    none.run();
    report((u8*)"empty queue:", none);
}
