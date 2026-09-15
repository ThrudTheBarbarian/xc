//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_static_init.xc — the race-free static-init once.
//
// private:docs/Design/threading.md §4.3 / §9.5. `static_init_once.xc` pins the SEMANTICS
// of the once (exactly once, re-entrancy sees zeroed state, mutual dependency
// resolves) on one thread. This pins them when several threads reach a class's
// FIRST static use simultaneously, which is the case the plain check-then-act
// flag got wrong.
//
// There are two distinct bugs here and a fix can close one without the other:
//
//   T1  EXACTLY ONCE. Two threads both read the flag as 0 and both run `init`.
//       Caught by counting runs.
//   T2  NO HALF-INITIALISED READ. The loser sails past a flag that says "in
//       flight" and reads statics the winner has not finished writing. A bare
//       CAS fixes T1 and leaves T2 — so this is the assertion that distinguishes
//       a real once from a cheap one.
//
// `init` deliberately writes its fields SLOWLY and out of order — a long spin
// between the first field and the last — so a reader that does not wait has a
// wide window to observe the gap rather than a lucky-timing one.
//
//   T3  re-entrancy still behaves: a class whose init touches itself does not
//       deadlock against the new wait, and still sees zeroed state.
//
// ── It bites, and here is the evidence ───────────────────────────────────
//
// With the once DISABLED but atomic ARC left ON — isolating this fix from the
// flag it shares — this program SEGFAULTS, 6 runs out of 6. With it enabled,
// 6 of 6 clean. The failure mode is a crash rather than a reported tear, which
// is if anything the stronger signal: concurrent initialisers scribbling over
// one class's static block do not politely produce a wrong number.
//
// The arrival counters below are what make it race, and are worth keeping. An
// earlier version of this fixture PASSED with the fix off, because spawning is
// so much slower than the init body that thread 1 finished before thread 2
// existed. The counters report `atInitStart=2 atInitEnd=4` — two racers already
// waiting when init began, all four before it ended — which is how we know the
// window is genuinely open rather than the test being lucky. They are not
// asserted on: they are timing, and asserting on timing is how a test becomes
// flaky. They are here to be READ when this fixture ever goes quiet again.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Atomic.xc"

// The class every worker races to touch first.
class Shared
{
    static u32 first;
    static u32 last;
    static u32 initRuns;
    static u32 reentrantSaw;

    static void init(void)
    {
        initRuns = initRuns + (u32)1;
        gAtInitStart.store(gArrived.load());
        first = (u32)0xAAAA;
        // A wide, PRECISE window: a thread that does not WAIT for the init to
        // finish sees first set and last still zero. A sleep rather than a spin
        // because the window has to be long enough to swallow thread-start
        // jitter — a busy loop big enough to do that takes seconds in generated
        // code, and a shorter one let every racer arrive after init had already
        // finished, which is exactly how this fixture first failed to fail.
        Thread.sleepMs((u32)250);
        // T3: a re-entrant read of our own class must not deadlock on the new
        // wait, and must see the ZERO value rather than 0xAAAA.
        reentrantSaw = Shared.peekLast();
        gAtInitEnd.store(gArrived.load());
        last = (u32)0xBBBB;
    }

    static u32 peekFirst(void) { return first; }
    static u32 peekLast(void)  { return last; }
    static u32 runs(void)      { return initRuns; }
    static u32 reentrant(void) { return reentrantSaw; }
}

Atomic* gTorn;          // workers that saw first-set-but-last-unset
Atomic* gDone;
// A start barrier. Without it this fixture cannot fail: spawning is far slower
// than the init body, so thread 1 finishes before thread 2 exists and the race
// never opens. Every racer spins here until main releases them, so they reach
// the first static use together.
Atomic* gGo;
// Timing witnesses — see the header. Not asserted on.
Atomic* gArrived;
Atomic* gAtInitStart;
Atomic* gAtInitEnd;

class Racer
{
    void init(void) { }

    void run(void)
    {
        while (gGo.load() == (i32)0) { }        // all four leave the gate together
        gArrived.add((i32)1);
        // The FIRST static use of Shared, from several threads at once.
        u32 f = Shared.peekFirst();
        u32 l = Shared.peekLast();
        // Either the init has not been observed at all (both zero — impossible
        // here, since the guard runs it before returning) or it is COMPLETE.
        // Anything in between is a half-initialised read.
        if (f == (u32)0xAAAA && l != (u32)0xBBBB) gTorn.add((i32)1);
        if (f != (u32)0xAAAA)                     gTorn.add((i32)1);
        gDone.add((i32)1);
    }
}

i32 main(void)
{
    gTorn = Atomic.withValue((i32)0);
    gDone = Atomic.withValue((i32)0);
    gGo   = Atomic.withValue((i32)0);
    gArrived     = Atomic.withValue((i32)0);
    gAtInitStart = Atomic.withValue((i32)0);
    gAtInitEnd   = Atomic.withValue((i32)0);

    Racer* a = new Racer();
    Racer* b = new Racer();
    Racer* c = new Racer();
    Racer* d = new Racer();

    Thread* t1 = Thread.spawn(&a.run);
    Thread* t2 = Thread.spawn(&b.run);
    Thread* t3 = Thread.spawn(&c.run);
    Thread* t4 = Thread.spawn(&d.run);
    gGo.store((i32)1);                               // release the barrier
    t1.join();
    t2.join();
    t3.join();
    t4.join();

    Assert.isEqual(gDone.load(), (i32)4);            // all four ran
    Assert.isEqual(Shared.runs(), (u32)1);           // T1 — exactly once
    Assert.isEqual(gTorn.load(), (i32)0);            // T2 — nobody saw a half-init
    Assert.isEqual(Shared.peekFirst(), (u32)0xAAAA); // and the state is complete
    Assert.isEqual(Shared.peekLast(),  (u32)0xBBBB);
    Assert.isEqual(Shared.reentrant(), (u32)0);      // T3 — re-entry saw zero, no deadlock

    Assert.summary();
    return 0;
}
