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
#if !(ARCH_6502 || ARCH_m68k || ARCH_wasm32)
#import "ParTiles.xc"
#endif
#if ARCH_wasm32
#import "ParWebGpu.xc"
#endif

#if ARCH_arm64 || ARCH_x86_64 || ARCH_win64
// The bytes from p to the end of the page-aligned heap block it points into,
// or -1 outside every such block (the runtime's registry, rt.c).
i64 _xtc_simd_span(pointer p);
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
    // Generated too, for a block that overwrites a global array whole: true
    // for that global's name, so its old contents need not reach the device.
    bool gpuWritesAll(u8* name)
        {
        return false;
        }
    // Generated too, for a block that overwrites a captured array whole: true
    // for own ivar k, so its old contents need not reach the device.
    bool gpuWritesAllOwn(i32 k)
        {
        return false;
        }
    // Generated too: true for own ivar k / the named global when the body only
    // reads that array, so it need not be copied back.
    bool gpuReadsOnly(i32 k)
        {
        return false;
        }
    bool gpuReadsOnlyGlobal(u8* name)
        {
        return false;
        }
    i64 gpuGlobalBytes(u8* name)
        {
        return (i64)0 - (i64)1;
        }

    // The bytes a GPU kernel takes the block object as: this object's own,
    // for a generated block; a worker on another machine (ParRemote.xc)
    // holds the object it was sent as bytes beside a stand-in chunk.
    u8* objBytes(void)
        {
        return (u8*)(pointer)self;
        }
    // Whether a worker should hand a tile's reduction partials back raw, as
    // bytes, instead of folding them into a chunk copy: the remote worker,
    // whose fold happens where the block's class is.
    bool rawPartials(void)
        {
        return false;
        }
    // What a thread runs: a bound method that is never overridden, so the
    // binding is unambiguous, and whose call to run() dispatches to the block.
    void go(void)
        {
        run();
        }
    }

// A block the IR outliner made (XC_PAR_PROPOSE=outline; experimental): one
// class for every such block. Its captured values and its reductions'
// accumulators are a byte record, and the three pieces that differ per block
// are methods the compiler replaces in a vtable it makes for the block: body
// (the loop over [lo, hi) on a record), resetCtx (a record's accumulators to
// their identities) and mergeCtx (one record's accumulators folded into
// another's).
class ParFnChunk : ParChunk
    {
    Data* _ctx;
    u8* _name;

    void body(u8* ctx, i64 from, i64 to)
        {
        }
    void resetCtx(u8* ctx)
        {
        }
    void mergeCtx(u8* into, u8* from)
        {
        }
    void run(void)
        {
        body(_ctx.bytes(), lo, hi);
        }
    ParChunk* copyChunk(void)
        {
        ParFnChunk* c = new ParFnChunk();
        // The block's own vtable, so that the copy runs the same body.
        *(pointer*)(pointer)c = *(pointer*)(pointer)self;
        c._ctx = Data.withData(_ctx);
        c._name = _name;
        resetCtx(c._ctx.bytes());
        return (ParChunk*)c;
        }
    void merge(ParChunk* other)
        {
        mergeCtx(_ctx.bytes(), ((ParFnChunk*)other)._ctx.bytes());
        }
    u8* parName(void)
        {
        return _name;
        }
    // A GPU takes the block as its record: the captures, as a generated
    // block's object holds them, and lo and hi where a generated block's
    // object has them (bytes 8 and 16, ParChunk's fields).
    u8* objBytes(void)
        {
        u8* r = _ctx.bytes();
        *(i64*)(pointer)(r + 8) = lo;
        *(i64*)(pointer)(r + 16) = hi;
        return r;
        }
    u8* ctx(void)
        {
        return _ctx.bytes();
        }
    static ParFnChunk* make(u32 bytes, u8* name)
        {
        ParFnChunk* c = new ParFnChunk();
        c._ctx = Data.withLength(bytes);
        c._name = name;
        return c;
        }
    // The block over [lo, hi): on the par runtime, or here, serially, where
    // the compiler's check at the call found two of its arrays overlapping.
    static void runOn(ParFnChunk* c, i64 from, i64 to, bool serial)
        {
        if (serial)
            {
            c.lo = from;
            c.hi = to;
            c.run();
            ParDevice.ranClear((ParChunk*)c);
            ParDevice.ranAdd((ParChunk*)c, String.withCString("cpu"));
            return;
            }
        // The record holds each accumulator's value from before the loop,
        // where a generated block's object holds its identity (the code
        // after the block folds in the value before). A device takes the
        // record as it is, every thread starting from it, so the block
        // runs from the identity and the value before is folded in after.
        Data* before = Data.withData(c._ctx);
        c.resetCtx(c._ctx.bytes());
        Par.run((ParChunk*)c, from, to);
        c.mergeCtx(before.bytes(), c._ctx.bytes());
        memcpy((pointer)c._ctx.bytes(), (pointer)before.bytes(), (u64)before.length());
        }
    }

