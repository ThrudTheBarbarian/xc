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
// Step 2 of par-tiles-and-devices.md: streams, events and pinned host memory,
// so a tile's copies overlap another tile's kernel.
typedef i32 cuDeviceGetAttribute_t(i32* value, i32 attrib, i32 dev);
typedef i32 cuStreamCreate_t(pointer* stream, u32 flags);
typedef i32 cuStreamSynchronize_t(pointer stream);
typedef i32 cuEventCreate_t(pointer* event, u32 flags);
typedef i32 cuEventRecord_t(pointer event, pointer stream);
typedef i32 cuEventSynchronize_t(pointer event);
typedef i32 cuMemHostAlloc_t(pointer* host, u64 bytes, u32 flags);
typedef i32 cuMemFreeHost_t(pointer host);
typedef i32 cuMemcpyHtoDAsync_t(u64 dst, pointer src, u64 n, pointer stream);
typedef i32 cuMemcpyDtoHAsync_t(pointer dst, u64 src, u64 n, pointer stream);
typedef i32 cuStreamWaitEvent_t(pointer stream, pointer event, u32 flags);
typedef i32 cuMemHostRegister_t(pointer host, u64 bytes, u32 flags);
typedef i32 cuMemHostUnregister_t(pointer host);
typedef i32 cuDeviceGetCount_t(i32* count);
typedef i32 cuCtxSetCurrent_t(pointer ctx);
typedef i32 cuEventQuery_t(pointer event);
// The caller's arrays registered as pinned memory, so a tile's copies go
// straight between them and the device with no staging copy on the host:
// registering costs about a millisecond per 64 MB, so only arrays of a
// megabyte and more are registered, and they stay registered across runs
// (a block's arrays are usually the same ones every run). Eight entries,
// the least recently used unregistered to make room.
#define PAR_CU_REG 8
pointer gParCuRegHost[PAR_CU_REG];
i64 gParCuRegLen[PAR_CU_REG];
i64 gParCuRegUsed[PAR_CU_REG];
i64 gParCuRegClock;

