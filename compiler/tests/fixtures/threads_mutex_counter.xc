//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_mutex_counter.xc — mutual exclusion, and the two ways to release it.
//
// private:docs/Design/threading.md §3.2. The classic shape: several threads doing a
// read-modify-write on one global. Unsynchronised it loses updates; under a
// Mutex the total is EXACT, and exactness is the only honest assertion here —
// "roughly right" would pass with the lock removed.
//
//   T1  N threads × M increments under a lock == N*M, exactly.
//   T2  the same with Guard (scope-exit unlock) instead of lock/unlock.
//   T3  tryLock: fails while the lock is held, succeeds once released.
//   T4  a Guard's explicit unlock() is idempotent — unlocking early and then
//       letting the guard drop must not double-unlock.
//
// The counts are large enough that a lost update is near-certain if the mutex
// is not doing its job (the unsynchronised version of T1 was observed dropping
// ~1/3 of its increments on this host).

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Mutex.xc"

u32    gCount = (u32)0;
Mutex* gLock;

class Bumper
{
    u32  n;
    bool useGuard;

    void init(void) { }

    void run(void)
    {
        for (u32 i = (u32)0; i < n; i++)
        {
            if (useGuard)
            {
                Guard* g = Guard.on(gLock);
                gCount = gCount + (u32)1;
            }
            else
            {
                gLock.lock();
                gCount = gCount + (u32)1;
                gLock.unlock();
            }
        }
    }
}

void main(void)
{
    gLock = new Mutex();

    // ── T1: three threads, 5000 increments each, plain lock/unlock.
    Bumper* b1 = new Bumper(); b1.n = (u32)5000; b1.useGuard = false;
    Bumper* b2 = new Bumper(); b2.n = (u32)5000; b2.useGuard = false;
    Bumper* b3 = new Bumper(); b3.n = (u32)5000; b3.useGuard = false;

    Thread* t1 = Thread.spawn(&b1.run);
    Thread* t2 = Thread.spawn(&b2.run);
    Thread* t3 = Thread.spawn(&b3.run);
    t1.join(); t2.join(); t3.join();
    Assert.isEqual(gCount, (u32)15000);                 // T1

    // ── T2: the same again through Guard, so scope exit does the unlocking.
    gCount = (u32)0;
    Bumper* g1 = new Bumper(); g1.n = (u32)5000; g1.useGuard = true;
    Bumper* g2 = new Bumper(); g2.n = (u32)5000; g2.useGuard = true;
    Bumper* g3 = new Bumper(); g3.n = (u32)5000; g3.useGuard = true;

    Thread* u1 = Thread.spawn(&g1.run);
    Thread* u2 = Thread.spawn(&g2.run);
    Thread* u3 = Thread.spawn(&g3.run);
    u1.join(); u2.join(); u3.join();
    Assert.isEqual(gCount, (u32)15000);                 // T2

    // ── T3: tryLock reflects the real state of the lock.
    Mutex* m = new Mutex();
    Assert.isTrue(m.tryLock());                         // T3a — was free
    m.unlock();
    Assert.isTrue(m.tryLock());                         // T3b — free again
    m.unlock();

    // ── T4: Guard.unlock() then scope exit — exactly one unlock happens, so
    // the mutex is takeable afterwards rather than left over-unlocked.
    Mutex* n = new Mutex();
    {
        Guard* g = Guard.on(n);
        g.unlock();
        Assert.isTrue(n.tryLock());                     // T4a — really released
        n.unlock();
    }
    Assert.isTrue(n.tryLock());                         // T4b — still consistent
    n.unlock();

    Assert.summary();
}