// Never made. A second class that overrides the three per-block methods, so
// that ParFnChunk's calls to them are dispatched through the vtable (the
// compiler binds a call to a method nothing overrides), which is where a
// block's own vtable puts its versions.
class ParFnChunkBase : ParFnChunk
    {
    void body(u8* ctx, i64 from, i64 to)
        {
        }
    u8* gpuSource(void)
        {
        return "";
        }
    pointer gpuGlobal(u8* name)
        {
        return (pointer)0;
        }
    i64 gpuGlobalBytes(u8* name)
        {
        return (i64)0 - (i64)1;
        }
    i64 gpuLength(i32 k)
        {
        return (i64)0 - (i64)1;
        }
    void resetCtx(u8* ctx)
        {
        }
    void mergeCtx(u8* into, u8* from)
        {
        }
    }

class Par
    {
    // The byte length a block's generated gpuLength() reports for a captured
    // pointer to numbers: the bytes from p to the end of the page-aligned
    // heap block it points into (a `simd:` array, or any numeric array of
    // 64 KB and more, which the runtime aligns unasked), or -1 when p is in
    // no such block — a pointer into a small array, a stack array, a global —
    // and the block runs on the CPU as before. On a target without the
    // aligned allocator a `simd:` pointer is trusted to be its block's start
    // and sized from the header, as it was; elem is the element's size.
    static i64 spanOf(pointer p, i64 elem, bool simdType)
        {
        if (p == (pointer)0)
            return (i64)0 - (i64)1;
#if ARCH_arm64 || ARCH_x86_64 || ARCH_win64
        parGlobals();
        return _xtc_simd_span(p);
#else
#if ARCH_6502
        // No GPU, and no element count in a primitive array's header.
        return (i64)0 - (i64)1;
#else
        if (!simdType)
            return (i64)0 - (i64)1;
        return (i64)((u8*)p).length * elem;
#endif
#endif
        }

    // Run a block over [lo, hi), on the device chosen for it: the GPU or the
    // CPU, by XC_PAR, Par.device, or (auto) by measuring both (ParDevice.xc).
    static void run(ParChunk* proto, i64 lo, i64 hi)
        {
        if (hi <= lo)
            return;
        ParDevice.ranClear(proto);
        // A block --par-auto made from a plain loop that par-check could not
        // prove independent, or that a GPU could not run: its kernel is the
        // marker `// xcpar serial`, and it runs as its source reads, one item
        // after another, on this thread. First, before anything asks the
        // hardware: that cost a demoted loop 15 % over the plain one.
        if (ParDevice.serialOnly(proto.gpuSource()))
            {
            proto.lo = lo;
            proto.hi = hi;
            proto.run();
            ParDevice.ranAdd(proto, String.withCString("cpu"));
            return;
            }
#if (ARCH_arm64 && !PLATFORM_ios) || ARCH_x86_64 || ARCH_wasm32
        // The GPU's identity, for the hardware key auto keeps its choices
        // under, asked of the runtime only when choose() will look them up.
        if (ParDevice.needsHardware(proto))
#if ARCH_wasm32
            ParDevice.setHardware(Par.gpuIdentity(), new String());
#else
            ParDevice.setHardware(Par.gpuIdentity(), ParTiles.identities());
        // Several devices on one tile queue (par-tiles-and-devices.md step
        // 3): every block when XC_PAR_WORKERS names the workers, else when
        // auto finds the GPUs (3) or every device (4) the fastest. Not on
        // wasm32: its runtime has no threads, so no CPU worker, and WebGPU
        // is one device.
        if (ParTiles.explicit() && ParTiles.run(proto, proto.gpuSource(), lo, hi, (i32)0))
            return;
#endif
        // Two captured arrays that overlap, one written, run serially too
        // (the alias guard).
        if (!ParDevice.guardsHold(proto, proto.gpuSource(), lo, hi))
            {
            if (ParDevice.reporting())
                Log.info("par: %s: at this run's offset two work items touch the same element, so it runs serially", proto.parName());
            proto.lo = lo;
            proto.hi = hi;
            proto.run();
            ParDevice.ranAdd(proto, String.withCString("cpu"));
            return;
            }
        if (ParDevice.bufferOverlap(proto, proto.gpuSource()))
            {
            if (ParDevice.reporting())
                Log.info("par: %s: two of its arrays overlap and one is written, so it runs serially", proto.parName());
            proto.lo = lo;
            proto.hi = hi;
            proto.run();
            ParDevice.ranAdd(proto, String.withCString("cpu"));
            return;
            }
#if !ARCH_wasm32
        // XC_PAR_PROBE=1: the block's first run is a sweep of tile sizes per
        // worker, written as priors (ParTiles.probe); the run itself follows.
        if (ParDevice.probing() && !ParDevice.probed(proto))
            ParTiles.probe(proto, proto.gpuSource(), lo, hi);
#endif
        i32 choice = ParDevice.choose(proto, hi - lo);
#if !ARCH_wasm32
        if (choice >= (i32)3)
            {
            if (ParTiles.run(proto, proto.gpuSource(), lo, hi, choice))
                return;
            choice = (i32)2;
            }
#endif
        if (choice == (i32)2)
            {
#if ARCH_wasm32
            if (ParWebGpu.run(proto, proto.gpuSource(), lo, hi))
                {
                ParDevice.ranAdd(proto, ParWebGpu.identity());
                return;
                }
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
                    {
                    ParDevice.ranAdd(proto, ParCuda.identity());
                    return;
                    }
                ParDevice.cannotRun(proto, (i32)1);
                }
            ParDevice.useApi((i32)2);
            if (ParVulkan.run(proto, proto.gpuSource(), lo, hi))
                {
                ParDevice.ranAdd(proto, ParVulkan.identity());
                return;
                }
            ParDevice.cannotRun(proto, (i32)2);
            if (api == (i32)2 && !ParDevice.vulkanOnly())
                {
                ParDevice.useApi((i32)1);
                if (ParCuda.run(proto, proto.gpuSource(), lo, hi))
                    {
                    ParDevice.ranAdd(proto, ParCuda.identity());
                    return;
                    }
                ParDevice.cannotRun(proto, (i32)1);
                }
#elif ARCH_x86_64 || PLATFORM_android
            if (ParVulkan.run(proto, proto.gpuSource(), lo, hi))
                {
                ParDevice.ranAdd(proto, ParVulkan.identity());
                return;
                }
#else
            if (ParMetal.run(proto, proto.gpuSource(), lo, hi))
                {
                ParDevice.ranAdd(proto, ParMetal.identity());
                return;
                }
#endif
            }
        i64 t0 = ParDevice.nowUs();
        Par.runCpu(proto, lo, hi);
        ParDevice.ranOnCpu(proto, ParDevice.nowUs() - t0);
#else
        Par.runCpu(proto, lo, hi);
#endif
        ParDevice.ranAdd(proto, String.withCString("cpu"));
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

    // The hardware the block's last run used, as its runtimes name it: "cpu",
    // "metal:…", "cuda:…", "vulkan:…", "remote:…" — several when the run was
    // split across devices; empty when it has not run. By the block's name,
    // as Par.device takes it: its source name, or file:line (a lifted loop
    // too). Float results can differ in their last bits from one device to
    // another; integer results never do.
    static Array* ranOn(u8* block)
        {
        return ParDevice.ranOn(block);
        }

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
#if !ARCH_wasm32
        // The lanes made once for the process, unless they are taken: a
        // thread spawned per run cost a third of a small block's time.
        if (ParCpuLanes.run(proto, lo, hi, k))
            return;
#endif
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

// From C: the hardware a block's last run used, as Par.ranOn gives it, joined
// with ", " ("cuda:…, cpu"); "" when it has not run. The block is named as
// XC_PAR_REPORT names it: file:line for a loop --par-auto made a block of.
// The text stays valid until the next call for the same block.
u8* xc_par_ran_on(u8* block)
{
    return ParDevice.ranOnText(block);
}
