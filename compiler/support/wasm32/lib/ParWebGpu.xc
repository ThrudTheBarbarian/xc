// ParWebGpu.xc — the `par` GPU runtime for wasm32: WebGPU, through the loader.
//
// A block's kernel is WGSL (XTIRParWGSL.m): the header line ParDevice reads,
// then the text. The loader does the WebGPU work — the device, a pipeline per
// kernel, the buffers, the dispatch and the copies back — in one call, which
// suspends this code until the GPU is done (JSPI, WebAssembly.Suspending):
// WebGPU only answers asynchronously, and a `par` block has to finish before
// the statement after it runs. Where there is no WebGPU or no JSPI (Node, an
// older browser) the call answers 0 at once and the block runs on the CPU.
//
// Bindings, in order: the block object (read), the span (lo, hi, per: three
// i64), each captured array, each global, each reduction's partials (one per
// thread, folded here afterwards in thread order). Each is described to the
// loader as (address, bytes, copy back?).
#import "ParDevice.xc"

#package xcgpu
// 1 the kernel ran, 0 no WebGPU device (or no JSPI), 2 it needs more buffers,
// or a larger one, than the device can bind, -1 its WGSL did not build.
extern i32 _xc_gpu_run(u8* src, u32 n, u32* desc, u32 nb, u32 groups);

u32 parWebGpuLen(u8* s)
    {
    u32 n = (u32)0;
    while (s[n] != (u8)0)
        n = n + (u32)1;
    return n;
    }

class ParWebGpu
    {
    static bool run(ParChunk* proto, u8* src, i64 lo, i64 hi)
        {
        if (src == (u8*)0 || src[0] != (u8)'/')
            return ParDevice.cpu("it has no GPU version");
        i64 started = ParDevice.nowUs();
        ParLayout* l = ParDevice.layout(proto, src, lo, hi);
        if (l == (ParLayout*)0)
            return false;
        u8* obj = (u8*)(pointer)proto;
        u32 nb = (u32)2 + l.nbuf + l.nglob + l.nred;
        if (nb > (u32)50)
            return ParDevice.cpu("it uses more buffers than its WebGPU version can bind");
        u32 desc[150];
        i64 span[3];
        span[0] = lo;
        span[1] = hi;
        span[2] = l.per;
        desc[0] = (u32)(pointer)obj;
        desc[1] = (u32)l.size;
        desc[2] = (u32)0;
        desc[3] = (u32)(pointer)&span[0];
        desc[4] = (u32)24;
        desc[5] = (u32)0;
        u32 b = (u32)2;
        for (u32 i = (u32)0; i < l.nbuf; i = i + (u32)1)
            {
            desc[b * (u32)3] = (u32)*(pointer*)(obj + l.bufOff[i]);
            desc[b * (u32)3 + (u32)1] = (u32)l.bufLen[i];
            desc[b * (u32)3 + (u32)2] = (u32)1;
            b = b + (u32)1;
            }
        for (u32 i = (u32)0; i < l.nglob; i = i + (u32)1)
            {
            desc[b * (u32)3] = (u32)l.globPtr[i];
            desc[b * (u32)3 + (u32)1] = (u32)l.globLen[i];
            desc[b * (u32)3 + (u32)2] = (u32)1;
            b = b + (u32)1;
            }
        u8* parts[16];
        for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
            {
            u32 bytes = (u32)(l.threads * l.redSize[i]);
            parts[i] = new u8[bytes + (u32)4];
            desc[b * (u32)3] = (u32)(pointer)parts[i];
            desc[b * (u32)3 + (u32)1] = bytes;
            desc[b * (u32)3 + (u32)2] = (u32)1;
            b = b + (u32)1;
            }
        i64 gpuStart = ParDevice.nowUs();
        i32 rc = _xc_gpu_run(src, parWebGpuLen(src), &desc[0], nb, (u32)((l.threads + (i64)63) / (i64)64));
        i64 gpuUs = ParDevice.nowUs() - gpuStart;
        if (rc == (i32)1)
            l.fold(proto, &parts[0]);
        for (u32 i = (u32)0; i < l.nred; i = i + (u32)1)
            delete parts[i];
        if (rc == (i32)0)
            return ParDevice.cpu("there is no WebGPU device (or no JSPI to wait for it)");
        if (rc == (i32)2)
            return ParDevice.cpu("it needs more GPU buffers, or a larger one, than this WebGPU device allows");
        if (rc != (i32)1)
            return ParDevice.cpu("its GPU version did not build");
        ParDevice.ranOnGpu(proto, l, ParDevice.nowUs() - started, gpuUs);
        return true;
        }
    }
