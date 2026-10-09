// ParCuda.xc — runs a `par` block on an NVIDIA GPU through the CUDA driver
// (Windows), for Par.run when ParDevice chooses the GPU.
//
// The compiler gives each block its kernel as PTX (gpuSource()), printed from
// the block's own chunk method, under the same header line as the Metal
// runtime reads (ParDevice.xc). The driver compiles the PTX for the GPU it
// finds, so a program needs no CUDA toolkit, only the driver: nvcuda.dll is
// loaded when a block first asks for the GPU, and its entry points are looked
// up by name, so a machine without one runs every block on the CPU.
//
// Each GPU thread runs the method over its own slice of the range. Captured
// arrays and globals are copied in and back; each thread's reductions come
// back as partials, folded in thread order (ParLayout.fold).
#import "ParDevice.xc"

pointer LoadLibraryA(u8* name);
pointer GetProcAddress(pointer module, u8* name);
pointer malloc(u64 n);
void free(pointer p);

typedef i32 cuInit_t(u32 flags);
typedef i32 cuDeviceGet_t(i32* dev, i32 ordinal);
typedef i32 cuDeviceGetName_t(u8* name, i32 len, i32 dev);
typedef i32 cuCtxCreate_t(pointer* ctx, u32 flags, i32 dev);
typedef i32 cuModuleLoadDataEx_t(pointer* mod, pointer image, u32 n, pointer options, pointer values);
typedef i32 cuModuleGetFunction_t(pointer* fn, pointer mod, u8* name);
typedef i32 cuMemAlloc_t(u64* dptr, u64 bytes);
typedef i32 cuMemFree_t(u64 dptr);
typedef i32 cuMemcpyHtoD_t(u64 dst, pointer src, u64 n);
typedef i32 cuMemcpyDtoH_t(pointer dst, u64 src, u64 n);
typedef i32 cuLaunchKernel_t(pointer f, u32 gx, u32 gy, u32 gz, u32 bx, u32 by, u32 bz, u32 shmem,
                             pointer stream, pointer* params, pointer* extra);
typedef i32 cuCtxSynchronize_t(void);

// The kernels compiled so far: each gpuSource() pointer and its function.
pointer gParCuSrc[64];
pointer gParCuFn[64];
u32 gParCuKernels;
// Each kernel parameter slot's device memory from the last runs, and its size
// (see upload).
i32 memcmp(pointer a, pointer b, u64 n);
u64 gParCuDev[52];
i64 gParCuCap[52];
// What slot k's device memory holds when a kernel that only reads it put it
// there: the host address, its length and a copy of the bytes (bug 645). The
// next upload of the same bytes from the same place is left out. Any other
// upload to the slot clears it, so the device copy is only trusted while
// nothing else has written there.
pointer gParCuShadowHost[52];
i64 gParCuShadowLen[52];
u8* gParCuShadow[52];

