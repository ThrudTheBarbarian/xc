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

#if ARCH_win64
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* perSecond);
#elif ARCH_x86_64 || ARCH_wasm32 || PLATFORM_android
// Linux's monotonic clock (on wasm32, the loader's, in the same form).
struct _ParTimespec { i64 sec; i64 nsec; }
i32 clock_gettime(i32 clock, u8* ts);
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
bool gParLearned[64];
i64 gParMeasN[64];
i64 gParLastN[64];
bool gParMeasuring[64]; // this run is one auto measures (not decided by a setting or the bounds)
#if ARCH_win64
// Windows reaches an NVIDIA GPU two ways, CUDA and Vulkan, and auto measures
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
    u32 nbuf;
    pointer globPtr[16];
    i64 globLen[16];
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

    void plan(i64 lo, i64 hi)
        {
        n = hi - lo;
        per = (i64)1;
        i64 most = nred > (u32)0 && devred == (i64)0 ? (i64)65536 : (i64)1 << (i64)22;
        if (n > most)
            per = (n + most - (i64)1) / most;
        threads = (n + per - (i64)1) / per;
        nparts = devred != (i64)0 ? (threads + (i64)255) / (i64)256 : threads;
        }

    // Each thread's partials, at parts[i] + thread * redStride[i], folded into
    // the block in thread order with its own merge(), so an integer result is
    // the CPU's exactly. One chunk carries them into merge(), which only
    // reads them: no allocation per thread.
    void fold(ParChunk* proto, u8** parts)
        {
        if (nred == (u32)0)
            return;
        ParChunk* c = proto.copyChunk();
        u8* cb = (u8*)(pointer)c;
        for (i64 t = (i64)0; t < nparts; t = t + (i64)1)
            {
            for (u32 i = (u32)0; i < nred; i = i + (u32)1)
                memcpy((pointer)(cb + redOff[i]), (pointer)(parts[i] + t * redStride[i]), (u64)redSize[i]);
            proto.merge(c);
            }
        }
    }

