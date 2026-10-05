//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads (see threads_cond_sem.xc); the serial fallback is operation_queue.xc
// operation_queue_threads.xc — OperationQueue on worker threads: never more
// operations at once than setMaxConcurrent, a dependency on another queue,
// addAll waiting for its operations, an operation cancelled while it runs, and
// the main queue (on RunLoop.main() where there is one).
#import "Stdio.xc"
#import "Atomic.xc"
#import "OperationQueue.xc"

class Spinner : Operation
{
    void main(void)
    {
        while (!isCancelled())
            Thread.sleepMs((u32)1);
        Stdio.printf("spinner saw the cancel\n");
    }
}

i32 main(void)
{
    // At most three at once, all forty run.
    OperationQueue* q = new OperationQueue();
    q.setMaxConcurrent((i32)3);
    Atomic* now = Atomic.withValue((i32)0);
    Atomic* peak = Atomic.withValue((i32)0);
    Atomic* ran = Atomic.withValue((i32)0);
    for (u32 i in 0..40)
        q.addBlock(block void(void) {
            i32 n = now.increment();
            i32 p = peak.load();
            while (n > p && !peak.compareAndSwap(p, n))
                p = peak.load();
            Thread.sleepMs((u32)2);
            now.decrement();
            ran.increment();
        });
    q.waitUntilAllFinished();
    Stdio.printf("ran %d, at most 3 at once: %d\n", ran.load(), peak.load() <= (i32)3 ? (i32)1 : (i32)0);

    // A dependency on another queue.
    Atomic* step = Atomic.withValue((i32)0);
    OperationQueue* other = OperationQueue.serial();
    Operation* slow = Operation.withBlock(block void(void) { Thread.sleepMs((u32)20); step.store((i32)1); });
    Operation* after = Operation.withBlock(block void(void) {
        Stdio.printf("after ran once slow had: %d\n", step.load());
    });
    after.addDependency(slow);
    other.add(after);
    q.add(slow);
    after.waitUntilFinished();

    // addAll, waiting.
    Array* batch = new Array();
    for (u32 i in 0..5)
        batch.add((Object*)Operation.withBlock(block void(void) { ran.increment(); }));
    q.addAll(batch, true);
    Stdio.printf("after the batch: %d\n", ran.load());

    // Cancelled while it runs: main() sees it.
    Spinner* sp = new Spinner();
    q.add(sp);
    Thread.sleepMs((u32)20);
    sp.cancel();
    sp.waitUntilFinished();

    // The main queue.
    OperationQueue.main().addBlock(block void(void) { Stdio.printf("on the main queue\n"); });
    OperationQueue.main().waitUntilAllFinished();
    return 0;
}
