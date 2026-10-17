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
#import "ParDevice.xc"
#define PAR_MTL_DEPTH 3
#import "ParWorker.xc"
#import <Metal>
#import <Foundation>

pointer MTLCreateSystemDefaultDevice(void);
pointer dlsym(pointer handle, u8* name);
i32 strcmp(u8* a, u8* b);

struct ParMTLSize
    {
    u64 w;
    u64 h;
    u64 d;
    }

// The kernels compiled so far: each gpuSource() pointer and its pipeline.
pointer gParSrc[64];
pointer gParPso[64];
// The fold kernel's pipeline, from the same library (bug 645): 0 when the
// module has none.
pointer gParPsoFold[64];
u32 gParKernels;

typedef pointer parObjcName_t(u8* name);
typedef pointer parMsg0_t(pointer obj, pointer sel);
typedef u64 parMsgU_t(pointer obj, pointer sel);
typedef pointer parMsgP_t(pointer obj, pointer sel, pointer a);
typedef pointer parMsgPP_t(pointer obj, pointer sel, pointer a, pointer b);
typedef pointer parMsgPPP_t(pointer obj, pointer sel, pointer a, pointer b, pointer c);
typedef pointer parMsgBytes_t(pointer obj, pointer sel, pointer bytes, u64 len, u64 opts);
typedef pointer parMsgLen_t(pointer obj, pointer sel, u64 len, u64 opts);
typedef pointer parMsgNoCopy_t(pointer obj, pointer sel, pointer bytes, u64 len, u64 opts, pointer dealloc);
typedef void parMsgSetBuf_t(pointer obj, pointer sel, pointer buf, u64 offset, u64 index);
typedef void parMsgSetU_t(pointer obj, pointer sel, u64 v);
typedef void parMsgDispatch_t(pointer obj, pointer sel, ParMTLSize* grid, ParMTLSize* group);
typedef u8* parMsgStr_t(pointer obj, pointer sel);
typedef double parMsgD_t(pointer obj, pointer sel);
// The device, queue and objc_msgSend, for the worker below (a class's static
// ivars are its own).
pointer gMtlSend;
pointer gMtlDev;
pointer gMtlQueue;

