// OptIdiomMemset.xc — the IdiomMemset pass, ported from src/xtc/ir/XTIROptIdiomMemset.m.
// One of the files class Opt is split into (2026-11-01), so the split build
// compiles the optimiser side by side; Opt.xc says how the files layer.

#import "Foundation.xc"
#import <Ir>
#import "IrDefs.xc"
#import <IrParse>
#import "Process.xc"
#import "OptDefs.xc"
#import <OptBase>

    class Opt (IdiomMemset)
    {

    final void idiomMemset(IRModule* m)
        {
        if (!_profile.memsetIdiom())
            return;
        for (u32 f = (u32)0; f < m.funcs().count(); f = f + (u32)1)
            {
            IRFunc* fn = (IRFunc*)m.funcs().get(f);
            for (u32 iter = (u32)0; iter < (u32)256; iter = iter + (u32)1)
                {
                if (!recogniseMemset(fn))
                    break;
                applyMemset(fn);
                }
            }
        }

    final bool recogniseMemset(IRFunc* fn)
        {
        Map* defOf = self.defMapAll(fn);
        Map* defBlk = self.defBlockMap(fn);
        Map* uses = self.useCounts(fn);
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* H = (IRBlock*)fn.blocks().get(b);
            if (memsetHeader(fn, H, defOf, defBlk, uses))
                return true;
            }
        return false;
        }

    // The loop HEADER: one integer phi, a pure body, and a CondBranch on a
    // comparison of that phi against a constant.
    final bool memsetHeader(IRFunc* fn, IRBlock* H, Map* defOf, Map* defBlk, Map* uses)
        {
        if (H.phis().count() != (u32)1)
            return false;
        IRInsn* ivPhi = (IRInsn*)H.phis().get((u32)0);
        if (ivPhi.res() == 0 || ivPhi.memRes() != 0)
            return false;
        if (irWidth(ivPhi.res().ty()) == (u32)0)
            return false;
        IRValue* iv = ivPhi.res();
        for (u32 i = (u32)0; i < H.insns().count(); i = i + (u32)1)
            if (((IRInsn*)H.insns().get(i)).memRes() != 0)
                return false;

        IRInsn* term = H.term();
        if (term == 0 || !term.op().equals(String.withCString("CondBranch")))
            return false;
        if (term.ops().count() < (u32)3)
            return false;
        IROperand* c0 = (IROperand*)term.ops().get((u32)0);
        if (c0.kind() != (u8)OPK_USE || c0.val() == 0)
            return false;
        Object* gd = defOf.get((Hashable*)c0.val());
        if (gd == 0)
            return false;
        IRInsn* guard = (IRInsn*)gd;
        if (!guard.op().equals(String.withCString("ICmp")))
            return false;
        if (defBlk.get((Hashable*)c0.val()) != (Object*)H)
            return false;
        if (guard.ops().count() < (u32)2)
            return false;
        IROperand* g0 = (IROperand*)guard.ops().get((u32)0);
        IROperand* g1 = (IROperand*)guard.ops().get((u32)1);
        bool ivIs0 = g0.kind() == (u8)OPK_USE && g0.val() == iv;
        bool ivIs1 = g1.kind() == (u8)OPK_USE && g1.val() == iv;
        if (ivIs0 == ivIs1)
            return false;
        i64 bound = (i64)0;
        if (!self.constValue(defOf, ivIs0 ? g1 : g0, &bound))
            return false;
        if (bound < (i32)0)
            return false;

        IRBlock* T = ((IROperand*)term.ops().get((u32)1)).blk();
        IRBlock* F = ((IROperand*)term.ops().get((u32)2)).blk();
        IRBlock* B = (IRBlock*)0;
        IRBlock* E = (IRBlock*)0;
        bool bodyOnTrue = false;
        if (latchesTo(T, H))
            {
            B = T;
            E = F;
            bodyOnTrue = true;
            }
        else if (latchesTo(F, H))
            {
            B = F;
            E = T;
            bodyOnTrue = false;
            }
        else
            return false;
        if (E == 0)
            return false;
        if (B.phis().count() != (u32)0 || E.phis().count() != (u32)0)
            return false;

        String* eff = effectivePredicate(guard.pred(), ivIs1, bodyOnTrue);
        if (eff == 0)
            return false;
        bool inclusive = eff.equals(String.withCString("ULE"));

        _msH = H;
        _msB = B;
        _msE = E;
        _msBound = bound;
        _msInclusive = inclusive;
        return memsetBody(fn, ivPhi, iv, defOf, defBlk, uses);
        }

    final bool latchesTo(IRBlock* b, IRBlock* H)
        {
        if (b == 0 || b == H || b.term() == 0)
            return false;
        if (!b.term().op().equals(String.withCString("Branch")))
            return false;
        if (b.term().ops().count() < (u32)1)
            return false;
        return ((IROperand*)b.term().ops().get((u32)0)).blk() == H;
        }

    // The loop-continue predicate, with the operands swapped and the edge
    // negated as needed. 0 when it is not a `<` or `<=` against the bound.
    final String* effectivePredicate(String* pred, bool swapped, bool bodyOnTrue)
        {
        if (pred == 0)
            return (String*)0;
        String* eff = String.withString(pred);
        if (swapped)
            {
            if (eff.equals(String.withCString("ULT")))
                eff = String.withCString("UGT");
            else if (eff.equals(String.withCString("UGT")))
                eff = String.withCString("ULT");
            else if (eff.equals(String.withCString("ULE")))
                eff = String.withCString("UGE");
            else if (eff.equals(String.withCString("UGE")))
                eff = String.withCString("ULE");
            }
        if (!bodyOnTrue)
            {
            if (eff.equals(String.withCString("ULT")))
                eff = String.withCString("UGE");
            else if (eff.equals(String.withCString("UGE")))
                eff = String.withCString("ULT");
            else if (eff.equals(String.withCString("ULE")))
                eff = String.withCString("UGT");
            else if (eff.equals(String.withCString("UGT")))
                eff = String.withCString("ULE");
            else
                return (String*)0;
            }
        if (eff.equals(String.withCString("ULT")) || eff.equals(String.withCString("ULE")))
            return eff;
        return (String*)0;
        }

    // The induction variable's incomings, the body's single store, and the
    // conditions that make the whole loop one MemSet.
    final bool memsetBody(IRFunc* fn, IRInsn* ivPhi, IRValue* iv,
                    Map* defOf, Map* defBlk, Map* uses)
        {
        if (ivPhi.ops().count() != (u32)4)
            return false;
        IROperand* initOp = (IROperand*)0;
        IROperand* nextOp = (IROperand*)0;
        IRBlock* P = (IRBlock*)0;
        if (((IROperand*)ivPhi.ops().get((u32)0)).blk() == _msB)
            {
            nextOp = (IROperand*)ivPhi.ops().get((u32)1);
            P = ((IROperand*)ivPhi.ops().get((u32)2)).blk();
            initOp = (IROperand*)ivPhi.ops().get((u32)3);
            }
        else if (((IROperand*)ivPhi.ops().get((u32)2)).blk() == _msB)
            {
            nextOp = (IROperand*)ivPhi.ops().get((u32)3);
            P = ((IROperand*)ivPhi.ops().get((u32)0)).blk();
            initOp = (IROperand*)ivPhi.ops().get((u32)1);
            }
        if (nextOp == 0 || initOp == 0 || P == 0)
            return false;
        i64 initV = (i64)0;
        if (!self.constValue(defOf, initOp, &initV) || initV != (i32)0)
            return false;
        if (nextOp.kind() != (u8)OPK_USE || nextOp.val() == 0)
            return false;
        Object* nd = defOf.get((Hashable*)nextOp.val());
        if (nd == 0)
            return false;
        IRInsn* ivNext = (IRInsn*)nd;
        if (!ivNext.op().equals(String.withCString("Add")))
            return false;
        if (defBlk.get((Hashable*)nextOp.val()) != (Object*)_msB)
            return false;
        if (countOf(uses, nextOp.val()) != (u32)1)
            return false;
        if (ivNext.ops().count() < (u32)2)
            return false;
        IROperand* na = (IROperand*)ivNext.ops().get((u32)0);
        IROperand* nb = (IROperand*)ivNext.ops().get((u32)1);
        IROperand* stepOp = (IROperand*)0;
        if (na.kind() == (u8)OPK_USE && na.val() == iv)
            stepOp = nb;
        else if (nb.kind() == (u8)OPK_USE && nb.val() == iv)
            stepOp = na;
        i64 step = (i64)0;
        if (stepOp == 0 || !self.constValue(defOf, stepOp, &step) || step != (i32)1)
            return false;

        IRInsn* store = soleStoreIn(_msB);
        if (store == 0 || store.ops().count() < (u32)3)
            return false;
        IROperand* pa = (IROperand*)store.ops().get((u32)0);
        if (pa.kind() != (u8)OPK_USE || pa.val() == 0)
            return false;
        Object* ed = defOf.get((Hashable*)pa.val());
        if (ed == 0)
            return false;
        IRInsn* ea = (IRInsn*)ed;
        if (!ea.op().equals(String.withCString("ElementAddr")))
            return false;
        if (ea.ops().count() < (u32)2)
            return false;
        IROperand* ix = (IROperand*)ea.ops().get((u32)1);
        if (ix.kind() != (u8)OPK_USE || ix.val() != iv)
            return false;
        IROperand* ba = (IROperand*)ea.ops().get((u32)0);
        if (ba.kind() != (u8)OPK_USE || ba.val() == 0)
            return false;
        // A memset fills BYTES: the element has to be one.
        if (!isBytePointer(ba.val().ty()))
            return false;

        // The base must be reconstructable in the preheader: an AddrOf to
        // clone, or a value defined outside the loop.
        Object* bd = defOf.get((Hashable*)ba.val());
        Object* bb = defBlk.get((Hashable*)ba.val());
        bool clonable = bd != 0 && ((IRInsn*)bd).op().equals(String.withCString("AddrOf")) && bb == (Object*)_msB;
        bool invariant = bd == 0 || (bb != (Object*)_msH && bb != (Object*)_msB);
        if (!clonable && !invariant)
            return false;

        i64 fill = (i64)0;
        if (!self.constValue(defOf, (IROperand*)store.ops().get((u32)1), &fill))
            return false;
        IROperand* mi = (IROperand*)store.ops().get((u32)2);
        if (mi.kind() != (u8)OPK_USE || mi.val() == 0)
            return false;
        Object* mb = defBlk.get((Hashable*)mi.val());
        if (mb == (Object*)_msB || mb == (Object*)_msH)
            return false;
        if (ivEscapes(fn, iv))
            return false;

        _msP = P;
        _msStore = store;
        _msBaseDef = clonable ? (IRInsn*)bd : (IRInsn*)0;
        _msBase = ba.val();
        _msFill = fill;
        _msMemIn = mi.val();
        _msMemOut = store.memRes();
        return true;
        }

    // The body's ONE store — and 0 when there is another memory operation, a
    // call, or a volatile store in there with it.
    final IRInsn* soleStoreIn(IRBlock* B)
        {
        IRInsn* store = (IRInsn*)0;
        for (u32 i = (u32)0; i < B.insns().count(); i = i + (u32)1)
            {
            IRInsn* n = (IRInsn*)B.insns().get(i);
            String* op = n.op();
            if (op.equals(String.withCString("Store")))
                {
                if (store != 0)
                    return (IRInsn*)0;
                store = n;
                continue;
                }
            if (op.equals(String.withCString("StoreVolatile")) || op.equals(String.withCString("Load")) || op.equals(String.withCString("LoadVolatile")) || op.equals(String.withCString("MemCopy")) || op.equals(String.withCString("MemSet")) || self.isCallOp(op))
                return (IRInsn*)0;
            }
        return store;
        }

    final bool isBytePointer(String* t)
        {
        return t.equals(String.withCString("Ptr(U8, unbanked)")) || t.equals(String.withCString("Ptr(I8, unbanked)")) || t.equals(String.withCString("Ptr(Bool, unbanked)"));
        }

    // The loop's final index must not be read outside it.
    final bool ivEscapes(IRFunc* fn, IRValue* iv)
        {
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb == _msH || bb == _msB)
                continue;
            if (usesValue(bb.phis(), iv) || usesValue(bb.insns(), iv))
                return true;
            if (bb.term() != 0 && insnUses(bb.term(), iv))
                return true;
            }
        return false;
        }

    final bool usesValue(Array* list, IRValue* v)
        {
        for (u32 i = (u32)0; i < list.count(); i = i + (u32)1)
            if (insnUses((IRInsn*)list.get(i), v))
                return true;
        return false;
        }

    final bool insnUses(IRInsn* n, IRValue* v)
        {
        for (u32 k = (u32)0; k < n.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)n.ops().get(k);
            if (o.kind() == (u8)OPK_USE && o.val() == v)
                return true;
            }
        return false;
        }

    final void applyMemset(IRFunc* fn)
        {
        IRValue* dst = _msBase;
        if (_msBaseDef != 0)
            {
            // The AddrOf lived in the body; the preheader gets its own copy.
            IRValue* res = new IRValue(_msBaseDef.res().ty());
            IRInsn* ad = IRInsn.with(String.withCString("AddrOf"));
            ad.copyDbg(_msBaseDef);
            ad.setRes(res);
            for (u32 k = (u32)0; k < _msBaseDef.ops().count(); k = k + (u32)1)
                ad.add((IROperand*)_msBaseDef.ops().get(k));
            _msP.add(ad);
            dst = res;
            }
        i32 n = _msBound + (_msInclusive ? (i32)1 : (i32)0);
        IRValue* memRes = new IRValue(String.withCString("Mem"));
        IRInsn* ms = IRInsn.with(String.withCString("MemSet"));
        ms.setMemRes(memRes);
        ms.add(IROperand.useVal(dst));
        ms.add(IROperand.immI(_msFill & (i32)$FF, String.withCString("U8")));
        ms.add(IROperand.immI(n, String.withCString("U32")));
        ms.add(IROperand.useVal(_msMemIn));
        _msP.add(ms);

        // Anything outside the loop that read the loop's memory output now
        // reads the MemSet's.
        if (_msMemOut != 0)
            {
            for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
                {
                IRBlock* bb = (IRBlock*)fn.blocks().get(b);
                if (bb == _msH || bb == _msB)
                    continue;
                remapUsesInBlock(bb, _msMemOut, memRes);
                }
            }

        retargetTerminator(_msP, _msH, _msE);
        Array* blocks = new Array();
        for (u32 b = (u32)0; b < fn.blocks().count(); b = b + (u32)1)
            {
            IRBlock* bb = (IRBlock*)fn.blocks().get(b);
            if (bb != _msH && bb != _msB)
                blocks.add((Object*)bb);
            }
        fn.setBlocks(blocks);
        }

    final void retargetTerminator(IRBlock* blk, IRBlock* from, IRBlock* to)
        {
        IRInsn* t = blk.term();
        if (t == 0)
            return;
        for (u32 k = (u32)0; k < t.ops().count(); k = k + (u32)1)
            {
            IROperand* o = (IROperand*)t.ops().get(k);
            if (o.kind() != (u8)OPK_BLOCK || o.blk() != from)
                continue;
            t.ops().set(k, (Object*)IROperand.block(to));
            }
        }

    final void remapUsesInBlock(IRBlock* bb, IRValue* from, IRValue* to)
        {
        for (u32 i = (u32)0; i < bb.phis().count(); i = i + (u32)1)
            self.replaceUse((IRInsn*)bb.phis().get(i), from, IROperand.useVal(to));
        for (u32 i = (u32)0; i < bb.insns().count(); i = i + (u32)1)
            self.replaceUse((IRInsn*)bb.insns().get(i), from, IROperand.useVal(to));
        if (bb.term() != 0)
            self.replaceUse(bb.term(), from, IROperand.useVal(to));
        }
    }
