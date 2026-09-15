//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_detach_reap.xc — a detached thread must not cost anything forever.
//
// A thread's stack cannot be freed by the thread itself (it is standing on it),
// so a detached thread's resources have to be reclaimed by SOMEONE ELSE, later.
// The freestanding Linux runtime does it with a reap list swept on the next
// create or detach, keyed on the word the kernel zeroes when a thread dies
// (private:docs/Design/threading.md §9.3); the pthreads hosts get it from
// `pthread_detach`. Either way the contract this fixture pins is the same:
//
//   T1  a detached thread still RUNS to completion — reaping must not race the
//       body, which is the way a too-eager reaper would break;
//   T2  many detach-and-forget threads in sequence all run, and the process
//       stays healthy — before the reaper, 200 of them held 200 MB of stacks
//       (measured: peak VmSize 206040 kB → 2264 kB with it);
//   T3  detaching an ALREADY-FINISHED thread is fine, and detaching twice is a
//       no-op rather than a double free;
//   T4  join and detach can be mixed in one program without confusing either.
//
// The memory itself is not asserted here — a fixture cannot read its own VmSize
// portably — so this is the behavioural half. The measurement is in the doc.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Atomic.xc"
#import "Foundation.xc"

Atomic* gRan;
Mutex*  gLock;

class Worker
{
    void init(void) { }
    void run(void)  { gRan.increment(); }

    // Constructed through a factory, not a bare `new`: the call site is a loop
    // (one worker per detached thread), and `new` inside a loop is a leak
    // warning — correct in general, and wrong here because each worker really
    // is a separate object the caller keeps.
    static Worker* make(void) { return new Worker(); }
}

// Kept alive for the whole run: a `^` never retains its receiver, so a detached
// thread's receiver has to outlive it, and an array of workers is how a caller
// arranges that (the same reason Pool holds its workers).
Array* gWorkers;

void main(void)
{
    gRan    = new Atomic();
    gLock   = new Mutex();
    gWorkers = new Array();

    // ── T1: one detached thread, and it really runs.
    {
        Worker* w = new Worker();
        gWorkers.add((Object*)w);
        Thread* t = Thread.spawn(&w.run);
        t.detach();
        Assert.isFalse(t.isValid());                 // T1a — handle consumed
    }
    Thread.sleepMs((u32)50);
    Assert.isEqual((u32)gRan.load(), (u32)1);        // T1b — the body ran

    // ── T2: 64 detach-and-forget threads. Without reclamation each one holds
    // its stack for the life of the process.
    for (u32 i = (u32)0; i < (u32)64; i++)
    {
        Worker* w = Worker.make();
        gWorkers.add((Object*)w);
        Thread* t = Thread.spawn(&w.run);
        t.detach();
        Thread.sleepMs((u32)1);
    }
    Thread.sleepMs((u32)200);
    Assert.isEqual((u32)gRan.load(), (u32)65);       // T2

    // ── T3: detach after the thread has certainly finished, then again.
    {
        Worker* w = new Worker();
        gWorkers.add((Object*)w);
        Thread* t = Thread.spawn(&w.run);
        Thread.sleepMs((u32)50);                     // let it end first
        t.detach();
        t.detach();                                  // no-op, not a double free
        Assert.isFalse(t.join());                    // T3a — nothing to join
    }
    Thread.sleepMs((u32)50);
    Assert.isEqual((u32)gRan.load(), (u32)66);       // T3b

    // ── T4: joined and detached threads in the same program.
    {
        Worker* a = new Worker();
        Worker* b = new Worker();
        gWorkers.add((Object*)a);
        gWorkers.add((Object*)b);
        Thread* ta = Thread.spawn(&a.run);
        Thread* tb = Thread.spawn(&b.run);
        tb.detach();
        Assert.isTrue(ta.join());                    // T4a
    }
    Thread.sleepMs((u32)50);
    Assert.isEqual((u32)gRan.load(), (u32)68);       // T4b

    Assert.summary();
}
