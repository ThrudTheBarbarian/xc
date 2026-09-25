---
title: Threading
description: Thread, Mutex, Guard, Cond, Sem, Atomic and Pool on the native targets, and how ARC refcounts stay safe across threads.
---

Threading is available on the **native targets only**: `arm64`, `x86_64`,
`win64` and `arm9`. On `xt6502` and `m68k` every one of these classes is a hard
`#error`, with no stub, so a threaded program cannot build and then run
single-threaded.

The API is small: `Thread`, `Mutex` (+ `Guard`), `Cond`, `Sem`, `Atomic`,
`ThreadLocal`, and `Pool.forRange`.

## The part that is not in the library

Two threads that use one object race on its **ARC refcount**. A non-atomic
increment that loses the race under-counts, and the object is freed while still
in use. The crash can then appear far from the cause.

The back ends therefore emit the refcount update as an atomic read-modify-write.
The decision is made **per module**: it is on when the module references the
thread-creation runtime, which happens when the program spawns a thread. You do
not need to request it.

`-fthread-safe-arc` and `-fno-thread-safe-arc` force it on or off when the
automatic decision is wrong. Both flags are `xcc-bootstrap` only. For example, a separately compiled library that a
threaded program will use needs the flag on.

## Spawning

A thread body is a bound method (a `callback`), so the thread's state is the
object the method belongs to. There is no `void*` context and no cast on entry.

```c
class Worker : Object
{
    i32 id;
    i32 result;
    void run(void) { … }            // this runs on the new thread
}

Worker* a = Worker.withId((i32)2);
Thread* ta = Thread.spawn(&a.run);
ta.join();
```

| Method | Effect |
|---|---|
| `Thread.spawn(&obj.body)` | Start a thread running `body`. Returns a `Thread*`. |
| `join()` | Block until the thread finishes. Returns `false` if it could not be joined. |
| `detach()` | Let it run unjoined; its resources are released when it exits. |
| `isValid()` | `false` if the thread failed to start. |
| `Thread.yield()` | Hint to the scheduler. |
| `Thread.sleepMs(u32)` | Sleep the calling thread. |

## Mutex and Guard

`Guard.on(m)` locks immediately and unlocks when the guard is released at the end
of the scope. This includes an early `return` or a `throw`, which a bare
`lock()`/`unlock()` pair does not handle.

```c
class Ledger : Object
{
    Mutex* lock;
    i32    balance;
    void init(void) { lock = new Mutex(); balance = (i32)0; }

    void deposit(i32 amount)
    {
        Guard* g = Guard.on(lock);
        balance = balance + amount;
    }                                    // unlocked here, whatever the exit
}
```

`Mutex` also has `lock()`, `unlock()` and `tryLock()` for when the scope does not
match the critical section.

## Atomics

When the shared state is one word, use an `Atomic`: it needs no lock or scope,
and there is no unlock to forget.

```c
Atomic* hits = Atomic.withValue((i32)0);
hits.add((i32)5);
hits.load();
hits.store((i32)0);
hits.compareAndSwap((i32)12, (i32)100);      // true if it was 12
```

## Cond and Sem

`Cond` is a condition variable paired with a `Mutex`. It waits for a predicate to
become true without spinning. `Sem` is a counting semaphore, for limiting use of
a resource.

## Data parallelism

`Pool.forRange(from, to, &obj.body)` calls the body once per index, spread across
the available cores, and blocks until every index is done. The body is a
callback, so it can accumulate into the object it belongs to:

```c
class Squares : Object
{
    Atomic* total;
    void init(void) { total = Atomic.withValue((i32)0); }
    void one(i32 i) { total.add(i * i); }
}

Squares* sq = new Squares();
Pool.forRange((i32)1, (i32)11, &sq.one);     // 385
```

`Pool.forRangeWithThreads(from, to, body, n)` sets the thread count.

## Worked example

```c
// threading.xc — Thread, Mutex, Guard, Atomic and Pool.
#import "Stdio.xc"
#import "Foundation.xc"
#import "Thread.xc"
#import "Mutex.xc"
#import "Atomic.xc"
#import "Pool.xc"

class Worker : Object
{
    i32 id;
    i32 result;
    void init(void) { id = (i32)0; result = (i32)0; }
    static Worker* withId(i32 n) { Worker* w = new Worker(); w.id = n; return w; }

    void run(void)
    {
        i32 acc = (i32)0;
        for (i32 i = (i32)1; i <= (i32)1000; i = i + (i32)1) acc = acc + i * id;
        result = acc;
    }
}

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

class Squares : Object
{
    Atomic* total;
    void init(void) { total = Atomic.withValue((i32)0); }
    void one(i32 i) { total.add(i * i); }
}

i32 main(void)
{
    // ---- spawn and join ----
    Worker* a = Worker.withId((i32)2);
    Worker* b = Worker.withId((i32)3);
    Thread* ta = Thread.spawn(&a.run);
    Thread* tb = Thread.spawn(&b.run);
    ta.join();
    tb.join();
    Stdio.printf("workers %ld %ld\n", a.result, b.result);

    // ---- a mutex around shared state ----
    Ledger* led = new Ledger();
    Summer* s1 = new Summer(); s1.ledger = led;
    Summer* s2 = new Summer(); s2.ledger = led;
    Thread* t1 = Thread.spawn(&s1.addMany);
    Thread* t2 = Thread.spawn(&s2.addMany);
    t1.join();
    t2.join();
    Stdio.printf("balance %ld\n", led.balance);

    // ---- atomics without a lock ----
    Atomic* hits = Atomic.withValue((i32)0);
    hits.add((i32)5);
    hits.add((i32)7);
    Stdio.printf("atomic %ld, cas ok %d, after %ld\n",
                 hits.load(),
                 (i16)(hits.compareAndSwap((i32)12, (i32)100) ? 1 : 0),
                 hits.load());

    // ---- data parallelism ----
    Squares* sq = new Squares();
    Pool.forRange((i32)1, (i32)11, &sq.one);
    Stdio.printf("sum of squares 1..10 = %ld\n", sq.total.load());

    return 0;
}
```

```
workers 1001000 1501500
balance 2000
atomic 12, cas ok 1, after 100
sum of squares 1..10 = 385
```

The balance is deterministic because `deposit` takes the lock: two threads each
make 500 deposits of 2.

## Runtime

The runtime uses pthreads on macOS, raw `clone` + futex (Linux) or kernel32
(Windows) on the freestanding targets, and XTOS threads on `arm9`. Both macOS
runtimes share one runtime source.

On `arm9` the kernel provides only thread lifecycle and a futex. `Mutex`, `Cond`
and `Sem` are built on it in user space, so an uncontended lock is
`ldrex`/`strex` and never enters the kernel. Two behaviours there differ from a
host:

- **A faulting thread ends its whole process.** The thread may have held shared
  locks and left shared state half-updated, so its siblings stop too.
- **`cpuCount()` returns 1**, because XTOS owns one A9 core. A plain
  `Pool.forRange` therefore runs one worker. Set the count with
  `Pool.forRangeWithThreads` when a workload needs more (the limit is 128 threads
  per process).

**Known gap:** the static-initialiser guard (`__sinit_<Class>`) is a
check-then-act, so two threads that touch the same class's statics for the first
time at once can both run the initialiser.
