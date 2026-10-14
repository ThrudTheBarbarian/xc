// xcc runtime library.
//
// Copyright (C) 2026 ThrudTheBarbarian@compile-xc.org
//
// This file is part of the xcc runtime library: the code that is combined
// with a program when xcc compiles it. It is free software; you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License as published by the Free Software Foundation, either version 3 of
// the License, or (at your option) any later version.
//
// Under Section 7 of GPL version 3, you are granted additional permissions
// described in the GCC Runtime Library Exception, version 3.1, as published
// by the Free Software Foundation -- see COPYING.RUNTIME in this directory's
// parent.
//
// The effect of that exception is the point: a program compiled by xcc
// contains parts of this file, and the exception is what leaves that program
// under whatever licence its author chooses, including a proprietary one.
//
// This file is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
// FITNESS FOR A PARTICULAR PURPOSE.
// ParVulkan.xc — runs a `par` block on a Vulkan GPU (Linux), for Par.run when
// ParDevice chooses the GPU.
//
// The compiler gives each block its kernel as a SPIR-V module (gpuSource()),
// under the same header line as the Metal and CUDA runtimes read
// (ParDevice.xc), followed by ` spirv=<words>`, a NUL, padding to four bytes
// and the module. libvulkan.so.1 is loaded when a block first asks for the
// GPU and its entry points are looked up by name, so a machine without a
// Vulkan driver runs every block on the CPU. Loading a library needs the
// dynamic glibc link (xcc -dynamic); a static program runs blocks on the CPU.
//
// The kernel's interface (par-spirv-wgsl.md): binding 0 the block object,
// bindings 1.. the captured arrays, globals and reduction partials in the
// header's order, push constants lo / hi / per. Buffers are host-visible and
// coherent: copied in, one dispatch of 64-wide groups, copied back, partials
// folded in thread order (ParLayout.fold).
//
// Vulkan structures are filled as bytes at their C offsets (x86-64), which
// keeps this file free of a header and of any layout guesswork.
//
// XC_PAR_VULKAN_DEVICE=<n> picks the n-th Vulkan device; by default the first
// discrete GPU, else the first integrated one, else the first of any kind.
#import "ParDevice.xc"
#import "ParWorker.xc"
#define PAR_VK_DEPTH 3
#import "ParSoftFloat.xc"   // correctly rounded division and sqrt for accuracy blocks

// The Vulkan loader: vulkan-1.dll on Windows, libvulkan.so on Android, and
// libvulkan.so.1 on Linux, where only a dynamically linked program can load it.
#if ARCH_win64
pointer LoadLibraryA(u8* name);
pointer GetProcAddress(pointer module, u8* name);
#elif LINK_DYNAMIC || PLATFORM_android
pointer dlopen(u8* path, i32 mode);
pointer dlsym(pointer handle, u8* name);
#endif
pointer malloc(u64 n);
void free(pointer p);
pointer calloc(u64 n, u64 size);
pointer memcpy(pointer dst, pointer src, u64 n);
pointer memset(pointer dst, i32 c, u64 n);
u8* getenv(u8* name);

typedef i32 vkCreateInstance_t(pointer info, pointer alloc, pointer* out);
typedef i32 vkEnumeratePhysicalDevices_t(pointer inst, u32* count, pointer* devices);
typedef void vkGetPhysicalDeviceProperties_t(pointer pd, pointer props);
typedef void vkGetPhysicalDeviceFeatures_t(pointer pd, pointer feats);
typedef void vkGetPhysicalDeviceMemoryProperties_t(pointer pd, pointer props);
typedef void vkGetPhysicalDeviceQueueFamilyProperties_t(pointer pd, u32* count, pointer props);
typedef i32 vkCreateDevice_t(pointer pd, pointer info, pointer alloc, pointer* out);
typedef i32 vkEnumerateDeviceExtensionProperties_t(pointer pd, u8* layer, u32* count, pointer props);
typedef pointer vkGetDeviceProcAddr_t(pointer dev, u8* name);
// VK_EXT_external_memory_host: a `simd:` block imported as the buffer's memory.
typedef i32 vkGetMemoryHostPointerPropertiesEXT_t(pointer dev, u32 handleType, pointer host, pointer props);
typedef void vkGetDeviceQueue_t(pointer dev, u32 family, u32 index, pointer* out);
typedef i32 vkCreateBuffer_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef void vkDestroyBuffer_t(pointer dev, u64 buf, pointer alloc);
typedef void vkGetBufferMemoryRequirements_t(pointer dev, u64 buf, pointer reqs);
typedef i32 vkAllocateMemory_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef void vkFreeMemory_t(pointer dev, u64 mem, pointer alloc);
typedef i32 vkBindBufferMemory_t(pointer dev, u64 buf, u64 mem, u64 offset);
typedef i32 vkMapMemory_t(pointer dev, u64 mem, u64 offset, u64 size, u32 flags, pointer* out);
typedef i32 vkCreateDescriptorSetLayout_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef i32 vkCreatePipelineLayout_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef i32 vkCreateShaderModule_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef i32 vkCreateComputePipelines_t(pointer dev, u64 cache, u32 n, pointer infos, pointer alloc, u64* out);
typedef i32 vkCreateDescriptorPool_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef void vkDestroyDescriptorPool_t(pointer dev, u64 pool, pointer alloc);
typedef i32 vkAllocateDescriptorSets_t(pointer dev, pointer info, u64* out);
typedef void vkUpdateDescriptorSets_t(pointer dev, u32 nw, pointer writes, u32 nc, pointer copies);
typedef i32 vkCreateCommandPool_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef i32 vkAllocateCommandBuffers_t(pointer dev, pointer info, pointer* out);
typedef i32 vkBeginCommandBuffer_t(pointer cb, pointer info);
typedef i32 vkEndCommandBuffer_t(pointer cb);
typedef i32 vkResetCommandBuffer_t(pointer cb, u32 flags);
typedef void vkCmdBindPipeline_t(pointer cb, u32 point, u64 pipeline);
typedef void vkCmdBindDescriptorSets_t(pointer cb, u32 point, u64 layout, u32 first, u32 n, u64* sets, u32 nd,
                                       pointer dyn);
typedef void vkCmdPushConstants_t(pointer cb, u64 layout, u32 stages, u32 offset, u32 size, pointer values);
typedef void vkCmdDispatch_t(pointer cb, u32 x, u32 y, u32 z);
typedef void vkCmdCopyBuffer_t(pointer cb, u64 src, u64 dst, u32 n, pointer regions);
typedef void vkCmdPipelineBarrier_t(pointer cb, u32 srcStages, u32 dstStages, u32 deps, u32 nm, pointer mem,
                                    u32 nb, pointer bufs, u32 ni, pointer imgs);
typedef i32 vkCreateFence_t(pointer dev, pointer info, pointer alloc, u64* out);
typedef void vkDestroyFence_t(pointer dev, u64 fence, pointer alloc);
typedef i32 vkQueueSubmit_t(pointer q, u32 n, pointer submits, u64 fence);
typedef i32 vkWaitForFences_t(pointer dev, u32 n, u64* fences, u32 all, u64 timeout);
typedef i32 vkGetFenceStatus_t(pointer dev, u64 fence);
typedef i32 vkResetFences_t(pointer dev, u32 n, u64* fences);
typedef i32 vkResetCommandBuffer_t(u64 cb, u32 flags);

// The pipelines made so far: each gpuSource() pointer, its pipeline, layout
// and number of bindings (0 when it did not build).
pointer gParVkSrc[64];
u64 gParVkPipe[64];
// The fold entry point's own pipeline (bug 645), from the same module: 0 when
// the kernel has none. It is dispatched after the kernel to combine the
// workgroups' partials on the device.
u64 gParVkFold[64];
u64 gParVkLayout[64];
u64 gParVkSetLayout[64];
u32 gParVkBindings[64];
u32 gParVkKernels;
// One descriptor pool, descriptor set and command buffer PER SLOT, kept across
// runs: creating them a run was the bulk of the per-run host cost.
u64 gParVkDpool[64];
u64 gParVkDset[64];
u64 gParVkCb[64];

// The buffers of the last runs, by binding slot, kept for the next: a block
// run again (or another of the same shape) reuses them where they are big
// enough, as allocating GPU memory costs more than most blocks' work. Host
// buffer, its memory and mapping; the device copy and its memory (discrete
// GPUs); the size they hold.
u64 gParVkBuf[49];
u64 gParVkMem[49];
u8* gParVkMap[49];
u64 gParVkDev[49];
u64 gParVkDMem[49];
i64 gParVkCap[49];

// Little-endian stores into a structure's bytes.
void _vk32(u8* b, u32 at, u32 v)
    {
    *(u32*)(pointer)(b + at) = v;
    }

void _vk64(u8* b, u32 at, u64 v)
    {
    *(u64*)(pointer)(b + at) = v;
    }

void _vkp(u8* b, u32 at, pointer v)
    {
    *(pointer*)(pointer)(b + at) = v;
    }

// The entry points, device and queue, for the worker below (a class's static
// ivars are its own).
vkCreateBuffer_t* gVk_createBuffer;
vkDestroyBuffer_t* gVk_destroyBuffer;
vkGetBufferMemoryRequirements_t* gVk_bufferReqs;
vkAllocateMemory_t* gVk_allocate;
vkFreeMemory_t* gVk_freeMemory;
vkBindBufferMemory_t* gVk_bind;
vkMapMemory_t* gVk_map;
vkCreateDescriptorPool_t* gVk_createPool;
vkDestroyDescriptorPool_t* gVk_destroyPool;
vkAllocateDescriptorSets_t* gVk_allocateSets;
vkUpdateDescriptorSets_t* gVk_updateSets;
vkAllocateCommandBuffers_t* gVk_allocateCommands;
vkBeginCommandBuffer_t* gVk_begin;
vkEndCommandBuffer_t* gVk_end;
vkCmdBindPipeline_t* gVk_bindPipeline;
vkCmdBindDescriptorSets_t* gVk_bindSets;
vkCmdPushConstants_t* gVk_push;
vkCmdDispatch_t* gVk_dispatch;
vkCmdCopyBuffer_t* gVk_copy;
vkCmdPipelineBarrier_t* gVk_barrier;
vkCreateFence_t* gVk_createFence;
vkDestroyFence_t* gVk_destroyFence;
vkQueueSubmit_t* gVk_submit;
vkWaitForFences_t* gVk_wait;
vkResetFences_t* gVk_resetFences;
vkResetCommandBuffer_t* gVk_resetCmd;
vkGetFenceStatus_t* gVk_fenceStatus;
pointer gVkDev;
pointer gVkQueue;
u64 gVkCmdPool;
bool gVkDiscrete;
// An integrated GPU whose driver imports host memory (VK_EXT_external_memory_host):
// a `simd:` block is bound where it lies, with no copy either way.
bool gVkHostImport;
vkGetMemoryHostPointerPropertiesEXT_t* gVk_hostPtrProps;
pointer gParVkHost[49];     // the `simd:` block binding slot i imports, or 0

