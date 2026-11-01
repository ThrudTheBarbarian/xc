// OptTailRecursion.xc — the TailRecursion pass, ported from src/xtc/ir/XTIROptTailRecursion.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (TailRecursion)
    {

    // ── tail-recursion ───────────────────────────────────────────────────
    //
    // `return f(args)` becomes a loop: the entry block is split into a
    // preheader and a header carrying one phi per parameter, and every
    // iterated return becomes a back edge that feeds the phis its arguments.
    // Tier-2 does the same for `return g ⊕ f(args)` with an accumulator phi,
    // and is profile-gated — it is a win on an in-order core and a loss where
    // the call overhead is already hidden.
    //
    // Memory is LOOSE in this IR: there is no memory phi, and the body's memory
    // operations simply re-run in order each iteration.
    final void tailRecursion(IRModule* m)
        {
        if (!_profile.tailRecursion())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            tailRecInFunc(m, (IRFunc*)m.funcs().get(f));
        }

    final void tailRecInFunc(IRModule* m, IRFunc* fn)
        {
        if (fn.blocks().count() == (u32)0)
            return;
        IRBlock* entry = (IRBlock*)fn.blocks().get((u32)0);
        if (entry.phis().count() != (u32)0)
            return; // entry must be phi-free

        // Variadic self-recursion: the arg marshalling cannot be re-expressed
        // as a parameter reassignment.
        IRSymbol* selfSym = self.symNamed(m, fn.name());
        if (selfSym != 0 && selfSym.variadic())
            return;
        // A pinned local whose address ESCAPES is unsafe: the loop reuses one
        // frame slot, so a callee holding a pointer into a previous "frame"
        // would alias it.
        for (u32 i = (u32)0; i < fn.pinned().count(); i = i + (u32)1)
            if (((IRPinned*)fn.pinned().get(i)).esc())
                return;

        u32 nParams = fn.params().count();
        if (nParams == (u32)0)
            return;
        IRValue* memParam = (IRValue*)fn.params().get(nParams - (u32)1);
        if (!memParam.ty().equals(String.withCString("Mem")))
            return;
        u32 userParams = nParams - (u32)1;

        if (!collectTailReturns(m, fn, userParams))
            return;

        // The parallel-copy hazard: a back edge that feeds parameter phi j the
        // value of a DIFFERENT parameter is a permutation, and the sequential
        // phi-edge copies cannot express it. Passing a parameter through to its
        // own slot is a no-op and fine.
        for (u32 c = (u32)0; c < _trCalls.count(); c = c + (u32)1)
            {
            IRInsn* tc = (IRInsn*)_trCalls.get(c);
            for (u32 j = (u32)0; j < userParams; j = j + (u32)1)
                {
                IROperand* arg = (IROperand*)tc.ops().get((u32)1 + j);
                if (arg.kind() != (u8)OPK_USE || arg.val() == 0)
                    continue;
                i32 pi = paramIndex(fn, arg.val());
                if (pi >= (i32)0 && (u32)pi != j)
                    return;
                }
            }
        buildTailLoop(fn, entry, userParams);
        }

    // Every `return f(args)` (Tier-1) and, where the profile allows it,
    // `return g ⊕ f(args)` (Tier-2). False when there is nothing to iterate.
    final bool collectTailReturns(IRModule* m, IRFunc* fn, u32 userParams)
        {
        _trBlocks = new Array();
        _trCalls = new Array();
        _trCombines = new Array();
        _trGIdx = new Array();
        Map* defOf = self.defMapAll(fn);
        Map* defBlk = self.defBlockMap(fn);
        Map* useCount = self.useCounts(fn);
        Array* t1b = new Array();
        Array* t1c = new Array();
        Array* t2b = new Array();
        Array* t2c = new Array();
        Array* t2m = new Array();
        Array* t2g = new Array();

        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == 0 || !term.op().equals(String.withCString("Return")))
                continue;
            if (term.ops().count() == (u32)0)
                continue;
            IROperand* memOp = (IROperand*)term.ops().get(term.ops().count() - (u32)1);
            if (memOp.kind() != (u8)OPK_USE)
                continue;
            IROperand* valOp = term.ops().count() >= (u32)2
                                   ? (IROperand*)term.ops().get((u32)0)
                                   : (IROperand*)0;

            IRInsn* tc1 = selfTailCall(m, fn, bb, valOp, memOp, defOf, defBlk,
                                       useCount, userParams);
            if (tc1 != 0)
                {
                t1b.add((Object*)bb);
                t1c.add((Object*)tc1);
                continue;
                }
            if (!_profile.accumRecursion())
                continue;
            if (valOp == 0 || valOp.kind() != (u8)OPK_USE || valOp.val() == 0)
                continue;
            Object* cd = defOf.get((Hashable*)valOp.val());
            if (cd == 0)
                continue;
            IRInsn* cmb = (IRInsn*)cd;
            if (defBlk.get((Hashable*)valOp.val()) != (Object*)bb)
                continue;
            if (cmb.ops().count() != (u32)2 || cmb.res() == 0)
                continue;
            if (!isCombineOp(cmb.op()))
                continue;
            if (irWidth(cmb.res().ty()) == (u32)0)
                continue; // integers only
            if (countOf(useCount, valOp.val()) != (u32)1)
                continue;
            for (u32 k = (u32)0; k < (u32)2; k = k + (u32)1)
                {
                IRInsn* c = selfTailCall(m, fn, bb, (IROperand*)cmb.ops().get(k), memOp,
                                         defOf, defBlk, useCount, userParams);
                if (c == 0)
                    continue;
                t2b.add((Object*)bb);
                t2c.add((Object*)c);
                t2m.add((Object*)cmb);
                t2g.add((Object*)Number.with(k == (u32)0 ? (u32)1 : (u32)0));
                break;
                }
            }

        // Tier-2 wins when it is available: every return using the SAME ⊕ is
        // iterated, and the bare tail calls join them.
        if (t2c.count() > (u32)0)
            {
            IRInsn* first = (IRInsn*)t2m.get((u32)0);
            for (u32 i = (u32)0; i < t2c.count(); i = i + (u32)1)
                {
                IRInsn* cmb = (IRInsn*)t2m.get(i);
                if (!cmb.op().equals(first.op()))
                    continue;
                if (!cmb.res().ty().equals(first.res().ty()))
                    continue;
                _trBlocks.add(t2b.get(i));
                _trCalls.add(t2c.get(i));
                _trCombines.add(t2m.get(i));
                _trGIdx.add(t2g.get(i));
                }
            }
        for (u32 i = (u32)0; i < t1c.count(); i = i + (u32)1)
            {
            _trBlocks.add(t1b.get(i));
            _trCalls.add(t1c.get(i));
            _trCombines.add((Object*)0);
            _trGIdx.add((Object*)Number.with((u32)0));
            }
        return _trCalls.count() > (u32)0;
        }

    // A Use of a self-call in THIS block whose memory result is the return's
    // memory (so the call is the last side effect) and whose value is used
    // exactly once — here.
    final IRInsn* selfTailCall(IRModule* m, IRFunc* fn, IRBlock* bb, IROperand* op,
                         IROperand* memOp, Map* defOf, Map* defBlk,
                         Map* useCount, u32 userParams)
        {
        if (op == 0 || op.kind() != (u8)OPK_USE || op.val() == 0)
            return (IRInsn*)0;
        Object* d = defOf.get((Hashable*)op.val());
        if (d == 0)
            return (IRInsn*)0;
        IRInsn* c = (IRInsn*)d;
        if (!callIsSelf(m, c, fn))
            return (IRInsn*)0;
        if (defBlk.get((Hashable*)op.val()) != (Object*)bb)
            return (IRInsn*)0;
        if (c.res() != op.val())
            return (IRInsn*)0;
        if (c.memRes() == 0 || c.memRes() != memOp.val())
            return (IRInsn*)0;
        if (countOf(useCount, op.val()) != (u32)1)
            return (IRInsn*)0;
        if (c.ops().count() != userParams + (u32)2)
            return (IRInsn*)0;
        return c;
        }

    final bool callIsSelf(IRModule* m, IRInsn* n, IRFunc* fn)
        {
        if (!self.isCallOp(n.op()) || n.ops().count() < (u32)2)
            return false;
        IROperand* callee = (IROperand*)n.ops().get((u32)0);
        if (callee.kind() != (u8)OPK_SYM || callee.name() == 0)
            return false;
        return callee.name().equals(fn.name());
        }

    // Associative AND commutative with an unambiguous identity: `And`'s is
    // width-dependent to materialise and is left out, as in the original.
    final bool isCombineOp(String* op)
        {
        return op.equals(String.withCString("Add")) || op.equals(String.withCString("Or")) || op.equals(String.withCString("Xor")) || op.equals(String.withCString("Mul"));
        }

    final i32 combineIdentity(String* op)
        {
        if (op.equals(String.withCString("Mul")))
            return (i32)1;
        return (i32)0;
        }

    final i32 paramIndex(IRFunc* fn, IRValue* v)
        {
        for (u32 i = (u32)0; i < fn.params().count(); i = i + (u32)1)
            if ((IRValue*)fn.params().get(i) == v)
                return (i32)i;
        return (i32)-1;
        }
    // ── the loop the transform builds ────────────────────────────────────
    final void buildTailLoop(IRFunc* fn, IRBlock* entry, u32 userParams)
        {
        String* hname = entry.name() == 0 ? String.withCString("entry")
                                          : String.withString(entry.name());
        hname.appendCString("_loop");
        IRBlock* H = new IRBlock(hname);
        H.setPhis(entry.phis());
        H.setInsns(entry.insns());
        if (entry.term() != 0)
            H.setTerm(entry.term());
        entry.setPhis(new Array());
        entry.setInsns(new Array());
        entry.setTerm((IRInsn*)0);
        Array* one = new Array();
        one.add((Object*)H);
        fn.blocks().insertAll((u32)1, one);
        // A return that lived in the old entry now lives in the header.
        for (u32 i = (u32)0; i < _trBlocks.count(); i = i + (u32)1)
            if ((IRBlock*)_trBlocks.get(i) == entry)
                _trBlocks.set(i, (Object*)H);

        // One phi per parameter, and every use of a parameter becomes a use of
        // its phi. A phi that named the old entry as a predecessor now names H,
        // because the entry's terminator — and so its out-edges — moved there.
        Array* phiRes = new Array();
        Map* remap = new Map();
        for (u32 i = (u32)0; i < userParams; i = i + (u32)1)
            {
            IRValue* pv = (IRValue*)fn.params().get(i);
            IRValue* nv = new IRValue(pv.ty());
            phiRes.add((Object*)nv);
            remap.set((Hashable*)pv, (Object*)IROperand.useVal(nv));
            }
        retargetParams(fn, remap, entry, H);

        // Tier-2's accumulator: the identity in the preheader, a phi in H.
        bool tier2 = _trCombines.count() > (u32)0 && firstCombine() != 0;
        IRValue* accPhi = (IRValue*)0;
        IROperand* accInit = (IROperand*)0;
        String* accTy = (String*)0;
        String* combineOp = (String*)0;
        if (tier2)
            {
            IRInsn* first = firstCombine();
            combineOp = first.op();
            accTy = first.res().ty();
            IRValue* idVal = new IRValue(accTy);
            IRInsn* k = IRInsn.with(String.withCString("Const"));
            k.setRes(idVal);
            k.add(IROperand.immI(combineIdentity(combineOp), accTy));
            entry.add(k);
            accInit = IROperand.useVal(idVal);
            accPhi = new IRValue(accTy);
            }

        // Phi operand lists: the preheader edge first, then one per back edge.
        Array* phiOps = new Array();
        for (u32 i = (u32)0; i < userParams; i = i + (u32)1)
            {
            Array* ops = new Array();
            ops.add((Object*)IROperand.block(entry));
            ops.add((Object*)IROperand.useVal((IRValue*)fn.params().get(i)));
            phiOps.add((Object*)ops);
            }
        Array* accOps = new Array();
        if (tier2)
            {
            accOps.add((Object*)IROperand.block(entry));
            accOps.add((Object*)accInit);
            }

        for (u32 c = (u32)0; c < _trCalls.count(); c = c + (u32)1)
            closeBackEdge(fn, H, c, userParams, phiOps, accOps, accPhi, combineOp, accTy);

        if (tier2)
            wrapBaseReturns(fn, accPhi, combineOp, accTy);

        materialiseHeaderPhis(H, userParams, phiRes, phiOps, accPhi, accOps);

        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H));
        entry.setTerm(br);
        }

    // The header's phis go in FRONT of whatever it already had.
    final void materialiseHeaderPhis(IRBlock* H, u32 userParams, Array* phiRes,
                               Array* phiOps, IRValue* accPhi, Array* accOps)
        {
        Array* newPhis = new Array();
        for (u32 i = (u32)0; i < userParams; i = i + (u32)1)
            newPhis.add((Object*)makePhi((IRValue*)phiRes.get(i), (Array*)phiOps.get(i)));
        if (accPhi != 0)
            newPhis.add((Object*)makePhi(accPhi, accOps));
        for (u32 i = (u32)0; i < H.phis().count(); i = i + (u32)1)
            newPhis.add(H.phis().get(i));
        H.setPhis(newPhis);
        }

    final IRInsn* makePhi(IRValue* res, Array* ops)
        {
        IRInsn* phi = IRInsn.with(String.withCString("Phi"));
        phi.setRes(res);
        for (u32 k = (u32)0; k < ops.count(); k = k + (u32)1)
            phi.add((IROperand*)ops.get(k));
        return phi;
        }

    final IRInsn* firstCombine(void)
        {
        for (u32 i = (u32)0; i < _trCombines.count(); i = i + (u32)1)
            if (_trCombines.get(i) != 0)
                return (IRInsn*)_trCombines.get(i);
        return (IRInsn*)0;
        }

    // Parameter uses become phi uses, and a phi edge that named the old entry
    // block now names the header.
    final void retargetParams(IRFunc* fn, Map* remap, IRBlock* entry, IRBlock* H)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
                retargetInsn((IRInsn*)bb.phis().get(i), remap, entry, H, true);
            for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
                retargetInsn((IRInsn*)bb.insns().get(i), remap, entry, H, false);
            if (bb.term() != 0)
                retargetInsn(bb.term(), remap, entry, H, false);
            }
        }

    final void retargetInsn(IRInsn* n, Map* remap, IRBlock* entry, IRBlock* H, bool isPhi)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() != 0)
                {
                Object* r = remap.get((Hashable*)o.val());
                if (r != 0)
                    n.ops().set(k, (Object*)(IROperand*)r);
                continue;
                }
            if (isPhi && o.kind() == (u8)OPK_BLOCK && o.blk() == entry)
                n.ops().set(k, (Object*)IROperand.block(H));
            }
        }

    // One iterated return becomes a back edge: the call (and Tier-2's combine)
    // leave the block, the arguments feed the phis, and the terminator becomes
    // a Branch to the header. The call's memory input is DROPPED — memory is
    // loose, so the body simply re-runs its memory ops next time round.
    final void closeBackEdge(IRFunc* fn, IRBlock* H, u32 c, u32 userParams,
                       Array* phiOps, Array* accOps, IRValue* accPhi,
                       String* combineOp, String* accTy)
        {
        IRBlock* RB = (IRBlock*)_trBlocks.get(c);
        IRInsn* tc = (IRInsn*)_trCalls.get(c);
        IRInsn* cmb = (IRInsn*)_trCombines.get(c);
        RB.setTerm((IRInsn*)0);
        // The call is about to go, so a later use of its memory result would
        // name a value nothing defines. Forward it to the call's own memory
        // input — memory is loose here, so this changes no behaviour.
        if (tc.memRes() != 0)
            {
            IROperand* memIn = (IROperand*)tc.ops().get(tc.ops().count() - (u32)1);
            if (memIn.kind() == (u8)OPK_USE)
                self.forwardMem(fn, tc.memRes(), memIn.val());
            }
        Array* keep = new Array();
        for (u32 i = (u32)0; i < RB.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)RB.insns().get(i);
            if (n == tc || (cmb != 0 && n == cmb))
                continue;
            keep.add((Object*)n);
            }
        RB.setInsns(keep);

        IROperand* accBack = accPhi == 0 ? (IROperand*)0 : IROperand.useVal(accPhi);
        if (cmb != 0)
            {
            // acc_next = acc_phi ⊕ g, where g is the combine's other operand.
            u32 gi = ((Number*)_trGIdx.get(c)).asU32();
            IROperand* gUse = (IROperand*)cmb.ops().get(gi);
            IRValue* anVal = new IRValue(accTy);
            IRInsn* an = IRInsn.with(combineOp);
            an.setRes(anVal);
            an.add(IROperand.useVal(accPhi));
            an.add(gUse);
            RB.add(an);
            accBack = IROperand.useVal(anVal);
            }
        for (u32 j = (u32)0; j < userParams; j = j + (u32)1)
            {
            Array* ops = (Array*)phiOps.get(j);
            ops.add((Object*)IROperand.block(RB));
            ops.add(tc.ops().get((u32)1 + j));
            }
        if (accPhi != 0)
            {
            accOps.add((Object*)IROperand.block(RB));
            accOps.add((Object*)accBack);
            }
        IRInsn* br = IRInsn.with(String.withCString("Branch"));
        br.add(IROperand.block(H));
        RB.setTerm(br);
        }

    // Tier-2: every remaining (base-case) return hands back acc ⊕ its value.
    final void wrapBaseReturns(IRFunc* fn, IRValue* accPhi, String* combineOp, String* accTy)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            IRInsn* term = bb.term();
            if (term == 0 || !term.op().equals(String.withCString("Return")))
                continue;
            if (term.ops().count() < (u32)2)
                continue;
            IROperand* valOp = (IROperand*)term.ops().get((u32)0);
            IRValue* wVal = new IRValue(accTy);
            IRInsn* w = IRInsn.with(combineOp);
            w.setRes(wVal);
            w.add(IROperand.useVal(accPhi));
            w.add(valOp);
            bb.add(w);
            term.ops().set((u32)0, (Object*)IROperand.useVal(wVal));
            }
        }
    }
