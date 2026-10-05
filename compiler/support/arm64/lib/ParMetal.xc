// ParMetal.xc — runs a `par` block on the GPU through Metal (macOS, Apple
// silicon), for Par.run when XC_PAR=gpu.
//
// The compiler gives each block its kernel as Metal source (gpuSource()),
// printed from the block's own chunk method; its first line says where the
// block object keeps lo, hi, each captured array and each reduction:
//   // xcpar size=<bytes> lo=<off> hi=<off> buf=<off>:<own-ivar>:<elem-bytes>… red=<off>:<bytes>…
// Each GPU thread runs the method over its own slice of the range. Captured
// arrays are copied in and back; each thread's reductions come back as
// partials, folded into the block in thread order with its own merge(), so an
// integer result is the CPU's exactly.
//
// Metal is reached through the Objective-C runtime's C entry points: the
// device by MTLCreateSystemDefaultDevice, everything else by objc_msgSend
// with one function-pointer type per call shape. libobjc is already loaded
// (Metal and Foundation need it), so its entry points come from dlsym and
// nothing has to be passed at link time. The device, the queue and each
// block's pipeline are made at the first launch that needs them.
#import "Foundation.xc"
#import <Metal>
#import <Foundation>

pointer MTLCreateSystemDefaultDevice(void);
pointer dlsym(pointer handle, u8* name);
pointer memcpy(pointer dst, pointer src, u64 n);
i32 strcmp(u8* a, u8* b);

struct ParMTLSize
    {
    u64 w;
    u64 h;
    u64 d;
    }

// Darwin's monotonic clock, in nanoseconds.
u64 clock_gettime_nsec_np(i32 clock);

// Each block seen so far, by its name (the parName() string): the device it
// was set to (0 auto, 1 CPU, 2 GPU) and, for auto, what each device took.
u8* gParBlock[64];
i32 gParSet[64];
i64 gParGpuUs[64];
i64 gParCpuUs[64];
u32 gParBlocks;
i32 gParAll;            // Par.device("par", …): every block without its own

// The kernels compiled so far: each gpuSource() pointer and its pipeline.
pointer gParSrc[64];
pointer gParPso[64];
u32 gParKernels;

typedef pointer parObjcName_t(u8* name);
typedef pointer parMsg0_t(pointer obj, pointer sel);
typedef u64 parMsgU_t(pointer obj, pointer sel);
typedef pointer parMsgP_t(pointer obj, pointer sel, pointer a);
typedef pointer parMsgPP_t(pointer obj, pointer sel, pointer a, pointer b);
typedef pointer parMsgPPP_t(pointer obj, pointer sel, pointer a, pointer b, pointer c);
typedef pointer parMsgBytes_t(pointer obj, pointer sel, pointer bytes, u64 len, u64 opts);
typedef pointer parMsgLen_t(pointer obj, pointer sel, u64 len, u64 opts);
typedef void parMsgSetBuf_t(pointer obj, pointer sel, pointer buf, u64 offset, u64 index);
typedef void parMsgSetU_t(pointer obj, pointer sel, u64 v);
typedef void parMsgDispatch_t(pointer obj, pointer sel, ParMTLSize* grid, ParMTLSize* group);
typedef u8* parMsgStr_t(pointer obj, pointer sel);
typedef double parMsgD_t(pointer obj, pointer sel);

