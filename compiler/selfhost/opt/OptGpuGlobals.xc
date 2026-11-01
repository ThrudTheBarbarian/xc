// OptGpuGlobals.xc — the GpuGlobals pass, ported from src/xtc/ir/XTIROptGpuGlobals.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (GpuGlobals)
    {
    // ── gpu-globals ──────────────────────────────────────────────────────
    //
    // A numeric global array of 64 KB or more gets pages of its own, as a heap
    // array of that size does (rt.c's _xtc_alloc_aligned): the back end puts it
    // on a 16 KB boundary and pads it to whole 16 KB pages (the `gpupage`
    // attribute), and __xt_gpu_globals registers it with the runtime's block
    // registry. A par block's GPU runtime then treats it as it treats a
    // page-aligned heap block: a unified-memory GPU (Metal, an integrated
    // Vulkan device) uses it in place instead of copying it in and out, and a
    // discrete card keeps an unwritten copy resident between runs (the page
    // watch). The padding matters for correctness, not just tidiness: the
    // watch protects whole pages, and a neighbour sharing one would fault
    // outside every block.
    //
    // The par runtime declares __xt_gpu_globals and calls it the first time it
    // asks the registry anything (ParDevice's parGlobals), so it is defined
    // exactly where it is declared: in the module carrying the par runtime,
    // registering that module's arrays (none, it may be). A program without a
    // par block keeps its layout. No load-time constructor, which a link from
    // objects (the C path's) would lose. A C program's arrays are clang's: the
    // C path pads them in the IR clang compiles and marks the extern side
    // gpupage. Arrays are registered on a target with threads and 64-bit
    // pointers (the ptr64 profile).
    final void gpuGlobals(IRModule* m)
        {
        String* fnName = String.withCString("__xt_gpu_globals");
        bool declared = false;
        for (u32 i = (u32)0; i < m.syms().count() && !declared; i = i + (u32)1)
            declared = ((IRSymbol*)m.syms().get(i)).name().equals(fnName);
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            if (((IRFunc*)m.funcs().get(f)).name().equals(fnName))
                return;
        if (!declared)
            return;
        Array* regs = new Array();
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)m.syms().get(i);
            // An extern one is registered only when its definition was given
            // pages of its own too (the C path's rest IR marks it gpupage).
            // Elsewhere (android, iOS: no par GPU path takes a global yet)
            // the function is defined, empty, since the runtime calls it.
            if (!_profile.ptr64() || sym.kind() != (u8)SYM_DATAGLOBAL || sym.isVolatile() || sym.isTaskLocal()
                || (sym.isExtern() && !sym.attr(String.withCString("gpupage"))))
                continue;
            u32 bytes = gpuGlobalBytes(m, sym.globalTy());
            if (bytes < (u32)GPU_GLOBAL_MIN)
                continue;
            sym.setAttr(String.withCString("gpupage"), true);
            regs.add((Object*)sym);
            }
        String* rn = String.withCString("_xtc_simd_register");
        bool have = false;
        for (u32 i = (u32)0; i < m.syms().count(); i = i + (u32)1)
            if (((IRSymbol*)m.syms().get(i)).name().equals(rn))
                have = true;
        if (!have && regs.count() > (u32)0)
            m.addSym(IRSymbol.runtime(rn));
        IRFunc* ctor = new IRFunc();
        ctor.setName(fnName);
        IRValue* mem = new IRValue(String.withCString("Mem"));
        ctor.addParam(mem);
        IRBlock* b = new IRBlock(String.withCString("bb_entry"));
        String* u8p = String.withCString("Ptr(U8, unbanked)");
        String* tyU64 = String.withCString("U64");
        for (u32 i = (u32)0; i < regs.count(); i = i + (u32)1)
            {
            IRSymbol* sym = (IRSymbol*)regs.get(i);
            IRValue* a = new IRValue(u8p);
            IRInsn* ao = IRInsn.with(String.withCString("AddrOf"));
            ao.setRes(a);
            ao.add(IROperand.sym(sym.name()));
            b.add(ao);
            IRInsn* c = IRInsn.with(String.withCString("Call"));
            c.setCc(String.withCString("CallConv::Standard"));
            c.add(IROperand.sym(rn));
            c.add(IROperand.useVal(a));
            c.add(IROperand.immI((i64)gpuGlobalPadded(gpuGlobalBytes(m, sym.globalTy())), tyU64));
            c.add(IROperand.useVal(mem));
            mem = new IRValue(String.withCString("Mem"));
            c.setMemRes(mem);
            b.add(c);
            }
        IRInsn* r = IRInsn.with(String.withCString("Return"));
        r.add(IROperand.useVal(mem));
        b.setTerm(r);
        ctor.addBlock(b);
        m.addFunc(ctor);
        }

    // A global's bytes when it is an array of a numeric type, else 0.
    static u32 gpuGlobalBytes(IRModule* m, String* ty)
        {
        if (ty == (String*)0 || !ty.hasPrefix(String.withCString("Agg(")))
            return (u32)0;
        u32 id = (u32)0;
        for (u32 k = (u32)4; k < ty.byteLength() && ty.byteAt(k) >= (u8)'0' && ty.byteAt(k) <= (u8)'9'; k = k + (u32)1)
            id = id * (u32)10 + (u32)(ty.byteAt(k) - (u8)'0');
        if (id >= m.layouts().count())
            return (u32)0;
        IRLayout* l = (IRLayout*)m.layouts().get(id);
        if (!l.isArray())
            return (u32)0;
        String* e = l.elemType();
        u8 c = e.byteLength() > (u32)0 ? e.byteAt((u32)0) : (u8)0;
        if (c != (u8)'U' && c != (u8)'I' && c != (u8)'F')
            return (u32)0;
        return l.size();
        }

    // The registered length: whole 16 KB pages (what the back end reserves).
    static u32 gpuGlobalPadded(u32 bytes)
        {
        return (bytes + (u32)GPU_GLOBAL_PAGE - (u32)1) & ~((u32)GPU_GLOBAL_PAGE - (u32)1);
        }
    }