class ParMetal
    {
    static pointer _send;
    static parObjcName_t* _cls;
    static parObjcName_t* _sel;
    static pointer _dev;
    static pointer _queue;

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
        gMtlSend = _send;
        gMtlDev = _dev;
        gMtlQueue = _queue;
        return _queue != (pointer)0;
        }

    // The GPU, for the hardware key auto's learned choices are kept under
    // (ParDevice): "metal:<device name>", or "" when there is none.
    static String* identity(void)
        {
        if (!start())
            return String.withCString("");
        pointer nm = ((parMsg0_t*)_send)(_dev, sel("name"));
        u8* c = nm != (pointer)0 ? (u8*)((parMsg0_t*)_send)(nm, sel("UTF8String")) : (u8*)0;
        String* s = String.withCString("metal:");
        if (c != (u8*)0)
            s.appendCString(c);
        return s;
        }

    static pointer nsString(u8* c)
        {
        return ((parMsgP_t*)_send)(_cls("NSString"), sel("stringWithUTF8String:"), (pointer)c);
        }

    // A captured array's device buffer. A pointer into a page-aligned heap
    // block (ParDevice.simdBase: a `simd:` array, or any numeric array of
    // 64 KB and more) has its block wrapped where it lies
    // (newBufferWithBytesNoCopy: the unified memory the CPU already holds),
    // bound at the pointer's offset into it, and *shared says so, so its
    // result is not copied back either; anything else is copied in as
    // before. An offset that is not a multiple of 256 bytes — finer than any
    // GPU's buffer-offset rule — is copied too.
    static bool isShared(pointer host)
        {
        pointer base = ParDevice.simdBase(host);
        return base != (pointer)0 && (((u64)host - (u64)base) & (u64)255) == (u64)0;
        }

    static pointer bufferFor(pointer host, u64 len, bool* shared, u64* offset)
        {
        *shared = false;
        *offset = (u64)0;
        pointer base = ParDevice.simdBase(host);
        if (isShared(host))
            {
            u64 off = (u64)host - (u64)base;
            u64 pages = ((off + len + (u64)16383) / (u64)16384) * (u64)16384;
            pointer b = ((parMsgNoCopy_t*)_send)(_dev, sel("newBufferWithBytesNoCopy:length:options:deallocator:"),
                                                 base, pages, (u64)0, (pointer)0);
            if (b != (pointer)0)
                {
                *shared = true;
                *offset = off;
                return b;
                }
            }
        return ((parMsgBytes_t*)_send)(_dev, sel("newBufferWithBytes:length:options:"), host, len, (u64)0);
        }

    // The compiled pipeline for a kernel source, made once.
    static pointer pipeline(u8* src)
        {
        for (u32 i = (u32)0; i < gParKernels; i = i + (u32)1)
            if (gParSrc[i] == (pointer)src)
                return gParPso[i];
        pointer opts = ((parMsg0_t*)_send)(_cls("MTLCompileOptions"), sel("new"));
        // Precise maths unless the block says otherwise: MTLMathModeSafe, or
        // MTLMathModeFast for a block whose goal is speed (the default).
        ((parMsgSetU_t*)_send)(opts, sel("setMathMode:"), ParDevice.isFast(src) ? (u64)2 : (u64)0);
        pointer err = (pointer)0;
        pointer lib = ((parMsgPPP_t*)_send)(_dev, sel("newLibraryWithSource:options:error:"),
                                            nsString(src), opts, (pointer)&err);
        pointer pso = (pointer)0;
        pointer fpso = (pointer)0;
        if (lib != (pointer)0)
            {
            pointer fn = ((parMsgP_t*)_send)(lib, sel("newFunctionWithName:"), nsString("par_kernel"));
            pso = ((parMsgPP_t*)_send)(_dev, sel("newComputePipelineStateWithFunction:error:"), fn, (pointer)&err);
            // A module with a fold kernel as well (bug 645): the same library's
            // second function, dispatched after the kernel to combine the
            // workgroups' partials on the device instead of on the host.
            if (hasFold(src))
                {
                pointer ffn = ((parMsgP_t*)_send)(lib, sel("newFunctionWithName:"), nsString("par_fold"));
                fpso = ((parMsgPP_t*)_send)(_dev, sel("newComputePipelineStateWithFunction:error:"), ffn, (pointer)&err);
                }
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
            gParPsoFold[gParKernels] = fpso;
            gParKernels = gParKernels + (u32)1;
            }
        return pso;
        }

    // Whether the kernel's header says `devlast`: the module carries a fold
    // kernel the run dispatches after it, so one partial comes back.
    static bool hasFold(u8* src)
        {
        for (u32 at = (u32)0; src[at] != (u8)0 && src[at] != (u8)10; at = at + (u32)1)
            if (src[at] == (u8)' ' && src[at + (u32)1] == (u8)'d' && src[at + (u32)2] == (u8)'e' &&
                src[at + (u32)3] == (u8)'v' && src[at + (u32)4] == (u8)'l' && src[at + (u32)5] == (u8)'a' &&
                src[at + (u32)6] == (u8)'s' && src[at + (u32)7] == (u8)'t')
                return true;
        return false;
        }

    // The fold kernel's pipeline for a source, or 0.
    static pointer foldPipeline(u8* src)
        {
        for (u32 i = (u32)0; i < gParKernels; i = i + (u32)1)
            if (gParSrc[i] == (pointer)src)
                return gParPsoFold[i];
        return (pointer)0;
        }

    // Run [lo, hi) of the block on the GPU. False when the block cannot go
    // there (no kernel, a buffer of unknown size, no device): the caller then
    // runs it on the CPU, which gives the same answer.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        src = ParDevice.sectionOf(src, "msl", true);
        if (src == (u8*)0)
            return ParDevice.cpu("it has no Metal version");
        if (!start())
            return ParDevice.cpu("there is no Metal device");
        pointer pso = pipeline(src);
        if (pso == (pointer)0)
            return ParDevice.cpu("its GPU version did not compile");
        i64 started = ParDevice.nowUs();

        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        // A kernel that reduces on the device runs in threadgroups of 256
        // (bug 645); a pipeline that cannot hold that many stays on the CPU.
        if (l.devred != (i64)0 && ((parMsgU_t*)_send)(pso, sel("maxTotalThreadsPerThreadgroup")) < (u64)256)
            return ParDevice.cpu("its GPU version needs more registers than a 256-thread group has");
        u8* obj = proto.objBytes();
        i64 per = l.per;
        i64 threads = l.threads;
        u32 nbuf = l.nbuf;
        u32 nglob = l.nglob;
        u32 nred = l.nred;

        parMsgBytes_t* withBytes = (parMsgBytes_t*)_send;
        parMsgLen_t* withLen = (parMsgLen_t*)_send;
        parMsgSetBuf_t* setBuf = (parMsgSetBuf_t*)_send;
        parMsg0_t* send0 = (parMsg0_t*)_send;

        i64 span[4];
        span[0] = lo;
        span[1] = hi;
        span[2] = per;
        // The fold kernel reads it: how many partials to combine.
        span[3] = l.nparts;
        pointer args = withBytes(_dev, sel("newBufferWithBytes:length:options:"), (pointer)obj, (u64)l.size, (u64)0);
        pointer spanB = withBytes(_dev, sel("newBufferWithBytes:length:options:"), (pointer)&span[0], (u64)32, (u64)0);
        pointer bufs[16];
        bool bufShared[16];
        u64 bufAt[16];
        pointer reds[16];
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            pointer host = *(pointer*)(obj + l.bufOff[i]);
            bufs[i] = bufferFor(host, (u64)l.bufLen[i], &bufShared[i], &bufAt[i]);
            }
        pointer globs[16];
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            globs[i] = l.globOut[i] != (i64)0
                           ? withLen(_dev, sel("newBufferWithLength:options:"), (u64)l.globLen[i], (u64)0)
                           : withBytes(_dev, sel("newBufferWithBytes:length:options:"), l.globPtr[i], (u64)l.globLen[i], (u64)0);
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            reds[i] = withLen(_dev, sel("newBufferWithLength:options:"), (u64)(l.nparts * l.redStride[i]), (u64)0);

        pointer cb = send0(_queue, sel("commandBuffer"));
        pointer enc = send0(cb, sel("computeCommandEncoder"));
        ((parMsgP_t*)_send)(enc, sel("setComputePipelineState:"), pso);
        setBuf(enc, sel("setBuffer:offset:atIndex:"), args, (u64)0, (u64)0);
        setBuf(enc, sel("setBuffer:offset:atIndex:"), spanB, (u64)0, (u64)1);
        u64 slot = (u64)2;
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            setBuf(enc, sel("setBuffer:offset:atIndex:"), bufs[i], bufAt[i], slot);
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
        if (l.devred != (i64)0)
            {
            // A kernel that reduces on the device (bug 645) needs whole
            // threadgroups of 256: one partial each, every slot written. The
            // threads past the range hold their starting values.
            grid.w = (u64)l.nparts;
            group.w = (u64)256;
            ((parMsgDispatch_t*)_send)(enc, sel("dispatchThreadgroups:threadsPerThreadgroup:"), &grid, &group);
            }
        else
            ((parMsgDispatch_t*)_send)(enc, sel("dispatchThreads:threadsPerThreadgroup:"), &grid, &group);
        // And when the module has a fold kernel, one more dispatch combines the
        // partials on the device (bug 645). The buffer barrier is the memory
        // dependency; the dispatch boundary is the execution one. The bindings
        // stay as they are — Metal keeps them across a pipeline change.
        if (l.devlast != (i64)0)
            {
            pointer fpso = foldPipeline(src);
            if (fpso != (pointer)0)
                {
                ((parMsgP_t*)_send)(enc, sel("setComputePipelineState:"), fpso);
                ((parMsgSetU_t*)_send)(enc, sel("memoryBarrierWithScope:"), (u64)1);   // MTLBarrierScopeBuffers
                ParMTLSize fgrid;
                fgrid.w = (u64)1; fgrid.h = (u64)1; fgrid.d = (u64)1;
                ParMTLSize fgroup;
                fgroup.w = (u64)256; fgroup.h = (u64)1; fgroup.d = (u64)1;
                ((parMsgDispatch_t*)_send)(enc, sel("dispatchThreadgroups:threadsPerThreadgroup:"), &fgrid, &fgroup);
                }
            }
        send0(enc, sel("endEncoding"));
        send0(cb, sel("commit"));
        send0(cb, sel("waitUntilCompleted"));

        // The arrays come back; each thread's partials fold in thread order.
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            pointer host = *(pointer*)(obj + l.bufOff[i]);
            if (l.bufIn[i] == (i64)0 && !bufShared[i])
                memcpy(host, send0(bufs[i], sel("contents")), (u64)l.bufLen[i]);
            send0(bufs[i], sel("release"));
            }
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            {
            if (l.globIn[i] == (i64)0)
                memcpy(l.globPtr[i], send0(globs[i], sel("contents")), (u64)l.globLen[i]);
            send0(globs[i], sel("release"));
            }
        u8* parts[16];
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            parts[i] = (u8*)send0(reds[i], sel("contents"));
        l.fold(proto, &parts[0]);
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            send0(reds[i], sel("release"));
        send0(args, sel("release"));
        send0(spanB, sel("release"));
        // For auto: the whole run (copies in and out included), without the
        // one-off pipeline build; for XC_PAR_REPORT, the GPU's own time too.
        i64 took = ParDevice.nowUs() - started;
        double t0 = ((parMsgD_t*)_send)(cb, sel("GPUStartTime"));
        double t1 = ((parMsgD_t*)_send)(cb, sel("GPUEndTime"));
        ParDevice.ranOnGpu(proto, l, took, (i64)((t1 - t0) * 1000000.0));
        return true;
        }
    }

