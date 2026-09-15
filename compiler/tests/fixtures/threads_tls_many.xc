//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_tls_many.xc — per-thread storage, at a scale that catches a shared one.
//
// The point of this fixture is the SCALE. Two threads with different values in
// one slot is satisfied by almost anything, including a table with a hard row
// limit or a key that quietly aliases; a hundred threads is not. Before the
// freestanding Linux runtime gave each thread a context block, its TLS was a
// (tid, key) table with 64 rows — this fixture would have had 36 threads
// sharing whatever the last writer left (private:docs/Design/threading.md §9.3).
//
//   T1  100 threads each write their own value, sleep, and read it back. Every
//       one reads what IT wrote — a shared slot fails 99 times, a capped table
//       fails for every thread past the cap.
//   T2  the main thread's own value survives all of that untouched.
//   T3  two independent slots do not alias.
//
// The sleep between write and read is what makes it a real test: without it a
// thread could finish before the next one starts, and a single shared slot
// would pass.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "ThreadLocal.xc"
#import "Atomic.xc"
#import "Foundation.xc"

ThreadLocal* gSlot;
ThreadLocal* gOther;
Atomic*      gWrong;
Atomic*      gRan;

class Worker
{
    u32 mine;

    void init(void) { }

    void run(void)
    {
        gSlot.set((pointer)mine);
        gOther.set((pointer)(mine + (u32)1000));
        Thread.sleepMs((u32)2);                    // let every other thread write
        if (gSlot.get()  != (pointer)mine)                 gWrong.increment();
        if (gOther.get() != (pointer)(mine + (u32)1000))   gWrong.increment();
        gRan.increment();
    }

    // A factory, not a bare `new` in the loop — see Pool.xc for why.
    static Worker* make(u32 id)
    {
        Worker* w = new Worker();
        w.mine = id;
        return w;
    }
}

void main(void)
{
    gSlot  = new ThreadLocal();
    gOther = new ThreadLocal();
    gWrong = new Atomic();
    gRan   = new Atomic();

    gSlot.set((pointer)999999);                    // T2: the main thread's value
    gOther.set((pointer)888888);

    Array* workers = new Array();
    Array* handles = new Array();
    for (u32 i = (u32)1; i <= (u32)100; i++)
    {
        Worker* w = Worker.make(i);
        workers.add((Object*)w);
        handles.add((Object*)Thread.spawn(&w.run));
    }
    for (u32 i = (u32)0; i < handles.count(); i++)
        ((Thread*)handles.get(i)).join();

    Assert.isEqual((u32)gRan.load(), (u32)100);            // all ran
    Assert.isEqual((u32)gWrong.load(), (u32)0);            // T1 + T3
    Assert.isTrue(gSlot.get()  == (pointer)999999);        // T2a
    Assert.isTrue(gOther.get() == (pointer)888888);        // T2b

    Assert.summary();
}
