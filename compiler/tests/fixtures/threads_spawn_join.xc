//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_spawn_join.xc — the core of the threading surface: a bound method
// runs on another thread, and join() sees everything it did.
//
// private:docs/Design/threading.md §3.1. Deliberately checks the SHAPE of the feature
// rather than any timing:
//
//   T1  a spawned thread actually runs, and its side effects are visible after
//       join() — which is the whole promise of join.
//   T2  the receiver is the thread's `self`: each worker sees its OWN fields,
//       so three threads over three receivers produce three different answers.
//   T3  a thread's identity differs from the spawning thread's, and a thread
//       that has been joined cannot be joined again.
//   T4  detach() is a valid alternative ending — the program does not hang and
//       the handle is consumed.
//   T5  a widened FREE function works as a body too (no receiver at all), which
//       is the `^` widening rule, not a threading special case.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"

u32 gFreeFnRan = (u32)0;
u32 gMainId    = (u32)0;

class Worker
{
    u32  input;
    u32  output;
    u32  ranOnId;

    void init(void) { output = (u32)0; ranOnId = (u32)0; }

    void run(void)
    {
        // Read a field, write a field: the receiver IS the argument channel.
        output  = input * (u32)3;
        ranOnId = Thread.currentId();
    }
}

// A body needs no receiver — a plain function widens into a `^` (T5).
void freeBody(void)
{
    gFreeFnRan = (u32)1;
}

void main(void)
{
    gMainId = Thread.currentId();

    // ── T1/T2: three workers, three receivers, three answers.
    Worker* a = new Worker(); a.input = (u32)1;
    Worker* b = new Worker(); b.input = (u32)2;
    Worker* c = new Worker(); c.input = (u32)3;

    Thread* ta = Thread.spawn(&a.run);
    Thread* tb = Thread.spawn(&b.run);
    Thread* tc = Thread.spawn(&c.run);

    Assert.isTrue(ta.isValid());                       // T1a
    Assert.isTrue(ta.join());                          // T1b
    Assert.isTrue(tb.join());
    Assert.isTrue(tc.join());

    Assert.isEqual(a.output, (u32)3);                  // T2a
    Assert.isEqual(b.output, (u32)6);                  // T2b
    Assert.isEqual(c.output, (u32)9);                  // T2c

    // ── T3: identity, and join-once.
    Assert.isNotEqual(a.ranOnId, gMainId);             // T3a — ran elsewhere
    Assert.isFalse(ta.join());                         // T3b — already joined
    Assert.isFalse(ta.isValid());                      // T3c — handle consumed

    // ── T4: detach instead of join. The worker's result is not observable
    // without a rendezvous, so only the handle state is asserted.
    Worker* d = new Worker(); d.input = (u32)4;
    Thread* td = Thread.spawn(&d.run);
    td.detach();
    Assert.isFalse(td.isValid());                      // T4a
    Assert.isFalse(td.join());                         // T4b — nothing to join

    // ── T5: a widened free function as a thread body.
    Thread* tf = Thread.spawn(&freeBody);
    Assert.isTrue(tf.join());                          // T5a
    Assert.isEqual(gFreeFnRan, (u32)1);                // T5b

    Assert.isTrue(Thread.cpuCount() > (i32)0);         // sanity on the sizing hint

    Assert.summary();
}