// The Metal GPU as a worker on the tile queue (par-tiles-and-devices.md
// step 3). Apple silicon shares memory with the CPU, so a run copies each
// buffer into a shared MTLBuffer ONCE (what a single shot does) and each
// tile is a dispatch over its own span of the same buffers; a tile's
// written slices are copied back to the host as it finishes, while later
// tiles run, and its partials fold as a chunk copy. What this buys on a Mac
// is the GPU and the CPU pool splitting one range, and the read-back
// overlapping the kernels.
class ParMetalWorker : ParWorker
    {
    bool _ready;
    pointer _pso;
    pointer _fpso;
    ParChunk* _proto;
    ParLayout* _l;
    pointer _args;          // the object as it was before any fold
    pointer _bufs[16];
    pointer _globs[16];
    pointer _span[PAR_MTL_DEPTH];
    pointer _reds[PAR_MTL_DEPTH * 16];
    pointer _cb[PAR_MTL_DEPTH];
    ParTile* _slotTile[PAR_MTL_DEPTH];
    i64 _slotStart[PAR_MTL_DEPTH];
    u32 _nextSlot;
    u32 _oldest;
    u32 _inFlight;
    bool _bufShared[16];      // captured array i is a page-aligned block the GPU shares in place
    u64 _bufAt[16];           // and the pointer's offset into that block

    String* identity(void)
        {
        return ParMetal.identity();
        }
    u32 depth(void)
        {
        return (u32)PAR_MTL_DEPTH;
        }
    u8* section(u8* src)
        {
        return ParDevice.sectionOf(src, "msl", true);
        }
    i64 floor(void)
        {
        return (i64)4096;
        }
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        src = ParDevice.sectionOf(src, "msl", true);
        if (src == (u8*)0 || l == (ParLayout*)0 || !ParMetal.start())
            return false;
        // The block laid out from this worker's own section.
        l = ParDevice.layout(proto, src, (i64)0, l.n);
        if (l == (ParLayout*)0)
            return false;
        pointer pso = ParMetal.pipeline(src);
        if (pso == (pointer)0)
            return false;
        if (l.devred != (i64)0 && ((parMsgU_t*)gMtlSend)(pso, ParMetal.sel("maxTotalThreadsPerThreadgroup")) < (u64)256)
            return false;
        // Every written buffer needs a footprint, so a tile knows which slice
        // to copy back; a read-only one is whole in any case, and a `simd:`
        // block the GPU shares in place has nothing to copy.
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufIn[i] == (i64)0 && l.bufFp[i] == (i64)0
                && !ParMetal.isShared(*(pointer*)(proto.objBytes() + l.bufOff[i])))
                return false;
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globIn[i] == (i64)0 && l.globFp[i] == (i64)0)
                return false;
        return true;
        }

    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        parMsgBytes_t* withBytes = (parMsgBytes_t*)gMtlSend;
        parMsgLen_t* withLen = (parMsgLen_t*)gMtlSend;
        src = ParDevice.sectionOf(src, "msl", true);
        if (src == (u8*)0)
            return false;
        _proto = proto;
        _l = ParDevice.layout(proto, src, (i64)0, l.n);
        if (_l == (ParLayout*)0)
            return false;
        l = _l;
        _pso = ParMetal.pipeline(src);
        _fpso = l.devlast != (i64)0 ? ParMetal.foldPipeline(src) : (pointer)0;
        if (_pso == (pointer)0)
            return false;
        u8* obj = proto.objBytes();
        _args = withBytes(gMtlDev, ParMetal.sel("newBufferWithBytes:length:options:"), (pointer)obj, (u64)l.size, (u64)0);
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            _bufs[i] = ParMetal.bufferFor(*(pointer*)(obj + l.bufOff[i]), (u64)l.bufLen[i], &_bufShared[i], &_bufAt[i]);
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            _globs[i] = withBytes(gMtlDev, ParMetal.sel("newBufferWithBytes:length:options:"), l.globPtr[i], (u64)l.globLen[i], (u64)0);
        l.plan(0, tile);
        for (u32 d = (u32)0; d < (u32)PAR_MTL_DEPTH; d = d + (u32)1)
            {
            _span[d] = withLen(gMtlDev, ParMetal.sel("newBufferWithLength:options:"), (u64)32, (u64)0);
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                _reds[d * (u32)16 + r] = withLen(gMtlDev, ParMetal.sel("newBufferWithLength:options:"), (u64)(l.nparts * l.redStride[r]), (u64)0);
            _slotTile[d] = (ParTile*)0;
            _cb[d] = (pointer)0;
            }
        _nextSlot = (u32)0;
        _oldest = (u32)0;
        _inFlight = (u32)0;
        _ready = true;
        return true;
        }

    void finish(void)
        {
        parMsg0_t* send0 = (parMsg0_t*)gMtlSend;
        if (!_ready)
            return;
        ParLayout* l = _l;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            send0(_bufs[i], ParMetal.sel("release"));
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            send0(_globs[i], ParMetal.sel("release"));
        for (u32 d = (u32)0; d < (u32)PAR_MTL_DEPTH; d = d + (u32)1)
            {
            send0(_span[d], ParMetal.sel("release"));
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                send0(_reds[d * (u32)16 + r], ParMetal.sel("release"));
            }
        send0(_args, ParMetal.sel("release"));
        _ready = false;
        _proto = (ParChunk*)0;
        _l = (ParLayout*)0;
        }

    // Metal's working-set figure and what it has allocated now.
    void memory(u64* total, u64* free)
        {
        *total = (u64)0;
        *free = (u64)0;
        if (gMtlDev == (pointer)0)
            return;
        u64 max = ((parMsgU_t*)gMtlSend)(gMtlDev, ParMetal.sel("recommendedMaxWorkingSetSize"));
        u64 used = ((parMsgU_t*)gMtlSend)(gMtlDev, ParMetal.sel("currentAllocatedSize"));
        *total = max;
        *free = used < max ? max - used : (u64)0;
        }
    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (!_ready || _inFlight >= (u32)PAR_MTL_DEPTH)
            return false;
        l = _l;
        parMsg0_t* send0 = (parMsg0_t*)gMtlSend;
        parMsgSetBuf_t* setBuf = (parMsgSetBuf_t*)gMtlSend;
        u32 d = _nextSlot;
        l.plan(t.lo, t.hi);
        i64* span = (i64*)send0(_span[d], ParMetal.sel("contents"));
        span[0] = t.lo;
        span[1] = t.hi;
        span[2] = l.per;
        span[3] = l.nparts;
        pointer cb = send0(gMtlQueue, ParMetal.sel("commandBuffer"));
        pointer enc = send0(cb, ParMetal.sel("computeCommandEncoder"));
        ((parMsgP_t*)gMtlSend)(enc, ParMetal.sel("setComputePipelineState:"), _pso);
        setBuf(enc, ParMetal.sel("setBuffer:offset:atIndex:"), _args, (u64)0, (u64)0);
        setBuf(enc, ParMetal.sel("setBuffer:offset:atIndex:"), _span[d], (u64)0, (u64)1);
        u64 slot = (u64)2;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            setBuf(enc, ParMetal.sel("setBuffer:offset:atIndex:"), _bufs[i], _bufAt[i], slot);
            slot = slot + (u64)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            setBuf(enc, ParMetal.sel("setBuffer:offset:atIndex:"), _globs[i], (u64)0, slot);
            slot = slot + (u64)1;
            }
        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
            {
            setBuf(enc, ParMetal.sel("setBuffer:offset:atIndex:"), _reds[d * (u32)16 + r], (u64)0, slot);
            slot = slot + (u64)1;
            }
        u64 width = ((parMsgU_t*)gMtlSend)(_pso, ParMetal.sel("maxTotalThreadsPerThreadgroup"));
        ParMTLSize grid;
        grid.w = (u64)l.threads;
        grid.h = (u64)1;
        grid.d = (u64)1;
        ParMTLSize group;
        group.w = width < (u64)l.threads ? width : (u64)l.threads;
        group.h = (u64)1;
        group.d = (u64)1;
        if (l.devred != (i64)0)
            {
            grid.w = (u64)l.nparts;
            group.w = (u64)256;
            ((parMsgDispatch_t*)gMtlSend)(enc, ParMetal.sel("dispatchThreadgroups:threadsPerThreadgroup:"), &grid, &group);
            }
        else
            ((parMsgDispatch_t*)gMtlSend)(enc, ParMetal.sel("dispatchThreads:threadsPerThreadgroup:"), &grid, &group);
        if (l.devlast != (i64)0 && _fpso != (pointer)0)
            {
            ((parMsgP_t*)gMtlSend)(enc, ParMetal.sel("setComputePipelineState:"), _fpso);
            ((parMsgSetU_t*)gMtlSend)(enc, ParMetal.sel("memoryBarrierWithScope:"), (u64)1);
            ParMTLSize fgrid;
            fgrid.w = (u64)1; fgrid.h = (u64)1; fgrid.d = (u64)1;
            ParMTLSize fgroup;
            fgroup.w = (u64)256; fgroup.h = (u64)1; fgroup.d = (u64)1;
            ((parMsgDispatch_t*)gMtlSend)(enc, ParMetal.sel("dispatchThreadgroups:threadsPerThreadgroup:"), &fgrid, &fgroup);
            }
        send0(enc, ParMetal.sel("endEncoding"));
        send0(cb, ParMetal.sel("retain"));
        send0(cb, ParMetal.sel("commit"));
        _cb[d] = cb;
        _slotTile[d] = t;
        _slotStart[d] = ParDevice.nowUs();
        t.worker = (ParWorker*)self;
        _nextSlot = (d + (u32)1) % (u32)PAR_MTL_DEPTH;
        _inFlight = _inFlight + (u32)1;
        return true;
        }

    // The oldest slot's tile, finished: its written slices back to the host,
    // its partials into a chunk copy.
    ParTile* complete(u32 d)
        {
        parMsg0_t* send0 = (parMsg0_t*)gMtlSend;
        ParTile* t = _slotTile[d];
        ParLayout* l = _l;
        u8* obj = _proto.objBytes();
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufIn[i] != (i64)0 || l.bufFp[i] == (i64)0 || _bufShared[i])
                continue;
            i64 count = l.bufLen[i] / l.bufElem[i];
            i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
            if (e1 > e0)
                memcpy((pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]),
                       (pointer)((u8*)send0(_bufs[i], ParMetal.sel("contents")) + e0 * l.bufElem[i]), (u64)((e1 - e0) * l.bufElem[i]));
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globIn[i] != (i64)0 || l.globFp[i] == (i64)0)
                continue;
            i64 count = l.globLen[i] / l.globElem[i];
            i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
            i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
            if (e1 > e0)
                memcpy((pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]),
                       (pointer)((u8*)send0(_globs[i], ParMetal.sel("contents")) + e0 * l.globElem[i]), (u64)((e1 - e0) * l.globElem[i]));
            }
        if (l.nred > (u32)0)
            {
            l.plan(t.lo, t.hi);
            u8* parts[16];
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                parts[r] = (u8*)send0(_reds[d * (u32)16 + r], ParMetal.sel("contents"));
            if (_proto.rawPartials())
                {
                t.raw = Data.withLength((u32)0);
                for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                    t.raw.appendBytes(parts[r], (u32)(l.nback * l.redStride[r]));
                }
            else
                {
                ParChunk* c = _proto.copyChunk();
                l.fold(c, &parts[0]);
                t.partial = c;
                }
            }
        send0(_cb[d], ParMetal.sel("release"));
        _cb[d] = (pointer)0;
        t.done = true;
        t.usTaken = ParDevice.nowUs() - _slotStart[d];
        _slotTile[d] = (ParTile*)0;
        _oldest = (d + (u32)1) % (u32)PAR_MTL_DEPTH;
        _inFlight = _inFlight - (u32)1;
        return t;
        }

    ParTile* poll(void)
        {
        if (_inFlight == (u32)0)
            return (ParTile*)0;
        u32 d = _oldest;
        // MTLCommandBufferStatus: 4 completed, 5 error.
        u64 st = ((parMsgU_t*)gMtlSend)(_cb[d], ParMetal.sel("status"));
        if (st < (u64)4)
            return (ParTile*)0;
        if (st == (u64)5)
            Log.error("par: a Metal tile failed");
        return complete(d);
        }

    bool waits(void)
        {
        return true;
        }
    bool waitFor(ParTile* t)
        {
        for (u32 d = (u32)0; d < (u32)PAR_MTL_DEPTH; d = d + (u32)1)
            if (_slotTile[d] == t)
                {
                ((parMsg0_t*)gMtlSend)(_cb[d], ParMetal.sel("waitUntilCompleted"));
                return true;
                }
        return false;
        }

    void drain(void)
        {
        parMsg0_t* send0 = (parMsg0_t*)gMtlSend;
        while (_inFlight > (u32)0)
            {
            send0(_cb[_oldest], ParMetal.sel("waitUntilCompleted"));
            complete(_oldest);
            }
        }
    }
