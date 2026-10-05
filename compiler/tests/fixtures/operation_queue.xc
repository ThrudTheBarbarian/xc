// operation_queue.xc — Operation and OperationQueue on a serial queue, on
// every target (without threads the queue runs on the waiting thread, with
// the same result). A diamond of dependencies: a, then c and b (c first, its
// priority is high), then d. An operation cancelled before it starts never
// runs main(), but its completion runs and its place in the order is kept.
#import "Stdio.xc"
#import "OperationQueue.xc"
i32 main(void)
{
    // A diamond on a serial queue: a, then b and c (c first: higher priority), then d.
    OperationQueue* q = OperationQueue.serial();
    q.suspend();
    Operation* a = Operation.withBlock(block void(void) { Stdio.printf("a\n"); });
    Operation* b = Operation.withBlock(block void(void) { Stdio.printf("b\n"); });
    Operation* c = Operation.withBlock(block void(void) { Stdio.printf("c\n"); });
    Operation* d = Operation.withBlock(block void(void) { Stdio.printf("d\n"); });
    c.setPriority(Operation.high());
    b.addDependency(a);
    c.addDependency(a);
    d.addDependency(b);
    d.addDependency(c);
    q.add(d);
    q.add(c);
    q.add(b);
    q.add(a);
    // Cancelled before it starts: main() never runs, the completion does.
    Operation* x = Operation.withBlock(block void(void) { Stdio.printf("never\n"); });
    x.setCompletion(block void(void) { Stdio.printf("x done, cancelled=%d\n", x.isCancelled() ? (i32)1 : (i32)0); });
    x.cancel();
    q.add(x);
    Stdio.printf("queued %d, priority of c %d\n", q.count(), c.priority());
    q.resume();
    q.waitUntilAllFinished();
    Stdio.printf("left %d, d finished %d\n", q.count(), d.isFinished() ? (i32)1 : (i32)0);
    return 0;
}