// The tiled path's streams, events and pinned staging, made on first use and
// kept: one compute stream the kernels queue on in tile order (a kernel that
// folds its partials on the device counts its workgroups in a module
// global, so two of them must not run at once), and per in-flight tile a
// copy stream, two events and two pinned buffers, uploads and downloads.
#define PAR_CU_DEPTH 3
// The driver's entry points, for the workers (a class's static ivars are its own).
cuMemAlloc_t* gCu_alloc;
cuDeviceGetAttribute_t* gCu_attr;
cuCtxCreate_t* gCu_ctxCreate;
cuCtxSetCurrent_t* gCu_ctxSetCurrent;
cuDeviceGet_t* gCu_deviceGet;
cuEventCreate_t* gCu_eventCreate;
cuEventQuery_t* gCu_eventQuery;
cuEventRecord_t* gCu_eventRecord;
cuEventSynchronize_t* gCu_eventSync;
cuMemFree_t* gCu_free;
cuModuleGetFunction_t* gCu_getFunction;
cuDeviceGetName_t* gCu_getName;
cuMemHostAlloc_t* gCu_hostAlloc;
cuMemFreeHost_t* gCu_hostFree;
cuLaunchKernel_t* gCu_launch;
cuModuleLoadDataEx_t* gCu_load;
cuStreamCreate_t* gCu_streamCreate;
cuStreamWaitEvent_t* gCu_streamWait;
cuMemcpyHtoD_t* gCu_toDevice;
cuMemcpyHtoDAsync_t* gCu_toDeviceAsync;
cuMemcpyDtoHAsync_t* gCu_toHostAsync;
pointer gParCuCompute;
pointer gParCuCopy[PAR_CU_DEPTH];
pointer gParCuUpDone[PAR_CU_DEPTH];
pointer gParCuKernelDone[PAR_CU_DEPTH];
pointer gParCuTileDone[PAR_CU_DEPTH];
u8* gParCuUp[PAR_CU_DEPTH];
i64 gParCuUpCap[PAR_CU_DEPTH];
u8* gParCuDown[PAR_CU_DEPTH];
i64 gParCuDownCap[PAR_CU_DEPTH];

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
    static cuDeviceGetAttribute_t* _attr;
    static cuStreamCreate_t* _streamCreate;
    static cuStreamSynchronize_t* _streamSync;
    static cuEventCreate_t* _eventCreate;
    static cuEventRecord_t* _eventRecord;
    static cuEventSynchronize_t* _eventSync;
    static cuMemHostAlloc_t* _hostAlloc;
    static cuMemFreeHost_t* _hostFree;
    static cuMemcpyHtoDAsync_t* _toDeviceAsync;
    static cuMemcpyDtoHAsync_t* _toHostAsync;
    static cuStreamWaitEvent_t* _streamWait;
    static cuMemHostRegister_t* _hostRegister;
    static cuMemHostUnregister_t* _hostUnregister;
    static cuDeviceGet_t* _deviceGet;
    static cuCtxCreate_t* _ctxCreate;
    static cuDeviceGetName_t* _getName;
    static cuDeviceGetCount_t* _deviceGetCount;
    static cuCtxSetCurrent_t* _ctxSetCurrent;
    static cuEventQuery_t* _eventQuery;
    static i32 _dev;            // the device ordinal the context is on
    static i32 _sms;            // its multiprocessor count (0: unknown)
    static i32 _engines;        // its copy engines (1: a copy in and a copy out never overlap)
    static bool _tiles;         // the async entry points were all found

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
        _attr = (cuDeviceGetAttribute_t*)GetProcAddress(lib, "cuDeviceGetAttribute");
        _streamCreate = (cuStreamCreate_t*)GetProcAddress(lib, "cuStreamCreate");
        _streamSync = (cuStreamSynchronize_t*)GetProcAddress(lib, "cuStreamSynchronize");
        _eventCreate = (cuEventCreate_t*)GetProcAddress(lib, "cuEventCreate");
        _eventRecord = (cuEventRecord_t*)GetProcAddress(lib, "cuEventRecord");
        _eventSync = (cuEventSynchronize_t*)GetProcAddress(lib, "cuEventSynchronize");
        _hostAlloc = (cuMemHostAlloc_t*)GetProcAddress(lib, "cuMemHostAlloc");
        _hostFree = (cuMemFreeHost_t*)GetProcAddress(lib, "cuMemFreeHost");
        _toDeviceAsync = (cuMemcpyHtoDAsync_t*)GetProcAddress(lib, "cuMemcpyHtoDAsync_v2");
        _toHostAsync = (cuMemcpyDtoHAsync_t*)GetProcAddress(lib, "cuMemcpyDtoHAsync_v2");
        _streamWait = (cuStreamWaitEvent_t*)GetProcAddress(lib, "cuStreamWaitEvent");
        _hostRegister = (cuMemHostRegister_t*)GetProcAddress(lib, "cuMemHostRegister_v2");
        _hostUnregister = (cuMemHostUnregister_t*)GetProcAddress(lib, "cuMemHostUnregister");
        _deviceGet = deviceGet;
        _ctxCreate = ctxCreate;
        _getName = (cuDeviceGetName_t*)GetProcAddress(lib, "cuDeviceGetName");
        _deviceGetCount = (cuDeviceGetCount_t*)GetProcAddress(lib, "cuDeviceGetCount");
        _ctxSetCurrent = (cuCtxSetCurrent_t*)GetProcAddress(lib, "cuCtxSetCurrent");
        _eventQuery = (cuEventQuery_t*)GetProcAddress(lib, "cuEventQuery");
        // Without the whole set the runtime stays single shot; the driver's
        // API has had all of them since CUDA 4, so this is defensive.
        _tiles = _attr != (cuDeviceGetAttribute_t*)0 && _streamCreate != (cuStreamCreate_t*)0 &&
                 _streamSync != (cuStreamSynchronize_t*)0 && _eventCreate != (cuEventCreate_t*)0 &&
                 _eventRecord != (cuEventRecord_t*)0 && _eventSync != (cuEventSynchronize_t*)0 &&
                 _hostAlloc != (cuMemHostAlloc_t*)0 && _hostFree != (cuMemFreeHost_t*)0 &&
                 _toDeviceAsync != (cuMemcpyHtoDAsync_t*)0 && _toHostAsync != (cuMemcpyDtoHAsync_t*)0 &&
                 _streamWait != (cuStreamWaitEvent_t*)0;
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
        _dev = dev;
        _sms = (i32)0;
        i32 sms = (i32)0;
        if (_attr != (cuDeviceGetAttribute_t*)0 && _attr(&sms, (i32)16, dev) == (i32)0)   // CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT
            _sms = sms;
        _engines = (i32)0;
        i32 eng = (i32)0;
        if (_attr != (cuDeviceGetAttribute_t*)0 && _attr(&eng, (i32)40, dev) == (i32)0)   // CU_DEVICE_ATTRIBUTE_ASYNC_ENGINE_COUNT
            _engines = eng;
        _identity = String.withCString("cuda:");
        cuDeviceGetName_t* getName = (cuDeviceGetName_t*)GetProcAddress(lib, "cuDeviceGetName");
        u8 nm[256];
        nm[0] = (u8)0;
        if (getName != (cuDeviceGetName_t*)0 && getName(&nm[0], (i32)255, dev) == (i32)0)
            _identity.appendCString(&nm[0]);
        gCu_alloc = _alloc;
        gCu_attr = _attr;
        gCu_ctxCreate = _ctxCreate;
        gCu_ctxSetCurrent = _ctxSetCurrent;
        gCu_deviceGet = _deviceGet;
        gCu_eventCreate = _eventCreate;
        gCu_eventQuery = _eventQuery;
        gCu_eventRecord = _eventRecord;
        gCu_eventSync = _eventSync;
        gCu_free = _free;
        gCu_getFunction = _getFunction;
        gCu_getName = _getName;
        gCu_hostAlloc = _hostAlloc;
        gCu_hostFree = _hostFree;
        gCu_launch = _launch;
        gCu_load = _load;
        gCu_streamCreate = _streamCreate;
        gCu_streamWait = _streamWait;
        gCu_toDevice = _toDevice;
        gCu_toDeviceAsync = _toDeviceAsync;
        gCu_toHostAsync = _toHostAsync;
        _state = (i32)1;
        gParGpuDiscrete = true;     // a CUDA card is across the bus
        if (ParDevice.reporting())
            Log.info("par: CUDA device 0 is %s, %d multiprocessors, %d copy engine(s)", _identity.cString(), _sms, _engines);
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

    // ── tiles (par-tiles-and-devices.md step 2) ────────────────────────────
    //
    // A block whose written buffers all have footprints is run as tiles of
    // the range, each a launch over its own slice with its own copies, so
    // tile t+1's upload and tile t-1's download overlap tile t's kernel. A
    // read-only buffer with no footprint is uploaded whole once (the
    // single-shot path's slot memory); a written one with none keeps the
    // block single shot.

    // Whether the block can be tiled at all: byval (the object and span are
    // launch parameters, so each tile needs no copy of them), every written
    // buffer and global footprinted with k > 0, and every footprinted
    // buffer's element size known.
    static bool tileable(ParLayout* l)
        {
        if (!_tiles || l.byval == (i64)0)
            return false;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] != (i64)0 && (l.bufFpK[i] <= (i64)0 || l.bufElem[i] <= (i64)0))
                return false;
            if (l.bufIn[i] == (i64)0 && l.bufFp[i] == (i64)0)
                return false;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] != (i64)0 && (l.globFpK[i] <= (i64)0 || l.globElem[i] <= (i64)0))
                return false;
            if (l.globIn[i] == (i64)0 && l.globFp[i] == (i64)0)
                return false;
            }
        return true;
        }

    // The bytes a tile of `items` work items moves for footprinted buffers,
    // both ways.
    static i64 tileBytes(ParLayout* l, i64 items)
        {
        i64 b = (i64)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufFp[i] != (i64)0)
                b = b + (l.bufFpK[i] * items + (l.bufFpHi[i] - l.bufFpLo[i])) * l.bufElem[i] * (l.bufIn[i] != (i64)0 ? (i64)1 : (i64)2);
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globFp[i] != (i64)0)
                b = b + (l.globFpK[i] * items + (l.globFpHi[i] - l.globFpLo[i])) * l.globElem[i] *
                        (l.globIn[i] != (i64)0 || (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1) ? (i64)1 : (i64)2);
        return b;
        }

    // Element range [e0, e1) of a footprinted buffer of `len` bytes that the
    // work items [tlo, thi) touch, clipped to the buffer.
    static i64 sliceLo(i64 k, i64 flo, i64 tlo, i64 count)
        {
        i64 e0 = k * tlo + flo;
        if (e0 < (i64)0) e0 = (i64)0;
        if (e0 > count) e0 = count;
        return e0;
        }
    static i64 sliceHi(i64 k, i64 fhi, i64 thi, i64 count)
        {
        i64 e1 = k * (thi - (i64)1) + fhi;
        if (e1 < (i64)0) e1 = (i64)0;
        if (e1 > count) e1 = count;
        return e1;
        }

    // Whether [host, host+bytes) is registered (pinned), registering it when
    // it is a megabyte or more and the driver has the call. A range already
    // inside a registered one counts.
    static bool pinned(pointer host, i64 bytes)
        {
        if (host == (pointer)0 || bytes <= (i64)0)
            return false;
        gParCuRegClock = gParCuRegClock + (i64)1;
        u64 h = (u64)host;
        for (u32 i = (u32)0; i < (u32)PAR_CU_REG; i = i + (u32)1)
            if (gParCuRegHost[i] != (pointer)0 && h >= (u64)gParCuRegHost[i] &&
                h + (u64)bytes <= (u64)gParCuRegHost[i] + (u64)gParCuRegLen[i])
                {
                gParCuRegUsed[i] = gParCuRegClock;
                return true;
                }
        if (bytes < ((i64)1 << (i64)20) || _hostRegister == (cuMemHostRegister_t*)0 ||
            _hostUnregister == (cuMemHostUnregister_t*)0)
            return false;
        u32 slot = (u32)0;
        for (u32 i = (u32)0; i < (u32)PAR_CU_REG; i = i + (u32)1)
            if (gParCuRegHost[i] == (pointer)0 || gParCuRegUsed[i] < gParCuRegUsed[slot])
                slot = i;
        if (gParCuRegHost[slot] != (pointer)0)
            {
            _hostUnregister(gParCuRegHost[slot]);
            gParCuRegHost[slot] = (pointer)0;
            }
        if (_hostRegister(host, (u64)bytes, (u32)1) != (i32)0)   // CU_MEMHOSTREGISTER_PORTABLE: every context
            return false;
        gParCuRegHost[slot] = host;
        gParCuRegLen[slot] = bytes;
        gParCuRegUsed[slot] = gParCuRegClock;
        return true;
        }

    static bool tileSetup(void)
        {
        if (gParCuCompute != (pointer)0)
            return true;
        if (_streamCreate(&gParCuCompute, (u32)1) != (i32)0)   // CU_STREAM_NON_BLOCKING
            return false;
        for (u32 d = (u32)0; d < (u32)PAR_CU_DEPTH; d = d + (u32)1)
            {
            if (_streamCreate(&gParCuCopy[d], (u32)1) != (i32)0)
                return false;
            // CU_EVENT_DISABLE_TIMING (2): these only order work.
            if (_eventCreate(&gParCuUpDone[d], (u32)2) != (i32)0 || _eventCreate(&gParCuKernelDone[d], (u32)2) != (i32)0 ||
                _eventCreate(&gParCuTileDone[d], (u32)2) != (i32)0)
                return false;
            }
        return true;
        }

    // Pinned staging of at least `bytes` for slot d, uploads or downloads.
    static u8* staging(u32 d, bool up, i64 bytes)
        {
        u8* cur = up ? gParCuUp[d] : gParCuDown[d];
        i64 cap = up ? gParCuUpCap[d] : gParCuDownCap[d];
        if (cur != (u8*)0 && cap >= bytes)
            return cur;
        if (cur != (u8*)0)
            _hostFree((pointer)cur);
        pointer p = (pointer)0;
        if (_hostAlloc(&p, (u64)bytes, (u32)0) != (i32)0)
            p = (pointer)0;
        if (up) { gParCuUp[d] = (u8*)p; gParCuUpCap[d] = p != (pointer)0 ? bytes : (i64)0; }
        else { gParCuDown[d] = (u8*)p; gParCuDownCap[d] = p != (pointer)0 ? bytes : (i64)0; }
        return (u8*)p;
        }

    // Run [lo, hi) as tiles. False when something failed before any tile
    // was launched (the caller falls back as for a single shot); once tiles
    // are in flight a failure is reported and false returned after the
    // streams drain, and the host's arrays are then partly written, as a
    // failed single shot leaves them.
    static bool runTiled(ParChunk* proto, pointer fn, ParLayout* l, i64 lo, i64 hi, i64 started)
        {
        i64 n = hi - lo;
        // Tile size: about 8 MB moved per tile, at least 256 work items per
        // multiprocessor so a tile still fills the GPU, and no tiling under
        // three tiles.
        i64 perItem = tileBytes(l, (i64)1) - tileBytes(l, (i64)0);
        if (perItem <= (i64)0)
            return false;
        i64 tileMb = ParDevice.tileMegabytes();
        i64 tile = (tileMb << (i64)20) / perItem;
        i64 floor = (i64)256 * (i64)(_sms > (i32)0 ? _sms : (i32)16);
        if (tile < floor)
            tile = floor;
        // A multiple of 1024 items, so a slice of a buffer whose footprint
        // starts at the item (k = 1, lo = 0) begins on a page: the copy
        // engine moves an aligned slice faster.
        tile = (tile + (i64)1023) & ~(i64)1023;
        if (n < (i64)3 * tile)
            return false;
        i64 ntiles = (n + tile - (i64)1) / tile;
        if (!tileSetup())
            return false;
        u8* obj = proto.objBytes();

        // The un-footprinted read-only buffers and globals: whole, once, in
        // the single-shot path's slot memory. Slots 0 and 1 are the object
        // and span, which go by value.
        u64 whole[52];
        u32 nd = (u32)2;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            whole[nd] = l.bufFp[i] != (i64)0 ? (u64)0
                      : uploadKeeping(nd, *(pointer*)(obj + l.bufOff[i]), l.bufLen[i], true);
            if (l.bufFp[i] == (i64)0 && whole[nd] == (u64)0)
                return false;
            nd = nd + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            whole[nd] = l.globFp[i] != (i64)0 ? (u64)0 : uploadKeeping(nd, l.globPtr[i], l.globLen[i], true);
            if (l.globFp[i] == (i64)0 && whole[nd] == (u64)0)
                return false;
            nd = nd + (u32)1;
            }
        u32 nparams = nd + l.nred;

        // Per in-flight slot: a device slice per footprinted buffer and per
        // reduction, sized for the largest tile.
        i64 sliceMax[32];
        u64 slice[PAR_CU_DEPTH * 32];
        i64 partMax[16];
        u64 partDev[PAR_CU_DEPTH * 16];
        i64 tileItems = tile;
        // The layout plans each tile in turn (its threads and partials);
        // its whole-range plan is put back for the report at the end.
        l.plan(lo, lo + tileItems);
        // Which footprinted buffers are pinned in place: their copies go
        // straight from and to the caller's array; the others go through
        // the slot's staging buffer.
        bool pin[32];
        i64 upMax = (i64)0;
        i64 downMax = (i64)0;
        u32 q = (u32)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            sliceMax[q] = (i64)0;
            pin[q] = false;
            if (l.bufFp[i] != (i64)0)
                {
                sliceMax[q] = (l.bufFpK[i] * tileItems + (l.bufFpHi[i] - l.bufFpLo[i])) * l.bufElem[i];
                pin[q] = pinned(*(pointer*)(obj + l.bufOff[i]), l.bufLen[i]);
                if (!pin[q])
                    {
                    upMax = upMax + sliceMax[q];
                    if (l.bufIn[i] == (i64)0) downMax = downMax + sliceMax[q];
                    }
                }
            q = q + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            sliceMax[q] = (i64)0;
            pin[q] = false;
            if (l.globFp[i] != (i64)0)
                {
                sliceMax[q] = (l.globFpK[i] * tileItems + (l.globFpHi[i] - l.globFpLo[i])) * l.globElem[i];
                pin[q] = pinned(l.globPtr[i], l.globLen[i]);
                if (!pin[q])
                    {
                    upMax = upMax + sliceMax[q];
                    if (l.globIn[i] == (i64)0) downMax = downMax + sliceMax[q];
                    }
                }
            q = q + (u32)1;
            }
        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
            {
            partMax[r] = l.nparts * l.redStride[r];
            downMax = downMax + l.nback * l.redStride[r];
            }
        if (ParDevice.reporting())
            {
            u32 npin = (u32)0;
            u32 nfp = (u32)0;
            for (u32 b = (u32)0; b < q; b = b + (u32)1)
                if (sliceMax[b] > (i64)0)
                    {
                    nfp = nfp + (u32)1;
                    if (pin[b]) npin = npin + (u32)1;
                    }
            Log.info("par: tiles of %ld items (%ld MB each way at most), %ld tiles, %u of %u sliced buffers pinned in place",
                     tile, tileMb, ntiles, npin, nfp);
            }
        bool ok = true;
        for (u32 d = (u32)0; d < (u32)PAR_CU_DEPTH && ok; d = d + (u32)1)
            {
            for (u32 b = (u32)0; b < q; b = b + (u32)1)
                {
                slice[d * (u32)32 + b] = (u64)0;
                if (sliceMax[b] > (i64)0 && _alloc(&slice[d * (u32)32 + b], (u64)sliceMax[b]) != (i32)0)
                    ok = false;
                }
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                {
                partDev[d * (u32)16 + r] = (u64)0;
                if (_alloc(&partDev[d * (u32)16 + r], (u64)partMax[r]) != (i32)0)
                    ok = false;
                }
            if (ok && upMax > (i64)0 && staging(d, true, upMax) == (u8*)0)
                ok = false;
            if (ok && downMax > (i64)0 && staging(d, false, downMax) == (u8*)0)
                ok = false;
            }
        if (!ok)
            {
            for (u32 d = (u32)0; d < (u32)PAR_CU_DEPTH; d = d + (u32)1)
                {
                for (u32 b = (u32)0; b < q; b = b + (u32)1)
                    if (slice[d * (u32)32 + b] != (u64)0) _free(slice[d * (u32)32 + b]);
                for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                    if (partDev[d * (u32)16 + r] != (u64)0) _free(partDev[d * (u32)16 + r]);
                }
            return false;
            }

        // Every tile is launched from the object as it was before any tile's
        // partials were folded into it: the kernel's threads start their
        // reductions from the object's fields, as the single shot does once.
        u8* snap = (u8*)malloc((u64)l.size);
        if (snap == (u8*)0)
            ok = false;
        else
            memcpy((pointer)snap, (pointer)obj, (u64)l.size);
        i64 gpuStart = ParDevice.nowUs();
        i64 span[PAR_CU_DEPTH * 3];
        u64 dev[PAR_CU_DEPTH * 52];
        pointer params[PAR_CU_DEPTH * 52];
        // What each in-flight tile is, for its completion: its range and
        // where its downloads went in the staging buffer.
        i64 tLo[PAR_CU_DEPTH];
        i64 tHi[PAR_CU_DEPTH];
        bool launched = false;
        for (i64 t = (i64)0; t < ntiles + (i64)PAR_CU_DEPTH && ok; t = t + (i64)1)
            {
            u32 d = (u32)(t % (i64)PAR_CU_DEPTH);
            // Complete the tile that used this slot PAR_CU_DEPTH tiles ago, in
            // tile order: its downloads to the host, its partials folded.
            if (t >= (i64)PAR_CU_DEPTH)
                {
                ok = _eventSync(gParCuTileDone[d]) == (i32)0;
                if (ok)
                    {
                    i64 clo = tLo[d];
                    i64 chi = tHi[d];
                    u8* down = gParCuDown[d];
                    i64 at = (i64)0;
                    u32 b = (u32)0;
                    for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                        {
                        if (l.bufFp[i] != (i64)0 && l.bufIn[i] == (i64)0)
                            {
                            i64 count = l.bufLen[i] / l.bufElem[i];
                            i64 e0 = sliceLo(l.bufFpK[i], l.bufFpLo[i], clo, count);
                            i64 e1 = sliceHi(l.bufFpK[i], l.bufFpHi[i], chi, count);
                            i64 bytes = (e1 - e0) * l.bufElem[i];
                            if (bytes > (i64)0 && !pin[b])
                                {
                                memcpy((pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]), (pointer)(down + at), (u64)bytes);
                                at = at + bytes;
                                }
                            }
                        b = b + (u32)1;
                        }
                    for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                        {
                        if (l.globFp[i] != (i64)0 && l.globIn[i] == (i64)0)
                            {
                            i64 count = l.globLen[i] / l.globElem[i];
                            i64 e0 = sliceLo(l.globFpK[i], l.globFpLo[i], clo, count);
                            i64 e1 = sliceHi(l.globFpK[i], l.globFpHi[i], chi, count);
                            i64 bytes = (e1 - e0) * l.globElem[i];
                            if (bytes > (i64)0 && !pin[b])
                                {
                                memcpy((pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]), (pointer)(down + at), (u64)bytes);
                                at = at + bytes;
                                }
                            }
                        b = b + (u32)1;
                        }
                    if (l.nred > (u32)0)
                        {
                        l.plan(clo, chi);
                        u8* parts[16];
                        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                            {
                            parts[r] = down + at;
                            at = at + l.nback * l.redStride[r];
                            }
                        l.fold(proto, &parts[0]);
                        }
                    }
                }
            if (t >= ntiles || !ok)
                continue;
            i64 tlo = lo + t * tile;
            i64 thi = tlo + tile;
            if (thi > hi) thi = hi;
            tLo[d] = tlo;
            tHi[d] = thi;
            l.plan(tlo, thi);
            span[d * (u32)3 + 0] = tlo;
            span[d * (u32)3 + 1] = thi;
            span[d * (u32)3 + 2] = l.per;
            // Stage the tile's inputs into pinned memory and start them up
            // on the slot's copy stream; a footprinted buffer's kernel
            // parameter is its slice less its first element's offset, so
            // the kernel's index i still lands on element i.
            u8* up = gParCuUp[d];
            i64 at = (i64)0;
            u32 b = (u32)0;
            dev[d * (u32)52 + 0] = (u64)1;
            dev[d * (u32)52 + 1] = (u64)1;
            u32 pi = (u32)2;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufFp[i] != (i64)0)
                    {
                    i64 count = l.bufLen[i] / l.bufElem[i];
                    i64 e0 = sliceLo(l.bufFpK[i], l.bufFpLo[i], tlo, count);
                    i64 e1 = sliceHi(l.bufFpK[i], l.bufFpHi[i], thi, count);
                    i64 bytes = (e1 - e0) * l.bufElem[i];
                    pointer src = (pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]);
                    if (bytes > (i64)0 && pin[b])
                        {
                        if (_toDeviceAsync(slice[d * (u32)32 + b], src, (u64)bytes, gParCuCopy[d]) != (i32)0)
                            ok = false;
                        }
                    else if (bytes > (i64)0)
                        {
                        memcpy((pointer)(up + at), src, (u64)bytes);
                        if (_toDeviceAsync(slice[d * (u32)32 + b], (pointer)(up + at), (u64)bytes, gParCuCopy[d]) != (i32)0)
                            ok = false;
                        at = at + bytes;
                        }
                    dev[d * (u32)52 + pi] = slice[d * (u32)32 + b] - (u64)(e0 * l.bufElem[i]);
                    }
                else
                    dev[d * (u32)52 + pi] = whole[pi];
                pi = pi + (u32)1;
                b = b + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globFp[i] != (i64)0)
                    {
                    i64 count = l.globLen[i] / l.globElem[i];
                    i64 e0 = sliceLo(l.globFpK[i], l.globFpLo[i], tlo, count);
                    i64 e1 = sliceHi(l.globFpK[i], l.globFpHi[i], thi, count);
                    i64 bytes = (e1 - e0) * l.globElem[i];
                    // A slice the tile's items overwrite whole (the body
                    // writes every element it touches, and the footprint has
                    // no gaps) is not uploaded: the kernel fills it.
                    if (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1)
                        bytes = (i64)0;
                    pointer src = (pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]);
                    if (bytes > (i64)0 && pin[b])
                        {
                        if (_toDeviceAsync(slice[d * (u32)32 + b], src, (u64)bytes, gParCuCopy[d]) != (i32)0)
                            ok = false;
                        }
                    else if (bytes > (i64)0)
                        {
                        memcpy((pointer)(up + at), src, (u64)bytes);
                        if (_toDeviceAsync(slice[d * (u32)32 + b], (pointer)(up + at), (u64)bytes, gParCuCopy[d]) != (i32)0)
                            ok = false;
                        at = at + bytes;
                        }
                    dev[d * (u32)52 + pi] = slice[d * (u32)32 + b] - (u64)(e0 * l.globElem[i]);
                    }
                else
                    dev[d * (u32)52 + pi] = whole[pi];
                pi = pi + (u32)1;
                b = b + (u32)1;
                }
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                {
                dev[d * (u32)52 + pi] = partDev[d * (u32)16 + r];
                pi = pi + (u32)1;
                }
            if (!ok)
                break;
            // The kernel, on the compute stream, after this slot's uploads.
            if (_eventRecord(gParCuUpDone[d], gParCuCopy[d]) != (i32)0 ||
                _streamWait(gParCuCompute, gParCuUpDone[d], (u32)0) != (i32)0)
                { ok = false; break; }
            for (u32 i = (u32)0; i < nparams; i = i + (u32)1)
                params[d * (u32)52 + i] = (pointer)&dev[d * (u32)52 + i];
            params[d * (u32)52 + 0] = (pointer)snap;
            params[d * (u32)52 + 1] = (pointer)&span[d * (u32)3 + 0];
            u32 group = (u32)256;
            u32 grid = (u32)((l.threads + (i64)group - (i64)1) / (i64)group);
            if (_launch(fn, grid, (u32)1, (u32)1, group, (u32)1, (u32)1, (u32)0, gParCuCompute, &params[d * (u32)52 + 0],
                        (pointer*)0) != (i32)0)
                { ok = false; break; }
            launched = true;
            // Its downloads, on the slot's copy stream, after the kernel.
            if (_eventRecord(gParCuKernelDone[d], gParCuCompute) != (i32)0 ||
                _streamWait(gParCuCopy[d], gParCuKernelDone[d], (u32)0) != (i32)0)
                { ok = false; break; }
            u8* down = gParCuDown[d];
            at = (i64)0;
            b = (u32)0;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufFp[i] != (i64)0 && l.bufIn[i] == (i64)0)
                    {
                    i64 count = l.bufLen[i] / l.bufElem[i];
                    i64 e0 = sliceLo(l.bufFpK[i], l.bufFpLo[i], tlo, count);
                    i64 e1 = sliceHi(l.bufFpK[i], l.bufFpHi[i], thi, count);
                    i64 bytes = (e1 - e0) * l.bufElem[i];
                    pointer dst = pin[b] ? (pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]) : (pointer)(down + at);
                    if (bytes > (i64)0 && _toHostAsync(dst, slice[d * (u32)32 + b], (u64)bytes, gParCuCopy[d]) != (i32)0)
                        ok = false;
                    if (!pin[b]) at = at + bytes;
                    }
                b = b + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globFp[i] != (i64)0 && l.globIn[i] == (i64)0)
                    {
                    i64 count = l.globLen[i] / l.globElem[i];
                    i64 e0 = sliceLo(l.globFpK[i], l.globFpLo[i], tlo, count);
                    i64 e1 = sliceHi(l.globFpK[i], l.globFpHi[i], thi, count);
                    i64 bytes = (e1 - e0) * l.globElem[i];
                    pointer dst = pin[b] ? (pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]) : (pointer)(down + at);
                    if (bytes > (i64)0 && _toHostAsync(dst, slice[d * (u32)32 + b], (u64)bytes, gParCuCopy[d]) != (i32)0)
                        ok = false;
                    if (!pin[b]) at = at + bytes;
                    }
                b = b + (u32)1;
                }
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                {
                i64 bytes = l.nback * l.redStride[r];
                if (_toHostAsync((pointer)(down + at), partDev[d * (u32)16 + r], (u64)bytes, gParCuCopy[d]) != (i32)0)
                    ok = false;
                at = at + bytes;
                }
            if (_eventRecord(gParCuTileDone[d], gParCuCopy[d]) != (i32)0)
                ok = false;
            }
        // Nothing of the tiles' device memory is kept: the slices are per
        // run (the staging and streams stay).
        if (!ok)
            {
            _sync();
            Log.error("par: the GPU run failed, running on the CPU");
            }
        for (u32 d = (u32)0; d < (u32)PAR_CU_DEPTH; d = d + (u32)1)
            {
            for (u32 b = (u32)0; b < q; b = b + (u32)1)
                if (slice[d * (u32)32 + b] != (u64)0) _free(slice[d * (u32)32 + b]);
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                if (partDev[d * (u32)16 + r] != (u64)0) _free(partDev[d * (u32)16 + r]);
            }
        if (snap != (u8*)0)
            free((pointer)snap);
        if (!ok)
            return false;
        l.plan(lo, hi);
        l.tiles = ntiles;
        ParDevice.ranOnGpu(proto, l, ParDevice.nowUs() - started, ParDevice.nowUs() - gpuStart);
        return true;
        }

    // Run [lo, hi) of the block on the GPU. False when the block cannot go
    // there (no kernel, a buffer of unknown size, no device): the caller then
    // runs it on the CPU, which gives the same answer.
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        // The PTX section, or none (SPIR-V alone, say: that is for Vulkan,
        // which Par tries next).
        src = ParDevice.sectionOf(src, "ptx", true);
        if (src == (u8*)0)
            return false;
        if (!start())
            return ParDevice.cpu("there is no CUDA device");
        // The workers' contexts may have been current since (their holds):
        // this path's handles belong to the first device's.
        if (_ctxSetCurrent != (cuCtxSetCurrent_t*)0)
            _ctxSetCurrent(_ctx);
        pointer fn = function(src);
        if (fn == (pointer)0)
            return ParDevice.cpu("its GPU version did not compile");
        i64 started = ParDevice.nowUs();
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        if (tileable(l) && ParDevice.tilesWanted() && runTiled(proto, fn, l, lo, hi, started))
            return true;
        u8* obj = proto.objBytes();

        // The kernel's parameters, in its order: args, span, buffers,
        // globals, reductions. Each is a device address, passed by pointer.
        i64 span[3];
        span[0] = lo;
        span[1] = hi;
        span[2] = l.per;
        u64 dev[52];
        u32 nd = (u32)0;
        // By value: the launch reads the object and the range from here.
        if (l.byval != (i64)0)
            {
            dev[0] = (u64)1;
            dev[1] = (u64)1;
            nd = (u32)2;
            }
        else
            {
            dev[nd] = upload(nd, (pointer)obj, l.size);
            nd = nd + (u32)1;
            dev[nd] = upload(nd, (pointer)&span[0], (i64)24);
            nd = nd + (u32)1;
            }
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
        if (l.byval != (i64)0)
            {
            params[0] = (pointer)obj;
            params[1] = (pointer)&span[0];
            }
        i64 gpuStart = ParDevice.nowUs();
        i64 gpuUs = (i64)-1;
        if (ok)
            {
            u32 group = (u32)256;
            u32 grid = (u32)((l.threads + (i64)group - (i64)1) / (i64)group);
            ok = _launch(fn, grid, (u32)1, (u32)1, group, (u32)1, (u32)1, (u32)0, (pointer)0, &params[0],
                         (pointer*)0) == (i32)0;
            }

        // The arrays come back; the partials (one per thread, or per
        // workgroup when the kernel reduced on the device) fold in order.
        // No separate cuCtxSynchronize first (bug 645): a copy from the
        // device waits for the kernel, and the extra round trip cost about
        // 30 us a run. A failed kernel's error is sticky, so the first copy
        // after it fails too: every copy is checked, and nothing is folded
        // unless all of them worked. With nothing to copy back, the
        // synchronise stays, so the run is still known to have finished.
        u8* parts[16];
        u32 nparts = (u32)0;
        if (ok)
            {
            u32 copies = (u32)0;
            u32 at = (u32)2;
            for (u32 i = (u32)0; i < l.nbuf && ok; i = i + (u32)1)
                {
                if (l.bufIn[i] == (i64)0)
                    {
                    ok = _toHost(*(pointer*)(obj + l.bufOff[i]), dev[at], (u64)l.bufLen[i]) == (i32)0;
                    copies = copies + (u32)1;
                    }
                at = at + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob && ok; i = i + (u32)1)
                {
                if (l.globIn[i] == (i64)0)
                    {
                    ok = _toHost(l.globPtr[i], dev[at], (u64)l.globLen[i]) == (i32)0;
                    copies = copies + (u32)1;
                    }
                at = at + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nred && ok; i = i + (u32)1)
                {
                i64 bytes = l.nback * l.redStride[i];
                parts[i] = (u8*)malloc((u64)bytes);
                nparts = i + (u32)1;
                ok = _toHost((pointer)parts[i], dev[at], (u64)bytes) == (i32)0;
                copies = copies + (u32)1;
                at = at + (u32)1;
                }
            if (ok && copies == (u32)0)
                ok = _sync() == (i32)0;
            // The kernel and what came back: the copies are what waited for it.
            gpuUs = ParDevice.nowUs() - gpuStart;
            if (ok)
                l.fold(proto, &parts[0]);
            }
        for (u32 i = (u32)0; i < nparts; i = i + (u32)1)
            free((pointer)parts[i]);
        // The device memory stays for the next run (gParCuDev).
        if (!ok)
            {
            Log.error("par: the GPU run failed, running on the CPU");
            return false;
            }
        ParDevice.ranOnGpu(proto, l, ParDevice.nowUs() - started, gpuUs);
        return true;
        }

    // A worker per CUDA device (par-tiles-and-devices.md step 3), each with
    // its own context; XC_PAR_CUDA_DEVICES=0,1 keeps only those ordinals.
    static void addWorkers(Array* into)
        {
        if (!start() || !_tiles || _deviceGetCount == (cuDeviceGetCount_t*)0 || _ctxSetCurrent == (cuCtxSetCurrent_t*)0 ||
            _eventQuery == (cuEventQuery_t*)0)
            return;
        i32 count = (i32)0;
        if (_deviceGetCount(&count) != (i32)0)
            return;
        String* only = Platform.env(String.withCString("XC_PAR_CUDA_DEVICES"));
        for (i32 ord = (i32)0; ord < count; ord = ord + (i32)1)
            {
            if (only.byteLength() > (u32)0)
                {
                bool named = false;
                for (u32 i = (u32)0; i < only.byteLength(); i = i + (u32)1)
                    if (only.byteAt(i) == (u8)('0' + ord))
                        named = true;
                if (!named)
                    continue;
                }
            ParCudaWorker* w = new ParCudaWorker();
            if (w.open(ord))
                into.add((Object*)w);
            }
        _ctxSetCurrent(_ctx);
        }
    }

