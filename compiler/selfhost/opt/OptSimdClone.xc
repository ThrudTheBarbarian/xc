// OptSimdClone.xc — the SimdClone pass, ported from src/xtc/ir/XTIROptSimdClone.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptVectorizeRewrite>

    class Opt (SimdClone)
    {

    // ── runtime SIMD dispatch: the per-level clones (the reference's
    // XTIROptSimdClone). CLONE, before the vectorisers, copies each function
    // with a loop (a phi) as `<name>$avx2` at 32 bytes and `<name>$avx512` at
    // 64; PRUNE, after them, drops the clones that did not vectorise at their
    // own width and marks the bases of the rest dispatched.
    // The copy is a printed and re-parsed module, taken only when it prints back
    // exactly — a lossy round trip clones nothing.
    static bool simdHasPhi(IRFunc* fn)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            if (((IRBlock*)fn.blocks().get(b)).phis().count() > (u32)0)
                return true;
        return false;
        }

    static bool simdHasWide(IRFunc* fn, u32 bytes)
        {
        String* sfx = new String();
        sfx.appendFormat(", %u)", bytes);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bl = (IRBlock*)fn.blocks().get(b);
            for (u32 k = (u32)0; k < bl.phis().count() + bl.insns().count(); k = k + (u32)1)
                {
                IRInsn* n = (IRInsn*)(k < bl.phis().count() ? bl.phis().get(k)
                                                            : bl.insns().get(k - bl.phis().count()));
                if (n.res() != (IRValue*)0 && n.res().ty() != (String*)0
                    && n.res().ty().hasPrefix(String.withCString("Vec("))
                    && n.res().ty().hasSuffix(sfx))
                    return true;
                }
            }
        return false;
        }

    // A loop with at least 8 scalar float operations (F32/F64 FAdd, FSub,
    // FMul, FDiv): blocks from a back edge's target to its source, by block
    // order. As the reference's hasFloatLoop.
    static bool simdFloatLoop(IRFunc* fn)
        {
        u32 nb = fn.blocks().count();
        Array* inLoop = new Array();
        for (u32 b = (u32)0; b < nb; b = b + (u32)1)
            inLoop.add((Object*)0);
        for (u32 b = (u32)0; b < nb; b = b + (u32)1)
            {
            IRInsn* t = ((IRBlock*)fn.blocks().get(b)).term();
            for (u32 k = (u32)0; t != (IRInsn*)0 && k < t.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)t.ops().get(k);
                if (o.kind() != (u8)OPK_BLOCK || o.blk() == (IRBlock*)0)
                    continue;
                for (u32 h = (u32)0; h <= b; h = h + (u32)1)
                    if ((IRBlock*)fn.blocks().get(h) == o.blk())
                        for (u32 j = h; j <= b; j = j + (u32)1)
                            inLoop.set(j, (Object*)Number.withU32((u32)1));
                }
            }
        u32 n = (u32)0;
        for (u32 b = (u32)0; b < nb; b = b + (u32)1)
            {
            if (inLoop.get(b) == (Object*)0)
                continue;
            IRBlock* bl = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bl.insns().count(); i = i + (u32)1)
                {
                IRInsn* x = (IRInsn*)bl.insns().get(i);
                String* op = x.op();
                if (x.res() == (IRValue*)0 || x.res().ty() == (String*)0)
                    continue;
                bool fp = x.res().ty().equals(String.withCString("F32")) || x.res().ty().equals(String.withCString("F64"));
                if (fp && (op.equals(String.withCString("FAdd")) || op.equals(String.withCString("FSub"))
                           || op.equals(String.withCString("FMul")) || op.equals(String.withCString("FDiv"))))
                    n = n + (u32)1;
                }
            }
        return n >= (u32)8;
        }

    final void simdClone(IRModule* m)
        {
        if (!_profile.simdDispatch() || !_profile.vectorize())
            return;
        Array* names = new Array();
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.simdLevel() == (String*)0 && simdHasPhi(fn))
                names.add((Object*)fn.name());
            }
        if (names.count() == (u32)0)
            return;
        String* printed = m.text();
        // One copy per level, each from its own parse, as the reference takes
        // them: the avx2 clones join the module before the avx512 ones.
        IRModule* copy2 = IrParser.parseText(printed, new IrParser());
        if (copy2 == (IRModule*)0 || !copy2.text().equals(printed))
            return;
        IRModule* copy5 = IrParser.parseText(printed, new IrParser());
        if (copy5 == (IRModule*)0 || !copy5.text().equals(printed))
            return;
        simdAddClones(m, copy2, names, String.withCString("avx2"), (u32)32);
        simdAddClones(m, copy5, names, String.withCString("avx512"), (u32)64);
        }

    final void simdAddClones(IRModule* m, IRModule* copy, Array* names, String* level, u32 bytes)
        {
        for (u32 i = (u32)0; i < names.count(); i = i + (u32)1)
            {
            String* n = (String*)names.get(i);
            for (u32 f = (u32)0; f < copy.funcs().count(); f = f + (u32)1)
                {
                IRFunc* c = (IRFunc*)copy.funcs().get(f);
                if (!c.name().equals(n))
                    continue;
                String* cn = String.withString(n);
                cn.appendByte((u8)'$');
                cn.append(level);
                c.setName(cn);
                c.setSimdLaneBytes(bytes);
                c.setSimdLevel(level);
                c.setSimdBaseName(n);
                m.addFunc(c);
                break;
                }
            }
        }

    final void simdPrune(IRModule* m)
        {
        if (!_profile.simdDispatch() || !_profile.vectorize())
            return;
        Array* keep = new Array();
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            if (fn.simdLevel() == (String*)0)
                {
                keep.add((Object*)fn);
                continue;
                }
            IRFunc* base = (IRFunc*)0;
            for (u32 g = (u32)0; g < m.funcs().count(); g = g + (u32)1)
                if (((IRFunc*)m.funcs().get(g)).name().equals(fn.simdBaseName()))
                    base = (IRFunc*)m.funcs().get(g);
            // An avx2 clone with a scalar float loop stays too, though it did
            // not vectorise: its float code takes the three-operand VEX forms
            // (the back end), which save the copy every destructive SSE op
            // needs (perlin, 2026-10-25). As the reference.
            if (base != (IRFunc*)0 && (simdHasWide(fn, fn.simdLaneBytes())
                                       || (fn.simdLevel().equals(String.withCString("avx2")) && simdFloatLoop(fn))))
                {
                base.setSimdDispatch(true);
                keep.add((Object*)fn);
                }
            }
        while (m.funcs().count() > (u32)0)
            m.funcs().removeAt(m.funcs().count() - (u32)1);
        for (u32 f = (u32)0; f < keep.count(); f = f + (u32)1)
            m.funcs().add(keep.get(f));
        }
    }
