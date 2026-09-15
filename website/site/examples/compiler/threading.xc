// threading.xc — Thread, Mutex, Guard, Atomic and Pool.
//
// Threading exists on the NATIVE targets only (arm64, x86_64, win64, arm9).
// On xt6502 and m68k every one of these classes is a hard #error rather than a
// stub, because a threading API that silently runs single-threaded is worse
// than one that refuses to build.
//
// The load-bearing part is not in this file. Two threads touching one object
// race on its ARC REFCOUNT, so the back end emits refcount updates as atomic
// read-modify-writes — automatically, for any module that spawns a thread.
// `-fthread-safe-arc` / `-fno-thread-safe-arc` force the decision either way.
#import "Stdio.xc"
#import "Foundation.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Atomic.xc"
#import "Pool.xc"

// A thread body is a bound method (`^`), so the thread's state is just the
// object the method belongs to — no void* context argument, no cast on entry.
class Worker : Object
{
    i32     id;
    i32     result;
    void init(void) { id = (i32)0; result = (i32)0; }

    static Worker* withId(i32 n) { Worker* w = new Worker(); w.id = n; return w; }

    // This runs on the new thread.
    void run(void)
    {
        i32 acc = (i32)0;
        for (i32 i = (i32)1; i <= (i32)1000; i = i + (i32)1) acc = acc + i * id;
        result = acc;
    }
}

// Shared mutable state, guarded. `Guard.on(m)` locks now and unlocks when the
// guard is released at end of scope — including on an early return or a throw.
class Ledger : Object
{
    Mutex* lock;
    i32    balance;
    void init(void) { lock = new Mutex(); balance = (i32)0; }

    void deposit(i32 amount)
    {
        Guard* g = Guard.on(lock);
        balance = balance + amount;
    }
}

class Summer : Object
{
    Ledger* ledger;
    void init(void) { ledger = 0; }
    void addMany(void)
    {
        for (i32 i = (i32)0; i < (i32)500; i = i + (i32)1) ledger.deposit((i32)2);
    }
}

// Pool.forRange calls a body once per index, spread over the available cores.
// The body is a `^` too, so it can accumulate into the object it belongs to.
class Squares : Object
{
    Atomic* total;
    void init(void) { total = Atomic.withValue((i32)0); }
    void one(i32 i) { total.add(i * i); }
}

i32 main(void)
{
    // ---- spawn and join ----------------------------------------------------
    Worker* a = Worker.withId((i32)2);
    Worker* b = Worker.withId((i32)3);
    Thread* ta = Thread.spawn(&a.run);
    Thread* tb = Thread.spawn(&b.run);
    ta.join();
    tb.join();
    Stdio.printf("workers %ld %ld\n", a.result, b.result);

    // ---- a mutex around shared state ---------------------------------------
    // Two threads, 500 deposits of 2 each: the answer is deterministic only
    // because deposit() takes the lock.
    Ledger* led = new Ledger();
    Summer* s1 = new Summer(); s1.ledger = led;
    Summer* s2 = new Summer(); s2.ledger = led;
    Thread* t1 = Thread.spawn(&s1.addMany);
    Thread* t2 = Thread.spawn(&s2.addMany);
    t1.join();
    t2.join();
    Stdio.printf("balance %ld\n", led.balance);

    // ---- atomics without a lock --------------------------------------------
    // An Atomic is the right tool when the shared state IS one word: no lock,
    // no scope, and no chance of forgetting to unlock.
    Atomic* hits = Atomic.withValue((i32)0);
    hits.add((i32)5);
    hits.add((i32)7);
    Stdio.printf("atomic %ld, cas ok %d, after %ld\n",
                 hits.load(),
                 (i16)(hits.compareAndSwap((i32)12, (i32)100) ? 1 : 0),
                 hits.load());

    // ---- data parallelism --------------------------------------------------
    // forRange hides the thread count; it picks one per core and blocks until
    // every index has been handled.
    Squares* sq = new Squares();
    Pool.forRange((i32)1, (i32)11, &sq.one);
    Stdio.printf("sum of squares 1..10 = %ld\n", sq.total.load());

    return 0;
}
