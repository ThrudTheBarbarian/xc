//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_cond_sem.xc — blocking rendezvous: condition variables and semaphores.
//
// private:docs/Design/threading.md §3.2. Both types exist to make one thread WAIT for
// another, so the assertions are about ordering that could not hold by accident:
//
//   T1  a consumer blocked in Cond.wait() resumes only after the producer sets
//       the predicate and signals — and it observes the produced value, which
//       is the acquire/release rule of §6 in action.
//   T2  broadcast() wakes EVERY waiter, not one: three consumers all finish.
//   T3  a Sem used as a completion latch — the main thread waits once per
//       worker, so all four have run before it proceeds.
//   T4  a Sem used as a permit pool caps concurrency: with 2 permits and 4
//       workers, the observed peak occupancy never exceeds 2.
//
// T4's "peak" is tracked under a mutex, so it is an exact observation rather
// than a sampled one.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Cond.xc"
#import "Sem.xc"

Mutex* gLock;
Cond*  gCond;
bool   gReady   = false;
u32    gPayload = (u32)0;
u32    gWoken   = (u32)0;

Sem*   gLatch;
Sem*   gPermits;
Mutex* gPeakLock;
u32    gInside  = (u32)0;
u32    gPeak    = (u32)0;
u32    gDone    = (u32)0;

// Waits for the predicate, then records that it woke and what it saw.
class Consumer
{
    u32 saw;
    void init(void) { saw = (u32)0; }
    void run(void)
    {
        gLock.lock();
        while (!gReady) gCond.wait(gLock);   // ALWAYS a loop — see Cond.xc
        saw = gPayload;
        gWoken = gWoken + (u32)1;
        gLock.unlock();
    }
}

// Posts the latch when finished; used to prove "all workers ran".
class LatchWorker
{
    void init(void) { }
    void run(void)
    {
        gPeakLock.lock();
        gDone = gDone + (u32)1;
        gPeakLock.unlock();
        gLatch.post();
    }
}

// Holds a permit for the duration of its "work", tracking peak occupancy.
class PoolWorker
{
    void init(void) { }
    void run(void)
    {
        gPermits.wait();

        gPeakLock.lock();
        gInside = gInside + (u32)1;
        if (gInside > gPeak) gPeak = gInside;
        gPeakLock.unlock();

        Thread.sleepMs((u32)5);              // hold the permit long enough to overlap

        gPeakLock.lock();
        gInside = gInside - (u32)1;
        gPeakLock.unlock();

        gPermits.post();
    }
}

void main(void)
{
    gLock     = new Mutex();
    gCond     = new Cond();
    gPeakLock = new Mutex();

    // ── T1/T2: three consumers block; the producer publishes then broadcasts.
    Consumer* c1 = new Consumer();
    Consumer* c2 = new Consumer();
    Consumer* c3 = new Consumer();
    Thread* t1 = Thread.spawn(&c1.run);
    Thread* t2 = Thread.spawn(&c2.run);
    Thread* t3 = Thread.spawn(&c3.run);

    Thread.sleepMs((u32)20);                 // give them time to reach the wait
    gLock.lock();
    gPayload = (u32)4242;
    gReady   = true;
    gCond.broadcast();
    gLock.unlock();

    t1.join(); t2.join(); t3.join();
    Assert.isEqual(c1.saw, (u32)4242);       // T1 — saw what the producer wrote
    Assert.isEqual(gWoken, (u32)3);          // T2 — every waiter woke
    Assert.isEqual(c2.saw, (u32)4242);
    Assert.isEqual(c3.saw, (u32)4242);

    // ── T3: latch. Four workers post; main waits four times.
    gLatch = new Sem();                      // starts at zero
    LatchWorker* w1 = new LatchWorker();
    LatchWorker* w2 = new LatchWorker();
    LatchWorker* w3 = new LatchWorker();
    LatchWorker* w4 = new LatchWorker();
    Thread* l1 = Thread.spawn(&w1.run);
    Thread* l2 = Thread.spawn(&w2.run);
    Thread* l3 = Thread.spawn(&w3.run);
    Thread* l4 = Thread.spawn(&w4.run);
    for (u32 i = (u32)0; i < (u32)4; i++) gLatch.wait();
    Assert.isEqual(gDone, (u32)4);           // T3 — all four ran before we got here
    l1.join(); l2.join(); l3.join(); l4.join();

    // ── T4: permit pool of 2 with 4 workers — at most 2 inside at any moment.
    gPermits = Sem.withCount((i32)2);
    PoolWorker* p1 = new PoolWorker();
    PoolWorker* p2 = new PoolWorker();
    PoolWorker* p3 = new PoolWorker();
    PoolWorker* p4 = new PoolWorker();
    Thread* q1 = Thread.spawn(&p1.run);
    Thread* q2 = Thread.spawn(&p2.run);
    Thread* q3 = Thread.spawn(&p3.run);
    Thread* q4 = Thread.spawn(&p4.run);
    q1.join(); q2.join(); q3.join(); q4.join();
    Assert.isTrue(gPeak <= (u32)2);          // T4a — the cap held
    Assert.isTrue(gPeak >= (u32)1);          // T4b — and work really happened
    Assert.isEqual(gInside, (u32)0);         // T4c — every permit returned

    Assert.summary();
}
