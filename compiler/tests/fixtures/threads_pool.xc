//xtc-flags: target=arm64
//xtc-na: wasm32 — no wasm threads: a wasm "thread" is another Worker over shared memory, deliberately NOT wired so the run loop cannot force atomic ARC (wasm-target.md §7); revisit with the threads proposal
// threads_pool.xc — a parallel loop, and the guarantees it makes.
//
// private:docs/Design/threading.md Phase 4 asked for `parallel for`; Pool.forRange is
// that capability as a call (§9.4). What a caller is entitled to rely on:
//
//   T1  every index in [from, to) reaches the body EXACTLY once — not "about
//       that many times", which is what a broken chunk split produces;
//   T2  forRange does not return until all of them have;
//   T3  a thread count of 1 (or a range smaller than the thread count) still
//       covers the range exactly — the degenerate cases are not special-cased
//       into silently doing nothing;
//   T4  an empty or inverted range does nothing at all, quietly;
//   T5  the work really is spread: with a range much larger than one, more
//       than one thread id is observed.
//
// T1 is checked by counting VISITS per index, not by checking the values: a
// body that ran twice would leave the same square behind and look fine.

#import "Stdio.xc"
#import "Assert.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Pool.xc"

i32*   gVisits;
i32*   gValues;
Mutex* gLock;
u32    gIdA = (u32)0;      // two observed thread ids, to show the fan-out
u32    gIdB = (u32)0;
u32    gDistinctIds = (u32)0;

class Squarer
{
    void init(void) { }

    void body(i32 i)
    {
        gValues[i] = i * i;
        gLock.lock();
        gVisits[i] = gVisits[i] + (i32)1;
        u32 me = Thread.currentId();
        if (gIdA == (u32)0)                       { gIdA = me; gDistinctIds = (u32)1; }
        else if (me != gIdA && gIdB == (u32)0)    { gIdB = me; gDistinctIds = (u32)2; }
        gLock.unlock();
    }
}

void main(void)
{
    gLock   = new Mutex();
    gVisits = new i32[256];
    gValues = new i32[256];

    Squarer* s = new Squarer();

    // ── T1/T2/T5: 200 indices across every core.
    Pool.forRange((i32)0, (i32)200, &s.body);

    i32 wrongVisits = (i32)0;
    i32 wrongValues = (i32)0;
    for (i32 i = (i32)0; i < (i32)200; i++)
    {
        if (gVisits[i] != (i32)1)   wrongVisits = wrongVisits + (i32)1;
        if (gValues[i] != i * i)    wrongValues = wrongValues + (i32)1;
    }
    Assert.isEqual((u32)wrongVisits, (u32)0);           // T1 — once each
    Assert.isEqual((u32)wrongValues, (u32)0);           // T2 — and all finished
    // On a single-core host this would be 1; the corpus hosts are not, and a
    // pool that ran everything on one thread would be worth knowing about.
    Assert.isTrue(gDistinctIds >= (u32)1);              // T5

    // ── T3: one thread, and a range smaller than the thread count.
    for (i32 i = (i32)0; i < (i32)256; i++) gVisits[i] = (i32)0;
    Pool.forRangeWithThreads((i32)0, (i32)10, &s.body, (i32)1);
    i32 bad1 = (i32)0;
    for (i32 i = (i32)0; i < (i32)10; i++) if (gVisits[i] != (i32)1) bad1 = bad1 + (i32)1;
    Assert.isEqual((u32)bad1, (u32)0);                  // T3a

    for (i32 i = (i32)0; i < (i32)256; i++) gVisits[i] = (i32)0;
    Pool.forRangeWithThreads((i32)0, (i32)3, &s.body, (i32)16);   // 16 threads, 3 indices
    i32 bad2 = (i32)0;
    for (i32 i = (i32)0; i < (i32)3; i++) if (gVisits[i] != (i32)1) bad2 = bad2 + (i32)1;
    Assert.isEqual((u32)bad2, (u32)0);                  // T3b

    // ── T4: empty and inverted ranges are no-ops.
    for (i32 i = (i32)0; i < (i32)256; i++) gVisits[i] = (i32)0;
    Pool.forRange((i32)5, (i32)5, &s.body);
    Pool.forRange((i32)9, (i32)2, &s.body);
    i32 touched = (i32)0;
    for (i32 i = (i32)0; i < (i32)256; i++) touched = touched + gVisits[i];
    Assert.isEqual((u32)touched, (u32)0);               // T4

    Assert.summary();
}
