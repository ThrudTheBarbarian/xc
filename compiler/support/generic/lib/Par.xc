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
// A GPU runtime: Metal on macOS (Apple silicon), Vulkan on Linux, CUDA's
// driver on Windows (NVIDIA). Each runs a block on the GPU when ParDevice
// chooses it.
#if ARCH_arm64 && !PLATFORM_ios && !PLATFORM_android
#import "ParMetal.xc"
#endif
#if ARCH_x86_64 || (ARCH_arm64 && PLATFORM_android)
#import "ParVulkan.xc"
#endif
#if ARCH_win64
#import "ParCuda.xc"
#endif
#if ARCH_wasm32
#import "ParWebGpu.xc"
#endif

// Two C strings equal: how a block's generated gpuGlobal() finds a global by
// the name its Metal kernel gives it.
bool parSameName(u8* a, u8* b)
    {
    u32 i = (u32)0;
    while (a[i] != (u8)0 && a[i] == b[i])
        i = i + (u32)1;
    return a[i] == b[i];
    }

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
    // Generated too: the block's name (its source name, or file:line).
    u8* parName(void)
        {
        return "par";
        }
    // Generated too: where the global called `name` lives, and its size in
    // bytes; null and -1 for a name the block does not use.
    pointer gpuGlobal(u8* name)
        {
        return (pointer)0;
        }
    i64 gpuGlobalBytes(u8* name)
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
    // Run a block over [lo, hi), on the device chosen for it: the GPU or the
    // CPU, by XC_PAR, Par.device, or (auto) by measuring both (ParDevice.xc).
    static void run(ParChunk* proto, i64 lo, i64 hi)
        {
        if (hi <= lo)
            return;
#if (ARCH_arm64 && !PLATFORM_ios) || ARCH_x86_64 || ARCH_wasm32
        // The GPU's identity, for the hardware key auto keeps its choices
        // under, asked of the runtime only when choose() will look them up.
        if (ParDevice.needsHardware(proto))
            ParDevice.setHardware(Par.gpuIdentity());
        if (ParDevice.choose(proto, hi - lo) == (i32)2)
            {
#if ARCH_wasm32
            if (ParWebGpu.run(proto, proto.gpuSource(), lo, hi))
                return;
#elif ARCH_win64
            // NVIDIA's own driver or Vulkan (AMD, Intel, or NVIDIA where CUDA
            // is missing): auto measures both where both work and keeps the
            // faster; XC_PAR_GPU=cuda|vulkan picks one. If the one tried
            // cannot run the block, the other may.
            i32 api = ParDevice.gpuApi(proto);
            if (api == (i32)1)
                {
                ParDevice.useApi((i32)1);
                if (ParCuda.run(proto, proto.gpuSource(), lo, hi))
                    return;
                ParDevice.cannotRun(proto, (i32)1);
                }
            ParDevice.useApi((i32)2);
            if (ParVulkan.run(proto, proto.gpuSource(), lo, hi))
                return;
            ParDevice.cannotRun(proto, (i32)2);
            if (api == (i32)2 && !ParDevice.vulkanOnly())
                {
                ParDevice.useApi((i32)1);
                if (ParCuda.run(proto, proto.gpuSource(), lo, hi))
                    return;
                ParDevice.cannotRun(proto, (i32)1);
                }
#elif ARCH_x86_64 || PLATFORM_android
            if (ParVulkan.run(proto, proto.gpuSource(), lo, hi))
                return;
#else
            if (ParMetal.run(proto, proto.gpuSource(), lo, hi))
                return;
#endif
            }
        i64 t0 = ParDevice.nowUs();
        Par.runCpu(proto, lo, hi);
        ParDevice.ranOnCpu(proto, ParDevice.nowUs() - t0);
#else
        Par.runCpu(proto, lo, hi);
#endif
        }

#if (ARCH_arm64 && !PLATFORM_ios) || ARCH_x86_64 || ARCH_wasm32
    // The GPU this program would run on, as its runtime names it ("" for none).
    static String* gpuIdentity(void)
        {
#if ARCH_wasm32
        return ParWebGpu.identity();
#elif ARCH_win64
        if (!ParDevice.vulkanOnly())
            {
            String* c = ParCuda.identity();
            if (c.byteLength() > (u32)0)
                return c;
            }
        return ParVulkan.identity();
#elif ARCH_x86_64 || PLATFORM_android
        return ParVulkan.identity();
#else
        return ParMetal.identity();
#endif
        }
#endif

    // Which device a block runs on: "cpu", "gpu" or "auto" (measure both
    // and keep the faster), by the block's name — its source name, or
    // file:line — or "par" for every block without its own. An app that keeps
    // the choice in its Settings passes it on here; XC_PAR overrides all.
    static void device(u8* block, u8* choice)
        {
#if (ARCH_arm64 && !PLATFORM_ios) || ARCH_x86_64 || ARCH_wasm32
        ParDevice.setDevice(block, choice);
#endif
        }

    // The CPU path: one chunk per thread.
    static void runCpu(ParChunk* proto, i64 lo, i64 hi)
        {
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
