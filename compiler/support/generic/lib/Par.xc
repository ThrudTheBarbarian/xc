// Par.xc — the CPU runtime behind `par` blocks.
//
// The compiler turns each `par` block into a subclass of ParChunk whose ivars
// are the values the block captured (an array as a pointer to its first
// element), whose reduction variables start at their operator's identity, and
// whose run() is the block's loop over [lo, hi). Par.run splits the range into
// one contiguous chunk per thread, runs them, and folds every chunk's
// reductions into the first in chunk order — so integer reductions are exact
// and the same whatever the thread count.
//
// XC_PAR_THREADS=<n> sets the thread count for one run (1: no threads at all).
// Targets without threads (xt6502, m68k, wasm32) run the whole range on the
// calling thread: a `par` block compiles everywhere and is sequential there.
#import "Foundation.xc"
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
#import "Thread.xc"
#import "PlatformCore.xc"
#endif
// macOS on Apple silicon: XC_PAR=gpu runs blocks on the GPU (ParMetal.xc).
#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
#import "ParMetal.xc"
#endif

class ParChunk : Object
    {
    i64 lo;
    i64 hi;

    // Generated per block.
    void run(void)
        {
        }
    ParChunk* copyChunk(void)
        {
        return (ParChunk*)0;
        }
    void merge(ParChunk* other)
        {
        }

    // For the GPU (generated per block): the kernel's Metal source, or "" when
    // the block cannot run there, and the byte length of own ivar k when it is
    // a captured array, else -1.
    u8* gpuSource(void)
        {
        return "";
        }
    i64 gpuLength(i32 k)
        {
        return (i64)0 - (i64)1;
        }

    // What a thread runs: a bound method that is never overridden, so the
    // binding is unambiguous, and whose call to run() dispatches to the block.
    void go(void)
        {
        run();
        }
    }

class Par
    {
    static void run(ParChunk* proto, i64 lo, i64 hi)
        {
        if (hi <= lo)
            return;
#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
        if (ParMetal.wanted() && ParMetal.run(proto, proto.gpuSource(), lo, hi))
            return;
#endif
#if ARCH_6502 || ARCH_m68k || ARCH_wasm32
        proto.lo = lo;
        proto.hi = hi;
        proto.run();
#else
        i64 n = hi - lo;
        i32 k = Par.threads();
        if ((i64)k > n)
            k = (i32)n;
        if (k <= (i32)1)
            {
            proto.lo = lo;
            proto.hi = hi;
            proto.run();
            return;
            }
        // The calling thread takes the first chunk itself, on `proto`, so a
        // block costs k - 1 spawns and its reductions land in proto directly.
        Array* chunks = new Array();
        Array* threads = new Array();
        for (i32 j = (i32)1; j < k; j = j + (i32)1)
            {
            ParChunk* c = proto.copyChunk();
            c.lo = lo + (n * (i64)j) / (i64)k;
            c.hi = lo + (n * (i64)(j + (i32)1)) / (i64)k;
            chunks.add((Object*)c);
            threads.add((Object*)Thread.spawn(&c.go));
            }
        proto.lo = lo;
        proto.hi = lo + n / (i64)k;
        proto.run();
        for (u32 j = (u32)0; j < threads.count(); j = j + (u32)1)
            ((Thread*)threads.get(j)).join();
        for (u32 j = (u32)0; j < chunks.count(); j = j + (u32)1)
            proto.merge((ParChunk*)chunks.get(j));
#endif
        }

#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
    // XC_PAR_THREADS when it holds a positive number, else the machine's CPUs.
    static i32 threads(void)
        {
        String* v = Platform.env(String.withCString("XC_PAR_THREADS"));
        i32 n = (i32)0;
        for (u32 i = (u32)0; i < v.byteLength(); i = i + (u32)1)
            {
            u8 c = v.byteAt(i);
            if (c < (u8)'0' || c > (u8)'9')
                {
                n = (i32)0;
                break;
                }
            n = n * (i32)10 + (i32)(c - (u8)'0');
            }
        if (n > (i32)0)
            return n;
        i32 cpus = Thread.cpuCount();
        return cpus > (i32)0 ? cpus : (i32)1;
        }
#endif
    }
