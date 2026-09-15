//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_atomic_tls.xc — lock-free counters, and per-thread storage.
//
// private:docs/Design/threading.md §3.2 (Atomic) and §3.3 (thread-local storage; the
// `thread` qualifier was not implemented — see ThreadLocal.xc for why the
// library class is what exists instead).
//
//   T1  concurrent increments through Atomic are exact — the same shape as the
//       mutex counter fixture, with no lock in sight.
//   T2  add() returns the value AFTER the operation, and never returns the same
//       value to two threads (each caller gets a distinct ticket).
//   T3  compare-and-swap succeeds only on the expected value, and the loser of
//       a contended CAS really loses.
//   T4  exchange() returns the previous value.
//   T5  a ThreadLocal slot holds a DIFFERENT value per thread, and the main
//       thread's value is unaffected by what the workers stored.
//
// T2's distinctness check is the interesting one: it is what a plain `x = x+1`
// fails even when the total happens to come out right.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Atomic.xc"
#import "ThreadLocal.xc"

Atomic*      gCounter;
Atomic*      gTickets;
ThreadLocal* gSlot;

// Ticket bookkeeping: each thread records the tickets it drew, and afterwards
// every ticket in 1..N must have been drawn exactly once.
u8*    gSeen;                 // one byte per ticket
Mutex* gSeenLock;
u32    gDuplicate = (u32)0;

class Counter
{
    u32 n;
    void init(void) { }
    void run(void)
    {
        for (u32 i = (u32)0; i < n; i++) gCounter.increment();
    }
}

class Ticketer
{
    u32 n;
    void init(void) { }
    void run(void)
    {
        for (u32 i = (u32)0; i < n; i++)
        {
            i32 t = gTickets.add((i32)1);      // the ticket THIS call produced
            gSeenLock.lock();
            if (gSeen[(u32)t] != (u8)0) gDuplicate = gDuplicate + (u32)1;
            gSeen[(u32)t] = (u8)1;
            gSeenLock.unlock();
        }
    }
}

class Stasher
{
    u32     mine;
    pointer readBack;
    void init(void) { readBack = (pointer)0; }
    void run(void)
    {
        gSlot.set((pointer)mine);
        Thread.sleepMs((u32)5);                // let the other threads store theirs
        readBack = gSlot.get();                // must still be OURS
    }
}

void main(void)
{
    gCounter  = new Atomic();
    gTickets  = new Atomic();
    gSeenLock = new Mutex();
    gSlot     = new ThreadLocal();
    gSeen     = new u8[4096];

    // ── T1: 3 × 5000 lock-free increments.
    Counter* c1 = new Counter(); c1.n = (u32)5000;
    Counter* c2 = new Counter(); c2.n = (u32)5000;
    Counter* c3 = new Counter(); c3.n = (u32)5000;
    Thread* t1 = Thread.spawn(&c1.run);
    Thread* t2 = Thread.spawn(&c2.run);
    Thread* t3 = Thread.spawn(&c3.run);
    t1.join(); t2.join(); t3.join();
    Assert.isEqual((u32)gCounter.load(), (u32)15000);      // T1

    // ── T2: 3 × 1000 tickets, all distinct and covering 1..3000.
    Ticketer* k1 = new Ticketer(); k1.n = (u32)1000;
    Ticketer* k2 = new Ticketer(); k2.n = (u32)1000;
    Ticketer* k3 = new Ticketer(); k3.n = (u32)1000;
    Thread* u1 = Thread.spawn(&k1.run);
    Thread* u2 = Thread.spawn(&k2.run);
    Thread* u3 = Thread.spawn(&k3.run);
    u1.join(); u2.join(); u3.join();
    Assert.isEqual((u32)gTickets.load(), (u32)3000);       // T2a
    Assert.isEqual(gDuplicate, (u32)0);                    // T2b — no ticket twice
    u32 missing = (u32)0;
    for (u32 i = (u32)1; i <= (u32)3000; i++) if (gSeen[i] == (u8)0) missing = missing + (u32)1;
    Assert.isEqual(missing, (u32)0);                       // T2c — none skipped

    // ── T3/T4: single-threaded semantics of CAS and exchange.
    Atomic* a = Atomic.withValue((i32)7);
    Assert.isTrue(a.compareAndSwap((i32)7, (i32)11));      // T3a
    Assert.isEqual((u32)a.load(), (u32)11);                // T3b
    Assert.isFalse(a.compareAndSwap((i32)7, (i32)99));     // T3c — wrong expectation
    Assert.isEqual((u32)a.load(), (u32)11);                // T3d — and no write happened
    Assert.isEqual((u32)a.exchange((i32)5), (u32)11);      // T4a — returns the old value
    Assert.isEqual((u32)a.load(), (u32)5);                 // T4b

    // ── T5: per-thread storage.
    gSlot.set((pointer)9999);
    Stasher* s1 = new Stasher(); s1.mine = (u32)111;
    Stasher* s2 = new Stasher(); s2.mine = (u32)222;
    Thread* v1 = Thread.spawn(&s1.run);
    Thread* v2 = Thread.spawn(&s2.run);
    v1.join(); v2.join();
    Assert.isTrue(s1.readBack == (pointer)111);            // T5a — kept its own
    Assert.isTrue(s2.readBack == (pointer)222);            // T5b
    Assert.isTrue(gSlot.get() == (pointer)9999);           // T5c — main's is untouched

    Assert.summary();
}