class ParDevice
    {
    static i32 _mode;            // XC_PAR: 0 unread, 1 cpu, 2 gpu, 3 auto, 4 unset
    static Settings* _store;     // the program's settings store, opened on first use
    static String* _hw;          // the hardware key (hex), once the GPU is known

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
        clock_gettime((i32)1, (u8*)&ts);   // CLOCK_MONOTONIC on Linux
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
        gParLearned[i] = false;
        gParMeasN[i] = (i64)0;
        gParLastN[i] = (i64)0;
        gParMeasuring[i] = false;
#if ARCH_win64
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

#if ARCH_win64
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

    static bool reporting(void)
        {
        return Platform.env(String.withCString("XC_PAR_REPORT")).byteLength() > (u32)0;
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
            }
        return _store;
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
        if (_mode == (i32)1 || _mode == (i32)2)
            return false;
        u8* src = proto.gpuSource();
        if (src == (u8*)0 || src[0] == (u8)0)
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

    // The GPU's identity from its runtime ("" for none): the hardware key.
    static void setHardware(String* gpu)
        {
        String* both = String.withString(gpu);
        both.appendCString("|");
        both.append(cpuIdentity());
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

    static String* learnedKey(u32 i, ParChunk* proto)
        {
        String* key = String.withCString("par.learned.");
        key.append(_hw);
        key.appendCString(".");
        key.appendCString(gParBlock[i]);
        key.appendFormat(".%08x", hash(proto.gpuSource(), (u32)2166136261));
        return key;
        }

    static void readLearned(u32 i, ParChunk* proto)
        {
        if (gParLearned[i] || _hw == (String*)0)
            return;
        gParLearned[i] = true;
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
#if ARCH_win64
        // ,cuda or ,vulkan: the interface auto chose (none in a 0.73/0.74 record).
        if (c[at] == (u8)',' && gParApi[i] == (i32)0)
            gParApi[i] = c[at + (u32)1] == (u8)'v' ? (i32)2 : c[at + (u32)1] == (u8)'c' ? (i32)1 : (i32)0;
#endif
        }

    // A measured run's verdict at size n: the bounds move to take it in (a
    // contradicting bound is dropped, the newer evidence kept), and are saved.
    static void learn(u32 i, ParChunk* proto, i64 n, bool gpuWon)
        {
        if (_hw == (String*)0 || n <= (i64)0)
            return;
        if (gpuWon)
            {
            if (gParGpuFrom[i] < (i64)0 || n < gParGpuFrom[i])
                gParGpuFrom[i] = n;
            if (gParCpuUpTo[i] >= gParGpuFrom[i])
                gParCpuUpTo[i] = (i64)-1;
            }
        else
            {
            if (n > gParCpuUpTo[i])
                gParCpuUpTo[i] = n;
            if (gParGpuFrom[i] >= (i64)0 && gParGpuFrom[i] <= gParCpuUpTo[i])
                gParGpuFrom[i] = (i64)-1;
            }
        Settings* st = store();
        String* v = String.withFormat("%ld,%ld", gParCpuUpTo[i], gParGpuFrom[i]);
#if ARCH_win64
        if (gParApi[i] != (i32)0)
            v.appendCString(gParApi[i] == (i32)2 ? ",vulkan" : ",cuda");
#endif
        st.set(learnedKey(i, proto), v);
        st.save();
        if (reporting())
            Log.info("par: %s: learned the %s wins at %ld items (CPU up to %ld, GPU from %ld)", gParBlock[i],
                     gpuWon ? "GPU" : "CPU", n, gParCpuUpTo[i], gParGpuFrom[i]);
        }

    static i32 choose(ParChunk* proto, i64 n)
        {
        if (_mode == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR"));
            _mode = v.equals(String.withCString("cpu")) ? (i32)1
                  : v.equals(String.withCString("gpu")) ? (i32)2
                  : v.equals(String.withCString("auto")) ? (i32)3 : (i32)4;
            }
        if (_mode == (i32)1 || _mode == (i32)2 || n < (i64)0)
            return _mode;
        u32 i = slot(proto.parName());
        gParLastN[i] = n;
        gParMeasuring[i] = false;
        i32 dev = gParSet[i];
        if (_mode == (i32)4 && dev < (i32)0 && gParAll > (i32)0)
            dev = gParAll - (i32)1;
        if (_mode == (i32)4 && dev > (i32)0)
            return dev;
        u8* src = proto.gpuSource();
        if (src == (u8*)0 || src[0] == (u8)0)
            return (i32)1;
        if (_mode == (i32)4)
            {
            i32 u = userSetting(i);
            if (u == (i32)1 || u == (i32)2)
                return u;
            if (u == (i32)4)
                return n >= gParUserN[i] ? (i32)2 : (i32)1;
            }
        // The learned bounds decide a size outside them, with no measuring.
        readLearned(i, proto);
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
            gParCpuRuns[i] = (u32)1;
            gParGpuRuns[i] = gParGpuRuns[i] > (u32)0 ? (u32)1 : (u32)0;
            gParMeasN[i] = n;
            }
        if (gParMeasN[i] == (i64)0)
            gParMeasN[i] = n;
        gParMeasuring[i] = true;
        if (gParCpuUs[i] < (i64)0 || gParCpuUs[i] < (i64)1000)
            return (i32)1;
        if (gParGpuUs[i] < (i64)0)
            return (i32)2;
        return gParGpuUs[i] <= gParCpuUs[i] ? (i32)2 : (i32)1;
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
        bool gpuable = proto.gpuSource() != (u8*)0 && proto.gpuSource()[0] != (u8)0;
        if (reporting())
            {
            Log.info("par: %s: %ld us on the CPU", gParBlock[i], us);
            if (measured && us < (i64)1000 && gpuable)
                Log.info("par: %s: auto keeps it on the CPU (%ld us, too short for a GPU to win)", gParBlock[i], us);
            }
        if (measured && us < (i64)1000 && gpuable)
            learn(i, proto, gParLastN[i], false);
        }

    // A GPU run: took is the whole run (copies in and out included, the
    // one-off kernel build left out), gpuUs the GPU's own time (-1: not known).
    static void ranOnGpu(ParChunk* proto, ParLayout* l, i64 took, i64 gpuUs)
        {
        u32 bi = slot(proto.parName());
        if (gParMeasuring[bi])
            gParGpuRuns[bi] = gParGpuRuns[bi] + (u32)1;
        bool decided = gParMeasuring[bi] && gParGpuUs[bi] < (i64)0 && gParGpuRuns[bi] >= (u32)2;
        i64 measured = took;
#if ARCH_win64
        // Neither interface kept yet: each is warmed up and timed on its own,
        // and the GPU's time is the faster one's once both are known.
        if (gParMeasuring[bi] && gParApi[bi] == (i32)0 && forcedApi() == (i32)0)
            {
            decided = false;
            if (gParRanApi == (i32)1)
                {
                gParCudaRuns[bi] = gParCudaRuns[bi] + (u32)1;
                if (gParCudaRuns[bi] >= (u32)2 && gParCudaUs[bi] == (i64)-1)
                    gParCudaUs[bi] = took;
                }
            else
                {
                gParVkRuns[bi] = gParVkRuns[bi] + (u32)1;
                if (gParVkRuns[bi] >= (u32)2 && gParVkUs[bi] == (i64)-1)
                    gParVkUs[bi] = took;
                }
            i64 cu = gParCudaUs[bi];
            i64 vk = gParVkUs[bi];
            if (cu != (i64)-1 && vk != (i64)-1 && (cu >= (i64)0 || vk >= (i64)0))
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
#endif
        if (decided)
            {
            gParGpuUs[bi] = measured;
            if (gParCpuUs[bi] >= (i64)0)
                learn(bi, proto, l.n, measured <= gParCpuUs[bi]);
            }
        if (!reporting())
            return;
        if (decided && gParCpuUs[bi] >= (i64)0)
            Log.info("par: %s: auto picks the %s (GPU %ld us, CPU %ld us)", gParBlock[bi],
                     gParGpuUs[bi] <= gParCpuUs[bi] ? "GPU" : "CPU", gParGpuUs[bi], gParCpuUs[bi]);
        if (gpuUs >= (i64)0)
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
                num(src, &at);
                l.bufLen[k] = proto.gpuLength((i32)ivar);
                if (l.bufLen[k] < (i64)0)
                    {
                    cpu("it uses an array whose size is not known");
                    return (ParLayout*)0;
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
                num(src, &at);
                u32 k = l.nglob;
                l.globPtr[k] = proto.gpuGlobal(&gname[0]);
                l.globLen[k] = proto.gpuGlobalBytes(&gname[0]);
                if (l.globPtr[k] == (pointer)0 || l.globLen[k] <= (i64)0)
                    {
                    cpu("it uses a global the block cannot locate");
                    return (ParLayout*)0;
                    }
                l.nglob = k + (u32)1;
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
            at = at + (u32)1;
            }
        if (l.size <= (i64)0)
            {
            cpu("its GPU version has no header");
            return (ParLayout*)0;
            }
        l.plan(lo, hi);
        return l;
        }
    }