class ParVulkan
    {
    static i32 _state;          // 0 not tried, 1 ready, 2 no driver or no GPU
    static pointer _dev;
    static pointer _queue;
    static u32 _family;
    static u64 _cmdPool;
    static u8* _memProps;       // VkPhysicalDeviceMemoryProperties (520 bytes)
    static vkGetMemoryHostPointerPropertiesEXT_t* _hostPtrProps;
    static bool _hostImport;    // integrated, and the driver imports host memory
    static vkCreateBuffer_t* _createBuffer;
    static vkDestroyBuffer_t* _destroyBuffer;
    static vkGetBufferMemoryRequirements_t* _bufferReqs;
    static vkAllocateMemory_t* _allocate;
    static vkFreeMemory_t* _freeMemory;
    static vkBindBufferMemory_t* _bind;
    static vkMapMemory_t* _map;
    static vkCreateDescriptorSetLayout_t* _createSetLayout;
    static vkCreatePipelineLayout_t* _createLayout;
    static vkCreateShaderModule_t* _createModule;
    static vkCreateComputePipelines_t* _createPipelines;
    static vkCreateDescriptorPool_t* _createPool;
    static vkDestroyDescriptorPool_t* _destroyPool;
    static vkAllocateDescriptorSets_t* _allocateSets;
    static vkUpdateDescriptorSets_t* _updateSets;
    static vkCreateCommandPool_t* _createCommandPool;
    static vkAllocateCommandBuffers_t* _allocateCommands;
    static vkBeginCommandBuffer_t* _begin;
    static vkEndCommandBuffer_t* _end;
    static vkCmdBindPipeline_t* _bindPipeline;
    static vkCmdBindDescriptorSets_t* _bindSets;
    static vkCmdPushConstants_t* _push;
    static vkCmdDispatch_t* _dispatch;
    static vkCmdCopyBuffer_t* _copy;
    static vkCmdPipelineBarrier_t* _barrier;
    static bool _discrete;      // the kernel's buffers in the GPU's memory, copied through staging
    static String* _identity;   // the chosen device, for auto's hardware key (ParDevice)
    static vkCreateFence_t* _createFence;
    static vkDestroyFence_t* _destroyFence;
    static vkQueueSubmit_t* _submit;
    static vkWaitForFences_t* _wait;
    static vkResetFences_t* _resetFences;
    static u64 _fence;          // one fence, reset and reused: a create and a destroy a run was latency
    static vkResetCommandBuffer_t* _resetCmd;

#if ARCH_win64 || LINK_DYNAMIC || PLATFORM_android
    static pointer _lib;

    static pointer fn(u8* name)
        {
#if ARCH_win64
        return GetProcAddress(_lib, name);
#else
        return dlsym(_lib, name);
#endif
        }
#endif

    // The GPU, for the hardware key auto's learned choices are kept under
    // (ParDevice), or "" when there is none.
    static String* identity(void)
        {
        if (!start() || _identity == (String*)0)
            return String.withCString("");
        return _identity;
        }

    static bool start(void)
        {
        if (_state != (i32)0)
            return _state == (i32)1;
        _state = (i32)2;
#if ARCH_win64 || LINK_DYNAMIC || PLATFORM_android
#if ARCH_win64
        _lib = LoadLibraryA("vulkan-1.dll");
#elif PLATFORM_android
        _lib = dlopen("libvulkan.so", (i32)2);     // RTLD_NOW
#else
        _lib = dlopen("libvulkan.so.1", (i32)2);   // RTLD_NOW
#endif
        if (_lib == (pointer)0)
            return false;
        vkCreateInstance_t* createInstance = (vkCreateInstance_t*)fn("vkCreateInstance");
        vkEnumeratePhysicalDevices_t* enumerate = (vkEnumeratePhysicalDevices_t*)fn("vkEnumeratePhysicalDevices");
        vkGetPhysicalDeviceProperties_t* props = (vkGetPhysicalDeviceProperties_t*)fn("vkGetPhysicalDeviceProperties");
        vkGetPhysicalDeviceFeatures_t* feats = (vkGetPhysicalDeviceFeatures_t*)fn("vkGetPhysicalDeviceFeatures");
        vkGetPhysicalDeviceMemoryProperties_t* memProps =
            (vkGetPhysicalDeviceMemoryProperties_t*)fn("vkGetPhysicalDeviceMemoryProperties");
        vkGetPhysicalDeviceQueueFamilyProperties_t* families =
            (vkGetPhysicalDeviceQueueFamilyProperties_t*)fn("vkGetPhysicalDeviceQueueFamilyProperties");
        vkCreateDevice_t* createDevice = (vkCreateDevice_t*)fn("vkCreateDevice");
        vkGetDeviceQueue_t* getQueue = (vkGetDeviceQueue_t*)fn("vkGetDeviceQueue");
        _createBuffer = (vkCreateBuffer_t*)fn("vkCreateBuffer");
        _destroyBuffer = (vkDestroyBuffer_t*)fn("vkDestroyBuffer");
        _bufferReqs = (vkGetBufferMemoryRequirements_t*)fn("vkGetBufferMemoryRequirements");
        _allocate = (vkAllocateMemory_t*)fn("vkAllocateMemory");
        _freeMemory = (vkFreeMemory_t*)fn("vkFreeMemory");
        _bind = (vkBindBufferMemory_t*)fn("vkBindBufferMemory");
        _map = (vkMapMemory_t*)fn("vkMapMemory");
        _createSetLayout = (vkCreateDescriptorSetLayout_t*)fn("vkCreateDescriptorSetLayout");
        _createLayout = (vkCreatePipelineLayout_t*)fn("vkCreatePipelineLayout");
        _createModule = (vkCreateShaderModule_t*)fn("vkCreateShaderModule");
        _createPipelines = (vkCreateComputePipelines_t*)fn("vkCreateComputePipelines");
        _createPool = (vkCreateDescriptorPool_t*)fn("vkCreateDescriptorPool");
        _destroyPool = (vkDestroyDescriptorPool_t*)fn("vkDestroyDescriptorPool");
        _allocateSets = (vkAllocateDescriptorSets_t*)fn("vkAllocateDescriptorSets");
        _updateSets = (vkUpdateDescriptorSets_t*)fn("vkUpdateDescriptorSets");
        _createCommandPool = (vkCreateCommandPool_t*)fn("vkCreateCommandPool");
        _allocateCommands = (vkAllocateCommandBuffers_t*)fn("vkAllocateCommandBuffers");
        _begin = (vkBeginCommandBuffer_t*)fn("vkBeginCommandBuffer");
        _end = (vkEndCommandBuffer_t*)fn("vkEndCommandBuffer");
        _bindPipeline = (vkCmdBindPipeline_t*)fn("vkCmdBindPipeline");
        _bindSets = (vkCmdBindDescriptorSets_t*)fn("vkCmdBindDescriptorSets");
        _push = (vkCmdPushConstants_t*)fn("vkCmdPushConstants");
        _dispatch = (vkCmdDispatch_t*)fn("vkCmdDispatch");
        _copy = (vkCmdCopyBuffer_t*)fn("vkCmdCopyBuffer");
        _barrier = (vkCmdPipelineBarrier_t*)fn("vkCmdPipelineBarrier");
        _createFence = (vkCreateFence_t*)fn("vkCreateFence");
        _destroyFence = (vkDestroyFence_t*)fn("vkDestroyFence");
        _submit = (vkQueueSubmit_t*)fn("vkQueueSubmit");
        _wait = (vkWaitForFences_t*)fn("vkWaitForFences");
        _resetFences = (vkResetFences_t*)fn("vkResetFences");
        _resetCmd = (vkResetCommandBuffer_t*)fn("vkResetCommandBuffer");
        if (createInstance == (vkCreateInstance_t*)0 || enumerate == (vkEnumeratePhysicalDevices_t*)0 ||
            props == (vkGetPhysicalDeviceProperties_t*)0 || feats == (vkGetPhysicalDeviceFeatures_t*)0 ||
            memProps == (vkGetPhysicalDeviceMemoryProperties_t*)0 ||
            families == (vkGetPhysicalDeviceQueueFamilyProperties_t*)0 || createDevice == (vkCreateDevice_t*)0 ||
            getQueue == (vkGetDeviceQueue_t*)0 || _createBuffer == (vkCreateBuffer_t*)0 ||
            _destroyBuffer == (vkDestroyBuffer_t*)0 || _bufferReqs == (vkGetBufferMemoryRequirements_t*)0 ||
            _allocate == (vkAllocateMemory_t*)0 || _freeMemory == (vkFreeMemory_t*)0 ||
            _bind == (vkBindBufferMemory_t*)0 || _map == (vkMapMemory_t*)0 ||
            _createSetLayout == (vkCreateDescriptorSetLayout_t*)0 || _createLayout == (vkCreatePipelineLayout_t*)0 ||
            _createModule == (vkCreateShaderModule_t*)0 || _createPipelines == (vkCreateComputePipelines_t*)0 ||
            _createPool == (vkCreateDescriptorPool_t*)0 || _destroyPool == (vkDestroyDescriptorPool_t*)0 ||
            _allocateSets == (vkAllocateDescriptorSets_t*)0 || _updateSets == (vkUpdateDescriptorSets_t*)0 ||
            _createCommandPool == (vkCreateCommandPool_t*)0 || _allocateCommands == (vkAllocateCommandBuffers_t*)0 ||
            _begin == (vkBeginCommandBuffer_t*)0 || _end == (vkEndCommandBuffer_t*)0 ||
            _bindPipeline == (vkCmdBindPipeline_t*)0 || _bindSets == (vkCmdBindDescriptorSets_t*)0 ||
            _push == (vkCmdPushConstants_t*)0 || _dispatch == (vkCmdDispatch_t*)0 ||
            _createFence == (vkCreateFence_t*)0 || _destroyFence == (vkDestroyFence_t*)0 ||
            _submit == (vkQueueSubmit_t*)0 || _wait == (vkWaitForFences_t*)0)
            return false;

        // An instance for Vulkan 1.3 (SPIR-V 1.6).
        u8 app[48];
        u8 ici[64];
        memset((pointer)&app[0], (i32)0, (u64)48);
        memset((pointer)&ici[0], (i32)0, (u64)64);
        _vk32(&app[0], (u32)0, (u32)0);
        _vk32(&app[0], (u32)44, (u32)0x403000);        // VK_API_VERSION_1_3
        _vk32(&ici[0], (u32)0, (u32)1);
        _vkp(&ici[0], (u32)24, (pointer)&app[0]);
        pointer inst = (pointer)0;
        if (createInstance((pointer)&ici[0], (pointer)0, &inst) != (i32)0)
            return false;
        u32 n = (u32)0;
        enumerate(inst, &n, (pointer*)0);
        if (n == (u32)0)
            return false;
        if (n > (u32)16)
            n = (u32)16;
        pointer pds[16];
        enumerate(inst, &n, &pds[0]);

        // The device: XC_PAR_VULKAN_DEVICE, else discrete, else integrated, else the first.
        u8* pp = (u8*)malloc((u64)824);
        i32 pick = (i32)-1;
        String* wantS = Platform.env(String.withCString("XC_PAR_VULKAN_DEVICE"));
        u8* want = wantS.cString();
        if (want != (u8*)0 && want[0] >= (u8)'0' && want[0] <= (u8)'9')
            {
            i32 w = (i32)(want[0] - (u8)'0');
            if (w < (i32)n)
                pick = w;
            }
        for (u32 kind = (u32)2; pick < (i32)0 && kind >= (u32)1; kind = kind - (u32)1)
            for (u32 i = (u32)0; i < n && pick < (i32)0; i = i + (u32)1)
                {
                props(pds[i], (pointer)pp);
                if (*(u32*)(pointer)(pp + 16) == kind)   // 2 discrete, 1 integrated
                    pick = (i32)i;
                }
        if (pick < (i32)0)
            pick = (i32)0;
        pointer pd = pds[pick];
        // A discrete GPU reads host memory across the bus, slowly, and its own
        // memory, where the host can map it at all, is uncached for the host.
        props(pd, (pointer)pp);
        // "vulkan:<deviceName>:<vendorID>:<deviceID>", for auto's hardware key.
        _identity = String.withCString("vulkan:");
        _identity.appendCString(pp + 20);
        _identity.appendFormat(":%x:%x", *(u32*)(pointer)(pp + 8), *(u32*)(pointer)(pp + 12));
        _discrete = *(u32*)(pointer)(pp + 16) == (u32)2 && _copy != (vkCmdCopyBuffer_t*)0 &&
                    _barrier != (vkCmdPipelineBarrier_t*)0;
        free((pointer)pp);

        // 64-bit integers are required (lo and hi); doubles are enabled where the device has them.
        u8* has = (u8*)calloc((u64)1, (u64)220);
        feats(pd, (pointer)has);
        if (*(u32*)(pointer)(has + 160) == (u32)0)
            {
            free((pointer)has);
            return false;
            }
        u8* on = (u8*)calloc((u64)1, (u64)220);
        _vk32(on, (u32)160, (u32)1);
        _vk32(on, (u32)156, *(u32*)(pointer)(has + 156));
        free((pointer)has);

        // A queue family with compute.
        u32 nf = (u32)0;
        families(pd, &nf, (pointer)0);
        if (nf > (u32)16)
            nf = (u32)16;
        u8 qf[384];
        families(pd, &nf, (pointer)&qf[0]);
        u32 fam = (u32)0;
        while (fam < nf && (*(u32*)(pointer)(&qf[0] + fam * (u32)24) & (u32)2) == (u32)0)
            fam = fam + (u32)1;
        if (fam >= nf)
            return false;

        float pri = 1.0;
        u8 dq[40];
        u8 dci[72];
        memset((pointer)&dq[0], (i32)0, (u64)40);
        memset((pointer)&dci[0], (i32)0, (u64)72);
        _vk32(&dq[0], (u32)0, (u32)2);
        _vk32(&dq[0], (u32)20, fam);
        _vk32(&dq[0], (u32)24, (u32)1);
        _vkp(&dq[0], (u32)32, (pointer)&pri);
        _vk32(&dci[0], (u32)0, (u32)3);
        _vk32(&dci[0], (u32)20, (u32)1);
        _vkp(&dci[0], (u32)24, (pointer)&dq[0]);
        _vkp(&dci[0], (u32)64, (pointer)on);
        // An integrated GPU works in host memory already: with
        // VK_EXT_external_memory_host its driver binds a `simd:` block where
        // it lies (importBuffer), so the block is never copied. Asked for
        // only where the device lists it; a discrete card would read such
        // memory across the bus at every access, so it keeps its copies.
        vkEnumerateDeviceExtensionProperties_t* enumerateExt =
            (vkEnumerateDeviceExtensionProperties_t*)fn("vkEnumerateDeviceExtensionProperties");
        vkGetDeviceProcAddr_t* getDevProc = (vkGetDeviceProcAddr_t*)fn("vkGetDeviceProcAddr");
        u8* extName = "VK_EXT_external_memory_host";
        pointer extNames[1];
        extNames[0] = (pointer)extName;
        bool haveExt = false;
        if (!_discrete && enumerateExt != (vkEnumerateDeviceExtensionProperties_t*)0 &&
            getDevProc != (vkGetDeviceProcAddr_t*)0)
            {
            u32 ne = (u32)0;
            enumerateExt(pd, (u8*)0, &ne, (pointer)0);
            if (ne > (u32)0)
                {
                u8* ep = (u8*)malloc((u64)ne * (u64)260);   // VkExtensionProperties: name[256], specVersion
                if (enumerateExt(pd, (u8*)0, &ne, (pointer)ep) == (i32)0)
                    for (u32 e = (u32)0; e < ne; e = e + (u32)1)
                        {
                        u8* nm = ep + e * (u32)260;
                        u32 k = (u32)0;
                        while (k < (u32)27 && nm[k] == extName[k])
                            k = k + (u32)1;
                        if (k == (u32)27 && nm[27] == (u8)0)
                            haveExt = true;
                        }
                free((pointer)ep);
                }
            }
        if (haveExt)
            {
            _vk32(&dci[0], (u32)48, (u32)1);
            _vkp(&dci[0], (u32)56, (pointer)&extNames[0]);
            }
        pointer dev = (pointer)0;
        if (createDevice(pd, (pointer)&dci[0], (pointer)0, &dev) != (i32)0)
            return false;
        _dev = dev;
        if (haveExt)
            _hostPtrProps = (vkGetMemoryHostPointerPropertiesEXT_t*)getDevProc(dev, "vkGetMemoryHostPointerPropertiesEXT");
        _hostImport = _hostPtrProps != (vkGetMemoryHostPointerPropertiesEXT_t*)0;
        _family = fam;
        pointer q = (pointer)0;
        getQueue(dev, fam, (u32)0, &q);
        _queue = q;
        _memProps = (u8*)malloc((u64)520);
        memProps(pd, (pointer)_memProps);
        u8 cpi[24];
        memset((pointer)&cpi[0], (i32)0, (u64)24);
        _vk32(&cpi[0], (u32)0, (u32)39);
        _vk32(&cpi[0], (u32)16, (u32)2);                // RESET_COMMAND_BUFFER
        _vk32(&cpi[0], (u32)20, fam);
        u64 pool = (u64)0;
        if (_createCommandPool(dev, (pointer)&cpi[0], (pointer)0, &pool) != (i32)0)
            return false;
        _cmdPool = pool;
        gVk_createBuffer = _createBuffer;
        gVk_destroyBuffer = _destroyBuffer;
        gVk_bufferReqs = _bufferReqs;
        gVk_allocate = _allocate;
        gVk_freeMemory = _freeMemory;
        gVk_bind = _bind;
        gVk_map = _map;
        gVk_createPool = _createPool;
        gVk_destroyPool = _destroyPool;
        gVk_allocateSets = _allocateSets;
        gVk_updateSets = _updateSets;
        gVk_allocateCommands = _allocateCommands;
        gVk_begin = _begin;
        gVk_end = _end;
        gVk_bindPipeline = _bindPipeline;
        gVk_bindSets = _bindSets;
        gVk_push = _push;
        gVk_dispatch = _dispatch;
        gVk_copy = _copy;
        gVk_barrier = _barrier;
        gVk_createFence = _createFence;
        gVk_destroyFence = _destroyFence;
        gVk_submit = _submit;
        gVk_wait = _wait;
        gVk_resetFences = _resetFences;
        gVk_resetCmd = _resetCmd;
        gVk_fenceStatus = (vkGetFenceStatus_t*)fn("vkGetFenceStatus");
        gVkDev = _dev;
        gVkQueue = _queue;
        gVkCmdPool = _cmdPool;
        gVkDiscrete = _discrete;
        if (_discrete)
            gParGpuDiscrete = true;
        gVk_hostPtrProps = _hostPtrProps;
        gVkHostImport = _hostImport;
        _state = (i32)1;
        if (ParDevice.reporting() && _identity != (String*)0)
            Log.info("par: Vulkan device is %s%s", _identity.cString(),
                     _hostImport ? ", sharing simd: blocks in place" : "");
        return true;
#else
        return false;
#endif
        }

    // A memory type among `bits` with all of `want` (2 host-visible, 4
    // coherent, 1 device-local), or -1.
    static i32 memoryWith(u32 bits, u32 want)
        {
        u32 n = *(u32*)(pointer)_memProps;
        for (u32 i = (u32)0; i < n; i = i + (u32)1)
            {
            u32 flags = *(u32*)(pointer)(_memProps + (u32)4 + i * (u32)8);
            if ((bits & ((u32)1 << i)) != (u32)0 && (flags & want) == want)
                return (i32)i;
            }
        return (i32)-1;
        }

    // A buffer of `bytes`: in the GPU's own memory (`device`, unmapped), else
    // mapped host memory, cached where it can be. The buffer, its memory and the mapping, or false.
    static bool buffer(i64 bytes, bool device, u64* buf, u64* mem, u8** map)
        {
        if (bytes < (i64)4)
            bytes = (i64)4;
        u8 bci[56];
        memset((pointer)&bci[0], (i32)0, (u64)56);
        _vk32(&bci[0], (u32)0, (u32)12);
        _vk64(&bci[0], (u32)24, (u64)bytes);
        // STORAGE_BUFFER, and TRANSFER_SRC|DST for the copies.
        _vk32(&bci[0], (u32)32, device ? (u32)0x23 : _discrete ? (u32)3 : (u32)0x20);
        if (_createBuffer(_dev, (pointer)&bci[0], (pointer)0, buf) != (i32)0)
            return false;
        u8 req[24];
        _bufferReqs(_dev, *buf, (pointer)&req[0]);
        u32 bits = *(u32*)(pointer)(&req[0] + 16);
        // 1 device-local; 2 host-visible, 4 coherent, 8 cached.
        // Host memory the CPU caches, where there is one: the copies in and out
        // read it at memory speed rather than across an uncached mapping (on an
        // integrated GPU the kernel works in it directly, the GPU snooping).
        i32 type = device ? memoryWith(bits, (u32)1) : memoryWith(bits, (u32)14);
        if (!device && type < (i32)0)
            type = memoryWith(bits, (u32)6);
        if (type < (i32)0)
            return false;
        u8 mai[32];
        memset((pointer)&mai[0], (i32)0, (u64)32);
        _vk32(&mai[0], (u32)0, (u32)5);
        _vk64(&mai[0], (u32)16, *(u64*)(pointer)&req[0]);
        _vk32(&mai[0], (u32)24, (u32)type);
        if (_allocate(_dev, (pointer)&mai[0], (pointer)0, mem) != (i32)0)
            return false;
        if (_bind(_dev, *buf, *mem, (u64)0) != (i32)0)
            return false;
        if (device)
            return true;
        pointer p = (pointer)0;
        if (_map(_dev, *mem, (u64)0, (u64)0xFFFFFFFFFFFFFFFF, (u32)0, &p) != (i32)0)
            return false;
        *map = (u8*)p;
        return true;
        }

    // A buffer over a `simd:` block's own pages (VK_EXT_external_memory_host):
    // the block is page-aligned and a page-multiple long, so its pages import
    // whole, and the kernel reads and writes the program's memory directly.
    // False when the driver declines (an alignment it does not take, say),
    // and the caller copies as before.
    static bool importBuffer(pointer host, i64 bytes, u64* buf, u64* mem)
        {
        if (!_hostImport)
            return false;
        bytes = (bytes + (i64)16383) & (i64)-16384;
        u8 ext[24];                                     // VkExternalMemoryBufferCreateInfo
        memset((pointer)&ext[0], (i32)0, (u64)24);
        _vk32(&ext[0], (u32)0, (u32)1000072000);
        _vk32(&ext[0], (u32)16, (u32)0x80);             // HOST_ALLOCATION_BIT_EXT
        u8 bci[56];
        memset((pointer)&bci[0], (i32)0, (u64)56);
        _vk32(&bci[0], (u32)0, (u32)12);
        _vkp(&bci[0], (u32)8, (pointer)&ext[0]);
        _vk64(&bci[0], (u32)24, (u64)bytes);
        _vk32(&bci[0], (u32)32, (u32)0x20);             // STORAGE_BUFFER
        if (_createBuffer(_dev, (pointer)&bci[0], (pointer)0, buf) != (i32)0)
            return false;
        u8 req[24];
        _bufferReqs(_dev, *buf, (pointer)&req[0]);
        u32 bits = *(u32*)(pointer)(&req[0] + 16);
        u8 hpp[24];                                     // VkMemoryHostPointerPropertiesEXT
        memset((pointer)&hpp[0], (i32)0, (u64)24);
        _vk32(&hpp[0], (u32)0, (u32)1000178001);
        if (_hostPtrProps(_dev, (u32)0x80, host, (pointer)&hpp[0]) != (i32)0 ||
            *(u64*)(pointer)&req[0] > (u64)bytes)
            {
            _destroyBuffer(_dev, *buf, (pointer)0);
            *buf = (u64)0;
            return false;
            }
        bits = bits & *(u32*)(pointer)(&hpp[0] + 16);
        i32 type = memoryWith(bits, (u32)14);
        if (type < (i32)0)
            type = memoryWith(bits, (u32)6);
        if (type < (i32)0)
            type = memoryWith(bits, (u32)2);
        if (type < (i32)0)
            {
            _destroyBuffer(_dev, *buf, (pointer)0);
            *buf = (u64)0;
            return false;
            }
        u8 imp[32];                                     // VkImportMemoryHostPointerInfoEXT
        memset((pointer)&imp[0], (i32)0, (u64)32);
        _vk32(&imp[0], (u32)0, (u32)1000178000);
        _vk32(&imp[0], (u32)16, (u32)0x80);
        _vkp(&imp[0], (u32)24, host);
        u8 mai[32];
        memset((pointer)&mai[0], (i32)0, (u64)32);
        _vk32(&mai[0], (u32)0, (u32)5);
        _vkp(&mai[0], (u32)8, (pointer)&imp[0]);
        _vk64(&mai[0], (u32)16, (u64)bytes);
        _vk32(&mai[0], (u32)24, (u32)type);
        if (_allocate(_dev, (pointer)&mai[0], (pointer)0, mem) != (i32)0)
            {
            _destroyBuffer(_dev, *buf, (pointer)0);
            *buf = (u64)0;
            *mem = (u64)0;
            return false;
            }
        if (_bind(_dev, *buf, *mem, (u64)0) != (i32)0)
            {
            _freeMemory(_dev, *mem, (pointer)0);
            _destroyBuffer(_dev, *buf, (pointer)0);
            *buf = (u64)0;
            *mem = (u64)0;
            return false;
            }
        return true;
        }

    // Frees binding slot i's kept buffers, if any.
    static void drop(u32 i)
        {
        gParVkHost[i] = (pointer)0;
        if (gParVkBuf[i] != (u64)0)
            _destroyBuffer(_dev, gParVkBuf[i], (pointer)0);
        if (gParVkMem[i] != (u64)0)
            _freeMemory(_dev, gParVkMem[i], (pointer)0);
        if (gParVkDev[i] != (u64)0)
            _destroyBuffer(_dev, gParVkDev[i], (pointer)0);
        if (gParVkDMem[i] != (u64)0)
            _freeMemory(_dev, gParVkDMem[i], (pointer)0);
        gParVkBuf[i] = (u64)0;
        gParVkMem[i] = (u64)0;
        gParVkMap[i] = (u8*)0;
        gParVkDev[i] = (u64)0;
        gParVkDMem[i] = (u64)0;
        gParVkCap[i] = (i64)0;
        }

    // The pipeline for a source, made once: its slot in the cache, or -1.
    static i32 pipeline(u8* src)
        {
        for (u32 i = (u32)0; i < gParVkKernels; i = i + (u32)1)
            if (gParVkSrc[i] == (pointer)src)
                return gParVkPipe[i] != (u64)0 ? (i32)i : (i32)-1;
        if (gParVkKernels >= (u32)64)
            return (i32)-1;
        u32 slot = gParVkKernels;
        gParVkKernels = gParVkKernels + (u32)1;
        gParVkSrc[slot] = (pointer)src;
        gParVkPipe[slot] = (u64)0;

        // The header: bindings (block, then one per buf=, glob=, red=) and spirv=<words>.
        u32 nb = (u32)1;
        u64 words = (u64)0;
        u32 devlast = (u32)0;
        u32 at = (u32)0;
        while (src[at] != (u8)0 && src[at] != (u8)10)
            {
            if (src[at] == (u8)' ' && ((src[at + (u32)1] == (u8)'b' && src[at + (u32)4] == (u8)'=') ||
                                       (src[at + (u32)1] == (u8)'g' && src[at + (u32)5] == (u8)'=') ||
                                       (src[at + (u32)1] == (u8)'r' && src[at + (u32)4] == (u8)'=')))
                nb = nb + (u32)1;
            // devlast: the module has a fold entry point the run dispatches
            // after the kernel (bug 645).
            if (src[at] == (u8)' ' && src[at + (u32)1] == (u8)'d' && src[at + (u32)2] == (u8)'e' &&
                src[at + (u32)3] == (u8)'v' && src[at + (u32)4] == (u8)'l' && src[at + (u32)5] == (u8)'a' &&
                src[at + (u32)6] == (u8)'s' && src[at + (u32)7] == (u8)'t')
                devlast = (u32)1;
            if (src[at] == (u8)'s' && src[at + (u32)1] == (u8)'p' && src[at + (u32)5] == (u8)'=')
                {
                u32 k = at + (u32)6;
                words = (u64)ParDevice.num(src, &k);
                }
            at = at + (u32)1;
            }
        if (words == (u64)0 || nb > (u32)49)
            return (i32)-1;
        while (src[at] != (u8)0)
            at = at + (u32)1;
        at = (at + (u32)4) & ~(u32)3;
        // The words, copied to aligned memory.
        u32* code = (u32*)malloc(words * (u64)4);
        memcpy((pointer)code, (pointer)(src + at), words * (u64)4);

        u8* lb = (u8*)calloc((u64)nb, (u64)24);
        for (u32 i = (u32)0; i < nb; i = i + (u32)1)
            {
            _vk32(lb + i * (u32)24, (u32)0, i);
            _vk32(lb + i * (u32)24, (u32)4, (u32)7);    // STORAGE_BUFFER
            _vk32(lb + i * (u32)24, (u32)8, (u32)1);
            _vk32(lb + i * (u32)24, (u32)12, (u32)0x20);   // COMPUTE
            }
        u8 dli[32];
        memset((pointer)&dli[0], (i32)0, (u64)32);
        _vk32(&dli[0], (u32)0, (u32)32);
        _vk32(&dli[0], (u32)20, nb);
        _vkp(&dli[0], (u32)24, (pointer)lb);
        u64 dsl = (u64)0;
        i32 rc = _createSetLayout(_dev, (pointer)&dli[0], (pointer)0, &dsl);
        free((pointer)lb);
        u8 pcr[12];
        _vk32(&pcr[0], (u32)0, (u32)0x20);
        _vk32(&pcr[0], (u32)4, (u32)0);
        _vk32(&pcr[0], (u32)8, (u32)32);   // lo, hi, per, and the fold's partial count
        u8 pli[48];
        memset((pointer)&pli[0], (i32)0, (u64)48);
        _vk32(&pli[0], (u32)0, (u32)30);
        _vk32(&pli[0], (u32)20, (u32)1);
        _vkp(&pli[0], (u32)24, (pointer)&dsl);
        _vk32(&pli[0], (u32)32, (u32)1);
        _vkp(&pli[0], (u32)40, (pointer)&pcr[0]);
        u64 layout = (u64)0;
        if (rc == (i32)0)
            rc = _createLayout(_dev, (pointer)&pli[0], (pointer)0, &layout);
        u8 smi[40];
        memset((pointer)&smi[0], (i32)0, (u64)40);
        _vk32(&smi[0], (u32)0, (u32)16);
        _vk64(&smi[0], (u32)24, words * (u64)4);
        _vkp(&smi[0], (u32)32, (pointer)code);
        u64 module = (u64)0;
        if (rc == (i32)0)
            rc = _createModule(_dev, (pointer)&smi[0], (pointer)0, &module);
        u8 cpi[96];
        memset((pointer)&cpi[0], (i32)0, (u64)96);
        _vk32(&cpi[0], (u32)0, (u32)29);
        _vk32(&cpi[0], (u32)24, (u32)18);                   // the stage
        _vk32(&cpi[0], (u32)24 + (u32)20, (u32)0x20);
        _vk64(&cpi[0], (u32)24 + (u32)24, module);
        _vkp(&cpi[0], (u32)24 + (u32)32, (pointer)"main");
        _vk64(&cpi[0], (u32)72, layout);
        u64 pipe = (u64)0;
        if (rc == (i32)0)
            rc = _createPipelines(_dev, (u64)0, (u32)1, (pointer)&cpi[0], (pointer)0, &pipe);
        // A module with a fold entry point (bug 645): a second pipeline from
        // the same module and layout, named par_fold.
        u64 foldPipe = (u64)0;
        if (rc == (i32)0 && devlast != (u32)0)
            {
            memset((pointer)&cpi[0], (i32)0, (u64)96);
            _vk32(&cpi[0], (u32)0, (u32)29);
            _vk32(&cpi[0], (u32)24, (u32)18);                   // the stage
            _vk32(&cpi[0], (u32)24 + (u32)20, (u32)0x20);
            _vk64(&cpi[0], (u32)24 + (u32)24, module);
            _vkp(&cpi[0], (u32)24 + (u32)32, (pointer)"par_fold");
            _vk64(&cpi[0], (u32)72, layout);
            rc = _createPipelines(_dev, (u64)0, (u32)1, (pointer)&cpi[0], (pointer)0, &foldPipe);
            }
        free((pointer)code);
        if (rc != (i32)0)
            {
            Log.error("par: the GPU kernel did not build, running on the CPU: Vulkan error %d", rc);
            return (i32)-1;
            }
        gParVkPipe[slot] = pipe;
        gParVkFold[slot] = foldPipe;
        gParVkLayout[slot] = layout;
        gParVkSetLayout[slot] = dsl;
        gParVkBindings[slot] = nb;
        return (i32)slot;
        }

    // Run [lo, hi) of the block on the GPU. False when the block cannot go
    // there (no kernel, a buffer of unknown size, no device): the caller then
    // runs it on the CPU, which gives the same answer.
    // The SPIR-V half of a kernel: the kernel itself where its header names
    // spirv=, else (on Windows, where the PTX comes first) the part after
    // the PTX's NUL, at the next 4-byte offset; 0 when there is none.
    static u8* spirvOf(u8* src)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return (u8*)0;
        u32 at = (u32)0;
        while (src[at] != (u8)0 && src[at] != (u8)10)
            {
            if (src[at] == (u8)'s' && src[at + (u32)1] == (u8)'p' && src[at + (u32)5] == (u8)'=')
                return src;
            at = at + (u32)1;
            }
        while (src[at] != (u8)0)
            at = at + (u32)1;
        // Counted from the kernel's start, as the compiler pads it: a string
        // literal itself need not sit on a 4-byte boundary.
        u8* s2 = src + ((at + (u32)4) & ~(u32)3);
        return s2[0] == (u8)'/' && s2[1] == (u8)'/' ? s2 : (u8*)0;
        }

    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        src = spirvOf(src);
        if (src == (u8*)0)
            return ParDevice.cpu("it has no Vulkan version");
