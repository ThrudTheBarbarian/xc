// ParDevice.xc — where each `par` block runs, for the targets with a GPU
// runtime (ParMetal.xc on macOS, ParCuda.xc on Windows): the choice between
// the CPU and the GPU, the record auto keeps, XC_PAR_REPORT, and the reading
// of a kernel's header line,
//   // xcpar size=<bytes> lo=<off> hi=<off> buf=<off>:<own-ivar>:<elem-bytes>…
//            glob=<name>:<elem-bytes>… red=<off>:<bytes>[:<stride>]…
// which says where the block object keeps lo, hi, each captured array, each
// global it uses and each reduction. The GPU runtimes share all of it, and
// differ only in how they compile a kernel, move the data and launch.
//
// From 0.73 auto's choices are KEPT, in the program's own settings store
// (Settings.standard(<program name>)), so the measuring is paid once per
// machine rather than on every run. Two tables:
//
//   par.<block> = cpu | gpu | auto | <N>     the user's: read, never written;
//   par = …                                  <N> runs the block on the GPU from
//                                            N items up. `par` is every block.
//   par.learned.<hw>.<block>.<code> = <cpuUpTo>,<gpuFrom>
//                                            auto's: the largest size the CPU
//                                            won at and the smallest the GPU
//                                            won at (-1: none yet).
//
// <hw> hashes the GPU (interface, name, ids) and the CPU (model, threads), so
// a different GPU learns afresh and the old one's entries wait for it; <code>
// hashes the block's GPU version, so a changed block learns afresh. A size
// outside the learned bounds is decided without measuring; one between them
// is measured (sizes within a factor of two count as one) and narrows them.
// The order: XC_PAR, then Par.device, then the user's table, then the learned
// one, then measuring.
#import "Settings.xc"
#import "Process.xc"
// The compiler version, which keys the learned-choice cache below so a new
// release re-learns (a changed code generator can move the CPU/GPU crossover).
// A plain source constant, NOT a predefined macro: the self-host differentials
// build the port compiler without a version define, and a predefine would then
// differ from the reference and break lib-diff on every par library. Bumped
// with VERSION each release (release-checklist). A re-issue of a version
// changes it too: 0.85's re-issue generates different code (and kernels), so
// its learned choices, and the xcd daemons it works with, are its own.
#define PAR_CACHE_VER "0.87.3"
#if !ARCH_wasm32
// Wall-clock epoch seconds, stamped into each learned record so a future
// `xcc --par-forget-before <date>` can prune by age. Monotonic clocks (what
// the timing path uses) cannot date a record; time() can, and is in every
// native C library. wasm32 has no C library and does not keep the cache.
i64 time(pointer t);
#endif
#if ARCH_wasm32
// No C library on wasm32: the bytes, one at a time (reduction partials are small).
pointer memcpy(pointer dst, pointer src, u64 n)
    {
    u8* d = (u8*)dst;
    u8* s = (u8*)src;
    for (u64 i = (u64)0; i < n; i = i + (u64)1)
        d[i] = s[i];
    return dst;
    }
#else
pointer memcpy(pointer dst, pointer src, u64 n);
#endif
// The GPU here is across a bus (CUDA, or a discrete Vulkan card): every
// array a block uses is copied there and back around a run. Set by the
// device runtimes when they start; a unified-memory GPU (Metal, an
// integrated Vulkan GPU) leaves it false.
bool gParGpuDiscrete;

// CUDA's driver beside Vulkan: on Windows, and on Linux in a dynamically
// linked program, the one that can load libcuda.so.1 (Par.xc and ParTiles.xc
// spell the same condition out, as they can be read before this file).
#if ARCH_win64 || (ARCH_x86_64 && LINK_DYNAMIC && !PLATFORM_android)
#define PAR_CUDA 1
#endif
#if ARCH_win64
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* perSecond);
i32 GlobalMemoryStatusEx(pointer status);
pointer memset(pointer dst, i32 c, u64 n);
#elif ARCH_x86_64 || ARCH_wasm32 || PLATFORM_android
// Linux's monotonic clock (on wasm32, the loader's, in the same form).
struct _ParTimespec { i64 sec; i64 nsec; }
i32 clock_gettime(i32 clock, pointer ts);
#if !ARCH_wasm32
i32 sysinfo(pointer info);
pointer memset(pointer dst, i32 c, u64 n);
#endif
#else
// Darwin's monotonic clock, in nanoseconds, and the CPU's model for the
// hardware key.
u64 clock_gettime_nsec_np(i32 clock);
i32 sysctlbyname(u8* name, pointer oldp, u64* oldlenp, pointer newp, u64 newlen);
#endif

// Each block seen so far, by its name (the parName() string): the device it
// was set to (0 auto, 1 CPU, 2 GPU) and, for auto, what each device took.
u8* gParBlock[64];
i32 gParSet[64];
i64 gParGpuUs[64];
i64 gParCpuUs[64];
u32 gParGpuRuns[64];    // runs so far on each device: the first is a warm-up
u32 gParCpuRuns[64];
u32 gParBlocks;
i32 gParAll;            // Par.device("par", …): every block without its own
// The kept choices (see the top): the user's setting per block (0 unread, 1
// cpu, 2 gpu, 3 auto, 4 from gParUserN items up, 5 none), the learned bounds
// (-1 none) and whether they were read, the size being measured, the last size.
i32 gParUser[64];
i64 gParUserN[64];
i64 gParCpuUpTo[64];
i64 gParGpuFrom[64];
// The tile queue's two sets (par-tiles-and-devices.md step 3): "gpus" is
// every GPU worker, "all" is those and the CPU pool. Measured after the
// CPU and the one GPU, learned as the size each wins from.
i64 gParGpusUs[64];
i64 gParAllUs[64];
u32 gParGpusRuns[64];
u32 gParAllRuns[64];
i64 gParGpusFrom[64];
i64 gParAllFrom[64];
u32 gParGpuWorkers;     // GPU workers in the default set (ParTiles tells)
// The third queue set (2026-10-17): the GPUs on other machines alone (xcd),
// where one is far faster than this machine's own (an integrated GPU beside
// a remote RTX: "GPUs" let the slow one hold the fast one back).
i64 gParRemUs[64];
u32 gParRemRuns[64];
i64 gParRemFrom[64];
u32 gParRemoteWorkers;  // remote GPU workers in the default set (ParTiles tells)
// Measurements in progress, kept across processes of the program: up to four
// size bands a block, each the size measured and the four candidates' times.
i64 gParProgN[256];
i64 gParProgUs[1280];   // five candidates an entry: cpu, gpu, gpus, all, remote
u32 gParProgCount[64];
bool gParLearned[64];
bool gParProbed[64];    // XC_PAR_PROBE: the block's first run was the sweep
i64 gParMeasN[64];
i64 gParLastN[64];
bool gParMeasuring[64]; // this run is one auto measures (not decided by a setting or the bounds)
// Warm measurement of a GPU candidate (warmTime below), per block and
// candidate: 0 the GPU (through CUDA on Windows), 1 the GPU through Vulkan,
// 2 the GPUs set, 3 the all-devices set, 4 the remote set.
// The fastest worker's rate on the tile queue's last run of the block, in
// items per us scaled by 1024: the next run sizes its tiles so each is worth
// well over the queue's fixed cost per tile (ParTiles).
i64 gParTileRate[64];
u32 gParWarmRuns[320];
i64 gParWarmBusy[320];  // the candidate's run time so far, us
i64 gParWarmFirst[320]; // wall at its first run
i64 gParWarmPrev[320];  // the run before this one, or -1
#if PAR_CUDA
// Windows and Linux reach an NVIDIA GPU two ways, CUDA and Vulkan, and auto measures
// both: per block, the interface kept (0 none yet, 1 CUDA, 2 Vulkan), the
// runs on each and what each took (-1 not yet, -2 the block cannot run
// there), and the interface the current GPU run uses.
i32 gParApi[64];
u32 gParCudaRuns[64];
u32 gParVkRuns[64];
i64 gParCudaUs[64];
i64 gParVkUs[64];
i32 gParRanApi;
#endif

// A kernel's header line, read, and the run planned over [lo, hi): one item
// per thread, unless the range is huge — or the block has reductions, whose
// per-thread partials the host folds: then at most 65536 threads, each
// taking a run of items.
class ParLayout : Object
    {
    i64 size;
    i64 bufOff[16];
    i64 bufLen[16];
    i64 bufIvar[16];      // the captured array's index among the block's ivars
    i64 bufElem[16];      // bytes per element
    i64 globElem[16];
    i64 tiles;            // how many tiles the last run was cut into (0: one shot)
    u32 nbuf;
    u8 globName[1024];    // each global's name, as the header names it, 64 bytes apart
    pointer globPtr[16];
    i64 globLen[16];
    // 1: the kernel overwrites the whole global, so nothing need be copied to
    // the device before it runs; it still comes back (gpuWritesAll, bug 645).
    i64 globOut[16];
    // 1: the body only reads the global / buffer k, so it is not copied back.
    i64 globIn[16];
    i64 bufIn[16];
    // 1: the kernel overwrites the whole captured array k, so nothing need be
    // copied to the device before it runs; it still comes back
    // (gpuWritesAllOwn, as globOut for a global).
    i64 bufOut[16];
    // The elements work item i touches in buffer / global k, from the header's
    // fp= / gfp= words: [fpK*i + fpLo, fpK*i + fpHi), when known (fp = 1);
    // else the whole buffer (par-tiles-and-devices.md step 1).
    i64 bufFp[16];
    i64 bufFpK[16];
    i64 bufFpLo[16];
    i64 bufFpHi[16];
    // 1: the body writes every element of the global in its range (the
    // raw gpuWritesAll, whatever the range), so a tile's slice of it need
    // not be uploaded when the footprint is contiguous (k = 1).
    i64 globAll[16];
    i64 globFp[16];
    i64 globFpK[16];
    i64 globFpLo[16];
    i64 globFpHi[16];
    u32 nglob;
    i64 redOff[16];
    i64 redSize[16];
    i64 redStride[16];  // bytes per thread's partial: redSize, or a 32-bit slot for a narrow one
    u32 nred;
    i64 n;
    i64 per;
    i64 threads;
    // The kernel reduces on the device (header word `devred`, bug 645): each
    // workgroup of 256 threads combines its threads' values and writes one
    // partial, so the host folds `nparts` = workgroups, not threads, and the
    // block plans as one without reductions — one item per thread.
    i64 devred;     // 1: the kernel reduced on the device
    i64 nparts;
    // And when the header also says `devlast`, the LAST workgroup to finish
    // folds every workgroup's partial on the device and leaves the result in
    // slot 0, so one partial comes back instead of `nparts` (bug 645). The
    // buffers are still `nparts` long: every workgroup writes its own first.
    i64 devlast;
    // 1: the kernel takes the block object and its range as launch parameters
    // (header word `byval`, bug 645), so they are not copied to the device.
    i64 byval;
    i64 nback;
    // The static cost model (par-auto-parallelisation.md): `ops` compute ops
    // per item and `hasLoop` whether the item body has a nested loop. With
    // bytesPerItem (from the footprints) these give the arithmetic intensity
    // the runtime uses to prune a hopeless device and seed the partition.
    i64 ops;
    i64 hasLoop;
    // merge=<n>,…: bit n set when the n-th reduction may be folded on a node
    // before the coordinator folds it (the order cannot change its bits).
    // Read for a daemon that merges partials; the coordinator folds them all.
    u32 mergeMask;

    void plan(i64 lo, i64 hi)
        {
        n = hi - lo;
        per = (i64)1;
        i64 most = nred > (u32)0 && devred == (i64)0 ? (i64)65536 : (i64)1 << (i64)22;
        if (n > most)
            per = (n + most - (i64)1) / most;
        threads = (n + per - (i64)1) / per;
        nparts = devred != (i64)0 ? (threads + (i64)255) / (i64)256 : threads;
        nback = devlast != (i64)0 ? (i64)1 : nparts;
        }

    // Each thread's partials, at parts[i] + thread * redStride[i], folded into
    // the block in thread order with its own merge(), so an integer result is
    // the CPU's exactly. One chunk carries them into merge(), which only
    // reads them: no allocation per thread.
    void fold(ParChunk* proto, u8** parts)
        {
        foldN(proto, parts, nback);
        }
    // The same over `count` partials each: a worker on another machine
    // folds by its own layout's count, which its kernel form may set
    // differently (device-side reduction or not), and says so with the tile.
    void foldN(ParChunk* proto, u8** parts, i64 count)
        {
        if (nred == (u32)0)
            return;
        ParChunk* c = proto.copyChunk();
        // The block's bytes (its object, for a generated block; its record,
        // for one the IR outliner made).
        u8* cb = c.objBytes();
        for (i64 t = (i64)0; t < count; t = t + (i64)1)
            {
            for (u32 i = (u32)0; i < nred; i = i + (u32)1)
                memcpy((pointer)(cb + redOff[i]), (pointer)(parts[i] + t * redStride[i]), (u64)redSize[i]);
            proto.merge(c);
            }
        }
    }