class ParMetal
    {
    static pointer _send;
    static parObjcName_t* _cls;
    static parObjcName_t* _sel;
    static pointer _dev;
    static pointer _queue;
    static i32 _mode;            // XC_PAR: 0 unread, 1 cpu, 2 gpu, 3 auto, 4 unset
    static i64 _lastUs;          // the last GPU run, without building its pipeline

    static i64 nowUs(void)
        {
        return (i64)(clock_gettime_nsec_np((i32)6) / (u64)1000); // CLOCK_MONOTONIC
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
    // for every block, then auto: no GPU version or a small range stays on
    // the CPU; otherwise run each device once and keep the faster.
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
        if (src == (u8*)0 || src[0] == (u8)0 || n < (i64)65536)
            return (i32)1;
        if (gParGpuUs[i] < (i64)0)
            return (i32)2;
        if (gParCpuUs[i] < (i64)0)
            return (i32)1;
        return gParGpuUs[i] <= gParCpuUs[i] ? (i32)2 : (i32)1;
        }

    // What a run took, for auto's comparison (the first of each is kept).
    static void ranOnCpu(ParChunk* proto, i64 us)
        {
        u32 i = slot(proto.parName());
        bool decided = gParGpuUs[i] >= (i64)0 && gParCpuUs[i] < (i64)0;
        if (gParCpuUs[i] < (i64)0)
            gParCpuUs[i] = us;
        if (reporting())
            {
            Log.info("par: %s: %ld us on the CPU", gParBlock[i], us);
            if (decided)
                Log.info("par: %s: auto picks the %s (GPU %ld us, CPU %ld us)", gParBlock[i],
                         gParGpuUs[i] <= gParCpuUs[i] ? "GPU" : "CPU", gParGpuUs[i], gParCpuUs[i]);
            }
        }

    // XC_PAR_REPORT=1: why a block stays on the CPU. False, for `return`.
    static bool cpu(u8* why)
        {
        if (Platform.env(String.withCString("XC_PAR_REPORT")).byteLength() > (u32)0)
            Log.info("par: a block stays on the CPU: %s", why);
        return false;
        }

    static pointer sel(u8* n)
        {
        return _sel(n);
        }

    static bool start(void)
        {
        if (_dev != (pointer)0)
            return true;
        pointer any = (pointer)((i64)0 - (i64)2); // RTLD_DEFAULT
        _cls = (parObjcName_t*)dlsym(any, "objc_getClass");
        _sel = (parObjcName_t*)dlsym(any, "sel_registerName");
        _send = dlsym(any, "objc_msgSend");
        if (_cls == (parObjcName_t*)0 || _sel == (parObjcName_t*)0 || _send == (pointer)0)
            return false;
        _dev = MTLCreateSystemDefaultDevice();
        if (_dev == (pointer)0)
            return false;
        _queue = ((parMsg0_t*)_send)(_dev, sel("newCommandQueue"));
        return _queue != (pointer)0;
        }

    static pointer nsString(u8* c)
        {
        return ((parMsgP_t*)_send)(_cls("NSString"), sel("stringWithUTF8String:"), (pointer)c);
        }

    // The compiled pipeline for a kernel source, made once.
    static pointer pipeline(u8* src)
        {
        for (u32 i = (u32)0; i < gParKernels; i = i + (u32)1)
            if (gParSrc[i] == (pointer)src)
                return gParPso[i];
        pointer opts = ((parMsg0_t*)_send)(_cls("MTLCompileOptions"), sel("new"));
        // Precise maths unless the block says otherwise (par-blocks.md §7):
        // MTLMathModeSafe.
        ((parMsgSetU_t*)_send)(opts, sel("setMathMode:"), (u64)0);
        pointer err = (pointer)0;
        pointer lib = ((parMsgPPP_t*)_send)(_dev, sel("newLibraryWithSource:options:error:"),
                                            nsString(src), opts, (pointer)&err);
        pointer pso = (pointer)0;
        if (lib != (pointer)0)
            {
            pointer fn = ((parMsgP_t*)_send)(lib, sel("newFunctionWithName:"), nsString("par_kernel"));
            pso = ((parMsgPP_t*)_send)(_dev, sel("newComputePipelineStateWithFunction:error:"), fn, (pointer)&err);
            }
        else if (err != (pointer)0)
            {
            pointer d = ((parMsg0_t*)_send)(err, sel("localizedDescription"));
            Log.error("par: the GPU kernel did not compile, running on the CPU: %s",
                      ((parMsgStr_t*)_send)(d, sel("UTF8String")));
            }
        if (gParKernels < (u32)64)
            {
            gParSrc[gParKernels] = (pointer)src;
            gParPso[gParKernels] = pso;
            gParKernels = gParKernels + (u32)1;
            }
        return pso;
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

    // Run [lo, hi) of the block on the GPU. False when the block cannot go
    // there (no kernel, a buffer of unknown size, no device): the caller then
    // runs it on the CPU, which gives the same answer.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return cpu("it has no GPU version");
        if (!start())
            return cpu("there is no Metal device");
        pointer pso = pipeline(src);
        if (pso == (pointer)0)
            return cpu("its GPU version did not compile");
        i64 started = nowUs();

        // The header line.
        u8* obj = (u8*)(pointer)proto;
        i64 size = (i64)0;
        i64 bufOff[16]; i64 bufIvar[16]; i64 bufLen[16]; u32 nbuf = (u32)0;
        i64 redOff[16]; i64 redSize[16]; u32 nred = (u32)0;
        pointer globPtr[16]; i64 globLen[16]; u32 nglob = (u32)0;
        u8 gname[128];
        u32 at = (u32)0;
        while (src[at] != (u8)0 && src[at] != (u8)10)
            {
            if (src[at] == (u8)'s' && src[at + (u32)1] == (u8)'i' && src[at + (u32)4] == (u8)'=')
                {
                at = at + (u32)5;
                size = num(src, &at);
                continue;
                }
            if (src[at] == (u8)'b' && src[at + (u32)1] == (u8)'u' && src[at + (u32)3] == (u8)'=' && nbuf < (u32)16)
                {
                at = at + (u32)4;
                bufOff[nbuf] = num(src, &at);
                at = at + (u32)1;
                bufIvar[nbuf] = num(src, &at);
                at = at + (u32)1;
                num(src, &at);
                bufLen[nbuf] = proto.gpuLength((i32)bufIvar[nbuf]);
                if (bufLen[nbuf] < (i64)0)
                    return cpu("it uses an array whose size is not known");
                nbuf = nbuf + (u32)1;
                continue;
                }
            if (src[at] == (u8)'g' && src[at + (u32)1] == (u8)'l' && src[at + (u32)4] == (u8)'=' && nglob < (u32)16)
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
                globPtr[nglob] = proto.gpuGlobal(&gname[0]);
                globLen[nglob] = proto.gpuGlobalBytes(&gname[0]);
                if (globPtr[nglob] == (pointer)0 || globLen[nglob] <= (i64)0)
                    return cpu("it uses a global the block cannot locate");
                nglob = nglob + (u32)1;
                continue;
                }
            if (src[at] == (u8)'r' && src[at + (u32)1] == (u8)'e' && src[at + (u32)3] == (u8)'=' && nred < (u32)16)
                {
                at = at + (u32)4;
                redOff[nred] = num(src, &at);
                at = at + (u32)1;
                redSize[nred] = num(src, &at);
                nred = nred + (u32)1;
                continue;
                }
            at = at + (u32)1;
            }
        if (size <= (i64)0)
            return cpu("its GPU version has no header");

        i64 n = hi - lo;
        i64 per = (i64)1;
        // One item per thread, unless the range is huge — or the block has
        // reductions, whose per-thread partials the host folds: then at most
        // 65536 threads, each taking a run of items.
        i64 most = nred > (u32)0 ? (i64)65536 : (i64)1 << (i64)22;
        if (n > most)
            per = (n + most - (i64)1) / most;
        i64 threads = (n + per - (i64)1) / per;

        parMsgBytes_t* withBytes = (parMsgBytes_t*)_send;
        parMsgLen_t* withLen = (parMsgLen_t*)_send;
        parMsgSetBuf_t* setBuf = (parMsgSetBuf_t*)_send;
        parMsg0_t* send0 = (parMsg0_t*)_send;

        i64 span[3];
        span[0] = lo;
        span[1] = hi;
        span[2] = per;
        pointer args = withBytes(_dev, sel("newBufferWithBytes:length:options:"), (pointer)obj, (u64)size, (u64)0);
        pointer spanB = withBytes(_dev, sel("newBufferWithBytes:length:options:"), (pointer)&span[0], (u64)24, (u64)0);
        pointer bufs[16];
        pointer reds[16];
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            pointer host = *(pointer*)(obj + bufOff[i]);
            bufs[i] = withBytes(_dev, sel("newBufferWithBytes:length:options:"), host, (u64)bufLen[i], (u64)0);
            }
        pointer globs[16];
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            globs[i] = withBytes(_dev, sel("newBufferWithBytes:length:options:"), globPtr[i], (u64)globLen[i], (u64)0);
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            reds[i] = withLen(_dev, sel("newBufferWithLength:options:"), (u64)(threads * redSize[i]), (u64)0);

        pointer cb = send0(_queue, sel("commandBuffer"));
        pointer enc = send0(cb, sel("computeCommandEncoder"));
        ((parMsgP_t*)_send)(enc, sel("setComputePipelineState:"), pso);
        setBuf(enc, sel("setBuffer:offset:atIndex:"), args, (u64)0, (u64)0);
        setBuf(enc, sel("setBuffer:offset:atIndex:"), spanB, (u64)0, (u64)1);
        u64 slot = (u64)2;
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            setBuf(enc, sel("setBuffer:offset:atIndex:"), bufs[i], (u64)0, slot);
            slot = slot + (u64)1;
            }
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            {
            setBuf(enc, sel("setBuffer:offset:atIndex:"), globs[i], (u64)0, slot);
            slot = slot + (u64)1;
            }
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            {
            setBuf(enc, sel("setBuffer:offset:atIndex:"), reds[i], (u64)0, slot);
            slot = slot + (u64)1;
            }
        u64 width = ((parMsgU_t*)_send)(pso, sel("maxTotalThreadsPerThreadgroup"));
        ParMTLSize grid;
        grid.w = (u64)threads;
        grid.h = (u64)1;
        grid.d = (u64)1;
        ParMTLSize group;
        group.w = width < (u64)threads ? width : (u64)threads;
        group.h = (u64)1;
        group.d = (u64)1;
        ((parMsgDispatch_t*)_send)(enc, sel("dispatchThreads:threadsPerThreadgroup:"), &grid, &group);
        send0(enc, sel("endEncoding"));
        send0(cb, sel("commit"));
        send0(cb, sel("waitUntilCompleted"));

        // The arrays come back; each thread's partials fold in thread order.
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            pointer host = *(pointer*)(obj + bufOff[i]);
            memcpy(host, send0(bufs[i], sel("contents")), (u64)bufLen[i]);
            send0(bufs[i], sel("release"));
            }
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            {
            memcpy(globPtr[i], send0(globs[i], sel("contents")), (u64)globLen[i]);
            send0(globs[i], sel("release"));
            }
        if (nred > (u32)0)
            {
            // One chunk to carry each thread's partials into merge(), which
            // only reads them: no allocation per thread.
            ParChunk* c = proto.copyChunk();
            u8* cb2 = (u8*)(pointer)c;
            u8* parts[16];
            for (u32 i = (u32)0; i < nred; i = i + (u32)1)
                parts[i] = (u8*)send0(reds[i], sel("contents"));
            for (i64 t = (i64)0; t < threads; t = t + (i64)1)
                {
                for (u32 i = (u32)0; i < nred; i = i + (u32)1)
                    memcpy((pointer)(cb2 + redOff[i]), (pointer)(parts[i] + t * redSize[i]), (u64)redSize[i]);
                proto.merge(c);
                }
            }
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            send0(reds[i], sel("release"));
        send0(args, sel("release"));
        send0(spanB, sel("release"));
        // For auto: the whole run (copies in and out included), without the
        // one-off pipeline build.
        u32 bi = slot(proto.parName());
        i64 took = nowUs() - started;
        if (gParGpuUs[bi] < (i64)0)
            gParGpuUs[bi] = took;
        // XC_PAR_REPORT=1: say where each block ran (par-blocks.md §8), and
        // how long the GPU itself spent on it.
        if (reporting())
            {
            double t0 = ((parMsgD_t*)_send)(cb, sel("GPUStartTime"));
            double t1 = ((parMsgD_t*)_send)(cb, sel("GPUEndTime"));
            i64 us = (i64)((t1 - t0) * 1000000.0);
            Log.info("par: %s: %ld items on the GPU, %ld threads, %ld us of GPU time (%ld us in all)",
                     gParBlock[bi], n, threads, us, took);
            }
        return true;
        }
    }
