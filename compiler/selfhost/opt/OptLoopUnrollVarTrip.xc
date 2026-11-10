// OptLoopUnrollVarTrip.xc — the LoopUnrollVarTrip pass, ported from src/xtc/ir/XTIROptLoopUnrollVarTrip.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>
#import <OptLoopClone>
#import <OptReassociate>
#import <OptVectorizeParts>

    class Opt (LoopUnrollVarTrip)
    {

    // ── loop-unroll-var-trip ─────────────────────────────────────────────
    //
    // Partial-unroll a loop whose trip count is NOT known: emit four copies of
    // the body, each intermediate one guarded by its own compare so it can fall
    // out to the exit, and the last taking the back edge. Four is clang's
    // common choice — the out-of-order host hides most of the cross-iteration
    // overlap anyway, so a larger factor buys little and bloats the code.
    //
    // Profile-gated: on for arm64, arm9, x86_64 and win64; off for the 68000
    // (kernel-dependent there — the extra live values an unrolled body carries
    // spill) and for the 6502.
    final void loopUnrollVarTrip(IRModule* m)
        {
        if (!_profile.unrollVarTrip())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            // One loop at a time, re-recognised from the live CFG: an unrolled
            // body is no longer a single block, so it cannot re-match and the
            // bound is only a runaway backstop.
            u32 iter = (u32)0;
            while (iter < (u32)256)
                {
                VTCand* c = vtRecognise(fn);
                if (c == (VTCand*)0)
                    break;
                vtApply(fn, c);
                iter = iter + (u32)1;
                }
            }
        }

    final VTCand* vtRecognise(IRFunc* fn)
        {
        Map* defOf = new Map();
        Map* defBlk = new Map();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            self.vecNoteDefs(defOf, defBlk, bb.phis(), bb);
            self.vecNoteDefs(defOf, defBlk, bb.insns(), bb);
            if (bb.term() != (IRInsn*)0 && bb.term().res() != (IRValue*)0)
                {
                defOf.set((Hashable*)bb.term().res(), (Object*)bb.term());
                defBlk.set((Hashable*)bb.term().res(), (Object*)bb);
                }
            }
        Map* uses = self.useCounts(fn);
        for (u32 hi = (u32)0; hi < fn.blocks().count(); hi = hi + (u32)1)
            {
            VTCand* c = vtAt(fn, (IRBlock*)fn.blocks().get(hi), defOf, defBlk, uses);
            if (c != (VTCand*)0)
                return c;
            }
        return (VTCand*)0;
        }

    // The header/body/exit shape: at least the induction phi, a pure header, a
    // CondBranch on an ICmp, a single-block call-free body that latches back.
    final bool vtShape(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk)
        {
        _vtIvPhi = (IRInsn*)0;
        _vtGuard = (IRInsn*)0;
        _vtIv = (IRValue*)0;
        _vtB = (IRBlock*)0;
        _vtE = (IRBlock*)0;
        if (H.phis().count() == (u32)0)
            return false;
        if (H.phis().count() > (u32)1 && !_profile.unrollMultiCarried())
            return false;
        // Skip the vectoriser's reduction loops (several vector accumulators,
        // already unrolled); ONE is an outer-vectorised loop, which nothing
        // else unrolls (the reference explains).
        u32 vecPhis = (u32)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && self.isVectorType(p.res().ty()))
                vecPhis = vecPhis + (u32)1;
            }
        if (vecPhis > (u32)1)
            return false;
        // The header runs once per group after unrolling, so anything with a
        // side effect there would fire a different number of times.
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n.memRes() != (IRValue*)0 || vtIsCall(n.op()))
                return false;
            }
        IRInsn* term = H.term();
        if (term == (IRInsn*)0 || !term.op().equals(String.withCString("CondBranch")) || term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE)
            return false;
        Object* go = defOf.get((Hashable*)c0.val());
        Object* gb = defBlk.get((Hashable*)c0.val());
        if (go == (Object*)0 || gb == (Object*)0 || (IRBlock*)gb != H)
            return false;
        IRInsn* guard = (IRInsn*)go;
        if (!guard.op().equals(String.withCString("ICmp")) || guard.ops().count() < (u32)2)
            return false;

        // The induction phi is whichever header phi the guard tests directly.
        IRInsn* ivPhi = (IRInsn*)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0)
                continue;
            if (insnUsesValue(guard, p.res()))
                {
                ivPhi = p;
                break;
                }
            }
        if (ivPhi == (IRInsn*)0)
            return false;
        if (!self.isIntType(ivPhi.res().ty()))
            return false;

        IRBlock* T = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* F = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        if (vtLatches(T, H))
            {
            B = T;
            E = F;
            }
        else if (vtLatches(F, H))
            {
            B = F;
            E = T;
            }
        else
            return false;
        if (E == (IRBlock*)0 || B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;
        if (B.insns().count() == (u32)0 || B.insns().count() > (u32)48)
            return false;
        // Call-free, and free of the horizontal reduces (which live in the exit
        // block, never the body). A vectorised MAP body is fine — the clone path
        // handles VLoad/VStore memory tokens like any other.
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            String* op = ((IRInsn*)B.insns().get(i)).op();
            if (vtIsCall(op) || op.equals(String.withCString("VReduceAdd")) || op.equals(String.withCString("VReduceMax")) || op.equals(String.withCString("VReduceMin")))
                return false;
            }
        _vtIvPhi = ivPhi;
        _vtGuard = guard;
        _vtIv = ivPhi.res();
        _vtB = B;
        _vtE = E;
        return true;
        }

    // The variable-trip unroller's own call test, which is NARROWER than the
    // const-trip one: it does not count CallIndirect / VTblDispatch /
    // ProtoDispatch, so a body that dispatches through a vtable still unrolls.
    // The two passes really do differ here.
    final bool vtIsCall(String* op)
        {
        return op.equals(String.withCString("Call")) || op.equals(String.withCString("CallBanked")) || op.equals(String.withCString("CallCloaked"));
        }

    final bool vtLatches(IRBlock* b, IRBlock* H)
        {
        return b != (IRBlock*)0 && b != H && b.term() != (IRInsn*)0 && b.term().op().equals(String.withCString("Branch")) && b.term().ops().count() >= (u32)1 && ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    final VTCand* vtAt(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (!vtShape(fn, H, defOf, defBlk))
            return (VTCand*)0;
        IRInsn* ivPhi = _vtIvPhi;
        IRInsn* guard = _vtGuard;
        IRValue* iv = _vtIv;
        IRBlock* B = _vtB;
        IRBlock* E = _vtE;

        // ivNext = Add(iv, step) in the body, read only by the phi.
        if (ivPhi.ops().count() != (u32)4)
            return (VTCand*)0;
        IROperand* nextOp = self.vecBackOp(ivPhi, B);
        if (nextOp == (IROperand*)0 || nextOp.kind() != (u8)OPK_USE)
            return (VTCand*)0;
        Object* no = defOf.get((Hashable*)nextOp.val());
        Object* nb = defBlk.get((Hashable*)nextOp.val());
        if (no == (Object*)0 || nb == (Object*)0 || (IRBlock*)nb != B)
            return (VTCand*)0;
        IRInsn* ivNext = (IRInsn*)no;
        if (!ivNext.op().equals(String.withCString("Add")) || self.countOf(uses, nextOp.val()) != (u32)1 || ivNext.ops().count() < (u32)2)
            return (VTCand*)0;
        IROperand* a0 = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* a1 = (IROperand*)ivNext.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (a0.kind() == (u8)OPK_USE && a0.val() == iv)
            stepOp = a1;
        else if (a1.kind() == (u8)OPK_USE && a1.val() == iv)
            stepOp = a0;
        if (stepOp == (IROperand*)0)
            return (VTCand*)0;
        // The step must not vary with the iv — a per-copy clone would recompute
        // a different value. Defined outside the body means loop-invariant; a
        // body-defined step is safe only when it folds to a constant, which each
        // copy simply re-materialises.
        // i64, NOT i32. A u32 bound above 2^31 — `for (u32 r = 0; r < 2800000000;
        // r++)` — wraps NEGATIVE in an i32, the span comes out below zero, and
        // the exact-trip test silently says no. The reference has held these in
        // an int64_t throughout. Same truncation as bug 236, in the third site:
        // the recogniser and the const-trip unroller were fixed there, and this
        // one was not, because no target reached it with a bound that large
        // until wasm32 turned variable-trip unrolling on — arm64 vectorises the
        // shape first and never gets here. private:docs/bugs/243.
        i64 stepK = (i64)0;
        bool stepConst = self.vecConstWide(stepOp, defOf, &stepK);
        if (stepOp.kind() == (u8)OPK_USE && !stepConst)
            {
            Object* sb = defBlk.get((Hashable*)stepOp.val());
            if (sb != (Object*)0 && (IRBlock*)sb == B)
                return (VTCand*)0;
            }
        // The guard's bound must not live in the body either — the cloned guards
        // reference it from outside the block that is about to be removed.
        for (u32 i = (u32)0; i < guard.ops().count(); i = i + (u32)1)
            {
            IROperand* o = (IROperand*)guard.ops().get(i);
            if (o.kind() != (u8)OPK_USE || o.val() == iv)
                continue;
            Object* ob = defBlk.get((Hashable*)o.val());
            if (ob != (Object*)0 && (IRBlock*)ob == B)
                return (VTCand*)0;
            }
        // The iv must not escape: there is no exit phi materialising its final
        // value, so an outside reader would see the wrong one.
        if (vtEscapes(fn, H, B, iv))
            return (VTCand*)0;

        VTCand* c = new VTCand();
        c.setLoop(H, B, E);
        c.setIv(ivPhi, guard, ivNext, iv);
        c.setStep(stepOp, stepConst, stepK);

        // A CONSTANT trip that is a whole number of unrolled groups needs no
        // per-copy guard: the vectoriser leaves exactly that behind, array_map
        // counting 0..4096 by 4 being 256 groups of four.
        //
        // Only a STRICT `<` with the iv on the left gives trip = (N - S) / step;
        // `<=` is one more and the arithmetic would be off in the unsafe
        // direction. And only for a VECTOR body: dropping the guards merges the
        // copies into one straight-line run, which lengthens every live range in
        // it. A vector body barely notices — its values live in their own pool —
        // but a scalar body spills instead. Measured: array_map 11431 -> 6730us
        // with the gate, bit_ops unchanged; without the gate bit_ops loses 5%.
        // ...or a FLOATING-POINT body, for the same reason. The gate is about
        // what the body's values compete for: a vector body uses v18-v31 and an
        // FP body d8-d15, so in both cases the GP traffic is a few pointers and
        // lengthening a GP live range to save instructions is a good trade. A
        // GP-bound integer body is the case that spills instead.
        //
        // The FP half was added to the reference and not mirrored here, which
        // is the whole of bug 228's second half: float_math IS an FP body, so
        // the reference re-based its pointer inductions on copy 0 and this side
        // chained them, and the two compilers emitted different code for a
        // benchmark in the suite.
        bool vecBody = false;
        for (u32 k = (u32)0; k < B.insns().count(); k = k + (u32)1)
            {
            IRInsn* bi = (IRInsn*)B.insns().get(k);
            if (bi.res() == (IRValue*)0)
                continue;
            String* bt = bi.res().ty();
            if (bt.hasPrefix(String.withCString("Vec("))
                || bt.equals(String.withCString("F32"))
                || bt.equals(String.withCString("F64")))
                vecBody = true;
            }
        c.setVectorBody(vecBody);
        bool exact = false;
        if (stepConst && stepK > (i64)0 && guard.ops().count() >= (u32)2
            && (guard.pred().equals(String.withCString("ULT"))
                || guard.pred().equals(String.withCString("SLT")))
            && ((IROperand*)guard.ops().get((u32)0)).kind() == (u8)OPK_USE
            && ((IROperand*)guard.ops().get((u32)0)).val() == iv)
            {
            IROperand* initOp = (IROperand*)0;
            for (u32 k = (u32)0; k + (u32)1 < ivPhi.ops().count(); k = k + (u32)2)
                if (((IROperand*)ivPhi.ops().get(k)).blk() != B)
                    initOp = (IROperand*)ivPhi.ops().get(k + (u32)1);
            i64 boundK = (i64)0;
            i64 startK = (i64)0;
            if (initOp != (IROperand*)0
                && self.vecConstWide((IROperand*)guard.ops().get((u32)1), defOf, &boundK)
                && self.vecConstWide(initOp, defOf, &startK))
                {
                i64 span = boundK - startK;
                i64 group = stepK * (i64)4;
                // This used to be restricted to a VECTOR body, because a
                // scalar one spilled once the guards were gone and the copies
                // merged into one straight-line run. That was the
                // live-interval bug, not a property of scalar bodies — every
                // interval in the function shared one start, so lengthening
                // any of them cost a register nothing could get back. With
                // that fixed, re-measured: bit_ops unchanged, matrix_mul 17%
                // faster with the guards gone.
                if (span > (i64)0 && group > (i64)0 && span % group == (i64)0)
                    exact = true;
                }
            }
        c.setExactTrip(exact);
        if (_vtExactOnly && !exact)
            return (VTCand*)0;
        if (!vtCarried(fn, H, B, c, defOf, defBlk, uses))
            return (VTCand*)0;
        if (!vtHeaderDeps(fn, H, B, c))
            return (VTCand*)0;

        // When an accumulator escapes, the apply builds an exit phi in E whose
        // incomings are the header plus the intermediate copies. That covers all
        // of E's edges only if E was reached solely from the header beforehand —
        // otherwise an external predecessor would leave the phi an incoming short.
        bool anyEsc = false;
        for (u32 i = (u32)0; i < c.redEsc().count(); i = i + (u32)1)
            if (((Number*)c.redEsc().get(i)).asI32() != (i32)0)
                {
                anyEsc = true;
                break;
                }
        if (anyEsc)
            {
            u32 ePreds = (u32)0;
            bool onlyH = true;
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (bb.term() == (IRInsn*)0)
                    continue;
                for (u32 k = (u32)0; k < bb.term().ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)bb.term().ops().get(k);
                    if (o.kind() != (u8)OPK_BLOCK || o.blk() != E)
                        continue;
                    ePreds = ePreds + (u32)1;
                    if (bb != H)
                        onlyH = false;
                    break;
                    }
                }
            if (!onlyH || ePreds != (u32)1)
                return (VTCand*)0;
            }
        return c;
        }

    // A loop of independent vector chains: no memory access or call in the
    // body, and no body value combines two vector phis' chains (a value's
    // chain is the vector phi it derives from in the body, if any).
    final bool vtChainsIndependent(IRBlock* H, IRBlock* B)
        {
        Map* chainOf = new Map();
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && self.isVectorType(p.res().ty()))
                chainOf.set((Hashable*)p.res(), (Object*)Number.with(i));
            }
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.memRes() != (IRValue*)0 || vtIsCall(n.op()))
                return false;
            Object* ch = (Object*)0;
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                Object* oc = chainOf.get((Hashable*)o.val());
                if (oc == (Object*)0)
                    continue;
                if (ch != (Object*)0 && ((Number*)ch).asU32() != ((Number*)oc).asU32())
                    return false;
                ch = oc;
                }
            if (ch != (Object*)0 && n.res() != (IRValue*)0)
                chainOf.set((Hashable*)n.res(), ch);
            }
        return true;
        }

    // A loop the vectoriser leaves rotated, one block that branches back to
    // itself: several independent vector chains (v = v*k + c) and a counter
    // from a constant to a constant bound by one. Unrolled twice when the
    // trip is even, the second copy reading the first's results; only its
    // test drives the back edge. rcRegroup then orders the block chain by
    // chain, so each fmla writes a register other than its multiplicand
    // (#8: orr + fmla a step, not orr + fmla + orr).
    final void unrollChainLoops(IRModule* m)
        {
        if (!_profile.unrollChains())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* L = (IRBlock*)fn.blocks().get(b);
                if (ucRecognise(L))
                    {
                    ucApply(fn, L);
                    rcRegroup(L, L);
                    }
                }
            }
        }

    final bool ucRecognise(IRBlock* L)
        {
        IRInsn* t = L.term();
        if (t == (IRInsn*)0 || !t.op().equals(String.withCString("CondBranch")) || t.ops().count() < (u32)3)
            return false;
        if (((IROperand*)t.ops().get((u32)1)).blk() != L || ((IROperand*)t.ops().get((u32)2)).blk() == L)
            return false;
        IROperand* c0 = (IROperand*)t.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE || c0.val() == (IRValue*)0)
            return false;
        u32 vecPhis = (u32)0;
        _ucIv = (IRInsn*)0;
        for (u32 i = (u32)0; i < L.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)L.phis().get(i);
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            if (self.isVectorType(p.res().ty()))
                vecPhis = vecPhis + (u32)1;
            else if (_ucIv == (IRInsn*)0 && self.isIntType(p.res().ty()))
                _ucIv = p;
            else
                return false;
            }
        if (vecPhis < (u32)2 || _ucIv == (IRInsn*)0 || L.insns().count() > (u32)64)
            return false;
        // The counter: Add(iv, #1) read only by the compare and the phi, the
        // compare ULT against a constant, the phi starting at a constant.
        _ucNext = (IRInsn*)0;
        _ucCmp = (IRInsn*)0;
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (n.res() == c0.val())
                _ucCmp = n;
            if (n.op().equals(String.withCString("Add")) && n.ops().count() == (u32)2
                && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
                && ((IROperand*)n.ops().get((u32)0)).val() == _ucIv.res()
                && ((IROperand*)n.ops().get((u32)1)).kind() == (u8)OPK_IMMI
                && ((IROperand*)n.ops().get((u32)1)).imm() == (i32)1)
                _ucNext = n;
            }
        if (_ucNext == (IRInsn*)0 || _ucCmp == (IRInsn*)0 || !_ucCmp.op().equals(String.withCString("ICmp"))
            || _ucCmp.pred() == (String*)0 || !_ucCmp.pred().equals(String.withCString("ULT")) || _ucCmp.ops().count() < (u32)2)
            return false;
        IROperand* ca = (IROperand*)_ucCmp.ops().get((u32)0);
        IROperand* cb = (IROperand*)_ucCmp.ops().get((u32)1);
        if (ca.kind() != (u8)OPK_USE || ca.val() != _ucNext.res() || cb.kind() != (u8)OPK_IMMI)
            return false;
        i64 initK = (i64)-1;
        for (u32 k = (u32)0; k + (u32)1 < _ucIv.ops().count(); k = k + (u32)2)
            {
            IROperand* bo = (IROperand*)_ucIv.ops().get(k);
            IROperand* vo = (IROperand*)_ucIv.ops().get(k + (u32)1);
            if (bo.blk() == L)
                {
                if (vo.kind() != (u8)OPK_USE || vo.val() != _ucNext.res())
                    return false;
                }
            else if (vo.kind() == (u8)OPK_IMMI)
                initK = (i64)vo.imm();
            }
        i64 trip = (i64)cb.imm() - initK;
        if (initK < (i64)0 || trip < (i64)2)
            return false;
        // An odd trip runs one step before the loop, in the block that enters
        // it, and the loop the rest, an even number (#26: par_vec_chain's 37
        // rounds kept orr + fmla + orr). That block must do nothing but enter.
        _ucPre = (IRBlock*)0;
        if ((trip & (i64)1) != (i64)0)
            {
            if (trip < (i64)3)
                return false;
            for (u32 k = (u32)0; k + (u32)1 < _ucIv.ops().count(); k = k + (u32)2)
                if (((IROperand*)_ucIv.ops().get(k)).blk() != L)
                    _ucPre = ((IROperand*)_ucIv.ops().get(k)).blk();
            if (_ucPre == (IRBlock*)0 || _ucPre.term() == (IRInsn*)0
                || !_ucPre.term().op().equals(String.withCString("Branch")) || _ucPre.term().ops().count() != (u32)1
                || ((IROperand*)_ucPre.term().ops().get((u32)0)).blk() != L)
                return false;
            }
        // The counter's values read nowhere else in the block.
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (n == _ucNext || n == _ucCmp)
                continue;
            if (insnUsesValue(n, _ucIv.res()) || insnUsesValue(n, _ucNext.res()) || insnUsesValue(n, _ucCmp.res()))
                return false;
            }
        // Each vector phi's chain its own, no memory access, no call.
        return vtChainsIndependent(L, L);
        }

    // One step of the loop in the block before it: each instruction but the
    // counter's, reading the phis' entry values, and the phis then start from
    // that step's results (the counter from one on). The chains hold no memory
    // access and no call (ucRecognise), so the step may run there.
    final void ucPeel(IRBlock* L)
        {
        Map* entry = new Map();   // a phi -> its operand from the block before
        for (u32 i = (u32)0; i < L.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)L.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                if (((IROperand*)p.ops().get(k)).blk() == _ucPre)
                    entry.set((Hashable*)p.res(), p.ops().get(k + (u32)1));
            }
        Map* step = new Map();    // a loop value -> the step's copy of it
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (n == _ucNext || n == _ucCmp)
                continue;
            IRInsn* cl = IRInsn.with(n.op());
            cl.copyDbg(n);
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0)
                    {
                    Object* e = entry.get((Hashable*)o.val());
                    Object* c = step.get((Hashable*)o.val());
                    if (e != (Object*)0)
                        o = (IROperand*)e;
                    else if (c != (Object*)0)
                        o = IROperand.useVal((IRValue*)c);
                    }
                cl.add(o);
                }
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                step.set((Hashable*)n.res(), (Object*)cl.res());
                }
            _ucPre.add(cl);
            }
        for (u32 i = (u32)0; i < L.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)L.phis().get(i);
            IRValue* back = (IRValue*)0;
            u32 at = (u32)$FFFF_FFFF;
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                {
                IROperand* bo = (IROperand*)p.ops().get(k);
                IROperand* vo = (IROperand*)p.ops().get(k + (u32)1);
                if (bo.blk() == L && vo.kind() == (u8)OPK_USE)
                    back = vo.val();
                if (bo.blk() == _ucPre)
                    at = k + (u32)1;
                }
            if (at == (u32)$FFFF_FFFF)
                continue;
            if (p == _ucIv)
                {
                IROperand* vo = (IROperand*)p.ops().get(at);
                p.ops().set(at, (Object*)IROperand.immI(vo.imm() + (i64)1, vo.ty()));
                }
            else if (back != (IRValue*)0 && step.get((Hashable*)back) != (Object*)0)
                p.ops().set(at, (Object*)IROperand.useVal((IRValue*)step.get((Hashable*)back)));
            }
        }

    final void ucApply(IRFunc* fn, IRBlock* L)
        {
        if (_ucPre != (IRBlock*)0)
            ucPeel(L);
        Map* map = new Map();
        // Copy 1 reads copy 0's results where copy 0 read the phis.
        for (u32 i = (u32)0; i < L.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)L.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                if (((IROperand*)p.ops().get(k)).blk() == L)
                    {
                    IROperand* bv = (IROperand*)p.ops().get(k + (u32)1);
                    if (bv.kind() == (u8)OPK_USE)
                        map.set((Hashable*)p.res(), (Object*)bv.val());
                    }
            }
        u32 n0 = L.insns().count();
        for (u32 i = (u32)0; i < n0; i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)L.insns().get(i);
            if (n == _ucCmp)
                continue;
            IRInsn* cl = IRInsn.with(n.op());
            cl.copyDbg(n);
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                cl.add(self.unrollSubstMap(map, (IROperand*)n.ops().get(k)));
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                map.set((Hashable*)n.res(), (Object*)cl.res());
                }
            L.add(cl);
            }
        // The compare tests copy 1's counter; the phis take copy 1's values.
        IROperand* ca = (IROperand*)_ucCmp.ops().get((u32)0);
        _ucCmp.ops().set((u32)0, (Object*)IROperand.useVal((IRValue*)map.get((Hashable*)ca.val())));
        u32 at = (u32)0;
        for (u32 i = (u32)0; i < L.insns().count(); i = i + (u32)1)
            if ((IRInsn*)L.insns().get(i) == _ucCmp)
                at = i;
        L.insns().removeAt(at);
        L.add(_ucCmp);
        // The loop is rotated: what follows it reads the last step's values,
        // which are copy 1's now.
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == L)
                continue;
            Array* all = new Array();
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1) all.add(bb.phis().get(i));
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1) all.add(bb.insns().get(i));
            if (bb.term() != (IRInsn*)0) all.add((Object*)bb.term());
            for (u32 i = (u32)0; i < all.count(); i = i + (u32)1)
                {
                IRInsn* u = (IRInsn*)all.get(i);
                for (u32 k = (u32)0; k < u.ops().count(); k = k + (u32)1)
                    {
                    IROperand* o = (IROperand*)u.ops().get(k);
                    if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0 || inPhiOf(L, o.val()))
                        continue;
                    Object* nv = map.get((Hashable*)o.val());
                    if (nv != (Object*)0)
                        u.ops().set(k, (Object*)IROperand.useVal((IRValue*)nv));
                    }
                }
            }
        for (u32 i = (u32)0; i < L.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)L.phis().get(i);
            for (u32 k = (u32)0; k + (u32)1 < p.ops().count(); k = k + (u32)2)
                if (((IROperand*)p.ops().get(k)).blk() == L)
                    {
                    IROperand* bv = (IROperand*)p.ops().get(k + (u32)1);
                    if (bv.kind() == (u8)OPK_USE && map.get((Hashable*)bv.val()) != (Object*)0)
                        p.ops().set(k + (u32)1, (Object*)IROperand.useVal((IRValue*)map.get((Hashable*)bv.val())));
                    }
            }
        }

    // Is v one of L's phis? (The map also sends each phi to copy 0's value,
    // which a reader after the loop must not take.)
    final bool inPhiOf(IRBlock* L, IRValue* v)
        {
        for (u32 i = (u32)0; i < L.phis().count(); i = i + (u32)1)
            if (((IRInsn*)L.phis().get(i)).res() == v)
                return true;
        return false;
        }

    // An unrolled chain loop's body is in copy order: copy 0 of every chain,
    // then copy 1 of every chain, which keeps every chain's copy-0 value live
    // at once (8 chains need 8 + 8 vector registers and the arm64 pool has
    // 14). H holds the vector phis; B is the body (H itself for a rotated
    // loop). Reorder it chain by chain, each chain's instructions in their
    // order; the instructions of no chain (the induction, the compare) first,
    // which read no chain value. Every instruction moves only past ones it
    // does not depend on.
    final void rcRegroup(IRBlock* H, IRBlock* B)
        {
        Map* chainOf = new Map();
        u32 nchains = (u32)0;
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p.res() != (IRValue*)0 && self.isVectorType(p.res().ty()))
                {
                chainOf.set((Hashable*)p.res(), (Object*)Number.with(nchains));
                nchains = nchains + (u32)1;
                }
            }
        Array* chainOfInsn = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            if (n.memRes() != (IRValue*)0)
                return;
            i32 ch = (i32)-1;
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                {
                IROperand* o = (IROperand*)n.ops().get(k);
                if (o.kind() != (u8)OPK_USE || o.val() == (IRValue*)0)
                    continue;
                Object* oc = chainOf.get((Hashable*)o.val());
                if (oc == (Object*)0)
                    continue;
                i32 c = (i32)((Number*)oc).asU32();
                if (ch >= (i32)0 && ch != c)
                    return;
                ch = c;
                }
            if (ch >= (i32)0 && n.res() != (IRValue*)0)
                chainOf.set((Hashable*)n.res(), (Object*)Number.with((u32)ch));
            chainOfInsn.add((Object*)Number.withI32(ch));
            }
        Array* order = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            if (((Number*)chainOfInsn.get(i)).asI32() < (i32)0)
                order.add(B.insns().get(i));
        for (u32 c = (u32)0; c < nchains; c = c + (u32)1)
            for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
                if (((Number*)chainOfInsn.get(i)).asI32() == (i32)c)
                    order.add(B.insns().get(i));
        if (order.count() != B.insns().count())
            return;
        // A chain-free instruction that reads a chain value cannot move first;
        // there is none in an independent-chain body, but keep the order then.
        for (u32 i = (u32)0; i < order.count(); i = i + (u32)1)
            B.insns().set(i, order.get(i));
        }

    // Is `v` read anywhere outside the header and the body?
    final bool vtEscapes(IRFunc* fn, IRBlock* H, IRBlock* B, IRValue* v)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == H || bb == B)
                continue;
            if (unrollUsesValue(bb, v))
                return true;
            }
        return false;
        }

    // Every non-induction header phi is a carried accumulator, and each must have
    // the standard (preheader init, body update) shape with the update in the
    // body and read only by the phi. The copies then serial-chain it, preserving
    // order — so no associativity is required and float reductions are fine.
    final bool vtCarried(IRFunc* fn, IRBlock* H, IRBlock* B, VTCand* c,
                   Map* defOf, Map* defBlk, Map* uses)
        {
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* p = (IRInsn*)H.phis().get(i);
            if (p == c.ivPhi())
                continue;
            if (p.res() == (IRValue*)0 || p.memRes() != (IRValue*)0 || p.ops().count() != (u32)4)
                return false;
            String* rt = p.res().ty();
            if (rt == (String*)0 || rt.equals(String.withCString("Mem")) || rt.equals(String.withCString("Void")) || rt.hasPrefix(String.withCString("Agg(")))
                return false;
            IROperand* rNextOp = self.vecBackOp(p, B);
            if (rNextOp == (IROperand*)0 || rNextOp.kind() != (u8)OPK_USE)
                return false;
            Object* ro = defOf.get((Hashable*)rNextOp.val());
            Object* rb = defBlk.get((Hashable*)rNextOp.val());
            if (ro == (Object*)0 || rb == (Object*)0 || (IRBlock*)rb != B)
                return false;
            if (countOf(uses, rNextOp.val()) != (u32)1)
                return false;
            c.redPhis().add((Object*)p);
            c.redNexts().add(ro);
            c.redVals().add((Object*)p.res());
            c.redEsc().add((Object*)Number.withI32(
                vtEscapes(fn, H, B, p.res()) ? (i32)1 : (i32)0));
            }
        return true;
        }

    // Does `n` read a value `set` holds?
    final bool vtReadsAny(IRInsn* n, Map* set)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && set.get((Hashable*)o.val()) != (Object*)0)
                return true;
            }
        return false;
        }

    // Header values computed from the iv or an accumulator. xc's lowering
    // never makes one, but clang's IR does: `getelementptr p, i` in the loop's
    // condition block, read by the body's load and store. In the header such a
    // value is copy 0's, so each later copy computes its own from its own iv
    // (vtCopy); the ones the body reads go to c.hdrDeps in header order. A
    // loop whose guard compares against one, or that reads one after the
    // loop, cannot be given a value per copy and is left alone.
    final bool vtHeaderDeps(IRFunc* fn, IRBlock* H, IRBlock* B, VTCand* c)
        {
        Map* dep = new Map();
        dep.set((Hashable*)c.iv(), (Object*)c.iv());
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            dep.set((Hashable*)c.redVals().get(i), c.redVals().get(i));
        Map* hdr = new Map();
        Array* hd = new Array();
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n.res() == (IRValue*)0 || !vtReadsAny(n, dep))
                continue;
            dep.set((Hashable*)n.res(), (Object*)n.res());
            hdr.set((Hashable*)n.res(), (Object*)n.res());
            hd.add((Object*)n);
            }
        if (vtReadsAny(c.guard(), hdr))
            return false;
        for (u32 i = (u32)0; i < hd.count(); i = i + (u32)1)
            if (vtEscapes(fn, H, B, ((IRInsn*)hd.get(i)).res()))
                return false;
        Map* need = new Map();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            vtNeedHeader((IRInsn*)B.insns().get(i), hdr, need);
        if (B.term() != (IRInsn*)0)
            vtNeedHeader(B.term(), hdr, need);
        for (u32 i = hd.count(); i > (u32)0; i = i - (u32)1)
            {
            IRInsn* n = (IRInsn*)hd.get(i - (u32)1);
            if (need.get((Hashable*)n.res()) != (Object*)0)
                vtNeedHeader(n, hdr, need);
            }
        for (u32 i = (u32)0; i < hd.count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)hd.get(i);
            if (need.get((Hashable*)n.res()) != (Object*)0)
                c.hdrDeps().add((Object*)n);
            }
        return true;
        }

    // Mark in `need` each value of `hdr` that `n` reads.
    final void vtNeedHeader(IRInsn* n, Map* hdr, Map* need)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != (IRValue*)0 && hdr.get((Hashable*)o.val()) != (Object*)0)
                need.set((Hashable*)o.val(), (Object*)o.val());
            }
        }

    final void vtApply(IRFunc* fn, VTCand* c)
        {
        IRBlock* H = c.h();
        IRBlock* B = c.b();
        IRBlock* E = c.e();
        u32 U = (u32)4;

        _vtClones = new Array();
        _vtGuards = new Array();
        _vtAccAfter = new Array();
        _vtLastRed = new Array();
        _vtLastIvNext = c.iv();
        Array* prevRed = new Array();
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            {
            prevRed.add(c.redVals().get(i));
            _vtLastRed.add(c.redVals().get(i));
            _vtAccAfter.add((Object*)new Array());
            }

        IRValue* prevIv = c.iv(); // copy 0 enters with the header phi
        _vtLastMap = new Map();
        // A pure LOOP-INVARIANT body instruction (a VSplat of an outer-loop
        // value the vectoriser left in the body, or the Const/cast chain
        // feeding it) computes the same value in every copy: clone it once, in
        // copy 0, and let the later copies reference that result — copy 0
        // dominates them. One live broadcast instead of U is what keeps the
        // backends' 8-register vector pools from overflowing (#1198).
        _vtSharedPure = new Map();
        for (u32 j = (u32)0; j < U; j = j + (u32)1)
            prevIv = vtCopy(fn, c, j, U, prevIv, prevRed);

        self.vtWire(fn, c, U);
        vtCountGroups(fn, c, U);
        }

    // In a par kernel the unrolled loop counts its groups by one, and each
    // copy's induction value is start + g*U*step (issue #7). Mesa's compiler
    // for the Pi 5's V3D runs a loop counted by one far faster than the same
    // loop counted by four: nbody's inner loop 32.5 ms against 66.2 ms, the
    // bodies otherwise the same. Only an exact trip (constant start and
    // bound), with the induction value read in the header by the guard alone.
    final void vtCountGroups(IRFunc* fn, VTCand* c, u32 U)
        {
        if (!_vtExactOnly || !c.exactTrip() || !c.stepIsConst() || _vtClones.count() == (u32)0)
            return;
        IRBlock* H = c.h();
        IRInsn* ivPhi = c.ivPhi();
        IRInsn* guard = c.guard();
        IRValue* iv = c.iv();
        IRBlock* first = (IRBlock*)_vtClones.get((u32)0);
        IRBlock* last = (IRBlock*)_vtClones.get(_vtClones.count() - (u32)1);
        String* ty = iv.ty();
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.insns().get(i);
            if (n != guard && insnUsesValue(n, iv))
                return;
            }
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)H.phis().get(i);
            if (n != ivPhi && insnUsesValue(n, iv))
                return;
            }
        IRBlock* pre = (IRBlock*)0;
        IROperand* initOp = (IROperand*)0;
        for (u32 k = (u32)0; k + (u32)1 < ivPhi.ops().count(); k = k + (u32)2)
            {
            IROperand* bo = (IROperand*)ivPhi.ops().get(k);
            if (bo.blk() != last)
                {
                pre = bo.blk();
                initOp = (IROperand*)ivPhi.ops().get(k + (u32)1);
                }
            }
        if (pre == (IRBlock*)0 || initOp == (IROperand*)0 || guard.ops().count() < (u32)2)
            return;
        Map* defOf = self.defMapAll(fn);
        i64 startK = (i64)0;
        i64 boundK = (i64)0;
        if (!self.vecConstWide(initOp, defOf, &startK) || !self.vecConstWide((IROperand*)guard.ops().get((u32)1), defOf, &boundK))
            return;
        i64 group = c.stepK() * (i64)U;
        if (group <= (i64)0)
            return;
        i64 groups = (boundK - startK) / group;
        if (groups <= (i64)0 || groups > (i64)2147483647)
            return;

        // g: 0 from the preheader, g + 1 round the back edge.
        IRInsn* z = IRInsn.with(String.withCString("Const"));
        z.setRes(new IRValue(ty));
        z.add(IROperand.immI((i32)0, ty));
        pre.add(z);
        IRValue* g = new IRValue(ty);
        IRInsn* gNext = IRInsn.with(String.withCString("Add"));
        gNext.setRes(new IRValue(ty));
        gNext.add(IROperand.useVal(g));
        gNext.add(IROperand.immI((i32)1, ty));
        last.add(gNext);
        IRInsn* gPhi = IRInsn.with(String.withCString("Phi"));
        gPhi.setRes(g);
        gPhi.add(IROperand.block(pre));
        gPhi.add(IROperand.useVal(z.res()));
        gPhi.add(IROperand.block(last));
        gPhi.add(IROperand.useVal(gNext.res()));
        H.phis().add(gPhi);
        guard.ops().set((u32)0, (Object*)IROperand.useVal(g));
        guard.ops().set((u32)1, (Object*)IROperand.immI((i32)groups, ty));

        // The copies' induction value, from g at the top of the first.
        IRInsn* mul = IRInsn.with(String.withCString("Mul"));
        mul.copyDbg(c.ivNext());
        mul.setRes(new IRValue(ty));
        mul.add(IROperand.useVal(g));
        mul.add(IROperand.immI((i32)group, ty));
        IRInsn* add = IRInsn.with(String.withCString("Add"));
        add.copyDbg(c.ivNext());
        add.setRes(new IRValue(ty));
        add.add(IROperand.useVal(mul.res()));
        add.add(initOp);
        first.insns().insert((u32)0, (Object*)add);
        first.insns().insert((u32)0, (Object*)mul);
        for (u32 j = (u32)0; j < _vtClones.count(); j = j + (u32)1)
            {
            IRBlock* C = (IRBlock*)_vtClones.get(j);
            for (u32 i = (u32)0; i < C.insns().count(); i = i + (u32)1)
                {
                IRInsn* n = (IRInsn*)C.insns().get(i);
                if (n == mul || n == add)
                    continue;
                vtReplaceUse(n, iv, add.res());
                }
            if (C.term() != (IRInsn*)0)
                vtReplaceUse(C.term(), iv, add.res());
            }

        // The old induction is dead: its phi, and the back-edge add.
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            if ((IRInsn*)H.phis().get(i) == ivPhi)
                {
                H.phis().removeAt(i);
                break;
                }
        for (u32 i = (u32)0; i < last.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)last.insns().get(i);
            if (n.res() == _vtLastIvNext)
                {
                last.insns().removeAt(i);
                break;
                }
            }
        }

    final void vtReplaceUse(IRInsn* n, IRValue* from, IRValue* to)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == from)
                n.ops().set(k, (Object*)IROperand.useVal(to));
            }
        }

    // Invariant iff pure (VSplat / Const / a cast) and every Use operand is
    // either defined outside the body (not remapped) or itself a shared
    // invariant clone (#1198). A helper so vtCopy stays under the arm64
    // frame budget.
    final bool vtShareable(IRInsn* n, VTCand* c, Map* map)
        {
        if (n.res() == (IRValue*)0 || n.memRes() != (IRValue*)0 || n == c.ivNext())
            return false;
        // Vector arithmetic on invariants (sort_small's splat(r) *
        // splat(40503)) is shared the same way. As the reference.
        bool vecArith = n.op().equals(String.withCString("VAdd")) || n.op().equals(String.withCString("VSub")) || n.op().equals(String.withCString("VMul"))
                     || n.op().equals(String.withCString("VAnd")) || n.op().equals(String.withCString("VOr")) || n.op().equals(String.withCString("VXor"));
        if (!vecArith && !n.op().equals(String.withCString("VSplat")) && !n.op().equals(String.withCString("Const")) && !n.op().equals(String.withCString("ZExt")) && !n.op().equals(String.withCString("SExt")) && !n.op().equals(String.withCString("Trunc")))
            return false;
        // A splat of a value the body defines (a constant the vectoriser left
        // in the body, past its hoisting budget) is made again in each copy:
        // shared, it would be live across all of them, and MD5's rounds have
        // dozens.
        if (n.op().equals(String.withCString("VSplat")) && n.ops().count() == (u32)1
            && ((IROperand*)n.ops().get((u32)0)).kind() == (u8)OPK_USE
            && map.get((Hashable*)((IROperand*)n.ops().get((u32)0)).val()) != (Object*)0)
            return false;
        // In a large body none is: each is a register the copies' own values
        // need.
        if ((vecArith || n.op().equals(String.withCString("VSplat"))) && c.b().insns().count() > (u32)VEC_SPLAT_BIG_BODY)
            return false;
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && map.get((Hashable*)o.val()) != (Object*)0 && _vtSharedPure.get((Hashable*)o.val()) == (Object*)0)
                return false;
            }
        return true;
        }

    // One copy of the body. Returns the induction value the NEXT copy enters
    // with; `prevRed` carries each accumulator's incoming value and is advanced.
    final IRValue* vtCopy(IRFunc* fn, VTCand* c, u32 j, u32 U,
                    IRValue* prevIv, Array* prevRed)
        {
        IRBlock* B = c.b();
        String* base = B.name() == (String*)0 ? String.withCString("body") : B.name();
        String* nm = new String();
        nm.appendFormat("%s_vu%lu", base.cString(), j);
        IRBlock* C = new IRBlock(nm);

        Map* map = new Map();
        map.set((Hashable*)c.iv(), (Object*)prevIv);
        // In a par kernel each copy's induction value is copy 0's plus j
        // steps, not the previous copy's plus one: the GPU's compiler folds a
        // constant offset from one base into each load, and does not fold a
        // chain (nbody on the Pi 5's V3D: 66.3 ms chained, 32.5 ms re-based;
        // issue #7).
        if (_vtExactOnly && j > (u32)0 && c.stepIsConst())
            {
            IRInsn* ivj = IRInsn.with(String.withCString("Add"));
            ivj.copyDbg(c.ivNext());
            ivj.setRes(new IRValue(c.iv().ty()));
            ivj.add(IROperand.useVal(c.iv()));
            ivj.add(IROperand.immI((i32)(c.stepK() * (i64)j), c.iv().ty()));
            C.add(ivj);
            map.set((Hashable*)c.iv(), (Object*)ivj.res());
            }
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            map.set((Hashable*)(IRValue*)c.redVals().get(i), prevRed.get(i));

        // A POINTER carried by a constant stride is RE-BASED on copy 0 rather
        // than chained. The chain `p -> p+16 -> p+32 -> p+48` costs one add per
        // copy per array; `p+0, p+16, p+32, p+48` costs none, because the back
        // end folds ElementAddr(base, CONSTANT) into `ldr/str q, [base, #imm]`.
        // mem_copy carries two pointers over four copies — eight adds on a
        // twenty-instruction body.
        // The update of a re-based pointer is re-based too: p + K*(j+1) straight
        // from the phi, not (p + K*j) + K. In the last copy that is the
        // back-edge value, which was otherwise a chain of two adds.
        Map* rebasedNext = new Map();
        if (j > (u32)0)
            {
            for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
                {
                IRInsn* rn = (IRInsn*)c.redNexts().get(i);
                IRValue* rp = (IRValue*)c.redVals().get(i);
                if (rn == (IRInsn*)0 || !rn.op().equals(String.withCString("ElementAddr")))
                    continue;
                if (rn.ops().count() < (u32)2)
                    continue;
                IROperand* b0 = (IROperand*)rn.ops().get((u32)0);
                IROperand* b1 = (IROperand*)rn.ops().get((u32)1);
                if (b0.kind() != (u8)OPK_USE || b0.val() != rp || b1.kind() != (u8)OPK_IMMI)
                    continue;
                if (!rp.ty().hasPrefix(String.withCString("Ptr(")))
                    continue;
                IRValue* rv = new IRValue(rp.ty());
                IRInsn* ea = IRInsn.with(String.withCString("ElementAddr"));
                ea.copyDbg(rn);
                ea.setRes(rv);
                ea.add(IROperand.useVal(rp));
                ea.add(IROperand.immI((i32)(b1.imm() * (i64)j), b1.ty()));
                C.add(ea);
                map.set((Hashable*)rp, (Object*)rv);
                IRInsn* nx = IRInsn.with(String.withCString("ElementAddr"));
                nx.add(IROperand.useVal(rp));
                nx.add(IROperand.immI((i32)(b1.imm() * (i64)(j + (u32)1)), b1.ty()));
                rebasedNext.set((Hashable*)rn.res(), (Object*)nx);
                }
            }

        // The header values computed from the iv (vtHeaderDeps): copy 0 reads
        // the header's, which are its own, and each later copy computes them
        // again from its iv. Copy 0 maps them to themselves, so vtShareable
        // never takes a body value computed from one for loop-invariant.
        for (u32 i = (u32)0; i < c.hdrDeps().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)c.hdrDeps().get(i);
            if (j == (u32)0)
                {
                map.set((Hashable*)n.res(), (Object*)n.res());
                continue;
                }
            IRInsn* hc = IRInsn.with(n.op());
            hc.copyDbg(n);
            hc.setPred(n.pred());
            hc.setCc(n.cc());
            for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                hc.add(self.unrollSubstMap(map, (IROperand*)n.ops().get(k)));
            hc.setRes(new IRValue(n.res().ty()));
            map.set((Hashable*)n.res(), (Object*)hc.res());
            C.add(hc);
            }

        IRValue* cloneIvNext = prevIv;
        // A re-based pointer update goes at the END of the copy, after the last
        // access through the old pointer, so the two never overlap and the
        // register allocator can give the new value the old one's register (no
        // copy at the back edge). Only when nothing in the body reads it.
        Array* deferred = new Array();
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            bool shareable = vtShareable(n, c, map);
            if (shareable && _vtSharedPure.get((Hashable*)n.res()) != (Object*)0)
                {
                map.set((Hashable*)n.res(), _vtSharedPure.get((Hashable*)n.res()));
                continue; // copies 1..U-1 reuse copy 0's
                }
            IRInsn* cl = IRInsn.with(n.op());
            cl.copyDbg(n);
            cl.setPred(n.pred());
            cl.setCc(n.cc());
            IRInsn* rbn = n.res() == (IRValue*)0 ? (IRInsn*)0 : (IRInsn*)rebasedNext.get((Hashable*)n.res());
            if (rbn != (IRInsn*)0)
                {
                for (u32 k = (u32)0; k < rbn.ops().count(); k = k + (u32)1)
                    cl.add((IROperand*)rbn.ops().get(k));
                }
            else
                for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
                    cl.add(self.unrollSubstMap(map, (IROperand*)n.ops().get(k)));
            if (n.res() != (IRValue*)0)
                {
                cl.setRes(new IRValue(n.res().ty()));
                map.set((Hashable*)n.res(), (Object*)cl.res());
                }
            if (n.memRes() != (IRValue*)0)
                {
                cl.setMemRes(new IRValue(String.withCString("Mem")));
                map.set((Hashable*)n.memRes(), (Object*)cl.memRes());
                }
            if (rbn != (IRInsn*)0 && self.jtUseCountIn(B.insns(), n.res()) == (u32)0)
                deferred.add((Object*)cl);
            else
                C.add(cl);
            if (n == c.ivNext())
                cloneIvNext = cl.res();
            if (shareable)
                _vtSharedPure.set((Hashable*)n.res(), (Object*)cl.res());
            }

        for (u32 i = (u32)0; i < deferred.count(); i = i + (u32)1)
            C.add((IRInsn*)deferred.get(i));
        // Each accumulator's update in this copy is its value afterwards.
        for (u32 i = (u32)0; i < c.redVals().count(); i = i + (u32)1)
            {
            IRInsn* rn = (IRInsn*)c.redNexts().get(i);
            Object* cn = map.get((Hashable*)rn.res());
            ((Array*)_vtAccAfter.get(i)).add(cn);
            prevRed.set(i, cn);
            if (j + (u32)1 == U)
                _vtLastRed.set(i, cn);
            }

        if (j + (u32)1 < U && c.exactTrip())
            {
            // Provably true — no guard; the copy falls into the next one.
            _vtGuards.add((Object*)0);
            }
        else if (j + (u32)1 < U)
            {
            // An intermediate copy tests `iv_{j+1} <cmp> bound` and either falls
            // through to the next copy or leaves for the exit.
            Map* gmap = new Map();
            gmap.set((Hashable*)c.iv(), (Object*)cloneIvNext);
            IRInsn* g = IRInsn.with(c.guard().op());
            g.copyDbg(c.guard());
            g.setPred(c.guard().pred());
            g.setRes(new IRValue(c.guard().res().ty()));
            for (u32 k = (u32)0; k < c.guard().ops().count(); k = k + (u32)1)
                g.add(self.unrollSubstMap(gmap, (IROperand*)c.guard().ops().get(k)));
            C.add(g);
            _vtGuards.add((Object*)g.res());
            }
        else
            {
            _vtGuards.add((Object*)0);
            // The back-edge induction update is computed INDEPENDENTLY of the
            // per-copy chain: iv_next = iv_0 + U*step rather than iv_{U-1}+step.
            // The chain still feeds the copies' bodies, but the value crossing
            // the back edge no longer waits on it — the carried recurrence drops
            // from U serial adds to one. The multiply is loop-invariant and off
            // the carried path, and for a power-of-two U folds to a shifted add.
            String* ivTy = c.ivPhi().res().ty();
            IROperand* nStep = (IROperand*)0;
            if (c.stepIsConst())
                {
                nStep = IROperand.immI((i32)(c.stepK() * (i64)U), ivTy);
                }
            else
                {
                IRValue* mres = new IRValue(ivTy);
                IRInsn* mi = IRInsn.with(String.withCString("Mul"));
                mi.setRes(mres);
                mi.add(c.step());
                mi.add(IROperand.immI((i32)U, ivTy));
                C.add(mi);
                nStep = IROperand.useVal(mres);
                }
            IRValue* ares = new IRValue(ivTy);
            IRInsn* ai = IRInsn.with(String.withCString("Add"));
            ai.setRes(ares);
            ai.add(IROperand.useVal(c.iv()));
            ai.add(nStep);
            C.add(ai);
            _vtLastIvNext = ares;
            }
        _vtClones.add((Object*)C);
        _vtLastMap = map;
        return cloneIvNext;
        }
    }