// One CUDA device as a worker: its context, kernel cache, streams, events
// and staging are its own; the registration cache is shared (portable).
// take() is step 2's per-tile enqueue, poll() its completion, asked rather
// than waited for; prepare() and finish() make and free a run's slices.
class ParCudaWorker : ParWorker
    {
    i32 _ordinal;
    pointer _ctx;
    String* _identity;
    i32 _sms;
    // Kernels compiled on this device.
    pointer _src[64];
    pointer _fn[64];
    u32 _nk;
    // Blocks this device refused (holds memo).
    pointer _refused[64];
    u32 _nrefused;
    // Streams and events, PAR_CU_DEPTH slots.
    pointer _compute;
    pointer _copy[PAR_CU_DEPTH];
    pointer _upDone[PAR_CU_DEPTH];
    pointer _kernelDone[PAR_CU_DEPTH];
    pointer _tileDone[PAR_CU_DEPTH];
    u8* _up[PAR_CU_DEPTH];
    i64 _upCap[PAR_CU_DEPTH];
    u8* _down[PAR_CU_DEPTH];
    i64 _downCap[PAR_CU_DEPTH];
    bool _ready;
    // The run in progress.
    ParChunk* _proto;
    ParLayout* _l;
    pointer _kernel;
    u8* _snap;
    u64 _whole[52];
    i64 _wholeCap[52];      // device memory is kept from run to run and grown
    u32 _nparams;
    u32 _q;                 // sliced buffers + globals
    i64 _sliceMax[32];
    bool _pin[32];
    u64 _slice[PAR_CU_DEPTH * 32];
    i64 _sliceCap[PAR_CU_DEPTH * 32];
    u64 _partDev[PAR_CU_DEPTH * 16];
    i64 _partCap[PAR_CU_DEPTH * 16];
    i64 _tile;
    // In flight: the tile in each slot, taken in ring order.
    ParTile* _slotTile[PAR_CU_DEPTH];
    i64 _tTake[PAR_CU_DEPTH];       // the timeline (XC_PAR_REPORT=2): when the slot's tile was taken
    i64 _tLaunched[PAR_CU_DEPTH];   // and when its launch had been issued
    i64 _span[PAR_CU_DEPTH * 3];
    u64 _dev[PAR_CU_DEPTH * 52];
    pointer _params[PAR_CU_DEPTH * 52];
    u32 _nextSlot;
    u32 _oldest;
    u32 _inFlight;

    bool open(i32 ordinal)
        {
        _ordinal = ordinal;
        i32 dev = (i32)0;
        pointer ctx = (pointer)0;
        if (gCu_deviceGet(&dev, ordinal) != (i32)0 || gCu_ctxCreate(&ctx, (u32)0, dev) != (i32)0)
            return false;
        _ctx = ctx;
        _identity = String.withCString("cuda:");
        u8 nm[256];
        nm[0] = (u8)0;
        if (gCu_getName != (cuDeviceGetName_t*)0 && gCu_getName(&nm[0], (i32)255, dev) == (i32)0)
            _identity.appendCString(&nm[0]);
        i32 sms = (i32)0;
        if (gCu_attr != (cuDeviceGetAttribute_t*)0 && gCu_attr(&sms, (i32)16, dev) == (i32)0)
            _sms = sms;
        if (gCu_streamCreate(&_compute, (u32)1) != (i32)0)
            return false;
        for (u32 d = (u32)0; d < (u32)PAR_CU_DEPTH; d = d + (u32)1)
            {
            if (gCu_streamCreate(&_copy[d], (u32)1) != (i32)0)
                return false;
            if (gCu_eventCreate(&_upDone[d], (u32)2) != (i32)0 || gCu_eventCreate(&_kernelDone[d], (u32)2) != (i32)0 ||
                gCu_eventCreate(&_tileDone[d], (u32)2) != (i32)0)
                return false;
            }
        _ready = true;
        if (ParDevice.reporting())
            Log.info("par: CUDA worker %d is %s, %d multiprocessors", ordinal, _identity.cString(), _sms);
        return true;
        }

    String* identity(void)
        {
        return _identity;
        }
    u32 depth(void)
        {
        return (u32)PAR_CU_DEPTH;
        }
    u8* section(u8* src)
        {
        return ParDevice.sectionOf(src, "ptx", true);
        }
    i64 floor(void)
        {
        return (i64)256 * (i64)(_sms > (i32)0 ? _sms : (i32)16);
        }
    i64 tileItems(ParLayout* l)
        {
        i64 perItem = ParCuda.tileBytes(l, (i64)1) - ParCuda.tileBytes(l, (i64)0);
        if (perItem <= (i64)0)
            return (i64)0;
        return (ParDevice.tileMegabytes() << (i64)20) / perItem;
        }

    // The kernel for a source on this device, compiled once.
    pointer kernel(u8* src)
        {
        for (u32 i = (u32)0; i < _nk; i = i + (u32)1)
            if (_src[i] == (pointer)src)
                return _fn[i];
        pointer mod = (pointer)0;
        pointer fn = (pointer)0;
        u8 log[2048];
        log[0] = (u8)0;
        u32 opts[2];
        opts[0] = (u32)5;
        opts[1] = (u32)6;
        pointer vals[2];
        vals[0] = (pointer)&log[0];
        vals[1] = (pointer)(u64)2048;
        i32 rc = gCu_load(&mod, (pointer)src, (u32)2, (pointer)&opts[0], (pointer)&vals[0]);
        if (rc == (i32)0)
            rc = gCu_getFunction(&fn, mod, "par_kernel");
        if (rc != (i32)0)
            fn = (pointer)0;
        if (_nk < (u32)64)
            {
            _src[_nk] = (pointer)src;
            _fn[_nk] = fn;
            _nk = _nk + (u32)1;
            }
        return fn;
        }

    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        if (!_ready || l == (ParLayout*)0)
            return false;
        src = ParDevice.sectionOf(src, "ptx", true);
        if (src == (u8*)0)
            return false;   // no PTX printed (SPIR-V alone, say)
        for (u32 i = (u32)0; i < _nrefused; i = i + (u32)1)
            if (_refused[i] == (pointer)src)
                return false;
        gCu_ctxSetCurrent(_ctx);
        // The block laid out from this worker's own section (`byval`).
        ParLayout* ml = ParDevice.layout(proto, src, (i64)0, l.n);
        bool ok = ml != (ParLayout*)0 && ParCuda.tileable(ml) && kernel(src) != (pointer)0;
        if (!ok && _nrefused < (u32)64)
            {
            _refused[_nrefused] = (pointer)src;
            _nrefused = _nrefused + (u32)1;
            }
        return ok;
        }

    // Pinned staging of at least `bytes` for slot d.
    u8* staging(u32 d, bool up, i64 bytes)
        {
        u8* cur = up ? _up[d] : _down[d];
        i64 cap = up ? _upCap[d] : _downCap[d];
        if (cur != (u8*)0 && cap >= bytes)
            return cur;
        if (cur != (u8*)0)
            gCu_hostFree((pointer)cur);
        pointer p = (pointer)0;
        if (gCu_hostAlloc(&p, (u64)bytes, (u32)0) != (i32)0)
            p = (pointer)0;
        if (up) { _up[d] = (u8*)p; _upCap[d] = p != (pointer)0 ? bytes : (i64)0; }
        else { _down[d] = (u8*)p; _downCap[d] = p != (pointer)0 ? bytes : (i64)0; }
        return (u8*)p;
        }

    // Device memory of at least `need` bytes at *mem: what is there if it is
    // big enough, else a new allocation (the old one freed).
    bool devBuf(u64* mem, i64* cap, i64 need)
        {
        if (need < (i64)1)
            need = (i64)1;
        if (*mem != (u64)0 && *cap >= need)
            return true;
        if (*mem != (u64)0)
            gCu_free(*mem);
        *mem = (u64)0;
        *cap = (i64)0;
        if (gCu_alloc(mem, (u64)need) != (i32)0)
            return false;
        *cap = need;
        return true;
        }

    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        gCu_ctxSetCurrent(_ctx);
        src = ParDevice.sectionOf(src, "ptx", true);
        if (src == (u8*)0)
            return false;
        _proto = proto;
        _l = ParDevice.layout(proto, src, (i64)0, l.n);
        if (_l == (ParLayout*)0)
            return false;
        l = _l;
        _tile = tile;
        _kernel = kernel(src);
        if (_kernel == (pointer)0)
            return false;
        u8* obj = proto.objBytes();
        _snap = (u8*)malloc((u64)l.size);
        if (_snap == (u8*)0)
            return false;
        memcpy((pointer)_snap, (pointer)obj, (u64)l.size);
        // The un-footprinted read-only buffers and globals, whole, once per
        // device per run.
        u32 nd = (u32)2;
        bool ok = true;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] == (i64)0)
                {
                if (!devBuf(&_whole[nd], &_wholeCap[nd], l.bufLen[i]) ||
                    gCu_toDevice(_whole[nd], *(pointer*)(obj + l.bufOff[i]), (u64)l.bufLen[i]) != (i32)0)
                    ok = false;
                }
            nd = nd + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] == (i64)0)
                {
                if (!devBuf(&_whole[nd], &_wholeCap[nd], l.globLen[i]) ||
                    gCu_toDevice(_whole[nd], l.globPtr[i], (u64)l.globLen[i]) != (i32)0)
                    ok = false;
                }
            nd = nd + (u32)1;
            }
        _nparams = nd + l.nred;
        // Slices per slot, sized for a tile; which buffers are pinned.
        l.plan(0, tile);
        i64 upMax = (i64)0;
        i64 downMax = (i64)0;
        u32 q = (u32)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            _sliceMax[q] = (i64)0;
            _pin[q] = false;
            if (l.bufFp[i] != (i64)0)
                {
                _sliceMax[q] = (l.bufFpK[i] * tile + (l.bufFpHi[i] - l.bufFpLo[i])) * l.bufElem[i];
                _pin[q] = ParCuda.pinned(*(pointer*)(obj + l.bufOff[i]), l.bufLen[i]);
                if (!_pin[q])
                    {
                    upMax = upMax + _sliceMax[q];
                    if (l.bufIn[i] == (i64)0) downMax = downMax + _sliceMax[q];
                    }
                }
            q = q + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            _sliceMax[q] = (i64)0;
            _pin[q] = false;
            if (l.globFp[i] != (i64)0)
                {
                _sliceMax[q] = (l.globFpK[i] * tile + (l.globFpHi[i] - l.globFpLo[i])) * l.globElem[i];
                _pin[q] = ParCuda.pinned(l.globPtr[i], l.globLen[i]);
                if (!_pin[q])
                    {
                    upMax = upMax + _sliceMax[q];
                    if (l.globIn[i] == (i64)0) downMax = downMax + _sliceMax[q];
                    }
                }
            q = q + (u32)1;
            }
        _q = q;
        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
            downMax = downMax + l.nback * l.redStride[r];
        for (u32 d = (u32)0; d < (u32)PAR_CU_DEPTH && ok; d = d + (u32)1)
            {
            for (u32 b = (u32)0; b < q; b = b + (u32)1)
                if (_sliceMax[b] > (i64)0 && !devBuf(&_slice[d * (u32)32 + b], &_sliceCap[d * (u32)32 + b], _sliceMax[b]))
                    ok = false;
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                if (!devBuf(&_partDev[d * (u32)16 + r], &_partCap[d * (u32)16 + r], l.nparts * l.redStride[r]))
                    ok = false;
            if (ok && upMax > (i64)0 && staging(d, true, upMax) == (u8*)0)
                ok = false;
            if (ok && downMax > (i64)0 && staging(d, false, downMax) == (u8*)0)
                ok = false;
            _slotTile[d] = (ParTile*)0;
            }
        _nextSlot = (u32)0;
        _oldest = (u32)0;
        _inFlight = (u32)0;
        if (!ok)
            finish();
        return ok;
        }

    // A run's end: the device memory stays for the next run (an allocation
    // and a free a run were most of a small block's time).
    void finish(void)
        {
        if (_snap != (u8*)0) { free((pointer)_snap); _snap = (u8*)0; }
        _proto = (ParChunk*)0;
        _l = (ParLayout*)0;
        }

    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (_inFlight >= (u32)PAR_CU_DEPTH || _l == (ParLayout*)0)
            return false;
        l = _l;
        gCu_ctxSetCurrent(_ctx);
        u32 d = _nextSlot;
        _tTake[d] = ParDevice.nowUs();
        u8* obj = proto.objBytes();
        i64 tlo = t.lo;
        i64 thi = t.hi;
        l.plan(tlo, thi);
        _span[d * (u32)3 + 0] = tlo;
        _span[d * (u32)3 + 1] = thi;
        _span[d * (u32)3 + 2] = l.per;
        bool ok = true;
        u8* up = _up[d];
        i64 at = (i64)0;
        u32 b = (u32)0;
        _dev[d * (u32)52 + 0] = (u64)1;
        _dev[d * (u32)52 + 1] = (u64)1;
        u32 pi = (u32)2;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] != (i64)0)
                {
                i64 count = l.bufLen[i] / l.bufElem[i];
                i64 e0 = ParCuda.sliceLo(l.bufFpK[i], l.bufFpLo[i], tlo, count);
                i64 e1 = ParCuda.sliceHi(l.bufFpK[i], l.bufFpHi[i], thi, count);
                i64 bytes = (e1 - e0) * l.bufElem[i];
                pointer srcp = (pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]);
                if (bytes > (i64)0 && _pin[b])
                    {
                    if (gCu_toDeviceAsync(_slice[d * (u32)32 + b], srcp, (u64)bytes, _copy[d]) != (i32)0)
                        ok = false;
                    }
                else if (bytes > (i64)0)
                    {
                    memcpy((pointer)(up + at), srcp, (u64)bytes);
                    if (gCu_toDeviceAsync(_slice[d * (u32)32 + b], (pointer)(up + at), (u64)bytes, _copy[d]) != (i32)0)
                        ok = false;
                    at = at + bytes;
                    }
                _dev[d * (u32)52 + pi] = _slice[d * (u32)32 + b] - (u64)(e0 * l.bufElem[i]);
                }
            else
                _dev[d * (u32)52 + pi] = _whole[pi];
            pi = pi + (u32)1;
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] != (i64)0)
                {
                i64 count = l.globLen[i] / l.globElem[i];
                i64 e0 = ParCuda.sliceLo(l.globFpK[i], l.globFpLo[i], tlo, count);
                i64 e1 = ParCuda.sliceHi(l.globFpK[i], l.globFpHi[i], thi, count);
                i64 bytes = (e1 - e0) * l.globElem[i];
                if (l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1)
                    bytes = (i64)0;
                pointer srcp = (pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]);
                if (bytes > (i64)0 && _pin[b])
                    {
                    if (gCu_toDeviceAsync(_slice[d * (u32)32 + b], srcp, (u64)bytes, _copy[d]) != (i32)0)
                        ok = false;
                    }
                else if (bytes > (i64)0)
                    {
                    memcpy((pointer)(up + at), srcp, (u64)bytes);
                    if (gCu_toDeviceAsync(_slice[d * (u32)32 + b], (pointer)(up + at), (u64)bytes, _copy[d]) != (i32)0)
                        ok = false;
                    at = at + bytes;
                    }
                _dev[d * (u32)52 + pi] = _slice[d * (u32)32 + b] - (u64)(e0 * l.globElem[i]);
                }
            else
                _dev[d * (u32)52 + pi] = _whole[pi];
            pi = pi + (u32)1;
            b = b + (u32)1;
            }
        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
            {
            _dev[d * (u32)52 + pi] = _partDev[d * (u32)16 + r];
            pi = pi + (u32)1;
            }
        if (!ok)
            return false;
        if (gCu_eventRecord(_upDone[d], _copy[d]) != (i32)0 || gCu_streamWait(_compute, _upDone[d], (u32)0) != (i32)0)
            return false;
        for (u32 i = (u32)0; i < _nparams; i = i + (u32)1)
            _params[d * (u32)52 + i] = (pointer)&_dev[d * (u32)52 + i];
        _params[d * (u32)52 + 0] = (pointer)_snap;
        _params[d * (u32)52 + 1] = (pointer)&_span[d * (u32)3 + 0];
        u32 group = (u32)256;
        u32 grid = (u32)((l.threads + (i64)group - (i64)1) / (i64)group);
        if (gCu_launch(_kernel, grid, (u32)1, (u32)1, group, (u32)1, (u32)1, (u32)0, _compute, &_params[d * (u32)52 + 0],
                            (pointer*)0) != (i32)0)
            return false;
        _tLaunched[d] = ParDevice.nowUs();
        if (gCu_eventRecord(_kernelDone[d], _compute) != (i32)0 || gCu_streamWait(_copy[d], _kernelDone[d], (u32)0) != (i32)0)
            return false;
        u8* down = _down[d];
        at = (i64)0;
        b = (u32)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] != (i64)0 && l.bufIn[i] == (i64)0)
                {
                i64 count = l.bufLen[i] / l.bufElem[i];
                i64 e0 = ParCuda.sliceLo(l.bufFpK[i], l.bufFpLo[i], tlo, count);
                i64 e1 = ParCuda.sliceHi(l.bufFpK[i], l.bufFpHi[i], thi, count);
                i64 bytes = (e1 - e0) * l.bufElem[i];
                pointer dst = _pin[b] ? (pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]) : (pointer)(down + at);
                if (bytes > (i64)0 && gCu_toHostAsync(dst, _slice[d * (u32)32 + b], (u64)bytes, _copy[d]) != (i32)0)
                    ok = false;
                if (!_pin[b]) at = at + bytes;
                }
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] != (i64)0 && l.globIn[i] == (i64)0)
                {
                i64 count = l.globLen[i] / l.globElem[i];
                i64 e0 = ParCuda.sliceLo(l.globFpK[i], l.globFpLo[i], tlo, count);
                i64 e1 = ParCuda.sliceHi(l.globFpK[i], l.globFpHi[i], thi, count);
                i64 bytes = (e1 - e0) * l.globElem[i];
                pointer dst = _pin[b] ? (pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]) : (pointer)(down + at);
                if (bytes > (i64)0 && gCu_toHostAsync(dst, _slice[d * (u32)32 + b], (u64)bytes, _copy[d]) != (i32)0)
                    ok = false;
                if (!_pin[b]) at = at + bytes;
                }
            b = b + (u32)1;
            }
        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
            {
            i64 bytes = l.nback * l.redStride[r];
            if (gCu_toHostAsync((pointer)(down + at), _partDev[d * (u32)16 + r], (u64)bytes, _copy[d]) != (i32)0)
                ok = false;
            at = at + bytes;
            }
        if (!ok || gCu_eventRecord(_tileDone[d], _copy[d]) != (i32)0)
            return false;
        _slotTile[d] = t;
        t.worker = (ParWorker*)self;
        _nextSlot = (d + (u32)1) % (u32)PAR_CU_DEPTH;
        _inFlight = _inFlight + (u32)1;
        return true;
        }

    // Finish the oldest slot's tile: its unpinned downloads to the host, its
    // partials into a chunk copy.
    ParTile* complete(u32 d)
        {
        ParTile* t = _slotTile[d];
        ParLayout* l = _l;
        u8* obj = _proto.objBytes();
        u8* down = _down[d];
        i64 at = (i64)0;
        u32 b = (u32)0;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufFp[i] != (i64)0 && l.bufIn[i] == (i64)0 && !_pin[b])
                {
                i64 count = l.bufLen[i] / l.bufElem[i];
                i64 e0 = ParCuda.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
                i64 e1 = ParCuda.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
                i64 bytes = (e1 - e0) * l.bufElem[i];
                if (bytes > (i64)0)
                    memcpy((pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]), (pointer)(down + at), (u64)bytes);
                at = at + bytes;
                }
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globFp[i] != (i64)0 && l.globIn[i] == (i64)0 && !_pin[b])
                {
                i64 count = l.globLen[i] / l.globElem[i];
                i64 e0 = ParCuda.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
                i64 e1 = ParCuda.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
                i64 bytes = (e1 - e0) * l.globElem[i];
                if (bytes > (i64)0)
                    memcpy((pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]), (pointer)(down + at), (u64)bytes);
                at = at + bytes;
                }
            b = b + (u32)1;
            }
        if (l.nred > (u32)0)
            {
            l.plan(t.lo, t.hi);
            u8* parts[16];
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                {
                parts[r] = down + at;
                at = at + l.nback * l.redStride[r];
                }
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
        t.done = true;
        _slotTile[d] = (ParTile*)0;
        _oldest = (d + (u32)1) % (u32)PAR_CU_DEPTH;
        _inFlight = _inFlight - (u32)1;
        if (ParDevice.tracing())
            {
            i64 now = ParDevice.nowUs();
            Log.info("par: tile %ld [%ld, %ld) on %s: issue %ld us, done %ld us after taking it",
                     t.index, t.lo, t.hi, _identity.cString(), _tLaunched[d] - _tTake[d], now - _tTake[d]);
            }
        return t;
        }

    ParTile* poll(void)
        {
        if (_inFlight == (u32)0)
            return (ParTile*)0;
        gCu_ctxSetCurrent(_ctx);
        u32 d = _oldest;
        i32 rc = gCu_eventQuery(_tileDone[d]);
        if (rc != (i32)0)
            return (ParTile*)0;   // not ready (600), or an error the drain will see
        return complete(d);
        }

    void drain(void)
        {
        gCu_ctxSetCurrent(_ctx);
        while (_inFlight > (u32)0)
            {
            u32 d = _oldest;
            if (gCu_eventSync(_tileDone[d]) != (i32)0)
                {
                Log.error("par: a CUDA tile failed on %s", _identity.cString());
                _slotTile[d].done = true;
                _slotTile[d] = (ParTile*)0;
                _oldest = (d + (u32)1) % (u32)PAR_CU_DEPTH;
                _inFlight = _inFlight - (u32)1;
                continue;
                }
            complete(d);
            }
        }
    }
