// ParDevice.xc — where each `par` block runs, for the targets with a GPU
// runtime (ParMetal.xc on macOS, ParCuda.xc on Windows): the choice between
// the CPU and the GPU, the record auto keeps, XC_PAR_REPORT, and the reading
// of a kernel's header line,
//   // xcpar size=<bytes> lo=<off> hi=<off> buf=<off>:<own-ivar>:<elem-bytes>…
//            glob=<name>:<elem-bytes>… red=<off>:<bytes>…
// which says where the block object keeps lo, hi, each captured array, each
// global it uses and each reduction. The GPU runtimes share all of it, and
// differ only in how they compile a kernel, move the data and launch.
pointer memcpy(pointer dst, pointer src, u64 n);

#if ARCH_win64
i32 QueryPerformanceCounter(i64* count);
i32 QueryPerformanceFrequency(i64* perSecond);
#elif ARCH_x86_64
// Linux's monotonic clock.
struct _ParTimespec { i64 sec; i64 nsec; }
i32 clock_gettime(i32 clock, u8* ts);
#else
// Darwin's monotonic clock, in nanoseconds.
u64 clock_gettime_nsec_np(i32 clock);
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
    u32 nred;
    i64 n;
    i64 per;
    i64 threads;

    void plan(i64 lo, i64 hi)
        {
        n = hi - lo;
        per = (i64)1;
        i64 most = nred > (u32)0 ? (i64)65536 : (i64)1 << (i64)22;
        if (n > most)
            per = (n + most - (i64)1) / most;
        threads = (n + per - (i64)1) / per;
        }

    // Each thread's partials, at parts[i] + thread * redSize[i], folded into
    // the block in thread order with its own merge(), so an integer result is
    // the CPU's exactly. One chunk carries them into merge(), which only
    // reads them: no allocation per thread.
    void fold(ParChunk* proto, u8** parts)
        {
        if (nred == (u32)0)
            return;
        ParChunk* c = proto.copyChunk();
        u8* cb = (u8*)(pointer)c;
        for (i64 t = (i64)0; t < threads; t = t + (i64)1)
            {
            for (u32 i = (u32)0; i < nred; i = i + (u32)1)
                memcpy((pointer)(cb + redOff[i]), (pointer)(parts[i] + t * redSize[i]), (u64)redSize[i]);
            proto.merge(c);
            }
        }
    }

class ParDevice
    {
    static i32 _mode;            // XC_PAR: 0 unread, 1 cpu, 2 gpu, 3 auto, 4 unset

    static i64 nowUs(void)
        {
#if ARCH_win64
        i64 c = (i64)0;
        i64 f = (i64)1;
        QueryPerformanceCounter(&c);
        QueryPerformanceFrequency(&f);
        return (c / f) * (i64)1000000 + (c % f) * (i64)1000000 / f;
#elif ARCH_x86_64
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
    static i32 choose(ParChunk* proto, i64 n)
        {
        if (_mode == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR"));
            _mode = v.equals(String.withCString("cpu")) ? (i32)1
                  : v.equals(String.withCString("gpu")) ? (i32)2
                  : v.equals(String.withCString("auto")) ? (i32)3 : (i32)4;
            }
        if (_mode == (i32)1 || _mode == (i32)2)
            return _mode;
        u32 i = slot(proto.parName());
        i32 dev = gParSet[i];
        if (_mode == (i32)4 && dev < (i32)0 && gParAll > (i32)0)
            dev = gParAll - (i32)1;
        if (_mode == (i32)4 && dev > (i32)0)
            return dev;
        u8* src = proto.gpuSource();
        if (src == (u8*)0 || src[0] == (u8)0)
            return (i32)1;
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
        gParCpuRuns[i] = gParCpuRuns[i] + (u32)1;
        bool measured = gParCpuUs[i] < (i64)0 && gParCpuRuns[i] >= (u32)2;
        if (measured)
            gParCpuUs[i] = us;
        if (reporting())
            {
            Log.info("par: %s: %ld us on the CPU", gParBlock[i], us);
            if (measured && us < (i64)1000 && proto.gpuSource() != (u8*)0 && proto.gpuSource()[0] != (u8)0)
                Log.info("par: %s: auto keeps it on the CPU (%ld us, too short for a GPU to win)", gParBlock[i], us);
            }
        }

    // A GPU run: took is the whole run (copies in and out included, the
    // one-off kernel build left out), gpuUs the GPU's own time (-1: not known).
    static void ranOnGpu(ParChunk* proto, ParLayout* l, i64 took, i64 gpuUs)
        {
        u32 bi = slot(proto.parName());
        gParGpuRuns[bi] = gParGpuRuns[bi] + (u32)1;
        bool decided = gParGpuUs[bi] < (i64)0 && gParGpuRuns[bi] >= (u32)2;
        if (decided)
            gParGpuUs[bi] = took;
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
            if (src[at] == (u8)'r' && src[at + (u32)1] == (u8)'e' && src[at + (u32)3] == (u8)'=' &&
                l.nred < (u32)16)
                {
                at = at + (u32)4;
                u32 k = l.nred;
                l.redOff[k] = num(src, &at);
                at = at + (u32)1;
                l.redSize[k] = num(src, &at);
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
