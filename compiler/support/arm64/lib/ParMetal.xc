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

class ParMetal
    {
    static pointer _send;
    static parObjcName_t* _cls;
    static parObjcName_t* _sel;
    static pointer _dev;
    static pointer _queue;
    static i32 _mode;            // 0 unread, 1 CPU, 2 GPU (statics start at 0)

    // XC_PAR=gpu sends every block that has a kernel to the GPU.
    static bool wanted(void)
        {
        if (_mode == (i32)0)
            {
            String* v = Platform.env(String.withCString("XC_PAR"));
            _mode = v.equals(String.withCString("gpu")) ? (i32)2 : (i32)1;
            }
        return _mode == (i32)2;
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
        if (src == (u8*)0 || src[0] != (u8)'/' || !start())
            return false;
        pointer pso = pipeline(src);
        if (pso == (pointer)0)
            return false;

        // The header line.
        u8* obj = (u8*)(pointer)proto;
        i64 size = (i64)0;
        i64 bufOff[16]; i64 bufIvar[16]; i64 bufLen[16]; u32 nbuf = (u32)0;
        i64 redOff[16]; i64 redSize[16]; u32 nred = (u32)0;
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
                    return false; // not a sized array: the CPU takes it
                nbuf = nbuf + (u32)1;
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
            return false;

        i64 n = hi - lo;
        i64 per = (i64)1;
        i64 most = (i64)1 << (i64)22;
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
        if (nred > (u32)0)
            {
            for (i64 t = (i64)0; t < threads; t = t + (i64)1)
                {
                ParChunk* c = proto.copyChunk();
                u8* cb2 = (u8*)(pointer)c;
                for (u32 i = (u32)0; i < nred; i = i + (u32)1)
                    {
                    u8* part = (u8*)send0(reds[i], sel("contents"));
                    memcpy((pointer)(cb2 + redOff[i]), (pointer)(part + t * redSize[i]), (u64)redSize[i]);
                    }
                proto.merge(c);
                }
            }
        for (u32 i = (u32)0; i < nred; i = i + (u32)1)
            send0(reds[i], sel("release"));
        send0(args, sel("release"));
        send0(spanB, sel("release"));
        // XC_PAR_REPORT=1: say where each block ran (par-blocks.md §8).
        if (Platform.env(String.withCString("XC_PAR_REPORT")).byteLength() > (u32)0)
            Log.info("par: %ld items on the GPU, %ld threads", n, threads);
        return true;
        }
    }