#if !(ARCH_win64 || LINK_DYNAMIC || PLATFORM_android)
        return ParDevice.cpu("the program is linked with -static, and a Vulkan GPU needs the dynamic link");
#else
        if (!start())
            return ParDevice.cpu("there is no Vulkan device with 64-bit integers");
        i32 slot = pipeline(src);
        if (slot < (i32)0)
            return ParDevice.cpu("its GPU version did not build");
        i64 started = ParDevice.nowUs();
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        u8* obj = (u8*)(pointer)proto;
        u32 nb = gParVkBindings[slot];
        if (nb != (u32)1 + l.nbuf + l.nglob + l.nred)
            return ParDevice.cpu("its GPU version's header does not match");

        // The buffers, in binding order, filled from the host.
        u64 bufs[49];
        u64 mems[49];
        u64 devs[49];           // a discrete GPU's own copies, else 0
        u64 dmems[49];
        u8* maps[49];
        i64 sizes[49];
        for (u32 i = (u32)0; i < nb; i = i + (u32)1)
            {
            bufs[i] = (u64)0;
            mems[i] = (u64)0;
            devs[i] = (u64)0;
            dmems[i] = (u64)0;
            }
        sizes[0] = l.size;
        u32 b = (u32)1;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            sizes[b] = l.bufLen[i];
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            sizes[b] = l.globLen[i];
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
            {
            sizes[b] = l.nparts * l.redStride[i];
            b = b + (u32)1;
            }
        // Whole 32-bit words: an array of 8- or 16-bit values is read and
        // written by the kernel a word at a time, so its last part-word must
        // be inside the buffer. The copies in and out stay exact.
        for (u32 i = (u32)0; i < nb; i = i + (u32)1)
            sizes[i] = (sizes[i] + (i64)3) & (i64)-4;
        bool ok = true;
        for (u32 i = (u32)0; i < nb && ok; i = i + (u32)1)
            {
            // A captured `simd:` block on an integrated GPU that imports host
            // memory is bound in place; the slot is remade when the block
            // bound there changes.
            pointer want = (pointer)0;
            if (_hostImport && i >= (u32)1 && i <= l.nbuf)
                {
                pointer h = *(pointer*)(obj + l.bufOff[i - (u32)1]);
                if (ParDevice.simdBlock(h))
                    want = h;
                }
            if (gParVkBuf[i] == (u64)0 || gParVkCap[i] < sizes[i] || gParVkHost[i] != want)
                {
                drop(i);
                u64 hb = (u64)0;
                u64 hm = (u64)0;
                u8* hp = (u8*)0;
                u64 db = (u64)0;
                u64 dm = (u64)0;
                ok = false;
                if (want != (pointer)0)
                    {
                    ok = importBuffer(want, sizes[i], &hb, &hm);
                    if (ok)
                        hp = (u8*)want;
                    else
                        want = (pointer)0;
                    }
                if (!ok)
                    ok = buffer(sizes[i], false, &hb, &hm, &hp);
                gParVkHost[i] = want;
                if (ok && _discrete)
                    ok = buffer(sizes[i], true, &db, &dm, (u8**)0);
                // Kept even when half made, so drop() frees what was made.
                gParVkBuf[i] = hb;
                gParVkMem[i] = hm;
                gParVkMap[i] = hp;
                gParVkDev[i] = db;
                gParVkDMem[i] = dm;
                gParVkCap[i] = ok ? sizes[i] : (i64)0;
                }
            bufs[i] = gParVkBuf[i];
            mems[i] = gParVkMem[i];
            maps[i] = gParVkMap[i];
            devs[i] = gParVkDev[i];
            dmems[i] = gParVkDMem[i];
            }
        if (ok)
            {
            memcpy((pointer)maps[0], (pointer)obj, (u64)l.size);
            b = (u32)1;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                // An imported `simd:` block IS the mapping: nothing to copy.
                if ((pointer)maps[b] != *(pointer*)(obj + l.bufOff[i]))
                    memcpy((pointer)maps[b], *(pointer*)(obj + l.bufOff[i]), (u64)l.bufLen[i]);
                b = b + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globOut[i] == (i64)0)
                    memcpy((pointer)maps[b], l.globPtr[i], (u64)l.globLen[i]);
                b = b + (u32)1;
                }
            }

        // One descriptor set naming them.
        u64 pool = (u64)0;
        u64 set = (u64)0;
        if (ok)
            {
            u8 ps[8];
            _vk32(&ps[0], (u32)0, (u32)7);
            _vk32(&ps[0], (u32)4, nb);
            u8 dpi[40];
            memset((pointer)&dpi[0], (i32)0, (u64)40);
            _vk32(&dpi[0], (u32)0, (u32)33);
            _vk32(&dpi[0], (u32)20, (u32)1);
            _vk32(&dpi[0], (u32)24, (u32)1);
            _vkp(&dpi[0], (u32)32, (pointer)&ps[0]);
            if (gParVkDpool[slot] == (u64)0)
                ok = _createPool(_dev, (pointer)&dpi[0], (pointer)0, &gParVkDpool[slot]) == (i32)0;
            pool = gParVkDpool[slot];
            }
        if (ok)
            {
            u64 dsl = gParVkSetLayout[slot];
            u8 dsa[40];
            memset((pointer)&dsa[0], (i32)0, (u64)40);
            _vk32(&dsa[0], (u32)0, (u32)34);
            _vk64(&dsa[0], (u32)16, pool);
            _vk32(&dsa[0], (u32)24, (u32)1);
            _vkp(&dsa[0], (u32)32, (pointer)&dsl);
            if (gParVkDset[slot] == (u64)0)
                ok = _allocateSets(_dev, (pointer)&dsa[0], &gParVkDset[slot]) == (i32)0;
            set = gParVkDset[slot];
            }
        if (ok)
            {
            u8* info = (u8*)calloc((u64)nb, (u64)24);
            u8* wds = (u8*)calloc((u64)nb, (u64)64);
            for (u32 i = (u32)0; i < nb; i = i + (u32)1)
                {
                _vk64(info + i * (u32)24, (u32)0, _discrete ? devs[i] : bufs[i]);
                _vk64(info + i * (u32)24, (u32)8, (u64)0);
                _vk64(info + i * (u32)24, (u32)16, (u64)0xFFFFFFFFFFFFFFFF);
                u8* w = wds + i * (u32)64;
                _vk32(w, (u32)0, (u32)35);
                _vk64(w, (u32)16, set);
                _vk32(w, (u32)24, i);
                _vk32(w, (u32)32, (u32)1);
                _vk32(w, (u32)36, (u32)7);
                _vkp(w, (u32)48, (pointer)(info + i * (u32)24));
                }
            _updateSets(_dev, nb, (pointer)wds, (u32)0, (pointer)0);
            free((pointer)info);
            free((pointer)wds);
            }

        // Record, submit, wait.
        i64 gpuStart = ParDevice.nowUs();
        i64 gpuUs = (i64)-1;
        u64 fence = (u64)0;
        if (ok)
            {
            u8 cba[32];
            memset((pointer)&cba[0], (i32)0, (u64)32);
            _vk32(&cba[0], (u32)0, (u32)40);
            _vk64(&cba[0], (u32)16, _cmdPool);
            _vk32(&cba[0], (u32)24, (u32)0);
            _vk32(&cba[0], (u32)28, (u32)1);
            pointer cb = (pointer)0;
            if (gParVkCb[slot] == (u64)0)
                ok = _allocateCommands(_dev, (pointer)&cba[0], &gParVkCb[slot]) == (i32)0;
            else if (_resetCmd != (vkResetCommandBuffer_t*)0)
                ok = _resetCmd(gParVkCb[slot], (u32)0) == (i32)0;
            cb = gParVkCb[slot];
            u8 cbb[32];
            memset((pointer)&cbb[0], (i32)0, (u64)32);
            _vk32(&cbb[0], (u32)0, (u32)42);
            _vk32(&cbb[0], (u32)16, (u32)1);            // ONE_TIME_SUBMIT
            if (ok)
                ok = _begin(cb, (pointer)&cbb[0]) == (i32)0;
            if (ok)
                {
                i64 span[4];
                span[0] = lo;
                span[1] = hi;
                span[2] = l.per;
                // The fold entry point reads it: how many partials to combine.
                span[3] = l.nparts;
                // Stages: 0x800 compute, 0x1000 transfer, 0x4000 host. Access:
                // 0x20/0x40 shader read/write, 0x800/0x1000 transfer read/write,
                // 0x2000 host read.
                u8 mb[24];
                u8 cr[24];
                memset((pointer)&mb[0], (i32)0, (u64)24);
                _vk32(&mb[0], (u32)0, (u32)46);
                if (_discrete)
                    {
                    for (u32 i = (u32)0; i < nb; i = i + (u32)1)
                        {
                        _vk64(&cr[0], (u32)0, (u64)0);
                        _vk64(&cr[0], (u32)8, (u64)0);
                        _vk64(&cr[0], (u32)16, (u64)sizes[i]);
                        _copy(cb, bufs[i], devs[i], (u32)1, (pointer)&cr[0]);
                        }
                    _vk32(&mb[0], (u32)16, (u32)0x1000);
                    _vk32(&mb[0], (u32)20, (u32)0x60);
                    _barrier(cb, (u32)0x1000, (u32)0x800, (u32)0, (u32)1, (pointer)&mb[0],
                             (u32)0, (pointer)0, (u32)0, (pointer)0);
                    }
                _bindPipeline(cb, (u32)1, gParVkPipe[slot]);
                _bindSets(cb, (u32)1, gParVkLayout[slot], (u32)0, (u32)1, &set, (u32)0, (pointer)0);
                _push(cb, gParVkLayout[slot], (u32)0x20, (u32)0, (u32)32, (pointer)&span[0]);
                // A kernel that reduces on the device (bug 645) has workgroups
                // of 256, one partial each; any other, workgroups of 64.
                if (l.devred != (i64)0)
                    _dispatch(cb, (u32)l.nparts, (u32)1, (u32)1);
                else
                    _dispatch(cb, (u32)((l.threads + (i64)63) / (i64)64), (u32)1, (u32)1);
                // And when the module has a fold entry point, one more dispatch
                // combines the partials on the device: the dispatch boundary is
                // the execution dependency, the barrier below the memory one.
                if (l.devlast != (i64)0)
                    {
                    _vk32(&mb[0], (u32)16, (u32)0x40);   // SHADER_WRITE (the partials)
                    _vk32(&mb[0], (u32)20, (u32)0x60);   // SHADER_READ | SHADER_WRITE
                    _barrier(cb, (u32)0x800, (u32)0x800, (u32)0, (u32)1, (pointer)&mb[0],
                             (u32)0, (pointer)0, (u32)0, (pointer)0);
                    _bindPipeline(cb, (u32)1, gParVkFold[slot]);
                    _bindSets(cb, (u32)1, gParVkLayout[slot], (u32)0, (u32)1, &set, (u32)0, (pointer)0);
                    _dispatch(cb, (u32)1, (u32)1, (u32)1);
                    }
                if (_discrete)
                    {
                    _vk32(&mb[0], (u32)16, (u32)0x40);
                    _vk32(&mb[0], (u32)20, (u32)0x800);
                    _barrier(cb, (u32)0x800, (u32)0x1000, (u32)0, (u32)1, (pointer)&mb[0],
                             (u32)0, (pointer)0, (u32)0, (pointer)0);
                    for (u32 i = (u32)0; i < nb; i = i + (u32)1)
                        {
                        _vk64(&cr[0], (u32)0, (u64)0);
                        _vk64(&cr[0], (u32)8, (u64)0);
                        _vk64(&cr[0], (u32)16, (u64)sizes[i]);
                        _copy(cb, devs[i], bufs[i], (u32)1, (pointer)&cr[0]);
                        }
                    _vk32(&mb[0], (u32)16, (u32)0x1000);
                    _vk32(&mb[0], (u32)20, (u32)0x2000);
                    _barrier(cb, (u32)0x1000, (u32)0x4000, (u32)0, (u32)1, (pointer)&mb[0],
                             (u32)0, (pointer)0, (u32)0, (pointer)0);
                    }
                ok = _end(cb) == (i32)0;
                }
            u8 fci[24];
            memset((pointer)&fci[0], (i32)0, (u64)24);
            _vk32(&fci[0], (u32)0, (u32)8);
            if (ok && _fence == (u64)0)
                {
                u64 nf = (u64)0;
                ok = _createFence(_dev, (pointer)&fci[0], (pointer)0, &nf) == (i32)0;
                _fence = nf;
                }
            fence = _fence;
            if (ok && _resetFences != (vkResetFences_t*)0)
                ok = _resetFences(_dev, (u32)1, &fence) == (i32)0;
            if (ok)
                {
                u8 si[72];
                memset((pointer)&si[0], (i32)0, (u64)72);
                _vk32(&si[0], (u32)0, (u32)4);
                _vk32(&si[0], (u32)40, (u32)1);
                _vkp(&si[0], (u32)48, (pointer)&cb);
                ok = _submit(_queue, (u32)1, (pointer)&si[0], fence) == (i32)0 &&
                     _wait(_dev, (u32)1, &fence, (u32)1, (u64)0xFFFFFFFFFFFFFFFF) == (i32)0;
                }
            gpuUs = ParDevice.nowUs() - gpuStart;
            }

        // The arrays come back; each thread's partials fold in thread order.
        if (ok)
            {
            b = (u32)1;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufIn[i] == (i64)0 && (pointer)maps[b] != *(pointer*)(obj + l.bufOff[i]))
                    memcpy(*(pointer*)(obj + l.bufOff[i]), (pointer)maps[b], (u64)l.bufLen[i]);
                b = b + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globIn[i] == (i64)0)
                    memcpy(l.globPtr[i], (pointer)maps[b], (u64)l.globLen[i]);
                b = b + (u32)1;
                }
            u8* parts[16];
            for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
                {
                parts[i] = maps[b];
                b = b + (u32)1;
                }
            l.fold(proto, &parts[0]);
            }
        // The fence is kept for the next run (one create, not one a run).
        // The descriptor pool, set and command buffer are kept for later runs.
        // The buffers stay for the next run (gParVkBuf…), unless this one failed.
        if (!ok)
            for (u32 i = (u32)0; i < nb; i = i + (u32)1)
                drop(i);
        if (!ok)
            {
            Log.error("par: the GPU run failed, running on the CPU");
            return false;
            }
        ParDevice.ranOnGpu(proto, l, ParDevice.nowUs() - started, gpuUs);
        return true;