class ParCuda
    {
    static i32 _state;          // 0 not tried, 1 ready, 2 no driver or no GPU
    static String* _identity;   // "cuda:<device name>", for auto's hardware key (ParDevice)
    static pointer _ctx;
    static cuModuleLoadDataEx_t* _load;
    static cuModuleGetFunction_t* _getFunction;
    static cuMemAlloc_t* _alloc;
    static cuMemFree_t* _free;
    static cuMemcpyHtoD_t* _toDevice;
    static cuMemcpyDtoH_t* _toHost;
    static cuLaunchKernel_t* _launch;
    static cuCtxSynchronize_t* _sync;

    static bool start(void)
        {
        if (_state != (i32)0)
            return _state == (i32)1;
        _state = (i32)2;
        pointer lib = LoadLibraryA("nvcuda.dll");
        if (lib == (pointer)0)
            return false;
        cuInit_t* init = (cuInit_t*)GetProcAddress(lib, "cuInit");
        cuDeviceGet_t* deviceGet = (cuDeviceGet_t*)GetProcAddress(lib, "cuDeviceGet");
        cuCtxCreate_t* ctxCreate = (cuCtxCreate_t*)GetProcAddress(lib, "cuCtxCreate_v2");
        _load = (cuModuleLoadDataEx_t*)GetProcAddress(lib, "cuModuleLoadDataEx");
        _getFunction = (cuModuleGetFunction_t*)GetProcAddress(lib, "cuModuleGetFunction");
        _alloc = (cuMemAlloc_t*)GetProcAddress(lib, "cuMemAlloc_v2");
        _free = (cuMemFree_t*)GetProcAddress(lib, "cuMemFree_v2");
        _toDevice = (cuMemcpyHtoD_t*)GetProcAddress(lib, "cuMemcpyHtoD_v2");
        _toHost = (cuMemcpyDtoH_t*)GetProcAddress(lib, "cuMemcpyDtoH_v2");
        _launch = (cuLaunchKernel_t*)GetProcAddress(lib, "cuLaunchKernel");
        _sync = (cuCtxSynchronize_t*)GetProcAddress(lib, "cuCtxSynchronize");
        if (init == (cuInit_t*)0 || deviceGet == (cuDeviceGet_t*)0 || ctxCreate == (cuCtxCreate_t*)0 ||
            _load == (cuModuleLoadDataEx_t*)0 || _getFunction == (cuModuleGetFunction_t*)0 ||
            _alloc == (cuMemAlloc_t*)0 || _free == (cuMemFree_t*)0 || _toDevice == (cuMemcpyHtoD_t*)0 ||
            _toHost == (cuMemcpyDtoH_t*)0 || _launch == (cuLaunchKernel_t*)0 ||
            _sync == (cuCtxSynchronize_t*)0)
            return false;
        i32 dev = (i32)0;
        pointer ctx = (pointer)0;
        if (init((u32)0) != (i32)0 || deviceGet(&dev, (i32)0) != (i32)0 || ctxCreate(&ctx, (u32)0, dev) != (i32)0)
            return false;
        _ctx = ctx;
        _identity = String.withCString("cuda:");
        cuDeviceGetName_t* getName = (cuDeviceGetName_t*)GetProcAddress(lib, "cuDeviceGetName");
        u8 nm[256];
        nm[0] = (u8)0;
        if (getName != (cuDeviceGetName_t*)0 && getName(&nm[0], (i32)255, dev) == (i32)0)
            _identity.appendCString(&nm[0]);
        _state = (i32)1;
        return true;
        }

    // The GPU, for the hardware key auto's learned choices are kept under, or
    // "" when CUDA has none.
    static String* identity(void)
        {
        if (!start() || _identity == (String*)0)
            return String.withCString("");
        return _identity;
        }

    // The compiled kernel for a source, made once (nil if it did not compile).
    static pointer function(u8* src)
        {
        for (u32 i = (u32)0; i < gParCuKernels; i = i + (u32)1)
            if (gParCuSrc[i] == (pointer)src)
                return gParCuFn[i];
        pointer mod = (pointer)0;
        pointer fn = (pointer)0;
        // The JIT's error log: CU_JIT_ERROR_LOG_BUFFER (5) and its size (6).
        u8 log[2048];
        log[0] = (u8)0;
        u32 opts[2];
        opts[0] = (u32)5;
        opts[1] = (u32)6;
        pointer vals[2];
        vals[0] = (pointer)&log[0];
        vals[1] = (pointer)(u64)2048;
        i32 rc = _load(&mod, (pointer)src, (u32)2, (pointer)&opts[0], (pointer)&vals[0]);
        if (rc == (i32)0)
            rc = _getFunction(&fn, mod, "par_kernel");
        if (rc != (i32)0)
            {
            Log.error("par: the GPU kernel did not compile, running on the CPU: CUDA error %d: %s", rc, &log[0]);
            fn = (pointer)0;
            }
        if (gParCuKernels < (u32)64)
            {
            gParCuSrc[gParCuKernels] = (pointer)src;
            gParCuFn[gParCuKernels] = fn;
            gParCuKernels = gParCuKernels + (u32)1;
            }
        return fn;
        }

    // Parameter slot k's device memory, holding a copy of host (or space the
    // kernel fills, when host is nil). Kept for the next run and reused where
    // big enough, as allocating device memory costs more than most blocks.
    static u64 upload(u32 k, pointer host, i64 bytes)
        {
        return uploadKeeping(k, host, bytes, false);
        }

    // As upload, for data the kernel only reads: up to 64 KB of it is
    // remembered, and not sent again while it has not changed.
    static u64 uploadKeeping(u32 k, pointer host, i64 bytes, bool readOnly)
        {
        bool keep = readOnly && host != (pointer)0 && bytes > (i64)0 && bytes <= (i64)65536;
        if (keep && gParCuDev[k] != (u64)0 && gParCuShadow[k] != (u8*)0 && gParCuShadowHost[k] == host &&
            gParCuShadowLen[k] == bytes && memcmp((pointer)gParCuShadow[k], host, (u64)bytes) == (i32)0)
            return gParCuDev[k];
        if (gParCuShadow[k] != (u8*)0)
            {
            free((pointer)gParCuShadow[k]);
            gParCuShadow[k] = (u8*)0;
            gParCuShadowHost[k] = (pointer)0;
            gParCuShadowLen[k] = (i64)0;
            }
        if (gParCuDev[k] == (u64)0 || gParCuCap[k] < bytes)
            {
            if (gParCuDev[k] != (u64)0)
                _free(gParCuDev[k]);
            gParCuDev[k] = (u64)0;
            gParCuCap[k] = (i64)0;
            u64 d = (u64)0;
            if (_alloc(&d, (u64)bytes) != (i32)0)
                return (u64)0;
            gParCuDev[k] = d;
            gParCuCap[k] = bytes;
            }
        if (host != (pointer)0)
            _toDevice(gParCuDev[k], host, (u64)bytes);
        if (keep)
            {
            gParCuShadow[k] = (u8*)malloc((u64)bytes);
            if (gParCuShadow[k] != (u8*)0)
                {
                memcpy((pointer)gParCuShadow[k], host, (u64)bytes);
                gParCuShadowHost[k] = host;
                gParCuShadowLen[k] = bytes;
                }
            }
        return gParCuDev[k];
        }

    // Run [lo, hi) of the block on the GPU. False when the block cannot go
    // there (no kernel, a buffer of unknown size, no device): the caller then
    // runs it on the CPU, which gives the same answer.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return ParDevice.cpu("it has no GPU version");
        // A kernel whose header names spirv= is SPIR-V alone (the PTX did not
        // print): that is for Vulkan, which Par tries next.
        for (u32 at = (u32)0; src[at] != (u8)0 && src[at] != (u8)10; at = at + (u32)1)
            if (src[at] == (u8)'s' && src[at + (u32)1] == (u8)'p' && src[at + (u32)5] == (u8)'=')
                return false;
        if (!start())
            return ParDevice.cpu("there is no CUDA device");
        pointer fn = function(src);
        if (fn == (pointer)0)
            return ParDevice.cpu("its GPU version did not compile");
        i64 started = ParDevice.nowUs();
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        u8* obj = (u8*)(pointer)proto;

        // The kernel's parameters, in its order: args, span, buffers,
        // globals, reductions. Each is a device address, passed by pointer.
        i64 span[3];
        span[0] = lo;
        span[1] = hi;
        span[2] = l.per;
        u64 dev[52];
        u32 nd = (u32)0;
        dev[nd] = upload(nd, (pointer)obj, l.size);
        nd = nd + (u32)1;
        dev[nd] = upload(nd, (pointer)&span[0], (i64)24);
        nd = nd + (u32)1;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            dev[nd] = uploadKeeping(nd, *(pointer*)(obj + l.bufOff[i]), l.bufLen[i], l.bufIn[i] != (i64)0);
            nd = nd + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            dev[nd] = uploadKeeping(nd, l.globOut[i] != (i64)0 ? (pointer)0 : l.globPtr[i], l.globLen[i], l.globIn[i] != (i64)0);
            nd = nd + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
            {
            dev[nd] = upload(nd, (pointer)0, l.nparts * l.redStride[i]);
            nd = nd + (u32)1;
            }
        bool ok = true;
        pointer params[52];
        for (u32 i = (u32)0; i < nd; i = i + (u32)1)
            {
            if (dev[i] == (u64)0)
                ok = false;
            params[i] = (pointer)&dev[i];
            }
        i64 gpuStart = ParDevice.nowUs();
        i64 gpuUs = (i64)-1;
        if (ok)
            {
            u32 group = (u32)256;
            u32 grid = (u32)((l.threads + (i64)group - (i64)1) / (i64)group);
            ok = _launch(fn, grid, (u32)1, (u32)1, group, (u32)1, (u32)1, (u32)0, (pointer)0, &params[0],
                         (pointer*)0) == (i32)0 &&
                 _sync() == (i32)0;
            gpuUs = ParDevice.nowUs() - gpuStart;
            }

        // The arrays come back; the partials (one per thread, or per
        // workgroup when the kernel reduced on the device) fold in order.
        if (ok)
            {
            u32 at = (u32)2;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufIn[i] == (i64)0)
                    _toHost(*(pointer*)(obj + l.bufOff[i]), dev[at], (u64)l.bufLen[i]);
                at = at + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globIn[i] == (i64)0)
                    _toHost(l.globPtr[i], dev[at], (u64)l.globLen[i]);
                at = at + (u32)1;
                }
            u8* parts[16];
            for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
                {
                i64 bytes = l.nback * l.redStride[i];
                parts[i] = (u8*)malloc((u64)bytes);
                _toHost((pointer)parts[i], dev[at], (u64)bytes);
                at = at + (u32)1;
                }
            l.fold(proto, &parts[0]);
            for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
                free((pointer)parts[i]);
            }
        // The device memory stays for the next run (gParCuDev).
        if (!ok)
            {
            Log.error("par: the GPU run failed, running on the CPU");
            return false;
            }
        ParDevice.ranOnGpu(proto, l, ParDevice.nowUs() - started, gpuUs);
        return true;
        }
    }
