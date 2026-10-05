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
        // Precise maths unless the block says otherwise: MTLMathModeSafe, or
        // MTLMathModeFast for a block whose goal is speed (the default).
        ((parMsgSetU_t*)_send)(opts, sel("setMathMode:"), ParDevice.isFast(src) ? (u64)2 : (u64)0);
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

    // Run [lo, hi) of the block on the GPU. False when the block cannot go
    // there (no kernel, a buffer of unknown size, no device): the caller then
    // runs it on the CPU, which gives the same answer.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return ParDevice.cpu("it has no GPU version");
        if (!start())
            return ParDevice.cpu("there is no Metal device");
        pointer pso = pipeline(src);
        if (pso == (pointer)0)
            return ParDevice.cpu("its GPU version did not compile");
        i64 started = ParDevice.nowUs();

        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        u8* obj = (u8*)(pointer)proto;
        i64 per = l.per;
        i64 threads = l.threads;
        u32 nbuf = l.nbuf;
        u32 nglob = l.nglob;
        u32 nred = l.nred;

        parMsgBytes_t* withBytes = (parMsgBytes_t*)_send;
        parMsgLen_t* withLen = (parMsgLen_t*)_send;
        parMsgSetBuf_t* setBuf = (parMsgSetBuf_t*)_send;
        parMsg0_t* send0 = (parMsg0_t*)_send;

        i64 span[3];
        span[0] = lo;
        span[1] = hi;
        span[2] = per;
        pointer args = withBytes(_dev, sel("newBufferWithBytes:length:options:"), (pointer)obj, (u64)l.size, (u64)0);
        pointer spanB = withBytes(_dev, sel("newBufferWithBytes:length:options:"), (pointer)&span[0], (u64)24, (u64)0);
        pointer bufs[16];
        pointer reds[16];
        for (u32 i = (u32)0; i < nbuf; i = i + (u32)1)
            {
            pointer host = *(pointer*)(obj + l.bufOff[i]);
            bufs[i] = withBytes(_dev, sel("newBufferWithBytes:length:options:"), host, (u64)l.bufLen[i], (u64)0);
            }
        pointer globs[16];
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            globs[i] = withBytes(_dev, sel("newBufferWithBytes:length:options:"), l.globPtr[i], (u64)l.globLen[i], (u64)0);
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            reds[i] = withLen(_dev, sel("newBufferWithLength:options:"), (u64)(threads * l.redSize[i]), (u64)0);

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
            pointer host = *(pointer*)(obj + l.bufOff[i]);
            memcpy(host, send0(bufs[i], sel("contents")), (u64)l.bufLen[i]);
            send0(bufs[i], sel("release"));
            }
        for (u32 i = (u32)0; i < nglob; i = i + (u32)1)
            {
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