#endif
        }
    }


// The Vulkan GPU ParVulkan.start chose, as a worker on the tile queue
// (par-tiles-and-devices.md step 3). A run makes each buffer whole once —
// host-visible, mapped, filled from the host, and on a discrete card a copy
// in the GPU's own memory (the single shot's cost, no more) — and each tile
// is a dispatch over its own span of the same buffers, with its written
// slices copied back (through the GPU on a discrete card) as it finishes
// and its partials folded as a chunk copy. Three tiles in flight, each with
// its own command buffer, fence, descriptor set and partial buffers.
class ParVulkanWorker : ParWorker
    {
    bool _ready;
    i32 _slot;              // the kernel's pipeline slot
    ParChunk* _proto;
    ParLayout* _l;
    u32 _nb;                // bindings: args + buffers + globals + reductions
    // The buffers are kept from run to run and grown when a run needs more
    // (a host-visible allocation is pages pinned and zeroed: costly a run).
    u64 _hbuf[49];
    u64 _hmem[49];
    u8* _hmap[49];
    i64 _hcap[49];
    pointer _hhost[49];     // the `simd:` block slot i imports in place, or 0
    u64 _dbuf[49];
    u64 _dmem[49];
    i64 _dcap[49];
    i64 _sizes[49];
    // Per slot: the reductions' buffers, the set, the command buffer, the fence.
    // A discrete card: a tile's slices go through a staging buffer per slot
    // (host-visible, mapped) and vkCmdCopyBuffer at their offsets; the
    // device holds every buffer whole. An integrated one maps the whole
    // buffers and the kernel reads them in place.
    u64 _sbuf[PAR_VK_DEPTH];
    u64 _smem[PAR_VK_DEPTH];
    u8* _smap[PAR_VK_DEPTH];
    i64 _scapAlloc[PAR_VK_DEPTH];
    i64 _scap;              // staging bytes per slot (uploads then downloads)
    i64 _upMax;
    u64 _rhbuf[PAR_VK_DEPTH * 16];
    u64 _rhmem[PAR_VK_DEPTH * 16];
    u8* _rhmap[PAR_VK_DEPTH * 16];
    i64 _rhcap[PAR_VK_DEPTH * 16];
    u64 _rdbuf[PAR_VK_DEPTH * 16];
    u64 _rdmem[PAR_VK_DEPTH * 16];
    i64 _rdcap[PAR_VK_DEPTH * 16];
    i64 _rsize[16];
    u64 _pool;
    i32 _poolSlot;          // the pipeline slot the pool's sets were laid out for, -1 none
    u32 _poolNb;
    bool _once;             // command buffers and fences made
    u64 _set[PAR_VK_DEPTH];
    u64 _cb[PAR_VK_DEPTH];
    u64 _fence[PAR_VK_DEPTH];
    ParTile* _slotTile[PAR_VK_DEPTH];
    u32 _nextSlot;
    u32 _oldest;
    u32 _inFlight;

    String* identity(void)
        {
        return ParVulkan.identity();
        }
    u32 depth(void)
        {
        return (u32)PAR_VK_DEPTH;
        }
    i64 floor(void)
        {
        return (i64)4096;
        }
    i64 tileItems(ParLayout* l)
        {
        return gVkDiscrete ? ParTiles.tileItemsFor(l) : (i64)0;
        }
    bool holds(ParChunk* proto, u8* src, ParLayout* l)
        {
        if (l == (ParLayout*)0)
            return false;
        u8* spv = ParVulkan.spirvOf(src);
        if (spv == (u8*)0 || !ParVulkan.start())
            return false;
        i32 slot = ParVulkan.pipeline(spv);
        if (slot < (i32)0 || gParVkBindings[slot] != (u32)1 + l.nbuf + l.nglob + l.nred)
            return false;
        // Every written buffer needs a footprint, so a tile knows which slice
        // to copy back — unless it is a `simd:` block an integrated GPU binds
        // in place, which has nothing to copy.
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            if (l.bufIn[i] == (i64)0 && l.bufFp[i] == (i64)0
                && !(gVkHostImport && !gVkDiscrete && ParDevice.simdBlock(*(pointer*)((u8*)(pointer)proto + l.bufOff[i]))))
                return false;
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            if (l.globIn[i] == (i64)0 && l.globFp[i] == (i64)0)
                return false;
        return true;
        }

    void freeBuf(u64* b, u64* m)
        {
        if (*b != (u64)0) gVk_destroyBuffer(gVkDev, *b, (pointer)0);
        if (*m != (u64)0) gVk_freeMemory(gVkDev, *m, (pointer)0);
        *b = (u64)0;
        *m = (u64)0;
        }
    // A buffer of at least `need` bytes in the slot: the one there if it is
    // big enough, else a new one.
    bool ensure(i64 need, bool device, u64* b, u64* m, u8** map, i64* cap)
        {
        if (*b != (u64)0 && *cap >= need)
            return true;
        freeBuf(b, m);
        *cap = (i64)0;
        if (!ParVulkan.buffer(need, device, b, m, map))
            return false;
        *cap = need;
        return true;
        }

    // ensure(), for a host slot that may hold an imported `simd:` block
    // (`want`, or 0 for an ordinary buffer): kept while the same block is
    // bound there, remade when it changes, and an import the driver declines
    // falls back to a copied buffer.
    bool ensureHost(pointer want, i64 need, u64* b, u64* m, u8** map, i64* cap, pointer* host)
        {
        if (*b != (u64)0 && *host == want && (want != (pointer)0 || *cap >= need))
            return true;
        freeBuf(b, m);
        *cap = (i64)0;
        *host = (pointer)0;
        if (want != (pointer)0 && ParVulkan.importBuffer(want, need, b, m))
            {
            *map = (u8*)want;
            *host = want;
            *cap = need;
            return true;
            }
        if (!ParVulkan.buffer(need, false, b, m, map))
            return false;
        *cap = need;
        return true;
        }

    bool prepare(ParChunk* proto, u8* src, ParLayout* l, i64 tile)
        {
        u8* spv = ParVulkan.spirvOf(src);
        _slot = spv != (u8*)0 ? ParVulkan.pipeline(spv) : (i32)-1;
        if (_slot < (i32)0)
            return false;
        _proto = proto;
        _l = l;
        u8* obj = (u8*)(pointer)proto;
        u32 nfixed = (u32)1 + l.nbuf + l.nglob;
        _nb = nfixed + l.nred;
        for (u32 d = (u32)0; d < (u32)PAR_VK_DEPTH; d = d + (u32)1)
            _slotTile[d] = (ParTile*)0;
        // The whole buffers: the object as it is before any fold, every
        // captured array, every global; words whole as the single shot does.
        _sizes[0] = l.size;
        u32 b = (u32)1;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1) { _sizes[b] = l.bufLen[i]; b = b + (u32)1; }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1) { _sizes[b] = l.globLen[i]; b = b + (u32)1; }
        l.plan(0, tile);
        for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
            _rsize[r] = (l.nparts * l.redStride[r] + (i64)3) & (i64)-4;
        bool ok = true;
        _scap = (i64)0;
        _upMax = (i64)0;
        // Which buffers are sliced: footprinted ones on a discrete card go
        // up and down a tile at a time; the rest are whole (host-visible,
        // filled once; copied to the device once when it is discrete).
        bool sliced[49];
        for (u32 i = (u32)0; i < (u32)49; i = i + (u32)1)
            sliced[i] = false;
        if (gVkDiscrete)
            {
            u32 bi = (u32)1;
            i64 downMax = (i64)0;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufFp[i] != (i64)0)
                    {
                    sliced[bi] = true;
                    i64 sl = (l.bufFpK[i] * tile + (l.bufFpHi[i] - l.bufFpLo[i])) * l.bufElem[i];
                    _upMax = _upMax + sl;
                    if (l.bufIn[i] == (i64)0) downMax = downMax + sl;
                    }
                bi = bi + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globFp[i] != (i64)0)
                    {
                    sliced[bi] = true;
                    i64 sl = (l.globFpK[i] * tile + (l.globFpHi[i] - l.globFpLo[i])) * l.globElem[i];
                    if (!(l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1)) _upMax = _upMax + sl;
                    if (l.globIn[i] == (i64)0) downMax = downMax + sl;
                    }
                bi = bi + (u32)1;
                }
            _scap = ((_upMax + downMax) + (i64)4095) & (i64)-4096;
            if (_scap < (i64)4096) _scap = (i64)4096;
            for (u32 d = (u32)0; d < (u32)PAR_VK_DEPTH && ok; d = d + (u32)1)
                ok = ensure(_scap, false, &_sbuf[d], &_smem[d], &_smap[d], &_scapAlloc[d]);
            }
        for (u32 i = (u32)0; i < nfixed && ok; i = i + (u32)1)
            {
            _sizes[i] = (_sizes[i] + (i64)3) & (i64)-4;
            if (!sliced[i])
                {
                pointer want = (pointer)0;
                if (gVkHostImport && !gVkDiscrete && i >= (u32)1 && i <= l.nbuf)
                    {
                    pointer h = *(pointer*)(obj + l.bufOff[i - (u32)1]);
                    if (ParDevice.simdBlock(h))
                        want = h;
                    }
                ok = ensureHost(want, _sizes[i], &_hbuf[i], &_hmem[i], &_hmap[i], &_hcap[i], &_hhost[i]);
                }
            if (ok && gVkDiscrete)
                ok = ensure(_sizes[i], true, &_dbuf[i], &_dmem[i], (u8**)0, &_dcap[i]);
            }
        for (u32 d = (u32)0; d < (u32)PAR_VK_DEPTH && ok; d = d + (u32)1)
            for (u32 r = (u32)0; r < l.nred && ok; r = r + (u32)1)
                {
                ok = ensure(_rsize[r], false, &_rhbuf[d * (u32)16 + r], &_rhmem[d * (u32)16 + r], &_rhmap[d * (u32)16 + r], &_rhcap[d * (u32)16 + r]);
                if (ok && gVkDiscrete)
                    ok = ensure(_rsize[r], true, &_rdbuf[d * (u32)16 + r], &_rdmem[d * (u32)16 + r], (u8**)0, &_rdcap[d * (u32)16 + r]);
                }
        if (ok)
            {
            memcpy((pointer)_hmap[0], (pointer)obj, (u64)l.size);
            b = (u32)1;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                { if (!sliced[b] && (pointer)_hmap[b] != *(pointer*)(obj + l.bufOff[i])) memcpy((pointer)_hmap[b], *(pointer*)(obj + l.bufOff[i]), (u64)l.bufLen[i]); b = b + (u32)1; }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                { if (!sliced[b]) memcpy((pointer)_hmap[b], l.globPtr[i], (u64)l.globLen[i]); b = b + (u32)1; }
            }
        // One descriptor pool, a set per slot naming the whole buffers and
        // the slot's partials; the pool and sets are kept while the kernel
        // and binding count stay, the sets rewritten every run.
        if (ok && _pool != (u64)0 && (_poolSlot != _slot || _poolNb != _nb))
            {
            gVk_destroyPool(gVkDev, _pool, (pointer)0);
            _pool = (u64)0;
            }
        if (ok && _pool == (u64)0)
            {
            u8 ps[8];
            _vk32(&ps[0], (u32)0, (u32)7);
            _vk32(&ps[0], (u32)4, _nb * (u32)PAR_VK_DEPTH);
            u8 dpi[40];
            memset((pointer)&dpi[0], (i32)0, (u64)40);
            _vk32(&dpi[0], (u32)0, (u32)33);
            _vk32(&dpi[0], (u32)20, (u32)PAR_VK_DEPTH);
            _vk32(&dpi[0], (u32)24, (u32)1);
            _vkp(&dpi[0], (u32)32, (pointer)&ps[0]);
            ok = gVk_createPool(gVkDev, (pointer)&dpi[0], (pointer)0, &_pool) == (i32)0;
            for (u32 d = (u32)0; d < (u32)PAR_VK_DEPTH && ok; d = d + (u32)1)
                {
                u64 dsl = gParVkSetLayout[_slot];
                u8 dsa[40];
                memset((pointer)&dsa[0], (i32)0, (u64)40);
                _vk32(&dsa[0], (u32)0, (u32)34);
                _vk64(&dsa[0], (u32)16, _pool);
                _vk32(&dsa[0], (u32)24, (u32)1);
                _vkp(&dsa[0], (u32)32, (pointer)&dsl);
                ok = gVk_allocateSets(gVkDev, (pointer)&dsa[0], &_set[d]) == (i32)0;
                }
            _poolSlot = _slot;
            _poolNb = _nb;
            }
        for (u32 d = (u32)0; d < (u32)PAR_VK_DEPTH && ok; d = d + (u32)1)
            {
            u8* info = (u8*)calloc((u64)_nb, (u64)24);
            u8* wds = (u8*)calloc((u64)_nb, (u64)64);
            for (u32 i = (u32)0; i < _nb; i = i + (u32)1)
                {
                u64 which = i < nfixed ? (gVkDiscrete ? _dbuf[i] : _hbuf[i])
                                       : (gVkDiscrete ? _rdbuf[d * (u32)16 + (i - nfixed)] : _rhbuf[d * (u32)16 + (i - nfixed)]);
                _vk64(info + i * (u32)24, (u32)0, which);
                _vk64(info + i * (u32)24, (u32)8, (u64)0);
                _vk64(info + i * (u32)24, (u32)16, (u64)0xFFFFFFFFFFFFFFFF);
                u8* w = wds + i * (u32)64;
                _vk32(w, (u32)0, (u32)35);
                _vk64(w, (u32)16, _set[d]);
                _vk32(w, (u32)24, i);
                _vk32(w, (u32)32, (u32)1);
                _vk32(w, (u32)36, (u32)7);
                _vkp(w, (u32)48, (pointer)(info + i * (u32)24));
                }
            gVk_updateSets(gVkDev, _nb, (pointer)wds, (u32)0, (pointer)0);
            free((pointer)info);
            free((pointer)wds);
            if (_once)
                continue;
            // The slot's command buffer and fence, made once.
            u8 cba[32];
            memset((pointer)&cba[0], (i32)0, (u64)32);
            _vk32(&cba[0], (u32)0, (u32)40);
            _vk64(&cba[0], (u32)16, gVkCmdPool);
            _vk32(&cba[0], (u32)24, (u32)0);
            _vk32(&cba[0], (u32)28, (u32)1);
            ok = gVk_allocateCommands(gVkDev, (pointer)&cba[0], &_cb[d]) == (i32)0;
            u8 fci[24];
            memset((pointer)&fci[0], (i32)0, (u64)24);
            _vk32(&fci[0], (u32)0, (u32)8);
            if (ok)
                ok = gVk_createFence(gVkDev, (pointer)&fci[0], (pointer)0, &_fence[d]) == (i32)0;
            }
        if (ok)
            _once = true;
        // A discrete card: the whole buffers go up once, through the GPU.
        if (ok && gVkDiscrete)
            {
            u8 cbb[32];
            memset((pointer)&cbb[0], (i32)0, (u64)32);
            _vk32(&cbb[0], (u32)0, (u32)42);
            _vk32(&cbb[0], (u32)16, (u32)1);
            ok = gVk_begin((pointer)_cb[0], (pointer)&cbb[0]) == (i32)0;
            u8 cr[24];
            for (u32 i = (u32)0; i < nfixed && ok; i = i + (u32)1)
                {
                if (sliced[i])
                    continue;
                _vk64(&cr[0], (u32)0, (u64)0);
                _vk64(&cr[0], (u32)8, (u64)0);
                _vk64(&cr[0], (u32)16, (u64)_sizes[i]);
                gVk_copy((pointer)_cb[0], _hbuf[i], _dbuf[i], (u32)1, (pointer)&cr[0]);
                }
            if (ok)
                ok = gVk_end((pointer)_cb[0]) == (i32)0 && submitAndWait((u32)0);
            }
        _nextSlot = (u32)0;
        _oldest = (u32)0;
        _inFlight = (u32)0;
        _ready = ok;
        if (!ok)
            release();
        return ok;
        }

    bool submitAndWait(u32 d)
        {
        if (!submit(d))
            return false;
        return gVk_wait(gVkDev, (u32)1, &_fence[d], (u32)1, (u64)0xFFFFFFFFFFFFFFFF) == (i32)0;
        }

    bool submit(u32 d)
        {
        if (gVk_resetFences(gVkDev, (u32)1, &_fence[d]) != (i32)0)
            return false;
        u8 si[72];
        memset((pointer)&si[0], (i32)0, (u64)72);
        _vk32(&si[0], (u32)0, (u32)4);
        _vk32(&si[0], (u32)40, (u32)1);
        _vkp(&si[0], (u32)48, (pointer)&_cb[d]);
        return gVk_submit(gVkQueue, (u32)1, (pointer)&si[0], _fence[d]) == (i32)0;
        }

    // A run's end: the buffers stay for the next run.
    void finish(void)
        {
        _ready = false;
        _proto = (ParChunk*)0;
        _l = (ParLayout*)0;
        }

    // Everything back to the device, after a failed prepare.
    void release(void)
        {
        for (u32 d = (u32)0; d < (u32)PAR_VK_DEPTH; d = d + (u32)1)
            {
            if (_fence[d] != (u64)0) { gVk_destroyFence(gVkDev, _fence[d], (pointer)0); _fence[d] = (u64)0; }
            for (u32 r = (u32)0; r < (u32)16; r = r + (u32)1)
                {
                freeBuf(&_rhbuf[d * (u32)16 + r], &_rhmem[d * (u32)16 + r]);
                freeBuf(&_rdbuf[d * (u32)16 + r], &_rdmem[d * (u32)16 + r]);
                _rhcap[d * (u32)16 + r] = (i64)0;
                _rdcap[d * (u32)16 + r] = (i64)0;
                }
            freeBuf(&_sbuf[d], &_smem[d]);
            _scapAlloc[d] = (i64)0;
            }
        for (u32 i = (u32)0; i < (u32)49; i = i + (u32)1)
            {
            freeBuf(&_hbuf[i], &_hmem[i]);
            freeBuf(&_dbuf[i], &_dmem[i]);
            _hcap[i] = (i64)0;
            _dcap[i] = (i64)0;
            }
        // The pool takes its sets with it; the command buffers stay with
        // the command pool.
        if (_pool != (u64)0) { gVk_destroyPool(gVkDev, _pool, (pointer)0); _pool = (u64)0; }
        _once = false;
        _ready = false;
        _proto = (ParChunk*)0;
        _l = (ParLayout*)0;
        }

    bool take(ParTile* t, ParChunk* proto, u8* src, ParLayout* l)
        {
        if (!_ready || _inFlight >= (u32)PAR_VK_DEPTH)
            return false;
        u32 d = _nextSlot;
        u32 nfixed = (u32)1 + l.nbuf + l.nglob;
        l.plan(t.lo, t.hi);
        pointer cb = (pointer)_cb[d];
        if (gVk_resetCmd != (vkResetCommandBuffer_t*)0 && gVk_resetCmd(cb, (u32)0) != (i32)0)
            return false;
        u8 cbb[32];
        memset((pointer)&cbb[0], (i32)0, (u64)32);
        _vk32(&cbb[0], (u32)0, (u32)42);
        _vk32(&cbb[0], (u32)16, (u32)1);
        if (gVk_begin(cb, (pointer)&cbb[0]) != (i32)0)
            return false;
        i64 span[4];
        span[0] = t.lo;
        span[1] = t.hi;
        span[2] = l.per;
        span[3] = l.nparts;
        u8 mb[24];
        u8 cr[24];
        memset((pointer)&mb[0], (i32)0, (u64)24);
        _vk32(&mb[0], (u32)0, (u32)46);
        i64 sat = (i64)0;   // where the next slice sits in the slot's staging
        if (gVkDiscrete)
            {
            u8* obj = (u8*)(pointer)proto;
            u8* st = _smap[d];
            u32 b = (u32)1;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufFp[i] != (i64)0)
                    {
                    i64 count = l.bufLen[i] / l.bufElem[i];
                    i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
                    i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
                    i64 bytes = (e1 - e0) * l.bufElem[i];
                    if (bytes > (i64)0)
                        {
                        memcpy((pointer)(st + sat), (pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]), (u64)bytes);
                        _vk64(&cr[0], (u32)0, (u64)sat);
                        _vk64(&cr[0], (u32)8, (u64)(e0 * l.bufElem[i]));
                        _vk64(&cr[0], (u32)16, (u64)bytes);
                        gVk_copy(cb, _sbuf[d], _dbuf[b], (u32)1, (pointer)&cr[0]);
                        sat = sat + bytes;
                        }
                    }
                b = b + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globFp[i] != (i64)0 && !(l.globAll[i] != (i64)0 && l.globFpK[i] == (i64)1))
                    {
                    i64 count = l.globLen[i] / l.globElem[i];
                    i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
                    i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
                    i64 bytes = (e1 - e0) * l.globElem[i];
                    if (bytes > (i64)0)
                        {
                        memcpy((pointer)(st + sat), (pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]), (u64)bytes);
                        _vk64(&cr[0], (u32)0, (u64)sat);
                        _vk64(&cr[0], (u32)8, (u64)(e0 * l.globElem[i]));
                        _vk64(&cr[0], (u32)16, (u64)bytes);
                        gVk_copy(cb, _sbuf[d], _dbuf[b], (u32)1, (pointer)&cr[0]);
                        sat = sat + bytes;
                        }
                    }
                b = b + (u32)1;
                }
            // The uploads land before the kernel reads them.
            _vk32(&mb[0], (u32)16, (u32)0x1000);
            _vk32(&mb[0], (u32)20, (u32)0x60);
            gVk_barrier(cb, (u32)0x1000, (u32)0x800, (u32)0, (u32)1, (pointer)&mb[0], (u32)0, (pointer)0, (u32)0, (pointer)0);
            sat = _upMax;
            }
        gVk_bindPipeline(cb, (u32)1, gParVkPipe[_slot]);
        gVk_bindSets(cb, (u32)1, gParVkLayout[_slot], (u32)0, (u32)1, &_set[d], (u32)0, (pointer)0);
        gVk_push(cb, gParVkLayout[_slot], (u32)0x20, (u32)0, (u32)32, (pointer)&span[0]);
        if (l.devred != (i64)0)
            gVk_dispatch(cb, (u32)l.nparts, (u32)1, (u32)1);
        else
            gVk_dispatch(cb, (u32)((l.threads + (i64)63) / (i64)64), (u32)1, (u32)1);
        if (l.devlast != (i64)0)
            {
            _vk32(&mb[0], (u32)16, (u32)0x40);
            _vk32(&mb[0], (u32)20, (u32)0x60);
            gVk_barrier(cb, (u32)0x800, (u32)0x800, (u32)0, (u32)1, (pointer)&mb[0], (u32)0, (pointer)0, (u32)0, (pointer)0);
            gVk_bindPipeline(cb, (u32)1, gParVkFold[_slot]);
            gVk_bindSets(cb, (u32)1, gParVkLayout[_slot], (u32)0, (u32)1, &_set[d], (u32)0, (pointer)0);
            gVk_dispatch(cb, (u32)1, (u32)1, (u32)1);
            }
        if (gVkDiscrete)
            {
            // The tile's written slices and its partials, back to the host-visible side.
            _vk32(&mb[0], (u32)16, (u32)0x40);
            _vk32(&mb[0], (u32)20, (u32)0x800);
            gVk_barrier(cb, (u32)0x800, (u32)0x1000, (u32)0, (u32)1, (pointer)&mb[0], (u32)0, (pointer)0, (u32)0, (pointer)0);
            u32 b = (u32)1;
            for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
                {
                if (l.bufIn[i] == (i64)0)
                    {
                    i64 count = l.bufLen[i] / l.bufElem[i];
                    i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
                    i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
                    if (e1 > e0)
                        {
                        _vk64(&cr[0], (u32)0, (u64)(e0 * l.bufElem[i]));
                        _vk64(&cr[0], (u32)8, (u64)sat);
                        _vk64(&cr[0], (u32)16, (u64)((e1 - e0) * l.bufElem[i]));
                        gVk_copy(cb, _dbuf[b], _sbuf[d], (u32)1, (pointer)&cr[0]);
                        sat = sat + (e1 - e0) * l.bufElem[i];
                        }
                    }
                b = b + (u32)1;
                }
            for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
                {
                if (l.globIn[i] == (i64)0)
                    {
                    i64 count = l.globLen[i] / l.globElem[i];
                    i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
                    i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
                    if (e1 > e0)
                        {
                        _vk64(&cr[0], (u32)0, (u64)(e0 * l.globElem[i]));
                        _vk64(&cr[0], (u32)8, (u64)sat);
                        _vk64(&cr[0], (u32)16, (u64)((e1 - e0) * l.globElem[i]));
                        gVk_copy(cb, _dbuf[b], _sbuf[d], (u32)1, (pointer)&cr[0]);
                        sat = sat + (e1 - e0) * l.globElem[i];
                        }
                    }
                b = b + (u32)1;
                }
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                {
                _vk64(&cr[0], (u32)0, (u64)0);
                _vk64(&cr[0], (u32)8, (u64)0);
                _vk64(&cr[0], (u32)16, (u64)_rsize[r]);
                gVk_copy(cb, _rdbuf[d * (u32)16 + r], _rhbuf[d * (u32)16 + r], (u32)1, (pointer)&cr[0]);
                }
            _vk32(&mb[0], (u32)16, (u32)0x1000);
            _vk32(&mb[0], (u32)20, (u32)0x2000);
            gVk_barrier(cb, (u32)0x1000, (u32)0x4000, (u32)0, (u32)1, (pointer)&mb[0], (u32)0, (pointer)0, (u32)0, (pointer)0);
            }
        if (gVk_end(cb) != (i32)0 || !submit(d))
            return false;
        _slotTile[d] = t;
        t.worker = (ParWorker*)self;
        _nextSlot = (d + (u32)1) % (u32)PAR_VK_DEPTH;
        _inFlight = _inFlight + (u32)1;
        return true;
        }

    ParTile* complete(u32 d)
        {
        ParTile* t = _slotTile[d];
        ParLayout* l = _l;
        u8* obj = (u8*)(pointer)_proto;
        i64 sat = _upMax;   // a discrete card's downloads sit after its uploads in the slot's staging
        u32 b = (u32)1;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            if (l.bufIn[i] == (i64)0)
                {
                i64 count = l.bufLen[i] / l.bufElem[i];
                i64 e0 = ParTiles.sliceLo(l.bufFpK[i], l.bufFpLo[i], t.lo, count);
                i64 e1 = ParTiles.sliceHi(l.bufFpK[i], l.bufFpHi[i], t.hi, count);
                i64 bytes = (e1 - e0) * l.bufElem[i];
                // An imported `simd:` block was written in place: nothing comes back.
                if (bytes > (i64)0 && !(!gVkDiscrete && (pointer)_hmap[b] == *(pointer*)(obj + l.bufOff[i])))
                    {
                    pointer from = gVkDiscrete ? (pointer)(_smap[d] + sat) : (pointer)(_hmap[b] + e0 * l.bufElem[i]);
                    memcpy((pointer)(*(u8**)(obj + l.bufOff[i]) + e0 * l.bufElem[i]), from, (u64)bytes);
                    if (gVkDiscrete) sat = sat + bytes;
                    }
                }
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            if (l.globIn[i] == (i64)0)
                {
                i64 count = l.globLen[i] / l.globElem[i];
                i64 e0 = ParTiles.sliceLo(l.globFpK[i], l.globFpLo[i], t.lo, count);
                i64 e1 = ParTiles.sliceHi(l.globFpK[i], l.globFpHi[i], t.hi, count);
                i64 bytes = (e1 - e0) * l.globElem[i];
                if (bytes > (i64)0)
                    {
                    pointer from = gVkDiscrete ? (pointer)(_smap[d] + sat) : (pointer)(_hmap[b] + e0 * l.globElem[i]);
                    memcpy((pointer)((u8*)l.globPtr[i] + e0 * l.globElem[i]), from, (u64)bytes);
                    if (gVkDiscrete) sat = sat + bytes;
                    }
                }
            b = b + (u32)1;
            }
        if (l.nred > (u32)0)
            {
            l.plan(t.lo, t.hi);
            u8* parts[16];
            for (u32 r = (u32)0; r < l.nred; r = r + (u32)1)
                parts[r] = _rhmap[d * (u32)16 + r];
            ParChunk* c = _proto.copyChunk();
            l.fold(c, &parts[0]);
            t.partial = c;
            }
        t.done = true;
        _slotTile[d] = (ParTile*)0;
        _oldest = (d + (u32)1) % (u32)PAR_VK_DEPTH;
        _inFlight = _inFlight - (u32)1;
        return t;
        }

    ParTile* poll(void)
        {
        if (_inFlight == (u32)0 || gVk_fenceStatus == (vkGetFenceStatus_t*)0)
            return (ParTile*)0;
        u32 d = _oldest;
        if (gVk_fenceStatus(gVkDev, _fence[d]) != (i32)0)
            return (ParTile*)0;   // VK_NOT_READY (1), or a loss the drain reports
        return complete(d);
        }

    void drain(void)
        {
        while (_inFlight > (u32)0)
            {
            u32 d = _oldest;
            if (gVk_wait(gVkDev, (u32)1, &_fence[d], (u32)1, (u64)0xFFFFFFFFFFFFFFFF) != (i32)0)
                Log.error("par: a Vulkan tile failed on %s", ParVulkan.identity().cString());
            complete(d);
            }
        }
    }