#if ARCH_arm64 || ARCH_x86_64 || ARCH_win64
// The program's global arrays with pages of their own (the optimiser's
// gpu-globals pass defines this, registering each), registered the first
// time anything asks the registry: no load-time constructor to lose in a
// link from objects, and none at all in a program without a par block.
void __xt_gpu_globals(void);
bool gParGlobalsDone;
void parGlobals(void)
{
    if (!gParGlobalsDone)
        {
        gParGlobalsDone = true;
        __xt_gpu_globals();
        }
}
// The start of the page-aligned heap block p points into, or 0 (rt.c).
pointer _xtc_simd_base(pointer p);
// Resident data (par-blocks.md §3): the runtime watches a block's pages
// (read-only, the first host write faulting and absorbed).
i32 _xtc_simd_watch(pointer p);
void _xtc_simd_unwatch(pointer p);
i32 _xtc_simd_dirty(pointer p);
#endif
// A block's generation (ParDevice.generation): the watch is one flag per block,
// and a second device re-watching after its own upload would make the first
// device's stale copy look current. So each copy records the generation it
// was made at, and the generation moves on every write the watch catches
// and every write the runtime makes itself (a copy back, a kernel writing a
// pinned block in place, which no page fault sees).
#define PAR_DEV_GENS 64
pointer gParDevGenHost[PAR_DEV_GENS];
i64 gParDevGen[PAR_DEV_GENS];
u32 gParDevGens;
i64 gParDevGenClock;
i64 gParDevGenNext(void)
{
    gParDevGenClock = gParDevGenClock + (i64)1;
    return gParDevGenClock;
}

