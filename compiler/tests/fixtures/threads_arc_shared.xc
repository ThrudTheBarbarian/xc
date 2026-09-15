//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_arc_shared.xc — the correctness core of threading: ARC under threads.
//
// private:docs/Design/threading.md §4.1 calls the refcount race "the single blocking
// correctness issue", and this is the fixture that would catch its return. The
// shape is the one from the doc: several threads repeatedly taking and dropping
// strong references to objects the main thread also holds, so retain/release on
// the SAME header runs concurrently thousands of times.
//
// A lost increment frees an object that is still referenced (a later use reads
// freed memory, or the dealloc counter over-counts); a lost decrement leaks it
// (the dealloc counter under-counts). Both show up as an exact-count failure:
//
//   T1  every shared object is destroyed exactly once, after the last thread
//       has dropped it — not before, and not never.
//   T2  the objects are still intact while the threads are running (each read
//       returns the value written at construction, not freed-memory garbage).
//   T3  objects created and destroyed ENTIRELY inside a worker thread are also
//       balanced — the allocator itself is reached from several threads.
//
// The counters are themselves shared, so they are updated under a mutex; an
// unsynchronised counter would make a passing run meaningless.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Mutex.xc"

Mutex* gLock;
u32    gMade  = (u32)0;
u32    gGone  = (u32)0;
u32    gBadRead = (u32)0;

class Payload : Object
{
    u32 marker;

    void init(void)
    {
        marker = (u32)3735928559;              // $DEADBEEF — a value freed memory won't hold
        gLock.lock();  gMade = gMade + (u32)1;  gLock.unlock();
    }

    void dealloc(void)
    {
        gLock.lock();  gGone = gGone + (u32)1;  gLock.unlock();
    }

    u32 read(void) { return marker; }
}

// Holds the shared objects. Every worker takes strong references out of it and
// drops them again, which is exactly the retain/release traffic that races.
class Holder
{
    Payload* a;
    Payload* b;
    void init(void) { }
}

Holder* gHolder;

class Hammer
{
    u32 n;
    void init(void) { }

    void run(void)
    {
        for (u32 i = (u32)0; i < n; i++)
        {
            // Local strong references: each assignment retains, each scope exit
            // releases. Two threads doing this to one object is the race.
            Payload* p = gHolder.a;
            Payload* q = gHolder.b;
            if (p.read() != (u32)3735928559 || q.read() != (u32)3735928559)
            {
                gLock.lock();  gBadRead = gBadRead + (u32)1;  gLock.unlock();
            }

            // T3: an object born and buried on this thread.
            Payload* own = new Payload();
            if (own.read() != (u32)3735928559)
            {
                gLock.lock();  gBadRead = gBadRead + (u32)1;  gLock.unlock();
            }
        }
    }
}

void main(void)
{
    gLock   = new Mutex();
    gHolder = new Holder();
    gHolder.a = new Payload();
    gHolder.b = new Payload();

    Hammer* h1 = new Hammer(); h1.n = (u32)3000;
    Hammer* h2 = new Hammer(); h2.n = (u32)3000;
    Hammer* h3 = new Hammer(); h3.n = (u32)3000;

    Thread* t1 = Thread.spawn(&h1.run);
    Thread* t2 = Thread.spawn(&h2.run);
    Thread* t3 = Thread.spawn(&h3.run);
    t1.join(); t2.join(); t3.join();

    // 2 shared + 9000 thread-local objects made.
    Assert.isEqual(gMade, (u32)9002);                  // T3a
    // The 9000 thread-local ones are all gone; the 2 shared ones are NOT (the
    // holder still owns them) — that is the "not freed early" half of T1.
    Assert.isEqual(gGone, (u32)9000);                  // T1a / T3b
    Assert.isEqual(gBadRead, (u32)0);                  // T2

    // Still alive and readable after all that traffic.
    Assert.isEqual(gHolder.a.read(), (u32)3735928559); // T2b
    Assert.isEqual(gHolder.b.read(), (u32)3735928559); // T2c

    // Drop the last references: now exactly the two shared objects die.
    gHolder.a = (Payload*)0;
    gHolder.b = (Payload*)0;
    Assert.isEqual(gGone, (u32)9002);                  // T1b — destroyed exactly once

    Assert.summary();
}