class ParDevice
    {
    static i32 _mode;            // XC_PAR: 0 unread, 1 cpu, 2 gpu, 3 auto, 4 unset
    static Settings* _store;     // the program's settings store, opened on first use
    static String* _hw;          // the hardware key (hex), once the GPU is known

    // Whether a GPU run may be cut into tiles (par-tiles-and-devices.md
    // step 2): XC_PAR_TILES=0 keeps every run single shot, for comparison.
    static i32 _tilesMode;   // 0 unread, 1 on, 2 off
    static bool tilesWanted(void)
        {
        if (_tilesMode == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR_TILES"));
            _tilesMode = v.byteLength() > (u32)0 && v.byteAt((u32)0) == (u8)'0' ? (i32)2 : (i32)1;
            }
        return _tilesMode == (i32)1;
        }

    // The bytes a tile moves, in megabytes: XC_PAR_TILE_MB, default 8.
    static i64 _tileMb;
    static i64 tileMegabytes(void)
        {
        if (_tileMb == (i64)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR_TILE_MB"));
            i64 n = (i64)0;
            for (u32 i = (u32)0; i < v.byteLength(); i = i + (u32)1)
                if (v.byteAt(i) >= (u8)'0' && v.byteAt(i) <= (u8)'9')
                    n = n * (i64)10 + (i64)(v.byteAt(i) - (u8)'0');
            _tileMb = n > (i64)0 && n <= (i64)1024 ? n : (i64)8;
            }
        return _tileMb;
        }

    static i64 nowUs(void)
        {
#if ARCH_win64
        i64 c = (i64)0;
        i64 f = (i64)1;
        QueryPerformanceCounter(&c);
        QueryPerformanceFrequency(&f);
        return (c / f) * (i64)1000000 + (c % f) * (i64)1000000 / f;
#elif ARCH_x86_64 || ARCH_wasm32 || PLATFORM_android
        _ParTimespec ts;
        clock_gettime((i32)1, (pointer)&ts);   // CLOCK_MONOTONIC on Linux
        return ts.sec * (i64)1000000 + ts.nsec / (i64)1000;
#else
        return (i64)(clock_gettime_nsec_np((i32)6) / (u64)1000); // CLOCK_MONOTONIC
#endif
        }

    static i32 parseDevice(u8* c)
        {
        if (parSameName(c, "cpu"))
            return (i32)1;
        if (parSameName(c, "gpu"))
            return (i32)2;
        if (parSameName(c, "gpus"))
            return (i32)3;
        if (parSameName(c, "all"))
            return (i32)4;
        return (i32)0; // "auto", or anything else
        }

    // The record for a block, by its name string (made on first sight).
    static u32 slot(u8* name)
        {
        for (u32 i = (u32)0; i < gParBlocks; i = i + (u32)1)
            if (gParBlock[i] == name || parSameName(gParBlock[i], name))
                return i;
        if (gParBlocks >= (u32)64)
            return (u32)63;
        u32 i = gParBlocks;
        gParBlock[i] = name;
        gParSet[i] = (i32)-1;
        gParGpuUs[i] = (i64)-1;
        gParCpuUs[i] = (i64)-1;
        gParGpuRuns[i] = (u32)0;
        gParCpuRuns[i] = (u32)0;
        gParUser[i] = (i32)0;
        gParUserN[i] = (i64)0;
        gParCpuUpTo[i] = (i64)-1;
        gParGpuFrom[i] = (i64)-1;
        gParGpusUs[i] = (i64)-1;
        gParAllUs[i] = (i64)-1;
        gParGpusRuns[i] = (u32)0;
        gParAllRuns[i] = (u32)0;
        gParGpusFrom[i] = (i64)-1;
        gParAllFrom[i] = (i64)-1;
        gParRemUs[i] = (i64)-1;
        gParRemRuns[i] = (u32)0;
        gParRemFrom[i] = (i64)-1;
        gParLearned[i] = false;
        gParProgCount[i] = (u32)0;
        gParMeasN[i] = (i64)0;
        gParLastN[i] = (i64)0;
        gParMeasuring[i] = false;
#if PAR_CUDA
        gParApi[i] = (i32)0;
        gParCudaRuns[i] = (u32)0;
        gParVkRuns[i] = (u32)0;
        gParCudaUs[i] = (i64)-1;
        gParVkUs[i] = (i64)-1;
#endif
        gParBlocks = gParBlocks + (u32)1;
        return i;
        }

    static void setDevice(u8* block, u8* choice)
        {
        if (parSameName(block, "par"))
            {
            gParAll = parseDevice(choice) + (i32)1; // 0 = not set
            return;
            }
        gParSet[slot(block)] = parseDevice(choice);
        }

    // XC_PAR_GPU=vulkan: on Windows, Vulkan even where CUDA is there.
    static bool vulkanOnly(void)
        {
        return Platform.env(String.withCString("XC_PAR_GPU")).equals(String.withCString("vulkan"));
        }

#if PAR_CUDA
    // XC_PAR_GPU's interface: 1 cuda, 2 vulkan, 0 neither (auto chooses).
    static i32 forcedApi(void)
        {
        String* v = Platform.env(String.withCString("XC_PAR_GPU"));
        if (v.equals(String.withCString("vulkan")))
            return (i32)2;
        if (v.equals(String.withCString("cuda")))
            return (i32)1;
        return (i32)0;
        }

    // The interface a GPU run of the block tries first: XC_PAR_GPU's, else
    // the one kept, else, while auto measures, CUDA and then Vulkan, each
    // warmed up and timed once. A run auto does not measure uses CUDA.
    static i32 gpuApi(ParChunk* proto)
        {
        i32 f = forcedApi();
        if (f != (i32)0)
            return f;
        u32 i = slot(proto.parName());
        if (gParApi[i] != (i32)0)
            return gParApi[i];
        if (gParMeasuring[i] && gParCudaUs[i] != (i64)-1 && gParVkUs[i] == (i64)-1)
            return (i32)2;
        return (i32)1;
        }

    // The interface the GPU run about to start uses, for ranOnGpu.
    static void useApi(i32 api)
        {
        gParRanApi = api;
        }

    // The block could not run through api (no such device, or no kernel for
    // it): while auto measures, the other interface decides alone.
    static void cannotRun(ParChunk* proto, i32 api)
        {
        if (forcedApi() != (i32)0)
            return;
        u32 i = slot(proto.parName());
        if (gParApi[i] != (i32)0 || !gParMeasuring[i])
            return;
        if (api == (i32)1)
            gParCudaUs[i] = (i64)-2;
        else
            gParVkUs[i] = (i64)-2;
        }
#endif

    // The host's RAM, bytes: total and free now (free 0 where the host does
    // not say cheaply). For a daemon's greeting.
    static void systemMemory(u64* total, u64* free)
        {
        *total = (u64)0;
        *free = (u64)0;
#if ARCH_win64
        u8 st[64];                      // MEMORYSTATUSEX
        memset((pointer)&st[0], (i32)0, (u64)64);
        *(u32*)(pointer)&st[0] = (u32)64;
        if (GlobalMemoryStatusEx((pointer)&st[0]) != (i32)0)
            {
            *total = *(u64*)(pointer)(&st[0] + 8);
            *free = *(u64*)(pointer)(&st[0] + 16);
            }
#elif ARCH_x86_64 || PLATFORM_android
        u8 si[128];                     // struct sysinfo: totalram at 32, freeram at 40, mem_unit at 104
        memset((pointer)&si[0], (i32)0, (u64)128);
        if (sysinfo((pointer)&si[0]) == (i32)0)
            {
            u64 unit = (u64)*(u32*)(pointer)(&si[0] + 104);
            if (unit == (u64)0)
                unit = (u64)1;
            *total = *(u64*)(pointer)(&si[0] + 32) * unit;
            *free = *(u64*)(pointer)(&si[0] + 40) * unit;
            }
#elif ARCH_arm64
        u64 mem = (u64)0;
        u64 len = (u64)8;
        if (sysctlbyname("hw.memsize", (pointer)&mem, &len, (pointer)0, (u64)0) == (i32)0)
            *total = mem;
#endif
        }

    static bool reporting(void)
        {
        return Platform.env(String.withCString("XC_PAR_REPORT")).byteLength() > (u32)0;
        }

    // XC_PAR_REPORT=2: the tile queue's timeline as well — each tile's
    // worker and its submit-to-done time — for placing the per-tile cost.
    static bool tracing(void)
        {
        return Platform.env(String.withCString("XC_PAR_REPORT")).equals(String.withCString("2"));
        }

    // 1 CPU, 2 GPU. XC_PAR first, then the block's own setting, then the one
    // for every block, then auto, by time rather than by size (a few thousand
    // items can each be heavy): the CPU is measured first; a block it runs in
    // under a millisecond stays there, since the GPU's fixed costs alone are
    // more; otherwise the GPU is measured too, and the faster kept. Each
    // device's first run is a warm-up, not counted.
    // ── the kept choices ─────────────────────────────────────────────────

    static Settings* store(void)
        {
        if (_store == (Settings*)0)
            {
            String* name = String.withCString("xc-program");
            Array* av = Process.arguments();
            if (av != (Array*)0 && av.count() > (u32)0)
                {
                String* a0 = ((String*)av.get((u32)0)).lastPathComponent();
                if (a0.hasSuffix(String.withCString(".exe")))
                    a0 = a0.substringBytes((u32)0, a0.byteLength() - (u32)4);
                if (a0.byteLength() > (u32)0)
                    name = a0;
                }
            _store = Settings.standard(name);
            purge(_store);
            }
        return _store;
        }

    // Once per process, on first open: drop learned/measuring records that are
    // not this compiler's (a different version prefix), so a release upgrade
    // re-learns rather than acting on another code generator's crossover, and
    // the old records do not pile up. XC_PAR_FORGET=1 drops ALL of them, for a
    // clean re-measure.
    static void purge(Settings* st)
        {
        bool forget = Platform.env(String.withCString("XC_PAR_FORGET")).byteLength() > (u32)0;
        String* curL = keyHead("learned");
        String* curM = keyHead("measuring");
        String* anyL = String.withCString("par.learned.");
        String* anyM = String.withCString("par.measuring.");
        Array* ks = st.keys();
        bool changed = false;
        for (u32 j = (u32)0; j < ks.count(); j = j + (u32)1)
            {
            String* k = (String*)ks.get(j);
            bool mine = k.hasPrefix(curL) || k.hasPrefix(curM);
            bool ours = k.hasPrefix(anyL) || k.hasPrefix(anyM);
            if (ours && (forget || !mine))
                {
                st.remove(k);
                changed = true;
                }
            }
        if (changed)
            st.save();
        }

    // FNV-1a over the bytes of s, from h.
    static u32 hash(u8* s, u32 h)
        {
        for (u32 k = (u32)0; s[k] != (u8)0; k = k + (u32)1)
            h = (h ^ (u32)s[k]) * (u32)16777619;
        return h;
        }

    // The CPU's part of the hardware key: its model where the system says,
    // and how many threads it runs.
    static String* cpuIdentity(void)
        {
#if ARCH_wasm32
        String* s = String.withCString("cpu:wasm:");     // no threads on wasm32: the GPU is the key
#else
        String* s = String.withFormat("cpu:%d:", Thread.cpuCount());
#endif
#if ARCH_win64
        s.append(Platform.env(String.withCString("PROCESSOR_IDENTIFIER")));
#elif ARCH_x86_64 || PLATFORM_android
        String* info = Files.readText(String.withCString("/proc/cpuinfo"));
        if (info != (String*)0)
            {
            Array* lines = info.splitOnByte((u8)10);
            for (u32 k = (u32)0; k < lines.count(); k = k + (u32)1)
                {
                String* l = (String*)lines.get(k);
                if (l.hasPrefix(String.withCString("model name")) || l.hasPrefix(String.withCString("Hardware")))
                    {
                    u32 c = l.indexOfByte((u8)':');
                    s.append(c != String.notFound() ? l.substringFromByte(c + (u32)1).trimmed() : l);
                    break;
                    }
                }
            }
#elif ARCH_arm64
        u8 brand[128];
        u64 len = (u64)127;
        brand[0] = (u8)0;
        if (sysctlbyname("machdep.cpu.brand_string", (pointer)&brand[0], &len, (pointer)0, (u64)0) == (i32)0)
            {
            brand[127] = (u8)0;
            s.appendCString(&brand[0]);
            }
#endif
        return s;
        }

    // Whether choose() will want the learned table, and so the GPU's identity
    // (Par.run asks the runtime only then: opening a GPU costs something).
    static bool needsHardware(ParChunk* proto)
        {
        if (_hw != (String*)0)
            return false;
        if (_mode == (i32)0)
            choose(proto, (i64)-1);       // reads XC_PAR
        if (_mode == (i32)1 || _mode == (i32)2 || _mode == (i32)5 || _mode == (i32)6)
            return false;
        u8* src = proto.gpuSource();
        if (!hasKernel(src))
            return false;
        u32 i = slot(proto.parName());
        if (_mode == (i32)4)
            {
            i32 dev = gParSet[i];
            if (dev < (i32)0 && gParAll > (i32)0)
                dev = gParAll - (i32)1;
            if (dev > (i32)0)
                return false;
            if (userSetting(i) != (i32)3 && userSetting(i) != (i32)5)
                return false;
            }
        return true;
        }

    // The GPU's identity from its runtime ("" for none) and the tile queue's
    // workers (sorted, "" where there is no queue): the hardware key, so a
    // box with a second card learns apart from the same box with one.
    static void setHardware(String* gpu, String* workers)
        {
        String* both = String.withString(gpu);
        both.appendCString("|");
        both.append(cpuIdentity());
        if (workers.byteLength() > (u32)0)
            {
            both.appendCString("|");
            both.append(workers);
            }
        _hw = String.withFormat("%08x", hash(both.cString(), (u32)2166136261));
        if (reporting())
            Log.info("par: hardware key %s (%s)", _hw.cString(), both.cString());
        }

    // The user's setting for block i: par.<block>, else par.
    static i32 userSetting(u32 i)
        {
        if (gParUser[i] != (i32)0)
            return gParUser[i];
        Settings* st = store();
        String* key = String.withCString("par.");
        key.appendCString(gParBlock[i]);
        String* v = st.get(key);
        if (v == (String*)0)
            v = st.get(String.withCString("par"));
        i32 u = (i32)5;
        if (v != (String*)0)
            {
            if (v.equals(String.withCString("cpu"))) u = (i32)1;
            else if (v.equals(String.withCString("gpu"))) u = (i32)2;
            else if (v.equals(String.withCString("auto"))) u = (i32)3;
            else if (v.equals(String.withCString("gpus"))) u = (i32)6;
            else if (v.equals(String.withCString("all"))) u = (i32)7;
            else if (v.byteLength() > (u32)0 && v.byteAt((u32)0) >= (u8)'0' && v.byteAt((u32)0) <= (u8)'9')
                {
                u32 at = (u32)0;
                gParUserN[i] = num(v.cString(), &at);
                u = (i32)4;
                }
            }
        gParUser[i] = u;
        return u;
        }

    // The key prefix for the current compiler: `par.<kind>.v<version>.`. The
    // version is in the key so a new release's records never collide with an
    // older one's — what a block learned under a different code generator could
    // be wrong even with the same record shape (the CPU/GPU crossover moves).
    // purge() below drops records whose prefix is not the current one.
    static String* keyHead(u8* kind)
        {
        String* p = String.withCString("par.");
        p.appendCString(kind);
        p.appendCString(".v");
        p.appendCString(PAR_CACHE_VER);
        p.appendCString(".");
        return p;
        }
    static String* learnedKey(u32 i, ParChunk* proto)
        {
        String* key = keyHead("learned");
        key.append(_hw);
        key.appendCString(".");
        key.appendCString(gParBlock[i]);
        key.appendFormat(".%08x", hash(proto.gpuSource(), (u32)2166136261));
        return key;
        }

    // ── the probe (XC_PAR_PROBE=1) ─────────────────────────────────────
    // A block's first run sweeps tile sizes per worker and writes what it
    // found as PRIORS: the device crossover into the learned record, the
    // per-worker boundaries here, `<ident>:<knee>:<saturation>:<rate>;…`
    // (rate in items per us times 1024). Run-time learning starts from
    // them and keeps adjusting; the probe only says where to begin.
    static bool probing(void)
        {
        return Platform.env(String.withCString("XC_PAR_PROBE")).byteLength() > (u32)0;
        }
    static bool probed(ParChunk* proto)
        {
        return gParProbed[slot(proto.parName())];
        }
    static void setProbed(ParChunk* proto)
        {
        gParProbed[slot(proto.parName())] = true;
        }
    static String* probeKey(u32 i, ParChunk* proto)
        {
        String* key = keyHead("probe");
        key.append(_hw);
        key.appendCString(".");
        key.appendCString(gParBlock[i]);
        key.appendFormat(".%08x", hash(proto.gpuSource(), (u32)2166136261));
        return key;
        }
    static void saveProbe(ParChunk* proto, String* record)
        {
        if (_hw == (String*)0)
            return;
        Settings* st = store();
        st.set(probeKey(slot(proto.parName()), proto), record);
        st.save();
        }
    // The probe's boundaries for one worker of a block, or false.
    static bool probePrior(ParChunk* proto, String* ident, i64* knee, i64* saturation, i64* rate)
        {
        if (_hw == (String*)0)
            return false;
        String* v = store().get(probeKey(slot(proto.parName()), proto));
        if (v == (String*)0)
            return false;
        Array* entries = v.splitOnByte((u8)';');
        for (u32 e = (u32)0; e < entries.count(); e = e + (u32)1)
            {
            String* en = (String*)entries.get(e);
            // ident:knee:sat:rate — the ident itself may hold ':' (remote:host:…),
            // so the three numbers are read from the END.
            u32 c3 = (u32)$FFFFFFFF;
            u32 c2 = (u32)$FFFFFFFF;
            u32 c1 = (u32)$FFFFFFFF;
            for (u32 k = en.byteLength(); k > (u32)0; k = k - (u32)1)
                if (en.byteAt(k - (u32)1) == (u8)':')
                    {
                    if (c3 == (u32)$FFFFFFFF) c3 = k - (u32)1;
                    else if (c2 == (u32)$FFFFFFFF) c2 = k - (u32)1;
                    else if (c1 == (u32)$FFFFFFFF) { c1 = k - (u32)1; break; }
                    }
            if (c1 == (u32)$FFFFFFFF)
                continue;
            if (!en.substringBytes((u32)0, c1).equals(ident))
                continue;
            u8* s = en.cString();
            u32 at = c1 + (u32)1;
            *knee = num(s, &at);
            at = c2 + (u32)1;
            *saturation = num(s, &at);
            at = c3 + (u32)1;
            *rate = num(s, &at);
            return true;
            }
        return false;
        }

    static String* progressKey(u32 i, ParChunk* proto)
        {
        String* key = keyHead("measuring");
        key.append(_hw);
        key.appendCString(".");
        key.appendCString(gParBlock[i]);
        key.appendFormat(".%08x", hash(proto.gpuSource(), (u32)2166136261));
        return key;
        }

    // The measurements an earlier process of this program left unfinished
    // (<n>,<cpu us>,<gpu us>,<gpus us>,<all us>,<remote us>; entries separated by ';'):
    // a block run a few times a process still learns in the end. Each
    // candidate still warms up once in every process.
    static void readProgress(u32 i, ParChunk* proto)
        {
        gParProgCount[i] = (u32)0;
        String* v = store().get(progressKey(i, proto));
        if (v == (String*)0)
            return;
        u8* c = v.cString();
        u32 at = (u32)0;
        while (c[at] != (u8)0 && gParProgCount[i] < (u32)4)
            {
            i64 f[6];
            f[5] = (i64)-1;                 // a record from before the remote set has five fields
            for (u32 k = (u32)0; k < (u32)6; k = k + (u32)1)
                {
                if (k == (u32)5 && !(c[at] == (u8)'-' || (c[at] >= (u8)'0' && c[at] <= (u8)'9')))
                    break;
                bool ng = c[at] == (u8)'-';
                if (ng) at = at + (u32)1;
                i64 val = num(c, &at);      // always read: "-1" is two characters
                f[k] = ng ? (i64)-1 : val;
                if (c[at] == (u8)',') at = at + (u32)1;
                }
            if (f[0] > (i64)0)
                {
                u32 e = i * (u32)4 + gParProgCount[i];
                gParProgN[e] = f[0];
                for (u32 k = (u32)0; k < (u32)5; k = k + (u32)1)
                    gParProgUs[e * (u32)5 + k] = f[k + (u32)1];
                gParProgCount[i] = gParProgCount[i] + (u32)1;
                }
            if (c[at] == (u8)';') at = at + (u32)1;
            else break;
            }
        }

    // The saved entry for a size within a factor of two of n, if any.
    static i32 progressFor(u32 i, i64 n)
        {
        for (u32 k = (u32)0; k < gParProgCount[i]; k = k + (u32)1)
            {
            i64 pn = gParProgN[i * (u32)4 + k];
            if (n <= pn * (i64)2 && pn <= n * (i64)2)
                return (i32)k;
            }
        return (i32)-1;
        }

    static void readLearned(u32 i, ParChunk* proto)
        {
        if (gParLearned[i] || _hw == (String*)0)
            return;
        gParLearned[i] = true;
        readProgress(i, proto);
        String* v = store().get(learnedKey(i, proto));
        if (v == (String*)0)
            return;
        u8* c = v.cString();
        u32 at = (u32)0;
        bool neg = c[at] == (u8)'-';
        if (neg) at = at + (u32)1;
        i64 a = num(c, &at);
        gParCpuUpTo[i] = neg ? (i64)-1 : a;
        if (c[at] != (u8)',')
            return;
        at = at + (u32)1;
        neg = c[at] == (u8)'-';
        if (neg) at = at + (u32)1;
        i64 b = num(c, &at);
        gParGpuFrom[i] = neg ? (i64)-1 : b;
        // ,gpusFrom,allFrom (a 0.75 record has neither).
        if (c[at] == (u8)',' && (c[at + (u32)1] == (u8)'-' || (c[at + (u32)1] >= (u8)'0' && c[at + (u32)1] <= (u8)'9')))
            {
            at = at + (u32)1;
            neg = c[at] == (u8)'-';
            if (neg) at = at + (u32)1;
            i64 g = num(c, &at);
            gParGpusFrom[i] = neg ? (i64)-1 : g;
            if (c[at] == (u8)',' && (c[at + (u32)1] == (u8)'-' || (c[at + (u32)1] >= (u8)'0' && c[at + (u32)1] <= (u8)'9')))
                {
                at = at + (u32)1;
                neg = c[at] == (u8)'-';
                if (neg) at = at + (u32)1;
                i64 a2 = num(c, &at);
                gParAllFrom[i] = neg ? (i64)-1 : a2;
                // ,remoteFrom (from 2026-10-17).
                if (c[at] == (u8)',' && (c[at + (u32)1] == (u8)'-' || (c[at + (u32)1] >= (u8)'0' && c[at + (u32)1] <= (u8)'9')))
                    {
                    at = at + (u32)1;
                    neg = c[at] == (u8)'-';
                    if (neg) at = at + (u32)1;
                    i64 r2 = num(c, &at);
                    gParRemFrom[i] = neg ? (i64)-1 : r2;
                    }
                }
            }
#if PAR_CUDA
        // ,cuda or ,vulkan: the interface auto chose (none in a 0.73/0.74 record).
        if (c[at] == (u8)',' && gParApi[i] == (i32)0)
            gParApi[i] = c[at + (u32)1] == (u8)'v' ? (i32)2 : c[at + (u32)1] == (u8)'c' ? (i32)1 : (i32)0;
#endif
        }

    static u8* choiceName(i32 c)
        {
        return c == (i32)1 ? "CPU" : c == (i32)2 ? "GPU" : c == (i32)3 ? "GPUs" : c == (i32)5 ? "remote GPUs" : "all devices";
        }

    // A measured run's verdict at size n — winner 1 CPU, 2 the GPU, 3 the
    // GPUs on the tile queue, 4 every device on it: the winner's bound moves
    // to take n in, a losing bound n contradicts is dropped (the newer
    // evidence kept), and they are saved.
    static void learn(u32 i, ParChunk* proto, i64 n, i32 winner)
        {
        if (_hw == (String*)0 || n <= (i64)0)
            return;
        if (winner == (i32)1 && n > gParCpuUpTo[i])
            gParCpuUpTo[i] = n;
        if (winner == (i32)1 && gParCpuUpTo[i] >= (i64)0)
            {
            if (gParGpuFrom[i] >= (i64)0 && gParGpuFrom[i] <= gParCpuUpTo[i]) gParGpuFrom[i] = (i64)-1;
            if (gParGpusFrom[i] >= (i64)0 && gParGpusFrom[i] <= gParCpuUpTo[i]) gParGpusFrom[i] = (i64)-1;
            if (gParAllFrom[i] >= (i64)0 && gParAllFrom[i] <= gParCpuUpTo[i]) gParAllFrom[i] = (i64)-1;
            if (gParRemFrom[i] >= (i64)0 && gParRemFrom[i] <= gParCpuUpTo[i]) gParRemFrom[i] = (i64)-1;
            }
        if (winner == (i32)2 && (gParGpuFrom[i] < (i64)0 || n < gParGpuFrom[i])) gParGpuFrom[i] = n;
        if (winner == (i32)3 && (gParGpusFrom[i] < (i64)0 || n < gParGpusFrom[i])) gParGpusFrom[i] = n;
        if (winner == (i32)4 && (gParAllFrom[i] < (i64)0 || n < gParAllFrom[i])) gParAllFrom[i] = n;
        if (winner == (i32)5 && (gParRemFrom[i] < (i64)0 || n < gParRemFrom[i])) gParRemFrom[i] = n;
        if (winner != (i32)1)
            {
            if (gParCpuUpTo[i] >= n) gParCpuUpTo[i] = (i64)-1;
            if (winner != (i32)2 && gParGpuFrom[i] >= (i64)0 && gParGpuFrom[i] <= n) gParGpuFrom[i] = (i64)-1;
            if (winner != (i32)3 && gParGpusFrom[i] >= (i64)0 && gParGpusFrom[i] <= n) gParGpusFrom[i] = (i64)-1;
            if (winner != (i32)4 && gParAllFrom[i] >= (i64)0 && gParAllFrom[i] <= n) gParAllFrom[i] = (i64)-1;
            if (winner != (i32)5 && gParRemFrom[i] >= (i64)0 && gParRemFrom[i] <= n) gParRemFrom[i] = (i64)-1;
            }
        Settings* st = store();
        String* v = String.withFormat("%ld,%ld,%ld,%ld,%ld", gParCpuUpTo[i], gParGpuFrom[i], gParGpusFrom[i], gParAllFrom[i],
                                      gParRemFrom[i]);
#if PAR_CUDA
        if (gParApi[i] != (i32)0)
            v.appendCString(gParApi[i] == (i32)2 ? ",vulkan" : ",cuda");
#endif
#if !ARCH_wasm32
        // When it was learned, in epoch seconds, in its own `;` segment so the
        // field parser (which stops at the fields it knows) never sees it.
        v.appendFormat(";%ld", time((pointer)0));
#endif
        st.set(learnedKey(i, proto), v);
        st.save();
        if (reporting())
            Log.info("par: %s: learned the %s wins at %ld items (CPU up to %ld, GPU from %ld, GPUs from %ld, all from %ld, remote from %ld)",
                     gParBlock[i], choiceName(winner), n, gParCpuUpTo[i], gParGpuFrom[i], gParGpusFrom[i], gParAllFrom[i],
                     gParRemFrom[i]);
        }

    // What is measured so far at this size, saved for the next process of
    // this program: the entry for this size band is replaced, else one is
    // added (the oldest going when four are kept).
    static void saveProgress(u32 i, ParChunk* proto)
        {
        if (_hw == (String*)0 || gParMeasN[i] <= (i64)0)
            return;
        i32 k = progressFor(i, gParMeasN[i]);
        if (k < (i32)0)
            {
            if (gParProgCount[i] < (u32)4)
                {
                k = (i32)gParProgCount[i];
                gParProgCount[i] = gParProgCount[i] + (u32)1;
                }
            else
                {
                for (u32 j = (u32)1; j < (u32)4; j = j + (u32)1)
                    {
                    gParProgN[i * (u32)4 + j - (u32)1] = gParProgN[i * (u32)4 + j];
                    for (u32 q = (u32)0; q < (u32)5; q = q + (u32)1)
                        gParProgUs[(i * (u32)4 + j - (u32)1) * (u32)5 + q] = gParProgUs[(i * (u32)4 + j) * (u32)5 + q];
                    }
                k = (i32)3;
                }
            }
        u32 e = i * (u32)4 + (u32)k;
        gParProgN[e] = gParMeasN[i];
        gParProgUs[e * (u32)5 + (u32)0] = gParCpuUs[i];
        gParProgUs[e * (u32)5 + (u32)1] = gParGpuUs[i];
        gParProgUs[e * (u32)5 + (u32)2] = gParGpusUs[i];
        gParProgUs[e * (u32)5 + (u32)3] = gParAllUs[i];
        gParProgUs[e * (u32)5 + (u32)4] = gParRemUs[i];
        String* v = new String();
        for (u32 j = (u32)0; j < gParProgCount[i]; j = j + (u32)1)
            {
            u32 f = i * (u32)4 + j;
            if (j > (u32)0) v.appendCString(";");
            v.appendFormat("%ld,%ld,%ld,%ld,%ld,%ld", gParProgN[f], gParProgUs[f * (u32)5], gParProgUs[f * (u32)5 + (u32)1],
                           gParProgUs[f * (u32)5 + (u32)2], gParProgUs[f * (u32)5 + (u32)3], gParProgUs[f * (u32)5 + (u32)4]);
            }
        Settings* st = store();
        st.set(progressKey(i, proto), v);
        st.save();
        }

    // Measuring (re)starts at size n: what an earlier process measured at a
    // size within a factor of two is taken as done.
    static void loadProgress(u32 i, i64 n)
        {
        i32 k = progressFor(i, n);
        if (k < (i32)0)
            return;
        u32 e = i * (u32)4 + (u32)k;
        gParCpuUs[i] = gParProgUs[e * (u32)5 + (u32)0];
        gParGpuUs[i] = gParProgUs[e * (u32)5 + (u32)1];
        gParGpusUs[i] = gParProgUs[e * (u32)5 + (u32)2];
        gParAllUs[i] = gParProgUs[e * (u32)5 + (u32)3];
        gParRemUs[i] = gParProgUs[e * (u32)5 + (u32)4];
        }

    // Once every candidate is timed at the size being measured, the fastest
    // is learned. The queue's sets are candidates only where there are GPU
    // workers (two for "GPUs": one is the GPU again, tiled).
    static void decide(u32 i, ParChunk* proto)
        {
        bool pending = gParCpuUs[i] < (i64)0 || gParGpuUs[i] < (i64)0 ||
                       (gParGpuWorkers >= (u32)2 && gParGpusUs[i] < (i64)0) ||
                       (gParGpuWorkers >= (u32)1 && gParAllUs[i] < (i64)0) ||
                       (gParRemoteWorkers >= (u32)1 && gParRemUs[i] < (i64)0);
        if (pending)
            {
            saveProgress(i, proto);
            return;
            }
        i32 winner = gParGpuUs[i] <= gParCpuUs[i] ? (i32)2 : (i32)1;
        i64 best = gParGpuUs[i] <= gParCpuUs[i] ? gParGpuUs[i] : gParCpuUs[i];
        if (gParGpusUs[i] >= (i64)0 && gParGpusUs[i] < best) { winner = (i32)3; best = gParGpusUs[i]; }
        if (gParAllUs[i] >= (i64)0 && gParAllUs[i] < best) { winner = (i32)4; best = gParAllUs[i]; }
        if (gParRemUs[i] >= (i64)0 && gParRemUs[i] < best) { winner = (i32)5; best = gParRemUs[i]; }
        if (reporting())
            Log.info("par: %s: auto picks the %s (CPU %ld us, GPU %ld us, GPUs %ld us, all %ld us, remote %ld us)", gParBlock[i],
                     choiceName(winner), gParCpuUs[i], gParGpuUs[i], gParGpusUs[i], gParAllUs[i], gParRemUs[i]);
        learn(i, proto, gParMeasN[i], winner);
        }

    // The queue would not run a set for the block (one tile, or no worker
    // holds it): the set is out of the comparison, as if it never ended.
    static void setDeclined(ParChunk* proto, i32 set)
        {
        u32 i = slot(proto.parName());
        if (!gParMeasuring[i])
            return;
        if (set == (i32)3) { gParGpusUs[i] = (i64)1 << (i64)50; gParGpusRuns[i] = (u32)2; }
        else if (set == (i32)5) { gParRemUs[i] = (i64)1 << (i64)50; gParRemRuns[i] = (u32)2; }
        else { gParAllUs[i] = (i64)1 << (i64)50; gParAllRuns[i] = (u32)2; }
        if (reporting())
            Log.info("par: %s: the tile queue declines %s for this block", gParBlock[i], choiceName(set));
        decide(i, proto);
        }

    // A run on the tile queue's set (3 the GPUs, 4 every device), for auto's
    // comparison; the second run of each is the one timed, as below.
    static void ranOnSet(ParChunk* proto, i32 set, i64 us)
        {
        u32 i = slot(proto.parName());
        if (reporting())
            Log.info("par: %s: %ld us on %s", gParBlock[i], us, choiceName(set));
        if (!gParMeasuring[i])
            return;
        i64 warm = (i64)0;
        if (set == (i32)3)
            {
            gParGpusRuns[i] = gParGpusRuns[i] + (u32)1;
            if (gParGpusUs[i] < (i64)0 && warmTime(i, (u32)2, us, &warm))
                gParGpusUs[i] = warm;
            }
        else if (set == (i32)5)
            {
            gParRemRuns[i] = gParRemRuns[i] + (u32)1;
            if (gParRemUs[i] < (i64)0 && warmTime(i, (u32)4, us, &warm))
                gParRemUs[i] = warm;
            }
        else
            {
            gParAllRuns[i] = gParAllRuns[i] + (u32)1;
            if (gParAllUs[i] < (i64)0 && warmTime(i, (u32)3, us, &warm))
                gParAllUs[i] = warm;
            }
        decide(i, proto);
        }

    static i32 choose(ParChunk* proto, i64 n)
        {
        if (_mode == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR"));
            _mode = v.equals(String.withCString("cpu")) ? (i32)1
                  : v.equals(String.withCString("gpu")) ? (i32)2
                  : v.equals(String.withCString("auto")) ? (i32)3
                  : v.equals(String.withCString("gpus")) ? (i32)5
                  : v.equals(String.withCString("all")) ? (i32)6 : (i32)4;
            }
        // The item count is kept for the report whatever decides the device:
        // a forced XC_PAR=cpu run said "0 items" before.
        if (n >= (i64)0)
            gParLastN[slot(proto.parName())] = n;
        if (_mode == (i32)1 || _mode == (i32)2 || n < (i64)0)
            return _mode;
        if (_mode == (i32)5 || _mode == (i32)6)
            return _mode - (i32)2;
        u32 i = slot(proto.parName());
        gParMeasuring[i] = false;
        i32 dev = gParSet[i];
        if (_mode == (i32)4 && dev < (i32)0 && gParAll > (i32)0)
            dev = gParAll - (i32)1;
        if (_mode == (i32)4 && dev > (i32)0)
            return dev;
        u8* src = proto.gpuSource();
        if (!hasKernel(src))
            return (i32)1;
        if (_mode == (i32)4)
            {
            i32 u = userSetting(i);
            if (u == (i32)1 || u == (i32)2)
                return u;
            if (u == (i32)6 || u == (i32)7)
                return u - (i32)3;
            if (u == (i32)4)
                return n >= gParUserN[i] ? (i32)2 : (i32)1;
            }
        // The learned bounds decide a size outside them, with no measuring.
        readLearned(i, proto);
        if (gParRemoteWorkers >= (u32)1 && gParRemFrom[i] >= (i64)0 && n >= gParRemFrom[i])
            return (i32)5;
        if (gParAllFrom[i] >= (i64)0 && n >= gParAllFrom[i])
            return (i32)4;
        if (gParGpusFrom[i] >= (i64)0 && n >= gParGpusFrom[i])
            return (i32)3;
        if (gParGpuFrom[i] >= (i64)0 && n >= gParGpuFrom[i])
            return (i32)2;
        if (gParCpuUpTo[i] >= (i64)0 && n <= gParCpuUpTo[i])
            return (i32)1;
        // Measuring: a size more than twice or less than half the one being
        // measured starts again (a block whose size never repeats would
        // otherwise never finish), the devices already warm.
        if (gParMeasN[i] > (i64)0 && (n > gParMeasN[i] * (i64)2 || n * (i64)2 < gParMeasN[i]))
            {
            gParCpuUs[i] = (i64)-1;
            gParGpuUs[i] = (i64)-1;
            gParGpusUs[i] = (i64)-1;
            gParAllUs[i] = (i64)-1;
            gParRemUs[i] = (i64)-1;
            gParRemRuns[i] = gParRemRuns[i] > (u32)0 ? (u32)1 : (u32)0;
            gParCpuRuns[i] = (u32)1;
            gParGpuRuns[i] = gParGpuRuns[i] > (u32)0 ? (u32)1 : (u32)0;
            gParGpusRuns[i] = gParGpusRuns[i] > (u32)0 ? (u32)1 : (u32)0;
            gParAllRuns[i] = gParAllRuns[i] > (u32)0 ? (u32)1 : (u32)0;
            warmReset(i);
            gParMeasN[i] = n;
            loadProgress(i, n);
            }
        if (gParMeasN[i] == (i64)0)
            {
            gParMeasN[i] = n;
            loadProgress(i, n);
            }
        gParMeasuring[i] = true;
        // A bandwidth-bound block (computeBound: few operations per byte it
        // moves, and no loop per item) cannot win on a GPU across a bus,
        // where every byte goes there and back around the run; auto does not
        // measure it there (par-auto-parallelisation.md, step B.2). A
        // unified-memory GPU is still measured: a `simd:` array costs it no
        // copy at all.
        if (gParGpuUs[i] < (i64)0 && gParGpuDiscrete)
            {
            ParLayout* l = layout(proto, src, (i64)0, n);
            if (l != (ParLayout*)0 && !computeBound(l))
                {
                if (reporting())
                    Log.info("par: %s: auto keeps it on the CPU (bandwidth-bound, and the GPU is across a bus)", gParBlock[i]);
                learn(i, proto, n, (i32)1);
                return (i32)1;
                }
            }
        // The GPU candidates first, the CPU last: a card measured after the
        // CPU's runs has cooled to its idle clocks, which the driver raises
        // only after sustained work (warmTime); measured straight after the
        // hardware probe made its context, it runs at speed. The single GPU,
        // then the tile queue's sets where there are GPU workers.
        if (gParGpuUs[i] < (i64)0)
            return (i32)2;
        // The remote GPUs alone, where there are any: one across the network
        // may beat this machine's own by far, and with it "GPUs" lets the
        // slower card hold the faster back.
        if (gParRemoteWorkers >= (u32)1 && gParRemUs[i] < (i64)0)
            return (i32)5;
        if (gParGpuWorkers >= (u32)2 && gParGpusUs[i] < (i64)0)
            return (i32)3;
        if (gParGpuWorkers >= (u32)1 && gParAllUs[i] < (i64)0)
            {
            // The CPU and a GPU that is not across a bus draw on ONE memory
            // bus (the shares-bandwidth-with-CPU device bit of the design
            // note): on a bandwidth-bound block the two together move no
            // more bytes a second than the faster of them alone, so "all
            // devices" cannot win there and is not measured. The set is out
            // of the comparison as the queue's own decline leaves it.
            ParLayout* l = gParGpuDiscrete ? (ParLayout*)0 : layout(proto, src, (i64)0, n);
            if (l == (ParLayout*)0 || computeBound(l))
                return (i32)4;
            gParAllUs[i] = (i64)1 << (i64)50;
            gParAllRuns[i] = (u32)2;
            if (reporting())
                Log.info("par: %s: auto does not try all devices (bandwidth-bound, and the CPU and GPU share one memory bus)", gParBlock[i]);
            }
        if (gParCpuUs[i] < (i64)0)
            return (i32)1;
        i32 best = gParGpuUs[i] <= gParCpuUs[i] ? (i32)2 : (i32)1;
        i64 bestUs = gParGpuUs[i] <= gParCpuUs[i] ? gParGpuUs[i] : gParCpuUs[i];
        if (gParGpusUs[i] >= (i64)0 && gParGpusUs[i] < bestUs) { best = (i32)3; bestUs = gParGpusUs[i]; }
        if (gParAllUs[i] >= (i64)0 && gParAllUs[i] < bestUs) { best = (i32)4; bestUs = gParAllUs[i]; }
        if (gParRemUs[i] >= (i64)0 && gParRemUs[i] < bestUs) { best = (i32)5; bestUs = gParRemUs[i]; }
        return best;
        }

    // What a run took, for auto's comparison. Each device's first run of a
    // block is a warm-up and is not counted: it pays one-off costs a later run
    // does not (a GPU's first buffers and dispatch, the CPU's first threads),
    // and judging by it kept a block the GPU runs three times as fast on the
    // CPU. The second run of each is the one compared.
    static void ranOnCpu(ParChunk* proto, i64 us)
        {
        u32 i = slot(proto.parName());
        // Only a run auto measures counts: one a setting or the learned bounds
        // decided was not compared with anything, and may be another size.
        if (gParMeasuring[i])
            gParCpuRuns[i] = gParCpuRuns[i] + (u32)1;
        bool measured = gParMeasuring[i] && gParCpuUs[i] < (i64)0 && gParCpuRuns[i] >= (u32)2;
        if (measured)
            gParCpuUs[i] = us;
        bool gpuable = hasKernel(proto.gpuSource());
        if (reporting())
            {
            Log.info("par: %s: %ld items on the CPU, %ld us", gParBlock[i], gParLastN[i], us);
            if (measured && us < (i64)1000 && gpuable && gParGpuUs[i] < (i64)0)
                Log.info("par: %s: auto keeps it on the CPU (%ld us, too short for a GPU to win)", gParBlock[i], us);
            }
        // Under a millisecond the CPU keeps the block without a GPU trial
        // where none has been made (the GPU's fixed costs alone are more);
        // once the GPU is measured, the faster wins as usual.
        if (measured && us < (i64)1000 && gpuable && gParGpuUs[i] < (i64)0)
            learn(i, proto, gParLastN[i], (i32)1);
        else if (measured)
            decide(i, proto);
        }

    // A page-aligned heap block (par-blocks.md §3): a `simd:` array, or a
    // numeric array of 64 KB and more, which the 64-bit runtimes (rt.c,
    // rt-freestanding.c) align unasked and keep in a registry. simdBase is
    // the block a pointer points INTO (its start, or 0 outside every such
    // block), so a pointer offset by arithmetic still finds its block;
    // simdBlock says the pointer IS a block's start. A unified-memory GPU
    // shares such a block in place instead of copying it.
    static pointer simdBase(pointer host)
        {
#if ARCH_arm64 || ARCH_x86_64 || ARCH_win64
        parGlobals();
        return host != (pointer)0 ? _xtc_simd_base(host) : (pointer)0;
#else
        return (pointer)0;
#endif
        }

    static bool simdBlock(pointer host)
        {
        return host != (pointer)0 && simdBase(host) == host;
        }

    // The block at host's generation, watched from here on: -1 when it
    // cannot be watched (not a page-aligned block), so no copy of it is ever
    // taken for current.
    static i64 generation(pointer host)
        {
#if !(ARCH_arm64 || ARCH_x86_64 || ARCH_win64)
        return (i64)-1;
#else
        parGlobals();
        if (host == (pointer)0)
            return (i64)-1;
        u32 at = gParDevGens;
        for (u32 i = (u32)0; i < gParDevGens; i = i + (u32)1)
            if (gParDevGenHost[i] == host)
                at = i;
        if (at == gParDevGens)
            {
            if (gParDevGens == (u32)PAR_DEV_GENS)
                {
                // Full: the oldest entry goes, and its block's copies with it
                // (a generation never seen again cannot match).
                for (u32 i = (u32)1; i < (u32)PAR_DEV_GENS; i = i + (u32)1)
                    {
                    gParDevGenHost[i - (u32)1] = gParDevGenHost[i];
                    gParDevGen[i - (u32)1] = gParDevGen[i];
                    }
                gParDevGens = gParDevGens - (u32)1;
                at = gParDevGens;
                }
            gParDevGenHost[at] = host;
            gParDevGen[at] = gParDevGenNext();
            gParDevGens = gParDevGens + (u32)1;
            }
        if (_xtc_simd_dirty(host) != (i32)0)
            {
            gParDevGen[at] = gParDevGenNext();
            if (_xtc_simd_watch(host) == (i32)0)
                return (i64)-1;
            }
        return gParDevGen[at];
#endif
        }

    // The runtime writes the block at host (a copy back, a kernel on pinned
    // memory): its pages writable, and every copy of it out of date.
    // A pointer INTO a block (`stack + k*n`, a slice of a big array) writes
    // that block: its generation moves too, or a copy of the whole array kept
    // on a GPU was taken for current after its slices were written one at a
    // time (2026-10-26, CUDA: a combine over ten slices saw only the first).
    static void wrote(pointer host)
        {
        pointer base = simdBase(host);
#if ARCH_arm64 || ARCH_x86_64 || ARCH_win64
        _xtc_simd_unwatch(base != (pointer)0 ? base : host);
#endif
        for (u32 i = (u32)0; i < gParDevGens; i = i + (u32)1)
            if (gParDevGenHost[i] == host || (base != (pointer)0 && gParDevGenHost[i] == base))
                gParDevGen[i] = gParDevGenNext();
        }

    // The arrays the block writes: every copy of them out of date.
    static void wroteAll(u8* obj, ParLayout* l)
        {
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufIn[i] == (i64)0)
                ParDevice.wrote(*(pointer*)(obj + l.bufOff[i]));
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globIn[i] == (i64)0)
                ParDevice.wrote(l.globPtr[i]);
        }

    // A GPU candidate's time for auto's comparison: the first run is the
    // warm-up (the kernel build), the second is timed. A card measured AFTER
    // the CPU's runs had cooled to its idle clocks, which the driver raises
    // only after sustained work (the 5080 under Windows: 55 ms a run where
    // the warm card does 19.5, for some 300 ms), so auto measured a cold GPU
    // against a warm CPU; the GPU candidates are therefore measured first,
    // straight after the hardware probe made the card's context, while the
    // driver still holds it at speed (choose). Each run is the program's
    // own: the runtime never repeats one.
    static bool warmTime(u32 i, u32 cand, i64 us, i64* out)
        {
        // Two runs a candidate, the second timed: the contract every size's
        // eight runs rest on (tests/par/keep.sh). The cold card is met by
        // the ORDER instead (choose: the GPU candidates before the CPU), so
        // the threshold rules this once carried are not needed; the state
        // stays, for a run count a future tuning may want.
        u32 e = i * (u32)5 + cand;
        gParWarmRuns[e] = gParWarmRuns[e] + (u32)1;
        gParWarmBusy[e] = gParWarmBusy[e] + us;
        if (gParWarmRuns[e] == (u32)1)
            {
            gParWarmFirst[e] = nowUs();
            gParWarmPrev[e] = (i64)-1;
            return false;
            }
        gParWarmPrev[e] = us;
        *out = us;
        return true;
        }

    // Measuring starts again at another size: a candidate that has run keeps
    // its warm-up, and measures afresh.
    static void warmReset(u32 i)
        {
        for (u32 c = (u32)0; c < (u32)5; c = c + (u32)1)
            {
            u32 e = i * (u32)5 + c;
            gParWarmRuns[e] = gParWarmRuns[e] > (u32)0 ? (u32)1 : (u32)0;
            gParWarmBusy[e] = (i64)0;
            gParWarmPrev[e] = (i64)-1;
            gParWarmFirst[e] = nowUs();
            }
        }

    // A GPU run: took is the whole run (copies in and out included, the
    // one-off kernel build left out), gpuUs the GPU's own time (-1: not known).
    static void ranOnGpu(ParChunk* proto, ParLayout* l, i64 took, i64 gpuUs)
        {
        u32 bi = slot(proto.parName());
        if (gParMeasuring[bi])
            gParGpuRuns[bi] = gParGpuRuns[bi] + (u32)1;
        bool decided = false;
        i64 measured = took;
        i64 warm = (i64)0;
#if PAR_CUDA
        // Neither interface kept yet: each is warmed up and timed on its own,
        // and the GPU's time is the faster one's once both are known.
        if (gParMeasuring[bi] && gParApi[bi] == (i32)0 && forcedApi() == (i32)0)
            {
            if (gParRanApi == (i32)1)
                {
                gParCudaRuns[bi] = gParCudaRuns[bi] + (u32)1;
                if (gParCudaUs[bi] == (i64)-1 && warmTime(bi, (u32)0, took, &warm))
                    gParCudaUs[bi] = warm;
                }
            else
                {
                gParVkRuns[bi] = gParVkRuns[bi] + (u32)1;
                if (gParVkUs[bi] == (i64)-1 && warmTime(bi, (u32)1, took, &warm))
                    gParVkUs[bi] = warm;
                }
            i64 cu = gParCudaUs[bi];
            i64 vk = gParVkUs[bi];
            // CUDA ran the block: it is the card's own interface, and the
            // Vulkan path on the same card is never the faster, so it is not
            // measured (two runs saved). Vulkan is timed where CUDA cannot.
            if (cu >= (i64)0 && gParApi[bi] == (i32)0)
                {
                gParApi[bi] = (i32)1;
                measured = cu;
                decided = gParGpuUs[bi] < (i64)0;
                if (reporting())
                    Log.info("par: %s: the GPU is reached through CUDA (%ld us)", gParBlock[bi], cu);
                }
            else if (cu != (i64)-1 && vk != (i64)-1 && (cu >= (i64)0 || vk >= (i64)0))
                {
                bool useVk = cu < (i64)0 || (vk >= (i64)0 && vk < cu);
                gParApi[bi] = useVk ? (i32)2 : (i32)1;
                measured = useVk ? vk : cu;
                decided = gParGpuUs[bi] < (i64)0;
                if (reporting() && cu >= (i64)0 && vk >= (i64)0)
                    Log.info("par: %s: auto picks %s for the GPU (CUDA %ld us, Vulkan %ld us)", gParBlock[bi],
                             useVk ? "Vulkan" : "CUDA", cu, vk);
                else if (reporting())
                    Log.info("par: %s: the GPU is reached through %s only", gParBlock[bi], useVk ? "Vulkan" : "CUDA");
                }
            }
        else if (gParMeasuring[bi] && gParGpuUs[bi] < (i64)0 && warmTime(bi, (u32)0, took, &warm))
            {
            decided = true;
            measured = warm;
            }
#else
        if (gParMeasuring[bi] && gParGpuUs[bi] < (i64)0 && warmTime(bi, (u32)0, took, &warm))
            {
            decided = true;
            measured = warm;
            }
#endif
        if (decided)
            {
            gParGpuUs[bi] = measured;
            decide(bi, proto);
            }
        if (!reporting())
            return;
        if (gpuUs >= (i64)0 && l.tiles > (i64)0)
            Log.info("par: %s: %ld items on the GPU in %ld tiles, %ld us of GPU time (%ld us in all)",
                     gParBlock[bi], l.n, l.tiles, gpuUs, took);
        else if (gpuUs >= (i64)0)
            Log.info("par: %s: %ld items on the GPU, %ld threads, %ld us of GPU time (%ld us in all)",
                     gParBlock[bi], l.n, l.threads, gpuUs, took);
        else
            Log.info("par: %s: %ld items on the GPU, %ld threads, %ld us in all", gParBlock[bi], l.n, l.threads,
                     took);
        }

    // XC_PAR_REPORT=1: why a block stays on the CPU. False, for `return`.
    static bool cpu(u8* why)
        {
        if (reporting())
            Log.info("par: a block stays on the CPU: %s", why);
        return false;
        }

    // Whether a kernel's header line ends in ` fast`: a block whose goal is
    // speed, which may use approximate maths.
    static bool isFast(u8* src)
        {
        u32 n = (u32)0;
        while (src[n] != (u8)0 && src[n] != (u8)10)
            n = n + (u32)1;
        return n >= (u32)5 && src[n - (u32)5] == (u8)' ' && src[n - (u32)4] == (u8)'f' &&
               src[n - (u32)3] == (u8)'a' && src[n - (u32)2] == (u8)'s' && src[n - (u32)1] == (u8)'t';
        }

    // The decimal number at p, and where it ends.
    // A signed number: a footprint's offsets can be negative (a stencil's
    // `a[i - 1]`).
    static i64 snum(u8* p, u32* at)
        {
        if (p[*at] == (u8)'-')
            {
            *at = *at + (u32)1;
            return (i64)0 - num(p, at);
            }
        return num(p, at);
        }

    static i64 num(u8* p, u32* at)
        {
        i64 v = (i64)0;
        u32 i = *at;
        while (p[i] >= (u8)'0' && p[i] <= (u8)'9')
            {
            v = v * (i64)10 + (i64)(p[i] - (u8)'0');
            i = i + (u32)1;
            }
        *at = i;
        return v;
        }

    // The header line of src, read against the block (the arrays' lengths and
    // the globals' places come from it), planned over [lo, hi). Nil, with the
    // reason reported, when the block cannot go to the GPU.
    // A block's kernel source is sections, one per GPU interface: the MSL,
    // PTX and WGSL text each ended by a NUL with the next on a 4-byte
    // boundary, and the SPIR-V module last (par-check assembles them, every
    // form under -fpar-kernels=all so a worker on another machine finds its
    // own). Each header names its kind — `// xcpar ptx …` — and this finds
    // the section for `kind` ("msl", "ptx", "wgsl", or "spirv", whose header
    // says `spirv=<words>` instead). A program built by an earlier compiler
    // has no kind words: its first section is its target's own form, which
    // `native` takes; the SPIR-V behind a PTX section is still found.
    static u8* sectionOf(u8* src, u8* kind, bool native)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return (u8*)0;
        // The header a block with no form carries is no form of any kind,
        // even where a device is forced (XC_PAR=gpu).
        if (!hasKernel(src))
            return (u8*)0;
        bool wantSpv = kind[0] == (u8)'s';
        u8* s = src;
        while (true)
            {
            u32 h = (u32)0;
            bool spv = false;
            bool hasKind = false;
            bool isKind = false;
            while (s[h] != (u8)0 && s[h] != (u8)10)
                {
                if (s[h] == (u8)' ')
                    {
                    if (s[h + (u32)1] == (u8)'s' && s[h + (u32)2] == (u8)'p' && s[h + (u32)6] == (u8)'=')
                        spv = true;
                    u32 k = (u32)0;
                    while (kind[k] != (u8)0 && s[h + (u32)1 + k] == kind[k])
                        k = k + (u32)1;
                    bool word = kind[k] == (u8)0 && (s[h + (u32)1 + k] == (u8)' ' || s[h + (u32)1 + k] == (u8)10);
                    if (word && !wantSpv)
                        isKind = true;
                    u8 c1 = s[h + (u32)1];
                    u8 c2 = s[h + (u32)2];
                    u8 c3 = s[h + (u32)3];
                    u8 c4 = s[h + (u32)4];
                    if ((c1 == (u8)'m' && c2 == (u8)'s' && c3 == (u8)'l' && c4 == (u8)' ') ||
                        (c1 == (u8)'p' && c2 == (u8)'t' && c3 == (u8)'x' && c4 == (u8)' ') ||
                        (c1 == (u8)'w' && c2 == (u8)'g' && c3 == (u8)'s' && c4 == (u8)'l' && s[h + (u32)5] == (u8)' '))
                        hasKind = true;
                    }
                h = h + (u32)1;
                }
            if (spv)
                return wantSpv ? s : (u8*)0;
            if (hasKind)
                {
                if (isKind)
                    return s;
                }
            else if (!wantSpv)
                return native ? s : (u8*)0;
            // The next section, past this one's NUL.
            u32 e = h;
            while (s[e] != (u8)0)
                e = e + (u32)1;
            u8* n = s + ((e + (u32)4) & ~(u32)3);
            if (!(n[0] == (u8)'/' && n[1] == (u8)'/'))
                return (u8*)0;
            s = n;
            }
        return (u8*)0;
        }

    // Where each block's last run went (Par.ranOn): its name -> the devices
    // that did its work, as their runtimes name them ("cpu", "metal:…",
    // "cuda:…", "vulkan:…", "remote:…"). A float result can differ in its
    // last bits between devices, and a program can say which made it.
    static Map* _ranOn;
    static Map* _ranText;   // its name -> the list as one string (xc_par_ran_on)

    // A run of the block starts: forget where the last one went.
    static void ranClear(ParChunk* proto)
        {
        if (_ranOn == (Map*)0)
            _ranOn = new Map();
        _ranOn.set((Hashable*)String.withCString(proto.parName()), (Object*)new Array());
        }

    // This run did some of its work on `dev`.
    static void ranAdd(ParChunk* proto, String* dev)
        {
        if (dev == (String*)0 || dev.byteLength() == (u32)0)
            return;
        if (_ranOn == (Map*)0)
            _ranOn = new Map();
        String* k = String.withCString(proto.parName());
        Array* a = (Array*)_ranOn.get((Hashable*)k);
        if (a == (Array*)0)
            {
            a = new Array();
            _ranOn.set((Hashable*)k, (Object*)a);
            }
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            if (((String*)a.get(i)).equals(dev))
                return;
        a.add((Object*)String.withString(dev));
        }

    // The devices of the block's last run; empty when it has not run.
    static Array* ranOn(u8* block)
        {
        Array* a = _ranOn != (Map*)0 ? (Array*)_ranOn.get((Hashable*)String.withCString(block)) : (Array*)0;
        return a != (Array*)0 ? a : new Array();
        }

    // The same as one string, "cuda:…, cpu", kept until the next call for it.
    static u8* ranOnText(u8* block)
        {
        Array* a = ParDevice.ranOn(block);
        String* s = new String();
        for (u32 i = (u32)0; i < a.count(); i = i + (u32)1)
            {
            if (i > (u32)0)
                s.appendCString(", ");
            s.append((String*)a.get(i));
            }
        if (_ranText == (Map*)0)
            _ranText = new Map();
        _ranText.set((Hashable*)String.withCString(block), (Object*)s);
        return s.cString();
        }

    // Whether a block's kernel source is the marker par-check leaves on an
    // auto block it demoted: `// xcpar serial`. Such a block runs on one
    // thread (Par.run) and never on a GPU.
    static bool serialOnly(u8* src)
        {
        if (src == (u8*)0)
            return false;
        u8* m = "// xcpar serial";
        u32 i = (u32)0;
        while (m[i] != (u8)0 && src[i] == m[i])
            i = i + (u32)1;
        return m[i] == (u8)0;
        }

    // The checks par-check left the run (guard= words on the header line):
    // the block writes and reads one array at offsets that differ by a
    // captured integer, `a[i + off] = f(a[i])`, which no static test can
    // settle. Each word is <offset>:<bytes>:<m>:<d0>:<k> — the integer v at
    // <offset> in the block's object — and two items meet iff k*(i1 - i2)
    // == d, d = d0 + m*v, for items of [lo, hi). False when they can: the
    // block then runs serially, as its source reads.
    // A captured integer of the block: `bytes` wide at `off` in its object,
    // read signed (0 when there is none).
    static i64 guardValue(u8* obj, i64 off, i64 bytes)
        {
        if (off < (i64)0)
            return (i64)0;
        u8* p = obj + off;
        if (bytes == (i64)1) return (i64)*(i8*)p;
        if (bytes == (i64)2) return (i64)*(i16*)p;
        if (bytes == (i64)4) return (i64)*(i32*)p;
        return *(i64*)p;
        }

    // guardx=<kw>:<cw>:<offw>:<bytesw>:<mw>:<kr>:<cr>:<offr>:<bytesr>:<mr>: a
    // write at kw*i + cw + mw*vw and a read at kr*i + cr + mr*vr meet in no two
    // items of [lo, hi) when the two ranges of elements are disjoint, or, with
    // one stride k, when d (the write's offset less the read's) is 0, not a
    // multiple of k, or at least |k| times the items apart. A side with a
    // second captured integer has it after both:
    // :<offw2>:<bytesw2>:<mw2>:<offr2>:<bytesr2>:<mr2> (offset -1 for none).
    static bool intervalHolds(u8* obj, i64* f, i64 lo, i64 hi)
        {
        i64 ow = f[1] + f[4] * ParDevice.guardValue(obj, f[2], f[3]) + f[12] * ParDevice.guardValue(obj, f[10], f[11]);
        i64 orr = f[6] + f[9] * ParDevice.guardValue(obj, f[7], f[8]) + f[15] * ParDevice.guardValue(obj, f[13], f[14]);
        i64 w0 = f[0] * lo + ow;
        i64 w1 = f[0] * (hi - (i64)1) + ow;
        i64 r0 = f[5] * lo + orr;
        i64 r1 = f[5] * (hi - (i64)1) + orr;
        i64 wmin = w0 < w1 ? w0 : w1;
        i64 wmax = w0 < w1 ? w1 : w0;
        i64 rmin = r0 < r1 ? r0 : r1;
        i64 rmax = r0 < r1 ? r1 : r0;
        if (wmax < rmin || rmax < wmin)
            return true;
        if (f[0] != f[5] || f[0] == (i64)0)
            return false;
        i64 d = ow - orr;
        i64 kk = f[0] < (i64)0 ? (i64)0 - f[0] : f[0];
        i64 ad = d < (i64)0 ? (i64)0 - d : d;
        return d == (i64)0 || d % kk != (i64)0 || ad >= kk * (hi - lo);
        }

    static bool guardsHold(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return true;
        u8* obj = proto.objBytes();
        u8* gx = "guardx=";
        for (u32 at = (u32)0; src[at] != (u8)0 && src[at] != (u8)10; at = at + (u32)1)
            {
            u32 k = (u32)0;
            while (gx[k] != (u8)0 && src[at + k] == gx[k])
                k = k + (u32)1;
            if (gx[k] != (u8)0 || (at > (u32)0 && src[at - (u32)1] != (u8)' '))
                continue;
            u32 q = at + k;
            i64 f[16];
            f[10] = (i64)-1; f[11] = (i64)0; f[12] = (i64)0;
            f[13] = (i64)-1; f[14] = (i64)0; f[15] = (i64)0;
            bool more = true;
            for (u32 n = (u32)0; n < (u32)16 && (n < (u32)10 || more); n = n + (u32)1)
                {
                bool neg = src[q] == (u8)'-';
                if (neg) q = q + (u32)1;
                i64 v = (i64)0;
                while (src[q] >= (u8)'0' && src[q] <= (u8)'9')
                    {
                    v = v * (i64)10 + (i64)(src[q] - (u8)'0');
                    q = q + (u32)1;
                    }
                f[n] = neg ? (i64)0 - v : v;
                more = src[q] == (u8)':';
                if (more) q = q + (u32)1;
                }
            if (!ParDevice.intervalHolds(obj, &f[0], lo, hi))
                return false;
            }
        u8* g = "guard=";
        u32 at = (u32)0;
        while (src[at] != (u8)0 && src[at] != (u8)10)
            {
            u32 k = (u32)0;
            while (g[k] != (u8)0 && src[at + k] == g[k])
                k = k + (u32)1;
            if (g[k] != (u8)0 || (at > (u32)0 && src[at - (u32)1] != (u8)' '))
                {
                at = at + (u32)1;
                continue;
                }
            at = at + k;
            i64 f[5];
            for (u32 q = (u32)0; q < (u32)5; q = q + (u32)1)
                {
                bool neg = src[at] == (u8)'-';
                if (neg) at = at + (u32)1;
                i64 v = (i64)0;
                while (src[at] >= (u8)'0' && src[at] <= (u8)'9')
                    {
                    v = v * (i64)10 + (i64)(src[at] - (u8)'0');
                    at = at + (u32)1;
                    }
                f[q] = neg ? (i64)0 - v : v;
                if (src[at] == (u8)':') at = at + (u32)1;
                }
            i64 v = (i64)0;
            u8* p = obj + f[0];
            if (f[1] == (i64)1) v = (i64)*(i8*)p;
            else if (f[1] == (i64)2) v = (i64)*(i16*)p;
            else if (f[1] == (i64)4) v = (i64)*(i32*)p;
            else v = *(i64*)p;
            // An unsigned capture wider than its sign bit reads negative
            // here; its true value is larger still, so |d| only grows.
            i64 d = f[3] + f[2] * v;
            i64 kk = f[4] < (i64)0 ? (i64)0 - f[4] : f[4];
            i64 ad = d < (i64)0 ? (i64)0 - d : d;
            if (d != (i64)0 && kk != (i64)0 && d % kk == (i64)0 && ad < kk * (hi - lo))
                return false;
            }
        return true;
        }

    // Two captured arrays of the block that are one block of memory, or
    // overlap, with one of them written: the compiler's dependence check
    // (§4) holds for a buffer against ITSELF, but two pointers it sees as
    // two buffers may be one — `u32* b = a;` — and then an item's write is
    // another item's read. No static test can rule it out, so the run is
    // checked: such a block runs serially, as its source reads.
    // Whether a block's source holds a GPU form: not empty, and not the
    // header alone a block with none carries (`// xcpar cpu buf=…`), which
    // is there only so bufferOverlap can check its arrays.
    static bool hasKernel(u8* src)
        {
        if (src == (u8*)0 || src[0] == (u8)0)
            return false;
        u8* m = "// xcpar cpu";
        for (u32 i = (u32)0; m[i] != (u8)0; i = i + (u32)1)
            if (src[i] != m[i])
                return true;
        return false;
        }

    static bool bufferOverlap(ParChunk* proto, u8* src)
        {
        if (src == (u8*)0 || src[0] == (u8)0)
            return false;
        u8* obj = proto.objBytes();
        pointer ptr[16];
        i64 len[16];
        bool ro[16];
        u32 nbuf = (u32)0;
        u32 at = (u32)0;
        while (src[at] != (u8)0 && src[at] != (u8)10)
            {
            if (src[at] == (u8)'b' && src[at + (u32)1] == (u8)'u' && src[at + (u32)3] == (u8)'=' && nbuf < (u32)16)
                {
                at = at + (u32)4;
                i64 off = num(src, &at);
                at = at + (u32)1;
                i64 ivar = num(src, &at);
                at = at + (u32)1;
                num(src, &at);
                // The field at off, through an integer address: the block's
                // bytes are one object, and a checked build (which runs this
                // guard for a block that stays on the CPU) read `obj + off` as
                // subscript off of a one-element array and stopped the program.
                ptr[nbuf] = *(pointer*)((pointer)((u64)obj + (u64)off));
                len[nbuf] = proto.gpuLength((i32)ivar);
                ro[nbuf] = proto.gpuReadsOnly((i32)ivar);
                nbuf = nbuf + (u32)1;
                continue;
                }
            at = at + (u32)1;
            }
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            for (u32 j = i + (u32)1; j < nbuf; j = j + (u32)1)
                {
                if (ptr[i] == (pointer)0 || ptr[j] == (pointer)0 || len[i] <= (i64)0 || len[j] <= (i64)0)
                    continue;
                if (ro[i] && ro[j])
                    continue;
                u64 a0 = (u64)ptr[i];
                u64 a1 = a0 + (u64)len[i];
                u64 b0 = (u64)ptr[j];
                u64 b1 = b0 + (u64)len[j];
                if (a0 < b1 && b0 < a1)
                    return true;
                }
        return false;
        }

    static ParLayout* layout(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        ParLayout* l = new ParLayout();
        u8 gname[128];
        u32 at = (u32)0;
        while (src[at] != (u8)0 && src[at] != (u8)10)
            {
            if (src[at] == (u8)'s' && src[at + (u32)1] == (u8)'i' && src[at + (u32)4] == (u8)'=')
                {
                at = at + (u32)5;
                l.size = num(src, &at);
                continue;
                }
            if (src[at] == (u8)'b' && src[at + (u32)1] == (u8)'u' && src[at + (u32)3] == (u8)'=' &&
                l.nbuf < (u32)16)
                {
                at = at + (u32)4;
                u32 k = l.nbuf;
                l.bufOff[k] = num(src, &at);
                at = at + (u32)1;
                i64 ivar = num(src, &at);
                at = at + (u32)1;
                l.bufElem[k] = num(src, &at);
                l.bufIvar[k] = ivar;
                l.bufLen[k] = proto.gpuLength((i32)ivar);
                l.bufIn[k] = proto.gpuReadsOnly((i32)ivar) ? (i64)1 : (i64)0;
                if (l.bufLen[k] < (i64)0)
                    {
                    cpu("it uses an array whose size is not known");
                    return (ParLayout*)0;
                    }
                // Only when this run's range is the whole array: the body
                // writes element i for each i in it, and nothing else.
                l.bufOut[k] = (i64)0;
                if (proto.gpuWritesAllOwn((i32)ivar) && lo == (i64)0 && (hi - lo) * l.bufElem[k] >= l.bufLen[k])
                    {
                    l.bufOut[k] = (i64)1;
                    if (ParDevice.reporting())
                        Log.info("par: %ld bytes written whole on the device, not sent", l.bufLen[k]);
                    }
                l.nbuf = k + (u32)1;
                continue;
                }
            if (src[at] == (u8)'g' && src[at + (u32)1] == (u8)'l' && src[at + (u32)4] == (u8)'=' &&
                l.nglob < (u32)16)
                {
                // glob=<name>:<elem-bytes>: the block knows where it lives.
                at = at + (u32)5;
                u32 n = (u32)0;
                while (src[at] != (u8)':' && src[at] != (u8)0 && n < (u32)127)
                    {
                    gname[n] = src[at];
                    n = n + (u32)1;
                    at = at + (u32)1;
                    }
                gname[n] = (u8)0;
                at = at + (u32)1;
                i64 elem = num(src, &at);
                u32 k = l.nglob;
                l.globElem[k] = elem;
                for (u32 q = (u32)0; q <= n && q < (u32)64; q = q + (u32)1)
                    l.globName[k * (u32)64 + q] = gname[q];
                l.globPtr[k] = proto.gpuGlobal(&gname[0]);
                l.globLen[k] = proto.gpuGlobalBytes(&gname[0]);
                if (l.globPtr[k] == (pointer)0 || l.globLen[k] <= (i64)0)
                    {
                    cpu("it uses a global the block cannot locate");
                    return (ParLayout*)0;
                    }
                // Only when this run's range is the whole array: the body
                // writes element i for each i in it, and nothing else.
                l.globOut[k] = (i64)0;
                l.globIn[k] = proto.gpuReadsOnlyGlobal(&gname[0]) ? (i64)1 : (i64)0;
                l.globAll[k] = proto.gpuWritesAll(&gname[0]) ? (i64)1 : (i64)0;
                if (proto.gpuWritesAll(&gname[0]) && lo == (i64)0 && (hi - lo) * elem >= l.globLen[k])
                    l.globOut[k] = (i64)1;
                l.nglob = k + (u32)1;
                continue;
                }
            // fp=<buffer>:<k>:<lo>:<hi>: captured array <buffer>'s footprint.
            if (src[at] == (u8)'f' && src[at + (u32)1] == (u8)'p' && src[at + (u32)2] == (u8)'=')
                {
                at = at + (u32)3;
                i64 which = num(src, &at);
                at = at + (u32)1;
                i64 fk = snum(src, &at);
                at = at + (u32)1;
                i64 fLo = snum(src, &at);
                at = at + (u32)1;
                i64 fHi = snum(src, &at);
                // The header lists buf= words first, in ivar order, so the
                // buffer with that ivar index is found among them.
                for (u32 q = (u32)0; q < l.nbuf; q = q + (u32)1)
                    if (l.bufIvar[q] == which)
                        {
                        l.bufFp[q] = (i64)1;
                        l.bufFpK[q] = fk;
                        l.bufFpLo[q] = fLo;
                        l.bufFpHi[q] = fHi;
                        }
                continue;
                }
            // gfp=<name>:<k>:<lo>:<hi>: global <name>'s footprint.
            if (src[at] == (u8)'g' && src[at + (u32)1] == (u8)'f' && src[at + (u32)2] == (u8)'p' && src[at + (u32)3] == (u8)'=')
                {
                at = at + (u32)4;
                u32 n = (u32)0;
                while (src[at] != (u8)':' && src[at] != (u8)0 && n < (u32)127)
                    {
                    gname[n] = src[at];
                    n = n + (u32)1;
                    at = at + (u32)1;
                    }
                gname[n] = (u8)0;
                at = at + (u32)1;
                i64 fk = snum(src, &at);
                at = at + (u32)1;
                i64 fLo = snum(src, &at);
                at = at + (u32)1;
                i64 fHi = snum(src, &at);
                for (u32 q = (u32)0; q < l.nglob; q = q + (u32)1)
                    if (parSameName(&l.globName[q * (u32)64], &gname[0]))
                        {
                        l.globFp[q] = (i64)1;
                        l.globFpK[q] = fk;
                        l.globFpLo[q] = fLo;
                        l.globFpHi[q] = fHi;
                        }
                continue;
                }
            // byval: the object and range are the launch's parameters.
            if (src[at] == (u8)'b' && src[at + (u32)1] == (u8)'y' && src[at + (u32)2] == (u8)'v' &&
                src[at + (u32)3] == (u8)'a' && src[at + (u32)4] == (u8)'l')
                {
                l.byval = (i64)1;
                at = at + (u32)5;
                continue;
                }
            // devlast: and its last workgroup folds the workgroups' partials.
            if (src[at] == (u8)'d' && src[at + (u32)1] == (u8)'e' && src[at + (u32)2] == (u8)'v' &&
                src[at + (u32)3] == (u8)'l' && src[at + (u32)4] == (u8)'a' && src[at + (u32)5] == (u8)'s' &&
                src[at + (u32)6] == (u8)'t')
                {
                l.devlast = (i64)1;
                at = at + (u32)7;
                continue;
                }
            // devred: the kernel combines its reductions on the device (bug 645).
            if (src[at] == (u8)'d' && src[at + (u32)1] == (u8)'e' && src[at + (u32)2] == (u8)'v' &&
                src[at + (u32)3] == (u8)'r' && src[at + (u32)4] == (u8)'e' && src[at + (u32)5] == (u8)'d')
                {
                l.devred = (i64)1;
                at = at + (u32)6;
                continue;
                }
            if (src[at] == (u8)'r' && src[at + (u32)1] == (u8)'e' && src[at + (u32)3] == (u8)'=' &&
                l.nred < (u32)16)
                {
                at = at + (u32)4;
                u32 k = l.nred;
                l.redOff[k] = num(src, &at);
                at = at + (u32)1;
                l.redSize[k] = num(src, &at);
                l.redStride[k] = l.redSize[k];
                // A narrow partial in a 32-bit slot: its low bytes are the value.
                if (src[at] == (u8)':')
                    {
                    at = at + (u32)1;
                    l.redStride[k] = num(src, &at);
                    }
                l.nred = k + (u32)1;
                continue;
                }
            // ops=<n>: the per-item compute-op count (cost model).
            if (src[at] == (u8)'o' && src[at + (u32)1] == (u8)'p' && src[at + (u32)2] == (u8)'s' && src[at + (u32)3] == (u8)'=')
                {
                at = at + (u32)4;
                l.ops = num(src, &at);
                continue;
                }
            // merge=<n>,<n>…: the reductions a node may fold itself.
            if (src[at] == (u8)'m' && src[at + (u32)1] == (u8)'e' && src[at + (u32)2] == (u8)'r' && src[at + (u32)3] == (u8)'g'
                && src[at + (u32)4] == (u8)'e' && src[at + (u32)5] == (u8)'=')
                {
                at = at + (u32)6;
                while (true)
                    {
                    i64 k = num(src, &at);
                    if (k >= (i64)0 && k < (i64)32)
                        l.mergeMask = l.mergeMask | ((u32)1 << (u32)k);
                    if (src[at] != (u8)',')
                        break;
                    at = at + (u32)1;
                    }
                continue;
                }
            // loop: the item body has a nested loop (compute-heavy).
            if (src[at] == (u8)'l' && src[at + (u32)1] == (u8)'o' && src[at + (u32)2] == (u8)'o' && src[at + (u32)3] == (u8)'p')
                {
                l.hasLoop = (i64)1;
                at = at + (u32)4;
                continue;
                }
            at = at + (u32)1;
            }
        if (l.size <= (i64)0)
            {
            cpu("its GPU version has no header");
            return (ParLayout*)0;
            }
        l.plan(lo, hi);
        if (reporting())
            {
            i64 bpi = bytesPerItem(l);
            Log.info("par: %s: cost ops=%ld loop=%ld bytes/item=%ld -> %s", proto.parName(), l.ops, l.hasLoop, bpi,
                     computeBound(l) ? "compute-bound" : "bandwidth-bound");
            }
        return l;
        }

    // Bytes moved per work item, from the footprints (the coefficient of
    // `items` in a tile's transfer) — the denominator of arithmetic intensity.
    static i64 bytesPerItem(ParLayout* l)
        {
        i64 b = (i64)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufFp[i] != (i64)0)
                b = b + l.bufFpK[i] * l.bufElem[i] * (l.bufIn[i] != (i64)0 ? (i64)1 : (i64)2);
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globFp[i] != (i64)0)
                b = b + l.globFpK[i] * l.globElem[i] *
                        (l.globIn[i] != (i64)0 || (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1) ? (i64)1 : (i64)2);
        return b;
        }

    // The static classification (par-auto-parallelisation.md): a nested loop,
    // or no data to move, or high arithmetic intensity (>= 4 ops/byte) means
    // compute-bound — GPU-eligible and worth splitting; otherwise bandwidth-
    // bound, where a discrete GPU's transfer sinks it and the runtime keeps it
    // off that device. A block with no GPU header never reaches here.
    static bool computeBound(ParLayout* l)
        {
        if (l.hasLoop != (i64)0)
            return true;
        i64 bpi = bytesPerItem(l);
        if (bpi <= (i64)0)
            return true;
        return l.ops >= bpi * (i64)4;
        }
    }
